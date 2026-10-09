// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "../interfaces/IKernelHook.sol";
import {CallbackResult, CallbackType, ExecutionContext} from "../types/KernelHookTypes.sol";
import {CallbackLibrary} from "./CallbackLibrary.sol";
import {KernelHookConstants} from "./KernelHookConstants.sol";
import {Panic} from "@openzeppelin/contracts/utils/Panic.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice The base transient slot of one operation in progress.
type OperationFrame is bytes32;

using OperationFrameLibrary for OperationFrame global;

/// @notice Field accessors for an operation between its before and after callback.
library OperationFrameLibrary {
    function poolId(OperationFrame frame) internal view returns (PoolId) {
        return PoolId.wrap(_load(frame, 0));
    }

    function setPoolId(OperationFrame frame, PoolId value) internal {
        _store(frame, 0, PoolId.unwrap(value));
    }

    /// @dev The PoolManager caller. For a nested action, this is the route executor.
    function sender(OperationFrame frame) internal view returns (address) {
        return address(uint160(uint256(_load(frame, 1))));
    }

    function setSender(OperationFrame frame, address value) internal {
        _store(frame, 1, bytes32(uint256(uint160(value))));
    }

    /// @dev The extension whose callback runs now, or address(0) between callbacks.
    function extension(OperationFrame frame) internal view returns (address) {
        return address(uint160(uint256(_load(frame, 2))));
    }

    function setExtension(OperationFrame frame, address value) internal {
        _store(frame, 2, bytes32(uint256(uint160(value))));
    }

    function operationId(OperationFrame frame) internal view returns (uint64) {
        return uint64(uint256(_load(frame, 3)));
    }

    function setOperationId(OperationFrame frame, uint64 value) internal {
        _store(frame, 3, bytes32(uint256(value)));
    }

    /// @dev The before callback that opened this frame.
    function beforeCallback(OperationFrame frame) internal view returns (CallbackType) {
        return CallbackType(uint256(_load(frame, 4)));
    }

    function setBeforeCallback(OperationFrame frame, CallbackType value) internal {
        _store(frame, 4, bytes32(uint256(value)));
    }

    /// @dev The callback sequence that runs now (the before or the after callback).
    function callback(OperationFrame frame) internal view returns (CallbackType) {
        return CallbackType(uint256(_load(frame, 5)));
    }

    function setCallback(OperationFrame frame, CallbackType value) internal {
        _store(frame, 5, bytes32(uint256(value)));
    }

    /// @dev KernelHookOperations.actionHash of the operation; the after callback must match it.
    function actionHash(OperationFrame frame) internal view returns (bytes32) {
        return _load(frame, 6);
    }

    function setActionHash(OperationFrame frame, bytes32 value) internal {
        _store(frame, 6, value);
    }

    /// @dev gasleft() when the current callback sequence started.
    function callbackStartGas(OperationFrame frame) internal view returns (uint256) {
        return uint256(_load(frame, 7));
    }

    function setCallbackStartGas(OperationFrame frame, uint256 value) internal {
        _store(frame, 7, bytes32(value));
    }

    /// @dev The pool's gas budget for the current callback sequence.
    function callbackGasBudget(OperationFrame frame) internal view returns (uint256) {
        return uint256(_load(frame, 8));
    }

    function setCallbackGasBudget(OperationFrame frame, uint256 value) internal {
        _store(frame, 8, bytes32(value));
    }

    /// @dev The invocation gas (gas limit plus KernelHook's reserves) of the required extensions that have not
    /// run yet in this sequence.
    function remainingMandatoryGas(OperationFrame frame) internal view returns (uint256) {
        return uint256(_load(frame, 9));
    }

    function setRemainingMandatoryGas(OperationFrame frame, uint256 value) internal {
        _store(frame, 9, bytes32(value));
    }

    /// @dev Bit i is set if the optional extension with extensionIndex i is skipped for the rest of the operation.
    function skippedExtensions(OperationFrame frame) internal view returns (uint32) {
        return uint32(uint256(_load(frame, 10)));
    }

    function setSkippedExtensions(OperationFrame frame, uint32 value) internal {
        _store(frame, 10, bytes32(uint256(value)));
    }

    /// @dev The specified-currency delta that the beforeSwap callbacks returned, packed above the unspecified one.
    function beforeSwapSpecifiedDelta(OperationFrame frame) internal view returns (int128) {
        return int128(uint128(uint256(_load(frame, 11)) >> 128));
    }

    function setBeforeSwapDeltas(OperationFrame frame, BalanceDelta value) internal {
        _store(frame, 11, bytes32(uint256(BalanceDelta.unwrap(value))));
    }

    /// @dev The unspecified-currency delta that the beforeSwap callbacks returned.
    function beforeSwapUnspecifiedDelta(OperationFrame frame) internal view returns (int128) {
        return int128(uint128(uint256(_load(frame, 11))));
    }

    function setBeforeSwapUnspecifiedDelta(OperationFrame frame, int128 value) internal {
        _store(frame, 11, bytes32(uint256(int256(value))));
    }

    /// @dev True for the synthetic frame of unwindPositions, which is not a PoolManager operation.
    function isExitContext(OperationFrame frame) internal view returns (bool) {
        return _load(frame, 12) != bytes32(0);
    }

    function setIsExitContext(OperationFrame frame, bool value) internal {
        _store(frame, 12, bytes32(uint256(value ? 1 : 0)));
    }

    /// @dev The sum of the deltas that earlier extensions of the current callback returned. invokeExtension writes it
    /// before each extension call, inside the call's rollback scope.
    function priorDeltas(OperationFrame frame) internal view returns (BalanceDelta) {
        return BalanceDelta.wrap(int256(uint256(_load(frame, 13))));
    }

    function setPriorDeltas(OperationFrame frame, BalanceDelta value) internal {
        _store(frame, 13, bytes32(uint256(BalanceDelta.unwrap(value))));
    }

    /// @dev The fee override that an earlier extension of the current callback returned, or zero. Written with
    /// priorDeltas.
    function priorFeeOverride(OperationFrame frame) internal view returns (uint24) {
        return uint24(uint256(_load(frame, 14)));
    }

    function setPriorFeeOverride(OperationFrame frame, uint24 value) internal {
        _store(frame, 14, bytes32(uint256(value)));
    }

    function _load(OperationFrame frame, uint256 field) private view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := tload(add(frame, field))
        }
    }

    function _store(OperationFrame frame, uint256 field, bytes32 value) private {
        assembly ("memory-safe") {
            tstore(add(frame, field), value)
        }
    }
}

