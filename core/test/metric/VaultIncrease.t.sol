// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {
    CloseRequest,
    IncreaseRequest,
    OpenRequest,
    Position,
    VaultParameters
} from "../../src/metric/vault/VaultTypes.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {VaultFixture} from "./utils/VaultFixture.sol";
import {console} from "forge-std/console.sol";

contract VaultIncreaseTest is VaultFixture {
    uint256 internal constant WAD = 1e18;
    int24 internal constant STRADDLE_LOWER = PRICE_TICK - 300;
    int24 internal constant STRADDLE_UPPER = PRICE_TICK + 300;

    function increaseRequest(uint256 positionId, uint128 liquidity, uint128 collateral, uint128 escrow)
        internal
        pure
        returns (IncreaseRequest memory request)
    {
        request.positionId = positionId;
        request.liquidity = liquidity;
        request.collateral = collateral;
        request.escrow = escrow;
    }

    function increase(IncreaseRequest memory request) internal {
        vm.prank(trader);
        vault.increase(request);
    }

    function _straddle(uint256 notional, uint128 collateral) internal returns (uint256) {
        uint128 liquidity = liquidityFor1(STRADDLE_LOWER, STRADDLE_UPPER, notional);
        return open(openRequest(true, STRADDLE_LOWER, STRADDLE_UPPER, liquidity, collateral));
    }

    function _escrowSpent(uint256 positionId, uint256 escrowIn) internal view returns (uint256) {
        return escrowIn - vault.positionOf(positionId).escrow;
    }

    /// @dev Path A increases; path B opens the added size as a second position at the same moment. Both settle 30 days
    /// later: the premium paid must match within rounding, and the reserves and released amounts must add up exactly.
    function test_increase_chargesAsSettleThenOpen() public {
        deposit(lender, 100e18, 200_000e6);
        uint256 first = _straddle(20_000e6, 12_000e6);
        uint128 added = liquidityFor1(STRADDLE_LOWER, STRADDLE_UPPER, 15_000e6);
        vm.warp(block.timestamp + 10 days);
        setPrice(PRICE_TICK + 150, 1);
        uint256 state = vm.snapshotState();

        increase(increaseRequest(first, added, 9_000e6, 100e6));
        vm.warp(block.timestamp + 30 days);
        vault.settle(first);
        uint256 paidMerged = _escrowSpent(first, 200e6);
        Position memory merged = vault.positionOf(first);

        vm.revertToState(state);
        // The increase charges the old liquidity's realized charge to now; a price point now does the same for the
        // first position's later settle.
        vault.recordPrice(vaultId);
        uint256 second = open(openRequest(true, STRADDLE_LOWER, STRADDLE_UPPER, added, 9_000e6));
        vm.warp(block.timestamp + 30 days);
        vault.settle(first);
        vault.settle(second);
        uint256 paidApart = _escrowSpent(first, 100e6) + _escrowSpent(second, 100e6);
        Position memory one = vault.positionOf(first);
        Position memory two = vault.positionOf(second);

        console.log("merged", paidMerged, "apart", paidApart);
        console.log("M1 merged", merged.maximum1, "M1 sum", uint256(one.maximum1) + two.maximum1);
        assertGt(paidApart, 1e6, "premium accrued");
        assertApproxEqAbs(paidMerged, paidApart, 2, "premium: settle then open");
        assertEq(merged.reserve0, one.reserve0 + two.reserve0, "reserve0");
        assertEq(merged.reserve1, one.reserve1 + two.reserve1, "reserve1");
        assertEq(merged.released0, one.released0 + two.released0, "released0");
        assertEq(merged.released1, one.released1 + two.released1, "released1");
        assertEq(merged.basis, one.basis + two.basis, "basis");
        assertTrue(merged.weight0Wad > 0 && merged.weight0Wad < WAD, "blended weight");
        assertLedger();
    }

    /// @dev The tree's terms depend only on the liquidity and range, so the merged debt is valued exactly as one open of
    /// the total; the extremes are the total's.
    function test_increase_debtMatchesOneOpenOfTheTotal() public {
        deposit(lender, 100e18, 200_000e6);
        uint128 first = liquidityFor1(STRADDLE_LOWER, STRADDLE_UPPER, 20_000e6);
        uint128 added = liquidityFor1(STRADDLE_LOWER, STRADDLE_UPPER, 15_000e6);
        uint256 state = vm.snapshotState();
        uint256 positionId = open(openRequest(true, STRADDLE_LOWER, STRADDLE_UPPER, first, 12_000e6));
        increase(increaseRequest(positionId, added, 9_000e6, 0));
        Position memory merged = vault.positionOf(positionId);
        uint256[3] memory valuesMerged = _values();
        vm.revertToState(state);
        uint256 whole = open(openRequest(true, STRADDLE_LOWER, STRADDLE_UPPER, first + added, 21_000e6));
        Position memory single = vault.positionOf(whole);
        uint256[3] memory valuesSingle = _values();
        assertEq(merged.liquidity, single.liquidity, "liquidity");
        assertEq(merged.maximum0, single.maximum0, "maximum0");
        assertEq(merged.maximum1, single.maximum1, "maximum1");
        assertEq(valuesMerged[0], valuesSingle[0], "below");
        assertEq(valuesMerged[1], valuesSingle[1], "inside");
        assertEq(valuesMerged[2], valuesSingle[2], "above");
    }

    function _values() internal view returns (uint256[3] memory values) {
        int24[3] memory ticks = [STRADDLE_LOWER - 500, PRICE_TICK, STRADDLE_UPPER + 500];
        // three prices
        for (uint256 index = 0; index < 3; ++index) {
            (uint160 sqrtX96,) = VaultMath.rangeSqrtPrices(ticks[index], ticks[index] + 1);
            (uint256 low, uint256 high) = vault.debtValuesAt(vaultId, sqrtX96);
            values[index] = low + high;
        }
    }

    function test_increase_refusesShortfallAndFlag() public {
        deposit(lender, 0, 20_000e6);
        uint256 positionId = openLong(15_000e6, 3_000e6);
        uint128 added = liquidityFor1(PRICE_TICK - 200, PRICE_TICK - 100, 1_000e6);
        vm.warp(block.timestamp + 400 days);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.PremiumUnpaid.selector);
        vault.increase(increaseRequest(positionId, added, 1_000e6, 10_000e6));
        vault.flag(positionId);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.PremiumUnpaid.selector);
        vault.increase(increaseRequest(positionId, added, 1_000e6, 10_000e6));
        vm.prank(trader);
        vault.addEscrow(positionId, 10_000e6);
        increase(increaseRequest(positionId, added, 1_000e6, 0));
        assertLedger();
    }

    function test_increase_onlyOwner() public {
        deposit(lender, 0, 20_000e6);
        uint256 positionId = openLong(10_000e6, 300e6);
        uint128 added = liquidityFor1(PRICE_TICK - 200, PRICE_TICK - 100, 1_000e6);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.Unauthorized.selector);
        vault.increase(increaseRequest(positionId, added, 100e6, 0));
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.increase(increaseRequest(positionId + 1, added, 100e6, 0));
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.ZeroAmount.selector);
        vault.increase(increaseRequest(positionId, 0, 100e6, 0));
    }

    /// @dev The added part alone must reach the minimum borrow, as an open of its size must, though the whole is above it.
    function test_increase_addedPartNeedsTheMinimumBorrow() public {
        deposit(lender, 0, 20_000e6);
        uint256 positionId = openLong(10_000e6, 1_000e6);
        uint128 added = liquidityFor1(PRICE_TICK - 200, PRICE_TICK - 100, 50e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.BelowMinimumBorrow.selector);
        vault.increase(increaseRequest(positionId, added, 0, 0));
    }

    function test_increase_utilizationCeilingCountsTheWhole() public {
        deposit(lender, 0, 10_000e6);
        uint256 positionId = openLong(5_000e6, 3_000e6);
        uint128 added = liquidityFor1(PRICE_TICK - 200, PRICE_TICK - 100, 4_500e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.UtilizationCeiling.selector);
        vault.increase(increaseRequest(positionId, added, 3_000e6, 0));
    }

    /// @dev The chord is the combined position's: an increase with no collateral fails on a barely solvent position and
    /// passes on one whose reserves already cover the added debt.
    function test_increase_chordIsTheCombinedPositions() public {
        deposit(lender, 0, 100_000e6);
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        uint128 liquidity = liquidityFor1(lower, upper, 10_000e6);
        uint256 thin =
            open(openRequest(true, lower, upper, liquidity, uint128(minimumCollateral(lower, upper, liquidity))));
        uint128 added = liquidityFor1(lower, upper, 1_000e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.Insolvent.selector);
        vault.increase(increaseRequest(thin, added, 0, 0));
        uint256 thick = openLong(10_000e6, 2_000e6);
        increase(increaseRequest(thick, added, 0, 0));
        assertLedger();
    }

    function test_increase_requiresTheMinimumEscrowOfTheWhole() public {
        VaultParameters memory parameters = defaultParameters();
        parameters.minimumEscrowSeconds = 30 days;
        vm.prank(owner);
        vaultId = vault.createVault(parameters, defaultCurves());
        deposit(lender, 0, 100_000e6);
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        // 10,000 at 10% utilization is 0.5% a year: about 4.1 over 30 days, which 5 covers.
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, 10_000e6), 2_000e6);
        request.escrow = 5e6;
        uint256 positionId = open(request);
        // 30,000 at 30% is 1.5% a year: about 37 over 30 days, which the 5 left does not cover.
        uint128 added = liquidityFor1(lower, upper, 20_000e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.EscrowTooSmall.selector);
        vault.increase(increaseRequest(positionId, added, 2_000e6, 0));
        increase(increaseRequest(positionId, added, 2_000e6, 40e6));
    }

    function test_increase_entrySwapNeedsAPool() public {
        deposit(lender, 0, 20_000e6);
        uint256 positionId = openLong(10_000e6, 1_000e6);
        IncreaseRequest memory request =
            increaseRequest(positionId, liquidityFor1(PRICE_TICK - 200, PRICE_TICK - 100, 1_000e6), 100e6, 0);
        request.entryAmountIn = 1;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.increase(request);
    }

    /// @dev A merged position closes like any other: in part, then in full, leaving nothing outstanding.
    function test_increase_thenCloseLeavesNothingOutstanding() public {
        deposit(lender, 0, 50_000e6);
        uint256 positionId = openLong(10_000e6, 1_000e6);
        increase(increaseRequest(positionId, liquidityFor1(PRICE_TICK - 200, PRICE_TICK - 100, 5_000e6), 500e6, 0));
        (uint256 repay0, uint256 repay1) = repaymentFor(positionId, 0.5e18);
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: 0.5e18, repay0: repay0, repay1: repay1}));
        (repay0, repay1) = cheapestRepayment(positionId);
        closeFull(positionId, repay0, repay1);
        assertEq(vault.accrualOf(vaultId).outstanding1, 0);
        (uint256 low, uint256 high) = vault.debtValuesAt(vaultId, source.sqrtBidX96());
        assertEq(low + high, 0, "no debt left");
        assertLedger();
    }

    /// @dev `positionsOf` lists the trader's open positions: an increase keeps the id and mints none, and a full close
    /// moves the list's last id into the closed one's place.
    function test_positionsOf_listsOpenPositions() public {
        deposit(lender, 0, 100_000e6);
        uint256 first = openLong(10_000e6, 1_000e6);
        uint256 second = openLong(10_000e6, 1_000e6);
        uint256 third = openLong(10_000e6, 1_000e6);
        increase(increaseRequest(second, liquidityFor1(PRICE_TICK - 200, PRICE_TICK - 100, 1_000e6), 100e6, 0));
        assertEq(vault.lastPositionId(), third, "an increase mints no id");
        (uint256 repay0, uint256 repay1) = cheapestRepayment(first);
        closeFull(first, repay0, repay1);
        (uint256[] memory ids, uint256[] memory makerIds) = vault.positionsOf(trader);
        assertEq(makerIds.length, 0);
        assertEq(ids.length, 2);
        assertEq(ids[0], third, "last moved into the closed slot");
        assertEq(ids[1], second);
        (uint256[] memory lenderIds,) = vault.positionsOf(lender);
        assertEq(lenderIds.length, 0);
    }
}
