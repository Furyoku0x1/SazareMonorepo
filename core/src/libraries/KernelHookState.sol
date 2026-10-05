// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookCatalog} from "../interfaces/IHookCatalog.sol";
import {IKernelHook} from "../interfaces/IKernelHook.sol";
import {CALLBACK_COUNT, CallbackType, ExtensionSettings, PoolStatus} from "../types/KernelHookTypes.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice The persistent per-pool state of KernelHook, and the guarded lookups that all its parts share.
library KernelHookState {
    using LPFeeLibrary for uint24;

    /// @notice The lifecycle, limits and membership of one pool.
    struct PoolState {
        PoolStatus status;
        address initializer;
        uint8 maxOperationDepth;
        uint32[CALLBACK_COUNT] callbackGasBudgets;
        uint256 adminCount;
        /// @dev In installation order. The position of an extension is its extensionIndex.
        address[] extensions;
    }

    /// @notice One extension installed in one pool.
    struct Installation {
        bool installed;
        bool active;
        /// @dev The position in PoolState.extensions, and the bit of the extension in OperationFrame.skippedExtensions.
        uint8 extensionIndex;
        /// @dev A callback mask of the initialization callbacks that this installation has completed.
        uint16 completedInitializationCallbacks;
        /// @dev A copy of the catalog entry at installation time.
        IHookCatalog.Entry entry;
        ExtensionSettings settings;
    }

    struct State {
        mapping(PoolId => PoolKey) poolKeys;
        mapping(PoolId => PoolState) pools;
        mapping(PoolId => mapping(address => Installation)) installations;
        /// @dev The call order of each callback: the subscribed extensions, active or not.
        mapping(PoolId => mapping(CallbackType => address[])) callbackOrders;
        mapping(PoolId => mapping(bytes32 => mapping(address => bool))) roles;
    }

    /// @notice Reverts unless key is a valid pool key for this hook.
    /// @dev Applies the key rules of PoolManager.initialize (currency order, tick spacing, LP fee) plus
    /// key.hooks == this, so that no state is written for a key that this hook could never serve.
    function validatePoolKey(PoolKey calldata key) internal view {
        if (address(key.hooks) != address(this)) revert IKernelHook.InvalidPool();
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)) revert IKernelHook.InvalidPool();
        if (key.tickSpacing < TickMath.MIN_TICK_SPACING) revert IKernelHook.InvalidPool();
        if (key.tickSpacing > TickMath.MAX_TICK_SPACING) revert IKernelHook.InvalidPool();
        // Reverts if a static fee is above the maximum LP fee.
        key.fee.getInitialLPFee();
    }

    /// @notice Validates key and returns its pool id. Reverts if the pool was never prepared.
    function requireKnownPool(State storage state, PoolKey calldata key) internal view returns (PoolId poolId) {
        validatePoolKey(key);
        poolId = key.toId();
        if (state.pools[poolId].status == PoolStatus.Unprepared) revert IKernelHook.PoolNotPrepared();
    }

    /// @notice Returns the installation of extension in the pool. Reverts if it is not installed.
    function requireInstalled(State storage state, PoolId poolId, address extension)
        internal
        view
        returns (Installation storage installation)
    {
        installation = state.installations[poolId][extension];
        if (!installation.installed) revert IKernelHook.ExtensionNotInstalled();
    }

    /// @notice Returns true if the pool has completed initialization.
    function isInitialized(State storage state, PoolId poolId) internal view returns (bool) {
        return state.pools[poolId].status == PoolStatus.Initialized;
    }

    /// @notice Returns the sum of the callback gas limits of the active, required (not optional) subscribers of callback.
    /// @dev KernelHook reserves this gas so that an optional extension cannot use gas that a required one needs.
    function mandatoryCallbackGas(State storage state, PoolId poolId, CallbackType callback)
        internal
        view
        returns (uint256 gasAmount)
    {
        address[] storage order = state.callbackOrders[poolId][callback];
        // order.length <= MAX_EXTENSIONS
        for (uint256 i; i < order.length; ++i) {
            Installation storage installation = state.installations[poolId][order[i]];
            if (!installation.active) continue;
            if (installation.settings.optionalCallbacks) continue;
            gasAmount += installation.settings.callbackGasLimits[uint8(callback)];
        }
    }
}
