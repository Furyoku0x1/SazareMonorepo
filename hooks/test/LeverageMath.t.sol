// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Curve, LeverageMath} from "../src/libraries/leverage/LeverageMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev External wrapper, so expectRevert sees the library's revert one call deep.
contract LeverageMathHarness {
    function binTicks(int24 binIndex, uint24 binWidth, int24 tickSpacing) external pure returns (int24, int24) {
        return LeverageMath.binTicks(binIndex, binWidth, tickSpacing);
    }
}

/// forge-config: default.fuzz.runs = 512
contract LeverageMathTest is Test {
    LeverageMathHarness internal harness = new LeverageMathHarness();

    function _curve() internal pure returns (Curve memory) {
        return Curve({
            binWidth: 10,
            forceCloseRewardBps: 100,
            kinkWad: 0.8e18,
            baseRateWad: 0.01e18,
            slope1Wad: 0.04e18,
            slope2Wad: 3e18
        });
    }

    // ---------------------------------------------------------------- chord

    /// @dev The cross-multiplied chord against a 512-bit reference: r1·M0 + M1·r0 ≥ M1·M0.
    function testFuzz_chordMatchesWideArithmetic(uint128 reserve0, uint128 reserve1, uint128 maximum0, uint128 maximum1)
        public
        pure
    {
        uint256 leftA = uint256(reserve1) * maximum0;
        uint256 leftB = uint256(maximum1) * reserve0;
        uint256 right = uint256(maximum1) * maximum0;
        bool carry = leftA > type(uint256).max - leftB;
        bool expected = carry || leftA + leftB >= right;
        assertEq(LeverageMath.chordHolds(reserve0, reserve1, maximum0, maximum1), expected);
    }

    function test_chordCornersAndJustBelow() public pure {
        uint256 maximum0 = 3e19;
        uint256 maximum1 = 2e19;
        assertTrue(LeverageMath.chordHolds(maximum0, 0, maximum0, maximum1), "all-token0 corner");
        assertTrue(LeverageMath.chordHolds(0, maximum1, maximum0, maximum1), "all-token1 corner");
        assertFalse(LeverageMath.chordHolds(maximum0 - 1, 0, maximum0, maximum1));
        assertFalse(LeverageMath.chordHolds(0, maximum1 - 1, maximum0, maximum1));
        // The chord's midpoint: half of each corner.
        assertTrue(LeverageMath.chordHolds(maximum0 / 2, maximum1 / 2, maximum0, maximum1));
    }

    /// @dev In integers: the cost to rebuild a range at any price lies under its chord, up to the
    /// rounding of v4's up-rounded add amounts against down-rounded extremes (two wei per token).
    function testFuzz_rebuildCostLiesUnderTheChord(uint128 liquidity, int24 binIndex, int24 tick) public pure {
        liquidity = uint128(bound(liquidity, 1e6, 1e30));
        binIndex = int24(bound(binIndex, -1000, 1000));
        (int24 tickLower, int24 tickUpper) = LeverageMath.binTicks(binIndex, 10, 60);
        tick = int24(bound(tick, tickLower - 2000, tickUpper + 2000));
        (uint256 maximum0, uint256 maximum1) = LeverageMath.extremes(liquidity, tickLower, tickUpper);
        (uint256 needed0, uint256 needed1) = _addCost(liquidity, tickLower, tickUpper, tick);
        // needed1·M0 + M1·needed0 ≤ M1·M0 + slack, with slack for two wei per token.
        uint256 left = needed1 * maximum0 + maximum1 * needed0;
        uint256 slack = 2 * (maximum0 + maximum1);
        assertLe(left, maximum1 * maximum0 + slack);
    }

    function testFuzz_extremesAreTheFarCompositions(uint128 liquidity, int24 binIndex) public pure {
        liquidity = uint128(bound(liquidity, 1, type(uint96).max));
        binIndex = int24(bound(binIndex, -1000, 1000));
        (int24 tickLower, int24 tickUpper) = LeverageMath.binTicks(binIndex, 10, 60);
        (uint256 maximum0, uint256 maximum1) = LeverageMath.extremes(liquidity, tickLower, tickUpper);
        (uint256 below0, uint256 below1) = _addCost(liquidity, tickLower, tickUpper, tickLower - 1);
        (uint256 above0, uint256 above1) = _addCost(liquidity, tickLower, tickUpper, tickUpper);
        assertEq(below1, 0);
        assertEq(above0, 0);
        // Rounded down against v4's rounded-up add: at most one wei apart.
        assertLe(maximum0, below0);
        assertLe(below0 - maximum0, 1);
        assertLe(maximum1, above1);
        assertLe(above1 - maximum1, 1);
    }

    // ---------------------------------------------------------------- bins

    function testFuzz_binsTileTheTickRange(int24 binIndex, uint24 binWidth, int24 tickSpacing) public view {
        tickSpacing = int24(bound(tickSpacing, 1, 200));
        binWidth = uint24(bound(binWidth, 1, 100));
        int256 widthTicks = int256(uint256(binWidth)) * tickSpacing;
        int256 lowestBin = (int256(TickMath.minUsableTick(tickSpacing)) + widthTicks - 1) / widthTicks;
        int256 highestBin = int256(TickMath.maxUsableTick(tickSpacing)) / widthTicks - 2;
        binIndex = int24(bound(binIndex, lowestBin, highestBin));
        (int24 tickLower, int24 tickUpper) = harness.binTicks(binIndex, binWidth, tickSpacing);
        (int24 nextLower,) = harness.binTicks(binIndex + 1, binWidth, tickSpacing);
        assertEq(nextLower, tickUpper, "bins are adjacent");
        assertEq(int256(tickUpper) - tickLower, widthTicks);
        assertEq(tickLower % tickSpacing, 0, "aligned to the tick spacing");
    }

    function test_binsOutsideTheTickRangeRevert() public {
        vm.expectRevert(LeverageMath.InvalidBin.selector);
        harness.binTicks(1478, 10, 60);
        vm.expectRevert(LeverageMath.InvalidBin.selector);
        harness.binTicks(-1479, 10, 60);
        harness.binTicks(1477, 10, 60);
        harness.binTicks(-1478, 10, 60);
    }

    // ---------------------------------------------------------------- rate

    function test_rateFollowsTheTwoSlopeCurve() public pure {
        Curve memory curve = _curve();
        assertEq(LeverageMath.rateWad(curve, 0, 100), 0.01e18, "base");
        assertEq(LeverageMath.rateWad(curve, 40, 100), 0.01e18 + 0.02e18, "half way to the kink");
        assertEq(LeverageMath.rateWad(curve, 80, 100), 0.05e18, "at the kink");
        assertEq(LeverageMath.rateWad(curve, 90, 100), 0.05e18 + 1.5e18, "half way past the kink");
        assertEq(LeverageMath.rateWad(curve, 100, 100), 3.05e18, "fully lent");
    }

    function testFuzz_rateRisesWithUtilization(uint128 liquidity, uint128 lower, uint128 higher) public pure {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        higher = uint128(bound(higher, 0, liquidity));
        lower = uint128(bound(lower, 0, higher));
        Curve memory curve = _curve();
        assertLe(LeverageMath.rateWad(curve, lower, liquidity), LeverageMath.rateWad(curve, higher, liquidity));
        assertLe(LeverageMath.rateWad(curve, higher, liquidity), 3.05e18);
    }

    /// @dev Splitting an interval at a checkpoint loses at most a unit of the floor to rounding, so the integral does
    /// not depend on when checkpoints happen.
    function testFuzz_indexGrowthIsAdditive(uint128 borrowed, uint128 liquidity, uint32 first, uint32 second)
        public
        pure
    {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        borrowed = uint128(bound(borrowed, 0, liquidity));
        Curve memory curve = _curve();
        uint256 whole = LeverageMath.indexGrowthRay(curve, borrowed, liquidity, uint256(first) + second);
        uint256 parts = LeverageMath.indexGrowthRay(curve, borrowed, liquidity, first)
            + LeverageMath.indexGrowthRay(curve, borrowed, liquidity, second);
        assertLe(parts, whole);
        assertLe(whole - parts, 1);
    }

    // ---------------------------------------------------------------- portions and split

    function testFuzz_portionsBracketTheExactProduct(uint128 amount, uint256 fractionWad) public pure {
        fractionWad = bound(fractionWad, 0, 1e18);
        uint256 down = LeverageMath.portionDown(amount, fractionWad);
        uint256 up = LeverageMath.portionUp(amount, fractionWad);
        assertLe(down, up);
        assertLe(up - down, 1);
        assertLe(up, amount);
        assertEq(LeverageMath.portionDown(amount, 1e18), amount);
        assertEq(LeverageMath.portionUp(amount, 1e18), amount);
        // The two parts of a split never exceed the whole: the closed part rounds up, the rest is what remains.
        assertLe(up + LeverageMath.portionDown(amount, 1e18 - fractionWad), amount);
    }

    function testFuzz_splitShareSumsExactly(uint128 share, uint16 treasuryShareBps, uint16 feeVaultShareBps)
        public
        pure
    {
        treasuryShareBps = uint16(bound(treasuryShareBps, 0, 10_000));
        feeVaultShareBps = uint16(bound(feeVaultShareBps, 0, 10_000 - treasuryShareBps));
        (uint256 lpPart, uint256 treasuryPart, uint256 feeVaultPart) =
            LeverageMath.splitShare(share, treasuryShareBps, feeVaultShareBps);
        assertEq(lpPart + treasuryPart + feeVaultPart, share);
        assertEq(treasuryPart, uint256(share) * treasuryShareBps / 10_000);
        assertEq(feeVaultPart, uint256(share) * feeVaultShareBps / 10_000);
    }

    function test_agreedSplitOfOnePercent() public pure {
        (uint256 lpPart, uint256 treasuryPart, uint256 feeVaultPart) = LeverageMath.splitShare(1001, 2500, 2500);
        assertEq(treasuryPart, 250);
        assertEq(feeVaultPart, 250);
        assertEq(lpPart, 501, "rounding goes to the LPs");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev What v4's Pool.modifyLiquidity charges to add `liquidity` on the range with the pool at `tick`.
    function _addCost(uint128 liquidity, int24 tickLower, int24 tickUpper, int24 tick)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (tick < tickLower) return (SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true), 0);
        if (tick >= tickUpper) return (0, SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
    }
}
