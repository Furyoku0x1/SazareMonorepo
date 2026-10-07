// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ExtensionFixture} from "./utils/ExtensionFixture.sol";
import {LimitOrder} from "../src/LimitOrder.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";

contract RangeLimitOrderTest is ExtensionFixture {
    function setUp() public override {
        super.setUp();
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, 100e18, 0), "");
        _installOrders(key, _orderPolicy());
    }

    function test_sellCurrency0ContinuationPreviewAndCancel() public {
        _partialAndCancel(true);
    }

    function test_sellCurrency1ContinuationPreviewAndCancel() public {
        _partialAndCancel(false);
    }

    function _partialAndCancel(bool sell0) private {
        LimitOrder.OrderRequest memory request = _request(sell0, 10e18, 2, 10);
        request.endPriceNumerator = 6;
        uint64 index = orders.placeOrder(key, request);
        LimitOrder.FillPreview memory preview = orders.previewFill(pool, !sell0, 48e16, false);
        assertEq(preview.output, 2e18);
        assertEq(preview.input, 48e16);
        BalanceDelta delta = _swapExactInput(key, !sell0, 48e16);
        assertEq(sell0 ? delta.amount0() : delta.amount1(), 2e18);
        assertEq(orders.getOrder(pool, index).remaining, 8e18);
        preview = orders.previewFill(pool, !sell0, 102e16, false);
        assertEq(preview.output, 3e18);
        _swapExactInput(key, !sell0, 102e16);
        assertEq(orders.getOrder(pool, index).remaining, 5e18);
        _assertLiabilities(pool);
        hook.deactivateExtension(key, IHookExtension(address(orders)));
        orders.cancelOrder(pool, index);
        (uint256 proceeds,) = orders.claimable(pool, address(this), sell0 ? currency1 : currency0);
        (uint256 refund,) = orders.claimable(pool, address(this), sell0 ? currency0 : currency1);
        assertEq(proceeds, 15e17);
        assertEq(refund, 5e18);
        assertEq(orders.getOrder(pool, index).remaining, 5e18);
        vm.expectRevert(LimitOrder.InvalidOrder.selector);
        orders.cancelOrder(pool, index);
        _assertLiabilities(pool);
    }

    function test_rangeFullFillAndImmutableTerms() public {
        LimitOrder.OrderRequest memory request = _request(false, 10e18, 2, 10);
        request.endPriceNumerator = 6;
        uint64 index = orders.placeOrder(key, request);
        LimitOrder.Order memory order = orders.getOrder(pool, index);
        assertEq(order.owner, address(this));
        assertEq(order.originalAmount, request.amount);
        assertEq(order.priceNumerator, 2);
        assertEq(order.priceDenominator, 10);
        assertEq(order.endPriceNumerator, 6);
        assertEq(order.expiry, request.expiry);
        assertTrue(order.allowNested);
        BalanceDelta delta = _swapExactInput(key, true, 4e18);
        assertEq(delta.amount1(), 10e18);
        assertEq(uint8(orders.getOrder(pool, index).status), uint8(LimitOrder.OrderStatus.Filled));
        _assertLiabilities(pool);
    }

    function test_priceMovedRangeDoesNotHideFixedSuccessor() public {
        LimitOrder.OrderRequest memory request = _request(false, 10e18, 5, 10);
        request.endPriceNumerator = 15;
        uint64 first = orders.placeOrder(key, request);
        request = _request(false, 2e18, 8, 10);
        request.predecessor = first;
        uint64 second = orders.placeOrder(key, request);
        _swapExactInput(key, true, 375e16);
        assertEq(orders.getOrder(pool, first).remaining, 5e18);
        _swapExactInput(key, true, 1e18);
        assertEq(orders.getOrder(pool, first).remaining, 5e18);
        assertEq(orders.getOrder(pool, second).remaining, 75e16);
        _assertLiabilities(pool);
    }

    function test_rangeFailedSettlementRestoresProgress() public {
        LimitOrder.OrderRequest memory request = _request(false, 10e18, 2, 10);
        request.endPriceNumerator = 6;
        uint64 index = orders.placeOrder(key, request);
        vm.mockCall(
            Currency.unwrap(currency1), abi.encodeCall(IERC20.transfer, (address(manager), 2e18)), abi.encode(false)
        );
        _swapExactInput(key, true, 48e16);
        assertEq(orders.getOrder(pool, index).remaining, 10e18);
        (uint256 proceeds,) = orders.claimable(pool, address(this), currency0);
        assertEq(proceeds, 0);
        _assertLiabilities(pool);
        vm.clearMockedCalls();
    }

    function test_rejectsDecreasingReceivedPerSoldCurve() public {
        LimitOrder.OrderRequest memory request = _request(true, 10e18, 6, 10);
        request.endPriceNumerator = 2;
        vm.expectRevert(LimitOrder.InvalidOrder.selector);
        orders.placeOrder(key, request);
    }

    function test_rangeExpiryPreservesPartialProceeds() public {
        LimitOrder.OrderRequest memory request = _request(false, 10e18, 2, 10);
        request.endPriceNumerator = 6;
        uint64 index = orders.placeOrder(key, request);
        _swapExactInput(key, true, 48e16);
        vm.warp(block.timestamp + 2 days);
        uint64[] memory indices = new uint64[](1);
        indices[0] = index;
        orders.expireOrders(pool, indices);
        (uint256 proceeds,) = orders.claimable(pool, address(this), currency0);
        (uint256 refund,) = orders.claimable(pool, address(this), currency1);
        assertEq(proceeds, 48e16);
        assertEq(refund, 8e18);
        assertEq(orders.getOrder(pool, index).remaining, 8e18);
        _assertLiabilities(pool);
    }

    function test_coldHugeRangeSmallBudgetFitsBoundedPreviewCap() public {
        LimitOrder.OrderRequest memory request = _request(false, uint128(OrderMath.MAX_DELTA), 100, 1000);
        request.endPriceNumerator = 200;
        orders.placeOrder(key, request);
        vm.cool(address(orders));
        vm.cool(address(hook));
        vm.cool(address(hook.VAULT()));
        vm.cool(address(manager));
        (bool success, bytes memory data) = address(orders).staticcall{gas: 180_000}(
            abi.encodeCall(LimitOrder.previewFill, (pool, true, uint128(123), true))
        );
        assertTrue(success);
        LimitOrder.FillPreview memory preview = abi.decode(data, (LimitOrder.FillPreview));
        assertEq(preview.input, 123);
        assertEq(preview.output, 1229);
    }

    function test_rangeFeeAndBeneficiaryLedgerUseCumulativeAllocation() public {
        PoolKey memory peer = _peer();
        LimitOrder.Policy memory policy = _orderPolicy();
        policy.feeBps = 1000;
        policy.revenueShareBps = 5000;
        policy.feeBeneficiary = address(0xBEEF);
        _installOrders(peer, policy);
        LimitOrder.OrderRequest memory request = _request(false, 100, 200, 1000);
        request.endPriceNumerator = 600;
        uint64 index = orders.placeOrder(peer, request);
        _swapExactInput(peer, true, 4); // cumulative payment 3, fee 1, revenue 0
        _swapExactInput(peer, true, 40); // total payment 40, fee 4, revenue 2
        (uint256 maker,) = orders.claimable(peer.toId(), address(this), currency0);
        (, uint256 revenue) = orders.claimable(peer.toId(), address(0xBEEF), currency0);
        assertEq(maker, 42);
        assertEq(revenue, 2);
        assertEq(uint8(orders.getOrder(peer.toId(), index).status), uint8(LimitOrder.OrderStatus.Filled));
        _assertLiabilities(peer.toId());
    }

    function test_nativeRangeProceedsAndClaims() public {
        vm.deal(address(this), 100e18);
        PoolKey memory nativeKey = key;
        nativeKey.currency0 = Currency.wrap(address(0));
        _createPool(nativeKey);
        modifyLiquidityRouter.modifyLiquidity{value: 30e18}(
            nativeKey, ModifyLiquidityParams(-6000, 6000, 100e18, 0), ""
        );
        _installOrders(nativeKey, _orderPolicy());
        LimitOrder.OrderRequest memory request = _request(false, 10e18, 2, 10);
        request.endPriceNumerator = 6;
        uint64 index = orders.placeOrder(nativeKey, request);
        BalanceDelta delta = swapRouter.swap{value: 48e16}(
            nativeKey, SwapParams(true, -48e16, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(delta.amount1(), 2e18);
        assertEq(orders.getOrder(nativeKey.toId(), index).remaining, 8e18);
        (uint256 maker,) = orders.claimable(nativeKey.toId(), address(this), nativeKey.currency0);
        assertEq(maker, 48e16);
        uint256 beforeBalance = address(this).balance;
        orders.claim(nativeKey.toId(), nativeKey.currency0, maker, address(this));
        assertEq(address(this).balance - beforeBalance, maker);
    }
}
