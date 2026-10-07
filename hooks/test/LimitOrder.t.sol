// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ExtensionFixture} from "./utils/ExtensionFixture.sol";
import {LimitOrder} from "../src/LimitOrder.sol";
import {OrderMath} from "../src/libraries/OrderMath.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {ExtensionSettings, CallbackType} from "core/src/types/KernelHookTypes.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract LimitOrderTest is ExtensionFixture {
    function setUp() public override {
        super.setUp();
        // Kernel physically takes maker proceeds before the root router settles its debt.
        // Provide enough singleton float for the deliberately large order-only fills below.
        modifyLiquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-6000, 6000, 100e18, 0), "");
        _installOrders(key, _orderPolicy());
    }

    function test_partialFillCancelAndInactiveClaims() public {
        uint64 index = orders.placeOrder(key, _request(false, 2e18, 1, 1));
        BalanceDelta delta = _swapExactInput(key, true, 5e17);
        assertEq(delta.amount0(), -5e17);
        assertEq(delta.amount1(), 5e17);
        assertEq(orders.getOrder(pool, index).remaining, 15e17);
        _assertLiabilities(pool);
        hook.deactivateExtension(key, IHookExtension(address(orders)));
        orders.cancelOrder(pool, index);
        (uint256 proceeds,) = orders.claimable(pool, address(this), currency0);
        (uint256 refund,) = orders.claimable(pool, address(this), currency1);
        assertEq(proceeds, 5e17);
        assertEq(refund, 15e17);
        orders.claim(pool, currency0, proceeds, address(this));
        orders.claim(pool, currency1, refund, address(this));
        _assertLiabilities(pool);
        hook.removeExtension(key, IHookExtension(address(orders)));
    }

    function test_reverseDirectionFullFill() public {
        uint64 index = orders.placeOrder(key, _request(true, 1e18, 1, 1));
        BalanceDelta delta = _swapExactInput(key, false, 1e18);
        assertEq(delta.amount0(), 1e18);
        assertEq(delta.amount1(), -1e18);
        assertEq(uint8(orders.getOrder(pool, index).status), uint8(LimitOrder.OrderStatus.Filled));
        _assertLiabilities(pool);
    }

    function test_activationRejectsCallbackLargerThanPoolBudget() public {
        ExtensionSettings memory settings =
            _settings(uint16(1) << uint8(CallbackType.BeforeSwap), true, false, 4_000_000);
        settings.configuration = abi.encode(uint64(1));
        vm.prank(address(hook));
        assertFalse(orders.canActivate(key, settings));
    }

    function test_coldEightOrderPreviewFitsBoundedReadLimit() public {
        LimitOrder.OrderRequest memory request = _request(false, 1e15, 2, 1);
        for (uint256 i; i < 8; ++i) {
            request.predecessor = orders.placeOrder(key, request);
        }
        vm.cool(address(orders));
        vm.cool(address(hook));
        vm.cool(address(hook.VAULT()));
        vm.cool(address(manager));
        (bool success, bytes memory data) = address(orders).staticcall{gas: 180_000}(
            abi.encodeCall(LimitOrder.previewFill, (pool, true, uint128(1e16), true))
        );
        assertTrue(success);
        LimitOrder.FillPreview memory preview = abi.decode(data, (LimitOrder.FillPreview));
        assertTrue(preview.available);
        assertEq(preview.inspections, 8);
        assertEq(preview.fills, 0);
    }

    function test_reinstallRequiresFreshPolicyAndKeepsOrderIds() public {
        uint64 first = orders.placeOrder(key, _request(true, 100, 1, 1));
        orders.cancelOrder(pool, first);
        orders.claim(pool, currency0, 100, address(this));
        hook.deactivateExtension(key, IHookExtension(address(orders)));
        hook.removeExtension(key, IHookExtension(address(orders)));
        ExtensionSettings memory settings = _settings(uint16(1) << uint8(CallbackType.BeforeSwap), true, false, 600_000);
        settings.lifecycleGasLimit = 500_000;
        settings.configuration = abi.encode(uint64(0));
        hook.installExtension(key, IHookExtension(address(orders)), settings);
        vm.prank(address(hook));
        assertFalse(orders.canActivate(key, settings));
        (LimitOrder.Policy memory cleared, uint64 version,) = orders.policyState(pool);
        assertEq(cleared.minimumOrder, 0);
        assertEq(version, 1);
        orders.setPolicy(key, version, _orderPolicy());
        settings.configuration = abi.encode(uint64(2));
        hook.configureExtension(key, IHookExtension(address(orders)), settings);
        hook.activateExtension(key, IHookExtension(address(orders)));
        LimitOrder.OrderRequest memory request = _request(true, 100, 1, 1);
        vm.expectRevert(bytes4(keccak256("InvalidVersion()")));
        orders.placeOrder(key, request);
        request.expectedPolicyVersion = 2;
        assertEq(orders.placeOrder(key, request), first + 1);
        _assertLiabilities(pool);
    }

    function test_equalPricesRequireFIFOPlacement() public {
        uint64 first = orders.placeOrder(key, _request(false, 1e18, 1, 1));
        LimitOrder.OrderRequest memory request = _request(false, 1e18, 2, 2);
        vm.expectRevert(LimitOrder.InvalidHints.selector);
        orders.placeOrder(key, request);
        request.predecessor = first;
        uint64 second = orders.placeOrder(key, request);
        _swapExactInput(key, true, 15e17);
        assertEq(orders.getOrder(pool, first).remaining, 0);
        assertEq(orders.getOrder(pool, second).remaining, 5e17);
        _assertLiabilities(pool);
    }

    function test_expiryRefundBelongsToMaker() public {
        uint64 index = orders.placeOrder(key, _request(false, 1e18, 1, 1));
        vm.warp(block.timestamp + 2 days);
        uint64[] memory indices = new uint64[](1);
        indices[0] = index;
        vm.prank(address(0xBEEF));
        orders.expireOrders(pool, indices);
        (uint256 refund,) = orders.claimable(pool, address(this), currency1);
        assertEq(refund, 1e18);
        _assertLiabilities(pool);
    }

    function test_exactOutputDoesNotFillOrders() public {
        uint64 index = orders.placeOrder(key, _request(false, 1e18, 1, 1));
        swapRouter.swap(key, SwapParams(true, 1e14, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        assertEq(orders.getOrder(pool, index).remaining, 1e18);
    }

    function test_invalidLimitCannotBeBypassedByFullOrderFill() public {
        orders.placeOrder(key, _request(false, 1e18, 1, 1));
        vm.expectRevert();
        swapRouter.swap(key, SwapParams(true, -1e18, SQRT_PRICE_1_1), PoolSwapTest.TestSettings(false, false), "");
    }

    function test_failedOptionalSettlementRestoresBook() public {
        uint64 index = orders.placeOrder(key, _request(false, 1e18, 1, 1));
        vm.mockCall(
            Currency.unwrap(currency1), abi.encodeCall(IERC20.transfer, (address(manager), 1e18)), abi.encode(false)
        );
        BalanceDelta delta = _swapExactInput(key, true, 1e18);
        assertGt(delta.amount1(), 0);
        assertEq(orders.getOrder(pool, index).remaining, 1e18);
        (uint256 claim,) = orders.claimable(pool, address(this), currency0);
        assertEq(claim, 0);
        _assertLiabilities(pool);
        vm.clearMockedCalls();
    }

    function test_uninstallBlockedByRefundLiability() public {
        uint64 index = orders.placeOrder(key, _request(false, 1e18, 1, 1));
        orders.cancelOrder(pool, index);
        hook.deactivateExtension(key, IHookExtension(address(orders)));
        vm.expectRevert(IKernelHook.OutstandingObligations.selector);
        hook.removeExtension(key, IHookExtension(address(orders)));
    }

    function test_feeAllocationAndNativeProceeds() public {
        PoolKey memory nativeKey = PoolKey(Currency.wrap(address(0)), currency1, 1000, 60, IHooks(address(hook)));
        _createPool(nativeKey);
        vm.deal(address(this), 100e18);
        modifyLiquidityRouter.modifyLiquidity{value: 10e18}(nativeKey, ModifyLiquidityParams(-6000, 6000, 10e18, 0), "");
        LimitOrder.Policy memory policy = _orderPolicy();
        policy.feeBps = 100;
        policy.revenueShareBps = 5000;
        policy.feeBeneficiary = address(0xBEEF);
        _installOrders(nativeKey, policy);
        uint64 index = orders.placeOrder(nativeKey, _request(false, 1e18, 9, 10));
        BalanceDelta delta = swapRouter.swap{value: 909e15}(
            nativeKey, SwapParams(true, -909e15, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(delta.amount1(), 1e18);
        assertEq(orders.getOrder(nativeKey.toId(), index).remaining, 0);
        (uint256 maker,) = orders.claimable(nativeKey.toId(), address(this), nativeKey.currency0);
        (, uint256 revenue) = orders.claimable(nativeKey.toId(), address(0xBEEF), nativeKey.currency0);
        assertEq(maker, 9045e14);
        assertEq(revenue, 45e14);
        orders.claim(nativeKey.toId(), nativeKey.currency0, maker, address(this));
        vm.prank(address(0xBEEF));
        orders.claimRevenue(nativeKey.toId(), nativeKey.currency0, revenue, address(this));
    }

    function test_unauthorizedCancellationAndPolicyChange() public {
        uint64 index = orders.placeOrder(key, _request(false, 1e18, 1, 1));
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        orders.cancelOrder(pool, index);
        vm.expectRevert();
        orders.setPolicy(key, 1, _orderPolicy());
        vm.stopPrank();
    }

    function testFuzz_fillPreservesBudgetAndMakerMinimum(uint128 budget, uint128 n, uint128 d, uint16 fee) public pure {
        budget = uint128(uint256(budget) % OrderMath.MAX_DELTA);
        if (n == 0) n = 1;
        if (d == 0) d = 1;
        fee %= 1001;
        OrderMath.Fill memory fill = OrderMath.fill(budget, OrderMath.MAX_DELTA, n, d, fee);
        assertLe(uint256(fill.payment) + fill.fee, budget);
        if (fill.output != 0) {
            assertGt(fill.payment, 0);
            assertGe(uint256(fill.payment) * d, uint256(fill.output) * n);
        }
    }
}
