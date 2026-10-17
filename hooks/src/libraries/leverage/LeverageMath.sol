// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice The rate curve and bin width a pool chooses for its Leverage installation.
/// @dev Rates are yearly fractions in WAD on the quote-currency notional of borrowed liquidity.
struct Curve {
    /// @notice Bin width in tick spacings.
    uint24 binWidth;
    /// @notice Force-close reward, in basis points of the closed position's quote proceeds.
    uint16 forceCloseRewardBps;
    /// @notice The kink `U` of the two-slope curve, in WAD; strictly between 0 and 1.
    uint64 kinkWad;
    uint64 baseRateWad;
    uint64 slope1Wad;
    uint64 slope2Wad;
}

/// @notice Pure math of the Leverage extension: the solvency chord, bin geometry, the two-slope rate and the profit split.
/// @dev Extremes and compositions come from v4's SqrtPriceMath, the functions `Pool.modifyLiquidity` itself uses, so
/// what a removal releases and what an add charges are computed by the same code the pool runs.
library LeverageMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR_SECONDS = 365 days;
    /// @dev RAY / WAD. The rate index carries nine digits more than the WAD rate, so one-second checkpoints of a
    /// low rate still move it.
    uint256 internal constant WAD_TO_RAY = 1e9;

    error InvalidBin();

    /// @notice The exact chord test `r1 + K·r0 ≥ M1` with `K = M1 / M0`, cross-multiplied by `M0`.
    /// @dev No division and no rounding. Each product fits in 256 bits because every
    /// argument is at most uint128; the left-hand sum is carry-safe, so an overflowing sum means the chord holds.
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

    /// @notice The ticks of bin `binIndex`: `[b·W·s, (b+1)·W·s)` for bin width `W` and tick spacing `s`.
    function binTicks(int24 binIndex, uint24 binWidth, int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int256 widthTicks = int256(uint256(binWidth)) * tickSpacing;
        int256 lower = int256(binIndex) * widthTicks;
        int256 upper = lower + widthTicks;
        if (lower < TickMath.minUsableTick(tickSpacing)) revert InvalidBin();
        if (upper > TickMath.maxUsableTick(tickSpacing)) revert InvalidBin();
        return (int24(lower), int24(upper));
    }

    /// @notice The all-token0 cost `m0` and the all-token1 cost `m1` of `liquidity` on the given ticks, rounded down.
    /// @dev Rounded down because removal releases amounts rounded down, so a
    /// freshly borrowed corner stays solvent without dust collateral.
    function extremes(uint128 liquidity, int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (uint256 maximum0, uint256 maximum1)
    {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        maximum0 = SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false);
        maximum1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, liquidity, false);
    }

    /// @notice The yearly rate at utilization `borrowed / liquidity`, in WAD.
    /// @dev `BASE + SLOPE1·min(u, U)/U + SLOPE2·max(0, u − U)/(1 − U)`, Aave's two-slope curve.
    function rateWad(Curve memory curve, uint256 borrowed, uint256 liquidity) internal pure returns (uint256) {
        if (borrowed == 0) return curve.baseRateWad;
        uint256 utilizationWad = FullMath.mulDiv(borrowed, WAD, liquidity);
        if (utilizationWad <= curve.kinkWad) {
            return curve.baseRateWad + FullMath.mulDiv(curve.slope1Wad, utilizationWad, curve.kinkWad);
        }
        uint256 steepRate = FullMath.mulDiv(curve.slope2Wad, utilizationWad - curve.kinkWad, WAD - curve.kinkWad);
        return curve.baseRateWad + curve.slope1Wad + steepRate;
    }

    /// @notice How much the rate index grows over `elapsedSeconds` at a constant utilization, in RAY per unit notional.
    /// @dev Utilization changes only at checkpoints, so the rate is constant over the interval and the product is the
    /// exact integral. Rounded down: dust stays with the trader.
    function indexGrowthRay(Curve memory curve, uint256 borrowed, uint256 liquidity, uint256 elapsedSeconds)
        internal
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(rateWad(curve, borrowed, liquidity) * WAD_TO_RAY, elapsedSeconds, YEAR_SECONDS);
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
