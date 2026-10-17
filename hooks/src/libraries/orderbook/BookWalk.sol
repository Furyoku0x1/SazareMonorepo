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
    // Squaring Q96 produces Q192, matching the conversion from sqrt price to price.
    uint256 private constant Q192 = 1 << 192;
    /// @dev The commit's gas, counted as the walk loads the book, on top of the request's reserve (the settlement and
    /// the commit's fixed part): per point (a level's and the bitmap's writes, a dead boundary's clear), per chunk a
    /// level spans (each one written when taken), and once for a range stop's three slots and the stop count. Measured
    /// cold: a dead boundary with an emptied one-chunk level about 27k, a side's first range stop about 90k.
    uint256 private constant COMMIT_GAS_PER_POINT = 22_000;
    uint256 private constant COMMIT_GAS_PER_CHUNK = 5_000;
    uint256 private constant COMMIT_GAS_FOR_RANGES = 95_000;
    /// @dev Gas to load one more point (its searches read up to `limits.words` bitmap words each), and to read one chunk
    /// of a level, kept in hand so the walk never starts loading what it could not then commit.
    uint256 private constant LOAD_GAS = 30_000;
    uint256 private constant LOAD_GAS_PER_WORD = 5_000;
    uint256 private constant READ_GAS_PER_CHUNK = 4_500;
    /// @dev The gas cut's search (`_cutShare`) halves at most this many times: exact for the default 128 points. A probe
    /// (swap math twice and a segment search) costs up to about 20,000 gas; CUT_PROBE_GAS keeps a margin.
    uint256 private constant CUT_PROBES = 7;
    uint256 private constant CUT_PROBE_GAS = 24_000;

    /// @dev The request ran output: inside an AMM step, at its end, or in the book.
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
        /// @dev Per side: orders not cancelled. With none, the side holds nothing, and its start and extent clear.
        /// ponytail: an order filled in full stays counted; the walk that filled it clears the side's start.
        uint256[2] open;
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
        uint256 reserveGas; // gas guard; 0 for quotes
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
        uint160 traded; // the furthest price the book filled at (the last trade); 0 when it filled nothing
    }

    /// @dev The book's amounts in the input and output currencies.
    struct Amounts {
        uint256 principal; // input to makers, rounded up
        uint256 fee; // the taker fee on it
        uint256 output; // output from makers, rounded down
        uint256 rangePrincipal; // the range part of `principal`
        uint256 rangeMakerFee; // range maker fees on it, rounded down
    }

    /// @dev Book liquidity from `price` to the next segment.
    struct Segment {
        uint160 sqrtPriceX96;
        uint256 liquidity; // range liquidity
        uint256 feeLiquidity;
        uint256 stopIndex; // the range cursor's stop index here
        uint256 lots; // fixed lots available exactly at `price`
        bool complete; // `lots` is the whole level, so the walk may pass it
        uint256 chunks; // the level's chunks the walk read, which the commit takes from
        Amounts level; // a whole fill of `lots`
        Amounts before; // the book from the walk's start up to `price`, the level at `price` excluded
    }

    struct Plan {
        Fill fill;
        Amounts total;
        Segment[] segments;
        uint256 count;
        int24[] dead; // dead range boundaries crossed, cleared on commit
        uint256 deadCount;
        uint160 positionSqrtPriceX96; // where the book's fills end (beyond `fill.frontier` only past the book's end)
        uint160 levelSqrtPriceX96; // the price of `frontierLots` (0 if none)
        uint256 frontierLots; // lots filled exactly at `position`
        Amounts frontierLevel;
        uint256 side;
        bool down;
        // Loading: the next range point and fixed point, each found from where its own search stands.
        RangeBook.Cursor rangeCursor;
        uint160 rangePointSqrtPriceX96;
        bool rangeFound;
        int24 fixedTick; // fixed ticks strictly beyond it lie ahead (walking down: at or below it)
        uint160 fixedPointSqrtPriceX96;
        bool fixedFound;
        uint160 endSqrtPriceX96; // the book cannot fill beyond this price; 0 while open
        uint160 boundSqrtPriceX96; // searches stop here: the nearer of the limit and the side's extent
        uint160 reachSqrtPriceX96; // the book's spending crosses empty space no further: the AMM's next reachable price
        Amounts ahead; // the book from the walk's start through the last segment, up to the next point
        bool gasEnd; // the gas guard cut the walk short
        uint160 gasCutTargetSqrtPrice; // short of gas, the target of the AMM step `_cutShare` sized; 0 otherwise
        uint256 gasCutLiquidity; // the AMM's liquidity in that step
        uint256 commitGas; // what committing the loaded book will cost
        uint256 cutGas; // what the gas cut's search over the loaded points and the next would cost (`_cutShare`)
        bool ranged; // range liquidity was loaded
        bool clear; // nothing of the side is left ahead of the walk's end, up to the bound
    }

    // ---------------------------------------------------------------- entry points

    /// @notice Records a new order's prices: pulls its side's start back to the order's near end (an ask's lower
    /// price, a bid's upper price) and its extent output to the far end. A fixed order's ends are its price.
    function noteOrder(PoolBook storage book, bool sell0, uint160 nearSqrtPriceX96, uint160 farSqrtPriceX96) internal {
        uint256 side = sell0 ? 0 : 1;
        ++book.open[side];
        uint160 current = book.start[side];
        if (_extendsPrice(current, nearSqrtPriceX96, !sell0)) book.start[side] = nearSqrtPriceX96;
        current = book.extent[side];
        if (_extendsPrice(current, farSqrtPriceX96, sell0)) book.extent[side] = farSqrtPriceX96;
    }

    /// @notice Records a cancelled order. When its side has no order left, the side's start and extent clear, so an
    /// old price cannot hold back the other side's makers when no walk passes that side.
    function noteCancel(PoolBook storage book, bool sell0) internal {
        uint256 side = sell0 ? 0 : 1;
        if (--book.open[side] == 0) (book.start[side], book.extent[side]) = (0, 0);
    }

    /// @notice Plans a swap's book fills without writing.
    function plan(PoolBook storage book, Request memory request) internal view returns (Plan memory walkPlan) {
        AmmReplay.Cursor memory cursor = AmmReplay.load(request.pool);
        walkPlan.side = request.pool.zeroForOne ? 1 : 0;
        walkPlan.down = request.pool.zeroForOne;
        uint160 ammStartSqrtPriceX96 = cursor.sqrtPriceX96;
        uint160 startSqrtPriceX96 = book.start[walkPlan.side];
        if (startSqrtPriceX96 == 0) startSqrtPriceX96 = ammStartSqrtPriceX96;
        else if (_beyond(walkPlan, startSqrtPriceX96, ammStartSqrtPriceX96)) startSqrtPriceX96 = ammStartSqrtPriceX96;
        walkPlan.fill.frontier = startSqrtPriceX96;
        walkPlan.positionSqrtPriceX96 = startSqrtPriceX96;
        // v4 checks the price limit only when the AMM has something left to swap. A limit not ahead of the pool price,
        // or outside the price bounds, would have the book walk the wrong way: the book stays output, and v4 rejects it.
        uint160 limitSqrtPriceX96 = request.pool.limit;
        if (_invalidLimit(walkPlan, limitSqrtPriceX96, ammStartSqrtPriceX96)) {
            walkPlan.fill.stop = LIMIT;
            return walkPlan;
        }
        // A 100% fee leaves nothing to price the book against; the AMM takes the swap.
        if (request.pool.fee >= PIPS) {
            walkPlan.fill.stop = BOOK_DONE;
            return walkPlan;
        }
        if (_lowGas(walkPlan, request)) {
            walkPlan.fill.stop = GAS;
            return walkPlan;
        }
        _begin(walkPlan, book, request, startSqrtPriceX96);
        walkPlan.fill.frontier = ammStartSqrtPriceX96;
        // Catch-up: book liquidity priced better than the pool fills first. When it covers the whole request, the
        // book fills it in price order, stopping where the request is met, and the AMM is not touched.
        if (_catchUp(walkPlan, book, request, cursor, startSqrtPriceX96)) return _finish(walkPlan, request);
        _walkAmm(walkPlan, book, request, cursor);
        return _finish(walkPlan, request);
    }

    /// @notice Applies a plan: fills the fixed levels it passed, clears the dead boundaries it found, records the
    /// range stop when range liquidity sold, and moves the side's start forward to the frontier.
    /// @return makerFee Maker fees on the fills, rounded down, in the input currency.
    function commit(PoolBook storage book, Request memory request, Plan memory walkPlan)
        internal
        returns (uint256 makerFee)
    {
        if (walkPlan.count == 0) return 0; // the walk never began: the book and its start stay as they were
        RangeBook.Side storage rangeSide = book.ranges.sides[walkPlan.side];
        // i < walkPlan.deadCount <= request.limits.bookPoints + 1.
        for (uint256 i; i < walkPlan.deadCount; ++i) {
            RangeBook.clearDead(rangeSide, walkPlan.dead[i]);
        }
        makerFee = walkPlan.total.rangeMakerFee + _takeLevels(book.fixedOrders.sides[walkPlan.side], request, walkPlan);
        uint160 frontierSqrtPriceX96 = walkPlan.fill.frontier;
        if (walkPlan.total.rangePrincipal != 0) _recordRangeStop(rangeSide, walkPlan, frontierSqrtPriceX96);
        // With nothing left ahead up to the bound, the start moves there, or clears when no order reaches beyond it,
        // so an old price does not hold back the other side's makers.
        if (walkPlan.clear) {
            uint160 extentSqrtPriceX96 = book.extent[walkPlan.side];
            if (_noExtentAhead(walkPlan, extentSqrtPriceX96, walkPlan.boundSqrtPriceX96)) {
                frontierSqrtPriceX96 = 0;
            } else if (_beyond(walkPlan, walkPlan.boundSqrtPriceX96, frontierSqrtPriceX96)) {
                frontierSqrtPriceX96 = walkPlan.boundSqrtPriceX96;
            }
        }
        if (!_behindStart(walkPlan, book.start[walkPlan.side], frontierSqrtPriceX96)) {
            book.start[walkPlan.side] = frontierSqrtPriceX96;
        }
    }

    /// @dev Records the range stop where the walk's range selling ended. Past the walk's bound, the side's extent, every
    /// range is sold output, so the stop goes at the bound: one recorded beyond it would lie past stops the next such walk
    /// never loads or crosses, which then left two stops at one price and made a later walk revert (round 3).
    function _recordRangeStop(RangeBook.Side storage rangeSide, Plan memory walkPlan, uint160 frontierSqrtPriceX96)
        private
    {
        uint160 stopSqrtPrice = frontierSqrtPriceX96;
        if (_beyond(walkPlan, frontierSqrtPriceX96, walkPlan.boundSqrtPriceX96)) {
            stopSqrtPrice = walkPlan.boundSqrtPriceX96;
        }
        Segment memory segment = walkPlan.segments[_segmentAt(walkPlan, stopSqrtPrice)];
        RangeBook.record(
            rangeSide,
            RangeBook.Cursor(
                walkPlan.down, stopSqrtPrice, 0, segment.liquidity, segment.feeLiquidity, segment.stopIndex
            )
        );
    }

    /// @dev Whether a walk ended short of its side's start. It began at the pool price, before the start, and stopped
    /// (on gas, say) without reaching it, so it passed no order of the side; moving the start back would only hold back
    /// the other side's makers (round 3, BF-3). Clearing the side always applies.
    function _behindStart(Plan memory plan, uint160 startSqrtPrice, uint160 frontierSqrtPrice)
        private
        pure
        returns (bool)
    {
        if (frontierSqrtPrice == 0) return false;
        if (startSqrtPrice == 0) return false;
        return _beyond(plan, startSqrtPrice, frontierSqrtPrice);
    }

    // ---------------------------------------------------------------- the walk

    function _walkAmm(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor
    ) private view {
        uint256 steps;
        // steps <= request.limits.ammSteps; one final iteration detects the cap.
        while (true) {
            if (_lowGas(walkPlan, request)) {
                walkPlan.fill.stop = GAS;
                break;
            }
            if (_exhausted(walkPlan, request, cursor.sqrtPriceX96)) {
                walkPlan.fill.stop = walkPlan.endSqrtPriceX96 != 0 ? CAP : BOOK_DONE;
                break;
            }
            if (cursor.sqrtPriceX96 == request.pool.limit) {
                walkPlan.fill.stop = LIMIT;
                break;
            }
            if (steps++ == request.limits.ammSteps) {
                walkPlan.fill.stop = CAP;
                break;
            }
            uint8 outcome = _step(walkPlan, book, request, cursor);
            if (outcome == STEP_TAKEN) continue;
            if (outcome == STEP_FINISHED) return;
            break; // spent exactly at the step's end
        }
        walkPlan.total = _cost(walkPlan, request, walkPlan.fill.frontier);
        // Fixed orders exactly at the price limit are reachable; the taker keeps what is left.
        if (walkPlan.fill.stop == LIMIT) {
            walkPlan.reachSqrtPriceX96 = request.pool.limit;
            _spend(walkPlan, book, request);
        }
    }

    /// @dev One AMM step: take it whole if it fits, else finish the walk inside it.
    function _step(Plan memory walkPlan, PoolBook storage book, Request memory request, AmmReplay.Cursor memory cursor)
        private
        view
        returns (uint8)
    {
        AmmReplay.Step memory step = AmmReplay.next(request.pool, cursor);
        uint256 stepAmount = _ammAmount(request, cursor, step.target);
        // Book points load only as far as needed: when the AMM's step alone overshoots, the search loads up to the
        // landings it tries.
        uint256 total = walkPlan.fill.ammShare + stepAmount
            + _specifiedAmount(request, _cost(walkPlan, request, cursor.sqrtPriceX96));
        if (request.exactIn ? total <= request.budget : total < request.budget) {
            _loadThrough(walkPlan, book, request, step.target);
            total =
                walkPlan.fill.ammShare + stepAmount + _specifiedAmount(request, _cost(walkPlan, request, step.target));
        }
        // Exact output takes a step whole only while it stays short of the request; a step that would meet it exactly
        // goes through the search, which stops where the request is met rather than charging for liquidity whose
        // output rounds to zero.
        if (request.exactIn ? total > request.budget : total >= request.budget) {
            _finishInside(walkPlan, book, request, cursor, step, stepAmount);
            return STEP_FINISHED;
        }
        walkPlan.fill.ammShare += stepAmount;
        AmmReplay.move(request.pool, cursor, step, step.target);
        walkPlan.fill.frontier = step.target;
        if (total != request.budget) return STEP_TAKEN;
        // Spent exactly: stop here rather than walk on through empty steps.
        walkPlan.fill.stop = INSIDE;
        return STEP_EXACT;
    }

    /// @dev The request runs output inside this step: size the AMM's share, then spend the rest on the book.
    function _finishInside(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step,
        uint256 stepAmount
    ) private view {
        uint256 before = walkPlan.fill.ammShare;
        _search(walkPlan, book, request, cursor, step, stepAmount);
        walkPlan.fill.stop = INSIDE;
        walkPlan.total = _cost(walkPlan, request, walkPlan.fill.frontier);
        uint256 left = _rest(walkPlan, request, cursor, _spend(walkPlan, book, request));
        if (left == 0) return;
        // What the book could not trade goes to the AMM (see `_rest`).
        walkPlan.fill.ammShare += left;
        if (_stoppedAtEnd(walkPlan)) walkPlan.fill.stop = CAP;
        else if (walkPlan.fill.ammShare - before > stepAmount) walkPlan.fill.stop = BOOK_DONE;
    }

    /// @dev The largest AMM amount x in this step with ammShare + x + the book's cost to its landing within the
    /// request. Starts from the combined-liquidity guess and gallops output from it, then bisects; the answer is exact
    /// whatever the guess, only the number of probes depends on it.
    function _search(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step,
        uint256 stepAmount
    ) private view {
        SearchBounds memory bounds;
        bounds.high = stepAmount == 0 ? 0 : stepAmount - 1;
        _bracketShare(walkPlan, book, request, cursor, step, bounds);
        // At most 256 halvings of the uint256 amount bracket.
        while (bounds.low < bounds.high) {
            uint256 middle = bounds.low + (bounds.high - bounds.low + 1) / 2;
            if (_fits(walkPlan, book, request, cursor, step, middle)) bounds.low = middle;
            else bounds.high = middle - 1;
        }
        walkPlan.reachSqrtPriceX96 =
            bounds.low < stepAmount ? _landing(request, cursor, step, bounds.low + 1) : step.target;
        if (_lowGas(walkPlan, request)) bounds.low = _cutShare(walkPlan, request, cursor, step, bounds.low);
        if (bounds.low != 0) walkPlan.fill.frontier = _landing(request, cursor, step, bounds.low);
        // Rounding may put the AMM beyond the gas cut's point; the book must still fill that point's level.
        if (_beyond(walkPlan, walkPlan.fill.frontier, walkPlan.reachSqrtPriceX96)) {
            walkPlan.fill.frontier = walkPlan.reachSqrtPriceX96;
        }
        walkPlan.fill.ammShare += bounds.low;
    }

    struct SearchBounds {
        uint256 low;
        uint256 high;
    }

    function _bracketShare(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step,
        SearchBounds memory bounds
    ) private view {
        if (bounds.high == 0) return;
        uint256 guess = _guess(walkPlan, book, request, cursor, step);
        if (guess > bounds.high) guess = bounds.high;
        bool fits = true;
        if (guess != 0) fits = _fits(walkPlan, book, request, cursor, step, guess);
        if (fits) {
            bounds.low = guess;
            _growShare(walkPlan, book, request, cursor, step, bounds);
        } else {
            bounds.high = guess - 1;
            _shrinkShare(walkPlan, book, request, cursor, step, bounds);
        }
    }

    function _growShare(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step,
        SearchBounds memory bounds
    ) private view {
        // At most 256 doublings within the uint256 share bracket.
        for (uint256 distance = 1;; distance <<= 1) {
            if (distance > bounds.high - bounds.low) break;
            if (!_fits(walkPlan, book, request, cursor, step, bounds.low + distance)) {
                bounds.high = bounds.low + distance - 1;
                break;
            }
            bounds.low += distance;
        }
    }

    function _shrinkShare(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step,
        SearchBounds memory bounds
    ) private view {
        // At most 256 doublings within the uint256 share bracket.
        for (uint256 distance = 1;; distance <<= 1) {
            if (distance > bounds.high) break;
            if (_fits(walkPlan, book, request, cursor, step, bounds.high + 1 - distance)) {
                bounds.low = bounds.high + 1 - distance;
                break;
            }
            bounds.high -= distance;
        }
    }

    /// @dev Short of gas, the search could not size the AMM's share, and a book that needs the AMM to cross a gap first
    /// would fill nothing. The AMM goes on to the furthest loaded book point in this step that the AMM and the book
    /// reach together within the request, and the book fills up to it; beyond it the book crosses only what
    /// `_gasCutBound` allows. The search runs in memory: the gas left covers no more loading. Spending past the AMM's
    /// share bought levels priced beyond AMM liquidity the taker never reached (round 3, R3-3).
    /// ponytail: book pieces round separately in the makers' favour, so at unit scale the taker can get a few units
    /// less than the AMM alone would give (the accepted rounding); at realistic amounts it is no worse.
    function _cutShare(
        Plan memory plan,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step,
        uint256 share
    ) private pure returns (uint256) {
        plan.gasEnd = true;
        (plan.gasCutTargetSqrtPrice, plan.gasCutLiquidity) = (step.target, cursor.liquidity);
        uint256 low = _segmentAt(plan, _landing(request, cursor, step, share));
        uint256 high = _segmentAt(plan, step.target);
        bool moved;
        // probes < CUT_PROBES; past that, the best point so far stands
        for (uint256 probes; probes < CUT_PROBES; ++probes) {
            if (low == high) break;
            uint256 middle = (low + high + 1) / 2;
            if (_cutReaches(plan, request, cursor, step, plan.segments[middle].sqrtPriceX96)) {
                (low, moved) = (middle, true);
            } else {
                high = middle - 1;
            }
        }
        if (!moved) return share;
        uint160 sqrtPrice = plan.segments[low].sqrtPriceX96;
        plan.reachSqrtPriceX96 = sqrtPrice; // the point itself: the AMM's landing can round a unit short of it
        uint256 shareThere = _ammAmount(request, cursor, sqrtPrice);
        return shareThere > share ? shareThere : share;
    }

    /// @dev Whether the AMM and the book reach `sqrtPrice` together within the request. It holds up to some point and
    /// fails beyond it, which the binary search in `_cutShare` relies on: both amounts only grow with the price.
    function _cutReaches(
        Plan memory plan,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step,
        uint160 sqrtPrice
    ) private pure returns (bool) {
        uint256 shareThere = _ammAmount(request, cursor, sqrtPrice);
        // The whole step does not fit, or there would be no search. At thin liquidity an inner point's rounded amount
        // can equal the whole step's: exact output would then take, and charge for, the whole step.
        if (_landing(request, cursor, step, shareThere) == step.target) return false;
        // The book's cost to the point itself, its level excluded: the AMM's landing can round past the point, and
        // counting a large level there whole would reject a point whose level the book can fill in part.
        return _withinRequest(plan, request, shareThere, sqrtPrice);
    }

    /// @dev After `_cutShare`, how far the book may spend segment `index` from `fromSqrtPrice` toward `nextSqrtPrice`:
    /// returning `fromSqrtPrice` stops it. Within the reach it may go on. Beyond it, only through range liquidity at
    /// least as deep as the AMM's, and no further than the AMM's step: buying that range from the AMM's price gives the
    /// taker no less than the AMM would for the same input, while a gap, a thinner range or the next AMM step could
    /// lead to levels priced past cheaper AMM liquidity.
    function _gasCutBound(Plan memory plan, uint256 index, uint160 fromSqrtPrice, uint160 nextSqrtPrice)
        private
        pure
        returns (uint160)
    {
        uint160 targetSqrtPrice = plan.gasCutTargetSqrtPrice;
        if (targetSqrtPrice == 0) return nextSqrtPrice;
        if (!_beyond(plan, nextSqrtPrice, plan.reachSqrtPriceX96)) return nextSqrtPrice;
        if (plan.segments[index].liquidity < plan.gasCutLiquidity) return fromSqrtPrice;
        if (!_beyond(plan, nextSqrtPrice, targetSqrtPrice)) return nextSqrtPrice;
        if (!_beyond(plan, targetSqrtPrice, fromSqrtPrice)) return fromSqrtPrice;
        return targetSqrtPrice;
    }

    function _fits(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step,
        uint256 share
    ) private view returns (bool) {
        // Short of gas the search stops growing the AMM's share; the book spends from there, and the AMM takes the rest.
        if (_lowGas(walkPlan, request)) {
            walkPlan.gasEnd = true;
            return false;
        }
        ++walkPlan.fill.probes;
        uint160 landingSqrtPriceX96 = _landing(request, cursor, step, share);
        _loadThrough(walkPlan, book, request, landingSqrtPriceX96);
        return _withinRequest(walkPlan, request, share, landingSqrtPriceX96);
    }

    /// @dev Whether an AMM share landing at `landingSqrtPrice`, with the book's cost up to there, stays within the
    /// request: the one budget test the search and the gas cut share.
    function _withinRequest(Plan memory plan, Request memory request, uint256 share, uint160 landingSqrtPrice)
        private
        pure
        returns (bool)
    {
        return plan.fill.ammShare + share + _specifiedAmount(request, _cost(plan, request, landingSqrtPrice))
            <= request.budget;
    }

    struct Guess {
        uint256 rest;
        uint160 sqrtPriceX96;
        uint256 segmentIndex;
        bool levelPaid;
    }

    /// @dev The AMM's share if the rest were spent through this step on AMM and range liquidity together, paying
    /// fixed levels when reached. Exact up to rounding; the search corrects the rest.
    function _guess(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step
    ) private view returns (uint256) {
        Guess memory guessState;
        guessState.sqrtPriceX96 = cursor.sqrtPriceX96;
        guessState.rest = request.budget - walkPlan.fill.ammShare
            - _specifiedAmount(request, _cost(walkPlan, request, guessState.sqrtPriceX96));
        guessState.segmentIndex = _segmentAt(walkPlan, guessState.sqrtPriceX96);
        guessState.levelPaid = guessState.sqrtPriceX96 != walkPlan.segments[guessState.segmentIndex].sqrtPriceX96;
        // i < 16 probes; the estimate never needs unbounded loading.
        for (uint256 i; i < 16; ++i) {
            if (guessState.rest == 0) break;
            if (!_guessStep(walkPlan, book, request, cursor, step, guessState)) break;
        }
        return _ammAmount(request, cursor, guessState.sqrtPriceX96);
    }

    /// @return more Whether the guess reached the next book point with some of the request left.
    function _guessStep(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        AmmReplay.Step memory step,
        Guess memory guessState
    ) private view returns (bool more) {
        if (!_payPendingGuessLevel(walkPlan, request, guessState)) return false;
        // The next point: loaded, or the one the last search found, loaded only once the guess reaches it.
        bool loaded = guessState.segmentIndex + 1 < walkPlan.count;
        uint160 endSqrtPriceX96 = _guessNextPoint(walkPlan, request, guessState, step.target, loaded);
        bool last = _beyond(walkPlan, endSqrtPriceX96, step.target);
        if (last) endSqrtPriceX96 = step.target;
        if (endSqrtPriceX96 == guessState.sqrtPriceX96) return false;
        if (_combinedGuessStep(walkPlan, request, cursor, guessState, endSqrtPriceX96) != endSqrtPriceX96) {
            return false;
        }
        if (last) return false;
        if (!loaded) {
            if (!_hasPending(walkPlan, request)) return false;
            if (!_materialize(walkPlan, book, request)) return false;
        }
        ++guessState.segmentIndex;
        guessState.levelPaid = false;
        return true;
    }

    /// @dev Spends the guess's rest on AMM and range liquidity together toward e.
    function _combinedStep(Request memory request, Guess memory guessState, uint160 endSqrtPriceX96, uint256 liquidity)
        private
        pure
        returns (uint160 nextSqrtPriceX96)
    {
        // The cap only affects the guess; the search keeps the result exact.
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;
        uint256 amountIn;
        uint256 amountOut;
        uint256 fee;
        (nextSqrtPriceX96, amountIn, amountOut, fee) = SwapMath.computeSwapStep(
            guessState.sqrtPriceX96,
            endSqrtPriceX96,
            uint128(liquidity),
            request.exactIn ? -int256(guessState.rest) : int256(guessState.rest),
            request.pool.fee
        );
        guessState.rest -= request.exactIn ? amountIn + fee : amountOut;
        guessState.sqrtPriceX96 = nextSqrtPriceX96;
    }

    /// @dev The rest of the request fills book liquidity from the frontier on, in price order: a fixed level at the
    /// frontier (in whole lots), then range liquidity, across later points while it lasts.
    /// @return left What the book could not trade, in the specified currency.
    function _spend(Plan memory walkPlan, PoolBook storage book, Request memory request)
        private
        view
        returns (uint256 left)
    {
        left = request.budget - walkPlan.fill.ammShare - _specifiedAmount(request, walkPlan.total);
        uint160 sqrtPriceX96 = walkPlan.fill.frontier;
        uint256 segmentIndex = _segmentAt(walkPlan, sqrtPriceX96);
        bool levelDone = sqrtPriceX96 != walkPlan.segments[segmentIndex].sqrtPriceX96;
        // At most request.limits.bookPoints + 1 segments, then the terminal stretch.
        while (left != 0) {
            bool stop;
            (left, stop) = _spendUnpaidLevel(walkPlan, request, segmentIndex, left, levelDone);
            if (stop) break;
            // A zero amount would read as exact output in SwapMath.
            if (left == 0) break;
            (uint160 endSqrtPriceX96, bool open) = _spendBound(walkPlan, book, request, segmentIndex, sqrtPriceX96);
            if (!open) break;
            uint160 cutSqrtPriceX96 = _gasCutBound(walkPlan, segmentIndex, sqrtPriceX96, endSqrtPriceX96);
            if (cutSqrtPriceX96 == sqrtPriceX96) break;
            uint160 nextSqrtPriceX96 = cutSqrtPriceX96; // no book liquidity before it
            if (walkPlan.segments[segmentIndex].liquidity != 0) {
                (nextSqrtPriceX96, left) =
                    _spendRange(walkPlan, request, segmentIndex, sqrtPriceX96, cutSqrtPriceX96, left);
            } else if (_beyond(walkPlan, cutSqrtPriceX96, walkPlan.reachSqrtPriceX96)) {
                break; // what is left is dust: worth less than the AMM's next unit
            }
            sqrtPriceX96 = nextSqrtPriceX96;
            if (nextSqrtPriceX96 != endSqrtPriceX96) break; // short of the next point: the request, or a gas cut, ends the book here
            if (segmentIndex + 1 == walkPlan.count) break; // the limit
            ++segmentIndex;
            levelDone = false;
        }
        walkPlan.fill.frontier = sqrtPriceX96;
    }

    /// @dev What the book could not trade, for the AMM: exact output it could not deliver (its last unit can round
    /// away, or a lot is larger than what is left), and exact input it could not use (less than a lot's cost, or worth
    /// less than the AMM's next unit), which the AMM trades from where it stands. Where the AMM finds no liquidity
    /// toward the limit, exact input stays with the book as dust: the AMM would trade none of it and only run the
    /// price to the limit.
    /// ponytail: the dust is below one lot's cost at the book's frontier, so book-only pools want small lots.
    function _rest(Plan memory walkPlan, Request memory request, AmmReplay.Cursor memory cursor, uint256 left)
        private
        view
        returns (uint256)
    {
        if (left == 0) return left;
        if (!request.exactIn) return left;
        if (_ammTrades(walkPlan, request, cursor)) return left;
        walkPlan.fill.dust += left;
        return 0;
    }

    /// @dev Whether the AMM, from the cursor toward the limit, reaches a step that moves the price with liquidity,
    /// crossing at most a search's worth (`limits.words`) of empty steps or ticks first, so exact input handed to it
    /// trades.
    /// ponytail: liquidity further output than that counts as none; the input it would buy there is worth little at that
    /// distance.
    function _ammTrades(Plan memory walkPlan, Request memory request, AmmReplay.Cursor memory cursor)
        private
        view
        returns (bool)
    {
        // Short of gas to look, the input goes to the AMM: at worst it trades none of it.
        if (_lowGas(walkPlan, request)) return true;
        AmmReplay.Cursor memory probe = AmmReplay.Cursor(cursor.sqrtPriceX96, cursor.tick, cursor.liquidity);
        // i <= request.limits.words, including the starting step.
        for (uint256 i; i <= request.limits.words; ++i) {
            if (probe.sqrtPriceX96 == request.pool.limit) return false;
            AmmReplay.Step memory step = AmmReplay.next(request.pool, probe);
            if (_stepTrades(probe, step)) return true;
            AmmReplay.move(request.pool, probe, step, step.target); // an empty step, or a crossing where the price stands
        }
        return false;
    }

    /// @dev Fills segment j's range liquidity from x toward e with what is left.
    function _spendRange(
        Plan memory walkPlan,
        Request memory request,
        uint256 segmentIndex,
        uint160 sqrtPriceX96,
        uint160 endSqrtPriceX96,
        uint256 left
    ) private pure returns (uint160 nextSqrtPriceX96, uint256 rest) {
        Amounts memory amounts;
        (nextSqrtPriceX96, amounts) =
            _rangePartial(request, sqrtPriceX96, endSqrtPriceX96, walkPlan.segments[segmentIndex], left);
        _addTo(walkPlan.total, amounts);
        rest = left - _specifiedAmount(request, amounts);
    }

    /// @dev Fills the fixed level of segment j, at its price, with what is left.
    /// @return rest What is left after it.
    /// @return stop Whether the walk ends here: the level is not used up, or cannot be passed.
    function _spendLevel(Plan memory walkPlan, Request memory request, uint256 segmentIndex, uint256 left)
        private
        pure
        returns (uint256 rest, bool stop)
    {
        Segment memory segment = walkPlan.segments[segmentIndex];
        rest = left;
        if (segment.lots != 0) {
            (uint256 lots, Amounts memory amounts) = _fixedPartial(walkPlan, request, segment, left);
            if (lots == 0) return (rest, true);
            (walkPlan.levelSqrtPriceX96, walkPlan.frontierLots, walkPlan.frontierLevel) =
            (segment.sqrtPriceX96, lots, amounts);
            _addTo(walkPlan.total, amounts);
            rest -= _specifiedAmount(request, amounts);
            if (lots < segment.lots) return (rest, true);
        }
        stop = !segment.complete;
    }

    /// @dev The next point the book's spending may reach from x in segment j.
    /// @return endSqrtPriceX96 The next reachable point, so spending cannot cross unloaded liquidity.
    /// @return open Whether the book may go on: false at the book's end, at the limit, or with only empty space ahead.
    function _spendBound(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        uint256 segmentIndex,
        uint160 sqrtPriceX96
    ) private view returns (uint160 endSqrtPriceX96, bool open) {
        Segment memory segment = walkPlan.segments[segmentIndex];
        if (_atEnd(walkPlan, segment)) return (sqrtPriceX96, false);
        if (sqrtPriceX96 == request.pool.limit) return (sqrtPriceX96, false);
        if (sqrtPriceX96 == walkPlan.boundSqrtPriceX96) return (sqrtPriceX96, false);
        if (_onlyDustAhead(walkPlan, segment, segmentIndex)) return (sqrtPriceX96, false);
        if (segmentIndex + 1 < walkPlan.count) return (walkPlan.segments[segmentIndex + 1].sqrtPriceX96, true);
        if (_hasPending(walkPlan, request)) {
            if (_materialize(walkPlan, book, request)) return (walkPlan.segments[segmentIndex + 1].sqrtPriceX96, true);
        }
        // Without another point, ranges run to the bound and empty space sells nothing.
        if (walkPlan.endSqrtPriceX96 != 0) return (sqrtPriceX96, false);
        if (segment.liquidity == 0) return (sqrtPriceX96, false);
        return (walkPlan.boundSqrtPriceX96, true);
    }

    function _onlyDustAhead(Plan memory walkPlan, Segment memory segment, uint256 segmentIndex)
        private
        pure
        returns (bool)
    {
        if (segmentIndex + 1 != walkPlan.count) return false;
        if (segment.liquidity != 0) return false;
        return _beyond(walkPlan, _nextPoint(walkPlan), walkPlan.reachSqrtPriceX96);
    }

    function _finish(Plan memory walkPlan, Request memory request) private pure returns (Plan memory) {
        Amounts memory totals = walkPlan.total;
        uint256 input = totals.principal + totals.fee + walkPlan.fill.dust;
        (walkPlan.fill.specified, walkPlan.fill.other) =
            request.exactIn ? (input, totals.output) : (totals.output, input);
        walkPlan.fill.principal = totals.principal;
        walkPlan.fill.takerFee = totals.fee;
        walkPlan.fill.points = walkPlan.count;
        walkPlan.positionSqrtPriceX96 = walkPlan.fill.frontier;
        if (walkPlan.endSqrtPriceX96 != 0) {
            if (_beyond(walkPlan, walkPlan.fill.frontier, walkPlan.endSqrtPriceX96)) {
                // The AMM went on past where the book had to stop.
                walkPlan.fill.frontier = walkPlan.endSqrtPriceX96;
                walkPlan.fill.stop = CAP;
            }
        }
        if (walkPlan.gasEnd) walkPlan.fill.stop = GAS;
        walkPlan.clear = _canClear(walkPlan, request);
        if (walkPlan.count != 0) walkPlan.fill.traded = _traded(walkPlan);
        return walkPlan;
    }

    /// @dev The furthest price the book filled at: the last fixed level the commit takes (up to `position`, as
    /// `_takeLevels` does), or range liquidity sold up to the frontier, whichever is further. Beyond it the walk only
    /// passed empty space (or AMM steps).
    function _traded(Plan memory walkPlan) private pure returns (uint160 traded) {
        // index <= walkPlan.count <= request.limits.bookPoints + 1.
        for (uint256 index = _segmentAt(walkPlan, walkPlan.positionSqrtPriceX96) + 1; index != 0;) {
            Segment memory segment = walkPlan.segments[--index];
            if (_levelTraded(walkPlan, segment)) {
                traded = segment.sqrtPriceX96;
                break;
            }
        }
        uint160 frontierSqrtPriceX96 = walkPlan.fill.frontier;
        uint256 segmentIndex = _segmentAt(walkPlan, frontierSqrtPriceX96);
        // index <= walkPlan.count <= request.limits.bookPoints + 1.
        for (uint256 index = segmentIndex + 1; index != 0;) {
            Segment memory segment = walkPlan.segments[--index];
            uint160 upToSqrtPriceX96 =
                index == segmentIndex ? frontierSqrtPriceX96 : walkPlan.segments[index + 1].sqrtPriceX96;
            if (!_rangeTraded(walkPlan, segment, upToSqrtPriceX96)) continue;
            if (_extendsTrade(walkPlan, upToSqrtPriceX96, traded)) traded = upToSqrtPriceX96;
            break;
        }
    }

    function _levelTraded(Plan memory walkPlan, Segment memory segment) private pure returns (bool) {
        if (segment.lots == 0) return false;
        if (_beyond(walkPlan, walkPlan.positionSqrtPriceX96, segment.sqrtPriceX96)) return true;
        if (walkPlan.levelSqrtPriceX96 != segment.sqrtPriceX96) return false;
        return walkPlan.frontierLots != 0;
    }

    function _rangeTraded(Plan memory walkPlan, Segment memory segment, uint160 upToSqrtPriceX96)
        private
        pure
        returns (bool)
    {
        if (segment.liquidity == 0) return false;
        if (upToSqrtPriceX96 == segment.sqrtPriceX96) return false;
        return !_atEnd(walkPlan, segment);
    }

    function _extendsTrade(Plan memory walkPlan, uint160 nextSqrtPriceX96, uint160 tradedSqrtPriceX96)
        private
        pure
        returns (bool)
    {
        if (tradedSqrtPriceX96 == 0) return true;
        return _beyond(walkPlan, nextSqrtPriceX96, tradedSqrtPriceX96);
    }

    /// @dev Whether the book's fills reach its last loaded point and use up all of its liquidity there.
    function _usedUp(Plan memory walkPlan) private pure returns (bool) {
        Segment memory segment = walkPlan.segments[walkPlan.count - 1];
        if (segment.liquidity != 0) return false;
        if (_beyond(walkPlan, segment.sqrtPriceX96, walkPlan.positionSqrtPriceX96)) return false;
        if (segment.lots == 0) return true;
        if (_beyond(walkPlan, walkPlan.positionSqrtPriceX96, segment.sqrtPriceX96)) return true;
        if (walkPlan.levelSqrtPriceX96 != segment.sqrtPriceX96) return false;
        return walkPlan.frontierLots == segment.lots;
    }

    /// @dev Takes every fixed level the plan passed, and the lots it filled at its last position.
    function _takeLevels(FixedBook.Side storage fixedSide, Request memory request, Plan memory walkPlan)
        private
        returns (uint256 makerFee)
    {
        // segmentIndex < walkPlan.count <= request.limits.bookPoints + 1.
        for (uint256 segmentIndex; segmentIndex < walkPlan.count; ++segmentIndex) {
            Segment memory segment = walkPlan.segments[segmentIndex];
            if (_beyond(walkPlan, segment.sqrtPriceX96, walkPlan.positionSqrtPriceX96)) break;
            (uint256 lots, Amounts memory amounts) = segment.sqrtPriceX96 == walkPlan.positionSqrtPriceX96
                ? (
                    walkPlan.levelSqrtPriceX96 == segment.sqrtPriceX96 ? walkPlan.frontierLots : 0,
                    walkPlan.frontierLevel
                )
                : (segment.lots, segment.level);
            // A level the chunk limit cut short still moves past its emptied chunks, so later walks progress.
            if (_skipLevel(lots, segment)) continue;
            (uint256 taken, uint256 feeWeighted) =
                FixedBook.take(fixedSide, TickMath.getTickAtSqrtPrice(segment.sqrtPriceX96), lots, segment.chunks);
            assert(taken == lots); // `available` sized the plan with the same chunk limit
            if (lots != 0) makerFee += FullMath.mulDiv(amounts.principal, feeWeighted, lots * PIPS);
        }
    }

    // ---------------------------------------------------------------- book loading

    /// @dev Starts both searches at the walk's start and makes the first segment there.
    function _begin(Plan memory walkPlan, PoolBook storage book, Request memory request, uint160 startSqrtPriceX96)
        private
        view
    {
        walkPlan.segments = _segmentArray(request.limits.bookPoints + 1);
        walkPlan.dead = new int24[](request.limits.bookPoints + 1);
        uint160 extentSqrtPriceX96 = book.extent[walkPlan.side];
        walkPlan.boundSqrtPriceX96 = request.pool.limit;
        if (_noExtentAhead(walkPlan, extentSqrtPriceX96, startSqrtPriceX96)) {
            walkPlan.boundSqrtPriceX96 = startSqrtPriceX96; // nothing lies ahead
        } else if (_beyond(walkPlan, walkPlan.boundSqrtPriceX96, extentSqrtPriceX96)) {
            walkPlan.boundSqrtPriceX96 = extentSqrtPriceX96;
        }
        bool dead;
        (walkPlan.rangeCursor, dead) =
            RangeBook.begin(book.ranges.sides[walkPlan.side], walkPlan.down, startSqrtPriceX96);
        int24 tick = TickMath.getTickAtSqrtPrice(startSqrtPriceX96);
        if (dead) walkPlan.dead[walkPlan.deadCount++] = tick;
        Segment memory segment;
        walkPlan.segments[0] = segment;
        segment.sqrtPriceX96 = startSqrtPriceX96;
        segment.complete = true;
        bool exact = TickMath.getSqrtPriceAtTick(tick) == startSqrtPriceX96;
        if (exact) _loadLevel(walkPlan, book, request, segment, tick);
        walkPlan.fixedTick = exact ? (walkPlan.down ? tick - 1 : tick) : tick;
        _snapshot(walkPlan, segment);
        walkPlan.count = 1;
        walkPlan.cutGas = CUT_PROBE_GAS; // one halving for the first point and the next
        (walkPlan.rangePointSqrtPriceX96, walkPlan.rangeFound) = RangeBook.next(
            book.ranges.sides[walkPlan.side], walkPlan.rangeCursor, walkPlan.boundSqrtPriceX96, request.limits.words
        );
        _searchFixed(walkPlan, book, request);
        _ahead(walkPlan, request);
    }

    /// @dev An array of n segment pointers, each assigned when its segment is made: segments are allocated only
    /// as the walk loads them.
    function _segmentArray(uint256 length) private pure returns (Segment[] memory segments) {
        assembly ("memory-safe") {
            segments := mload(0x40)
            mstore(segments, length)
            mstore(0x40, add(segments, shl(5, add(length, 1))))
        }
    }

    /// @dev Loads book points up to `bound`.
    function _loadThrough(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        uint160 boundSqrtPriceX96
    ) private view {
        // walkPlan.count <= request.limits.bookPoints + 1; each iteration loads a point or returns.
        while (_hasPending(walkPlan, request)) {
            if (_beyond(walkPlan, _nextPoint(walkPlan), boundSqrtPriceX96)) return;
            if (!_materialize(walkPlan, book, request)) return;
        }
    }

    /// @dev Makes the next segment at the nearer of the next range point and the next fixed point.
    /// @return Whether it did; if not, the book ends at the last segment.
    function _materialize(Plan memory walkPlan, PoolBook storage book, Request memory request)
        private
        view
        returns (bool)
    {
        if (walkPlan.endSqrtPriceX96 != 0) return false;
        uint160 sqrtPriceX96 = _nextPoint(walkPlan);
        Segment memory segment;
        walkPlan.segments[walkPlan.count] = segment;
        segment.sqrtPriceX96 = sqrtPriceX96;
        segment.before = walkPlan.ahead;
        segment.complete = true;
        if (sqrtPriceX96 == walkPlan.rangePointSqrtPriceX96) {
            if (!_crossRangePoint(walkPlan, book, request, sqrtPriceX96)) return false;
        }
        if (sqrtPriceX96 == walkPlan.fixedPointSqrtPriceX96) {
            int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96); // a fixed point is always a tick's price
            if (walkPlan.fixedFound) _loadLevel(walkPlan, book, request, segment, tick);
            walkPlan.fixedTick = walkPlan.down ? tick - 1 : tick;
            _searchFixed(walkPlan, book, request);
        }
        _snapshot(walkPlan, segment);
        ++walkPlan.count;
        if (_addsHalving(walkPlan.count)) walkPlan.cutGas += CUT_PROBE_GAS;
        // When no further point can be loaded (the point limit, or the gas to commit what is loaded), the newest point
        // ends the book at once: no amount past it is ever counted, so the commit records everything the book sells.
        if (walkPlan.endSqrtPriceX96 == 0) {
            if (_pointsCapped(walkPlan, request)) {
                walkPlan.gasEnd = walkPlan.count != walkPlan.segments.length;
                walkPlan.endSqrtPriceX96 = segment.sqrtPriceX96;
            }
        }
        _ahead(walkPlan, request);
        return true;
    }

    /// @dev The book's amounts through the last segment's range liquidity up to the next point, beyond which the walk
    /// computes none before loading that point. If they would exceed the amount bound, the book ends inside the stretch.
    function _ahead(Plan memory walkPlan, Request memory request) private pure {
        if (walkPlan.endSqrtPriceX96 != 0) return;
        Segment memory segment = walkPlan.segments[walkPlan.count - 1];
        Amounts memory amounts = _sum(segment.before, segment.level);
        if (segment.liquidity != 0) {
            _addTo(amounts, _rangeAll(request, segment.sqrtPriceX96, _nextPoint(walkPlan), segment));
        }
        walkPlan.ahead = amounts;
        if (_amountsOverflow(amounts)) _endWithin(walkPlan, request, segment);
    }

    /// @dev Ends the book where its amounts reach the bound inside segment s's stretch, with a segment there that sells
    /// nothing further, so a later walk goes on from it. It ends at s's start instead when no segment is left, when the
    /// stretch up to that price would deliver no output (it would charge the taker for nothing), or when rounding
    /// leaves the price's amounts past the bound.
    function _endWithin(Plan memory walkPlan, Request memory request, Segment memory segment) private pure {
        walkPlan.endSqrtPriceX96 = segment.sqrtPriceX96;
        if (walkPlan.count == walkPlan.segments.length) return;
        Amounts memory amounts = _sum(segment.before, segment.level);
        uint256 roomIn = MAX_BOOK_AMOUNT - (amounts.principal + amounts.fee);
        uint256 roomOut = MAX_BOOK_AMOUNT - amounts.output;
        if (roomIn == 0) return;
        if (roomOut == 0) return;
        uint160 sqrtPriceX96 = _nextPoint(walkPlan);
        uint128 liquidity = uint128(segment.liquidity);
        (uint160 inputSqrtPriceX96,,,) =
            SwapMath.computeSwapStep(segment.sqrtPriceX96, sqrtPriceX96, liquidity, -int256(roomIn), request.pool.fee);
        (uint160 outputSqrtPriceX96,,,) =
            SwapMath.computeSwapStep(segment.sqrtPriceX96, sqrtPriceX96, liquidity, int256(roomOut), request.pool.fee);
        uint160 nextSqrtPriceX96 =
            _beyond(walkPlan, inputSqrtPriceX96, outputSqrtPriceX96) ? outputSqrtPriceX96 : inputSqrtPriceX96;
        if (nextSqrtPriceX96 == segment.sqrtPriceX96) return;
        Amounts memory range = _rangeAll(request, segment.sqrtPriceX96, nextSqrtPriceX96, segment);
        _addTo(amounts, range);
        if (range.output == 0) return;
        if (amounts.principal + amounts.fee > MAX_BOOK_AMOUNT) return;
        if (amounts.output > MAX_BOOK_AMOUNT) return;
        Segment memory endSegment;
        walkPlan.segments[walkPlan.count++] = endSegment;
        (endSegment.sqrtPriceX96, endSegment.before, endSegment.complete) = (nextSqrtPriceX96, amounts, true);
        (endSegment.liquidity, endSegment.feeLiquidity, endSegment.stopIndex) =
        (segment.liquidity, segment.feeLiquidity, segment.stopIndex);
        walkPlan.endSqrtPriceX96 = nextSqrtPriceX96;
    }

    /// @dev Records the range cursor in a new segment. The book ends at a segment it cannot pass: a level it cannot
    /// fill whole, or range liquidity too large for one SwapMath step.
    function _snapshot(Plan memory walkPlan, Segment memory segment) private pure {
        walkPlan.commitGas += COMMIT_GAS_PER_POINT;
        // The first range liquidity loaded: a commit may record a range stop.
        if (walkPlan.rangeCursor.liquidity != 0) {
            if (!walkPlan.ranged) {
                walkPlan.ranged = true;
                walkPlan.commitGas += COMMIT_GAS_FOR_RANGES;
            }
        }
        segment.liquidity = walkPlan.rangeCursor.liquidity;
        segment.feeLiquidity = walkPlan.rangeCursor.feeLiquidity;
        segment.stopIndex = walkPlan.rangeCursor.stopIndex;
        // At the walk's start such liquidity sells nothing: the book ends at once, with no stop to record.
        if (!segment.complete) walkPlan.endSqrtPriceX96 = segment.sqrtPriceX96;
        else if (segment.liquidity > type(uint128).max) walkPlan.endSqrtPriceX96 = segment.sqrtPriceX96;
    }

    /// @dev The fixed lots available at a tick within the chunk limit, and their whole fill. A level whose whole
    /// fill would not fit the book's amounts is left unfillable.
    /// @dev A level whose whole fill would take the book's totals past its amounts is left unfillable, as is one the
    /// chunk limit cuts short: the book ends there, and the next walk starts there.
    function _loadLevel(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        Segment memory segment,
        int24 tick
    ) private view {
        // Short of gas the walk reads fewer chunks: the level is then cut short, which ends the book there.
        segment.chunks = _affordableChunks(walkPlan, request);
        (uint256 lots, bool complete, uint256 chunks) =
            FixedBook.available(book.fixedOrders.sides[walkPlan.side], tick, segment.chunks);
        if (!complete) {
            if (segment.chunks < request.limits.chunks) walkPlan.gasEnd = true;
        }
        // The commit visits only the chunks read here: emptied chunks after them would be unpaid cold reads.
        segment.chunks = chunks;
        walkPlan.commitGas += chunks * COMMIT_GAS_PER_CHUNK;
        segment.complete = complete;
        if (lots == 0) return;
        if (!_loadLots(walkPlan, request, segment, lots)) segment.complete = false;
    }

    function _loadLots(Plan memory walkPlan, Request memory request, Segment memory segment, uint256 lots)
        private
        pure
        returns (bool)
    {
        Amounts memory before = segment.before;
        uint256 room = MAX_BOOK_AMOUNT - before.output;
        if (lots > room / request.lotSize) return false;
        Amounts memory amounts = _fixedAmounts(walkPlan, request, segment.sqrtPriceX96, lots * request.lotSize);
        // The fee sentinel prevents overflowing totals when the principal alone is already too large.
        if (amounts.fee == type(uint256).max) return false;
        if (before.principal + before.fee + amounts.principal + amounts.fee > MAX_BOOK_AMOUNT) return false;
        (segment.lots, segment.level) = (lots, amounts);
        return true;
    }

    function _searchFixed(Plan memory walkPlan, PoolBook storage book, Request memory request) private view {
        mapping(int16 => uint256) storage bitmap = book.fixedOrders.sides[walkPlan.side].bitmap;
        uint160 boundSqrtPriceX96 = walkPlan.boundSqrtPriceX96;
        (walkPlan.fixedPointSqrtPriceX96, walkPlan.fixedFound) = (boundSqrtPriceX96, false);
        int24 searched = walkPlan.fixedTick;
        // i < request.limits.words, the bitmap-search allowance.
        for (uint256 i; i < request.limits.words; ++i) {
            (int24 nextTick, bool initialized) = bitmap.nextInitializedTickWithinOneWord(searched, 1, walkPlan.down);
            if (nextTick < TickMath.MIN_TICK) return;
            if (nextTick > TickMath.MAX_TICK) return;
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(nextTick);
            if (_beyond(walkPlan, sqrtPriceX96, boundSqrtPriceX96)) return;
            if (_searchFinished(initialized, i, request.limits.words)) {
                (walkPlan.fixedPointSqrtPriceX96, walkPlan.fixedFound) = (sqrtPriceX96, initialized); // searched up to here
                return;
            }
            searched = walkPlan.down ? nextTick - 1 : nextTick;
        }
    }

    function _nextPoint(Plan memory walkPlan) private pure returns (uint160) {
        return _beyond(walkPlan, walkPlan.rangePointSqrtPriceX96, walkPlan.fixedPointSqrtPriceX96)
            ? walkPlan.fixedPointSqrtPriceX96
            : walkPlan.rangePointSqrtPriceX96;
    }

    /// @dev Whether a book point lies ahead before or at the limit. Searches that reached the limit empty-handed
    /// leave none.
    function _hasPending(Plan memory walkPlan, Request memory request) private pure returns (bool) {
        if (walkPlan.endSqrtPriceX96 != 0) return false;
        if (_nextPoint(walkPlan) != walkPlan.boundSqrtPriceX96) return true;
        if (walkPlan.rangeFound) return true;
        return walkPlan.fixedFound;
    }

    /// @dev Whether the book has nothing left to fill at or beyond `price`.
    function _exhausted(Plan memory walkPlan, Request memory request, uint160 sqrtPriceX96)
        private
        pure
        returns (bool)
    {
        Segment memory segment = walkPlan.segments[walkPlan.count - 1];
        if (walkPlan.endSqrtPriceX96 != 0) {
            if (_beyond(walkPlan, sqrtPriceX96, walkPlan.endSqrtPriceX96)) return true;
            if (sqrtPriceX96 != walkPlan.endSqrtPriceX96) return false;
            return segment.lots == 0;
        }
        if (_hasPending(walkPlan, request)) return false;
        if (segment.liquidity != 0) return false;
        if (segment.lots == 0) return true;
        return _beyond(walkPlan, sqrtPriceX96, segment.sqrtPriceX96);
    }

    // ---------------------------------------------------------------- amounts

    /// @dev The book's amounts from the walk's start up to `x`; the level exactly at `x` is excluded. Points must
    /// be loaded through `x`.
    function _cost(Plan memory walkPlan, Request memory request, uint160 sqrtPriceX96)
        private
        pure
        returns (Amounts memory amounts)
    {
        Segment memory segment = walkPlan.segments[_segmentAt(walkPlan, sqrtPriceX96)];
        // Copy before adding this segment's fill: aliasing would corrupt costs used by later probes.
        amounts = _copyAmounts(segment.before);
        if (sqrtPriceX96 == segment.sqrtPriceX96) return amounts;
        _addTo(amounts, segment.level);
        // Beyond the book's end the AMM goes on alone.
        if (segment.liquidity == 0) return amounts;
        if (_atEnd(walkPlan, segment)) return amounts;
        _addTo(amounts, _rangeAll(request, segment.sqrtPriceX96, sqrtPriceX96, segment));
    }

    /// @dev Range liquidity of segment `s` traded from `from` to `to` in full.
    function _rangeAll(Request memory request, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96, Segment memory segment)
        private
        pure
        returns (Amounts memory amounts)
    {
        (, uint256 amountIn, uint256 amountOut, uint256 fee) = SwapMath.computeSwapStep(
            fromSqrtPriceX96,
            toSqrtPriceX96,
            uint128(segment.liquidity),
            request.exactIn ? AmmReplay.ALL_IN : AmmReplay.ALL_OUT,
            request.pool.fee
        );
        return _rangeAmounts(amountIn, fee, amountOut, segment);
    }

    /// @dev Range liquidity of segment `s` traded from `from` toward `to` with `left` of the request.
    function _rangePartial(
        Request memory request,
        uint160 fromSqrtPriceX96,
        uint160 toSqrtPriceX96,
        Segment memory segment,
        uint256 left
    ) private pure returns (uint160 nextSqrtPriceX96, Amounts memory amounts) {
        uint256 amountIn;
        uint256 amountOut;
        uint256 fee;
        (nextSqrtPriceX96, amountIn, amountOut, fee) = SwapMath.computeSwapStep(
            fromSqrtPriceX96,
            toSqrtPriceX96,
            uint128(segment.liquidity),
            request.exactIn ? -int256(left) : int256(left),
            request.pool.fee
        );
        amounts = _rangeAmounts(amountIn, fee, amountOut, segment);
    }

    function _rangeAmounts(uint256 amountIn, uint256 fee, uint256 amountOut, Segment memory segment)
        private
        pure
        returns (Amounts memory amounts)
    {
        amounts.principal = amountIn;
        amounts.fee = fee;
        amounts.output = amountOut;
        amounts.rangePrincipal = amountIn;
        // Each range's share of the principal is proportional to its liquidity, so its maker fee is the principal
        // weighted by the fee-weighted liquidity.
        amounts.rangeMakerFee = FullMath.mulDiv(amountIn, segment.feeLiquidity, segment.liquidity * PIPS);
    }

    /// @dev The most whole lots of a level that `left` buys (exact input) or asks for (exact output).
    function _fixedPartial(Plan memory walkPlan, Request memory request, Segment memory segment, uint256 left)
        private
        pure
        returns (uint256 lots, Amounts memory amounts)
    {
        if (!request.exactIn) {
            lots = left / request.lotSize;
            if (lots >= segment.lots) return (segment.lots, segment.level);
            if (lots != 0) amounts = _fixedAmounts(walkPlan, request, segment.sqrtPriceX96, lots * request.lotSize);
            return (lots, amounts);
        }
        if (_specifiedAmount(request, segment.level) <= left) return (segment.lots, segment.level);
        // Costs grow with lots, so a gallop brackets the estimate before exact bisection.
        SearchBounds memory bounds;
        bounds.high = segment.lots - 1;
        _bracketLots(walkPlan, request, segment, left, bounds);
        // At most 256 halvings of the uint256 lot bracket.
        while (bounds.low < bounds.high) {
            uint256 middle = bounds.low + (bounds.high - bounds.low + 1) / 2;
            if (_lotsFit(walkPlan, request, segment.sqrtPriceX96, middle, left)) bounds.low = middle;
            else bounds.high = middle - 1;
        }
        lots = bounds.low;
        if (lots != 0) amounts = _fixedAmounts(walkPlan, request, segment.sqrtPriceX96, lots * request.lotSize);
    }

    function _bracketLots(
        Plan memory walkPlan,
        Request memory request,
        Segment memory segment,
        uint256 left,
        SearchBounds memory bounds
    ) private pure {
        uint256 guess = FullMath.mulDiv(segment.lots, left, _specifiedAmount(request, segment.level));
        if (guess > bounds.high) guess = bounds.high;
        bool fits = true;
        if (guess != 0) fits = _lotsFit(walkPlan, request, segment.sqrtPriceX96, guess, left);
        if (fits) {
            bounds.low = guess;
            _growLots(walkPlan, request, segment.sqrtPriceX96, left, bounds);
        } else {
            bounds.high = guess - 1;
            _shrinkLots(walkPlan, request, segment.sqrtPriceX96, left, bounds);
        }
    }

    function _growLots(
        Plan memory walkPlan,
        Request memory request,
        uint160 sqrtPriceX96,
        uint256 left,
        SearchBounds memory bounds
    ) private pure {
        // At most 256 doublings within the uint256 lot bracket.
        for (uint256 distance = 1;; distance <<= 1) {
            if (distance > bounds.high - bounds.low) break;
            if (!_lotsFit(walkPlan, request, sqrtPriceX96, bounds.low + distance, left)) {
                bounds.high = bounds.low + distance - 1;
                break;
            }
            bounds.low += distance;
        }
    }

    function _shrinkLots(
        Plan memory walkPlan,
        Request memory request,
        uint160 sqrtPriceX96,
        uint256 left,
        SearchBounds memory bounds
    ) private pure {
        // At most 256 doublings within the uint256 lot bracket.
        for (uint256 distance = 1;; distance <<= 1) {
            if (distance > bounds.high) break;
            if (_lotsFit(walkPlan, request, sqrtPriceX96, bounds.high + 1 - distance, left)) {
                bounds.low = bounds.high + 1 - distance;
                break;
            }
            bounds.high -= distance;
        }
    }

    function _lotsFit(Plan memory walkPlan, Request memory request, uint160 sqrtPriceX96, uint256 lots, uint256 left)
        private
        pure
        returns (bool)
    {
        return _specifiedAmount(request, _fixedAmounts(walkPlan, request, sqrtPriceX96, lots * request.lotSize)) <= left;
    }

    /// @dev `output` of a fixed level at sqrt price `price`: the taker's principal rounded up (the price applied once
    /// while its square fits 256 bits, otherwise in two rounded-up halves), and the fee as v4 rounds it.
    function _fixedAmounts(Plan memory walkPlan, Request memory request, uint160 sqrtPriceX96, uint256 output)
        private
        pure
        returns (Amounts memory amounts)
    {
        uint256 principal;
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 squared = uint256(sqrtPriceX96) * sqrtPriceX96;
            principal = walkPlan.down
                ? FullMath.mulDivRoundingUp(output, Q192, squared)
                : FullMath.mulDivRoundingUp(output, squared, Q192);
        } else {
            principal = walkPlan.down
                ? FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(output, Q96, sqrtPriceX96), Q96, sqrtPriceX96)
                : FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(output, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
        }
        amounts.principal = principal;
        amounts.output = output;
        // At a fee near 100% the fee of an oversized principal would not fit 256 bits; such a level is never filled.
        if (principal > MAX_BOOK_AMOUNT) {
            amounts.fee = type(uint256).max;
        } else {
            amounts.fee = request.pool.fee == 0
                ? 0
                : FullMath.mulDivRoundingUp(principal, request.pool.fee, PIPS - request.pool.fee);
        }
    }

    /// @dev The AMM's amount, in the specified currency, to move from the cursor to `price` within one step.
    function _ammAmount(Request memory request, AmmReplay.Cursor memory cursor, uint160 sqrtPriceX96)
        private
        pure
        returns (uint256)
    {
        (, uint256 amountIn, uint256 amountOut, uint256 fee) = SwapMath.computeSwapStep(
            cursor.sqrtPriceX96,
            sqrtPriceX96,
            cursor.liquidity,
            request.exactIn ? AmmReplay.ALL_IN : AmmReplay.ALL_OUT,
            request.pool.fee
        );
        return request.exactIn ? amountIn + fee : amountOut;
    }

    /// @dev Where the AMM lands in this step with x of the specified currency, against its own target.
    function _landing(Request memory request, AmmReplay.Cursor memory cursor, AmmReplay.Step memory step, uint256 share)
        private
        pure
        returns (uint160 sqrtPriceX96)
    {
        // SwapMath reads a zero amount as exact output; a zero share does not move the AMM.
        if (share == 0) return cursor.sqrtPriceX96;
        (sqrtPriceX96,,,) = SwapMath.computeSwapStep(
            cursor.sqrtPriceX96,
            step.target,
            cursor.liquidity,
            request.exactIn ? -int256(share) : int256(share),
            request.pool.fee
        );
    }

    function _specifiedAmount(Request memory request, Amounts memory amounts) private pure returns (uint256) {
        return request.exactIn ? amounts.principal + amounts.fee : amounts.output;
    }

    function _sum(Amounts memory first, Amounts memory second) private pure returns (Amounts memory) {
        return Amounts(
            first.principal + second.principal,
            first.fee + second.fee,
            first.output + second.output,
            first.rangePrincipal + second.rangePrincipal,
            first.rangeMakerFee + second.rangeMakerFee
        );
    }

    function _addTo(Amounts memory total, Amounts memory addition) private pure {
        total.principal += addition.principal;
        total.fee += addition.fee;
        total.output += addition.output;
        total.rangePrincipal += addition.rangePrincipal;
        total.rangeMakerFee += addition.rangeMakerFee;
    }

    function _copyAmounts(Amounts memory source) private pure returns (Amounts memory) {
        return Amounts(source.principal, source.fee, source.output, source.rangePrincipal, source.rangeMakerFee);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The last loaded segment not beyond `x`.
    function _segmentAt(Plan memory walkPlan, uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 low;
        uint256 high = walkPlan.count - 1;
        // At most 256 halvings of walkPlan.count (uint256).
        while (low < high) {
            uint256 middle = (low + high + 1) / 2;
            if (_beyond(walkPlan, walkPlan.segments[middle].sqrtPriceX96, sqrtPriceX96)) high = middle - 1;
            else low = middle;
        }
        return low;
    }

    /// @dev Whether the gas left would not cover the reserve, a commit of the book loaded so far, and loading and
    /// committing one more point (with a first range stop).
    function _lowGas(Plan memory walkPlan, Request memory request) private view returns (bool) {
        if (request.reserveGas == 0) return false;
        uint256 remainingGas = gasleft();
        if (remainingGas < request.reserveGas) return true;
        return remainingGas - request.reserveGas < _gasAhead(walkPlan, request);
    }

    /// @dev The chunks of a level the walk can read and commit with the gas left after `_lowGas`'s needs: the chunk
    /// limit when gas is ample (always for quotes).
    function _affordableChunks(Plan memory walkPlan, Request memory request) private view returns (uint256) {
        if (request.reserveGas == 0) return request.limits.chunks;
        uint256 remainingGas = gasleft();
        uint256 requiredGas = _gasAhead(walkPlan, request);
        if (remainingGas < request.reserveGas) return 0;
        if (remainingGas - request.reserveGas <= requiredGas) return 0;
        uint256 chunks = (remainingGas - request.reserveGas - requiredGas) / (READ_GAS_PER_CHUNK + COMMIT_GAS_PER_CHUNK);
        return chunks < request.limits.chunks ? chunks : request.limits.chunks;
    }

    function _gasAhead(Plan memory walkPlan, Request memory request) private pure returns (uint256) {
        return walkPlan.commitGas + LOAD_GAS + request.limits.words * LOAD_GAS_PER_WORD + COMMIT_GAS_PER_POINT
            + (walkPlan.ranged ? 0 : COMMIT_GAS_FOR_RANGES) + walkPlan.cutGas;
    }

    /// @dev Whether the point just loaded adds a halving to the gas cut's search over the loaded points and the next:
    /// ceil(log2(count + 1)) grows when count is a power of two, up to CUT_PROBES. Kept as the walk loads, so the guard's
    /// frequent checks stay cheap (computing it in each check ran the walk output of gas near the guard's trip).
    function _addsHalving(uint256 count) private pure returns (bool) {
        if (count > 1 << (CUT_PROBES - 1)) return false;
        return count & (count - 1) == 0;
    }

    function _beyond(Plan memory walkPlan, uint160 firstSqrtPriceX96, uint160 secondSqrtPriceX96)
        private
        pure
        returns (bool)
    {
        return walkPlan.down ? firstSqrtPriceX96 < secondSqrtPriceX96 : firstSqrtPriceX96 > secondSqrtPriceX96;
    }

    function _atEnd(Plan memory walkPlan, Segment memory segment) private pure returns (bool) {
        if (walkPlan.endSqrtPriceX96 == 0) return false;
        return segment.sqrtPriceX96 == walkPlan.endSqrtPriceX96;
    }

    function _noExtentAhead(Plan memory walkPlan, uint160 extentSqrtPriceX96, uint160 fromSqrtPriceX96)
        private
        pure
        returns (bool)
    {
        if (extentSqrtPriceX96 == 0) return true;
        return !_beyond(walkPlan, extentSqrtPriceX96, fromSqrtPriceX96);
    }

    function _invalidLimit(Plan memory walkPlan, uint160 limitSqrtPriceX96, uint160 startSqrtPriceX96)
        private
        pure
        returns (bool)
    {
        if (!_beyond(walkPlan, limitSqrtPriceX96, startSqrtPriceX96)) return true;
        if (limitSqrtPriceX96 <= TickMath.MIN_SQRT_PRICE) return true;
        return limitSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE;
    }

    function _amountsOverflow(Amounts memory amounts) private pure returns (bool) {
        if (amounts.principal + amounts.fee > MAX_BOOK_AMOUNT) return true;
        return amounts.output > MAX_BOOK_AMOUNT;
    }

    function _pointsCapped(Plan memory walkPlan, Request memory request) private view returns (bool) {
        if (walkPlan.count == walkPlan.segments.length) return true;
        return _lowGas(walkPlan, request);
    }

    function _extendsPrice(uint160 currentSqrtPriceX96, uint160 nextSqrtPriceX96, bool upward)
        private
        pure
        returns (bool)
    {
        if (currentSqrtPriceX96 == 0) return true;
        return upward ? nextSqrtPriceX96 > currentSqrtPriceX96 : nextSqrtPriceX96 < currentSqrtPriceX96;
    }

    function _catchUp(
        Plan memory walkPlan,
        PoolBook storage book,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        uint160 startSqrtPriceX96
    ) private view returns (bool) {
        uint160 ammStartSqrtPriceX96 = cursor.sqrtPriceX96;
        if (!_beyond(walkPlan, ammStartSqrtPriceX96, startSqrtPriceX96)) return false;
        _loadThrough(walkPlan, book, request, ammStartSqrtPriceX96);
        if (_specifiedAmount(request, _cost(walkPlan, request, ammStartSqrtPriceX96)) < request.budget) return false;
        walkPlan.fill.stop = INSIDE;
        walkPlan.fill.frontier = startSqrtPriceX96;
        walkPlan.reachSqrtPriceX96 = ammStartSqrtPriceX96;
        uint256 left = _rest(walkPlan, request, cursor, _spend(walkPlan, book, request));
        if (left != 0) {
            // Below one lot, v4 decides where the remainder lands.
            walkPlan.fill.ammShare = left;
            walkPlan.fill.stop = BOOK_DONE;
        }
        return true;
    }

    function _stoppedAtEnd(Plan memory walkPlan) private pure returns (bool) {
        if (walkPlan.endSqrtPriceX96 == 0) return false;
        return walkPlan.fill.frontier == walkPlan.endSqrtPriceX96;
    }

    function _guessOwesLevel(Guess memory guessState, Segment memory segment) private pure returns (bool) {
        if (guessState.sqrtPriceX96 != segment.sqrtPriceX96) return false;
        return !guessState.levelPaid;
    }

    function _canClear(Plan memory walkPlan, Request memory request) private pure returns (bool) {
        if (walkPlan.endSqrtPriceX96 != 0) return false;
        if (_hasPending(walkPlan, request)) return false;
        return _usedUp(walkPlan);
    }

    function _searchFinished(bool initialized, uint256 wordIndex, uint256 maxWords) private pure returns (bool) {
        if (initialized) return true;
        return wordIndex + 1 == maxWords;
    }

    function _crossRangePoint(Plan memory walkPlan, PoolBook storage book, Request memory request, uint160 sqrtPriceX96)
        private
        view
        returns (bool)
    {
        RangeBook.Side storage rangeSide = book.ranges.sides[walkPlan.side];
        if (RangeBook.cross(rangeSide, walkPlan.rangeCursor, sqrtPriceX96)) {
            walkPlan.dead[walkPlan.deadCount++] = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        }
        // A step and a recorded stop both narrow liquidity to uint128, so the book ends before an oversized point.
        if (walkPlan.rangeCursor.liquidity > type(uint128).max) {
            walkPlan.endSqrtPriceX96 = walkPlan.segments[walkPlan.count - 1].sqrtPriceX96;
            return false;
        }
        (walkPlan.rangePointSqrtPriceX96, walkPlan.rangeFound) =
            RangeBook.next(rangeSide, walkPlan.rangeCursor, walkPlan.boundSqrtPriceX96, request.limits.words);
        return true;
    }

    function _payGuessLevel(Request memory request, Guess memory guessState, Segment memory segment)
        private
        pure
        returns (bool)
    {
        guessState.levelPaid = true;
        uint256 level = _specifiedAmount(request, segment.level);
        // SwapMath reads zero as exact output, so no combined step may follow an exhausted request.
        if (level >= guessState.rest) return false;
        guessState.rest -= level;
        return true;
    }

    function _combinedGuessStep(
        Plan memory walkPlan,
        Request memory request,
        AmmReplay.Cursor memory cursor,
        Guess memory guessState,
        uint160 endSqrtPriceX96
    ) private pure returns (uint160) {
        Segment memory segment = walkPlan.segments[guessState.segmentIndex];
        uint256 liquidity = cursor.liquidity + (_atEnd(walkPlan, segment) ? 0 : segment.liquidity);
        return _combinedStep(request, guessState, endSqrtPriceX96, liquidity);
    }

    function _stepTrades(AmmReplay.Cursor memory cursor, AmmReplay.Step memory step) private pure returns (bool) {
        if (cursor.liquidity == 0) return false;
        return step.target != cursor.sqrtPriceX96;
    }

    function _skipLevel(uint256 lots, Segment memory segment) private pure returns (bool) {
        if (lots != 0) return false;
        return segment.complete;
    }

    function _spendUnpaidLevel(
        Plan memory walkPlan,
        Request memory request,
        uint256 segmentIndex,
        uint256 left,
        bool levelDone
    ) private pure returns (uint256, bool) {
        if (levelDone) return (left, false);
        return _spendLevel(walkPlan, request, segmentIndex, left);
    }

    function _payPendingGuessLevel(Plan memory walkPlan, Request memory request, Guess memory guessState)
        private
        pure
        returns (bool)
    {
        Segment memory segment = walkPlan.segments[guessState.segmentIndex];
        if (!_guessOwesLevel(guessState, segment)) return true;
        return _payGuessLevel(request, guessState, segment);
    }

    function _guessNextPoint(
        Plan memory walkPlan,
        Request memory request,
        Guess memory guessState,
        uint160 targetSqrtPriceX96,
        bool loaded
    ) private pure returns (uint160) {
        if (loaded) return walkPlan.segments[guessState.segmentIndex + 1].sqrtPriceX96;
        if (_hasPending(walkPlan, request)) return _nextPoint(walkPlan);
        return targetSqrtPriceX96;
    }
}
