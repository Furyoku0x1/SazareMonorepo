// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {OrderMath} from "./OrderMath.sol";

/// @dev Linear payment-per-escrow-unit curves. All functions are inlined/internal;
/// this library is not a separately deployed contract.
library RangeOrderMath {
    uint256 private constant SEARCH_STEPS = 127;

    struct Curve {
        uint128 amount;
        uint128 filled;
        uint128 start;
        uint128 end;
        uint128 denominator;
        uint16 feeBps;
    }

    struct Bounds {
        uint256 budget;
        uint256 maximumOutput;
        uint160 sqrtPrice;
        bool zeroForOne;
    }

    /// @notice Rounded cumulative integral, not a separately rounded price per fill.
    /// @dev q <= amount <= int128.max. The weighted numerator and denominator
    /// each fit uint256; FullMath handles the 512-bit outer product exactly.
    function cumulative(Curve memory curve, uint256 q) internal pure returns (uint256) {
        uint256 twiceAmount = uint256(curve.amount) * 2;
        uint256 weightedPrice = (twiceAmount - q) * curve.start + q * curve.end;
        return FullMath.mulDivRoundingUp(q, weightedPrice, twiceAmount * curve.denominator);
    }

    /// @dev Called after filled advances. Cumulative allocation prevents splitting
    /// a range into small fills from avoiding the beneficiary's fee share.
    function revenue(Curve memory curve, uint128 output, uint128 fee, uint16 shareBps) internal pure returns (uint256) {
        if (shareBps == 0 || fee == 0) return 0;
        if (curve.end == 0) return uint256(fee) * shareBps / OrderMath.BPS;
        uint256 beforeFee = _fee(cumulative(curve, curve.filled - output), curve.feeBps);
        uint256 afterFee = _fee(cumulative(curve, curve.filled), curve.feeBps);
        uint256 allocated =
            FullMath.mulDiv(afterFee, shareBps, OrderMath.BPS) - FullMath.mulDiv(beforeFee, shareBps, OrderMath.BPS);
        assert(allocated <= fee);
        return allocated;
    }

    function fill(Curve memory curve, Bounds memory bounds) internal pure returns (OrderMath.Fill memory result) {
        if (curve.end == 0) {
            return OrderMath.fill(bounds.budget, bounds.maximumOutput, curve.start, curve.denominator, curve.feeBps);
        }
        uint256 high = uint256(curve.filled) + bounds.maximumOutput;
        uint256 priceCap = _priceCap(curve, bounds);
        if (high > priceCap) high = priceCap;
        if (high <= curve.filled) return result;
        uint256 beforePayment = cumulative(curve, curve.filled);
        uint256 beforeFee = _fee(beforePayment, curve.feeBps);
        uint256 paymentLimit =
            FullMath.mulDiv(beforePayment + beforeFee + bounds.budget, OrderMath.BPS, OrderMath.BPS + curve.feeBps);
        uint256 q = _affordable(curve, high, paymentLimit, beforePayment);
        uint256 payment = cumulative(curve, q) - beforePayment;
        if (q == curve.filled || payment == 0) return result;
        uint256 fee = _fee(beforePayment + payment, curve.feeBps) - beforeFee;
        assert(payment + fee <= bounds.budget && q - curve.filled <= bounds.maximumOutput);
        return OrderMath.Fill(uint128(q - curve.filled), uint128(payment), uint128(fee));
    }

    /// @dev Binary search is exact in raw units and has a fixed 127-step ceiling.
    /// Full affordable/market-capped fills avoid the search entirely.
    function _affordable(Curve memory curve, uint256 high, uint256 paymentLimit, uint256 beforePayment)
        private
        pure
        returns (uint256 low)
    {
        low = curve.filled;
        if (cumulative(curve, high) <= paymentLimit) return high;
        // The convex integral lies above its current tangent. One payment unit
        // covers the cumulative ceil carry, giving a safe upper quantity bound.
        uint256 marginal = uint256(curve.amount) * curve.start + low * (curve.end - curve.start);
        uint256 maximumExtra =
            FullMath.mulDiv(paymentLimit - beforePayment + 1, uint256(curve.amount) * curve.denominator, marginal);
        if (high > low + maximumExtra) high = low + maximumExtra;
        for (uint256 i; i < SEARCH_STEPS; ++i) {
            if (low == high) break;
            uint256 mid = low + (high - low + 1) / 2;
            if (cumulative(curve, mid) <= paymentLimit) low = mid;
            else high = mid - 1;
        }
        assert(low == high);
    }

    /// @dev Conservative AMM spot cap includes the surcharge. Terminal marginal
    /// price must fit, so a cheap prefix cannot subsidize filling past the cap.
    function _priceCap(Curve memory curve, Bounds memory bounds) private pure returns (uint256) {
        uint256 input = bounds.zeroForOne
            ? FullMath.mulDiv(curve.denominator, OrderMath.Q96, bounds.sqrtPrice)
            : FullMath.mulDiv(curve.denominator, bounds.sqrtPrice, OrderMath.Q96);
        input = bounds.zeroForOne
            ? FullMath.mulDiv(input, OrderMath.Q96, bounds.sqrtPrice)
            : FullMath.mulDiv(input, bounds.sqrtPrice, OrderMath.Q96);
        uint256 numeratorCap = FullMath.mulDiv(input, OrderMath.BPS, OrderMath.BPS + curve.feeBps);
        if (numeratorCap < curve.start) return 0;
        if (numeratorCap >= curve.end) return curve.amount;
        return FullMath.mulDiv(curve.amount, numeratorCap - curve.start, curve.end - curve.start);
    }

    function _fee(uint256 payment, uint16 feeBps) private pure returns (uint256) {
        return FullMath.mulDivRoundingUp(payment, feeBps, OrderMath.BPS);
    }
}
