// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHookExtension} from "../../src/interfaces/IKernelHookExtension.sol";
import {CallbackResult, CallbackType, ExecutionContext, ExtensionSettings} from "../../src/types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice The cheapest correct extension: it checks its caller and returns a fixed result. Gas benchmarks use it to
/// keep the extension's own cost small. The numbers still include the router, the PoolManager and the token transfers.
/// @dev It returns RESULT_DELTA0 and RESULT_DELTA1 only for RESULT_CALLBACK, and zero deltas for all other callbacks.
contract NoopExtension is IKernelHookExtension {
    address public immutable KERNEL_HOOK;
    CallbackType public immutable RESULT_CALLBACK;
    int128 public immutable RESULT_DELTA0;
    int128 public immutable RESULT_DELTA1;

    error NotKernelHook();

    constructor(address kernelHook, CallbackType resultCallback, int128 resultDelta0, int128 resultDelta1) {
        KERNEL_HOOK = kernelHook;
        RESULT_CALLBACK = resultCallback;
        RESULT_DELTA0 = resultDelta0;
        RESULT_DELTA1 = resultDelta1;
    }

    modifier onlyKernelHook() {
        if (msg.sender != KERNEL_HOOK) revert NotKernelHook();
        _;
    }

    function onInstall(PoolKey calldata, ExtensionSettings calldata) external view onlyKernelHook returns (bytes4) {
        return IKernelHookExtension.onInstall.selector;
    }

    function onConfigure(PoolKey calldata, ExtensionSettings calldata, ExtensionSettings calldata)
        external
        view
        onlyKernelHook
        returns (bytes4)
    {
        return IKernelHookExtension.onConfigure.selector;
    }

    function canActivate(PoolKey calldata, ExtensionSettings calldata) external pure returns (bool) {
        return true;
    }

    function canUninstall(PoolKey calldata) external pure returns (bool) {
        return true;
    }

    function onUninstall(PoolKey calldata, bytes calldata) external view onlyKernelHook returns (bytes4) {
        return IKernelHookExtension.onUninstall.selector;
    }

    function onCallback(ExecutionContext calldata context, PoolKey calldata, bytes calldata)
        external
        view
        onlyKernelHook
        returns (CallbackResult memory result)
    {
        if (context.callback != RESULT_CALLBACK) return result;
        result.delta0 = RESULT_DELTA0;
        result.delta1 = RESULT_DELTA1;
    }
}
