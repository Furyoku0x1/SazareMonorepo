// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {OrderBook} from "../src/orderbook/OrderBook.sol";
import {BookOrders} from "../src/libraries/orderbook/BookOrders.sol";
import {OrderBookFixture} from "./utils/OrderBookFixture.sol";

/// @dev Audit round 3: the accepted residual of keeping an empty pool's price at the book's (R3-2, option A, decided
/// 2026-10-11). The move back trades nothing, so liquidity in its path still blocks it (FX-3). Passes while present.
contract AuditPoC3FXTest is OrderBookFixture {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- FX-3: a dust position blocks the move

    /// @dev R2-OB-3's move trades nothing, so any liquidity between the router's limit and the last trade makes it
    /// revert. One unit of liquidity near the top of the range, placed once by anyone, strands a book-only pool at
    /// MAX-1 after a buy the book cannot fill whole (here the griefer's own buy of one lot and five units, exact
    /// output). Then: every ask is refused; no buy can execute (no valid limit above MAX-1); a router-style sell
    /// (limit MIN+1) cannot replay ~350 empty bitmap words within the book's 2.5M gas, fills no bid and runs the price
    /// to MIN; and a router-style buy from there fills no ask either, its input going into the dust position at the top
    /// of the price range. The book stops filling router swaps in both directions until someone swaps the price back
    /// with a moderate limit; takers without an output minimum lose their input to the dust's owner.
    function test_FX3_dustPositionStrandsTheEmptyPool() public {
        _install(_policy());
        uint256 ask = _placeFixed(true, 100, 1e5);
        uint256 bid = _placeFixed(false, -100, 1e5);
        uint256 snapshot = vm.snapshotState();
        // Control without the dust: the pool moves back to the last trade.
        _swap(SwapParams(false, 1e6 + 5, MAX_LIMIT));
        (, int24 tick,,) = manager.getSlot0(pool);
        assertEq(tick, 100, "control: at the last trade");
        vm.revertToState(snapshot);
        _lp(887_000, 887_100, 1); // the griefer's dust, far from the market
        vm.recordLogs();
        _swap(SwapParams(false, 1e6 + 5, MAX_LIMIT)); // one lot and five units, exact output
        assertFalse(_emitted(OrderBook.PriceMoved.selector), "the move crossed the dust and reverted");
        (, tick,,) = manager.getSlot0(pool);
        assertEq(tick, TickMath.MAX_TICK - 1, "stranded at the router's limit");
        vm.prank(MAKER);
        vm.expectRevert(BookOrders.Crossing.selector);
        book.placeFixed(key, true, 110, 1, _version()); // every ask is refused
        // No buy can execute: v4 needs a limit above MAX-1 and below MAX (PriceLimitAlreadyExceeded).
        vm.expectRevert();
        _swap(SwapParams(false, -1e6, MAX_LIMIT));
        // A router-style sell does not reach the bids and runs the price to the bottom.
        (, uint64 bidBefore) = book.fixedOrder(pool, bid);
        vm.recordLogs();
        _swap(SwapParams(true, -1e10, MIN_LIMIT));
        (uint256 specified,,) = _bookFill(vm.getRecordedLogs());
        assertEq(specified, 0, "the book filled nothing");
        (, uint64 bidAfter) = book.fixedOrder(pool, bid);
        assertEq(bidAfter, bidBefore, "the bid at -100 was passed");
        (, tick,,) = manager.getSlot0(pool);
        assertEq(tick, TickMath.MIN_TICK, "now at the bottom");
        // A router-style buy does not reach the asks either; its input goes into the dust position.
        (, uint64 askBefore) = book.fixedOrder(pool, ask);
        BalanceDelta delta = _swap(SwapParams(false, -1e10, MAX_LIMIT));
        (, uint64 askAfter) = book.fixedOrder(pool, ask);
        assertEq(askAfter, askBefore, "the ask at 100 was passed");
        assertEq(delta.amount1(), -1e10, "the taker paid 1e10 of currency1");
        assertEq(delta.amount0(), 0, "and received nothing");
        _checkBacking();
    }
}
