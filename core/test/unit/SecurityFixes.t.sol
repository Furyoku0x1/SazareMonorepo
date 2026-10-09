// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {CodexDispatchRecorder} from "../mocks/CodexDispatchRecorder.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {CodexLifecycleExtension} from "../mocks/CodexLifecycleExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IKernelHookExtension} from "../../src/interfaces/IKernelHookExtension.sol";
import {CallbackLibrary} from "../../src/libraries/CallbackLibrary.sol";
import {CallbackType, ExtensionSettings, Operation, RouteAction} from "../../src/types/KernelHookTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract DispatchSecurityTest is KernelHookFixture {
    using CallbackLibrary for CallbackType;

    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        key = _poolKey();
        _createPool(key);
        _addLiquidity(key);
    }

    function test_dispatch_revertsWhenOptionalCallbackCannotBeForwarded() public {
        _extension(key, SWAP_CALLBACKS, true, false, 1_000_000);
        vm.expectRevert(
            _hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector))
        );
        _limitedSwap(500_000);
    }

    function test_dispatch_revertsInOptionalAfterOnlyGasWindow() public {
        CodexDispatchRecorder extension = new CodexDispatchRecorder();
        extension.setGasToBurn(400_000);
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, true, false, 500_000));
        vm.expectRevert(
            _hookRevert(IHooks.afterSwap.selector, abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector))
        );
        _limitedSwap(1_200_000);
    }

    function test_dispatch_revertsWhenOptionalInvocationReserveIsShort() public {
        _extension(key, SWAP_CALLBACKS, true, false, 500_000);
        // Both encodings of hookData consume the invocation reserve before onCallback is called.
        vm.expectRevert(
            _hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector))
        );
        swapRouter.swap(
            key, _exactInputParameters(true, 1e14), PoolSwapTest.TestSettings(false, false), new bytes(350_000)
        );
    }

    function test_dispatch_revertsWhenRequiredInvocationReserveIsShort() public {
        _extension(key, SWAP_CALLBACKS, false, false, 500_000);
        vm.expectRevert(
            _hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector))
        );
        swapRouter.swap(
            key, _exactInputParameters(true, 1e14), PoolSwapTest.TestSettings(false, false), new bytes(350_000)
        );
    }

    function test_dispatch_optionalPoolBudgetShortfallStillSkips() public {
        MockExtension extension = _extension(key, SWAP_CALLBACKS, true, false, 3_600_000);
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            key.toId(),
            address(extension),
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector)
        );
        _swapExactInput(key, true, 1e14);
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
    }

    function test_dispatch_nestedOptionalPoolBudgetShortfallStillSkips() public {
        PoolKey memory target = key;
        target.tickSpacing = 10;
        _createPool(target);
        _addLiquidity(target);
        MockExtension child = _extension(target, SWAP_CALLBACKS, true, false, 3_600_000);
        MockExtension origin = _extension(key, CallbackType.AfterSwap.mask(), true, true, 1_500_000);
        MockERC20(Currency.unwrap(currency0)).mint(address(origin), 1000);
        origin.deposit(key.toId(), currency0, 1000);
        origin.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction(target, Operation.Swap, abi.encode(_exactInputParameters(true, 100)), "")
        );
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            target.toId(),
            address(child),
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector)
        );
        _swapExactInput(key, true, 1e14);
        assertEq(origin.callCount(CallbackType.AfterSwap), 1);
        assertEq(child.callCount(CallbackType.BeforeSwap), 0);
        assertEq(child.callCount(CallbackType.AfterSwap), 0);
    }

    function test_dispatch_nestedOptionalGasShortfallSkips() public {
        PoolKey memory target = key;
        target.tickSpacing = 10;
        _createPool(target);
        _addLiquidity(target);
        MockExtension child = _extension(target, SWAP_CALLBACKS, true, false, 1_000_000);
        MockExtension origin = _extension(key, CallbackType.AfterSwap.mask(), true, true, 1_000_000);
        MockERC20(Currency.unwrap(currency0)).mint(address(origin), 1000);
        origin.deposit(key.toId(), currency0, 1000);
        origin.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction(target, Operation.Swap, abi.encode(_exactInputParameters(true, 100)), "")
        );
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            target.toId(),
            address(child),
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector)
        );
        _swapExactInput(key, true, 1e14);
        assertEq(origin.callCount(CallbackType.AfterSwap), 1);
        assertEq(origin.lastRouteResults().length, 1);
        assertEq(origin.lastRouteResults()[0].amount0(), -100);
        assertEq(child.callCount(CallbackType.BeforeSwap), 0);
        assertEq(child.callCount(CallbackType.AfterSwap), 0);
    }

    function testFuzz_dispatch_parentLimitCannotFitNestedOptionalCallback(bool optionalParent) public {
        PoolKey memory target = key;
        target.tickSpacing = 10;
        _createPool(target);
        _addLiquidity(target);
        MockExtension child = _extension(target, CallbackType.AfterSwap.mask(), true, false, 2_500_000);
        MockExtension origin = _extension(key, CallbackType.AfterSwap.mask(), optionalParent, true, 800_000);
        MockERC20(Currency.unwrap(currency0)).mint(address(origin), 1000);
        origin.deposit(key.toId(), currency0, 1000);
        origin.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction(target, Operation.Swap, abi.encode(_exactInputParameters(true, 100)), "")
        );
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            target.toId(),
            address(child),
            CallbackType.AfterSwap,
            abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector)
        );
        _swapExactInput(key, true, 1e14);
        assertEq(origin.callCount(CallbackType.AfterSwap), 1);
        assertEq(origin.lastRouteResults().length, 1);
        assertEq(origin.lastRouteResults()[0].amount0(), -100);
        assertEq(child.callCount(CallbackType.AfterSwap), 0);
    }

    function testFuzz_dispatch_nestedRequiredGasShortfallFailsParentAttempt(bool optionalParent) public {
        PoolKey memory target = key;
        target.tickSpacing = 10;
        _createPool(target);
        _addLiquidity(target);
        MockExtension child = _extension(target, CallbackType.BeforeSwap.mask(), false, false, 1_000_000);
        MockExtension origin = _extension(key, CallbackType.AfterSwap.mask(), optionalParent, true, 1_000_000);
        origin.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction(target, Operation.Swap, abi.encode(_exactInputParameters(true, 100)), "")
        );
        bytes memory reason =
            _hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector));
        // The parent's bounded call retains the first 256 bytes of PoolManager's wrapped nested error.
        assembly ("memory-safe") {
            mstore(reason, 256)
        }
        _expectAttempt(origin, key, CallbackType.AfterSwap, optionalParent, reason);
        _swapExactInput(key, true, 1e14);
        assertEq(origin.callCount(CallbackType.AfterSwap), 0);
        assertEq(origin.lastRouteResults().length, 0);
        assertEq(child.callCount(CallbackType.BeforeSwap), 0);
    }

    function test_dispatch_nestedOptionalInvocationReserveShortfallSkipsDuringUnwind() public {
        PoolKey memory target = key;
        target.tickSpacing = 10;
        _createPool(target);
        _addLiquidity(target);
        MockExtension child = _extension(target, CallbackType.AfterRemoveLiquidity.mask(), true, false, 500_000);
        MockExtension origin = _extension(key, CallbackType.AfterSwap.mask(), true, true, 1_500_000);
        MockERC20(Currency.unwrap(currency0)).mint(address(origin), 1000);
        MockERC20(Currency.unwrap(currency1)).mint(address(origin), 1000);
        origin.deposit(key.toId(), currency0, 1000);
        origin.deposit(key.toId(), currency1, 1000);
        origin.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction(target, Operation.ModifyLiquidity, abi.encode(_liquidityParameters(100)), "")
        );
        _swapExactInput(key, true, 1e14);
        hook.deactivateExtension(key, origin);
        RouteAction[] memory actions = new RouteAction[](1);
        // The large hookData exhausts the child's invocation reserve after admission. The synthetic exit frame
        // remains its parent, even though operationDepth excludes that frame for the pool's depth limit.
        actions[0] =
            RouteAction(target, Operation.ModifyLiquidity, abi.encode(_liquidityParameters(-100)), new bytes(350_000));
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            target.toId(),
            address(child),
            CallbackType.AfterRemoveLiquidity,
            abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector)
        );
        assertEq(origin.unwindPositions(key, actions).length, 1);
        assertEq(child.callCount(CallbackType.AfterRemoveLiquidity), 0);
        assertEq(hook.ROUTE_EXECUTOR().openPositionCount(key.toId(), address(origin)), 0);
    }

    function testFuzz_dispatch_exactOutputRejectsFullFeeOverride(bool optional) public {
        PoolKey memory dynamicKey = key;
        dynamicKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _createPool(dynamicKey);
        _addLiquidity(dynamicKey);
        MockExtension extension = _extension(dynamicKey, SWAP_CALLBACKS, optional, false, 500_000);
        extension.setBehavior(
            CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | 1_000_000, false, 0)
        );
        _expectAttempt(
            extension,
            dynamicKey,
            CallbackType.BeforeSwap,
            optional,
            abi.encodeWithSelector(IKernelHook.InvalidFeeOverride.selector)
        );
        swapRouter.swap(
            dynamicKey, SwapParams(true, 1e14, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
    }

    function testFuzz_dispatch_rechecksFullFeeAfterLaterSpecifiedDelta(bool optional) public {
        PoolKey memory dynamicKey = key;
        dynamicKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _createPool(dynamicKey);
        _addLiquidity(dynamicKey);
        MockExtension first = _extension(dynamicKey, CallbackType.BeforeSwap.mask(), false, false, 500_000);
        hook.deactivateExtension(dynamicKey, first);
        MockExtension second = _extension(dynamicKey, CallbackType.BeforeSwap.mask(), optional, false, 500_000);
        hook.activateExtension(dynamicKey, first);
        MockERC20(Currency.unwrap(currency1)).mint(address(first), 100);
        first.deposit(dynamicKey.toId(), currency1, 100);
        first.setBehavior(
            CallbackType.BeforeSwap,
            MockExtension.Behavior(0, -100, LPFeeLibrary.OVERRIDE_FEE_FLAG | 1_000_000, false, 0)
        );
        second.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(0, 1, 0, false, 0));
        _expectAttempt(
            second,
            dynamicKey,
            CallbackType.BeforeSwap,
            optional,
            abi.encodeWithSelector(IKernelHook.InvalidFeeOverride.selector)
        );
        swapRouter.swap(dynamicKey, SwapParams(true, 100, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        assertEq(second.callCount(CallbackType.BeforeSwap), 0);
        assertEq(first.callCount(CallbackType.BeforeSwap), optional ? 1 : 0);
    }

    function test_dispatch_optionalExtensionGasErrorStillSkips() public {
        MockExtension extension = _extension(key, SWAP_CALLBACKS, true, false, 500_000);
        extension.setExternalCall(
            CallbackType.BeforeSwap, address(this), abi.encodeCall(this.revertCallbackGasBudget, ())
        );
        _expectAttempt(
            extension,
            key,
            CallbackType.BeforeSwap,
            true,
            abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector)
        );
        _swapExactInput(key, true, 1e14);
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
    }

    function revertCallbackGasBudget() external pure {
        revert IKernelHook.GasBudgetExceeded();
    }

    function test_dispatch_fullFeeOverrideAcceptsZeroRemainingExactOutput() public {
        PoolKey memory dynamicKey = key;
        dynamicKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _createPool(dynamicKey);
        _addLiquidity(dynamicKey);
        MockExtension extension = _extension(dynamicKey, SWAP_CALLBACKS, false, false, 500_000);
        MockERC20(Currency.unwrap(currency1)).mint(address(extension), 100);
        extension.deposit(dynamicKey.toId(), currency1, 100);
        extension.setBehavior(
            CallbackType.BeforeSwap,
            MockExtension.Behavior(0, -100, LPFeeLibrary.OVERRIDE_FEE_FLAG | 1_000_000, false, 0)
        );
        swapRouter.swap(dynamicKey, SwapParams(true, 100, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        assertEq(extension.callCount(CallbackType.BeforeSwap), 1);
    }

    function testFuzz_dispatch_afterSwapRejectsCallerDeltaOverflow(bool optional, bool zeroForOne) public {
        MockExtension extension = _extension(key, CallbackType.AfterSwap.mask(), optional, false, 500_000);
        // Exact output makes the unspecified input delta negative; charging int128.max underflows the caller.
        extension.setBehavior(
            CallbackType.AfterSwap,
            MockExtension.Behavior(
                zeroForOne ? type(int128).max : int128(0), zeroForOne ? int128(0) : type(int128).max, 0, false, 0
            )
        );
        _expectAttempt(
            extension, key, CallbackType.AfterSwap, optional, abi.encodeWithSelector(IKernelHook.DeltaOverflow.selector)
        );
        swapRouter.swap(
            key,
            SwapParams(zeroForOne, 1e14, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
        assertEq(hook.VAULT().fundedCurrencyCount(key.toId(), address(extension)), 0);
    }

    function testFuzz_dispatch_afterSwapIncludesBeforeUnspecifiedDelta(bool optional) public {
        MockExtension extension = _extension(key, SWAP_CALLBACKS, optional, false, 500_000);
        extension.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(type(int128).max - 1e16, 0, 0, false, 0));
        extension.setBehavior(CallbackType.AfterSwap, MockExtension.Behavior(1e16 - 1, 0, 0, false, 0));
        _expectAttempt(
            extension, key, CallbackType.AfterSwap, optional, abi.encodeWithSelector(IKernelHook.DeltaOverflow.selector)
        );
        swapRouter.swap(key, SwapParams(true, 1e14, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        assertEq(extension.callCount(CallbackType.BeforeSwap), optional ? 1 : 0);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
    }

    function testFuzz_dispatch_afterLiquidityRejectsCallerDeltaOverflow(bool optional, bool removal) public {
        CallbackType callback = removal ? CallbackType.AfterRemoveLiquidity : CallbackType.AfterAddLiquidity;
        MockExtension extension = _extension(key, callback.mask(), optional, false, 500_000);
        int128 charge = removal ? -type(int128).max : type(int128).max;
        if (removal) {
            MockERC20(Currency.unwrap(currency0)).mint(address(extension), uint256(uint128(type(int128).max)));
            extension.deposit(key.toId(), currency0, uint256(uint128(type(int128).max)));
        }
        extension.setBehavior(callback, MockExtension.Behavior(charge, 0, 0, false, 0));
        _expectAttempt(extension, key, callback, optional, abi.encodeWithSelector(IKernelHook.DeltaOverflow.selector));
        if (removal) _removeLiquidity(key);
        else _addLiquidity(key);
        assertEq(extension.callCount(callback), 0);
    }

    function testFuzz_dispatch_rejectsDirectExtensionDebt(bool optional) public {
        MockExtension extension = _extension(key, CallbackType.BeforeSwap.mask(), optional, false, 500_000);
        extension.setExternalCall(
            CallbackType.BeforeSwap,
            address(manager),
            abi.encodeWithSignature("mint(address,uint256,uint256)", address(extension), currency0.toId(), 100)
        );
        _expectAttempt(
            extension, key, CallbackType.BeforeSwap, optional, abi.encodeWithSignature("UnexpectedAccounting()")
        );
        _swapExactInput(key, true, 1e14);
        assertEq(manager.balanceOf(address(extension), currency0.toId()), 0);
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
    }

    function testFuzz_dispatch_rejectsUnexpectedHookCurrencyDelta(bool optional) public {
        MockExtension extension = _extension(key, CallbackType.BeforeSwap.mask(), optional, false, 500_000);
        // settleFor credits KernelHook without creating an extension debt. The currency-delta check catches it.
        // A pending sync and transfer lets settleFor produce an unexpected credit.
        extension.setExternalCall(CallbackType.BeforeSwap, address(this), abi.encodeCall(this.creditHook, ()));
        _expectAttempt(
            extension, key, CallbackType.BeforeSwap, optional, abi.encodeWithSignature("UnexpectedAccounting()")
        );
        _swapExactInput(key, true, 1e14);
    }

    function creditHook() external {
        manager.sync(currency0);
        MockERC20(Currency.unwrap(currency0)).transfer(address(manager), 100);
        manager.settleFor(address(hook));
    }

    function _limitedSwap(uint256 gasLimit) internal {
        swapRouter.swap{gas: gasLimit}(
            key, _exactInputParameters(true, 1e14), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function _extension(PoolKey memory pool, uint16 mask, bool optional, bool nesting, uint32 gasLimit)
        internal
        returns (MockExtension extension)
    {
        extension = new MockExtension(address(hook));
        _installAndActivate(pool, address(extension), _settings(mask, optional, nesting, gasLimit));
    }

    function _expectAttempt(
        MockExtension extension,
        PoolKey memory pool,
        CallbackType callback,
        bool optional,
        bytes memory reason
    ) internal {
        if (optional) {
            vm.expectEmit(true, true, true, true, address(hook));
            emit IKernelHook.ExtensionSkipped(pool.toId(), address(extension), callback, reason);
        } else {
            bytes4 selector = callback == CallbackType.BeforeSwap
                ? IHooks.beforeSwap.selector
                : callback == CallbackType.AfterSwap
                    ? IHooks.afterSwap.selector
                    : callback == CallbackType.AfterAddLiquidity
                        ? IHooks.afterAddLiquidity.selector
                        : IHooks.afterRemoveLiquidity.selector;
            vm.expectRevert(
                _hookRevert(
                    selector,
                    abi.encodeWithSelector(IKernelHook.ExtensionFailed.selector, address(extension), callback, reason)
                )
            );
        }
    }
}

contract ConfigurationSecurityTest is KernelHookFixture {
    using CallbackLibrary for CallbackType;

    PoolKey internal key;
    CodexLifecycleExtension internal extension;

    function setUp() public override {
        super.setUp();
        key = _poolKey();
        _createPool(key);
        extension = new CodexLifecycleExtension(address(hook));
        _admit(address(extension));
    }

    function test_installExtension_revertsWhenLifecycleGasCannotBeForwarded() public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.lifecycleGasLimit = 1_000_000;
        vm.expectRevert(IKernelHook.GasBudgetExceeded.selector);
        hook.installExtension{gas: 600_000}(key, extension, settings);
    }

    function test_configureExtension_revertsWhenLifecycleGasCannotBeForwarded() public {
        hook.installExtension(key, extension, _settings(SWAP_CALLBACKS, false, false));
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.lifecycleGasLimit = 1_000_000;
        vm.expectRevert(IKernelHook.GasBudgetExceeded.selector);
        hook.configureExtension{gas: 500_000}(key, extension, settings);
    }

    function test_activateExtension_revertsWhenLifecycleGasCannotBeForwarded() public {
        _installLargeLifecycle();
        vm.expectRevert(IKernelHook.GasBudgetExceeded.selector);
        hook.activateExtension{gas: 500_000}(key, extension);
    }

    function test_removeExtension_revertsWhenCanUninstallGasCannotBeForwarded() public {
        _installLargeLifecycle();
        vm.expectRevert(IKernelHook.GasBudgetExceeded.selector);
        hook.removeExtension{gas: 500_000}(key, extension);
    }

    function test_removeExtension_revertsWhenOnUninstallGasCannotBeForwarded() public {
        _installLargeLifecycle();
        extension.setGasToBurn(IKernelHookExtension.canUninstall.selector, 600_000);
        vm.expectRevert(IKernelHook.GasBudgetExceeded.selector);
        hook.removeExtension{gas: 1_400_000}(key, extension);
    }

    function test_removeExtension_rechecksCanUninstallGasAfterOnUninstall() public {
        _installLargeLifecycle();
        extension.setGasToBurn(IKernelHookExtension.onUninstall.selector, 600_000);
        vm.expectRevert(IKernelHook.GasBudgetExceeded.selector);
        hook.removeExtension{gas: 1_400_000}(key, extension);
    }

    function testFuzz_configureExtension_gatesSubscribedGasLimitChanges(bool increase) public {
        hook.installExtension(key, extension, _settings(SWAP_CALLBACKS, true, false));
        _activeSubscriber();
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, true, false);
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = increase ? 600_000 : 400_000;
        vm.expectRevert(IKernelHook.SubscribersActive.selector);
        hook.configureExtension(key, extension, settings);
    }

    function testFuzz_configureExtension_gatesNestingChanges(bool nesting) public {
        hook.installExtension(key, extension, _settings(SWAP_CALLBACKS, true, !nesting));
        _activeSubscriber();
        vm.expectRevert(IKernelHook.SubscribersActive.selector);
        hook.configureExtension(key, extension, _settings(SWAP_CALLBACKS, true, nesting));
    }

    function test_configureExtension_allowsUnsubscribedGasAndLifecycleAndConfigurationChanges() public {
        hook.installExtension(key, extension, _settings(SWAP_CALLBACKS, false, false));
        _activeSubscriber();
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, true, false);
        settings.callbackGasLimits[uint8(CallbackType.AfterDonate)] = 600_000;
        settings.lifecycleGasLimit = 300_000;
        settings.configuration = hex"1234";
        hook.configureExtension(key, extension, settings);
    }

    function _installLargeLifecycle() internal {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.lifecycleGasLimit = 1_000_000;
        hook.installExtension(key, extension, settings);
    }

    function _activeSubscriber() internal {
        CodexLifecycleExtension second = new CodexLifecycleExtension(address(hook));
        _admit(address(second));
        hook.installExtension(key, second, _settings(SWAP_CALLBACKS, false, false));
        hook.activateExtension(key, second);
    }
}

contract DynamicFeeSecurityTest is KernelHookFixture {
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        key = _poolKey();
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _createPool(key);
        _addLiquidity(key);
    }

    function test_setDynamicLPFee_appliesWithoutOverride() public {
        uint256 snapshot = vm.snapshotState();
        BalanceDelta zeroFee = _swapExactInput(key, true, 1e14);
        vm.revertToState(snapshot);
        vm.expectEmit(true, false, false, true, address(hook));
        emit IKernelHook.DynamicLPFeeChanged(key.toId(), FEE);
        hook.setDynamicLPFee(key, FEE);
        BalanceDelta withFee = _swapExactInput(key, true, 1e14);
        assertEq(withFee.amount0(), zeroFee.amount0());
        assertLt(withFee.amount1(), zeroFee.amount1());
        PoolKey memory staticKey = _poolKey();
        _createPool(staticKey);
        _addLiquidity(staticKey);
        assertEq(BalanceDelta.unwrap(withFee), BalanceDelta.unwrap(_swapExactInput(staticKey, true, 1e14)));
    }

    function test_setDynamicLPFee_appliesWhenOptionalOverrideIsSkipped() public {
        hook.setDynamicLPFee(key, FEE);
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, true, false));
        extension.setBehavior(
            CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | 100, true, 0)
        );
        BalanceDelta withFee = _swapExactInput(key, true, 1e14);
        PoolKey memory staticKey = _poolKey();
        _createPool(staticKey);
        _addLiquidity(staticKey);
        assertEq(BalanceDelta.unwrap(withFee), BalanceDelta.unwrap(_swapExactInput(staticKey, true, 1e14)));
    }

    function test_setDynamicLPFee_rejectsNonAdmin() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.setDynamicLPFee(key, FEE);
    }

    function test_setDynamicLPFee_rejectsConfigurer() public {
        hook.grantPoolRole(key, hook.CONFIGURER_ROLE(), address(0xBAD));
        vm.prank(address(0xBAD));
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.setDynamicLPFee(key, FEE);
    }

    function test_setDynamicLPFee_rejectsStaticPool() public {
        PoolKey memory staticKey = _poolKey();
        _createPool(staticKey);
        vm.expectRevert(IKernelHook.InvalidPool.selector);
        hook.setDynamicLPFee(staticKey, FEE);
    }

    function test_setDynamicLPFee_rejectsUninitializedPool() public {
        PoolKey memory preparedKey = key;
        preparedKey.tickSpacing = 10;
        hook.preparePool(preparedKey);
        vm.expectRevert(IKernelHook.PoolNotInitialized.selector);
        hook.setDynamicLPFee(preparedKey, FEE);
    }

    function testFuzz_setDynamicLPFee_validatesFee(uint24 fee) public {
        fee = uint24(bound(fee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));
        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, fee));
        hook.setDynamicLPFee(key, fee);
    }

    function test_setDynamicLPFee_rejectsManagementDuringCallback() public {
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, false));
        hook.grantPoolRole(key, hook.POOL_ADMIN_ROLE(), address(extension));
        extension.setExternalCall(
            CallbackType.BeforeSwap, address(hook), abi.encodeCall(IKernelHook.setDynamicLPFee, (key, FEE))
        );
        vm.expectRevert(
            _hookRevert(
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(
                    IKernelHook.ExtensionFailed.selector,
                    address(extension),
                    CallbackType.BeforeSwap,
                    abi.encodeWithSelector(IKernelHook.ExecutionInProgress.selector)
                )
            )
        );
        _swapExactInput(key, true, 1e14);
    }
}
