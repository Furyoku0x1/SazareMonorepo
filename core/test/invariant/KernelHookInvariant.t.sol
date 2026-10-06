// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {KernelHookHandler, POOL_0_BUDGET} from "./KernelHookHandler.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";
import {KernelRouteExecutor} from "../../src/KernelRouteExecutor.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {CallbackLibrary} from "../../src/libraries/CallbackLibrary.sol";
import {
    CALLBACK_COUNT,
    CallbackType,
    ExtensionSettings,
    Operation,
    PoolStatus,
    RouteAction
} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTestNoChecks} from "v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Simulation test (TigerStyle): random sequences of pool operations, routes, vault transfers and management
/// calls, with system-wide invariants checked after every call.
/// @dev Three pools: pool 0 with three extensions (router, optional, fee taker), pool 1 (the route pool) with an
/// observer and a relay that routes from a nested operation, and pool 2, a native-currency pool with a dynamic LP
/// fee and two fee overriders. The handler also prepares and initializes new pools.
/// The frames, the tickets, the reentry counters and the management flag are in transient storage. The EVM
/// clears it at the end of each transaction, so between transactions they are empty by construction.
/// test_runtime_isObservableDuringOperations reads them inside a transaction, through currentContext and ticketCount;
/// the unit tests that make several calls in one transaction (multicall, two swaps in one test) cover their reset.
/// The persistent counter lastOperationId is in slot 5 (`forge inspect src/KernelHook.sol:KernelHook storageLayout`).
contract KernelHookInvariantTest is StdInvariant, KernelHookFixture {
    using StateLibrary for IPoolManager;

    /// @dev lastOperationId (uint64).
    uint256 internal constant COUNTERS_SLOT = 5;

    uint16 internal constant OPTIONAL_CALLBACKS = SWAP_CALLBACKS | uint16(1) << uint8(CallbackType.BeforeAddLiquidity)
        | uint16(1) << uint8(CallbackType.AfterAddLiquidity) | uint16(1) << uint8(CallbackType.BeforeRemoveLiquidity)
        | uint16(1) << uint8(CallbackType.AfterRemoveLiquidity) | uint16(1) << uint8(CallbackType.BeforeDonate)
        | uint16(1) << uint8(CallbackType.AfterDonate);
    uint16 internal constant BEFORE_SWAP = uint16(1) << uint8(CallbackType.BeforeSwap);

    /// @dev The router's limit covers the relay's whole invocation gas in the nested pool-1 swap (2,000,000
    /// + 64,516 + 250,000), the observer's, and the PoolManager's work. The relay's limit covers the two overriders
    /// of the native pool (2 * (300,000 + 9,677 + 250,000)) in the third-level swap.
    uint32 internal constant ROUTER_GAS_LIMIT = 5_000_000;
    uint32 internal constant RELAY_GAS_LIMIT = 2_000_000;

    KernelHookHandler internal handler;
    PoolKey[3] internal keys;
    PoolId[3] internal poolIds;
    MockExtension[3] internal extensions;
    uint16[3] internal callbackMasks;
    /// @dev An optional extension of the route pool, so that routes run nested extension calls.
    MockExtension internal observer;
    /// @dev An optional extension of the route pool that allows nesting and routes in routeRecursive.
    MockExtension internal relay;
    /// @dev Two optional extensions of the native pool that return fee overrides.
    MockExtension[2] internal overriders;
    KernelHookVault internal vault;
    KernelRouteExecutor internal executor;

    function setUp() public override {
        super.setUp();
        vault = hook.VAULT();
        executor = hook.ROUTE_EXECUTOR();
        vm.deal(address(this), 1e24);
        keys[0] = _poolKey();
        keys[1] = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        keys[2] =
            PoolKey(Currency.wrap(address(0)), currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        // poolIndex < 3
        for (uint256 i; i < 3; ++i) {
            poolIds[i] = keys[i].toId();
            _createPool(keys[i]);
        }
        _addLiquidity(keys[0]);
        _addLiquidity(keys[1]);
        modifyLiquidityRouter.modifyLiquidity{value: 1e18}(keys[2], _liquidityParameters(1e18), "");
        _installExtensions();
        // Installation needs inactive subscribers on the same callbacks: install all extensions of a pool first.
        observer = new MockExtension(address(hook));
        relay = new MockExtension(address(hook));
        _install(keys[1], address(observer), _settings(OPTIONAL_CALLBACKS, true, false, 300_000));
        _install(keys[1], address(relay), _settings(SWAP_CALLBACKS, true, true, RELAY_GAS_LIMIT));
        hook.activateExtension(keys[1], IHookExtension(address(observer)));
        hook.activateExtension(keys[1], IHookExtension(address(relay)));
        // overrider < 2
        for (uint256 k; k < 2; ++k) {
            overriders[k] = new MockExtension(address(hook));
            _install(keys[2], address(overriders[k]), _settings(BEFORE_SWAP, true, false, 300_000));
        }
        // overrider < 2
        for (uint256 k; k < 2; ++k) {
            hook.activateExtension(keys[2], IHookExtension(address(overriders[k])));
        }
        handler = new KernelHookHandler(
            KernelHookHandler.Setup({
                hook: hook,
                swapRouter: swapRouter,
                liquidityRouter: new PoolModifyLiquidityTestNoChecks(manager),
                donateRouter: donateRouter,
                keys: keys,
                extensions: extensions,
                observer: observer,
                relay: relay,
                overriders: overriders
            })
        );
        IERC20(Currency.unwrap(currency0)).transfer(address(handler), type(uint96).max);
        IERC20(Currency.unwrap(currency1)).transfer(address(handler), type(uint96).max);
        vm.deal(address(handler), type(uint96).max);
        hook.grantPoolRole(keys[0], hook.CONFIGURER_ROLE(), address(handler));
        hook.grantPoolRole(keys[0], hook.POOL_ADMIN_ROLE(), address(handler));
        // Start every modeled installation with vault funds in each currency, so that routes and negative deltas can
        // succeed from the first call. installation < 4, currencyIndex < 3
        for (uint256 j; j < 4; ++j) {
            for (uint256 c; c < 3; ++c) {
                handler.deposit(j, c, 1e16);
            }
        }
        // Start with a route position, so that unwinds and removals are possible from the first call.
        handler.routeLiquidity(1e15);
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

    /// @notice Receives the native refunds of the liquidity router.
    receive() external payable {}

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_runtimeIsEmptyBetweenTransactions() public view {
        assertEq(hook.currentContext().depth, 0, "frames left on the stack");
        assertEq(hook.ticketCount(), 0, "tickets left");
        assertFalse(vault.transferInProgress());
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_vaultAccountingMatchesBalances() public view {
        Currency[3] memory currencies = _currencies();
        (PoolId[7] memory pools, address[7] memory accounts) = _installations();
        // currencyIndex < 3
        for (uint256 c; c < 3; ++c) {
            uint256 sum;
            // installation < 7
            for (uint256 k; k < 7; ++k) {
                sum += vault.balanceOf(pools[k], accounts[k], currencies[c]);
            }
            assertEq(vault.accountedBalance(currencies[c]), sum, "accounted balance differs from the sum of balances");
            uint256 held =
                c == 2 ? address(vault).balance : IERC20(Currency.unwrap(currencies[c])).balanceOf(address(vault));
            assertLe(sum, held, "vault holds too little");
        }
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_fundedCurrencyCountMatchesNonzeroBalances() public view {
        Currency[3] memory currencies = _currencies();
        (PoolId[7] memory pools, address[7] memory accounts) = _installations();
        // installation < 7
        for (uint256 k; k < 7; ++k) {
            uint256 funded;
            // currencyIndex < 3
            for (uint256 c; c < 3; ++c) {
                if (vault.balanceOf(pools[k], accounts[k], currencies[c]) != 0) ++funded;
            }
            assertEq(vault.fundedCurrencyCount(pools[k], accounts[k]), funded);
        }
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_routeLiquidityMatchesModel() public view {
        address router = address(extensions[0]);
        uint256 expected = handler.ghostRouteLiquidity();
        assertEq(handler.trackedRouteLiquidity(), expected, "executor record differs from the model");
        assertEq(executor.openPositionCount(poolIds[0], router), expected == 0 ? 0 : 1, "open position count");
        bytes32 namespacedSalt = keccak256(abi.encode(poolIds[0], router, bytes32(0)));
        (uint128 liquidity,,) = manager.getPositionInfo(poolIds[1], address(executor), -60, 60, namespacedSalt);
        assertEq(uint256(liquidity), expected, "PoolManager position differs from the model");
    }

    /// @dev Each modeled installation's balance changes only by its own deposits, withdrawals, fees and route
    /// results. A charge or a credit to the wrong installation breaks this. The observer and the overriders never
    /// hold funds.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_installationBalancesMatchModel() public view {
        Currency[3] memory currencies = _currencies();
        (PoolId[7] memory pools, address[7] memory accounts) = _installations();
        // installation < 7, currencyIndex < 3
        for (uint256 k; k < 7; ++k) {
            for (uint256 c; c < 3; ++c) {
                uint256 balance = vault.balanceOf(pools[k], accounts[k], currencies[c]);
                // Installations 0 to 3 are the handler's modeled ones: the three of pool 0, then the relay.
                if (k > 3) {
                    assertEq(balance, 0, "the observer or an overrider holds funds");
                    continue;
                }
                int256 expected = handler.ghostBalance(k, c);
                assertGe(expected, 0, "model balance below zero");
                assertEq(balance, uint256(expected), "vault balance differs from the model");
            }
        }
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_hookAndRouteExecutorHoldNoTokens() public view {
        // tokenIndex < 2
        for (uint256 c; c < 2; ++c) {
            IERC20 token = IERC20(Currency.unwrap(_currencies()[c]));
            assertEq(token.balanceOf(address(hook)), 0, "KernelHook holds tokens");
            assertEq(token.balanceOf(address(executor)), 0, "route executor holds tokens");
        }
        assertEq(address(hook).balance, 0, "KernelHook holds native currency");
        assertEq(address(executor).balance, 0, "route executor holds native currency");
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_callbackOrdersMatchSubscriptions() public view {
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            CallbackType callback = CallbackType(i);
            address[] memory order = hook.callbackOrder(poolIds[0], callback);
            uint256 subscribers;
            // extensionIndex < 3
            for (uint256 j; j < 3; ++j) {
                subscribers += _assertSubscription(order, address(extensions[j]), callbackMasks[j], callback);
            }
            assertEq(order.length, subscribers, "pool 0 callback order length");
            order = hook.callbackOrder(poolIds[1], callback);
            subscribers = _assertSubscription(order, address(observer), OPTIONAL_CALLBACKS, callback)
                + _assertSubscription(order, address(relay), SWAP_CALLBACKS, callback);
            assertEq(order.length, subscribers, "route pool callback order length");
            order = hook.callbackOrder(poolIds[2], callback);
            subscribers = _assertSubscription(order, address(overriders[0]), BEFORE_SWAP, callback)
                + _assertSubscription(order, address(overriders[1]), BEFORE_SWAP, callback);
            assertEq(order.length, subscribers, "native pool callback order length");
        }
    }

    /// @dev The probes of the handler (authority, removal, preparation, initialization, depth limits, fee overrides)
    /// count every unsafe outcome that they see.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_probesSeeNoViolation() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_rolesMatchModel() public view {
        bytes32 configurerRole = hook.CONFIGURER_ROLE();
        bytes32 adminRole = hook.POOL_ADMIN_ROLE();
        // account < 3
        for (uint256 i; i < 3; ++i) {
            address account = handler.roleAccount(i);
            assertEq(hook.hasPoolRole(poolIds[0], configurerRole, account), handler.ghostRole(i, 0), "configurer role");
            assertEq(hook.hasPoolRole(poolIds[0], adminRole, account), handler.ghostRole(i, 1), "admin role");
        }
        assertTrue(hook.hasPoolRole(poolIds[0], adminRole, address(handler)), "handler admin role");
        assertTrue(hook.hasPoolRole(poolIds[0], adminRole, address(this)), "first admin role");
    }

    /// @dev Every pool that the handler prepared keeps the handler as its initializer, is Initialized exactly when
    /// the model initialized it, and then has the handler as its first admin.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_preparedPoolsMatchModel() public view {
        (,, uint8 maxOperationDepth,) = hook.poolState(poolIds[0]);
        assertEq(maxOperationDepth, handler.ghostMaxOperationDepth(), "pool 0 depth limit");
        bytes32 adminRole = hook.POOL_ADMIN_ROLE();
        // The first three keys are the setup pools; preparedKeyCount() <= 16.
        for (uint256 i = 3; i < handler.preparedKeyCount(); ++i) {
            PoolId poolId = handler.preparedKey(i).toId();
            (PoolStatus status, address initializer,,) = hook.poolState(poolId);
            bool initialized = handler.ghostInitialized(poolId);
            assertEq(initializer, address(handler), "initializer");
            assertEq(uint8(status), uint8(initialized ? PoolStatus.Initialized : PoolStatus.Prepared), "pool status");
            assertEq(hook.hasPoolRole(poolId, adminRole, address(handler)), initialized, "first admin");
        }
    }

    /// @dev Prints how often each counted handler action succeeded in the last run (run with -vv). The behavior
    /// setters (setFee, setOptionalFailure, setFeeOverride) are not counted. The test_handler_* tests make sure that
    /// each action works; this log shows how often a run reached it.
    function afterInvariant() public view {
        string[22] memory names = [
            "swap",
            "addLiquidity",
            "removeLiquidity",
            "donate",
            "swapDynamic",
            "deposit",
            "withdraw",
            "routeSwap",
            "routeLiquidity",
            "routeNativeSwap",
            "routeRecursive",
            "routeSamePoolDonate",
            "unwind",
            "toggleActive",
            "reorder",
            "reconfigure",
            "setDepthLimit",
            "removeAndReinstall",
            "changeRole",
            "probeAuthority",
            "preparePool",
            "initializePrepared"
        ];
        // i < 22
        for (uint256 i; i < 22; ++i) {
            console.log(names[i], handler.successfulCalls(names[i]));
        }
    }

    /// @dev Reads the transient runtime inside a transaction, where it is not empty: depth 1 and no ticket in a direct
    /// swap, depth 2 and one ticket in the nested swap of a route, and all empty after each operation. Also checks
    /// that lastOperationId is the persistent counter in COUNTERS_SLOT.
    function test_runtime_isObservableDuringOperations() public {
        observer.setExternalCall(CallbackType.BeforeSwap, address(this), abi.encodeCall(this.recordRuntime, ()));
        uint64 before = uint64(uint256(vm.load(address(hook), bytes32(COUNTERS_SLOT))));

        _swapExactInput(keys[1], true, 1e12);

        assertEq(uint64(uint256(vm.load(address(hook), bytes32(COUNTERS_SLOT)))), before + 1);
        assertEq(_recordedDepth, 1);
        assertEq(_recordedTickets, 0);
        assertEq(hook.currentContext().depth, 0);

        handler.routeSwap(true, 1e9);

        assertEq(_recordedDepth, 2);
        assertEq(_recordedTickets, 1);
        assertEq(hook.currentContext().depth, 0);
        assertEq(hook.ticketCount(), 0);
    }

    uint256 internal _recordedDepth;
    uint256 internal _recordedTickets;

    /// @notice An extension calls this from inside a swap.
    function recordRuntime() external {
        _recordedDepth = hook.currentContext().depth;
        _recordedTickets = hook.ticketCount();
    }

    /// @dev The route actions of the handler must really run: the invariant run can skip them by chance, and an
    /// inactive router lets the outer swap succeed without its route.
    function test_handler_reachesRoutesAndUnwind() public {
        uint256 seeded = handler.trackedRouteLiquidity();
        assertEq(seeded, 1e15);
        bytes32 namespacedSalt = keccak256(abi.encode(poolIds[0], address(extensions[0]), bytes32(0)));
        (uint128 managerLiquidity,,) = manager.getPositionInfo(poolIds[1], address(executor), -60, 60, namespacedSalt);
        assertEq(managerLiquidity, seeded);

        (uint160 priceBefore,,,) = manager.getSlot0(poolIds[1]);
        handler.routeSwap(true, 1e9);
        (uint160 priceAfter,,,) = manager.getSlot0(poolIds[1]);
        assertLt(priceAfter, priceBefore);

        handler.unwind(type(uint256).max);
        assertEq(handler.trackedRouteLiquidity(), 0);
        assertEq(handler.ghostRouteLiquidity(), 0);
        (managerLiquidity,,) = manager.getPositionInfo(poolIds[1], address(executor), -60, 60, namespacedSalt);
        assertEq(managerLiquidity, 0);

        handler.toggleActive(0);
        vm.expectRevert(bytes("route did not run"));
        handler.routeSwap(true, 1e9);
    }

    /// @dev reorder and reconfigure run through multicall on a live pool. After both, all three swap subscribers
    /// still run, in the new order.
    function test_handler_reorderAndReconfigureKeepThePoolWorking() public {
        handler.reorder(5);
        address[] memory order = hook.callbackOrder(poolIds[0], CallbackType.BeforeSwap);
        assertEq(order[0], address(extensions[2]));
        assertEq(order[1], address(extensions[1]));
        assertEq(order[2], address(extensions[0]));

        handler.reconfigure(300_000, 512);
        (bool active, ExtensionSettings memory settings,) =
            hook.extensionConfiguration(poolIds[0], address(extensions[1]));
        assertTrue(active);
        assertEq(settings.configuration.length, 512);

        uint256[3] memory calls;
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            calls[j] = extensions[j].callCount(CallbackType.BeforeSwap);
        }
        handler.swap(0, true, 1e10, false);
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            assertEq(extensions[j].callCount(CallbackType.BeforeSwap), calls[j] + 1);
        }
    }

    /// @dev Each probe call must succeed exactly when the account has the right: no role, configurer, admin, then
    /// the admin role revoked again.
    function test_handler_probesAuthorityOfEachRole() public {
        handler.probeAuthority(0);
        handler.changeRole(0, false, true);
        handler.probeAuthority(0);
        handler.changeRole(1, true, true);
        handler.probeAuthority(1);
        handler.changeRole(1, true, false);
        handler.probeAuthority(1);

        assertEq(handler.violations(), 0, handler.lastViolation());
        assertEq(handler.successfulCalls("probeAuthority"), 4);
        assertTrue(hook.hasPoolRole(poolIds[0], hook.CONFIGURER_ROLE(), handler.roleAccount(0)));
        assertFalse(hook.hasPoolRole(poolIds[0], hook.POOL_ADMIN_ROLE(), handler.roleAccount(1)));
    }

    /// @dev A new valid key is prepared, a prepared key and an invalid key are refused, and only the initializer's
    /// first initialization succeeds.
    function test_handler_preparesAndInitializesPools() public {
        handler.preparePool(3001, 60, false);
        handler.preparePool(0, 60, true);
        handler.preparePool(1, 0, false);
        handler.initializePrepared(0);
        handler.initializePrepared(0);

        assertEq(handler.violations(), 0, handler.lastViolation());
        assertEq(handler.successfulCalls("preparePool"), 1);
        assertEq(handler.successfulCalls("initializePrepared"), 1);
        PoolId poolId = handler.preparedKey(3).toId();
        (PoolStatus status, address initializer,,) = hook.poolState(poolId);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));
        assertEq(initializer, address(handler));
    }

    /// @dev Removal needs no vault funds and no open route position. After a removal and installation, the fee
    /// taker is active again and swaps still run.
    function test_handler_removesAndReinstallsOnlyWithoutObligations() public {
        handler.removeAndReinstall(2, false);
        assertEq(handler.successfulCalls("removeAndReinstall"), 0);

        handler.removeAndReinstall(2, true);
        assertEq(handler.successfulCalls("removeAndReinstall"), 1);

        handler.removeAndReinstall(0, true);
        assertEq(handler.successfulCalls("removeAndReinstall"), 1);

        assertEq(handler.violations(), 0, handler.lastViolation());
        (bool active,,) = hook.extensionConfiguration(poolIds[0], address(extensions[2]));
        assertTrue(active);
        uint256 feeCalls = extensions[2].callCount(CallbackType.BeforeSwap);
        handler.swap(0, true, 1e10, false);
        assertEq(extensions[2].callCount(CallbackType.BeforeSwap), feeCalls + 1);
    }

    /// @dev Native swaps and native routes run at the first valid fee override. The direct swaps of this test read
    /// the fee from the PoolManager's Swap event, so they do not depend on the handler's model.
    function test_handler_nativeSwapsUseTheFirstValidFeeOverride() public {
        handler.setFeeOverride(false, 1 | 3000 << 2);
        handler.setFeeOverride(true, 1 | 5000 << 2);
        assertEq(_swapFeeOfNativePool(true), 3000, "first override");
        handler.swapDynamic(true, 1e10);
        handler.swapDynamic(false, 1e10);
        handler.routeNativeSwap(true, 1e9);
        handler.routeNativeSwap(false, 1e9);

        // An override above the maximum LP fee is skipped, so the second overrider's fee applies.
        handler.setFeeOverride(false, 2);
        assertEq(_swapFeeOfNativePool(false), 5000, "second override");
        handler.swapDynamic(true, 1e10);

        // A nonzero value without the override flag is skipped too, so the second overrider's fee still applies.
        handler.setFeeOverride(false, 3 | 7 << 2);
        assertEq(_swapFeeOfNativePool(true), 5000, "override after a value without the flag");

        // With no valid override, the swap runs at the pool's stored LP fee, which is 0 for a new dynamic-fee pool.
        handler.setFeeOverride(true, 0);
        assertEq(_swapFeeOfNativePool(true), 0, "stored fee");

        assertEq(handler.violations(), 0, handler.lastViolation());
        assertEq(handler.successfulCalls("swapDynamic"), 3);
        assertEq(handler.successfulCalls("routeNativeSwap"), 2);
    }

    /// @dev The relay's route is the third operation (depth 3, two tickets). With a depth limit of 2 on pool 0 it
    /// cannot run, with 2 a route from pool 0 still runs, and with 1 the required router's route fails.
    function test_handler_recursiveRouteFollowsTheDepthLimit() public {
        overriders[0].setExternalCall(CallbackType.BeforeSwap, address(this), abi.encodeCall(this.recordRuntime, ()));
        uint256 relayCalls = relay.callCount(CallbackType.AfterSwap);
        handler.routeRecursive(true, 1e8);
        assertEq(relay.callCount(CallbackType.AfterSwap), relayCalls + 1);
        assertEq(_recordedDepth, 3);
        assertEq(_recordedTickets, 2);
        handler.routeRecursive(false, 1e8);
        overriders[0].setExternalCall(CallbackType.BeforeSwap, address(0), "");

        handler.setDepthLimit(2);
        vm.expectRevert(bytes("relay route did not run"));
        handler.routeRecursive(true, 1e8);
        handler.routeSwap(true, 1e9);

        handler.setDepthLimit(1);
        try handler.routeSwap(true, 1e9) {
            fail("a route ran at depth limit 1");
        } catch (bytes memory reason) {
            assertTrue(_contains(reason, IKernelHook.DepthLimitReached.selector), "not DepthLimitReached");
        }

        assertEq(handler.violations(), 0, handler.lastViolation());
        assertEq(handler.successfulCalls("routeRecursive"), 2);
    }

    /// @dev The optional extension donates to its own pool from afterSwap. With the order router, fee taker,
    /// optional, every required extension has run, so the nested operation runs and the optional extension pays the
    /// donation. With the fee taker after it, KernelHook refuses the route (ReentrancyDenied) and skips the optional.
    function test_handler_routesADonationToItsOwnPoolAfterTheRequiredExtensions() public {
        handler.reorder(1);
        uint256 balance = vault.balanceOf(poolIds[0], address(extensions[1]), currency0);
        handler.routeSamePoolDonate(1e6);
        assertEq(vault.balanceOf(poolIds[0], address(extensions[1]), currency0), balance - 1e6);

        handler.reorder(0);
        vm.expectRevert(bytes("same-pool route did not run"));
        handler.routeSamePoolDonate(1e6);

        assertEq(handler.violations(), 0, handler.lastViolation());
        assertEq(handler.successfulCalls("routeSamePoolDonate"), 1);
    }

    /// @dev A pool on the operation stack can be entered again only from its after callback, after all required
    /// extensions of that sequence have run. The required router is still running, so its route into its own pool is
    /// refused with ReentrancyDenied, and the outer swap reverts.
    function test_requiredRouterCannotRouteIntoItsOwnPool() public {
        RouteAction memory action = RouteAction({
            key: keys[0],
            operation: Operation.Swap,
            parameters: abi.encode(SwapParams(true, -1e9, TickMath.MIN_SQRT_PRICE + 1)),
            hookData: ""
        });
        extensions[0].addRouteAction(CallbackType.AfterSwap, action);

        try swapRouter.swap(
            keys[0], SwapParams(true, -1e10, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        ) {
            fail("the same-pool route of the required router ran");
        } catch (bytes memory reason) {
            assertTrue(_contains(reason, IKernelHook.ReentrancyDenied.selector), "not ReentrancyDenied");
        }
    }

    function _swapFeeOfNativePool(bool zeroForOne) private returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap{value: zeroForOne ? 1e9 : 0}(
            keys[2],
            SwapParams(zeroForOne, -1e9, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // logs.length is bounded by the gas of one swap
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager)) continue;
            if (logs[i].topics[0] != IPoolManager.Swap.selector) continue;
            (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            return fee;
        }
        fail("no swap event");
    }

    function _contains(bytes memory data, bytes4 selector) private pure returns (bool) {
        // i + 4 <= data.length
        for (uint256 i; i + 4 <= data.length; ++i) {
            bytes4 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), i))
            }
            if (word == selector) return true;
        }
        return false;
    }

    function _assertSubscription(address[] memory order, address account, uint16 mask, CallbackType callback)
        private
        pure
        returns (uint256 subscribes)
    {
        subscribes = CallbackLibrary.includes(mask, callback) ? 1 : 0;
        assertEq(_count(order, account), subscribes, "subscriber not in the callback order exactly once");
    }

    function _count(address[] memory order, address account) private pure returns (uint256 found) {
        // order.length <= MAX_EXTENSIONS
        for (uint256 i; i < order.length; ++i) {
            if (order[i] == account) ++found;
        }
    }

    function _currencies() private view returns (Currency[3] memory) {
        return [currency0, currency1, Currency.wrap(address(0))];
    }

    /// @dev Every installation of the three pools: the three of pool 0 and the relay (the handler's modeled ones,
    /// in the handler's order), then the observer and the two overriders.
    function _installations() private view returns (PoolId[7] memory pools, address[7] memory accounts) {
        pools = [poolIds[0], poolIds[0], poolIds[0], poolIds[1], poolIds[1], poolIds[2], poolIds[2]];
        accounts = [
            address(extensions[0]),
            address(extensions[1]),
            address(extensions[2]),
            address(relay),
            address(observer),
            address(overriders[0]),
            address(overriders[1])
        ];
    }

    function _install(PoolKey memory key, address extension, ExtensionSettings memory settings) private {
        _admit(extension);
        hook.installExtension(key, IHookExtension(extension), settings);
    }

    function _installExtensions() private {
        callbackMasks = [SWAP_CALLBACKS, OPTIONAL_CALLBACKS, SWAP_CALLBACKS];
        bool[3] memory optionalCallbacks = [false, true, false];
        bool[3] memory allowNesting = [true, true, false];
        uint32[3] memory gasLimits = [ROUTER_GAS_LIMIT, 500_000, 500_000];
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            extensions[j] = new MockExtension(address(hook));
            _admit(address(extensions[j]));
            hook.installExtension(
                keys[0],
                IHookExtension(address(extensions[j])),
                _settings(callbackMasks[j], optionalCallbacks[j], allowNesting[j], gasLimits[j])
            );
        }
        // The required router and fee taker need (5,000,000 + 161,290 + 250,000) + (500,000 + 16,129 + 250,000)
        // + 80,000 + 25,000 + 3 * 37,000 = 6,393,419, above the default budget of 4,000,000.
        uint32[CALLBACK_COUNT] memory budgets;
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = POOL_0_BUDGET;
        }
        hook.setExecutionLimits(keys[0], 4, budgets);
        // The optional extension runs last in afterSwap, after the required ones, so that its same-pool route can run
        // from the start of a campaign. The handler's reorder changes the order later.
        address[] memory afterSwapOrder = new address[](3);
        afterSwapOrder[0] = address(extensions[0]);
        afterSwapOrder[1] = address(extensions[2]);
        afterSwapOrder[2] = address(extensions[1]);
        hook.setCallbackOrder(keys[0], CallbackType.AfterSwap, afterSwapOrder);
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            hook.activateExtension(keys[0], IHookExtension(address(extensions[j])));
        }
    }

    function _handlerSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](25);
        selectors[0] = KernelHookHandler.swap.selector;
        selectors[1] = KernelHookHandler.addLiquidity.selector;
        selectors[2] = KernelHookHandler.removeLiquidity.selector;
        selectors[3] = KernelHookHandler.donate.selector;
        selectors[4] = KernelHookHandler.swapDynamic.selector;
        selectors[5] = KernelHookHandler.setFee.selector;
        selectors[6] = KernelHookHandler.setOptionalFailure.selector;
        selectors[7] = KernelHookHandler.setFeeOverride.selector;
        selectors[8] = KernelHookHandler.deposit.selector;
        selectors[9] = KernelHookHandler.withdraw.selector;
        selectors[10] = KernelHookHandler.routeSwap.selector;
        selectors[11] = KernelHookHandler.routeLiquidity.selector;
        selectors[12] = KernelHookHandler.routeNativeSwap.selector;
        selectors[13] = KernelHookHandler.routeRecursive.selector;
        selectors[14] = KernelHookHandler.routeSamePoolDonate.selector;
        selectors[15] = KernelHookHandler.unwind.selector;
        selectors[16] = KernelHookHandler.toggleActive.selector;
        selectors[17] = KernelHookHandler.reorder.selector;
        selectors[18] = KernelHookHandler.reconfigure.selector;
        selectors[19] = KernelHookHandler.setDepthLimit.selector;
        selectors[20] = KernelHookHandler.removeAndReinstall.selector;
        selectors[21] = KernelHookHandler.changeRole.selector;
        selectors[22] = KernelHookHandler.probeAuthority.selector;
        selectors[23] = KernelHookHandler.preparePool.selector;
        selectors[24] = KernelHookHandler.initializePrepared.selector;
    }
}
