// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ArbitrageFixture as ExtensionFixture} from "./utils/ArbitrageFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {ArbitrageHook} from "../src/arbitrage/ArbitrageHook.sol";
import {ArbitrageNetwork} from "../src/arbitrage/ArbitrageNetwork.sol";
import {LimitOrder} from "../src/limitorder/LimitOrder.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {CallbackType, ExtensionSettings, CALLBACK_COUNT} from "core/src/types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @dev Run with --isolate --hardfork cancun. Each router call is a fresh transaction;
/// snapshot only that call, never setup/registration/order placement or later assertions.
contract ArbitrageGasTest is ExtensionFixture {
    PoolKey[] private _peers;

    function setUp() public override {
        if (!vm.isIsolateMode()) vm.skip(true);
        super.setUp();
    }

    function test_gas_kernelWithoutExtensions() public {
        _measureSwap("kernel_no_extensions", 1e16, 10_000_000);
    }

    function test_gas_kernelWithoutExtensionsTinySwap() public {
        _measureSwap("kernel_no_extensions_tiny_swap", 1, 10_000_000);
    }

    function test_gas_unhookedV4() public {
        PoolKey memory unhooked = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(unhooked, SQRT_PRICE_1_1);
        _wideLiquidity(unhooked);
        swapRouter.swap(
            unhooked, SwapParams(true, -int256(1e16), MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        _record("unhooked_v4", vm.lastFrameGas());
    }

    function test_gas_inactiveArbitrage() public {
        _network(1, 2, 1, false);
        hook.deactivateExtension(key, IHookExtension(address(arbitrage)));
        _measureSwap("arbitrage_inactive", 1e16, 10_000_000);
    }

    function test_gas_searchNoOpportunityOnePeer() public {
        _network(1, 2, 1, false);
        _measureSwap("no_opportunity_1_peer_1_size", 1, 10_000_000);
        assertEq(arbitrage.claimable(pool, address(this)), 0);
    }

    function test_gas_searchNoOpportunityFourPeersTwoSizes() public {
        _network(4, 5, 4, true);
        _measureSwap("no_opportunity_4_peers_2_sizes", 1, 10_000_000);
        assertEq(arbitrage.claimable(pool, address(this)), 0);
    }

    function test_gas_successOnePeerOneSize() public {
        _network(1, 2, 1, false);
        _measureSwap("success_1_peer_1_size", 1e16, 10_000_000);
        _assertProfit();
    }

    function test_gas_successTwoPeersOneSize() public {
        _network(2, 3, 2, false);
        _measureSwap("success_2_peers_1_size", 1e16, 10_000_000);
        _assertProfit();
    }

    function test_gas_successFourPeersOneSize() public {
        _network(4, 5, 4, false);
        _measureSwap("success_4_peers_1_size", 1e16, 10_000_000);
        _assertProfit();
    }

    function test_gas_successFourPeersTwoSizes() public {
        _network(4, 5, 4, true);
        _measureSwap("success_4_peers_2_sizes", 1e16, 10_000_000);
        _assertProfit();
    }

    function test_gas_thousandMembersOnePinnedPeer() public {
        _network(1, 1000, 1, false);
        _measureSwap("success_1000_members_1_pinned_peer", 1e16, 10_000_000);
        _assertProfit();
    }

    function test_gas_thousandMembersFourPeersTwoSizes() public {
        _network(4, 1000, 4, true);
        _measureSwap("success_1000_members_4_peers_2_sizes", 1e16, 10_000_000);
        _assertProfit();
    }

    function test_gas_originOrderFillOneMaker() public {
        _installOrders(key, _orderPolicy());
        uint64 index = orders.placeOrder(key, _request(true, 1e16, 4, 5));
        _network(1, 2, 1, false);
        _measureSwap("success_origin_order_1_maker", 1e16, 10_000_000);
        assertLt(orders.getOrder(pool, index).remaining, 1e16);
        _assertProfit();
        _assertLiabilities(pool);
    }

    function test_gas_originOrderFillsFourMakers() public {
        _installOrders(key, _orderPolicy());
        _fourMakerOrders(key);
        _network(1, 2, 1, false);
        _measureSwap("success_origin_orders_4_makers", 1e16, 10_000_000);
        for (uint64 i = 1; i <= 4; ++i) {
            assertEq(orders.getOrder(pool, i).remaining, 0);
        }
        _assertProfit();
        _assertLiabilities(pool);
    }

    /// @dev The peer's orders sell currency0 below the AMM price, a book-only opportunity that the AMM spot gate does
    /// not see; the same-pair book probe finds it.
    function test_gas_peerOrderFillsFourMakers() public {
        _network(1, 2, 1, false);
        _installOrders(_peers[0], _orderPolicy());
        _fourMakerOrders(_peers[0]);
        _measureSwap("success_peer_orders_4_makers", 1e16, 10_000_000);
        for (uint64 i = 1; i <= 4; ++i) {
            assertEq(orders.getOrder(_peers[0].toId(), i).remaining, 0);
        }
        _assertProfit();
        _assertLiabilities(_peers[0].toId());
    }

    function test_gas_failedLateRouteSettlement() public {
        _network(1, 2, 1, false);
        (uint160 beforePrice,,,) = StateLibrary.getSlot0(manager, _peers[0].toId());
        vm.mockCallRevert(
            address(manager),
            abi.encodeWithSelector(IPoolManager.mint.selector, address(hook.VAULT())),
            abi.encodeWithSignature("Error(string)", "benchmark settlement failure")
        );
        BalanceDelta delta = _measureSwap("failed_late_settlement", 1e16, 10_000_000);
        assertEq(delta.amount0(), -1e16);
        assertEq(arbitrage.claimable(pool, address(this)), 0);
        (uint160 afterPrice,,,) = StateLibrary.getSlot0(manager, _peers[0].toId());
        assertEq(afterPrice, beforePrice);
        vm.clearMockedCalls();
    }

    /// @dev A router's gas no longer decides whether the optional arbitrage callback runs (Kernel audit K-1): with
    /// too little for it, the swap reverts with GasBudgetExceeded instead of succeeding without it.
    function test_routerAllowanceOneMillionReverts() public {
        _network(1, 2, 1, false);
        _expectGasBudgetExceeded(1_000_000);
    }

    function test_routerAllowanceFourMillionReverts() public {
        _network(1, 2, 1, false);
        _expectGasBudgetExceeded(4_000_000);
    }

    function _expectGasBudgetExceeded(uint256 allowance) private {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap{gas: allowance}(
            key, SwapParams(true, -1e16, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function test_gas_routerAllowanceFiveMillion() public {
        _network(1, 2, 1, false);
        _measureSwap("allowance_5m_success", 1e16, 5_000_000);
        _assertProfit();
    }

    function test_gas_smallerCallbackAllowance() public {
        _network(1, 2, 1, false);
        _smallerCallback();
        _measureSwap("callback_1_6m_router_2_5m_success", 1e16, 2_500_000);
        _assertProfit();
    }

    function test_gas_smallerAllowanceStopsSearchEarly() public {
        _network(4, 5, 4, true);
        _smallerCallback();
        _measureSwap("callback_1_6m_bounded_search", 1e16, 2_500_000);
        _assertProfit();
    }

    function test_gas_profitClaimSeparateTransaction() public {
        _network(1, 2, 1, false);
        _swapExactInput(key, true, 1e16);
        uint256 earned = arbitrage.claimable(pool, address(this));
        arbitrage.claimProfit(pool, earned, address(this));
        _record("profit_claim", vm.lastFrameGas());
        assertEq(arbitrage.claimable(pool, address(this)), 0);
    }

    function test_gas_registrationAndRemoval() public {
        network.register(key);
        _record("register_first_pair_member", vm.lastFrameGas());
        PoolKey memory peer = _peer();
        network.register(peer);
        _record("register_existing_pair_member", vm.lastFrameGas());
        network.unregister(pool);
        _record("unregister_nonlast_member", vm.lastFrameGas());
    }

    /// @dev Replaces the old standalone quote: one cold call now runs the whole search and the exact quote.
    function test_gas_coldStandaloneSearch() public {
        _peers.push(_peer());
        // Create a gap before activating, so the search observes the same post-root prices.
        _swapExactInput(key, true, 1e16);
        network.register(_peers[0]);
        _installArbitrage(key);
        ArbitrageNetwork.Limits memory limits = ArbitrageNetwork.Limits(16, 8, 16, 4, 1, type(uint128).max >> 1);
        vm.prank(address(arbitrage));
        ArbitrageNetwork.Plan memory plan = network.findCycle(pool, true, limits);
        _record("cold_standalone_search", vm.lastFrameGas());
        assertGt(plan.proceeds, plan.input);
    }

    function test_gas_successTriangle() public {
        _loops(true, false);
        _measureSwap("success_triangle", 1e16, 10_000_000);
        _assertProfit();
    }

    function test_gas_successFourPoolLoop() public {
        _loops(false, true);
        _measureSwap("success_four_pool_loop", 1e16, 10_000_000);
        _assertProfit();
    }

    function test_gas_noOpportunityFullLists() public {
        _network(4, 5, 4, true);
        _loops(true, true);
        _measureSwap("no_opportunity_full_lists", 1, 10_000_000);
        assertEq(arbitrage.claimable(pool, address(this)), 0);
    }

    function test_gas_refreshAndSync() public {
        _loops(true, true);
        network.refresh(network.tokenIdOf(currency0), network.tokenIdOf(currency1));
        _record("refresh_pair_loops", vm.lastFrameGas());
        uint32[] memory pools = new uint32[](1);
        pools[0] = network.poolIndexOf(pool);
        network.syncDepth(pools);
        _record("sync_depth_one_pool", vm.lastFrameGas());
    }

    /// @dev liquidPeers same-pair peers with liquidity, members - 1 - liquidPeers empty filler pools, `candidates`
    /// same-pair peers searched, and two cycles sized with live liquidity when twoSizes is set (one otherwise).
    /// Closed-form sizing replaced the old fixed sizes; the scenario names stay for before/after comparison.
    function _network(uint8 liquidPeers, uint16 members, uint8 candidates, bool twoSizes) private {
        assertGe(members, uint256(liquidPeers) + 1);
        for (uint24 i; i < liquidPeers; ++i) {
            PoolKey memory peer = PoolKey(currency0, currency1, 500 + i * 100, 60, IHooks(address(hook)));
            _createPool(peer);
            _wideLiquidity(peer);
            network.register(peer);
            _peers.push(peer);
        }
        // Directory-scale fixtures add initialized zero-liquidity pools. This measures directory growth, not
        // 1000 simulated opportunities.
        for (uint24 i = liquidPeers; i < members - 1; ++i) {
            PoolKey memory peer = PoolKey(currency0, currency1, 10_000 + i, 60, IHooks(address(hook)));
            _createPool(peer);
            network.register(peer);
        }
        _installArbitrage(key);
        ArbitrageHook.Policy memory policy = _policy();
        policy.samePair = candidates;
        policy.sized = twoSizes ? 2 : 1;
        _reconfigure(policy, ARBITRAGE_CALLBACK_GAS);
    }

    /// @dev A triangle (currency1-middle-currency0) and/or a four-pool loop (currency1-first-second-currency0)
    /// around the root pair, with the root pair's saved loops refreshed.
    function _loops(bool triangle, bool fourPool) private {
        _ensureRegistered(key);
        if (triangle) {
            Currency middle = _newCurrency();
            network.register(_kernelPool(currency1, middle, 500, SQRT_PRICE_1_1, 1e18));
            network.register(_kernelPool(middle, currency0, 500, SQRT_PRICE_1_1, 1e18));
        }
        if (fourPool) {
            Currency first = _newCurrency();
            Currency second = _newCurrency();
            network.register(_kernelPool(currency1, first, 500, SQRT_PRICE_1_1, 1e18));
            network.register(_kernelPool(first, second, 500, SQRT_PRICE_1_1, 1e18));
            network.register(_kernelPool(second, currency0, 500, SQRT_PRICE_1_1, 1e18));
        }
        if (_peers.length == 0) _installArbitrage(key);
        _refreshRoot();
    }

    function _reconfigure(ArbitrageHook.Policy memory policy, uint32 callbackGas) private {
        hook.deactivateExtension(key, IHookExtension(address(arbitrage)));
        (, uint64 version,,) = arbitrage.profitState(pool);
        arbitrage.setPolicy(key, version, policy);
        ExtensionSettings memory settings =
            _settings(uint16(1) << uint8(CallbackType.AfterSwap), true, true, callbackGas);
        settings.lifecycleGasLimit = 500_000;
        settings.configuration = abi.encode(version + 1);
        hook.configureExtension(key, IHookExtension(address(arbitrage)), settings);
        hook.activateExtension(key, IHookExtension(address(arbitrage)));
    }

    function _fourMakerOrders(PoolKey memory target) private {
        LimitOrder.OrderRequest memory request = _request(true, 1e14, 4, 5);
        for (uint256 i; i < 4; ++i) {
            address maker = address(uint160(0x1000 + i));
            MockERC20(Currency.unwrap(currency0)).mint(maker, request.amount);
            vm.startPrank(maker);
            IERC20(Currency.unwrap(currency0)).approve(address(orders), request.amount);
            request.predecessor = orders.placeOrder(target, request);
            vm.stopPrank();
        }
    }

    function _smallerCallback() private {
        (ArbitrageHook.Policy memory policy,,,) = arbitrage.profitState(pool);
        // A small search budget (the minimum for 2 sized cycles is 530k) plus a 900k execution reserve and overhead
        // fits in a 1.6M callback.
        policy.searchGasLimit = 550_000;
        policy.executionGasReserve = 900_000;
        _reconfigure(policy, 1_600_000);
    }

    function _measureSwap(string memory name, uint256 input, uint256 allowance) private returns (BalanceDelta delta) {
        delta = swapRouter.swap{gas: allowance}(
            key, SwapParams(true, -int256(input), MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        // This must be the first call after the router: later getters would overwrite lastFrameGas.
        _record(name, vm.lastFrameGas());
    }

    function _record(string memory name, Vm.Gas memory measured) private {
        assertEq(measured.gasStateUsed, 0); // Cancun has no separate EIP-8037 state reservoir.
        assertGe(measured.gasRefunded, 0);
        uint256 refund = uint256(uint64(measured.gasRefunded));
        uint256 gross = measured.gasTotalUsed;
        assertLe(refund, gross / 5);
        vm.snapshotValue("ArbitrageGas", string.concat(name, "_gross"), gross);
        vm.snapshotValue("ArbitrageGas", string.concat(name, "_refund"), refund);
        vm.snapshotValue("ArbitrageGas", string.concat(name, "_net"), gross - refund);
        emit log_string(name);
        emit log_named_uint("receipt_gas_gross", gross);
        emit log_named_uint("receipt_gas_refund", refund);
        emit log_named_uint("receipt_gas_net", gross - refund);
    }

    function _assertProfit() private view {
        assertGt(arbitrage.claimable(pool, address(this)), 0);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency0), arbitrage.claimable(pool, address(this)));
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency1), 0);
    }
}
