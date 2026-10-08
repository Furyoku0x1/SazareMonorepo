// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Fixed-price orders: one FIFO queue per price tick, split into chunks of 256 orders. A fill moves
/// the head chunk's counter; each order's share is resolved from its queue position when it is read.
/// A mid-chunk cancellation shifts later positions in its chunk through a 4-ary prefix-sum tree with three
/// 64-bit lanes per word. Amounts are lots.
/// @dev Shared by the maker library and the swap walk. Each chunk keeps the maker fee in force when it
/// opened, so a fee change starts new chunks and existing orders keep their rate.
library FixedBook {
    using TickBitmap for mapping(int16 => uint256);

    uint256 internal constant CHUNK_ORDERS = 256;
    /// @dev Keeps a full chunk's totals within 64 bits.
    uint64 internal constant MAX_ORDER_LOTS = uint64((1 << 56) - 1);

    error InvalidTick();
    error InvalidAmount();
    error NotOwner();

    struct Chunk {
        uint64 deposited; // queue end: lots placed, less cancellations of the chunk's last order
        uint64 cancelled; // lots removed mid-chunk (the tree total)
        uint64 filled; // lots taken
        uint16 count; // orders placed; the next index
        uint8 depth; // tree levels in use: 4 ** depth >= count
        uint24 feePips; // maker fee for every order in the chunk
    }

    struct Level {
        uint64 head; // first chunk that may hold live lots
        uint64 tail; // newest chunk; new orders join it (64-bit: no practical lifetime cap per price)
        uint128 live; // lots available at this price
    }

    struct Side {
        mapping(int16 => uint256) bitmap; // ticks with live lots
        mapping(int24 => Level) levels;
        mapping(int24 => mapping(uint64 => Chunk)) chunks;
        mapping(int24 => mapping(uint64 => mapping(uint256 => uint256))) trees;
    }

    struct Order {
        address owner;
        int24 tick;
        uint8 index;
        bool sell0;
        uint64 chunk;
        uint64 start; // the chunk's deposited lots when placed
        uint64 lots; // after a cancellation: the lots it kept (its filled lots)
        uint64 claimed; // filled lots already claimed
    }

    struct Book {
        Side[2] sides; // [0] makers sell currency0 (asks); [1] makers sell currency1 (bids)
        mapping(uint256 => Order) orders;
        uint256 nextId;
    }

    function place(Book storage book, address owner, bool sell0, int24 tick, uint64 lots, uint24 feePips)
        internal
        returns (uint256 id)
    {
        if (tick < TickMath.MIN_TICK || tick > TickMath.MAX_TICK) revert InvalidTick();
        if (lots == 0 || lots > MAX_ORDER_LOTS) revert InvalidAmount();
        Side storage side = book.sides[sell0 ? 0 : 1];
        Level memory level = side.levels[tick];
        if (level.live == 0) side.bitmap.flipTick(tick, 1);
        uint64 c = level.tail;
        Chunk memory chunk;
        if (c != 0) chunk = side.chunks[tick][c];
        if (c == 0 || chunk.count == CHUNK_ORDERS || chunk.feePips != feePips) {
            c = ++level.tail;
            if (level.head == 0) level.head = c;
            chunk = Chunk(0, 0, 0, 0, 0, feePips);
        }
        uint8 index = uint8(chunk.count);
        // Index 4 ** depth opens the next tree level; its first lane covers every earlier index.
        if (chunk.count == uint256(1) << (2 * uint256(chunk.depth))) {
            if (chunk.cancelled != 0) side.trees[tick][c][uint256(chunk.depth) << 8] = chunk.cancelled;
            ++chunk.depth;
        }
        id = ++book.nextId;
        book.orders[id] = Order(owner, tick, index, sell0, c, chunk.deposited, lots, 0);
        chunk.deposited += lots;
        ++chunk.count;
        level.live += lots;
        side.chunks[tick][c] = chunk;
        side.levels[tick] = level;
    }

    /// @return kept Filled lots the order keeps.
    /// @return refund Unfilled lots returned.
    function cancel(Book storage book, uint256 id, address caller) internal returns (uint64 kept, uint64 refund) {
        Order storage order = book.orders[id];
        if (order.owner != caller) revert NotOwner();
        kept = filledLots(book, id);
        refund = order.lots - kept;
        if (refund == 0) return (kept, 0);
        Side storage side = book.sides[order.sell0 ? 0 : 1];
        int24 tick = order.tick;
        Chunk memory chunk = side.chunks[tick][order.chunk];
        if (uint256(order.index) + 1 == chunk.count) {
            chunk.deposited -= refund; // the chunk's last order: no later positions to shift
        } else {
            _add(side.trees[tick][order.chunk], order.index, refund, chunk.depth);
            chunk.cancelled += refund;
        }
        side.chunks[tick][order.chunk] = chunk;
        Level storage level = side.levels[tick];
        level.live -= refund;
        if (level.live == 0) side.bitmap.flipTick(tick, 1);
        order.lots = kept;
    }

    /// @return lots Lots filled since the last claim.
    /// @return feePips The order's maker fee.
    function claim(Book storage book, uint256 id, address caller) internal returns (uint64 lots, uint24 feePips) {
        Order storage order = book.orders[id];
        if (order.owner != caller) revert NotOwner();
        uint64 filled = filledLots(book, id);
        lots = filled - order.claimed;
        order.claimed = filled;
        feePips = book.sides[order.sell0 ? 0 : 1].chunks[order.tick][order.chunk].feePips;
    }

    /// @notice Takes up to `want` lots at one price, oldest first, visiting at most `maxChunks` chunks. It also moves
    /// past chunks with nothing left (emptied by cancellations) within that allowance, even when it takes nothing.
    /// @return taken Lots taken.
    /// @return feeWeighted Sum of lots taken times their chunk's maker fee, for fees at fill time.
    function take(Side storage side, int24 tick, uint256 want, uint256 maxChunks)
        internal
        returns (uint256 taken, uint256 feeWeighted)
    {
        Level memory level = side.levels[tick];
        if (want > level.live) want = level.live;
        for (uint256 visits; visits < maxChunks; ++visits) {
            Chunk storage chunk = side.chunks[tick][level.head];
            uint256 free = uint256(chunk.deposited) - chunk.cancelled - chunk.filled;
            if (want == 0 && free != 0) break; // nothing more wanted from a chunk that still has lots
            uint256 t = free < want ? free : want;
            if (t != 0) {
                chunk.filled += uint64(t);
                taken += t;
                feeWeighted += t * chunk.feePips;
                want -= t;
            }
            // Move past a used-up chunk; the newest stays, as new orders join it.
            if (t != free || level.head == level.tail) break;
            ++level.head;
        }
        level.live -= uint128(taken);
        if (taken != 0 && level.live == 0) side.bitmap.flipTick(tick, 1);
        side.levels[tick] = level;
    }

    /// @notice Lots `take` with the same `maxChunks` would take at one price.
    /// @return lots Available lots.
    /// @return complete Whether that is everything at the price.
    function available(Side storage side, int24 tick, uint256 maxChunks)
        internal
        view
        returns (uint256 lots, bool complete)
    {
        Level memory level = side.levels[tick];
        if (level.live == 0) return (0, true);
        uint64 c = level.head;
        for (uint256 visits; visits < maxChunks; ++visits) {
            Chunk memory chunk = side.chunks[tick][c];
            lots += uint256(chunk.deposited) - chunk.cancelled - chunk.filled;
            if (lots == level.live) return (lots, true);
            if (c == level.tail) break;
            ++c;
        }
        return (lots, lots == level.live);
    }

    function filledLots(Book storage book, uint256 id) internal view returns (uint64) {
        Order storage order = book.orders[id];
        uint64 lots = order.lots;
        if (lots == 0) return 0;
        Side storage side = book.sides[order.sell0 ? 0 : 1];
        Chunk memory chunk = side.chunks[order.tick][order.chunk];
        uint256 position = order.start - _prefix(side.trees[order.tick][order.chunk], order.index, chunk.depth);
        if (chunk.filled <= position) return 0;
        uint256 done = chunk.filled - position;
        return done < lots ? uint64(done) : lots;
    }

    function live(Side storage side, int24 tick) internal view returns (uint128) {
        return side.levels[tick].live;
    }

    /// @dev Prefix reads only use lanes 0-2, so lane 3 is never stored.
    function _add(mapping(uint256 => uint256) storage tree, uint256 index, uint256 amount, uint256 depth) private {
        for (uint256 level; level < depth; ++level) {
            uint256 lane = (index >> (2 * level)) & 3;
            if (lane != 3) tree[(level << 8) | (index >> (2 * level + 2))] += amount << (64 * lane);
        }
    }

    /// @dev Lots cancelled mid-chunk ahead of `index`.
    function _prefix(mapping(uint256 => uint256) storage tree, uint256 index, uint256 depth)
        private
        view
        returns (uint256 sum)
    {
        for (uint256 level; level < depth; ++level) {
            uint256 lane = (index >> (2 * level)) & 3;
            if (lane == 0) continue;
            uint256 word = tree[(level << 8) | (index >> (2 * level + 2))];
            for (uint256 i; i < lane; ++i) {
                sum += uint64(word >> (64 * i));
            }
        }
    }
}