/// @notice The base transient slot of one authorized nested action.
type ActionTicket is bytes32;

using ActionTicketLibrary for ActionTicket global;

/// @notice Field accessors for permission to enter one nested action's before callback.
library ActionTicketLibrary {
    function actionHash(ActionTicket ticket) internal view returns (bytes32) {
        return _load(ticket, 0);
    }

    function setActionHash(ActionTicket ticket, bytes32 value) internal {
        _store(ticket, 0, value);
    }

    /// @dev The number of frames when the action was authorized.
    function parentDepth(ActionTicket ticket) internal view returns (uint256) {
        return uint256(_load(ticket, 1));
    }

    function setParentDepth(ActionTicket ticket, uint256 value) internal {
        _store(ticket, 1, bytes32(value));
    }

    /// @dev True until the before callback of the action consumes the ticket.
    function awaitingBeforeCallback(ActionTicket ticket) internal view returns (bool) {
        return _load(ticket, 2) != bytes32(0);
    }

    function setAwaitingBeforeCallback(ActionTicket ticket, bool value) internal {
        _store(ticket, 2, bytes32(uint256(value ? 1 : 0)));
    }

    function _load(ActionTicket ticket, uint256 field) private view returns (bytes32 value) {
        assembly ("memory-safe") {
            value := tload(add(ticket, field))
        }
    }

    function _store(ActionTicket ticket, uint256 field, bytes32 value) private {
        assembly ("memory-safe") {
            tstore(add(ticket, field), value)
        }
    }
}

