// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "./utils/KernelHookFixture.sol";
import {MockExtension} from "./mocks/MockExtension.sol";
import {IKernelHook} from "../src/interfaces/IKernelHook.sol";
import {CallbackType, ExecutionContext, PoolStatus} from "../src/types/KernelHookTypes.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Smoke tests: the fixture deploys a working KernelHook, and one swap runs through its extensions.
/// The detailed unit tests for each area are in their own files.
contract KernelHookTest is KernelHookFixture {
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        poolKey = _poolKey();
        poolId = poolKey.toId();
    }

    function test_constructor_connectsVaultAndRouteExecutor() public view {
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(address(hook.CATALOG()), address(catalog));
        assertEq(hook.VAULT().KERNEL_HOOK(), address(hook));
        assertEq(address(hook.ROUTE_EXECUTOR().KERNEL_HOOK()), address(hook));
        assertEq(hook.VAULT().routeExecutor(), address(hook.ROUTE_EXECUTOR()));
        assertEq(address(hook.ROUTE_EXECUTOR().VAULT()), address(hook.VAULT()));
        assertEq(address(hook.VAULT().POOL_MANAGER()), address(manager));
        assertEq(address(hook.ROUTE_EXECUTOR().POOL_MANAGER()), address(manager));
    }

    /// @dev deployCodeTo hides the revert data, so the test runs the constructor itself at a valid hook address.
    function test_constructor_revertsWhenCatalogHasNoCode() public {
        address target = address(uint160(0xBEEF) << 136 | uint160(Hooks.ALL_HOOK_MASK));
        bytes memory creationCode = vm.getCode("KernelHook.sol:KernelHook");
        vm.etch(target, abi.encodePacked(creationCode, abi.encode(manager, address(0xCA7A106))));
        (bool success, bytes memory reason) = target.call("");
        assertFalse(success);
        assertEq(reason, abi.encodeWithSelector(IKernelHook.InvalidConfiguration.selector));
    }

    /// @dev Only the PoolManager can call a hook callback. An after callback with no open operation is rejected.
    function test_afterSwap_revertsWithoutOpenOperation() public {
        _createPool(poolKey);
        vm.prank(address(manager));
        vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
        hook.afterSwap(address(swapRouter), poolKey, _exactInputParameters(true, 1e14), BalanceDelta.wrap(0), "");
    }

    /// @dev The PoolManager never calls beforeSwap for an uninitialized pool; KernelHook checks it again.
    function test_beforeSwap_revertsWhenPoolIsNotInitialized() public {
        hook.preparePool(poolKey);
        vm.prank(address(manager));
        vm.expectRevert(IKernelHook.PoolNotInitialized.selector);
        hook.beforeSwap(address(swapRouter), poolKey, _exactInputParameters(true, 1e14), "");
    }

    function test_createPool_makesInitializerFirstAdmin() public {
        _createPool(poolKey);
        (PoolStatus status, address initializer,,) = hook.poolState(poolId);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));
        assertEq(initializer, address(this));
        assertTrue(hook.hasPoolRole(poolId, hook.POOL_ADMIN_ROLE(), address(this)));
        assertEq(hook.currentContext().depth, 0);
    }

    function test_swap_withoutExtensions() public {
        _createPool(poolKey);
        _addLiquidity(poolKey);
        _swapExactInput(poolKey, true, 1e14);
        assertEq(hook.currentContext().depth, 0);
    }

    function test_swap_runsRequiredExtensionWithContext() public {
        _createPool(poolKey);
        _addLiquidity(poolKey);
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(poolKey, address(extension), _settings(SWAP_CALLBACKS, false, false));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(extension.callCount(CallbackType.BeforeSwap), 1);
        assertEq(extension.callCount(CallbackType.AfterSwap), 1);
        ExecutionContext memory context = extension.lastContext();
        assertEq(uint8(context.callback), uint8(CallbackType.AfterSwap));
        assertEq(PoolId.unwrap(context.poolId), PoolId.unwrap(poolId));
        assertEq(PoolId.unwrap(context.rootPoolId), PoolId.unwrap(poolId));
        assertEq(context.sender, address(swapRouter));
        assertEq(context.extension, address(extension));
        assertEq(context.depth, 1);
    }

    function test_swap_skipsFailedOptionalExtension() public {
        _createPool(poolKey);
        _addLiquidity(poolKey);
        MockExtension extension = new MockExtension(address(hook));
        extension.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, 0, true, 0));
        _installAndActivate(poolKey, address(extension), _settings(SWAP_CALLBACKS, true, false));

        // The event names the extension and the callback, so its reason is the extension's revert data.
        bytes memory reason = abi.encodeWithSelector(MockExtension.MockRevert.selector, CallbackType.BeforeSwap);
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(poolId, address(extension), CallbackType.BeforeSwap, reason);
        _swapExactInput(poolKey, true, 1e14);

        // The skip lasts for the rest of the swap, so the after callback does not run either.
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
    }

    function test_swap_revertsWhenRequiredExtensionFails() public {
        _createPool(poolKey);
        _addLiquidity(poolKey);
        MockExtension extension = new MockExtension(address(hook));
        extension.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, 0, true, 0));
        _installAndActivate(poolKey, address(extension), _settings(SWAP_CALLBACKS, false, false));

        // The dispatch loop wraps the extension's revert data once, with the extension and the callback.
        bytes memory extensionError = abi.encodeWithSelector(MockExtension.MockRevert.selector, CallbackType.BeforeSwap);
        bytes memory failure = abi.encodeWithSelector(
            IKernelHook.ExtensionFailed.selector, address(extension), CallbackType.BeforeSwap, extensionError
        );
        vm.expectRevert(_hookRevert(IHooks.beforeSwap.selector, failure));
        _swapExactInput(poolKey, true, 1e14);
    }

    function test_swap_beforeSwapFeeIsCreditedToVault() public {
        _createPool(poolKey);
        _addLiquidity(poolKey);
        MockExtension extension = new MockExtension(address(hook));
        // Exact input zeroForOne: currency0 is the specified currency, so delta0 charges the swapper a fee.
        extension.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(1e10, 0, 0, false, 0));
        _installAndActivate(poolKey, address(extension), _settings(SWAP_CALLBACKS, false, false));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 1e10);
        assertEq(hook.VAULT().fundedCurrencyCount(poolId, address(extension)), 1);
    }
}
