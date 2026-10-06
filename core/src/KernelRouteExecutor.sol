// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "./interfaces/IKernelHook.sol";
import {IKernelExecutorCallback} from "./interfaces/callback/IKernelExecutorCallback.sol";
import {Operation, RouteAction} from "./types/KernelHookTypes.sol";
import {KernelHookVault} from "./KernelHookVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice Executes authorized actions as a distinct PoolManager caller, preserving hook callbacks.
/// @dev Net route debts are paid from the initiating installation's vault. Positions use an
/// installation-specific salt namespace so one installation cannot remove another's liquidity.
contract KernelRouteExecutor is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    /// @notice Kernel hook authorized to initiate routes.
    /// @return The kernel hook callback interface.
    IKernelExecutorCallback public immutable KERNEL_HOOK;
    /// @notice PoolManager that executes and settles route actions.
    /// @return The PoolManager interface.
    IPoolManager public immutable POOL_MANAGER;
    /// @notice Vault that holds each installation's route funds.
    /// @return The installation vault.
    KernelHookVault public immutable VAULT;
    /// @notice Maximum number of actions in one route.
    /// @return The route action limit.
    uint256 public constant MAX_ACTIONS = 16;
    /// @notice Number of nonempty positions owned by an installation.
    /// @return The installation's open position count.
    mapping(PoolId => mapping(address => uint256)) public openPositionCount;
    mapping(bytes32 => uint256) private _liquidity;
    /// @dev True while this contract's own PoolManager unlock runs. Transient: the EVM clears it after each transaction.
    bool private transient _unlockInProgress;

    error InvalidRoute();
    error InvalidLiquidity();
    error UnsettledRoute();

    /// @notice Bind the executor to its deploying kernel hook, PoolManager and vault.
    /// @param manager PoolManager used for route execution.
    /// @param vault Vault used for route settlement.
    constructor(IPoolManager manager, KernelHookVault vault) {
        KERNEL_HOOK = IKernelExecutorCallback(msg.sender);
        POOL_MANAGER = manager;
        VAULT = vault;
    }

    modifier onlyKernelHook() {
        if (msg.sender != address(KERNEL_HOOK)) revert IKernelHook.Unauthorized();
        _;
    }

    /// @notice Execute an installation's route while the PoolManager is unlocked.
    /// @param originPoolId Pool whose installation owns the route funds and positions.
    /// @param extension Extension initiating the route.
    /// @param actions Authorized actions to execute in order.
    /// @return The PoolManager balance delta for each action.
    function executeWhileUnlocked(PoolId originPoolId, address extension, RouteAction[] calldata actions)
        external
        onlyKernelHook
        returns (BalanceDelta[] memory)
    {
        if (!POOL_MANAGER.isUnlocked()) revert InvalidRoute();
        return _execute(originPoolId, extension, actions);
    }

    /// @notice Unlock the PoolManager and execute an installation's route.
    /// @param originPoolId Pool whose installation owns the route funds and positions.
    /// @param extension Extension initiating the route.
    /// @param actions Authorized actions to execute in order.
    /// @return results The PoolManager balance delta for each action.
    function unlockAndExecute(PoolId originPoolId, address extension, RouteAction[] calldata actions)
        external
        onlyKernelHook
        returns (BalanceDelta[] memory results)
    {
        if (_unlockInProgress) revert InvalidRoute();
        if (POOL_MANAGER.isUnlocked()) revert InvalidRoute();
        _unlockInProgress = true;
        results = abi.decode(POOL_MANAGER.unlock(abi.encode(originPoolId, extension, actions)), (BalanceDelta[]));
        _unlockInProgress = false;
    }

    /// @notice Execute the route requested by the current PoolManager unlock.
    /// @param data Encoded origin pool, extension and route actions.
    /// @return Encoded balance deltas for the route actions.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert IKernelHook.Unauthorized();
        if (!_unlockInProgress) revert IKernelHook.Unauthorized();
        (PoolId originPoolId, address extension, RouteAction[] memory actions) =
            abi.decode(data, (PoolId, address, RouteAction[]));
        return abi.encode(_execute(originPoolId, extension, actions));
    }

    /// @notice Read liquidity owned by an installation under its original position salt.
    /// @param originPoolId Pool whose installation owns the position.
    /// @param extension Extension that owns the position.
    /// @param targetPoolId Pool containing the position.
    /// @param tickLower Lower tick of the position.
    /// @param tickUpper Upper tick of the position.
    /// @param salt Installation's position salt before PoolManager namespacing.
    /// @return The position's tracked liquidity.
    function positionLiquidity(
        PoolId originPoolId,
        address extension,
        PoolId targetPoolId,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) external view returns (uint256) {
        return _liquidity[_positionId(originPoolId, extension, targetPoolId, tickLower, tickUpper, salt)];
    }

    function _execute(PoolId originPoolId, address extension, RouteAction[] memory actions)
        private
        returns (BalanceDelta[] memory results)
    {
        if (actions.length == 0) revert InvalidRoute();
        if (actions.length > MAX_ACTIONS) revert InvalidRoute();
        (Currency[] memory currencies, int256[] memory startingDeltas, uint256 count) = _recordStartingDeltas(actions);
        results = new BalanceDelta[](actions.length);
        // actions.length <= MAX_ACTIONS
        for (uint256 i; i < actions.length; ++i) {
            results[i] = _runAction(originPoolId, extension, actions[i]);
        }
        _settleNetDeltas(originPoolId, extension, currencies, startingDeltas, count);
    }

    function _recordStartingDeltas(RouteAction[] memory actions)
        private
        view
        returns (Currency[] memory currencies, int256[] memory startingDeltas, uint256 count)
    {
        currencies = new Currency[](actions.length * 2);
        startingDeltas = new int256[](currencies.length);
        // actions.length <= MAX_ACTIONS
        for (uint256 i; i < actions.length; ++i) {
            count = _recordStartingDelta(currencies, startingDeltas, count, actions[i].key.currency0);
            count = _recordStartingDelta(currencies, startingDeltas, count, actions[i].key.currency1);
        }
    }

    function _runAction(PoolId originPoolId, address extension, RouteAction memory action)
        private
        returns (BalanceDelta result)
    {
        if (action.operation == Operation.ModifyLiquidity) {
            ModifyLiquidityParams memory liquidityParameters = abi.decode(action.parameters, (ModifyLiquidityParams));
            _trackPosition(originPoolId, extension, action.key.toId(), liquidityParameters);
            // Track the installation salt; namespace the PoolManager salt to isolate installations' positions.
            liquidityParameters.salt = keccak256(abi.encode(originPoolId, extension, liquidityParameters.salt));
            action.parameters = abi.encode(liquidityParameters);
        }
        KERNEL_HOOK.authorizeAction(action);
        if (action.operation == Operation.Swap) {
            result = POOL_MANAGER.swap(action.key, abi.decode(action.parameters, (SwapParams)), action.hookData);
        } else if (action.operation == Operation.ModifyLiquidity) {
            (result,) = POOL_MANAGER.modifyLiquidity(
                action.key, abi.decode(action.parameters, (ModifyLiquidityParams)), action.hookData
            );
        } else {
            (uint256 amount0, uint256 amount1) = abi.decode(action.parameters, (uint256, uint256));
            result = POOL_MANAGER.donate(action.key, amount0, amount1, action.hookData);
        }
        KERNEL_HOOK.finishAction();
    }

    function _settleNetDeltas(
        PoolId originPoolId,
        address extension,
        Currency[] memory currencies,
        int256[] memory startingDeltas,
        uint256 count
    ) private {
        // Restore starting deltas instead of zero so nested routes preserve the parent route's debts.
        // count <= 2 * MAX_ACTIONS
        for (uint256 i; i < count; ++i) {
            int256 change = POOL_MANAGER.currencyDelta(address(this), currencies[i]) - startingDeltas[i];
            if (change > 0) {
                POOL_MANAGER.take(currencies[i], address(VAULT), uint256(change));
                VAULT.credit(originPoolId, extension, currencies[i], uint256(change));
            } else if (change < 0) {
                VAULT.settleDebtFor(originPoolId, extension, currencies[i], uint256(-change), address(this));
            }
            if (POOL_MANAGER.currencyDelta(address(this), currencies[i]) != startingDeltas[i]) revert UnsettledRoute();
        }
    }

    function _recordStartingDelta(
        Currency[] memory currencies,
        int256[] memory startingDeltas,
        uint256 count,
        Currency currency
    ) private view returns (uint256) {
        // count <= 2 * MAX_ACTIONS
        for (uint256 i; i < count; ++i) {
            if (Currency.unwrap(currencies[i]) == Currency.unwrap(currency)) return count;
        }
        currencies[count] = currency;
        startingDeltas[count] = POOL_MANAGER.currencyDelta(address(this), currency);
        return count + 1;
    }

    function _trackPosition(
        PoolId originPoolId,
        address extension,
        PoolId targetPoolId,
        ModifyLiquidityParams memory liquidityParameters
    ) private {
        bytes32 positionId = _positionId(
            originPoolId,
            extension,
            targetPoolId,
            liquidityParameters.tickLower,
            liquidityParameters.tickUpper,
            liquidityParameters.salt
        );
        uint256 previous = _liquidity[positionId];
        uint256 next;
        if (liquidityParameters.liquidityDelta >= 0) {
            next = previous + uint256(liquidityParameters.liquidityDelta);
        } else {
            uint256 amount = uint256(-liquidityParameters.liquidityDelta);
            if (amount > previous) revert InvalidLiquidity();
            next = previous - amount;
        }
        _liquidity[positionId] = next;
        if (previous == 0) {
            if (next != 0) ++openPositionCount[originPoolId][extension];
        }
        if (previous != 0) {
            if (next == 0) --openPositionCount[originPoolId][extension];
        }
    }

    function _positionId(
        PoolId originPoolId,
        address extension,
        PoolId targetPoolId,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(originPoolId, extension, targetPoolId, tickLower, tickUpper, salt));
    }
}
