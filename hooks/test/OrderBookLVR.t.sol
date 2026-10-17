// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {CallbackType, ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {OrderBook} from "../src/orderbook/OrderBook.sol";
import {LVRHook} from "../src/lvr/uniswap-v4/LVRHook.sol";
import {BookWalk} from "../src/libraries/orderbook/BookWalk.sol";
import {OrderBookFixture} from "./utils/OrderBookFixture.sol";

/// @dev The order book and LVRHook in one dynamic-fee pool. LVRHook is the required fee owner and runs first in both
/// swap callbacks; the book is optional, last in beforeSwap, and charges LVRHook's fee on its fills.
contract OrderBookLVRTest is OrderBookFixture {
    using StateLibrary for IPoolManager;

    LVRHook internal lvr;

    function setUp() public override {
        super.setUp();
        vm.warp(100);
        lvr = LVRHook(deployCode("LVRHook.sol:LVRHook", abi.encode(IKernelHook(address(hook)))));
        catalog.admit(
            address(lvr),
            IHookCatalog.Entry(address(lvr).codehash, lvr.CALLBACK_MASK(), false, false, false, true, true)
        );
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
    }

    // ---------------------------------------------------------------- order

    function test_lvrRunsBeforeTheBook() public {
        _installBoth(true);
        address[] memory before = hook.callbackOrder(pool, CallbackType.BeforeSwap);
        address[] memory afterOrder = hook.callbackOrder(pool, CallbackType.AfterSwap);
        assertEq(before.length, 2);
        assertEq(before[0], address(lvr));
        assertEq(before[1], address(book));
        assertEq(afterOrder[0], address(lvr));
        assertEq(afterOrder[1], address(book));
        // The other order is refused: the required fee owner must precede the optional book.
        hook.deactivateExtension(key, IHookExtension(address(book)));
        hook.deactivateExtension(key, IHookExtension(address(lvr)));
        address[] memory reversed = new address[](2);
        (reversed[0], reversed[1]) = (address(book), address(lvr));
        vm.expectRevert(IKernelHook.InvalidCallbackOrder.selector);
        hook.setCallbackOrder(key, CallbackType.BeforeSwap, reversed);
    }

    // ---------------------------------------------------------------- fees

    /// @dev After a price move raises LVRHook's fee, book fills pay that fee: the quote at LVRHook's fee matches the
    /// swap exactly, in both directions and modes, and charges more than at the base fee.
    function test_bookFillsPayTheLvrFee() public {
        _installBoth(true);
        _swap(SwapParams(true, -1e16, MIN_LIMIT)); // the AMM moves: LVRHook's window fee rises
        (uint24 fee,,) = lvr.previewFee(pool);
        assertGt(fee, 3000, "LVRHook's fee rose");
        (, int24 tick,,) = manager.getSlot0(pool);
        _placeFixed(true, tick + 5, 1e11);
        _placeFixed(false, tick - 5, 1e11);
        SwapParams[4] memory swaps = [
            SwapParams(false, -5e16, MAX_LIMIT),
            SwapParams(false, 5e16, MAX_LIMIT),
            SwapParams(true, -5e16, MIN_LIMIT),
            SwapParams(true, 5e16, MIN_LIMIT)
        ];
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            BookWalk.Fill memory q = book.quote(key, swaps[i], fee);
            BookWalk.Fill memory atBase = book.quote(key, swaps[i], 3000);
            assertGt(q.takerFee, atBase.takerFee, "the book charges LVRHook's fee, above the base fee");
            vm.recordLogs();
            _swap(swaps[i]);
            (uint256 specified, uint256 other) = _bookFilled();
            assertGt(specified, 0, "the book filled");
            assertEq(specified, q.specified, "execution matches the quote at LVRHook's fee");
            assertEq(other, q.other);
            _checkBacking();
            vm.revertToState(snap);
        }
    }

    /// @dev The book fills a whole swap (asks at the pool price), so the AMM does not run. LVRHook still sets the fee
    /// first and records the unchanged price afterwards.
    function test_bookFillsAWholeSwapUnderLvr() public {
        _installBoth(true);
        _placeFixed(true, 0, 1e6);
        LVRHook.Observation memory before = lvr.observation(pool);
        vm.recordLogs();
        _swap(SwapParams(false, 1e11, MAX_LIMIT));
        (uint256 specified,) = _bookFilled();
        assertEq(specified, 1e11, "the book delivered it all");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, PRICE_1, "the AMM did not run");
        LVRHook.Observation memory after_ = lvr.observation(pool);
        assertEq(after_.lastTick, 0);
        assertEq(after_.windowMovement, before.windowMovement, "no movement recorded");
        _checkBacking();
    }

    /// @dev With LVRHook inactive the pool falls back to its stored base fee, which the admin sets with the Kernel's
    /// setDynamicLPFee; book fills then pay that fee.
    function test_lvrInactiveFallsBackToTheBaseFee() public {
        _installBoth(true);
        hook.setDynamicLPFee(key, 2500);
        hook.deactivateExtension(key, IHookExtension(address(lvr)));
        _placeFixed(true, 5, 1e11);
        SwapParams memory buy = SwapParams(false, 5e16, MAX_LIMIT);
        BookWalk.Fill memory q = book.quote(key, buy, 2500);
        vm.recordLogs();
        _swap(buy);
        (uint256 specified, uint256 other) = _bookFilled();
        assertEq(specified, q.specified);
        assertEq(other, q.other, "the book charged the base fee");
        _checkBacking();
    }

    // ---------------------------------------------------------------- pools with no AMM liquidity

    /// @dev In a pool with no AMM liquidity, the book's afterSwap price move is a nested swap in which LVRHook's
    /// callbacks run. It succeeds, and LVRHook records the book's last trade.
    function test_emptyPoolPriceMoveRunsThroughLvr() public {
        _installBoth(false);
        _placeFixed(true, 100, 1e6);
        vm.recordLogs();
        _swap(SwapParams(false, 1e11, TickMath.getSqrtPriceAtTick(5000))); // the book fills it all
        assertTrue(_emitted(OrderBook.PriceMoved.selector), "moved");
        (, int24 tick,,) = manager.getSlot0(pool);
        assertEq(tick, 100, "at the last trade");
        LVRHook.Observation memory state = lvr.observation(pool);
        assertEq(state.lastTick, 100, "LVRHook saw the move");
        assertEq(state.windowMovement, 100);
        _checkBacking();
    }

    /// @dev Open finding (deferred; hooks/docs/lvr-audit-2026-10-10.md, finding 2), asserting the current behavior: in a
    /// pool with no AMM liquidity, a swap whose remainder runs to a router's extreme
    /// limit (here exact output of whole lots and 5 units) moves the price there and back for free, and LVRHook
    /// records that as the window's movement: its fee jumps to the maximum for the rest of the window, and every book
    /// fill pays it.
    function test_emptyPoolRunawayRaisesTheLvrFeeToItsMaximum() public {
        _installBoth(false);
        _placeFixed(true, 100, 1e6);
        _swap(SwapParams(false, 1e11 + 5, MAX_LIMIT));
        (, int24 tick,,) = manager.getSlot0(pool);
        assertEq(tick, 100, "the price came back to the last trade");
        (uint24 fee,,) = lvr.previewFee(pool);
        assertEq(fee, _lvrPolicy().maximumFee, "LVRHook's fee is at its maximum");
    }

    /// @dev The gas of one swap through LVRHook and the book, with the AMM taking part (logged, not snapshotted).
    function test_gasSwapThroughLvrAndBook() public {
        _installBoth(true);
        _placeFixed(true, 5, 1e11);
        uint256 gas = gasleft();
        _swap(SwapParams(false, -5e16, MAX_LIMIT));
        emit log_named_uint("swap through LVRHook and the book", gas - gasleft());
    }

    // ---------------------------------------------------------------- setup

    function _installBoth(bool ammLiquidity) private {
        if (ammLiquidity) _lp(-6000, 6000, 1e18);
        hook.installExtension(key, IHookExtension(address(lvr)), _lvrSettings(0));
        lvr.setPolicy(key, 0, _lvrPolicy());
        hook.configureExtension(key, IHookExtension(address(lvr)), _lvrSettings(1));
        _installInactive(_settings(), _policy());
        hook.activateExtension(key, IHookExtension(address(lvr)));
        hook.activateExtension(key, IHookExtension(address(book)));
    }

    function _lvrPolicy() private pure returns (LVRHook.Policy memory) {
        return LVRHook.Policy(3000, 10_000, 2000, 10, 60, 10, 2);
    }

    function _lvrSettings(uint64 version) private view returns (ExtensionSettings memory settings) {
        settings.callbackMask = lvr.CALLBACK_MASK();
        settings.lifecycleGasLimit = 500_000;
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 150_000;
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 150_000;
        settings.configuration = abi.encode(version);
    }
}
