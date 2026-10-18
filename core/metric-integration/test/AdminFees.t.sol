// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CloseRequest, Ledger, OpenRequest, Stream} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MetricPrice} from "vault/libraries/MetricPrice.sol";
import {VaultMath} from "vault/libraries/VaultMath.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice Audit finding W-1: Metric's factory (the pool admin) may change each bin's additional fees and the notional
/// fee at any time, and those fees widen the pool's quote. Read straight from it, a wider band pushed a winning
/// position across the scale-or-wait line and lowered the profit share's bid: the Sol-2-1 transfer by a fee change.
/// Force closes and profit shares now price at the band without those fees.
contract AdminFeesTest is MetricFixture {
    /// @dev Metric's largest additional fee per bin, 6.5535%.
    uint16 internal constant MAX_ADDITIONAL_FEE_E6 = type(uint16).max;

    /// @dev A short that sold its borrowed base wins as the price falls. With every bin's fees at the maximum, its
    /// force close neither scales (handing its gain to lenders) nor buys through the dearer pool past its budget: it
    /// waits. Once the fees are back, it pays the trader exactly what it would have with the fees never raised.
    function test_forceClose_waitsOutAFeeRiseInsteadOfScaling() public {
        uint256 positionId = _openSoldShort();
        provider.set(uint128(1_980 * Q64), HALF_SPREAD_E5);
        vm.warp(block.timestamp + 10 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 snapshot = vm.snapshotState();
        uint256 quoteBefore = quote.balanceOf(trader);
        vm.prank(closer);
        vault.forceClose(positionId);
        uint256 untouchedPayout = quote.balanceOf(trader) - quoteBefore;
        vm.revertToState(snapshot);
        _setEveryBinFee(MAX_ADDITIONAL_FEE_E6);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.ShortfallUnfilled.selector);
        vault.forceClose(positionId);
        _setEveryBinFee(0);
        vm.prank(closer);
        vault.forceClose(positionId);
        assertGt(untouchedPayout, 0, "the short won");
        assertEq(quote.balanceOf(trader) - quoteBefore, untouchedPayout, "the fee rise cost the trader nothing");
        assertLedger();
    }

    /// @dev A winning short holding its base, closed by its owner: the profit share is the same whether or not the pool
    /// admin has raised every bin's fees, to within the product of the oracle's spread and the admin fee, magnified by
    /// value over profit (about eight here, so 0.03%). Read from the pool's own band, the fee rise would cut the share
    /// by about half.
    function test_profitShare_ignoresTheAdminsFees() public {
        uint256 positionId = _openHeldShort();
        provider.set(uint128(2_400 * Q64), HALF_SPREAD_E5);
        uint128 maximum1 = vault.positionOf(positionId).maximum1;
        uint256 snapshot = vm.snapshotState();
        uint256 feesBefore = _feesInBase();
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: 1e18, repay0: 0, repay1: maximum1}));
        uint256 untouchedShare = _feesInBase() - feesBefore;
        vm.revertToState(snapshot);
        _setEveryBinFee(MAX_ADDITIONAL_FEE_E6);
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: 1e18, repay0: 0, repay1: maximum1}));
        assertGt(untouchedShare, 0, "a winning close pays a share");
        assertApproxEqRel(_feesInBase() - feesBefore, untouchedShare, 5e14, "the same share");
        assertLedger();
    }

    /// @dev With no admin fees the close band is the pool's band; with every bin's fee at the maximum, it stays where
    /// the fee-free band was, to within the product of the oracle's spread and the fee (0.003% in price, half that in
    /// sqrt price), while the pool's band widens by the whole fee. Force closes and profit shares price at this band,
    /// so a band that followed the fees would let the pool admin move value between traders and lenders.
    function test_closeBand_leavesOutTheAdminsFees() public {
        (bool quoted, uint160 freeSqrtBidX96, uint160 freeSqrtAskX96) =
            MetricPrice.tryBandWithoutAdminFees(address(pool), 1, 1e12);
        (uint160 poolSqrtBidX96, uint160 poolSqrtAskX96) = MetricPrice.band(address(pool), 1, 1e12);
        assertTrue(quoted, "quoted");
        assertEq(freeSqrtBidX96, poolSqrtBidX96, "no admin fee: the same bid");
        assertEq(freeSqrtAskX96, poolSqrtAskX96, "no admin fee: the same ask");
        _setEveryBinFee(MAX_ADDITIONAL_FEE_E6);
        (, uint160 raisedSqrtBidX96, uint160 raisedSqrtAskX96) =
            MetricPrice.tryBandWithoutAdminFees(address(pool), 1, 1e12);
        (uint160 widenedSqrtBidX96,) = MetricPrice.band(address(pool), 1, 1e12);
        assertLt(widenedSqrtBidX96, poolSqrtBidX96, "the pool's own band widens");
        assertApproxEqRel(raisedSqrtBidX96, freeSqrtBidX96, 2e13, "the close band's bid stays");
        assertApproxEqRel(raisedSqrtAskX96, freeSqrtAskX96, 2e13, "the close band's ask stays");
    }

    // ---------------------------------------------------------------- helpers

    function _setEveryBinFee(uint16 feeE6) internal {
        // 2 * BINS_PER_SIDE == 80 bins, the fixture's whole pool
        for (int256 binIndex = -int256(BINS_PER_SIDE); binIndex < int256(BINS_PER_SIDE); ++binIndex) {
            pool.setBinAdditionalFees(int16(binIndex), feeE6, feeE6);
        }
    }

    /// @dev A 10,000 USD short 50 ticks above the ask that sold all its borrowed base at entry, with 3% collateral and
    /// no escrow, so it is delinquent at once.
    function _openSoldShort() internal returns (uint256 positionId) {
        OpenRequest memory request = _shortRequest(300e6);
        (, uint160 sqrtAskX96) = MetricPrice.band(address(pool), 1, 1e12);
        (uint256 release0,) = VaultMath.releaseAcrossBand(
            request.liquidity,
            TickMath.getSqrtPriceAtTick(request.tickLower),
            TickMath.getSqrtPriceAtTick(request.tickUpper),
            sqrtAskX96,
            sqrtAskX96
        );
        request.entryAmountIn = release0;
        vm.prank(trader);
        positionId = vault.open(request);
    }

    /// @dev A 10,000 USD short holding its borrowed base and the quote to repay above its range.
    function _openHeldShort() internal returns (uint256 positionId) {
        OpenRequest memory request = _shortRequest(10_010e6);
        vm.prank(trader);
        positionId = vault.open(request);
    }

    function _shortRequest(uint128 collateral) internal returns (OpenRequest memory request) {
        deposit(lender, 100e18, 200_000e6);
        (, uint160 sqrtAskX96) = MetricPrice.band(address(pool), 1, 1e12);
        int24 tickLower = TickMath.getTickAtSqrtPrice(sqrtAskX96) + 50;
        int24 tickUpper = tickLower + 100;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        request.vaultId = vaultId;
        request.isLong = false;
        request.tickLower = tickLower;
        request.tickUpper = tickUpper;
        request.liquidity = uint128(uint256(10_000e6) * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        request.collateral = collateral;
    }

    /// @dev The base owed to the treasury, the fee vault and the lenders' stream: where a profit share in base lands.
    function _feesInBase() internal view returns (uint256) {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        Stream memory stream = vault.streamOf(vaultId);
        return uint256(ledger.treasury0) + ledger.feeVault0 + stream.remaining0;
    }
}
