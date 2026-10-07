// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {KernelHook} from "../../src/KernelHook.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {KernelHookConstants} from "../../src/libraries/KernelHookConstants.sol";
import {
    CALLBACK_COUNT,
    CallbackType,
    ExecutionContext,
    ExtensionSettings,
    Operation,
    RouteAction
} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev The callback gas budget of pool 0. The router's 5,000,000 limit needs more than the default budget.
uint32 constant POOL_0_BUDGET = 8_000_000;

/// @notice The actions of the invariant test. The fuzzer calls these functions in random order with random inputs.
/// @dev Each function is one transaction. If it reverts, the fuzzer discards it, so a function can try an action
/// that is not valid now (for example a route swap that the router's vault balance cannot pay for) without a guard.
/// A discarded call also discards any check inside it, so the handler does not assert. A probe that sees an unsafe
/// outcome adds to `violations` instead, and the invariant test requires zero.
/// The handler keeps a model (ghost state) of the route liquidity, of each modeled installation's vault balances,
/// of pool 0's roles and depth limit, and of the pools that it prepared. It updates the model only from the
/// requested amounts and from the results that each successful action reports.
contract KernelHookHandler is Test {
    /// @notice The contracts and pools that the invariant test sets up.
    struct Setup {
        KernelHook hook;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTestNoChecks liquidityRouter;
        PoolDonateTest donateRouter;
        PoolKey[3] keys;
        MockExtension[3] extensions;
        MockExtension observer;
        MockExtension relay;
        MockExtension[2] overriders;
    }

    /// @dev The modeled installations. Pool 0: extension 0 starts routes (required), extension 1 is optional and can
    /// fail, extension 2 charges a fee. Pool 1: the relay routes from inside a nested operation (optional).
    uint256 internal constant ROUTER = 0;
    uint256 internal constant OPTIONAL = 1;
    uint256 internal constant FEE_TAKER = 2;
    uint256 internal constant RELAY = 3;
    uint256 internal constant MODELED_INSTALLATIONS = 4;

    /// @dev Currency indexes of the model: the two tokens, then the native currency.
    uint256 internal constant NATIVE = 2;
    uint256 internal constant CURRENCY_COUNT = 3;

    /// @dev Pool 0 is the main pool, pool 1 the route pool, and pool 2 the native pool with a dynamic LP fee.
    uint256 internal constant NATIVE_POOL = 2;

    int24 internal constant ROUTE_TICK_LOWER = -60;
    int24 internal constant ROUTE_TICK_UPPER = 60;

    /// @dev The three setup pools plus at most 13 pools that the handler prepares.
    uint256 internal constant MAX_PREPARED_POOLS = 16;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    KernelHook public immutable hook;
    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    /// @dev The router without balance assertions: v4's checked router assumes that an addition always costs
    /// the caller and a removal always pays it, which fees and very small amounts can break.
    PoolModifyLiquidityTestNoChecks internal immutable liquidityRouter;
    PoolDonateTest internal immutable donateRouter;
    /// @dev An optional extension of the route pool, so that routes run nested extension calls.
    MockExtension public immutable observer;
    /// @dev An optional extension of the route pool that allows nesting. routeRecursive gives it a route.
    MockExtension public immutable relay;

    PoolKey[3] internal _keys;
    Currency[CURRENCY_COUNT] internal _currencies;
    MockExtension[3] internal _extensions;
    /// @dev Two optional extensions of the native pool that return the fee overrides in `_overrides`.
    MockExtension[2] internal _overriders;
    uint24[2] internal _overrides;
    uint256[2] internal _handlerLiquidity;
    int128 internal _fee;
    address[3] internal _roleAccounts;
    PoolKey[] internal _preparedKeys;
    mapping(PoolId => bool) internal _prepared;

    /// @notice The route liquidity that the requested additions and removals add up to.
    uint256 public ghostRouteLiquidity;
    /// @notice The vault balance of each modeled installation in each currency.
    int256[CURRENCY_COUNT][MODELED_INSTALLATIONS] public ghostBalance;
    /// @notice Pool 0's roles of the three role accounts: index 0 is the configurer role, index 1 the admin role.
    bool[2][3] public ghostRole;
    /// @notice Pool 0's maximum operation depth.
    uint8 public ghostMaxOperationDepth = KernelHookConstants.DEFAULT_MAX_OPERATION_DEPTH;
    mapping(PoolId => bool) public ghostInitialized;

    /// @notice The number of unsafe outcomes that the probes saw, and the last one.
    uint256 public violations;
    string public lastViolation;

    mapping(string => uint256) public successfulCalls;

    constructor(Setup memory setup) {
        hook = setup.hook;
        manager = setup.swapRouter.manager();
        swapRouter = setup.swapRouter;
        liquidityRouter = setup.liquidityRouter;
        donateRouter = setup.donateRouter;
        observer = setup.observer;
        relay = setup.relay;
        _extensions = setup.extensions;
        _overriders = setup.overriders;
        _currencies = [setup.keys[0].currency0, setup.keys[0].currency1, Currency.wrap(address(0))];
        _roleAccounts = [address(0xA11CE), address(0xB0B), address(0xCA401)];
        // The legacy compiler cannot copy a memory array of structs to storage at once.
        // poolIndex < 3
        for (uint256 i; i < 3; ++i) {
            _keys[i] = setup.keys[i];
            _preparedKeys.push(setup.keys[i]);
            _prepared[setup.keys[i].toId()] = true;
            ghostInitialized[setup.keys[i].toId()] = true;
        }
        // tokenIndex < 2
        for (uint256 i; i < 2; ++i) {
            IERC20 token = IERC20(Currency.unwrap(_currencies[i]));
            token.approve(address(setup.swapRouter), type(uint256).max);
            token.approve(address(setup.liquidityRouter), type(uint256).max);
            token.approve(address(setup.donateRouter), type(uint256).max);
        }
    }

    /// @notice Receives native currency from vault withdrawals and from the refunds of the test routers.
    receive() external payable {}

    // ---------------------------------------------------------------- pool operations

    function swap(uint256 poolSeed, bool zeroForOne, uint256 amount, bool exactOutput) external {
        amount = bound(amount, 1e6, exactOutput ? 1e12 : 1e14);
        SwapParams memory parameters = _exactInput(zeroForOne, amount);
        if (exactOutput) parameters.amountSpecified = int256(amount);
        _swap(_keys[poolSeed % 2], parameters);
        ++successfulCalls["swap"];
    }

    function addLiquidity(uint256 poolSeed, uint256 liquidity) external {
        uint256 index = poolSeed % 2;
        liquidity = bound(liquidity, 1e9, 1e17);
        liquidityRouter.modifyLiquidity(_keys[index], _handlerRange(int256(liquidity)), "");
        _handlerLiquidity[index] += liquidity;
        ++successfulCalls["addLiquidity"];
    }

    function removeLiquidity(uint256 poolSeed, uint256 liquidity) external {
        uint256 index = poolSeed % 2;
        if (_handlerLiquidity[index] == 0) return;
        liquidity = bound(liquidity, 1, _handlerLiquidity[index]);
        liquidityRouter.modifyLiquidity(_keys[index], _handlerRange(-int256(liquidity)), "");
        _handlerLiquidity[index] -= liquidity;
        ++successfulCalls["removeLiquidity"];
    }

    function donate(uint256 poolSeed, uint256 amount) external {
        amount = bound(amount, 1, 1e12);
        donateRouter.donate(_keys[poolSeed % 2], amount, amount, "");
        ++successfulCalls["donate"];
    }

    /// @notice Swaps exact input on the native pool, where the two overriders can set the LP fee of the swap.
    /// v4 rejects exact output at the maximum LP fee, so this action uses exact input only.
    function swapDynamic(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 1e6, 1e14);
        uint256[2] memory overriderCalls = _overriderCalls();
        vm.recordLogs();
        swapRouter.swap{value: zeroForOne ? amount : 0}(
            _keys[NATIVE_POOL], _exactInput(zeroForOne, amount), PoolSwapTest.TestSettings(false, false), ""
        );
        _checkDynamicFee(vm.getRecordedLogs());
        _checkOverriderContexts(overriderCalls, PoolId.wrap(0), address(0));
        ++successfulCalls["swapDynamic"];
    }

    // ---------------------------------------------------------------- extension behavior

    /// @notice Sets the amount of currency0 that the fee taker charges (positive) or pays (negative) in beforeSwap.
    function setFee(int256 fee) external {
        _fee = int128(bound(fee, -1e6, 1e6));
        _extensions[FEE_TAKER].setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(_fee, 0, 0, false, 0));
    }

    /// @notice Makes an optional extension (of pool 0 or of the route pool) fail, or stop failing, in one callback.
    function setOptionalFailure(bool routePool, uint256 callbackSeed, bool shouldRevert) external {
        MockExtension target = routePool ? observer : _extensions[OPTIONAL];
        CallbackType callback = CallbackType(2 + callbackSeed % 8);
        target.setBehavior(callback, MockExtension.Behavior(0, 0, 0, shouldRevert, 0));
    }

    /// @notice Sets the fee override that one overrider of the native pool returns in beforeSwap: none, a valid one,
    /// one above the maximum LP fee, or a nonzero value without the override flag.
    function setFeeOverride(bool second, uint256 seed) external {
        uint24 fee = uint24((seed >> 2) % (LPFeeLibrary.MAX_LP_FEE + 1));
        uint256 kind = seed % 4;
        uint24 value;
        if (kind == 1) value = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        if (kind == 2) value = (LPFeeLibrary.MAX_LP_FEE + 1 + fee % 1000) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        if (kind == 3) value = fee == 0 ? 1 : fee;
        uint256 index = second ? 1 : 0;
        _overrides[index] = value;
        _overriders[index].setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, value, false, 0));
    }

    // ---------------------------------------------------------------- vault

    function deposit(uint256 installationSeed, uint256 currencySeed, uint256 amount) external {
        uint256 index = installationSeed % MODELED_INSTALLATIONS;
        uint256 currencyIndex = currencySeed % CURRENCY_COUNT;
        _deposit(index, currencyIndex, bound(amount, 1, 1e16));
        ++successfulCalls["deposit"];
    }

    function withdraw(uint256 installationSeed, uint256 currencySeed, uint256 amount) external {
        uint256 index = installationSeed % MODELED_INSTALLATIONS;
        uint256 currencyIndex = currencySeed % CURRENCY_COUNT;
        int256 balance = ghostBalance[index][currencyIndex];
        if (balance <= 0) return;
        _withdraw(index, currencyIndex, bound(amount, 1, uint256(balance)));
        ++successfulCalls["withdraw"];
    }

    // ---------------------------------------------------------------- routes

    /// @notice In afterSwap of the main pool, the router swaps on the route pool.
    function routeSwap(bool zeroForOne, uint256 amount, bool prepare) external {
        amount = bound(amount, 1e6, 1e12);
        _prepare(prepare, ROUTER);
        _swapWithRoute(_swapAction(_keys[1], zeroForOne, amount));
        ++successfulCalls["routeSwap"];
    }

    /// @notice In afterSwap of the main pool, the router changes its liquidity in the route pool.
    function routeLiquidity(int256 liquidityDelta, bool prepare) external {
        liquidityDelta = bound(liquidityDelta, -int256(ghostRouteLiquidity), 1e15);
        _prepare(prepare, ROUTER);
        _swapWithRoute(_routeLiquidityAction(liquidityDelta));
        ghostRouteLiquidity = uint256(int256(ghostRouteLiquidity) + liquidityDelta);
        ++successfulCalls["routeLiquidity"];
    }

    /// @notice In afterSwap of the main pool, the router swaps on the native pool with its native and token balances.
    function routeNativeSwap(bool zeroForOne, uint256 amount, bool prepare) external {
        amount = bound(amount, 1e6, 1e12);
        _prepare(prepare, ROUTER);
        uint256[2] memory overriderCalls = _overriderCalls();
        vm.recordLogs();
        _swapWithRoute(_swapAction(_keys[NATIVE_POOL], zeroForOne, amount));
        _checkDynamicFee(vm.getRecordedLogs());
        _checkOverriderContexts(overriderCalls, _keys[0].toId(), address(_extensions[ROUTER]));
        ++successfulCalls["routeNativeSwap"];
    }

    /// @notice Three levels of operations: in afterSwap of pool 0, the router swaps on pool 1, and in that nested
    /// afterSwap the relay swaps on the native pool. Each route settles from its own installation's balances.
    function routeRecursive(bool zeroForOne, uint256 amount, bool prepare) external {
        amount = bound(amount, 1e6, 1e10);
        _prepare(prepare, ROUTER);
        _prepare(prepare, RELAY);
        uint256[2] memory overriderCalls = _overriderCalls();
        uint256 relayCalls = relay.callCount(CallbackType.AfterSwap);
        relay.addRouteAction(CallbackType.AfterSwap, _swapAction(_keys[NATIVE_POOL], zeroForOne, amount));
        vm.recordLogs();
        _swapWithRoute(_swapAction(_keys[1], true, 1e9));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        relay.clearRoute(CallbackType.AfterSwap);
        // The relay is optional: KernelHook skips it if its route fails, and the outer route still succeeds.
        require(relay.callCount(CallbackType.AfterSwap) > relayCalls, "relay route did not run");
        // The relay's route is the third operation: the root pool must allow depth 3.
        if (ghostMaxOperationDepth < 3) _violation("a third-level route ran above the root pool's depth limit");
        _addResults(RELAY, _keys[NATIVE_POOL], relay.lastRouteResults());
        _checkDynamicFee(logs);
        _checkOverriderContexts(overriderCalls, _keys[1].toId(), address(relay));
        ++successfulCalls["routeRecursive"];
    }

    /// @notice In afterSwap of pool 0, the optional extension donates to pool 0: a nested operation on its own pool.
    /// KernelHook allows it only from an after callback in which every required extension has already run, so that
    /// no required extension sees the pool change under it. A route that ran while an active required extension came
    /// later in the afterSwap order is a violation. (The required router can never do this: it is still running.)
    function routeSamePoolDonate(uint256 amount, bool prepare) external {
        amount = bound(amount, 1, 1e9);
        _prepare(prepare, OPTIONAL);
        MockExtension optional = _extensions[OPTIONAL];
        bool requiredStillToRun = _requiredRunsAfter(OPTIONAL);
        uint256 calls = optional.callCount(CallbackType.AfterSwap);
        optional.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction({
                key: _keys[0], operation: Operation.Donate, parameters: abi.encode(amount, amount), hookData: ""
            })
        );
        _swap(_keys[0], _exactInput(true, 1e10));
        optional.clearRoute(CallbackType.AfterSwap);
        // The extension is optional: KernelHook skips it if its route fails, and the swap still succeeds.
        require(optional.callCount(CallbackType.AfterSwap) > calls, "same-pool route did not run");
        if (requiredStillToRun) _violation("a nested operation entered pool 0 before its required extensions ran");
        if (ghostMaxOperationDepth < 2) _violation("a route ran above the root pool's depth limit");
        _addResults(OPTIONAL, _keys[0], optional.lastRouteResults());
        ++successfulCalls["routeSamePoolDonate"];
    }

    /// @notice The router closes part of its route position through unwindPositions, which needs an inactive
    /// installation. The router is deactivated for the call and then activated again, if it was active.
    function unwind(uint256 liquidity) external {
        if (ghostRouteLiquidity == 0) return;
        liquidity = bound(liquidity, 1, ghostRouteLiquidity);
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _routeLiquidityAction(-int256(liquidity));
        bool active = _isActive(ROUTER);
        if (active) hook.deactivateExtension(_keys[0], _extension(ROUTER));
        BalanceDelta[] memory results = _extensions[ROUTER].unwindPositions(_keys[0], actions);
        if (active) hook.activateExtension(_keys[0], _extension(ROUTER));
        _addResults(ROUTER, _keys[1], results);
        ghostRouteLiquidity -= liquidity;
        ++successfulCalls["unwind"];
    }

    // ---------------------------------------------------------------- management of pool 0

    /// @notice Deactivates an active extension, or activates an inactive one.
    function toggleActive(uint256 extensionSeed) external {
        uint256 index = extensionSeed % 3;
        if (_isActive(index)) hook.deactivateExtension(_keys[0], _extension(index));
        else hook.activateExtension(_keys[0], _extension(index));
        ++successfulCalls["toggleActive"];
    }

    /// @notice Sets a new order of the three swap subscribers in one multicall: deactivate the active ones, set the
    /// order of both swap callbacks, and activate the same ones again.
    function reorder(uint256 permutationSeed) external {
        address[] memory order = _permutation(permutationSeed % 6);
        (bool[3] memory active, bytes[] memory calls, uint256 count) = _startBatch();
        calls[count++] = abi.encodeCall(IKernelHook.setCallbackOrder, (_keys[0], CallbackType.BeforeSwap, order));
        calls[count++] = abi.encodeCall(IKernelHook.setCallbackOrder, (_keys[0], CallbackType.AfterSwap, order));
        hook.multicall(_finishBatch(active, calls, count));
        ++successfulCalls["reorder"];
    }

    /// @notice Gives the optional extension a new callback gas limit and a new configuration size, in one multicall
    /// on a live pool. The callback gas limit changes the invocation gas that KernelHook reserves for each call of
    /// the extension.
    function reconfigure(uint256 gasLimit, uint256 configurationBytes) external {
        (, ExtensionSettings memory settings,) =
            hook.extensionConfiguration(_keys[0].toId(), address(_extensions[OPTIONAL]));
        uint32 limit = uint32(bound(gasLimit, 200_000, 600_000));
        // i < CALLBACK_COUNT
        for (uint256 i; i < settings.callbackGasLimits.length; ++i) {
            settings.callbackGasLimits[i] = limit;
        }
        settings.configuration = new bytes(bound(configurationBytes, 0, 1024));
        bool active = _isActive(OPTIONAL);
        bytes[] memory calls = new bytes[](3);
        uint256 count;
        if (active) calls[count++] = abi.encodeCall(IKernelHook.deactivateExtension, (_keys[0], _extension(OPTIONAL)));
        calls[count++] = abi.encodeCall(IKernelHook.configureExtension, (_keys[0], _extension(OPTIONAL), settings));
        if (active) calls[count++] = abi.encodeCall(IKernelHook.activateExtension, (_keys[0], _extension(OPTIONAL)));
        hook.multicall(_shorten(calls, count));
        ++successfulCalls["reconfigure"];
    }

    /// @notice Sets pool 0's maximum operation depth, in one multicall (execution limits need inactive subscribers).
    /// A route from pool 0 needs depth 2, and the relay's route needs depth 3.
    function setDepthLimit(uint256 depth) external {
        uint8 maxDepth = uint8(bound(depth, 1, KernelHookConstants.MAX_OPERATION_DEPTH));
        uint32[CALLBACK_COUNT] memory budgets;
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = POOL_0_BUDGET;
        }
        (bool[3] memory active, bytes[] memory calls, uint256 count) = _startBatch();
        calls[count++] = abi.encodeCall(IKernelHook.setExecutionLimits, (_keys[0], maxDepth, budgets));
        hook.multicall(_finishBatch(active, calls, count));
        ghostMaxOperationDepth = maxDepth;
        ++successfulCalls["setDepthLimit"];
    }

    /// @notice Removes one pool-0 extension and installs it again with the same settings, in one multicall that
    /// rolls back as a whole. Removal needs no vault balance and no open route position. With withdrawFirst, the
    /// extension first withdraws all of its balances, so that the removal can succeed.
    function removeAndReinstall(uint256 extensionSeed, bool withdrawFirst) external {
        uint256 index = extensionSeed % 3;
        if (withdrawFirst) {
            // currencyIndex < CURRENCY_COUNT
            for (uint256 c; c < CURRENCY_COUNT; ++c) {
                if (ghostBalance[index][c] > 0) _withdraw(index, c, uint256(ghostBalance[index][c]));
            }
        }
        bool removable = !_isFunded(index) && (index != ROUTER || ghostRouteLiquidity == 0);
        (, ExtensionSettings memory settings,) =
            hook.extensionConfiguration(_keys[0].toId(), address(_extensions[index]));
        (bool[3] memory active, bytes[] memory calls, uint256 count) = _startBatch();
        calls[count++] = abi.encodeCall(IKernelHook.removeExtension, (_keys[0], _extension(index)));
        calls[count++] = abi.encodeCall(IKernelHook.installExtension, (_keys[0], _extension(index), settings));
        try hook.multicall(_finishBatch(active, calls, count)) {
            if (!removable) _violation("an extension with vault funds or a route position was removed");
            ++successfulCalls["removeAndReinstall"];
        } catch {
            if (removable) _violation("an extension without obligations could not be removed and installed again");
        }
    }

    /// @notice Grants or revokes the configurer or the admin role of one of three accounts on pool 0. The handler and
    /// the test contract keep their roles, so the other actions keep working and the last admin is never revoked.
    function changeRole(uint256 accountSeed, bool admin, bool grant) external {
        uint256 index = accountSeed % 3;
        bytes32 role = admin ? KernelHookConstants.POOL_ADMIN_ROLE : KernelHookConstants.CONFIGURER_ROLE;
        if (grant) hook.grantPoolRole(_keys[0], role, _roleAccounts[index]);
        else hook.revokePoolRole(_keys[0], role, _roleAccounts[index]);
        ghostRole[index][admin ? 1 : 0] = grant;
        ++successfulCalls["changeRole"];
    }

    /// @notice One role account makes an admin-only call and a configurer call that change nothing. Each call must
    /// succeed exactly when the model gives the account that right. An admin also has the configurer rights.
    function probeAuthority(uint256 accountSeed) external {
        uint256 index = accountSeed % 3;
        bool admin = ghostRole[index][1];
        bool configurer = admin || ghostRole[index][0];
        // Revoking a role that the account does not have returns early, after the admin check.
        vm.prank(_roleAccounts[index]);
        try hook.revokePoolRole(_keys[0], KernelHookConstants.CONFIGURER_ROLE, address(0xdead)) {
            if (!admin) _violation("an account without the admin role passed the admin check");
        } catch {
            if (admin) _violation("an admin failed the admin check");
        }
        // No extension subscribes to BeforeInitialize, so its order is empty and stays empty.
        vm.prank(_roleAccounts[index]);
        try hook.setCallbackOrder(_keys[0], CallbackType.BeforeInitialize, new address[](0)) {
            if (!configurer) _violation("an account without the configurer role passed the configurer check");
        } catch {
            if (configurer) _violation("a configurer failed the configurer check");
        }
        ++successfulCalls["probeAuthority"];
    }

    // ---------------------------------------------------------------- new pools

    /// @notice Prepares a pool with a new key, or (with repeat) tries a key that is already prepared. preparePool
    /// accepts a tick spacing in [1, 32767] and a static LP fee of at most 1,000,000 or the dynamic fee flag.
    function preparePool(uint256 feeSeed, int256 tickSpacingSeed, bool repeat) external {
        PoolKey memory key;
        if (repeat) {
            key = _preparedKeys[feeSeed % _preparedKeys.length];
        } else {
            if (_preparedKeys.length >= MAX_PREPARED_POOLS) return;
            uint24 fee = feeSeed % 8 == 0
                ? LPFeeLibrary.DYNAMIC_FEE_FLAG
                : uint24(bound(feeSeed, 0, LPFeeLibrary.MAX_LP_FEE + 100));
            int24 tickSpacing = int24(bound(tickSpacingSeed, -1, TickMath.MAX_TICK_SPACING + 1));
            key = PoolKey(_currencies[0], _currencies[1], fee, tickSpacing, IHooks(address(hook)));
        }
        PoolId poolId = key.toId();
        bool feeIsValid = key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG || key.fee <= LPFeeLibrary.MAX_LP_FEE;
        bool tickSpacingIsValid =
            key.tickSpacing >= TickMath.MIN_TICK_SPACING && key.tickSpacing <= TickMath.MAX_TICK_SPACING;
        bool expected = feeIsValid && tickSpacingIsValid && !_prepared[poolId];
        try hook.preparePool(key) {
            if (!expected) _violation("preparePool accepted an invalid or already prepared key");
            _preparedKeys.push(key);
            _prepared[poolId] = true;
            ++successfulCalls["preparePool"];
        } catch {
            if (expected) _violation("preparePool rejected a new valid key");
        }
    }

    /// @notice Another account tries to initialize a pool that the handler prepared, then the handler (the pool's
    /// initializer) tries. Only the initializer's first initialization can succeed.
    function initializePrepared(uint256 seed) external {
        if (_preparedKeys.length == 3) return;
        PoolKey memory key = _preparedKeys[3 + seed % (_preparedKeys.length - 3)];
        PoolId poolId = key.toId();
        vm.prank(_roleAccounts[seed % 3]);
        try manager.initialize(key, SQRT_PRICE_1_1) {
            _violation("an account other than the initializer initialized a pool");
        } catch {}
        bool expected = !ghostInitialized[poolId];
        try manager.initialize(key, SQRT_PRICE_1_1) {
            if (!expected) _violation("a pool was initialized twice");
            ghostInitialized[poolId] = true;
            ++successfulCalls["initializePrepared"];
        } catch {
            if (expected) _violation("the initializer could not initialize its prepared pool");
        }
    }

    // ---------------------------------------------------------------- views for the invariant test

    /// @notice The router's liquidity in its one route position, as the route executor records it.
    function trackedRouteLiquidity() public view returns (uint256) {
        return hook.ROUTE_EXECUTOR()
            .positionLiquidity(
                _keys[0].toId(),
                address(_extensions[ROUTER]),
                _keys[1].toId(),
                ROUTE_TICK_LOWER,
                ROUTE_TICK_UPPER,
                bytes32(0)
            );
    }

    function roleAccount(uint256 index) external view returns (address) {
        return _roleAccounts[index];
    }

    function preparedKeyCount() external view returns (uint256) {
        return _preparedKeys.length;
    }

    function preparedKey(uint256 index) external view returns (PoolKey memory) {
        return _preparedKeys[index];
    }

    // ---------------------------------------------------------------- helpers

    function _swapWithRoute(RouteAction memory action) private {
        MockExtension router = _extensions[ROUTER];
        uint256 calls = router.callCount(CallbackType.AfterSwap);
        router.addRouteAction(CallbackType.AfterSwap, action);
        _swap(_keys[0], _exactInput(true, 1e10));
        router.clearRoute(CallbackType.AfterSwap);
        // KernelHook skips an inactive router, so the swap succeeds without the route. That call must not count.
        require(router.callCount(CallbackType.AfterSwap) > calls, "route did not run");
        // A route from pool 0 is the second operation: the root pool must allow depth 2.
        if (ghostMaxOperationDepth < 2) _violation("a route ran above the root pool's depth limit");
        _addResults(ROUTER, action.key, router.lastRouteResults());
    }

    /// @dev Every swap of pool 0 in which the fee taker runs moves its fee in currency0.
    function _swap(PoolKey memory key, SwapParams memory parameters) private {
        MockExtension feeTaker = _extensions[FEE_TAKER];
        uint256 feeCalls = feeTaker.callCount(CallbackType.BeforeSwap);
        swapRouter.swap(key, parameters, PoolSwapTest.TestSettings(false, false), "");
        uint256 charged = feeTaker.callCount(CallbackType.BeforeSwap) - feeCalls;
        ghostBalance[FEE_TAKER][0] += int256(charged) * _fee;
    }

    /// @dev The native pool must run exactly one swap, at the first valid override in callback order, or at the
    /// pool's stored LP fee (zero for a new dynamic-fee pool) when no override is valid. KernelHook skips an invalid
    /// override, and a second override after a valid one (MultipleFeeOverrides), because both overriders are optional.
    /// A skip for gas would also change the fee: that is a finding too.
    function _checkDynamicFee(Vm.Log[] memory logs) private {
        bytes32 poolId = PoolId.unwrap(_keys[NATIVE_POOL].toId());
        uint256 swaps;
        // logs.length is bounded by the gas of one call
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager)) continue;
            if (logs[i].topics[0] != IPoolManager.Swap.selector) continue;
            if (logs[i].topics[1] != poolId) continue;
            (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            if (fee != _expectedDynamicFee()) _violation("the native pool's swap fee differs from the override model");
            ++swaps;
        }
        if (swaps != 1) _violation("the native pool did not run exactly one swap");
    }

    function _expectedDynamicFee() private view returns (uint24) {
        // overrider < 2
        for (uint256 i; i < 2; ++i) {
            if (_isValidOverride(_overrides[i])) return _overrides[i] & LPFeeLibrary.REMOVE_OVERRIDE_MASK;
        }
        return 0;
    }

    function _isValidOverride(uint24 value) private pure returns (bool) {
        if (value & LPFeeLibrary.OVERRIDE_FEE_FLAG == 0) return false;
        return value & LPFeeLibrary.REMOVE_OVERRIDE_MASK <= LPFeeLibrary.MAX_LP_FEE;
    }

    function _overriderCalls() private view returns (uint256[2] memory calls) {
        // overrider < 2
        for (uint256 k; k < 2; ++k) {
            calls[k] = _overriders[k].callCount(CallbackType.BeforeSwap);
        }
    }

    /// @dev Each overrider that ran (its call count grew; a skipped attempt rolls back) must see the origin that
    /// KernelHook takes from the parent operation. The second one must see the first one's fee override as its prior
    /// result, or zero if KernelHook skipped the first one's invalid override.
    function _checkOverriderContexts(uint256[2] memory callsBefore, PoolId originPoolId, address originExtension)
        private
    {
        // overrider < 2
        for (uint256 k; k < 2; ++k) {
            if (_overriders[k].callCount(CallbackType.BeforeSwap) == callsBefore[k]) continue;
            ExecutionContext memory context = _overriders[k].lastContext();
            if (context.originExtension != originExtension) _violation("an extension saw the wrong origin extension");
            if (PoolId.unwrap(context.originPoolId) != PoolId.unwrap(originPoolId)) {
                _violation("an extension saw the wrong origin pool");
            }
            uint24 expectedPrior = k == 1 && _isValidOverride(_overrides[0]) ? _overrides[0] : 0;
            if (context.prior.feeOverride != expectedPrior) _violation("an extension saw the wrong prior result");
        }
    }

    function _deposit(uint256 index, uint256 currencyIndex, uint256 amount) private {
        MockExtension installation = _installation(index);
        Currency currency = _currencies[currencyIndex];
        if (currencyIndex == NATIVE) {
            installation.deposit{value: amount}(_installationPool(index), currency, amount);
        } else {
            IERC20(Currency.unwrap(currency)).transfer(address(installation), amount);
            installation.deposit(_installationPool(index), currency, amount);
        }
        ghostBalance[index][currencyIndex] += int256(amount);
    }

    /// @dev With prepare, a route action first removes the common reasons that its route cannot run: an inactive
    /// routing extension, a low vault balance, an optional extension set to fail in afterSwap, and a fee rebate that
    /// the fee taker cannot pay. Long runs then reach routes more often. Without it, the action tries the route in the
    /// state that the earlier actions left. The model counts these deposits like the deposit action's.
    function _prepare(bool prepare, uint256 index) private {
        if (!prepare) return;
        if (index != RELAY && !_isActive(index)) hook.activateExtension(_keys[0], _extension(index));
        if (index == OPTIONAL) {
            _extensions[OPTIONAL].setBehavior(CallbackType.AfterSwap, MockExtension.Behavior(0, 0, 0, false, 0));
        }
        // currencyIndex < CURRENCY_COUNT
        for (uint256 c; c < CURRENCY_COUNT; ++c) {
            if (ghostBalance[index][c] < 1e15) _deposit(index, c, 1e16);
        }
        if (_fee < 0 && ghostBalance[FEE_TAKER][0] < -int256(_fee)) _deposit(FEE_TAKER, 0, 1e16);
    }

    /// @dev A route result is the PoolManager delta that the vault settles for the routing installation, in the
    /// currency order of the target pool: a negative amount is paid from its balance, and a positive amount is
    /// credited to it.
    function _addResults(uint256 index, PoolKey memory target, BalanceDelta[] memory results) private {
        uint256 index0 = _currencyIndex(target.currency0);
        uint256 index1 = _currencyIndex(target.currency1);
        // results.length <= MAX_ACTIONS
        for (uint256 i; i < results.length; ++i) {
            ghostBalance[index][index0] += results[i].amount0();
            ghostBalance[index][index1] += results[i].amount1();
        }
    }

    function _withdraw(uint256 index, uint256 currencyIndex, uint256 amount) private {
        _installation(index).withdraw(_installationPool(index), _currencies[currencyIndex], amount, address(this));
        ghostBalance[index][currencyIndex] -= int256(amount);
    }

    function _violation(string memory description) private {
        ++violations;
        lastViolation = description;
    }

    /// @dev Starts a management batch for pool 0 with the deactivation of its active extensions: most management
    /// calls need inactive subscribers. _finishBatch adds the activation of the same extensions.
    function _startBatch() private view returns (bool[3] memory active, bytes[] memory calls, uint256 count) {
        active = [_isActive(0), _isActive(1), _isActive(2)];
        calls = new bytes[](10);
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            if (active[j]) calls[count++] = abi.encodeCall(IKernelHook.deactivateExtension, (_keys[0], _extension(j)));
        }
    }

    function _finishBatch(bool[3] memory active, bytes[] memory calls, uint256 count)
        private
        view
        returns (bytes[] memory)
    {
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            if (active[j]) calls[count++] = abi.encodeCall(IKernelHook.activateExtension, (_keys[0], _extension(j)));
        }
        return _shorten(calls, count);
    }

    /// @dev Whether an active required extension comes after `index` in pool 0's afterSwap order. The router and the
    /// fee taker are required; the optional extension is not.
    function _requiredRunsAfter(uint256 index) private view returns (bool) {
        address[] memory order = hook.callbackOrder(_keys[0].toId(), CallbackType.AfterSwap);
        bool after_;
        // order.length == 3
        for (uint256 i; i < order.length; ++i) {
            if (order[i] == address(_extensions[index])) {
                after_ = true;
                continue;
            }
            if (!after_) continue;
            if (order[i] == address(_extensions[OPTIONAL])) continue;
            if (order[i] == address(_extensions[ROUTER]) && _isActive(ROUTER)) return true;
            if (order[i] == address(_extensions[FEE_TAKER]) && _isActive(FEE_TAKER)) return true;
        }
        return false;
    }

    function _isFunded(uint256 index) private view returns (bool) {
        // currencyIndex < CURRENCY_COUNT
        for (uint256 c; c < CURRENCY_COUNT; ++c) {
            if (ghostBalance[index][c] != 0) return true;
        }
        return false;
    }

    function _isActive(uint256 index) private view returns (bool active) {
        (active,,) = hook.extensionConfiguration(_keys[0].toId(), address(_extensions[index]));
    }

    function _extension(uint256 index) private view returns (IHookExtension) {
        return IHookExtension(address(_extensions[index]));
    }

    function _installation(uint256 index) private view returns (MockExtension) {
        return index == RELAY ? relay : _extensions[index];
    }

    function _installationPool(uint256 index) private view returns (PoolId) {
        return index == RELAY ? _keys[1].toId() : _keys[0].toId();
    }

    function _currencyIndex(Currency currency) private view returns (uint256) {
        if (Currency.unwrap(currency) == address(0)) return NATIVE;
        return Currency.unwrap(currency) == Currency.unwrap(_currencies[0]) ? 0 : 1;
    }

    function _permutation(uint256 index) private view returns (address[] memory order) {
        uint8[3][6] memory permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
        order = new address[](3);
        // position < 3
        for (uint256 i; i < 3; ++i) {
            order[i] = address(_extensions[permutations[index][i]]);
        }
    }

    function _shorten(bytes[] memory calls, uint256 count) private pure returns (bytes[] memory result) {
        result = new bytes[](count);
        // i < count <= calls.length
        for (uint256 i; i < count; ++i) {
            result[i] = calls[i];
        }
    }

    function _exactInput(bool zeroForOne, uint256 amount) private pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _swapAction(PoolKey memory key, bool zeroForOne, uint256 amount)
        private
        pure
        returns (RouteAction memory)
    {
        return RouteAction({
            key: key, operation: Operation.Swap, parameters: abi.encode(_exactInput(zeroForOne, amount)), hookData: ""
        });
    }

    function _handlerRange(int256 liquidityDelta) private pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: liquidityDelta, salt: 0});
    }

    function _routeLiquidityAction(int256 liquidityDelta) private view returns (RouteAction memory) {
        ModifyLiquidityParams memory parameters = ModifyLiquidityParams({
            tickLower: ROUTE_TICK_LOWER, tickUpper: ROUTE_TICK_UPPER, liquidityDelta: liquidityDelta, salt: bytes32(0)
        });
        return RouteAction({
            key: _keys[1], operation: Operation.ModifyLiquidity, parameters: abi.encode(parameters), hookData: ""
        });
    }
}
