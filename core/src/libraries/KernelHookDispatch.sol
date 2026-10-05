// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "../interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "../interfaces/IKernelHookExtension.sol";
import {IKernelCallbackRunner} from "../interfaces/callback/IKernelCallbackRunner.sol";
import {KernelHookVault} from "../KernelHookVault.sol";
import {CallbackResult, CallbackType} from "../types/KernelHookTypes.sol";
import {BoundedCall} from "./BoundedCall.sol";
import {CallbackLibrary} from "./CallbackLibrary.sol";
import {KernelHookConstants} from "./KernelHookConstants.sol";
import {KernelHookState} from "./KernelHookState.sol";
import {KernelHookOperations} from "./KernelHookOperations.sol";
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

    struct Invocation {
        address extension;
        PoolKey key;
        bytes data;
        CallbackResult aggregate;
    }

    struct CallbackSequence {
        PoolKey key;
        bytes data;
        CallbackResult aggregate;
    }

    /// @notice Calls one extension, validates its result, and settles its deltas in one rollback scope.
    /// @param state The pool and installation state
    /// @param runtime The operation stack and active invocation counts
    /// @param manager The PoolManager whose deltas are settled
    /// @param vault The vault holding the installation's funds
    /// @param invocation The extension, callback arguments, and accumulated result
    /// @return next The accumulated result including this extension
    function invokeExtension(
        KernelHookState.State storage state,
        KernelHookOperations.Runtime storage runtime,
        IPoolManager manager,
        KernelHookVault vault,
        Invocation memory invocation
    ) external returns (CallbackResult memory next) {
        if (msg.sender != address(this)) revert IKernelHook.Unauthorized();
        if (runtime.frames.length == 0) revert IKernelHook.Unauthorized();
        KernelHookOperations.OperationFrame storage frame = KernelHookOperations.currentFrame(runtime);
        address extension = invocation.extension;
        if (frame.extension != extension) revert IKernelHook.Unauthorized();
        if (PoolId.unwrap(frame.poolId) != PoolId.unwrap(invocation.key.toId())) revert IKernelHook.Unauthorized();
        KernelHookState.Installation storage installation = state.installations[frame.poolId][extension];
        if (extension.codehash != installation.entry.codeHash) revert IKernelHook.ExtensionCodeMismatch();
        ++runtime.activeInvocations[frame.poolId][extension];
        CallbackResult memory result = _callExtension(runtime, installation, invocation);
        next = _accumulate(invocation.aggregate, result);
        _validateResult(frame, invocation.key, invocation.data, result, next);
        _settleExtensionDelta(manager, vault, frame.poolId, extension, invocation.key.currency0, result.delta0);
        _settleExtensionDelta(manager, vault, frame.poolId, extension, invocation.key.currency1, result.delta1);
        if (frame.callback.isInitialization()) installation.completedInitializationCallbacks |= frame.callback.mask();
        --runtime.activeInvocations[frame.poolId][extension];
    }

    function _callExtension(
        KernelHookOperations.Runtime storage runtime,
        KernelHookState.Installation storage installation,
        Invocation memory invocation
    ) private returns (CallbackResult memory) {
        // BoundedCall caps return and revert data so extension payloads cannot exhaust the caller's gas.
        (bool success, bytes memory response) = BoundedCall.tryCall(
            invocation.extension,
            gasleft(),
            abi.encodeCall(
                IKernelHookExtension.onCallback,
                (
                    KernelHookOperations.context(runtime),
                    invocation.key,
                    installation.settings.configuration,
                    invocation.data
                )
            ),
            KernelHookConstants.CALLBACK_RESULT_BYTES
        );
        if (!success) {
            revert IKernelHook.ExtensionFailed(
                invocation.extension, KernelHookOperations.currentFrame(runtime).callback, response
            );
        }
        return abi.decode(response, (CallbackResult));
    }

    function _accumulate(CallbackResult memory aggregate, CallbackResult memory result)
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
    /// @param runtime The operation stack and active invocation counts
    /// @param key The pool key of the current operation
    /// @param callback The callback to run
    /// @param data The encoded callback arguments
    /// @return aggregate The accumulated result of successful extension attempts
    function runCallbacks(
        KernelHookState.State storage state,
        KernelHookOperations.Runtime storage runtime,
        PoolKey calldata key,
        CallbackType callback,
        bytes memory data
    ) public returns (CallbackResult memory aggregate) {
        KernelHookOperations.OperationFrame storage frame = KernelHookOperations.currentFrame(runtime);
        frame.callback = callback;
        frame.callbackStartGas = gasleft();
        frame.callbackGasBudget = state.pools[frame.poolId].callbackGasBudgets[uint8(callback)];
        frame.remainingMandatoryGas = KernelHookState.mandatoryCallbackGas(state, frame.poolId, callback);
        address[] storage order = state.callbackOrders[frame.poolId][callback];
        CallbackSequence memory sequence = CallbackSequence(key, data, aggregate);
        // order.length <= MAX_EXTENSIONS
        for (uint256 i; i < order.length; ++i) {
            _attemptExtension(state, runtime, sequence, order[i], order.length - i - 1);
        }
        frame.extension = address(0);
        if (frame.callbackStartGas - gasleft() > frame.callbackGasBudget) revert IKernelHook.GasBudgetExceeded();
        return sequence.aggregate;
    }

    function _attemptExtension(
        KernelHookState.State storage state,
        KernelHookOperations.Runtime storage runtime,
        CallbackSequence memory sequence,
        address extension,
        uint256 remainingCount
    ) private {
        KernelHookOperations.OperationFrame storage frame = KernelHookOperations.currentFrame(runtime);
        KernelHookState.Installation storage installation = state.installations[frame.poolId][extension];
        uint32 bit = uint32(1) << installation.extensionIndex;
        if (!installation.active) return;
        if (frame.skippedExtensions & bit != 0) return;
        bool optional = installation.settings.optionalCallbacks;
        if (!_passesReentrancyRule(runtime, frame, installation, extension, bit, optional)) return;

        uint256 gasLimit = installation.settings.callbackGasLimits[uint8(frame.callback)];
        bytes memory input = abi.encodeCall(
            IKernelCallbackRunner.invokeExtension, (extension, sequence.key, sequence.data, sequence.aggregate)
        );
        if (!_admitCallbackGas(frame, extension, bit, gasLimit, optional, remainingCount)) return;

        // Validation and settlement share this self-call with the extension callback.
        // If it fails, all effects of that extension roll back before an optional skip.
        frame.extension = extension;
        (bool success, bytes memory response) =
            BoundedCall.tryCall(address(this), gasLimit, input, KernelHookConstants.CALLBACK_RESULT_BYTES);
        frame.extension = address(0);
        // tryCall succeeds only if the response is exactly one CallbackResult.
        if (!success) {
            _handleAttemptFailure(frame, extension, bit, optional, response);
            return;
        }
        sequence.aggregate = abi.decode(response, (CallbackResult));
        if (!optional) frame.remainingMandatoryGas -= gasLimit;
    }

    function _passesReentrancyRule(
        KernelHookOperations.Runtime storage runtime,
        KernelHookOperations.OperationFrame storage frame,
        KernelHookState.Installation storage installation,
        address extension,
        uint32 bit,
        bool optional
    ) private returns (bool) {
        if (runtime.activeInvocations[frame.poolId][extension] == 0) return true;
        if (!optional) {
            if (!installation.entry.supportsReentrancy) revert IKernelHook.ReentrancyDenied();
            return true;
        }
        _skipExtension(frame, extension, bit, abi.encodePacked(IKernelHook.ReentrancyDenied.selector));
        return false;
    }

    function _admitCallbackGas(
        KernelHookOperations.OperationFrame storage frame,
        address extension,
        uint32 bit,
        uint256 gasLimit,
        bool optional,
        uint256 remainingCount
    ) private returns (bool) {
        if (_hasCallbackGas(frame, gasLimit, optional, remainingCount)) return true;
        if (!optional) revert IKernelHook.GasBudgetExceeded();
        _skipExtension(frame, extension, bit, abi.encodePacked(IKernelHook.GasBudgetExceeded.selector));
        return false;
    }

    function _handleAttemptFailure(
        KernelHookOperations.OperationFrame storage frame,
        address extension,
        uint32 bit,
        bool optional,
        bytes memory response
    ) private {
        if (!optional) revert IKernelHook.ExtensionFailed(extension, frame.callback, response);
        // A failed optional after attempt rolls back only that attempt,
        // preserving an earlier successful before attempt.
        _skipExtension(frame, extension, bit, response);
    }

    function _hasCallbackGas(
        KernelHookOperations.OperationFrame storage frame,
        uint256 gasLimit,
        bool optional,
        uint256 remainingCount
    ) private view returns (bool) {
        // Keep gas for returning to the PoolManager, mandatory callbacks still to run,
        // and the overhead of each remaining iteration.
        uint256 reserveGas = KernelHookConstants.RETURN_GAS_RESERVE + frame.remainingMandatoryGas + remainingCount
            * KernelHookConstants.ITERATION_GAS_RESERVE;
        // The current mandatory limit is charged below, so it must not also remain in the reserve.
        if (!optional) reserveGas -= gasLimit;
        uint256 spentGas = frame.callbackStartGas - gasleft();
        if (spentGas + gasLimit + reserveGas > frame.callbackGasBudget) return false;
        uint256 availableGas = gasleft();
        // Allow EIP-150 forwarding headroom (a call receives at most 63/64 of the remaining gas) in addition
        // to the reserve for the work after the call.
        uint256 forwardingGas = gasLimit + gasLimit / 63 + reserveGas;
        return availableGas >= forwardingGas;
    }

    function _validateResult(
        KernelHookOperations.OperationFrame storage frame,
        PoolKey memory key,
        bytes memory data,
        CallbackResult memory result,
        CallbackResult memory aggregate
    ) private view {
        if (frame.callback == CallbackType.BeforeSwap) {
            _validateBeforeSwapResult(key, data, result, aggregate);
            return;
        }
        if (frame.callback == CallbackType.AfterSwap) {
            _validateAfterSwapResult(frame, data, result, aggregate);
            return;
        }
        _validateNonSwapResult(frame.callback, result);
    }

    function _validateBeforeSwapResult(
        PoolKey memory key,
        bytes memory data,
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
        KernelHookOperations.OperationFrame storage frame,
        bytes memory data,
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
        int256 combined = int256(frame.beforeSwapUnspecifiedDelta) + int256(unspecified);
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

    function _skipExtension(
        KernelHookOperations.OperationFrame storage frame,
        address extension,
        uint32 bit,
        bytes memory reason
    ) private {
        // A skip lasts through the rest of this operation, including its after callback.
        frame.skippedExtensions |= bit;
        emit IKernelHook.ExtensionSkipped(frame.poolId, extension, frame.callback, reason);
    }
}
