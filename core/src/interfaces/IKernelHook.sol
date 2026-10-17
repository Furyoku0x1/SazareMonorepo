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
///   nested action on a KernelHook pool, the route executor gets an ActionTicket from authorizeAction. The ticket
///   binds the next before callback to that exact action. finishAction removes the ticket when the action is
///   complete. A ForeignSwap (hookless pool) or ExternalSwap (outside venue) calls no KernelHook callback, so it
///   gets no ticket and the executor does not call finishAction for it.
/// - Each callback attempt settles at most an int128 delta per currency. Route net settlement has the same limit.
/// - An extension contract installed in several pools is one trust domain: it is the custodian of its vault funds
///   and may withdraw from one installation to fund another. Pools needing isolation must use separate instances.
/// - Optional attempts roll back their own call, result validation and settlement on failure. In a root operation
///   or a direct child of the unwindPositions exit frame, an optional extension is skipped when it fails, when it is
///   already mid-call, or when the pool's callback budget cannot fit the attempt and its reserves; a caller
///   forwarding too little gas makes the operation revert. The unwind exception keeps an unreliable target from
///   blocking position removal. A nested operation entered from another pool, even a pool further up the stack,
///   reverts instead of skipping, for each of those reasons and for a forwarding shortfall: another pool must not
///   make this pool run without one of its extensions. Only a route from a pool into itself (the parent operation's
///   pool) may skip optional callbacks, including under the parent's gas limit.
///   A skip lasts through the rest of that operation.
/// - Operation hookData is capped at 8 KiB, including nested Kernel operations.
///   Callback admission charges the gas actually spent by earlier subscribers, which grows with the caller's
///   hookData (up to 8 KiB) and with what earlier extensions do. A pool whose callback budget does not cover its
///   subscribers' declared limits lets the caller tip whether a later optional extension runs.
/// - Swap gas depends on extension state; frontends should forward the configured worst case rather than rely
///   only on estimates against current state.
/// - Operations revert with SyncPending while the PoolManager has an ERC20 sync pending, including nested
///   actions, initialization seeds and unwindPositions actions. A nested refusal fails the extension's attempt.
///   Pay with sync, transfer and settle together, as Uniswap's periphery does, before starting another operation.
///   Vault claims-only payments preserve a pending sync; physical payments, ExternalSwap and claim redemption
///   remain blocked while an ERC20 sync is pending.
/// - Accounting checks compare synced currency and reserves, PoolManager's nonzero-delta count and KernelHook's deltas,
///   allowing only its settlement changes. This is a tripwire, not a sandbox: count-neutral manipulation by admitted
///   code outside KernelHook's pool currencies is outside it.
interface IKernelHook {
    /// @notice Thrown when the caller does not have the role or identity that the function requires.
    error Unauthorized();

    /// @notice Thrown when a pool key is not valid for this hook: wrong hook address, currency order or tick spacing
    /// (below 20, or above the PoolManager's maximum).
    /// Also thrown when the key of a ForeignSwap route action has a hook.
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

    /// @notice Thrown when an operation starts while the PoolManager has an ERC20 sync pending.
    /// @dev Complete sync, transfer and settle together before starting an operation.
    error SyncPending();

    /// @notice Thrown when a required callback would reenter the same installation (one pool and extension)
    /// without supportsReentrancy, or a nested action targets a pool whose operation is not yet in its after callback
    /// or still has required extensions to run.
    /// @dev Optional callbacks skip reentry into the same installation even with supportsReentrancy, except in a
    /// nested operation entered from another pool, which reverts. Calls to the same extension contract in other pools
    /// are different installations.
    error ReentrancyDenied();

    /// @notice Thrown when a nested route is not allowed here.
    error NestingDenied();

    /// @notice Thrown when the pool's callback budget cannot cover required extensions, or optional ones in a nested
    /// operation entered from another pool, or the forwarded gas cannot cover a root callback, required nested callback
    /// or lifecycle call's full limit and KernelHook's reserves.
    /// @dev Only a route from a pool into itself may skip optional callbacks for forwarded gas.
    error GasBudgetExceeded();

    /// @notice Thrown when a lifecycle call to an extension does not return the expected value.
    error InvalidResponse();

