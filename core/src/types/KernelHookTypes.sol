// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @dev The number of CallbackType members. Sizes every per-callback array: ExtensionSettings.callbackGasLimits
/// and the callback gas budgets of a pool.
uint256 constant CALLBACK_COUNT = 10;

/// @notice The Uniswap v4 callbacks that KernelHook forwards to extensions.
/// @dev The ordinal of a member is also its bit in a callback mask and its index in each per-callback array.
/// Do not reorder or insert members.
enum CallbackType {
    BeforeInitialize,
    AfterInitialize,
    BeforeSwap,
    AfterSwap,
    BeforeAddLiquidity,
    AfterAddLiquidity,
    BeforeRemoveLiquidity,
    AfterRemoveLiquidity,
    BeforeDonate,
    AfterDonate
}

/// @notice The lifecycle of a pool that uses KernelHook.
enum PoolStatus {
    /// @dev No one has called preparePool for this pool key.
    Unprepared,
    /// @dev Reserved for its initializer, who must initialize it directly in the PoolManager.
    Prepared,
    /// @dev Between the beforeInitialize and afterInitialize callbacks.
    Initializing,
    Initialized
}

/// @notice The PoolManager call that a route action makes.
enum Operation {
    Swap,
    ModifyLiquidity,
    Donate
}

/// @notice The settings of one extension installation in one pool.
struct ExtensionSettings {
    /// @notice Bit i subscribes the extension to CallbackType(i).
    uint16 callbackMask;
    /// @notice If true, a callback that fails, reenters, or does not fit the gas budget is skipped
    /// for the rest of the operation. If false, it reverts the whole operation.
    bool optionalCallbacks;
    /// @notice If true, the extension can call executeRoute from its callbacks.
    bool allowNesting;
    /// @notice The gas limit for onInstall, onConfigure, onUninstall, canActivate and canUninstall.
    uint32 lifecycleGasLimit;
    /// @notice The gas limit of each callback, indexed by CallbackType. Only subscribed entries are used.
    /// @dev The extension's onCallback receives exactly this much gas. KernelHook's own work around the call,
    /// including the settlement of the result's deltas, uses a separate reserve that the pool's budget pays.
    uint32[CALLBACK_COUNT] callbackGasLimits;
    /// @notice Extension-defined data. KernelHook passes it back in onUninstall, and inside the settings in onInstall,
    /// onConfigure and canActivate. It does not pass it in onCallback.
    bytes configuration;
}

/// @notice What an extension can read about the operation that is calling it.
/// @dev During unwindPositions, the root is a synthetic exit frame, not a PoolManager call: its sender is the
/// extension itself, and its callback is AfterRemoveLiquidity.
struct ExecutionContext {
    /// @notice The id of the outermost operation: the PoolManager call that started this execution.
    uint64 rootOperationId;
    /// @notice The pool of the outermost operation.
    PoolId rootPoolId;
    /// @notice The pool of the current (innermost) operation.
    PoolId poolId;
    /// @notice The PoolManager caller of the current operation. For a nested route, this is the route executor.
    address sender;
    /// @notice The extension whose callback runs now, or address(0) between callbacks.
    address extension;
    /// @notice The callback that runs now.
    CallbackType callback;
    /// @notice The number of operations on the stack, including the synthetic frame of unwindPositions.
    uint8 depth;
}

/// @notice The answer of an extension to one callback.
/// @dev Deltas use currency0/currency1 order. A positive delta charges the caller and credits this
/// installation's vault balance. A negative delta spends that vault balance in favor of the caller.
struct CallbackResult {
    int128 delta0;
    int128 delta1;
    /// @notice An LP fee override with the override flag set, for beforeSwap on dynamic-fee pools only.
    /// 0 means no override.
    uint24 feeOverride;
}

/// @notice One PoolManager call in a nested route.
struct RouteAction {
    PoolKey key;
    Operation operation;
    /// @notice abi.encode(SwapParams), abi.encode(ModifyLiquidityParams), or abi.encode(uint256 amount0, uint256 amount1),
    /// according to operation.
    bytes parameters;
    bytes hookData;
}
