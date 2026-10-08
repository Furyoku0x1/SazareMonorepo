// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "./interfaces/IKernelHook.sol";
import {IKernelExecutorCallback} from "./interfaces/callback/IKernelExecutorCallback.sol";
import {IHookCatalog} from "./interfaces/IHookCatalog.sol";
import {IExternalVenueAdapter} from "./interfaces/IExternalVenueAdapter.sol";
import {ExternalSwapParameters, Operation, RouteAction} from "./types/KernelHookTypes.sol";
import {BoundedCall} from "./libraries/BoundedCall.sol";
import {KernelHookVault} from "./KernelHookVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice Executes authorized actions as a distinct PoolManager caller, preserving hook callbacks.
/// @dev Net route debts are paid from the initiating installation's vault. Positions use an
/// installation-specific salt namespace so one installation cannot remove another's liquidity.
/// An ExternalSwap action uses the PoolManager's flash accounting for a venue outside it: the executor takes the
/// input to a Catalog-admitted adapter and settles the venue's output back, so the route nets it like a pool swap.
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
    /// @notice Catalog that admits external venue adapters.
    /// @return The catalog of the deploying kernel hook.
    IHookCatalog public immutable CATALOG;
    /// @notice Maximum number of actions in one route.
    /// @return The route action limit.
    uint256 public constant MAX_ACTIONS = 16;
    /// @notice Number of nonempty positions owned by an installation.
    /// @return The installation's open position count.
    mapping(PoolId => mapping(address => uint256)) public openPositionCount;
    mapping(bytes32 => uint256) private _liquidity;
    /// @dev True while this contract's own PoolManager unlock runs. Transient: the EVM clears it after each transaction.
    bool private transient _unlockInProgress;
    /// @dev True while an external swap's input transfer, adapter and settlement run. Code that runs then (the venue,
    /// a token callback, the extension) must not start another route of this executor. Transient.
    bool private transient _externalSwapInProgress;
    /// @dev External swap amounts must fit the int128 of a BalanceDelta.
    uint256 private constant MAX_EXTERNAL_AMOUNT = uint256(uint128(type(int128).max));

    /// @dev What an external swap records before its adapter runs.
    struct ExternalSwapState {
        Currency currencyIn;
        Currency currencyOut;
        uint256 amountIn;
        int256 deltaIn;
        int256 deltaOut;
        uint256 nonzeroDeltas;
    }

    error InvalidRoute();
    error InvalidLiquidity();
    error UnsettledRoute();
    error ExternalSwapInProgress();
    error InvalidExternalSwap();
    error ExternalSwapFailed();
    error ExternalSwapLimitExceeded();
    error ExternalBalanceMismatch();

    /// @notice Bind the executor to its deploying kernel hook, PoolManager, vault and catalog.
    /// @param manager PoolManager used for route execution.
    /// @param vault Vault used for route settlement.
    /// @param catalog Catalog that admits external venue adapters.
    constructor(IPoolManager manager, KernelHookVault vault, IHookCatalog catalog) {
        KERNEL_HOOK = IKernelExecutorCallback(msg.sender);
        POOL_MANAGER = manager;
        VAULT = vault;
        CATALOG = catalog;
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
        if (_externalSwapInProgress) revert ExternalSwapInProgress();
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
        // A ForeignSwap has no ticket: finishAction would pop the ticket of an enclosing Kernel action instead.
        if (action.operation == Operation.ForeignSwap) {
            return POOL_MANAGER.swap(action.key, abi.decode(action.parameters, (SwapParams)), action.hookData);
        }
        if (action.operation == Operation.ExternalSwap) return _runExternalSwap(action);
        if (action.operation == Operation.Swap) {
            result = POOL_MANAGER.swap(action.key, abi.decode(action.parameters, (SwapParams)), action.hookData);
        } else if (action.operation == Operation.ModifyLiquidity) {
            (result,) = POOL_MANAGER.modifyLiquidity(
                action.key, abi.decode(action.parameters, (ModifyLiquidityParams)), action.hookData
            );
        } else if (action.operation == Operation.Donate) {
            (uint256 amount0, uint256 amount1) = abi.decode(action.parameters, (uint256, uint256));
            result = POOL_MANAGER.donate(action.key, amount0, amount1, action.hookData);
        } else {
            revert InvalidRoute();
        }
        KERNEL_HOOK.finishAction();
    }

    /// @dev Takes the input from the PoolManager to the adapter, lets the adapter swap on its venue and pay the
    /// output to the PoolManager, then settles that output for this executor. The route's net settlement then charges
    /// or credits the origin installation as for a pool swap.
    function _runExternalSwap(RouteAction memory action) private returns (BalanceDelta) {
        ExternalSwapParameters memory parameters = abi.decode(action.parameters, (ExternalSwapParameters));
        ExternalSwapState memory state = _beginExternalSwap(action.key, parameters, action.hookData);
        _externalSwapInProgress = true;
        _fundAdapter(state, parameters.adapter);
        uint256 amountOut = _swapOnVenue(state, parameters, action.hookData);
        _externalSwapInProgress = false;
        _checkExternalSwap(state, parameters, amountOut);
        int128 paid = -int128(int256(state.amountIn));
        int128 received = int128(int256(amountOut));
        return parameters.zeroForOne ? toBalanceDelta(paid, received) : toBalanceDelta(received, paid);
    }

    function _beginExternalSwap(PoolKey memory key, ExternalSwapParameters memory parameters, bytes memory data)
        private
        view
        returns (ExternalSwapState memory state)
    {
        _requireExternalKey(key);
        IHookCatalog.AdapterEntry memory entry = CATALOG.getAdapterEntry(parameters.adapter);
        if (!entry.admitted) revert InvalidExternalSwap();
        // Admission pins code, not an address, so the hash is compared on every use.
        if (entry.codeHash != parameters.adapter.codehash) revert InvalidExternalSwap();
        (state.currencyIn, state.currencyOut) =
            parameters.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        state.amountIn = _externalAmountIn(state, parameters, data);
        // A pending sync belongs to another settlement in progress; this swap's sync would overwrite it.
        if (!POOL_MANAGER.getSyncedCurrency().isAddressZero()) revert InvalidExternalSwap();
        state.deltaIn = POOL_MANAGER.currencyDelta(address(this), state.currencyIn);
        state.deltaOut = POOL_MANAGER.currencyDelta(address(this), state.currencyOut);
        state.nonzeroDeltas = POOL_MANAGER.getNonzeroDeltaCount();
    }

    /// @dev The key carries only the two currencies, so the route's net settlement includes them. They must be
    /// sorted and distinct, and not native: an outside venue trades ERC20 tokens.
    function _requireExternalKey(PoolKey memory key) private pure {
        if (key.fee != 0) revert InvalidExternalSwap();
        if (key.tickSpacing != 0) revert InvalidExternalSwap();
        if (address(key.hooks) != address(0)) revert InvalidExternalSwap();
        if (key.currency0.isAddressZero()) revert InvalidExternalSwap();
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)) revert InvalidExternalSwap();
    }

    /// @dev The exact input, or the adapter's quote for the exact output, capped by the limit.
    function _externalAmountIn(
        ExternalSwapState memory state,
        ExternalSwapParameters memory parameters,
        bytes memory data
    ) private view returns (uint256 amountIn) {
        int256 specified = parameters.amountSpecified;
        if (specified == 0) revert InvalidExternalSwap();
        if (specified < -int256(MAX_EXTERNAL_AMOUNT)) revert InvalidExternalSwap();
        if (specified > int256(MAX_EXTERNAL_AMOUNT)) revert InvalidExternalSwap();
        if (specified < 0) return uint256(-specified);
        bytes memory quote = abi.encodeCall(
            IExternalVenueAdapter.quoteExactOutput,
            (parameters.venue, state.currencyIn, state.currencyOut, uint256(specified), data)
        );
        (bool success, bytes memory output) = BoundedCall.tryStaticCall(parameters.adapter, gasleft(), quote);
        if (!success) revert ExternalSwapFailed();
        amountIn = abi.decode(output, (uint256));
        if (amountIn == 0) revert ExternalSwapFailed();
        if (amountIn > MAX_EXTERNAL_AMOUNT) revert ExternalSwapFailed();
        if (amountIn > parameters.limit) revert ExternalSwapLimitExceeded();
    }

    /// @dev The PoolManager records the nominal amount as this executor's debt. A token that taxes the receiver
    /// would deliver less to the adapter; one that charges the sender would take more from the PoolManager's custody.
    function _fundAdapter(ExternalSwapState memory state, address adapter) private {
        uint256 held = state.currencyIn.balanceOf(adapter);
        uint256 custody = state.currencyIn.balanceOf(address(POOL_MANAGER));
        POOL_MANAGER.take(state.currencyIn, adapter, state.amountIn);
        if (state.currencyIn.balanceOf(adapter) != held + state.amountIn) revert ExternalBalanceMismatch();
        if (state.currencyIn.balanceOf(address(POOL_MANAGER)) != custody - state.amountIn) {
            revert ExternalBalanceMismatch();
        }
    }

    /// @dev settle() credits the balance increase since the last sync. The sync happens after the input transfer, so
    /// a token callback during that transfer cannot change it; a changed sync after the adapter would credit
    /// something else. settle() must also credit exactly the output: an adapter could credit this executor itself
    /// with settleFor, take the output back as its own debt and restore the sync, which the deltas would not show.
    function _swapOnVenue(ExternalSwapState memory state, ExternalSwapParameters memory parameters, bytes memory data)
        private
        returns (uint256 amountOut)
    {
        POOL_MANAGER.sync(state.currencyOut);
        uint256 reserves = POOL_MANAGER.getSyncedReserves();
        bytes memory swap = abi.encodeCall(
            IExternalVenueAdapter.swap,
            (
                parameters.venue,
                state.currencyIn,
                state.currencyOut,
                state.amountIn,
                parameters.amountSpecified,
                address(POOL_MANAGER),
                data
            )
        );
        (bool success, bytes memory output) = BoundedCall.tryCall(parameters.adapter, gasleft(), swap, 32);
        if (!success) revert ExternalSwapFailed();
        amountOut = abi.decode(output, (uint256));
        if (Currency.unwrap(POOL_MANAGER.getSyncedCurrency()) != Currency.unwrap(state.currencyOut)) {
            revert ExternalBalanceMismatch();
        }
        if (POOL_MANAGER.getSyncedReserves() != reserves) revert ExternalBalanceMismatch();
        if (POOL_MANAGER.settle() != amountOut) revert ExternalBalanceMismatch();
    }

    /// @dev The output meets the limit, and this executor's PoolManager deltas moved by exactly the amounts. The
    /// nonzero-delta count is a tripwire for an adapter or venue that leaves its own debt open, which would revert the
    /// whole unlock; it cannot see every case, so adapters are admitted by code.
    function _checkExternalSwap(
        ExternalSwapState memory state,
        ExternalSwapParameters memory parameters,
        uint256 amountOut
    ) private view {
        if (amountOut > MAX_EXTERNAL_AMOUNT) revert ExternalBalanceMismatch();
        if (parameters.amountSpecified > 0) {
            if (amountOut != uint256(parameters.amountSpecified)) revert ExternalSwapLimitExceeded();
        } else if (amountOut < parameters.limit) {
            revert ExternalSwapLimitExceeded();
        }
        int256 deltaIn = POOL_MANAGER.currencyDelta(address(this), state.currencyIn);
        int256 deltaOut = POOL_MANAGER.currencyDelta(address(this), state.currencyOut);
        if (deltaIn != state.deltaIn - int256(state.amountIn)) revert ExternalBalanceMismatch();
        if (deltaOut != state.deltaOut + int256(amountOut)) revert ExternalBalanceMismatch();
        uint256 expected = state.nonzeroDeltas + _nonzero(deltaIn) + _nonzero(deltaOut) - _nonzero(state.deltaIn)
            - _nonzero(state.deltaOut);
        if (POOL_MANAGER.getNonzeroDeltaCount() != expected) revert UnsettledRoute();
    }

    function _nonzero(int256 delta) private pure returns (uint256) {
        return delta == 0 ? 0 : 1;
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
                // Claims, not tokens: a credit never needs the PoolManager to hold the currency now.
                POOL_MANAGER.mint(address(VAULT), currencies[i].toId(), uint256(change));
                VAULT.credit(originPoolId, extension, currencies[i], uint256(change));
            } else if (change < 0) {
                uint256 fromClaims =
                    VAULT.settleDebtFor(originPoolId, extension, currencies[i], uint256(-change), address(this));
                if (fromClaims != 0) POOL_MANAGER.burn(address(VAULT), currencies[i].toId(), fromClaims);
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
