// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {KernelRouteExecutor} from "../../src/KernelRouteExecutor.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {CallbackType, ExecutionContext, Operation, RouteAction} from "../../src/types/KernelHookTypes.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Exercises each ticket and frame check while an installed extension has a live parent callback.
contract TicketsTest is KernelHookFixture {
    uint32 internal constant ROUTE_GAS_LIMIT = 2_500_000;
    uint256 internal constant ACTION_AMOUNT = 1e12;

    enum Probe {
        BeforePool,
        BeforeParameters,
        BeforeHookData,
        ConsumedTwice,
        FinishUnconsumed,
        FinishOpenChild,
        AfterSender,
        AfterPool,
        AfterParameters,
        AfterHookData
    }

    PoolKey internal poolKey;
    PoolKey internal actionKey;
    PoolKey internal otherKey;
    MockExtension internal router;
    KernelRouteExecutor internal executor;
    uint256 internal completedProbes;

    function setUp() public override {
        super.setUp();
        poolKey = _poolKey();
        actionKey = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        otherKey = PoolKey(currency0, currency1, 10_000, 60, IHooks(address(hook)));
        _createPool(poolKey);
        _addLiquidity(poolKey);
        _createPool(actionKey);
        _createPool(otherKey);
        router = new MockExtension(address(hook));
        executor = hook.ROUTE_EXECUTOR();
        uint16 callbacks = uint16(1) << uint8(CallbackType.AfterSwap);
        _installAndActivate(poolKey, address(router), _settings(callbacks, false, true, ROUTE_GAS_LIMIT));
    }

    /// @dev Isolates consumeTicket's action hash check with another known pool and matching sender/depth.
    function test_ticket_rejectsMismatchedAction_pool() public {
        _runProbe(Probe.BeforePool);
    }

    /// @dev Isolates consumeTicket's action hash check with identical parameters and hookData, changing only operation.
    function test_ticket_rejectsMismatchedAction_operation() public {
        router.setExternalCall(CallbackType.AfterSwap, address(this), abi.encodeCall(this.probeMismatchedOperation, ()));
        bytes memory reason = abi.encodeWithSelector(IKernelHook.UnexpectedCallback.selector);
        bytes memory failure = abi.encodeWithSelector(
            IKernelHook.ExtensionFailed.selector, address(router), CallbackType.AfterSwap, reason
        );
        vm.expectRevert(_hookRevert(IHooks.afterSwap.selector, failure));

        _swapExactInput(poolKey, true, 1e14);
    }

    /// @dev Isolates consumeTicket's action hash check after its ticket, awaiting, depth and sender checks pass.
    function test_ticket_rejectsMismatchedAction_parameters() public {
        _runProbe(Probe.BeforeParameters);
    }

    /// @dev Isolates consumeTicket's action hash check with every action field except hookData unchanged.
    function test_ticket_rejectsMismatchedAction_hookData() public {
        _runProbe(Probe.BeforeHookData);
    }

    /// @dev Isolates consumeTicket's awaiting check by closing the first child, restoring the ticket's parent depth.
    function test_ticket_cannotBeConsumedTwice() public {
        _runProbe(Probe.ConsumedTwice);
    }

    /// @dev Isolates popTicket's awaiting check with the correct caller, a live ticket and its original parent depth.
    function test_finishAction_rejectsUnconsumedTicket() public {
        _runProbe(Probe.FinishUnconsumed);
    }

    /// @dev Isolates popTicket's parent depth check after the child has consumed its ticket.
    function test_finishAction_rejectsStillOpenChildFrame() public {
        _runProbe(Probe.FinishOpenChild);
    }

    /// @dev Isolates requireMatchingFrame's sender check with a live child and otherwise identical action.
    function test_afterCallback_rejectsMismatchedSenderOrAction_sender() public {
        _runProbe(Probe.AfterSender);
    }

    /// @dev Isolates requireMatchingFrame's callback check; positive liquidity makes the later normalized hash match.
    function test_afterCallback_rejectsMismatchedSenderOrAction_callbackType() public {
        _runCallback(abi.encodeCall(this.probeMismatchedAfterCallbackType, ()));
    }

    /// @dev Isolates _requireMatchingOperation's action hash check with matching frame sender and callback type.
    function test_afterCallback_rejectsMismatchedSenderOrAction_pool() public {
        _runProbe(Probe.AfterPool);
    }

    /// @dev Isolates _requireMatchingOperation's action hash check with only the swap parameters changed.
    function test_afterCallback_rejectsMismatchedSenderOrAction_parameters() public {
        _runProbe(Probe.AfterParameters);
    }

    /// @dev Isolates _requireMatchingOperation's action hash check with only hookData changed.
    function test_afterCallback_rejectsMismatchedSenderOrAction_hookData() public {
        _runProbe(Probe.AfterHookData);
    }

    /// @dev Cheatcodes here make direct hook calls with the PoolManager and route executor identities.
    function probeTicket(Probe probe) external {
        assertEq(msg.sender, address(router));
        SwapParams memory params = _exactInputParameters(true, ACTION_AMOUNT);
        bytes memory hookData = "authorized data";
        _authorize(RouteAction(actionKey, Operation.Swap, abi.encode(params), hookData));

        if (probe == Probe.BeforePool) {
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _beforeSwap(otherKey, params, hookData);
        } else if (probe == Probe.BeforeParameters) {
            SwapParams memory differentParams = _exactInputParameters(true, ACTION_AMOUNT + 1);
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _beforeSwap(actionKey, differentParams, hookData);
        } else if (probe == Probe.BeforeHookData) {
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _beforeSwap(actionKey, params, "different data");
        } else if (probe == Probe.FinishUnconsumed) {
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _finish();
        }

        _beforeSwap(actionKey, params, hookData);
        if (probe == Probe.FinishOpenChild) {
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _finish();
        } else if (probe == Probe.AfterSender) {
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _afterSwap(address(0xBEEF), actionKey, params, hookData);
        } else if (probe == Probe.AfterPool) {
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _afterSwap(address(executor), otherKey, params, hookData);
        } else if (probe == Probe.AfterParameters) {
            SwapParams memory differentParams = _exactInputParameters(true, ACTION_AMOUNT + 1);
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _afterSwap(address(executor), actionKey, differentParams, hookData);
        } else if (probe == Probe.AfterHookData) {
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _afterSwap(address(executor), actionKey, params, "different data");
        }
        _afterSwap(address(executor), actionKey, params, hookData);

        if (probe == Probe.ConsumedTwice) {
            // Closing the first child makes the later parent-depth check pass if the awaiting check is removed.
            vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
            _beforeSwap(actionKey, params, hookData);
        }
        _finish();
        _completeProbe();
    }

    function probeMismatchedOperation() external {
        assertEq(msg.sender, address(router));
        SwapParams memory params = _exactInputParameters(true, ACTION_AMOUNT);
        bytes memory hookData = "authorized data";
        // authorizeAction records opaque Donate parameters for an initialized target without decoding them.
        _authorize(RouteAction(actionKey, Operation.Donate, abi.encode(params), hookData));
        // The callback has the exact bytes that were authorized; only its operation differs.
        _beforeSwap(actionKey, params, hookData);
    }

    function probeMismatchedAfterCallbackType() external {
        assertEq(msg.sender, address(router));
        ModifyLiquidityParams memory params = _liquidityParameters(1e15);
        bytes memory hookData = "authorized data";
        _authorize(RouteAction(actionKey, Operation.ModifyLiquidity, abi.encode(params), hookData));
        vm.prank(address(manager));
        hook.beforeAddLiquidity(address(executor), actionKey, params, hookData);

        // With positive liquidity, actionHash normalizes both callback types to BeforeAddLiquidity.
        vm.expectRevert(IKernelHook.UnexpectedCallback.selector);
        vm.prank(address(manager));
        hook.afterRemoveLiquidity(
            address(executor), actionKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), hookData
        );

        vm.prank(address(manager));
        hook.afterAddLiquidity(
            address(executor), actionKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), hookData
        );
        _finish();
        _completeProbe();
    }

    function _runProbe(Probe probe) private {
        _runCallback(abi.encodeCall(this.probeTicket, (probe)));
    }

    function _runCallback(bytes memory data) private {
        router.setExternalCall(CallbackType.AfterSwap, address(this), data);
        _swapExactInput(poolKey, true, 1e14);

        assertEq(completedProbes, 1);
        assertEq(router.callCount(CallbackType.AfterSwap), 1);
        assertEq(hook.currentContext().depth, 0);
    }

    function _authorize(RouteAction memory action) private {
        vm.prank(address(executor));
        hook.authorizeAction(action);
    }

    function _finish() private {
        vm.prank(address(executor));
        hook.finishAction();
    }

    function _beforeSwap(PoolKey memory key, SwapParams memory params, bytes memory hookData) private {
        vm.prank(address(manager));
        hook.beforeSwap(address(executor), key, params, hookData);
    }

    function _afterSwap(address sender, PoolKey memory key, SwapParams memory params, bytes memory hookData) private {
        vm.prank(address(manager));
        hook.afterSwap(sender, key, params, BalanceDelta.wrap(0), hookData);
    }

    function _completeProbe() private {
        ExecutionContext memory context = hook.currentContext();
        assertEq(context.depth, 1);
        assertEq(context.extension, address(router));
        assertEq(context.sender, address(swapRouter));
        ++completedProbes;
    }
}
