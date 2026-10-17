// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "core/src/interfaces/IKernelHookExtension.sol";
import {BeforeSwapLibrary} from "core/src/libraries/BeforeSwapLibrary.sol";
import {CallbackResult, CallbackType, ExecutionContext, ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {KernelExtension} from "../../base/KernelExtension.sol";

/// @notice Experimental pool-local adaptive LP fees for Kernel dynamic-fee pools.
/// @dev This observes local price movement, not fair value or realized LVR. It cannot
/// identify the first external price jump. It holds no funds and never executes routes.
/// Required callbacks protect the active installation; deactivation removes the fee
/// override and exposes the PoolManager's stored fee (currently zero by default).
contract LVRHook is KernelExtension, IKernelHookExtension {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    uint16 public constant CALLBACK_MASK =
        (uint16(1) << uint8(CallbackType.BeforeSwap)) | (uint16(1) << uint8(CallbackType.AfterSwap));
    uint32 public constant MAX_POOLS = 16_384;
    uint24 public constant MAX_FEE = 100_000; // 10%; fees use v4's millionths.
    uint32 public constant MAX_SECONDS = 30 days;
    uint32 public constant MAX_FEE_WINDOW_SECONDS = 60;
    uint24 private constant MAX_MOVEMENT = 1_774_544; // Full TickMath domain width.

    /// @dev Fees are millionths. A tick is log-base-1.0001 price, not an exact basis point.
    struct Policy {
        uint24 baseFee;
        uint24 maximumFee;
        uint24 idlePremium;
        uint24 feePerTick;
        uint32 decaySeconds;
        uint32 idleSeconds;
        uint32 feeWindowSeconds;
    }

    struct Installation {
        uint64 policyVersion;
        uint64 configuredVersion;
        bool installed;
        bool seen;
    }

    /// @dev One packed storage word. No history, per-user records or pool enumeration.
    struct Observation {
        uint64 epoch;
        uint40 timestamp;
        int24 anchorTick;
        int24 lastTick;
        uint24 volatilityTicks;
        uint24 windowMovement;
        uint24 windowFee;
    }

    uint32 public totalPools;
    mapping(PoolId => Installation) private _installations;
    mapping(PoolId => Policy) private _policies;
    mapping(PoolId => Observation) private _observations;

    error PoolCapacityReached();
    error FeeConflict();
    error ObservationInvariant();
    error ClockOutOfBounds();

    event PolicyUpdated(PoolId indexed pool, uint64 version);
    event WindowOpened(PoolId indexed pool, uint64 indexed epoch, uint24 fee, uint24 volatilityTicks);

    constructor(IKernelHook kernel) KernelExtension(kernel) {}

    function setPolicy(PoolKey memory key, uint64 expectedVersion, Policy memory policy) external publicMutation {
        PoolId pool = _validateDynamicKey(key);
        _requireRole(pool);
        Installation storage installation = _installations[pool];
        if (!installation.installed || !KERNEL.isPoolInitialized(pool)) revert InvalidPool();
        (bool readable, uint256 flags) = _profile(pool, address(this));
        if (!readable || flags & ACTIVE != 0) revert InvalidConfiguration();
        if (installation.policyVersion != expectedVersion) revert InvalidVersion();
        _validatePolicy(policy);
        _checkClock();
        (, int24 tick,,) = MANAGER.getSlot0(pool);
        _policies[pool] = policy;
        installation.policyVersion = expectedVersion + 1;
        _observations[pool] = Observation(0, uint40(block.timestamp), tick, tick, 0, 0, 0);
        if (installation.policyVersion <= expectedVersion) revert ObservationInvariant();
        emit PolicyUpdated(pool, installation.policyVersion);
    }

    function policyState(PoolId pool) external view returns (Policy memory, uint64, uint64, bool) {
        Installation storage installation = _installations[pool];
        return (_policies[pool], installation.policyVersion, installation.configuredVersion, installation.installed);
    }

    function observation(PoolId pool) external view returns (Observation memory) {
        return _observations[pool];
    }

    /// @notice Indicative fee at the current local tick; later callbacks may change state.
    /// @dev No direction or external reference is observed. This is not an executable route quote.
    function previewFee(PoolId pool) external view returns (uint24 fee, uint24 volatilityTicks, uint24 idleFee) {
        if (!_ready(pool)) revert InvalidConfiguration();
        _checkClock();
        (, int24 tick,,) = MANAGER.getSlot0(pool);
        Observation memory next = _advance(_observations[pool], _policies[pool], tick);
        uint256 elapsed = block.timestamp - _observations[pool].timestamp;
        idleFee = next.epoch == _observations[pool].epoch ? 0 : _idleFee(_policies[pool], elapsed);
        return (next.windowFee, next.volatilityTicks, idleFee);
    }

    function onInstall(PoolKey memory key, ExtensionSettings calldata settings) external lifecycle returns (bytes4) {
        PoolId pool = _validateDynamicKey(key);
        _checkSettings(settings);
        if (_version(settings.configuration) != 0) revert InvalidVersion();
        Installation storage installation = _installations[pool];
        if (installation.installed) revert InvalidConfiguration();
        if (!installation.seen) {
            if (totalPools >= MAX_POOLS) revert PoolCapacityReached();
            ++totalPools;
            installation.seen = true;
        }
        installation.installed = true;
        installation.configuredVersion = 0;
        if (!installation.seen || totalPools > MAX_POOLS) revert ObservationInvariant();
        return this.onInstall.selector;
    }

    function onConfigure(PoolKey memory key, ExtensionSettings calldata, ExtensionSettings calldata settings)
        external
        lifecycle
        returns (bytes4)
    {
        _checkSettings(settings);
        Installation storage installation = _installations[_validateDynamicKey(key)];
        if (!installation.installed) revert InvalidPool();
        uint64 version = _version(settings.configuration);
        if (version == 0 || version != installation.policyVersion) revert InvalidVersion();
        installation.configuredVersion = version;
        if (installation.configuredVersion != installation.policyVersion) revert ObservationInvariant();
        return this.onConfigure.selector;
    }

    function canActivate(PoolKey memory key, ExtensionSettings calldata settings)
        external
        view
        onlyKernel
        returns (bool)
    {
        _checkSettings(settings);
        PoolId pool = _validateDynamicKey(key);
        Installation storage installation = _installations[pool];
        if (
            !_ready(pool) || installation.configuredVersion != _version(settings.configuration)
                || !KERNEL.isPoolInitialized(pool)
        ) return false;
        return _callbackFits(
            pool,
            CallbackType.BeforeSwap,
            settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)],
            KERNEL.callbackOrder(pool, CallbackType.BeforeSwap).length,
            false
        )
            && _callbackFits(
            pool,
            CallbackType.AfterSwap,
            settings.callbackGasLimits[uint8(CallbackType.AfterSwap)],
            KERNEL.callbackOrder(pool, CallbackType.AfterSwap).length,
            false
        );
    }

    function canUninstall(PoolKey memory key) external view onlyKernel returns (bool) {
        _validateDynamicKey(key);
        return !_entered; // No escrow, positions or user claims are created.
    }

    function onUninstall(PoolKey memory key, bytes calldata) external lifecycle returns (bytes4) {
        PoolId pool = _validateDynamicKey(key);
        Installation storage installation = _installations[pool];
        if (!installation.installed) revert InvalidPool();
        installation.installed = false;
        installation.configuredVersion = 0;
        delete _policies[pool];
        delete _observations[pool];
        if (installation.installed || _policies[pool].maximumFee != 0) revert ObservationInvariant();
        return this.onUninstall.selector;
    }

    function onCallback(ExecutionContext calldata context, PoolKey memory key, bytes calldata data)
        external
        onlyKernel
        returns (CallbackResult memory result)
    {
        _authenticate(context, key);
        if (!_ready(context.poolId)) revert InvalidConfiguration();
        _checkClock();
        if (context.callback == CallbackType.BeforeSwap) return _beforeSwap(context, data);
        if (context.callback != CallbackType.AfterSwap) revert Unauthorized();
        _afterSwap(context.poolId);
        return result;
    }

    function _beforeSwap(ExecutionContext calldata context, bytes calldata data)
        private
        returns (CallbackResult memory result)
    {
        if (context.prior.feeOverride != 0) revert FeeConflict();
        SwapParams memory params = abi.decode(data, (SwapParams));
        if (params.amountSpecified == 0) revert InvalidAmount();
        if (BeforeSwapLibrary.remainingAmountSpecified(params, context.prior) == 0) return result;
        PoolId pool = context.poolId;
        (, int24 tick,,) = MANAGER.getSlot0(pool);
        uint64 previousEpoch = _observations[pool].epoch;
        Observation memory next = _advance(_observations[pool], _policies[pool], tick);
        _observations[pool] = next;
        if (next.windowFee < _policies[pool].baseFee || next.windowFee > _policies[pool].maximumFee) {
            revert ObservationInvariant();
        }
        if (previousEpoch != next.epoch) {
            emit WindowOpened(pool, next.epoch, next.windowFee, next.volatilityTicks);
        }
        result.feeOverride = next.windowFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    function _afterSwap(PoolId pool) private {
        Observation memory previous = _observations[pool];
        // BeforeSwap may have found that an earlier extension consumed the entire swap.
        if (previous.epoch != _epoch(_policies[pool])) return;
        uint24 previousMovement = previous.windowMovement;
        uint24 previousFee = previous.windowFee;
        (, int24 tick,,) = MANAGER.getSlot0(pool);
        Observation memory next = _mark(previous, _policies[pool], tick);
        _observations[pool] = next;
        if (next.windowMovement < previousMovement || next.windowFee < previousFee) {
            revert ObservationInvariant();
        }
    }

    function _advance(Observation memory state, Policy memory policy, int24 tick)
        private
        view
        returns (Observation memory)
    {
        uint64 epoch = _epoch(policy);
        if (epoch < state.epoch || block.timestamp < state.timestamp) revert ClockOutOfBounds();
        if (state.epoch == epoch) return _mark(state, policy, tick);
        uint256 elapsed = block.timestamp - state.timestamp;
        uint256 risk = state.volatilityTicks > state.windowMovement ? state.volatilityTicks : state.windowMovement;
        risk = risk * policy.decaySeconds / (uint256(policy.decaySeconds) + elapsed);
        uint24 gap = _distance(tick, state.lastTick);
        if (gap > risk) risk = gap;
        state.epoch = epoch;
        state.timestamp = uint40(block.timestamp);
        state.anchorTick = tick;
        state.lastTick = tick;
        state.volatilityTicks = uint24(risk);
        state.windowMovement = 0;
        state.windowFee = _fee(policy, uint24(risk), _idleFee(policy, elapsed));
        return state;
    }

    function _mark(Observation memory state, Policy memory policy, int24 tick)
        private
        pure
        returns (Observation memory)
    {
        uint24 movement = _distance(tick, state.anchorTick);
        if (movement > state.windowMovement) state.windowMovement = movement;
        uint24 risk = state.volatilityTicks > state.windowMovement ? state.volatilityTicks : state.windowMovement;
        uint24 fee = _fee(policy, risk, 0);
        if (fee > state.windowFee) state.windowFee = fee;
        state.lastTick = tick;
        return state;
    }

    function _fee(Policy memory policy, uint24 risk, uint24 idleFee) private pure returns (uint24) {
        uint256 fee = uint256(policy.baseFee) + uint256(risk) * policy.feePerTick + idleFee;
        return fee > policy.maximumFee ? policy.maximumFee : uint24(fee);
    }

    function _idleFee(Policy memory policy, uint256 elapsed) private pure returns (uint24) {
        if (elapsed >= policy.idleSeconds) return policy.idlePremium;
        return uint24(uint256(policy.idlePremium) * elapsed / policy.idleSeconds);
    }

    function _distance(int24 left, int24 right) private pure returns (uint24 distance) {
        int256 signed = int256(left) - int256(right);
        uint256 absolute = uint256(signed < 0 ? -signed : signed);
        if (absolute > MAX_MOVEMENT) revert ObservationInvariant();
        return uint24(absolute);
    }

    function _ready(PoolId pool) private view returns (bool) {
        Installation storage installation = _installations[pool];
        return installation.installed && installation.policyVersion != 0
            && installation.configuredVersion == installation.policyVersion && _policies[pool].maximumFee != 0;
    }

    function _validateDynamicKey(PoolKey memory key) private view returns (PoolId) {
        if (!key.fee.isDynamicFee()) revert InvalidPool();
        return _validateKey(key);
    }

    function _validatePolicy(Policy memory policy) private pure {
        if (policy.baseFee == 0 || policy.maximumFee < policy.baseFee || policy.maximumFee > MAX_FEE) {
            revert InvalidConfiguration();
        }
        if (policy.idlePremium > policy.maximumFee - policy.baseFee || policy.feePerTick > MAX_FEE) {
            revert InvalidConfiguration();
        }
        if (policy.feeWindowSeconds == 0 || policy.feeWindowSeconds > MAX_FEE_WINDOW_SECONDS) {
            revert InvalidConfiguration();
        }
        if (
            policy.decaySeconds == 0 || policy.decaySeconds > MAX_SECONDS || policy.idleSeconds == 0
                || policy.idleSeconds > MAX_SECONDS
        ) revert InvalidConfiguration();
    }

    function _checkSettings(ExtensionSettings calldata settings) private pure {
        if (settings.callbackMask != CALLBACK_MASK || settings.optionalCallbacks || settings.allowNesting) {
            revert InvalidConfiguration();
        }
        if (
            settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] == 0
                || settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] == 0
        ) revert InvalidConfiguration();
    }

    /// @dev Timestamp windows deliberately avoid chain-specific block.number semantics.
    function _epoch(Policy memory policy) private view returns (uint64) {
        return uint64(block.timestamp / policy.feeWindowSeconds) + 1;
    }

    function _checkClock() private view {
        if (block.timestamp == 0 || block.timestamp > type(uint40).max) {
            revert ClockOutOfBounds();
        }
    }
}
