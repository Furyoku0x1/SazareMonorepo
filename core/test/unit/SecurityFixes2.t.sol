// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";
import {KernelHookDispatch} from "../../src/libraries/KernelHookDispatch.sol";
import {CallbackLibrary} from "../../src/libraries/CallbackLibrary.sol";
import {CallbackType, Operation, RouteAction} from "../../src/types/KernelHookTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Models both a hand-written pending-sync router and the periphery's atomic payment flow.
contract SyncRegressionRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    IPoolManager immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, Currency pending, uint256 prepaid)
        external
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, params, pending, prepaid, false)), (BalanceDelta));
    }

    function swapAfterPayment(PoolKey memory key, SwapParams memory params, Currency currency, uint256 prepaid)
        external
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, params, currency, prepaid, true)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (
            address payer,
            PoolKey memory key,
            SwapParams memory params,
            Currency pending,
            uint256 prepaid,
            bool settleBefore
        ) = abi.decode(data, (address, PoolKey, SwapParams, Currency, uint256, bool));
        if (!pending.isAddressZero()) {
            manager.sync(pending);
            if (prepaid != 0) MockERC20(Currency.unwrap(pending)).transferFrom(payer, address(manager), prepaid);
        }
        if (settleBefore) manager.settle();
        BalanceDelta delta = manager.swap(key, params, "");
        if (prepaid != 0 && !settleBefore) manager.settle();
        _settle(key.currency0, payer);
        _settle(key.currency1, payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, address payer) private {
        int256 amount = manager.currencyDelta(address(this), currency);
        if (amount < 0) {
            manager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-amount));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(amount));
        }
    }
}

