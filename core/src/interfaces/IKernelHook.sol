// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookCatalog} from "./IHookCatalog.sol";
import {IHookExtension} from "./IHookExtension.sol";
import {
    CALLBACK_COUNT,
    CallbackType,
    ExecutionContext,
    ExtensionSettings,
    PoolStatus,
    RouteAction
} from "../types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice A Uniswap v4 hook that runs an ordered list of extensions for each pool.
/// @dev Each pool controls its own extensions: pool admins install and remove them, and configurers
/// activate, configure and order them. The catalog decides only which extensions a pool may install.
///
/// Execution model:
/// - An operation is one PoolManager call (initialize, swap, modify liquidity or donate) on a KernelHook pool.
///   The before callback of the operation pushes an OperationFrame; the matching after callback pops it.
/// - In each callback, KernelHook calls the active extensions that subscribe to it, in the pool's callback order.
/// - An extension with allowNesting can start a nested route from its callback with executeRoute. Before each
///   nested action, the route executor gets an ActionTicket from authorizeAction. The ticket binds the next
///   before callback to that exact action. finishAction removes the ticket when the action is complete.
interface IKernelHook {
    /// @notice Thrown when the caller does not have the role or identity that the function requires.
    error Unauthorized();

    /// @notice Thrown when a pool key is not valid for this hook: wrong hook address, currency order or tick spacing.
    /// @dev A static fee above the maximum reverts with LPFeeLibrary.LPFeeTooLarge instead.
    error InvalidPool();

    /// @notice Thrown at deployment when the catalog address has no code.
    error InvalidConfiguration();

    /// @notice Thrown when a role is not CONFIGURER_ROLE or POOL_ADMIN_ROLE, or cannot be granted now.
    error InvalidRole();

    /// @notice Thrown when a revoke would remove the last pool admin.
    error LastAdmin();

    /// @notice Thrown when an extension still holds vault funds or open positions, or refuses to uninstall.
    error OutstandingObligations();

    /// @notice Thrown when a management call, a pool operation or a vault transfer is in progress and blocks this call.
    /// @dev Authorized nested route actions are not blocked: they run inside the operation that started them.
    error ExecutionInProgress();

    /// @notice Thrown when a callback or a route step does not match the operation that KernelHook expects.
    error UnexpectedCallback();

    /// @notice Thrown when an extension would be called again while one of its calls is in progress, or when a
    /// nested action targets a pool whose operation is not yet in its after callback or still has required
    /// extensions to run.
    error ReentrancyDenied();

    /// @notice Thrown when a nested route is not allowed here.
    error NestingDenied();

    /// @notice Thrown when the extensions of a callback need more gas than the pool's callback gas budget.
    error GasBudgetExceeded();

    /// @notice Thrown when a lifecycle call to an extension does not return the expected value.
    error InvalidResponse();

    /// @notice Thrown when a callback returns a delta that it may not return: any delta from a callback other than
    /// beforeSwap, afterSwap and the after-liquidity callbacks, or a specified-currency delta from afterSwap.
    error InvalidDelta();

    /// @notice Thrown when a required (not optional) extension callback fails.
    /// @dev reason is one of: the extension's revert data; its return data, if that is not exactly one
    /// CallbackResult; or the error of KernelHook's check or settlement of the result. KernelHook raises
    /// GasBudgetExceeded here when its own reserve cannot give the extension its whole gas limit, for example with
    /// very large hookData; an extension can also raise the same error itself. Empty data can also mean that the
    /// settlement ran out of gas, for example with a token whose transfer costs more than a standard ERC20 transfer.
    /// @param extension The extension that failed
    /// @param callback The callback that failed
    /// @param reason Up to 256 bytes of the revert or return data
    error ExtensionFailed(address extension, CallbackType callback, bytes reason);

    /// @notice Thrown when preparePool is called for a pool key that is already prepared.
    error PoolAlreadyPrepared();

    /// @notice Thrown when a pool key was never prepared with preparePool.
    error PoolNotPrepared();

    /// @notice Thrown when a call needs an initialized pool, and the pool is not initialized yet.
    error PoolNotInitialized();

    /// @notice Thrown when the extension is not installed in the pool.
    error ExtensionNotInstalled();

    /// @notice Thrown when the extension is already installed in the pool.
    error ExtensionAlreadyInstalled();

    /// @notice Thrown when the pool already has MAX_EXTENSIONS installations.
    error TooManyExtensions();

    /// @notice Thrown when the catalog does not currently admit the extension.
    error ExtensionNotAdmitted();

