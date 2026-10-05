// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "../interfaces/IKernelHook.sol";
import {CallbackType, ExecutionContext} from "../types/KernelHookTypes.sol";
import {CallbackLibrary} from "./CallbackLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice The runtime stack of operations in progress, and the tickets of nested route actions.
/// @dev See the execution model in IKernelHook. The stack is empty between transactions.
library KernelHookOperations {
    using CallbackLibrary for CallbackType;

    /// @notice One operation in progress: a PoolManager call between its before and after callback.
    struct OperationFrame {
        PoolId poolId;
        /// @dev The PoolManager caller. For a nested action, this is the route executor.
        address sender;
        /// @dev The extension whose callback runs now, or address(0) between callbacks.
        address extension;
        uint64 operationId;
        /// @dev The before callback that opened this frame.
        CallbackType beforeCallback;
        /// @dev The callback sequence that runs now (the before or the after callback).
        CallbackType callback;
        /// @dev KernelHookOperations.actionHash of the operation; the after callback must match it.
        bytes32 actionHash;
        /// @dev gasleft() when the current callback sequence started.
        uint256 callbackStartGas;
        /// @dev The pool's gas budget for the current callback sequence.
        uint256 callbackGasBudget;
        /// @dev The callback gas limits of the required extensions that have not run yet in this sequence.
        uint256 remainingMandatoryGas;
        /// @dev Bit i is set if the optional extension with extensionIndex i is skipped for the rest of the operation.
        uint32 skippedExtensions;
        /// @dev The unspecified-currency delta that the beforeSwap callbacks returned.
        int128 beforeSwapUnspecifiedDelta;
        /// @dev True for the synthetic frame of unwindPositions, which is not a PoolManager operation.
        bool isExitContext;
    }

    /// @notice Permission for the next before callback to belong to one authorized nested action.
    struct ActionTicket {
        bytes32 actionHash;
        /// @dev The number of frames when the action was authorized.
        uint256 parentDepth;
        /// @dev True until the before callback of the action consumes the ticket.
        bool awaitingBeforeCallback;
    }

    struct Runtime {
        /// @dev frames.length <= MAX_OPERATION_DEPTH + 1 (the extra frame is the synthetic exit frame).
        OperationFrame[] frames;
        ActionTicket[] tickets;
        /// @dev The number of calls in progress for each installation, to detect reentrancy.
        mapping(PoolId => mapping(address => uint256)) activeInvocations;
        uint64 lastOperationId;
        /// @dev True during a management call, so that no pool operation can start inside it.
        bool managementInProgress;
    }

    /// @notice Reverts unless no management call, operation or ticket is in progress.
    /// @dev KernelHook also checks the vault, which is a separate contract.
    function requireIdle(Runtime storage runtime) internal view {
        if (runtime.managementInProgress) revert IKernelHook.ExecutionInProgress();
        if (runtime.frames.length != 0) revert IKernelHook.ExecutionInProgress();
        if (runtime.tickets.length != 0) revert IKernelHook.ExecutionInProgress();
    }

    /// @notice Opens the frame of an operation, from its before callback.
    function pushFrame(
        Runtime storage runtime,
        PoolId poolId,
        address sender,
        CallbackType beforeCallback,
        bytes32 hash
    ) internal {
        OperationFrame storage frame = runtime.frames.push();
        frame.poolId = poolId;
        frame.sender = sender;
        frame.operationId = ++runtime.lastOperationId;
        frame.beforeCallback = beforeCallback;
        frame.actionHash = hash;
    }

    /// @notice Opens the synthetic root frame of unwindPositions.
    /// @dev It is not a PoolManager operation. The extension is both its sender and its active extension, so
    /// that authorizeAction accepts the extension's nested actions. Its callback is AfterRemoveLiquidity, an
    /// after callback with no required gas left, so that those actions may enter this frame's own pool.
    function pushExitFrame(Runtime storage runtime, PoolId poolId, address extension) internal {
        OperationFrame storage frame = runtime.frames.push();
        frame.poolId = poolId;
        frame.sender = extension;
        frame.extension = extension;
        frame.operationId = ++runtime.lastOperationId;
        frame.callback = CallbackType.AfterRemoveLiquidity;
        frame.isExitContext = true;
    }

    /// @notice Closes the innermost frame: from its after callback, or at the end of unwindPositions.
    function popFrame(Runtime storage runtime) internal {
        runtime.frames.pop();
    }

    /// @notice Reverts unless an after callback has the sender and the before callback of the innermost frame.
    /// @return expectedHash The action hash that the after callback must also match.
    function requireMatchingFrame(Runtime storage runtime, address sender, CallbackType beforeCallback)
        internal
        view
        returns (bytes32 expectedHash)
    {
        if (runtime.frames.length == 0) revert IKernelHook.UnexpectedCallback();
        OperationFrame storage frame = currentFrame(runtime);
        if (frame.sender != sender) revert IKernelHook.UnexpectedCallback();
        if (frame.beforeCallback != beforeCallback) revert IKernelHook.UnexpectedCallback();
        return frame.actionHash;
    }

    /// @notice Records the ticket of a nested action that the route executor is about to run.
    function pushTicket(Runtime storage runtime, bytes32 hash) internal {
        runtime.tickets
            .push(ActionTicket({actionHash: hash, parentDepth: runtime.frames.length, awaitingBeforeCallback: true}));
    }

    /// @notice Marks the newest ticket as used by the before callback of its action.
    /// @dev The before callback must come from the exact action that was authorized, at the depth where it was
    /// authorized, and only once.
    function consumeTicket(Runtime storage runtime, bytes32 hash) internal {
        if (runtime.tickets.length == 0) revert IKernelHook.UnexpectedCallback();
        ActionTicket storage ticket = runtime.tickets[runtime.tickets.length - 1];
        if (!ticket.awaitingBeforeCallback) revert IKernelHook.UnexpectedCallback();
        if (ticket.parentDepth != runtime.frames.length) revert IKernelHook.UnexpectedCallback();
        if (ticket.actionHash != hash) revert IKernelHook.UnexpectedCallback();
        ticket.awaitingBeforeCallback = false;
    }

    /// @notice Removes the newest ticket after its action has completed.
    /// @dev The action must have reached its before callback, and its frame must be closed again.
    function popTicket(Runtime storage runtime) internal {
        if (runtime.tickets.length == 0) revert IKernelHook.Unauthorized();
        ActionTicket storage ticket = runtime.tickets[runtime.tickets.length - 1];
        if (ticket.awaitingBeforeCallback) revert IKernelHook.UnexpectedCallback();
        if (ticket.parentDepth != runtime.frames.length) revert IKernelHook.UnexpectedCallback();
        runtime.tickets.pop();
    }

    /// @notice Returns the operation depth: the frames on the stack, without the synthetic exit frame.
    /// The stack must not be empty.
    /// @dev The exit frame is not a pool operation. Without this exception, a pool with a depth limit of one
    /// could not let users close positions through an inactive installation.
    function operationDepth(Runtime storage runtime) internal view returns (uint256) {
        return runtime.frames.length - (runtime.frames[0].isExitContext ? 1 : 0);
    }

    /// @notice Reverts if a nested action may not enter poolId now.
    /// @dev A pool that already has an operation on the stack can be entered again only from that operation's
    /// after callback, and only after all required extensions of that after-callback sequence have run. So no
    /// required extension of the sequence observes a pool that a nested action changed under it.
    /// The initial-liquidity seed of a new pool does not use this check (see KernelHook._isInitialLiquiditySeed).
    function requireNoReentryInto(Runtime storage runtime, PoolId poolId) internal view {
        // frames.length <= MAX_OPERATION_DEPTH + 1
        for (uint256 i; i < runtime.frames.length; ++i) {
            OperationFrame storage ancestor = runtime.frames[i];
            if (PoolId.unwrap(ancestor.poolId) != PoolId.unwrap(poolId)) continue;
            if (!ancestor.callback.isAfterOperation()) revert IKernelHook.ReentrancyDenied();
            if (ancestor.remainingMandatoryGas != 0) revert IKernelHook.ReentrancyDenied();
        }
    }

    /// @notice Returns the innermost operation. The stack must not be empty.
    function currentFrame(Runtime storage runtime) internal view returns (OperationFrame storage) {
        return runtime.frames[runtime.frames.length - 1];
    }

    /// @notice Returns the context of the innermost operation, or an empty context if no operation is in progress.
    function context(Runtime storage runtime) internal view returns (ExecutionContext memory result) {
        if (runtime.frames.length == 0) return result;
        OperationFrame storage root = runtime.frames[0];
        OperationFrame storage frame = currentFrame(runtime);
        return ExecutionContext(
            root.operationId,
            root.poolId,
            frame.poolId,
            frame.sender,
            frame.extension,
            frame.callback,
            uint8(runtime.frames.length)
        );
    }

    /// @notice Returns the hash that binds a before callback to its after callback and to its ticket.
    /// @dev The PoolManager calls beforeAddLiquidity only when liquidityDelta > 0, and beforeRemoveLiquidity
    /// otherwise (a zero delta is a fee collection). For every ModifyLiquidity action, authorizeAction passes the
    /// BeforeAddLiquidity placeholder, so the callback is replaced here by the one that the PoolManager will call.
    function actionHash(PoolKey memory key, CallbackType callback, bytes memory parameters, bytes memory hookData)
        internal
        pure
        returns (bytes32)
    {
        bool isBeforeLiquidity =
            callback == CallbackType.BeforeAddLiquidity || callback == CallbackType.BeforeRemoveLiquidity;
        if (isBeforeLiquidity) {
            ModifyLiquidityParams memory params = abi.decode(parameters, (ModifyLiquidityParams));
            callback = params.liquidityDelta > 0 ? CallbackType.BeforeAddLiquidity : CallbackType.BeforeRemoveLiquidity;
        }
        return keccak256(abi.encode(key, callback, parameters, hookData));
    }
}
