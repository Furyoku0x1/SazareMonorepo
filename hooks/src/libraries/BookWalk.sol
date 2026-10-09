// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {AmmReplay} from "./AmmReplay.sol";
import {FixedBook} from "./FixedBook.sol";
import {RangeBook} from "./RangeBook.sol";

/// @notice The swap walk over a pool's order book. It sizes the book's share of a swap against the AMM so that the
/// PoolManager's swap of the rest lands exactly where the walk expects; fixed orders fill FIFO at their ticks and
/// range orders by price; the walk stops where the request is met. `plan` only reads, so a quote is the same code
/// as a swap; `commit` applies a plan.
/// @dev Generalizes the Phase 0 `SliceWalk` (one range, one fixed price) to the stored books. Book points (range
/// boundaries and stops, fixed-order ticks, edges of searched bitmap words) split the walk into segments of
/// constant range liquidity, with fixed lots at their starts. The AMM's cost is always one `SwapMath` step from
/// the AMM step's start to its own target, never split at book points, so its landing is the PoolManager's.
/// Prices are sqrt prices; "beyond" follows the swap's direction. A zeroForOne swap fills bids (side 1, walking
/// down); a oneForZero swap fills asks (side 0, walking up).
library BookWalk {
    using TickBitmap for mapping(int16 => uint256);

    uint256 internal constant PIPS = 1_000_000;
    /// @dev Book points along one walk stay below this, so the hook's int128 deltas fit.
    uint256 internal constant MAX_BOOK_AMOUNT = 1 << 126;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant Q192 = 1 << 192;

    /// @dev The request ran out: inside an AMM step, at its end, or in the book.
    uint8 internal constant INSIDE = 0;
    /// @dev No book liquidity is left ahead; the AMM takes the rest.
    uint8 internal constant BOOK_DONE = 1;
    /// @dev The swap's price limit.
    uint8 internal constant LIMIT = 2;
    /// @dev A deterministic limit (AMM steps, book points, chunks per price, amounts): the book stops, the AMM goes on.
    uint8 internal constant CAP = 3;
    /// @dev The gas guard stopped the walk; quotes, which pass no guard, cannot reproduce this.
    uint8 internal constant GAS = 4;

    uint8 private constant STEP_TAKEN = 0;
    uint8 private constant STEP_FINISHED = 1;
    uint8 private constant STEP_EXACT = 2;

    /// @notice A pool's book: the storage root the book's libraries share.
    struct PoolBook {
        FixedBook.Book fixedOrders;
        RangeBook.Book ranges;
        /// @dev Per side ([0] asks, [1] bids): no unfilled liquidity of the side lies before it. Set to where each
        /// walk ends, pulled back by orders placed before it; 0 until the side's first order.
        uint160[2] start;
        /// @dev Per side: no order of the side has ever reached beyond it, so searches stop there; 0 before any order.
        uint160[2] extent;
    }

    struct Limits {
        uint256 ammSteps; // AMM steps the walk replays
        uint256 bookPoints; // book points it loads: events and searched word edges
        uint256 words; // bitmap words per search, at least 1
        uint256 chunks; // chunks per fixed price
    }

    struct Request {
        AmmReplay.Pool pool; // fee: the swap's fee rate, LP and protocol combined
        bool exactIn;
        uint256 budget; // the specified amount still to trade, above zero
        uint256 lotSize; // output currency per fixed-order lot
        Limits limits;
        uint256 minGas; // gas guard; 0 for quotes
    }

    /// @notice What the book trades with the taker.
    struct Fill {
        uint256 specified; // book totals from the taker's view; exact-input dust the book keeps is included
        uint256 other;
        uint256 principal; // input to makers, rounded up per piece, without the taker fee
        uint256 takerFee; // the pool-rate fee on the book's fills, input currency
        uint256 dust; // exact input the book kept without trading it, where the AMM had no liquidity
        uint256 ammShare; // the specified amount the walk sized for the AMM (the PoolManager swaps the rest)
        uint160 frontier; // the book filled everything before this price, and `Plan.frontierLots` at it
        uint8 stop;
        uint256 probes; // AMM landings the search computed
        uint256 points; // book points loaded
    }

    /// @dev The book's amounts in the input and output currencies.
    struct Amounts {
        uint256 principal; // input to makers, rounded up
        uint256 fee; // the taker fee on it
        uint256 out; // output from makers, rounded down
        uint256 rangePrincipal; // the range part of `principal`
        uint256 rangeMakerFee; // range maker fees on it, rounded down
    }

    /// @dev Book liquidity from `price` to the next segment.
    struct Seg {
        uint160 price;
        uint256 liquidity; // range liquidity
        uint256 feeLiquidity;
        uint256 m; // the range cursor's stop index here
        uint256 lots; // fixed lots available exactly at `price`
        bool complete; // `lots` is the whole level, so the walk may pass it
        Amounts level; // a whole fill of `lots`
        Amounts before; // the book from the walk's start up to `price`, the level at `price` excluded
    }

    struct Plan {
        Fill fill;
        Amounts total;
        Seg[] segs;
        uint256 count;
        int24[] dead; // dead range boundaries crossed, cleared on commit
        uint256 deadCount;
        uint160 position; // where the book's fills end (beyond `fill.frontier` only past the book's end)
        uint160 levelPrice; // the price of `frontierLots` (0 if none)
        uint256 frontierLots; // lots filled exactly at `position`
        Amounts frontierLevel;
        uint256 side;
        bool down;
        // Loading: the next range point and fixed point, each found from where its own search stands.
        RangeBook.Cursor rc;
        uint160 rangePoint;
        bool rangeFound;
        int24 fixedTick; // fixed ticks strictly beyond it lie ahead (walking down: at or below it)
        uint160 fixedPoint;
        bool fixedFound;
        uint160 end; // the book cannot fill beyond this price; 0 while open
        uint160 bound; // searches stop here: the nearer of the limit and the side's extent
        uint160 reach; // the book's spending crosses empty space no further: the AMM's next reachable price
        Amounts ahead; // the book from the walk's start through the last segment, up to the next point
    }

    // ---------------------------------------------------------------- entry points

    /// @notice Records a new order's prices: pulls its side's start back to the order's near end (an ask's lower
    /// price, a bid's upper price) and its extent out to the far end. A fixed order's ends are its price.
    function noteOrder(PoolBook storage b, bool sell0, uint160 near, uint160 far) internal {
        uint256 side = sell0 ? 0 : 1;
        uint160 current = b.start[side];
        if (current == 0 || (sell0 ? near < current : near > current)) b.start[side] = near;
        current = b.extent[side];
        if (current == 0 || (sell0 ? far > current : far < current)) b.extent[side] = far;
    }

    /// @notice Plans a swap's book fills without writing.
    function plan(PoolBook storage b, Request memory r) internal view returns (Plan memory p) {
        AmmReplay.Cursor memory c = AmmReplay.load(r.pool);
        p.side = r.pool.zeroForOne ? 1 : 0;
        p.down = r.pool.zeroForOne;
        uint160 ammStart = c.sqrtPriceX96;
        uint160 s0 = b.start[p.side];
        if (s0 == 0 || _beyond(p, s0, ammStart)) s0 = ammStart;
        p.fill.frontier = s0;
        p.position = s0;
        // A 100% fee leaves nothing to price the book against; the AMM takes the swap.
        if (r.pool.fee >= PIPS) {
            p.fill.stop = BOOK_DONE;
            return p;
        }
        if (_lowGas(r)) {
            p.fill.stop = GAS;
            return p;
        }
        _begin(p, b, r, s0);
        p.fill.frontier = ammStart;
        // Catch-up: book liquidity priced better than the pool fills first. When it covers the whole request, the
        // book fills it in price order, stopping where the request is met, and the AMM is not touched.
        if (_beyond(p, ammStart, s0)) {
            _loadThrough(p, b, r, ammStart);
            if (_spec(r, _cost(p, r, ammStart)) >= r.budget) {
                p.fill.stop = INSIDE;
                p.fill.frontier = s0;
                p.reach = ammStart;
                uint256 left = _rest(p, r, c, _spend(p, b, r));
                if (left != 0) {
                    p.fill.ammShare = left; // below a lot, or rounding: the PoolManager decides where it lands
                    p.fill.stop = BOOK_DONE;
                }
                return _finish(p, r);
            }
        }
        _walkAmm(p, b, r, c);
        return _finish(p, r);
    }

    /// @notice Applies a plan: fills the fixed levels it passed, clears the dead boundaries it found, records the
    /// range stop when range liquidity sold, and moves the side's start to the frontier.
    /// @return makerFee Maker fees on the fills, rounded down, in the input currency.
    function commit(PoolBook storage b, Request memory r, Plan memory p) internal returns (uint256 makerFee) {
        if (p.count == 0) {
            b.start[p.side] = p.fill.frontier; // the walk's start: at or before the old one
            return 0;
        }
        RangeBook.Side storage rs = b.ranges.sides[p.side];
        for (uint256 i; i < p.deadCount; ++i) {
            RangeBook.clearDead(rs, p.dead[i]);
        }
        makerFee = p.total.rangeMakerFee + _takeLevels(b.fixedOrders.sides[p.side], r, p);
        uint160 frontier = p.fill.frontier;
        if (p.total.rangePrincipal != 0) {
            Seg memory s = p.segs[_segAt(p, frontier)];
            RangeBook.record(rs, RangeBook.Cursor(p.down, frontier, 0, s.liquidity, s.feeLiquidity, s.m));
        }
        b.start[p.side] = frontier;
    }

    // ---------------------------------------------------------------- the walk

    function _walkAmm(Plan memory p, PoolBook storage b, Request memory r, AmmReplay.Cursor memory c) private view {
        uint256 steps;
        while (true) {
            if (_lowGas(r)) {
                p.fill.stop = GAS;
                break;
            }
            if (_exhausted(p, r, c.sqrtPriceX96)) {
                p.fill.stop = p.end != 0 ? CAP : BOOK_DONE;
                break;
            }
            if (c.sqrtPriceX96 == r.pool.limit) {
                p.fill.stop = LIMIT;
                break;
            }
            if (steps++ == r.limits.ammSteps) {
                p.fill.stop = CAP;
                break;
            }
            uint8 outcome = _step(p, b, r, c);
            if (outcome == STEP_TAKEN) continue;
            if (outcome == STEP_FINISHED) return;
            break; // spent exactly at the step's end
        }
        p.total = _cost(p, r, p.fill.frontier);
        // Fixed orders exactly at the price limit are reachable; the taker keeps what is left.
        if (p.fill.stop == LIMIT) {
            p.reach = r.pool.limit;
            _spend(p, b, r);
        }
    }

    /// @dev One AMM step: take it whole if it fits, else finish the walk inside it.
    function _step(Plan memory p, PoolBook storage b, Request memory r, AmmReplay.Cursor memory c)
        private
        view
        returns (uint8)
    {
        AmmReplay.Step memory s = AmmReplay.next(r.pool, c);
        uint256 stepAmount = _ammAmount(r, c, s.target);
        // Book points load only as far as needed: when the AMM's step alone overshoots, the search loads up to the
        // landings it tries.
        uint256 total = p.fill.ammShare + stepAmount + _spec(r, _cost(p, r, c.sqrtPriceX96));
        if (r.exactIn ? total <= r.budget : total < r.budget) {
            _loadThrough(p, b, r, s.target);
            total = p.fill.ammShare + stepAmount + _spec(r, _cost(p, r, s.target));
        }
        // Exact output takes a step whole only while it stays short of the request; a step that would meet it exactly
        // goes through the search, which stops where the request is met rather than charging for liquidity whose
        // output rounds to zero.
        if (r.exactIn ? total > r.budget : total >= r.budget) {
            _finishInside(p, b, r, c, s, stepAmount);
            return STEP_FINISHED;
        }
        p.fill.ammShare += stepAmount;
        AmmReplay.move(r.pool, c, s, s.target);
        p.fill.frontier = s.target;
        if (total != r.budget) return STEP_TAKEN;
        // Spent exactly: stop here rather than walk on through empty steps.
        p.fill.stop = INSIDE;
        return STEP_EXACT;
    }

    /// @dev The request runs out inside this step: size the AMM's share, then spend the rest on the book.
    function _finishInside(
        Plan memory p,
        PoolBook storage b,
        Request memory r,
        AmmReplay.Cursor memory c,
        AmmReplay.Step memory s,
        uint256 stepAmount
    ) private view {
        uint256 before = p.fill.ammShare;
        _search(p, b, r, c, s, stepAmount);
        p.fill.stop = INSIDE;
        p.total = _cost(p, r, p.fill.frontier);
        uint256 left = _rest(p, r, c, _spend(p, b, r));
        if (left == 0) return;
        // What the book could not trade goes to the AMM (see `_rest`).
        p.fill.ammShare += left;
        if (p.end != 0 && p.fill.frontier == p.end) p.fill.stop = CAP; // the book stopped at a limit; the AMM goes on
        else if (p.fill.ammShare - before > stepAmount) p.fill.stop = BOOK_DONE; // the PoolManager decides where it lands
    }

    /// @dev The largest AMM amount x in this step with ammShare + x + the book's cost to its landing within the
    /// request. Starts from the combined-liquidity guess and gallops out from it, then bisects; the answer is exact
    /// whatever the guess, only the number of probes depends on it.
    function _search(
        Plan memory p,
        PoolBook storage b,
        Request memory r,
        AmmReplay.Cursor memory c,
        AmmReplay.Step memory s,
        uint256 stepAmount
    ) private view {
        uint256 lo;
        uint256 hi = stepAmount == 0 ? 0 : stepAmount - 1; // the whole step does not fit
        if (hi != 0) {
            uint256 guess = _guess(p, b, r, c, s);
            if (guess > hi) guess = hi;
            if (guess == 0 || _fits(p, b, r, c, s, guess)) {
                lo = guess;
                for (uint256 d = 1;; d <<= 1) {
                    if (d > hi - lo) break;
                    if (!_fits(p, b, r, c, s, lo + d)) {
                        hi = lo + d - 1;
                        break;
                    }
                    lo += d;
                }
            } else {
                hi = guess - 1;
                for (uint256 d = 1;; d <<= 1) {
                    if (d > hi) break;
                    if (_fits(p, b, r, c, s, hi + 1 - d)) {
                        lo = hi + 1 - d;
                        break;
                    }
                    hi -= d;
                }
            }
        }
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (_fits(p, b, r, c, s, mid)) lo = mid;
            else hi = mid - 1;
        }
        if (lo != 0) p.fill.frontier = _landing(r, c, s, lo);
        p.reach = lo < stepAmount ? _landing(r, c, s, lo + 1) : s.target;
        p.fill.ammShare += lo;
    }

    function _fits(
        Plan memory p,
        PoolBook storage b,
        Request memory r,
        AmmReplay.Cursor memory c,
        AmmReplay.Step memory s,
        uint256 x
    ) private view returns (bool) {
        ++p.fill.probes;
        uint160 landing = _landing(r, c, s, x);
        _loadThrough(p, b, r, landing);
        return p.fill.ammShare + x + _spec(r, _cost(p, r, landing)) <= r.budget;
    }

    struct Guess {
        uint256 rest;
        uint160 price;
        uint256 j;
        bool levelPaid;
    }

    /// @dev The AMM's share if the rest were spent through this step on AMM and range liquidity together, paying
    /// fixed levels when reached. Exact up to rounding; the search corrects the rest.
    function _guess(
        Plan memory p,
        PoolBook storage b,
        Request memory r,
        AmmReplay.Cursor memory c,
        AmmReplay.Step memory s
    ) private view returns (uint256) {
        Guess memory g;
        g.price = c.sqrtPriceX96;
        g.rest = r.budget - p.fill.ammShare - _spec(r, _cost(p, r, g.price));
        g.j = _segAt(p, g.price);
        g.levelPaid = g.price != p.segs[g.j].price;
        for (uint256 i; i < 16 && g.rest != 0; ++i) {
            if (!_guessStep(p, b, r, c, s, g)) break;
        }
        return _ammAmount(r, c, g.price);
    }

    /// @return more Whether the guess reached the next book point with some of the request left.
    function _guessStep(
        Plan memory p,
        PoolBook storage b,
        Request memory r,
        AmmReplay.Cursor memory c,
        AmmReplay.Step memory s,
        Guess memory g
    ) private view returns (bool more) {
        Seg memory seg = p.segs[g.j];
        if (g.price == seg.price && !g.levelPaid) {
            g.levelPaid = true;
            uint256 level = _spec(r, seg.level);
            if (level >= g.rest) return false; // nothing left for a SwapMath step, which reads zero as exact output
            g.rest -= level;
        }
        // The next point: loaded, or the one the last search found, loaded only once the guess reaches it.
        bool loaded = g.j + 1 < p.count;
        uint160 e = loaded ? p.segs[g.j + 1].price : _hasPending(p, r) ? _nextPoint(p) : s.target;
        bool last = _beyond(p, e, s.target);
        if (last) e = s.target;
        if (e == g.price) return false;
        uint160 q = _combinedStep(r, g, e, c.liquidity + (p.end != 0 && seg.price == p.end ? 0 : seg.liquidity));
        if (q != e || last || (!loaded && !_hasPending(p, r))) return false;
        if (!loaded && !_materialize(p, b, r)) return false;
        ++g.j;
        g.levelPaid = false;
        return true;
    }

    /// @dev Spends the guess's rest on AMM and range liquidity together toward e.
    function _combinedStep(Request memory r, Guess memory g, uint160 e, uint256 liquidity)
        private
        pure
        returns (uint160 q)
    {
        // The cap only affects the guess; the search keeps the result exact.
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;
        uint256 amountIn;
        uint256 amountOut;
        uint256 fee;
        (q, amountIn, amountOut, fee) = SwapMath.computeSwapStep(
            g.price, e, uint128(liquidity), r.exactIn ? -int256(g.rest) : int256(g.rest), r.pool.fee
        );
        g.rest -= r.exactIn ? amountIn + fee : amountOut;
        g.price = q;
    }

    /// @dev The rest of the request fills book liquidity from the frontier on, in price order: a fixed level at the
    /// frontier (in whole lots), then range liquidity, across later points while it lasts.
    /// @return left What the book could not trade, in the specified currency.
    function _spend(Plan memory p, PoolBook storage b, Request memory r) private view returns (uint256 left) {
        left = r.budget - p.fill.ammShare - _spec(r, p.total);
        uint160 x = p.fill.frontier;
        uint256 j = _segAt(p, x);
        bool levelDone = x != p.segs[j].price;
        while (left != 0) {
            if (!levelDone) {
                levelDone = true;
                bool stop;
                (left, stop) = _spendLevel(p, r, j, left);
                // A zero amount would read as exact output in SwapMath.
                if (stop || left == 0) break;
            }
            (uint160 e, bool open) = _spendBound(p, b, r, j, x);
            if (!open) break;
            uint160 q = e; // no book liquidity before the next point
            if (p.segs[j].liquidity != 0) (q, left) = _spendRange(p, r, j, x, e, left);
            else if (_beyond(p, e, p.reach)) break; // what is left is dust: worth less than the AMM's next unit
            x = q;
            if (q != e) break;
            if (j + 1 == p.count) break; // the limit
            ++j;
            levelDone = false;
        }
        p.fill.frontier = x;
    }

    /// @dev What the book could not trade, for the AMM: exact output it could not deliver (its last unit can round
    /// away, or a lot is larger than what is left), and exact input it could not use (less than a lot's cost, or worth
    /// less than the AMM's next unit), which the AMM trades from where it stands. Where the AMM finds no liquidity
    /// toward the limit, exact input stays with the book as dust: the AMM would trade none of it and only run the
    /// price to the limit.
    /// ponytail: the dust is below one lot's cost at the book's frontier, so book-only pools want small lots.
    function _rest(Plan memory p, Request memory r, AmmReplay.Cursor memory c, uint256 left)
        private
        view
        returns (uint256)
    {
        if (left == 0 || !r.exactIn || _ammTrades(r, c)) return left;
        p.fill.dust += left;
        return 0;
    }

    /// @dev Whether the AMM, from the cursor toward the limit, reaches a step that moves the price with liquidity,
    /// crossing at most a search's worth (`limits.words`) of empty steps or ticks first, so exact input handed to it
    /// trades.
    /// ponytail: liquidity further out than that counts as none; the input it would buy there is worth little at that
    /// distance.
    function _ammTrades(Request memory r, AmmReplay.Cursor memory c) private view returns (bool) {
        AmmReplay.Cursor memory probe = AmmReplay.Cursor(c.sqrtPriceX96, c.tick, c.liquidity);
        for (uint256 i; i <= r.limits.words; ++i) {
            if (probe.sqrtPriceX96 == r.pool.limit) return false;
            AmmReplay.Step memory s = AmmReplay.next(r.pool, probe);
            if (probe.liquidity != 0 && s.target != probe.sqrtPriceX96) return true;
            AmmReplay.move(r.pool, probe, s, s.target); // an empty step, or a crossing where the price stands
        }
        return false;
    }

    /// @dev Fills segment j's range liquidity from x toward e with what is left.
    function _spendRange(Plan memory p, Request memory r, uint256 j, uint160 x, uint160 e, uint256 left)
        private
        pure
        returns (uint160 q, uint256 rest)
    {
        Amounts memory a;
        (q, a) = _rangePartial(r, x, e, p.segs[j], left);
        _addTo(p.total, a);
        rest = left - _spec(r, a);
    }

    /// @dev Fills the fixed level of segment j, at its price, with what is left.
    /// @return rest What is left after it.
    /// @return stop Whether the walk ends here: the level is not used up, or cannot be passed.
    function _spendLevel(Plan memory p, Request memory r, uint256 j, uint256 left)
        private
        pure
        returns (uint256 rest, bool stop)
    {
        Seg memory s = p.segs[j];
        rest = left;
        if (s.lots != 0) {
            (uint256 t, Amounts memory a) = _fixedPartial(p, r, s, left);
            if (t == 0) return (rest, true);
            (p.levelPrice, p.frontierLots, p.frontierLevel) = (s.price, t, a);
            _addTo(p.total, a);
            rest -= _spec(r, a);
            if (t < s.lots) return (rest, true);
        }
        stop = !s.complete;
    }

    /// @dev The next point the book's spending may reach from x in segment j.
    /// @return e The point: the next segment, or the limit when nothing more lies ahead.
    /// @return open Whether the book may go on: false at the book's end, at the limit, or with only empty space ahead.
    function _spendBound(Plan memory p, PoolBook storage b, Request memory r, uint256 j, uint160 x)
        private
        view
        returns (uint160 e, bool open)
    {
        Seg memory s = p.segs[j];
        if ((p.end != 0 && s.price == p.end) || x == r.pool.limit || x == p.bound) return (x, false);
        if (j + 1 == p.count && s.liquidity == 0 && _beyond(p, _nextPoint(p), p.reach)) return (x, false); // dust
        if (j + 1 < p.count || (_hasPending(p, r) && _materialize(p, b, r))) return (p.segs[j + 1].price, true);
        // Nothing more ahead: range liquidity, if any, runs to the limit; the book ends at its last point otherwise.
        if (p.end != 0 || s.liquidity == 0) return (x, false);
        return (p.bound, true);
    }

    function _finish(Plan memory p, Request memory r) private pure returns (Plan memory) {
        Amounts memory t = p.total;
        uint256 input = t.principal + t.fee + p.fill.dust;
        (p.fill.specified, p.fill.other) = r.exactIn ? (input, t.out) : (t.out, input);
        p.fill.principal = t.principal;
        p.fill.takerFee = t.fee;
        p.fill.points = p.count;
        p.position = p.fill.frontier;
        if (p.end != 0 && _beyond(p, p.fill.frontier, p.end)) {
            // The AMM went on past where the book had to stop.
            p.fill.frontier = p.end;
            p.fill.stop = CAP;
        }
        return p;
    }

    /// @dev Takes every fixed level the plan passed, and the lots it filled at its last position.
    function _takeLevels(FixedBook.Side storage fs, Request memory r, Plan memory p)
        private
        returns (uint256 makerFee)
    {
        for (uint256 k; k < p.count; ++k) {
            Seg memory s = p.segs[k];
            if (_beyond(p, s.price, p.position)) break;
            (uint256 lots, Amounts memory a) = s.price == p.position
                ? (p.levelPrice == s.price ? p.frontierLots : 0, p.frontierLevel)
                : (s.lots, s.level);
            // A level the chunk limit cut short still moves past its emptied chunks, so later walks progress.
            if (lots == 0 && s.complete) continue;
            (uint256 taken, uint256 feeWeighted) =
                FixedBook.take(fs, TickMath.getTickAtSqrtPrice(s.price), lots, r.limits.chunks);
            assert(taken == lots); // `available` sized the plan with the same chunk limit
            if (lots != 0) makerFee += FullMath.mulDiv(a.principal, feeWeighted, lots * PIPS);
        }
    }

    // ---------------------------------------------------------------- book loading

    /// @dev Starts both searches at the walk's start and makes the first segment there.
    function _begin(Plan memory p, PoolBook storage b, Request memory r, uint160 s0) private view {
        p.segs = _segArray(r.limits.bookPoints + 1);
        p.dead = new int24[](r.limits.bookPoints + 1);
        uint160 extent = b.extent[p.side];
        p.bound = r.pool.limit;
        if (extent == 0 || !_beyond(p, extent, s0)) p.bound = s0; // nothing lies ahead
        else if (_beyond(p, p.bound, extent)) p.bound = extent;
        bool dead;
        (p.rc, dead) = RangeBook.begin(b.ranges.sides[p.side], p.down, s0);
        int24 tick = TickMath.getTickAtSqrtPrice(s0);
        if (dead) p.dead[p.deadCount++] = tick;
        Seg memory s;
        p.segs[0] = s;
        s.price = s0;
        s.complete = true;
        bool exact = TickMath.getSqrtPriceAtTick(tick) == s0;
        if (exact) _loadLevel(p, b, r, s, tick);
        p.fixedTick = exact && p.down ? tick - 1 : tick;
        _snapshot(p, s);
        p.count = 1;
        (p.rangePoint, p.rangeFound) = RangeBook.next(b.ranges.sides[p.side], p.rc, p.bound, r.limits.words);
        _searchFixed(p, b, r);
        _ahead(p, r);
    }

    /// @dev An array of n segment pointers, each assigned when its segment is made: segments are allocated only
    /// as the walk loads them.
    function _segArray(uint256 n) private pure returns (Seg[] memory segs) {
        assembly ("memory-safe") {
            segs := mload(0x40)
            mstore(segs, n)
            mstore(0x40, add(segs, shl(5, add(n, 1))))
        }
    }

    /// @dev Loads book points up to `bound`.
    function _loadThrough(Plan memory p, PoolBook storage b, Request memory r, uint160 bound) private view {
        while (_hasPending(p, r) && !_beyond(p, _nextPoint(p), bound)) {
            if (!_materialize(p, b, r)) return;
        }
    }

    /// @dev Makes the next segment at the nearer of the next range point and the next fixed point.
    /// @return Whether it did; if not, the book ends at the last segment.
    function _materialize(Plan memory p, PoolBook storage b, Request memory r) private view returns (bool) {
        if (p.end != 0) return false;
        Seg memory prev = p.segs[p.count - 1];
        uint160 x = _nextPoint(p);
        // The book cannot load more points than its limit; `_ahead` kept its amounts within theirs.
        if (p.count == p.segs.length) {
            p.end = prev.price;
            return false;
        }
        Seg memory s;
        p.segs[p.count] = s;
        s.price = x;
        s.before = p.ahead;
        s.complete = true;
        if (x == p.rangePoint) {
            RangeBook.Side storage rs = b.ranges.sides[p.side];
            if (RangeBook.cross(rs, p.rc, x)) p.dead[p.deadCount++] = TickMath.getTickAtSqrtPrice(x);
            // Range liquidity beyond one SwapMath step (or a stop's G): the book ends before this point.
            if (p.rc.liquidity > type(uint128).max) {
                p.end = prev.price;
                return false;
            }
            (p.rangePoint, p.rangeFound) = RangeBook.next(rs, p.rc, p.bound, r.limits.words);
        }
        if (x == p.fixedPoint) {
            int24 tick = TickMath.getTickAtSqrtPrice(x); // a fixed point is always a tick's price
            if (p.fixedFound) _loadLevel(p, b, r, s, tick);
            p.fixedTick = p.down ? tick - 1 : tick;
            _searchFixed(p, b, r);
        }
        _snapshot(p, s);
        ++p.count;
        _ahead(p, r);
        return true;
    }

    /// @dev The book's amounts through the last segment's range liquidity up to the next point, beyond which the walk
    /// computes none before loading that point. The book ends at the segment if they would exceed the amount bound.
    /// ponytail: it ends at the segment's start, not inside it; filling up to the bound would let such a stretch fill
    /// over several swaps.
    function _ahead(Plan memory p, Request memory r) private pure {
        if (p.end != 0) return;
        Seg memory s = p.segs[p.count - 1];
        Amounts memory a = _sum(s.before, s.level);
        if (s.liquidity != 0) _addTo(a, _rangeAll(r, s.price, _nextPoint(p), s));
        p.ahead = a;
        if (a.principal + a.fee > MAX_BOOK_AMOUNT || a.out > MAX_BOOK_AMOUNT) p.end = s.price;
    }

    /// @dev Records the range cursor in a new segment. The book ends at a segment it cannot pass: a level it cannot
    /// fill whole, or range liquidity too large for one SwapMath step.
    function _snapshot(Plan memory p, Seg memory s) private pure {
        s.liquidity = p.rc.liquidity;
        s.feeLiquidity = p.rc.feeLiquidity;
        s.m = p.rc.m;
        // At the walk's start such liquidity sells nothing: the book ends at once, with no stop to record.
        if (!s.complete || s.liquidity > type(uint128).max) p.end = s.price;
    }

    /// @dev The fixed lots available at a tick within the chunk limit, and their whole fill. A level whose whole
    /// fill would not fit the book's amounts is left unfillable.
    /// @dev A level whose whole fill would take the book's totals past its amounts is left unfillable, as is one the
    /// chunk limit cuts short: the book ends there, and the next walk starts there.
    function _loadLevel(Plan memory p, PoolBook storage b, Request memory r, Seg memory s, int24 tick) private view {
        (uint256 lots, bool complete) = FixedBook.available(b.fixedOrders.sides[p.side], tick, r.limits.chunks);
        s.complete = complete;
        if (lots == 0) return;
        Amounts memory before = s.before;
        uint256 room = MAX_BOOK_AMOUNT - before.out;
        if (before.out <= MAX_BOOK_AMOUNT && lots <= room / r.lotSize) {
            Amounts memory a = _fixedAmounts(p, r, s.price, lots * r.lotSize);
            // `_fixedAmounts` leaves the fee unset when the principal alone is too large.
            if (a.fee != type(uint256).max && before.principal + before.fee + a.principal + a.fee <= MAX_BOOK_AMOUNT) {
                (s.lots, s.level) = (lots, a);
                return;
            }
        }
        s.complete = false;
    }

    function _searchFixed(Plan memory p, PoolBook storage b, Request memory r) private view {
        mapping(int16 => uint256) storage bitmap = b.fixedOrders.sides[p.side].bitmap;
        uint160 bound = p.bound;
        (p.fixedPoint, p.fixedFound) = (bound, false);
        int24 searched = p.fixedTick;
        for (uint256 i; i < r.limits.words; ++i) {
            (int24 t, bool initialized) = bitmap.nextInitializedTickWithinOneWord(searched, 1, p.down);
            if (t < TickMath.MIN_TICK || t > TickMath.MAX_TICK) return;
            uint160 price = TickMath.getSqrtPriceAtTick(t);
            if (_beyond(p, price, bound)) return;
            if (initialized || i + 1 == r.limits.words) {
                (p.fixedPoint, p.fixedFound) = (price, initialized); // searched up to here
                return;
            }
            searched = p.down ? t - 1 : t;
        }
    }

    function _nextPoint(Plan memory p) private pure returns (uint160) {
        return _beyond(p, p.rangePoint, p.fixedPoint) ? p.fixedPoint : p.rangePoint;
    }

    /// @dev Whether a book point lies ahead before or at the limit. Searches that reached the limit empty-handed
    /// leave none.
    function _hasPending(Plan memory p, Request memory r) private pure returns (bool) {
        if (p.end != 0) return false;
        return _nextPoint(p) != p.bound || p.rangeFound || p.fixedFound;
    }

    /// @dev Whether the book has nothing left to fill at or beyond `price`.
    function _exhausted(Plan memory p, Request memory r, uint160 price) private pure returns (bool) {
        Seg memory s = p.segs[p.count - 1];
        if (p.end != 0) return _beyond(p, price, p.end) || (price == p.end && s.lots == 0);
        if (_hasPending(p, r)) return false;
        return s.liquidity == 0 && (s.lots == 0 || _beyond(p, price, s.price));
    }

    // ---------------------------------------------------------------- amounts

    /// @dev The book's amounts from the walk's start up to `x`; the level exactly at `x` is excluded. Points must
    /// be loaded through `x`.
    function _cost(Plan memory p, Request memory r, uint160 x) private pure returns (Amounts memory a) {
        Seg memory s = p.segs[_segAt(p, x)];
        a = _sum(s.before, _zero());
        if (x == s.price) return a;
        _addTo(a, s.level);
        // Beyond the book's end the AMM goes on alone.
        if (s.liquidity != 0 && !(p.end != 0 && s.price == p.end)) _addTo(a, _rangeAll(r, s.price, x, s));
    }

    /// @dev Range liquidity of segment `s` traded from `from` to `to` in full.
    function _rangeAll(Request memory r, uint160 from, uint160 to, Seg memory s)
        private
        pure
        returns (Amounts memory a)
    {
        (, uint256 amountIn, uint256 amountOut, uint256 fee) = SwapMath.computeSwapStep(
            from, to, uint128(s.liquidity), r.exactIn ? AmmReplay.ALL_IN : AmmReplay.ALL_OUT, r.pool.fee
        );
        return _rangeAmounts(amountIn, fee, amountOut, s);
    }

    /// @dev Range liquidity of segment `s` traded from `from` toward `to` with `left` of the request.
    function _rangePartial(Request memory r, uint160 from, uint160 to, Seg memory s, uint256 left)
        private
        pure
        returns (uint160 q, Amounts memory a)
    {
        uint256 amountIn;
        uint256 amountOut;
        uint256 fee;
        (q, amountIn, amountOut, fee) = SwapMath.computeSwapStep(
            from, to, uint128(s.liquidity), r.exactIn ? -int256(left) : int256(left), r.pool.fee
        );
        a = _rangeAmounts(amountIn, fee, amountOut, s);
    }

    function _rangeAmounts(uint256 amountIn, uint256 fee, uint256 amountOut, Seg memory s)
        private
        pure
        returns (Amounts memory a)
    {
        a.principal = amountIn;
        a.fee = fee;
        a.out = amountOut;
        a.rangePrincipal = amountIn;
        // Each range's share of the principal is proportional to its liquidity, so its maker fee is the principal
        // weighted by the fee-weighted liquidity.
        a.rangeMakerFee = FullMath.mulDiv(amountIn, s.feeLiquidity, s.liquidity * PIPS);
    }

    /// @dev The most whole lots of a level that `left` buys (exact input) or asks for (exact output).
    function _fixedPartial(Plan memory p, Request memory r, Seg memory s, uint256 left)
        private
        pure
        returns (uint256 t, Amounts memory a)
    {
        if (!r.exactIn) {
            t = left / r.lotSize;
            if (t >= s.lots) return (s.lots, s.level);
            if (t != 0) a = _fixedAmounts(p, r, s.price, t * r.lotSize);
            return (t, a);
        }
        if (_spec(r, s.level) <= left) return (s.lots, s.level);
        // The cost grows with the lots: gallop from the direct estimate, then bisect.
        uint256 lo;
        uint256 hi = s.lots - 1;
        uint256 guess = FullMath.mulDiv(s.lots, left, _spec(r, s.level));
        if (guess > hi) guess = hi;
        if (guess == 0 || _lotsFit(p, r, s.price, guess, left)) {
            lo = guess;
            for (uint256 d = 1;; d <<= 1) {
                if (d > hi - lo) break;
                if (!_lotsFit(p, r, s.price, lo + d, left)) {
                    hi = lo + d - 1;
                    break;
                }
                lo += d;
            }
        } else {
            hi = guess - 1;
            for (uint256 d = 1;; d <<= 1) {
                if (d > hi) break;
                if (_lotsFit(p, r, s.price, hi + 1 - d, left)) {
                    lo = hi + 1 - d;
                    break;
                }
                hi -= d;
            }
        }
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (_lotsFit(p, r, s.price, mid, left)) lo = mid;
            else hi = mid - 1;
        }
        t = lo;
        if (t != 0) a = _fixedAmounts(p, r, s.price, t * r.lotSize);
    }

    function _lotsFit(Plan memory p, Request memory r, uint160 price, uint256 lots, uint256 left)
        private
        pure
        returns (bool)
    {
        return _spec(r, _fixedAmounts(p, r, price, lots * r.lotSize)) <= left;
    }

    /// @dev `out` of a fixed level at sqrt price `price`: the taker's principal rounded up (the price applied once
    /// while its square fits 256 bits, otherwise in two rounded-up halves), and the fee as v4 rounds it.
    function _fixedAmounts(Plan memory p, Request memory r, uint160 price, uint256 out)
        private
        pure
        returns (Amounts memory a)
    {
        uint256 principal;
        if (price <= type(uint128).max) {
            uint256 squared = uint256(price) * price;
            principal =
                p.down ? FullMath.mulDivRoundingUp(out, Q192, squared) : FullMath.mulDivRoundingUp(out, squared, Q192);
        } else {
            principal = p.down
                ? FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(out, Q96, price), Q96, price)
                : FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(out, price, Q96), price, Q96);
        }
        a.principal = principal;
        a.out = out;
        // At a fee near 100% the fee of an oversized principal would not fit 256 bits; such a level is never filled.
        if (principal > MAX_BOOK_AMOUNT) a.fee = type(uint256).max;
        else a.fee = r.pool.fee == 0 ? 0 : FullMath.mulDivRoundingUp(principal, r.pool.fee, PIPS - r.pool.fee);
    }

    /// @dev The AMM's amount, in the specified currency, to move from the cursor to `price` within one step.
    function _ammAmount(Request memory r, AmmReplay.Cursor memory c, uint160 price) private pure returns (uint256) {
        (, uint256 amountIn, uint256 amountOut, uint256 fee) = SwapMath.computeSwapStep(
            c.sqrtPriceX96, price, c.liquidity, r.exactIn ? AmmReplay.ALL_IN : AmmReplay.ALL_OUT, r.pool.fee
        );
        return r.exactIn ? amountIn + fee : amountOut;
    }

    /// @dev Where the AMM lands in this step with x of the specified currency, against its own target.
    function _landing(Request memory r, AmmReplay.Cursor memory c, AmmReplay.Step memory s, uint256 x)
        private
        pure
        returns (uint160 price)
    {
        // SwapMath reads a zero amount as exact output; a zero share does not move the AMM.
        if (x == 0) return c.sqrtPriceX96;
        (price,,,) = SwapMath.computeSwapStep(
            c.sqrtPriceX96, s.target, c.liquidity, r.exactIn ? -int256(x) : int256(x), r.pool.fee
        );
    }

    function _spec(Request memory r, Amounts memory a) private pure returns (uint256) {
        return r.exactIn ? a.principal + a.fee : a.out;
    }

    function _sum(Amounts memory x, Amounts memory y) private pure returns (Amounts memory) {
        return Amounts(
            x.principal + y.principal,
            x.fee + y.fee,
            x.out + y.out,
            x.rangePrincipal + y.rangePrincipal,
            x.rangeMakerFee + y.rangeMakerFee
        );
    }

    function _addTo(Amounts memory x, Amounts memory y) private pure {
        x.principal += y.principal;
        x.fee += y.fee;
        x.out += y.out;
        x.rangePrincipal += y.rangePrincipal;
        x.rangeMakerFee += y.rangeMakerFee;
    }

    function _zero() private pure returns (Amounts memory a) {}

    // ---------------------------------------------------------------- helpers

    /// @dev The last loaded segment not beyond `x`.
    function _segAt(Plan memory p, uint160 x) private pure returns (uint256) {
        uint256 lo;
        uint256 hi = p.count - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_beyond(p, p.segs[mid].price, x)) hi = mid - 1;
            else lo = mid;
        }
        return lo;
    }

    function _lowGas(Request memory r) private view returns (bool) {
        return r.minGas != 0 && gasleft() < r.minGas;
    }

    function _beyond(Plan memory p, uint160 a, uint160 b) private pure returns (bool) {
        return p.down ? a < b : a > b;
    }
}
