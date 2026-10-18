// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {DebtTree, DebtValuation} from "../../src/metric/vault/libraries/DebtValuation.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";

/// @notice Holds one debt tree in storage for the test.
contract DebtTreeHarness {
    DebtTree internal tree;

    function add(uint128 liquidity, int24 tickLower, int24 tickUpper) external {
        DebtValuation.add(tree, liquidity, tickLower, tickUpper);
    }

    function remove(uint128 liquidity, int24 tickLower, int24 tickUpper) external {
        DebtValuation.remove(tree, liquidity, tickLower, tickUpper);
    }

    function holdingsX64(uint160 sqrtPriceX96) external view returns (int256 amount0X64, int256 amount1X64) {
        return DebtValuation.holdingsX64(tree, sqrtPriceX96);
    }

    function values(uint160 sqrtPriceX96) external view returns (uint256 low, uint256 high) {
        return (DebtValuation.valueLow(tree, sqrtPriceX96), DebtValuation.valueHigh(tree, sqrtPriceX96));
    }
}

/// @notice The debt tree (audit finding H1) against each debt's holdings computed on its own: at any price, the tree's
/// holdings match their sum within its rounding slack, its low and high values bracket the sum's value, and removing
/// debts takes out exactly what adding them put in.
contract DebtValuationTest is Test {
    uint256 internal constant MAX_DEBTS = 8;
    int24 internal constant MAX_RANGE_TICK = 443_636;
    /// @dev The band's bounds (`VaultPricing.MIN_SQRT_X96` and `MAX_SQRT_X96`).
    uint160 internal constant MIN_SQRT_X96 = 18446744073709551616;
    uint160 internal constant MAX_SQRT_X96 = 340282366920938463463374607431768211455;
    uint256 internal constant X64 = 1 << 64;

    DebtTreeHarness internal harness;

    struct Debt {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
    }

    function setUp() public {
        harness = new DebtTreeHarness();
    }

    /// @dev Up to eight debts anywhere in the tick range, a price anywhere in the band; then the first `removed` taken
    /// out again.
    function testFuzz_matchesEachDebtSummed(
        uint256[MAX_DEBTS] memory seeds,
        uint8 count,
        uint8 removed,
        uint256 priceSeed
    ) public {
        count = uint8(bound(count, 1, MAX_DEBTS));
        removed = uint8(bound(removed, 0, count));
        Debt[] memory debts = new Debt[](count);
        // index < count <= MAX_DEBTS
        for (uint256 index = 0; index < count; ++index) {
            debts[index] = _debt(seeds[index]);
            harness.add(debts[index].liquidity, debts[index].tickLower, debts[index].tickUpper);
        }
        // index < removed <= MAX_DEBTS
        for (uint256 index = 0; index < removed; ++index) {
            harness.remove(debts[index].liquidity, debts[index].tickLower, debts[index].tickUpper);
        }
        uint160 sqrtPriceX96 = _price(priceSeed);
        _assertMatches(debts, removed, sqrtPriceX96);
        // Exactly at one debt's lower and upper ends, where a range turns from one case to the next.
        Debt memory last = debts[count - 1];
        _assertMatches(debts, removed, TickMath.getSqrtPriceAtTick(_inBand(last.tickLower)));
        _assertMatches(debts, removed, TickMath.getSqrtPriceAtTick(_inBand(last.tickUpper)));
    }

    /// @dev Adding and then removing every debt leaves the tree reading nothing at any price.
    function testFuzz_removingEverythingLeavesNothing(uint256[MAX_DEBTS] memory seeds, uint256 priceSeed) public {
        // index < MAX_DEBTS
        for (uint256 index = 0; index < MAX_DEBTS; ++index) {
            Debt memory debt = _debt(seeds[index]);
            harness.add(debt.liquidity, debt.tickLower, debt.tickUpper);
            if (index % 2 == 1) harness.remove(debt.liquidity, debt.tickLower, debt.tickUpper);
        }
        // index < MAX_DEBTS
        for (uint256 index = 0; index < MAX_DEBTS; index += 2) {
            Debt memory debt = _debt(seeds[index]);
            harness.remove(debt.liquidity, debt.tickLower, debt.tickUpper);
        }
        (int256 amount0, int256 amount1) = harness.holdingsX64(_price(priceSeed));
        assertEq(amount0, 0, "no token0");
        assertEq(amount1, 0, "no token1");
        (uint256 low, uint256 high) = harness.values(_price(priceSeed));
        assertEq(low, 0, "worth nothing");
        assertEq(high, 0, "worth nothing");
    }

    /// @dev H1's case: a range 3,000 ticks below the price holds only token1, its whole notional, where the old lower
    /// bound valued it at nothing.
    function test_aRangeBelowThePrice_isWorthItsNotional() public {
        int24 priceTick = -200_311;
        int24 lower = priceTick - 3_000;
        int24 upper = priceTick - 2_900;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        uint128 liquidity = uint128(uint256(10_000e6) * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        harness.add(liquidity, lower, upper);
        (uint256 low, uint256 high) = harness.values(TickMath.getSqrtPriceAtTick(priceTick));
        assertApproxEqAbs(low, 10_000e6, 2, "low: the notional");
        assertApproxEqAbs(high, 10_000e6, 2, "high: the notional");
    }

    /// @dev Sol's verification of H1: the slack was whole units of each token, so with a base of no decimals worth
    /// 10,000 USDC, a 101 USDC debt holding no base was priced for deposits at 30,065 USDC. Rounding now stays in
    /// 2^-64 units until the value is in token1.
    function test_aBaseWithoutDecimals_addsNoWholeUnitOfSlack() public {
        // 10,000 USDC of six decimals per unit of a base with none: a raw price of 1e10.
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(230_258);
        int24 lower = 200_000;
        int24 upper = 201_000;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        uint128 liquidity = uint128(uint256(101e6) * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        harness.add(liquidity, lower, upper);
        // About 101 USDC: a unit of liquidity here is worth hundreds of raw units, so the notional rounds.
        uint256 notional = FullMath.mulDiv(liquidity, sqrtUpperX96 - sqrtLowerX96, 1 << 96);
        (uint256 low, uint256 high) = harness.values(sqrtPriceX96);
        assertApproxEqAbs(low, notional, 2, "low: the notional");
        assertApproxEqAbs(high, notional, 2, "high: the notional");
    }

    function _assertMatches(Debt[] memory debts, uint256 removed, uint160 sqrtPriceX96) internal view {
        uint256 count = debts.length - removed;
        (uint256 brute0, uint256 brute1) = _bruteHoldingsX64(debts, removed, sqrtPriceX96);
        (int256 amount0, int256 amount1) = harness.holdingsX64(sqrtPriceX96);
        // The tree's terms are within 2 units per debt and 1 for the price's; the brute force's within 2 per debt.
        uint256 apart = 4 * count + 1;
        assertApproxEqAbs(amount0, int256(brute0), apart, "token0 within the slack");
        assertApproxEqAbs(amount1, int256(brute1), apart, "token1 within the slack");
        (uint256 low, uint256 high) = harness.values(sqrtPriceX96);
        // The exact value lies between the brute force's and that plus 2 units per debt of each token.
        uint256 upper = 2 * count;
        uint256 atMostX64 = VaultMath.valueInToken1(brute0 + upper, brute1 + upper, sqrtPriceX96, true);
        assertLe(low * X64, atMostX64, "low is at most the value");
        assertGe(high * X64, VaultMath.valueInToken1(brute0, brute1, sqrtPriceX96, false), "high is at least it");
        uint256 units = DebtValuation.ROUNDING_UNITS * count + 3;
        uint256 slackX64 = VaultMath.valueInToken1(units, units, sqrtPriceX96, true);
        assertLe((high - low) * X64, 2 * slackX64 + 2 * X64, "and they are a slack apart");
    }

    /// @dev Each remaining debt's holdings at the price on its own, in 2^-64 units, rounded down: under a unit of token1
    /// and two of token0 below the exact amounts.
    function _bruteHoldingsX64(Debt[] memory debts, uint256 removed, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 amount0X64, uint256 amount1X64)
    {
        // index < debts.length <= MAX_DEBTS
        for (uint256 index = removed; index < debts.length; ++index) {
            Debt memory debt = debts[index];
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(debt.tickLower, debt.tickUpper);
            uint160 inside = sqrtPriceX96 < sqrtLowerX96 ? sqrtLowerX96 : sqrtPriceX96;
            inside = inside > sqrtUpperX96 ? sqrtUpperX96 : inside;
            amount1X64 += FullMath.mulDiv(debt.liquidity, inside - sqrtLowerX96, 1 << 32);
            // L < 2^96, so L · 2^160 fits: L(√b − √P)/(√P·√b) in 2^-64 units.
            uint256 scaled = uint256(debt.liquidity) << 160;
            amount0X64 += FullMath.mulDiv(scaled, sqrtUpperX96 - inside, sqrtUpperX96) / inside;
        }
    }

    function _debt(uint256 seed) internal pure returns (Debt memory debt) {
        int24 tickLower = int24(int256(bound(seed % 1e12, 0, uint256(int256(2 * MAX_RANGE_TICK - 1))))) - MAX_RANGE_TICK;
        int24 width = int24(int256(bound((seed >> 40) % 1e12, 1, 20_000)));
        int24 tickUpper = tickLower + width > MAX_RANGE_TICK ? MAX_RANGE_TICK : tickLower + width;
        debt.tickLower = tickLower;
        debt.tickUpper = tickUpper;
        debt.liquidity = uint128(bound(seed >> 128, 1, type(uint96).max));
    }

    function _price(uint256 seed) internal pure returns (uint160) {
        return uint160(bound(seed, MIN_SQRT_X96, MAX_SQRT_X96));
    }

    /// @dev A range end's tick, kept inside the band so its price is one a band can give.
    function _inBand(int24 tick) internal pure returns (int24) {
        return tick >= MAX_RANGE_TICK ? MAX_RANGE_TICK - 1 : tick;
    }
}
