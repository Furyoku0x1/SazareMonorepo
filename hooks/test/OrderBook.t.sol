// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {HookCatalog} from "core/src/HookCatalog.sol";
import {KernelHookVault} from "core/src/KernelHookVault.sol";
import {KernelHook} from "core/src/KernelHook.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {ExtensionSettings, CallbackType, CALLBACK_COUNT} from "core/src/types/KernelHookTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IKernelHookExtension} from "core/src/interfaces/IKernelHookExtension.sol";
import {CallbackResult, ExecutionContext} from "core/src/types/KernelHookTypes.sol";
import {OrderBook, IWETH} from "../src/orderbook/OrderBook.sol";
import {BookWalk} from "../src/libraries/orderbook/BookWalk.sol";
import {KernelExtension} from "../src/base/KernelExtension.sol";
import {BookOrders, IDepositVault} from "../src/libraries/orderbook/BookOrders.sol";
import {FixedBook} from "../src/libraries/orderbook/FixedBook.sol";
import {RangeBook} from "../src/libraries/orderbook/RangeBook.sol";

import {
    OrderBookFixture,
    FeeOverrider,
    ExecutorGift,
    UnitSwapTax,
    TwoSwaps,
    GasBurner
} from "./utils/OrderBookFixture.sol";

/// @dev The order book extension through the Kernel, against a real PoolManager.
contract OrderBookTest is OrderBookFixture {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- swaps

    /// @dev Exact input through a range and a fixed level above the pool price: the taker pays the book's input plus
    /// the AMM's, and the book's part equals its quote.
    function test_exactInputFillsBookAndAmm() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 fixedId = _placeFixed(true, 100, 1e11); // 1e17 of currency0 at lot size 1e6
        uint256 rangeId = _placeRange(true, 50, 600, 1e18);
        SwapParams memory params = SwapParams(false, -2e17, MAX_LIMIT);
        BookWalk.Fill memory q = book.quote(key, params, 3000);
        BalanceDelta delta = _swap(params);
        assertEq(uint256(int256(-delta.amount1())), 2e17, "paid the exact input");
        (FixedBook.Order memory order, uint64 filled) = book.fixedOrder(pool, fixedId);
        assertEq(filled, order.lots, "fixed level filled");
        (, uint160 frontier) = book.rangeOrder(pool, rangeId);
        assertGt(frontier, TickMath.getSqrtPriceAtTick(50), "range partly sold");
        OrderBook.Ledger memory l = book.ledger(pool);
        assertEq(l.escrow[0] + q.other, 1e17 + _rangeDeposit(true, 50, 600, 1e18), "book output left escrow");
        assertGt(q.specified, 0);
        _checkBacking();
    }

    function test_exactOutputFillsBookAndAmm() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        _placeFixed(true, 100, 1e11);
        _placeRange(true, 50, 600, 1e18);
        SwapParams memory params = SwapParams(false, 15e16, MAX_LIMIT);
        BalanceDelta delta = _swap(params);
        assertEq(uint256(int256(delta.amount0())), 15e16, "received the exact output");
        _checkBacking();
    }

    /// @dev Makers' net claims: gross proceeds less the maker fee rounded up; the fee and the taker fee's split; the
    /// LPs' share released over a period and donated after later swaps.
    function test_feesClaimsAndDonation() public {
        _lp(-6000, 6000, 1e18);
        OrderBook.Policy memory p = _policy();
        _install(p);
        uint256 id = _placeFixed(true, 100, 1e11);
        vm.recordLogs();
        _swap(SwapParams(false, -2e17, MAX_LIMIT)); // the price stays inside the LP range
        assertFalse(_emitted(OrderBook.LpFeesDonated.selector), "the LPs' share is not released yet");
        vm.recordLogs();
        _donateReleased();
        assertTrue(_emitted(OrderBook.LpFeesDonated.selector), "LP share donated");
        OrderBook.Ledger memory l = book.ledger(pool);
        assertEq(l.lpFees[1], 0, "nothing left to donate");
        assertGt(l.treasury[1], 0, "treasury share");
        // The maker's net: proceeds of 1e17 at tick 100's price, less 0.3% rounded up.
        uint160 price = TickMath.getSqrtPriceAtTick(100);
        uint256 gross = FullMath.mulDiv(1e17, uint256(price) * price, 1 << 192);
        uint256 expected = gross - FullMath.mulDivRoundingUp(gross, 3000, 1e6);
        vm.prank(MAKER);
        uint256 net = book.claimFixed(pool, id, MAKER);
        assertEq(net, expected, "net claim");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(MAKER), 1e30 + net);
        // The treasury withdraws its share.
        uint256 owed = book.ledger(pool).treasury[1];
        vm.prank(TREASURY);
        book.withdrawTreasury(pool, currency1, owed, TREASURY, false);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(TREASURY), owed);
        _checkBacking();
    }

    /// @dev A pool with no AMM liquidity: the book fills the whole swap although the PoolManager never held the input,
    /// and the price then moves to the book's frontier, where LPs can add liquidity at the market price.
    function test_zeroLiquidityPool() public {
        _install(_policy());
        _placeFixed(true, 200, 1e11);
        _placeFixed(false, -200, 1e11);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(manager)), 0, "no float");
        BalanceDelta delta = _swap(SwapParams(false, -5e16, MAX_LIMIT));
        assertEq(uint256(int256(-delta.amount1())), 5e16);
        assertGt(delta.amount0(), 0);
        (uint160 price, int24 tick,,) = manager.getSlot0(pool);
        assertEq(price, TickMath.getSqrtPriceAtTick(200), "price moved to the book");
        assertEq(tick, 200);
        _lp(140, 260, 1e18); // LPs enter at the market price
        _swap(SwapParams(true, -1e16, MIN_LIMIT));
        _checkBacking();
    }

    function test_postOnly() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        vm.startPrank(MAKER);
        vm.expectRevert(BookOrders.Crossing.selector);
        book.placeFixed(key, true, -10, 1, _version());
        vm.expectRevert(BookOrders.Crossing.selector);
        book.placeFixed(key, false, 10, 1, _version());
        vm.expectRevert(BookOrders.Crossing.selector);
        book.placeRange(key, true, -10, 100, 1e18, _version());
        vm.stopPrank();
        // A bid behind the pool price bounds new asks.
        _placeFixed(false, 0, 1e5);
        (uint160[2] memory start,) = book.bookBounds(pool);
        assertEq(start[1], PRICE_1);
        _placeFixed(true, 0, 1e5); // at the bid: allowed, the book does not match makers
    }

    function test_cancelRefundsAndUninstall() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 fixedId = _placeFixed(true, 100, 1e11);
        uint256 rangeId = _placeRange(true, 50, 600, 1e18);
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        vm.startPrank(MAKER);
        uint256 refund = book.cancelRange(pool, rangeId, MAKER);
        assertGt(refund, 0);
        book.cancelFixed(pool, fixedId, MAKER);
        book.claimRange(pool, rangeId, MAKER);
        book.claimFixed(pool, fixedId, MAKER);
        vm.stopPrank();
        assertEq(book.ledger(pool).openOrders, 0, "settled");
        _checkBacking();
        book.sweep(pool);
        OrderBook.Ledger memory l = book.ledger(pool);
        vm.startPrank(TREASURY);
        if (l.treasury[0] != 0) book.withdrawTreasury(pool, currency0, l.treasury[0], TREASURY, false);
        if (l.treasury[1] != 0) book.withdrawTreasury(pool, currency1, l.treasury[1], TREASURY, false);
        vm.stopPrank();
        _donateReleased();
        assertEq(book.ledger(pool).lpFees[0] + book.ledger(pool).lpFees[1], 0, "LP shares donated");
        hook.deactivateExtension(key, IHookExtension(address(book)));
        hook.removeExtension(key, IHookExtension(address(book)));
        assertFalse(hook.isInstalled(pool, address(book)));
    }

    /// @dev Native currency: a bid sells currency1 for ETH; the treasury takes its ETH share as WETH.
    function test_nativeTreasuryAsWeth() public {
        key = PoolKey(Currency.wrap(address(0)), currency1, 3000, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        vm.deal(address(this), 100 ether);
        lpRouter.modifyLiquidity{value: 10 ether}(key, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
        _install(_policy());
        _placeFixed(false, -100, 1e11);
        swapRouter.swap{value: 5e17}(
            key, SwapParams(true, -5e17, MIN_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 owed = book.ledger(pool).treasury[0];
        assertGt(owed, 0);
        vm.prank(TREASURY);
        book.withdrawTreasury(pool, Currency.wrap(address(0)), owed, TREASURY, true);
        assertEq(weth.balanceOf(TREASURY), owed);
        _checkBacking();
    }

    /// @dev A fee change applies to new orders only: each keeps the rate in force when placed.
    function test_makerFeeKeptPerOrder() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 first = _placeFixed(true, 100, 1e10);
        OrderBook.Policy memory p = _policy();
        p.makerFeePips = 10_000;
        hook.deactivateExtension(key, IHookExtension(address(book)));
        book.setPolicy(key, 1, p);
        ExtensionSettings memory settings = _settings();
        settings.configuration = abi.encode(uint64(2));
        hook.configureExtension(key, IHookExtension(address(book)), settings);
        hook.activateExtension(key, IHookExtension(address(book)));
        uint256 second = _placeFixed(true, 100, 1e10);
        (FixedBook.Order memory a,) = book.fixedOrder(pool, first);
        (FixedBook.Order memory b,) = book.fixedOrder(pool, second);
        assertEq(a.chunk + 1, b.chunk, "a fee change starts a new chunk");
        _swap(SwapParams(false, -5e17, MAX_LIMIT));
        vm.startPrank(MAKER);
        uint256 netFirst = book.claimFixed(pool, first, MAKER);
        uint256 netSecond = book.claimFixed(pool, second, MAKER);
        vm.stopPrank();
        assertGt(netFirst, netSecond, "the later order pays 1%");
        _checkBacking();
    }

    /// @dev An ask selling native currency: the deposit's msg.value passes through the order library's delegatecall.
    function test_nativeAskDeposit() public {
        key = PoolKey(Currency.wrap(address(0)), currency1, 3000, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        vm.deal(address(this), 100 ether);
        lpRouter.modifyLiquidity{value: 10 ether}(key, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
        _install(_policy());
        vm.deal(MAKER, 1 ether);
        vm.prank(MAKER);
        vm.expectRevert(BookOrders.InvalidAmount.selector);
        book.placeFixed{value: 1}(key, true, 100, 1e5, _version());
        vm.prank(MAKER);
        uint256 id = book.placeFixed{value: 1e11}(key, true, 100, 1e5, _version());
        _swap(SwapParams(false, -5e16, MAX_LIMIT));
        (FixedBook.Order memory order, uint64 filled) = book.fixedOrder(pool, id);
        assertEq(filled, order.lots, "ETH sold");
        vm.prank(MAKER);
        assertGt(book.claimFixed(pool, id, MAKER), 0);
        _checkBacking();
    }

    /// @dev An earlier extension overrides the LP fee in a dynamic-fee pool: the book charges takers that fee.
    function test_feeOverrideFromEarlierExtension() public {
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        _lp(-6000, 6000, 1e18);
        FeeOverrider overrider = new FeeOverrider(10_000);
        uint16 beforeSwap = uint16(1) << uint8(CallbackType.BeforeSwap);
        catalog.admit(
            address(overrider),
            IHookCatalog.Entry(address(overrider).codehash, beforeSwap, true, false, false, true, true)
        );
        ExtensionSettings memory settings;
        settings.callbackMask = beforeSwap;
        settings.optionalCallbacks = true;
        settings.lifecycleGasLimit = 500_000;
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 200_000;
        hook.installExtension(key, IHookExtension(address(overrider)), settings);
        // Both install before either activates: an active beforeSwap subscriber freezes the order.
        ExtensionSettings memory bookSettings = _settings();
        bookSettings.configuration = abi.encode(uint64(0));
        hook.installExtension(key, IHookExtension(address(book)), bookSettings);
        book.setPolicy(key, 0, _policy());
        bookSettings.configuration = abi.encode(uint64(1));
        hook.configureExtension(key, IHookExtension(address(book)), bookSettings);
        hook.activateExtension(key, IHookExtension(address(overrider)));
        hook.activateExtension(key, IHookExtension(address(book)));
        _placeFixed(true, 100, 1e11);
        SwapParams memory params = SwapParams(false, -2e17, MAX_LIMIT);
        BookWalk.Fill memory withOverride = book.quote(key, params, 10_000);
        BookWalk.Fill memory withoutOverride = book.quote(key, params, 0);
        vm.recordLogs();
        _swap(params);
        (uint256 specified,) = _bookFilled();
        assertEq(specified, withOverride.specified, "the swap's fee is the override");
        assertTrue(withOverride.takerFee > withoutOverride.takerFee);
        _checkBacking();
    }

    /// @dev The book's callback has too little gas for its walk: the gas guard stops it cleanly with no fill, so the
    /// Kernel does not skip it, and the swap goes to the AMM.
    function test_gasGuardLeavesTheSwapToTheAmm() public {
        _lp(-6000, 6000, 1e18);
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 120_000; // below the policy's 300,000 reserve
        _installWith(settings, _policy());
        uint256 id = _placeFixed(true, 100, 1e11);
        vm.recordLogs();
        BalanceDelta delta = _swap(SwapParams(false, -2e17, MAX_LIMIT));
        assertFalse(_skipped(), "a clean stop, not a skip");
        assertEq(uint256(int256(-delta.amount1())), 2e17, "the swap went through");
        (, uint64 filled) = book.fixedOrder(pool, id);
        assertEq(filled, 0, "no fill");
        _checkBacking();
    }

    /// @dev Sol's review: a failure after the book's commit, here in the Kernel's settlement of its output, skips the
    /// book and rolls back all of its writes; the swap goes to the AMM, and the next swap fills the order.
    function test_bookFailureRollsBack() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 id = _placeFixed(true, 100, 1e11);
        (uint160[2] memory start,) = book.bookBounds(pool);
        OrderBook.Ledger memory before = book.ledger(pool);
        address vault = address(hook.VAULT());
        vm.mockCallRevert(
            vault, abi.encodeWithSelector(KernelHookVault.settleDebtFor.selector, pool, address(book)), ""
        );
        vm.recordLogs();
        BalanceDelta delta = _swap(SwapParams(false, -2e17, MAX_LIMIT));
        assertTrue(_skipped(), "the book was skipped");
        assertEq(uint256(int256(-delta.amount1())), 2e17, "the swap went through");
        (, uint64 filled) = book.fixedOrder(pool, id);
        assertEq(filled, 0, "fills rolled back");
        (uint160[2] memory startAfter,) = book.bookBounds(pool);
        assertEq(startAfter[0], start[0], "start rolled back");
        assertEq(keccak256(abi.encode(book.ledger(pool))), keccak256(abi.encode(before)), "ledger rolled back");
        _checkBacking();
        vm.clearMockedCalls();
        _swap(SwapParams(false, -2e17, MAX_LIMIT));
        (, filled) = book.fixedOrder(pool, id);
        assertGt(filled, 0, "the next swap fills the order");
        _checkBacking();
    }

    /// @dev Sol's review: an earlier extension that charges the book's empty-pool price move took it from the book's
    /// vault without the ledger. A move that trades anything now rolls back.
    function test_priceMoveThatIsChargedRollsBack() public {
        _taxedPriceMove(1);
    }

    /// @dev The same with a credit, which would leave the vault above the ledger.
    function test_priceMoveThatIsCreditedRollsBack() public {
        _taxedPriceMove(-1);
    }

    function _taxedPriceMove(int128 amount) private {
        UnitSwapTax tax = new UnitSwapTax(amount);
        uint16 beforeSwap = uint16(1) << uint8(CallbackType.BeforeSwap);
        catalog.admit(
            address(tax), IHookCatalog.Entry(address(tax).codehash, beforeSwap, true, false, false, true, true)
        );
        ExtensionSettings memory settings;
        settings.callbackMask = beforeSwap;
        settings.optionalCallbacks = true;
        settings.lifecycleGasLimit = 500_000;
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 200_000;
        hook.installExtension(key, IHookExtension(address(tax)), settings);
        MockERC20(Currency.unwrap(currency0)).mint(address(tax), 1e6);
        tax.fund(address(hook.VAULT()), pool, currency0, 1e6);
        _installInactive(_settings(), _policy());
        hook.activateExtension(key, IHookExtension(address(tax)));
        hook.activateExtension(key, IHookExtension(address(book)));
        _placeFixed(true, 200, 1e11);
        vm.recordLogs();
        _swap(SwapParams(false, -5e16, MAX_LIMIT));
        assertFalse(_emitted(OrderBook.PriceMoved.selector), "no price move");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, PRICE_1, "the price stays");
        _checkBacking();
    }

    /// @dev Sol's review: an extension could pay the route executor directly during the price move, which credited
    /// the book's vault although the swap's own delta was zero. The Kernel now refuses such an attempt (its
    /// accounting check sees a delta it did not settle) and skips the extension; the move goes through with the
    /// vault matching the ledger. (The book's own vault check still backs this up; the donation test reaches it.)
    function test_priceMoveWithAPaymentToTheExecutorRollsBack() public {
        ExecutorGift gift = _gift(CallbackType.BeforeSwap, false);
        _installInactive(_settings(), _policy());
        hook.activateExtension(key, IHookExtension(address(gift)));
        hook.activateExtension(key, IHookExtension(address(book)));
        uint256 id = _placeFixed(true, 200, 1e11);
        _expectGift();
        vm.recordLogs();
        _swap(SwapParams(false, -5e16, MAX_LIMIT));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_giftSkippedIn(logs, address(gift)), "the Kernel skipped the paying extension");
        (, uint64 filled) = book.fixedOrder(pool, id);
        assertGt(filled, 0, "the fill stays");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, TickMath.getSqrtPriceAtTick(200), "the move went through");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(gift)), 1e6, "the payment rolled back");
        _checkBacking();
    }

    /// @dev The same during the LP donation, with the payment in the donated currency after the donation's debt exists
    /// (afterDonate): the executor's delta changes value but not its count, which the Kernel's check does not see,
    /// so the book's own check rolls the donation back. It would have cost the book less than it booked.
    function test_donationWithAPaymentToTheExecutorRollsBack() public {
        _lp(-6000, 6000, 1e18);
        ExecutorGift gift = _gift(CallbackType.AfterDonate, true);
        hook.activateExtension(key, IHookExtension(address(gift)));
        _install(_policy());
        _placeFixed(true, 100, 1e11);
        _swap(SwapParams(false, -5e16, MAX_LIMIT)); // an LP share to release
        vm.warp(block.timestamp + 1 days);
        _expectGift();
        vm.recordLogs();
        _swap(SwapParams(false, -2e17, MAX_LIMIT));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_skippedIn(logs), "the book ran");
        assertTrue(_emittedIn(logs, OrderBook.BookFilled.selector), "the book filled");
        assertFalse(_emittedIn(logs, OrderBook.LpFeesDonated.selector), "no donation");
        uint256 pending = book.ledger(pool).lpFees[1];
        assertGt(pending, 0, "the LPs' share kept for later");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(gift)), 1e6, "the payment rolled back");
        _checkBacking();
        hook.deactivateExtension(key, IHookExtension(address(gift)));
        vm.recordLogs();
        _donateReleased();
        assertTrue(_emitted(OrderBook.LpFeesDonated.selector), "the retry donates");
        assertEq(book.ledger(pool).lpFees[1], 0, "the kept share donated");
        _checkBacking();
    }

    function _giftSkippedIn(Vm.Log[] memory logs, address gift) private view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook) && logs[i].topics[0] == IKernelHook.ExtensionSkipped.selector
                    && logs[i].topics[2] == bytes32(uint256(uint160(gift)))
            ) return true;
        }
        return false;
    }

    function _gift(CallbackType callback, bool pay1) private returns (ExecutorGift gift) {
        gift = new ExecutorGift(manager, pay1);
        uint16 mask = uint16(1) << uint8(callback);
        catalog.admit(address(gift), IHookCatalog.Entry(address(gift).codehash, mask, true, false, false, true, true));
        ExtensionSettings memory settings;
        settings.callbackMask = mask;
        settings.optionalCallbacks = true;
        settings.lifecycleGasLimit = 500_000;
        settings.callbackGasLimits[uint8(callback)] = 200_000;
        hook.installExtension(key, IHookExtension(address(gift)), settings);
        MockERC20(Currency.unwrap(pay1 ? currency1 : currency0)).mint(address(gift), 1e6);
    }

    /// @dev The extension's payment reaches the PoolManager, for the route executor.
    function _expectGift() private {
        vm.expectCall(address(manager), abi.encodeCall(IPoolManager.settleFor, (address(hook.ROUTE_EXECUTOR()))));
    }

    /// @dev Sol's review: a frontier recorded by a swap whose afterSwap was skipped reached a later swap's afterSwap in
    /// the same transaction. Each beforeSwap now replaces its depth's record. Since round 3 (R3-2) an empty pool's price
    /// is the book's: the second swap, which the book does not fill, returns the price to the pool's last trade in the
    /// transaction, the first swap's, whose own move was skipped.
    function test_skippedAfterSwapLeavesNoFrontier() public {
        GasBurner burner = _installBurner();
        _installInactive(_settingsBesideBurner(), _policy());
        hook.activateExtension(key, IHookExtension(address(burner)));
        hook.activateExtension(key, IHookExtension(address(book)));
        uint256 id = _placeFixed(true, 200, 1e11);
        TwoSwaps swaps = new TwoSwaps(swapRouter, currency0, currency1);
        MockERC20(Currency.unwrap(currency0)).mint(address(swaps), 1e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(swaps), 1e18);
        uint160 limit = TickMath.getSqrtPriceAtTick(-100);
        burner.setBurn(3_100_000); // leaves too little of the afterSwap budget for the book
        vm.recordLogs();
        // The first swap fills the book, whose afterSwap the Kernel then skips. The second, after the burner stops and
        // which the book does not fill, moves the empty AMM to its limit.
        swaps.run(
            key,
            SwapParams(false, -5e16, MAX_LIMIT),
            address(burner),
            abi.encodeCall(burner.setBurn, (0)),
            SwapParams(true, -1e6, limit)
        );
        assertTrue(_skipped(), "the first afterSwap skipped");
        (, uint64 filled) = book.fixedOrder(pool, id);
        assertGt(filled, 0, "the first swap filled the book");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, TickMath.getSqrtPriceAtTick(200), "at the book's last trade, not the second swap's limit");
        _checkBacking();
    }

    /// @dev Exact input worth less than one lot, with the pool price at a partly filled level: the AMM takes it and
    /// the taker receives its output; the book's reserve gets nothing. (The book used to keep all of it.)
    function test_subLotExactInputGoesToTheAmm() public {
        _lp(-6000, 6000, 1e18);
        OrderBook.Policy memory p = _policy();
        p.lotSize0 = 1e12;
        _install(p);
        uint256 id = _placeFixed(true, 100, 1000);
        _swap(SwapParams(false, -55e14, MAX_LIMIT)); // up to the level and part of it
        (, uint64 filled) = book.fixedOrder(pool, id);
        assertGt(filled, 0);
        assertLt(filled, 1000);
        BalanceDelta delta = _swap(SwapParams(false, -5e11, MAX_LIMIT)); // about half a lot's cost
        assertEq(delta.amount1(), -5e11);
        assertGt(delta.amount0(), 0, "the taker received the AMM's output");
        (, uint64 after_) = book.fixedOrder(pool, id);
        assertEq(after_, filled, "no lot filled");
        assertEq(book.ledger(pool).reserve[1], 0, "nothing kept");
        _checkBacking();
    }

    // ---------------------------------------------------------------- audit regressions

    /// @dev Round 4, R4-3 (reviewer B4): a gasReserve of 100,000 or 150,000 did not cover the commit and settlement
    /// after a gas stop, so the book ran out of gas and was skipped. The policy's floor is now 200,000, where a busy,
    /// cold book under a 600k beforeSwap limit is never skipped.
    function test_regression_gasReserveFloorCoversTheSettlement() public {
        assertEq(_skipsWithReserve(200_000), 0, "never skipped at the floor");
        hook.deactivateExtension(key, IHookExtension(address(book)));
        OrderBook.Policy memory policy = _policy();
        policy.gasReserve = 199_999;
        uint64 version = _version();
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        book.setPolicy(key, version, policy);
    }

    /// @dev Sixty ask levels, each a range and a one-lot order, read cold; one exact-input and one exact-output buy.
    function _skipsWithReserve(uint32 gasReserve) private returns (uint256 skips) {
        _lp(-6000, 6000, 1e18);
        OrderBook.Policy memory policy = _policy();
        policy.gasReserve = gasReserve;
        _install(policy);
        // i <= 60 levels
        for (uint256 i = 1; i <= 60; ++i) {
            _placeRange(true, int24(int256(10 * i)), 6000, 1e15);
            _placeFixed(true, int24(int256(10 * i)), 1);
        }
        _setBeforeSwapGas(600_000);
        // mode < 2: exact input, then exact output
        for (uint256 mode; mode < 2; ++mode) {
            uint256 snapshot = vm.snapshotState();
            _coolAll();
            vm.recordLogs();
            _swap(mode == 0 ? SwapParams(false, -2e17, MAX_LIMIT) : SwapParams(false, 15e16, MAX_LIMIT));
            if (_skippedIn(vm.getRecordedLogs())) ++skips;
            vm.revertToState(snapshot);
        }
    }

    /// @dev Audit (critical): a buy with its price limit below the pool price, filled whole by the book, so v4 never
    /// checked the limit; the walk priced the range downward and sold maker escrow far below the ask. The book now
    /// refuses the limit, and v4 rejects the swap; the maker's deposit stays whole.
    function test_regression_wrongSidePriceLimitIsRefused() public {
        key = PoolKey(currency0, currency1, 0, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(14_000));
        _install(_policy());
        uint256 id = _placeRange(true, 14_000, 14_010, 1e12);
        uint160 below = TickMath.getSqrtPriceAtTick(13_999);
        uint256 out = SqrtPriceMath.getAmount1Delta(below, TickMath.getSqrtPriceAtTick(14_000), 1e12, false);
        SwapParams memory params = SwapParams(false, int256(out), below);
        assertEq(book.quote(key, params, 0).specified, 0, "the quote fills nothing");
        vm.expectRevert();
        _swap(params);
        vm.prank(MAKER);
        assertEq(book.cancelRange(pool, id, MAKER), _rangeDeposit(true, 14_000, 14_010, 1e12) - 1, "deposit intact");
        _checkBacking();
    }

    /// @dev Audit: 128 one-lot asks inside one AMM step used to run the book out of gas on every swap, so the AMM
    /// passed them all. The walk now stops loading points while it can still commit them (a `GAS` stop) and fills
    /// those; repeated swaps work through the whole cluster.
    function test_regression_denseBookFillsWithinItsGas() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256[] memory ids = new uint256[](128);
        for (uint256 i; i < 128; ++i) {
            ids[i] = _placeFixed(true, int24(int256(10 * (i + 1))), 1);
        }
        _coolAll();
        vm.recordLogs();
        _swap(SwapParams(false, -1e17, MAX_LIMIT));
        assertFalse(_skipped(), "the book ran");
        (, uint64 first) = book.fixedOrder(pool, ids[0]);
        assertEq(first, 1, "the nearest ask filled");
        for (uint256 i; i < 8; ++i) {
            _swap(SwapParams(false, -1e15, MAX_LIMIT));
        }
        (, uint64 last) = book.fixedOrder(pool, ids[127]);
        assertEq(last, 1, "later swaps worked through the cluster");
        _checkBacking();
    }

    /// @dev Sol's review of the gas fix: levels spread over many chunks (a maker-fee change starts a new chunk at every
    /// price) cost more to commit than a flat per-point estimate. 64 levels of 8 one-lot chunks each, inside one AMM
    /// step: the book is not skipped, and repeated swaps work through all of them.
    function test_regression_denseMultiChunkLevelsFillWithinTheirGas() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256[] memory last = new uint256[](64);
        for (uint256 k; k < 8; ++k) {
            if (k != 0) _setMakerFee(uint24(1000 * k));
            for (uint256 i; i < 64; ++i) {
                last[i] = _placeFixed(true, int24(int256(10 * (i + 1))), 1);
            }
        }
        _coolAll();
        vm.recordLogs();
        _swap(SwapParams(false, -1e17, MAX_LIMIT));
        assertFalse(_skipped(), "the book ran");
        (, uint64 first) = book.fixedOrder(pool, last[0]);
        assertEq(first, 1, "the nearest level filled, all its chunks");
        for (uint256 i; i < 24; ++i) {
            _coolAll();
            vm.recordLogs();
            _swap(SwapParams(false, -1e15, MAX_LIMIT));
            assertFalse(_skipped(), "never skipped");
        }
        (, uint64 far) = book.fixedOrder(pool, last[63]);
        assertEq(far, 1, "later swaps worked through every level");
        _checkBacking();
    }

    /// @dev Sol's review of the gas fix: one level spread over 256 chunks (the most the policy allows), read cold under
    /// a tight callback allowance. The walk reads only the chunks it can still commit, so the book is never skipped
    /// and each swap works further through the level.
    function test_regression_deepLevelFillsWithinATightAllowance() public {
        _lp(-6000, 6000, 1e18);
        OrderBook.Policy memory p = _policy();
        p.limits.chunks = 256;
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 600_000;
        _installWith(settings, p);
        uint256 first = _placeFixed(true, 100, 1);
        uint256 last;
        for (uint256 k = 1; k < 256; ++k) {
            p.makerFeePips = k % 2 == 1 ? 1000 : 3000; // each change starts a new chunk at the price
            _setPolicy(p, settings);
            last = _placeFixed(true, 100, 1);
        }
        // With this little gas a swap reads only a few chunks, so the level fills over many swaps (the first passes it
        // through the AMM, the rest catch up behind the pool price); none skips the book.
        (uint64 filled, uint256 swaps) = (0, 0);
        while (filled == 0 && swaps < 200) {
            _coolAll();
            vm.recordLogs();
            _swap(SwapParams(false, swaps == 0 ? int256(-1e16) : int256(-1e14), MAX_LIMIT)); // the first reaches the level
            assertFalse(_skipped(), "the book ran");
            (, filled) = book.fixedOrder(pool, last);
            ++swaps;
        }
        (, uint64 head) = book.fixedOrder(pool, first);
        assertEq(head, 1, "the level's head filled");
        assertEq(filled, 1, "the whole level filled over the swaps");
        emit log_named_uint("swaps to fill 256 chunks", swaps);
        _checkBacking();
    }

    /// @dev Marks the book's, the Kernel's, the vault's and the PoolManager's storage cold, as for a fresh transaction.
    function _coolAll() private {
        vm.cool(address(book));
        vm.cool(address(hook));
        vm.cool(address(hook.VAULT()));
        vm.cool(address(manager));
    }

    /// @dev Deactivates, sets the policy, and reactivates with these settings.
    function _setPolicy(OrderBook.Policy memory p, ExtensionSettings memory settings) private {
        hook.deactivateExtension(key, IHookExtension(address(book)));
        uint64 version = _version();
        book.setPolicy(key, version, p);
        settings.configuration = abi.encode(version + 1);
        hook.configureExtension(key, IHookExtension(address(book)), settings);
        hook.activateExtension(key, IHookExtension(address(book)));
    }

    /// @dev Deactivates, sets the maker fee, and reactivates.
    function _setMakerFee(uint24 fee) private {
        hook.deactivateExtension(key, IHookExtension(address(book)));
        OrderBook.Policy memory p = _policy();
        p.makerFeePips = fee;
        uint64 version = _version();
        book.setPolicy(key, version, p);
        ExtensionSettings memory settings = _settings();
        settings.configuration = abi.encode(version + 1);
        hook.configureExtension(key, IHookExtension(address(book)), settings);
        hook.activateExtension(key, IHookExtension(address(book)));
    }

    /// @dev Audit: reinstalled with its retained policy version, the book used to activate with its policy deleted,
    /// and a free order then wedged it. Activation now needs a set policy.
    function test_regression_reinstallNeedsAPolicy() public {
        _install(_policy());
        hook.deactivateExtension(key, IHookExtension(address(book)));
        hook.removeExtension(key, IHookExtension(address(book)));
        ExtensionSettings memory settings = _settings();
        settings.configuration = abi.encode(_version());
        hook.installExtension(key, IHookExtension(address(book)), settings);
        vm.expectRevert();
        hook.activateExtension(key, IHookExtension(address(book)));
        book.setPolicy(key, _version(), _policy());
        settings.configuration = abi.encode(_version());
        hook.configureExtension(key, IHookExtension(address(book)), settings);
        hook.activateExtension(key, IHookExtension(address(book)));
        _placeFixed(true, 100, 1e5);
        assertEq(book.ledger(pool).escrow[0], 1e11, "a funded order");
    }

    /// @dev Audit: an order names the policy version its maker read; a policy changed since then (lot size, maker
    /// fee) refuses it.
    function test_placementNamesThePolicyVersion() public {
        _install(_policy());
        uint64 seen = _version();
        hook.deactivateExtension(key, IHookExtension(address(book)));
        OrderBook.Policy memory p = _policy();
        p.makerFeePips = 100_000;
        book.setPolicy(key, seen, p);
        ExtensionSettings memory settings = _settings();
        settings.configuration = abi.encode(seen + 1);
        hook.configureExtension(key, IHookExtension(address(book)), settings);
        hook.activateExtension(key, IHookExtension(address(book)));
        vm.prank(MAKER);
        vm.expectRevert(bytes4(keccak256("InvalidVersion()")));
        book.placeFixed(key, true, 100, 1e5, seen);
        _placeFixed(true, 100, 1e5);
    }

    /// @dev Audit: an AMM-only move used to leave an empty side's start at the old price, refusing valid orders near
    /// the market on the other side. A walk that finds nothing ahead now clears its side's start.
    function test_regression_emptySideDoesNotBlockPlacement() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        _swap(SwapParams(false, -6e15, MAX_LIMIT)); // no asks: the AMM moves the price up about 100 ticks
        (, int24 tick,,) = manager.getSlot0(pool);
        assertGt(tick, 60);
        (uint160[2] memory start,) = book.bookBounds(pool);
        assertEq(start[0], 0, "the empty ask side has no start");
        _placeFixed(false, 50, 1e5); // a bid below the pool price
        // The same once the side's only order is cancelled: the next walk finds nothing ahead.
        uint256 ask = _placeFixed(true, tick + 10, 1e5);
        vm.prank(MAKER);
        book.cancelFixed(pool, ask, MAKER);
        _swap(SwapParams(false, -1e15, MAX_LIMIT));
        (start,) = book.bookBounds(pool);
        assertEq(start[0], 0);
        _placeFixed(false, tick, 1e5);
        _checkBacking();
    }

    /// @dev Sol's review: a walk that never begins (here too little callback gas for the reserve) leaves the side's
    /// start as it was, so it cannot write an old price for an empty side either.
    function test_regression_walkThatNeverBeginsKeepsTheStart() public {
        _lp(-6000, 6000, 1e18);
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 120_000; // below the policy's 300,000 reserve
        _installWith(settings, _policy());
        vm.recordLogs();
        _swap(SwapParams(false, -6e15, MAX_LIMIT));
        assertFalse(_skipped(), "a clean stop, not a skip");
        (uint160[2] memory start,) = book.bookBounds(pool);
        assertEq(start[0], 0, "no ask start");
        _placeFixed(false, 50, 1e5); // a bid between the old and new prices
        // A side with orders keeps its start too.
        _placeFixed(true, 700, 1e5);
        (start,) = book.bookBounds(pool);
        uint160 asks = start[0];
        assertGt(asks, 0);
        _swap(SwapParams(false, -1e15, MAX_LIMIT));
        (start,) = book.bookBounds(pool);
        assertEq(start[0], asks, "the ask start stays");
    }

    /// @dev Round-2 audit (R2-OB-1): with about 40 one-lot asks inside the AMM's step, the gas guard tripped while
    /// loading them; the search then had no gas to size the AMM's share, the book could not cross the gap before its
    /// first order, and the whole swap went to the thin AMM. The book now fills what it loaded, up to the furthest
    /// loaded point the AMM and the book reach together (R3-3); the range beyond it waits for the next swap.
    function test_regression_gasStopFillsWhatItLoaded() public {
        _lp(-60_000, 60_000, 1e15); // thin AMM
        _install(_policy());
        uint256 honest = _placeRange(true, 10, 1000, 1e20);
        for (uint256 i = 1; i <= 60; ++i) {
            _placeFixed(true, int24(int256(i)), 1);
        }
        SwapParams memory params = SwapParams(false, -1e17, TickMath.getSqrtPriceAtTick(5000));
        BookWalk.Fill memory q = book.quote(key, params, 3000);
        _coolAll();
        vm.recordLogs();
        _swap(params);
        (, uint256 other, uint8 stop) = _bookFill(vm.getRecordedLogs());
        assertEq(stop, BookWalk.GAS, "a gas stop");
        assertGt(other, q.other * 95 / 100, "the book fills about what the quote has");
        (, uint160 frontier) = book.rangeOrder(pool, honest);
        assertGt(frontier, TickMath.getSqrtPriceAtTick(10), "the honest range sold");
        _checkBacking();
    }

    /// @dev Sol's review of the R3-3 fix: a gas stop must not keep the book from a deep range at the pool price. A thin
    /// AMM (liquidity 1,000) and an ask range of 1,000,000 from tick 100, with the pool parked at 100; exact input 200.
    /// The first fix crossed nothing past the reach on a gas stop, so no gas stop sold the range; the second sold none
    /// when the range ran past the AMM's step (an initialized tick at 300) until about 40,000 more gas. Over each sweep
    /// the book never does worse than the AMM; gas stops sell the range, and the step inside it delays that by no
    /// more than a sweep step or two.
    function test_regression_gasCutSellsADeepRange() public {
        uint256 snapshot = vm.snapshotState();
        (uint32 onset, bool soldOnGasStop) = _deepRangeSweep(false);
        vm.revertToState(snapshot);
        (uint32 onsetAcrossSteps,) = _deepRangeSweep(true);
        assertTrue(soldOnGasStop, "a gas stop sold the range");
        assertLe(onsetAcrossSteps, onset + 4000, "a range past the AMM's step sells as soon");
    }

    /// @return onset The smallest swept gas limit at which the book sold any of the range
    /// @return soldOnGasStop Whether a gas stop sold some of it
    function _deepRangeSweep(bool stepAt300) private returns (uint32 onset, bool soldOnGasStop) {
        PoolKey memory twin = _thinAmmPools(false);
        if (stepAt300) {
            _lp(300, 6000, 1);
            lpRouter.modifyLiquidity(twin, ModifyLiquidityParams(300, 6000, 1, 0), "");
        }
        _placeRange(true, 100, 1000, 1_000_000);
        SwapParams memory park = SwapParams(false, -1e9, TickMath.getSqrtPriceAtTick(100));
        _swap(park);
        swapRouter.swap(twin, park, PoolSwapTest.TestSettings(false, false), "");
        SwapParams memory buy = SwapParams(false, -200, MAX_LIMIT);
        uint256 ammOut = uint128(swapRouter.swap(twin, buy, PoolSwapTest.TestSettings(false, false), "").amount0());
        onset = type(uint32).max;
        // (1,000,000 - 400,000) / 2,000 + 1 runs
        for (uint32 gasLimit = 400_000; gasLimit <= 1_000_000; gasLimit += 2000) {
            uint256 snapshot = vm.snapshotState();
            _setBeforeSwapGas(gasLimit);
            vm.recordLogs();
            uint256 bookOut = uint128(_swap(buy).amount0());
            (,, uint8 stop) = _bookFill(vm.getRecordedLogs());
            assertGe(bookOut, ammOut, "no worse than the AMM alone");
            bool sold = bookOut > ammOut;
            if (sold && gasLimit < onset) onset = gasLimit;
            if (sold && stop == BookWalk.GAS) soldOnGasStop = true;
            vm.revertToState(snapshot);
        }
    }

    /// @dev Round 3 (Sol's review of the R3-3 fix): the gas cut's search spends gas after the guard trips. With the
    /// policy's largest book (1,024 points) and 400 cold levels, no beforeSwap gas limit from 600,000 to 5,000,000 makes
    /// the book run out of gas: the Kernel never skips it, and the guard stops the walk instead.
    function test_regression_gasStopsNeverSkipALargeBook() public {
        _lp(-60_000, 60_000, 1e18);
        uint32[CALLBACK_COUNT] memory budgets;
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = 20_000_000;
        }
        hook.setExecutionLimits(key, 4, budgets);
        OrderBook.Policy memory policy = _policy();
        policy.limits = BookWalk.Limits(512, 1024, 8, 64);
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 5_000_000;
        _installWith(settings, policy);
        // levels 1..400
        for (uint256 level = 1; level <= 400; ++level) {
            _placeFixed(true, int24(int256(level * 10)), 1e8);
        }
        bool stopped;
        // (5,000,000 - 600,000) / 100,000 + 1 gas limits, each in both modes
        for (uint32 gasLimit = 600_000; gasLimit <= 5_000_000; gasLimit += 100_000) {
            if (_largeBookStops(gasLimit, true)) stopped = true;
            if (_largeBookStops(gasLimit, false)) stopped = true;
        }
        assertTrue(stopped, "the guard stopped some walks");
    }

    /// @return stopped Whether the walk stopped on gas
    function _largeBookStops(uint32 gasLimit, bool exactIn) private returns (bool stopped) {
        uint256 snapshot = vm.snapshotState();
        _setBeforeSwapGas(gasLimit);
        _coolAll();
        vm.recordLogs();
        _swap(SwapParams(false, exactIn ? -1e17 : int256(5e16), MAX_LIMIT));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_skippedIn(logs), "the Kernel never skips the book");
        (,, uint8 stop) = _bookFill(logs);
        stopped = stop == BookWalk.GAS;
        vm.revertToState(snapshot);
    }

    /// @dev Sol's third review of the R3-3 fix: the gas cut priced a candidate point with the book's cost up to the AMM's
    /// landing, which rounds a hair past the point, so a large level there counted whole and the point was refused; the
    /// book then filled nothing. Spacing 10,000, AMM liquidity 1e18, an ask of 1e20 at tick 10 and 399 one-lot asks
    /// after it, a 1,024-point book; exact input 1e18. Every gas stop must fill part of the large ask (before the fix no
    /// gas limit from 300,000 to 4,900,000 did).
    function test_regression_gasCutFillsALargeLevelPastItsLanding() public {
        key = PoolKey(currency0, currency1, 0, 10_000, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        _lp(-10_000, 10_000, 1e18);
        uint32[CALLBACK_COUNT] memory budgets;
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = 20_000_000;
        }
        hook.setExecutionLimits(key, 4, budgets);
        OrderBook.Policy memory policy = _policy();
        policy.limits = BookWalk.Limits(512, 1024, 8, 64);
        _install(policy);
        uint256 large = _placeFixed(true, 10, 1e14);
        // ticks 20..418
        for (int24 tick = 20; tick <= 418; ++tick) {
            _placeFixed(true, tick, 1);
        }
        // (3,000,000 - 1,000,000) / 200,000 + 1 runs
        for (uint32 gasLimit = 1_000_000; gasLimit <= 3_000_000; gasLimit += 200_000) {
            uint256 snapshot = vm.snapshotState();
            _setBeforeSwapGas(gasLimit);
            vm.recordLogs();
            _swap(SwapParams(false, -1e18, MAX_LIMIT));
            (,, uint8 stop) = _bookFill(vm.getRecordedLogs());
            assertEq(stop, BookWalk.GAS, "a gas stop");
            (, uint64 filled) = book.fixedOrder(pool, large);
            assertGt(filled, 0, "the large ask fills in part");
            vm.revertToState(snapshot);
        }
    }

    /// @dev Sol's fourth review of the R3-3 fix: at thin AMM liquidity an inner point's rounded exact-output amount can
    /// equal the whole step's; a gas cut that gave the AMM that share made the PoolManager take, and charge for, the
    /// whole step. AMM liquidity 2 over [-10000, 600000], a 100-lot ask at tick 14,000 and one-lot asks after it, lot
    /// size 1; exact output 2. Every gas stop must buy from the book (input 9), not the step (about 2.1e13).
    function test_regression_gasCutNeverTakesAWholeThinStep() public {
        key = PoolKey(currency0, currency1, 0, 10_000, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        _lp(-10_000, 600_000, 2);
        OrderBook.Policy memory policy = _policy();
        policy.lotSize0 = 1;
        policy.limits = BookWalk.Limits(512, 128, 64, 64);
        _install(policy);
        _placeFixed(true, 14_000, 100);
        // ticks 14,001..14,399
        for (int24 tick = 14_001; tick <= 14_399; ++tick) {
            _placeFixed(true, tick, 1);
        }
        // (2,500,000 - 1,400,000) / 100,000 + 1 runs
        for (uint32 gasLimit = 1_400_000; gasLimit <= 2_500_000; gasLimit += 100_000) {
            uint256 snapshot = vm.snapshotState();
            _setBeforeSwapGas(gasLimit);
            vm.recordLogs();
            BalanceDelta delta = _swap(SwapParams(false, 2, MAX_LIMIT));
            (,, uint8 stop) = _bookFill(vm.getRecordedLogs());
            assertEq(stop, BookWalk.GAS, "a gas stop");
            assertLt(uint128(-delta.amount1()), 1000, "bought from the book, not the whole step");
            vm.revertToState(snapshot);
        }
    }

    /// @dev Round 3 (reviewer FX's measurement): a heavy ask book (60 range boundaries with live liquidity and a one-lot
    /// level at each, inside one AMM step), cold storage, both modes, the book's beforeSwap limit swept from 400k to
    /// 2.5M. The book is never skipped: the gas stop reserves enough for the commit and settlement.
    function test_regression_coldGasStopsNeverSkipABusyBook() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        // i <= 60
        for (uint256 i = 1; i <= 60; ++i) {
            _placeRange(true, int24(int256(10 * i)), 6000, 1e15);
            _placeFixed(true, int24(int256(10 * i)), 1);
        }
        uint32[9] memory limits =
            [uint32(400_000), 500_000, 600_000, 800_000, 1_000_000, 1_300_000, 1_700_000, 2_100_000, 2_500_000];
        // both modes
        for (uint256 m; m < 2; ++m) {
            // i < limits.length
            for (uint256 i; i < limits.length; ++i) {
                uint256 snapshot = vm.snapshotState();
                _setBeforeSwapGas(limits[i]);
                _coolAll();
                vm.recordLogs();
                _swap(m == 0 ? SwapParams(false, -2e17, MAX_LIMIT) : SwapParams(false, 15e16, MAX_LIMIT));
                Vm.Log[] memory logs = vm.getRecordedLogs();
                assertFalse(_skippedIn(logs), "the book ran");
                vm.revertToState(snapshot);
            }
        }
    }

    /// @dev Round 3 (reviewer BF's soundness check): native currency0, a protocol fee, both directions and both modes
    /// through fixed and range orders and the AMM; the vault equals the ledger after every step, makers claim and
    /// cancel, the treasury takes its native share as WETH, and the book empties.
    function test_nativeProtocolFeeLedger() public {
        key = PoolKey(Currency.wrap(address(0)), currency1, 3000, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 500 | (300 << 12));
        vm.deal(address(this), 1000 ether);
        lpRouter.modifyLiquidity{value: 100 ether}(key, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
        _install(_policy());
        vm.deal(MAKER, 100 ether);
        uint64 v = _version();
        vm.startPrank(MAKER);
        uint256 ask = book.placeFixed{value: 1e17}(key, true, 100, 1e11, v);
        uint256 askRange = book.placeRange{value: _rangeDeposit(true, 50, 600, 1e18)}(key, true, 50, 600, 1e18, v);
        uint256 bid = book.placeFixed(key, false, -100, 1e11, v);
        uint256 bidRange = book.placeRange(key, false, -600, -50, 1e18, v);
        vm.stopPrank();
        _checkBacking();
        swapRouter.swap{value: 1 ether}(key, SwapParams(false, -2e17, MAX_LIMIT), _noClaims(), "");
        _checkBacking();
        swapRouter.swap{value: 1 ether}(key, SwapParams(true, 3e17, MIN_LIMIT), _noClaims(), "");
        _checkBacking();
        swapRouter.swap{value: 1 ether}(key, SwapParams(false, 1e17, MAX_LIMIT), _noClaims(), "");
        _checkBacking();
        swapRouter.swap{value: 1 ether}(key, SwapParams(true, -2e17, MIN_LIMIT), _noClaims(), "");
        _checkBacking();
        vm.startPrank(MAKER);
        book.cancelFixed(pool, ask, MAKER);
        book.claimFixed(pool, ask, MAKER);
        book.cancelRange(pool, askRange, MAKER);
        book.claimRange(pool, askRange, MAKER);
        book.cancelFixed(pool, bid, MAKER);
        book.claimFixed(pool, bid, MAKER);
        book.cancelRange(pool, bidRange, MAKER);
        book.claimRange(pool, bidRange, MAKER);
        vm.stopPrank();
        _checkBacking();
        _donateReleasedNative();
        book.sweep(pool);
        OrderBook.Ledger memory l = book.ledger(pool);
        assertGt(l.treasury[0], 0, "native treasury share");
        vm.startPrank(TREASURY);
        book.withdrawTreasury(pool, Currency.wrap(address(0)), l.treasury[0], TREASURY, true);
        book.withdrawTreasury(pool, currency1, l.treasury[1], TREASURY, false);
        vm.stopPrank();
        assertEq(weth.balanceOf(TREASURY), l.treasury[0], "taken as WETH");
        l = book.ledger(pool);
        assertEq(l.escrow[0] + l.escrow[1] + l.makers[0] + l.makers[1] + l.lpFees[0] + l.lpFees[1], 0, "empty");
        assertEq(l.openOrders, 0);
        _checkBacking();
    }

    function _noClaims() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings(false, false);
    }

    function _donateReleasedNative() private {
        vm.warp(block.timestamp + 1 days);
        swapRouter.swap{value: 1e6}(key, SwapParams(true, -1e6, MIN_LIMIT), _noClaims(), "");
        vm.warp(block.timestamp + 1 days);
        swapRouter.swap{value: 1e6}(key, SwapParams(true, -1e6, MIN_LIMIT), _noClaims(), "");
    }

    // ---------------------------------------------------------------- round 3: pools with no AMM liquidity

    /// @dev Round 3 (R3-2: BF-1, Sol, FX): in a pool with no AMM liquidity, a swap the book filled nothing of ran the
    /// price to the router's limit for free, and nothing moved it back: asks were refused, buys could not execute and
    /// router swaps stopped reaching the book. The book's price is now the pool's: such a swap returns the price to
    /// where it started. Exact output below one lot in both directions, and exact input toward an empty side.
    function test_regression_emptyPoolNoFillSwapLeavesThePrice() public {
        _install(_policy());
        uint256 ask = _placeFixed(true, 100, 1e11);
        SwapParams[3] memory pushes = [
            SwapParams(false, 1, MAX_LIMIT), // one unit of output, below a lot, up
            SwapParams(true, 1, MIN_LIMIT), // and down
            SwapParams(true, -1e16, MIN_LIMIT) // toward the bids, of which there are none
        ];
        // pushes.length == 3
        for (uint256 i; i < pushes.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            BalanceDelta push = _swap(pushes[i]);
            assertEq(push.amount0(), 0, "nothing traded");
            assertEq(push.amount1(), 0, "nothing traded");
            (uint160 price,,,) = manager.getSlot0(pool);
            assertEq(price, PRICE_1, "the price stays");
            _placeFixed(true, 110, 1); // asks near the market are still accepted
            _placeFixed(false, -110, 1); // and bids
            _swap(SwapParams(false, -1e16, MAX_LIMIT));
            (, uint64 filled) = book.fixedOrder(pool, ask);
            assertGt(filled, 0, "a router-style buy still fills the ask");
            _checkBacking();
            vm.revertToState(snapshot);
        }
    }

    /// @dev Round 3 (BF-1): the same with AMM liquidity on one side only (above the price). A one-unit sell to the router's
    /// limit, which no bid fills, no longer leaves the next buyer to the AMM: the ask below the liquidity fills.
    function test_regression_oneSidedPoolPushLeavesThePrice() public {
        _lp(60, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 50, 1e11);
        _swap(SwapParams(true, -1, MIN_LIMIT));
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, PRICE_1, "the price stays");
        _swap(SwapParams(false, -1e16, MAX_LIMIT));
        (, uint64 filled) = book.fixedOrder(pool, ask);
        assertGt(filled, 0, "the ask fills");
        _checkBacking();
    }

    /// @dev Round 3 (FX-2): the move back crosses every empty bitmap word from the router's limit, and at spacing 10 it
    /// did not fit the book's 2.5M afterSwap gas for last trades beyond about tick -510,000. Kernel pools now need
    /// spacing 20, where the whole price range fits: pools near either end move back. Whole lots and 5 units of exact
    /// output: the 5 run to the limit.
    function test_regression_emptyPoolMovesBackAcrossTheWholeRange() public {
        uint256 snapshot = vm.snapshotState();
        _emptyPoolAt(-880_000);
        _placeFixed(true, -879_900, 1e5);
        _swap(SwapParams(false, 1e11 + 5, MAX_LIMIT));
        (, int24 tick,,) = manager.getSlot0(pool);
        assertEq(tick, -879_900, "back from the top");
        vm.revertToState(snapshot);
        _emptyPoolAt(880_000);
        _placeFixed(false, 879_900, 1e5);
        _swap(SwapParams(true, 1e11 + 5, MIN_LIMIT));
        (, tick,,) = manager.getSlot0(pool);
        assertEq(tick, 879_900, "back from the bottom");
        _checkBacking();
    }

    /// @dev Sol's review of the R3-2 change: a fill of dust alone (exact input below a lot's cost, kept by the book)
    /// trades at no price, and recording it erased the transaction's last trade, so the price stayed where a swap with a
    /// skipped afterSwap left it. In one transaction: one lot fills and the rest runs the empty AMM to tick 200, with
    /// the book's afterSwap skipped; then a one-unit buy is all dust. The price returns to the last trade at 100.
    function test_regression_dustFillKeepsTheLastTrade() public {
        GasBurner burner = _installBurner();
        _installInactive(_settingsBesideBurner(), _policy());
        hook.activateExtension(key, IHookExtension(address(burner)));
        hook.activateExtension(key, IHookExtension(address(book)));
        _placeFixed(true, 100, 2);
        TwoSwaps swaps = new TwoSwaps(swapRouter, currency0, currency1);
        MockERC20(Currency.unwrap(currency0)).mint(address(swaps), 1e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(swaps), 1e18);
        burner.setBurn(3_100_000); // leaves too little of the afterSwap budget for the book
        vm.recordLogs();
        swaps.run(
            key,
            SwapParams(false, 1e6 + 5, TickMath.getSqrtPriceAtTick(200)),
            address(burner),
            abi.encodeCall(burner.setBurn, (0)),
            SwapParams(false, -1, MAX_LIMIT)
        );
        assertTrue(_skipped(), "the first afterSwap skipped");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, TickMath.getSqrtPriceAtTick(100), "at the last trade");
        _checkBacking();
    }

    /// @dev Round 3 (found by the empty-pool price fuzz): a walk whose AMM goes on past its side's extent ended its range
    /// stop beyond its search bound, past a stop an earlier such walk left there; two stops at one price then made a
    /// later walk revert (NoProgress) and the Kernel skip the book. Stops are now recorded at the bound. Exact-output
    /// buys larger than the asks run the empty AMM on to their limit.
    function test_regression_rangeStopStaysWithinTheExtent() public {
        _install(_policy());
        uint160 limit = TickMath.getSqrtPriceAtTick(60);
        _placeRange(true, 20, 40, 1e15);
        _swap(SwapParams(false, 1e13, limit)); // sells the range; the rest runs to tick 60
        _placeRange(true, 45, 55, 1e15);
        _swap(SwapParams(false, 1e13, limit)); // again past the extent, to the same price
        uint256 last = _placeRange(true, 56, 80, 1e15);
        _swap(SwapParams(false, -1e18, MAX_LIMIT)); // a walk across tick 60
        (, uint160 frontier) = book.rangeOrder(pool, last);
        assertGt(frontier, TickMath.getSqrtPriceAtTick(56), "the range sold");
        _checkBacking();
    }

    /// @dev Round 3 (R3-2): in a pool with no AMM liquidity the price moves only with the book. Random orders and
    /// router-style swaps in both directions and modes: a swap the book fills nothing of leaves the price, and none
    /// leaves it at a router's limit.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_emptyPoolPriceFollowsTheBook(uint256 seed) public {
        _install(_policy());
        // step < 40
        for (uint256 step; step < 40; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 operation = r % 4;
            if (operation == 0) _randomFixed(r >> 8);
            else if (operation == 1) _randomRange(r >> 8);
            else _emptyPoolSwap(r >> 8);
            _checkBacking();
        }
    }

    function _emptyPoolSwap(uint256 randomness) private {
        (uint160 before,,,) = manager.getSlot0(pool);
        vm.recordLogs();
        _randomSwap(randomness);
        bool filled = _emittedIn(vm.getRecordedLogs(), OrderBook.BookFilled.selector);
        (uint160 price,,,) = manager.getSlot0(pool);
        if (!filled) assertEq(price, before, "no fill, no move");
        assertGt(price, MIN_LIMIT, "not left at the bottom");
        assertLt(price, MAX_LIMIT, "not left at the top");
    }

    function _emptyPoolAt(int24 tick) private {
        key = PoolKey(currency0, currency1, 2999, 20, key.hooks);
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        _install(_policy());
    }

    /// @dev Round 3 (BF-3): a walk that began at the pool price, before its side's start, and stopped short of it (at its
    /// price limit, or on gas) moved the start back to where it stopped, which tightened the other side's post-only
    /// check. The start now only moves forward.
    function test_regression_walkShortOfTheStartKeepsIt() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 3000, 1e11);
        _swap(SwapParams(false, -1e18, TickMath.getSqrtPriceAtTick(1000))); // stops at its limit, short of the ask
        (, uint64 filled) = book.fixedOrder(pool, ask);
        assertEq(filled, 0, "the walk did not reach the ask");
        (uint160[2] memory start,) = book.bookBounds(pool);
        assertEq(start[0], TickMath.getSqrtPriceAtTick(3000), "the ask side's start stays");
        _swap(SwapParams(false, -1e18, MAX_LIMIT));
        (, filled) = book.fixedOrder(pool, ask);
        assertGt(filled, 0, "the next buyer fills the ask");
        _checkBacking();
    }

    /// @dev Round 3 (R3-3): on a gas stop the book filled loaded levels across gaps without the AMM liquidity priced
    /// below them; a few dust levels in front of a large one cost takers up to 53% against the AMM alone. The book now
    /// fills as far as the AMM's share reaches, and beyond it only range liquidity at least as deep as the AMM's, so the
    /// taker gets at least what a twin pool without the book gives (up to rounding, negligible at these amounts).
    /// Sol's case (fee 0, spacing 22,000), the same with a dust range across the gap (which the book must not cross
    /// either), and a realistic one (0.3%, spacing 60), with and without gas pressure.
    function test_regression_gasStopIsNoWorseThanTheAmm() public {
        uint256[5] memory paddings = [uint256(0), 14, 25, 60, 99];
        bool stopped;
        // 3 cases x 5 paddings
        for (uint256 i; i < 15; ++i) {
            uint256 snapshot = vm.snapshotState();
            (uint256 bookOut, uint256 ammOut, uint8 stop) = _gasCutCase(i / 5, paddings[i % 5]);
            assertGe(bookOut, ammOut, "no worse than the AMM alone");
            if (stop == BookWalk.GAS) stopped = true;
            vm.revertToState(snapshot);
        }
        assertTrue(stopped, "the gas guard tripped");
    }

    /// @dev The same with an ordinary busy book and the usual AMM depth, and for exact output on the bid side.
    function test_regression_gasStopFillsABusyBook() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 snapshot = vm.snapshotState();
        for (uint256 i = 1; i <= 50; ++i) {
            _placeFixed(true, int24(int256(10 * i)), 1e10);
        }
        SwapParams memory params = SwapParams(false, -2e17, MAX_LIMIT);
        BookWalk.Fill memory q = book.quote(key, params, 3000);
        _coolAll();
        vm.recordLogs();
        _swap(params);
        (, uint256 other, uint8 stop) = _bookFill(vm.getRecordedLogs());
        assertEq(stop, BookWalk.GAS, "a gas stop");
        assertGt(other, q.other * 9 / 10, "the book fills");
        _checkBacking();
        vm.revertToState(snapshot);
        for (uint256 i = 1; i <= 50; ++i) {
            _placeFixed(false, -int24(int256(10 * i)), 1e10);
        }
        params = SwapParams(true, 1e17, MIN_LIMIT);
        q = book.quote(key, params, 3000);
        _coolAll();
        vm.recordLogs();
        BalanceDelta delta = _swap(params);
        (uint256 specified,) = _bookFilled();
        assertGt(specified, q.specified * 9 / 10, "the book delivers");
        assertEq(uint256(int256(delta.amount1())), 1e17, "the request is met");
        _checkBacking();
    }

    /// @dev Round-2 audit (R2-OB-4): the LPs' share was donated as one lump after each swap, so liquidity added just
    /// for that swap took nearly all of it; a taker could add, swap and remove in one transaction and rebate its own fee.
    /// Shares now release at locked x elapsed / LP_FEE_PERIOD_SECONDS: none in the swap that earned them, and an hour
    /// later an hour's worth.
    function test_regression_lpShareReleasesOverTime() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        _placeFixed(true, 0, 1e6); // asks at the pool price: the book fills the swap ahead of the AMM
        vm.recordLogs();
        _swap(SwapParams(false, -1e11, MAX_LIMIT));
        assertFalse(_emitted(OrderBook.LpFeesDonated.selector), "nothing released in the swap that earned it");
        uint256 owed = book.ledger(pool).lpFees[1];
        assertGt(owed, 0);
        vm.warp(block.timestamp + 1 hours);
        vm.recordLogs();
        _swap(SwapParams(true, -1e6, MIN_LIMIT));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 donated;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == OrderBook.LpFeesDonated.selector) {
                (, donated) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(donated, (owed * 1 hours + 1 days - 1) / 1 days, "an hour's worth, rounded up");
        assertEq(book.ledger(pool).lpFees[1], owed - donated);
        _checkBacking();
    }

    /// @dev The release rounds up: rounded down, a share below a period's worth of steps released nothing on each swap
    /// (here hourly), so it stayed locked as long as swaps kept coming and the book could never be removed.
    function test_regression_smallLpShareStillReleases() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        _placeFixed(true, 0, 1);
        _swap(SwapParams(false, -2e6, MAX_LIMIT)); // one lot: an LP share of a few thousand units
        uint256 owed = book.ledger(pool).lpFees[1];
        assertGt(owed, 24, "more than an hourly floor release can move");
        for (uint256 i; i < 200 && book.ledger(pool).lpFees[1] != 0; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _swap(SwapParams(true, -1e6, MIN_LIMIT));
        }
        assertEq(book.ledger(pool).lpFees[1], 0, "all released and donated");
        _checkBacking();
    }

    /// @dev Round-2 audit (R2-OB-7): a range's whole proceeds are bounded at placement like a fixed level's, so a claim
    /// always fits one vault withdrawal (the PoolManager's int128). Before, an ask range at a high price could earn more
    /// than int128 and its claim reverted for good.
    function test_regression_rangeProceedsAreBounded() public {
        key = PoolKey(currency0, currency1, 0, 20, key.hooks);
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(480_000));
        _install(_policy());
        vm.prank(MAKER);
        vm.expectRevert(BookOrders.InvalidOrder.selector); // its deposit is under 1e18, its proceeds above 2^124
        book.placeRange(key, true, 480_000, 482_000, uint128(1 << 96), _version());
        _placeRange(true, 480_000, 482_000, uint128(1 << 90));
    }

    /// @dev Round-2 audit (R2-OB-6): cancels did not touch a side's start, so after the last ask was cancelled and the
    /// price moved without a walk on the ask side, bids between the old ask and the price were refused as crossing.
    /// A side with no order left now clears its start.
    function test_regression_cancelledSideClearsItsStart() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 id = _placeFixed(true, 100, 1e5);
        vm.prank(MAKER);
        book.cancelFixed(pool, id, MAKER);
        (uint160[2] memory start,) = book.bookBounds(pool);
        assertEq(start[0], 0, "no ask start");
        // The price moves past the old ask without the book.
        hook.deactivateExtension(key, IHookExtension(address(book)));
        _swap(SwapParams(false, -5e16, TickMath.getSqrtPriceAtTick(200)));
        hook.activateExtension(key, IHookExtension(address(book)));
        _placeFixed(false, 150, 1e5); // below the price, and no ask exists
    }

    /// @dev Round-2 audit: a refund or claim sent to the book or the vault would be lost to the maker; round 3 (FX-6):
    /// so would one sent to the Kernel, its route executor or the PoolManager.
    function test_regression_refundToTheBookOrTheKernelIsRefused() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 id = _placeFixed(true, 100, 1e5);
        address[6] memory refused = [
            address(0),
            address(book),
            address(hook.VAULT()),
            address(hook),
            address(hook.ROUTE_EXECUTOR()),
            address(manager)
        ];
        // i < refused.length
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(MAKER);
            vm.expectRevert(bytes4(keccak256("InvalidAmount()")));
            book.cancelFixed(pool, id, refused[i]);
            vm.prank(MAKER);
            vm.expectRevert(bytes4(keccak256("InvalidAmount()")));
            book.claimFixed(pool, id, refused[i]);
        }
    }

    /// @dev The same for ranges: cancelling or claiming a range refuses each of those recipients.
    function test_regression_rangeRefundToTheBookOrTheKernelIsRefused() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 id = _placeRange(true, 100, 400, 1e15);
        address[6] memory refused = [
            address(0),
            address(book),
            address(hook.VAULT()),
            address(hook),
            address(hook.ROUTE_EXECUTOR()),
            address(manager)
        ];
        // i < refused.length
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(MAKER);
            vm.expectRevert(bytes4(keccak256("InvalidAmount()")));
            book.cancelRange(pool, id, refused[i]);
            vm.prank(MAKER);
            vm.expectRevert(bytes4(keccak256("InvalidAmount()")));
            book.claimRange(pool, id, refused[i]);
        }
        vm.prank(MAKER);
        assertGt(book.cancelRange(pool, id, MAKER), 0, "the maker's own refund goes through");
    }

    /// @dev Round 3 (BF-3) on every side and order kind: a walk stopped by its price limit short of the side's first
    /// order keeps the side's start there, and the next taker fills the order.
    function test_regression_walkShortOfTheStartKeepsItOnEverySide() public {
        // 2 sides x 2 order kinds
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            _walkShortOfTheStart(i % 2 == 0, i < 2);
            vm.revertToState(snapshot);
        }
    }

    function _walkShortOfTheStart(bool sell0, bool fixedOrder) private {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        int24 orderTick = sell0 ? int24(3000) : int24(-3000);
        if (fixedOrder) _placeFixed(sell0, orderTick, 1e11);
        if (!fixedOrder) {
            _placeRange(sell0, sell0 ? orderTick : orderTick - 600, sell0 ? orderTick + 600 : orderTick, 1e17);
        }
        // The taker buys what the order sells.
        bool zeroForOne = !sell0;
        _swap(SwapParams(zeroForOne, -1e18, TickMath.getSqrtPriceAtTick(sell0 ? int24(1000) : int24(-1000))));
        (uint160[2] memory start,) = book.bookBounds(pool);
        assertEq(start[sell0 ? 0 : 1], TickMath.getSqrtPriceAtTick(orderTick), "the side's start stays");
        vm.recordLogs();
        _swap(SwapParams(zeroForOne, -1e18, zeroForOne ? MIN_LIMIT : MAX_LIMIT));
        (uint256 specified,) = _bookFilled();
        assertGt(specified, 0, "the next taker fills the order");
        _checkBacking();
    }

    /// @dev Round-2 audit (R2-OB-3): in a pool with no AMM liquidity, the move after a swap went to where the walk's
    /// last whole AMM step ended (a bitmap word edge, or the taker's limit), not to the last trade; and a move back from
    /// a router's extreme limit ran out of gas replaying every empty word before swapping across them. Asks near the
    /// market were then refused, and a seller's walk from the top could run past the bids. The pool now moves to the
    /// last trade, and the move is checked by its own landing instead of a replay.
    function test_regression_emptyPoolMovesToTheLastTrade() public {
        _install(_policy());
        _placeFixed(true, 200, 1e6);
        uint256 bid = _placeFixed(false, -200, 1e5);
        uint256 snapshot = vm.snapshotState();
        _swap(SwapParams(false, -1e18, TickMath.getSqrtPriceAtTick(5000))); // a moderate limit
        (, int24 tick,,) = manager.getSlot0(pool);
        assertEq(tick, 200, "at the last trade");
        _placeFixed(true, 210, 1); // an ask just above it
        vm.revertToState(snapshot);
        _swap(SwapParams(false, -1e18, MAX_LIMIT)); // a router's limit
        (, tick,,) = manager.getSlot0(pool);
        assertEq(tick, 200, "back from the taker's limit");
        // A seller then reaches the bids.
        _swap(SwapParams(true, -1e10, MIN_LIMIT));
        (, uint64 filled) = book.fixedOrder(pool, bid);
        assertGt(filled, 0, "the bid filled");
        vm.revertToState(snapshot);
        BalanceDelta delta = _swap(SwapParams(false, 1e11 + 5, MAX_LIMIT)); // whole lots and 5 units, exact output
        assertEq(delta.amount0(), 1e11, "the book delivered the whole lots");
        (, tick,,) = manager.getSlot0(pool);
        assertEq(tick, 200, "back after the sub-lot remainder ran to the limit");
        _checkBacking();
    }

    /// @dev Sol's review of the fix: when the book ends at a fixed level (here its point limit) and the AMM step goes
    /// on past it, the commit fills the level, so the pool moves to it; both directions and modes.
    function test_regression_emptyPoolMovesToATerminalLevel() public {
        OrderBook.Policy memory p = _policy();
        p.limits.bookPoints = 1;
        _install(p);
        uint256 ask = _placeFixed(true, 100, 1e5);
        uint256 bid = _placeFixed(false, -100, 1e5);
        SwapParams[4] memory swaps = [
            SwapParams(false, -1e18, MAX_LIMIT),
            SwapParams(false, 1e18, MAX_LIMIT),
            SwapParams(true, -1e18, MIN_LIMIT),
            SwapParams(true, 1e18, MIN_LIMIT)
        ];
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            _swap(swaps[i]);
            (, uint64 filled) = book.fixedOrder(pool, swaps[i].zeroForOne ? bid : ask);
            assertEq(filled, 1e5, "the level filled");
            (, int24 tick,,) = manager.getSlot0(pool);
            assertEq(tick, swaps[i].zeroForOne ? -100 : int24(100), "the pool shows the fill");
            _checkBacking();
            vm.revertToState(snapshot);
        }
    }

    /// @dev The same with tick spacing 60, where a bitmap word spans 15,360 ticks.
    function test_regression_emptyPoolMovesToTheLastTrade_spacing60() public {
        key.tickSpacing = 60;
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        _install(_policy());
        _placeFixed(true, 600, 1e5);
        _swap(SwapParams(false, -1e18, MAX_LIMIT));
        (, int24 tick,,) = manager.getSlot0(pool);
        assertEq(tick, 600, "at the last trade");
        _placeFixed(true, 660, 1);
    }

    /// @dev Audit: a cancel's refund goes to the recipient its owner names, so a maker contract that cannot take the
    /// currency can still recover its deposit.
    function test_cancelRefundsToTheNamedRecipient() public {
        _install(_policy());
        uint256 id = _placeFixed(true, 100, 1e5);
        uint256 before = MockERC20(Currency.unwrap(currency0)).balanceOf(TREASURY);
        vm.prank(MAKER);
        book.cancelFixed(pool, id, TREASURY);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(TREASURY) - before, 1e11);
        _checkBacking();
    }

    /// @dev Random placements, cancellations, claims and swaps in both directions and modes; the vault always holds
    /// exactly what the ledger owes. Then everything is cancelled and claimed, the rest swept and withdrawn, and the
    /// extension removed.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_lifecycle(uint256 seed) public {
        _lp(-6000, 6000, 1e18);
        _lp(-200, 200, 5e17);
        _install(_policy());
        for (uint256 step; step < 40; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 10;
            if (op < 2) _randomFixed(r >> 8);
            else if (op < 4) _randomRange(r >> 8);
            else if (op < 8) _randomSwap(r >> 8);
            else if (op < 9) _randomCancel(r >> 8);
            else _randomClaim(r >> 8);
            if ((r >> 248) % 4 == 0) vm.warp(block.timestamp + (r >> 200) % 2 days); // LP shares release over time
            _checkBacking();
        }
        _closeAll();
    }

    uint256[] private fixedIds;
    uint256[] private rangeIds;
    // What the test saw each order receive, for the independent check at the close.
    mapping(uint256 => uint64) private placedLots;
    mapping(uint256 => uint256) private fixedPaid;
    mapping(uint256 => uint256) private fixedRefunded;
    mapping(uint256 => uint256) private rangePaid;
    mapping(uint256 => uint256) private rangeRefunded;

    function _randomFixed(uint256 r) private {
        (, int24 tick,,) = manager.getSlot0(pool);
        bool sell0 = r & 1 == 1;
        int24 offset = int24(int256((r >> 8) % 40));
        int24 at = sell0 ? tick + 1 + offset : tick - offset; // asks above the pool price, bids at or below it
        if (!_postOnlyHolds(sell0, at)) return;
        uint64 lots = uint64(1 + (r >> 20) % 1e11);
        vm.prank(MAKER);
        uint256 id = book.placeFixed(key, sell0, at, lots, _version());
        fixedIds.push(id);
        placedLots[id] = lots;
    }

    function _randomRange(uint256 r) private {
        (, int24 tick,,) = manager.getSlot0(pool);
        bool sell0 = r & 1 == 1;
        int24 near = sell0 ? tick + 1 + int24(int256((r >> 8) % 40)) : tick - 1 - int24(int256((r >> 8) % 40));
        if (!_postOnlyHolds(sell0, near)) return;
        int24 width = 1 + int24(int256((r >> 20) % 200));
        (int24 lower, int24 upper) = sell0 ? (near, near + width) : (near - width, near);
        vm.prank(MAKER);
        rangeIds.push(book.placeRange(key, sell0, lower, upper, uint128(1e6 + (r >> 40) % 1e18), _version()));
    }

    /// @dev Whether an order with this near end is at or beyond every unfilled order of the other side.
    function _postOnlyHolds(bool sell0, int24 near) private view returns (bool) {
        if (near <= TickMath.MIN_TICK + 500 || near >= TickMath.MAX_TICK - 500) return false; // the price ran to a limit
        (uint160[2] memory start,) = book.bookBounds(pool);
        uint160 price = TickMath.getSqrtPriceAtTick(near);
        return sell0 ? (start[1] == 0 || price >= start[1]) : (start[0] == 0 || price <= start[0]);
    }

    function _randomSwap(uint256 r) private {
        bool zeroForOne = r & 1 == 1;
        uint256 amount = 1 + (r >> 8) % (10 ** (13 + (r >> 200) % 5)); // a few ticks to a few hundred
        int256 specified = (r >> 1) & 1 == 1 ? -int256(amount) : int256(amount);
        (uint160 price,,,) = manager.getSlot0(pool);
        if (zeroForOne ? price <= MIN_LIMIT : price >= MAX_LIMIT) return;
        _swap(SwapParams(zeroForOne, specified, zeroForOne ? MIN_LIMIT : MAX_LIMIT));
    }

    function _randomCancel(uint256 r) private {
        if (r & 1 == 1 && fixedIds.length != 0) _cancelFixed(fixedIds[(r >> 8) % fixedIds.length]);
        else if (rangeIds.length != 0) _cancelRange(rangeIds[(r >> 8) % rangeIds.length]);
    }

    function _randomClaim(uint256 r) private {
        if (r & 1 == 1 && fixedIds.length != 0) _claimFixed(fixedIds[(r >> 8) % fixedIds.length]);
        else if (rangeIds.length != 0) _claimRange(rangeIds[(r >> 8) % rangeIds.length]);
    }

    /// @dev Claims go to a recipient other than the maker; every payment is checked as received.
    address private constant CLAIMANT = address(0xC1A1);

    function _cancelFixed(uint256 id) private {
        (FixedBook.Order memory o,) = book.fixedOrder(pool, id);
        fixedRefunded[
            id
        ] += _paid(o.sell0 ? currency0 : currency1, MAKER, abi.encodeCall(book.cancelFixed, (pool, id, MAKER)));
    }

    function _cancelRange(uint256 id) private {
        (RangeBook.Range memory o,) = book.rangeOrder(pool, id);
        rangeRefunded[
            id
        ] += _paid(o.sell0 ? currency0 : currency1, MAKER, abi.encodeCall(book.cancelRange, (pool, id, MAKER)));
    }

    function _claimFixed(uint256 id) private {
        (FixedBook.Order memory o,) = book.fixedOrder(pool, id);
        fixedPaid[
            id
        ] += _paid(o.sell0 ? currency1 : currency0, CLAIMANT, abi.encodeCall(book.claimFixed, (pool, id, CLAIMANT)));
    }

    function _claimRange(uint256 id) private {
        (RangeBook.Range memory o,) = book.rangeOrder(pool, id);
        rangePaid[
            id
        ] += _paid(o.sell0 ? currency1 : currency0, CLAIMANT, abi.encodeCall(book.claimRange, (pool, id, CLAIMANT)));
    }

    /// @dev Calls the book as the maker and returns the amount it reported paying, checked against what `recipient`
    /// received.
    function _paid(Currency currency, address recipient, bytes memory call) private returns (uint256 amount) {
        uint256 before = currency.balanceOf(recipient);
        vm.prank(MAKER);
        (bool ok, bytes memory ret) = address(book).call(call);
        assertTrue(ok, "maker call");
        amount = abi.decode(ret, (uint256));
        assertEq(currency.balanceOf(recipient) - before, amount, "paid as reported");
    }

    /// @dev Each closed order, from its own fills: refunds are its unfilled lots, or its range's unsold part rounded
    /// down; its claims add up to x - ceil(r x) of its gross proceeds x, rounded down at its price or along its range.
    function _checkMakers() private view {
        uint256 fee = _policy().makerFeePips;
        for (uint256 i; i < fixedIds.length; ++i) {
            uint256 id = fixedIds[i];
            (FixedBook.Order memory o, uint64 filled) = book.fixedOrder(pool, id);
            uint256 lotSize = o.sell0 ? _policy().lotSize0 : _policy().lotSize1;
            assertEq(fixedRefunded[id], uint256(placedLots[id] - filled) * lotSize, "fixed refund");
            uint256 x = _proceeds(o.sell0, TickMath.getSqrtPriceAtTick(o.tick), uint256(filled) * lotSize);
            assertEq(fixedPaid[id], x - FullMath.mulDivRoundingUp(x, fee, 1e6), "fixed net claims");
        }
        for (uint256 i; i < rangeIds.length; ++i) {
            uint256 id = rangeIds[i];
            (RangeBook.Range memory o, uint160 frontier) = book.rangeOrder(pool, id);
            uint160 lower = TickMath.getSqrtPriceAtTick(o.lower);
            uint160 upper = TickMath.getSqrtPriceAtTick(o.upper);
            (uint256 x, uint256 unsold) = o.sell0
                ? (
                    SqrtPriceMath.getAmount1Delta(lower, frontier, o.liquidity, false),
                    SqrtPriceMath.getAmount0Delta(frontier, upper, o.liquidity, false)
                )
                : (
                    SqrtPriceMath.getAmount0Delta(frontier, upper, o.liquidity, false),
                    SqrtPriceMath.getAmount1Delta(lower, frontier, o.liquidity, false)
                );
            assertEq(rangeRefunded[id], unsold, "range refund");
            assertEq(rangePaid[id], x - FullMath.mulDivRoundingUp(x, fee, 1e6), "range net claims");
        }
    }

    /// @dev What `out` sold at sqrt price `price` earns, rounded down; the price is applied in two steps when its
    /// square would not fit.
    function _proceeds(bool sell0, uint160 price, uint256 out) private pure returns (uint256) {
        if (price <= type(uint128).max) {
            uint256 squared = uint256(price) * price;
            return sell0 ? FullMath.mulDiv(out, squared, 1 << 192) : FullMath.mulDiv(out, 1 << 192, squared);
        }
        return sell0
            ? FullMath.mulDiv(FullMath.mulDiv(out, price, 1 << 96), price, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(out, 1 << 96, price), 1 << 96, price);
    }

    function _closeAll() private {
        for (uint256 i; i < fixedIds.length; ++i) {
            _cancelFixed(fixedIds[i]);
            _claimFixed(fixedIds[i]);
        }
        for (uint256 i; i < rangeIds.length; ++i) {
            _cancelRange(rangeIds[i]);
            _claimRange(rangeIds[i]);
        }
        assertEq(book.ledger(pool).openOrders, 0, "every order settled");
        _checkMakers();
        _checkBacking();
        // Undonated LP shares go out with a swap while liquidity is in range.
        (uint160 price,,,) = manager.getSlot0(pool);
        uint160 middle = TickMath.getSqrtPriceAtTick(0);
        if (price != middle) _swap(SwapParams(price > middle, -1e12, middle));
        _donateReleased();
        book.sweep(pool);
        OrderBook.Ledger memory l = book.ledger(pool);
        vm.startPrank(TREASURY);
        if (l.treasury[0] != 0) book.withdrawTreasury(pool, currency0, l.treasury[0], TREASURY, false);
        if (l.treasury[1] != 0) book.withdrawTreasury(pool, currency1, l.treasury[1], TREASURY, false);
        vm.stopPrank();
        l = book.ledger(pool);
        assertEq(l.lpFees[0] + l.lpFees[1], 0, "LP shares donated");
        hook.deactivateExtension(key, IHookExtension(address(book)));
        hook.removeExtension(key, IHookExtension(address(book)));
        assertEq(hook.VAULT().fundedCurrencyCount(pool, address(book)), 0, "vault emptied");
    }

    // ---------------------------------------------------------------- gas

    function test_gas_fullStack() public {
        if (!vm.isIsolateMode()) vm.skip(true);
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        vm.prank(MAKER);
        book.placeFixed(key, true, 100, 1e11, _version());
        _record("place_fixed_first");
        vm.prank(MAKER);
        book.placeFixed(key, true, 100, 1e11, _version());
        _record("place_fixed_join");
        vm.prank(MAKER);
        uint256 rangeId = book.placeRange(key, true, 50, 600, 1e18, _version());
        _record("place_range");
        _swap(SwapParams(false, -1e16, MAX_LIMIT));
        _record("swap_book_and_amm");
        _swap(SwapParams(false, -3e17, MAX_LIMIT));
        _record("swap_through_level_and_range");
        vm.prank(MAKER);
        book.claimFixed(pool, 1, MAKER);
        _record("claim_fixed");
        vm.prank(MAKER);
        book.cancelRange(pool, rangeId, MAKER);
        _record("cancel_range");
        _swap(SwapParams(true, -1e16, MIN_LIMIT));
        _record("swap_empty_side");
    }

    function _record(string memory label) private {
        Vm.Gas memory measured = vm.lastFrameGas();
        vm.snapshotValue("OrderBookExtensionGas", label, measured.gasTotalUsed);
    }

    /// @dev The book's pool and a hookless twin, fee 0 and spacing 10, each with AMM liquidity 1,000 over
    /// [-6000, 6000]; the book installed with range liquidity from 1, and lot size 1 when asked.
    function _thinAmmPools(bool unitLots) private returns (PoolKey memory twin) {
        key = PoolKey(currency0, currency1, 0, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        twin = PoolKey(currency0, currency1, 0, 20, IHooks(address(0)));
        manager.initialize(twin, PRICE_1);
        _lp(-6000, 6000, 1000);
        lpRouter.modifyLiquidity(twin, ModifyLiquidityParams(-6000, 6000, 1000, 0), "");
        OrderBook.Policy memory policy = _policy();
        policy.minRangeLiquidity = 1;
        if (unitLots) policy.lotSize0 = 1;
        _install(policy);
    }

    /// @dev Reconfigures the book's beforeSwap gas limit, which sets where its gas guard trips.
    function _setBeforeSwapGas(uint32 gasLimit) private {
        hook.deactivateExtension(key, IHookExtension(address(book)));
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = gasLimit;
        settings.configuration = abi.encode(_version());
        hook.configureExtension(key, IHookExtension(address(book)), settings);
        hook.activateExtension(key, IHookExtension(address(book)));
    }

    /// @dev Two AMM positions of 1000e18 ([-edge, edge] and [edge, 2 edge]) in the book's pool and in a hookless twin, a
    /// one-lot ask, a 1000e18 ask, and `padding` one-lot asks after it; the same exact-input buy in both pools. Variant
    /// 0 is Sol's case, 1 adds a dust range from the small ask to the large one, 2 is the realistic case.
    function _gasCutCase(uint256 variant, uint256 padding)
        private
        returns (uint256 bookOut, uint256 ammOut, uint8 stop)
    {
        bool solsCase = variant < 2;
        (uint24 fee, int24 spacing, int24 edge, int24 tiny, int24 big, uint256 input) = solsCase
            ? (uint24(0), int24(22_000), int24(22_000), int24(13_864), int24(21_900), uint256(2100e18))
            : (uint24(3000), int24(60), int24(15_000), int24(6000), int24(14_000), uint256(1200e18));
        key = PoolKey(currency0, currency1, fee, spacing, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        PoolKey memory twin = PoolKey(currency0, currency1, fee, spacing, IHooks(address(0)));
        manager.initialize(twin, PRICE_1);
        _lp(-edge, edge, 1000e18);
        _lp(edge, 2 * edge, 1000e18);
        lpRouter.modifyLiquidity(twin, ModifyLiquidityParams(-edge, edge, 1000e18, 0), "");
        lpRouter.modifyLiquidity(twin, ModifyLiquidityParams(edge, 2 * edge, 1000e18, 0), "");
        OrderBook.Policy memory policy = _policy();
        policy.lotSize0 = 1e12;
        policy.minRangeLiquidity = 1;
        _install(policy);
        _placeFixed(true, tiny, 1);
        if (variant == 1) _placeRange(true, tiny, big, 1e10);
        _placeFixed(true, big, 1e9);
        // padding <= 99
        for (uint256 i; i < padding; ++i) {
            _placeFixed(true, big + 1 + int24(int256(i)), 1);
        }
        _coolAll();
        vm.recordLogs();
        bookOut = uint128(_swap(SwapParams(false, -int256(input), MAX_LIMIT)).amount0());
        (,, stop) = _bookFill(vm.getRecordedLogs());
        ammOut = uint128(
            swapRouter.swap(
                    twin, SwapParams(false, -int256(input), MAX_LIMIT), PoolSwapTest.TestSettings(false, false), ""
                )
                .amount0()
        );
        _checkBacking();
    }
}