/// @notice The runtime stack of operations in progress, and the tickets of nested route actions.
/// @dev See the execution model in IKernelHook. The stack is empty between transactions.
library KernelHookOperations {
    using CallbackLibrary for CallbackType;
    using SlotDerivation for bytes32;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;

    /// @notice The base slot of the reentry counters in transient storage.
    /// @dev A counter holds the number of calls of one installation in progress. The EVM clears transient storage at
    /// the end of each transaction, and each call also brings its counter back to zero.
    bytes32 internal constant ACTIVE_INVOCATIONS_SLOT = bytes32(uint256(keccak256("KernelHook.activeInvocations")) - 1);

    /// @notice Holds the frame count; frame i starts at FRAMES_SLOT + 1 + i * FRAME_FIELD_COUNT.
    bytes32 internal constant FRAMES_SLOT = bytes32(uint256(keccak256("KernelHook.frames")) - 1);
    /// @notice Holds the ticket count; ticket i starts at TICKETS_SLOT + 1 + i * TICKET_FIELD_COUNT.
    bytes32 internal constant TICKETS_SLOT = bytes32(uint256(keccak256("KernelHook.tickets")) - 1);
    uint256 internal constant FRAME_FIELD_COUNT = 15;
    uint256 internal constant TICKET_FIELD_COUNT = 3;
    /// @dev Includes the synthetic exit frame. Sequential route actions need at most one ticket per nesting level.
    uint256 internal constant MAX_FRAMES = uint256(KernelHookConstants.MAX_OPERATION_DEPTH) + 1;

    /// @notice The persistent part of the runtime. The frames and tickets are in transient storage.
    struct Runtime {
        /// @dev Persistent, so that operation ids stay unique forever.
        uint64 lastOperationId;
    }

    /// @notice Returns the number of calls of an installation in progress, to detect reentrancy.
    function activeInvocations(PoolId poolId, address extension) internal view returns (uint256) {
        return _activeInvocationsSlot(poolId, extension).tload();
    }

    /// @notice Counts the start of a call of an installation.
    function enterInvocation(PoolId poolId, address extension) internal {
        TransientSlot.Uint256Slot slot = _activeInvocationsSlot(poolId, extension);
        slot.tstore(slot.tload() + 1);
    }

    /// @notice Counts the end of a call of an installation. Reverts (underflow) without a matching start.
    function exitInvocation(PoolId poolId, address extension) internal {
        TransientSlot.Uint256Slot slot = _activeInvocationsSlot(poolId, extension);
        slot.tstore(slot.tload() - 1);
    }

    function _activeInvocationsSlot(PoolId poolId, address extension) private pure returns (TransientSlot.Uint256Slot) {
        return ACTIVE_INVOCATIONS_SLOT.deriveMapping(PoolId.unwrap(poolId)).deriveMapping(extension).asUint256();
    }

    /// @notice Reverts unless no operation or ticket is in progress.
    /// @dev KernelHook also checks its management flag and the vault, which is a separate contract.
    function requireIdle() internal view {
        if (frameCount() != 0) revert IKernelHook.ExecutionInProgress();
        if (ticketCount() != 0) revert IKernelHook.ExecutionInProgress();
    }

    /// @notice Opens the frame of an operation, from its before callback.
    function pushFrame(
        Runtime storage runtime,
        PoolId poolId,
        address sender,
        CallbackType beforeCallback,
        bytes32 hash
    ) internal {
        OperationFrame frame = _pushFrame();
        // A pop leaves transient fields behind: every push must write all fields, including zeros, before reuse.
        frame.setPoolId(poolId);
        frame.setSender(sender);
        frame.setExtension(address(0));
        frame.setOperationId(++runtime.lastOperationId);
        frame.setBeforeCallback(beforeCallback);
        frame.setCallback(CallbackType.BeforeInitialize);
        frame.setActionHash(hash);
        frame.setCallbackStartGas(0);
        frame.setCallbackGasBudget(0);
        frame.setRemainingMandatoryGas(0);
        frame.setSkippedExtensions(0);
        frame.setBeforeSwapUnspecifiedDelta(0);
        frame.setIsExitContext(false);
        frame.setPriorDeltas(BalanceDelta.wrap(0));
        frame.setPriorFeeOverride(0);
    }

    /// @notice Opens the synthetic root frame of unwindPositions.
    /// @dev It is not a PoolManager operation. The extension is both its sender and its active extension, so
    /// that authorizeAction accepts the extension's nested actions. Its callback is AfterRemoveLiquidity, an
    /// after callback with no required gas left, so that those actions may enter this frame's own pool.
    function pushExitFrame(Runtime storage runtime, PoolId poolId, address extension) internal {
        OperationFrame frame = _pushFrame();
        // A pop leaves transient fields behind: every push must write all fields, including zeros, before reuse.
        frame.setPoolId(poolId);
        frame.setSender(extension);
        frame.setExtension(extension);
        frame.setOperationId(++runtime.lastOperationId);
        frame.setBeforeCallback(CallbackType.BeforeInitialize);
        frame.setCallback(CallbackType.AfterRemoveLiquidity);
        frame.setActionHash(bytes32(0));
        frame.setCallbackStartGas(0);
        frame.setCallbackGasBudget(0);
        frame.setRemainingMandatoryGas(0);
        frame.setSkippedExtensions(0);
        frame.setBeforeSwapUnspecifiedDelta(0);
        frame.setIsExitContext(true);
        frame.setPriorDeltas(BalanceDelta.wrap(0));
        frame.setPriorFeeOverride(0);
    }

    function _pushFrame() private returns (OperationFrame frame) {
        uint256 count = frameCount();
        // Paired assertion: the existing operation-depth checks make a push beyond this capacity unreachable.
        if (count >= MAX_FRAMES) revert IKernelHook.DepthLimitReached();
        frame = _frameAt(count);
        FRAMES_SLOT.asUint256().tstore(count + 1);
    }

    /// @notice Closes the innermost frame: from its after callback, or at the end of unwindPositions.
    function popFrame() internal {
        uint256 count = frameCount();
        if (count == 0) Panic.panic(Panic.EMPTY_ARRAY_POP);
        FRAMES_SLOT.asUint256().tstore(count - 1);
    }

    /// @notice Reverts unless an after callback has the sender and the before callback of the innermost frame.
    /// @return expectedHash The action hash that the after callback must also match.
    function requireMatchingFrame(address sender, CallbackType beforeCallback)
        internal
        view
        returns (bytes32 expectedHash)
    {
        if (frameCount() == 0) revert IKernelHook.UnexpectedCallback();
        OperationFrame frame = currentFrame();
        if (frame.sender() != sender) revert IKernelHook.UnexpectedCallback();
        if (frame.beforeCallback() != beforeCallback) revert IKernelHook.UnexpectedCallback();
        return frame.actionHash();
    }

    /// @notice Records the ticket of a nested action that the route executor is about to run.
    function pushTicket(bytes32 hash) internal {
        uint256 count = ticketCount();
        // Paired assertion: depth checks and sequential route actions make a push beyond this capacity unreachable.
        if (count >= MAX_FRAMES) revert IKernelHook.DepthLimitReached();
        ActionTicket ticket = _ticketAt(count);
        // A pop leaves transient fields behind: every push must write all fields, including zeros, before reuse.
        ticket.setActionHash(hash);
        ticket.setParentDepth(frameCount());
        ticket.setAwaitingBeforeCallback(true);
        TICKETS_SLOT.asUint256().tstore(count + 1);
    }

    /// @notice Marks the newest ticket as used by the before callback of its action.
    /// @dev The before callback must come from the exact action that was authorized, at the depth where it was
    /// authorized, and only once.
    function consumeTicket(bytes32 hash) internal {
        if (ticketCount() == 0) revert IKernelHook.UnexpectedCallback();
        ActionTicket ticket = currentTicket();
        if (!ticket.awaitingBeforeCallback()) revert IKernelHook.UnexpectedCallback();
        if (ticket.parentDepth() != frameCount()) revert IKernelHook.UnexpectedCallback();
        if (ticket.actionHash() != hash) revert IKernelHook.UnexpectedCallback();
        ticket.setAwaitingBeforeCallback(false);
    }

    /// @notice Removes the newest ticket after its action has completed.
    /// @dev The action must have reached its before callback, and its frame must be closed again.
    function popTicket() internal {
        uint256 count = ticketCount();
        if (count == 0) revert IKernelHook.Unauthorized();
        ActionTicket ticket = currentTicket();
        if (ticket.awaitingBeforeCallback()) revert IKernelHook.UnexpectedCallback();
        if (ticket.parentDepth() != frameCount()) revert IKernelHook.UnexpectedCallback();
        TICKETS_SLOT.asUint256().tstore(count - 1);
    }

    /// @notice Returns the operation depth: the frames on the stack, without the synthetic exit frame.
    /// The stack must not be empty.
    /// @dev The exit frame is not a pool operation. Without this exception, a pool with a depth limit of one
    /// could not let users close positions through an inactive installation.
    function operationDepth() internal view returns (uint256) {
        return frameCount() - (frameAt(0).isExitContext() ? 1 : 0);
    }

    /// @notice Reverts if a nested action may not enter poolId now.
    /// @dev A pool that already has an operation on the stack can be entered again only from that operation's
    /// after callback, and only after all required extensions of that after-callback sequence have run. So no
    /// required extension of the sequence observes a pool that a nested action changed under it.
    /// The initial-liquidity seed of a new pool does not use this check (see KernelHook._isInitialLiquiditySeed).
    function requireNoReentryInto(PoolId poolId) internal view {
        // frameCount() <= MAX_FRAMES
        for (uint256 i; i < frameCount(); ++i) {
            OperationFrame ancestor = frameAt(i);
            if (PoolId.unwrap(ancestor.poolId()) != PoolId.unwrap(poolId)) continue;
            if (!ancestor.callback().isAfterOperation()) revert IKernelHook.ReentrancyDenied();
            if (ancestor.remainingMandatoryGas() != 0) revert IKernelHook.ReentrancyDenied();
        }
    }

    /// @notice Returns the number of operations on the stack, including the synthetic exit frame.
    function frameCount() internal view returns (uint256) {
        return FRAMES_SLOT.asUint256().tload();
    }

    /// @notice Returns an operation by its zero-based stack index.
    function frameAt(uint256 index) internal view returns (OperationFrame) {
        if (index >= frameCount()) Panic.panic(Panic.ARRAY_OUT_OF_BOUNDS);
        return _frameAt(index);
    }

    function _frameAt(uint256 index) private pure returns (OperationFrame) {
        unchecked {
            return OperationFrame.wrap(bytes32(uint256(FRAMES_SLOT) + 1 + index * FRAME_FIELD_COUNT));
        }
    }

    /// @notice Returns the innermost operation. The stack must not be empty.
    function currentFrame() internal view returns (OperationFrame) {
        return frameAt(frameCount() - 1);
    }

    /// @notice Returns the number of authorized nested actions that have not finished.
    function ticketCount() internal view returns (uint256) {
        return TICKETS_SLOT.asUint256().tload();
    }

    /// @notice Returns the innermost authorized nested action. The stack must not be empty.
    function currentTicket() internal view returns (ActionTicket) {
        return _ticketAt(ticketCount() - 1);
    }

    function _ticketAt(uint256 index) private pure returns (ActionTicket) {
        unchecked {
            return ActionTicket.wrap(bytes32(uint256(TICKETS_SLOT) + 1 + index * TICKET_FIELD_COUNT));
        }
    }

    /// @notice Returns the context of the innermost operation, or an empty context if no operation is in progress.
    function context() internal view returns (ExecutionContext memory result) {
        uint256 count = frameCount();
        if (count == 0) return result;
        OperationFrame root = _frameAt(0);
        OperationFrame frame = _frameAt(count - 1);
        result.rootOperationId = root.operationId();
        result.rootPoolId = root.poolId();
        result.poolId = frame.poolId();
        result.sender = frame.sender();
        result.extension = frame.extension();
        result.callback = frame.callback();
        result.depth = uint8(count);
        if (count > 1) {
            // The parent operation's extension started this nested operation: executeRoute accepts only the
            // extension of the current frame, and unwindPositions records its caller as its exit frame's extension.
            OperationFrame parent = _frameAt(count - 2);
            result.originPoolId = parent.poolId();
            result.originExtension = parent.extension();
        }
        // The prior result belongs to the extension call in progress. The exit frame of unwindPositions has an
        // extension but no callback; its prior fields stay zero from the push.
        if (result.extension == address(0)) return result;
        BalanceDelta deltas = frame.priorDeltas();
        result.prior = CallbackResult(deltas.amount0(), deltas.amount1(), frame.priorFeeOverride());
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
