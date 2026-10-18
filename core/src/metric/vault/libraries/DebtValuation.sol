// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {VaultMath} from "./VaultMath.sol";

/// @notice One node of the debt tree: three sums over the range ends in the node's span.
struct DebtNode {
    /// @dev `+L` at a lower end, `−L` at an upper end: a prefix up to the price is the liquidity of ranges holding it.
    int256 liquidity;
    /// @dev `−L·√a` at a lower end, `+L·√b` at an upper end, in 2^-64 units of token1.
    int256 amount1X64;
    /// @dev `+L/√a` at a lower end, `−L/√b` at an upper end, in 2^-64 units of token0.
    int256 amount0X64;
}

/// @notice The vault's open debts, indexed by their range ends in a Fenwick tree, so their exact holdings at any price
/// take a fixed number of reads (the owner's decision on audit finding H1).
struct DebtTree {
    /// @dev Open debts: each one's rounded terms can be off by up to `ROUNDING_UNITS` 2^-64 units of each token.
    uint256 count;
    /// @dev Every debt's all-token0 amount, `Σ (L/√a − L/√b)`, from the same rounded terms as the nodes, so a range
    /// wholly below the price cancels to exactly nothing.
    int256 allAmount0X64;
    mapping(uint256 index => DebtNode) nodes;
}

