// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {CodexRouteCaller} from "../mocks/CodexRouteCaller.sol";
import {KernelRouteExecutor} from "../../src/KernelRouteExecutor.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {CallbackType, ExtensionSettings, Operation, RouteAction} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Route ordering, net settlement, nested attribution and callback rollback.
contract RouteActionsTest is KernelHookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint32 private constant ROUTE_GAS_LIMIT = 2_500_000;
    uint256 private constant VAULT_FUNDS = 1e16;
    uint256 private constant ROUTE_SWAP_AMOUNT = 1e12;
    uint128 private constant ROUTE_LIQUIDITY = 1e15;

    PoolKey private poolKey;
    PoolKey private routeKey;
    PoolId private poolId;
    PoolId private routeId;
    MockExtension private router;
    KernelRouteExecutor private executor;
    uint256 private parentDebtObservations;
    uint256 private maximumActionsVerified;

    function setUp() public override {
        super.setUp();
        poolKey = _poolKey();
        poolId = poolKey.toId();
        routeKey = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        routeId = routeKey.toId();
        _createPool(poolKey);
        _addLiquidity(poolKey);
        _createPool(routeKey);
        _addLiquidity(routeKey);
        router = new MockExtension(address(hook));
        executor = hook.ROUTE_EXECUTOR();
    }

    /// @dev Gross input exceeds available funds, so success requires netting both swaps first.
    function test_executeRoute_settlesOnlyNetDebtAcrossMultipleActions() public {
        _installRouter(false);
        router.withdraw(poolId, currency0, VAULT_FUNDS - 1e10, address(this));
        router.withdraw(poolId, currency1, VAULT_FUNDS - 1e10, address(this));
        _installAndActivate(
            routeKey, address(router), _settings(uint16(1) << uint8(CallbackType.BeforeDonate), false, true)
        );
        _fund(router, routeId, VAULT_FUNDS);
        MockExtension unrelated = new MockExtension(address(hook));
        _installAndActivate(
            poolKey, address(unrelated), _settings(uint16(1) << uint8(CallbackType.BeforeDonate), false, true)
        );
        _fund(unrelated, poolId, VAULT_FUNDS);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey, true, ROUTE_SWAP_AMOUNT));
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey, false, ROUTE_SWAP_AMOUNT));

        _swapExactInput(poolKey, true, 1e14);

        BalanceDelta[] memory results = router.lastRouteResults();
        assertEq(results.length, 2);
        assertEq(results[0].amount0(), -int128(int256(ROUTE_SWAP_AMOUNT)));
        assertGt(results[0].amount1(), 0);
        assertGt(results[1].amount0(), 0);
        assertEq(results[1].amount1(), -int128(int256(ROUTE_SWAP_AMOUNT)));
        (int256 delta0, int256 delta1) = _sum(results);
        assertLt(delta0, 0);
        assertLt(delta1, 0);
        assertLt(uint256(-delta0), 1e10);
        assertLt(uint256(-delta1), 1e10);
        _assertBalances(poolId, router, 1e10, delta0, delta1);
        _assertBalances(routeId, router, VAULT_FUNDS, 0, 0);
        _assertBalances(poolId, unrelated, VAULT_FUNDS, 0, 0);
    }

    /// @dev The inner route starts during the second parent action, with the first action still unsettled.
    function test_executeRoute_nestedRoutePreservesParentDeltas() public {
        PoolKey memory secondKey = PoolKey(currency0, currency1, 10_000, 60, IHooks(address(hook)));
        PoolKey memory innerKey = PoolKey(currency0, currency1, 100, 10, IHooks(address(hook)));
        _createPool(secondKey);
        _addLiquidity(secondKey);
        _createPool(innerKey);
        _addLiquidity(innerKey);
        uint256 snapshot = vm.snapshotState();
        BalanceDelta firstResult = _swapExactInput(routeKey, true, ROUTE_SWAP_AMOUNT);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        _installRouter(false);
        MockExtension innerRouter = new MockExtension(address(hook));
        // The outer callback's 2.5m also covers the inner router's invocation reserves.
        _installAndActivate(
            secondKey,
            address(innerRouter),
            _settings(uint16(1) << uint8(CallbackType.AfterSwap), false, true, 1_000_000)
        );
        _fund(innerRouter, secondKey.toId(), VAULT_FUNDS);
        innerRouter.setExternalCall(
            CallbackType.AfterSwap, address(this), abi.encodeCall(this.assertParentDeltas, (firstResult))
        );
        innerRouter.addRouteAction(CallbackType.AfterSwap, _swapAction(innerKey, false, ROUTE_SWAP_AMOUNT));
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey, true, ROUTE_SWAP_AMOUNT));
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(secondKey, true, ROUTE_SWAP_AMOUNT * 2));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(parentDebtObservations, 1);
        BalanceDelta[] memory parentResults = router.lastRouteResults();
        BalanceDelta[] memory innerResults = innerRouter.lastRouteResults();
        assertEq(parentResults.length, 2);
        assertEq(BalanceDelta.unwrap(parentResults[0]), BalanceDelta.unwrap(firstResult));
        assertEq(parentResults[1].amount0(), -int128(int256(ROUTE_SWAP_AMOUNT * 2)));
        assertGt(parentResults[1].amount1(), 0);
        assertEq(innerResults.length, 1);
        assertGt(innerResults[0].amount0(), 0);
        assertEq(innerResults[0].amount1(), -int128(int256(ROUTE_SWAP_AMOUNT)));
        (int256 parent0, int256 parent1) = _sum(parentResults);
        (int256 inner0, int256 inner1) = _sum(innerResults);
        _assertBalances(poolId, router, VAULT_FUNDS, parent0, parent1);
        _assertBalances(secondKey.toId(), innerRouter, VAULT_FUNDS, inner0, inner1);
        assertEq(hook.VAULT().balanceOf(poolId, address(innerRouter), currency0), 0);
        assertEq(hook.VAULT().balanceOf(poolId, address(innerRouter), currency1), 0);
        assertEq(hook.VAULT().balanceOf(secondKey.toId(), address(router), currency0), 0);
        assertEq(hook.VAULT().balanceOf(secondKey.toId(), address(router), currency1), 0);
        assertEq(hook.currentContext().depth, 0);
    }

    /// @dev Result validation shares the callback's rollback scope with its completed route.
    function test_executeRoute_optionalFailureRollsBackNestedEffects() public {
        _installRouter(true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey, true, ROUTE_SWAP_AMOUNT));
        router.addRouteAction(CallbackType.AfterSwap, _liquidityAction(routeKey, int256(uint256(ROUTE_LIQUIDITY))));
        router.setBehavior(CallbackType.AfterSwap, MockExtension.Behavior(0, 0, 1, false, 0));
        bytes32 stateBefore = _poolStateHash(routeId);
        uint256 held0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook.VAULT()));
        uint256 held1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook.VAULT()));
        // Isolates the after-swap fee-override check: both deltas and the preceding aggregate are zero.
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            poolId,
            address(router),
            CallbackType.AfterSwap,
            abi.encodeWithSelector(IKernelHook.InvalidFeeOverride.selector)
        );

        _swapExactInput(poolKey, true, 1e14);

        assertEq(_poolStateHash(routeId), stateBefore);
        _assertBalances(poolId, router, VAULT_FUNDS, 0, 0);
        assertEq(hook.VAULT().accountedBalance(currency0), VAULT_FUNDS);
        assertEq(hook.VAULT().accountedBalance(currency1), VAULT_FUNDS);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(hook.VAULT())), held0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(hook.VAULT())), held1);
        assertEq(executor.positionLiquidity(poolId, address(router), routeId, -60, 60, bytes32(0)), 0);
        assertEq(executor.openPositionCount(poolId, address(router)), 0);
        bytes32 salt = keccak256(abi.encode(poolId, address(router), bytes32(0)));
        (uint128 positionLiquidity,,) = manager.getPositionInfo(routeId, address(executor), -60, 60, salt);
        assertEq(positionLiquidity, 0);
        assertEq(router.callCount(CallbackType.BeforeSwap), 1);
        assertEq(router.callCount(CallbackType.AfterSwap), 0);
        assertEq(router.lastRouteResults().length, 0);
        assertEq(hook.currentContext().depth, 0);
    }

    /// @dev A direct callback call reaches executeRoute even when the mock has no stored actions.
    function test_executeRoute_rejectsEmptyRoute() public {
        _installRouter(false);
        router.setExternalCall(
            CallbackType.AfterSwap, address(hook), abi.encodeCall(hook.executeRoute, (new RouteAction[](0)))
        );
        // Isolates the executor's zero-length check: current installed caller, nesting and unlocked guards pass.
        vm.expectRevert(_routeFailure(abi.encodeWithSelector(KernelRouteExecutor.InvalidRoute.selector)));

        _swapExactInput(poolKey, true, 1e14);
    }

    /// @dev Ordered swaps interleave distinct donations; PoolManager receipts prove every action's execution order.
    function test_executeRoute_executesMaximumActionsInOrder() public {
        uint256 count = executor.MAX_ACTIONS();
        BalanceDelta[] memory expected = new BalanceDelta[](count);
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < count; ++i) {
            if (i % 4 == 0) {
                expected[i] = _swapExactInput(routeKey, i % 8 == 0, ROUTE_SWAP_AMOUNT * (i + 1));
            } else {
                expected[i] = donateRouter.donate(routeKey, 1e8 * (i + 1), 3e8 * (i + 1), "");
            }
        }
        bytes32 expectedPoolState = _poolStateHash(routeId);
        assertTrue(vm.revertToStateAndDelete(snapshot));
        // These sixteen actions (4 swaps and 12 donations on a pool without extensions) need between 1,300,000 and
        // 1,350,000 gas of the router's limit with cold storage. 2,000,000 keeps a margin and fits the default budget.
        ExtensionSettings memory maxSettings = _settings(SWAP_CALLBACKS, false, true, ROUTE_GAS_LIMIT);
        maxSettings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 2_000_000;
        _installAndActivate(poolKey, address(router), maxSettings);
        _fund(router, poolId, VAULT_FUNDS);
        // Build and verify inside the callback without the mock's stored-action and stored-result copies.
        router.setExternalCall(
            CallbackType.AfterSwap, address(this), abi.encodeCall(this.executeMaximumActions, (expected))
        );

        vm.recordLogs();
        _swapExactInput(poolKey, true, 1e14);

        _assertMaximumActionOrder(vm.getRecordedLogs(), expected);
        assertEq(maximumActionsVerified, 1);
        assertEq(_poolStateHash(routeId), expectedPoolState);
        (int256 delta0, int256 delta1) = _sum(expected);
        _assertBalances(poolId, router, VAULT_FUNDS, delta0, delta1);
        assertEq(hook.currentContext().depth, 0);
    }

    /// @dev Executes inside the router's callback; the route retains the active installation's identity.
    function executeMaximumActions(BalanceDelta[] calldata expected) external {
        assertEq(msg.sender, address(router));
        assertEq(hook.currentContext().extension, address(router));
        uint256 count = executor.MAX_ACTIONS();
        assertEq(expected.length, count);
        RouteAction[] memory actions = new RouteAction[](count);
        for (uint256 i; i < count; ++i) {
            actions[i] = _maximumAction(i);
        }
        vm.prank(address(router));
        BalanceDelta[] memory results = hook.executeRoute(actions);
        assertEq(results.length, count);
        for (uint256 i; i < count; ++i) {
            assertEq(BalanceDelta.unwrap(results[i]), BalanceDelta.unwrap(expected[i]));
        }
        ++maximumActionsVerified;
    }

    function _maximumAction(uint256 index) private view returns (RouteAction memory) {
        if (index % 4 == 0) {
            return _swapAction(routeKey, index % 8 == 0, ROUTE_SWAP_AMOUNT * (index + 1));
        }
        return RouteAction({
            key: routeKey,
            operation: Operation.Donate,
            parameters: abi.encode(1e8 * (index + 1), 3e8 * (index + 1)),
            hookData: ""
        });
    }

    function _assertMaximumActionOrder(Vm.Log[] memory entries, BalanceDelta[] memory expected) private view {
        uint256 actionIndex;
        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.emitter != address(manager) || entry.topics.length != 3) continue;
            if (entry.topics[1] != PoolId.unwrap(routeId)) continue;
            assertLt(actionIndex, expected.length);
            assertEq(entry.topics[2], bytes32(uint256(uint160(address(executor)))));
            if (actionIndex % 4 == 0) {
                assertEq(entry.topics[0], IPoolManager.Swap.selector);
                (int128 amount0, int128 amount1,,,,) =
                    abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(amount0, expected[actionIndex].amount0());
                assertEq(amount1, expected[actionIndex].amount1());
            } else {
                assertEq(entry.topics[0], IPoolManager.Donate.selector);
                (uint256 amount0, uint256 amount1) = abi.decode(entry.data, (uint256, uint256));
                assertEq(amount0, uint256(-int256(expected[actionIndex].amount0())));
                assertEq(amount1, uint256(-int256(expected[actionIndex].amount1())));
            }
            ++actionIndex;
        }
        assertEq(actionIndex, expected.length);
    }

    /// @dev Installation membership alone does not grant the active extension's route authority.
    function test_executeRoute_rejectsInstalledCallerOtherThanCurrentExtension() public {
        _installRouter(false);
        CodexRouteCaller intruder = new CodexRouteCaller(address(hook));
        _installAndActivate(
            poolKey, address(intruder), _settings(uint16(1) << uint8(CallbackType.BeforeDonate), false, true)
        );
        _fund(intruder, poolId, VAULT_FUNDS);
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _swapAction(routeKey, true, ROUTE_SWAP_AMOUNT);
        router.setExternalCall(CallbackType.AfterSwap, address(intruder), abi.encodeCall(intruder.callRoute, (actions)));
        assertTrue(hook.isInstalled(poolId, address(intruder)));
        // Isolates frame.extension != msg.sender: caller is installed, allows nesting and has a valid funded route.
        vm.expectRevert(_routeFailure(abi.encodeWithSelector(IKernelHook.NestingDenied.selector)));

        _swapExactInput(poolKey, true, 1e14);
    }

    /// @dev A route cannot bypass the hook-address rule by targeting an otherwise valid pool key.
    function test_executeRoute_rejectsInvalidTargetKeyHookAddress() public {
        PoolKey memory target = routeKey;
        target.hooks = IHooks(address(0));
        // Isolates validatePoolKey's hook-address check: current installation and nesting guards pass.
        _expectInvalidTarget(target);
    }

    /// @dev Currency ordering is checked during authorization before the PoolManager action.
    function test_executeRoute_rejectsInvalidTargetKeyCurrencyOrder() public {
        PoolKey memory target = routeKey;
        (target.currency0, target.currency1) = (target.currency1, target.currency0);
        // Isolates validatePoolKey's currency-order check: hook identity and nesting guards pass.
        _expectInvalidTarget(target);
    }

    /// @dev A zero tick spacing never reaches the PoolManager through a route.
    function test_executeRoute_rejectsInvalidTargetKeyTickSpacing() public {
        PoolKey memory target = routeKey;
        target.tickSpacing = 0;
        // Isolates validatePoolKey's minimum-spacing check: hook identity, currency order and nesting guards pass.
        _expectInvalidTarget(target);
    }

    /// @dev Tick spacing also has an upper bound even when it is positive.
    function test_executeRoute_rejectsInvalidTargetKeyTickSpacingAboveMaximum() public {
        PoolKey memory target = routeKey;
        target.tickSpacing = TickMath.MAX_TICK_SPACING + 1;
        // Isolates validatePoolKey's maximum-spacing check: hook, currency order and minimum spacing are valid.
        _expectInvalidTarget(target);
    }

    /// @dev Both currencies of a donation are owed by the originating installation.
    function test_executeRoute_donateSettlesBothCurrencies() public {
        _installRouter(false);
        uint256 amount0 = 1e12;
        uint256 amount1 = 2e12;
        router.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction({
                key: routeKey,
                operation: Operation.Donate,
                parameters: abi.encode(amount0, amount1),
                hookData: "donation"
            })
        );

        _swapExactInput(poolKey, true, 1e14);

        BalanceDelta[] memory results = router.lastRouteResults();
        assertEq(results.length, 1);
        assertEq(results[0].amount0(), -int128(int256(amount0)));
        assertEq(results[0].amount1(), -int128(int256(amount1)));
        _assertBalances(poolId, router, VAULT_FUNDS, -int256(amount0), -int256(amount1));
        assertEq(hook.VAULT().accountedBalance(currency0), VAULT_FUNDS - amount0);
        assertEq(hook.VAULT().accountedBalance(currency1), VAULT_FUNDS - amount1);
    }

    /// @dev Runs from the second parent's target extension before its own route starts.
    function assertParentDeltas(BalanceDelta firstResult) external {
        assertEq(hook.currentContext().depth, 2);
        assertLt(firstResult.amount0(), 0);
        assertGt(firstResult.amount1(), 0);
        assertEq(manager.currencyDelta(address(executor), currency0), int256(firstResult.amount0()));
        assertEq(manager.currencyDelta(address(executor), currency1), int256(firstResult.amount1()));
        ++parentDebtObservations;
    }

    function _installRouter(bool optional) private {
        _installAndActivate(poolKey, address(router), _settings(SWAP_CALLBACKS, optional, true, ROUTE_GAS_LIMIT));
        _fund(router, poolId, VAULT_FUNDS);
    }

    function _fund(MockExtension extension, PoolId fundedPoolId, uint256 amount) private {
        IERC20(Currency.unwrap(currency0)).transfer(address(extension), amount);
        IERC20(Currency.unwrap(currency1)).transfer(address(extension), amount);
        extension.deposit(fundedPoolId, currency0, amount);
        extension.deposit(fundedPoolId, currency1, amount);
    }

    function _swapAction(PoolKey memory target, bool zeroForOne, uint256 amount)
        private
        pure
        returns (RouteAction memory)
    {
        return RouteAction({
            key: target,
            operation: Operation.Swap,
            parameters: abi.encode(_exactInputParameters(zeroForOne, amount)),
            hookData: ""
        });
    }

    function _liquidityAction(PoolKey memory target, int256 liquidityDelta) private pure returns (RouteAction memory) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams(-60, 60, liquidityDelta, bytes32(0));
        return
            RouteAction({
                key: target, operation: Operation.ModifyLiquidity, parameters: abi.encode(params), hookData: ""
            });
    }

    function _sum(BalanceDelta[] memory results) private pure returns (int256 delta0, int256 delta1) {
        for (uint256 i; i < results.length; ++i) {
            delta0 += results[i].amount0();
            delta1 += results[i].amount1();
        }
    }

    function _assertBalances(PoolId origin, MockExtension extension, uint256 starting, int256 delta0, int256 delta1)
        private
        view
    {
        assertEq(hook.VAULT().balanceOf(origin, address(extension), currency0), uint256(int256(starting) + delta0));
        assertEq(hook.VAULT().balanceOf(origin, address(extension), currency1), uint256(int256(starting) + delta1));
    }

    function _poolStateHash(PoolId targetId) private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(targetId);
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(targetId);
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1, manager.getLiquidity(targetId)));
    }

    function _expectInvalidTarget(PoolKey memory target) private {
        _installRouter(false);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(target, true, ROUTE_SWAP_AMOUNT));
        vm.expectRevert(_routeFailure(abi.encodeWithSelector(IKernelHook.InvalidPool.selector)));
        _swapExactInput(poolKey, true, 1e14);
    }

    function _routeFailure(bytes memory reason) private view returns (bytes memory) {
        return _hookRevert(
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(
                IKernelHook.ExtensionFailed.selector, address(router), CallbackType.AfterSwap, reason
            )
        );
    }
}
