// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {KernelHookVault} from "core/src/KernelHookVault.sol";
import {
    CALLBACK_COUNT,
    CallbackResult,
    CallbackType,
    ExecutionContext,
    ExtensionSettings,
    Operation,
    RouteAction
} from "core/src/types/KernelHookTypes.sol";
import {OrderBook} from "../src/orderbook/OrderBook.sol";
import {BookOrders, IDepositVault} from "../src/libraries/orderbook/BookOrders.sol";
import {OrderBookFixture, FeeOverrider} from "./utils/OrderBookFixture.sol";

/// @dev A router that syncs a currency before its swap ("pay first": sync, swap, then transfer and settle), which is
/// legal v4 usage. Any pending ERC20 sync works, even one in a currency the pool does not use.
contract SyncFirstRouter is IUnlockCallback {
    IPoolManager internal immutable MANAGER;

    constructor(IPoolManager manager) {
        MANAGER = manager;
    }

    function swap(PoolKey memory key, SwapParams memory params, Currency syncFirst) external returns (BalanceDelta) {
        return abi.decode(MANAGER.unlock(abi.encode(key, params, syncFirst)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER));
        (PoolKey memory key, SwapParams memory params, Currency syncFirst) =
            abi.decode(data, (PoolKey, SwapParams, Currency));
        if (Currency.unwrap(syncFirst) != address(0)) MANAGER.sync(syncFirst);
        BalanceDelta delta = MANAGER.swap(key, params, "");
        _settle(key.currency0, delta.amount0(), syncFirst);
        _settle(key.currency1, delta.amount1(), syncFirst);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount, Currency synced) private {
        if (amount < 0) {
            if (Currency.unwrap(currency) != Currency.unwrap(synced)) MANAGER.sync(currency);
            MockERC20(Currency.unwrap(currency)).transfer(address(MANAGER), uint256(uint128(-amount)));
            MANAGER.settle();
        } else if (amount > 0) {
            MANAGER.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}

/// @dev An admitted nesting extension in a pool the attacker controls: from its afterSwap it routes one swap into any
/// other Kernel pool. The gas it has (its installation's afterSwap limit, which the attacker sets) is all the nested
/// swap gets.
contract CrossPoolNester is FeeOverrider {
    IKernelHook public immutable KERNEL;
    PoolKey internal _target;
    SwapParams internal _params;
    bool public armed;

    constructor(IKernelHook kernel) FeeOverrider(0) {
        KERNEL = kernel;
    }

    function arm(PoolKey calldata target, SwapParams calldata params) external {
        (_target, _params, armed) = (target, params, true);
    }

    function fund(address vault, PoolId pool, Currency currency, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).approve(vault, amount);
        IDepositVault(vault).deposit(pool, address(this), currency, amount);
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata)
        external
        override
        returns (CallbackResult memory result)
    {
        if (!armed) return result;
        armed = false;
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = RouteAction(_target, Operation.Swap, abi.encode(_params), "");
        KERNEL.executeRoute(actions);
    }
}

/// @dev Routes a swap into another pool, only from a nested operation (depth 2): from inside the book's own afterSwap
/// routes in the pool it is installed in.
contract DeepNester is FeeOverrider {
    IKernelHook public immutable KERNEL;
    PoolKey internal _target;
    SwapParams internal _params;

    constructor(IKernelHook kernel, PoolKey memory target, SwapParams memory params) FeeOverrider(0) {
        (KERNEL, _target, _params) = (kernel, target, params);
    }

    function fund(address vault, PoolId pool, Currency currency, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).approve(vault, amount);
        IDepositVault(vault).deposit(pool, address(this), currency, amount);
    }

    function onCallback(ExecutionContext calldata context, PoolKey calldata, bytes calldata)
        external
        override
        returns (CallbackResult memory result)
    {
        if (context.depth != 2) return result;
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = RouteAction(_target, Operation.Swap, abi.encode(_params), "");
        KERNEL.executeRoute(actions);
    }
}

