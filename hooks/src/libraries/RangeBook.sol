// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @notice Range orders: one-way liquidity with the shape of a v4 position, sold from its near end outward as
/// swaps move through it. Asks sell currency0 as the price rises; bids sell currency1 as it falls. See "Range
/// orders: proposed design" in hooks/docs/order-book-design.md.
/// @dev A range's frontier is the furthest book stop since it was placed, clamped to the range. Boundaries
/// carry liquidity changes tagged with their last write; a boundary is dead once a stop at or beyond it came
/// after that write, its effect then living in that stop's G. Each range keeps the maker fee in force when
/// placed, so boundaries and stops also carry fee-weighted liquidity (liquidity times fee).
/// A walk runs `begin`, then `next` and `cross` until it reaches its end, then `record` if range liquidity sold
/// (see "Swap walk" in the design). The walk itself only reads: crossing a dead boundary reports it, and the
/// caller clears it with `clearDead` when it commits, so a quote runs the same code as a swap. A walk starts at
/// or before every open range's frontier on its side; the caller keeps a per-side start for that. Walk prices
/// lie in [MIN_SQRT_PRICE, MAX_SQRT_PRICE), as v4 prices do.
library RangeBook {
    using TickBitmap for mapping(int16 => uint256);

    uint128 internal constant MAX_RANGE_LIQUIDITY = uint128(1 << 96);

    error InvalidRange();
    error InvalidAmount();
    error NotOwner();
    error NoProgress();

    struct Range {
        address owner;
        int24 lower;
        int24 upper;
        uint24 feePips;
        bool sell0;
        uint128 liquidity;
        uint64 seq; // placement sequence number
        uint160 frozen; // frontier at cancellation; 0 while open
        uint256 claimed; // gross proceeds already claimed
    }

    struct Boundary {
        int160 net; // liquidity change when the walk reaches this tick (wider than any sum of capped ranges)
        uint64 tag; // sequence number of the last write
        int256 feeNet; // fee-weighted liquidity change
    }

    struct Stop {
        uint64 seq;
        uint160 price; // sqrt price where the book stopped
        uint128 g; // range liquidity active just beyond the stop
        uint256 feeG;
    }

    struct Side {
        mapping(int16 => uint256) bitmap; // boundary ticks
        mapping(int24 => Boundary) boundaries;
        mapping(uint256 => Stop) stops; // from the furthest (oldest) stop to the nearest (newest)
        uint256 stopCount;
        uint64 seq;
    }

    struct Book {
        Side[2] sides; // [0] asks: makers sell currency0, filled upwards; [1] bids, filled downwards
        mapping(uint256 => Range) ranges;
        uint256 nextId;
    }

    /// @dev A walk over one side; `down` for bids.
    struct Cursor {
        bool down;
        uint160 price;
        int24 tick; // boundaries strictly beyond it are ahead (walking down: at or below it)
        uint256 liquidity; // wide, so events at one price apply in any order; narrowed when recorded
        uint256 feeLiquidity;
        uint256 m; // stops [0, m) lie strictly beyond `price`, or at it until crossed
    }

    // ---------------------------------------------------------------- makers

    function place(
        Book storage book,
        address owner,
        bool sell0,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint24 feePips
    ) internal returns (uint256 id) {
        if (lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK) revert InvalidRange();
        if (liquidity == 0 || liquidity > MAX_RANGE_LIQUIDITY) revert InvalidAmount();
        Side storage side = book.sides[sell0 ? 0 : 1];
        uint64 seq = ++side.seq;
        id = ++book.nextId;
        book.ranges[id] = Range(owner, lower, upper, feePips, sell0, liquidity, seq, 0, 0);
        int256 fee = int256(uint256(liquidity) * feePips);
        (int24 near, int24 far) = sell0 ? (lower, upper) : (upper, lower);
        _write(side, !sell0, near, int160(int128(liquidity)), fee, seq);
        _write(side, !sell0, far, -int160(int128(liquidity)), -fee, seq);
    }

    /// @return refund Unsold amount of the currency the range sells, rounded down.
    function cancel(Book storage book, uint256 id, address caller) internal returns (uint256 refund) {
        Range storage range = book.ranges[id];
        if (range.owner != caller) revert NotOwner();
        if (range.frozen != 0) return 0;
        bool sell0 = range.sell0;
        Side storage side = book.sides[sell0 ? 0 : 1];
        (uint160 frontier, uint256 j, bool touched) = _frontier(side, range);
        range.frozen = frontier;
        (int24 near, int24 far) = sell0 ? (range.lower, range.upper) : (range.upper, range.lower);
        uint160 farPrice = TickMath.getSqrtPriceAtTick(far);
        if (frontier == farPrice) return 0; // fully sold
        uint128 liquidity = range.liquidity;
        uint64 seq = ++side.seq;
        int256 fee = int256(uint256(liquidity) * range.feePips);
        if (touched) {
            Stop storage stop = side.stops[j]; // its unsold part lives in the G of the stop that set its frontier
            stop.g -= liquidity;
            stop.feeG -= uint256(fee);
        } else {
            _write(side, !sell0, near, -int160(int128(liquidity)), -fee, seq); // untouched: its start boundary holds it
        }
        _write(side, !sell0, far, int160(int128(liquidity)), fee, seq);
        refund = sell0
            ? SqrtPriceMath.getAmount0Delta(frontier, farPrice, liquidity, false)
            : SqrtPriceMath.getAmount1Delta(farPrice, frontier, liquidity, false);
    }

    /// @return proceeds Gross proceeds since the last claim, rounded down: currency1 for asks, currency0 for bids.
    /// @return feePips The range's maker fee.
    function claim(Book storage book, uint256 id, address caller) internal returns (uint256 proceeds, uint24 feePips) {
        Range storage range = book.ranges[id];
        if (range.owner != caller) revert NotOwner();
        uint256 total = proceedsOf(book, id);
        proceeds = total - range.claimed;
        range.claimed = total;
        feePips = range.feePips;
    }

    /// @notice Cumulative gross proceeds of a range, rounded down.
    function proceedsOf(Book storage book, uint256 id) internal view returns (uint256) {
        Range storage range = book.ranges[id];
        uint160 frontier = frontierOf(book, id);
        return range.sell0
            ? SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(range.lower), frontier, range.liquidity, false)
            : SqrtPriceMath.getAmount0Delta(frontier, TickMath.getSqrtPriceAtTick(range.upper), range.liquidity, false);
    }

    /// @notice A range's frontier: the furthest book stop since it was placed, clamped to the range, and fixed
    /// once it is cancelled.
    function frontierOf(Book storage book, uint256 id) internal view returns (uint160 frontier) {
        Range storage range = book.ranges[id];
        frontier = range.frozen;
        if (frontier == 0) (frontier,,) = _frontier(book.sides[range.sell0 ? 0 : 1], range);
    }

    // ---------------------------------------------------------------- walk

    /// @notice Starts a walk at `price`, applying the events exactly there.
    /// @return c The cursor.
    /// @return dead Whether a dead boundary lies exactly at `price` (clear it on commit).
    function begin(Side storage side, bool down, uint160 price) internal view returns (Cursor memory c, bool dead) {
        c.down = down;
        // Stops at or beyond the price form a prefix: their prices fall (rise, walking down) with the index.
        uint256 lo;
        uint256 hi = side.stopCount;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_atOrBeyond(down, side.stops[mid].price, price)) lo = mid + 1;
            else hi = mid;
        }
        c.m = lo;
        dead = _cross(side, c, price);
    }

    /// @notice The next point a walk must stop at: the nearest stop or boundary beyond the cursor, not beyond
    /// `bound`. If `maxWords` (at least 1) bitmap words run out first, the edge of the searched words.
    /// @return point Where to cross next; `bound` when nothing lies before it.
    /// @return found Whether an event lies at `point`.
    function next(Side storage side, Cursor memory c, uint160 bound, uint256 maxWords)
        internal
        view
        returns (uint160 point, bool found)
    {
        point = bound;
        if (c.m != 0) {
            uint160 stopPrice = side.stops[c.m - 1].price;
            if (!_beyond(c.down, stopPrice, point)) (point, found) = (stopPrice, true);
        }
        int24 searched = c.tick;
        for (uint256 i; i < maxWords; ++i) {
            (int24 t, bool initialized) = side.bitmap.nextInitializedTickWithinOneWord(searched, 1, c.down);
            if (t < TickMath.MIN_TICK || t > TickMath.MAX_TICK) return (point, found);
            uint160 p = TickMath.getSqrtPriceAtTick(t);
            if (_beyond(c.down, p, point)) return (point, found);
            if (initialized) return (p, true);
            if (i + 1 == maxWords) return (p, found && p == point); // searched up to here: only a stop can be at `p`
            searched = c.down ? t - 1 : t;
        }
    }

    /// @notice Moves the cursor to `price` and applies the events there; none may lie strictly between. A walk
    /// that ends at an event's price must cross it before `record`.
    /// @return dead Whether a dead boundary lies exactly at `price` (clear it on commit).
    function cross(Side storage side, Cursor memory c, uint160 price) internal view returns (bool dead) {
        if (!_beyond(c.down, price, c.price)) revert NoProgress(); // events at the cursor are already applied
        return _cross(side, c, price);
    }

    /// @notice Clears a boundary a walk found dead: its effect already lives in a stop's G, so it is paid for once.
    function clearDead(Side storage side, int24 tick) internal {
        delete side.boundaries[tick];
        side.bitmap.flipTick(tick, 1);
    }

    /// @notice Ends a walk at the cursor: drops the stops it passed, then appends this one with G = the range
    /// liquidity active beyond it.
    function record(Side storage side, Cursor memory c) internal {
        side.stops[c.m] = Stop(++side.seq, c.price, SafeCast.toUint128(c.liquidity), c.feeLiquidity);
        side.stopCount = c.m + 1;
    }

    // ---------------------------------------------------------------- internals

    function _cross(Side storage side, Cursor memory c, uint160 price) private view returns (bool dead) {
        c.price = price;
        uint64 threshold; // the newest stop at or beyond this price
        bool stopHere;
        if (c.m != 0) {
            Stop storage stop = side.stops[c.m - 1];
            threshold = stop.seq;
            if (stop.price == price) {
                // The ranges that stopped here resume.
                stopHere = true;
                c.liquidity += stop.g;
                c.feeLiquidity += stop.feeG;
            }
        }
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        bool exact = TickMath.getSqrtPriceAtTick(tick) == price;
        if (exact) {
            Boundary storage boundary = side.boundaries[tick];
            if (boundary.tag != 0) {
                if (boundary.tag > threshold) {
                    c.liquidity = _addDelta(c.liquidity, boundary.net);
                    c.feeLiquidity = _addDelta(c.feeLiquidity, boundary.feeNet);
                } else {
                    dead = true; // its effect already lives in a stop's G
                }
            }
        }
        // Boundaries strictly beyond `c.tick` lie ahead (walking down: at or below it).
        c.tick = exact && c.down ? tick - 1 : tick;
        if (stopHere) --c.m;
    }

    /// @dev Adds a liquidity change at `tick`, first resetting a dead value there. A zero result is cleared.
    function _write(Side storage side, bool down, int24 tick, int160 net, int256 feeNet, uint64 seq) private {
        Boundary storage boundary = side.boundaries[tick];
        bool empty = boundary.tag == 0;
        if (!empty && _dead(side, down, tick, boundary.tag)) {
            boundary.net = 0;
            boundary.feeNet = 0;
        }
        int160 total = boundary.net + net;
        int256 feeTotal = boundary.feeNet + feeNet;
        if (total == 0 && feeTotal == 0) {
            delete side.boundaries[tick];
            if (!empty) side.bitmap.flipTick(tick, 1);
            return;
        }
        boundary.net = total;
        boundary.feeNet = feeTotal;
        boundary.tag = seq;
        if (empty) side.bitmap.flipTick(tick, 1);
    }

    /// @dev Whether a stop at or beyond `tick` came after sequence `tag`.
    function _dead(Side storage side, bool down, int24 tick, uint64 tag) private view returns (bool) {
        (bool any, uint256 j) = _firstAfter(side, tag);
        return any && _atOrBeyond(down, side.stops[j].price, TickMath.getSqrtPriceAtTick(tick));
    }

    /// @return frontier The range's frontier.
    /// @return j The stop holding its unsold liquidity, when touched.
    /// @return touched Whether a stop at or beyond its near end came after its placement.
    function _frontier(Side storage side, Range storage range)
        private
        view
        returns (uint160 frontier, uint256 j, bool touched)
    {
        bool down = !range.sell0;
        (int24 near, int24 far) = down ? (range.upper, range.lower) : (range.lower, range.upper);
        frontier = TickMath.getSqrtPriceAtTick(near);
        bool any;
        (any, j) = _firstAfter(side, range.seq);
        if (!any) return (frontier, j, false);
        uint160 furthest = side.stops[j].price;
        if (!_atOrBeyond(down, furthest, frontier)) return (frontier, j, false);
        touched = true;
        uint160 farPrice = TickMath.getSqrtPriceAtTick(far);
        frontier = _beyond(down, furthest, farPrice) ? farPrice : furthest;
    }

    /// @dev The first stop recorded after sequence `seq`: the furthest stop since then.
    function _firstAfter(Side storage side, uint64 seq) private view returns (bool any, uint256 j) {
        uint256 lo;
        uint256 hi = side.stopCount;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (side.stops[mid].seq > seq) hi = mid;
            else lo = mid + 1;
        }
        return (lo < side.stopCount, lo);
    }

    function _addDelta(uint256 x, int256 y) private pure returns (uint256) {
        return y < 0 ? x - uint256(-y) : x + uint256(y);
    }

    function _beyond(bool down, uint160 a, uint160 b) private pure returns (bool) {
        return down ? a < b : a > b;
    }

    function _atOrBeyond(bool down, uint160 a, uint160 b) private pure returns (bool) {
        return down ? a <= b : a >= b;
    }
}