contract Round2SecurityTest is KernelHookFixture {
    using CallbackLibrary for CallbackType;
    using TransientStateLibrary for IPoolManager;
    PoolKey internal key;
    SyncRegressionRouter internal router;
    MockERC20 internal unrelated;

    function setUp() public override {
        super.setUp();
        key = _poolKey();
        _createPool(key);
        _addLiquidity(key);
        router = new SyncRegressionRouter(manager);
        unrelated = new MockERC20("Unrelated", "U", 18);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    // R2-K-2: no Kernel operation may start while an ERC20 sync is pending.
    function test_pendingSyncUsedCurrencyRevertsAtRootSwapStart() public {
        _assertRootSyncRefusal(currency0);
    }

    function test_pendingSyncUnrelatedCurrencyRevertsAtRootSwapStart() public {
        _assertRootSyncRefusal(Currency.wrap(address(unrelated)));
    }

    function _assertRootSyncRefusal(Currency pending) internal {
        MockExtension extension = _extension(key, SWAP_CALLBACKS, true, false, 500_000);
        vm.expectRevert(
            _hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(IKernelHook.SyncPending.selector))
        );
        router.swap(key, _exactInputParameters(true, 1e14), pending, 0);
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
        _swapExactInput(key, true, 1e14);
        assertEq(extension.callCount(CallbackType.BeforeSwap), 1);
    }

    function test_routerSettlingPaymentBeforeSwapWorks() public {
        MockExtension payer = _extension(key, CallbackType.BeforeSwap.mask(), true, false, 500_000);
        MockERC20(Currency.unwrap(currency1)).mint(address(payer), 1000);
        payer.deposit(key.toId(), currency1, 1000);
        payer.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(0, -100, 0, false, 0));
        router.swapAfterPayment(key, _exactInputParameters(true, 1e14), currency0, 1e14);
        assertEq(payer.callCount(CallbackType.BeforeSwap), 1);
        assertEq(hook.VAULT().balanceOf(key.toId(), address(payer), currency1), 900);
        assertEq(manager.currencyDelta(address(router), currency0), 0);
        assertEq(Currency.unwrap(manager.getSyncedCurrency()), address(0));
    }

    function test_pendingSyncClaimsOnlyPaymentStillWorks() public {
        MockExtension payer = _extension(key, CallbackType.BeforeSwap.mask(), true, false, 500_000);
        payer.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(0, 1000, 0, false, 0));
        _swapExactInput(key, true, 1e14);
        // Direct authorized vault settlement is reachable without starting another Kernel operation.
        manager.unlock(abi.encode(address(payer)));
        assertEq(hook.VAULT().balanceOf(key.toId(), address(payer), currency1), 900);
        assertEq(manager.balanceOf(address(hook.VAULT()), currency1.toId()), 900);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        address payer = abi.decode(data, (address));
        manager.sync(Currency.wrap(address(unrelated)));
        uint256 reserves = manager.getSyncedReserves();
        vm.prank(address(hook));
        manager.take(currency1, address(this), 100);
        KernelHookVault vault = hook.VAULT();
        vm.prank(address(hook));
        uint256 fromClaims = vault.settleDebtFor(key.toId(), payer, currency1, 100, address(hook));
        assertEq(fromClaims, 100);
        vm.prank(address(hook));
        manager.burn(address(vault), currency1.toId(), fromClaims);
        assertEq(Currency.unwrap(manager.getSyncedCurrency()), address(unrelated));
        assertEq(manager.getSyncedReserves(), reserves);
        return "";
    }

    function testFuzz_pendingSyncAtNestedOperationStartFailsOnlyOriginAttempt(uint8 operation, bool samePool) public {
        operation = uint8(bound(operation, 0, 2));
        PoolKey memory target = key;
        if (!samePool) {
            target.tickSpacing = 20;
            _createPool(target);
            _addLiquidity(target);
        }
        MockExtension origin = new MockExtension(address(hook));
        _admit(address(origin));
        hook.installExtension(key, origin, _settings(CallbackType.AfterSwap.mask(), true, true, 1_500_000));
        MockExtension later = new MockExtension(address(hook));
        _admit(address(later));
        hook.installExtension(key, later, _settings(CallbackType.AfterSwap.mask(), false, false, 500_000));
        // Required subscribers must precede optional ones.
        address[] memory order = new address[](2);
        order[0] = address(later);
        order[1] = address(origin);
        hook.setCallbackOrder(key, CallbackType.AfterSwap, order);
        hook.activateExtension(key, later);
        hook.activateExtension(key, origin);
        MockERC20(Currency.unwrap(currency0)).mint(address(origin), 1000);
        origin.deposit(key.toId(), currency0, 1000);
        origin.setExternalCall(CallbackType.AfterSwap, address(this), abi.encodeCall(this.syncUnrelated, ()));
        RouteAction memory action;
        bytes4 selector;
        if (operation == 0) {
            action = RouteAction(target, Operation.Swap, abi.encode(_exactInputParameters(true, 100)), "");
            selector = IHooks.beforeSwap.selector;
        } else if (operation == 1) {
            action = RouteAction(target, Operation.ModifyLiquidity, abi.encode(_liquidityParameters(100)), "");
            selector = IHooks.beforeAddLiquidity.selector;
        } else {
            action = RouteAction(target, Operation.Donate, abi.encode(uint256(100), uint256(0)), "");
            selector = IHooks.beforeDonate.selector;
        }
        origin.addRouteAction(CallbackType.AfterSwap, action);
        _expectSkip(origin, CallbackType.AfterSwap, _nestedSyncRevert(selector));
        _swapExactInput(key, true, 1e14);
        assertEq(origin.callCount(CallbackType.AfterSwap), 0);
        assertEq(later.callCount(CallbackType.AfterSwap), 1);
        assertEq(hook.VAULT().balanceOf(key.toId(), address(origin), currency0), 1000);
        assertEq(hook.ticketCount(), 0);
        assertEq(Currency.unwrap(manager.getSyncedCurrency()), address(0));
    }

    function test_emptyExtensionRevertAtCapSkipsAsOwnFailure() public {
        MockExtension extension = _extension(key, SWAP_CALLBACKS, true, false, 500_000);
        extension.setExternalCall(CallbackType.BeforeSwap, address(this), abi.encodeCall(this.emptyRevert, ()));
        _expectSkip(extension, CallbackType.BeforeSwap, "");
        swapRouter.swap(
            key, _exactInputParameters(true, 1e14), PoolSwapTest.TestSettings(false, false), new bytes(8192)
        );
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
    }

    function emptyRevert() external pure {
        assembly ("memory-safe") { revert(0, 0) }
    }

    function test_pendingSyncInitializationRevertsAtStart() public {
        PoolKey memory preparing = key;
        preparing.tickSpacing = 20;
        hook.preparePool(preparing);
        vm.expectRevert(
            _hookRevert(IHooks.beforeInitialize.selector, abi.encodeWithSelector(IKernelHook.SyncPending.selector))
        );
        this.initializeWithPendingSync(preparing);
    }

    function test_pendingSyncInitializationSeedFailsOnlyOriginAttempt() public {
        PoolKey memory preparing = key;
        preparing.tickSpacing = 20;
        hook.preparePool(preparing);
        MockExtension origin = new MockExtension(address(hook));
        _admit(address(origin));
        hook.installExtension(preparing, origin, _settings(CallbackType.AfterInitialize.mask(), true, true, 1_500_000));
        hook.activateExtension(preparing, origin);
        origin.setExternalCall(CallbackType.AfterInitialize, address(this), abi.encodeCall(this.syncUnrelated, ()));
        origin.addRouteAction(
            CallbackType.AfterInitialize,
            RouteAction(preparing, Operation.ModifyLiquidity, abi.encode(_liquidityParameters(100)), "")
        );
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            preparing.toId(),
            address(origin),
            CallbackType.AfterInitialize,
            _nestedSyncRevert(IHooks.beforeAddLiquidity.selector)
        );
        manager.initialize(preparing, SQRT_PRICE_1_1);
        assertTrue(hook.isPoolInitialized(preparing.toId()));
        assertEq(origin.callCount(CallbackType.AfterInitialize), 0);
        assertEq(hook.ticketCount(), 0);
    }

    function test_pendingSyncUnwindActionRevertsAtStart() public {
        MockExtension origin = _extension(key, CallbackType.AfterSwap.mask(), true, true, 1_500_000);
        hook.deactivateExtension(key, origin);
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = RouteAction(key, Operation.ModifyLiquidity, abi.encode(_liquidityParameters(0)), "");
        vm.expectRevert(
            _hookRevert(IHooks.beforeRemoveLiquidity.selector, abi.encodeWithSelector(IKernelHook.SyncPending.selector))
        );
        this.unwindWithPendingSync(origin, actions);
    }

    function initializeWithPendingSync(PoolKey memory preparing) external {
        manager.sync(Currency.wrap(address(unrelated)));
        manager.initialize(preparing, SQRT_PRICE_1_1);
    }

    function unwindWithPendingSync(MockExtension origin, RouteAction[] calldata actions) external {
        manager.sync(Currency.wrap(address(unrelated)));
        origin.unwindPositions(key, actions);
    }

    function _nestedSyncRevert(bytes4 selector) internal view returns (bytes memory reason) {
        reason = _hookRevert(selector, abi.encodeWithSelector(IKernelHook.SyncPending.selector));
        // Extension revert data is bounded to 256 bytes; the PoolManager wrapper is 260 bytes.
        assembly ("memory-safe") { mstore(reason, 256) }
    }

    // F1b and R2-K-9 sync: this attempt rolls back, without contaminating any later callback.
    function test_extensionLeavingSyncFailsItsOwnAttempt() public {
        MockExtension first = new MockExtension(address(hook));
        MockExtension second = new MockExtension(address(hook));
        _admit(address(first));
        _admit(address(second));
        hook.installExtension(key, first, _settings(CallbackType.BeforeSwap.mask(), true, false));
        hook.installExtension(key, second, _settings(CallbackType.AfterSwap.mask(), false, false));
        hook.activateExtension(key, first);
        hook.activateExtension(key, second);
        first.setExternalCall(CallbackType.BeforeSwap, address(this), abi.encodeCall(this.syncUnrelated, ()));
        MockERC20(Currency.unwrap(currency1)).mint(address(second), 1000);
        second.deposit(key.toId(), currency1, 1000);
        second.setBehavior(CallbackType.AfterSwap, MockExtension.Behavior(0, -100, 0, false, 0));
        _expectSkip(first, CallbackType.BeforeSwap, abi.encodeWithSelector(IKernelHook.UnexpectedAccounting.selector));
        _swapExactInput(key, true, 1e14);
        assertEq(first.callCount(CallbackType.BeforeSwap), 0);
        assertEq(second.callCount(CallbackType.AfterSwap), 1);
    }

    function syncUnrelated() external {
        manager.sync(Currency.wrap(address(unrelated)));
    }

    // R2-K-1: the F2/KB size sweeps and F2b/c/d all fail at operation entry, never skip.
    function testFuzz_hookDataOverCapRejectedBeforeOptionalAttempt(uint32 size) public {
        size = uint32(bound(size, 8193, 500_000));
        MockExtension extension = _extension(key, SWAP_CALLBACKS, true, false, 2_500_000);
        vm.expectRevert(
            _hookRevert(IHooks.beforeSwap.selector, abi.encodeWithSelector(IKernelHook.HookDataTooLarge.selector))
        );
        swapRouter.swap(
            key, _exactInputParameters(true, 1e14), PoolSwapTest.TestSettings(false, false), new bytes(size)
        );
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
    }

    function test_hookDataAtCapFitsHeavyOptionalBeforeAndAfterAttempts() public {
        MockExtension extension = _extension(key, SWAP_CALLBACKS, true, false, 500_000);
        extension.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(1e12, 0, 0, false, 250_000));
        extension.setBehavior(CallbackType.AfterSwap, MockExtension.Behavior(0, 100, 0, false, 250_000));
        swapRouter.swap(
            key, _exactInputParameters(true, 1e14), PoolSwapTest.TestSettings(false, false), new bytes(8192)
        );
        assertEq(extension.callCount(CallbackType.BeforeSwap), 1);
        assertEq(extension.callCount(CallbackType.AfterSwap), 1);
        assertEq(hook.VAULT().balanceOf(key.toId(), address(extension), currency0), 1e12);
        assertEq(hook.VAULT().balanceOf(key.toId(), address(extension), currency1), 100);
    }

    // R2-K-4 / F3: keep ordinary revert reasons, rewrite just the forged gas sentinel.
    function test_optionalForgedGasSignalSkipsInsteadOfRevertingSwap() public {
        MockExtension extension = _extension(key, SWAP_CALLBACKS, true, false, 500_000);
        extension.setExternalCall(CallbackType.BeforeSwap, address(this), abi.encodeCall(this.forgeGasSignal, ()));
        _expectSkip(
            extension, CallbackType.BeforeSwap, abi.encodeWithSelector(KernelHookDispatch.ExtensionGasSignal.selector)
        );
        _swapExactInput(key, true, 1e14);
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
        assertEq(extension.callCount(CallbackType.AfterSwap), 0);
    }

    function forgeGasSignal() external pure {
        revert KernelHookDispatch.InsufficientCallbackGas();
    }

    // R2-K-6 / F4: directional protocol fee plus 999,999 LP fee is a full combined fee.
    function testFuzz_exactOutputRejectsFullCombinedFee(bool zeroForOne) public {
        PoolKey memory dynamicKey = key;
        dynamicKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _createPool(dynamicKey);
        _addLiquidity(dynamicKey);
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(dynamicKey, zeroForOne ? 1 : (1 << 12));
        MockExtension extension = _extension(dynamicKey, CallbackType.BeforeSwap.mask(), true, false, 500_000);
        extension.setBehavior(
            CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | 999_999, false, 0)
        );
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            dynamicKey.toId(),
            address(extension),
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(IKernelHook.InvalidFeeOverride.selector)
        );
        swapRouter.swap(
            dynamicKey,
            SwapParams(zeroForOne, 1e14, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(extension.callCount(CallbackType.BeforeSwap), 0);
    }

    // R2-K-5 / F5: configuration rejects unsafe order; a safe order gives the required fee priority.
    function test_feeConflictRequiredRunsFirstAndOptionalRollsBack() public {
        PoolKey memory dynamicKey = key;
        dynamicKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _createPool(dynamicKey);
        _addLiquidity(dynamicKey);
        MockExtension optional = new MockExtension(address(hook));
        MockExtension required = new MockExtension(address(hook));
        _admit(address(optional));
        _admit(address(required));
        hook.installExtension(dynamicKey, optional, _settings(SWAP_CALLBACKS, true, false));
        hook.installExtension(dynamicKey, required, _settings(SWAP_CALLBACKS, false, false));
        address[] memory order = new address[](2);
        order[0] = address(required);
        order[1] = address(optional);
        hook.setCallbackOrder(dynamicKey, CallbackType.BeforeSwap, order);
        hook.setCallbackOrder(dynamicKey, CallbackType.AfterSwap, order);
        hook.activateExtension(dynamicKey, optional);
        hook.activateExtension(dynamicKey, required);
        optional.setBehavior(
            CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | 3000, false, 0)
        );
        required.setBehavior(
            CallbackType.BeforeSwap, MockExtension.Behavior(0, 0, LPFeeLibrary.OVERRIDE_FEE_FLAG | 5000, false, 0)
        );
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(
            dynamicKey.toId(),
            address(optional),
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(IKernelHook.MultipleFeeOverrides.selector)
        );
        _swapExactInput(dynamicKey, true, 1e14);
        assertEq(required.callCount(CallbackType.BeforeSwap), 1);
        assertEq(optional.callCount(CallbackType.BeforeSwap), 0);
    }

    function testFuzz_swapOrderChangesRejectOptionalBeforeRequired(bool afterSwap) public {
        CallbackType callback = afterSwap ? CallbackType.AfterSwap : CallbackType.BeforeSwap;
        MockExtension required = _extension(key, callback.mask(), false, false, 500_000);
        hook.deactivateExtension(key, required);
        MockExtension optional = _extension(key, callback.mask(), true, false, 500_000);
        hook.deactivateExtension(key, optional);
        address[] memory order = new address[](2);
        order[0] = address(optional);
        order[1] = address(required);
        vm.expectRevert(IKernelHook.InvalidCallbackOrder.selector);
        hook.setCallbackOrder(key, callback, order);
    }

    function test_swapMaskChangeCannotAppendRequiredAfterOptional() public {
        MockExtension required = _extension(key, CallbackType.AfterDonate.mask(), false, false, 500_000);
        hook.deactivateExtension(key, required);
        MockExtension optional = _extension(key, CallbackType.BeforeSwap.mask(), true, false, 500_000);
        hook.deactivateExtension(key, optional);
        hook.configureExtension(key, required, _settings(CallbackType.BeforeSwap.mask(), false, false));
        address[] memory order = hook.callbackOrder(key.toId(), CallbackType.BeforeSwap);
        assertEq(order[0], address(required));
        assertEq(order[1], address(optional));
    }

    // R2-K-7: activating a later subscriber must recheck the already-active subscriber.
    function test_activationRechecksActiveCoSubscriber() public {
        MockExtension first = new MockExtension(address(hook));
        MockExtension second = new MockExtension(address(hook));
        _admit(address(first));
        _admit(address(second));
        hook.installExtension(key, first, _settings(SWAP_CALLBACKS, true, false));
        hook.installExtension(key, second, _settings(SWAP_CALLBACKS, true, false, 3_000_000));
        hook.activateExtension(key, first);
        // Stand-in for a book rejecting the resulting active set after the new callback becomes active.
        first.setLifecycle(false, true, false);
        vm.expectRevert(IKernelHook.ActivationRejected.selector);
        hook.activateExtension(key, second);
        (bool active,,) = hook.extensionConfiguration(key.toId(), address(second));
        assertFalse(active);
    }

    function test_samePoolForwardingShortfallStillSkipsOptionalChild() public {
        MockExtension child = new MockExtension(address(hook));
        MockExtension origin = new MockExtension(address(hook));
        _admit(address(child));
        _admit(address(origin));
        hook.installExtension(key, child, _settings(CallbackType.BeforeSwap.mask(), true, false, 1_000_000));
        hook.installExtension(key, origin, _settings(CallbackType.AfterSwap.mask(), true, true, 1_000_000));
        hook.activateExtension(key, child);
        hook.activateExtension(key, origin);
        MockERC20(Currency.unwrap(currency0)).mint(address(origin), 1000);
        origin.deposit(key.toId(), currency0, 1000);
        origin.addRouteAction(
            CallbackType.AfterSwap, RouteAction(key, Operation.Swap, abi.encode(_exactInputParameters(true, 100)), "")
        );
        _expectSkip(child, CallbackType.BeforeSwap, abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector));
        _swapExactInput(key, true, 1e14);
        assertEq(origin.callCount(CallbackType.AfterSwap), 1);
        assertEq(origin.lastRouteResults().length, 1);
        assertEq(child.callCount(CallbackType.BeforeSwap), 1, "root ran; nested child skipped");
    }

    function _extension(PoolKey memory pool, uint16 mask, bool optional, bool nesting, uint32 gasLimit)
        internal
        returns (MockExtension extension)
    {
        extension = new MockExtension(address(hook));
        _installAndActivate(pool, address(extension), _settings(mask, optional, nesting, gasLimit));
    }

    function _expectSkip(MockExtension extension, CallbackType callback, bytes memory reason) internal {
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(key.toId(), address(extension), callback, reason);
    }
}