/// @dev An optional extension that, when armed, reverts with the 4-byte selector of the Kernel dispatch's internal
/// root-shortfall signal (KernelHookDispatch.InsufficientCallbackGas), or with an ordinary error.
contract SignalForger is FeeOverrider {
    error InsufficientCallbackGas();
    error Ordinary();

    uint8 public mode; // 0 off, 1 forged signal, 2 ordinary revert

    constructor() FeeOverrider(0) {}

    function setMode(uint8 m) external {
        mode = m;
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata)
        external
        view
        override
        returns (CallbackResult memory result)
    {
        if (mode == 1) revert InsufficientCallbackGas();
        if (mode == 2) revert Ordinary();
        return result;
    }
}

/// @dev An optional extension before the book in beforeSwap that only leaves an ERC20 sync pending: no deltas, no
/// nonzero-delta count change, so the Kernel's accounting tripwire does not see it.
contract SyncLeaver is FeeOverrider {
    IPoolManager internal immutable MANAGER;
    Currency internal immutable CURRENCY;

    constructor(IPoolManager manager, Currency currency) FeeOverrider(0) {
        (MANAGER, CURRENCY) = (manager, currency);
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata)
        external
        override
        returns (CallbackResult memory result)
    {
        MANAGER.sync(CURRENCY);
        return result;
    }
}

/// @dev Round-2 audit, integration: the order book under the Kernel next to other extensions and pools. A swapper
/// or another pool cannot make the Kernel skip the book: the swap either runs with it or reverts.
/// @dev A relay the book pool's admin installs next to the book: it routes one small swap into another Kernel pool
/// whenever its callback runs (as a cross-pool rebalancer would). Optional, so its failures never block the pool.
contract AlwaysRelay is FeeOverrider {
    IKernelHook public immutable KERNEL;
    PoolKey internal _target;

    constructor(IKernelHook kernel, PoolKey memory target) FeeOverrider(0) {
        (KERNEL, _target) = (kernel, target);
    }

    function fund(address vault, PoolId pool, Currency currency, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).approve(vault, amount);
        IDepositVault(vault).deposit(pool, address(this), currency, amount);
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata)
        external
        override
        returns (CallbackResult memory result)
    {
        RouteAction[] memory actions = new RouteAction[](1);
        SwapParams memory params = SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1);
        actions[0] = RouteAction(_target, Operation.Swap, abi.encode(params), "");
        KERNEL.executeRoute(actions);
    }
}

/// @dev The attacker's extension in its own pool: at one depth only (3: its pool entered by the relay from inside one
/// of the book's own routes, where the book's call is still in progress), it routes a buy into the book's pool.
contract DepthReturner is FeeOverrider {
    IKernelHook public immutable KERNEL;
    uint8 public immutable DEPTH;
    PoolKey internal _victim;
    SwapParams internal _push;

    constructor(IKernelHook kernel, PoolKey memory victim, SwapParams memory push, uint8 depth) FeeOverrider(0) {
        (KERNEL, _victim, _push, DEPTH) = (kernel, victim, push, depth);
    }

    function fund(address vault, PoolId pool, Currency currency, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).approve(vault, amount);
        IDepositVault(vault).deposit(pool, address(this), currency, amount);
    }

    function onCallback(ExecutionContext calldata context, PoolKey calldata, bytes calldata)
        external
        override
        returns (CallbackResult memory result)
    {
        if (context.depth != DEPTH) return result;
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = RouteAction(_victim, Operation.Swap, abi.encode(_push), "");
        KERNEL.executeRoute(actions);
    }
}

