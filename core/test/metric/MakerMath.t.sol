// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Leg} from "../../src/metric/vault/MakerTypes.sol";
import {MakerMath} from "../../src/metric/vault/libraries/MakerMath.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";

/// @notice Properties of the maker book's arithmetic, above all the integer allocator behind the multi-leg force close.
contract MakerMathTest is Test {
    uint256 internal constant WAD = 1e18;

    uint256 internal constant START = 1_000_000;

    Leg internal splitLeg;
    Leg internal wholeLeg;

    /// @dev One fuzzed leg: its range and liquidity, and the extremes they imply.
    struct FuzzLeg {
        uint160 sqrtLowerX96;
        uint160 sqrtUpperX96;
        uint128 liquidity;
        uint256 maximum0;
        uint256 maximum1;
    }

    /// @dev Sol's finding: flooring a proportional split can fail to repay. With one raw unit of each token kept back
    /// per leg, the rounded-up split puts every leg on its own chord, so every leg repays, and the parts never exceed
    /// the reserves.
    function testFuzz_allocationRepaysEveryLeg(uint256 seed, uint8 countSeed, uint256 reserve0Seed, uint256 extraSeed)
        public
        pure
    {
        uint256 legCount = bound(countSeed, 1, MakerMath.MAX_LEGS);
        FuzzLeg[] memory legs = new FuzzLeg[](legCount);
        uint256 total0;
        uint256 total1;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            legs[index] = _leg(uint256(keccak256(abi.encode(seed, index))));
            total0 += legs[index].maximum0;
            total1 += legs[index].maximum1;
        }
        uint256 reserve0 = bound(reserve0Seed, 0, total0 + legCount);
        uint256 reserve1 = _leastReserve1(reserve0, total0, total1, legCount) + bound(extraSeed, 0, 1e6);
        assertTrue(
            MakerMath.aggregateChordHolds(reserve0, reserve1, total0, total1, legCount), "on the aggregate chord"
        );
        uint256 given0;
        uint256 given1;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            FuzzLeg memory leg = legs[index];
            uint256 part0 = MakerMath.allocation(reserve0, legCount, leg.maximum0, total0);
            uint256 part1 = MakerMath.allocation(reserve1, legCount, leg.maximum1, total1);
            assertTrue(VaultMath.chordHolds(part0, part1, leg.maximum0, leg.maximum1), "on its own chord");
            assertTrue(
                VaultMath.repays(part0, part1, leg.liquidity, leg.sqrtLowerX96, leg.sqrtUpperX96), "repays its leg"
            );
            given0 += part0;
            given1 += part1;
        }
        assertLe(given0, reserve0, "token0 parts within the reserves");
        assertLe(given1, reserve1, "token1 parts within the reserves");
    }

    function testFuzz_bucketIdRoundTrips(int24 level, bool isBuy, uint32 generation) public pure {
        (int24 decodedLevel, bool decodedSide, uint32 decodedGeneration) =
            MakerMath.decode(MakerMath.bucketId(level, isBuy, generation));
        assertEq(decodedLevel, level);
        assertEq(decodedSide, isBuy);
        assertEq(decodedGeneration, generation);
    }

    /// @dev The units a deposit buys never claim more of the waiting token than was deposited.
    function testFuzz_liquidityForRoundsDown(int24 levelSeed, bool isBuy, uint128 amount) public pure {
        int24 level = int24(bound(levelSeed, -4_000, 4_000));
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, 100);
        uint256 liquidity = MakerMath.liquidityFor(isBuy, amount, sqrtLowerX96, sqrtUpperX96);
        vm.assume(liquidity <= type(uint128).max);
        uint256 backed = isBuy
            ? SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, uint128(liquidity), true)
            : SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, uint128(liquidity), true);
        assertLe(backed, amount, "units backed by the deposit");
    }

    /// @dev The distance is rounded down, so the floor it selects is never too low, and it is within a basis point of
    /// the exact `1 − K/bid` (buy) or `K/ask − 1` (sell).
    function testFuzz_strikeDistanceRoundsDown(int24 levelSeed, uint24 gapSeed, bool isBuy) public pure {
        int24 level = int24(bound(levelSeed, -3_000, 3_000));
        uint256 gapTicks = bound(gapSeed, 1, 60_000);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, 100);
        int256 edgeTick = isBuy ? int256(level) * 100 + 100 + int256(gapTicks) : int256(level) * 100 - int256(gapTicks);
        uint160 sqrtEdgeX96 = TickMath.getSqrtPriceAtTick(int24(edgeTick));
        uint256 distanceBps = MakerMath.strikeDistanceBps(isBuy, sqrtEdgeX96, sqrtLowerX96, sqrtUpperX96);
        uint256 ratioWad = FullMath.mulDiv(FullMath.mulDiv(sqrtLowerX96, sqrtUpperX96, sqrtEdgeX96), WAD, sqrtEdgeX96);
        uint256 exactBps = isBuy ? (WAD - ratioWad) * 10_000 / WAD : (ratioWad - WAD) * 10_000 / WAD;
        assertLe(distanceBps, exactBps + 1, "never above the exact distance");
        assertGe(distanceBps + 1, exactBps, "within a basis point");
    }

    /// @dev `waitingFor` is the least amount whose `liquidityFor` reaches the target: the exact inverse of its rounding.
    function testFuzz_waitingForInvertsLiquidityFor(int24 levelSeed, bool isBuy, uint128 liquiditySeed) public pure {
        int24 level = int24(bound(levelSeed, -4_000, 4_000));
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, 100);
        uint256 liquidity = bound(liquiditySeed, 1, type(uint96).max);
        uint256 amount = MakerMath.waitingFor(isBuy, liquidity, sqrtLowerX96, sqrtUpperX96);
        assertGe(MakerMath.liquidityFor(isBuy, amount, sqrtLowerX96, sqrtUpperX96), liquidity, "enough");
        assertLt(MakerMath.liquidityFor(isBuy, amount - 1, sqrtLowerX96, sqrtUpperX96), liquidity, "the least");
    }

    /// @dev Whatever a withdrawal takes at the fraction allowed, the loans stay within the ceiling of what is left.
    function testFuzz_ceilingFractionKeepsTheCeiling(
        int24 levelSeed,
        bool isBuy,
        uint128 lentSeed,
        uint128 waitingSeed,
        uint16 ceilingSeed
    ) public pure {
        int24 level = int24(bound(levelSeed, -4_400, 4_400));
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, 100);
        uint256 lent = bound(lentSeed, 1, type(uint96).max);
        uint256 waiting = bound(waitingSeed, 1, type(uint96).max);
        uint256 ceilingBps = bound(ceilingSeed, 1, 10_000);
        uint256 fractionWad = MakerMath.ceilingFractionWad(isBuy, lent, waiting, ceilingBps, sqrtLowerX96, sqrtUpperX96);
        vm.assume(fractionWad != 0);
        uint256 left = waiting - VaultMath.portionDown(waiting, fractionWad);
        uint256 capacity = MakerMath.liquidityFor(isBuy, left, sqrtLowerX96, sqrtUpperX96);
        assertLe(lent * 10_000, (lent + capacity) * ceilingBps, "within the ceiling");
    }

    /// @dev Sol's counterexample to the scaled-capacity algebra: a high-price buy level where 12 units of capacity
    /// shrank to 0 on a withdrawal the old fraction allowed, taking a 90% ceiling to 100%.
    function test_ceilingFraction_solsCounterexample() public pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(4_400, 100);
        uint256 waiting = 215_385_560;
        assertEq(MakerMath.liquidityFor(true, waiting, sqrtLowerX96, sqrtUpperX96), 12, "capacity before");
        assertEq(MakerMath.liquidityFor(true, 11_965_865, sqrtLowerX96, sqrtUpperX96), 0, "what the old fraction left");
        uint256 fractionWad = MakerMath.ceilingFractionWad(true, 6, waiting, 9_000, sqrtLowerX96, sqrtUpperX96);
        uint256 left = waiting - VaultMath.portionDown(waiting, fractionWad);
        uint256 capacity = MakerMath.liquidityFor(true, left, sqrtLowerX96, sqrtUpperX96);
        assertGe(capacity, 1, "a unit of capacity stays");
        assertLe(6 * 10_000, (6 + capacity) * 9_000, "within the ceiling");
    }

    /// @dev The cumulative split hands out exactly the amount, and while the amount is within the total no part exceeds
    /// its weight.
    function testFuzz_cumulativePartSplitsExactly(uint256 amountSeed, uint64[8] memory weightSeeds, uint8 countSeed)
        public
        pure
    {
        uint256 count = bound(countSeed, 1, 8);
        uint256 total;
        // count <= 8
        for (uint256 index = 0; index < count; ++index) {
            total += weightSeeds[index];
        }
        vm.assume(total != 0);
        uint256 amount = bound(amountSeed, 0, total);
        uint256 given;
        uint256 weightBefore;
        // count <= 8
        for (uint256 index = 0; index < count; ++index) {
            uint256 part = MakerMath.cumulativePart(amount, weightBefore, weightSeeds[index], total);
            assertLe(part, weightSeeds[index], "no part above its weight");
            weightBefore += weightSeeds[index];
            given += part;
        }
        assertEq(given, amount, "exactly the amount");
    }

    /// @dev Sol's counterexample to a remainder-to-last split: three legs owe 2 each and 5 is paid. The remainder rule
    /// paid [1, 1, 3] and left 2 unpaid; cumulative floors pay [1, 2, 2] and leave exactly 1.
    function test_cumulativePart_solsCounterexample() public pure {
        assertEq(MakerMath.cumulativePart(5, 0, 2, 6), 1);
        assertEq(MakerMath.cumulativePart(5, 2, 2, 6), 2);
        assertEq(MakerMath.cumulativePart(5, 4, 2, 6), 2);
    }

    /// @dev Sol's finding: however an interval is split into settlements that round down and carry, then closed with
    /// one that rounds up, the total never exceeds one settlement over the whole interval, and falls short by at most
    /// a unit.
    function testFuzz_settlingOftenNeverChargesMore(
        uint128 maximum1Seed,
        uint32 floorSeed,
        uint64 rateSeed,
        uint32[8] memory gapSeeds,
        uint8 countSeed
    ) public {
        uint256 maximum1 = bound(maximum1Seed, 1, 1e24);
        uint256 floorRateBps = bound(floorSeed, 0, 100_000);
        uint256 growthPerSecondRay = bound(rateSeed, 0, 1e20);
        _startLeg(splitLeg, maximum1, floorRateBps);
        _startLeg(wholeLeg, maximum1, floorRateBps);
        uint256 count = bound(countSeed, 1, 8);
        uint256 nowSeconds = START;
        uint256 charged;
        // count <= 8
        for (uint256 index = 0; index < count; ++index) {
            nowSeconds += bound(gapSeeds[index], 0, 30 days);
            charged += MakerMath.settleLeg(splitLeg, growthPerSecondRay * (nowSeconds - START), nowSeconds, false);
        }
        uint256 indexRay = growthPerSecondRay * (nowSeconds - START);
        charged += MakerMath.settleLeg(splitLeg, indexRay, nowSeconds, true);
        uint256 once = MakerMath.settleLeg(wholeLeg, indexRay, nowSeconds, true);
        assertLe(charged, once, "never more than one settlement");
        assertGe(charged + 1, once, "at most a unit less");
    }

    function test_strikeDistance_matchesLeverage() public pure {
        // A buy level whose strike sits about 10% below the bid is about 10x.
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(-2_014, 100);
        uint160 sqrtBidX96 = TickMath.getSqrtPriceAtTick(-200_312);
        uint256 distanceBps = MakerMath.strikeDistanceBps(true, sqrtBidX96, sqrtLowerX96, sqrtUpperX96);
        assertApproxEqAbs(distanceBps, 985, 5, "about 9.85% below the bid");
    }

    // ---------------------------------------------------------------- helpers

    function _startLeg(Leg storage leg, uint256 maximum1, uint256 floorRateBps) internal {
        leg.maximum1 = uint128(maximum1);
        leg.floorRateBps = uint32(floorRateBps);
        leg.rateIndexRay = 0;
        leg.settledAt = uint40(START);
        leg.owedFractionWad = 0;
    }

    function _leg(uint256 seed) internal pure returns (FuzzLeg memory leg) {
        int256 tickLower = int256(bound(seed % 1_000_003, 0, 600_000)) - 300_000;
        uint256 width = bound((seed >> 32) % 100_003, 1, 20_000);
        int256 tickUpper = tickLower + int256(width);
        (leg.sqrtLowerX96, leg.sqrtUpperX96) = VaultMath.rangeSqrtPrices(int24(tickLower), int24(tickUpper));
        leg.liquidity = uint128(bound(seed >> 64, 1, 1e24));
        (leg.maximum0, leg.maximum1) = VaultMath.debtExtremes(leg.liquidity, leg.sqrtLowerX96, leg.sqrtUpperX96);
        vm.assume(leg.maximum0 < type(uint96).max);
        vm.assume(leg.maximum1 < type(uint96).max);
    }

    /// @dev The least token1 that, with `reserve0`, passes the aggregate chord with its per-leg reserve:
    /// `(r1 − n)·ΣM0 ≥ ΣM1·(ΣM0 − (r0 − n))`.
    function _leastReserve1(uint256 reserve0, uint256 total0, uint256 total1, uint256 legCount)
        internal
        pure
        returns (uint256)
    {
        uint256 kept0 = reserve0 > legCount ? reserve0 - legCount : 0;
        if (kept0 >= total0) return legCount;
        return FullMath.mulDivRoundingUp(total1, total0 - kept0, total0) + legCount;
    }
}
