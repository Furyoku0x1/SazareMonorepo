// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CloseRequest, OpenRequest, Position, Venue} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MetricPrice} from "vault/libraries/MetricPrice.sol";
import {VaultMath} from "vault/libraries/VaultMath.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice Exposes the price reader so tests can compare it with the provider.
contract PriceReader {
    function band(address pool) external returns (uint160, uint160) {
        return MetricPrice.band(pool, 1, 1e12);
    }
}

contract MetricVenueIntegrationTest is MetricFixture {
    uint256 internal constant WAD = 1e18;
    /// @dev Raw price 2e-9 is about tick -200,311.
    int24 internal constant PRICE_TICK = -200_311;

    PriceReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new PriceReader();
    }

    // ---------------------------------------------------------------- price

    /// @dev The band read through the pool brackets the provider's bid and ask, and the cursor's deviation is gone:
    /// pushing the pool off-center leaves the band where it was.
    function test_band_matchesProviderAndIgnoresCursor() public {
        (uint160 bid, uint160 ask) = reader.band(address(pool));
        (uint160 providerBid, uint160 providerAsk) = _providerBand();
        assertLe(bid, providerBid, "bid at or below the provider's");
        assertGe(ask, providerAsk, "ask at or above the provider's");
        assertApproxEqRel(bid, providerBid, 1e14, "bid close to the provider's");
        assertApproxEqRel(ask, providerAsk, 1e14, "ask close to the provider's");
        outsider.swap(pool, false, int128(int256(60_000e6)));
        (uint160 bidAfter, uint160 askAfter) = reader.band(address(pool));
        assertApproxEqRel(bidAfter, bid, 1e12, "cursor move does not move the bid");
        assertApproxEqRel(askAfter, ask, 1e12, "cursor move does not move the ask");
    }

    // ---------------------------------------------------------------- lenders

    function test_deposit_placesAroundTheCursor() public {
        deposit(lender, 20e18, 40_000e6);
        Venue memory venue = vault.venueOf(vaultId);
        assertTrue(venue.windowSet, "window set");
        assertApproxEqRel(venue.holdings0, 20e18, 1e15, "base placed");
        assertApproxEqRel(venue.holdings1, 40_000e6, 1e15, "quote placed");
        assertLt(vault.ledgerOf(vaultId).buffer0, 1e15, "little base left in the buffer");
        assertLedger();
    }

    function test_withdraw_gathersFromMetric() public {
        uint256 shares = deposit(lender, 20e18, 40_000e6);
        uint256 baseBefore = base.balanceOf(lender);
        vm.prank(lender);
        (uint256 amount0, uint256 amount1,) = vault.withdraw(vaultId, shares, 0, 0, lender);
        assertApproxEqRel(amount0, 20e18, 1e15, "base back");
        assertApproxEqRel(amount1, 40_000e6, 1e15, "quote back");
        assertEq(base.balanceOf(lender) - baseBefore, amount0);
        assertLedger();
    }

    // ---------------------------------------------------------------- positions

    function test_openLong_entrySwapThroughMetric() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = _openLong(10_000e6, 300e6, 10_000e6, 100e6);
        Position memory position = vault.positionOf(positionId);
        assertGt(position.reserve0, 4e18, "reserves now hold base");
        assertTrue(
            VaultMath.chordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1), "chord"
        );
        assertLedger();
    }

    function test_close_returnsRepaymentToMetric() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = _openLong(10_000e6, 300e6, 0, 100e6);
        Venue memory before = vault.venueOf(vaultId);
        Position memory position = vault.positionOf(positionId);
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: 0, repay1: position.maximum1}));
        Venue memory afterwards = vault.venueOf(vaultId);
        assertGt(afterwards.holdings1, before.holdings1, "repayment placed back in Metric");
        assertLedger();
    }

    function test_forceClose_buysShortfallThroughMetric() public {
        deposit(lender, 100e18, 100_000e6);
        // A dollar of escrow: premium alone outruns it well within the warp.
        uint256 positionId = _openLong(10_000e6, 300e6, 10_200e6, 1e6);
        vm.warp(block.timestamp + 120 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertEq(vault.accrualOf(vaultId).outstanding1, 0, "debt repaid");
        assertLedger();
    }

    function test_forceClose_scalesWhenMetricIsPaused() public {
        deposit(lender, 100e18, 100_000e6);
        // A dollar of escrow: premium alone outruns it well within the warp.
        uint256 positionId = _openLong(10_000e6, 300e6, 10_200e6, 1e6);
        vm.warp(block.timestamp + 120 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        // The test is the pool's factory, so it can pause swaps; adds and removes still work.
        pool.setPause(1);
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).owner, address(0), "closed by scaling");
        assertLedger();
    }

    function test_callback_refusedWithoutExpectation() public {
        vm.expectRevert(IMetricLendingVault.UnexpectedCallback.selector);
        vault.metricOmmModifyLiquidityCallback(1, 1, "");
        vm.prank(address(pool));
        vm.expectRevert(IMetricLendingVault.UnexpectedCallback.selector);
        vault.metricOmmSwapCallback(1, 1, "");
    }

    // ---------------------------------------------------------------- helpers

    function _openLong(uint256 notional, uint128 collateral, uint256 entryAmountIn, uint128 escrow)
        internal
        returns (uint256)
    {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.tickLower = lower;
        request.tickUpper = upper;
        request.liquidity = _liquidityFor1(lower, upper, notional);
        request.collateral = collateral;
        request.escrow = escrow;
        request.entryAmountIn = entryAmountIn;
        vm.prank(trader);
        return vault.open(request);
    }

    function _liquidityFor1(int24 tickLower, int24 tickUpper, uint256 amount1) internal pure returns (uint128) {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        return uint128(amount1 * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
    }

    function _providerBand() internal view returns (uint160 sqrtBidX96, uint160 sqrtAskX96) {
        (uint128 bidX64, uint128 askX64,) = provider.getQuote();
        // Raw price = whole price · scale0 / scale1 = whole / 1e12.
        sqrtBidX96 = uint160(Math.sqrt(uint256(bidX64) * (1 << 128) / 1e12));
        sqrtAskX96 = uint160(Math.sqrt(uint256(askX64) * (1 << 128) / 1e12));
    }
}
