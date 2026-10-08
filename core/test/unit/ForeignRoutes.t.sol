// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {CALLBACK_COUNT, CallbackType, Operation, RouteAction} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice ForeignSwap route actions: swaps in a hookless pool on the same PoolManager, settled net with the rest of
/// the route. They open no Kernel operation and use no ticket.
contract ForeignRoutesTest is KernelHookFixture {
    using StateLibrary for IPoolManager;

    /// @dev Same budget reasoning as RoutesTest: the route and the nested operation's reserves fit 4,000,000.
    uint32 private constant ROUTE_GAS_LIMIT = 2_500_000;
    /// @dev The inner router of a nested route runs inside the outer route's gas.
    uint32 private constant INNER_ROUTE_GAS_LIMIT = 800_000;
    uint256 private constant VAULT_FUNDS = 1e16;
    uint256 private constant ROUTE_SWAP_AMOUNT = 1e12;

    PoolKey private poolKey;
    PoolKey private routeKey;
    PoolKey private foreignKey;
    PoolId private poolId;
    PoolId private routeId;
    PoolId private foreignId;
    MockExtension private router;
    KernelHookVault private vault;

    function setUp() public override {
        super.setUp();
        poolKey = _poolKey();
        poolId = poolKey.toId();
        routeKey = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        routeId = routeKey.toId();
        foreignKey = _plainPoolKey();
        foreignId = foreignKey.toId();
        _createPool(poolKey);
        _addLiquidity(poolKey);
        _createPool(routeKey);
        _addLiquidity(routeKey);
        // A hookless pool is initialized directly: KernelHook never prepares it.
        manager.initialize(foreignKey, SQRT_PRICE_1_1);
        _addLiquidity(foreignKey);
        router = new MockExtension(address(hook));
        vault = hook.VAULT();
    }

    // ---------------------------------------------------------------- settlement

    function testFuzz_foreignSwap_settlesFromTheOriginVaultOnly(bool zeroForOne, bool exactInput, uint256 amount)
        public
    {
        amount = bound(amount, 1e6, ROUTE_SWAP_AMOUNT);
        _installRouter(false, true);
        MockExtension other = _fundedBystander();
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        router.addRouteAction(CallbackType.AfterSwap, _foreignSwap(foreignKey, zeroForOne, specified));
        (uint256 before0, uint256 before1) = _balances(poolId, address(router));
        (uint160 priceBefore,,,) = manager.getSlot0(foreignId);

        _swapExactInput(poolKey, true, 1e14);

        BalanceDelta result = router.lastRouteResults()[0];
        (int128 input, int128 output) =
            zeroForOne ? (result.amount0(), result.amount1()) : (result.amount1(), result.amount0());
        assertLt(input, 0);
        assertGt(output, 0);
        if (exactInput) assertEq(input, -int128(int256(amount)));
        else assertEq(output, int128(int256(amount)));
        (uint256 after0, uint256 after1) = _balances(poolId, address(router));
        assertEq(int256(after0) - int256(before0), result.amount0());
        assertEq(int256(after1) - int256(before1), result.amount1());
        (uint256 other0, uint256 other1) = _balances(routeId, address(other));
        assertEq(other0, VAULT_FUNDS);
        assertEq(other1, VAULT_FUNDS);
        (uint160 priceAfter,,,) = manager.getSlot0(foreignId);
        assertTrue(priceAfter != priceBefore);
    }

    /// @dev The gross input of currency0 is about 1e12, but the vault holds 1e10: only netting lets it settle. The
    /// vault holds no currency1, which is bought and sold in the same route.
    function test_foreignSwap_mixedRouteSettlesOnlyNetDebt() public {
        _installRouter(false, true);
        router.withdraw(poolId, currency0, VAULT_FUNDS - 1e10, address(this));
        router.withdraw(poolId, currency1, VAULT_FUNDS, address(this));
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, true, int256(ROUTE_SWAP_AMOUNT)));
        router.addRouteAction(CallbackType.AfterSwap, _foreignSwap(foreignKey, false, -int256(ROUTE_SWAP_AMOUNT)));

        _swapExactInput(poolKey, true, 1e14);

        BalanceDelta[] memory results = router.lastRouteResults();
        assertEq(results[0].amount1(), int128(int256(ROUTE_SWAP_AMOUNT)));
        assertEq(results[1].amount1(), -int128(int256(ROUTE_SWAP_AMOUNT)));
        int256 net0 = int256(results[0].amount0()) + results[1].amount0();
        assertLt(net0, 0);
        (uint256 balance0, uint256 balance1) = _balances(poolId, address(router));
        assertEq(int256(balance0), 1e10 + net0);
        assertEq(balance1, 0);
    }

    /// @dev The optional router cannot pay the net debt. Its route rolls back, the swap continues, and the vault never
    /// borrows the balance of another installation.
    function test_foreignSwap_unpaidNetDebtRollsBackWithoutBorrowing() public {
        _installRouter(true, true);
        router.withdraw(poolId, currency0, VAULT_FUNDS, address(this));
        MockExtension other = _fundedBystander();
        router.addRouteAction(CallbackType.AfterSwap, _foreignSwap(foreignKey, true, -int256(ROUTE_SWAP_AMOUNT)));
        (uint160 priceBefore,,,) = manager.getSlot0(foreignId);

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 0);
        (uint160 priceAfter,,,) = manager.getSlot0(foreignId);
        assertEq(priceAfter, priceBefore);
        (uint256 balance0, uint256 balance1) = _balances(poolId, address(router));
        assertEq(balance0, 0);
        assertEq(balance1, VAULT_FUNDS);
        (uint256 other0,) = _balances(routeId, address(other));
        assertEq(other0, VAULT_FUNDS);
    }

    // ---------------------------------------------------------------- ticket handshake

    /// @dev Each Kernel action keeps its own ticket around the foreign swap between them.
    function test_foreignSwap_betweenKernelActionsCompletesEachHandshake() public {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, true, -int256(ROUTE_SWAP_AMOUNT)));
        router.addRouteAction(CallbackType.AfterSwap, _foreignSwap(foreignKey, false, -int256(ROUTE_SWAP_AMOUNT)));
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, false, -int256(ROUTE_SWAP_AMOUNT)));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 3);
        assertEq(hook.ticketCount(), 0);
        assertEq(hook.currentContext().depth, 0);
    }

    /// @dev The outer route's Kernel swap triggers an inner router, whose route is one foreign swap. If the foreign
    /// swap called finishAction, it would pop the outer action's consumed ticket, and the outer finishAction would
    /// revert.
    function test_foreignSwap_insideNestedKernelActionKeepsTheParentTicket() public {
        _installRouter(false, true);
        MockExtension inner = new MockExtension(address(hook));
        _installAndActivate(routeKey, address(inner), _settings(SWAP_CALLBACKS, false, true, INNER_ROUTE_GAS_LIMIT));
        _fund(inner, routeId);
        inner.addRouteAction(CallbackType.AfterSwap, _foreignSwap(foreignKey, true, -int256(ROUTE_SWAP_AMOUNT)));
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, true, -int256(ROUTE_SWAP_AMOUNT)));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 1);
        assertEq(inner.lastRouteResults().length, 1);
        assertEq(inner.lastRouteResults()[0].amount0(), -int128(int256(ROUTE_SWAP_AMOUNT)));
        assertEq(inner.lastContext().depth, 2);
        assertEq(hook.ticketCount(), 0);
    }

    // ---------------------------------------------------------------- depth

    /// @dev A foreign swap opens no Kernel operation, so a root pool that allows no nested operation accepts it.
    function test_foreignSwap_runsAtRootDepthLimitOne() public {
        hook.setExecutionLimits(poolKey, 1, _defaultBudgets());
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _foreignSwap(foreignKey, true, -int256(ROUTE_SWAP_AMOUNT)));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults()[0].amount0(), -int128(int256(ROUTE_SWAP_AMOUNT)));
    }

    /// @dev The Kernel action after the foreign swap reaches the depth limit, and the whole route rolls back.
    function test_foreignSwap_rollsBackWhenALaterKernelActionReachesTheDepthLimit() public {
        hook.setExecutionLimits(poolKey, 1, _defaultBudgets());
        _installRouter(true, true);
        router.addRouteAction(CallbackType.AfterSwap, _foreignSwap(foreignKey, true, -int256(ROUTE_SWAP_AMOUNT)));
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, false, -int256(ROUTE_SWAP_AMOUNT)));
        (uint160 priceBefore,,,) = manager.getSlot0(foreignId);
        (uint256 before0, uint256 before1) = _balances(poolId, address(router));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 0);
        (uint160 priceAfter,,,) = manager.getSlot0(foreignId);
        assertEq(priceAfter, priceBefore);
        (uint256 after0, uint256 after1) = _balances(poolId, address(router));
        assertEq(after0, before0);
        assertEq(after1, before1);
    }

    // ---------------------------------------------------------------- rejections

    function test_foreignSwap_rejectsTheKernelHookKey() public {
        _expectRouteFailure(
            _foreignSwap(_withHooks(address(hook)), true, -1e9),
            abi.encodeWithSelector(IKernelHook.InvalidPool.selector)
        );
    }

    function test_foreignSwap_rejectsAnotherHook() public {
        _expectRouteFailure(
            _foreignSwap(_withHooks(address(0xBEEF)), true, -1e9),
            abi.encodeWithSelector(IKernelHook.InvalidPool.selector)
        );
    }

    /// @dev Only ForeignSwap may target a hookless pool; the Kernel operations keep their key rule.
    function test_kernelSwap_rejectsAHooklessKey() public {
        _expectRouteFailure(
            _kernelSwap(foreignKey, true, -1e9), abi.encodeWithSelector(IKernelHook.InvalidPool.selector)
        );
    }

    function test_kernelDonate_rejectsAHooklessKey() public {
        RouteAction memory donate =
            RouteAction({key: foreignKey, operation: Operation.Donate, parameters: abi.encode(1, 1), hookData: ""});
        _expectRouteFailure(donate, abi.encodeWithSelector(IKernelHook.InvalidPool.selector));
    }

    function test_kernelModifyLiquidity_rejectsAHooklessKey() public {
        RouteAction memory liquidity = RouteAction({
            key: foreignKey,
            operation: Operation.ModifyLiquidity,
            parameters: abi.encode(ModifyLiquidityParams(-120, 120, 1e12, bytes32(0))),
            hookData: ""
        });
        _expectRouteFailure(liquidity, abi.encodeWithSelector(IKernelHook.InvalidPool.selector));
    }

    /// @dev KernelHook does not check that a hookless pool exists; the PoolManager rejects an uninitialized one.
    function test_foreignSwap_uninitializedPoolRevertsAtThePoolManager() public {
        PoolKey memory missing = PoolKey(currency0, currency1, 10_000, 200, IHooks(address(0)));
        bytes memory notInitialized = abi.encodeWithSelector(Pool.PoolNotInitialized.selector);
        _expectRouteFailure(_foreignSwap(missing, true, -1e9), notInitialized);
    }

    function test_foreignSwap_requiresNestingOnTheInstallation() public {
        _installRouter(false, false);
        router.addRouteAction(CallbackType.AfterSwap, _foreignSwap(foreignKey, true, -1e9));
        vm.expectRevert(
            _routeFailure(CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.NestingDenied.selector))
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    /// @dev unwindPositions only removes liquidity; the exit context rejects every swap, foreign or not.
    function test_unwindPositions_rejectsForeignSwap() public {
        _installRouter(false, true);
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _foreignSwap(foreignKey, true, -1e9);
        vm.expectRevert(IKernelHook.NestingDenied.selector);
        router.unwindPositions(poolKey, actions);
    }

    // ---------------------------------------------------------------- helpers

    function _installRouter(bool optionalCallbacks, bool allowNesting) private {
        _installAndActivate(
            poolKey, address(router), _settings(SWAP_CALLBACKS, optionalCallbacks, allowNesting, ROUTE_GAS_LIMIT)
        );
        _fund(router, poolId);
    }

    /// @dev Another installation with vault funds, which no route in these tests may touch.
    function _fundedBystander() private returns (MockExtension other) {
        other = new MockExtension(address(hook));
        _installAndActivate(
            routeKey, address(other), _settings(uint16(1) << uint8(CallbackType.BeforeDonate), false, false)
        );
        _fund(other, routeId);
    }

    /// @dev A required router whose only route action is action; the swap reverts with the router's failure.
    function _expectRouteFailure(RouteAction memory action, bytes memory reason) private {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, action);
        vm.expectRevert(_routeFailure(CallbackType.AfterSwap, reason));
        _swapExactInput(poolKey, true, 1e14);
    }

    function _fund(MockExtension extension, PoolId fundedPoolId) private {
        IERC20(Currency.unwrap(currency0)).transfer(address(extension), VAULT_FUNDS);
        IERC20(Currency.unwrap(currency1)).transfer(address(extension), VAULT_FUNDS);
        extension.deposit(fundedPoolId, currency0, VAULT_FUNDS);
        extension.deposit(fundedPoolId, currency1, VAULT_FUNDS);
    }

    function _balances(PoolId vaultPoolId, address extension) private view returns (uint256, uint256) {
        return (vault.balanceOf(vaultPoolId, extension, currency0), vault.balanceOf(vaultPoolId, extension, currency1));
    }

    function _withHooks(address hooks) private view returns (PoolKey memory key) {
        key = foreignKey;
        key.hooks = IHooks(hooks);
    }

    function _foreignSwap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        private
        pure
        returns (RouteAction memory)
    {
        return RouteAction({
            key: key,
            operation: Operation.ForeignSwap,
            parameters: abi.encode(_swapParameters(zeroForOne, amountSpecified)),
            hookData: ""
        });
    }

    function _kernelSwap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        private
        pure
        returns (RouteAction memory)
    {
        return RouteAction({
            key: key,
            operation: Operation.Swap,
            parameters: abi.encode(_swapParameters(zeroForOne, amountSpecified)),
            hookData: ""
        });
    }

    function _swapParameters(bool zeroForOne, int256 amountSpecified) private pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
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
        return _hookRevert(
            hookCallback,
            abi.encodeWithSelector(IKernelHook.ExtensionFailed.selector, address(router), callback, reason)
        );
    }
}
