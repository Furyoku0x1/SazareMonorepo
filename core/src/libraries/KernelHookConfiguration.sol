// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookExtension} from "../interfaces/IHookExtension.sol";
import {IHookCatalog} from "../interfaces/IHookCatalog.sol";
import {IKernelHook} from "../interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "../interfaces/IKernelHookExtension.sol";
import {KernelHookVault} from "../KernelHookVault.sol";
import {KernelRouteExecutor} from "../KernelRouteExecutor.sol";
import {CALLBACK_COUNT, CallbackType, ExtensionSettings, PoolStatus} from "../types/KernelHookTypes.sol";
import {BoundedCall} from "./BoundedCall.sol";
import {CallbackLibrary} from "./CallbackLibrary.sol";
import {KernelHookConstants} from "./KernelHookConstants.sol";
import {KernelHookState} from "./KernelHookState.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice Statically linked configuration implementation for KernelHook.
/// @dev KernelHook wraps every mutation in its execution lock. This library is immutable
/// framework code, not an extension, and has no administrative owner or upgrade mechanism.
library KernelHookConfiguration {
    using CallbackLibrary for CallbackType;

    /// @notice Prepares a pool with the default execution limits.
    /// @dev See IKernelHook.preparePool.
    function preparePool(KernelHookState.State storage state, PoolKey calldata key) public {
        KernelHookState.validatePoolKey(key);
        PoolId poolId = key.toId();
        KernelHookState.PoolState storage pool = state.pools[poolId];
        if (pool.status != PoolStatus.Unprepared) revert IKernelHook.PoolAlreadyPrepared();
        pool.status = PoolStatus.Prepared;
        pool.initializer = msg.sender;
        pool.maxOperationDepth = KernelHookConstants.DEFAULT_MAX_OPERATION_DEPTH;
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            pool.callbackGasBudgets[i] = KernelHookConstants.DEFAULT_CALLBACK_GAS_BUDGET;
        }
        state.poolKeys[poolId] = key;
        emit IKernelHook.PoolPrepared(poolId, msg.sender);
    }

    /// @notice Installs an admitted extension with its initial settings.
    /// @dev See IKernelHook.installExtension.
    function installExtension(
        KernelHookState.State storage state,
        IHookCatalog catalog,
        PoolKey calldata key,
        IHookExtension extension,
        ExtensionSettings calldata settings
    ) public {
        PoolId poolId = KernelHookState.requireKnownPool(state, key);
        _requireAdmin(state, poolId);
        address account = address(extension);
        KernelHookState.PoolState storage pool = state.pools[poolId];
        KernelHookState.Installation storage installation = state.installations[poolId][account];
        if (installation.installed) revert IKernelHook.ExtensionAlreadyInstalled();
        if (pool.extensions.length == KernelHookConstants.MAX_EXTENSIONS) revert IKernelHook.TooManyExtensions();
        IHookCatalog.Entry memory entry = catalog.getEntry(account);
        _requireInstallableEntry(account, pool.status, settings.callbackMask, entry);
        _validateSettings(settings, entry);
        _requireCallbacksInactive(state, poolId, settings.callbackMask);
        installation.installed = true;
        installation.extensionIndex = uint8(pool.extensions.length);
        installation.entry = entry;
        installation.settings = settings;
        // _validateSettings limits the configuration to MAX_CONFIGURATION_BYTES, which is 256 words.
        installation.configurationWords = uint16((settings.configuration.length + 31) / 32);
        pool.extensions.push(account);
        _subscribe(state, poolId, account, settings.callbackMask);
        _callLifecycleHook(
            account,
            settings.lifecycleGasLimit,
            abi.encodeCall(IKernelHookExtension.onInstall, (key, settings)),
            IKernelHookExtension.onInstall.selector
        );
        emit IKernelHook.ExtensionInstalled(poolId, account, settings.callbackMask);
    }

    /// @notice Updates the settings of an inactive installation.
    /// @dev See IKernelHook.configureExtension.
    function configureExtension(
        KernelHookState.State storage state,
        PoolKey calldata key,
        IHookExtension extension,
        ExtensionSettings calldata settings
    ) public {
        PoolId poolId = KernelHookState.requireKnownPool(state, key);
        _requireConfigurer(state, poolId);
        address account = address(extension);
        KernelHookState.Installation storage installation = KernelHookState.requireInstalled(state, poolId, account);
        _requireInactiveInstallation(installation, account);
        _validateSettings(settings, installation.entry);
        if (settings.callbackMask != installation.settings.callbackMask) {
            _requireInitializationCallbacksTimely(state.pools[poolId].status, settings.callbackMask);
            _requireCallbacksInactive(state, poolId, settings.callbackMask | installation.settings.callbackMask);
            _unsubscribe(state, poolId, account, installation.settings.callbackMask);
            _subscribe(state, poolId, account, settings.callbackMask);
        }
        // The extension validates that new settings preserve outstanding users' rights.
        _callLifecycleHook(
            account,
            settings.lifecycleGasLimit,
            abi.encodeCall(IKernelHookExtension.onConfigure, (key, installation.settings, settings)),
            IKernelHookExtension.onConfigure.selector
        );
        installation.settings = settings;
        // _validateSettings limits the configuration to MAX_CONFIGURATION_BYTES, which is 256 words.
        installation.configurationWords = uint16((settings.configuration.length + 31) / 32);
        emit IKernelHook.ExtensionConfigured(poolId, account);
    }

    /// @notice Activates an eligible installation within the pool's callback gas budgets.
    /// @dev See IKernelHook.activateExtension.
    function activateExtension(KernelHookState.State storage state, PoolKey calldata key, IHookExtension extension)
        public
    {
        PoolId poolId = KernelHookState.requireKnownPool(state, key);
        _requireConfigurer(state, poolId);
        KernelHookState.Installation storage installation =
            KernelHookState.requireInstalled(state, poolId, address(extension));
        _requireInactiveInstallation(installation, address(extension));
        _requireInitializationCallbacksComplete(state.pools[poolId].status, installation);
        _requireActivationAccepted(address(extension), key, installation);
        installation.active = true;
        _requireBudgetsCoverMandatoryGas(state, poolId);
        emit IKernelHook.ExtensionActivationChanged(poolId, address(extension), true);
    }

    /// @notice Deactivates an active installation.
    /// @dev See IKernelHook.deactivateExtension.
    function deactivateExtension(KernelHookState.State storage state, PoolKey calldata key, IHookExtension extension)
        public
    {
        PoolId poolId = KernelHookState.requireKnownPool(state, key);
        _requireConfigurer(state, poolId);
        KernelHookState.Installation storage installation =
            KernelHookState.requireInstalled(state, poolId, address(extension));
        if (!installation.active) revert IKernelHook.ExtensionInactive();
        installation.active = false;
        emit IKernelHook.ExtensionActivationChanged(poolId, address(extension), false);
    }

    /// @notice Removes an inactive installation after it releases its obligations.
    /// @dev See IKernelHook.removeExtension.
    function removeExtension(
        KernelHookState.State storage state,
        KernelHookVault vault,
        KernelRouteExecutor routeExecutor,
        PoolKey calldata key,
        IHookExtension extension
    ) public {
        PoolId poolId = KernelHookState.requireKnownPool(state, key);
        _requireAdmin(state, poolId);
        address account = address(extension);
        KernelHookState.Installation storage installation = KernelHookState.requireInstalled(state, poolId, account);
        _requireInactiveInstallation(installation, account);
        _requireCallbacksInactive(state, poolId, installation.settings.callbackMask);
        _requireRemovable(vault, routeExecutor, poolId, account, key, installation.settings.lifecycleGasLimit);
        _callLifecycleHook(
            account,
            installation.settings.lifecycleGasLimit,
            abi.encodeCall(IKernelHookExtension.onUninstall, (key, installation.settings.configuration)),
            IKernelHookExtension.onUninstall.selector
        );
        // onUninstall is untrusted code. The management lock stops pool operations during it, but the extension
        // is still installed and can deposit into the vault, so check its obligations again.
        _requireRemovable(vault, routeExecutor, poolId, account, key, installation.settings.lifecycleGasLimit);
        _unsubscribe(state, poolId, account, installation.settings.callbackMask);
        _removeInstallation(state, poolId, account);
        emit IKernelHook.ExtensionRemoved(poolId, account);
    }

    /// @notice Sets the order of the inactive subscribers of a callback.
    /// @dev See IKernelHook.setCallbackOrder.
    function setCallbackOrder(
        KernelHookState.State storage state,
        PoolKey calldata key,
        CallbackType callback,
        address[] calldata order
    ) public {
        PoolId poolId = KernelHookState.requireKnownPool(state, key);
        _requireConfigurer(state, poolId);
        _requireCallbacksInactive(state, poolId, callback.mask());
        _validateCallbackOrder(state, poolId, callback, order);
        state.callbackOrders[poolId][callback] = order;
        emit IKernelHook.CallbackOrderChanged(poolId, callback, order);
    }

    /// @notice Sets the operation depth and callback gas budgets of a pool.
    /// @dev See IKernelHook.setExecutionLimits.
    function setExecutionLimits(
        KernelHookState.State storage state,
        PoolKey calldata key,
        uint8 maxOperationDepth,
        uint32[CALLBACK_COUNT] calldata callbackGasBudgets
    ) public {
        PoolId poolId = KernelHookState.requireKnownPool(state, key);
        _requireConfigurer(state, poolId);
        _requireCallbacksInactive(state, poolId, CallbackLibrary.ALL_CALLBACKS_MASK);
        if (maxOperationDepth == 0) revert IKernelHook.InvalidExecutionLimits();
        if (maxOperationDepth > KernelHookConstants.MAX_OPERATION_DEPTH) revert IKernelHook.InvalidExecutionLimits();
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            // A budget must fit at least one extension call with the smallest gas limit.
            uint256 smallestCall = KernelHookState.invocationGas(KernelHookConstants.MIN_CALL_GAS, CallbackType(i), 0);
            uint256 smallestBudget = KernelHookConstants.RETURN_GAS_RESERVE + KernelHookConstants.SEQUENCE_GAS_RESERVE
                + KernelHookConstants.ITERATION_GAS_RESERVE + smallestCall;
            if (callbackGasBudgets[i] < smallestBudget) {
                revert IKernelHook.InvalidExecutionLimits();
            }
        }
        state.pools[poolId].maxOperationDepth = maxOperationDepth;
        state.pools[poolId].callbackGasBudgets = callbackGasBudgets;
        emit IKernelHook.ExecutionLimitsChanged(poolId, maxOperationDepth, callbackGasBudgets);
    }

    /// @notice Grants a pool role to an account.
    /// @dev See IKernelHook.grantPoolRole.
    function grantPoolRole(KernelHookState.State storage state, PoolKey calldata key, bytes32 role, address account)
        public
    {
        PoolId poolId = KernelHookState.requireKnownPool(state, key);
        _requireAdmin(state, poolId);
        _validateRole(role);
        if (account == address(0)) revert IKernelHook.InvalidRole();
        if (state.pools[poolId].status != PoolStatus.Initialized) {
            if (role == KernelHookConstants.POOL_ADMIN_ROLE) revert IKernelHook.InvalidRole();
        }
        if (!state.roles[poolId][role][account]) {
            state.roles[poolId][role][account] = true;
            if (role == KernelHookConstants.POOL_ADMIN_ROLE) ++state.pools[poolId].adminCount;
            emit IKernelHook.PoolRoleChanged(poolId, role, account, true);
        }
    }

    /// @notice Revokes a pool role without removing the last pool administrator.
    /// @dev See IKernelHook.revokePoolRole.
    function revokePoolRole(KernelHookState.State storage state, PoolKey calldata key, bytes32 role, address account)
        public
    {
        PoolId poolId = KernelHookState.requireKnownPool(state, key);
        _requireAdmin(state, poolId);
        _validateRole(role);
        if (!state.roles[poolId][role][account]) return;
        if (role == KernelHookConstants.POOL_ADMIN_ROLE) {
            if (state.pools[poolId].adminCount == 1) revert IKernelHook.LastAdmin();
            --state.pools[poolId].adminCount;
        }
        delete state.roles[poolId][role][account];
        emit IKernelHook.PoolRoleChanged(poolId, role, account, false);
    }

    function _requireInstallableEntry(
        address account,
        PoolStatus status,
        uint16 callbackMask,
        IHookCatalog.Entry memory entry
    ) private view {
        if (!entry.admitted) revert IKernelHook.ExtensionNotAdmitted();
        if (account.code.length == 0) revert IKernelHook.ExtensionCodeMismatch();
        if (entry.codeHash != account.codehash) revert IKernelHook.ExtensionCodeMismatch();
        if (status != PoolStatus.Initialized) return;
        if (!entry.supportsLateInstallation) revert IKernelHook.LateInstallationNotSupported();
        _requireInitializationCallbacksTimely(status, callbackMask);
    }

    function _requireInactiveInstallation(KernelHookState.Installation storage installation, address account)
        private
        view
    {
        if (installation.active) revert IKernelHook.ExtensionActive();
        if (account.codehash != installation.entry.codeHash) revert IKernelHook.ExtensionCodeMismatch();
    }

    function _requireInitializationCallbacksTimely(PoolStatus status, uint16 callbackMask) private pure {
        if (status != PoolStatus.Initialized) return;
        if (callbackMask & CallbackLibrary.INITIALIZATION_CALLBACKS_MASK != 0) {
            revert IKernelHook.InitializationCallbacksTooLate();
        }
    }

    function _requireInitializationCallbacksComplete(
        PoolStatus status,
        KernelHookState.Installation storage installation
    ) private view {
        if (status != PoolStatus.Initialized) return;
        if (installation.settings.optionalCallbacks) return;
        if (
            (installation.settings.callbackMask & CallbackLibrary.INITIALIZATION_CALLBACKS_MASK
                        & ~installation.completedInitializationCallbacks) != 0
        ) revert IKernelHook.InitializationCallbacksIncomplete();
    }

    function _requireActivationAccepted(
        address account,
        PoolKey calldata key,
        KernelHookState.Installation storage installation
    ) private view {
        (bool success, bytes memory response) = BoundedCall.tryStaticCall(
            account,
            installation.settings.lifecycleGasLimit,
            abi.encodeCall(IKernelHookExtension.canActivate, (key, installation.settings))
        );
        // tryStaticCall succeeds only with exactly one 32-byte word.
        if (!success) revert IKernelHook.ActivationRejected();
        if (!abi.decode(response, (bool))) revert IKernelHook.ActivationRejected();
    }

    function _requireBudgetsCoverMandatoryGas(KernelHookState.State storage state, PoolId poolId) private view {
        // i < CALLBACK_COUNT
        for (uint8 i; i < CALLBACK_COUNT; ++i) {
            // The reserves that the dispatch gas check keeps at the start of a callback sequence: the limits
            // of the active required callbacks, the return work, and the loop overhead of each subscriber.
            uint256 requiredGas = KernelHookState.mandatoryCallbackGas(state, poolId, CallbackType(i))
                + KernelHookConstants.RETURN_GAS_RESERVE + KernelHookConstants.SEQUENCE_GAS_RESERVE
                + state.callbackOrders[poolId][CallbackType(i)].length * KernelHookConstants.ITERATION_GAS_RESERVE;
            if (requiredGas > state.pools[poolId].callbackGasBudgets[i]) revert IKernelHook.GasBudgetExceeded();
        }
    }

    function _removeInstallation(KernelHookState.State storage state, PoolId poolId, address account) private {
        // Indices are compacted. The management lock guarantees that no operation, and so no
        // skippedExtensions bitmap, is live during removal.
        address[] storage accounts = state.pools[poolId].extensions;
        uint256 extensionIndex = state.installations[poolId][account].extensionIndex;
        // accounts.length <= MAX_EXTENSIONS
        for (uint256 i = extensionIndex; i + 1 < accounts.length; ++i) {
            accounts[i] = accounts[i + 1];
            state.installations[poolId][accounts[i]].extensionIndex = uint8(i);
        }
        accounts.pop();
        delete state.installations[poolId][account];
    }

    function _validateCallbackOrder(
        KernelHookState.State storage state,
        PoolId poolId,
        CallbackType callback,
        address[] calldata order
    ) private view {
        if (order.length != state.callbackOrders[poolId][callback].length) {
            revert IKernelHook.InvalidCallbackOrder();
        }
        uint32 seen;
        // order.length <= MAX_EXTENSIONS
        for (uint256 i; i < order.length; ++i) {
            KernelHookState.Installation storage installation =
                KernelHookState.requireInstalled(state, poolId, order[i]);
            if (!CallbackLibrary.includes(installation.settings.callbackMask, callback)) {
                revert IKernelHook.InvalidCallbackOrder();
            }
            uint32 bit = uint32(1) << installation.extensionIndex;
            if (seen & bit != 0) revert IKernelHook.InvalidCallbackOrder();
            seen |= bit;
        }
    }

    function _validateSettings(ExtensionSettings calldata settings, IHookCatalog.Entry memory entry) private pure {
        _validateCallbackMask(settings.callbackMask, entry.callbackMask);
        if (settings.configuration.length > KernelHookConstants.MAX_CONFIGURATION_BYTES) {
            revert IKernelHook.ConfigurationTooLarge();
        }
        _validateCapabilities(settings, entry);
        _validateGasLimits(settings);
    }

    function _validateCallbackMask(uint16 callbackMask, uint16 supportedCallbackMask) private pure {
        if (callbackMask == 0) revert IKernelHook.InvalidCallbackMask();
        if (callbackMask & ~supportedCallbackMask != 0) revert IKernelHook.InvalidCallbackMask();
    }

    function _validateCapabilities(ExtensionSettings calldata settings, IHookCatalog.Entry memory entry) private pure {
        if (settings.optionalCallbacks) {
            if (!entry.supportsOptionalCallbacks) revert IKernelHook.UnsupportedCapability();
        }
        if (settings.allowNesting) {
            if (!entry.supportsNesting) revert IKernelHook.UnsupportedCapability();
        }
    }

    function _validateGasLimits(ExtensionSettings calldata settings) private pure {
        _requireGasLimitInRange(settings.lifecycleGasLimit);
        // i < CALLBACK_COUNT
        for (uint8 i; i < CALLBACK_COUNT; ++i) {
            if (!CallbackLibrary.includes(settings.callbackMask, CallbackType(i))) continue;
            _requireGasLimitInRange(settings.callbackGasLimits[i]);
        }
    }

    function _requireGasLimitInRange(uint256 gasLimit) private pure {
        if (gasLimit < KernelHookConstants.MIN_CALL_GAS) revert IKernelHook.GasLimitOutOfRange();
        if (gasLimit > KernelHookConstants.MAX_CALL_GAS) revert IKernelHook.GasLimitOutOfRange();
    }

    function _requireCallbacksInactive(KernelHookState.State storage state, PoolId poolId, uint16 callbackMask)
        private
        view
    {
        // i < CALLBACK_COUNT
        for (uint8 i; i < CALLBACK_COUNT; ++i) {
            if (!CallbackLibrary.includes(callbackMask, CallbackType(i))) continue;
            _requireSubscribersInactive(state, poolId, state.callbackOrders[poolId][CallbackType(i)]);
        }
    }

    function _requireSubscribersInactive(KernelHookState.State storage state, PoolId poolId, address[] storage order)
        private
        view
    {
        // order.length <= MAX_EXTENSIONS
        for (uint256 i; i < order.length; ++i) {
            if (state.installations[poolId][order[i]].active) revert IKernelHook.SubscribersActive();
        }
    }

    function _subscribe(KernelHookState.State storage state, PoolId poolId, address account, uint16 callbackMask)
        private
    {
        // i < CALLBACK_COUNT
        for (uint8 i; i < CALLBACK_COUNT; ++i) {
            if (!CallbackLibrary.includes(callbackMask, CallbackType(i))) continue;
            state.callbackOrders[poolId][CallbackType(i)].push(account);
        }
    }

    function _unsubscribe(KernelHookState.State storage state, PoolId poolId, address account, uint16 callbackMask)
        private
    {
        // i < CALLBACK_COUNT
        for (uint8 i; i < CALLBACK_COUNT; ++i) {
            if (!CallbackLibrary.includes(callbackMask, CallbackType(i))) continue;
            _removeFromCallbackOrder(state.callbackOrders[poolId][CallbackType(i)], account);
        }
    }

    function _removeFromCallbackOrder(address[] storage order, address account) private {
        // order.length <= MAX_EXTENSIONS
        for (uint256 j; j < order.length; ++j) {
            if (order[j] != account) continue;
            // order.length <= MAX_EXTENSIONS
            for (uint256 k = j; k + 1 < order.length; ++k) {
                order[k] = order[k + 1];
            }
            order.pop();
            return;
        }
    }

    function _requireRemovable(
        KernelHookVault vault,
        KernelRouteExecutor routeExecutor,
        PoolId poolId,
        address account,
        PoolKey calldata key,
        uint256 gasLimit
    ) private view {
        if (vault.fundedCurrencyCount(poolId, account) != 0) {
            revert IKernelHook.OutstandingObligations();
        }
        if (routeExecutor.openPositionCount(poolId, account) != 0) revert IKernelHook.OutstandingObligations();
        (bool success, bytes memory response) =
            BoundedCall.tryStaticCall(account, gasLimit, abi.encodeCall(IKernelHookExtension.canUninstall, (key)));
        // tryStaticCall succeeds only with exactly one 32-byte word.
        if (!success) revert IKernelHook.OutstandingObligations();
        if (!abi.decode(response, (bool))) revert IKernelHook.OutstandingObligations();
    }

    /// @dev BoundedCall limits copied return and revert data so lifecycle hooks cannot exhaust gas with large payloads.
    function _callLifecycleHook(address account, uint256 gasLimit, bytes memory data, bytes4 expected) private {
        (bool success, bytes memory response) =
            BoundedCall.tryCall(account, gasLimit, data, KernelHookConstants.ABI_WORD_BYTES);
        // tryCall succeeds only with exactly one 32-byte word.
        if (!success) revert IKernelHook.InvalidResponse();
        if (abi.decode(response, (bytes4)) != expected) revert IKernelHook.InvalidResponse();
    }

    function _requireAdmin(KernelHookState.State storage state, PoolId poolId) private view {
        if (state.pools[poolId].status == PoolStatus.Prepared) {
            if (msg.sender != state.pools[poolId].initializer) revert IKernelHook.Unauthorized();
        } else if (!state.roles[poolId][KernelHookConstants.POOL_ADMIN_ROLE][msg.sender]) {
            revert IKernelHook.Unauthorized();
        }
    }

    function _requireConfigurer(KernelHookState.State storage state, PoolId poolId) private view {
        if (!state.roles[poolId][KernelHookConstants.CONFIGURER_ROLE][msg.sender]) _requireAdmin(state, poolId);
    }

    function _validateRole(bytes32 role) private pure {
        if (role == KernelHookConstants.POOL_ADMIN_ROLE) return;
        if (role != KernelHookConstants.CONFIGURER_ROLE) revert IKernelHook.InvalidRole();
    }
}
