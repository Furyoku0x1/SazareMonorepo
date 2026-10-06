// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {IKernelCallbackRunner} from "../../src/interfaces/callback/IKernelCallbackRunner.sol";
import {CallbackResult, CallbackType} from "../../src/types/KernelHookTypes.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice multicall: management changes on a live pool in one transaction, with no gap in which swaps run
/// without the pool's extensions.
contract MulticallTest is KernelHookFixture {
    PoolKey internal poolKey;
    PoolId internal poolId;
    MockExtension internal live;
    MockExtension internal added;

    function setUp() public override {
        super.setUp();
        poolKey = _poolKey();
        poolId = poolKey.toId();
        _createPool(poolKey);
        _addLiquidity(poolKey);
        live = new MockExtension(address(hook));
        _installAndActivate(poolKey, address(live), _settings(SWAP_CALLBACKS, false, false));
        added = new MockExtension(address(hook));
        _admit(address(added));
    }

    function test_installExtension_revertsWhileSubscribersAreActive() public {
        vm.expectRevert(IKernelHook.SubscribersActive.selector);
        hook.installExtension(poolKey, IHookExtension(address(added)), _settings(SWAP_CALLBACKS, false, false));
    }

    function test_multicall_installsOnLivePoolInOneTransaction() public {
        hook.multicall(_installBatch());

        assertTrue(_isActive(live));
        assertTrue(_isActive(added));
        _swapExactInput(poolKey, true, 1e14);
        assertEq(live.callCount(CallbackType.BeforeSwap), 1);
        assertEq(added.callCount(CallbackType.BeforeSwap), 1);
    }

    /// @dev The new extension rejects activation, so the whole batch reverts and the live extension stays active.
    function test_multicall_revertsAllCallsWhenOneFails() public {
        added.setLifecycle(false, true, false);

        vm.expectRevert(IKernelHook.ActivationRejected.selector);
        hook.multicall(_installBatch());

        assertTrue(_isActive(live));
        assertFalse(hook.isInstalled(poolId, address(added)));
    }

    function test_multicall_keepsTheCallerOfEachCall() public {
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.multicall(_installBatch());
    }

    /// @dev Each call is a delegatecall, so msg.sender is the batch caller, not KernelHook. The live extension makes
    /// the attempt from inside its own callback, where its frame is open, so only the caller check can reject it.
    function test_multicall_cannotReachInvokeExtension() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            IKernelCallbackRunner.invokeExtension, (address(live), poolKey, "", CallbackResult(0, 0, 0))
        );
        live.setExternalCall(CallbackType.BeforeSwap, address(hook), abi.encodeCall(IKernelHook.multicall, (calls)));
        bytes memory failure = abi.encodeWithSelector(
            IKernelHook.ExtensionFailed.selector,
            address(live),
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(IKernelHook.Unauthorized.selector)
        );
        vm.expectRevert(_hookRevert(IHooks.beforeSwap.selector, failure));
        _swapExactInput(poolKey, true, 1e14);
    }

    /// @dev Deactivate the live subscriber, install the new extension, and activate both again.
    function _installBatch() private view returns (bytes[] memory calls) {
        calls = new bytes[](4);
        calls[0] = abi.encodeCall(IKernelHook.deactivateExtension, (poolKey, IHookExtension(address(live))));
        calls[1] = abi.encodeCall(
            IKernelHook.installExtension,
            (poolKey, IHookExtension(address(added)), _settings(SWAP_CALLBACKS, false, false))
        );
        calls[2] = abi.encodeCall(IKernelHook.activateExtension, (poolKey, IHookExtension(address(live))));
        calls[3] = abi.encodeCall(IKernelHook.activateExtension, (poolKey, IHookExtension(address(added))));
    }

    function _isActive(MockExtension extension) private view returns (bool active) {
        (active,,) = hook.extensionConfiguration(poolId, address(extension));
    }
}
