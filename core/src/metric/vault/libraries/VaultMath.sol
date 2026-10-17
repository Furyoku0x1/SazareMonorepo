// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice A two-slope rate curve, as in Aave: yearly fractions in WAD on the quote notional `M1` of a debt.
struct Curve {
    /// @notice The kink `U`, in WAD; strictly between 0 and 1.
    uint64 kinkWad;
    uint64 baseRateWad;
    uint64 slope1Wad;
    uint64 slope2Wad;
}

/// @notice Sums over a set of open debts, enough to bound their combined value at any price without a loop.
/// @dev Amounts are in raw token units. `virtual0` is Σ L/√b (token0) and `virtual1` is Σ L·√a (token1), the offsets
/// of each range's Uniswap v3 virtual reserves.
struct DebtTotals {
    uint256 liquidity;
    uint256 virtual0;
    uint256 virtual1;
    uint256 maximum0;
    uint256 maximum1;
}

/// @notice Pure math of the Metric Lending Vault: the solvency chord, the repayment rule, the force-close scale, the
/// two-slope rate, and bounds on the value of open debts.
/// @dev `chordHolds`, `rateWad`, `indexGrowthRay`, `portionDown`, `portionUp` and `splitShare` are copied from
/// `hooks/src/libraries/LeverageMath.sol` at commit a8bc03f, which the Leverage audit reviewed and fuzzed. A debt is
/// Uniswap v3 liquidity `L` on `[a, b]`; prices are raw token1 per raw token0, as v4 sqrt prices in Q96.
library VaultMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR_SECONDS = 365 days;
    /// @dev RAY / WAD. The rate index carries nine digits more than the WAD rate, so one-second checkpoints of a
    /// low rate still move it.
    uint256 internal constant WAD_TO_RAY = 1e9;
    /// @dev Bisection steps for the force-close scale. Each halves [0, WAD], and WAD < 2^60, so 64 steps reach one
    /// unit.
    uint256 internal constant SCALE_STEPS = 64;
    uint256 internal constant Q64 = 1 << 64;
    /// @dev 2^160 = Q96 · Q64: the factor that turns `L / √b` into token0 with 64 fractional bits.
    uint256 internal constant Q160 = 1 << 160;
    /// @dev Ranges lie within raw prices [2^-64, 2^64], the ticks ±443636. There every sqrt price is between 2^64 and
    /// 2^128 in Q96, so a virtual reserve with 64 fractional bits stays below 2^225 and keeps at least 2^32 units of
    /// precision for liquidity of at least one.
    int24 internal constant MAX_RANGE_TICK = 443_636;

    error InvalidRange();
    /// @dev The reserves cannot repay the debt even in full; the chord check at open rules this out.
    error ReservesShort();

    /// @notice The exact chord test `r1 + K·r0 ≥ M1` with `K = M1 / M0`, cross-multiplied by `M0`.
    /// @dev No division and no rounding. Each product fits in 256 bits because every argument is at most uint128; the
    /// left-hand sum is carry-safe, so an overflowing sum means the chord holds.
    function chordHolds(uint256 reserve0, uint256 reserve1, uint256 maximum0, uint256 maximum1)
        internal
        pure
        returns (bool)
    {
        uint256 leftA = reserve1 * maximum0;
        uint256 leftB = maximum1 * reserve0;
        uint256 right = maximum1 * maximum0;
        unchecked {
            uint256 left = leftA + leftB;
            if (left < leftA) return true;
            return left >= right;
        }
    }

    /// @notice The sqrt prices of a range given by ticks; any tick spacing of 1 is allowed.
    function rangeSqrtPrices(int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (uint160 sqrtLowerX96, uint160 sqrtUpperX96)
    {
        if (tickLower >= tickUpper) revert InvalidRange();
        if (tickLower < -MAX_RANGE_TICK) revert InvalidRange();
        if (tickUpper > MAX_RANGE_TICK) revert InvalidRange();
        sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
    }

    /// @notice The debt's all-token0 amount `M0` and all-token1 amount `M1`, rounded up, plus one unit each.
    /// @dev `repays` rounds against the borrower, so an exact corner can fall short of it by a fraction of a unit; the
    /// extra unit makes every reserve passing the chord on these extremes pass `repays` (fuzzed).
    function debtExtremes(uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (uint256 maximum0, uint256 maximum1)
    {
        maximum0 = SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, liquidity, true) + 1;
        maximum1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, liquidity, true) + 1;
    }

    /// @notice What the range holds at a price, rounded down: `x = L(1/√P − 1/√b)`, `y = L(√P − √a)`, clamped.
    function holdingsAt(uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtPriceX96 <= sqrtLowerX96) {
            return (SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false), 0);
        }
        if (sqrtPriceX96 >= sqrtUpperX96) {
            return (0, SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false));
        }
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpperX96, liquidity, false);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtPriceX96, liquidity, false);
    }

    /// @notice The tokens released at open: the range's cheapest holdings across the price band, `(x(ask), y(bid))`.
    /// @dev `x` falls and `y` rises with price, so this is at most the holdings at any price inside the band. Lenders
    /// lose nothing at open while the true price is inside it.
    function releaseAcrossBand(
        uint128 liquidity,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        uint160 sqrtBidX96,
        uint160 sqrtAskX96
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        (amount0,) = holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtAskX96);
        (, amount1) = holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96);
    }

    /// @notice The repayment rule: `(x + L/√b)·(y + L·√a) ≥ L²`, the range's v3 virtual-reserve curve.
    /// @dev Exactly the amounts that rebuild `L` on `[a, b]` at some price. Virtual reserves carry 64 fractional bits
    /// and round down, against the borrower: rounding an offset of a fraction of a unit to a whole unit would scale the
    /// other axis's requirement by that error. `amount0` and `amount1` must be at most uint128.
    function repays(uint256 amount0, uint256 amount1, uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (bool)
    {
        if (liquidity == 0) return true;
        uint256 virtual0X64 = amount0 * Q64 + FullMath.mulDiv(liquidity, Q160, sqrtUpperX96);
        uint256 virtual1X64 = amount1 * Q64 + FullMath.mulDiv(liquidity, sqrtLowerX96, 1 << 32);
        uint256 thresholdX64 = uint256(liquidity) * Q64;
        // If both reach L·2^64 the product reaches (L·2^64)². Otherwise the quotient below is smaller than the larger
        // virtual reserve, so it fits in 256 bits; floor(X·Y / T) ≥ T exactly when X·Y ≥ T².
        if (virtual0X64 >= thresholdX64) {
            if (virtual1X64 >= thresholdX64) return true;
        }
        return FullMath.mulDiv(virtual0X64, virtual1X64, thresholdX64) >= thresholdX64;
    }

    /// @notice The smallest fraction of the reserves, in WAD and rounded up, that still repays the debt: the
    /// force-close fallback, which needs no price and no swap.
    /// @dev `repays` is monotonic in the fraction, so bisection finds the boundary. The returned fraction, applied with
    /// `portionUp`, repays.
    function scaleToRepay(
        uint256 reserve0,
        uint256 reserve1,
        uint128 liquidity,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) internal pure returns (uint256 fractionWad) {
        if (!repays(reserve0, reserve1, liquidity, sqrtLowerX96, sqrtUpperX96)) {
            revert ReservesShort();
        }
        uint256 low = 0;
        uint256 high = WAD;
        // SCALE_STEPS halvings of [0, WAD]
        for (uint256 step = 0; step < SCALE_STEPS; ++step) {
            if (high - low <= 1) break;
            uint256 middle = (low + high) / 2;
            uint256 part0 = portionUp(reserve0, middle);
            uint256 part1 = portionUp(reserve1, middle);
            if (repays(part0, part1, liquidity, sqrtLowerX96, sqrtUpperX96)) high = middle;
            else low = middle;
        }
        return high;
    }

    /// @notice The value of `amount0` and `amount1` in token1 at a sqrt price.
    function valueInToken1(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        return amount1 + priceTimes(amount0, sqrtPriceX96, roundUp);
    }

    /// @notice `amount0 · P` in token1, where `P = (sqrtPriceX96 / 2^96)²`.
    function priceTimes(uint256 amount0, uint160 sqrtPriceX96, bool roundUp) internal pure returns (uint256) {
        if (roundUp) {
            uint256 halfUp = FullMath.mulDivRoundingUp(amount0, sqrtPriceX96, FixedPoint96.Q96);
            return FullMath.mulDivRoundingUp(halfUp, sqrtPriceX96, FixedPoint96.Q96);
        }
        uint256 halfDown = FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96);
        return FullMath.mulDiv(halfDown, sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @notice Adds or removes one debt from a set of totals. Terms round up, which keeps `debtValueLower` a lower
    /// bound and `debtValueUpper` an upper bound.
    function debtTerms(uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (DebtTotals memory terms)
    {
        terms.liquidity = liquidity;
        terms.virtual0 = FullMath.mulDivRoundingUp(liquidity, FixedPoint96.Q96, sqrtUpperX96);
        terms.virtual1 = FullMath.mulDivRoundingUp(liquidity, sqrtLowerX96, FixedPoint96.Q96);
        (terms.maximum0, terms.maximum1) = debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
    }

    /// @notice A lower bound, in token1, on the combined value of the debts at a price.
    /// @dev Applies the in-range value `2·L·√P − L·√a − P·L/√b` to every debt. It is exact for a range containing
    /// the price and below the true value otherwise, by `(L/√b)(√P − √b)²` above the range and `(L/√a)(√a − √P)²`
    /// below it. Floored at zero.
    function debtValueLower(DebtTotals memory totals, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 gross = 2 * FullMath.mulDiv(totals.liquidity, sqrtPriceX96, FixedPoint96.Q96);
        uint256 cost = totals.virtual1 + priceTimes(totals.virtual0, sqrtPriceX96, true);
        if (gross <= cost) return 0;
        return gross - cost;
    }

    /// @notice An upper bound, in token1, on the combined value of the debts at a price: `min(ΣM1, P·ΣM0)`.
    /// @dev Each debt is worth at most `min(M1, P·M0)`, and a sum of minimums is at most the minimum of the sums.
    function debtValueUpper(DebtTotals memory totals, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 allToken0Value = priceTimes(totals.maximum0, sqrtPriceX96, true);
        if (allToken0Value < totals.maximum1) return allToken0Value;
        return totals.maximum1;
    }

    /// @notice The yearly rate at utilization `borrowed / supplied`, in WAD.
    /// @dev `BASE + SLOPE1·min(u, U)/U + SLOPE2·max(0, u − U)/(1 − U)`, Aave's two-slope curve.
    function rateWad(Curve memory curve, uint256 borrowed, uint256 supplied) internal pure returns (uint256) {
        if (borrowed == 0) return curve.baseRateWad;
        uint256 utilizationWad = FullMath.mulDiv(borrowed, WAD, supplied);
        if (utilizationWad <= curve.kinkWad) {
            return curve.baseRateWad + FullMath.mulDiv(curve.slope1Wad, utilizationWad, curve.kinkWad);
        }
        uint256 steepRate = FullMath.mulDiv(curve.slope2Wad, utilizationWad - curve.kinkWad, WAD - curve.kinkWad);
        return curve.baseRateWad + curve.slope1Wad + steepRate;
    }

    /// @notice How much the rate index grows over `elapsedSeconds` at a constant utilization, in RAY per unit notional.
    /// @dev Utilization is constant between checkpoints, so the product is the exact integral. Rounded down: dust stays
    /// with the trader.
    function indexGrowthRay(Curve memory curve, uint256 borrowed, uint256 supplied, uint256 elapsedSeconds)
        internal
        pure
        returns (uint256)
    {
        return growthAtRateRay(rateWad(curve, borrowed, supplied), elapsedSeconds);
    }

    /// @notice How much an index grows over `elapsedSeconds` at a yearly rate in WAD, in RAY, rounded down.
    function growthAtRateRay(uint256 yearlyRateWad, uint256 elapsedSeconds) internal pure returns (uint256) {
        return FullMath.mulDiv(yearlyRateWad * WAD_TO_RAY, elapsedSeconds, YEAR_SECONDS);
    }

    /// @notice The shares a withdrawal burns: `shares` are entitled to `entitlementWad` of the idle basket, it asked
    /// for `askedWad` of it and was paid `filledWad` of that. The fraction paid rounds up, so a partial payout of a few
    /// units still burns a share (Sol's verification finding), and the burn rounds up.
    function sharesPaidFor(uint256 shares, uint256 entitlementWad, uint256 askedWad, uint256 filledWad)
        internal
        pure
        returns (uint256)
    {
        uint256 paidWad = portionUp(askedWad, filledWad);
        if (paidWad >= entitlementWad) return shares;
        return FullMath.mulDivRoundingUp(shares, paidWad, entitlementWad);
    }

    /// @notice `amount · fractionWad / WAD`, rounded down.
    function portionDown(uint256 amount, uint256 fractionWad) internal pure returns (uint256) {
        if (fractionWad == WAD) return amount;
        return FullMath.mulDiv(amount, fractionWad, WAD);
    }

    /// @notice `amount · fractionWad / WAD`, rounded up.
    function portionUp(uint256 amount, uint256 fractionWad) internal pure returns (uint256) {
        if (fractionWad == WAD) return amount;
        return FullMath.mulDivRoundingUp(amount, fractionWad, WAD);
    }

    /// @notice Splits a profit share between the lenders, the treasury and the fee vault.
    /// @dev The treasury and fee-vault parts round down and the lenders take the rest, so the three parts always sum
    /// to the share exactly.
    function splitShare(uint256 share, uint256 treasuryShareBps, uint256 feeVaultShareBps)
        internal
        pure
        returns (uint256 lenderPart, uint256 treasuryPart, uint256 feeVaultPart)
    {
        treasuryPart = share * treasuryShareBps / BPS;
        feeVaultPart = share * feeVaultShareBps / BPS;
        lenderPart = share - treasuryPart - feeVaultPart;
    }
}
