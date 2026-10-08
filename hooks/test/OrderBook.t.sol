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
import {OrderBook, IWETH} from "../src/OrderBook.sol";
import {BookWalk} from "../src/libraries/BookWalk.sol";
import {BookOrders, IDepositVault} from "../src/libraries/BookOrders.sol";
import {FixedBook} from "../src/libraries/FixedBook.sol";
import {RangeBook} from "../src/libraries/RangeBook.sol";

/// @dev An extension that overrides the LP fee in beforeSwap, as LVRHook does.
contract FeeOverrider is IKernelHookExtension {
    uint24 public immutable FEE;

    constructor(uint24 fee) {
        FEE = fee;
    }

    function onInstall(PoolKey calldata, ExtensionSettings calldata) external pure returns (bytes4) {
        return this.onInstall.selector;
    }

    function onConfigure(PoolKey calldata, ExtensionSettings calldata, ExtensionSettings calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onConfigure.selector;
    }

    function canActivate(PoolKey calldata, ExtensionSettings calldata) external pure returns (bool) {
        return true;
    }

    function canUninstall(PoolKey calldata) external pure returns (bool) {
        return true;
    }

    function onUninstall(PoolKey calldata, bytes calldata) external pure returns (bytes4) {
        return this.onUninstall.selector;
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata)
        external
        virtual
        returns (CallbackResult memory)
    {
        return CallbackResult(0, 0, FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

/// @dev An extension that, inside a nested route, pays the route executor one unit of a currency straight through the
/// PoolManager, with no callback delta.
contract ExecutorGift is FeeOverrider {
    IPoolManager public immutable MANAGER;
    bool public immutable PAY1;

    constructor(IPoolManager manager, bool pay1) FeeOverrider(0) {
        MANAGER = manager;
        PAY1 = pay1;
    }

    function onCallback(ExecutionContext calldata context, PoolKey calldata key, bytes calldata)
        external
        override
        returns (CallbackResult memory)
    {
        if (context.depth > 1) {
            Currency currency = PAY1 ? key.currency1 : key.currency0;
            MANAGER.sync(currency);
            MockERC20(Currency.unwrap(currency)).transfer(address(MANAGER), 1);
            MANAGER.settleFor(context.sender);
        }
        return CallbackResult(0, 0, 0);
    }
}

/// @dev An extension that charges (positive) or credits (negative) the caller of an exact-input swap of one unit, as
/// the book's empty-pool price move is: a charge in the input currency, a credit in the output currency.
contract UnitSwapTax is FeeOverrider {
    int128 public immutable AMOUNT;

    constructor(int128 amount) FeeOverrider(0) {
        AMOUNT = amount;
    }

    function fund(address vault, PoolId pool, Currency currency, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).approve(vault, amount);
        IDepositVault(vault).deposit(pool, address(this), currency, amount);
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata data)
        external
        view
        override
        returns (CallbackResult memory)
    {
        SwapParams memory params = abi.decode(data, (SwapParams));
        if (params.amountSpecified != -1) return CallbackResult(0, 0, 0);
        bool charge0 = params.zeroForOne == AMOUNT > 0;
        return charge0 ? CallbackResult(AMOUNT, 0, 0) : CallbackResult(0, AMOUNT, 0);
    }
}

/// @dev Two swaps in one transaction (Foundry clears transient storage between a test's own calls), the first with a
/// gas allowance of its own.
contract TwoSwaps {
    PoolSwapTest internal immutable ROUTER;

    constructor(PoolSwapTest router, Currency currency0, Currency currency1) {
        ROUTER = router;
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function run(PoolKey calldata key, SwapParams calldata first, uint256 firstGas, SwapParams calldata second)
        external
    {
        ROUTER.swap{gas: firstGas}(key, first, PoolSwapTest.TestSettings(false, false), "");
        ROUTER.swap(key, second, PoolSwapTest.TestSettings(false, false), "");
    }
}

/// @dev The order book extension through the Kernel, against a real PoolManager.
contract OrderBookTest is Test {
    using StateLibrary for IPoolManager;

    address internal constant HOOK_ADDRESS = address(uint160(0xC0FFEE) << 136 | uint160(Hooks.ALL_HOOK_MASK));
    address internal constant TREASURY = address(0x7EA5);
    address internal constant MAKER = address(0x4A4E);
    uint160 internal constant PRICE_1 = 1 << 96;
    uint160 internal constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint16 internal constant MASK = uint16(1) << uint8(CallbackType.BeforeSwap) | uint16(1) << uint8(CallbackType.AfterSwap);

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    HookCatalog internal catalog;
    KernelHook internal hook;
    WETH internal weth;
    OrderBook internal book;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;
    PoolId internal pool;

    function setUp() public {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        (currency0, currency1) = (Currency.wrap(address(t0)), Currency.wrap(address(t1)));
        catalog = new HookCatalog();
        deployCodeTo("KernelHook.sol:KernelHook", abi.encode(manager, address(catalog)), HOOK_ADDRESS);
        hook = KernelHook(HOOK_ADDRESS);
        weth = new WETH();
        book = new OrderBook(IKernelHook(address(hook)), IWETH(address(weth)));
        catalog.admit(address(book), IHookCatalog.Entry(address(book).codehash, MASK, true, true, false, true, true));
        _fund(t0);
        _fund(t1);
        key = PoolKey(currency0, currency1, 3000, 10, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
    }

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
    /// LPs' share donated after the swap.
    function test_feesClaimsAndDonation() public {
        _lp(-6000, 6000, 1e18);
        OrderBook.Policy memory p = _policy();
        _install(p);
        uint256 id = _placeFixed(true, 100, 1e11);
        vm.recordLogs();
        _swap(SwapParams(false, -2e17, MAX_LIMIT)); // the price stays inside the LP range
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
        _lp(150, 250, 1e18); // LPs enter at the market price
        _swap(SwapParams(true, -1e16, MIN_LIMIT));
        _checkBacking();
    }

    function test_postOnly() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        vm.startPrank(MAKER);
        vm.expectRevert(BookOrders.Crossing.selector);
        book.placeFixed(key, true, -10, 1);
        vm.expectRevert(BookOrders.Crossing.selector);
        book.placeFixed(key, false, 10, 1);
        vm.expectRevert(BookOrders.Crossing.selector);
        book.placeRange(key, true, -10, 100, 1e18);
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
        uint256 refund = book.cancelRange(pool, rangeId);
        assertGt(refund, 0);
        book.cancelFixed(pool, fixedId);
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
        assertEq(book.ledger(pool).lpFees[0] + book.ledger(pool).lpFees[1], 0, "LP shares donated");
        hook.deactivateExtension(key, IHookExtension(address(book)));
        hook.removeExtension(key, IHookExtension(address(book)));
        assertFalse(hook.isInstalled(pool, address(book)));
    }

    /// @dev Native currency: a bid sells currency1 for ETH; the treasury takes its ETH share as WETH.
    function test_nativeTreasuryAsWeth() public {
        key = PoolKey(Currency.wrap(address(0)), currency1, 3000, 10, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        vm.deal(address(this), 100 ether);
        lpRouter.modifyLiquidity{value: 10 ether}(key, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
        _install(_policy());
        _placeFixed(false, -100, 1e11);
        swapRouter.swap{value: 5e17}(key, SwapParams(true, -5e17, MIN_LIMIT), PoolSwapTest.TestSettings(false, false), "");
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
        key = PoolKey(Currency.wrap(address(0)), currency1, 3000, 10, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        vm.deal(address(this), 100 ether);
        lpRouter.modifyLiquidity{value: 10 ether}(key, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
        _install(_policy());
        vm.deal(MAKER, 1 ether);
        vm.prank(MAKER);
        vm.expectRevert(BookOrders.InvalidAmount.selector);
        book.placeFixed{value: 1}(key, true, 100, 1e5);
        vm.prank(MAKER);
        uint256 id = book.placeFixed{value: 1e11}(key, true, 100, 1e5);
        _swap(SwapParams(false, -5e16, MAX_LIMIT));
        (FixedBook.Order memory order, uint64 filled) = book.fixedOrder(pool, id);
        assertEq(filled, order.lots, "ETH sold");
        vm.prank(MAKER);
        assertGt(book.claimFixed(pool, id, MAKER), 0);
        _checkBacking();
    }

    /// @dev An earlier extension overrides the LP fee in a dynamic-fee pool: the book charges takers that fee.
    function test_feeOverrideFromEarlierExtension() public {
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        _lp(-6000, 6000, 1e18);
        FeeOverrider overrider = new FeeOverrider(10_000);
        uint16 beforeSwap = uint16(1) << uint8(CallbackType.BeforeSwap);
        catalog.admit(
            address(overrider), IHookCatalog.Entry(address(overrider).codehash, beforeSwap, true, false, false, true, true)
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
        vm.mockCallRevert(vault, abi.encodeWithSelector(KernelHookVault.settleDebtFor.selector, pool, address(book)), "");
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
        catalog.admit(address(tax), IHookCatalog.Entry(address(tax).codehash, beforeSwap, true, false, false, true, true));
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
    /// the book's vault although the swap's own delta was zero. The book now checks its vault balances: the move rolls
    /// back with the payment, the fill stays, and the next move succeeds once the extension is gone.
    function test_priceMoveWithAPaymentToTheExecutorRollsBack() public {
        ExecutorGift gift = _gift(CallbackType.BeforeSwap, false);
        _installInactive(_settings(), _policy());
        hook.activateExtension(key, IHookExtension(address(gift)));
        hook.activateExtension(key, IHookExtension(address(book)));
        uint256 id = _placeFixed(true, 200, 1e11);
        _expectGift();
        vm.recordLogs();
        _swap(SwapParams(false, -5e16, MAX_LIMIT));
        // The recorded logs keep the book's own skip inside the reverted move (ReentrancyDenied), so the fill and the
        // expected payment show that the book ran and reached the move.
        assertFalse(_emitted(OrderBook.PriceMoved.selector), "no price move");
        (, uint64 filled) = book.fixedOrder(pool, id);
        assertGt(filled, 0, "the fill stays");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, PRICE_1, "the price stays");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(gift)), 1e6, "the payment rolled back");
        _checkBacking();
        hook.deactivateExtension(key, IHookExtension(address(gift)));
        _swap(SwapParams(false, -1e16, MAX_LIMIT));
        (price,,,) = manager.getSlot0(pool);
        assertEq(price, TickMath.getSqrtPriceAtTick(200), "the next move succeeds");
        _checkBacking();
    }

    /// @dev The same during the LP donation, with the payment in the donated currency, which would have cost the book
    /// less than it booked.
    function test_donationWithAPaymentToTheExecutorRollsBack() public {
        _lp(-6000, 6000, 1e18);
        ExecutorGift gift = _gift(CallbackType.BeforeDonate, true);
        hook.activateExtension(key, IHookExtension(address(gift)));
        _install(_policy());
        _placeFixed(true, 100, 1e11);
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
        _swap(SwapParams(true, -1e15, MIN_LIMIT));
        assertTrue(_emitted(OrderBook.LpFeesDonated.selector), "the retry donates");
        assertEq(book.ledger(pool).lpFees[1], 0, "the kept share donated");
        _checkBacking();
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
    /// the same transaction, which moved the empty pool's price to it. Each beforeSwap now clears the record.
    function test_skippedAfterSwapLeavesNoFrontier() public {
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 1_000_000;
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 3_000_000;
        _installWith(settings, _policy());
        uint256 id = _placeFixed(true, 200, 1e11);
        TwoSwaps swaps = new TwoSwaps(swapRouter, currency0, currency1);
        MockERC20(Currency.unwrap(currency0)).mint(address(swaps), 1e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(swaps), 1e18);
        uint160 limit = TickMath.getSqrtPriceAtTick(-100);
        vm.recordLogs();
        // The first swap fills the book with too little gas left for the book's afterSwap. The second, which the book
        // does not fill, moves the empty AMM to its limit.
        swaps.run(key, SwapParams(false, -5e16, MAX_LIMIT), 2_500_000, SwapParams(true, -1e6, limit));
        assertTrue(_skipped(), "the first afterSwap skipped");
        (, uint64 filled) = book.fixedOrder(pool, id);
        assertGt(filled, 0, "the first swap filled the book");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, limit, "no move to the first swap's frontier");
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
            _checkBacking();
        }
        _closeAll();
    }

    uint256[] private fixedIds;
    uint256[] private rangeIds;

    function _randomFixed(uint256 r) private {
        (, int24 tick,,) = manager.getSlot0(pool);
        bool sell0 = r & 1 == 1;
        int24 offset = int24(int256((r >> 8) % 40));
        int24 at = sell0 ? tick + 1 + offset : tick - offset; // asks above the pool price, bids at or below it
        if (!_postOnlyHolds(sell0, at)) return;
        vm.prank(MAKER);
        fixedIds.push(book.placeFixed(key, sell0, at, uint64(1 + (r >> 20) % 1e11)));
    }

    function _randomRange(uint256 r) private {
        (, int24 tick,,) = manager.getSlot0(pool);
        bool sell0 = r & 1 == 1;
        int24 near = sell0 ? tick + 1 + int24(int256((r >> 8) % 40)) : tick - 1 - int24(int256((r >> 8) % 40));
        if (!_postOnlyHolds(sell0, near)) return;
        int24 width = 1 + int24(int256((r >> 20) % 200));
        (int24 lower, int24 upper) = sell0 ? (near, near + width) : (near - width, near);
        vm.prank(MAKER);
        rangeIds.push(book.placeRange(key, sell0, lower, upper, uint128(1e6 + (r >> 40) % 1e18)));
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
        vm.startPrank(MAKER);
        if (r & 1 == 1 && fixedIds.length != 0) book.cancelFixed(pool, fixedIds[(r >> 8) % fixedIds.length]);
        else if (rangeIds.length != 0) book.cancelRange(pool, rangeIds[(r >> 8) % rangeIds.length]);
        vm.stopPrank();
    }

    function _randomClaim(uint256 r) private {
        vm.startPrank(MAKER);
        if (r & 1 == 1 && fixedIds.length != 0) book.claimFixed(pool, fixedIds[(r >> 8) % fixedIds.length], MAKER);
        else if (rangeIds.length != 0) book.claimRange(pool, rangeIds[(r >> 8) % rangeIds.length], MAKER);
        vm.stopPrank();
    }

    function _closeAll() private {
        vm.startPrank(MAKER);
        for (uint256 i; i < fixedIds.length; ++i) {
            book.cancelFixed(pool, fixedIds[i]);
            book.claimFixed(pool, fixedIds[i], MAKER);
        }
        for (uint256 i; i < rangeIds.length; ++i) {
            book.cancelRange(pool, rangeIds[i]);
            book.claimRange(pool, rangeIds[i], MAKER);
        }
        vm.stopPrank();
        assertEq(book.ledger(pool).openOrders, 0, "every order settled");
        _checkBacking();
        // Undonated LP shares go out with a swap while liquidity is in range.
        (uint160 price,,,) = manager.getSlot0(pool);
        uint160 middle = TickMath.getSqrtPriceAtTick(0);
        if (price != middle) _swap(SwapParams(price > middle, -1e12, middle));
        _swap(SwapParams(true, -1e6, MIN_LIMIT));
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
        book.placeFixed(key, true, 100, 1e11);
        _record("place_fixed_first");
        vm.prank(MAKER);
        book.placeFixed(key, true, 100, 1e11);
        _record("place_fixed_join");
        vm.prank(MAKER);
        uint256 rangeId = book.placeRange(key, true, 50, 600, 1e18);
        _record("place_range");
        _swap(SwapParams(false, -1e16, MAX_LIMIT));
        _record("swap_book_and_amm");
        _swap(SwapParams(false, -3e17, MAX_LIMIT));
        _record("swap_through_level_and_range");
        vm.prank(MAKER);
        book.claimFixed(pool, 1, MAKER);
        _record("claim_fixed");
        vm.prank(MAKER);
        book.cancelRange(pool, rangeId);
        _record("cancel_range");
        _swap(SwapParams(true, -1e16, MIN_LIMIT));
        _record("swap_empty_side");
    }

    function _record(string memory label) private {
        Vm.Gas memory measured = vm.lastFrameGas();
        vm.snapshotValue("OrderBookExtensionGas", label, measured.gasTotalUsed);
    }

    // ---------------------------------------------------------------- checks

    /// @dev The vault holds exactly what the ledger owes.
    function _checkBacking() private view {
        OrderBook.Ledger memory l = book.ledger(pool);
        for (uint256 c; c < 2; ++c) {
            Currency currency = c == 0 ? key.currency0 : key.currency1;
            uint256 owed = l.escrow[c] + l.makers[c] + l.treasury[c] + l.lpFees[c] + l.reserve[c];
            assertEq(hook.VAULT().balanceOf(pool, address(book), currency), owed, "vault balance equals the ledger");
        }
    }

    function _bookFilled() private returns (uint256 specified, uint256 other) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == OrderBook.BookFilled.selector) {
                (, specified, other,,) = abi.decode(logs[i].data, (uint64, uint256, uint256, uint256, uint8));
            }
        }
    }

    /// @dev Whether the Kernel skipped the book in the recorded logs.
    function _skipped() private returns (bool) {
        return _skippedIn(vm.getRecordedLogs());
    }

    function _skippedIn(Vm.Log[] memory logs) private view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook) && logs[i].topics[0] == IKernelHook.ExtensionSkipped.selector
                    && logs[i].topics[2] == bytes32(uint256(uint160(address(book))))
            ) return true;
        }
        return false;
    }

    function _emitted(bytes32 topic) private returns (bool) {
        return _emittedIn(vm.getRecordedLogs(), topic);
    }

    function _emittedIn(Vm.Log[] memory logs, bytes32 topic) private view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- setup

    function _policy() internal pure returns (OrderBook.Policy memory p) {
        p.lotSize0 = 1e6;
        p.lotSize1 = 1e6;
        p.minRangeLiquidity = 1e6;
        p.makerFeePips = 3000;
        p.nestedFills = true;
        p.gasReserve = 300_000;
        p.treasury = TREASURY;
        p.limits = BookWalk.Limits(512, 128, 8, 64);
    }

    function _settings() internal pure returns (ExtensionSettings memory settings) {
        settings.callbackMask = MASK;
        settings.optionalCallbacks = true;
        settings.allowNesting = true;
        settings.lifecycleGasLimit = 500_000;
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 2_500_000;
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 2_500_000;
    }

    function _install(OrderBook.Policy memory p) internal {
        _installWith(_settings(), p);
    }

    function _installWith(ExtensionSettings memory settings, OrderBook.Policy memory p) internal {
        _installInactive(settings, p);
        hook.activateExtension(key, IHookExtension(address(book)));
    }

    /// @dev Installs, sets the policy and configures the book, leaving `settings` at its version.
    function _installInactive(ExtensionSettings memory settings, OrderBook.Policy memory p) internal {
        settings.configuration = abi.encode(uint64(0));
        hook.installExtension(key, IHookExtension(address(book)), settings);
        book.setPolicy(key, 0, p);
        settings.configuration = abi.encode(uint64(1));
        hook.configureExtension(key, IHookExtension(address(book)), settings);
    }

    function _placeFixed(bool sell0, int24 tick, uint64 lots) internal returns (uint256 id) {
        vm.prank(MAKER);
        id = book.placeFixed(key, sell0, tick, lots);
    }

    function _placeRange(bool sell0, int24 lower, int24 upper, uint128 liquidity) internal returns (uint256 id) {
        vm.prank(MAKER);
        id = book.placeRange(key, sell0, lower, upper, liquidity);
    }

    function _rangeDeposit(bool sell0, int24 lower, int24 upper, uint128 liquidity) internal pure returns (uint256) {
        uint160 low = TickMath.getSqrtPriceAtTick(lower);
        uint160 high = TickMath.getSqrtPriceAtTick(upper);
        return sell0
            ? SqrtPriceMath.getAmount0Delta(low, high, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(low, high, liquidity, true);
    }

    function _swap(SwapParams memory params) internal returns (BalanceDelta) {
        return swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");
    }

    function _lp(int24 lower, int24 upper, uint256 liquidity) internal {
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(liquidity), 0), "");
    }

    function _fund(MockERC20 token) private {
        token.mint(address(this), 1e30);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        token.mint(MAKER, 1e30);
        vm.prank(MAKER);
        token.approve(address(book), type(uint256).max);
    }

    receive() external payable {}
}
