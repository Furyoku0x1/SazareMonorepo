// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "oz/contracts/utils/math/Math.sol";

/// @notice Closed-form sizing of a cycle of constant-liquidity pools.
/// @dev Inside its current tick range, a v4 pool is a constant-product pool on the virtual reserves
/// x = L * 2^96 / sqrtP and y = L * sqrtP / 2^96. A path of such pools folds into one equivalent pool (reserveIn,
/// reserveOut), so the best input of a cycle has a closed form. The fold is exact in real arithmetic; integer
/// rounding makes it an estimate, and the exact per-leg quote stays the authority before execution.
/// With sqrtP in [2^32, 2^160) and L < 2^128, each scaled virtual reserve is below 2^224, so every product below goes
/// through FullMath and the folded reserves never exceed the first input reserve or the last output reserve.
/// The caller keeps each pool's two reserves and folds them leg by leg, so no per-cycle array is built.
library CycleMath {
    uint256 internal constant Q96 = 1 << 96;
    /// @dev v4 swap fees are in hundredths of a basis point.
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    /// @dev Reserves are computed already scaled by 2^32, so a reserve below one unit does not truncate to zero. The
    /// best input and the output are homogeneous of degree 1 in (reserves, input), so the result scales back exactly.
    uint256 internal constant PRECISION_SHIFT = 32;
    uint256 internal constant Q96_SCALED = Q96 << PRECISION_SHIFT;
    uint256 internal constant Q96_UNSCALED = Q96 >> PRECISION_SHIFT;

    /// @notice Virtual reserves of a pool, scaled by 2^PRECISION_SHIFT.
    function reserves(uint160 sqrtPriceX96, uint128 liquidity)
        internal
        pure
        returns (uint256 reserve0, uint256 reserve1)
    {
        reserve0 = FullMath.mulDiv(liquidity, Q96_SCALED, sqrtPriceX96);
        reserve1 = FullMath.mulDiv(liquidity, sqrtPriceX96, Q96_UNSCALED);
    }

    /// @notice Folds one more hop into the equivalent pool (reserveIn, reserveOut). The first hop's fee is left out of
    /// the fold; optimize applies it.
    /// @dev Returns zeros when the hop cannot be folded. Rounding the input reserve up never overstates the cycle's
    /// rate, and a large mispricing keeps a non-zero input reserve instead of folding to zero.
    function fold(uint256 reserveIn, uint256 reserveOut, uint256 hopIn, uint256 hopOut, uint24 hopFee)
        internal
        pure
        returns (uint256, uint256)
    {
        // reserveOut < 2^224 and the fee factor < 2^20, so the product fits without FullMath.
        uint256 netOut = reserveOut * (FEE_DENOMINATOR - hopFee) / FEE_DENOMINATOR;
        uint256 denominator = hopIn + netOut;
        if (denominator == 0) return (0, 0);
        return (FullMath.mulDivRoundingUp(reserveIn, hopIn, denominator), FullMath.mulDiv(netOut, hopOut, denominator));
    }

    /// @notice Returns the profit-maximizing input of the folded cycle, capped at maximumInput, and its profit.
    /// @dev Profit is zero when the product of fee-adjusted spot rates is at most 1: no input size can profit.
    function optimize(uint256 reserveIn, uint256 reserveOut, uint24 fee, uint256 maximumInput)
        internal
        pure
        returns (uint256 input, uint256 profit)
    {
        if (reserveIn == 0) return (0, 0);
        uint256 gamma = FEE_DENOMINATOR - fee;
        uint256 netOut = FullMath.mulDiv(reserveOut, gamma, FEE_DENOMINATOR);
        if (netOut <= reserveIn) return (0, 0);
        // x* = (sqrt(gamma * reserveIn * reserveOut) - reserveIn) / gamma. The product can exceed 2^256, so the root
        // is taken per factor; each factor's root truncates by less than one unit, a relative error below
        // 1 / sqrt(reserve), and the exact per-leg quote decides the final amounts.
        uint256 root = Math.sqrt(reserveIn) * Math.sqrt(netOut);
        if (root <= reserveIn) return (0, 0);
        input = FullMath.mulDiv(root - reserveIn, FEE_DENOMINATOR, gamma) >> PRECISION_SHIFT;
        if (input > maximumInput) input = maximumInput;
        uint256 received = output(reserveIn, reserveOut, fee, input);
        if (received > input) profit = received - input;
    }

    /// @notice Constant-product output for an exact input in whole units, on scaled reserves, with the fee taken from
    /// the input. Rounds down to whole units, as the pool does.
    function output(uint256 reserveIn, uint256 reserveOut, uint24 fee, uint256 input) internal pure returns (uint256) {
        uint256 netInput = FullMath.mulDiv(input << PRECISION_SHIFT, FEE_DENOMINATOR - fee, FEE_DENOMINATOR);
        return FullMath.mulDiv(reserveOut, netInput, reserveIn + netInput) >> PRECISION_SHIFT;
    }
}