    /// @notice Thrown when the extension has no code, or its code hash differs from its catalog entry
    /// (at installation) or from the entry copied into the installation (later).
    error ExtensionCodeMismatch();

    /// @notice Thrown when the pool is initialized and the extension does not support late installation.
    error LateInstallationNotSupported();

    /// @notice Thrown when settings subscribe to initialization callbacks of a pool that is already initialized.
    error InitializationCallbacksTooLate();

    /// @notice Thrown when a required installation would be activated without having run its initialization callbacks.
    error InitializationCallbacksIncomplete();

    /// @notice Thrown when a callback mask is empty or includes callbacks that the extension does not implement.
    error InvalidCallbackMask();

    /// @notice Thrown when ExtensionSettings.configuration is longer than MAX_CONFIGURATION_BYTES.
    error ConfigurationTooLarge();

    /// @notice Thrown when settings ask for optional callbacks or nesting that the extension does not support.
    error UnsupportedCapability();

    /// @notice Thrown when a lifecycle or subscribed callback gas limit is outside MIN_CALL_GAS to MAX_CALL_GAS.
    error GasLimitOutOfRange();

    /// @notice Thrown when the call needs an inactive installation, and the installation is active.
    error ExtensionActive();

    /// @notice Thrown when the call needs an active installation, and the installation is inactive.
    error ExtensionInactive();

    /// @notice Thrown when the extension's canActivate call fails, returns a size other than 32 bytes, or returns false.
    /// @dev A 32-byte return value that is not a valid bool reverts in abi.decode instead.
    error ActivationRejected();

    /// @notice Thrown when a change needs the subscribers of a callback to be inactive, and one of them is active.
    error SubscribersActive();

    /// @notice Thrown when a callback order does not list each subscriber of the callback exactly once.
    error InvalidCallbackOrder();

    /// @notice Thrown when the maximum operation depth or a callback gas budget is out of range.
    error InvalidExecutionLimits();

    /// @notice Thrown when a nested action would exceed the maximum operation depth of its pool or of the root pool.
    error DepthLimitReached();

    /// @notice Thrown when a beforeSwap delta would change the sign of the swap amount.
    error DeltaExceedsSwapAmount();

    /// @notice Thrown when a fee override comes from a callback other than beforeSwap, for a pool without a
    /// dynamic fee, or without the override flag.
    /// @dev A fee above the maximum reverts with LPFeeLibrary.LPFeeTooLarge instead.
    error InvalidFeeOverride();

    /// @notice Thrown when two extensions return a fee override for the same callback.
    error MultipleFeeOverrides();

    /// @notice Thrown when the beforeSwap and afterSwap unspecified deltas together do not fit in an int128.
    error DeltaOverflow();

    /// @notice Emitted when a pool key is reserved for its initializer.
    /// @param poolId The pool
    /// @param initializer The only address that can initialize the pool
    event PoolPrepared(PoolId indexed poolId, address indexed initializer);

    /// @notice Emitted when a prepared pool completes initialization.
    /// @param poolId The pool
    /// @param initializer The address that initialized the pool and became its first admin
    event PoolRegistered(PoolId indexed poolId, address indexed initializer);

    /// @notice Emitted when an account gets or loses a pool role.
    /// @param poolId The pool
    /// @param role CONFIGURER_ROLE or POOL_ADMIN_ROLE
    /// @param account The account
    /// @param granted True if the role was granted, false if revoked
    event PoolRoleChanged(PoolId indexed poolId, bytes32 indexed role, address indexed account, bool granted);

    /// @notice Emitted when a pool installs an extension. The installation starts inactive.
    /// @param poolId The pool
    /// @param extension The extension
    /// @param callbackMask The callbacks that the installation subscribes to
    event ExtensionInstalled(PoolId indexed poolId, address indexed extension, uint16 callbackMask);

    /// @notice Emitted when an installation gets new settings.
    /// @param poolId The pool
    /// @param extension The extension
    event ExtensionConfigured(PoolId indexed poolId, address indexed extension);

    /// @notice Emitted when an installation is activated or deactivated.
    /// @param poolId The pool
    /// @param extension The extension
    /// @param active True if the installation is now active
    event ExtensionActivationChanged(PoolId indexed poolId, address indexed extension, bool active);

    /// @notice Emitted when a pool removes an extension.
    /// @param poolId The pool
    /// @param extension The extension
    event ExtensionRemoved(PoolId indexed poolId, address indexed extension);

    /// @notice Emitted when the call order of one callback changes.
    /// @param poolId The pool
    /// @param callback The callback
    /// @param order The extensions in the order in which they are called
    event CallbackOrderChanged(PoolId indexed poolId, CallbackType indexed callback, address[] order);

