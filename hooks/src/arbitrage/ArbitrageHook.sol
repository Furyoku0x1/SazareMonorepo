// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "core/src/interfaces/IKernelHookExtension.sol";
import {
    CallbackResult,
    CallbackType,
    ExecutionContext,
    ExtensionSettings,
    Operation,
    RouteAction
} from "core/src/types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {KernelExtension} from "../base/KernelExtension.sol";
import {ArbitrageNetwork} from "./ArbitrageNetwork.sol";
import {LimitOrder} from "../limitorder/LimitOrder.sol";
import {OrderMath} from "../libraries/limitorder/OrderMath.sol";
import {ExtensionRead} from "../libraries/shared/ExtensionRead.sol";
import {
    MAX_TOP_POOLS,
    MAX_TRIANGLES,
    MAX_QUADS,
    MAX_SIZED_CYCLES,
    SEARCH_ATTEMPT_RESERVE_GAS,
    SEARCH_SIZE_GAS
} from "../libraries/arbitrage/NetworkConstants.sol";

/// @notice Swap-triggered, on-chain arbitrage for Kernel pools: cycles of two to four pools through the swapped pool,
/// same pair first, then other pairs.
/// @dev ArbitrageNetwork finds and quotes the cycle; this extension executes it as one netted route and checks the
/// actual balances. Policies and profit claims live here.
contract ArbitrageHook is KernelExtension, IKernelHookExtension {
    using ExtensionRead for address;

    uint16 internal constant CALLBACK_MASK = uint16(1) << uint8(CallbackType.AfterSwap);
    bytes32 private constant SUCCESS_MARKER = keccak256("sazare.arbitrage.success");
    /// @dev ABI size of ArbitrageNetwork.Plan: 31 static words.
    uint256 private constant PLAN_BYTES = 31 * 32;
    /// @dev Gas this callback keeps besides the search and the execution reserve: setup, checks and return.
    uint256 private constant CALLBACK_OVERHEAD_GAS = 80_000;
    /// @dev Search gas beyond the guards' finish reserve, for loading, pricing and scoring at least a few cycles.
    uint256 private constant MIN_SEARCH_WORK_GAS = 100_000;
    /// @dev Gas the callback spends before the search admission check: authentication, vault lock read, policy load.
    uint256 private constant SETUP_GAS_ALLOWANCE = 50_000;
    uint256 private constant MAX_SEARCH_GAS = 4_000_000;
    uint256 private constant MIN_EXECUTION_RESERVE = 500_000;
    uint256 private constant MAX_EXECUTION_RESERVE = 3_000_000;

    ArbitrageNetwork public immutable NETWORK;
    LimitOrder public immutable LIMIT_ORDERS;

    /// @notice Per-pool search caps, gas budget and profit policy.
    struct Policy {
        uint8 samePair;
        uint8 triangles;
        uint8 quads;
        uint8 sized;
        uint128 minimumSurplus;
        uint128 maximumInput;
        uint32 searchGasLimit;
        uint32 executionGasReserve;
        bool profitCurrency0;
        address beneficiary;
    }

    struct Installation {
        bool installed;
        uint64 version;
        uint64 configuredVersion;
        uint256 liabilities;
    }

    mapping(PoolId => Installation) private _installations;
    mapping(PoolId => Policy) private _policies;
    mapping(PoolId => mapping(address => uint256)) public claimable;

    error RouteRejected();

    event PolicyUpdated(PoolId indexed pool, uint64 version);
    event CycleExecuted(PoolId indexed origin, uint64 rootOperation, uint8 legs, uint128 input, uint256 surplus);
    event ProfitClaimed(PoolId indexed pool, address indexed beneficiary, address recipient, uint256 amount);

    constructor(IKernelHook kernel, ArbitrageNetwork network) KernelExtension(kernel) {
        if (address(network.KERNEL()) != address(kernel)) revert InvalidConfiguration();
        NETWORK = network;
        LIMIT_ORDERS = network.LIMIT_ORDERS();
    }

    function setPolicy(PoolKey calldata key, uint64 expectedVersion, Policy calldata policy) external publicMutation {
        PoolId pool = _validateKey(key);
        _requireRole(pool);
        Installation storage installation = _installations[pool];
        if (!installation.installed || !KERNEL.isPoolInitialized(pool) || !_registered(pool)) revert InvalidPool();
        (bool readable, uint256 flags) = _profile(pool, address(this));
        if (!readable || flags & ACTIVE != 0) revert InvalidConfiguration();
        if (installation.version != expectedVersion) revert InvalidVersion();
        _validatePolicy(policy);
        // Earned claims keep their currency even when policy changes.
        if (installation.liabilities != 0 && policy.profitCurrency0 != _policies[pool].profitCurrency0) {
            revert OutstandingObligations();
        }
        _policies[pool] = policy;
        ++installation.version;
        emit PolicyUpdated(pool, installation.version);
    }

    function profitState(PoolId pool) external view returns (Policy memory, uint64, uint64, uint256) {
        Installation memory installation = _installations[pool];
        return (_policies[pool], installation.version, installation.configuredVersion, installation.liabilities);
    }

    function claimProfit(PoolId pool, uint256 amount, address recipient) external publicMutation {
        if (recipient == address(0) || amount == 0 || amount > claimable[pool][msg.sender]) revert InvalidAmount();
        claimable[pool][msg.sender] -= amount;
        _installations[pool].liabilities -= amount;
        PoolKey memory key = KERNEL.poolKey(pool);
        Currency currency = _policies[pool].profitCurrency0 ? key.currency0 : key.currency1;
        VAULT.withdraw(pool, currency, amount, recipient);
        emit ProfitClaimed(pool, msg.sender, recipient, amount);
    }

    function onInstall(PoolKey calldata key, ExtensionSettings calldata settings) external lifecycle returns (bytes4) {
        _checkSettings(settings);
        Installation storage installation = _installations[_validateKey(key)];
        if (installation.installed) revert InvalidConfiguration();
        uint64 version = _version(settings.configuration);
        if (version != 0 && version != installation.version) revert InvalidVersion();
        installation.installed = true;
        installation.configuredVersion = version;
        return this.onInstall.selector;
    }

    function onConfigure(PoolKey calldata key, ExtensionSettings calldata, ExtensionSettings calldata settings)
        external
        lifecycle
        returns (bytes4)
    {
        _checkSettings(settings);
        Installation storage installation = _installations[_validateKey(key)];
        uint64 version = _version(settings.configuration);
        if (!installation.installed || installation.version != version) revert InvalidVersion();
        installation.configuredVersion = version;
        return this.onConfigure.selector;
    }

    function canActivate(PoolKey calldata key, ExtensionSettings calldata settings)
        external
        view
        onlyKernel
        returns (bool)
    {
        _checkSettings(settings);
        PoolId pool = _validateKey(key);
        Installation memory installation = _installations[pool];
        Policy memory policy = _policies[pool];
        uint32 limit = settings.callbackGasLimits[uint8(CallbackType.AfterSwap)];
        return installation.installed && policy.searchGasLimit != 0 && installation.version != 0
            && installation.configuredVersion == installation.version
            && _version(settings.configuration) == installation.version && _registered(pool)
            && KERNEL.isPoolInitialized(pool) && _originCompatible(pool)
            && uint256(limit) > _requiredGas(policy) + SETUP_GAS_ALLOWANCE
            && _callbackFits(pool, CallbackType.AfterSwap, limit, 1, true);
    }

    function canUninstall(PoolKey calldata key) external view onlyKernel returns (bool) {
        return !_entered && _installations[key.toId()].liabilities == 0;
    }

    function onUninstall(PoolKey calldata key, bytes calldata) external lifecycle returns (bytes4) {
        Installation storage installation = _installations[key.toId()];
        if (installation.liabilities != 0) revert OutstandingObligations();
        installation.installed = false;
        installation.configuredVersion = 0;
        delete _policies[key.toId()];
        return this.onUninstall.selector;
    }

    function onCallback(ExecutionContext calldata context, PoolKey calldata key, bytes calldata)
        external
        onlyKernel
        returns (CallbackResult memory result)
    {
        _authenticateContext(context, key);
        if (context.callback != CallbackType.AfterSwap) revert Unauthorized();
        // Nested service never starts another search, including reentry on a different pool.
        if (context.depth > 1) return result;
        // Identity was checked above; keep the nested zero-result path ahead of the root transfer lock.
        if (_entered || VAULT.transferInProgress()) revert ExecutionInProgress();
        PoolId pool = context.poolId;
        if (PoolId.unwrap(pool) != PoolId.unwrap(context.rootPoolId)) return result;
        Installation memory installation = _installations[pool];
        if (!installation.installed) return result;
        if (installation.version == 0 || installation.configuredVersion != installation.version) return result;
        // One capture per root operation: the root swap's AfterSwap runs once, nested visits returned above.
        bytes32 successSlot = keccak256(abi.encode(SUCCESS_MARKER, pool, context.rootOperationId));
        if (_marked(successSlot)) return result;
        _entered = true;
        ArbitrageNetwork.Plan memory plan = _findCycle(pool);
        if (plan.legs != 0) {
            _execute(context, key, plan);
            _mark(successSlot);
        }
        _entered = false;
    }

    /// @dev Bounded staticcall into the network. A failed, oversized or out-of-gas search returns no plan, so the
    /// root swap always completes.
    function _findCycle(PoolId pool) private view returns (ArbitrageNetwork.Plan memory plan) {
        Policy memory policy = _policies[pool];
        if (gasleft() <= _requiredGas(policy)) return plan;
        ArbitrageNetwork.Limits memory limits = ArbitrageNetwork.Limits({
            samePair: policy.samePair,
            triangles: policy.triangles,
            quads: policy.quads,
            sized: policy.sized,
            minimumSurplus: policy.minimumSurplus,
            maximumInput: policy.maximumInput
        });
        (bool success, bytes memory data) = address(NETWORK)
            .read(
                policy.searchGasLimit,
                PLAN_BYTES,
                abi.encodeCall(ArbitrageNetwork.findCycle, (pool, policy.profitCurrency0, limits))
            );
        if (!success || data.length != PLAN_BYTES) return plan;
        plan = abi.decode(data, (ArbitrageNetwork.Plan));
    }

    /// @dev Gas the callback needs at the search admission check: the search, the 1/64 the EVM keeps back from it,
    /// the execution reserve and the callback's own overhead. Activation requires this plus SETUP_GAS_ALLOWANCE, so
    /// an activated policy always passes admission when the callback receives its full limit.
    function _requiredGas(Policy memory policy) private pure returns (uint256) {
        return uint256(policy.searchGasLimit) + policy.searchGasLimit / 63 + policy.executionGasReserve
            + CALLBACK_OVERHEAD_GAS;
    }

    function _execute(ExecutionContext calldata context, PoolKey calldata origin, ArbitrageNetwork.Plan memory plan)
        private
    {
        PoolId pool = context.poolId;
        Policy memory policy = _policies[pool];
        Currency profitCurrency = policy.profitCurrency0 ? origin.currency0 : origin.currency1;
        uint256 beforeProfit = VAULT.balanceOf(pool, address(this), profitCurrency);
        // Only profit claims are held; any other balance in a cycle currency means unsettled state.
        if (beforeProfit != _installations[pool].liabilities) revert RouteRejected();
        _requireNoMiddleBalances(pool, plan, profitCurrency);
        BalanceDelta[] memory deltas = KERNEL.executeRoute(_actions(plan));
        _checkLegs(deltas, plan, policy.maximumInput);
        _requireNoMiddleBalances(pool, plan, profitCurrency);
        uint256 afterProfit = VAULT.balanceOf(pool, address(this), profitCurrency);
        if (afterProfit <= beforeProfit) revert RouteRejected();
        uint256 surplus = afterProfit - beforeProfit;
        if (surplus < policy.minimumSurplus) revert RouteRejected();
        claimable[pool][policy.beneficiary] += surplus;
        _installations[pool].liabilities += surplus;
        emit CycleExecuted(pool, context.rootOperationId, plan.legs, plan.input, surplus);
    }

    /// @dev Every leg but the last is exact output (positive amount); the last is exact input (negative amount).
    function _actions(ArbitrageNetwork.Plan memory plan) private pure returns (RouteAction[] memory actions) {
        actions = new RouteAction[](plan.legs);
        // legs <= 4
        for (uint256 k; k < plan.legs; ++k) {
            int256 amount = int256(uint256(plan.amounts[k]));
            bool zeroForOne = plan.zeroForOne[k];
            SwapParams memory params = SwapParams(
                zeroForOne,
                k + 1 < plan.legs ? amount : -amount,
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            );
            actions[k] = RouteAction(plan.keys[k], Operation.Swap, abi.encode(params), "");
        }
    }

    /// @dev Each exact-output leg delivered exactly its amount, and the closing leg consumed exactly its amount.
    function _checkLegs(BalanceDelta[] memory deltas, ArbitrageNetwork.Plan memory plan, uint128 maximumInput)
        private
        pure
    {
        if (deltas.length != plan.legs) revert RouteRejected();
        // The first leg's payment is the cycle's input in the profit currency; the policy caps it.
        bool firstZeroForOne = plan.zeroForOne[0];
        int128 firstPaid = firstZeroForOne ? deltas[0].amount0() : deltas[0].amount1();
        if (firstPaid < -int128(maximumInput)) revert RouteRejected();
        // legs <= 4
        for (uint256 k; k < plan.legs; ++k) {
            bool zeroForOne = plan.zeroForOne[k];
            int128 paid = zeroForOne ? deltas[k].amount0() : deltas[k].amount1();
            int128 received = zeroForOne ? deltas[k].amount1() : deltas[k].amount0();
            int128 amount = int128(plan.amounts[k]);
            if (paid >= 0 || received <= 0) revert RouteRejected();
            if (k + 1 < plan.legs && received != amount) revert RouteRejected();
            if (k + 1 == plan.legs && paid != -amount) revert RouteRejected();
        }
    }

    /// @dev Middle currencies must hold zero before and after the route: the cycle nets them out exactly.
    function _requireNoMiddleBalances(PoolId pool, ArbitrageNetwork.Plan memory plan, Currency profitCurrency)
        private
        view
    {
        // legs <= 4, two currencies each
        for (uint256 k; k < plan.legs; ++k) {
            _requireNoBalance(pool, plan.keys[k].currency0, profitCurrency);
            _requireNoBalance(pool, plan.keys[k].currency1, profitCurrency);
        }
    }

    function _requireNoBalance(PoolId pool, Currency currency, Currency profitCurrency) private view {
        if (Currency.unwrap(currency) == Currency.unwrap(profitCurrency)) return;
        if (VAULT.balanceOf(pool, address(this), currency) != 0) revert RouteRejected();
    }

    /// @dev Only reviewed pricing profiles on the swapped pool: at most the LimitOrder book before and this hook after.
    function _originCompatible(PoolId pool) private view returns (bool) {
        address[] memory beforeOrder = KERNEL.callbackOrder(pool, CallbackType.BeforeSwap);
        address[] memory afterOrder = KERNEL.callbackOrder(pool, CallbackType.AfterSwap);
        if (beforeOrder.length > 1 || afterOrder.length > 1) return false;
        if (beforeOrder.length == 1 && beforeOrder[0] != address(LIMIT_ORDERS)) return false;
        if (afterOrder.length == 1 && afterOrder[0] != address(this)) return false;
        return true;
    }

    function _registered(PoolId pool) private view returns (bool) {
        uint32 index = NETWORK.poolIndexOf(pool);
        return index != 0 && NETWORK.poolRecord(index).active;
    }

    function _validatePolicy(Policy calldata policy) private pure {
        if (policy.samePair > MAX_TOP_POOLS) revert InvalidConfiguration();
        if (policy.triangles > MAX_TRIANGLES) revert InvalidConfiguration();
        if (policy.quads > MAX_QUADS) revert InvalidConfiguration();
        if (policy.sized == 0 || policy.sized > MAX_SIZED_CYCLES) revert InvalidConfiguration();
        if (policy.minimumSurplus == 0) revert InvalidConfiguration();
        if (policy.maximumInput == 0 || policy.maximumInput > OrderMath.MAX_DELTA) revert InvalidConfiguration();
        // The search's gas guards keep one quote attempt and the sizing rounds; below that it never finds a plan.
        uint256 minimumSearch =
            SEARCH_ATTEMPT_RESERVE_GAS + uint256(policy.sized) * SEARCH_SIZE_GAS + MIN_SEARCH_WORK_GAS;
        if (policy.searchGasLimit < minimumSearch || policy.searchGasLimit > MAX_SEARCH_GAS) {
            revert InvalidConfiguration();
        }
        if (policy.executionGasReserve < MIN_EXECUTION_RESERVE || policy.executionGasReserve > MAX_EXECUTION_RESERVE) {
            revert InvalidConfiguration();
        }
        if (policy.beneficiary == address(0)) revert InvalidConfiguration();
    }

    function _checkSettings(ExtensionSettings calldata settings) private pure {
        if (settings.callbackMask != CALLBACK_MASK || !settings.optionalCallbacks || !settings.allowNesting) {
            revert InvalidConfiguration();
        }
    }

    function _marked(bytes32 slot) private view returns (bool value) {
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _mark(bytes32 slot) private {
        assembly ("memory-safe") { tstore(slot, 1) }
    }
}