/// @notice Values the vault's open debts exactly: what repaying every one of them at a price would return. Replaces
/// bounds that were exact only for ranges holding the price: a range off the price was valued near zero for
/// withdrawals, so an exit forfeited the debt's value to whoever held the last shares (audit finding H1).
/// @dev A range `[a, b]` with liquidity `L` holds `L(1/√a − 1/√b)` token0 above the price, `L(√b − √a)` token1 below
/// it, and `L(1/√P − 1/√b)` token0 with `L(√P − √a)` token1 within it. Sums of those terms over the range ends at or
/// below the price tick give every case at once.
library DebtValuation {
    using SafeCast for uint256;

    /// @dev Range ends map to indices `tick + OFFSET`, from 1 for `-MAX_RANGE_TICK` to `SIZE` for `MAX_RANGE_TICK`.
    int256 internal constant OFFSET = 443_637;
    /// @dev `2·MAX_RANGE_TICK + 1`, under 2^20: a tree walk takes at most 20 steps.
    uint256 internal constant SIZE = 887_273;
    /// @dev Amounts carry 64 fractional bits: the slack is `2·count + 3` 2^-64 units of each token, valued at the price,
    /// rather than whole units, which on a token whose unit is worth much, such as one with no decimals, inflated the
    /// deposit price (Sol's verification). It reaches a whole unit of token1 only near the band's top price, where a
    /// unit of token1 is worth about 2^-64 of a unit of token0.
    uint256 internal constant X64 = 1 << 64;
    /// @dev `X64 · Q96`: a token0 term `L/√P` in 2^-64 units.
    uint256 internal constant X64_Q96 = 1 << 160;
    /// @dev `Q96 / X64`: a token1 term `L·√P` in 2^-64 units.
    uint256 internal constant Q96_PER_X64 = 1 << 32;
    /// @dev 2^-64 units of each token one debt's terms can be off by: two terms per token, each rounded down once.
    uint256 internal constant ROUNDING_UNITS = 2;

    /// @notice Adds a debt of `liquidity` on `[tickLower, tickUpper)`.
    function add(DebtTree storage tree, uint128 liquidity, int24 tickLower, int24 tickUpper) internal {
        tree.count += 1;
        _update(tree, liquidity, tickLower, tickUpper, 1);
    }

    /// @notice Removes a debt added with the same arguments. Its terms depend on nothing else, so this subtracts
    /// exactly what `add` added.
    function remove(DebtTree storage tree, uint128 liquidity, int24 tickLower, int24 tickUpper) internal {
        tree.count -= 1;
        _update(tree, liquidity, tickLower, tickUpper, -1);
    }

    /// @notice A lower bound in token1 on what the debts return at a price: their value less the rounding slack,
    /// rounded down. Withdrawals price debts with it at the bid.
    function valueLow(DebtTree storage tree, uint160 sqrtPriceX96) internal view returns (uint256) {
        if (tree.count == 0) return 0;
        (uint256 valueX64, uint256 slackX64) = _valueX64(tree, sqrtPriceX96);
        return valueX64 > slackX64 ? (valueX64 - slackX64) / X64 : 0;
    }

    /// @notice An upper bound in token1 on what the debts return at a price: their value plus the rounding slack,
    /// rounded up. Deposits price debts with it at the ask.
    function valueHigh(DebtTree storage tree, uint160 sqrtPriceX96) internal view returns (uint256) {
        if (tree.count == 0) return 0;
        (uint256 valueX64, uint256 slackX64) = _valueX64(tree, sqrtPriceX96);
        return FullMath.mulDivRoundingUp(valueX64 + slackX64, 1, X64);
    }

    /// @notice The debts' combined holdings at a price in 2^-64 units, each off by at most `ROUNDING_UNITS · count + 1`
    /// of them.
    function holdingsX64(DebtTree storage tree, uint160 sqrtPriceX96)
        internal
        view
        returns (int256 amount0X64, int256 amount1X64)
    {
        DebtNode memory below = _prefix(tree, _priceIndex(sqrtPriceX96));
        // The liquidity of the ranges holding the price: every lower end at or below it, less their upper ends.
        assert(below.liquidity >= 0);
        uint256 inRange = uint256(below.liquidity);
        amount1X64 = below.amount1X64 + FullMath.mulDiv(inRange, sqrtPriceX96, Q96_PER_X64).toInt256();
        amount0X64 = tree.allAmount0X64 - below.amount0X64 + FullMath.mulDiv(inRange, X64_Q96, sqrtPriceX96).toInt256();
    }

    /// @dev The holdings' value in 2^-64 units of token1, rounded down, and a slack that covers every rounding in it
    /// and in the terms: the terms' units of each token, one for the price's term, and two for this valuation's (its
    /// two roundings of the token0 part, under `1 + √P` units, never exceed `2 · (1 + P)`).
    function _valueX64(DebtTree storage tree, uint160 sqrtPriceX96)
        private
        view
        returns (uint256 valueX64, uint256 slackX64)
    {
        (int256 amount0X64, int256 amount1X64) = holdingsX64(tree, sqrtPriceX96);
        valueX64 = VaultMath.valueInToken1(_atLeastZero(amount0X64), _atLeastZero(amount1X64), sqrtPriceX96, false);
        uint256 units = ROUNDING_UNITS * tree.count + 3;
        slackX64 = VaultMath.valueInToken1(units, units, sqrtPriceX96, true);
    }

    function _update(DebtTree storage tree, uint128 liquidity, int24 tickLower, int24 tickUpper, int256 sign) private {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(tickLower, tickUpper);
        DebtNode memory lowerEnd = _end(liquidity, sqrtLowerX96, sign);
        DebtNode memory upperEnd = _end(liquidity, sqrtUpperX96, -sign);
        tree.allAmount0X64 += lowerEnd.amount0X64 + upperEnd.amount0X64;
        _addAt(tree, _tickIndex(tickLower), lowerEnd);
        _addAt(tree, _tickIndex(tickUpper), upperEnd);
    }

    /// @dev A range end's terms: a lower end (`sign` 1) adds the range from it up, an upper end (`sign` -1) takes it
    /// away again. A removal flips both.
    function _end(uint128 liquidity, uint160 sqrtX96, int256 sign) private pure returns (DebtNode memory end) {
        int256 amount1X64 = FullMath.mulDiv(liquidity, sqrtX96, Q96_PER_X64).toInt256();
        int256 amount0X64 = FullMath.mulDiv(liquidity, X64_Q96, sqrtX96).toInt256();
        end.liquidity = sign * int256(uint256(liquidity));
        end.amount1X64 = -sign * amount1X64;
        end.amount0X64 = sign * amount0X64;
    }

    function _addAt(DebtTree storage tree, uint256 index, DebtNode memory delta) private {
        // index <= SIZE < 2^20, and each step moves past index's lowest set bit: at most 20 steps
        while (index <= SIZE) {
            DebtNode storage node = tree.nodes[index];
            node.liquidity += delta.liquidity;
            node.amount1X64 += delta.amount1X64;
            node.amount0X64 += delta.amount0X64;
            index += index & (~index + 1);
        }
    }

    /// @dev The sums over every range end at an index up to `index`.
    function _prefix(DebtTree storage tree, uint256 index) private view returns (DebtNode memory sum) {
        // index <= SIZE < 2^20, and each step clears index's lowest set bit: at most 20 steps
        while (index > 0) {
            DebtNode storage node = tree.nodes[index];
            sum.liquidity += node.liquidity;
            sum.amount1X64 += node.amount1X64;
            sum.amount0X64 += node.amount0X64;
            index &= index - 1;
        }
    }

    function _tickIndex(int24 tick) private pure returns (uint256) {
        return uint256(int256(tick) + OFFSET);
    }

    /// @dev The index of the price's tick, the greatest whose price is at or below it: range ends there or lower are
    /// at or below the price. Band prices lie within the ranges' bounds; the clamp only guards that.
    function _priceIndex(uint160 sqrtPriceX96) private pure returns (uint256) {
        int256 index = int256(TickMath.getTickAtSqrtPrice(sqrtPriceX96)) + OFFSET;
        if (index < 0) return 0;
        if (index > int256(SIZE)) return SIZE;
        return uint256(index);
    }

    function _atLeastZero(int256 amount) private pure returns (uint256) {
        return amount > 0 ? uint256(amount) : 0;
    }
}
