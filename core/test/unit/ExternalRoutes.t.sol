// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {MockVenueAdapter} from "../mocks/MockVenueAdapter.sol";
import {ReentrantRouter} from "../mocks/ReentrantRouter.sol";
import {CodexVaultToken} from "../mocks/CodexVaultToken.sol";
import {SurchargeToken} from "../mocks/SurchargeToken.sol";
import {TestUniswapV2Factory, TestUniswapV2Pair} from "../mocks/TestUniswapV2.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";
import {KernelRouteExecutor} from "../../src/KernelRouteExecutor.sol";
import {UniswapV2Adapter, IUniswapV2FactoryMinimal} from "../../src/adapters/UniswapV2Adapter.sol";
import {IHookCatalog} from "../../src/interfaces/IHookCatalog.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {
    CALLBACK_COUNT,
    CallbackType,
    ExternalSwapParameters,
    Operation,
    RouteAction
} from "../../src/types/KernelHookTypes.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice ExternalSwap route actions: swaps on a venue outside the PoolManager through a Catalog-admitted adapter,
/// netted with the rest of the route through the PoolManager's flash accounting.
contract ExternalRoutesTest is KernelHookFixture {
    uint32 private constant ROUTE_GAS_LIMIT = 2_500_000;
    uint32 private constant INNER_ROUTE_GAS_LIMIT = 800_000;
    uint256 private constant VAULT_FUNDS = 1e16;
    uint256 private constant PAIR_RESERVE = 1e18;
    uint256 private constant ROUTE_SWAP_AMOUNT = 1e12;

    PoolKey private poolKey;
    PoolKey private routeKey;
    PoolKey private foreignKey;
    PoolKey private externalKey;
    PoolId private poolId;
    PoolId private routeId;
    MockExtension private router;
    KernelHookVault private vault;
    KernelRouteExecutor private executor;
    TestUniswapV2Factory private factory;
    TestUniswapV2Pair private pair;
    UniswapV2Adapter private adapter;

    function setUp() public override {
        super.setUp();
        poolKey = _poolKey();
        poolId = poolKey.toId();
        routeKey = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        routeId = routeKey.toId();
        foreignKey = _plainPoolKey();
        externalKey = PoolKey(currency0, currency1, 0, 0, IHooks(address(0)));
        _createPool(poolKey);
        _addLiquidity(poolKey);
        _createPool(routeKey);
        _addLiquidity(routeKey);
        manager.initialize(foreignKey, SQRT_PRICE_1_1);
        _addLiquidity(foreignKey);
        router = new MockExtension(address(hook));
        vault = hook.VAULT();
        executor = hook.ROUTE_EXECUTOR();
        factory = new TestUniswapV2Factory();
        pair = _newPair(currency0, currency1, PAIR_RESERVE, PAIR_RESERVE);
        adapter = new UniswapV2Adapter(address(executor), IUniswapV2FactoryMinimal(address(factory)), 30);
        catalog.admitAdapter(address(adapter), address(adapter).codehash);
    }

    // ---------------------------------------------------------------- amounts and settlement

    function testFuzz_externalSwap_exactInput(bool zeroForOne, uint256 amount) public {
        amount = bound(amount, 1e6, 1e15);
        _installRouter(false, true);
        uint256 expected = _v2AmountOut(amount, PAIR_RESERVE, PAIR_RESERVE);
        router.addRouteAction(CallbackType.AfterSwap, _externalSwap(zeroForOne, -int256(amount), expected));
        (uint256 before0, uint256 before1) = _balances(poolId, address(router));

        _swapExactInput(poolKey, true, 1e14);

        BalanceDelta result = router.lastRouteResults()[0];
        (int128 paid, int128 received) =
            zeroForOne ? (result.amount0(), result.amount1()) : (result.amount1(), result.amount0());
        assertEq(paid, -int128(int256(amount)));
        assertEq(received, int128(int256(expected)));
        _assertVaultMoved(before0, before1, result);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        assertEq(reserveIn, PAIR_RESERVE + amount);
        assertEq(reserveOut, PAIR_RESERVE - expected);
    }

    function testFuzz_externalSwap_exactOutput(bool zeroForOne, uint256 amount) public {
        amount = bound(amount, 1e6, 1e15);
        _installRouter(false, true);
        uint256 expectedInput = _v2AmountIn(amount, PAIR_RESERVE, PAIR_RESERVE);
        router.addRouteAction(CallbackType.AfterSwap, _externalSwap(zeroForOne, int256(amount), expectedInput));
        (uint256 before0, uint256 before1) = _balances(poolId, address(router));

        _swapExactInput(poolKey, true, 1e14);

        BalanceDelta result = router.lastRouteResults()[0];
        (int128 paid, int128 received) =
            zeroForOne ? (result.amount0(), result.amount1()) : (result.amount1(), result.amount0());
        assertEq(received, int128(int256(amount)));
        assertEq(paid, -int128(int256(expectedInput)));
        _assertVaultMoved(before0, before1, result);
    }

    function test_externalSwap_minimumOutputIsEnforced() public {
        uint256 output = _v2AmountOut(ROUTE_SWAP_AMOUNT, PAIR_RESERVE, PAIR_RESERVE);
        _expectRouteFailure(
            _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), output + 1),
            abi.encodeWithSelector(KernelRouteExecutor.ExternalSwapLimitExceeded.selector)
        );
    }

    function test_externalSwap_maximumInputIsEnforced() public {
        uint256 input = _v2AmountIn(ROUTE_SWAP_AMOUNT, PAIR_RESERVE, PAIR_RESERVE);
        _expectRouteFailure(
            _externalSwap(true, int256(ROUTE_SWAP_AMOUNT), input - 1),
            abi.encodeWithSelector(KernelRouteExecutor.ExternalSwapLimitExceeded.selector)
        );
    }

    /// @dev The v2 pair pays 1.1 currency0 per currency1. The route buys 2X currency1 on a Kernel pool and sells X on
    /// the v2 pair and X on the hookless pool. The vault holds nothing: the cycle's profit pays every leg.
    function test_externalSwap_unfundedCycleThroughThreeVenues() public {
        pair = _newPair(currency0, currency1, PAIR_RESERVE * 11 / 10, PAIR_RESERVE);
        _installRouter(false, true);
        router.withdraw(poolId, currency0, VAULT_FUNDS, address(this));
        router.withdraw(poolId, currency1, VAULT_FUNDS, address(this));
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, true, int256(2 * ROUTE_SWAP_AMOUNT)));
        router.addRouteAction(CallbackType.AfterSwap, _externalSwap(false, -int256(ROUTE_SWAP_AMOUNT), 0));
        router.addRouteAction(CallbackType.AfterSwap, _foreignSwap(false, -int256(ROUTE_SWAP_AMOUNT)));

        _swapExactInput(poolKey, true, 1e14);

        BalanceDelta[] memory results = router.lastRouteResults();
        int256 net0 = int256(results[0].amount0()) + results[1].amount0() + results[2].amount0();
        int256 net1 = int256(results[0].amount1()) + results[1].amount1() + results[2].amount1();
        assertGt(net0, 0);
        assertEq(net1, 0);
        (uint256 balance0, uint256 balance1) = _balances(poolId, address(router));
        assertEq(balance0, uint256(net0));
        assertEq(balance1, 0);
    }

    function test_externalSwap_optionalFailureRollsBackTheVenue() public {
        _installRouter(true, true);
        router.addRouteAction(CallbackType.AfterSwap, _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0));
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(foreignKey, true, -1e9));
        (uint256 before0, uint256 before1) = _balances(poolId, address(router));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 0);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        assertEq(reserve0, PAIR_RESERVE);
        assertEq(reserve1, PAIR_RESERVE);
        (uint256 after0, uint256 after1) = _balances(poolId, address(router));
        assertEq(after0, before0);
        assertEq(after1, before1);
    }

    /// @dev The Kernel swap leaves this executor +X currency1; the external swap sells exactly X, so that delta crosses
    /// back to zero and the nonzero-delta count drops during the external swap.
    function test_externalSwap_closesAnEarlierDeltaToZero() public {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, true, int256(ROUTE_SWAP_AMOUNT)));
        router.addRouteAction(CallbackType.AfterSwap, _externalSwap(false, -int256(ROUTE_SWAP_AMOUNT), 0));
        (, uint256 before1) = _balances(poolId, address(router));

        _swapExactInput(poolKey, true, 1e14);

        BalanceDelta[] memory results = router.lastRouteResults();
        assertEq(int256(results[0].amount1()) + results[1].amount1(), 0);
        (, uint256 after1) = _balances(poolId, address(router));
        assertEq(after1, before1);
    }

    /// @dev A sync left open by earlier code belongs to another settlement; the external swap's own sync would
    /// overwrite it.
    function test_externalSwap_rejectsAPendingSync() public {
        bytes memory openSync = abi.encodeCall(IPoolManager.sync, (currency0));
        router.setExternalCall(CallbackType.AfterSwap, address(manager), openSync);
        _expectRouteFailure(
            _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0),
            abi.encodeWithSelector(KernelRouteExecutor.InvalidExternalSwap.selector)
        );
    }

    // ---------------------------------------------------------------- ticket handshake and depth

    function test_externalSwap_betweenKernelActionsCompletesEachHandshake() public {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, true, -int256(ROUTE_SWAP_AMOUNT)));
        router.addRouteAction(CallbackType.AfterSwap, _externalSwap(false, -int256(ROUTE_SWAP_AMOUNT), 0));
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, false, -int256(ROUTE_SWAP_AMOUNT)));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults().length, 3);
        assertEq(hook.ticketCount(), 0);
        assertEq(hook.currentContext().depth, 0);
    }

    function test_externalSwap_insideNestedKernelActionKeepsTheParentTicket() public {
        _installRouter(false, true);
        MockExtension inner = new MockExtension(address(hook));
        _installAndActivate(routeKey, address(inner), _settings(SWAP_CALLBACKS, false, true, INNER_ROUTE_GAS_LIMIT));
        _fund(inner, routeId);
        inner.addRouteAction(CallbackType.AfterSwap, _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0));
        // The earlier foreign swap leaves this executor with nonzero parent deltas while the inner route runs.
        router.addRouteAction(CallbackType.AfterSwap, _foreignSwap(true, -int256(ROUTE_SWAP_AMOUNT)));
        router.addRouteAction(CallbackType.AfterSwap, _kernelSwap(routeKey, true, -int256(ROUTE_SWAP_AMOUNT)));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(inner.lastRouteResults()[0].amount0(), -int128(int256(ROUTE_SWAP_AMOUNT)));
        assertEq(router.lastRouteResults().length, 2);
        assertEq(hook.ticketCount(), 0);
    }

    function test_externalSwap_runsAtRootDepthLimitOne() public {
        hook.setExecutionLimits(poolKey, 1, _defaultBudgets());
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults()[0].amount0(), -int128(int256(ROUTE_SWAP_AMOUNT)));
    }

    function test_externalSwap_requiresNestingOnTheInstallation() public {
        _installRouter(false, false);
        router.addRouteAction(CallbackType.AfterSwap, _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0));
        vm.expectRevert(
            _routeFailure(CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.NestingDenied.selector))
        );
        _swapExactInput(poolKey, true, 1e14);
    }

    function test_unwindPositions_rejectsExternalSwap() public {
        _installRouter(false, true);
        hook.deactivateExtension(poolKey, IHookExtension(address(router)));
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0);
        vm.expectRevert(IKernelHook.NestingDenied.selector);
        router.unwindPositions(poolKey, actions);
    }

    // ---------------------------------------------------------------- invalid actions

    function test_externalSwap_rejectsInvalidKeys() public {
        PoolKey[6] memory keys;
        keys[0] = PoolKey(Currency.wrap(address(0)), currency1, 0, 0, IHooks(address(0)));
        keys[1] = PoolKey(currency1, currency0, 0, 0, IHooks(address(0)));
        keys[2] = PoolKey(currency0, currency0, 0, 0, IHooks(address(0)));
        keys[3] = PoolKey(currency0, currency1, 3000, 0, IHooks(address(0)));
        keys[4] = PoolKey(currency0, currency1, 0, 60, IHooks(address(0)));
        keys[5] = PoolKey(currency0, currency1, 0, 0, IHooks(address(hook)));
        uint256 state = vm.snapshotState();
        // keys.length == 6
        for (uint256 i; i < keys.length; ++i) {
            RouteAction memory action = _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0);
            action.key = keys[i];
            _expectRouteFailure(action, abi.encodeWithSelector(KernelRouteExecutor.InvalidExternalSwap.selector));
            vm.revertToState(state);
        }
    }

    function test_externalSwap_rejectsInvalidAmounts() public {
        int256 maximum = int256(type(int128).max);
        int256[3] memory amounts = [int256(0), -maximum - 1, maximum + 1];
        uint256 state = vm.snapshotState();
        // amounts.length == 3
        for (uint256 i; i < amounts.length; ++i) {
            _expectRouteFailure(
                _externalSwap(true, amounts[i], type(uint256).max),
                abi.encodeWithSelector(KernelRouteExecutor.InvalidExternalSwap.selector)
            );
            vm.revertToState(state);
        }
    }

    function test_externalSwap_rejectsAnUnadmittedAdapter() public {
        UniswapV2Adapter unadmitted =
            new UniswapV2Adapter(address(executor), IUniswapV2FactoryMinimal(address(factory)), 30);
        RouteAction memory action = _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0);
        action.parameters =
            abi.encode(ExternalSwapParameters(address(unadmitted), address(pair), true, -int256(ROUTE_SWAP_AMOUNT), 0));
        _expectRouteFailure(action, abi.encodeWithSelector(KernelRouteExecutor.InvalidExternalSwap.selector));
    }

    /// @dev Unlike extension admission, a stop applies at once to the next route.
    function test_externalSwap_rejectsARevokedAdapter() public {
        catalog.setAdapterAdmission(address(adapter), false);
        _expectRouteFailure(
            _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0),
            abi.encodeWithSelector(KernelRouteExecutor.InvalidExternalSwap.selector)
        );
    }

    function test_externalSwap_rejectsChangedAdapterCode() public {
        vm.etch(address(adapter), address(new MockVenueAdapter(manager, address(executor))).code);
        _expectRouteFailure(
            _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0),
            abi.encodeWithSelector(KernelRouteExecutor.InvalidExternalSwap.selector)
        );
    }

    /// @dev A pair with the right tokens that the adapter's factory did not create is not trusted.
    function test_v2Adapter_rejectsAPairOutsideItsFactory() public {
        TestUniswapV2Pair outsider = new TestUniswapV2Pair(Currency.unwrap(currency0), Currency.unwrap(currency1));
        RouteAction memory action = _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0);
        action.parameters = abi.encode(
            ExternalSwapParameters(address(adapter), address(outsider), true, -int256(ROUTE_SWAP_AMOUNT), 0)
        );
        _expectRouteFailure(action, abi.encodeWithSelector(KernelRouteExecutor.ExternalSwapFailed.selector));
    }

    function test_v2Adapter_onlyTheExecutorCanSwap() public {
        vm.expectRevert(UniswapV2Adapter.NotExecutor.selector);
        adapter.swap(address(pair), currency0, currency1, 1e9, -1e9, address(this), "");
    }

    /// @dev The PoolManager records the nominal input as debt; a taxed token delivers less to the adapter.
    function test_externalSwap_rejectsATaxedInputToken() public {
        CodexVaultToken taxed = new CodexVaultToken();
        taxed.mint(address(this), 1e24);
        taxed.approve(address(modifyLiquidityRouter), type(uint256).max);
        (Currency low, Currency high) = Currency.unwrap(currency1) < address(taxed)
            ? (currency1, Currency.wrap(address(taxed)))
            : (Currency.wrap(address(taxed)), currency1);
        PoolKey memory taxedPool = PoolKey(low, high, FEE, TICK_SPACING, IHooks(address(0)));
        manager.initialize(taxedPool, SQRT_PRICE_1_1);
        _addLiquidity(taxedPool);
        taxed.setFeeBasisPoints(100);
        RouteAction memory action = _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0);
        action.key = PoolKey(low, high, 0, 0, IHooks(address(0)));
        action.parameters = abi.encode(
            ExternalSwapParameters(
                address(adapter), address(pair), Currency.unwrap(low) == address(taxed), -int256(ROUTE_SWAP_AMOUNT), 0
            )
        );
        _expectRouteFailure(action, abi.encodeWithSelector(KernelRouteExecutor.ExternalBalanceMismatch.selector));
    }

    /// @dev A token that charges the sender takes more from the PoolManager's custody than the debt it records.
    function test_externalSwap_rejectsASenderSurchargeOnTheInput() public {
        SurchargeToken surcharged = new SurchargeToken();
        PoolKey memory key = _surchargePool(surcharged);
        surcharged.setSurchargeBasisPoints(100);
        RouteAction memory action = _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0);
        action.key = PoolKey(key.currency0, key.currency1, 0, 0, IHooks(address(0)));
        bool zeroForOne = Currency.unwrap(key.currency0) == address(surcharged);
        action.parameters = abi.encode(
            ExternalSwapParameters(address(adapter), address(pair), zeroForOne, -int256(ROUTE_SWAP_AMOUNT), 0)
        );
        _expectRouteFailure(action, abi.encodeWithSelector(KernelRouteExecutor.ExternalBalanceMismatch.selector));
    }

    /// @dev The adapter forwards exactly its input to the pair, and a sender surcharge would spend more than that.
    function test_v2Adapter_rejectsASenderSurchargeOnTheForward() public {
        SurchargeToken surcharged = new SurchargeToken();
        surcharged.mint(address(this), 1e24);
        Currency surchargedCurrency = Currency.wrap(address(surcharged));
        address surchargedPair = address(_newPair(surchargedCurrency, currency1, PAIR_RESERVE, PAIR_RESERVE));
        surcharged.transfer(address(adapter), 2 * ROUTE_SWAP_AMOUNT);
        surcharged.setSurchargeBasisPoints(100);
        vm.prank(address(executor));
        vm.expectRevert(UniswapV2Adapter.TransferMismatch.selector);
        adapter.swap(
            surchargedPair,
            surchargedCurrency,
            currency1,
            ROUTE_SWAP_AMOUNT,
            -int256(ROUTE_SWAP_AMOUNT),
            address(this),
            ""
        );
    }

    // ---------------------------------------------------------------- adversarial adapters

    function test_externalSwap_honestMockAdapterSucceeds() public {
        MockVenueAdapter mock = _admittedMockAdapter(MockVenueAdapter.Mode.Honest);
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, _mockSwap(mock));

        _swapExactInput(poolKey, true, 1e14);

        assertEq(router.lastRouteResults()[0].amount1(), int128(int256(ROUTE_SWAP_AMOUNT)));
    }

    function test_externalSwap_rejectsAnAdapterThatKeepsTheInput() public {
        _expectMockFailure(
            MockVenueAdapter.Mode.KeepInputPayNothing,
            abi.encodeWithSelector(KernelRouteExecutor.ExternalBalanceMismatch.selector)
        );
    }

    function test_externalSwap_rejectsAnAdapterThatUnderpays() public {
        _expectMockFailure(
            MockVenueAdapter.Mode.PayHalf, abi.encodeWithSelector(KernelRouteExecutor.ExternalBalanceMismatch.selector)
        );
    }

    function test_externalSwap_rejectsAnAdapterThatPaysTheWrongCurrency() public {
        _expectMockFailure(
            MockVenueAdapter.Mode.PayInputCurrency,
            abi.encodeWithSelector(KernelRouteExecutor.ExternalBalanceMismatch.selector)
        );
    }

    /// @dev The adapter pays correctly but leaves its own PoolManager debt, which would revert the whole unlock.
    function test_externalSwap_rejectsAnAdapterThatLeavesItsOwnDebt() public {
        _expectMockFailure(
            MockVenueAdapter.Mode.LeaveOwnDebt, abi.encodeWithSelector(KernelRouteExecutor.UnsettledRoute.selector)
        );
    }

    /// @dev The adapter settles the output for the executor itself, which clears the executor's sync.
    function test_externalSwap_rejectsAnAdapterThatChangesTheSync() public {
        _expectMockFailure(
            MockVenueAdapter.Mode.SettleForExecutor,
            abi.encodeWithSelector(KernelRouteExecutor.ExternalBalanceMismatch.selector)
        );
    }

    /// @dev An adapter that already holds PoolManager debt credits the executor itself, takes the output back as more
    /// debt and restores the sync. The deltas and the nonzero count look right; only settle() shows that the
    /// executor's own settlement credited nothing.
    function test_externalSwap_requiresTheSettlementToCreditTheOutput() public {
        MockVenueAdapter mock = _admittedMockAdapter(MockVenueAdapter.Mode.SettleTakeBackAndResync);
        router.setExternalCall(
            CallbackType.AfterSwap, address(mock), abi.encodeCall(MockVenueAdapter.takeOwnDebt, (currency1, 1))
        );
        _expectRouteFailure(
            _mockSwap(mock), abi.encodeWithSelector(KernelRouteExecutor.ExternalBalanceMismatch.selector)
        );
    }

    function test_externalSwap_rejectsAnAdapterThatReverts() public {
        _expectMockFailure(
            MockVenueAdapter.Mode.Revert, abi.encodeWithSelector(KernelRouteExecutor.ExternalSwapFailed.selector)
        );
    }

    function test_externalSwap_rejectsAnAdapterThatReturnsTooMuchData() public {
        _expectMockFailure(
            MockVenueAdapter.Mode.ReturnTooMuchData,
            abi.encodeWithSelector(KernelRouteExecutor.ExternalSwapFailed.selector)
        );
    }

    /// @dev The adapter makes the running extension start a second route. The executor refuses it while the external
    /// swap runs; the adapter records the reason and then pays, so the outer route completes.
    function test_externalSwap_blocksARouteStartedFromInsideTheAdapter() public {
        ReentrantRouter reentrant = new ReentrantRouter(address(hook));
        _installAndActivate(poolKey, address(reentrant), _settings(SWAP_CALLBACKS, false, true, ROUTE_GAS_LIMIT));
        _fund(reentrant, poolId);
        MockVenueAdapter mock = _admittedMockAdapter(MockVenueAdapter.Mode.Reenter);
        mock.setReentry(address(reentrant), abi.encodeCall(ReentrantRouter.reenter, ()));
        reentrant.addReentryAction(_foreignSwap(true, -1e9));
        reentrant.addRouteAction(CallbackType.AfterSwap, _mockSwap(mock));

        _swapExactInput(poolKey, true, 1e14);

        assertFalse(mock.reentrySucceeded());
        assertEq(mock.reentryReason(), abi.encodeWithSelector(KernelRouteExecutor.ExternalSwapInProgress.selector));
        assertEq(reentrant.lastRouteResults().length, 1);
    }

    // ---------------------------------------------------------------- catalog

    function test_catalog_admitsAnAdapterByCodeHash() public {
        MockVenueAdapter mock = new MockVenueAdapter(manager, address(executor));
        vm.expectRevert(IHookCatalog.InvalidAdapter.selector);
        catalog.admitAdapter(address(mock), bytes32(uint256(1)));
        vm.expectRevert(IHookCatalog.InvalidAdapter.selector);
        catalog.admitAdapter(address(0xBEEF), bytes32(0));
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        catalog.admitAdapter(address(mock), address(mock).codehash);

        catalog.admitAdapter(address(mock), address(mock).codehash);

        IHookCatalog.AdapterEntry memory entry = catalog.getAdapterEntry(address(mock));
        assertEq(entry.codeHash, address(mock).codehash);
        assertTrue(entry.admitted);
        vm.expectRevert(IHookCatalog.AlreadyCatalogued.selector);
        catalog.admitAdapter(address(mock), address(mock).codehash);
    }

    function test_catalog_setAdapterAdmissionNeedsAnEntry() public {
        vm.expectRevert(IHookCatalog.UnknownAdapter.selector);
        catalog.setAdapterAdmission(address(0xBEEF), true);
        catalog.setAdapterAdmission(address(adapter), false);
        assertFalse(catalog.getAdapterEntry(address(adapter)).admitted);
    }

    // ---------------------------------------------------------------- helpers

    function _newPair(Currency a, Currency b, uint256 amountA, uint256 amountB)
        private
        returns (TestUniswapV2Pair created)
    {
        created = TestUniswapV2Pair(factory.createPair(Currency.unwrap(a), Currency.unwrap(b)));
        IERC20(Currency.unwrap(a)).transfer(address(created), amountA);
        IERC20(Currency.unwrap(b)).transfer(address(created), amountB);
        created.sync();
    }

    /// @dev A hookless pool of token and currency1 with liquidity, so the PoolManager holds the token.
    function _surchargePool(SurchargeToken token) private returns (PoolKey memory key) {
        token.mint(address(this), 1e24);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        (Currency low, Currency high) = Currency.unwrap(currency1) < address(token)
            ? (currency1, Currency.wrap(address(token)))
            : (Currency.wrap(address(token)), currency1);
        key = PoolKey(low, high, FEE, TICK_SPACING, IHooks(address(0)));
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key);
    }

    function _installRouter(bool optionalCallbacks, bool allowNesting) private {
        _installAndActivate(
            poolKey, address(router), _settings(SWAP_CALLBACKS, optionalCallbacks, allowNesting, ROUTE_GAS_LIMIT)
        );
        _fund(router, poolId);
    }

    function _expectRouteFailure(RouteAction memory action, bytes memory reason) private {
        _installRouter(false, true);
        router.addRouteAction(CallbackType.AfterSwap, action);
        vm.expectRevert(_routeFailure(CallbackType.AfterSwap, reason));
        _swapExactInput(poolKey, true, 1e14);
    }

    function _expectMockFailure(MockVenueAdapter.Mode mode, bytes memory reason) private {
        _expectRouteFailure(_mockSwap(_admittedMockAdapter(mode)), reason);
    }

    /// @dev The mock pays currency1 from its own inventory.
    function _admittedMockAdapter(MockVenueAdapter.Mode mode) private returns (MockVenueAdapter mock) {
        mock = new MockVenueAdapter(manager, address(executor));
        mock.setMode(mode);
        catalog.admitAdapter(address(mock), address(mock).codehash);
        IERC20(Currency.unwrap(currency0)).transfer(address(mock), 1e18);
        IERC20(Currency.unwrap(currency1)).transfer(address(mock), 1e18);
    }

    function _mockSwap(MockVenueAdapter mock) private view returns (RouteAction memory action) {
        action = _externalSwap(true, -int256(ROUTE_SWAP_AMOUNT), 0);
        action.parameters =
            abi.encode(ExternalSwapParameters(address(mock), address(0), true, -int256(ROUTE_SWAP_AMOUNT), 0));
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

    function _assertVaultMoved(uint256 before0, uint256 before1, BalanceDelta result) private view {
        (uint256 after0, uint256 after1) = _balances(poolId, address(router));
        assertEq(int256(after0) - int256(before0), result.amount0());
        assertEq(int256(after1) - int256(before1), result.amount1());
    }

    function _externalSwap(bool zeroForOne, int256 amountSpecified, uint256 limit)
        private
        view
        returns (RouteAction memory)
    {
        return RouteAction({
            key: externalKey,
            operation: Operation.ExternalSwap,
            parameters: abi.encode(
                ExternalSwapParameters(address(adapter), address(pair), zeroForOne, amountSpecified, limit)
            ),
            hookData: ""
        });
    }

    function _foreignSwap(bool zeroForOne, int256 amountSpecified) private view returns (RouteAction memory) {
        return RouteAction({
            key: foreignKey,
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

    /// @dev Uniswap v2 getAmountOut and getAmountIn with the 0.3% fee.
    function _v2AmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) private pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
    }

    function _v2AmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) private pure returns (uint256) {
        return reserveIn * amountOut * 1000 / ((reserveOut - amountOut) * 997) + 1;
    }

    function _defaultBudgets() private pure returns (uint32[CALLBACK_COUNT] memory budgets) {
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = 4_000_000;
        }
    }

    function _routeFailure(CallbackType callback, bytes memory reason) private view returns (bytes memory) {
        bytes4 hookCallback =
            callback == CallbackType.BeforeSwap ? IHooks.beforeSwap.selector : IHooks.afterSwap.selector;
        return _hookRevert(
            hookCallback,
            abi.encodeWithSelector(IKernelHook.ExtensionFailed.selector, address(router), callback, reason)
        );
    }
}
