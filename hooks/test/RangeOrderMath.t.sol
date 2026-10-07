// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {RangeOrderMath} from "../src/libraries/RangeOrderMath.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";

contract RangeOrderMathTest is Test {
    uint160 private constant PRICE = uint160(2 << 96);

    function test_integralExampleAndContinuation() public pure {
        RangeOrderMath.Curve memory curve = RangeOrderMath.Curve(10e18, 0, 3000e6, 3200e6, 1e18, 0);
        OrderMath.Fill memory first = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(6040e6, 10e18, PRICE, false));
        assertEq(first.output, 2e18);
        assertEq(first.payment, 6040e6);
        curve.filled = first.output;
        OrderMath.Fill memory next = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(9210e6, 3e18, PRICE, false));
        assertEq(next.output, 3e18);
        assertEq(next.payment, 9210e6);
        assertEq(RangeOrderMath.cumulative(curve, 10e18), 31000e6);
    }

    function test_splitPaymentAndFeeEqualWholeFill() public pure {
        RangeOrderMath.Curve memory curve = RangeOrderMath.Curve(25, 0, 7, 13, 11, 333);
        OrderMath.Fill memory whole = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(100, 25, PRICE, false));
        OrderMath.Fill memory first = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(100, 7, PRICE, false));
        curve.filled = first.output;
        OrderMath.Fill memory rest = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(100, 18, PRICE, false));
        assertEq(whole.payment, 23);
        assertEq(whole.fee, 1);
        assertEq(uint256(first.payment) + rest.payment, whole.payment);
        assertEq(uint256(first.fee) + rest.fee, whole.fee);
        assertEq(uint256(first.output) + rest.output, whole.output);
    }

    function test_marketCapStopsAtTerminalPrice() public pure {
        RangeOrderMath.Curve memory curve = RangeOrderMath.Curve(1000, 0, 50, 150, 100, 0);
        OrderMath.Fill memory first =
            RangeOrderMath.fill(curve, RangeOrderMath.Bounds(2000, 1000, uint160(1 << 96), false));
        assertEq(first.output, 500);
        assertEq(first.payment, 375);
        curve.filled = first.output;
        OrderMath.Fill memory stopped =
            RangeOrderMath.fill(curve, RangeOrderMath.Bounds(2000, 500, uint160(1 << 96), false));
        assertEq(stopped.output, 0);
        OrderMath.Fill memory rest = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(2000, 500, PRICE, false));
        assertEq(rest.output, 500);
        assertEq(rest.payment, 625);
    }

    function test_extremeProductsUseFullPrecision() public pure {
        uint128 amount = uint128(OrderMath.MAX_DELTA);
        RangeOrderMath.Curve memory curve =
            RangeOrderMath.Curve(amount, 0, type(uint128).max - 1, type(uint128).max, type(uint128).max, 0);
        OrderMath.Fill memory result = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(amount, amount, PRICE, false));
        assertEq(result.output, amount);
        assertEq(result.payment, amount);
    }

    function test_noFreeDustFill() public pure {
        RangeOrderMath.Curve memory curve = RangeOrderMath.Curve(1000, 500, 1, 2, 1000, 0);
        OrderMath.Fill memory result = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(1, 1, PRICE, false));
        assertEq(result.payment, 0);
        assertEq(result.output, 0);
    }

    function test_splitBeneficiaryAllocationEqualsWhole() public pure {
        RangeOrderMath.Curve memory curve = RangeOrderMath.Curve(100, 0, 200, 600, 1000, 1000);
        OrderMath.Fill memory first = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(100, 12, PRICE, false));
        curve.filled = first.output;
        uint256 firstRevenue = RangeOrderMath.revenue(curve, first.output, first.fee, 5000);
        OrderMath.Fill memory rest = RangeOrderMath.fill(curve, RangeOrderMath.Bounds(100, 88, PRICE, false));
        curve.filled += rest.output;
        uint256 restRevenue = RangeOrderMath.revenue(curve, rest.output, rest.fee, 5000);
        assertEq(uint256(first.payment) + rest.payment, 40);
        assertEq(uint256(first.fee) + rest.fee, 4);
        assertEq(firstRevenue + restRevenue, 2);
    }

    function test_largeCumulativeFeeAllocationUsesFullPrecision() public pure {
        uint128 amount = uint128(OrderMath.MAX_DELTA);
        RangeOrderMath.Curve memory curve =
            RangeOrderMath.Curve(amount, amount / 2, type(uint128).max - 1, type(uint128).max, 8, 1000);
        OrderMath.Fill memory result =
            RangeOrderMath.fill(curve, RangeOrderMath.Bounds(amount, 1, type(uint160).max / 2, false));
        assertEq(result.output, 1);
        curve.filled += result.output;
        uint256 revenue = RangeOrderMath.revenue(curve, result.output, result.fee, 5000);
        assertGt(revenue, 0);
        assertLe(revenue, result.fee);
    }

    function testFuzz_splitIntegralAndBudget(
        uint80 amountSeed,
        uint64 startSeed,
        uint64 spread,
        uint64 denominatorSeed,
        uint80 filledSeed,
        uint128 budgetSeed,
        uint16 feeSeed
    ) public pure {
        uint128 amount = uint128(amountSeed) + 1;
        RangeOrderMath.Curve memory curve = RangeOrderMath.Curve(
            amount,
            uint128(filledSeed) % amount,
            uint128(startSeed) + 1,
            uint128(startSeed) + 1 + spread,
            uint128(denominatorSeed) + 1,
            feeSeed % 1001
        );
        uint256 budget = uint256(budgetSeed) % (OrderMath.MAX_DELTA + 1);
        uint128 available = amount - curve.filled;
        uint160 highMarketPrice = type(uint160).max / 2;
        OrderMath.Fill memory result =
            RangeOrderMath.fill(curve, RangeOrderMath.Bounds(budget, available, highMarketPrice, false));
        assertLe(uint256(result.payment) + result.fee, budget);
        assertLe(result.output, available);
        if (result.output == 0) return;
        uint256 beforePayment = RangeOrderMath.cumulative(curve, curve.filled);
        assertEq(beforePayment + result.payment, RangeOrderMath.cumulative(curve, curve.filled + result.output));
        // Independent polynomial integral for these widths: no FullMath needed.
        uint256 q = curve.filled + result.output;
        uint256 numerator = 2 * uint256(amount) * curve.start * q + uint256(curve.end - curve.start) * q * q;
        uint256 denominator = 2 * uint256(amount) * curve.denominator;
        assertEq(beforePayment + result.payment, (numerator + denominator - 1) / denominator);
        uint256 beforeGross = _referenceGross(curve, curve.filled);
        assertEq(uint256(result.payment) + result.fee, _referenceGross(curve, q) - beforeGross);
        if (q < amount) assertGt(_referenceGross(curve, q + 1) - beforeGross, budget);
    }

    function _referenceGross(RangeOrderMath.Curve memory curve, uint256 q) private pure returns (uint256) {
        uint256 numerator = 2 * uint256(curve.amount) * curve.start * q + uint256(curve.end - curve.start) * q * q;
        uint256 denominator = 2 * uint256(curve.amount) * curve.denominator;
        uint256 payment = (numerator + denominator - 1) / denominator;
        return payment + (payment * curve.feeBps + OrderMath.BPS - 1) / OrderMath.BPS;
    }
}