    /// @notice Emitted when a pool gets new execution limits.
    /// @param poolId The pool
    /// @param maxOperationDepth The maximum operation depth: the root operation plus nested operations,
    /// without the synthetic frame of unwindPositions. 1 allows no nesting.
    /// @param callbackGasBudgets The gas budget of each callback sequence, indexed by CallbackType
    event ExecutionLimitsChanged(
        PoolId indexed poolId, uint8 maxOperationDepth, uint32[CALLBACK_COUNT] callbackGasBudgets
    );

    /// @notice Emitted when KernelHook skips an optional extension for the rest of an operation.
    /// @param poolId The pool
    /// @param extension The skipped extension
    /// @param callback The callback in which the skip happened
    /// @param reason The revert data of the failed call, or the selector of the rule that caused the skip
    event ExtensionSkipped(
        PoolId indexed poolId, address indexed extension, CallbackType indexed callback, bytes reason
    );

    /// @notice Reserves a pool key for the caller, who must then initialize the pool in the PoolManager.
    /// @dev The caller is the pool's only admin until initialization. A factory can prepare and initialize
    /// a pool, grant admin to its user, and then revoke its own role.
    /// WARNING: the first caller reserves the key permanently, and a reservation does not expire. Any account can
    /// reserve a key first and never initialize it. The key is then blocked, but other keys are not: a pool with a
    /// different fee or tick spacing has a different key. To keep the gap small, prepare, install, and initialize
    /// in one transaction from a factory contract.
    /// @param key The pool key. key.hooks must be this contract.
    function preparePool(PoolKey calldata key) external;

    /// @notice Installs a catalogued extension in a pool. The installation starts inactive.
    /// @dev Only a pool admin (or the initializer of a prepared pool) can call this. KernelHook copies the
    /// catalog entry; later catalog changes do not affect the installation.
    /// @param key The pool key
    /// @param extension The extension to install
    /// @param settings The installation settings
    function installExtension(PoolKey calldata key, IHookExtension extension, ExtensionSettings calldata settings)
        external;

    /// @notice Replaces the settings of an inactive installation.
    /// @dev Only a configurer or pool admin can call this. The extension's onConfigure must accept the change.
    /// @param key The pool key
    /// @param extension The installed extension
    /// @param settings The new settings
    function configureExtension(PoolKey calldata key, IHookExtension extension, ExtensionSettings calldata settings)
        external;

    /// @notice Activates an installation, after the extension's canActivate returns true.
    /// @dev Only a configurer or pool admin can call this. Reverts if the pool's callback gas budgets
    /// cannot cover the required extensions.
    /// @param key The pool key
    /// @param extension The installed extension
    function activateExtension(PoolKey calldata key, IHookExtension extension) external;

    /// @notice Deactivates an installation. Its callbacks stop running.
    /// @dev Only a configurer or pool admin can call this.
    /// @param key The pool key
    /// @param extension The installed extension
    function deactivateExtension(PoolKey calldata key, IHookExtension extension) external;

    /// @notice Removes an inactive installation that has no vault funds, no open positions, and that the
    /// extension agrees to uninstall.
    /// @dev Only a pool admin can call this.
    /// @param key The pool key
    /// @param extension The installed extension
    function removeExtension(PoolKey calldata key, IHookExtension extension) external;

    /// @notice Sets the call order of one callback.
    /// @dev Only a configurer or pool admin can call this, and only while all subscribers of the callback are inactive.
    /// order must contain each subscriber exactly once.
    /// @param key The pool key
    /// @param callback The callback
    /// @param order The subscribed extensions in call order
    function setCallbackOrder(PoolKey calldata key, CallbackType callback, address[] calldata order) external;

    /// @notice Sets the maximum operation depth and the callback gas budgets of a pool.
    /// @dev Only a configurer or pool admin can call this, and only while all installations are inactive.
    /// @param key The pool key
    /// @param maxOperationDepth From 1 (no nesting) to MAX_OPERATION_DEPTH. The root operation counts as 1.
    /// @param callbackGasBudgets The gas budget of each callback sequence, indexed by CallbackType
    function setExecutionLimits(
        PoolKey calldata key,
        uint8 maxOperationDepth,
        uint32[CALLBACK_COUNT] calldata callbackGasBudgets
    ) external;

