// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ExtensionFixture} from "./utils/ExtensionFixture.sol";
import {FixedBookHarness} from "./FixedBook.t.sol";
import {RangeBookHarness} from "./RangeBook.t.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LimitOrder} from "../src/LimitOrder.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Run --isolate: each call is its own transaction with cold access state.
abstract contract GasRecorder is Test {
    function _group() internal pure virtual returns (string memory) {
        return "OrderBookGas";
    }

    function _record(string memory label) internal {
        Vm.Gas memory measured = vm.lastFrameGas();
        uint256 gross = measured.gasTotalUsed;
        uint256 refund = uint256(uint64(measured.gasRefunded));
        if (refund > gross / 5) refund = gross / 5;
        vm.snapshotValue(_group(), string.concat(label, "_gross"), gross);
        vm.snapshotValue(_group(), string.concat(label, "_net"), gross - refund);
    }
}

/// @dev The fixed-order book alone (FixedBook): no escrow transfers, Kernel or AMM.
contract FixedBookGasTest is GasRecorder {
    FixedBookHarness private book;

    function setUp() public {
        if (!vm.isIsolateMode()) vm.skip(true);
        book = new FixedBookHarness();
    }

    function test_gas_placeNewPriceNewWord() public {
        book.place(true, 100, 10, 3000);
        _record("fixed_place_new_price_new_word");
    }

    function test_gas_placeNewPriceSameWord() public {
        book.place(true, 100, 10, 3000);
        book.place(true, 101, 10, 3000);
        _record("fixed_place_new_price_same_word");
    }

    function test_gas_placeJoinQueue() public {
        book.place(true, 100, 10, 3000);
        book.place(true, 100, 10, 3000);
        _record("fixed_place_join_queue");
    }

    function test_gas_placeNewChunkForFeeChange() public {
        book.place(true, 100, 10, 3000);
        book.place(true, 100, 10, 5000);
        _record("fixed_place_new_chunk");
    }

    function test_gas_cancelChunkLastOrder() public {
        book.place(true, 100, 10, 3000);
        uint256 id = book.place(true, 100, 10, 3000);
        book.cancel(id);
        _record("fixed_cancel_chunk_last_order");
    }

    function test_gas_cancelMidFiveOrders() public {
        _queue(100, 5);
        book.cancel(2);
        _record("fixed_cancel_mid_5_orders_first");
        book.cancel(3);
        _record("fixed_cancel_mid_5_orders_second");
    }

    /// @dev Index 85 (lanes 1,1,1,1) touches all four tree levels of a full chunk.
    function test_gas_cancelMidFullChunk() public {
        _queue(100, 256);
        book.cancel(2);
        _record("fixed_cancel_mid_full_chunk_first");
        book.cancel(3);
        _record("fixed_cancel_mid_full_chunk_second");
        book.cancel(86);
        _record("fixed_cancel_mid_full_chunk_index_85");
    }

    function test_gas_claimAfterFill() public {
        _queue(100, 256);
        book.cancel(2);
        book.take(true, 100, type(uint128).max, 4);
        book.claim(86);
        _record("fixed_claim_index_85_after_cancel");
    }

    function test_gas_takeEmpty() public {
        book.take(true, 100, 10, 4);
        _record("fixed_take_empty");
    }

    function test_gas_takePartialOneOrder() public {
        book.place(true, 100, 10, 3000);
        book.take(true, 100, 5, 4);
        _record("fixed_take_partial_1_order");
    }

    function test_gas_takeFiftyOrders() public {
        _queue(100, 50);
        book.take(true, 100, 500, 4);
        _record("fixed_take_50_orders");
    }

    function test_gas_takeAcrossChunks() public {
        _queue(100, 306);
        book.take(true, 100, 3060, 4);
        _record("fixed_take_306_orders_2_chunks");
    }

    function _queue(int24 tick, uint256 count) private {
        for (uint256 i; i < count; ++i) {
            book.place(true, tick, 10, 3000);
        }
    }
}

