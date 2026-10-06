// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookCatalog} from "./interfaces/IHookCatalog.sol";
import {IHookExtension} from "./interfaces/IHookExtension.sol";
import {IKernelHook} from "./interfaces/IKernelHook.sol";
import {IKernelExecutorCallback} from "./interfaces/callback/IKernelExecutorCallback.sol";
import {KernelHookVault} from "./KernelHookVault.sol";
import {KernelRouteExecutor} from "./KernelRouteExecutor.sol";
import {CallbackLibrary} from "./libraries/CallbackLibrary.sol";
import {KernelHookConfiguration} from "./libraries/KernelHookConfiguration.sol";
import {KernelHookConstants} from "./libraries/KernelHookConstants.sol";
import {KernelHookDispatch} from "./libraries/KernelHookDispatch.sol";
import {KernelHookOperations, OperationFrame} from "./libraries/KernelHookOperations.sol";
import {KernelHookState} from "./libraries/KernelHookState.sol";
import {
    CALLBACK_COUNT,
    CallbackResult,
    CallbackType,
    ExecutionContext,
    ExtensionSettings,
    Operation,
    PoolStatus,
    RouteAction
} from "./types/KernelHookTypes.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";

/// @notice A Uniswap v4 hook in which each pool controls an ordered list of extensions.
/// @dev Deploy to an address mined for all fourteen hook flags. See IKernelHook for the execution model.
/// Preparation reserves one exact PoolId for its preparer, who must initialize it directly.
/// Catalog admission is checked only at installation; the copied entry and code hash of an installation
/// do not change afterwards.
contract KernelHook is BaseHook, Multicall, IKernelHook, IKernelExecutorCallback {
    using TransientStateLibrary for IPoolManager;

    uint256 public constant MAX_EXTENSIONS = KernelHookConstants.MAX_EXTENSIONS;
    uint8 public constant MAX_OPERATION_DEPTH = KernelHookConstants.MAX_OPERATION_DEPTH;
    uint32 public constant DEFAULT_CALLBACK_GAS_BUDGET = KernelHookConstants.DEFAULT_CALLBACK_GAS_BUDGET;
    bytes32 public constant CONFIGURER_ROLE = KernelHookConstants.CONFIGURER_ROLE;
    bytes32 public constant POOL_ADMIN_ROLE = KernelHookConstants.POOL_ADMIN_ROLE;

    IHookCatalog public immutable CATALOG;
    KernelHookVault public immutable VAULT;
    KernelRouteExecutor public immutable ROUTE_EXECUTOR;

    KernelHookState.State private _state;

    KernelHookOperations.Runtime private _runtime;

    /// @dev True during a management call, so that no pool operation can start inside it. The EVM clears transient
    /// storage at the end of each transaction; managementLock also clears it at the end of each call.
    bool private transient _managementInProgress;

    constructor(IPoolManager manager, address catalog) BaseHook(manager) {
        if (catalog.code.length == 0) revert InvalidConfiguration();
        CATALOG = IHookCatalog(catalog);
        VAULT = new KernelHookVault(manager);
        ROUTE_EXECUTOR = new KernelRouteExecutor(manager, VAULT);
        VAULT.setRouteExecutor(address(ROUTE_EXECUTOR));
    }

    /// @dev Rejects management calls while an operation is in progress. While the call runs, no pool operation
    /// can start: lifecycle calls go to untrusted extensions, which could otherwise start a swap.
    modifier managementLock() {
        _requireIdle();
        _managementInProgress = true;
        _;
        _managementInProgress = false;
    }

    /// @inheritdoc IKernelHook
    function preparePool(PoolKey calldata key) external managementLock {
        KernelHookConfiguration.preparePool(_state, key);
    }

    /// @inheritdoc IKernelHook
    function installExtension(PoolKey calldata key, IHookExtension extension, ExtensionSettings calldata settings)
        external
        managementLock
    {
        KernelHookConfiguration.installExtension(_state, CATALOG, key, extension, settings);
    }

    /// @inheritdoc IKernelHook
    function configureExtension(PoolKey calldata key, IHookExtension extension, ExtensionSettings calldata settings)
        external
        managementLock
    {
        KernelHookConfiguration.configureExtension(_state, key, extension, settings);
    }

    /// @inheritdoc IKernelHook
    function activateExtension(PoolKey calldata key, IHookExtension extension) external managementLock {
        KernelHookConfiguration.activateExtension(_state, key, extension);
    }

    /// @inheritdoc IKernelHook
    function deactivateExtension(PoolKey calldata key, IHookExtension extension) external managementLock {
        KernelHookConfiguration.deactivateExtension(_state, key, extension);
    }

    /// @inheritdoc IKernelHook
    function removeExtension(PoolKey calldata key, IHookExtension extension) external managementLock {
        KernelHookConfiguration.removeExtension(_state, VAULT, ROUTE_EXECUTOR, key, extension);
    }

    /// @inheritdoc IKernelHook
    function setCallbackOrder(PoolKey calldata key, CallbackType callback, address[] calldata order)
        external
        managementLock
    {
        KernelHookConfiguration.setCallbackOrder(_state, key, callback, order);
    }

    /// @inheritdoc IKernelHook
    function setExecutionLimits(
        PoolKey calldata key,
        uint8 maxOperationDepth,
        uint32[CALLBACK_COUNT] calldata callbackGasBudgets
    ) external managementLock {
        KernelHookConfiguration.setExecutionLimits(_state, key, maxOperationDepth, callbackGasBudgets);
    }

    /// @inheritdoc IKernelHook
    /// @dev Each call is a delegatecall to this contract, so it keeps msg.sender and all of its caller checks: a batch
    /// gives no right that the caller does not have alone. Each management call takes the management lock itself.
    /// The PoolManager callbacks and the route executor callbacks check msg.sender, so a batch
    /// cannot reach them. The function is not payable, so a batch cannot reuse msg.value.
    function multicall(bytes[] calldata data) public override(IKernelHook, Multicall) returns (bytes[] memory results) {
        return super.multicall(data);
    }

    /// @inheritdoc IKernelHook
    function grantPoolRole(PoolKey calldata key, bytes32 role, address account) external managementLock {
        KernelHookConfiguration.grantPoolRole(_state, key, role, account);
    }

    /// @inheritdoc IKernelHook
    function revokePoolRole(PoolKey calldata key, bytes32 role, address account) external managementLock {
        KernelHookConfiguration.revokePoolRole(_state, key, role, account);
    }

    /// @inheritdoc IKernelHook
    function hasPoolRole(PoolId poolId, bytes32 role, address account) external view returns (bool) {
        return _state.roles[poolId][role][account];
    }

    /// @inheritdoc IKernelHook
    function isPoolInitialized(PoolId poolId) external view returns (bool) {
        return KernelHookState.isInitialized(_state, poolId);
    }

    /// @inheritdoc IKernelHook
    function poolState(PoolId poolId)
        external
        view
        returns (
            PoolStatus status,
            address initializer,
            uint8 maxOperationDepth,
            uint32[CALLBACK_COUNT] memory callbackGasBudgets
        )
    {
        KernelHookState.PoolState storage pool = _state.pools[poolId];
        return (pool.status, pool.initializer, pool.maxOperationDepth, pool.callbackGasBudgets);
    }

    /// @inheritdoc IKernelHook
    function poolKey(PoolId poolId) external view returns (PoolKey memory) {
        return _state.poolKeys[poolId];
    }

    /// @inheritdoc IKernelHook
    function installedExtensions(PoolId poolId) external view returns (address[] memory) {
        return _state.pools[poolId].extensions;
    }

    /// @inheritdoc IKernelHook
    function callbackOrder(PoolId poolId, CallbackType callback) external view returns (address[] memory) {
        return _state.callbackOrders[poolId][callback];
    }

    /// @inheritdoc IKernelHook
    function isInstalled(PoolId poolId, address extension) external view returns (bool) {
        return _state.installations[poolId][extension].installed;
    }

    /// @inheritdoc IKernelHook
    function extensionConfiguration(PoolId poolId, address extension)
        external
        view
        returns (bool active, ExtensionSettings memory settings, IHookCatalog.Entry memory entry)
    {
        KernelHookState.Installation storage installation = KernelHookState.requireInstalled(_state, poolId, extension);
        return (installation.active, installation.settings, installation.entry);
    }

    /// @inheritdoc IKernelHook
    function currentContext() external view returns (ExecutionContext memory) {
        return KernelHookOperations.context();
    }

    /// @inheritdoc IKernelHook
    function ticketCount() external view returns (uint256) {
        return KernelHookOperations.ticketCount();
    }

    /// @inheritdoc IKernelHook
    /// @dev The route executor keeps Uniswap v4 hook dispatch for nested actions, and settles net debts
    /// without borrowing the inventory of another installation.
    function executeRoute(RouteAction[] calldata actions) external returns (BalanceDelta[] memory) {
        if (KernelHookOperations.frameCount() == 0) revert NestingDenied();
        if (VAULT.transferInProgress()) revert NestingDenied();
        OperationFrame frame = KernelHookOperations.currentFrame();
        KernelHookState.Installation storage installation =
            KernelHookState.requireInstalled(_state, frame.poolId(), msg.sender);
        if (frame.extension() != msg.sender) revert NestingDenied();
        if (!installation.settings.allowNesting) revert NestingDenied();
        if (poolManager.isUnlocked()) return ROUTE_EXECUTOR.executeWhileUnlocked(frame.poolId(), msg.sender, actions);
        // Only initialize can run while the PoolManager is locked. The route executor must then unlock the
        // PoolManager itself, which KernelHook allows only from afterInitialize. Such a route can act on any
        // initialized pool, and on this new pool only through the initial-liquidity seed exception.
        if (frame.callback() != CallbackType.AfterInitialize) revert NestingDenied();
        return ROUTE_EXECUTOR.unlockAndExecute(frame.poolId(), msg.sender, actions);
    }

    /// @inheritdoc IKernelHook
    function unwindPositions(PoolKey calldata key, RouteAction[] calldata actions)
        external
        returns (BalanceDelta[] memory results)
    {
        _requireIdle();
        PoolId poolId = KernelHookState.requireKnownPool(_state, key);
        KernelHookState.Installation storage installation = KernelHookState.requireInstalled(_state, poolId, msg.sender);
        if (installation.active) revert ExtensionActive();
        if (!KernelHookState.isInitialized(_state, poolId)) revert PoolNotInitialized();
        KernelHookOperations.pushExitFrame(_runtime, poolId, msg.sender);
        results = ROUTE_EXECUTOR.unlockAndExecute(poolId, msg.sender, actions);
        // Each nested action must have closed its own frame and ticket.
        if (KernelHookOperations.frameCount() != 1) revert UnexpectedCallback();
        if (KernelHookOperations.ticketCount() != 0) revert UnexpectedCallback();
        KernelHookOperations.popFrame();
    }

    /// @inheritdoc IKernelExecutorCallback
    function authorizeAction(RouteAction calldata action) external {
        if (msg.sender != address(ROUTE_EXECUTOR)) revert Unauthorized();
        if (KernelHookOperations.frameCount() == 0) revert Unauthorized();
        OperationFrame parent = KernelHookOperations.currentFrame();
        _requireNestingAllowed(parent, action);
        PoolId targetPoolId = action.key.toId();
        KernelHookState.validatePoolKey(action.key);
        bool isInitialLiquiditySeed = _isInitialLiquiditySeed(parent, targetPoolId, action);
        if (!KernelHookState.isInitialized(_state, targetPoolId)) {
            if (!isInitialLiquiditySeed) revert PoolNotInitialized();
        }
        _requireDepthBelowLimits(targetPoolId);
        if (!isInitialLiquiditySeed) KernelHookOperations.requireNoReentryInto(targetPoolId);
        CallbackType beforeCallback = CallbackLibrary.beforeCallbackOf(action.operation);
        KernelHookOperations.pushTicket(
            KernelHookOperations.actionHash(action.key, beforeCallback, action.parameters, action.hookData)
        );
    }

    /// @inheritdoc IKernelExecutorCallback
    function finishAction() external {
        if (msg.sender != address(ROUTE_EXECUTOR)) revert Unauthorized();
        KernelHookOperations.popTicket();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = KernelHookState.requireKnownPool(_state, key);
        // Only the preparer can initialize the pool, and only once.
        if (_state.pools[poolId].status != PoolStatus.Prepared) revert Unauthorized();
        if (sender != _state.pools[poolId].initializer) revert Unauthorized();
        _beginOperation(sender, key, CallbackType.BeforeInitialize, abi.encode(sqrtPriceX96), bytes(""));
        _state.pools[poolId].status = PoolStatus.Initializing;
        _runCallbacks(key, CallbackType.BeforeInitialize, abi.encode(sqrtPriceX96));
        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        _requireMatchingOperation(sender, key, CallbackType.BeforeInitialize, abi.encode(sqrtPriceX96), bytes(""));
        _runCallbacks(key, CallbackType.AfterInitialize, abi.encode(sqrtPriceX96, tick));
        PoolId poolId = key.toId();
        _state.pools[poolId].status = PoolStatus.Initialized;
        _state.roles[poolId][POOL_ADMIN_ROLE][sender] = true;
        _state.pools[poolId].adminCount = 1;
        emit PoolRoleChanged(poolId, POOL_ADMIN_ROLE, sender, true);
        emit PoolRegistered(poolId, sender);
        _endOperation();
        return IHooks.afterInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _beginOperation(sender, key, CallbackType.BeforeSwap, abi.encode(params), hookData);
        CallbackResult memory result = _runCallbacks(key, CallbackType.BeforeSwap, abi.encode(params, hookData));
        // Extensions return deltas in currency order. Uniswap wants them in specified/unspecified order:
        // the specified currency is currency0 for exact-input zeroForOne and exact-output oneForZero swaps.
        bool specified0 = (params.amountSpecified < 0) == params.zeroForOne;
        int128 specified = specified0 ? result.delta0 : result.delta1;
        int128 unspecified = specified0 ? result.delta1 : result.delta0;
        KernelHookOperations.currentFrame().setBeforeSwapUnspecifiedDelta(unspecified);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specified, unspecified), result.feeOverride);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        _requireMatchingOperation(sender, key, CallbackType.BeforeSwap, abi.encode(params), hookData);
        CallbackResult memory result = _runCallbacks(key, CallbackType.AfterSwap, abi.encode(params, delta, hookData));
        int128 unspecified = ((params.amountSpecified < 0) == params.zeroForOne) ? result.delta1 : result.delta0;
        _endOperation();
        return (IHooks.afterSwap.selector, unspecified);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _beginOperation(sender, key, CallbackType.BeforeAddLiquidity, abi.encode(params), hookData);
        _runCallbacks(key, CallbackType.BeforeAddLiquidity, abi.encode(params, hookData));
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _beginOperation(sender, key, CallbackType.BeforeRemoveLiquidity, abi.encode(params), hookData);
        _runCallbacks(key, CallbackType.BeforeRemoveLiquidity, abi.encode(params, hookData));
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        _requireMatchingOperation(sender, key, CallbackType.BeforeAddLiquidity, abi.encode(params), hookData);
        CallbackResult memory result =
            _runCallbacks(key, CallbackType.AfterAddLiquidity, abi.encode(params, delta, feesAccrued, hookData));
        _endOperation();
        return (IHooks.afterAddLiquidity.selector, toBalanceDelta(result.delta0, result.delta1));
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        _requireMatchingOperation(sender, key, CallbackType.BeforeRemoveLiquidity, abi.encode(params), hookData);
        CallbackResult memory result =
            _runCallbacks(key, CallbackType.AfterRemoveLiquidity, abi.encode(params, delta, feesAccrued, hookData));
        _endOperation();
        return (IHooks.afterRemoveLiquidity.selector, toBalanceDelta(result.delta0, result.delta1));
    }

    function _beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _beginOperation(sender, key, CallbackType.BeforeDonate, abi.encode(amount0, amount1), hookData);
        _runCallbacks(key, CallbackType.BeforeDonate, abi.encode(amount0, amount1, hookData));
        return IHooks.beforeDonate.selector;
    }

    function _afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        _requireMatchingOperation(sender, key, CallbackType.BeforeDonate, abi.encode(amount0, amount1), hookData);
        _runCallbacks(key, CallbackType.AfterDonate, abi.encode(amount0, amount1, hookData));
        _endOperation();
        return IHooks.afterDonate.selector;
    }

    function _runCallbacks(PoolKey calldata key, CallbackType callback, bytes memory data)
        private
        returns (CallbackResult memory)
    {
        return KernelHookDispatch.runCallbacks(
            _state, poolManager, VAULT, address(KernelHookDispatch), key, callback, data
        );
    }

    function _beginOperation(
        address sender,
        PoolKey calldata key,
        CallbackType callback,
        bytes memory parameters,
        bytes memory hookData
    ) private {
        if (_managementInProgress) revert ExecutionInProgress();
        if (VAULT.transferInProgress()) revert ExecutionInProgress();
        PoolId poolId = KernelHookState.requireKnownPool(_state, key);
        bytes32 hash = KernelHookOperations.actionHash(key, callback, parameters, hookData);
        if (KernelHookOperations.frameCount() != 0) {
            // A nested operation: only the route executor can start it, with the ticket of this exact action.
            if (sender != address(ROUTE_EXECUTOR)) revert UnexpectedCallback();
            KernelHookOperations.consumeTicket(hash);
        } else if (callback != CallbackType.BeforeInitialize) {
            // A top-level operation other than initialize needs an initialized pool.
            if (!KernelHookState.isInitialized(_state, poolId)) revert PoolNotInitialized();
        }
        KernelHookOperations.pushFrame(_runtime, poolId, sender, callback, hash);
    }

    function _requireMatchingOperation(
        address sender,
        PoolKey calldata key,
        CallbackType beforeCallback,
        bytes memory parameters,
        bytes memory hookData
    ) private view {
        bytes32 expectedHash = KernelHookOperations.requireMatchingFrame(sender, beforeCallback);
        bytes32 hash = KernelHookOperations.actionHash(key, beforeCallback, parameters, hookData);
        if (hash != expectedHash) revert UnexpectedCallback();
    }

    function _endOperation() private {
        KernelHookOperations.popFrame();
    }

    function _requireIdle() private view {
        if (_managementInProgress) revert ExecutionInProgress();
        KernelHookOperations.requireIdle();
        if (VAULT.transferInProgress()) revert ExecutionInProgress();
    }

    /// @dev Inside a callback, only the active installation can route, and only if it allows nesting.
    /// In the synthetic exit frame of unwindPositions, only liquidity removals and fee collections are allowed.
    function _requireNestingAllowed(OperationFrame parent, RouteAction calldata action) private view {
        if (parent.extension() == address(0)) revert NestingDenied();
        if (parent.isExitContext()) {
            if (action.operation != Operation.ModifyLiquidity) revert NestingDenied();
            if (abi.decode(action.parameters, (ModifyLiquidityParams)).liquidityDelta > 0) revert NestingDenied();
            return;
        }
        if (!_state.installations[parent.poolId()][parent.extension()].settings.allowNesting) revert NestingDenied();
    }

    /// @dev Nested actions need an initialized pool, with one exception: in afterInitialize, an installation
    /// of that pool may add (or collect) liquidity before KernelHook marks the pool Initialized.
    function _isInitialLiquiditySeed(OperationFrame parent, PoolId targetPoolId, RouteAction calldata action)
        private
        view
        returns (bool)
    {
        if (_state.pools[targetPoolId].status != PoolStatus.Initializing) return false;
        if (PoolId.unwrap(targetPoolId) != PoolId.unwrap(parent.poolId())) return false;
        if (parent.callback() != CallbackType.AfterInitialize) return false;
        if (action.operation != Operation.ModifyLiquidity) return false;
        return abi.decode(action.parameters, (ModifyLiquidityParams)).liquidityDelta >= 0;
    }

    /// @dev Both the target pool and the root pool limit how deep a route can go.
    function _requireDepthBelowLimits(PoolId targetPoolId) private view {
        uint256 depth = KernelHookOperations.operationDepth();
        PoolId rootPoolId = KernelHookOperations.frameAt(0).poolId();
        if (depth >= _state.pools[targetPoolId].maxOperationDepth) revert DepthLimitReached();
        if (depth >= _state.pools[rootPoolId].maxOperationDepth) revert DepthLimitReached();
    }
}
