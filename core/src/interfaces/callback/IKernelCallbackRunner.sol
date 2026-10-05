// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CallbackResult} from "../../types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice The self-call that KernelHook uses to run one extension callback in its own rollback scope.
interface IKernelCallbackRunner {
    /// @notice Calls one extension, validates its result, and settles its deltas against its vault balance.
    /// @dev Only KernelHook itself can call this. If an optional extension fails, this call reverts, so the
    /// extension call, the validation and the settlement all roll back together before KernelHook skips it.
    /// @param extension The extension to call
    /// @param key The pool key of the current operation
    /// @param data The callback arguments (see IKernelHookExtension.onCallback)
    /// @param aggregate The sum of the results of the extensions that ran earlier in this callback
    /// @return The new sum, including this extension's result
    function invokeExtension(
        address extension,
        PoolKey calldata key,
        bytes calldata data,
        CallbackResult calldata aggregate
    ) external returns (CallbackResult memory);
}
