// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ExtensionFixture} from "./utils/ExtensionFixture.sol";
import {LimitOrder} from "../src/limitorder/LimitOrder.sol";
import {LVRHook} from "../src/lvr/uniswap-v4/LVRHook.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {LVRTestExtension} from "./utils/LVRTestExtension.sol";
import {KernelExtension} from "../src/base/KernelExtension.sol";
import {CallbackType, ExtensionSettings, RouteAction, Operation} from "core/src/types/KernelHookTypes.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";

contract LVRHookTest is ExtensionFixture {
    LVRHook internal lvr;
    PoolKey internal dynamicKey;
    PoolId internal dynamicPool;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(100);
        lvr = LVRHook(deployCode("LVRHook.sol:LVRHook", abi.encode(IKernelHook(address(hook)))));
        catalog.admit(
            address(lvr),
            IHookCatalog.Entry(address(lvr).codehash, lvr.CALLBACK_MASK(), false, false, false, true, true)
        );
        dynamicKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        dynamicPool = dynamicKey.toId();
        _createPool(dynamicKey);
        _wideLiquidity(dynamicKey);
        _installLVR(dynamicKey, _policy());
    }

    function test_baseFeeMatchesStaticPoolAndAccruesToLPs() public {
        (uint24 fee,,) = lvr.previewFee(dynamicPool);
        assertEq(fee, 3000);
        BalanceDelta guarded = _swapExactInput(dynamicKey, true, 1e14);
        BalanceDelta control = _swapExactInput(key, true, 1e14);
        assertEq(guarded.amount0(), control.amount0());
        assertEq(guarded.amount1(), control.amount1());
        (uint256 growth0,) = StateLibrary.getFeeGrowthGlobals(manager, dynamicPool);
        assertGt(growth0, 0);
        assertEq(hook.VAULT().balanceOf(dynamicPool, address(lvr), currency0), 0);
        assertEq(hook.VAULT().balanceOf(dynamicPool, address(lvr), currency1), 0);
    }

    function test_idlePremiumSurvivesFirstDustSwap() public {
        vm.warp(110);
        (uint24 beforeFee,, uint24 idle) = lvr.previewFee(dynamicPool);
        assertEq(beforeFee, 5000);
        assertEq(idle, 2000);
        _swapExactInput(dynamicKey, true, 1);
        (uint24 fee,,) = lvr.previewFee(dynamicPool);
        assertGe(fee, beforeFee);
        BalanceDelta guarded = _swapExactInput(dynamicKey, false, 1e14);
        BalanceDelta control = _swapExactInput(key, false, 1e14);
        assertLt(guarded.amount0(), control.amount0());
    }

    function test_priceMoveRaisesOnlyFollowingSwapFee() public {
        (uint24 opening,,) = lvr.previewFee(dynamicPool);
        assertEq(opening, 3000);
        _swapExactInput(dynamicKey, true, 1e16);
        LVRHook.Observation memory state = lvr.observation(dynamicPool);
        assertGt(state.windowMovement, 0);
        assertGt(state.windowFee, opening);
        (uint24 next,,) = lvr.previewFee(dynamicPool);
        assertEq(next, state.windowFee);
        assertLe(next, 10_000);
    }

    function test_sameWindowReversalCannotResetPeakOrFee() public {
        _swapExactInput(dynamicKey, true, 1e16);
        LVRHook.Observation memory first = lvr.observation(dynamicPool);
        _swapExactInput(dynamicKey, false, 1e16);
        LVRHook.Observation memory second = lvr.observation(dynamicPool);
        assertGe(second.windowMovement, first.windowMovement);
        assertGe(second.windowFee, first.windowFee);
        assertEq(second.epoch, first.epoch);
    }

    function test_timeWindowsIgnoreBlockNumber() public {
        vm.warp(110);
        _swapExactInput(dynamicKey, true, 1);
        LVRHook.Observation memory first = lvr.observation(dynamicPool);
        vm.roll(block.number + 100);
        vm.warp(111);
        _swapExactInput(dynamicKey, true, 1);
        assertEq(lvr.observation(dynamicPool).epoch, first.epoch);
        vm.warp(112);
        _swapExactInput(dynamicKey, true, 1);
        assertGt(lvr.observation(dynamicPool).epoch, first.epoch);
    }

    function test_riskDecaysAcrossWindows() public {
        _swapExactInput(dynamicKey, true, 1e16);
        LVRHook.Observation memory first = lvr.observation(dynamicPool);
        vm.warp(160);
        _swapExactInput(dynamicKey, true, 1);
        LVRHook.Observation memory second = lvr.observation(dynamicPool);
        assertEq(second.volatilityTicks, first.windowMovement / 2);
        assertGe(second.windowFee, 3000);
        assertLe(second.windowFee, 10_000);
    }

    function test_exactOutputUsesFeeOverride() public {
        vm.warp(110);
        BalanceDelta guarded = swapRouter.swap(
            dynamicKey, SwapParams(true, 1e14, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        BalanceDelta control =
            swapRouter.swap(key, SwapParams(true, 1e14, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        assertEq(guarded.amount1(), 1e14);
        assertEq(control.amount1(), 1e14);
        assertLt(guarded.amount0(), control.amount0());
    }

    function test_laterRequiredFailureRollsBackObservationAndPrice() public {
        LVRTestExtension failing = _mock(CallbackType.AfterSwap, false, false);
        failing.setBehavior(true, 0);
        bytes32 beforeObservation = keccak256(abi.encode(lvr.observation(dynamicPool)));
        (uint160 beforePrice,,,) = StateLibrary.getSlot0(manager, dynamicPool);
        vm.expectRevert();
        _swapExactInput(dynamicKey, true, 1e16);
        assertEq(keccak256(abi.encode(lvr.observation(dynamicPool))), beforeObservation);
        (uint160 afterPrice,,,) = StateLibrary.getSlot0(manager, dynamicPool);
        assertEq(afterPrice, beforePrice);
    }

    function test_secondFeeOwnerRevertsRatherThanSilentlyReplacingFee() public {
        LVRTestExtension competing = _mock(CallbackType.BeforeSwap, false, false);
        competing.setBehavior(false, uint24(5000) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        vm.expectRevert();
        _swapExactInput(dynamicKey, true, 1e14);
    }

    function test_nestedSamePoolSwapAfterGuardCompletes() public {
        LVRTestExtension router = _mock(CallbackType.AfterSwap, true, true);
        IERC20(Currency.unwrap(currency0)).transfer(address(router), 1e16);
        router.deposit(dynamicPool, currency0, 1e16);
        router.setRoute(
            RouteAction(dynamicKey, Operation.Swap, abi.encode(SwapParams(true, -int256(1e14), MIN_PRICE_LIMIT)), "")
        );
        _swapExactInput(dynamicKey, true, 1e14);
        assertEq(router.routedCount(), 1);
        assertGe(lvr.observation(dynamicPool).windowFee, 3000);
    }

    function test_fullPriorFillDoesNotOpenAnAMMFeeObservation() public {
        LVRTestExtension filler = _mock(CallbackType.BeforeSwap, false, false);
        filler.setDeltas(1e14, -1e14);
        IERC20(Currency.unwrap(currency1)).transfer(address(filler), 1e14);
        filler.deposit(dynamicPool, currency1, 1e14);
        hook.deactivateExtension(dynamicKey, IHookExtension(address(lvr)));
        hook.deactivateExtension(dynamicKey, IHookExtension(address(filler)));
        address[] memory order = new address[](2);
        order[0] = address(filler);
        order[1] = address(lvr);
        hook.setCallbackOrder(dynamicKey, CallbackType.BeforeSwap, order);
        hook.activateExtension(dynamicKey, IHookExtension(address(lvr)));
        hook.activateExtension(dynamicKey, IHookExtension(address(filler)));
        (uint160 beforePrice,,,) = StateLibrary.getSlot0(manager, dynamicPool);
        BalanceDelta filled = _swapExactInput(dynamicKey, true, 1e14);
        assertEq(filled.amount0(), -1e14);
        assertEq(filled.amount1(), 1e14);
        assertEq(lvr.observation(dynamicPool).epoch, 0);
        (uint160 afterPrice,,,) = StateLibrary.getSlot0(manager, dynamicPool);
        assertEq(afterPrice, beforePrice);
    }

    function test_otherPoolObservationsRemainIndependent() public {
        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(address(hook)));
        _createPool(other);
        _wideLiquidity(other);
        _installLVR(other, _policy());
        _swapExactInput(dynamicKey, true, 1e16);
        assertGt(lvr.observation(dynamicPool).windowMovement, 0);
        assertEq(lvr.observation(other.toId()).windowMovement, 0);
        (uint24 fee,,) = lvr.previewFee(other.toId());
        assertEq(fee, 3000);
        assertEq(lvr.totalPools(), 2);
    }

    function test_policyCannotBeChangedWhileActive() public {
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        lvr.setPolicy(dynamicKey, 1, _policy());
    }

    function test_onlyPoolControllerMaySetPolicy() public {
        hook.deactivateExtension(dynamicKey, IHookExtension(address(lvr)));
        vm.prank(address(0xBAD));
        vm.expectRevert();
        lvr.setPolicy(dynamicKey, 1, _policy());
    }

    function test_staleVersionRejected() public {
        hook.deactivateExtension(dynamicKey, IHookExtension(address(lvr)));
        vm.expectRevert(KernelExtension.InvalidVersion.selector);
        lvr.setPolicy(dynamicKey, 0, _policy());
    }

    function test_invalidPolicyRejected() public {
        hook.deactivateExtension(dynamicKey, IHookExtension(address(lvr)));
        LVRHook.Policy memory policy = _policy();
        policy.feeWindowSeconds = 0;
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        lvr.setPolicy(dynamicKey, 1, policy);
        policy.feeWindowSeconds = 61;
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        lvr.setPolicy(dynamicKey, 1, policy);
        policy = _policy();
        policy.maximumFee = 100_001;
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        lvr.setPolicy(dynamicKey, 1, policy);
    }

    function test_optionalGuardRejected() public {
        hook.deactivateExtension(dynamicKey, IHookExtension(address(lvr)));
        ExtensionSettings memory settings = _lvrSettings(1);
        settings.optionalCallbacks = true;
        vm.expectRevert();
        hook.configureExtension(dynamicKey, IHookExtension(address(lvr)), settings);
    }

    function test_staticPoolRejected() public {
        ExtensionSettings memory settings = _lvrSettings(0);
        vm.expectRevert();
        hook.installExtension(key, IHookExtension(address(lvr)), settings);
    }

    function test_reinstallPreservesVersionAndCapacityAccounting() public {
        hook.deactivateExtension(dynamicKey, IHookExtension(address(lvr)));
        hook.removeExtension(dynamicKey, IHookExtension(address(lvr)));
        hook.installExtension(dynamicKey, IHookExtension(address(lvr)), _lvrSettings(0));
        lvr.setPolicy(dynamicKey, 1, _policy());
        hook.configureExtension(dynamicKey, IHookExtension(address(lvr)), _lvrSettings(2));
        hook.activateExtension(dynamicKey, IHookExtension(address(lvr)));
        assertEq(lvr.totalPools(), 1);
        (, uint64 version, uint64 configured, bool installed) = lvr.policyState(dynamicPool);
        assertTrue(installed);
        assertEq(version, 2);
        assertEq(configured, 2);
    }

    function test_deactivationExposesZeroStoredFeeDeploymentGap() public {
        hook.deactivateExtension(dynamicKey, IHookExtension(address(lvr)));
        (,,, uint24 storedFee) = StateLibrary.getSlot0(manager, dynamicPool);
        assertEq(storedFee, 0);
        BalanceDelta unguarded = _swapExactInput(dynamicKey, true, 1e14);
        BalanceDelta fixedFee = _swapExactInput(key, true, 1e14);
        assertGt(unguarded.amount1(), fixedFee.amount1());
    }

    function test_existingLimitOrderRejectsRequiredFeeCoSubscriber() public {
        hook.deactivateExtension(dynamicKey, IHookExtension(address(lvr)));
        // Installing orders while the guard is inactive is allowed. Place orders first in callback order.
        ExtensionSettings memory settings = _settings(uint16(1) << uint8(CallbackType.BeforeSwap), true, false, 600_000);
        settings.lifecycleGasLimit = 500_000;
        settings.configuration = abi.encode(uint64(0));
        hook.installExtension(dynamicKey, IHookExtension(address(orders)), settings);
        orders.setPolicy(dynamicKey, 0, _orderPolicyWithTwoSubscribers());
        settings.configuration = abi.encode(uint64(1));
        hook.configureExtension(dynamicKey, IHookExtension(address(orders)), settings);
        address[] memory order = new address[](2);
        order[0] = address(orders);
        order[1] = address(lvr);
        // The Kernel refuses the order itself: required subscribers must precede optional ones in beforeSwap.
        vm.expectRevert(IKernelHook.InvalidCallbackOrder.selector);
        hook.setCallbackOrder(dynamicKey, CallbackType.BeforeSwap, order);
    }

    function test_clockRegressionRejected() public {
        _swapExactInput(dynamicKey, true, 1e14);
        vm.warp(99);
        vm.expectRevert(LVRHook.ClockOutOfBounds.selector);
        lvr.previewFee(dynamicPool);
    }

    function testFuzz_feeBoundedAcrossMovesAndTime(uint128 amount, uint32 elapsed, bool direction) public {
        amount = uint128(bound(amount, 1, 1e17));
        elapsed = uint32(bound(elapsed, 0, 30 days));
        _swapExactInput(dynamicKey, direction, amount);
        vm.warp(100 + elapsed);
        (uint24 preview,,) = lvr.previewFee(dynamicPool);
        assertGe(preview, 3000);
        assertLe(preview, 10_000);
        _swapExactInput(dynamicKey, !direction, 1e12);
        LVRHook.Observation memory state = lvr.observation(dynamicPool);
        assertGe(state.windowFee, 3000);
        assertLe(state.windowFee, 10_000);
    }

    function _policy() internal pure returns (LVRHook.Policy memory) {
        return LVRHook.Policy(3000, 10_000, 2000, 10, 60, 10, 2);
    }

    function _lvrSettings(uint64 version) internal view returns (ExtensionSettings memory settings) {
        settings = _settings(lvr.CALLBACK_MASK(), false, false, 150_000);
        settings.lifecycleGasLimit = 500_000;
        settings.configuration = abi.encode(version);
    }

    function _installLVR(PoolKey memory target, LVRHook.Policy memory policy) internal {
        hook.installExtension(target, IHookExtension(address(lvr)), _lvrSettings(0));
        lvr.setPolicy(target, 0, policy);
        hook.configureExtension(target, IHookExtension(address(lvr)), _lvrSettings(1));
        hook.activateExtension(target, IHookExtension(address(lvr)));
    }

    function _mock(CallbackType callback, bool optional, bool nesting) private returns (LVRTestExtension extension) {
        hook.deactivateExtension(dynamicKey, IHookExtension(address(lvr)));
        extension = new LVRTestExtension(IKernelHook(address(hook)));
        uint16 mask = uint16(1) << uint8(callback);
        catalog.admit(
            address(extension), IHookCatalog.Entry(address(extension).codehash, mask, true, true, false, true, true)
        );
        ExtensionSettings memory settings = _settings(mask, optional, nesting, 2_500_000);
        settings.lifecycleGasLimit = 500_000;
        hook.installExtension(dynamicKey, IHookExtension(address(extension)), settings);
        hook.activateExtension(dynamicKey, IHookExtension(address(lvr)));
        hook.activateExtension(dynamicKey, IHookExtension(address(extension)));
    }

    function _orderPolicyWithTwoSubscribers() private pure returns (LimitOrder.Policy memory policy) {
        policy = _orderPolicy();
        policy.maximumCoSubscribers = 2;
    }
}
