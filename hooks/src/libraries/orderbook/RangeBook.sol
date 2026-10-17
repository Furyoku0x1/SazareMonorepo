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
        uint64 placementSequence; // the side's sequence at placement: only later stops can have crossed it
        uint160 frozen; // frontier at cancellation; 0 while open
        uint256 claimed; // gross proceeds already claimed
    }

    struct Boundary {
        int160 liquidityDelta; // liquidity change when the walk reaches this tick (wider than any sum of capped ranges)
        uint64 tag; // sequence number of the last write
        int256 feeLiquidityDelta; // fee-weighted liquidity change
    }

    struct Stop {
        uint64 sequence;
        uint160 sqrtPriceX96; // Retain this price so future walks and canceled ranges agree on the frontier.
        uint128 liquidity; // range liquidity active just beyond the stop
        uint256 feeLiquidity;
    }

    struct Side {
        mapping(int16 => uint256) bitmap; // boundary ticks
        mapping(int24 => Boundary) boundaries;
        mapping(uint256 => Stop) stops; // from the furthest (oldest) stop to the nearest (newest)
        uint256 stopCount;
        uint64 sequence;
    }

    struct Book {
        Side[2] sides; // [0] asks: makers sell currency0, filled upwards; [1] bids, filled downwards
        mapping(uint256 => Range) ranges;
        uint256 nextId;
    }

    /// @dev A walk over one side; `down` for bids.
    struct Cursor {
        bool down;
        uint160 sqrtPriceX96;
        int24 tick; // boundaries strictly beyond it are ahead (walking down: at or below it)
        uint256 liquidity; // Keep this wide so same-price events can apply in any order before narrowing on record.
        uint256 feeLiquidity;
        uint256 stopIndex; // Stops [0, stopIndex) must be crossed before nearer stops can affect the walk.
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
        if (lower >= upper) revert InvalidRange();
        if (lower < TickMath.MIN_TICK) revert InvalidRange();
        if (upper > TickMath.MAX_TICK) revert InvalidRange();
        if (liquidity == 0) revert InvalidAmount();
        if (liquidity > MAX_RANGE_LIQUIDITY) revert InvalidAmount();
        Side storage side = book.sides[sell0 ? 0 : 1];
        uint64 sequence = ++side.sequence;
        id = ++book.nextId;
        book.ranges[id] = Range(owner, lower, upper, feePips, sell0, liquidity, sequence, 0, 0);
        int256 feeLiquidity = int256(uint256(liquidity) * feePips);
        (int24 nearTick, int24 farTick) = sell0 ? (lower, upper) : (upper, lower);
        _write(side, !sell0, nearTick, int160(int128(liquidity)), feeLiquidity, sequence);
        _write(side, !sell0, farTick, -int160(int128(liquidity)), -feeLiquidity, sequence);
    }

    /// @return refund Unsold amount of the currency the range sells, rounded down.
    function cancel(Book storage book, uint256 id, address caller) internal returns (uint256 refund) {
        Range storage range = book.ranges[id];
        if (range.owner != caller) revert NotOwner();
        if (range.frozen != 0) return 0;
        bool sell0 = range.sell0;
        Side storage side = book.sides[sell0 ? 0 : 1];
        (uint160 frontierSqrtPriceX96, uint256 stopIndex, bool touched) = _frontier(side, range);
        range.frozen = frontierSqrtPriceX96;
        (int24 nearTick, int24 farTick) = sell0 ? (range.lower, range.upper) : (range.upper, range.lower);
        uint160 farSqrtPriceX96 = TickMath.getSqrtPriceAtTick(farTick);
        if (frontierSqrtPriceX96 == farSqrtPriceX96) return 0; // fully sold
        uint128 liquidity = range.liquidity;
        uint64 sequence = ++side.sequence;
        int256 feeLiquidity = int256(uint256(liquidity) * range.feePips);
        if (touched) {
            Stop storage stop = side.stops[stopIndex]; // its unsold part lives in the G of the stop that set its frontier
            stop.liquidity -= liquidity;
            stop.feeLiquidity -= uint256(feeLiquidity);
        } else {
            _write(side, !sell0, nearTick, -int160(int128(liquidity)), -feeLiquidity, sequence); // untouched: its start boundary holds it
        }
        _write(side, !sell0, farTick, int160(int128(liquidity)), feeLiquidity, sequence);
        refund = sell0
            ? SqrtPriceMath.getAmount0Delta(frontierSqrtPriceX96, farSqrtPriceX96, liquidity, false)
            : SqrtPriceMath.getAmount1Delta(farSqrtPriceX96, frontierSqrtPriceX96, liquidity, false);
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
        uint160 frontierSqrtPriceX96 = frontierOf(book, id);
        return range.sell0
            ? SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(range.lower), frontierSqrtPriceX96, range.liquidity, false
            )
            : SqrtPriceMath.getAmount0Delta(
                frontierSqrtPriceX96, TickMath.getSqrtPriceAtTick(range.upper), range.liquidity, false
            );
    }

    /// @notice A range's frontier: the furthest book stop since it was placed, clamped to the range, and fixed
    /// once it is cancelled.
    function frontierOf(Book storage book, uint256 id) internal view returns (uint160 frontierSqrtPriceX96) {
        Range storage range = book.ranges[id];
        frontierSqrtPriceX96 = range.frozen;
        if (frontierSqrtPriceX96 == 0) (frontierSqrtPriceX96,,) = _frontier(book.sides[range.sell0 ? 0 : 1], range);
    }

    // ---------------------------------------------------------------- walk

    /// @notice Starts a walk at `price`, applying the events exactly there.
    /// @return cursor The state needed to resume ranges at the starting price.
    /// @return dead Whether a dead boundary lies exactly at `price` (clear it on commit).
    function begin(Side storage side, bool down, uint160 sqrtPriceX96)
        internal
        view
        returns (Cursor memory cursor, bool dead)
    {
        cursor.down = down;
        // Stops at or beyond the price form a prefix: their prices fall (rise, walking down) with the index.
        uint256 low;
        uint256 high = side.stopCount;
        // At most 256 halvings of side.stopCount (uint256).
        while (low < high) {
            uint256 middle = (low + high) / 2;
            if (_atOrBeyond(down, side.stops[middle].sqrtPriceX96, sqrtPriceX96)) low = middle + 1;
            else high = middle;
        }
        cursor.stopIndex = low;
        dead = _cross(side, cursor, sqrtPriceX96);
    }

    /// @notice The next point a walk must stop at: the nearest stop or boundary beyond the cursor, not beyond
    /// `bound`. If `maxWords` (at least 1) bitmap words run out first, the edge of the searched words.
    /// @return pointSqrtPriceX96 Where to cross next without exceeding the search bound.
    /// @return found Whether an event lies at `point`.
    function next(Side storage side, Cursor memory cursor, uint160 boundSqrtPriceX96, uint256 maxWords)
        internal
        view
        returns (uint160 pointSqrtPriceX96, bool found)
    {
        pointSqrtPriceX96 = boundSqrtPriceX96;
        if (cursor.stopIndex != 0) {
            uint160 stopSqrtPriceX96 = side.stops[cursor.stopIndex - 1].sqrtPriceX96;
            if (!_beyond(cursor.down, stopSqrtPriceX96, pointSqrtPriceX96)) {
                (pointSqrtPriceX96, found) = (stopSqrtPriceX96, true);
            }
        }
        return _nextBoundary(side, cursor, pointSqrtPriceX96, found, maxWords);
    }

    function _nextBoundary(
        Side storage side,
        Cursor memory cursor,
        uint160 pointSqrtPriceX96,
        bool found,
        uint256 maxWords
    ) private view returns (uint160, bool) {
        int24 searched = cursor.tick;
        // i < maxWords, the caller's bitmap-search allowance.
        for (uint256 i; i < maxWords; ++i) {
            (int24 nextTick, bool initialized) = side.bitmap.nextInitializedTickWithinOneWord(searched, 1, cursor.down);
            if (nextTick < TickMath.MIN_TICK) return (pointSqrtPriceX96, found);
            if (nextTick > TickMath.MAX_TICK) return (pointSqrtPriceX96, found);
            uint160 nextSqrtPriceX96 = TickMath.getSqrtPriceAtTick(nextTick);
            if (_beyond(cursor.down, nextSqrtPriceX96, pointSqrtPriceX96)) return (pointSqrtPriceX96, found);
            if (initialized) return (nextSqrtPriceX96, true);
            if (i + 1 == maxWords) return (nextSqrtPriceX96, _stopFound(found, nextSqrtPriceX96, pointSqrtPriceX96));
            searched = cursor.down ? nextTick - 1 : nextTick;
        }
        return (pointSqrtPriceX96, found);
    }

    /// @notice Moves the cursor to `price` and applies the events there; none may lie strictly between. A walk
    /// that ends at an event's price must cross it before `record`.
    /// @return dead Whether a dead boundary lies exactly at `price` (clear it on commit).
    function cross(Side storage side, Cursor memory cursor, uint160 sqrtPriceX96) internal view returns (bool dead) {
        if (!_beyond(cursor.down, sqrtPriceX96, cursor.sqrtPriceX96)) revert NoProgress(); // events at the cursor are already applied
        return _cross(side, cursor, sqrtPriceX96);
    }

    /// @notice Clears a boundary a walk found dead: its effect already lives in a stop's G, so it is paid for once.
    function clearDead(Side storage side, int24 tick) internal {
        delete side.boundaries[tick];
        side.bitmap.flipTick(tick, 1);
    }

    /// @notice Ends a walk at the cursor: drops the stops it passed, then appends this one with G = the range
    /// liquidity active beyond it.
    function record(Side storage side, Cursor memory cursor) internal {
        side.stops[cursor.stopIndex] =
            Stop(++side.sequence, cursor.sqrtPriceX96, SafeCast.toUint128(cursor.liquidity), cursor.feeLiquidity);
        side.stopCount = cursor.stopIndex + 1;
    }

    // ---------------------------------------------------------------- internals

    function _cross(Side storage side, Cursor memory cursor, uint160 sqrtPriceX96) private view returns (bool dead) {
        cursor.sqrtPriceX96 = sqrtPriceX96;
        uint64 threshold; // the newest stop at or beyond this price
        bool stopHere;
        if (cursor.stopIndex != 0) {
            Stop storage stop = side.stops[cursor.stopIndex - 1];
            threshold = stop.sequence;
            if (stop.sqrtPriceX96 == sqrtPriceX96) {
                // The ranges that stopped here resume.
                stopHere = true;
                cursor.liquidity += stop.liquidity;
                cursor.feeLiquidity += stop.feeLiquidity;
            }
        }
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        bool exact = TickMath.getSqrtPriceAtTick(tick) == sqrtPriceX96;
        if (exact) dead = _crossBoundary(side.boundaries[tick], cursor, threshold);
        // Boundaries strictly beyond `c.tick` lie ahead (walking down: at or below it).
        cursor.tick = exact ? (cursor.down ? tick - 1 : tick) : tick;
        if (stopHere) --cursor.stopIndex;
    }

    /// @dev Adds a liquidity change at `tick`, first resetting a dead value there. A zero result is cleared.
    function _write(Side storage side, bool down, int24 tick, int160 net, int256 feeNet, uint64 sequence) private {
        Boundary storage boundary = side.boundaries[tick];
        bool empty = boundary.tag == 0;
        if (!empty) {
            if (_dead(side, down, tick, boundary.tag)) {
                boundary.liquidityDelta = 0;
                boundary.feeLiquidityDelta = 0;
            }
        }
        int160 total = boundary.liquidityDelta + net;
        int256 feeTotal = boundary.feeLiquidityDelta + feeNet;
        if (_emptyBoundary(total, feeTotal)) {
            delete side.boundaries[tick];
            if (!empty) side.bitmap.flipTick(tick, 1);
            return;
        }
        boundary.liquidityDelta = total;
        boundary.feeLiquidityDelta = feeTotal;
        boundary.tag = sequence;
        if (empty) side.bitmap.flipTick(tick, 1);
    }

    /// @dev Whether a stop at or beyond `tick` came after sequence `tag`.
    function _dead(Side storage side, bool down, int24 tick, uint64 tag) private view returns (bool) {
        (bool any, uint256 stopIndex) = _firstAfter(side, tag);
        if (!any) return false;
        return _atOrBeyond(down, side.stops[stopIndex].sqrtPriceX96, TickMath.getSqrtPriceAtTick(tick));
    }

    /// @return frontierSqrtPriceX96 The price used to determine sold and unsold amounts.
    /// @return stopIndex The stop holding unsold liquidity, so cancellation can subtract it there.
    /// @return touched Whether a stop at or beyond its near end came after its placement.
    function _frontier(Side storage side, Range storage range)
        private
        view
        returns (uint160 frontierSqrtPriceX96, uint256 stopIndex, bool touched)
    {
        bool down = !range.sell0;
        (int24 nearTick, int24 farTick) = down ? (range.upper, range.lower) : (range.lower, range.upper);
        frontierSqrtPriceX96 = TickMath.getSqrtPriceAtTick(nearTick);
        bool any;
        (any, stopIndex) = _firstAfter(side, range.placementSequence);
        if (!any) return (frontierSqrtPriceX96, stopIndex, false);
        uint160 furthestSqrtPriceX96 = side.stops[stopIndex].sqrtPriceX96;
        if (!_atOrBeyond(down, furthestSqrtPriceX96, frontierSqrtPriceX96)) {
            return (frontierSqrtPriceX96, stopIndex, false);
        }
        touched = true;
        uint160 farSqrtPriceX96 = TickMath.getSqrtPriceAtTick(farTick);
        frontierSqrtPriceX96 =
            _beyond(down, furthestSqrtPriceX96, farSqrtPriceX96) ? farSqrtPriceX96 : furthestSqrtPriceX96;
    }

    /// @dev The first stop recorded after `sequence`: the furthest stop since then.
    function _firstAfter(Side storage side, uint64 sequence) private view returns (bool any, uint256 stopIndex) {
        uint256 low;
        uint256 high = side.stopCount;
        // At most 256 halvings of side.stopCount (uint256).
        while (low < high) {
            uint256 middle = (low + high) / 2;
            if (side.stops[middle].sequence > sequence) high = middle;
            else low = middle + 1;
        }
        return (low < side.stopCount, low);
    }

    function _addDelta(uint256 amount, int256 delta) private pure returns (uint256) {
        return delta < 0 ? amount - uint256(-delta) : amount + uint256(delta);
    }

    function _beyond(bool down, uint160 firstSqrtPriceX96, uint160 secondSqrtPriceX96) private pure returns (bool) {
        return down ? firstSqrtPriceX96 < secondSqrtPriceX96 : firstSqrtPriceX96 > secondSqrtPriceX96;
    }

    function _atOrBeyond(bool down, uint160 firstSqrtPriceX96, uint160 secondSqrtPriceX96) private pure returns (bool) {
        return down ? firstSqrtPriceX96 <= secondSqrtPriceX96 : firstSqrtPriceX96 >= secondSqrtPriceX96;
    }

    function _crossBoundary(Boundary storage boundary, Cursor memory cursor, uint64 threshold)
        private
        view
        returns (bool dead)
    {
        if (boundary.tag == 0) return false;
        if (boundary.tag <= threshold) return true;
        cursor.liquidity = _addDelta(cursor.liquidity, boundary.liquidityDelta);
        cursor.feeLiquidity = _addDelta(cursor.feeLiquidity, boundary.feeLiquidityDelta);
    }

    function _emptyBoundary(int160 net, int256 feeNet) private pure returns (bool) {
        if (net != 0) return false;
        return feeNet == 0;
    }

    function _stopFound(bool found, uint160 nextSqrtPriceX96, uint160 pointSqrtPriceX96) private pure returns (bool) {
        if (!found) return false;
        return nextSqrtPriceX96 == pointSqrtPriceX96;
    }
}