    /// @notice Runs several calls to this contract in order, in one transaction. If one call fails, all fail.
    /// @dev Use it to change a live pool without a gap in which swaps run without its extensions: deactivate the
    /// subscribers, make the change, and activate them again. Each activation calls canActivate again, so each
    /// extension accepts the new set of subscribers, their order and the limits. A management call that needs
    /// inactive subscribers (installExtension, configureExtension, removeExtension, setCallbackOrder,
    /// setExecutionLimits) can therefore run on a live pool. Each call keeps its own caller and its own checks.
    /// @param data The encoded calls
    /// @return results The return data of each call
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);

    /// @notice Grants a pool role to an account.
    /// @dev Only a pool admin can call this. POOL_ADMIN_ROLE can be granted only after initialization.
    /// @param key The pool key
    /// @param role CONFIGURER_ROLE or POOL_ADMIN_ROLE
    /// @param account The account
    function grantPoolRole(PoolKey calldata key, bytes32 role, address account) external;

    /// @notice Revokes a pool role from an account.
    /// @dev Only a pool admin can call this. The last pool admin cannot be revoked.
    /// @param key The pool key
    /// @param role CONFIGURER_ROLE or POOL_ADMIN_ROLE
    /// @param account The account
    function revokePoolRole(PoolKey calldata key, bytes32 role, address account) external;

    /// @notice Runs a nested route of PoolManager actions for the extension whose callback runs now.
    /// @dev Only that extension can call this, and only if its installation allows nesting. All nested work
    /// uses the gas limit of the current callback, including KernelHook's reserves for the extension calls of each
    /// nested operation. Net debts are paid from the extension's own vault balance.
    /// @param actions The actions, in order
    /// @return The balance delta of each action
    function executeRoute(RouteAction[] calldata actions) external returns (BalanceDelta[] memory);

    /// @notice Lets an inactive installation close its route-executor positions without reactivation.
    /// @dev Only liquidity removals and fee collections (liquidityDelta <= 0) are accepted.
    /// No swaps, donations or liquidity increases.
    /// @param key The pool key
    /// @param actions ModifyLiquidity actions with liquidityDelta <= 0
    /// @return results The balance delta of each action
    function unwindPositions(PoolKey calldata key, RouteAction[] calldata actions)
        external
        returns (BalanceDelta[] memory results);

    /// @notice Returns true if account has role in the pool.
    function hasPoolRole(PoolId poolId, bytes32 role, address account) external view returns (bool);

    /// @notice Returns true if the pool has completed initialization.
    function isPoolInitialized(PoolId poolId) external view returns (bool);

    /// @notice Returns the lifecycle state and execution limits of a pool.
    /// @return status The pool status
    /// @return initializer The address that prepared the pool
    /// @return maxOperationDepth The maximum operation depth, including the root operation
    /// @return callbackGasBudgets The gas budget of each callback sequence, indexed by CallbackType
    function poolState(PoolId poolId)
        external
        view
        returns (
            PoolStatus status,
            address initializer,
            uint8 maxOperationDepth,
            uint32[CALLBACK_COUNT] memory callbackGasBudgets
        );

    /// @notice Returns the pool key of a prepared pool.
    function poolKey(PoolId poolId) external view returns (PoolKey memory);

    /// @notice Returns the installed extensions of a pool, in installation order.
    function installedExtensions(PoolId poolId) external view returns (address[] memory);

    /// @notice Returns the call order of one callback.
    function callbackOrder(PoolId poolId, CallbackType callback) external view returns (address[] memory);

    /// @notice Returns true if the extension is installed in the pool.
    function isInstalled(PoolId poolId, address extension) external view returns (bool);

    /// @notice Returns the flags of an installation, without copying its settings. All are false or zero if the
    /// extension is not installed in the pool.
    /// @dev Extensions read this at callback time to check their co-subscribers cheaply: two storage reads.
    /// @return installed True if the extension is installed in the pool
    /// @return active True if the installation is active
    /// @return optional True if KernelHook skips the installation's failed callbacks instead of reverting
    /// @return callbackMask The callbacks that the installation subscribes to, as a CallbackLibrary mask
    function installationFlags(PoolId poolId, address extension)
        external
        view
        returns (bool installed, bool active, bool optional, uint16 callbackMask);

    /// @notice Returns an installation. Reverts if the extension is not installed in the pool.
    /// @return active True if the installation is active
    /// @return settings The installation settings
    /// @return entry The catalog entry copied at installation
    function extensionConfiguration(PoolId poolId, address extension)
        external
        view
        returns (bool active, ExtensionSettings memory settings, IHookCatalog.Entry memory entry);

    /// @notice Returns the context of the operation in progress, or an empty context if there is none.
    function currentContext() external view returns (ExecutionContext memory);

    /// @notice The number of authorized nested actions that have not finished. Zero outside an operation.
    function ticketCount() external view returns (uint256);
}
