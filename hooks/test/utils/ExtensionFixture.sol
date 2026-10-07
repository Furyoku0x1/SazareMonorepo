// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookCatalog} from "core/src/HookCatalog.sol";
import {KernelHook} from "core/src/KernelHook.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {ExtensionSettings, CallbackType, CALLBACK_COUNT} from "core/src/types/KernelHookTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LimitOrder} from "../../src/LimitOrder.sol";

/// @dev PoolManagerArtifact builds the solc 0.8.26 unit separately from extension/Kernel sources.
abstract contract ExtensionFixture is Test {
    receive() external payable {}
    address internal constant HOOK_ADDRESS = address(uint160(0xC0FFEE) << 136 | uint160(Hooks.ALL_HOOK_MASK));
    uint160 internal constant SQRT_PRICE_1_1 = uint160(1 << 96);
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolDonateTest internal donateRouter;
    Currency internal currency0;
    Currency internal currency1;
    HookCatalog internal catalog;
    KernelHook internal hook;
    LimitOrder internal orders;
    PoolKey internal key;
    PoolId internal pool;

    function setUp() public virtual {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        currency0 = Currency.wrap(address(a) < address(b) ? address(a) : address(b));
        currency1 = Currency.wrap(address(a) < address(b) ? address(b) : address(a));
        _fundAsset(a);
        _fundAsset(b);
        catalog = new HookCatalog();
        deployCodeTo("KernelHook.sol:KernelHook", abi.encode(manager, address(catalog)), HOOK_ADDRESS);
        hook = KernelHook(HOOK_ADDRESS);
        orders = LimitOrder(deployCode("LimitOrder.sol:LimitOrder", abi.encode(IKernelHook(address(hook)))));
        _admit(address(orders));
        IERC20(Currency.unwrap(currency0)).approve(address(orders), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(orders), type(uint256).max);
        key = _poolKey();
        pool = key.toId();
        _createPool(key);
        _wideLiquidity(key);
    }

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
    }

    function _createPool(PoolKey memory target) internal {
        hook.preparePool(target);
        manager.initialize(target, SQRT_PRICE_1_1);
    }

    function _admit(address extension) internal {
        uint16 mask = uint16(1) << uint8(CallbackType.BeforeSwap);
        catalog.admit(extension, IHookCatalog.Entry(extension.codehash, mask, true, false, false, true, true));
    }

    function _settings(uint16 mask, bool optional, bool nesting, uint32 gasLimit)
        internal
        pure
        returns (ExtensionSettings memory settings)
    {
        settings.callbackMask = mask;
        settings.optionalCallbacks = optional;
        settings.allowNesting = nesting;
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            settings.callbackGasLimits[i] = gasLimit;
        }
    }

    function _swapExactInput(PoolKey memory target, bool zeroForOne, uint256 input) internal returns (BalanceDelta) {
        return swapRouter.swap(
            target,
            SwapParams(zeroForOne, -int256(input), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _fundAsset(MockERC20 asset) private {
        asset.mint(address(this), type(uint128).max);
        asset.approve(address(swapRouter), type(uint256).max);
        asset.approve(address(modifyLiquidityRouter), type(uint256).max);
        asset.approve(address(donateRouter), type(uint256).max);
    }

    function _wideLiquidity(PoolKey memory target) internal {
        modifyLiquidityRouter.modifyLiquidity(target, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
    }

    function _orderPolicy() internal pure returns (LimitOrder.Policy memory policy) {
        policy.minimumOrder = 1;
        policy.maximumLifetime = 30 days;
        policy.maximumOpenOrders = 4096;
        policy.maximumFills = 4;
        policy.maximumInspections = 8;
        policy.maximumCoSubscribers = 1;
        policy.allowNested = true;
    }

    function _installOrders(PoolKey memory target, LimitOrder.Policy memory policy) internal {
        ExtensionSettings memory settings = _settings(uint16(1) << uint8(CallbackType.BeforeSwap), true, false, 600_000);
        settings.lifecycleGasLimit = 500_000;
        settings.configuration = abi.encode(uint64(0));
        hook.installExtension(target, IHookExtension(address(orders)), settings);
        orders.setPolicy(target, 0, policy);
        settings.configuration = abi.encode(uint64(1));
        hook.configureExtension(target, IHookExtension(address(orders)), settings);
        hook.activateExtension(target, IHookExtension(address(orders)));
    }

    function _request(bool sell0, uint128 amount, uint128 n, uint128 d)
        internal
        view
        returns (LimitOrder.OrderRequest memory request)
    {
        request.sellCurrency0 = sell0;
        request.amount = amount;
        request.priceNumerator = n;
        request.priceDenominator = d;
        request.expiry = uint40(block.timestamp + 1 days);
        request.expectedPolicyVersion = 1;
        request.allowNested = true;
        request.maximumFeeBps = 1000;
    }

    function _peer() internal returns (PoolKey memory peer) {
        peer = PoolKey(currency0, currency1, 500, 60, IHooks(address(hook)));
        _createPool(peer);
        _wideLiquidity(peer);
    }

    function _assertLiabilities(PoolId target) internal view {
        (uint256 liability0, uint256 liability1, bool settled) = orders.accountingState(target);
        assertTrue(settled);
        assertEq(hook.VAULT().balanceOf(target, address(orders), currency0), liability0);
        assertEq(hook.VAULT().balanceOf(target, address(orders), currency1), liability1);
    }
}
