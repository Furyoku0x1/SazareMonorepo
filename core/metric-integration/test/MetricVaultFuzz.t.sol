// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {PoolStateLibrary} from "metric/libraries/PoolStateLibrary.sol";
import {IMetricOmmPoolActions} from "metric/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {CloseRequest, Ledger, OpenRequest, Position, Venue} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MetricPrice} from "vault/libraries/MetricPrice.sol";
import {DebtTotals, VaultMath} from "vault/libraries/VaultMath.sol";
import {VaultPricing} from "vault/libraries/VaultPricing.sol";
import {PoolReads} from "./invariant/MetricVaultHandler.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice Fuzzed properties of the vault on a real Metric pool. Each states why it must hold.
contract MetricVaultFuzzTest is MetricFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 1 << 96;
    /// @dev Metric rounds each add up and each bin's read down, by under one native unit per bin and operation. In
    /// quote units (6 decimals) the slack below is a few hundredths of a cent at most.
    uint256 internal constant DUST = 100;

    address internal roundTripper = makeAddr("roundTripper");

    function setUp() public override {
        super.setUp();
        base.mint(roundTripper, 1e30);
        quote.mint(roundTripper, 1e30);
        vm.startPrank(roundTripper);
        base.approve(address(vault), type(uint256).max);
        quote.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- (a) the band

    /// @dev The band recovered through the pool brackets the provider's bid and ask, whatever the cursor and the
    /// reference: `MetricPrice` divides out the cursor's deviation `m` and rounds the bid down and the ask up, with a
    /// margin for Metric's floored marginal. Spreads are lopsided up to 2.5:1, inside the pool's 3:1 bound.
    function testFuzz_band_bracketsTheProvidersBand(
        uint256 firstReferenceSeed,
        uint256 secondReferenceSeed,
        uint256 bidHalfSeed,
        uint256 askHalfSeed,
        bool zeroForOne,
        uint256 sizeSeed
    ) public {
        uint256 bidHalf = bound(bidHalfSeed, 1, 500);
        uint256 askHalf = bound(askHalfSeed, (bidHalf * 2 + 4) / 5, bidHalf * 5 / 2);
        provider.setBand(uint128(bound(firstReferenceSeed, 1_000 * Q64, 4_000 * Q64)), bidHalf, askHalf);
        _swapOutside(zeroForOne, sizeSeed, 300e18, 600_000e6);
        // A reference move keeps the cursor's bin and position, so the deviation now multiplies a new reference.
        provider.setBand(uint128(bound(secondReferenceSeed, 1_000 * Q64, 4_000 * Q64)), bidHalf, askHalf);
        (uint160 bandBid, uint160 bandAsk) = _band();
        (uint128 bidX64, uint128 askX64,) = provider.getQuote();
        (, uint160 providerBid) = MetricPrice.toSqrtX96(bidX64, 1, 1e12, false);
        (, uint160 providerAsk) = MetricPrice.toSqrtX96(askX64, 1, 1e12, true);
        assertLe(bandBid, providerBid, "bid at or below the provider's");
        assertGe(bandAsk, providerAsk, "ask at or above the provider's");
        assertApproxEqRel(bandBid, providerBid, 1e6, "bid within 1e-12");
        assertApproxEqRel(bandAsk, providerAsk, 1e6, "ask within 1e-12");
    }

    // ---------------------------------------------------------------- (b) lender round trip

    /// @dev After outside trading, a deposit withdrawn at once returns, valued at the band's bid:
    /// - at most what went in, plus rounding dust. Shares are priced at the ask and redeemed at the bid, so the claim is
    ///   `v·(V_bid + v)/(V_ask + v) ≤ v`: no one gains from the spread earned before the deposit.
    /// - at least `v · bid/ask` less dust, because `V_bid/V_ask ≥ bid/ask` for any idle basket: the round trip
    ///   costs at most the band's width.
    function testFuzz_depositWithdraw_roundTripWithinTheBand(
        uint256 amount0,
        uint256 amount1,
        bool zeroForOne,
        uint256 sizeSeed,
        uint256 secondSizeSeed
    ) public {
        deposit(lender, 20e18, 40_000e6);
        _swapOutside(zeroForOne, sizeSeed, 60e18, 120_000e6);
        _swapOutside(!zeroForOne, secondSizeSeed, 60e18, 120_000e6);
        amount0 = bound(amount0, 0, 50e18);
        amount1 = bound(amount1, 0, 100_000e6);
        (uint160 sqrtBidX96, uint160 sqrtAskX96) = _band();
        uint256 valueIn = VaultMath.valueInToken1(amount0, amount1, sqrtBidX96, false);
        vm.assume(valueIn >= 10e6);
        uint256 shares = deposit(roundTripper, amount0, amount1);
        vm.prank(roundTripper);
        (uint256 out0, uint256 out1, uint256 burned) = vault.withdraw(vaultId, shares, 0, 0, roundTripper);
        uint256 valueOut = VaultMath.valueInToken1(out0, out1, sqrtBidX96, false);
        assertLe(valueOut, valueIn + DUST, "a round trip gains nothing");
        if (burned == shares) {
            uint256 floor = FullMath.mulDiv(FullMath.mulDiv(valueIn, sqrtBidX96, sqrtAskX96), sqrtBidX96, sqrtAskX96);
            assertGe(valueOut + 10 * DUST, floor, "a round trip loses at most the band's width");
        }
        assertLedger();
        _assertAllInsideWindow();
    }

    // ---------------------------------------------------------------- (c) trader round trip

    /// @dev Open then close in the same block, repaying the cheapest passing amount at the band's bid. The band
    /// ignores the cursor the entry swap moved, so the close's bid is the open's: lenders get back, token by token,
    /// at least the release `(x(ask), y(bid))`, since `x` falls with price and the repayment rounds up. When the
    /// reserves cannot hold the bid's holdings, the whole reserves repay, and chord-solvent reserves are worth at least
    /// the range's holdings at any price. All debt totals return to zero and the ledger holds.
    function testFuzz_openClose_repaysAtLeastTheRelease(
        bool isLong,
        uint256 offsetSeed,
        uint256 widthSeed,
        uint256 notionalSeed,
        uint256 entrySeed,
        bool zeroForOne,
        uint256 sizeSeed
    ) public {
        deposit(lender, 100e18, 200_000e6);
        _swapOutside(zeroForOne, sizeSeed, 60e18, 120_000e6);
        (uint160 sqrtBidX96,) = _band();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtBidX96);
        int24 lower = tick - 800 + int24(int256(bound(offsetSeed, 0, 1_200)));
        int24 upper = lower + int24(int256(bound(widthSeed, 10, 600)));
        OpenRequest memory request = _request(isLong, lower, upper, bound(notionalSeed, 150e6, 25_000e6), 10, entrySeed);
        vm.prank(trader);
        try vault.open(request) returns (uint256 positionId) {
            Position memory position = vault.positionOf(positionId);
            (uint256 repay0, uint256 repay1, bool atBid) = _cheapestAtBid(position);
            vm.prank(trader);
            vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: repay0, repay1: repay1}));
            if (atBid) {
                assertGe(repay0, position.released0, "token0 back");
                assertGe(repay1, position.released1, "token1 back");
            } else {
                (uint160 bidNow,) = _band();
                assertGe(
                    VaultMath.valueInToken1(repay0, repay1, bidNow, false),
                    VaultMath.valueInToken1(position.released0, position.released1, bidNow, false),
                    "value back"
                );
            }
            _assertNoDebt();
            assertLedger();
            _assertAllInsideWindow();
        } catch (bytes memory reason) {
            _requireRefusal(reason);
        }
    }

    /// @dev When lenders hold only the borrowed token and the range lies outside the band on its side (a long below
    /// the bid borrowing quote, a short above the ask borrowing base), the vault's bins all lie on the far side of the
    /// cursor from the entry swap, so the swap trades only against outside liquidity. A same-block round trip then
    /// leaves lenders' idle value at the bid where it was, less Metric's rounding dust: the repayment is worth at least
    /// the release, and any profit share only adds. (With the vault's own bins in the swap's path, lenders carry
    /// ordinary LP gains and losses at the cursor's price, which no vault rule bounds; that case is not asserted.)
    function testFuzz_openClose_lendersKeepTheirValue(
        bool isLong,
        uint256 gapSeed,
        uint256 widthSeed,
        uint256 notionalSeed,
        uint256 entrySeed,
        bool zeroForOne,
        uint256 sizeSeed
    ) public {
        _swapOutside(zeroForOne, sizeSeed, 60e18, 120_000e6);
        if (isLong) deposit(lender, 0, 200_000e6);
        else deposit(lender, 100e18, 0);
        (uint160 sqrtBidX96, uint160 sqrtAskX96) = _band();
        int24 width = int24(int256(bound(widthSeed, 10, 400)));
        int24 gap = int24(int256(bound(gapSeed, 0, 200)));
        int24 lower = isLong
            ? TickMath.getTickAtSqrtPrice(sqrtBidX96) - gap - width
            : TickMath.getTickAtSqrtPrice(sqrtAskX96) + 1 + gap;
        OpenRequest memory request =
            _request(isLong, lower, lower + width, bound(notionalSeed, 150e6, 25_000e6), 5, entrySeed);
        uint256 valueBefore = _idleValue(sqrtBidX96);
        vm.prank(trader);
        try vault.open(request) returns (uint256 positionId) {
            Position memory position = vault.positionOf(positionId);
            assertEq(isLong ? position.released0 : position.released1, 0, "only the borrowed token released");
            (uint256 repay0, uint256 repay1,) = _cheapestAtBid(position);
            vm.prank(trader);
            vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: repay0, repay1: repay1}));
            assertGe(_idleValue(sqrtBidX96) + DUST, valueBefore, "lenders' idle value at the bid");
            _assertNoDebt();
            assertLedger();
        } catch (bytes memory reason) {
            _requireRefusal(reason);
        }
    }

    // ---------------------------------------------------------------- (d) force close

    /// @dev After its grace period a delinquent position force closes, or waits for a pool that cannot fill its
    /// shortfall swap: with the pool live or paused the close may wait, changing nothing; with the provider failing
    /// (no bid) it always closes, since scaling needs no price. Outside trading and a reference move in between put the
    /// price anywhere.
    function testFuzz_forceClose_closesOrWaitsForThePool(
        bool isLong,
        uint256 offsetSeed,
        uint256 widthSeed,
        uint256 notionalSeed,
        uint256 entrySeed,
        bool zeroForOne,
        uint256 sizeSeed,
        uint256 referenceSeed,
        uint8 mode
    ) public {
        deposit(lender, 100e18, 200_000e6);
        (uint160 sqrtBidX96,) = _band();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtBidX96);
        int24 lower = tick - 800 + int24(int256(bound(offsetSeed, 0, 1_200)));
        int24 upper = lower + int24(int256(bound(widthSeed, 10, 600)));
        OpenRequest memory request = _request(isLong, lower, upper, bound(notionalSeed, 150e6, 25_000e6), 10, entrySeed);
        request.escrow = 0;
        vm.prank(trader);
        try vault.open(request) returns (uint256 positionId) {
            _swapOutside(zeroForOne, sizeSeed, 300e18, 600_000e6);
            provider.set(uint128(bound(referenceSeed, 1_900 * Q64, 2_100 * Q64)), HALF_SPREAD_E5);
            vm.warp(block.timestamp + 30 days);
            vault.flag(positionId);
            vm.warp(block.timestamp + 1 days);
            if (mode % 2 == 1) pool.setPause(1);
            if ((mode / 2) % 2 == 1) provider.setBroken(true);
            _forceCloseOrWait(positionId, (mode / 2) % 2 == 1);
        } catch (bytes memory reason) {
            _requireRefusal(reason);
        }
    }

    /// @dev A force close after grace closes, or waits, changing nothing: with a price, for a pool that cannot fill its
    /// shortfall swap (audit finding Sol-2-1); without one, until the wait without a price is over, when it scales.
    function _forceCloseOrWait(uint256 positionId, bool unpriced) internal {
        vm.prank(closer);
        try vault.forceClose(positionId) {
            assertFalse(unpriced, "a close without a price waits first");
            _assertForceClosed(positionId);
        } catch (bytes memory reason) {
            bytes4 waits = unpriced
                ? IMetricLendingVault.PriceUnavailable.selector
                : IMetricLendingVault.ShortfallUnfilled.selector;
            assertEq(bytes4(reason), waits, "only an unfilled swap or a missing price waits");
            assertEq(vault.positionOf(positionId).owner, trader, "still open");
            assertLedger();
            if (!unpriced) return;
            vm.warp(block.timestamp + VaultPricing.NO_PRICE_WAIT_SECONDS);
            vm.prank(closer);
            vault.forceClose(positionId);
            _assertForceClosed(positionId);
        }
    }

    function _assertForceClosed(uint256 positionId) internal view {
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        _assertNoDebt();
        assertLedger();
        _assertAllInsideWindow();
    }

    /// @dev A short that sold all its base needs base back. With the pool's base bought out the exact-out swap can
    /// only fill partially, so the callback refuses it and nothing moves; the close waits rather than scale the
    /// trader's surplus away (audit finding Sol-2-1). Once the base is sold back, it buys exactly what repays.
    function test_forceClose_waitsForDepthThenBuys() public {
        deposit(lender, 100e18, 200_000e6);
        (, uint160 sqrtAskX96) = _band();
        int24 lower = TickMath.getTickAtSqrtPrice(sqrtAskX96) + 50;
        OpenRequest memory request = _request(false, lower, lower + 100, 10_000e6, 10, 0);
        request.escrow = 0;
        (uint256 release0,) = VaultMath.releaseAcrossBand(
            request.liquidity,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(lower + 100),
            sqrtAskX96,
            sqrtAskX96
        );
        request.entryAmountIn = release0;
        vm.prank(trader);
        uint256 positionId = vault.open(request);
        assertEq(vault.positionOf(positionId).reserve0, 0, "all base sold");
        // Buy out every unit of base the pool has.
        uint256 outsiderBase = base.balanceOf(address(outsider));
        outsider.swap(pool, false, int128(int256(1e24)));
        uint256 bought = base.balanceOf(address(outsider)) - outsiderBase;
        assertLt(base.balanceOf(address(pool)), vault.positionOf(positionId).maximum0, "base is short of the debt");
        vm.warp(block.timestamp + 30 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days);
        Position memory before = vault.positionOf(positionId);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.ShortfallUnfilled.selector);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).reserve1, before.reserve1, "nothing moved");
        // The depth comes back.
        outsider.swap(pool, true, int128(int256(bought)));
        uint256 poolBaseBefore = base.balanceOf(address(pool));
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertLt(base.balanceOf(address(pool)), poolBaseBefore, "bought its base");
        _assertNoDebt();
        assertLedger();
        _assertAllInsideWindow();
    }

    // ---------------------------------------------------------------- placement after a jump

    /// @dev Audit finding X-1: however far outside trading pushes the cursor, a deposit waits in the buffer and the
    /// window holds still, so the vault's tokens never land on the wrong side of the oracle price. Every
    /// share stays inside the window and the ledger holds; once the trade is reversed, a deposit places again.
    function testFuzz_pushedCursor_depositWaitsForTheReference(bool up, uint256 sizeSeed) public {
        deposit(lender, 20e18, 40_000e6);
        Venue memory before = vault.venueOf(vaultId);
        uint256 outsiderBase = base.balanceOf(address(outsider));
        if (up) outsider.swap(pool, false, int128(int256(bound(sizeSeed, 150_000e6, 800_000e6))));
        else outsider.swap(pool, true, int128(int256(bound(sizeSeed, 75e18, 400e18))));
        uint256 buffer1Before = vault.ledgerOf(vaultId).buffer1;
        deposit(lender, 0, 10_000e6);
        assertEq(vault.ledgerOf(vaultId).buffer1, buffer1Before + 10_000e6, "the deposit waits in the buffer");
        assertEq(vault.venueOf(vaultId).lowestBin, before.lowestBin, "the window held still");
        _assertAllInsideWindow();
        assertLedger();
        // Reverse the trade: the cursor returns to the reference and the waiting quote is placed.
        if (up) outsider.swap(pool, true, int128(int256(base.balanceOf(address(outsider)) - outsiderBase)));
        else outsider.swap(pool, false, -int128(int256(outsiderBase - base.balanceOf(address(outsider)))));
        deposit(lender, 0, 1_000e6);
        assertLt(vault.ledgerOf(vaultId).buffer1, buffer1Before + 11_000e6, "placed once back at the reference");
        _assertAllInsideWindow();
        assertLedger();
    }

    // ---------------------------------------------------------------- helpers

    function _band() internal returns (uint160, uint160) {
        return MetricPrice.band(address(pool), 1, 1e12);
    }

    /// @dev With ample idle and collateral, an open may be refused only because an adverse entry swap broke the chord,
    /// or because a dust entry swap rounds to no output.
    function _requireRefusal(bytes memory reason) internal pure {
        bytes4 selector = bytes4(reason);
        assertTrue(
            selector == IMetricLendingVault.Insolvent.selector
                || selector == IMetricOmmPoolActions.FinalAmountIsZero.selector,
            vm.toString(reason)
        );
    }

    function _swapOutside(bool zeroForOne, uint256 sizeSeed, uint256 maximumBase, uint256 maximumQuote) internal {
        uint256 amount = zeroForOne ? bound(sizeSeed, 1e15, maximumBase) : bound(sizeSeed, 1e6, maximumQuote);
        try outsider.swap(pool, zeroForOne, int128(int256(amount))) {} catch {}
    }

    /// @dev Collateral covers the chord's gap at the band plus `extraPercent` of `M1`; the entry swap sells 0 to 100%
    /// of the reserves' input token.
    function _request(bool isLong, int24 lower, int24 upper, uint256 notional, uint256 extraPercent, uint256 entrySeed)
        internal
        returns (OpenRequest memory request)
    {
        (uint160 sqrtBidX96, uint160 sqrtAskX96) = _band();
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        uint128 liquidity = uint128(FullMath.mulDiv(notional, Q96, sqrtUpperX96 - sqrtLowerX96));
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        (uint256 release0, uint256 release1) =
            VaultMath.releaseAcrossBand(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96, sqrtAskX96);
        uint256 covered = release1 + FullMath.mulDiv(release0, maximum1, maximum0);
        uint256 collateral = (covered >= maximum1 ? 0 : maximum1 - covered) + maximum1 * extraPercent / 100;
        request.vaultId = vaultId;
        request.isLong = isLong;
        request.tickLower = lower;
        request.tickUpper = upper;
        request.liquidity = liquidity;
        request.collateral = uint128(collateral);
        request.escrow = 10e6;
        request.entryAmountIn = (isLong ? release1 + collateral : release0) * bound(entrySeed, 0, 100) / 100;
    }

    /// @dev The range's holdings at the band's bid, rounded up (one more unit if that misses the rule), when the
    /// reserves hold them; otherwise the whole reserves.
    function _cheapestAtBid(Position memory position) internal returns (uint256 repay0, uint256 repay1, bool atBid) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        (uint160 sqrtBidX96,) = _band();
        uint160 inside = sqrtBidX96 < sqrtLowerX96 ? sqrtLowerX96 : sqrtBidX96;
        inside = inside > sqrtUpperX96 ? sqrtUpperX96 : inside;
        repay0 = SqrtPriceMath.getAmount0Delta(inside, sqrtUpperX96, position.liquidity, true);
        repay1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, inside, position.liquidity, true);
        if (!VaultMath.repays(repay0, repay1, position.liquidity, sqrtLowerX96, sqrtUpperX96)) {
            repay0 += 1;
            repay1 += 1;
        }
        if (repay0 <= position.reserve0 && repay1 <= position.reserve1) return (repay0, repay1, true);
        return (position.reserve0, position.reserve1, false);
    }

    /// @dev Lenders' idle tokens, the buffer plus the Metric position read from the pool, valued at a bid.
    function _idleValue(uint160 sqrtBidX96) internal view returns (uint256) {
        Venue memory venue = vault.venueOf(vaultId);
        (uint256 placed0, uint256 placed1) = PoolReads.holdings(
            address(pool),
            address(vault),
            vaultId,
            venue.lowestBin,
            vault.parametersOf(vaultId).binCount,
            venue.scale0,
            venue.scale1
        );
        Ledger memory ledger = vault.ledgerOf(vaultId);
        return VaultMath.valueInToken1(ledger.buffer0 + placed0, ledger.buffer1 + placed1, sqrtBidX96, false);
    }

    function _assertNoDebt() internal view {
        assertEq(vault.accrualOf(vaultId).outstanding0, 0, "outstanding0");
        assertEq(vault.accrualOf(vaultId).outstanding1, 0, "outstanding1");
        (DebtTotals memory longDebts, DebtTotals memory shortDebts) = vault.debtsOf(vaultId);
        assertEq(longDebts.liquidity + shortDebts.liquidity, 0, "debts");
        (, uint256 high) = vault.debtValuesAt(vaultId, TickMath.getSqrtPriceAtTick(0));
        assertEq(high, 0, "nothing left in the debt tree");
    }

    function _assertAllInsideWindow() internal view {
        Venue memory venue = vault.venueOf(vaultId);
        uint256 binCount = vault.parametersOf(vaultId).binCount;
        // every pool bin
        for (int256 binIndex = venue.poolLowestBin; binIndex <= venue.poolHighestBin; ++binIndex) {
            uint256 ours =
                PoolStateLibrary._positionBinShares(address(pool), address(vault), uint80(vaultId), int16(binIndex));
            if (ours == 0) continue;
            assertGe(binIndex, venue.lowestBin, "inside window, low side");
            assertLt(binIndex, int256(venue.lowestBin) + int256(binCount), "inside window, high side");
        }
    }
}
