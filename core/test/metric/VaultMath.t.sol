// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Curve, DebtTotals, VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";

/// @notice Exposes the library's reverting functions so tests can expect their errors.
contract VaultMathHarness {
    function rangeSqrtPrices(int24 tickLower, int24 tickUpper) external pure returns (uint160, uint160) {
        return VaultMath.rangeSqrtPrices(tickLower, tickUpper);
    }

    function scaleToRepay(uint256 reserve0, uint256 reserve1, uint128 liquidity, int24 tickLower, int24 tickUpper)
        external
        pure
        returns (uint256)
    {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(tickLower, tickUpper);
        return VaultMath.scaleToRepay(reserve0, reserve1, liquidity, sqrtLowerX96, sqrtUpperX96);
    }
}

contract VaultMathTest is Test {
    uint256 internal constant WAD = 1e18;
    /// @dev The library's own range bound.
    int24 internal constant TICK_BOUND = VaultMath.MAX_RANGE_TICK;
    uint128 internal constant MAX_LIQUIDITY = 2 ** 100;

    VaultMathHarness internal harness;

    function setUp() public {
        harness = new VaultMathHarness();
    }

    // ---- Ranges and extremes ----

    function test_rangeSqrtPrices_rejectsEmptyAndOutOfBounds() public {
        vm.expectRevert(VaultMath.InvalidRange.selector);
        harness.rangeSqrtPrices(10, 10);
        vm.expectRevert(VaultMath.InvalidRange.selector);
        harness.rangeSqrtPrices(10, 5);
        vm.expectRevert(VaultMath.InvalidRange.selector);
        harness.rangeSqrtPrices(-VaultMath.MAX_RANGE_TICK - 1, 0);
        vm.expectRevert(VaultMath.InvalidRange.selector);
        harness.rangeSqrtPrices(0, VaultMath.MAX_RANGE_TICK + 1);
    }

    function test_extremes_matchV3Corners() public pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(-600, 600);
        uint128 liquidity = 1e24;
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        (uint256 below0, uint256 below1) = VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtLowerX96);
        (uint256 above0, uint256 above1) = VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtUpperX96);
        assertEq(below1, 0);
        assertEq(above0, 0);
        // Extremes round up and add one unit, holdings round down: they differ by at most two units.
        assertLe(maximum0 - below0, 2);
        assertLe(maximum1 - above1, 2);
    }

    // ---- Repayment rule ----

    /// @dev Repaying nothing never passes, however small the range's virtual reserves (the failing seed of the first
    /// draft: a range near the lowest allowed price with liquidity 1e6).
    function testFuzz_nothingNeverRepays(int24 tickSeed, uint24 widthSeed, uint128 liquiditySeed) public pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity) = _range(tickSeed, widthSeed, liquiditySeed);
        assertFalse(VaultMath.repays(0, 0, liquidity, sqrtLowerX96, sqrtUpperX96));
    }

    function test_repays_cornersAndBelowCorners() public pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(-600, 600);
        uint128 liquidity = 1e24;
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        assertTrue(VaultMath.repays(maximum0, 0, liquidity, sqrtLowerX96, sqrtUpperX96));
        assertTrue(VaultMath.repays(0, maximum1, liquidity, sqrtLowerX96, sqrtUpperX96));
        // One part in a million short of a corner fails.
        assertFalse(VaultMath.repays(maximum0 - maximum0 / 1e6, 0, liquidity, sqrtLowerX96, sqrtUpperX96));
        assertFalse(VaultMath.repays(0, maximum1 - maximum1 / 1e6, liquidity, sqrtLowerX96, sqrtUpperX96));
        assertTrue(VaultMath.repays(0, 0, 0, sqrtLowerX96, sqrtUpperX96));
    }

    /// @dev Every reserve on (or rounded above) the chord of the rounded-up extremes repays.
    function testFuzz_chordSolventReservesRepay(int24 tickSeed, uint24 widthSeed, uint128 liquiditySeed, uint256 t)
        public
        pure
    {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity) = _range(tickSeed, widthSeed, liquiditySeed);
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        t = bound(t, 0, WAD);
        uint256 reserve0 = VaultMath.portionUp(maximum0, t);
        uint256 reserve1 = VaultMath.portionUp(maximum1, WAD - t);
        assertTrue(VaultMath.chordHolds(reserve0, reserve1, maximum0, maximum1));
        assertTrue(VaultMath.repays(reserve0, reserve1, liquidity, sqrtLowerX96, sqrtUpperX96));
    }

    /// @dev The range's own holdings at any price, rounded up plus one unit, repay; the same amounts cut by a hundredth
    /// of a percent do not, once they are large enough for the cut to exceed rounding.
    function testFuzz_holdingsRepayAndLessDoesNot(
        int24 tickSeed,
        uint24 widthSeed,
        uint128 liquiditySeed,
        uint256 priceSeed
    ) public pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity) = _range(tickSeed, widthSeed, liquiditySeed);
        uint160 sqrtPriceX96 = uint160(bound(priceSeed, sqrtLowerX96, sqrtUpperX96));
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpperX96, liquidity, true) + 1;
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtPriceX96, liquidity, true) + 1;
        assertTrue(VaultMath.repays(amount0, amount1, liquidity, sqrtLowerX96, sqrtUpperX96));
        if (amount0 < 1e12) return;
        if (amount1 < 1e12) return;
        uint256 short0 = amount0 - amount0 / 1e4;
        uint256 short1 = amount1 - amount1 / 1e4;
        assertFalse(VaultMath.repays(short0, short1, liquidity, sqrtLowerX96, sqrtUpperX96));
    }

    // ---- Release at open ----

    /// @dev The release across a band is at most the holdings at every price inside it.
    function testFuzz_releaseAtMostHoldingsInsideBand(
        int24 tickSeed,
        uint24 widthSeed,
        uint128 liquiditySeed,
        uint256 bidSeed,
        uint256 askSeed,
        uint256 priceSeed
    ) public pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity) = _range(tickSeed, widthSeed, liquiditySeed);
        uint160 lowSqrtX96 = sqrtLowerX96 / 2 + 1;
        uint160 highSqrtX96 = sqrtUpperX96 + sqrtUpperX96 / 2;
        uint160 sqrtBidX96 = uint160(bound(bidSeed, lowSqrtX96, highSqrtX96));
        uint160 sqrtAskX96 = uint160(bound(askSeed, sqrtBidX96, highSqrtX96));
        uint160 sqrtPriceX96 = uint160(bound(priceSeed, sqrtBidX96, sqrtAskX96));
        (uint256 release0, uint256 release1) =
            VaultMath.releaseAcrossBand(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96, sqrtAskX96);
        (uint256 hold0, uint256 hold1) = VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtPriceX96);
        assertLe(release0, hold0);
        assertLe(release1, hold1);
    }

    function test_release_outsideBandIsAnExtreme() public pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(-1200, -600);
        uint128 liquidity = 1e24;
        (uint160 sqrtBidX96,) = VaultMath.rangeSqrtPrices(-10, 10);
        (, uint160 sqrtAskX96) = VaultMath.rangeSqrtPrices(-10, 10);
        (uint256 release0, uint256 release1) =
            VaultMath.releaseAcrossBand(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96, sqrtAskX96);
        (, uint256 above1) = VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtUpperX96);
        assertEq(release0, 0);
        assertEq(release1, above1);
    }

    // ---- Force-close scale ----

    /// @dev The fraction repays, and one unit less does not: it is the smallest.
    function testFuzz_scaleToRepayIsMinimal(
        int24 tickSeed,
        uint24 widthSeed,
        uint128 liquiditySeed,
        uint256 t,
        uint256 surplusSeed
    ) public view {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity) = _range(tickSeed, widthSeed, liquiditySeed);
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        t = bound(t, 0, WAD);
        uint256 surplusWad = bound(surplusSeed, WAD, 10 * WAD);
        uint256 reserve0 = VaultMath.portionUp(VaultMath.portionUp(maximum0, t), surplusWad);
        uint256 reserve1 = VaultMath.portionUp(VaultMath.portionUp(maximum1, WAD - t), surplusWad);
        uint256 fractionWad = _scale(reserve0, reserve1, liquidity, sqrtLowerX96, sqrtUpperX96);
        assertTrue(_repaysPortion(reserve0, reserve1, fractionWad, liquidity, sqrtLowerX96, sqrtUpperX96), "repays");
        if (fractionWad == 0) return;
        assertFalse(
            _repaysPortion(reserve0, reserve1, fractionWad - 1, liquidity, sqrtLowerX96, sqrtUpperX96), "minimal"
        );
    }

    function test_scaleToRepay_revertsWhenReservesShort() public {
        vm.expectRevert(VaultMath.ReservesShort.selector);
        harness.scaleToRepay(1, 1, 1e24, -600, 600);
    }

    // ---- Debt value bounds ----

    /// @dev For up to three debts at any price: lower ≤ value ≤ upper.
    function testFuzz_debtValueBounds(uint256[9] memory seeds, uint256 priceSeed) public pure {
        DebtTotals memory totals;
        uint256 valueLow;
        uint256 valueHigh;
        uint160 sqrtPriceX96 = uint160(
            bound(priceSeed, TickMath.getSqrtPriceAtTick(-TICK_BOUND), TickMath.getSqrtPriceAtTick(TICK_BOUND))
        );
        // three debts, three seeds each
        for (uint256 debt = 0; debt < 3; ++debt) {
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity) = _range(
                int24(int256(seeds[3 * debt] % 2 ** 23)), uint24(seeds[3 * debt + 1]), uint128(seeds[3 * debt + 2])
            );
            _add(totals, VaultMath.debtTerms(liquidity, sqrtLowerX96, sqrtUpperX96));
            (uint256 hold0, uint256 hold1) = VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtPriceX96);
            valueLow += VaultMath.valueInToken1(hold0, hold1, sqrtPriceX96, false);
            uint256 up0 = sqrtPriceX96 >= sqrtUpperX96
                ? 0
                : SqrtPriceMath.getAmount0Delta(_max(sqrtPriceX96, sqrtLowerX96), sqrtUpperX96, liquidity, true);
            uint256 up1 = sqrtPriceX96 <= sqrtLowerX96
                ? 0
                : SqrtPriceMath.getAmount1Delta(sqrtLowerX96, _min(sqrtPriceX96, sqrtUpperX96), liquidity, true);
            valueHigh += VaultMath.valueInToken1(up0, up1, sqrtPriceX96, true);
        }
        assertLe(VaultMath.debtValueLower(totals, sqrtPriceX96), valueHigh);
        assertGe(VaultMath.debtValueUpper(totals, sqrtPriceX96), valueLow);
    }

    /// @dev The lower bound is exact, up to rounding, when every range contains the price.
    function test_debtValueLower_exactInRange() public pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(-6000, 6000);
        uint128 liquidity = 1e24;
        DebtTotals memory totals = VaultMath.debtTerms(liquidity, sqrtLowerX96, sqrtUpperX96);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(1234);
        (uint256 hold0, uint256 hold1) = VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtPriceX96);
        uint256 value = VaultMath.valueInToken1(hold0, hold1, sqrtPriceX96, false);
        uint256 lower = VaultMath.debtValueLower(totals, sqrtPriceX96);
        assertLe(lower, value + 2);
        assertGe(lower + 4, value);
    }

    // ---- Rates and splits ----

    function test_rateWad_twoSlopes() public pure {
        Curve memory curve = Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0.04e18, slope2Wad: 3e18});
        assertEq(VaultMath.rateWad(curve, 0, 100), 0);
        assertEq(VaultMath.rateWad(curve, 40, 100), 0.02e18);
        assertEq(VaultMath.rateWad(curve, 80, 100), 0.04e18);
        assertEq(VaultMath.rateWad(curve, 90, 100), 0.04e18 + 1.5e18);
        assertEq(VaultMath.rateWad(curve, 100, 100), 0.04e18 + 3e18);
    }

    function testFuzz_splitShareSumsExactly(uint128 share, uint16 treasuryBps, uint16 feeVaultBps) public pure {
        treasuryBps = uint16(bound(treasuryBps, 0, 5000));
        feeVaultBps = uint16(bound(feeVaultBps, 0, 5000));
        (uint256 lenderPart, uint256 treasuryPart, uint256 feeVaultPart) =
            VaultMath.splitShare(share, treasuryBps, feeVaultBps);
        assertEq(lenderPart + treasuryPart + feeVaultPart, share);
    }

    // ---- Helpers ----

    function _range(int24 tickSeed, uint24 widthSeed, uint128 liquiditySeed)
        internal
        pure
        returns (uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint128 liquidity)
    {
        int24 tickLower = int24(bound(int256(tickSeed), -TICK_BOUND, TICK_BOUND - 1));
        int24 width = int24(int256(bound(uint256(widthSeed), 1, 200_000)));
        int24 tickUpper = tickLower + width > TICK_BOUND ? TICK_BOUND : tickLower + width;
        (sqrtLowerX96, sqrtUpperX96) = VaultMath.rangeSqrtPrices(tickLower, tickUpper);
        liquidity = uint128(bound(liquiditySeed, 1, MAX_LIQUIDITY));
    }

    function _scale(uint256 reserve0, uint256 reserve1, uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        view
        returns (uint256)
    {
        int24 tickLower = TickMath.getTickAtSqrtPrice(sqrtLowerX96);
        int24 tickUpper = TickMath.getTickAtSqrtPrice(sqrtUpperX96);
        return harness.scaleToRepay(reserve0, reserve1, liquidity, tickLower, tickUpper);
    }

    function _repaysPortion(
        uint256 reserve0,
        uint256 reserve1,
        uint256 fractionWad,
        uint128 liquidity,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) internal pure returns (bool) {
        uint256 part0 = VaultMath.portionUp(reserve0, fractionWad);
        uint256 part1 = VaultMath.portionUp(reserve1, fractionWad);
        return VaultMath.repays(part0, part1, liquidity, sqrtLowerX96, sqrtUpperX96);
    }

    function _add(DebtTotals memory totals, DebtTotals memory terms) internal pure {
        totals.liquidity += terms.liquidity;
        totals.virtual0 += terms.virtual0;
        totals.virtual1 += terms.virtual1;
        totals.maximum0 += terms.maximum0;
        totals.maximum1 += terms.maximum1;
    }

    function _max(uint160 left, uint160 right) internal pure returns (uint160) {
        return left > right ? left : right;
    }

    function _min(uint160 left, uint160 right) internal pure returns (uint160) {
        return left < right ? left : right;
    }

    /// @dev Sol's verification finding: a payout of 10 wei against a claim the buffer could fill only 1% of rounded the
    /// fraction paid to zero and burned no share. It burns one.
    function test_sharesPaidFor_partialPayoutBurns() public pure {
        assertEq(VaultMath.sharesPaidFor(10, 10, 10, 1e16), 1);
    }

    /// @dev Whatever the fill, the burn is at least the paid fraction of the shares and at most all of them.
    function testFuzz_sharesPaidFor_bounds(uint256 shares, uint256 entitlementWad, uint256 filledWad) public pure {
        shares = bound(shares, 1, 1e30);
        entitlementWad = bound(entitlementWad, 1, 2e18);
        filledWad = bound(filledWad, 1, 1e18);
        uint256 askedWad = entitlementWad < 1e18 ? entitlementWad : 1e18;
        uint256 burned = VaultMath.sharesPaidFor(shares, entitlementWad, askedWad, filledWad);
        assertLe(burned, shares, "never more than asked");
        assertGt(burned, 0, "a payout always burns");
        uint256 paidWad = askedWad * filledWad / 1e18;
        assertGe(burned * entitlementWad, shares * paidWad, "at least the paid fraction");
    }
}