    /// @notice Thrown when a callback returns a delta that it may not return: any delta from a callback other than
    /// beforeSwap, afterSwap and the after-liquidity callbacks, or a specified-currency delta from afterSwap.
    error InvalidDelta();

    /// @notice Thrown when a required callback fails, or an optional attempt fails in a nested operation entered from
    /// another pool (even one already on the stack), other than a direct child of unwindPositions' exit frame.
    /// @dev reason is one of: the extension's revert data; its return data, if that is not exactly one
    /// CallbackResult; or the error of KernelHook's check or settlement of the result.
    /// GasBudgetExceeded raised by an extension itself, including from a required nested callback, is an attempt
    /// failure. KernelHook's own root forwarding and reserve shortfalls revert the operation directly with
    /// GasBudgetExceeded. Empty data can also mean that the settlement ran out of gas, for example with a token
    /// whose transfer costs more than a standard ERC20 transfer.
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

    /// @notice Thrown when an operation begins with hookData longer than 8 KiB.
    error HookDataTooLarge();

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

    /// @notice Thrown when a callback order does not list each subscriber exactly once, or a swap callback orders
    /// a required subscriber after an optional subscriber.
    error InvalidCallbackOrder();

    /// @notice Thrown when the maximum operation depth or a callback gas budget is out of range.
    error InvalidExecutionLimits();

    /// @notice Thrown when a nested action would exceed the maximum operation depth of its target pool or of the pool
    /// whose extension started it.
    error DepthLimitReached();

    /// @notice Thrown when a beforeSwap delta would change the sign of the swap amount.
    error DeltaExceedsSwapAmount();

    /// @notice Thrown when a fee override comes from a callback other than beforeSwap, for a pool without a
    /// dynamic fee, without the override flag, or a combined LP and directional protocol fee of 100% with remaining exact output.
    /// @dev A fee above the maximum reverts with LPFeeLibrary.LPFeeTooLarge instead.
    error InvalidFeeOverride();

    /// @notice Thrown when two extensions return a fee override for the same callback.
    error MultipleFeeOverrides();

    /// @notice Thrown when combined hook deltas, the caller's resulting after-callback deltas, or a route's net change
    /// in a currency do not fit int128.
    error DeltaOverflow();

    /// @notice Thrown when a callback attempt leaves unexpected KernelHook currency deltas or changes the
    /// PoolManager's nonzero-delta count beyond its settlement, or changes its synced currency or reserves.
    error UnexpectedAccounting();

    /// @notice Emitted when the base LP fee of a dynamic-fee pool changes.
    /// @param poolId The pool
    /// @param fee The new base fee, in millionths
    event DynamicLPFeeChanged(PoolId indexed poolId, uint24 fee);

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
    /// without the synthetic frame of unwindPositions. 1 allows no nested Kernel operation (a ForeignSwap adds none).
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
    /// a pool, grant admin to its user, and then revoke its own role. The initializer becomes the first admin:
    /// use an EOA or an access-controlled contract, never a shared public forwarder such as Multicall3.
    /// WARNING: the first caller reserves the key permanently, and a reservation does not expire. Any account can
    /// reserve a key first and never initialize it. The key is then blocked, but other keys are not: a pool with a
    /// different fee or tick spacing has a different key. To keep the gap small, prepare, install, and initialize
    /// in one transaction from a factory contract.
    /// @param key The pool key. key.hooks must be this contract, and key.tickSpacing at least 20.
    function preparePool(PoolKey calldata key) external;

    /// @notice Installs a catalogued extension in a pool. The installation starts inactive.
    /// @dev Only a pool admin (or the initializer of a prepared pool) can call this. KernelHook copies the
    /// catalog entry; later catalog changes do not affect the installation. A required extension's subscriptions go
    /// before each callback's first optional subscriber, an optional one's at the end.
    /// @param key The pool key
    /// @param extension The extension to install
    /// @param settings The installation settings
    function installExtension(PoolKey calldata key, IHookExtension extension, ExtensionSettings calldata settings)
        external;

