// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {FixedBook} from "../src/libraries/FixedBook.sol";

/// @dev The fixed-order book alone: no escrow, Kernel or AMM.
contract FixedBookHarness {
    FixedBook.Book internal _book;

    function place(bool sell0, int24 tick, uint64 lots, uint24 feePips) external returns (uint256) {
        return FixedBook.place(_book, msg.sender, sell0, tick, lots, feePips);
    }

    function cancel(uint256 id) external returns (uint64 kept, uint64 refund) {
        return FixedBook.cancel(_book, id, msg.sender);
    }

    function claim(uint256 id) external returns (uint64 lots, uint24 feePips) {
        return FixedBook.claim(_book, id, msg.sender);
    }

    function take(bool sell0, int24 tick, uint256 want, uint256 maxChunks)
        external
        returns (uint256 taken, uint256 feeWeighted)
    {
        return FixedBook.take(_book.sides[sell0 ? 0 : 1], tick, want, maxChunks);
    }

    function available(bool sell0, int24 tick, uint256 maxChunks) external view returns (uint256 lots, bool complete) {
        return FixedBook.available(_book.sides[sell0 ? 0 : 1], tick, maxChunks);
    }

    function filled(uint256 id) external view returns (uint64) {
        return FixedBook.filledLots(_book, id);
    }

    function live(bool sell0, int24 tick) external view returns (uint128) {
        return FixedBook.live(_book.sides[sell0 ? 0 : 1], tick);
    }

    function level(bool sell0, int24 tick) external view returns (FixedBook.Level memory) {
        return _book.sides[sell0 ? 0 : 1].levels[tick];
    }

    /// @dev Tick spacing 1: the bit for `tick` in the side's bitmap.
    function initialized(bool sell0, int24 tick) external view returns (bool) {
        uint256 word = _book.sides[sell0 ? 0 : 1].bitmap[int16(tick >> 8)];
        return word & (1 << uint8(uint24(tick & 0xff))) != 0;
    }
}

