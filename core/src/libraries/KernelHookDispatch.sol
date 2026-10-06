// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "../interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "../interfaces/IKernelHookExtension.sol";
import {KernelHookVault} from "../KernelHookVault.sol";
import {CallbackResult, CallbackType} from "../types/KernelHookTypes.sol";
import {BoundedCall} from "./BoundedCall.sol";
import {CallbackLibrary} from "./CallbackLibrary.sol";
import {KernelHookConstants} from "./KernelHookConstants.sol";
import {KernelHookState} from "./KernelHookState.sol";
import {KernelHookOperations, OperationFrame} from "./KernelHookOperations.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Runs the extensions of a callback in order, each in its own rollback scope.
/// @dev An external library: KernelHook delegatecalls it, which keeps KernelHook below the contract size limit.
library KernelHookDispatch {
    using LPFeeLibrary for uint24;
    using CallbackLibrary for CallbackType;

    struct CallbackSequence {
        PoolKey key;
        bytes data;
        CallbackResult aggregate;
        /// @dev What invokeExtension needs besides the arguments of one extension call.
        uint256 stateSlot;
        IPoolManager manager;
        KernelHookVault vault;
        /// @dev The address of this library, which the dispatch loop delegatecalls for each extension.
        address dispatch;
    }

    /// @notice Calls one extension, validates its result, and settles its deltas in one rollback scope.
    /// @dev The dispatch loop delegatecalls this function in KernelHook's context, with the invocation gas. If it
    /// reverts, the extension call, the validation and the settlement all roll back together. Solidity's library call
    /// protection rejects a direct call, and KernelHook has no other path to this function. The arguments stay in
    /// calldata; only the pool key is copied into memory, to compute its pool id.
    /// @param stateSlot The storage slot of KernelHook's pool and installation state
    /// @param manager The PoolManager whose deltas are settled
    /// @param vault The vault holding the installation's funds
    /// @param extension The extension to call
    /// @param key The pool key of the current operation
    /// @param data The encoded callback arguments
    /// @param aggregate The sum of the results of the extensions that ran earlier in this callback
    /// @return next The accumulated result including this extension
    function invokeExtension(
        uint256 stateSlot,
        IPoolManager manager,
        KernelHookVault vault,
        address extension,
        PoolKey calldata key,
        bytes calldata data,
        CallbackResult calldata aggregate
    ) external returns (CallbackResult memory next) {
        KernelHookState.State storage state;
        assembly ("memory-safe") {
            state.slot := stateSlot
        }
        // Paired assertions: the operation opened a frame, and _attemptExtension set its extension before this call.
        if (KernelHookOperations.frameCount() == 0) revert IKernelHook.Unauthorized();
        OperationFrame frame = KernelHookOperations.currentFrame();
        if (frame.extension() != extension) revert IKernelHook.Unauthorized();
        // A nested operation pushes its frames above this frame and pops back to it, and only this operation's own
        // runCallbacks sets its callback, so poolId and callback stay the same across the extension call.
        PoolId poolId = frame.poolId();
        CallbackType callback = frame.callback();
        if (PoolId.unwrap(poolId) != PoolId.unwrap(key.toId())) revert IKernelHook.Unauthorized();
        KernelHookState.Installation storage installation = state.installations[poolId][extension];
        if (extension.codehash != installation.entry.codeHash) revert IKernelHook.ExtensionCodeMismatch();
        KernelHookOperations.enterInvocation(poolId, extension);
        CallbackResult memory result = _callExtension(installation, extension, key, data, callback);
        next = _accumulate(aggregate, result);
        _validateResult(frame, callback, key, data, result, next);
        _settleExtensionDelta(manager, vault, poolId, extension, key.currency0, result.delta0);
        _settleExtensionDelta(manager, vault, poolId, extension, key.currency1, result.delta1);
        if (callback.isInitialization()) {
            installation.completedInitializationCallbacks |= callback.mask();
        }
        KernelHookOperations.exitInvocation(poolId, extension);
    }

    function _callExtension(
        KernelHookState.Installation storage installation,
        address extension,
        PoolKey calldata key,
        bytes calldata data,
        CallbackType callback
    ) private returns (CallbackResult memory) {
        bytes memory input = abi.encodeCall(
            IKernelHookExtension.onCallback, (KernelHookOperations.context(), key, data)
        );
        uint256 gasLimit = installation.settings.callbackGasLimits[uint8(callback)];
        // The invocation gas of this delegatecall covers the work before this point and the 1/64 that the EVM keeps
        // back, so the extension receives its whole gas limit. Less gas would charge KernelHook's cost to it.
        if (gasleft() < gasLimit + gasLimit / 63 + KernelHookConstants.COLD_CALL_GAS) {
            revert IKernelHook.GasBudgetExceeded();
        }
        // BoundedCall caps return and revert data so extension payloads cannot exhaust the caller's gas.
        (bool success, bytes memory response) =
            BoundedCall.tryCall(extension, gasLimit, input, KernelHookConstants.CALLBACK_RESULT_BYTES);
        // Pass the extension's revert data on unchanged. The dispatch loop adds the extension and the callback once:
        // in ExtensionFailed for a required extension, or in ExtensionSkipped for an optional one.
        if (!success) {
            assembly ("memory-safe") {
                revert(add(response, 32), mload(response))
            }
        }
        return abi.decode(response, (CallbackResult));
    }

    function _accumulate(CallbackResult calldata aggregate, CallbackResult memory result)
        private
        pure
        returns (CallbackResult memory next)
    {
        next = CallbackResult(aggregate.delta0 + result.delta0, aggregate.delta1 + result.delta1, aggregate.feeOverride);
        if (result.feeOverride != 0) {
            if (aggregate.feeOverride != 0) revert IKernelHook.MultipleFeeOverrides();
            next.feeOverride = result.feeOverride;
        }
    }

    /// @notice Runs the active subscribers of one callback in their configured order.
    /// @param state The pool, installation, and callback-order state
    /// @param manager The PoolManager whose deltas are settled
    /// @param vault The vault holding the installations' funds
    /// @param dispatch The address of this library
    /// @param key The pool key of the current operation
    /// @param callback The callback to run
    /// @param data The encoded callback arguments
    /// @return aggregate The accumulated result of successful extension attempts
    function runCallbacks(
        KernelHookState.State storage state,
        IPoolManager manager,
        KernelHookVault vault,
        address dispatch,
        PoolKey calldata key,
        CallbackType callback,
        bytes memory data
    ) public returns (CallbackResult memory aggregate) {
        OperationFrame frame = KernelHookOperations.currentFrame();
        frame.setCallback(callback);
        // The budget counts the sequence's gas from here, including the read of the callback order.
        uint256 startGas = gasleft();
        address[] storage order = state.callbackOrders[frame.poolId()][callback];
        // A callback without subscribers runs no extension, so its result is zero. The other sequence fields of the
        // frame are read only while an extension of this sequence runs, so they stay unread until the next sequence
        // or the end of the operation.
        if (order.length == 0) return aggregate;
        frame.setCallbackStartGas(startGas);
        frame.setCallbackGasBudget(state.pools[frame.poolId()].callbackGasBudgets[uint8(callback)]);
        frame.setRemainingMandatoryGas(KernelHookState.mandatoryCallbackGas(state, frame.poolId(), callback));
        uint256 stateSlot;
        assembly ("memory-safe") {
            stateSlot := state.slot
        }
        CallbackSequence memory sequence = CallbackSequence(key, data, aggregate, stateSlot, manager, vault, dispatch);
        // order.length <= MAX_EXTENSIONS
        for (uint256 i; i < order.length; ++i) {
            _attemptExtension(state, sequence, order[i], order.length - i - 1);
        }
        frame.setExtension(address(0));
        if (frame.callbackStartGas() - gasleft() > frame.callbackGasBudget()) revert IKernelHook.GasBudgetExceeded();
        return sequence.aggregate;
    }

    function _attemptExtension(
        KernelHookState.State storage state,
        CallbackSequence memory sequence,
        address extension,
        uint256 remainingCount
    ) private {
        OperationFrame frame = KernelHookOperations.currentFrame();
        KernelHookState.Installation storage installation = state.installations[frame.poolId()][extension];
        uint32 bit = uint32(1) << installation.extensionIndex;
        if (!installation.active) return;
        if (frame.skippedExtensions() & bit != 0) return;
        bool optional = installation.settings.optionalCallbacks;
        if (!_passesReentrancyRule(frame, installation, extension, bit, optional)) return;

        CallbackType callback = frame.callback();
        uint256 invocationGas =
            KernelHookState.invocationGas(installation.settings.callbackGasLimits[uint8(callback)], callback);
        bytes memory input = _invocationInput(sequence, extension);
        if (!_admitCallbackGas(frame, extension, bit, invocationGas, optional, remainingCount)) return;

        // Validation and settlement share this delegatecall with the extension callback.
        // If it fails, all effects of that extension roll back before an optional skip.
        frame.setExtension(extension);
        (bool success, bytes memory response) = BoundedCall.tryDelegateCall(
            sequence.dispatch, invocationGas, input, KernelHookConstants.CALLBACK_RESULT_BYTES
        );
        frame.setExtension(address(0));
        // tryDelegateCall succeeds only if the response is exactly one CallbackResult.
        if (!success) {
            _handleAttemptFailure(frame, extension, bit, optional, response);
            return;
        }
        sequence.aggregate = abi.decode(response, (CallbackResult));
        if (!optional) frame.setRemainingMandatoryGas(frame.remainingMandatoryGas() - invocationGas);
    }

    /// @dev abi.encodeCall cannot take a library function, so these arguments must follow the parameters of
    /// invokeExtension in order. A swap of the manager and the vault shows only when an extension returns a delta;
    /// the settlement tests (fee credits and debts) cover that. A wrong order of any other arguments fails the checks
    /// at the start of invokeExtension or the decoding.
    function _invocationInput(CallbackSequence memory sequence, address extension) private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            KernelHookDispatch.invokeExtension.selector,
            sequence.stateSlot,
            sequence.manager,
            sequence.vault,
            extension,
            sequence.key,
            sequence.data,
            sequence.aggregate
        );
    }

    function _passesReentrancyRule(
        OperationFrame frame,
        KernelHookState.Installation storage installation,
        address extension,
        uint32 bit,
        bool optional
    ) private returns (bool) {
        if (KernelHookOperations.activeInvocations(frame.poolId(), extension) == 0) return true;
        if (!optional) {
            if (!installation.entry.supportsReentrancy) revert IKernelHook.ReentrancyDenied();
            return true;
        }
        _skipExtension(frame, extension, bit, abi.encodePacked(IKernelHook.ReentrancyDenied.selector));
        return false;
    }

    function _admitCallbackGas(
        OperationFrame frame,
        address extension,
        uint32 bit,
        uint256 invocationGas,
        bool optional,
        uint256 remainingCount
    ) private returns (bool) {
        if (_hasCallbackGas(frame, invocationGas, optional, remainingCount)) return true;
        if (!optional) revert IKernelHook.GasBudgetExceeded();
        _skipExtension(frame, extension, bit, abi.encodePacked(IKernelHook.GasBudgetExceeded.selector));
        return false;
    }

    function _handleAttemptFailure(
        OperationFrame frame,
        address extension,
        uint32 bit,
        bool optional,
        bytes memory response
    ) private {
        if (!optional) revert IKernelHook.ExtensionFailed(extension, frame.callback(), response);
        // A failed optional after attempt rolls back only that attempt,
        // preserving an earlier successful before attempt.
        _skipExtension(frame, extension, bit, response);
    }

    function _hasCallbackGas(OperationFrame frame, uint256 invocationGas, bool optional, uint256 remainingCount)
        private
        view
        returns (bool)
    {
        // Keep gas for returning to the PoolManager, mandatory callbacks still to run,
        // and the overhead of each remaining iteration.
        uint256 reserveGas = KernelHookConstants.RETURN_GAS_RESERVE + frame.remainingMandatoryGas() + remainingCount
            * KernelHookConstants.ITERATION_GAS_RESERVE;
        // The current mandatory call is charged below, so it must not also remain in the reserve.
        if (!optional) reserveGas -= invocationGas;
        uint256 spentGas = frame.callbackStartGas() - gasleft();
        if (spentGas + invocationGas + reserveGas > frame.callbackGasBudget()) return false;
        uint256 availableGas = gasleft();
        // Allow EIP-150 forwarding headroom (a call receives at most 63/64 of the remaining gas) for this call, and
        // for the later required calls in the reserve, so that this call cannot take their headroom.
        uint256 forwardingGas = invocationGas + invocationGas / 63 + reserveGas + reserveGas / 63;
        return availableGas >= forwardingGas;
    }

    function _validateResult(
        OperationFrame frame,
        CallbackType callback,
        PoolKey calldata key,
        bytes calldata data,
        CallbackResult memory result,
        CallbackResult memory aggregate
    ) private view {
        if (callback == CallbackType.BeforeSwap) {
            _validateBeforeSwapResult(key, data, result, aggregate);
            return;
        }
        if (callback == CallbackType.AfterSwap) {
            _validateAfterSwapResult(frame, data, result, aggregate);
            return;
        }
        _validateNonSwapResult(callback, result);
    }

    function _validateBeforeSwapResult(
        PoolKey calldata key,
        bytes calldata data,
        CallbackResult memory result,
        CallbackResult memory aggregate
    ) private pure {
        (SwapParams memory swapParameters,) = abi.decode(data, (SwapParams, bytes));
        bool specifiedIsCurrency0 = (swapParameters.amountSpecified < 0) == swapParameters.zeroForOne;
        int128 specified = specifiedIsCurrency0 ? aggregate.delta0 : aggregate.delta1;
        int256 amount = swapParameters.amountSpecified + specified;
        if (swapParameters.amountSpecified < 0 ? amount > 0 : amount < 0) revert IKernelHook.DeltaExceedsSwapAmount();
        if (result.feeOverride == 0) return;
        if (!key.fee.isDynamicFee()) revert IKernelHook.InvalidFeeOverride();
        if (!result.feeOverride.isOverride()) revert IKernelHook.InvalidFeeOverride();
        result.feeOverride.removeOverrideFlagAndValidate();
    }

    function _validateAfterSwapResult(
        OperationFrame frame,
        bytes calldata data,
        CallbackResult memory result,
        CallbackResult memory aggregate
    ) private view {
        (SwapParams memory swapParameters,,) = abi.decode(data, (SwapParams, BalanceDelta, bytes));
        bool specifiedIsCurrency0 = (swapParameters.amountSpecified < 0) == swapParameters.zeroForOne;
        int128 specified = specifiedIsCurrency0 ? aggregate.delta0 : aggregate.delta1;
        int128 unspecified = specifiedIsCurrency0 ? aggregate.delta1 : aggregate.delta0;
        if (specified != 0) revert IKernelHook.InvalidDelta();
        if (result.feeOverride != 0) revert IKernelHook.InvalidFeeOverride();
        // Uniswap combines these deltas after the callback returns, so their sum must still fit.
        int256 combined = int256(frame.beforeSwapUnspecifiedDelta()) + int256(unspecified);
        if (combined > type(int128).max) revert IKernelHook.DeltaOverflow();
        if (combined < type(int128).min) revert IKernelHook.DeltaOverflow();
    }

    function _validateNonSwapResult(CallbackType callback, CallbackResult memory result) private pure {
        // The after-liquidity callbacks may return deltas. The other callbacks may return nothing.
        bool isAfterLiquidity =
            callback == CallbackType.AfterAddLiquidity || callback == CallbackType.AfterRemoveLiquidity;
        if (isAfterLiquidity) {
            if (result.feeOverride != 0) revert IKernelHook.InvalidFeeOverride();
            return;
        }
        if (result.delta0 != 0) revert IKernelHook.InvalidDelta();
        if (result.delta1 != 0) revert IKernelHook.InvalidDelta();
        if (result.feeOverride != 0) revert IKernelHook.InvalidFeeOverride();
    }

    function _settleExtensionDelta(
        IPoolManager manager,
        KernelHookVault vault,
        PoolId poolId,
        address extension,
        Currency currency,
        int128 delta
    ) private {
        if (delta > 0) {
            manager.take(currency, address(vault), uint256(int256(delta)));
            vault.credit(poolId, extension, currency, uint256(int256(delta)));
        } else if (delta < 0) {
            vault.settleDebtFor(poolId, extension, currency, uint256(-int256(delta)), address(this));
        }
    }

    function _skipExtension(OperationFrame frame, address extension, uint32 bit, bytes memory reason) private {
        // A skip lasts through the rest of this operation, including its after callback.
        frame.setSkippedExtensions(frame.skippedExtensions() | bit);
        emit IKernelHook.ExtensionSkipped(frame.poolId(), extension, frame.callback(), reason);
    }
}
