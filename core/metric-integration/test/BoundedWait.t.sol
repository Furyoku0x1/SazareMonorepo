// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {OpenRequest} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {VaultPricing} from "vault/libraries/VaultPricing.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice The bounded wait (audit findings W-3 and Sol's verification): a force close waits for a pool that cannot fill
/// its shortfall swap only while the trader would keep something, and scales once the arrears take it all. The rule must
/// compare what the trader keeps with the arrears as the close collects them, token0 at the strike. Valued at the bid
/// instead, it waited years past the point the trader kept nothing (bid above the strike) or scaled away what the
/// trader kept (bid below it). Each test finds, by bisection over days, the first day the swap path leaves the trader
/// nothing and the first day a paused close stops waiting, and requires them to meet.
contract BoundedWaitTest is MetricFixture {
    int24 internal constant PRICE_TICK = -200_311;
    /// @dev The search's horizon: arrears on a low-utilization position grow slowly.
    uint256 internal constant HORIZON_DAYS = 400 * 365;
    /// @dev The wait may outlast the point of zero payout by the swap's real cost over the edge price, a few days here.
    uint256 internal constant TOLERANCE_DAYS = 5;
    /// @dev The fixture's starting price, in whole quote per whole base.
    uint256 internal constant START_PRICE = 2_000;
    /// @dev Hourly steps from the start to the test's price, each recorded as a keeper would: the realized charge then
    /// costs the path's small hourly moves, not one jump across the range.
    uint256 internal constant PRICE_STEPS = 100;

    /// @dev A long that bought base, with the price risen above its range: the bid is above the strike.
    function test_waitEndsWhenTheTraderKeepsNothing_bidAboveTheStrike() public {
        uint256 positionId = _openBaseLong(PRICE_TICK - 200, 300e6, 10_200e6, 2_600);
        _assertWaitMatchesTheTradersStake(positionId);
    }

    /// @dev A long on a wide range, about 1,480 to 1,980 with its strike near 1,712, with the price fallen to 1,500
    /// inside it, below the strike: Sol's case, where the old rule scaled away base the trader would have kept.
    function test_waitEndsWhenTheTraderKeepsNothing_bidBelowTheStrike() public {
        uint256 positionId = _openBaseLong(PRICE_TICK - 3_000, 2_500e6, 12_400e6, 1_500);
        _assertWaitMatchesTheTradersStake(positionId);
    }

    /// @dev The owner's decision on a pool without a price: the close waits `NO_PRICE_WAIT_SECONDS` past the grace
    /// period for the price to return, then scales the reserves instead.
    function test_noPrice_waitsThenScales() public {
        uint256 positionId = _openBaseLong(PRICE_TICK - 200, 300e6, 10_200e6, 2_600);
        provider.setBroken(true);
        uint256 flaggedAt = vault.positionOf(positionId).delinquentSince;
        uint256 scalesFrom = flaggedAt + vault.parametersOf(vaultId).graceSeconds + VaultPricing.NO_PRICE_WAIT_SECONDS;
        vm.warp(scalesFrom - 1);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.PriceUnavailable.selector);
        vault.forceClose(positionId);
        vm.warp(scalesFrom);
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).owner, address(0), "scaled once the wait is over");
        assertLedger();
    }

    function _assertWaitMatchesTheTradersStake(uint256 positionId) internal {
        uint256 zeroDay = _firstDay(positionId, true);
        uint256 scaleDay = _firstDay(positionId, false);
        assertGt(zeroDay, 1, "the trader keeps something at first");
        assertGe(scaleDay, zeroDay, "never scales while the trader would keep something");
        assertLe(scaleDay, zeroDay + TOLERANCE_DAYS, "and stops waiting once it would keep nothing");
    }

    /// @dev The first day (by bisection) on which the swap path pays the trader nothing (`traderZero`), or on which a
    /// close with swaps paused runs instead of waiting.
    function _firstDay(uint256 positionId, bool traderZero) internal returns (uint256) {
        uint256 low = 0;
        uint256 high = HORIZON_DAYS;
        // log2(HORIZON_DAYS) < 18 halvings
        while (high - low > 1) {
            uint256 middle = (low + high) / 2;
            bool reached = traderZero ? _traderGetsNothing(positionId, middle) : _pausedCloseRuns(positionId, middle);
            if (reached) high = middle;
            else low = middle;
        }
        return high;
    }

    function _traderGetsNothing(uint256 positionId, uint256 extraDays) internal returns (bool nothing) {
        uint256 snapshot = vm.snapshotState();
        vm.warp(block.timestamp + extraDays * 1 days);
        uint256 base0 = base.balanceOf(trader);
        uint256 quote0 = quote.balanceOf(trader);
        vm.prank(closer);
        vault.forceClose(positionId);
        nothing = base.balanceOf(trader) == base0;
        if (nothing) nothing = quote.balanceOf(trader) == quote0;
        vm.revertToState(snapshot);
    }

    function _pausedCloseRuns(uint256 positionId, uint256 extraDays) internal returns (bool runs) {
        uint256 snapshot = vm.snapshotState();
        vm.warp(block.timestamp + extraDays * 1 days);
        pool.setPause(1);
        vm.prank(closer);
        try vault.forceClose(positionId) {
            runs = true;
        } catch {
            runs = false;
        }
        vm.revertToState(snapshot);
    }

    /// @dev Moves the price to `wholePrice` in `PRICE_STEPS` even hourly steps, recording a point at each.
    function _walkPrice(uint256 wholePrice) internal {
        // PRICE_STEPS steps
        for (uint256 step = 1; step <= PRICE_STEPS; ++step) {
            uint256 priceX64 = (START_PRICE * (PRICE_STEPS - step) + wholePrice * step) * Q64 / PRICE_STEPS;
            provider.set(uint128(priceX64), HALF_SPREAD_E5);
            // via_ir may reuse one read of `block.timestamp` across warps; the cheatcode reads the current one.
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            assertTrue(vault.recordPrice(vaultId), "an hourly point");
        }
    }

    /// @dev A 10,000 USD long from `lower` to a percent below the price that spent its quote on base, flagged and past
    /// grace at the given price.
    function _openBaseLong(int24 lower, uint128 collateral, uint256 entryAmountIn, uint256 wholePrice)
        internal
        returns (uint256 positionId)
    {
        deposit(lender, 100e18, 100_000e6);
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.tickLower = lower;
        request.tickUpper = upper;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        request.liquidity = uint128(uint256(10_000e6) * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        request.collateral = collateral;
        request.escrow = 1e6;
        request.entryAmountIn = entryAmountIn;
        vm.prank(trader);
        positionId = vault.open(request);
        _walkPrice(wholePrice);
        vm.warp(block.timestamp + 120 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
    }
}