contract FixedBookTest is Test {
    struct Model {
        bool sell0;
        int24 tick;
        uint64 placed;
        uint64 size; // lots after any cancellation
        uint64 done;
        uint64 claimed;
        uint64 refunded;
        uint24 fee;
    }

    /// @dev What a fuzz run varies.
    struct Mode {
        bool sameFee; // one fee: chunks fill to 256 orders
        bool oneTick; // all orders at one price: deep chunks
        bool bothSides;
        bool bigLots; // sizes near the 2^56 cap
    }

    uint256 private constant MAX = 900;
    int24[2] private ticks = [int24(-300), int24(4100)];

    /// @dev Running totals per side and price, so checks do not rescan every order.
    struct Totals {
        uint256 placed;
        uint256 refunded;
        uint256 done;
        uint256 live;
    }

    FixedBookHarness private book;
    Model[] private orders;
    uint256[] private ids;
    Mode private mode;
    Totals[2][2] private totals; // [side][price]

    function setUp() public {
        book = new FixedBookHarness();
    }

    /// @dev Random place, cancel, take and claim match a naive FIFO queue per price and side, with lot
    /// conservation checked after every operation. Modes vary fees (same fee fills chunks to 256 orders and
    /// grows full cancellation trees), one or two prices, one or both sides, and sizes up to the cap.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_matchesFifoModel(uint256 seed) public {
        vm.pauseGasMetering();
        mode = Mode(seed & 1 == 1, (seed >> 1) & 1 == 1, (seed >> 2) & 1 == 1, (seed >> 3) & 1 == 1);
        bool deep = mode.sameFee && mode.oneTick;
        uint256 steps = deep ? 1600 : 500;
        for (uint256 step; step < steps; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 8;
            if (op < (deep ? 5 : 3)) _place(r);
            else if (op < 6) _cancel(r);
            else if (op < 7) _take(r);
            else _claim(r);
            _checkConservation();
        }
        for (uint256 i; i < orders.length; ++i) {
            assertEq(book.filled(ids[i]), orders[i].done, "filled");
            (uint64 lots,) = book.claim(ids[i]);
            assertEq(lots, orders[i].done - orders[i].claimed, "final claim");
        }
        _checkLevels();
    }

    /// @dev Cancellations before and after each tree level opens (indices 1, 4, 16, 64), with prefixes
    /// through every lane, then fills checked order by order.
    function test_treeLevelsAndLanes() public {
        uint256[12] memory cancels = [uint256(0), 2, 3, 5, 15, 17, 62, 63, 65, 127, 191, 254];
        for (uint256 i; i < 256; ++i) {
            _record(book.place(true, -300, 3, 3000), true, -300, 3, 3000);
            for (uint256 k; k < cancels.length; ++k) {
                if (cancels[k] == i) _cancelAt(i); // cancel as soon as it exists
            }
        }
        for (uint256 k; k < cancels.length; ++k) {
            _cancelAt(cancels[k] + 1); // and its neighbour once later orders exist
        }
        for (uint256 step; step < 40; ++step) {
            _takeAt(true, -300, 7 + step * 3);
            _checkConservation();
        }
        for (uint256 i; i < orders.length; ++i) {
            assertEq(book.filled(ids[i]), orders[i].done, "filled");
        }
    }

    /// @dev A whole chunk emptied by cancellation, then bounded takes walk through it.
    function test_cancelledChunksAndBoundedTakes() public {
        for (uint256 i; i < 256; ++i) {
            _record(book.place(false, 4100, 2, 3000), false, 4100, 2, 3000);
        }
        _record(book.place(false, 4100, 5, 3000), false, 4100, 5, 3000);
        for (uint256 i; i < 256; ++i) {
            _cancelAt(i);
        }
        (uint256 taken,) = book.take(false, 4100, 1, 1);
        assertEq(taken, 0, "the first visit only skips the empty chunk");
        assertEq(book.level(false, 4100).head, 2);
        _takeAt(false, 4100, 5);
        assertEq(book.level(false, 4100).head, 2, "head stays on the tail");
        _record(book.place(false, 4100, 4, 3000), false, 4100, 4, 3000);
        _takeAt(false, 4100, 4);
        for (uint256 i; i < orders.length; ++i) {
            assertEq(book.filled(ids[i]), orders[i].done, "filled");
        }
        _checkConservation();
    }

    function test_chunkRollsOverAndFeeChangeStartsNewChunk() public {
        for (uint256 i; i < 300; ++i) {
            _record(book.place(true, 100, 10, 3000), true, 100, 10, 3000);
        }
        FixedBook.Level memory l = book.level(true, 100);
        assertEq(l.tail, 2, "chunk 2 opened after 256 orders");
        _record(book.place(true, 100, 7, 5000), true, 100, 7, 5000);
        assertEq(book.level(true, 100).tail, 3, "a fee change opens a chunk");
        _record(book.place(true, 100, 5, 3000), true, 100, 5, 3000);
        assertEq(book.level(true, 100).tail, 4, "and changing back opens another");
        // Take across all four chunks, oldest first.
        (uint256 taken, uint256 feeWeighted) = book.take(true, 100, 3010, 10);
        assertEq(taken, 3010);
        assertEq(feeWeighted, uint256(3000) * 3000 + uint256(7) * 5000 + uint256(3) * 3000);
        _fill(true, 100, 3010);
        for (uint256 i; i < orders.length; ++i) {
            assertEq(book.filled(ids[i]), orders[i].done);
        }
        assertEq(book.live(true, 100), 2);
        assertEq(book.level(true, 100).head, 4, "used-up chunks leave the queue");
    }

    function test_takeVisitsAtMostMaxChunks() public {
        for (uint256 i; i < 600; ++i) {
            book.place(true, 7, 1, 3000);
        }
        (uint256 taken,) = book.take(true, 7, 600, 2);
        assertEq(taken, 512, "two chunks of 256");
        assertEq(book.live(true, 7), 88);
    }

    function test_bitmapFollowsLiveLots() public {
        uint256 a = book.place(false, -50, 4, 3000);
        assertTrue(book.initialized(false, -50));
        book.cancel(a);
        assertFalse(book.initialized(false, -50));
        book.place(false, -50, 4, 3000);
        book.take(false, -50, 4, 4);
        assertFalse(book.initialized(false, -50));
    }

    function test_onlyOwnerCancelsAndClaims() public {
        uint256 id = book.place(true, 0, 1, 0);
        vm.prank(address(0xBEEF));
        vm.expectRevert(FixedBook.NotOwner.selector);
        book.cancel(id);
        vm.prank(address(0xBEEF));
        vm.expectRevert(FixedBook.NotOwner.selector);
        book.claim(id);
    }

    function test_rejectsOutOfRangeOrders() public {
        vm.expectRevert(FixedBook.InvalidAmount.selector);
        book.place(true, 0, 0, 0);
        vm.expectRevert(FixedBook.InvalidAmount.selector);
        book.place(true, 0, FixedBook.MAX_ORDER_LOTS + 1, 0);
        vm.expectRevert(FixedBook.InvalidTick.selector);
        book.place(true, 887_273, 1, 0);
    }

    // ---------------------------------------------------------------- model

    function _place(uint256 r) private {
        if (orders.length == MAX) return;
        bool sell0 = !mode.bothSides || (r >> 7) & 1 == 1;
        int24 tick = mode.oneTick ? ticks[0] : ticks[(r >> 8) & 1];
        uint64 lots = mode.bigLots
            ? FixedBook.MAX_ORDER_LOTS - uint64((r >> 16) % 1000)
            : uint64(1 + (r >> 16) % 1000);
        uint24 fee = mode.sameFee ? 3000 : (r >> 40) % 5 == 0 ? type(uint24).max : 3000;
        _record(book.place(sell0, tick, lots, fee), sell0, tick, lots, fee);
    }

    function _record(uint256 id, bool sell0, int24 tick, uint64 lots, uint24 fee) private {
        ids.push(id);
        orders.push(Model(sell0, tick, lots, lots, 0, 0, 0, fee));
        Totals storage t = _totals(sell0, tick);
        t.placed += lots;
        t.live += lots;
    }

    function _totals(bool sell0, int24 tick) private view returns (Totals storage) {
        return totals[sell0 ? 0 : 1][tick == ticks[0] ? 0 : 1];
    }

    function _cancelAt(uint256 i) private {
        (uint64 kept, uint64 refund) = book.cancel(ids[i]);
        assertEq(kept, orders[i].done, "kept");
        assertEq(refund, orders[i].size - orders[i].done, "refund");
        orders[i].refunded += refund;
        orders[i].size = orders[i].done;
        Totals storage t = _totals(orders[i].sell0, orders[i].tick);
        t.refunded += refund;
        t.live -= refund;
    }

    function _takeAt(bool sell0, int24 tick, uint256 want) private {
        uint256 liveLots = _live(sell0, tick);
        (uint256 taken, uint256 feeWeighted) = book.take(sell0, tick, want, type(uint256).max);
        assertEq(taken, want < liveLots ? want : liveLots, "taken");
        assertEq(feeWeighted, _fill(sell0, tick, taken), "fee-weighted");
    }

    /// @dev Per side and price: placed = refunded + live + filled, and the book's live lots match.
    function _checkConservation() private view {
        for (uint256 s; s < 2; ++s) {
            for (uint256 p; p < 2; ++p) {
                Totals storage t = totals[s][p];
                assertEq(t.placed, t.refunded + t.live + t.done, "conservation");
                assertEq(book.live(s == 0, ticks[p]), t.live, "live");
            }
        }
    }

    function _cancel(uint256 r) private {
        if (orders.length == 0) return;
        _cancelAt((r >> 8) % orders.length);
    }

    function _take(uint256 r) private {
        bool sell0 = !mode.bothSides || (r >> 7) & 1 == 1;
        int24 tick = mode.oneTick ? ticks[0] : ticks[(r >> 8) & 1];
        uint256 want = mode.bigLots ? (r >> 16) % (uint256(FixedBook.MAX_ORDER_LOTS) * 3) : (r >> 16) % 4000;
        // Half the takes are bounded by a chunk allowance, as the walk's are, including zero wants (its cleanup).
        if ((r >> 100) & 1 == 1) {
            _takeBoundedAt(sell0, tick, (r >> 101) % 3 == 0 ? 0 : want, (r >> 104) % 4);
        } else {
            _takeAt(sell0, tick, want == 0 ? 1 : want);
        }
        _checkLevels();
    }

    /// @dev Sol's review: a take bounded by a chunk allowance takes exactly what `available` reports for the same
    /// allowance, which is complete only when it is the whole level; a take of nothing over emptied chunks moves past
    /// them, so repeated walks progress.
    function _takeBoundedAt(bool sell0, int24 tick, uint256 want, uint256 maxChunks) private {
        uint256 liveLots = _live(sell0, tick);
        (uint256 lots, bool complete) = book.available(sell0, tick, maxChunks);
        assertLe(lots, liveLots, "available within live");
        assertEq(complete, lots == liveLots, "complete means the whole level");
        uint64 head = book.level(sell0, tick).head;
        (uint256 taken, uint256 feeWeighted) = book.take(sell0, tick, want, maxChunks);
        assertEq(taken, want < lots ? want : lots, "bounded take matches available");
        assertEq(feeWeighted, _fill(sell0, tick, taken), "fee-weighted");
        if (lots == 0 && !complete && maxChunks != 0) {
            assertGt(book.level(sell0, tick).head, head, "a take over emptied chunks moves past them");
        }
    }

    function _claim(uint256 r) private {
        if (orders.length == 0) return;
        uint256 i = (r >> 8) % orders.length;
        (uint64 lots, uint24 fee) = book.claim(ids[i]);
        assertEq(lots, orders[i].done - orders[i].claimed, "claim");
        assertEq(fee, orders[i].fee, "fee snapshot");
        orders[i].claimed = orders[i].done;
    }

    /// @return feeWeighted The model's lots times fee for the fill.
    function _fill(bool sell0, int24 tick, uint256 lots) private returns (uint256 feeWeighted) {
        for (uint256 i; i < orders.length && lots != 0; ++i) {
            Model storage o = orders[i];
            if (o.tick != tick || o.sell0 != sell0) continue;
            uint256 open = o.size - o.done;
            uint256 t = open < lots ? open : lots;
            o.done += uint64(t);
            lots -= t;
            feeWeighted += t * o.fee;
            Totals storage totalsAt = _totals(sell0, tick);
            totalsAt.done += t;
            totalsAt.live -= t;
        }
    }

    function _live(bool sell0, int24 tick) private view returns (uint256) {
        return _totals(sell0, tick).live;
    }

    function _checkLevels() private view {
        for (uint256 s; s < 2; ++s) {
            for (uint256 t; t < 2; ++t) {
                uint256 liveLots = _live(s == 0, ticks[t]);
                assertEq(book.live(s == 0, ticks[t]), liveLots, "live");
                assertEq(book.initialized(s == 0, ticks[t]), liveLots != 0, "bitmap");
            }
        }
    }
}
