// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {CodexDispatchRecorder} from "../mocks/CodexDispatchRecorder.sol";
import {NoopExtension} from "../mocks/NoopExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {IHookCatalog} from "../../src/interfaces/IHookCatalog.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";
import {CallbackLibrary} from "../../src/libraries/CallbackLibrary.sol";
import {KernelHookConstants} from "../../src/libraries/KernelHookConstants.sol";
import {KernelHookState} from "../../src/libraries/KernelHookState.sol";
import {BeforeSwapLibrary} from "../../src/libraries/BeforeSwapLibrary.sol";
import {KernelHookDispatch} from "../../src/libraries/KernelHookDispatch.sol";
import {
    CALLBACK_COUNT,
    CallbackResult,
    CallbackType,
    ExecutionContext,
    ExtensionSettings,
    Operation,
    RouteAction
} from "../../src/types/KernelHookTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract DispatchTest is KernelHookFixture {
    using CallbackLibrary for CallbackType;

    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public override {
        super.setUp();
        key = _poolKey();
        poolId = key.toId();
    }

    function test_dispatch_callsExtensionsInConfiguredOrder() public {
        _createPool(key);
        _addLiquidity(key);
        CodexDispatchRecorder first = new CodexDispatchRecorder();
        CodexDispatchRecorder second = new CodexDispatchRecorder();
        _admit(address(first));
        _admit(address(second));
        hook.installExtension(key, first, _settings(SWAP_CALLBACKS, false, false, 100_000));
        hook.installExtension(key, second, _settings(SWAP_CALLBACKS, false, false, 100_000));
        address[] memory order = new address[](2);
        order[0] = address(second);
        order[1] = address(first);
        hook.setCallbackOrder(key, CallbackType.BeforeSwap, order);
        hook.activateExtension(key, first);
        hook.activateExtension(key, second);

        vm.expectEmit(true, true, false, true, address(second));
        emit CodexDispatchRecorder.CallbackReceived(address(second), CallbackType.BeforeSwap);
        vm.expectEmit(true, true, false, true, address(first));
        emit CodexDispatchRecorder.CallbackReceived(address(first), CallbackType.BeforeSwap);
        vm.expectEmit(true, true, false, true, address(first));
        emit CodexDispatchRecorder.CallbackReceived(address(first), CallbackType.AfterSwap);
        vm.expectEmit(true, true, false, true, address(second));
        emit CodexDispatchRecorder.CallbackReceived(address(second), CallbackType.AfterSwap);
        _swapExactInput(key, true, 1e14);
    }

    function test_dispatch_skipsOptionalRevertWithExactReason() public {
        MockExtension extension = _swapExtension(true);
        _behavior(extension, CallbackType.BeforeSwap, 0, 0, 0, true);
        // The skip event names the extension and the callback, so its reason is the extension's revert data.
        _expectSkip(
            extension,
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(MockExtension.MockRevert.selector, CallbackType.BeforeSwap)
        );

        _swapExactInput(key, true, 1e14);

        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
    }

    function test_dispatch_skipEndsWithOperation() public {
        MockExtension extension = _swapExtension(true);
        _behavior(extension, CallbackType.BeforeSwap, 0, 0, 0, true);
        _swapExactInput(key, true, 1e14);
        _behavior(extension, CallbackType.BeforeSwap, 0, 0, 0, false);

        _swapExactInput(key, true, 1e14);

        assertEq(extension.callCount(CallbackType.BeforeSwap), 1);
        assertEq(extension.callCount(CallbackType.AfterSwap), 1);
    }

    function test_dispatch_optionalAfterFailurePreservesBeforeCredit() public {
        MockExtension extension = _swapExtension(true);
        _behavior(extension, CallbackType.BeforeSwap, 100, 0, 0, false);
        _behavior(extension, CallbackType.AfterSwap, 0, 0, 0, true);
        _expectSkip(
            extension,
            CallbackType.AfterSwap,
            abi.encodeWithSelector(MockExtension.MockRevert.selector, CallbackType.AfterSwap)
        );

        _swapExactInput(key, true, 1e14);

        assertEq(extension.callCount(CallbackType.BeforeSwap), 1);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 100);
    }

    /// @dev The credit's claims are minted first; the debt in the other currency then fails. The skip rolls back
    /// the minted claims with the rest of the callback.
    function test_dispatch_optionalFailedDebtRollsBackMintedClaims() public {
        MockExtension extension = _swapExtension(true);
        _fundExtension(extension, currency1, 10);
        _behavior(extension, CallbackType.BeforeSwap, 100, -11, 0, false);
        _expectSkip(
            extension, CallbackType.BeforeSwap, abi.encodeWithSelector(KernelHookVault.InsufficientBalance.selector)
        );

        _swapExactInput(key, true, 1e14);

        KernelHookVault vault = hook.VAULT();
        assertEq(manager.balanceOf(address(vault), currency0.toId()), 0, "claims rolled back");
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 0);
        assertEq(vault.accountedBalance(currency0), 0);
        assertEq(vault.balanceOf(poolId, address(extension), currency1), 10);
    }

    function test_dispatch_optionalInvalidResultRollsBackCallback() public {
        MockExtension extension = _swapExtension(true);
        _behavior(extension, CallbackType.AfterSwap, 1, 0, 0, false);
        _expectSkip(extension, CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.InvalidDelta.selector));

        _swapExactInput(key, true, 1e14);

        assertEq(extension.callCount(CallbackType.BeforeSwap), 1);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 0);
    }

    function testFuzz_dispatch_skipsOptionalGasAdmissionWithExactReason(uint32 gasLimit) public {
        // 3,600,000 + 116,129 + 250,000 (invocation reserves) + 80,000 (return) is above the default 4,000,000.
        gasLimit = uint32(bound(gasLimit, 3_600_000, 5_000_000));
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, true, false, gasLimit));
        _expectSkip(extension, CallbackType.BeforeSwap, abi.encodePacked(IKernelHook.GasBudgetExceeded.selector));

        _swapExactInput(key, true, 1e14);

        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
    }

    function test_dispatch_reservesGasForRequiredSubscribers() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension optional = new MockExtension(address(hook));
        MockExtension required = new MockExtension(address(hook));
        _admit(address(optional));
        _admit(address(required));
        hook.installExtension(key, optional, _settings(SWAP_CALLBACKS, true, false));
        hook.installExtension(key, required, _settings(SWAP_CALLBACKS, false, false));
        // Each call needs 766,129 gas. Activation needs 766,129 + 80,000 (return) + 25,000 (sequence setup)
        // + 2 * (25,000 + 12,000) = 945,129. The optional call must also keep the required call's 766,129 in reserve
        // (1,637,258 with the return and iteration reserves), so only the required call fits.
        _setBudgets(1_300_000);
        hook.activateExtension(key, optional);
        hook.activateExtension(key, required);
        _expectSkip(optional, CallbackType.BeforeSwap, abi.encodePacked(IKernelHook.GasBudgetExceeded.selector));

        _swapExactInput(key, true, 1e14);

        assertEq(optional.callCount(CallbackType.BeforeSwap), 0);
        assertEq(optional.callCount(CallbackType.AfterSwap), 0);
        assertEq(required.callCount(CallbackType.BeforeSwap), 1);
        assertEq(required.callCount(CallbackType.AfterSwap), 1);
    }

    function test_dispatch_sequenceBudgetIncludesGasSpentByEarlierCallbacks() public {
        // Each limit fits alone; earlier callbacks spend the budget needed by the third.
        _createPool(key);
        _addLiquidity(key);
        CodexDispatchRecorder first = new CodexDispatchRecorder();
        CodexDispatchRecorder second = new CodexDispatchRecorder();
        MockExtension third = new MockExtension(address(hook));
        first.setGasToBurn(300_000);
        second.setGasToBurn(300_000);
        address[] memory extensions = new address[](3);
        extensions[0] = address(first);
        extensions[1] = address(second);
        extensions[2] = address(third);
        for (uint256 i; i < extensions.length; ++i) {
            _admit(extensions[i]);
            hook.installExtension(key, IHookExtension(extensions[i]), _settings(SWAP_CALLBACKS, true, false));
        }
        // One call needs 766,129 + 80,000 + 2 * 25,000 = 896,129. After two calls of about 350,000 each, the third
        // call needs about 1,546,000.
        _setBudgets(1_400_000);
        for (uint256 i; i < extensions.length; ++i) {
            hook.activateExtension(key, IHookExtension(extensions[i]));
        }
        vm.expectEmit(true, true, false, true, address(first));
        emit CodexDispatchRecorder.CallbackReceived(address(first), CallbackType.BeforeSwap);
        vm.expectEmit(true, true, false, true, address(second));
        emit CodexDispatchRecorder.CallbackReceived(address(second), CallbackType.BeforeSwap);
        _expectSkip(third, CallbackType.BeforeSwap, abi.encodePacked(IKernelHook.GasBudgetExceeded.selector));

        _swapExactInput(key, true, 1e14);

        assertEq(third.callCount(CallbackType.BeforeSwap), 0);
        assertEq(third.callCount(CallbackType.AfterSwap), 0);
    }

    function test_dispatch_revertsWhenRequiredExtensionReverts() public {
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.BeforeSwap, 0, 0, 0, true);
        _expectFailure(
            extension,
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(MockExtension.MockRevert.selector, CallbackType.BeforeSwap)
        );

        _swapExactInput(key, true, 1e14);
    }

    /// @dev The first vault credit costs about 100,000 gas. KernelHook pays it from its own reserve, so an extension
    /// with the smallest gas limit can still return a fee.
    function test_dispatch_settlementDoesNotUseExtensionGasLimit() public {
        _createPool(key);
        _addLiquidity(key);
        NoopExtension extension = new NoopExtension(address(hook), CallbackType.BeforeSwap, 1e10, 0);
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, false, 10_000));

        _swapExactInput(key, true, 1e14);

        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 1e10);
    }

    /// @dev The smallest budget that activation accepts must also let all required extensions run. The setup of the
    /// sequence reads every subscriber (about 10,000 gas each with cold storage) before the first admission check,
    /// so a fixed setup reserve fails with many subscribers: the activation check must count them.
    function test_dispatch_requiredExtensionsRunAtActivationBoundary() public {
        _createPool(key);
        _addLiquidity(key);
        uint256 count = KernelHookConstants.MAX_EXTENSIONS;
        NoopExtension[] memory extensions = new NoopExtension[](count);
        for (uint256 i; i < count; ++i) {
            extensions[i] = new NoopExtension(address(hook), CallbackType.BeforeSwap, 0, 0);
            _admit(address(extensions[i]));
            hook.installExtension(key, extensions[i], _settings(SWAP_CALLBACKS, false, false, 10_000));
        }
        uint256 boundary = KernelHookConstants.RETURN_GAS_RESERVE + KernelHookConstants.SEQUENCE_GAS_RESERVE + count
            * (KernelHookConstants.ITERATION_GAS_RESERVE
                + KernelHookConstants.SUBSCRIBER_GAS_RESERVE
                + KernelHookState.invocationGas(10_000, CallbackType.BeforeSwap));
        // One gas less is refused: the boundary is the smallest budget that activation accepts.
        _setBudgets(uint32(boundary - 1));
        for (uint256 i; i < count - 1; ++i) {
            hook.activateExtension(key, extensions[i]);
        }
        vm.expectRevert(IKernelHook.GasBudgetExceeded.selector);
        hook.activateExtension(key, extensions[count - 1]);
        for (uint256 i; i < count - 1; ++i) {
            hook.deactivateExtension(key, extensions[i]);
        }
        _setBudgets(uint32(boundary));
        for (uint256 i; i < count; ++i) {
            hook.activateExtension(key, extensions[i]);
        }
        // A swap is the first access of the transaction: the setup reads every subscriber from cold storage.
        vm.cool(address(hook));

        _swapExactInput(key, true, 1e14);
    }

    /// @dev KernelHook does not pass the configuration to onCallback, so a callback's gas does not depend on its size.
    /// Before, KernelHook copied it from storage into every call: an 8 KB configuration added more than 25,000 gas
    /// to each call, even with warm storage. Both measured swaps run with warm storage, on the same pool.
    function test_dispatch_callbackGasDoesNotDependOnConfiguration() public {
        _createPool(key);
        _addLiquidity(key);
        NoopExtension extension = new NoopExtension(address(hook), CallbackType.BeforeSwap, 0, 0);
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false, 10_000);
        _installAndActivate(key, address(extension), settings);
        _swapExactInput(key, true, 1e14);
        uint256 start = gasleft();
        _swapExactInput(key, true, 1e14);
        uint256 withoutConfiguration = start - gasleft();

        settings.configuration = new bytes(8192);
        hook.deactivateExtension(key, extension);
        hook.configureExtension(key, extension, settings);
        hook.activateExtension(key, extension);
        _swapExactInput(key, true, 1e14);
        start = gasleft();
        _swapExactInput(key, true, 1e14);
        uint256 withConfiguration = start - gasleft();

        assertApproxEqAbs(withConfiguration, withoutConfiguration, 1000);
    }

    /// @dev The largest measured use of INVOCATION_GAS_RESERVE: an initialization callback has no settlement reserve,
    /// and it also records the completed callback. With cold storage, KernelHook's own work around the call is about
    /// 20,500 gas. The extension uses about 9,500 of the smallest gas limit (10,000), so the work after the call gets
    /// almost no spare gas from it.
    function test_dispatch_reserveCoversColdInitializationCallback() public {
        hook.preparePool(key);
        CodexDispatchRecorder extension = new CodexDispatchRecorder();
        extension.setGasToBurn(6500);
        _installAndActivate(
            key,
            address(extension),
            _settings(CallbackLibrary.INITIALIZATION_CALLBACKS_MASK, false, false, KernelHookConstants.MIN_CALL_GAS)
        );
        // Initialize is the first access of the transaction to KernelHook's storage and to the extension.
        vm.cool(address(hook));
        vm.cool(address(extension));

        vm.expectEmit(true, true, false, true, address(extension));
        emit CodexDispatchRecorder.CallbackReceived(address(extension), CallbackType.BeforeInitialize);
        vm.expectEmit(true, true, false, true, address(extension));
        emit CodexDispatchRecorder.CallbackReceived(address(extension), CallbackType.AfterInitialize);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    /// @dev The dispatch loop delegatecalls KernelHookDispatch.invokeExtension in KernelHook's context. A direct call
    /// runs in the library's own context; Solidity's library call protection rejects it with no data, before the
    /// function's own checks (which would revert with Unauthorized, as the library has no open frame).
    function test_invokeExtension_rejectsDirectCallToTheLibrary() public {
        bytes memory input = abi.encodeWithSelector(
            KernelHookDispatch.invokeExtension.selector,
            uint256(0),
            address(manager),
            address(hook.VAULT()),
            address(1),
            key,
            bytes(""),
            CallbackResult(0, 0, 0)
        );
        (bool success, bytes memory reason) = address(KernelHookDispatch).call(input);
        assertFalse(success);
        assertEq(reason.length, 0);
    }

    /// @dev installationFlags reports an installation without copying its settings, and reports nothing for an
    /// extension that is not installed (also after its removal).
    function test_installationFlags_followInstallActivateAndRemove() public {
        _createPool(key);
        MockExtension extension = new MockExtension(address(hook));
        _assertFlags(address(extension), false, false, false, 0);
        _admit(address(extension));
        hook.installExtension(key, extension, _settings(SWAP_CALLBACKS, true, false));
        _assertFlags(address(extension), true, false, true, SWAP_CALLBACKS);
        hook.activateExtension(key, extension);
        _assertFlags(address(extension), true, true, true, SWAP_CALLBACKS);
        hook.deactivateExtension(key, extension);
        hook.removeExtension(key, extension);
        _assertFlags(address(extension), false, false, false, 0);
    }

    /// @dev The second beforeSwap extension sees the first one's result as its prior result, both in its onCallback
    /// context and in currentContext. The first one sees zero. The remaining specified amount follows from it.
    function test_dispatch_contextCarriesTheResultsOfEarlierExtensions() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension first = new MockExtension(address(hook));
        MockExtension second = new MockExtension(address(hook));
        _admit(address(first));
        _admit(address(second));
        hook.installExtension(key, first, _settings(CallbackType.BeforeSwap.mask(), false, false));
        hook.installExtension(key, second, _settings(CallbackType.BeforeSwap.mask(), false, false));
        hook.activateExtension(key, first);
        hook.activateExtension(key, second);
        first.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(1e10, 0, 0, false, 0));
        second.setExternalCall(CallbackType.BeforeSwap, address(this), abi.encodeCall(this.recordContext, ()));

        _swapExactInput(key, true, 1e14);

        assertEq(abi.encode(first.lastContext().prior), abi.encode(CallbackResult(0, 0, 0)));
        ExecutionContext memory context = second.lastContext();
        assertEq(abi.encode(context.prior), abi.encode(CallbackResult(1e10, 0, 0)));
        assertEq(abi.encode(_recordedContext), abi.encode(context));
        SwapParams memory params = SwapParams(true, -1e14, MIN_PRICE_LIMIT);
        assertEq(BeforeSwapLibrary.remainingAmountSpecified(params, context.prior), -1e14 + 1e10);
        assertEq(context.originExtension, address(0));
        assertEq(PoolId.unwrap(context.originPoolId), bytes32(0));
    }

    ExecutionContext internal _recordedContext;

    /// @notice An extension calls this from inside its callback.
    function recordContext() external {
        _recordedContext = hook.currentContext();
    }

    function _assertFlags(address extension, bool installed, bool active, bool optional, uint16 callbackMask)
        private
        view
    {
        (bool isInstalled, bool isActive, bool isOptional, uint16 mask) = hook.installationFlags(poolId, extension);
        assertEq(isInstalled, installed, "installed");
        assertEq(isActive, active, "active");
        assertEq(isOptional, optional, "optional");
        assertEq(mask, callbackMask, "callback mask");
    }

    /// @dev The extension spends almost all of its 200,000 gas limit. KernelHook's own work before and after the
    /// call uses its reserve, so the call does not run out of gas.
    function test_dispatch_extensionReceivesItsWholeGasLimit() public {
        _createPool(key);
        _addLiquidity(key);
        CodexDispatchRecorder extension = new CodexDispatchRecorder();
        extension.setGasToBurn(190_000);
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, false, 200_000));

        vm.expectEmit(true, true, false, true, address(extension));
        emit CodexDispatchRecorder.CallbackReceived(address(extension), CallbackType.BeforeSwap);
        _swapExactInput(key, true, 1e14);
    }

    function test_dispatch_revertsWhenRequiredCallbackCannotBeForwarded() public {
        // Activation covers the configured limits; the caller must also supply forwarding headroom.
        _swapExtension(false);
        vm.expectRevert(
            _hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector))
        );

        swapRouter.swap{gas: 500_000}(
            key, _exactInputParameters(true, 1e14), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function test_dispatch_skipsOptionalReentryForRestOfNestedOperation() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = new MockExtension(address(hook));
        uint16 callbacks = SWAP_CALLBACKS | CallbackType.BeforeDonate.mask() | CallbackType.AfterDonate.mask();
        _installAndActivate(key, address(extension), _settings(callbacks, true, true, 1_000_000));
        extension.addRouteAction(
            CallbackType.AfterSwap, RouteAction(key, Operation.Donate, abi.encode(uint256(0), uint256(0)), "")
        );
        _expectSkip(extension, CallbackType.BeforeDonate, abi.encodePacked(IKernelHook.ReentrancyDenied.selector));

        _swapExactInput(key, true, 1e14);

        assertEq(extension.callCount(CallbackType.BeforeSwap), 1);
        assertEq(extension.callCount(CallbackType.AfterSwap), 1);
        assertEq(extension.callCount(CallbackType.BeforeDonate), 0);
        assertEq(extension.callCount(CallbackType.AfterDonate), 0);
    }

    /// @dev Two swaps in one transaction (one test is one transaction). The reentry counter of a required extension
    /// that does not support reentrancy must be zero again after each call; a counter that stays set would make its
    /// second callback revert with ReentrancyDenied.
    function test_dispatch_reentryCounterResetsAfterEachCall() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = new MockExtension(address(hook));
        IHookCatalog.Entry memory entry = _entry(address(extension));
        entry.supportsReentrancy = false;
        catalog.admit(address(extension), entry);
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, false));

        _swapExactInput(key, true, 1e14);
        _swapExactInput(key, false, 1e14);

        assertEq(extension.callCount(CallbackType.BeforeSwap), 2);
        assertEq(extension.callCount(CallbackType.AfterSwap), 2);
    }

    function test_dispatch_revertsWhenRequiredReentryIsUnsupported() public {
        // Initialization may seed its own pool, which reaches the extension reentrancy rule.
        hook.preparePool(key);
        MockExtension extension = new MockExtension(address(hook));
        IHookCatalog.Entry memory entry = _entry(address(extension));
        entry.supportsReentrancy = false;
        catalog.admit(address(extension), entry);
        uint16 callbacks = CallbackType.AfterInitialize.mask() | CallbackType.BeforeAddLiquidity.mask();
        hook.installExtension(key, extension, _settings(callbacks, false, true, 1_000_000));
        hook.activateExtension(key, extension);
        extension.addRouteAction(
            CallbackType.AfterInitialize,
            RouteAction(key, Operation.ModifyLiquidity, abi.encode(_liquidityParameters(1)), "")
        );
        bytes memory nestedReason = _hookRevert(
            IHooks.beforeAddLiquidity.selector, abi.encodeWithSelector(IKernelHook.ReentrancyDenied.selector)
        );
        vm.expectRevert(
            _hookRevert(
                IHooks.afterInitialize.selector,
                _failure(extension, CallbackType.AfterInitialize, _prefix(nestedReason))
            )
        );

        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function testFuzz_beforeSwap_revertsWhenDeltaExceedsExactInput(uint128 amount, uint128 excess) public {
        amount = uint128(bound(amount, 1, 1e14));
        excess = uint128(bound(excess, 1, 1e14));
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.BeforeSwap, int128(amount + excess), 0, 0, false);
        _expectFailure(
            extension, CallbackType.BeforeSwap, abi.encodeWithSelector(IKernelHook.DeltaExceedsSwapAmount.selector)
        );

        _swapExactInput(key, true, amount);
    }

    function testFuzz_beforeSwap_revertsWhenDeltaExceedsExactOutput(uint128 amount, uint128 excess) public {
        amount = uint128(bound(amount, 1, 1e14));
        excess = uint128(bound(excess, 1, 1e14));
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.BeforeSwap, 0, -int128(amount + excess), 0, false);
        _expectFailure(
            extension, CallbackType.BeforeSwap, abi.encodeWithSelector(IKernelHook.DeltaExceedsSwapAmount.selector)
        );

        swapRouter.swap(
            key, SwapParams(true, int256(uint256(amount)), MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function test_beforeSwap_revertsWhenStaticPoolReturnsFeeOverride() public {
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.BeforeSwap, 0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | FEE, false);
        _expectFailure(
            extension, CallbackType.BeforeSwap, abi.encodeWithSelector(IKernelHook.InvalidFeeOverride.selector)
        );

        _swapExactInput(key, true, 1e14);
    }

    function testFuzz_beforeSwap_revertsWhenFeeOverrideFlagIsMissing(uint24 fee) public {
        fee = uint24(bound(fee, 1, LPFeeLibrary.MAX_LP_FEE));
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        poolId = key.toId();
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.BeforeSwap, 0, 0, fee, false);
        _expectFailure(
            extension, CallbackType.BeforeSwap, abi.encodeWithSelector(IKernelHook.InvalidFeeOverride.selector)
        );

        _swapExactInput(key, true, 1e14);
    }

    function testFuzz_beforeSwap_revertsWhenOverrideFeeIsTooLarge(uint24 fee) public {
        fee = uint24(bound(fee, LPFeeLibrary.MAX_LP_FEE + 1, LPFeeLibrary.OVERRIDE_FEE_FLAG - 1));
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        poolId = key.toId();
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.BeforeSwap, 0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | fee, false);
        _expectFailure(
            extension, CallbackType.BeforeSwap, abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, fee)
        );

        _swapExactInput(key, true, 1e14);
    }

    function testFuzz_beforeSwap_acceptsValidDynamicFeeOverride(uint24 fee) public {
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        poolId = key.toId();
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.BeforeSwap, 0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | fee, false);

        _swapExactInput(key, true, 1e14);

        assertEq(extension.callCount(CallbackType.BeforeSwap), 1);
    }

    function test_beforeSwap_revertsWhenMultipleExtensionsOverrideFee() public {
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        poolId = key.toId();
        _createPool(key);
        _addLiquidity(key);
        MockExtension first = new MockExtension(address(hook));
        MockExtension second = new MockExtension(address(hook));
        _behavior(first, CallbackType.BeforeSwap, 0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | FEE, false);
        _behavior(second, CallbackType.BeforeSwap, 0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | FEE, false);
        address[] memory extensions = new address[](2);
        extensions[0] = address(first);
        extensions[1] = address(second);
        _installAndActivateAll(key, extensions, _settings(SWAP_CALLBACKS, false, false));
        _expectFailure(
            second, CallbackType.BeforeSwap, abi.encodeWithSelector(IKernelHook.MultipleFeeOverrides.selector)
        );

        _swapExactInput(key, true, 1e14);
    }

    function test_afterSwap_revertsWhenExactInputSpecifiedDeltaIsNonzero() public {
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.AfterSwap, 1, 0, 0, false);
        _expectFailure(extension, CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.InvalidDelta.selector));

        _swapExactInput(key, true, 1e14);
    }

    function test_afterSwap_revertsWhenExactOutputSpecifiedDeltaIsNonzero() public {
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.AfterSwap, 0, -1, 0, false);
        _expectFailure(extension, CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.InvalidDelta.selector));

        swapRouter.swap(key, SwapParams(true, 1e12, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
    }

    function test_afterSwap_revertsWhenFeeOverrideIsNonzero() public {
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.AfterSwap, 0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | FEE, false);
        _expectFailure(
            extension, CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.InvalidFeeOverride.selector)
        );

        _swapExactInput(key, true, 1e14);
    }

    function testFuzz_afterSwap_revertsWhenCombinedUnspecifiedDeltaOverflows(uint128 additional) public {
        additional = uint128(bound(additional, 1, 1e12));
        MockExtension extension = _swapExtension(false);
        // Supply inventory so the first delta reaches settlement before the combined-delta check.
        MockERC20(Currency.unwrap(currency1)).mint(address(manager), uint256(uint128(type(int128).max)));
        _behavior(extension, CallbackType.BeforeSwap, 0, type(int128).max, 0, false);
        _behavior(extension, CallbackType.AfterSwap, 0, int128(additional), 0, false);
        _expectFailure(extension, CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.DeltaOverflow.selector));

        _swapExactInput(key, true, 1e14);
    }

    function testFuzz_afterSwap_revertsWhenCombinedUnspecifiedDeltaUnderflows(uint128 additional) public {
        additional = uint128(bound(additional, 2, 1e12));
        MockExtension extension = _swapExtension(false);
        _fundExtension(extension, currency1, uint256(uint128(type(int128).max)));
        _behavior(extension, CallbackType.BeforeSwap, 0, -type(int128).max, 0, false);
        _behavior(extension, CallbackType.AfterSwap, 0, -int128(additional), 0, false);
        _expectFailure(extension, CallbackType.AfterSwap, abi.encodeWithSelector(IKernelHook.DeltaOverflow.selector));

        _swapExactInput(key, true, 1e14);
    }

    function testFuzz_beforeSwap_positiveDeltaCreditsVault(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1e12));
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.BeforeSwap, int128(amount), 0, 0, false);

        _swapExactInput(key, true, 1e14);

        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), amount);
        assertEq(hook.VAULT().accountedBalance(currency0), amount);
        assertEq(hook.VAULT().fundedCurrencyCount(poolId, address(extension)), 1);
    }

    /// @dev A required extension fills a whole exact-input swap in a pool with no liquidity, while the PoolManager
    /// holds none of the input currency: the credit arrives as claims, so it needs no PoolManager float. Its
    /// payout comes from its deposit; a later withdrawal redeems the claims for the router's payment.
    function testFuzz_beforeSwap_creditNeedsNoPoolManagerFloat(uint128 amountIn, uint128 amountOut) public {
        amountIn = uint128(bound(amountIn, 1, 1e30));
        amountOut = uint128(bound(amountOut, 1, 1e30));
        _createPool(key);
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, false));
        _fundExtension(extension, currency1, amountOut);
        _behavior(extension, CallbackType.BeforeSwap, int128(amountIn), -int128(amountOut), 0, false);
        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        assertEq(token0.balanceOf(address(manager)), 0, "no float");

        BalanceDelta delta = _swapExactInput(key, true, amountIn);

        assertEq(delta.amount0(), -int128(amountIn));
        assertEq(delta.amount1(), int128(amountOut));
        KernelHookVault vault = hook.VAULT();
        assertEq(vault.balanceOf(poolId, address(extension), currency0), amountIn);
        assertEq(manager.balanceOf(address(vault), currency0.toId()), amountIn, "credit held as claims");
        vm.prank(address(extension));
        vault.withdraw(poolId, currency0, amountIn, address(0xBEEF));
        assertEq(token0.balanceOf(address(0xBEEF)), amountIn);
        assertEq(token0.balanceOf(address(manager)), 0);
    }

    function testFuzz_beforeSwap_mapsSpecifiedCurrencyForSwapDirection(bool zeroForOne, bool exactInput, uint128 amount)
        public
    {
        amount = uint128(bound(amount, 1, 1e10));
        MockExtension extension = _swapExtension(false);
        bool specifiedIsCurrency0 = exactInput == zeroForOne;
        _behavior(
            extension,
            CallbackType.BeforeSwap,
            specifiedIsCurrency0 ? int128(amount) : int128(0),
            specifiedIsCurrency0 ? int128(0) : int128(amount),
            0,
            false
        );
        SwapParams memory params = SwapParams(
            zeroForOne, exactInput ? -int256(1e14) : int256(1e14), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        );

        swapRouter.swap(key, params, PoolSwapTest.TestSettings(false, false), "");

        assertEq(
            hook.VAULT().balanceOf(poolId, address(extension), specifiedIsCurrency0 ? currency0 : currency1), amount
        );
    }

    function testFuzz_beforeSwap_negativeDeltaSpendsVaultBalance(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1e12));
        MockExtension extension = _swapExtension(false);
        _fundExtension(extension, currency0, amount);
        _behavior(extension, CallbackType.BeforeSwap, -int128(amount), 0, 0, false);

        _swapExactInput(key, true, 1e14);

        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 0);
        assertEq(hook.VAULT().accountedBalance(currency0), 0);
        assertEq(hook.VAULT().fundedCurrencyCount(poolId, address(extension)), 0);
    }

    function testFuzz_beforeSwap_revertsWhenVaultBalanceIsInsufficient(uint128 balance, uint128 extra) public {
        balance = uint128(bound(balance, 0, 1e12));
        extra = uint128(bound(extra, 1, 1e12));
        MockExtension extension = _swapExtension(false);
        _fundExtension(extension, currency0, balance);
        _behavior(extension, CallbackType.BeforeSwap, -int128(balance + extra), 0, 0, false);
        _expectFailure(
            extension, CallbackType.BeforeSwap, abi.encodeWithSelector(KernelHookVault.InsufficientBalance.selector)
        );

        _swapExactInput(key, true, 1e14);
    }

    function testFuzz_afterSwap_unspecifiedDeltaCreditsVault(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1e10));
        MockExtension extension = _swapExtension(false);
        _behavior(extension, CallbackType.AfterSwap, 0, int128(amount), 0, false);

        _swapExactInput(key, true, 1e14);

        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency1), amount);
    }

    function test_afterAddLiquidity_acceptsDeltasInBothCurrencies() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(CallbackType.AfterAddLiquidity, false);
        _behavior(extension, CallbackType.AfterAddLiquidity, 100, 200, 0, false);

        _addLiquidity(key);

        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 100);
        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency1), 200);
    }

    function test_afterRemoveLiquidity_acceptsDeltasInBothCurrencies() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(CallbackType.AfterRemoveLiquidity, false);
        _behavior(extension, CallbackType.AfterRemoveLiquidity, 100, 200, 0, false);

        _removeLiquidity(key);

        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 100);
        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency1), 200);
    }

    function testFuzz_afterAddLiquidity_negativeDeltaSpendsVaultBalance(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1e12));
        _createPool(key);
        MockExtension extension = _installed(CallbackType.AfterAddLiquidity, false);
        _fundExtension(extension, currency0, amount);
        _fundExtension(extension, currency1, amount);
        _behavior(extension, CallbackType.AfterAddLiquidity, -int128(amount), -int128(amount), 0, false);

        _addLiquidity(key);

        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 0);
        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency1), 0);
        assertEq(hook.VAULT().fundedCurrencyCount(poolId, address(extension)), 0);
    }

    function testFuzz_afterRemoveLiquidity_negativeDeltaSpendsVaultBalance(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1e12));
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(CallbackType.AfterRemoveLiquidity, false);
        _fundExtension(extension, currency0, amount);
        _fundExtension(extension, currency1, amount);
        _behavior(extension, CallbackType.AfterRemoveLiquidity, -int128(amount), -int128(amount), 0, false);

        _removeLiquidity(key);

        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 0);
        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency1), 0);
        assertEq(hook.VAULT().fundedCurrencyCount(poolId, address(extension)), 0);
    }

    function test_afterAddLiquidity_revertsWhenFeeOverrideIsNonzero() public {
        _createPool(key);
        MockExtension extension = _installed(CallbackType.AfterAddLiquidity, false);
        _behavior(extension, CallbackType.AfterAddLiquidity, 0, 0, 1, false);
        _expectFailure(
            extension, CallbackType.AfterAddLiquidity, abi.encodeWithSelector(IKernelHook.InvalidFeeOverride.selector)
        );

        _addLiquidity(key);
    }

    function test_beforeInitialize_revertsWhenDeltaIsNonzero() public {
        _expectInvalidInitializationDelta(CallbackType.BeforeInitialize, 1, 0);
    }

    function test_afterInitialize_revertsWhenDeltaIsNonzero() public {
        _expectInvalidInitializationDelta(CallbackType.AfterInitialize, 0, 1);
    }

    function test_beforeDonate_revertsWhenDeltaIsNonzero() public {
        _expectInvalidOperationDelta(CallbackType.BeforeDonate, 1, 0);
    }

    function test_afterDonate_revertsWhenDeltaIsNonzero() public {
        _expectInvalidOperationDelta(CallbackType.AfterDonate, 0, 1);
    }

    function test_beforeAddLiquidity_revertsWhenDeltaIsNonzero() public {
        _expectInvalidOperationDelta(CallbackType.BeforeAddLiquidity, 1, 0);
    }

    function test_beforeRemoveLiquidity_revertsWhenDeltaIsNonzero() public {
        _expectInvalidOperationDelta(CallbackType.BeforeRemoveLiquidity, 0, 1);
    }

    function test_beforeInitialize_suppliesContextAndCallbackData() public {
        MockExtension extension = _initializeWith(CallbackType.BeforeInitialize);
        _assertContext(extension, CallbackType.BeforeInitialize, address(this), 1);
        assertEq(extension.lastCallbackDataHash(), keccak256(abi.encode(SQRT_PRICE_1_1)));
    }

    function test_afterInitialize_suppliesContextAndCallbackData() public {
        MockExtension extension = _initializeWith(CallbackType.AfterInitialize);
        _assertContext(extension, CallbackType.AfterInitialize, address(this), 1);
        assertEq(extension.lastCallbackDataHash(), keccak256(abi.encode(SQRT_PRICE_1_1, int24(0))));
    }

    function test_beforeSwap_suppliesContextAndCallbackData() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(CallbackType.BeforeSwap, false);
        _swapExactInput(key, true, 1e14);
        _assertContext(extension, CallbackType.BeforeSwap, address(swapRouter), 3);
        assertEq(extension.lastCallbackDataHash(), keccak256(abi.encode(_exactInputParameters(true, 1e14), bytes(""))));
    }

    function test_afterSwap_suppliesContextAndCallbackData() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(CallbackType.AfterSwap, false);
        BalanceDelta delta = _swapExactInput(key, true, 1e14);
        _assertContext(extension, CallbackType.AfterSwap, address(swapRouter), 3);
        assertEq(
            extension.lastCallbackDataHash(), keccak256(abi.encode(_exactInputParameters(true, 1e14), delta, bytes("")))
        );
    }

    function test_beforeAddLiquidity_suppliesContextAndCallbackData() public {
        _createPool(key);
        MockExtension extension = _installed(CallbackType.BeforeAddLiquidity, false);
        _addLiquidity(key);
        _assertContext(extension, CallbackType.BeforeAddLiquidity, address(modifyLiquidityRouter), 2);
        assertEq(extension.lastCallbackDataHash(), keccak256(abi.encode(_liquidityParameters(1e18), bytes(""))));
    }

    function test_afterAddLiquidity_suppliesContextAndCallbackData() public {
        _createPool(key);
        MockExtension extension = _installed(CallbackType.AfterAddLiquidity, false);
        BalanceDelta delta = _addLiquidity(key);
        _assertContext(extension, CallbackType.AfterAddLiquidity, address(modifyLiquidityRouter), 2);
        assertEq(
            extension.lastCallbackDataHash(),
            keccak256(abi.encode(_liquidityParameters(1e18), delta, BalanceDelta.wrap(0), bytes("")))
        );
    }

    function test_beforeRemoveLiquidity_suppliesContextAndCallbackData() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(CallbackType.BeforeRemoveLiquidity, false);
        _removeLiquidity(key);
        _assertContext(extension, CallbackType.BeforeRemoveLiquidity, address(modifyLiquidityRouter), 3);
        assertEq(extension.lastCallbackDataHash(), keccak256(abi.encode(_liquidityParameters(-1e18), bytes(""))));
    }

    function test_afterRemoveLiquidity_suppliesContextAndCallbackData() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(CallbackType.AfterRemoveLiquidity, false);
        BalanceDelta delta = _removeLiquidity(key);
        _assertContext(extension, CallbackType.AfterRemoveLiquidity, address(modifyLiquidityRouter), 3);
        assertEq(
            extension.lastCallbackDataHash(),
            keccak256(abi.encode(_liquidityParameters(-1e18), delta, BalanceDelta.wrap(0), bytes("")))
        );
    }

    function test_beforeDonate_suppliesContextAndCallbackData() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(CallbackType.BeforeDonate, false);
        donateRouter.donate(key, 100, 200, "data");
        _assertContext(extension, CallbackType.BeforeDonate, address(donateRouter), 3);
        assertEq(extension.lastCallbackDataHash(), keccak256(abi.encode(uint256(100), uint256(200), bytes("data"))));
    }

    function test_afterDonate_suppliesContextAndCallbackData() public {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(CallbackType.AfterDonate, false);
        donateRouter.donate(key, 100, 200, "data");
        _assertContext(extension, CallbackType.AfterDonate, address(donateRouter), 3);
        assertEq(extension.lastCallbackDataHash(), keccak256(abi.encode(uint256(100), uint256(200), bytes("data"))));
    }

    function test_initialize_completesRequiredInitializationCallbacks() public {
        hook.preparePool(key);
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(
            key, address(extension), _settings(CallbackLibrary.INITIALIZATION_CALLBACKS_MASK, false, false)
        );
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.deactivateExtension(key, extension);

        hook.activateExtension(key, extension);

        assertEq(extension.callCount(CallbackType.BeforeInitialize), 1);
        assertEq(extension.callCount(CallbackType.AfterInitialize), 1);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }

    function test_initialize_inactiveSubscriberRemainsIncomplete() public {
        hook.preparePool(key);
        MockExtension extension = new MockExtension(address(hook));
        _admit(address(extension));
        hook.installExtension(key, extension, _settings(CallbackLibrary.INITIALIZATION_CALLBACKS_MASK, false, false));
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InitializationCallbacksIncomplete.selector));

        hook.activateExtension(key, extension);
    }

    function test_initialize_skippedCallbackIsNotMarkedComplete() public {
        hook.preparePool(key);
        MockExtension extension = new MockExtension(address(hook));
        _behavior(extension, CallbackType.BeforeInitialize, 0, 0, 0, true);
        _installAndActivate(
            key, address(extension), _settings(CallbackLibrary.INITIALIZATION_CALLBACKS_MASK, true, false)
        );
        manager.initialize(key, SQRT_PRICE_1_1);
        hook.deactivateExtension(key, extension);
        hook.configureExtension(key, extension, _settings(CallbackLibrary.INITIALIZATION_CALLBACKS_MASK, false, false));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InitializationCallbacksIncomplete.selector));

        hook.activateExtension(key, extension);
    }

    function _swapExtension(bool optional) internal returns (MockExtension extension) {
        _createPool(key);
        _addLiquidity(key);
        extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, optional, false));
    }

    function _installed(CallbackType callback, bool optional) internal returns (MockExtension extension) {
        extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(callback.mask(), optional, false));
    }

    function _initializeWith(CallbackType callback) internal returns (MockExtension extension) {
        hook.preparePool(key);
        extension = _installed(callback, false);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function _behavior(
        MockExtension extension,
        CallbackType callback,
        int128 delta0,
        int128 delta1,
        uint24 fee,
        bool reverts_
    ) internal {
        extension.setBehavior(callback, MockExtension.Behavior(delta0, delta1, fee, reverts_, 0));
    }

    function _expectSkip(MockExtension extension, CallbackType callback, bytes memory reason) internal {
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(poolId, address(extension), callback, reason);
    }

    function _failure(MockExtension extension, CallbackType callback, bytes memory reason)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(IKernelHook.ExtensionFailed.selector, address(extension), callback, reason);
    }

    function _expectFailure(MockExtension extension, CallbackType callback, bytes memory reason) internal {
        vm.expectRevert(_hookRevert(_selector(callback), _failure(extension, callback, reason)));
    }

    function _selector(CallbackType callback) internal pure returns (bytes4) {
        if (callback == CallbackType.BeforeInitialize) return IHooks.beforeInitialize.selector;
        if (callback == CallbackType.AfterInitialize) return IHooks.afterInitialize.selector;
        if (callback == CallbackType.BeforeSwap) return IHooks.beforeSwap.selector;
        if (callback == CallbackType.AfterSwap) return IHooks.afterSwap.selector;
        if (callback == CallbackType.BeforeAddLiquidity) return IHooks.beforeAddLiquidity.selector;
        if (callback == CallbackType.AfterAddLiquidity) return IHooks.afterAddLiquidity.selector;
        if (callback == CallbackType.BeforeRemoveLiquidity) return IHooks.beforeRemoveLiquidity.selector;
        if (callback == CallbackType.AfterRemoveLiquidity) return IHooks.afterRemoveLiquidity.selector;
        if (callback == CallbackType.BeforeDonate) return IHooks.beforeDonate.selector;
        return IHooks.afterDonate.selector;
    }

    function _setBudgets(uint32 amount) internal {
        uint32[CALLBACK_COUNT] memory budgets;
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = amount;
        }
        hook.setExecutionLimits(key, 4, budgets);
    }

    function _fundExtension(MockExtension extension, Currency currency, uint256 amount) internal {
        MockERC20(Currency.unwrap(currency)).mint(address(extension), amount);
        extension.deposit(poolId, currency, amount);
    }

    function _entry(address extension) internal view returns (IHookCatalog.Entry memory) {
        return IHookCatalog.Entry(extension.codehash, CallbackLibrary.ALL_CALLBACKS_MASK, true, true, true, true, true);
    }

    function _prefix(bytes memory data) internal pure returns (bytes memory prefix) {
        uint256 length = data.length > 256 ? 256 : data.length;
        prefix = new bytes(length);
        for (uint256 i; i < length; ++i) {
            prefix[i] = data[i];
        }
    }

    function _expectInvalidInitializationDelta(CallbackType callback, int128 delta0, int128 delta1) internal {
        hook.preparePool(key);
        MockExtension extension = _installed(callback, false);
        _behavior(extension, callback, delta0, delta1, 0, false);
        _expectFailure(extension, callback, abi.encodeWithSelector(IKernelHook.InvalidDelta.selector));
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function _expectInvalidOperationDelta(CallbackType callback, int128 delta0, int128 delta1) internal {
        _createPool(key);
        _addLiquidity(key);
        MockExtension extension = _installed(callback, false);
        _behavior(extension, callback, delta0, delta1, 0, false);
        _expectFailure(extension, callback, abi.encodeWithSelector(IKernelHook.InvalidDelta.selector));
        if (callback == CallbackType.BeforeAddLiquidity) _addLiquidity(key);
        else if (callback == CallbackType.BeforeRemoveLiquidity) _removeLiquidity(key);
        else donateRouter.donate(key, 100, 200, "");
    }

    function _assertContext(MockExtension extension, CallbackType callback, address sender, uint64 operationId)
        internal
        view
    {
        ExecutionContext memory context = extension.lastContext();
        assertEq(context.rootOperationId, operationId);
        assertEq(PoolId.unwrap(context.rootPoolId), PoolId.unwrap(poolId));
        assertEq(PoolId.unwrap(context.poolId), PoolId.unwrap(poolId));
        assertEq(context.sender, sender);
        assertEq(context.extension, address(extension));
        assertEq(uint8(context.callback), uint8(callback));
        assertEq(context.depth, 1);
        assertEq(hook.currentContext().depth, 0);
    }
}
