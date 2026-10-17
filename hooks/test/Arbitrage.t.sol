// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ArbitrageFixture} from "./utils/ArbitrageFixture.sol";
import {ArbitrageHook} from "../src/arbitrage/ArbitrageHook.sol";
import {LimitOrder} from "../src/limitorder/LimitOrder.sol";
import {KernelExtension} from "../src/base/KernelExtension.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {CallbackType, ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract ArbitrageTest is ArbitrageFixture {
    function test_reverseCurrencyCycleClaimsOnlyItsProfitCurrency() public {
        network.register(_peer());
        _installArbitrage(key);
        hook.deactivateExtension(key, IHookExtension(address(arbitrage)));
        (ArbitrageHook.Policy memory policy, uint64 version,,) = arbitrage.profitState(pool);
        policy.profitCurrency0 = false;
        arbitrage.setPolicy(key, version, policy);
        hook.configureExtension(key, IHookExtension(address(arbitrage)), _arbitrageSettings(2));
        hook.activateExtension(key, IHookExtension(address(arbitrage)));
        _swapExactInput(key, false, 1e16);
        uint256 earned = arbitrage.claimable(pool, address(this));
        assertGt(earned, 0);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency0), 0);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency1), earned);
        uint256 beforeBalance = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        arbitrage.claimProfit(pool, earned, address(this));
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(this)), beforeBalance + earned);
        assertEq(arbitrage.claimable(pool, address(this)), 0);
    }

    function test_activationRejectsCallbackLargerThanPoolBudget() public {
        network.register(_peer());
        _installArbitrage(key);
        ExtensionSettings memory settings = _settings(uint16(1) << uint8(CallbackType.AfterSwap), true, true, 4_000_000);
        settings.configuration = abi.encode(uint64(1));
        vm.prank(address(hook));
        assertFalse(arbitrage.canActivate(key, settings));
    }

    function test_reinstallClearsPolicyAndPreservesVersion() public {
        network.register(_peer());
        _installArbitrage(key);
        hook.deactivateExtension(key, IHookExtension(address(arbitrage)));
        hook.removeExtension(key, IHookExtension(address(arbitrage)));
        hook.installExtension(key, IHookExtension(address(arbitrage)), _arbitrageSettings(0));
        vm.prank(address(hook));
        assertFalse(arbitrage.canActivate(key, _arbitrageSettings(0)));
        (ArbitrageHook.Policy memory cleared, uint64 version,,) = arbitrage.profitState(pool);
        assertEq(cleared.searchGasLimit, 0);
        assertEq(version, 1);
        arbitrage.setPolicy(key, version, _policy());
        hook.configureExtension(key, IHookExtension(address(arbitrage)), _arbitrageSettings(2));
        hook.activateExtension(key, IHookExtension(address(arbitrage)));
    }

    function test_AMMOnlyCycleFindsAndClaimsSurplusWithoutReserve() public {
        network.register(_peer());
        _installArbitrage(key);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency0), 0);
        _swapExactInput(key, true, 1e16);
        uint256 profit = arbitrage.claimable(pool, address(this));
        assertGt(profit, 0);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency0), profit);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency1), 0);
        arbitrage.claimProfit(pool, profit, address(this));
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency0), 0);
    }

    function test_cycleFillsOriginOrdersOnReturnLeg() public {
        _installOrders(key, _orderPolicy());
        uint64 index = orders.placeOrder(key, _request(true, 1e16, 4, 5));
        network.register(_peer());
        _installArbitrage(key);
        _swapExactInput(key, true, 1e16);
        assertGt(arbitrage.claimable(pool, address(this)), 0);
        assertLt(orders.getOrder(pool, index).remaining, 1e16);
        _assertLiabilities(pool);
    }

    function test_membershipRequiresPoolRoleAndReusesStableIdentity() public {
        uint32 id = network.register(key);
        vm.prank(address(0xBAD));
        vm.expectRevert(KernelExtension.Unauthorized.selector);
        network.unregister(pool);
        network.unregister(pool);
        assertEq(network.register(key), id);
        assertEq(PoolId.unwrap(network.poolRecord(id).id), PoolId.unwrap(pool));
    }

    function test_unprofitablePoolsDoNotAccumulateClaims() public {
        network.register(_peer());
        _installArbitrage(key);
        _swapExactInput(key, true, 1);
        assertEq(arbitrage.claimable(pool, address(this)), 0);
    }

    function test_failedRouteRollsBackCycleAndPreservesRootSwap() public {
        PoolKey memory peer = _peer();
        network.register(peer);
        _installArbitrage(key);
        (uint160 beforePrice,,,) = StateLibrary.getSlot0(manager, peer.toId());
        // The route's profit lands in the vault last, as claims; making that mint fail rolls the whole cycle back.
        vm.mockCallRevert(
            address(manager),
            abi.encodeWithSelector(IPoolManager.mint.selector, address(hook.VAULT())),
            abi.encodeWithSignature("Error(string)", "settlement failure")
        );
        BalanceDelta root = _swapExactInput(key, true, 1e16);
        vm.clearMockedCalls();
        assertEq(root.amount0(), -1e16);
        assertEq(arbitrage.claimable(pool, address(this)), 0);
        (uint160 afterPrice,,,) = StateLibrary.getSlot0(manager, peer.toId());
        assertEq(afterPrice, beforePrice);
    }

    function test_overoptimisticPreviewCannotInflateClaims() public {
        _installOrders(_peerWithOrders(), _orderPolicy());
        _installArbitrage(key);
        // Every preview claims a huge book fill. The plan looks better than it is; claims follow the real balance.
        LimitOrder.FillPreview memory preview;
        preview.input = 1;
        preview.output = 1e17;
        preview.available = true;
        vm.mockCall(address(orders), abi.encodeWithSelector(LimitOrder.previewFill.selector), abi.encode(preview));
        _swapExactInput(key, true, 1e16);
        vm.clearMockedCalls();
        uint256 earned = arbitrage.claimable(pool, address(this));
        assertGt(earned, 0);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency0), earned);
        assertLt(earned, 1e17);
    }

    function test_failedRoutePreservesEarlierClaims() public {
        network.register(_peer());
        _installArbitrage(key);
        _swapExactInput(key, true, 1e16);
        uint256 earned = arbitrage.claimable(pool, address(this));
        assertGt(earned, 0);
        vm.mockCallRevert(
            address(manager),
            abi.encodeWithSelector(IPoolManager.mint.selector, address(hook.VAULT())),
            abi.encodeWithSignature("Error(string)", "settlement failure")
        );
        _swapExactInput(key, true, 1e16);
        vm.clearMockedCalls();
        assertEq(arbitrage.claimable(pool, address(this)), earned);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency0), earned);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency1), 0);
    }

    function test_nativeCurrencyCycleCapturesSurplus() public {
        vm.deal(address(this), 100 ether);
        Currency native = Currency.wrap(address(0));
        PoolKey memory root = PoolKey(native, currency1, 3000, 60, IHooks(address(hook)));
        PoolKey memory peer = PoolKey(native, currency1, 500, 60, IHooks(address(hook)));
        _nativePool(root);
        _nativePool(peer);
        network.register(peer);
        _installArbitrage(root);
        swapRouter.swap{value: 1e16}(
            root, SwapParams(true, -1e16, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        PoolId rootId = root.toId();
        uint256 earned = arbitrage.claimable(rootId, address(this));
        assertGt(earned, 0);
        assertEq(hook.VAULT().balanceOf(rootId, address(arbitrage), native), earned);
        assertEq(hook.VAULT().balanceOf(rootId, address(arbitrage), currency1), 0);
        uint256 before = address(this).balance;
        arbitrage.claimProfit(rootId, earned, address(this));
        assertEq(address(this).balance, before + earned);
    }

    function _nativePool(PoolKey memory target) private {
        hook.preparePool(target);
        manager.initialize(target, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(target, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
    }

    /// @dev The taker's payment is credited as claims, so an order larger than the PoolManager's float still fills.
    function test_smallPoolManagerFloatFillsOversizedOrder() public {
        _installOrders(key, _orderPolicy());
        uint64 index = orders.placeOrder(key, _request(false, 2e18, 1, 1));
        uint256 float = IERC20(Currency.unwrap(currency0)).balanceOf(address(manager));
        _swapExactInput(key, true, 5e17);
        uint256 filled = 2e18 - orders.getOrder(pool, index).remaining;
        // The order's proceeds exceed what the PoolManager held before the taker paid.
        assertGt(hook.VAULT().balanceOf(pool, address(orders), currency0), float, "fill beyond float");
        assertGt(filled, 0);
        _assertLiabilities(pool);
    }

    /// @dev Book-only opportunity: a resting range order priced better than the AMM, with no AMM price gap. The AMM
    /// gate cannot see it; the same-pair book probe finds it through previewFill.
    function test_arbitrageConsumesRangeThroughExistingPreview() public {
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, 100e18, 0), "");
        _installOrders(key, _orderPolicy());
        LimitOrder.OrderRequest memory request = _request(true, 1e16, 800_000, 1_000_000);
        request.endPriceNumerator = 1_000_000;
        uint64 index = orders.placeOrder(key, request);
        network.register(_peer());
        _installArbitrage(key);
        _swapExactInput(key, true, 1e16);
        assertGt(arbitrage.claimable(pool, address(this)), 0);
        assertLt(orders.getOrder(pool, index).remaining, 1e16);
        _assertLiabilities(pool);
    }

    /// @dev The deepest peer keeps its synced depth but has no live liquidity, so it cannot deliver the first leg. The
    /// origin's book is then tried with the next peer.
    function test_originBookTriedWithNextPeerWhenDeepestCannotDeliver() public {
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, 100e18, 0), "");
        _installOrders(key, _orderPolicy());
        LimitOrder.OrderRequest memory request = _request(true, 1e16, 800_000, 1_000_000);
        request.endPriceNumerator = 1_000_000;
        uint64 index = orders.placeOrder(key, request);
        PoolKey memory drained = _kernelPool(currency0, currency1, 700, SQRT_PRICE_1_1, 10e18);
        network.register(drained);
        network.register(_peer());
        modifyLiquidityRouter.modifyLiquidity(drained, ModifyLiquidityParams(-6000, 6000, -10e18, 0), "");
        _installArbitrage(key);
        _swapExactInput(key, true, 1e16);
        assertGt(arbitrage.claimable(pool, address(this)), 0);
        assertLt(orders.getOrder(pool, index).remaining, 1e16);
        _assertLiabilities(pool);
    }

    function test_triangleCycleCapturesSurplus() public {
        Currency currency2 = _newCurrency();
        network.register(_kernelPool(currency1, currency2, 500, SQRT_PRICE_1_1, 1e18));
        network.register(_kernelPool(currency2, currency0, 500, SQRT_PRICE_1_1, 1e18));
        _installArbitrage(key);
        _refreshRoot();
        _swapExactInput(key, true, 1e16);
        _assertCapturedWithoutInventory(currency2);
    }

    function test_fourPoolCycleCapturesSurplus() public {
        Currency currency2 = _newCurrency();
        Currency currency3 = _newCurrency();
        network.register(_kernelPool(currency1, currency2, 500, SQRT_PRICE_1_1, 1e18));
        network.register(_kernelPool(currency2, currency3, 500, SQRT_PRICE_1_1, 1e18));
        network.register(_kernelPool(currency3, currency0, 500, SQRT_PRICE_1_1, 1e18));
        _installArbitrage(key);
        _refreshRoot();
        _swapExactInput(key, false, 1e16);
        _assertCapturedWithoutInventory(currency2);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency3), 0);
    }

    /// @dev A peer pool of the root pair with the LimitOrder book active, registered in the network.
    function _peerWithOrders() private returns (PoolKey memory peer) {
        peer = _peer();
        network.register(peer);
    }

    function _assertCapturedWithoutInventory(Currency middle) private view {
        uint256 earned = arbitrage.claimable(pool, address(this));
        assertGt(earned, 0);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency0), earned);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), currency1), 0);
        assertEq(hook.VAULT().balanceOf(pool, address(arbitrage), middle), 0);
    }
}
