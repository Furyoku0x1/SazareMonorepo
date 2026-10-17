// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

library OrderMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant MAX_DELTA = uint256(uint128(type(int128).max));

    struct Fill {
        uint128 output;
        uint128 payment;
        uint128 fee;
    }

    function compare(uint128 n0, uint128 d0, uint128 n1, uint128 d1) internal pure returns (int8) {
        uint256 left = uint256(n0) * d1;
        uint256 right = uint256(n1) * d0;
        return left < right ? int8(-1) : left > right ? int8(1) : int8(0);
    }

    function fill(uint256 budget, uint256 maximumOutput, uint128 n, uint128 d, uint16 feeBps)
        internal
        pure
        returns (Fill memory result)
    {
        uint256 paymentBudget = FullMath.mulDiv(budget, BPS, BPS + feeBps);
        uint256 output = FullMath.mulDiv(paymentBudget, d, n);
        if (output > maximumOutput) output = maximumOutput;
        if (output == 0) return result;
        uint256 payment = FullMath.mulDivRoundingUp(output, n, d);
        uint256 fee = FullMath.mulDivRoundingUp(payment, feeBps, BPS);
        assert(payment + fee <= budget && output <= MAX_DELTA);
        result = Fill(uint128(output), uint128(payment), uint128(fee));
    }

    function competitive(uint256 input, uint256 output, uint160 sqrtPrice, bool zeroForOne)
        internal
        pure
        returns (bool)
    {
        uint256 intermediate = zeroForOne
            ? FullMath.mulDivRoundingUp(input, sqrtPrice, Q96)
            : FullMath.mulDivRoundingUp(input, Q96, sqrtPrice);
        uint256 required = zeroForOne
            ? FullMath.mulDivRoundingUp(intermediate, sqrtPrice, Q96)
            : FullMath.mulDivRoundingUp(intermediate, Q96, sqrtPrice);
        return output >= required;
    }
}
