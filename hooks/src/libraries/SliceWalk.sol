// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {AmmReplay} from "./AmmReplay.sol";

/// @notice Phase 0 prototype. Sizes one book side, one range and one fixed price, against the AMM so that
/// the PoolManager's swap of the remainder lands exactly where the walk expects. Book liquidity priced
/// better than the pool (left behind by an early stop) fills first.
/// @dev Prices are sqrt prices. "Beyond" follows the swap's direction.
library SliceWalk {
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant Q192 = 1 << 192;
    uint256 private constant PIPS = 1_000_000;

    /// @dev The budget ran out inside an AMM step: the AMM lands at ammLanding.
    uint8 internal constant INSIDE = 0;
    /// @dev No book liquidity is left ahead; the AMM takes the rest.
    uint8 internal constant BOOK_DONE = 1;
    uint8 internal constant LIMIT = 2;
    uint8 internal constant CAP = 3;
    /// @dev The gas guard stopped the walk; quotes, which pass no guard, cannot reproduce this.
    uint8 internal constant GAS = 4;

    struct Book {
        uint160 rangeFrom; // the unsold range in walk order: rangeFrom is reached first
        uint160 rangeTo;
        uint128 rangeLiquidity;
        uint160 fixedPrice;
        uint128 fixedAmount; // output currency left at the fixed price
    }

    struct Swap {
        AmmReplay.Pool pool;
        bool exactIn;
        uint256 budget; // the specified amount
        uint256 maxSteps; // deterministic step limit, shared by execution and quotes
        uint256 minGas; // safety guard: stop when gasleft() falls below it; 0 for quotes
        uint160 start;
    }

    struct Fill {
        uint256 specified; // the book's share of the specified currency
        uint256 other;
        uint256 ammShare; // the AMM's share the walk sized, specified currency
        uint160 start;
        uint160 frontier; // the book filled everything before this price
        uint160 ammLanding; // where the AMM lands with ammShare (stop INSIDE)
        uint160 ammNext; // where it would land with one more unit (stop INSIDE)
        uint128 fixedFilled;
        uint256 iterations;
        uint8 stop;
    }

    function allocate(Swap memory w, Book memory b) internal view returns (Fill memory f) {
        AmmReplay.Cursor memory c = AmmReplay.load(w.pool);
        w.start = c.sqrtPriceX96;
        f.start = c.sqrtPriceX96;
        f.frontier = c.sqrtPriceX96;
        f.ammLanding = c.sqrtPriceX96;
        f.ammNext = c.sqrtPriceX96;
        // A 100% fee leaves nothing to price the book against; the AMM takes the swap.
        if (w.pool.fee >= PIPS) {
            f.stop = BOOK_DONE;
            return f;
        }
        if (w.minGas != 0 && gasleft() < w.minGas) {
            f.stop = GAS;
            return f;
        }
        // Catch-up: book liquidity priced better than the pool fills first. When it covers the whole budget,
        // the book fills it in price order, stopping where the request is met, and the AMM is not touched.
        (uint256 behind,) = _cost(w, b, w.start);
        if (behind >= w.budget) {
            f.stop = INSIDE;
            f.frontier = _bookStart(w, b);
            uint256 shortfall = _spend(w, b, f, true);
            if (shortfall != 0) {
                f.ammShare = shortfall; // rounding: the PoolManager decides where it lands
                f.stop = BOOK_DONE;
            }
            return f;
        }
        uint256 steps;
        while (true) {
            if (w.minGas != 0 && gasleft() < w.minGas) {
                f.stop = GAS;
                break;
            }
            if (_exhausted(w, b, c.sqrtPriceX96)) {
                f.stop = BOOK_DONE;
                break;
            }
            if (c.sqrtPriceX96 == w.pool.limit) {
                f.stop = LIMIT;
                break;
            }
            if (steps++ == w.maxSteps) {
                f.stop = CAP;
                break;
            }
            uint8 outcome = _step(w, b, c, f);
            if (outcome == STEP_TAKEN) continue;
            if (outcome == STEP_FINISHED) return f;
            break; // spent exactly at the step's end
        }
        (f.specified, f.other) = _cost(w, b, f.frontier);
        if (b.fixedAmount != 0 && _beyond(w, f.frontier, b.fixedPrice)) f.fixedFilled = b.fixedAmount;
        // Fixed orders exactly at the price limit are reachable; the taker keeps any input left.
        if (f.stop == LIMIT) _spend(w, b, f, false);
    }

    uint8 private constant STEP_TAKEN = 0;
    uint8 private constant STEP_FINISHED = 1;
    uint8 private constant STEP_EXACT = 2;

    /// @dev One AMM step: take it whole if it fits, else finish the walk inside it.
    function _step(Swap memory w, Book memory b, AmmReplay.Cursor memory c, Fill memory f)
        private
        view
        returns (uint8)
    {
        AmmReplay.Step memory s = AmmReplay.next(w.pool, c);
        uint256 stepAmount = _ammAmount(w, c, s.target);
        (uint256 bookAmount,) = _cost(w, b, s.target);
        uint256 total = f.ammShare + stepAmount + bookAmount;
        // Exact output takes a step whole only while it stays short of the request; a step that would meet it
        // exactly goes through the search, which stops where the request is met rather than charging for
        // liquidity whose output rounds to zero.
        if (w.exactIn ? total > w.budget : total >= w.budget) {
            _finishInside(w, b, c, s, stepAmount, f);
            return STEP_FINISHED;
        }
        f.ammShare += stepAmount;
        // v4 stops where its remaining amount reaches zero, before any empty steps.
        if (stepAmount != 0) f.ammLanding = s.target;
        AmmReplay.move(w.pool, c, s, s.target);
        f.frontier = s.target;
        if (total != w.budget) return STEP_TAKEN;
        // Spent exactly: stop here rather than walk on through empty steps.
        f.stop = INSIDE;
        f.ammNext = s.target;
        return STEP_EXACT;
    }

    /// @dev The budget runs out inside this step: size the AMM's share, then spend the rest on the book.
    function _finishInside(
        Swap memory w,
        Book memory b,
        AmmReplay.Cursor memory c,
        AmmReplay.Step memory s,
        uint256 stepAmount,
        Fill memory f
    ) private pure {
        uint256 before = f.ammShare;
        _search(w, b, c, s, stepAmount, f);
        f.stop = INSIDE;
        (f.specified, f.other) = _cost(w, b, f.frontier);
        if (b.fixedAmount != 0 && _beyond(w, f.frontier, b.fixedPrice)) f.fixedFilled = b.fixedAmount;
        uint256 shortfall = _spend(w, b, f, true);
        if (shortfall == 0) return;
        // Exact output the book could not deliver (its last unit can round away) goes to the AMM.
        uint256 x = f.ammShare - before + shortfall;
        f.ammShare += shortfall;
        if (x > stepAmount) {
            f.stop = BOOK_DONE; // the AMM leaves this step; the PoolManager decides where it lands
            return;
        }
        f.ammLanding = _landing(w, c, s, x);
        f.ammNext = x < stepAmount ? _landing(w, c, s, x + 1) : s.target;
    }

    /// @dev The largest AMM amount x in this step with ammShare + x + book cost to its landing within budget.
    /// Starts from the combined-liquidity guess and gallops out from it, then bisects; the answer is exact
    /// whatever the guess, only the number of probes depends on it.
    function _search(
        Swap memory w,
        Book memory b,
        AmmReplay.Cursor memory c,
        AmmReplay.Step memory s,
        uint256 stepAmount,
        Fill memory f
    ) private pure {
        uint256 lo;
        uint256 hi = stepAmount == 0 ? 0 : stepAmount - 1; // the whole step does not fit
        if (hi != 0) {
            uint256 guess = _guess(w, b, c, s, f.ammShare);
            if (guess > hi) guess = hi;
            if (guess == 0 || _fits(w, b, c, s, f, guess)) {
                lo = guess;
                for (uint256 d = 1;; d <<= 1) {
                    if (d > hi - lo) break;
                    if (!_fits(w, b, c, s, f, lo + d)) {
                        hi = lo + d - 1;
                        break;
                    }
                    lo += d;
                }
            } else {
                hi = guess - 1;
                for (uint256 d = 1;; d <<= 1) {
                    if (d > hi) break;
                    if (_fits(w, b, c, s, f, hi + 1 - d)) {
                        lo = hi + 1 - d;
                        break;
                    }
                    hi -= d;
                }
            }
        }
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (_fits(w, b, c, s, f, mid)) lo = mid;
            else hi = mid - 1;
        }
        if (lo != 0) {
            f.ammLanding = _landing(w, c, s, lo);
            f.frontier = f.ammLanding;
        }
        f.ammNext = lo < stepAmount ? _landing(w, c, s, lo + 1) : s.target;
        f.ammShare += lo;
    }

    function _fits(
        Swap memory w,
        Book memory b,
        AmmReplay.Cursor memory c,
        AmmReplay.Step memory s,
        Fill memory f,
        uint256 x
    ) private pure returns (bool) {
        ++f.iterations;
        (uint256 bookAmount,) = _cost(w, b, _landing(w, c, s, x));
        return f.ammShare + x + bookAmount <= w.budget;
    }

    struct Guess {
        uint256 rest;
        uint160 price;
        bool fixedPaid;
    }

    /// @dev The AMM's share if the remaining budget were spent through this step on AMM and range liquidity
    /// together, paying the fixed level when reached. Exact up to rounding; the search corrects the rest.
    function _guess(Swap memory w, Book memory b, AmmReplay.Cursor memory c, AmmReplay.Step memory s, uint256 used)
        private
        pure
        returns (uint256)
    {
        (uint256 booked,) = _cost(w, b, c.sqrtPriceX96);
        Guess memory g = Guess(
            w.budget - used - booked, c.sqrtPriceX96, b.fixedAmount == 0 || _beyond(w, c.sqrtPriceX96, b.fixedPrice)
        );
        // At most: the fixed level, the range's two ends and the step's end.
        for (uint256 i; i < 5 && g.rest != 0; ++i) {
            if (!_spendGuess(w, b, c, s, g)) break;
        }
        return _ammAmount(w, c, g.price);
    }

    /// @return more Whether the guess reached the next event with budget left.
    function _spendGuess(
        Swap memory w,
        Book memory b,
        AmmReplay.Cursor memory c,
        AmmReplay.Step memory s,
        Guess memory g
    ) private pure returns (bool more) {
        if (!g.fixedPaid && g.price == b.fixedPrice) {
            uint256 fixedAmount = w.exactIn ? _gross(w, b.fixedPrice, b.fixedAmount) : b.fixedAmount;
            if (fixedAmount > g.rest) return false;
            g.rest -= fixedAmount;
            g.fixedPaid = true;
        }
        uint160 e = _nextEvent(w, b, g.price, s.target, g.fixedPaid);
        if (e == g.price) return false;
        (uint160 q, uint256 amountIn, uint256 amountOut, uint256 fee) = SwapMath.computeSwapStep(
            g.price, e, _liquidityBetween(w, b, c, g.price, e), w.exactIn ? -int256(g.rest) : int256(g.rest), w.pool.fee
        );
        g.rest -= w.exactIn ? amountIn + fee : amountOut;
        g.price = q;
        return q == e;
    }

    /// @dev The first of the fixed price, the range's ends and `end` beyond p.
    function _nextEvent(Swap memory w, Book memory b, uint160 p, uint160 end, bool fixedPaid)
        private
        pure
        returns (uint160 e)
    {
        e = end;
        if (!fixedPaid && _beyond(w, b.fixedPrice, p) && _beyond(w, e, b.fixedPrice)) e = b.fixedPrice;
        if (b.rangeLiquidity != 0) {
            if (_beyond(w, b.rangeFrom, p) && _beyond(w, e, b.rangeFrom)) e = b.rangeFrom;
            if (_beyond(w, b.rangeTo, p) && _beyond(w, e, b.rangeTo)) e = b.rangeTo;
        }
    }

    function _liquidityBetween(Swap memory w, Book memory b, AmmReplay.Cursor memory c, uint160 p, uint160 e)
        private
        pure
        returns (uint128)
    {
        uint256 liquidity = c.liquidity;
        if (b.rangeLiquidity != 0 && !_beyond(w, b.rangeFrom, p) && !_beyond(w, e, b.rangeTo)) {
            liquidity += b.rangeLiquidity;
        }
        // The cap only affects the guess; the search keeps the result exact.
        return liquidity > type(uint128).max ? type(uint128).max : uint128(liquidity);
    }

    /// @dev The AMM's amount, in the specified currency, to move from the cursor to p within one step.
    function _ammAmount(Swap memory w, AmmReplay.Cursor memory c, uint160 p) private pure returns (uint256) {
        (, uint256 amountIn, uint256 amountOut, uint256 fee) = SwapMath.computeSwapStep(
            c.sqrtPriceX96, p, c.liquidity, w.exactIn ? AmmReplay.ALL_IN : AmmReplay.ALL_OUT, w.pool.fee
        );
        return w.exactIn ? amountIn + fee : amountOut;
    }

    /// @dev The leftover budget fills book liquidity beyond the AMM landing, at most up to the AMM's next
    /// reachable price. With `keepDust`, exact input the book cannot spend stays with it.
    /// @return shortfall Exact output the book could not deliver.
    function _spend(Swap memory w, Book memory b, Fill memory f, bool keepDust) private pure returns (uint256 shortfall) {
        uint256 left = w.budget - f.ammShare - f.specified;
        uint160 p = f.frontier;
        uint128 fixedLeft = f.fixedFilled == 0 ? b.fixedAmount : 0;
        while (left != 0) {
            if (fixedLeft != 0 && p == b.fixedPrice) {
                (uint128 out, uint256 spec, uint256 other) = _fixedPartial(w, b.fixedPrice, fixedLeft, left);
                if (out == 0) break;
                fixedLeft -= out;
                f.fixedFilled += out;
                f.specified += spec;
                f.other += other;
                left -= spec;
                if (fixedLeft != 0) break;
                continue;
            }
            uint160 stopAt = w.pool.limit;
            if (fixedLeft != 0 && _beyond(w, stopAt, b.fixedPrice)) stopAt = b.fixedPrice;
            if (stopAt == p) break;
            if (b.rangeLiquidity != 0 && !_beyond(w, b.rangeFrom, p) && _beyond(w, b.rangeTo, p)) {
                if (_beyond(w, stopAt, b.rangeTo)) stopAt = b.rangeTo;
                uint160 q;
                (q, left) = _spendRange(w, b, f, p, stopAt, left);
                p = q;
                if (q != stopAt) break;
            } else if (b.rangeLiquidity != 0 && _beyond(w, b.rangeFrom, p) && !_beyond(w, b.rangeFrom, stopAt)) {
                p = b.rangeFrom; // no book liquidity before the range starts
            } else if (fixedLeft != 0 && stopAt == b.fixedPrice) {
                p = b.fixedPrice; // nothing before the fixed price
            } else {
                break;
            }
        }
        f.frontier = p;
        if (!w.exactIn) shortfall = left;
        else if (keepDust) f.specified += left;
    }

    /// @return q Where the range spend stopped.
    /// @return rest The budget left.
    function _spendRange(Swap memory w, Book memory b, Fill memory f, uint160 p, uint160 stopAt, uint256 left)
        private
        pure
        returns (uint160 q, uint256 rest)
    {
        uint256 amountIn;
        uint256 amountOut;
        uint256 fee;
        (q, amountIn, amountOut, fee) =
            SwapMath.computeSwapStep(p, stopAt, b.rangeLiquidity, w.exactIn ? -int256(left) : int256(left), w.pool.fee);
        uint256 spec = w.exactIn ? amountIn + fee : amountOut;
        f.specified += spec;
        f.other += w.exactIn ? amountOut : amountIn + fee;
        rest = left - spec;
    }

    /// @dev Book amounts up to price p, including any catch-up behind the start: the unsold range so far,
    /// and the fixed level once passed.
    function _cost(Swap memory w, Book memory b, uint160 p) private pure returns (uint256 spec, uint256 other) {
        if (b.rangeLiquidity != 0) {
            uint160 from = b.rangeFrom;
            uint160 to = _beyond(w, p, b.rangeTo) ? b.rangeTo : p;
            if (_beyond(w, to, from)) {
                (, uint256 amountIn, uint256 amountOut, uint256 fee) = SwapMath.computeSwapStep(
                    from, to, b.rangeLiquidity, w.exactIn ? AmmReplay.ALL_IN : AmmReplay.ALL_OUT, w.pool.fee
                );
                (spec, other) = w.exactIn ? (amountIn + fee, amountOut) : (amountOut, amountIn + fee);
            }
        }
        if (b.fixedAmount != 0 && _beyond(w, p, b.fixedPrice)) {
            uint256 gross = _gross(w, b.fixedPrice, b.fixedAmount);
            (uint256 s, uint256 o) = w.exactIn ? (gross, uint256(b.fixedAmount)) : (uint256(b.fixedAmount), gross);
            spec += s;
            other += o;
        }
    }

    /// @dev The most of `have` the leftover buys (exact input) or delivers (exact output) at the fixed price.
    function _fixedPartial(Swap memory w, uint160 price, uint128 have, uint256 left)
        private
        pure
        returns (uint128 out, uint256 spec, uint256 other)
    {
        if (!w.exactIn) {
            out = left < have ? uint128(left) : have;
            return (out, out, _gross(w, price, out));
        }
        // Bisect a window around the direct estimate; outside it the whole level.
        uint256 lo;
        uint256 hi = have;
        if (price <= type(uint128).max) {
            uint256 estimate = _outFor(w, price, FullMath.mulDiv(left, PIPS - w.pool.fee, PIPS));
            uint256 slack = _outFor(w, price, 3) + 2;
            if (estimate < hi) {
                if (estimate + slack < hi) hi = estimate + slack;
                if (estimate > slack) lo = estimate - slack;
                if (_gross(w, price, lo) > left) lo = 0;
            }
        }
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (_gross(w, price, mid) <= left) lo = mid;
            else hi = mid - 1;
        }
        out = uint128(lo);
        if (out != 0) (spec, other) = (_gross(w, price, out), out);
    }

    /// @dev Taker currency for `out` at the fixed price, rounded up, plus the fee as v4 rounds it.
    function _gross(Swap memory w, uint160 price, uint256 out) private pure returns (uint256) {
        return fixedCost(w.pool.zeroForOne, price, out, w.pool.fee);
    }

    /// @notice Taker currency for `out` of a fixed order at sqrt price `price`: the price applied once and
    /// rounded up while its square fits 256 bits, otherwise in two rounded-up halves; plus the fee.
    function fixedCost(bool zeroForOne, uint160 price, uint256 out, uint24 fee) internal pure returns (uint256) {
        if (out == 0) return 0;
        if (fee >= PIPS) return type(uint256).max; // nothing is payable at a 100% fee
        uint256 amountIn;
        if (price <= type(uint128).max) {
            uint256 squared = uint256(price) * price;
            amountIn = zeroForOne
                ? FullMath.mulDivRoundingUp(out, Q192, squared)
                : FullMath.mulDivRoundingUp(out, squared, Q192);
        } else {
            amountIn = zeroForOne
                ? FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(out, Q96, price), Q96, price)
                : FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(out, price, Q96), price, Q96);
        }
        return amountIn + FullMath.mulDivRoundingUp(amountIn, fee, PIPS - fee);
    }

    /// @dev Output a taker currency amount buys at a fixed price below 2^128, rounded down and saturating.
    function _outFor(Swap memory w, uint160 price, uint256 amountIn) private pure returns (uint256) {
        uint256 squared = uint256(price) * price;
        if (w.pool.zeroForOne) {
            return amountIn >> 192 != 0 ? type(uint256).max : FullMath.mulDiv(amountIn, squared, Q192);
        }
        return amountIn >> 64 >= squared ? type(uint256).max : FullMath.mulDiv(amountIn, Q192, squared);
    }

    function _landing(Swap memory w, AmmReplay.Cursor memory c, AmmReplay.Step memory s, uint256 x)
        private
        pure
        returns (uint160 p)
    {
        // SwapMath reads a zero amount as exact output; a zero share does not move the AMM.
        if (x == 0) return c.sqrtPriceX96;
        (p,,,) = SwapMath.computeSwapStep(
            c.sqrtPriceX96, s.target, c.liquidity, w.exactIn ? -int256(x) : int256(x), w.pool.fee
        );
    }

    /// @dev The earliest unsold book price, behind the start when catching up.
    function _bookStart(Swap memory w, Book memory b) private pure returns (uint160 p) {
        p = w.start;
        if (b.rangeLiquidity != 0 && _beyond(w, p, b.rangeFrom)) p = b.rangeFrom;
        if (b.fixedAmount != 0 && _beyond(w, p, b.fixedPrice)) p = b.fixedPrice;
    }

    function _exhausted(Swap memory w, Book memory b, uint160 p) private pure returns (bool) {
        bool rangeDone = b.rangeLiquidity == 0 || !_beyond(w, b.rangeTo, p);
        bool fixedDone = b.fixedAmount == 0 || _beyond(w, p, b.fixedPrice);
        return rangeDone && fixedDone;
    }

    function _beyond(Swap memory w, uint160 a, uint160 b) private pure returns (bool) {
        return w.pool.zeroForOne ? a < b : a > b;
    }
}
