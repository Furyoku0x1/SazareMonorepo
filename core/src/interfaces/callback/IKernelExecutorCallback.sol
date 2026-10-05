// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RouteAction} from "../../types/KernelHookTypes.sol";

/// @notice The handshake between the route executor and KernelHook around each nested route action.
interface IKernelExecutorCallback {
    /// @notice Checks that a nested action is allowed, and records a ticket for its before callback.
    /// @dev Only the route executor can call this, immediately before it calls the PoolManager.
    /// @param action The action that the executor will run next
    function authorizeAction(RouteAction calldata action) external;

    /// @notice Removes the ticket of the action that just completed.
    /// @dev Only the route executor can call this, immediately after the PoolManager call returns.
    function finishAction() external;
}
