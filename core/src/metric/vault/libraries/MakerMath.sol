// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Bucket, FloorRow, Leg} from "../MakerTypes.sol";
import {IMakerBook} from "../interfaces/IMakerBook.sol";
import {VaultMath} from "./VaultMath.sol";

/// @notice The maker book's arithmetic: bucket ids, level geometry, units, floors, owed premium and a leg's settlement,
/// bucket value, and the aggregate chord with its per-leg rounding reserve.
library MakerMath {
    using SafeCast for uint256;

    /// @dev Bounds every loop over a position's legs.
    uint256 internal constant MAX_LEGS = 8;
    /// @dev Bounds every loop over curve or floor-table versions.
    uint256 internal constant MAX_VERSIONS = 64;
    /// @dev Bounds every loop over a floor table's rows.
    uint256 internal constant MAX_FLOOR_ROWS = 16;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant YEAR_SECONDS = 365 days;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q128 = 1 << 128;
    /// @dev Bucket id layout: bits 0–23 the level (two's complement), bit 24 the side, bits 32–63 the generation.
    uint256 internal constant SIDE_BIT = 1 << 24;
    uint256 internal constant GENERATION_SHIFT = 32;

    function bucketId(int24 level, bool isBuy, uint32 generation) internal pure returns (uint256) {
        uint256 side = isBuy ? SIDE_BIT : 0;
        return uint256(uint24(level)) | side | (uint256(generation) << GENERATION_SHIFT);
    }

    function decode(uint256 id) internal pure returns (int24 level, bool isBuy, uint32 generation) {
        level = int24(uint24(id));
        isBuy = id & SIDE_BIT != 0;
        generation = uint32(id >> GENERATION_SHIFT);
    }

    /// @notice Names a level and side, the pair whose current generation takes deposits.
    function levelKey(int24 level, bool isBuy) internal pure returns (uint256) {
        return bucketId(level, isBuy, 0);
    }

    /// @notice The sqrt prices bounding a level: ticks `[level · levelTicks, (level + 1) · levelTicks)`.
    function levelRange(int24 level, uint24 levelTicks)
        internal
        pure
        returns (uint160 sqrtLowerX96, uint160 sqrtUpperX96)
    {
        int256 lowerTick = int256(level) * int256(uint256(levelTicks));
        int256 upperTick = lowerTick + int256(uint256(levelTicks));
        if (lowerTick < -VaultMath.MAX_RANGE_TICK) revert IMakerBook.InvalidLevel();
        if (upperTick > VaultMath.MAX_RANGE_TICK) revert IMakerBook.InvalidLevel();
        return VaultMath.rangeSqrtPrices(int24(lowerTick), int24(upperTick));
    }

    /// @notice Requires the whole band on a bucket's waiting side: below a buy level's top is the bid, strictly above
    /// it; above a sell level's bottom is the ask, strictly below it.
    function requireWaitingSide(
        bool isBuy,
        uint160 sqrtBidX96,
        uint160 sqrtAskX96,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) internal pure {
        if (isBuy) {
            if (sqrtBidX96 <= sqrtUpperX96) revert IMakerBook.WrongSideOfPrice();
            return;
        }
        if (sqrtAskX96 >= sqrtLowerX96) revert IMakerBook.WrongSideOfPrice();
    }

    /// @notice The range liquidity a single-token amount buys on a level, rounded down: token1 for a buy level,
    /// `ℓ = amount1 / (√b − √a)`; token0 for a sell level, `ℓ = amount0 · √a · √b / (√b − √a)`.
    function liquidityFor(bool isBuy, uint256 amount, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (uint256)
    {
        uint256 width = sqrtUpperX96 - sqrtLowerX96;
        if (isBuy) return FullMath.mulDiv(amount, Q96, width);
        return FullMath.mulDiv(FullMath.mulDiv(amount, sqrtLowerX96, Q96), sqrtUpperX96, width);
    }

    /// @notice The distance between the band edge nearest a level and the level's geometric strike `√(P_a·P_b)`, in
    /// basis points of the edge price, rounded down so the floor it selects is never too low.
    /// @dev For a buy level below the price, `d = 1 − K / bid`; for a sell level above it, `d = K / ask − 1`.
    function strikeDistanceBps(bool isBuy, uint160 sqrtEdgeX96, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (uint256)
    {
        if (isBuy) {
            uint256 ratioUpWad = FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(sqrtLowerX96, WAD, sqrtEdgeX96), sqrtUpperX96, sqrtEdgeX96
            );
            if (ratioUpWad >= WAD) return 0;
            return (WAD - ratioUpWad) * BPS / WAD;
        }
        uint256 ratioDownWad =
            FullMath.mulDiv(FullMath.mulDiv(sqrtLowerX96, WAD, sqrtEdgeX96), sqrtUpperX96, sqrtEdgeX96);
        if (ratioDownWad <= WAD) return 0;
        return (ratioDownWad - WAD) * BPS / WAD;
    }

    /// @notice The floor rate of the first row whose minimum distance the leg reaches. Rows run from the farthest
    /// distance down to zero, so a row always matches.
    function floorRateBps(FloorRow[] storage rows, uint256 distanceBps) internal view returns (uint256) {
        uint256 count = rows.length;
        // count <= MAX_FLOOR_ROWS
        for (uint256 index = 0; index < count; ++index) {
            if (distanceBps >= rows[index].minimumDistanceBps) return rows[index].rateBps;
        }
        // Validation requires the last row's minimum to be zero, which every distance reaches.
        revert IMakerBook.InvalidLegs();
    }

    /// @notice What a leg owes since its last settlement, rounded up: the curve's integral plus the fixed floor on
    /// `M1`, plus the fraction the last settlement carried.
    function legOwed(Leg storage leg, uint256 rateIndexRay, uint256 nowSeconds) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(legOwedWad(leg, rateIndexRay, nowSeconds), 1, WAD);
    }

    /// @notice What a leg owes since its last settlement in WAD of a raw token1 unit, so that splitting an interval
    /// across settlements loses at most a WAD of a unit per settlement and never adds dues.
    function legOwedWad(Leg storage leg, uint256 rateIndexRay, uint256 nowSeconds) internal view returns (uint256) {
        uint256 maximum1 = leg.maximum1;
        uint256 settledAt = leg.settledAt;
        // Within the prepaid period the floor owes nothing yet; the curve accrues from the open.
        uint256 floorSeconds = nowSeconds > settledAt ? nowSeconds - settledAt : 0;
        uint256 curveWad = FullMath.mulDiv(maximum1, rateIndexRay - leg.rateIndexRay, RAY / WAD);
        uint256 floorWad = FullMath.mulDiv(maximum1 * leg.floorRateBps * WAD, floorSeconds, BPS * YEAR_SECONDS);
        return curveWad + floorWad + leg.owedFractionWad;
    }

    /// @notice Settles a leg to now and returns what it owes. Rounded up when `roundUp`, which a close uses once;
    /// otherwise rounded down with the remainder carried, so anyone settling often cannot charge more than one
    /// settlement would (Sol's finding).
    function settleLeg(Leg storage leg, uint256 rateIndexRay, uint256 nowSeconds, bool roundUp)
        internal
        returns (uint256 owedNow)
    {
        uint256 owedWad = legOwedWad(leg, rateIndexRay, nowSeconds);
        leg.rateIndexRay = rateIndexRay.toUint128();
        // A leg still in its prepaid period keeps its later start.
        if (leg.settledAt < nowSeconds) leg.settledAt = nowSeconds.toUint40();
        if (roundUp) {
            leg.owedFractionWad = 0;
            return FullMath.mulDivRoundingUp(owedWad, 1, WAD);
        }
        leg.owedFractionWad = uint64(owedWad % WAD);
        return owedWad / WAD;
    }

    /// @notice What `maximum1` of notional owes for a curve index growth and a floor held `elapsedSeconds`, each part
    /// rounded up. Opening uses it for the minimum escrow, so that check rounds exactly as settlement will.
    function owed(uint256 maximum1, uint256 growthRay, uint256 yearlyFloorBps, uint256 elapsedSeconds)
        internal
        pure
        returns (uint256)
    {
        uint256 curvePart = FullMath.mulDivRoundingUp(maximum1, growthRay, RAY);
        uint256 floorPart = FullMath.mulDivRoundingUp(maximum1 * yearlyFloorBps, elapsedSeconds, BPS * YEAR_SECONDS);
        return curvePart + floorPart;
    }

    /// @notice The least amount of a level's waiting token whose `liquidityFor` reaches `liquidity`: the exact inverse
    /// of its rounding down, step by step.
    function waitingFor(bool isBuy, uint256 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (uint256)
    {
        uint256 width = sqrtUpperX96 - sqrtLowerX96;
        if (isBuy) return FullMath.mulDivRoundingUp(liquidity, width, Q96);
        uint256 scaled = FullMath.mulDivRoundingUp(liquidity, width, sqrtUpperX96);
        return FullMath.mulDivRoundingUp(scaled, Q96, sqrtLowerX96);
    }

    /// @notice The largest fraction of an active bucket's balances a withdrawal may take, in WAD, so that its loans
    /// stay within the ceiling of `lent + liquidityFor(waiting left)`.
    /// @dev Works in integers rather than scaling capacity, because `liquidityFor` rounds down (Sol's finding): the
    /// least capacity the ceiling allows is `ceil(lent · (BPS − ceiling) / ceiling)`, `waitingFor` turns it into the
    /// least waiting balance that backs it, and the fraction rounds down so at least that balance stays.
    function ceilingFractionWad(
        bool isBuy,
        uint256 lent,
        uint256 waiting,
        uint256 ceilingBps,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) internal pure returns (uint256) {
        if (lent == 0) return WAD;
        uint256 capacityNeeded = FullMath.mulDivRoundingUp(lent, BPS - ceilingBps, ceilingBps);
        uint256 waitingKept = waitingFor(isBuy, capacityNeeded, sqrtLowerX96, sqrtUpperX96);
        if (waitingKept == 0) return WAD;
        if (waitingKept >= waiting) return 0;
        return FullMath.mulDiv(waiting - waitingKept, WAD, waiting);
    }

    /// @notice One part of a proportional split of `amount` by weights summing to `total`, given the weights before
    /// it: the difference of cumulative floors. The parts sum to exactly `amount`, and when `amount ≤ total` no part
    /// exceeds its weight (Sol's finding: giving the last part the remainder could).
    function cumulativePart(uint256 amount, uint256 weightBefore, uint256 weight, uint256 total)
        internal
        pure
        returns (uint256)
    {
        uint256 through = FullMath.mulDiv(amount, weightBefore + weight, total);
        return through - FullMath.mulDiv(amount, weightBefore, total);
    }

    /// @notice A bucket's value in token1 at a sqrt price: its balances plus the holdings of the liquidity it lent.
    /// Rounded up, holdings gain a unit of each token they hold, so the result bounds the true value from above.
    function bucketValue(
        Bucket storage bucket,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint160 sqrtPriceX96,
        bool roundUp
    ) internal view returns (uint256) {
        (uint256 lent0, uint256 lent1) = VaultMath.holdingsAt(bucket.lent, sqrtLowerX96, sqrtUpperX96, sqrtPriceX96);
        if (roundUp) {
            if (lent0 != 0) lent0 += 1;
            if (lent1 != 0) lent1 += 1;
        }
        uint256 amount0 = uint256(bucket.balance0) + lent0;
        uint256 amount1 = uint256(bucket.balance1) + lent1;
        return VaultMath.valueInToken1(amount0, amount1, sqrtPriceX96, roundUp);
    }

    /// @notice The aggregate chord, checked on the reserves less one raw unit of each token per leg. Splitting what
    /// remains in proportion to each leg's `M0` and `M1`, rounded up, then gives every leg reserves on its own chord.
    function aggregateChordHolds(
        uint256 reserve0,
        uint256 reserve1,
        uint256 maximum0,
        uint256 maximum1,
        uint256 legCount
    ) internal pure returns (bool) {
        uint256 kept0 = reserve0 > legCount ? reserve0 - legCount : 0;
        uint256 kept1 = reserve1 > legCount ? reserve1 - legCount : 0;
        return VaultMath.chordHolds(kept0, kept1, maximum0, maximum1);
    }

    /// @notice A leg's part of the reserves in the scaling fallback: `ceil(kept · part / whole)`, where `kept` excludes
    /// the per-leg rounding reserve. The ceilings sum to at most `kept + legCount`, which the reserves cover.
    function allocation(uint256 reserve, uint256 legCount, uint256 part, uint256 whole)
        internal
        pure
        returns (uint256)
    {
        if (whole == 0) return 0;
        uint256 kept = reserve > legCount ? reserve - legCount : 0;
        return FullMath.mulDivRoundingUp(kept, part, whole);
    }

    /// @notice A Metric price limit, whole-token Q64.64, from a raw sqrt price; the inverse of
    /// `MetricPrice.toSqrtX96`. Capped at Metric's uint128 limit.
    function toPriceX64(uint160 sqrtPriceX96, uint256 scale0, uint256 scale1, bool roundUp)
        internal
        pure
        returns (uint128)
    {
        uint256 rawX64 = roundUp
            ? FullMath.mulDivRoundingUp(sqrtPriceX96, sqrtPriceX96, Q128)
            : FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q128);
        uint256 priceX64 =
            roundUp ? FullMath.mulDivRoundingUp(rawX64, scale1, scale0) : FullMath.mulDiv(rawX64, scale1, scale0);
        if (priceX64 > type(uint128).max) return type(uint128).max;
        return priceX64.toUint128();
    }
}
