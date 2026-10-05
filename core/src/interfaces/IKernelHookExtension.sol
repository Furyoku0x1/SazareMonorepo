// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookExtension} from "./IHookExtension.sol";
import {CallbackResult, ExecutionContext, ExtensionSettings} from "../types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice The interface that an executable KernelHook extension implements.
/// @dev Implementations must check that the caller is KernelHook, and must keep their state separate per pool.
/// If an extension's callbacks are optional, the extension must stay correct when any one callback is skipped.
/// A rollback of an after callback does not undo a before callback that already succeeded.
interface IKernelHookExtension is IHookExtension {
    /// @notice Called when a pool installs the extension.
    /// @param key The pool key
    /// @param settings The installation settings
    /// @return The selector of this function
    function onInstall(PoolKey calldata key, ExtensionSettings calldata settings) external returns (bytes4);

    /// @notice Called when a pool changes the settings of an inactive installation.
    /// @dev The extension must reject settings that would harm the rights of its existing users.
    /// @param key The pool key
    /// @param previous The current settings
    /// @param settings The new settings
    /// @return The selector of this function
    function onConfigure(PoolKey calldata key, ExtensionSettings calldata previous, ExtensionSettings calldata settings)
        external
        returns (bytes4);

    /// @notice Returns true if the installation can be activated with these settings.
    /// @param key The pool key
    /// @param settings The installation settings
    function canActivate(PoolKey calldata key, ExtensionSettings calldata settings) external view returns (bool);

    /// @notice Returns true if the extension has no obligations left in the pool and can be removed.
    /// @param key The pool key
    function canUninstall(PoolKey calldata key) external view returns (bool);

    /// @notice Called when a pool removes the extension.
    /// @param key The pool key
    /// @param configuration The configuration of the installation
    /// @return The selector of this function
    function onUninstall(PoolKey calldata key, bytes calldata configuration) external returns (bytes4);

    /// @notice Called for each subscribed callback while the installation is active.
    /// @dev callbackData holds the arguments of the matching Uniswap v4 callback, without sender and key:
    /// - initialize: (sqrtPriceX96) / (sqrtPriceX96, tick)
    /// - swap: (params, hookData) / (params, delta, hookData)
    /// - liquidity: (params, hookData) / (params, delta, feesAccrued, hookData)
    /// - donate: (amount0, amount1, hookData)
    /// @param context The operation that calls the extension
    /// @param key The pool key
    /// @param configuration The configuration of the installation
    /// @param callbackData The callback arguments, ABI-encoded
    /// @return The deltas and the optional fee override of the extension
    function onCallback(
        ExecutionContext calldata context,
        PoolKey calldata key,
        bytes calldata configuration,
        bytes calldata callbackData
    ) external returns (CallbackResult memory);
}