    /// @notice Replaces the settings of an inactive installation.
    /// @dev Only a configurer or pool admin can call this. The extension's onConfigure must accept the change. A new
    /// callback mask, optional callbacks made required, a subscribed callback's gas limit change, or an allowNesting
    /// change in either direction needs every subscriber of the callbacks involved inactive. Required callbacks
    /// made optional, configuration bytes, lifecycleGasLimit and unsubscribed gas limits do not need this gate.
    /// Unchanged subscriptions keep their place; new ones, and all of them when required-ness changes, are placed as
    /// in installExtension, so the swap callbacks keep required-before-optional order.
    /// @param key The pool key
    /// @param extension The installed extension
    /// @param settings The new settings
    function configureExtension(PoolKey calldata key, IHookExtension extension, ExtensionSettings calldata settings)
        external;

    /// @notice Activates an installation, after the extension's canActivate returns true.
    /// @dev Only a configurer or pool admin can call this. Reverts if the pool's callback gas budgets
    /// cannot cover the required extensions. Required swap subscribers must precede every optional subscriber.
    /// Activation rechecks active co-subscribers' canActivate against the resulting active set.
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
    /// order must contain each subscriber exactly once; beforeSwap and afterSwap require required subscribers first.
    /// @param key The pool key
    /// @param callback The callback
    /// @param order The subscribed extensions in call order
    function setCallbackOrder(PoolKey calldata key, CallbackType callback, address[] calldata order) external;

    /// @notice Sets the base LP fee used when a dynamic-fee pool's swap has no extension override.
    /// @dev Only a pool admin can call this, after initialization and outside an operation or management call.
    /// Static-fee pools are rejected. Dynamic pools start at 0%; admins must set their desired fallback fee.
    /// A 100% base fee is valid, but PoolManager rejects exact-output swaps at that fee.
    /// @param key The dynamic-fee pool key
    /// @param fee The base fee in millionths, from 0 to 1,000,000
    function setDynamicLPFee(PoolKey calldata key, uint24 fee) external;

    /// @notice Sets the maximum operation depth and the callback gas budgets of a pool.
    /// @dev Only a configurer or pool admin can call this, and only while all installations are inactive.
    /// @param key The pool key
    /// @param maxOperationDepth From 1 (no nested Kernel operation) to MAX_OPERATION_DEPTH. The root operation counts
    /// as 1. A ForeignSwap in a hookless pool adds no Kernel operation, so it does not count. It limits the routes
    /// that enter this pool and the routes that this pool's extensions start; a route started by another pool's
    /// extension is not limited by the root pool, so a pool's admin cannot cap the depth of a chain beyond its first
    /// hop.
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
    /// nested operation. Net debts are paid from the extension's own vault balance. A ForeignSwap action swaps in
    /// a hookless pool on the same PoolManager, and an ExternalSwap action swaps on an outside venue through a
    /// Catalog-admitted adapter. Neither opens a Kernel operation, and the route settles both net with the other
    /// actions. The target pool of every other action must use this KernelHook. Routing liquidity into another
    /// Kernel pool trusts that pool's admin: its extensions and depth limits govern removal, and open positions
    /// pin the origin installation until closed. Net settlement is limited to int128 per currency, but debits the
    /// origin installation's vault without a caller-supplied bound. Extensions must check the returned BalanceDelta[]
    /// against their own spending and slippage limits before accepting the route.
    /// @param actions The actions, in order
    /// @return The balance delta of each action
    function executeRoute(RouteAction[] calldata actions) external returns (BalanceDelta[] memory);

    /// @notice Lets an inactive installation close its route-executor positions without reactivation.
    /// @dev Only liquidity removals and fee collections (liquidityDelta <= 0) are accepted.
    /// No swaps, donations or liquidity increases. A synthetic exit frame authorizes these actions but does not
    /// count toward operation depth. Its direct children receive root gas semantics, because gas comes from the
    /// unwind caller; callbacks of those children may route further under their own callback limits.
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

    /// @notice Whether the operation in progress could start a route into targetPoolId within the depth limits now:
    /// the target pool's limit and the limit of the operation's own pool. False with no operation in progress.
    /// @dev The same depth check that authorizes a route (only depth: not the route's other rules), so an extension
    /// can tell before it acts whether a later route from this operation (for example in its after callback) will
    /// have room.
    function hasDepthForRoute(PoolId targetPoolId) external view returns (bool);

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
