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
import {OrderBook, IWETH} from "../../src/OrderBook.sol";
import {BookWalk} from "../../src/libraries/BookWalk.sol";
import {BookOrders, IDepositVault} from "../../src/libraries/BookOrders.sol";
import {FixedBook} from "../../src/libraries/FixedBook.sol";
import {RangeBook} from "../../src/libraries/RangeBook.sol";

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

/// @dev Two swaps in one transaction (Foundry clears transient storage between a test's own calls), with a call
/// between them.
contract TwoSwaps {
    PoolSwapTest internal immutable ROUTER;

    constructor(PoolSwapTest router, Currency currency0, Currency currency1) {
        ROUTER = router;
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function run(
        PoolKey calldata key,
        SwapParams calldata first,
        address target,
        bytes calldata between,
        SwapParams calldata second
    ) external {
        ROUTER.swap(key, first, PoolSwapTest.TestSettings(false, false), "");
        (bool ok,) = target.call(between);
        require(ok, "between");
        ROUTER.swap(key, second, PoolSwapTest.TestSettings(false, false), "");
    }
}

/// @dev An extension that burns a set amount of gas in its callbacks. Placed before the book in afterSwap, it can
/// leave too little of the pool's callback budget for the book, which the Kernel then skips.
contract GasBurner is FeeOverrider {
    uint256 public burn;

    constructor() FeeOverrider(0) {}

    function setBurn(uint256 amount) external {
        burn = amount;
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata)
        external
        view
        override
        returns (CallbackResult memory result)
    {
        uint256 start = gasleft();
        while (start - gasleft() < burn) {}
        return result;
    }
}

/// @dev The order book extension through the Kernel, against a real PoolManager: shared setup and checks.
abstract contract OrderBookFixture is Test {
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

    function setUp() public virtual {
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


    // ---------------------------------------------------------------- checks

    /// @dev The vault holds exactly what the ledger owes.
    function _checkBacking() internal view {
        OrderBook.Ledger memory l = book.ledger(pool);
        for (uint256 c; c < 2; ++c) {
            Currency currency = c == 0 ? key.currency0 : key.currency1;
            uint256 owed = l.escrow[c] + l.makers[c] + l.treasury[c] + l.lpFees[c] + l.reserve[c];
            assertEq(hook.VAULT().balanceOf(pool, address(book), currency), owed, "vault balance equals the ledger");
        }
    }

    function _bookFilled() internal returns (uint256 specified, uint256 other) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(book) && logs[i].topics[0] == OrderBook.BookFilled.selector) {
                (, specified, other,,) = abi.decode(logs[i].data, (uint64, uint256, uint256, uint256, uint8));
            }
        }
    }

    /// @dev Whether the Kernel skipped the book in the recorded logs.
    function _skipped() internal returns (bool) {
        return _skippedIn(vm.getRecordedLogs());
    }

    function _skippedIn(Vm.Log[] memory logs) internal view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook) && logs[i].topics[0] == IKernelHook.ExtensionSkipped.selector
                    && logs[i].topics[2] == bytes32(uint256(uint160(address(book))))
            ) return true;
        }
        return false;
    }

    function _emitted(bytes32 topic) internal returns (bool) {
        return _emittedIn(vm.getRecordedLogs(), topic);
    }

    function _emittedIn(Vm.Log[] memory logs, bytes32 topic) internal view returns (bool) {
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

    /// @dev Installs a GasBurner in afterSwap ahead of the book (install it before the book), not yet active.
    function _installBurner() internal returns (GasBurner burner) {
        burner = new GasBurner();
        uint16 afterSwap = uint16(1) << uint8(CallbackType.AfterSwap);
        catalog.admit(address(burner), IHookCatalog.Entry(address(burner).codehash, afterSwap, true, false, false, true, true));
        ExtensionSettings memory settings;
        settings.callbackMask = afterSwap;
        settings.optionalCallbacks = true;
        settings.lifecycleGasLimit = 500_000;
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 3_300_000;
        hook.installExtension(key, IHookExtension(address(burner)), settings);
    }

    /// @dev Book settings small enough to fit the pool's afterSwap budget after the burner, unless it burns a lot.
    function _settingsBesideBurner() internal pure returns (ExtensionSettings memory settings) {
        settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 1_000_000;
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 1_000_000;
    }

    /// @dev Installs, sets the policy and configures the book, leaving `settings` at its version.
    function _installInactive(ExtensionSettings memory settings, OrderBook.Policy memory p) internal {
        settings.configuration = abi.encode(uint64(0));
        hook.installExtension(key, IHookExtension(address(book)), settings);
        book.setPolicy(key, 0, p);
        settings.configuration = abi.encode(uint64(1));
        hook.configureExtension(key, IHookExtension(address(book)), settings);
    }

    /// @dev The pool's current policy version, which placements name. Read from storage (`_installations`, slot 0:
    /// installed, then the policy version) rather than through `policy`, so it can sit inside a call made under
    /// `vm.prank` or `vm.expectRevert` without being that call.
    function _version() internal view returns (uint64) {
        bytes32 word = vm.load(address(book), keccak256(abi.encode(pool, uint256(0))));
        return uint64(uint256(word) >> 8);
    }

    function _placeFixed(bool sell0, int24 tick, uint64 lots) internal returns (uint256 id) {
        vm.prank(MAKER);
        id = book.placeFixed(key, sell0, tick, lots, _version());
    }

    function _placeRange(bool sell0, int24 lower, int24 upper, uint128 liquidity) internal returns (uint256 id) {
        vm.prank(MAKER);
        id = book.placeRange(key, sell0, lower, upper, liquidity, _version());
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

    function _fund(MockERC20 token) internal {
        token.mint(address(this), 1e30);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        token.mint(MAKER, 1e30);
        vm.prank(MAKER);
        token.approve(address(book), type(uint256).max);
    }

    receive() external payable {}
}
