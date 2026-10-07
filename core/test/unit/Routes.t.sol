// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {KernelRouteExecutor} from "../../src/KernelRouteExecutor.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Nested routes: executeRoute, the ticket handshake, depth and reentry limits, route positions,
/// unwindPositions and the initial-liquidity exception.
contract RoutesTest is KernelHookFixture {
    using StateLibrary for IPoolManager;

    /// @dev A route runs inside the callback gas limit, together with the reserves of the nested operation's own
    /// extension calls. 2,500,000 + 80,645 + 250,000 + 80,000 (return) + 25,000 (sequence setup) + 25,000 + 12,000
    /// = 2,972,645 fits the default budget of 4,000,000.
    uint32 internal constant ROUTE_GAS_LIMIT = 2_500_000;
    uint256 internal constant VAULT_FUNDS = 1e16;
    uint256 internal constant ROUTE_SWAP_AMOUNT = 1e12;
    uint128 internal constant ROUTE_LIQUIDITY = 1e15;
    /// @dev Two required routers on the same callbacks must fit the budget together:
    /// 2 * (1,200,000 + 38,709 + 250,000) + 80,000 + 25,000 + 2 * (25,000 + 12,000) = 3,156,418.
    uint32 internal constant TWO_ROUTERS_GAS_LIMIT = 1_200_000;
    bytes32 internal constant SALT = bytes32(uint256(1));

    PoolKey internal poolKey;
    PoolKey internal routeKey;
    PoolId internal poolId;
    PoolId internal routeId;
    MockExtension internal router;
    KernelRouteExecutor internal executor;

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

    // ---------------------------------------------------------------- executeRoute

    function test_executeRoute_swapsOnAnotherPoolAndSettlesFromVault() public {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));
        uint256 balance0 = hook.VAULT().balanceOf(poolId, address(router), currency0);
        uint256 balance1 = hook.VAULT().balanceOf(poolId, address(router), currency1);

        _swapExactInput(poolKey, true, 1e14);

        BalanceDelta result = router.lastRouteResults()[0];
        assertEq(result.amount0(), -int128(int256(ROUTE_SWAP_AMOUNT)));
        assertGt(result.amount1(), 0);
        assertEq(hook.VAULT().balanceOf(poolId, address(router), currency0), balance0 - ROUTE_SWAP_AMOUNT);
        assertEq(hook.VAULT().balanceOf(poolId, address(router), currency1), balance1 + uint128(result.amount1()));
    }

    function test_executeRoute_nestedContextShowsRootAndCurrentOperation() public {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));
        MockExtension observer = new MockExtension(address(hook));
        _installAndActivate(routeKey, address(observer), _settings(SWAP_CALLBACKS, false, false));

        _swapExactInput(poolKey, true, 1e14);

        // setUp ran four operations (two initializations, two liquidity additions), so this swap is operation 5.
        ExecutionContext memory nested = observer.lastContext();
        ExecutionContext memory root = router.lastContext();
        assertEq(PoolId.unwrap(nested.poolId), PoolId.unwrap(routeId));
        assertEq(PoolId.unwrap(nested.rootPoolId), PoolId.unwrap(poolId));
        assertEq(nested.rootOperationId, 5);
        assertEq(root.rootOperationId, 5);
        assertEq(uint8(nested.callback), uint8(CallbackType.AfterSwap));
        assertEq(uint8(root.callback), uint8(CallbackType.AfterSwap));
        assertEq(nested.extension, address(observer));
        assertEq(root.extension, address(router));
        assertEq(nested.sender, address(executor));
        assertEq(root.sender, address(swapRouter));
        assertEq(nested.depth, 2);
        assertEq(root.depth, 1);
        assertEq(hook.currentContext().depth, 0);
    }

    function test_executeRoute_revertsWhenTargetPoolIsNotInitialized() public {
        PoolKey memory preparedKey = PoolKey(currency0, currency1, 10_000, 60, IHooks(address(hook)));
        hook.preparePool(preparedKey);
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(preparedKey));
        vm.expectRevert(
            _routeFailure(CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.PoolNotInitialized.selector))
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    function test_executeRoute_revertsWhenInstallationDoesNotAllowNesting() public {
        _installRouter(false, false);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));
        vm.expectRevert(
            _routeFailure(CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.NestingDenied.selector))
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    function test_executeRoute_revertsOutsideAnOperation() public {
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _swapAction(routeKey);
        vm.expectRevert(IKernelHook.NestingDenied.selector);
        hook.executeRoute(actions);
    }

    function test_executeRoute_revertsWhenRouteHasTooManyActions() public {
        _installRouter(false, true);
        // MAX_ACTIONS + 1
        for (uint256 i; i < executor.MAX_ACTIONS() + 1; ++i) {
            router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));
        }
        vm.expectRevert(
            _routeFailure(CallbackType.AfterSwap, abi.encodeWithSelector(KernelRouteExecutor.InvalidRoute.selector))
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    // ---------------------------------------------------------------- depth and reentry limits

    function test_executeRoute_revertsWhenRootPoolDepthLimitIsReached() public {
        hook.setExecutionLimits(poolKey, 1, _defaultBudgets());
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));
        vm.expectRevert(
            _routeFailure(CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.DepthLimitReached.selector))
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    function test_executeRoute_revertsWhenTargetPoolDepthLimitIsReached() public {
        hook.setExecutionLimits(routeKey, 1, _defaultBudgets());
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));
        vm.expectRevert(
            _routeFailure(CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.DepthLimitReached.selector))
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    /// @dev The required router's own gas limit still counts as required gas while it runs, so its pool
    /// is not yet open for reentry.
    function test_executeRoute_revertsWhenRequiredExtensionRoutesIntoItsOwnPool() public {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(poolKey));
        vm.expectRevert(
            _routeFailure(CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.ReentrancyDenied.selector))
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    /// @dev An optional router leaves no required gas, so only the before-phase rule denies this reentry.
    function test_executeRoute_deniesReentryIntoOwnPoolFromBeforeSwap() public {
        _installRouter(true, true);
        router.addRouteAction(CallbackType.BeforeSwap, _swapAction(poolKey));
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            poolId,
            address(router),
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(IKernelHook.ReentrancyDenied.selector)
        );
        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 0);
        assertEq(router.callCount(CallbackType.BeforeSwap), 0);
    }

    /// @dev An optional router leaves no required gas, so it can reenter its own pool from afterSwap. In the
    /// nested swap, KernelHook skips the router itself, because one of its calls is still in progress.
    function test_executeRoute_optionalExtensionReentersItsOwnPoolFromAfterSwap() public {
        _installRouter(true, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(poolKey));

        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            poolId, address(router), CallbackType.BeforeSwap, abi.encodePacked(IKernelHook.ReentrancyDenied.selector)
        );
        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 1);
        assertEq(router.callCount(CallbackType.AfterSwap), 1);
    }

    // ---------------------------------------------------------------- ticket handshake

    /// @dev The call comes from inside an operation, so only the caller check can reject it.
    function test_authorizeAction_revertsWhenCallerIsNotRouteExecutor() public {
        _installRouter(false, true);
        router.setExternalCall(
            CallbackType.AfterSwap,
            address(hook),
            abi.encodeWithSelector(hook.authorizeAction.selector, _swapAction(routeKey))
        );
        vm.expectRevert(
            _routeFailure(CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.Unauthorized.selector))
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    function test_authorizeAction_revertsWhenNoOperationIsInProgress() public {
        vm.prank(address(executor));
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.authorizeAction(_swapAction(routeKey));
    }

    /// @dev An extension of the route pool calls finishAction while the route's ticket is live, so only the caller
    /// check can reject it.
    function test_finishAction_revertsWhenCallerIsNotRouteExecutor() public {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));
        MockExtension intruder = new MockExtension(address(hook));
        _installAndActivate(routeKey, address(intruder), _settings(SWAP_CALLBACKS, true, false));
        intruder.setExternalCall(
            CallbackType.BeforeSwap, address(hook), abi.encodeWithSelector(hook.finishAction.selector)
        );
        _expectFailureSkip(routeId, intruder, CallbackType.BeforeSwap, IKernelHook.Unauthorized.selector);

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 1);
    }

    function test_finishAction_revertsWhenThereIsNoTicket() public {
        vm.prank(address(executor));
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.finishAction();
    }

    function test_routeExecutor_rejectsCallersOtherThanKernelHook() public {
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _swapAction(routeKey);
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        executor.executeWhileUnlocked(poolId, address(router), actions);
        // An empty route: with actions, KernelHook's authorizeAction would also reject the call.
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        executor.unlockAndExecute(poolId, address(router), new RouteAction[](0));
        // The PoolManager is the right caller, but the executor did not start this unlock.
        vm.prank(address(manager));
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        executor.unlockCallback("");
    }

    /// @dev An extension of the route pool calls unlockCallback while the executor's own unlock is in progress, so
    /// only the caller check can reject it.
    function test_routeExecutor_rejectsUnlockCallbackFromOtherCallerDuringUnlock() public {
        _openRoutePosition();
        MockExtension intruder = new MockExtension(address(hook));
        uint16 removeCallbacks = uint16(1) << uint8(CallbackType.BeforeRemoveLiquidity) | uint16(1)
            << uint8(CallbackType.AfterRemoveLiquidity);
        _installAndActivate(routeKey, address(intruder), _settings(removeCallbacks, true, false));
        intruder.setExternalCall(
            CallbackType.BeforeRemoveLiquidity,
            address(executor),
            abi.encodeWithSelector(executor.unlockCallback.selector, bytes(""))
        );
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -int256(uint256(ROUTE_LIQUIDITY)));
        _expectFailureSkip(routeId, intruder, CallbackType.BeforeRemoveLiquidity, IKernelHook.Unauthorized.selector);

        router.unwindPositions(poolKey, actions);

        assertEq(executor.openPositionCount(poolId, address(router)), 0);
    }

    // ---------------------------------------------------------------- route positions and unwindPositions

    function test_executeRoute_tracksPositionUnderNamespacedSalt() public {
        _openRoutePosition();

        assertEq(executor.positionLiquidity(poolId, address(router), routeId, -60, 60, bytes32(0)), ROUTE_LIQUIDITY);
        assertEq(executor.openPositionCount(poolId, address(router)), 1);
        // In the PoolManager, the executor owns the position under a salt that names the origin pool and extension.
        bytes32 namespacedSalt = keccak256(abi.encode(poolId, address(router), bytes32(0)));
        (uint128 liquidity,,) = manager.getPositionInfo(routeId, address(executor), -60, 60, namespacedSalt);
        assertEq(liquidity, ROUTE_LIQUIDITY);
    }

    function test_unwindPositions_closesPositionOfInactiveInstallation() public {
        _openRoutePosition();
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        uint256 balance0 = hook.VAULT().balanceOf(poolId, address(router), currency0);
        uint256 balance1 = hook.VAULT().balanceOf(poolId, address(router), currency1);

        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -int256(uint256(ROUTE_LIQUIDITY)));
        BalanceDelta result = router.unwindPositions(poolKey, actions)[0];

        assertEq(executor.positionLiquidity(poolId, address(router), routeId, -60, 60, bytes32(0)), 0);
        assertEq(executor.openPositionCount(poolId, address(router)), 0);
        assertEq(_managerPositionLiquidity(routeId, address(router)), 0);
        assertGt(result.amount0(), 0);
        assertGt(result.amount1(), 0);
        assertEq(hook.VAULT().balanceOf(poolId, address(router), currency0), balance0 + uint128(result.amount0()));
        assertEq(hook.VAULT().balanceOf(poolId, address(router), currency1), balance1 + uint128(result.amount1()));
        assertEq(hook.currentContext().depth, 0);
    }

    function test_unwindPositions_revertsForLiquidityIncrease() public {
        _installInactiveRouter();
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, int256(uint256(ROUTE_LIQUIDITY)));
        vm.expectRevert(IKernelHook.NestingDenied.selector);
        router.unwindPositions(poolKey, actions);
    }

    function test_unwindPositions_revertsForSwap() public {
        _installInactiveRouter();
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _swapAction(routeKey);
        vm.expectRevert(IKernelHook.NestingDenied.selector);
        router.unwindPositions(poolKey, actions);
    }

    function test_unwindPositions_revertsWhenRemovingMoreThanTheTrackedLiquidity() public {
        _openRoutePosition();
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -int256(uint256(ROUTE_LIQUIDITY) + 1));
        vm.expectRevert(KernelRouteExecutor.InvalidLiquidity.selector);
        router.unwindPositions(poolKey, actions);

        assertEq(executor.positionLiquidity(poolId, address(router), routeId, -60, 60, bytes32(0)), ROUTE_LIQUIDITY);
        assertEq(_managerPositionLiquidity(routeId, address(router)), ROUTE_LIQUIDITY);
    }

    /// @dev The extension is installed but not active, and the pool is prepared but not initialized.
    function test_unwindPositions_revertsWhenOriginPoolIsNotInitialized() public {
        PoolKey memory preparedKey = PoolKey(currency0, currency1, 10_000, 60, IHooks(address(hook)));
        hook.preparePool(preparedKey);
        _admit(address(router));
        hook.installExtension(
            preparedKey, IHookExtension(address(router)), _settings(SWAP_CALLBACKS, false, true, ROUTE_GAS_LIMIT)
        );
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -1);
        vm.expectRevert(IKernelHook.PoolNotInitialized.selector);
        router.unwindPositions(preparedKey, actions);
    }

    function test_unwindPositions_revertsWhileInstallationIsActive() public {
        _installRouter(false, true);
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -1);
        vm.expectRevert(IKernelHook.ExtensionActive.selector);
        router.unwindPositions(poolKey, actions);
    }

    function test_unwindPositions_revertsWhenCallerIsNotInstalled() public {
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -1);
        vm.expectRevert(IKernelHook.ExtensionNotInstalled.selector);
        hook.unwindPositions(poolKey, actions);
    }

    /// @dev The router withdraws its vault funds first, so the open position is its only obligation.
    function test_removeExtension_revertsWhileRoutePositionIsOpen() public {
        _openRoutePosition();
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        router.withdraw(poolId, currency0, hook.VAULT().balanceOf(poolId, address(router), currency0), address(this));
        router.withdraw(poolId, currency1, hook.VAULT().balanceOf(poolId, address(router), currency1), address(this));
        assertEq(hook.VAULT().fundedCurrencyCount(poolId, address(router)), 0);
        assertEq(executor.openPositionCount(poolId, address(router)), 1);
        vm.expectRevert(IKernelHook.OutstandingObligations.selector);
        hook.removeExtension(poolKey, IHookExtension(address(router)));
    }

    /// @dev Two extensions and two salts at the same target and ticks: each position is separate.
    function test_routePositions_areIsolatedByExtensionAndSalt() public {
        MockExtension other = new MockExtension(address(hook));
        _admit(address(router));
        _admit(address(other));
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, true, TWO_ROUTERS_GAS_LIMIT);
        hook.installExtension(poolKey, IHookExtension(address(router)), settings);
        hook.installExtension(poolKey, IHookExtension(address(other)), settings);
        hook.activateExtension(poolKey, IHookExtension(address(router)));
        hook.activateExtension(poolKey, IHookExtension(address(other)));
        _fund(router, poolId);
        _fund(other, poolId);
        int256 liquidity = int256(uint256(ROUTE_LIQUIDITY));
        router.addRouteAction(CallbackType.AfterSwap, _liquidityAction(routeKey, liquidity));
        router.addRouteAction(CallbackType.AfterSwap, _saltedLiquidityAction(liquidity, SALT));
        other.addRouteAction(CallbackType.AfterSwap, _liquidityAction(routeKey, liquidity));
        _swapExactInput(poolKey, true, 1e14);
        router.clearRoute(CallbackType.AfterSwap);
        assertEq(executor.openPositionCount(poolId, address(router)), 2);

        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -liquidity);
        router.unwindPositions(poolKey, actions);

        assertEq(executor.positionLiquidity(poolId, address(router), routeId, -60, 60, bytes32(0)), 0);
        assertEq(executor.positionLiquidity(poolId, address(router), routeId, -60, 60, SALT), ROUTE_LIQUIDITY);
        assertEq(executor.positionLiquidity(poolId, address(other), routeId, -60, 60, bytes32(0)), ROUTE_LIQUIDITY);
        assertEq(executor.openPositionCount(poolId, address(router)), 1);
        assertEq(executor.openPositionCount(poolId, address(other)), 1);
        assertEq(_managerPositionLiquidity(routeId, address(other)), ROUTE_LIQUIDITY);
    }

    /// @dev Depth counts the operations without the synthetic frame of unwindPositions. With a depth limit of 1,
    /// the nested removal is at depth 1, so it passes; counting the synthetic frame would give DepthLimitReached.
    function test_unwindPositions_depthLimitOfOneIgnoresSyntheticFrame() public {
        _openRoutePosition();
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        hook.setExecutionLimits(poolKey, 1, _defaultBudgets());
        hook.setExecutionLimits(routeKey, 1, _defaultBudgets());
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -int256(uint256(ROUTE_LIQUIDITY)));

        router.unwindPositions(poolKey, actions);

        assertEq(executor.openPositionCount(poolId, address(router)), 0);
    }

    /// @dev A zero-delta removal collects the fees of the position and leaves its liquidity as it is.
    function test_unwindPositions_collectsAccruedFeesAtZeroDelta() public {
        _openRoutePosition();
        _swapExactInput(routeKey, true, 1e14);
        _swapExactInput(routeKey, false, 1e14);
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        uint256 balance0 = hook.VAULT().balanceOf(poolId, address(router), currency0);
        uint256 balance1 = hook.VAULT().balanceOf(poolId, address(router), currency1);
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, 0);

        BalanceDelta fees = router.unwindPositions(poolKey, actions)[0];

        assertGt(fees.amount0(), 0);
        assertGt(fees.amount1(), 0);
        assertEq(hook.VAULT().balanceOf(poolId, address(router), currency0), balance0 + uint128(fees.amount0()));
        assertEq(hook.VAULT().balanceOf(poolId, address(router), currency1), balance1 + uint128(fees.amount1()));
        assertEq(executor.positionLiquidity(poolId, address(router), routeId, -60, 60, bytes32(0)), ROUTE_LIQUIDITY);
        assertEq(executor.openPositionCount(poolId, address(router)), 1);
        assertEq(_managerPositionLiquidity(routeId, address(router)), ROUTE_LIQUIDITY);
    }

    /// @dev The exit does not depend on the nesting right: an installation without it can still close its positions.
    function test_unwindPositions_worksWhenNestingIsNotAllowed() public {
        _openRoutePosition();
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        hook.configureExtension(
            poolKey, IHookExtension(address(router)), _settings(SWAP_CALLBACKS, false, false, ROUTE_GAS_LIMIT)
        );
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -int256(uint256(ROUTE_LIQUIDITY)));

        router.unwindPositions(poolKey, actions);

        assertEq(executor.openPositionCount(poolId, address(router)), 0);
    }

    /// @dev Isolates the idle check: without it, the executor would reject the call with InvalidRoute, because
    /// the PoolManager is already unlocked.
    function test_unwindPositions_revertsDuringOperation() public {
        _openRoutePosition();
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        MockExtension caller = new MockExtension(address(hook));
        _installAndActivate(poolKey, address(caller), _settings(SWAP_CALLBACKS, false, false));
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -int256(uint256(ROUTE_LIQUIDITY)));
        caller.setExternalCall(
            CallbackType.BeforeSwap, address(router), abi.encodeCall(MockExtension.unwindPositions, (poolKey, actions))
        );
        vm.expectRevert(
            _hookRevert(
                IHooks.beforeSwap.selector,
                _requiredFailure(
                    address(caller),
                    CallbackType.BeforeSwap,
                    abi.encodeWithSelector(IKernelHook.ExecutionInProgress.selector)
                )
            )
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    /// @dev During unwindPositions, the root of the context is the synthetic exit frame of the origin pool.
    /// The context depth counts all frames on the stack, so the nested removal is at depth 2.
    function test_unwindPositions_suppliesSyntheticRootContext() public {
        _openRoutePosition();
        MockExtension observer = new MockExtension(address(hook));
        uint16 removeCallbacks = uint16(1) << uint8(CallbackType.BeforeRemoveLiquidity) | uint16(1)
            << uint8(CallbackType.AfterRemoveLiquidity);
        _installAndActivate(routeKey, address(observer), _settings(removeCallbacks, false, false));
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -int256(uint256(ROUTE_LIQUIDITY)));

        router.unwindPositions(poolKey, actions);

        // setUp ran operations 1 to 4, the swap that opened the position was 5 and its nested addition 6.
        ExecutionContext memory context = observer.lastContext();
        assertEq(context.rootOperationId, 7);
        assertEq(PoolId.unwrap(context.rootPoolId), PoolId.unwrap(poolId));
        assertEq(PoolId.unwrap(context.poolId), PoolId.unwrap(routeId));
        assertEq(context.sender, address(executor));
        assertEq(context.extension, address(observer));
        assertEq(uint8(context.callback), uint8(CallbackType.AfterRemoveLiquidity));
        assertEq(context.depth, 2);
    }

    /// @dev The two nested swaps of one route reuse the same frame index in one transaction. The first pool's
    /// optional extension fails and is skipped; the skip must not carry over to the extension with the same index
    /// in the second pool. Transient storage keeps a popped frame's fields, so each push must reset them.
    function test_executeRoute_skipDoesNotCarryToTheNextNestedOperation() public {
        PoolKey memory secondKey = PoolKey(currency0, currency1, 100, 1, IHooks(address(hook)));
        _createPool(secondKey);
        _addLiquidity(secondKey);
        MockExtension failing = new MockExtension(address(hook));
        failing.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, 0, true, 0));
        _installAndActivate(routeKey, address(failing), _settings(SWAP_CALLBACKS, true, false));
        MockExtension healthy = new MockExtension(address(hook));
        _installAndActivate(secondKey, address(healthy), _settings(SWAP_CALLBACKS, true, false));
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(secondKey));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 2);
        assertEq(failing.callCount(CallbackType.AfterSwap), 0);
        assertEq(healthy.callCount(CallbackType.BeforeSwap), 1);
        assertEq(healthy.callCount(CallbackType.AfterSwap), 1);
    }

    // ---------------------------------------------------------------- origin of nested operations

    /// @dev A nested operation's context names the pool and the extension that started the route. A root operation's
    /// context names none.
    function test_context_originNamesTheExtensionThatStartedTheRoute() public {
        MockExtension observer = new MockExtension(address(hook));
        _installAndActivate(routeKey, address(observer), _settings(SWAP_CALLBACKS, true, false));
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));

        _swapExactInput(poolKey, true, 1e14);

        ExecutionContext memory nested = observer.lastContext();
        assertEq(nested.depth, 2);
        assertEq(PoolId.unwrap(nested.originPoolId), PoolId.unwrap(poolId));
        assertEq(nested.originExtension, address(router));

        router.clearRoute(CallbackType.AfterSwap);
        _swapExactInput(routeKey, true, 1e12);

        ExecutionContext memory root = observer.lastContext();
        assertEq(root.depth, 1);
        assertEq(PoolId.unwrap(root.originPoolId), bytes32(0));
        assertEq(root.originExtension, address(0));
    }

    /// @dev The actions of unwindPositions run under the synthetic exit frame, whose extension is the unwinding one.
    function test_context_originOfAnUnwindActionIsTheUnwindingExtension() public {
        _openRoutePosition();
        MockExtension observer = new MockExtension(address(hook));
        uint16 removalCallbacks = uint16(1) << uint8(CallbackType.BeforeRemoveLiquidity) | uint16(1)
            << uint8(CallbackType.AfterRemoveLiquidity);
        _installAndActivate(routeKey, address(observer), _settings(removalCallbacks, true, false));
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -int256(uint256(ROUTE_LIQUIDITY)));

        router.unwindPositions(poolKey, actions);

        ExecutionContext memory context = observer.lastContext();
        assertEq(context.depth, 2);
        assertEq(PoolId.unwrap(context.originPoolId), PoolId.unwrap(poolId));
        assertEq(context.originExtension, address(router));
    }

    // ---------------------------------------------------------------- context after operations

    /// @dev After a swap with a route, an unwind, and a swap with an optional skip, every context field is zero.
    function test_currentContext_isEmptyAfterEachOperation() public {
        _openRoutePosition();
        _assertContextIsEmpty();

        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(routeKey, -int256(uint256(ROUTE_LIQUIDITY)));
        router.unwindPositions(poolKey, actions);
        _assertContextIsEmpty();

        MockExtension failing = new MockExtension(address(hook));
        failing.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, 0, true, 0));
        _installAndActivate(routeKey, address(failing), _settings(SWAP_CALLBACKS, true, false));
        _swapExactInput(routeKey, true, 1e14);
        _assertContextIsEmpty();
    }

    /// @dev A second extension of the same callback reads the context after the router's nested swap has
    /// finished. The stack is back to the parent frame.
    function test_currentContext_restoresParentAfterNestedRoute() public {
        MockExtension probe = new MockExtension(address(hook));
        _admit(address(router));
        _admit(address(probe));
        hook.installExtension(
            poolKey, IHookExtension(address(router)), _settings(SWAP_CALLBACKS, false, true, ROUTE_GAS_LIMIT)
        );
        hook.installExtension(poolKey, IHookExtension(address(probe)), _settings(SWAP_CALLBACKS, false, false));
        hook.activateExtension(poolKey, IHookExtension(address(router)));
        hook.activateExtension(poolKey, IHookExtension(address(probe)));
        _fund(router, poolId);
        router.addRouteAction(CallbackType.AfterSwap, _swapAction(routeKey));
        probe.setExternalCall(CallbackType.AfterSwap, address(this), abi.encodeCall(this.recordContext, ()));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 1);
        assertEq(_recordedContext.depth, 1);
        assertEq(_recordedContext.rootOperationId, 5);
        assertEq(PoolId.unwrap(_recordedContext.poolId), PoolId.unwrap(poolId));
        assertEq(PoolId.unwrap(_recordedContext.rootPoolId), PoolId.unwrap(poolId));
        assertEq(_recordedContext.sender, address(swapRouter));
        assertEq(_recordedContext.extension, address(probe));
        assertEq(uint8(_recordedContext.callback), uint8(CallbackType.AfterSwap));
    }

    ExecutionContext internal _recordedContext;

    /// @notice The probe extension calls this from inside a swap.
    function recordContext() external {
        _recordedContext = hook.currentContext();
    }

    // ---------------------------------------------------------------- initial liquidity of a new pool

    function test_executeRoute_seedsFirstLiquidityInAfterInitialize() public {
        (PoolKey memory newKey, MockExtension seeder) = _prepareSeededPool();
        seeder.addRouteAction(CallbackType.AfterInitialize, _liquidityAction(newKey, int256(uint256(ROUTE_LIQUIDITY))));

        manager.initialize(newKey, SQRT_PRICE_1_1);

        PoolId newId = newKey.toId();
        assertTrue(hook.isPoolInitialized(newId));
        assertEq(executor.positionLiquidity(newId, address(seeder), newId, -60, 60, bytes32(0)), ROUTE_LIQUIDITY);
        assertEq(executor.openPositionCount(newId, address(seeder)), 1);
        bytes32 namespacedSalt = keccak256(abi.encode(newId, address(seeder), bytes32(0)));
        (uint128 liquidity,,) = manager.getPositionInfo(newId, address(executor), -60, 60, namespacedSalt);
        assertEq(liquidity, ROUTE_LIQUIDITY);
        assertEq(hook.currentContext().depth, 0);
    }

    /// @dev The route executor records the position before it asks KernelHook to authorize the action, and a new
    /// pool has no positions. So a removal fails with InvalidLiquidity first. KernelHook's own rule (no removal
    /// while the pool initializes) is a second line of defense behind it, and this test does not reach that rule.
    function test_executeRoute_revertsWhenFirstLiquidityActionRemovesLiquidity() public {
        (PoolKey memory newKey, MockExtension seeder) = _prepareSeededPool();
        seeder.addRouteAction(CallbackType.AfterInitialize, _liquidityAction(newKey, -1));
        bytes memory failure = _requiredFailure(
            address(seeder),
            CallbackType.AfterInitialize,
            abi.encodeWithSelector(KernelRouteExecutor.InvalidLiquidity.selector)
        );
        vm.expectRevert(_hookRevert(IHooks.afterInitialize.selector, failure));
        manager.initialize(newKey, SQRT_PRICE_1_1);
    }

    function test_executeRoute_revertsFromBeforeInitializeWhilePoolManagerIsLocked() public {
        (PoolKey memory newKey, MockExtension seeder) = _prepareSeededPool();
        seeder.addRouteAction(CallbackType.BeforeInitialize, _swapAction(routeKey));
        bytes memory failure = _requiredFailure(
            address(seeder), CallbackType.BeforeInitialize, abi.encodeWithSelector(IKernelHook.NestingDenied.selector)
        );
        vm.expectRevert(_hookRevert(IHooks.beforeInitialize.selector, failure));
        manager.initialize(newKey, SQRT_PRICE_1_1);
    }

    /// @dev The executor's tracking allows the removal, because the first action added liquidity. KernelHook's own
    /// rule then rejects it: during initialization, only additions to the new pool are allowed.
    function test_executeRoute_afterInitializeRejectsRemovalAfterAddingLiquidity() public {
        (PoolKey memory newKey, MockExtension seeder) = _prepareSeededPool();
        seeder.addRouteAction(CallbackType.AfterInitialize, _liquidityAction(newKey, int256(uint256(ROUTE_LIQUIDITY))));
        seeder.addRouteAction(CallbackType.AfterInitialize, _liquidityAction(newKey, -1));
        bytes memory failure = _requiredFailure(
            address(seeder),
            CallbackType.AfterInitialize,
            abi.encodeWithSelector(IKernelHook.PoolNotInitialized.selector)
        );
        vm.expectRevert(_hookRevert(IHooks.afterInitialize.selector, failure));
        manager.initialize(newKey, SQRT_PRICE_1_1);
    }

    function test_executeRoute_afterInitializeCannotSwapOrDonateOnItsOwnPool() public {
        (PoolKey memory newKey, MockExtension seeder) = _prepareSeededPool();
        bytes memory failure = _requiredFailure(
            address(seeder),
            CallbackType.AfterInitialize,
            abi.encodeWithSelector(IKernelHook.PoolNotInitialized.selector)
        );
        seeder.addRouteAction(CallbackType.AfterInitialize, _swapAction(newKey));
        vm.expectRevert(_hookRevert(IHooks.afterInitialize.selector, failure));
        manager.initialize(newKey, SQRT_PRICE_1_1);

        seeder.clearRoute(CallbackType.AfterInitialize);
        seeder.addRouteAction(
            CallbackType.AfterInitialize, RouteAction(newKey, Operation.Donate, abi.encode(uint256(1), uint256(1)), "")
        );
        vm.expectRevert(_hookRevert(IHooks.afterInitialize.selector, failure));
        manager.initialize(newKey, SQRT_PRICE_1_1);
    }

    /// @dev From AfterInitialize, the PoolManager is locked, so the executor unlocks it for the route.
    function test_executeRoute_afterInitializeCanRouteToAnotherInitializedPool() public {
        (PoolKey memory newKey, MockExtension seeder) = _prepareSeededPool();
        seeder.addRouteAction(CallbackType.AfterInitialize, _swapAction(routeKey));
        PoolId newId = newKey.toId();
        uint256 balance0 = hook.VAULT().balanceOf(newId, address(seeder), currency0);

        manager.initialize(newKey, SQRT_PRICE_1_1);

        assertTrue(hook.isPoolInitialized(newId));
        assertEq(seeder.lastRouteResults()[0].amount0(), -int128(int256(ROUTE_SWAP_AMOUNT)));
        assertEq(hook.VAULT().balanceOf(newId, address(seeder), currency0), balance0 - ROUTE_SWAP_AMOUNT);
    }

    /// @dev The boundary of the rule is a liquidity delta of zero: it counts as an addition.
    function test_executeRoute_afterInitializeAllowsZeroDeltaAfterSeed() public {
        (PoolKey memory newKey, MockExtension seeder) = _prepareSeededPool();
        seeder.addRouteAction(CallbackType.AfterInitialize, _liquidityAction(newKey, int256(uint256(ROUTE_LIQUIDITY))));
        seeder.addRouteAction(CallbackType.AfterInitialize, _liquidityAction(newKey, 0));

        manager.initialize(newKey, SQRT_PRICE_1_1);

        PoolId newId = newKey.toId();
        assertEq(executor.positionLiquidity(newId, address(seeder), newId, -60, 60, bytes32(0)), ROUTE_LIQUIDITY);
        assertEq(seeder.lastRouteResults().length, 2);
    }

    // ---------------------------------------------------------------- helpers

    function _installRouter(bool optionalCallbacks, bool allowNesting) private {
        _installAndActivate(
            poolKey, address(router), _settings(SWAP_CALLBACKS, optionalCallbacks, allowNesting, ROUTE_GAS_LIMIT)
        );
        _fund(router, poolId);
    }

    /// @dev Installs the router and deactivates it, as a starting point for unwindPositions.
    function _installInactiveRouter() private {
        _installRouter(false, true);
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
    }

    /// @dev In afterSwap of the main pool, the router adds liquidity to the route pool.
    function _openRoutePosition() private {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _liquidityAction(routeKey, int256(uint256(ROUTE_LIQUIDITY))));
        _swapExactInput(poolKey, true, 1e14);
        router.clearRoute(CallbackType.AfterSwap);
    }

    /// @dev Prepares a new pool with a funded extension on both initialization callbacks, before initialize.
    function _prepareSeededPool() private returns (PoolKey memory newKey, MockExtension seeder) {
        newKey = PoolKey(currency0, currency1, 10_000, 60, IHooks(address(hook)));
        hook.preparePool(newKey);
        seeder = new MockExtension(address(hook));
        uint16 initializationCallbacks =
            uint16(1) << uint8(CallbackType.BeforeInitialize) | uint16(1) << uint8(CallbackType.AfterInitialize);
        _installAndActivate(newKey, address(seeder), _settings(initializationCallbacks, false, true, ROUTE_GAS_LIMIT));
        _fund(seeder, newKey.toId());
    }

    function _fund(MockExtension extension, PoolId fundedPoolId) private {
        IERC20(Currency.unwrap(currency0)).transfer(address(extension), VAULT_FUNDS);
        IERC20(Currency.unwrap(currency1)).transfer(address(extension), VAULT_FUNDS);
        extension.deposit(fundedPoolId, currency0, VAULT_FUNDS);
        extension.deposit(fundedPoolId, currency1, VAULT_FUNDS);
    }

    function _swapAction(PoolKey memory target) private pure returns (RouteAction memory) {
        return RouteAction({
            key: target,
            operation: Operation.Swap,
            parameters: abi.encode(_exactInputParameters(true, ROUTE_SWAP_AMOUNT)),
            hookData: ""
        });
    }

    function _liquidityAction(PoolKey memory target, int256 liquidityDelta) private pure returns (RouteAction memory) {
        ModifyLiquidityParams memory parameters =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: liquidityDelta, salt: bytes32(0)});
        return RouteAction({
            key: target, operation: Operation.ModifyLiquidity, parameters: abi.encode(parameters), hookData: ""
        });
    }

    function _managerPositionLiquidity(PoolId targetId, address extension) private view returns (uint128 liquidity) {
        bytes32 namespacedSalt = keccak256(abi.encode(poolId, extension, bytes32(0)));
        (liquidity,,) = manager.getPositionInfo(targetId, address(executor), -60, 60, namespacedSalt);
    }

    /// @dev Expects the skip of an optional extension whose callback failed with errorSelector.
    function _expectFailureSkip(
        PoolId skippedPoolId,
        MockExtension extension,
        CallbackType callback,
        bytes4 errorSelector
    ) private {
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            skippedPoolId, address(extension), callback, abi.encodeWithSelector(errorSelector)
        );
    }

    function _saltedLiquidityAction(int256 liquidityDelta, bytes32 salt) private view returns (RouteAction memory) {
        ModifyLiquidityParams memory parameters =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: liquidityDelta, salt: salt});
        return RouteAction({
            key: routeKey, operation: Operation.ModifyLiquidity, parameters: abi.encode(parameters), hookData: ""
        });
    }

    function _assertContextIsEmpty() private view {
        ExecutionContext memory empty;
        assertEq(abi.encode(hook.currentContext()), abi.encode(empty));
    }

    function _defaultBudgets() private pure returns (uint32[CALLBACK_COUNT] memory budgets) {
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = 4_000_000;
        }
    }

    /// @dev The revert data of a swap whose required router failed in callback with reason.
    function _routeFailure(CallbackType callback, bytes memory reason) private view returns (bytes memory) {
        bytes4 hookCallback =
            callback == CallbackType.BeforeSwap ? IHooks.beforeSwap.selector : IHooks.afterSwap.selector;
        return _hookRevert(hookCallback, _requiredFailure(address(router), callback, reason));
    }

    /// @dev The dispatch loop reports a required extension failure once, with the extension's revert data.
    function _requiredFailure(address extension, CallbackType callback, bytes memory reason)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(IKernelHook.ExtensionFailed.selector, extension, callback, reason);
    }
}