/// @dev The range book alone (RangeBook): no escrow, Kernel or AMM. Walks include per-step amounts.
contract RangeBookGasTest is GasRecorder {
    RangeBookHarness private book;

    function _group() internal pure override returns (string memory) {
        return "RangeBookGas";
    }

    function setUp() public {
        if (!vm.isIsolateMode()) vm.skip(true);
        book = new RangeBookHarness();
    }

    function test_gas_placeFirst() public {
        book.place(true, 10, 50, 1e18, 3000);
        _record("range_place_first");
    }

    function test_gas_placeSharedWordAndTick() public {
        book.place(true, 10, 50, 1e18, 3000);
        book.place(true, 50, 90, 1e18, 500);
        _record("range_place_shared_word_and_tick");
    }

    function test_gas_cancelUntouched() public {
        book.place(true, 10, 50, 1e18, 3000);
        book.cancel(1);
        _record("range_cancel_untouched");
    }

    function test_gas_cancelTouched() public {
        book.place(true, 10, 50, 1e18, 3000);
        _walk(true, 0, 30);
        book.cancel(1);
        _record("range_cancel_touched");
    }

    function test_gas_claim() public {
        book.place(true, 10, 50, 1e18, 3000);
        _walk(true, 0, 30);
        book.claim(1);
        _record("range_claim");
    }

    function test_gas_walkEmpty() public {
        _walk(true, 0, 30);
        _record("range_walk_empty");
    }

    function test_gas_walkOneRange() public {
        book.place(true, 10, 50, 1e18, 3000);
        _walk(true, 0, 30);
        _record("range_walk_1_range_first_stop");
        _walk(true, 30, 60);
        _record("range_walk_resume_from_stop");
    }

    /// @dev Ten ranges: twenty boundaries in one bitmap word.
    function test_gas_walkTenRanges() public {
        for (int24 i; i < 10; ++i) {
            book.place(true, 10 + 20 * i, 25 + 20 * i, 1e18, 3000);
        }
        _walk(true, 0, 230);
        _record("range_walk_10_ranges");
    }

    /// @dev A walk over a dead start boundary: the price fell back and the walk passes A's start again.
    function test_gas_walkDeadBoundary() public {
        book.place(true, 10, 100, 1e18, 3000);
        _walk(true, 0, 50);
        book.place(true, 5, 30, 1e18, 3000);
        _walk(true, 0, 70);
        _record("range_walk_dead_boundary_and_stop");
    }

    function _walk(bool sell0, int24 from, int24 to) private {
        book.sweep(sell0, TickMath.getSqrtPriceAtTick(from), TickMath.getSqrtPriceAtTick(to), 8, false);
    }
}

/// @dev 65,536 open orders at one price: 256 full chunks. Setup takes minutes, so it runs only with
/// DEEP_GAS=true: `DEEP_GAS=true forge test --root . --isolate --match-contract FixedBookDeepGasTest`.
contract FixedBookDeepGasTest is GasRecorder {
    FixedBookHarness private book;

    function _group() internal pure override returns (string memory) {
        return "OrderBookDeepGas";
    }

    function setUp() public {
        if (!vm.isIsolateMode() || !vm.envOr("DEEP_GAS", false)) vm.skip(true);
        book = new FixedBookHarness();
        vm.pauseGasMetering(); // 65,536 placements exceed the default test gas limit
        for (uint256 i; i < 65_536; ++i) {
            book.place(true, 100, 1, 3000);
        }
        vm.resumeGasMetering();
    }

    function test_gas_cancelDeepInTheQueue() public {
        book.cancel(65_000);
        _record("fixed_65536_cancel_deep_first");
        book.cancel(65_001);
        _record("fixed_65536_cancel_deep_second");
    }

    function test_gas_takeAcrossAllChunks() public {
        book.take(true, 100, 65_536, 300);
        _record("fixed_65536_take_all_256_chunks");
    }
}

/// @dev Current LimitOrder through the Kernel, including escrow and the AMM swap.
contract LimitOrderGasTest is ExtensionFixture, GasRecorder {
    function setUp() public override {
        if (!vm.isIsolateMode()) vm.skip(true);
        super.setUp();
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, 100e18, 0), "");
        _installOrders(key, _orderPolicy());
    }

    function test_gas_placeFirst() public {
        orders.placeOrder(key, _request(false, 1e15, 1, 1));
        _record("current_place_first");
    }

    function test_gas_placeAppend() public {
        _queue(1);
        LimitOrder.OrderRequest memory request = _request(false, 1e15, 1, 1);
        request.predecessor = 1;
        orders.placeOrder(key, request);
        _record("current_place_append");
    }

    function test_gas_cancel() public {
        _queue(2);
        orders.cancelOrder(pool, 1);
        _record("current_cancel_head");
    }

    function test_gas_swapNoOrders() public {
        _swapExactInput(key, true, 1e16);
        _record("current_swap_no_orders");
    }

    function test_gas_swapFillOne() public {
        _queue(1);
        _swapExactInput(key, true, 1e16);
        _record("current_swap_fill_1");
    }

    function test_gas_swapFillFour() public {
        _queue(4);
        _swapExactInput(key, true, 1e16);
        _record("current_swap_fill_4");
    }

    function test_gas_claim() public {
        _queue(1);
        _swapExactInput(key, true, 1e16);
        (uint256 proceeds,) = orders.claimable(pool, address(this), currency0);
        orders.claim(pool, currency0, proceeds, address(this));
        _record("current_claim");
    }

    function _queue(uint256 count) private {
        LimitOrder.OrderRequest memory request = _request(false, 1e15, 1, 1);
        for (uint256 i; i < count; ++i) {
            request.predecessor = orders.placeOrder(key, request);
        }
    }
}