contract OrderBookIntegrationTest is OrderBookFixture {
    using StateLibrary for IPoolManager;

    uint16 internal constant BEFORE_SWAP = uint16(1) << uint8(CallbackType.BeforeSwap);
    uint16 internal constant AFTER_SWAP = uint16(1) << uint8(CallbackType.AfterSwap);
    uint16 internal constant AFTER_DONATE = uint16(1) << uint8(CallbackType.AfterDonate);
    /// @dev Where the cross-pool push stops: far enough to strand a book, near enough for the move back to fit 5M gas.
    int24 internal constant PUSH_TICK = 100_000;

    /// @dev R2-K-2: a router that left any ERC20 sync pending before swapping made the book's output settlement
    /// fail inside its attempt, so the Kernel skipped the book and the AMM passed the ask. An operation that begins
    /// with a sync pending now reverts (SyncPending); routers that sync and settle in one step are unaffected.
    function test_regression_pendingSyncRevertsInsteadOfSkippingTheBook() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 100, 1e11);
        SwapParams memory buy = SwapParams(false, -2e17, MAX_LIMIT);
        SyncFirstRouter router = _syncRouter();
        uint256 snapshot = vm.snapshotState();
        router.swap(key, buy, Currency.wrap(address(0)));
        (, uint64 filled) = book.fixedOrder(pool, ask);
        assertEq(filled, 1e11, "control: the ask fills");
        vm.revertToState(snapshot);
        MockERC20 unrelated = new MockERC20("U", "U", 18);
        try router.swap(key, buy, Currency.wrap(address(unrelated))) {
            fail("a pending sync must revert the swap, not skip the book");
        } catch (bytes memory err) {
            assertTrue(_contains(err, IKernelHook.SyncPending.selector), "SyncPending");
        }
        (, filled) = book.fixedOrder(pool, ask);
        assertEq(filled, 0);
        _checkBacking();
    }

    /// @dev R2-K-2 / R2-K-9: an extension before the book that only leaves a sync pending fails its own attempt; the
    /// book still runs.
    function test_regression_extensionLeavingASyncFailsItsOwnAttempt() public {
        _lp(-6000, 6000, 1e18);
        SyncLeaver leaver = new SyncLeaver(manager, currency0);
        _installExtension(address(leaver), BEFORE_SWAP, true, 200_000);
        _installInactive(_settings(), _policy());
        hook.activateExtension(key, IHookExtension(address(leaver)));
        hook.activateExtension(key, IHookExtension(address(book)));
        uint256 ask = _placeFixed(true, 100, 1e11);
        vm.recordLogs();
        _swap(SwapParams(false, -2e17, MAX_LIMIT));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(_skipReason(logs, pool, address(leaver), CallbackType.BeforeSwap).length, 0, "the leaver is skipped");
        (, uint64 filled) = book.fixedOrder(pool, ask);
        assertEq(filled, 1e11, "the book fills");
        _checkBacking();
    }

    /// @dev R2-K-3: an extension in a pool the attacker controls routed a swap into the book's pool with too little gas
    /// for the book, which was skipped while the AMM passed the ask. That nested swap now fails (the attacker's own
    /// optional attempt is skipped); with enough gas it fills the book.
    function test_regression_crossPoolEntryCannotSkipTheBook() public {
        uint256 snapshot = vm.snapshotState();
        assertEq(_crossPoolBuy(3_300_000, true), 1e11, "enough parent gas: the book fills the ask");
        vm.revertToState(snapshot);
        assertEq(_crossPoolBuy(1_000_000, false), 0, "too little: the nested swap fails");
        (, int24 tick,,) = manager.getSlot0(pool);
        assertLt(tick, 100, "the AMM did not pass the ask");
    }

    function _crossPoolBuy(uint32 nesterGas, bool routes) private returns (uint64 filled) {
        _lp(-6000, 6000, 1e18);
        OrderBook.Policy memory p = _policy();
        p.nestedFills = true;
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 800_000;
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 800_000;
        _installWith(settings, p);
        uint256 ask = _placeFixed(true, 100, 1e11);
        PoolKey memory attackerPool = PoolKey(currency0, currency1, 500, 60, IHooks(address(hook)));
        hook.preparePool(attackerPool);
        manager.initialize(attackerPool, PRICE_1);
        CrossPoolNester nester = new CrossPoolNester(IKernelHook(address(hook)));
        catalog.admit(
            address(nester), IHookCatalog.Entry(address(nester).codehash, AFTER_SWAP, true, true, false, true, true)
        );
        hook.installExtension(
            attackerPool, IHookExtension(address(nester)), _extensionSettings(AFTER_SWAP, true, nesterGas)
        );
        hook.activateExtension(attackerPool, IHookExtension(address(nester)));
        MockERC20(Currency.unwrap(currency1)).mint(address(nester), 1e18);
        nester.fund(address(hook.VAULT()), attackerPool.toId(), currency1, 1e18);
        nester.arm(key, SwapParams(false, -2e17, TickMath.getSqrtPriceAtTick(PUSH_TICK)));
        swapRouter.swap(
            attackerPool,
            SwapParams(true, -1, TickMath.getSqrtPriceAtTick(-60)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(nester.armed(), !routes, "the route ran only with enough gas");
        (, filled) = book.fixedOrder(pool, ask);
        _checkBacking();
    }

    /// @dev Round 4 pre-audit (cross-pool R3-2): a route's depth was also checked against its root pool's limit, which
    /// the root pool's admin sets. An attacker's pool with its limit at 2 routed a swap into an empty pool, which ran
    /// to the router's limit; the book's move back, one level deeper, was refused and caught, so the price stayed
    /// there. The Kernel now limits a route by its target pool and the pool that starts it, not the root pool: the
    /// book's move back answers to its own pool's limit and runs.
    function test_regression_rootDepthLimitCannotStrandAnEmptyPool() public {
        uint8[2] memory originDepths = [uint8(4), 2];
        // i < originDepths.length
        for (uint256 i; i < originDepths.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            (bool routed, uint160 sqrtPriceX96) = _crossPoolPush(originDepths[i], 4, false);
            assertTrue(routed, "the route runs");
            assertEq(sqrtPriceX96, PRICE_1, "the book moves the price back");
            _checkBacking();
            vm.revertToState(snapshot);
        }
    }

    /// @dev Round 4 pre-audit (Sol): a route entering the book's pool at the pool's own depth limit leaves no level for
    /// the move back, so a push stayed. One hop reaches a limit of 2 here; a chain of the attacker's own pools reaches
    /// any limit. The book now refuses a nested swap into a pool with no liquidity in range when its limit leaves no
    /// room for the move, which fails the route; with liquidity in range the swap trades on the AMM and runs.
    function test_regression_entryAtTheDepthLimitCannotStrandAnEmptyPool() public {
        uint256 snapshot = vm.snapshotState();
        (bool routed, uint160 sqrtPriceX96) = _crossPoolPush(4, 2, false);
        assertFalse(routed, "the route fails");
        assertEq(sqrtPriceX96, PRICE_1, "the empty pool's price stays");
        _checkBacking();
        vm.revertToState(snapshot);
        (routed, sqrtPriceX96) = _crossPoolPush(4, 2, true);
        assertTrue(routed, "with liquidity in range, the route runs");
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(PUSH_TICK), "the price stays where the swap ended");
    }

    /// @dev Sol's review of an earlier fix, which failed every nested swap whose move back failed: a nested swap that
    /// trades through the pool's last liquidity in range leaves no liquidity, and the move back is blocked by the
    /// liquidity just traded. That swap is legitimate and keeps its result, as a root swap does.
    function test_nestedSwapThroughTheLastLiquidityKeepsItsResult() public {
        (bool routed, uint160 sqrtPriceX96) = _crossPoolPush(4, 4, true);
        assertTrue(routed, "the route runs");
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(PUSH_TICK), "the price stays where the swap ended");
        _checkBacking();
    }

    /// @dev From another pool with the given depth limit, an extension buys from the book's pool (with the given depth
    /// limit) up to PUSH_TICK. The
    /// book has no ask, so it fills nothing. With liquidity, the pool has a range around the price that the buy
    /// trades through; without, it is empty.
    function _crossPoolPush(uint8 originDepth, uint8 victimDepth, bool liquidity)
        private
        returns (bool routed, uint160 sqrtPriceX96)
    {
        if (liquidity) _lp(-60, 60, 1e18);
        (,,, uint32[CALLBACK_COUNT] memory victimBudgets) = hook.poolState(pool);
        hook.setExecutionLimits(key, victimDepth, victimBudgets);
        _install(_policy());
        PoolKey memory originPool = PoolKey(currency0, currency1, 500, 60, IHooks(address(hook)));
        hook.preparePool(originPool);
        manager.initialize(originPool, PRICE_1);
        uint32[CALLBACK_COUNT] memory callbackGasBudgets;
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            callbackGasBudgets[i] = 12_000_000;
        }
        hook.setExecutionLimits(originPool, originDepth, callbackGasBudgets);
        CrossPoolNester nester = new CrossPoolNester(IKernelHook(address(hook)));
        catalog.admit(
            address(nester), IHookCatalog.Entry(address(nester).codehash, AFTER_SWAP, true, true, false, true, true)
        );
        hook.installExtension(
            originPool, IHookExtension(address(nester)), _extensionSettings(AFTER_SWAP, true, 5_000_000)
        );
        hook.activateExtension(originPool, IHookExtension(address(nester)));
        MockERC20(Currency.unwrap(currency1)).mint(address(nester), 1e18);
        nester.fund(address(hook.VAULT()), originPool.toId(), currency1, 1e18);
        nester.arm(key, SwapParams(false, -2e17, TickMath.getSqrtPriceAtTick(PUSH_TICK)));
        swapRouter.swap(
            originPool,
            SwapParams(true, -1, TickMath.getSqrtPriceAtTick(-60)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        routed = !nester.armed();
        (sqrtPriceX96,,,) = manager.getSlot0(pool);
    }

    /// @dev R2-K-4: an optional extension reverting with the Kernel's internal shortfall signal used to revert the
    /// whole swap. It is now skipped like any other failure, and the book fills.
    function test_regression_forgedGasSignalIsSkipped() public {
        _lp(-6000, 6000, 1e18);
        SignalForger forger = new SignalForger();
        _installExtension(address(forger), BEFORE_SWAP, true, 200_000);
        _installInactive(_settings(), _policy());
        hook.activateExtension(key, IHookExtension(address(forger)));
        hook.activateExtension(key, IHookExtension(address(book)));
        uint256 ask = _placeFixed(true, 100, 1e11);
        forger.setMode(1);
        vm.recordLogs();
        _swap(SwapParams(false, -1e16, MAX_LIMIT));
        assertGt(_skipReason(vm.getRecordedLogs(), pool, address(forger), CallbackType.BeforeSwap).length, 0);
        (, uint64 filled) = book.fixedOrder(pool, ask);
        assertGt(filled, 0, "the book fills");
    }

    /// @dev Round 3 (R3-1): the book's reentry flag was contract-wide and held through its afterSwap routes. An
    /// extension in an attacker's pool A, which also runs the book, routed a swap into pool B from inside one of those
    /// routes; B's book refused the callback (ExecutionInProgress), the Kernel skipped it, and B's AMM passed B's ask.
    /// The flag is now per pool: B's book fills. Both routes: the empty-pool price move and the LP donation.
    function test_regression_bookRunsInAnotherPoolDuringItsOwnRoute() public {
        uint256 snapshot = vm.snapshotState();
        _crossPoolDuringRoute(false);
        vm.revertToState(snapshot);
        _crossPoolDuringRoute(true);
    }

    function _crossPoolDuringRoute(bool donation) private {
        // Pool B, the victim: AMM liquidity, an ask at tick 100, book limits the attacker's extension can afford.
        _lp(-6000, 6000, 1e18);
        ExtensionSettings memory victimSettings = _settings();
        victimSettings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 800_000;
        victimSettings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 800_000;
        _installWith(victimSettings, _policy());
        uint256 victimAsk = _placeFixed(true, 100, 1e11);
        (PoolKey memory victim, PoolId victimPool) = (key, pool);
        // Pool A, the attacker's: the same book, and a nester that acts inside the book's route.
        key = PoolKey(currency0, currency1, 500, 60, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        uint32[CALLBACK_COUNT] memory budgets;
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = 20_000_000;
        }
        hook.setExecutionLimits(key, 4, budgets);
        if (donation) _lp(-6000, 6000, 1e18);
        DeepNester nester = new DeepNester(IKernelHook(address(hook)), victim, SwapParams(false, -2e17, MAX_LIMIT));
        uint16 mask = donation ? uint16(1) << uint8(CallbackType.BeforeDonate) : BEFORE_SWAP;
        _installExtension(address(nester), mask, true, 3_700_000);
        MockERC20(Currency.unwrap(currency1)).mint(address(nester), 1e18);
        nester.fund(address(hook.VAULT()), pool, currency1, 1e18);
        ExtensionSettings memory attackerSettings = _settings();
        attackerSettings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 5_000_000;
        _installInactive(attackerSettings, _policy());
        hook.activateExtension(key, IHookExtension(address(nester)));
        hook.activateExtension(key, IHookExtension(address(book)));
        _placeFixed(true, 60, donation ? 1e10 : 1);
        // The price move: a buy fills A's book and runs past it. The donation: a buy fills it, then a day later a
        // small swap donates the released LP share.
        _swap(SwapParams(false, donation ? -1e16 : -1e15, MAX_LIMIT));
        if (donation) {
            vm.warp(block.timestamp + 1 days);
            _swap(SwapParams(true, -1e6, MIN_LIMIT));
        }
        (key, pool) = (victim, victimPool);
        (, uint64 filled) = book.fixedOrder(pool, victimAsk);
        assertGt(filled, 0, "the victim's book filled its ask");
        _checkBacking();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Round 4, R4-1 (reviewers K4, X4, Sol): the book's call is in progress during its own routes, and the Kernel
    /// used to skip it (ReentrancyDenied) when another pool's extension, reached from inside one of them, swapped in the
    /// book's pool. Here P's optional relay (afterDonate) routes into the attacker's pool Q during the book's donation,
    /// and Q's extension buys in P. That entry is now strict: the buy fails, the relay is skipped, and the AMM does not
    /// pass the maker's ask.
    function test_regression_anotherPoolCannotSkipTheBookDuringItsDonation() public {
        (uint256 ask, int24 askTick) = _setUpReturningBuy();
        vm.recordLogs();
        _swap(SwapParams(true, -1e6, MIN_LIMIT));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_emittedIn(logs, OrderBook.LpFeesDonated.selector), "the book donated");
        assertEq(_reentrySkipsOfBook(logs), 0, "the book was never skipped");
        (, int24 tick,,) = manager.getSlot0(pool);
        assertLt(tick, askTick, "the AMM did not pass the ask");
        (, uint64 filled) = book.fixedOrder(pool, ask);
        assertEq(filled, 0);
        _checkBacking();
    }

    /// @dev Round 4, R4-1, the empty-pool form (Sol's High): with an optional relay in afterSwap, the attacker's pool
    /// pushed P's price from inside the book's move back, with the book skipped, and the book's landing check then
    /// refused its own move. The push now fails, and the move brings the price back to the swap's start.
    function test_regression_anotherPoolCannotRefuseTheEmptyPoolMove() public {
        assertEq(_emptyPoolSellWithReturner(), PRICE_1, "the book moved the empty pool back to the swap's start");
    }

    /// @return ask The maker's ask in the book's pool, just above the price.
    /// @return askTick The ask's tick.
    function _setUpReturningBuy() private returns (uint256 ask, int24 askTick) {
        PoolKey memory attackerPool = _attackerPool();
        _lp(-6000, 6000, 1e18);
        uint32[CALLBACK_COUNT] memory budgets = _budgets();
        hook.setExecutionLimits(key, 4, budgets);
        hook.setExecutionLimits(attackerPool, 4, budgets);
        AlwaysRelay relay = new AlwaysRelay(IKernelHook(address(hook)), attackerPool);
        _admitAndInstall(key, address(relay), AFTER_DONATE, 2_800_000);
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 800_000;
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 4_200_000;
        _installInactive(settings, _policy());
        hook.activateExtension(key, IHookExtension(address(relay)));
        hook.activateExtension(key, IHookExtension(address(book)));
        MockERC20(Currency.unwrap(currency0)).mint(address(relay), 1e18);
        relay.fund(address(hook.VAULT()), pool, currency0, 1e18);
        // Earlier trading leaves an LP share that the book releases over a day and donates after a later swap.
        _placeFixed(true, 100, 1e11);
        _swap(SwapParams(false, -2e17, MAX_LIMIT));
        vm.warp(block.timestamp + 1 days);
        (, int24 tick,,) = manager.getSlot0(pool);
        askTick = (tick / 20 + 10) * 20;
        ask = _placeFixed(true, askTick, 1e11);
        DepthReturner returner = new DepthReturner(
            IKernelHook(address(hook)), key, SwapParams(false, -2e17, TickMath.getSqrtPriceAtTick(askTick + 200)), 3
        );
        _admitAndInstall(attackerPool, address(returner), AFTER_SWAP, 1_500_000);
        hook.activateExtension(attackerPool, IHookExtension(address(returner)));
        MockERC20(Currency.unwrap(currency1)).mint(address(returner), 1e18);
        returner.fund(address(hook.VAULT()), attackerPool.toId(), currency1, 1e18);
    }

    function _emptyPoolSellWithReturner() private returns (uint160 sqrtPriceX96) {
        PoolKey memory attackerPool = _attackerPool();
        hook.setExecutionLimits(key, 4, _budgets());
        AlwaysRelay relay = new AlwaysRelay(IKernelHook(address(hook)), attackerPool);
        _admitAndInstall(key, address(relay), AFTER_SWAP, 3_000_000);
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 4_500_000;
        _installInactive(settings, _policy());
        hook.activateExtension(key, IHookExtension(address(relay)));
        hook.activateExtension(key, IHookExtension(address(book)));
        MockERC20(Currency.unwrap(currency0)).mint(address(relay), 1e18);
        relay.fund(address(hook.VAULT()), pool, currency0, 1e18);
        DepthReturner returner = new DepthReturner(
            IKernelHook(address(hook)), key, SwapParams(false, -2e17, TickMath.getSqrtPriceAtTick(100_000)), 3
        );
        _admitAndInstall(attackerPool, address(returner), AFTER_SWAP, 1_500_000);
        hook.activateExtension(attackerPool, IHookExtension(address(returner)));
        _swap(SwapParams(true, -1e15, TickMath.getSqrtPriceAtTick(-2000)));
        (sqrtPriceX96,,,) = manager.getSlot0(pool);
    }

    /// @dev The attacker's pool Q, with liquidity so that the relay's one-unit swap trades.
    function _attackerPool() private returns (PoolKey memory attackerPool) {
        attackerPool = PoolKey(currency0, currency1, 500, 60, IHooks(address(hook)));
        hook.preparePool(attackerPool);
        manager.initialize(attackerPool, PRICE_1);
        lpRouter.modifyLiquidity(attackerPool, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
    }

    function _budgets() private pure returns (uint32[CALLBACK_COUNT] memory budgets) {
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = 12_000_000;
        }
    }

    function _admitAndInstall(PoolKey memory target, address extension, uint16 mask, uint32 gasLimit) private {
        catalog.admit(extension, IHookCatalog.Entry(extension.codehash, mask, true, true, false, true, true));
        hook.installExtension(target, IHookExtension(extension), _extensionSettings(mask, true, gasLimit));
    }

    /// @dev Skips of the book in the book pool's beforeSwap for reentry (ReentrancyDenied).
    function _reentrySkipsOfBook(Vm.Log[] memory logs) private view returns (uint256 skips) {
        bytes32 reason = keccak256(abi.encodePacked(IKernelHook.ReentrancyDenied.selector));
        // i < logs.length
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] != IKernelHook.ExtensionSkipped.selector) continue;
            if (logs[i].topics[1] != PoolId.unwrap(pool)) continue;
            if (logs[i].topics[2] != bytes32(uint256(uint160(address(book))))) continue;
            if (logs[i].topics[3] != bytes32(uint256(CallbackType.BeforeSwap))) continue;
            if (keccak256(abi.decode(logs[i].data, (bytes))) == reason) ++skips;
        }
    }

    function _syncRouter() private returns (SyncFirstRouter router) {
        router = new SyncFirstRouter(manager);
        MockERC20(Currency.unwrap(currency0)).mint(address(router), 1e24);
        MockERC20(Currency.unwrap(currency1)).mint(address(router), 1e24);
    }

    /// @dev The reason of the Kernel's ExtensionSkipped for (pool, extension, callback), or empty if none.
    function _skipReason(Vm.Log[] memory logs, PoolId id, address extension, CallbackType callback)
        private
        view
        returns (bytes memory)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook) && logs[i].topics[0] == IKernelHook.ExtensionSkipped.selector
                    && logs[i].topics[1] == PoolId.unwrap(id)
                    && logs[i].topics[2] == bytes32(uint256(uint160(extension)))
                    && logs[i].topics[3] == bytes32(uint256(callback))
            ) return abi.decode(logs[i].data, (bytes));
        }
        return "";
    }

    function _contains(bytes memory data, bytes4 selector) private pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    function _installExtension(address extension, uint16 mask, bool optional, uint32 gasLimit) private {
        catalog.admit(extension, IHookCatalog.Entry(extension.codehash, mask, true, true, false, true, true));
        hook.installExtension(key, IHookExtension(extension), _extensionSettings(mask, optional, gasLimit));
    }

    function _extensionSettings(uint16 mask, bool optional, uint32 gasLimit)
        private
        pure
        returns (ExtensionSettings memory settings)
    {
        settings.callbackMask = mask;
        settings.optionalCallbacks = optional;
        settings.allowNesting = true;
        settings.lifecycleGasLimit = 500_000;
        for (uint8 i; i < 16; ++i) {
            if (mask & (uint16(1) << i) != 0) settings.callbackGasLimits[i] = gasLimit;
        }
    }
}
