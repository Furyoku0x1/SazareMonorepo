// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {KernelHookHandler} from "./KernelHookHandler.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";
import {KernelRouteExecutor} from "../../src/KernelRouteExecutor.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {CallbackLibrary} from "../../src/libraries/CallbackLibrary.sol";
import {CALLBACK_COUNT, CallbackType, ExtensionSettings} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTestNoChecks} from "v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Simulation test (TigerStyle): random sequences of pool operations, routes, vault transfers and management
/// calls, with system-wide invariants checked after every call.
/// @dev The frames, the tickets, the reentry counters and the management flag are in transient storage. The EVM
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

    KernelHookHandler internal handler;
    PoolKey[2] internal keys;
    PoolId[2] internal poolIds;
    MockExtension[3] internal extensions;
    uint16[3] internal callbackMasks;
    /// @dev An optional extension of the route pool, so that routes run nested extension calls.
    MockExtension internal observer;
    KernelHookVault internal vault;
    KernelRouteExecutor internal executor;

    function setUp() public override {
        super.setUp();
        vault = hook.VAULT();
        executor = hook.ROUTE_EXECUTOR();
        keys[0] = _poolKey();
        keys[1] = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        // poolIndex < 2
        for (uint256 i; i < 2; ++i) {
            poolIds[i] = keys[i].toId();
            _createPool(keys[i]);
            _addLiquidity(keys[i]);
        }
        _installExtensions();
        observer = new MockExtension(address(hook));
        _installAndActivate(keys[1], address(observer), _settings(OPTIONAL_CALLBACKS, true, false, 300_000));
        handler = new KernelHookHandler(
            hook, swapRouter, new PoolModifyLiquidityTestNoChecks(manager), donateRouter, keys, extensions, observer
        );
        IERC20(Currency.unwrap(currency0)).transfer(address(handler), type(uint96).max);
        IERC20(Currency.unwrap(currency1)).transfer(address(handler), type(uint96).max);
        hook.grantPoolRole(keys[0], hook.CONFIGURER_ROLE(), address(handler));
        // Start every extension with vault funds, so that routes and negative deltas can succeed from the first call.
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            handler.deposit(j, 0, 1e16);
            handler.deposit(j, 1, 1e16);
        }
        // Start with a route position, so that unwinds and removals are possible from the first call.
        handler.routeLiquidity(1e15);
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _handlerSelectors()}));
    }

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
        Currency[2] memory currencies = [currency0, currency1];
        // currencyIndex < 2
        for (uint256 c; c < 2; ++c) {
            uint256 sum;
            // poolIndex < 2, extensionIndex < 3
            for (uint256 i; i < 2; ++i) {
                for (uint256 j; j < 3; ++j) {
                    sum += vault.balanceOf(poolIds[i], address(extensions[j]), currencies[c]);
                }
            }
            assertEq(vault.accountedBalance(currencies[c]), sum, "accounted balance differs from the sum of balances");
            assertLe(sum, IERC20(Currency.unwrap(currencies[c])).balanceOf(address(vault)), "vault holds too little");
        }
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_fundedCurrencyCountMatchesNonzeroBalances() public view {
        // poolIndex < 2, extensionIndex < 3
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 3; ++j) {
                uint256 funded;
                if (vault.balanceOf(poolIds[i], address(extensions[j]), currency0) != 0) ++funded;
                if (vault.balanceOf(poolIds[i], address(extensions[j]), currency1) != 0) ++funded;
                assertEq(vault.fundedCurrencyCount(poolIds[i], address(extensions[j])), funded);
            }
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

    /// @dev Each installation's balance changes only by its own deposits, withdrawals, fees and route results.
    /// A charge or a credit to the wrong installation breaks this.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_installationBalancesMatchModel() public view {
        Currency[2] memory currencies = [currency0, currency1];
        // extensionIndex < 3, currencyIndex < 2
        for (uint256 j; j < 3; ++j) {
            for (uint256 c; c < 2; ++c) {
                int256 expected = handler.ghostBalance(j, c);
                assertGe(expected, 0, "model balance below zero");
                assertEq(
                    vault.balanceOf(poolIds[0], address(extensions[j]), currencies[c]),
                    uint256(expected),
                    "vault balance differs from the model"
                );
            }
            assertEq(vault.balanceOf(poolIds[1], address(observer), currencies[0]), 0, "observer balance");
            assertEq(vault.balanceOf(poolIds[1], address(observer), currencies[1]), 0, "observer balance");
        }
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_hookAndRouteExecutorHoldNoTokens() public view {
        Currency[2] memory currencies = [currency0, currency1];
        // currencyIndex < 2
        for (uint256 c; c < 2; ++c) {
            IERC20 token = IERC20(Currency.unwrap(currencies[c]));
            assertEq(token.balanceOf(address(hook)), 0, "KernelHook holds tokens");
            assertEq(token.balanceOf(address(executor)), 0, "route executor holds tokens");
        }
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_callbackOrdersMatchSubscriptions() public view {
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            address[] memory order = hook.callbackOrder(poolIds[0], CallbackType(i));
            uint256 subscribers;
            // extensionIndex < 3
            for (uint256 j; j < 3; ++j) {
                uint256 found = _count(order, address(extensions[j]));
                if (CallbackLibrary.includes(callbackMasks[j], CallbackType(i))) {
                    assertEq(found, 1, "subscriber not in the callback order exactly once");
                    ++subscribers;
                } else {
                    assertEq(found, 0, "extension in the order of a callback it does not subscribe to");
                }
            }
            assertEq(order.length, subscribers, "callback order length");
            address[] memory routeOrder = hook.callbackOrder(poolIds[1], CallbackType(i));
            uint256 observerSubscribes = CallbackLibrary.includes(OPTIONAL_CALLBACKS, CallbackType(i)) ? 1 : 0;
            assertEq(routeOrder.length, observerSubscribes, "route pool callback order length");
            assertEq(_count(routeOrder, address(observer)), observerSubscribes, "route pool callback order");
        }
    }

    /// @dev Prints how often each counted handler action succeeded (run with -vv). The two behavior setters
    /// (setFee, setOptionalFailure) are not counted. test_handler_reachesRoutesAndUnwind makes sure that the
    /// route actions work; this log shows how often a run reached them.
    function afterInvariant() public view {
        string[12] memory names = [
            "swap",
            "addLiquidity",
            "removeLiquidity",
            "donate",
            "deposit",
            "withdraw",
            "routeSwap",
            "routeLiquidity",
            "unwind",
            "toggleActive",
            "reorder",
            "reconfigure"
        ];
        // i < 12
        for (uint256 i; i < 12; ++i) {
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

    /// @notice The observer extension calls this from inside a swap.
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

    function _count(address[] memory order, address account) private pure returns (uint256 found) {
        // order.length <= MAX_EXTENSIONS
        for (uint256 i; i < order.length; ++i) {
            if (order[i] == account) ++found;
        }
    }

    function _installExtensions() private {
        callbackMasks = [SWAP_CALLBACKS, OPTIONAL_CALLBACKS, SWAP_CALLBACKS];
        bool[3] memory optionalCallbacks = [false, true, false];
        bool[3] memory allowNesting = [true, false, false];
        // The router's limit covers its nested operation, including the observer's invocation reserve.
        uint32[3] memory gasLimits = [uint32(2_500_000), 500_000, 500_000];
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
        // The required router and fee taker need 2,850,645 + 786,129 + 80,000 + 80,000 + 3 * 25,000 = 3,871,774,
        // which fits the default budget of 4,000,000.
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            hook.activateExtension(keys[0], IHookExtension(address(extensions[j])));
        }
    }

    function _handlerSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](14);
        selectors[0] = KernelHookHandler.swap.selector;
        selectors[1] = KernelHookHandler.addLiquidity.selector;
        selectors[2] = KernelHookHandler.removeLiquidity.selector;
        selectors[3] = KernelHookHandler.donate.selector;
        selectors[4] = KernelHookHandler.setFee.selector;
        selectors[5] = KernelHookHandler.setOptionalFailure.selector;
        selectors[6] = KernelHookHandler.deposit.selector;
        selectors[7] = KernelHookHandler.withdraw.selector;
        selectors[8] = KernelHookHandler.routeSwap.selector;
        selectors[9] = KernelHookHandler.routeLiquidity.selector;
        selectors[10] = KernelHookHandler.unwind.selector;
        selectors[11] = KernelHookHandler.toggleActive.selector;
        selectors[12] = KernelHookHandler.reorder.selector;
        selectors[13] = KernelHookHandler.reconfigure.selector;
    }
}
