// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {NoopExtension} from "../mocks/NoopExtension.sol";
import {CodexLifecycleExtension} from "../mocks/CodexLifecycleExtension.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "../../src/interfaces/IHookCatalog.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "../../src/interfaces/IKernelHookExtension.sol";
import {CallbackLibrary} from "../../src/libraries/CallbackLibrary.sol";
import {
    CALLBACK_COUNT,
    CallbackType,
    ExtensionSettings,
    Operation,
    RouteAction
} from "../../src/types/KernelHookTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

abstract contract CodexLifecycleFixture is KernelHookFixture {
    using CallbackLibrary for CallbackType;

    address internal constant CONFIGURER = address(0xC0DE);
    address internal constant OUTSIDER = address(0xBAD);
    PoolKey internal poolKey;
    PoolId internal poolId;
    CodexLifecycleExtension internal extension;

    function setUp() public virtual override {
        super.setUp();
        poolKey = _poolKey();
        poolId = poolKey.toId();
        hook.preparePool(poolKey);
        extension = new CodexLifecycleExtension(address(hook));
        _admit(address(extension));
    }

    function _initialize() internal {
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function _install() internal {
        hook.installExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false));
    }

    function _installSecond(uint16 mask) internal returns (CodexLifecycleExtension second) {
        second = new CodexLifecycleExtension(address(hook));
        _admit(address(second));
        hook.installExtension(poolKey, second, _settings(mask, false, false));
    }

    function _budgets(uint32 amount) internal pure returns (uint32[CALLBACK_COUNT] memory budgets) {
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = amount;
        }
    }

    function _order(address first) internal pure returns (address[] memory order) {
        order = new address[](1);
        order[0] = first;
    }

    function _entry(address account) internal view returns (IHookCatalog.Entry memory entry) {
        entry = IHookCatalog.Entry(account.codehash, CallbackLibrary.ALL_CALLBACKS_MASK, true, true, true, true, true);
    }

    function _restrictedExtension(bool optional, bool nesting, bool late, uint16 mask)
        internal
        returns (CodexLifecycleExtension restricted)
    {
        restricted = new CodexLifecycleExtension(address(hook));
        IHookCatalog.Entry memory entry = _entry(address(restricted));
        entry.supportsOptionalCallbacks = optional;
        entry.supportsNesting = nesting;
        entry.supportsLateInstallation = late;
        entry.callbackMask = mask;
        catalog.admit(address(restricted), entry);
    }

    function _manage(uint8 operation, PoolKey memory key) internal {
        if (operation == 0) {
            hook.installExtension(key, extension, _settings(SWAP_CALLBACKS, false, false));
        } else if (operation == 1) {
            hook.configureExtension(key, extension, _settings(SWAP_CALLBACKS, false, false, 400_000));
        } else if (operation == 2) {
            hook.activateExtension(key, extension);
        } else if (operation == 3) {
            hook.deactivateExtension(key, extension);
        } else if (operation == 4) {
            hook.removeExtension(key, extension);
        } else if (operation == 5) {
            hook.setCallbackOrder(key, CallbackType.BeforeSwap, _order(address(extension)));
        } else {
            hook.setExecutionLimits(key, 4, _budgets(2_000_000));
        }
    }

    /// @dev Runs the management call and checks its effect, so that a call that changes nothing cannot pass.
    function _manageAndCheck(uint8 operation, PoolKey memory key) internal {
        if (operation == 5) {
            vm.expectEmit(true, true, false, true, address(hook));
            emit IKernelHook.CallbackOrderChanged(poolId, CallbackType.BeforeSwap, _order(address(extension)));
        }
        _manage(operation, key);
        if (operation == 0) assertTrue(hook.isInstalled(poolId, address(extension)));
        if (operation == 4) assertFalse(hook.isInstalled(poolId, address(extension)));
        if (operation == 1 || operation == 2 || operation == 3) {
            (bool active, ExtensionSettings memory settings,) = hook.extensionConfiguration(poolId, address(extension));
            if (operation == 1) assertEq(settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)], 400_000);
            if (operation == 2) assertTrue(active);
            if (operation == 3) assertFalse(active);
        }
        if (operation == 6) {
            (,, uint8 depth, uint32[CALLBACK_COUNT] memory budgets) = hook.poolState(poolId);
            assertEq(depth, 4);
            assertEq(budgets[uint8(CallbackType.BeforeSwap)], 2_000_000);
        }
    }

    function _prepareManagement(uint8 operation) internal {
        if (operation != 0) _install();
        if (operation == 3) hook.activateExtension(poolKey, extension);
    }

    function _expectUnauthorized(uint8 operation, bool initialized, address caller) internal {
        if (initialized) _initialize();
        _prepareManagement(operation);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        _manage(operation, poolKey);
    }

    function _indexOf(address account) internal returns (uint8) {
        // The index has no public getter. Record the installed flag's read to locate its packed storage word.
        vm.record();
        assertTrue(hook.isInstalled(poolId, account));
        (bytes32[] memory reads,) = vm.accesses(address(hook));
        return uint8(uint256(vm.load(address(hook), reads[0])) >> 16);
    }

    function _expectCallbackManagementFailure(bytes memory callData) internal {
        _initialize();
        _addLiquidity(poolKey);
        extension.setManagementCall(callData);
        _installAndActivate(poolKey, address(extension), _settings(SWAP_CALLBACKS, false, false));
        bytes memory failure = abi.encodeWithSelector(
            IKernelHook.ExtensionFailed.selector,
            address(extension),
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(IKernelHook.ExecutionInProgress.selector)
        );
        vm.expectRevert(_hookRevert(IHooks.beforeSwap.selector, failure));
        _swapExactInput(poolKey, true, 1e14);
    }
}

contract ExtensionInstallationTest is CodexLifecycleFixture {
    using CallbackLibrary for CallbackType;

    function test_installExtension_storesInactiveSettingsAndCatalogEntry() public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, true, true);
        settings.configuration = hex"123456";
        hook.installExtension(poolKey, extension, settings);
        (bool active, ExtensionSettings memory stored, IHookCatalog.Entry memory entry) =
            hook.extensionConfiguration(poolId, address(extension));
        assertFalse(active);
        assertEq(abi.encode(stored), abi.encode(settings));
        assertEq(abi.encode(entry), abi.encode(catalog.getEntry(address(extension))));
        assertEq(hook.installedExtensions(poolId), _order(address(extension)));
    }

    function test_installExtension_emitsInstalledEvent() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit IKernelHook.ExtensionInstalled(poolId, address(extension), SWAP_CALLBACKS);
        _install();
    }

    function test_installExtension_callsOnInstall() public {
        vm.expectEmit(false, false, false, true, address(extension));
        emit CodexLifecycleExtension.LifecycleCalled(IKernelHookExtension.onInstall.selector);
        _install();
    }

    function test_installExtension_preservesCopiedAdmissionAfterCatalogRevocation() public {
        _install();
        catalog.setAdmission(address(extension), false);
        hook.activateExtension(poolKey, extension);
        (bool active,, IHookCatalog.Entry memory entry) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
        assertTrue(entry.admitted);
    }

    function test_installExtension_acceptsInitializationCallbacksBeforeInitialization() public {
        hook.installExtension(poolKey, extension, _settings(3, false, false));
        assertEq(hook.callbackOrder(poolId, CallbackType.BeforeInitialize), _order(address(extension)));
        assertEq(hook.callbackOrder(poolId, CallbackType.AfterInitialize), _order(address(extension)));
    }

    function test_installExtension_acceptsLateInstallationWhenSupported() public {
        _initialize();
        _install();
        assertTrue(hook.isInstalled(poolId, address(extension)));
    }

    function test_installExtension_revertsWhenExtensionIsUnknown() public {
        CodexLifecycleExtension unknown = new CodexLifecycleExtension(address(hook));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionNotAdmitted.selector));
        hook.installExtension(poolKey, unknown, _settings(SWAP_CALLBACKS, false, false));
    }

    function test_installExtension_revertsWhenAdmissionIsRevoked() public {
        catalog.setAdmission(address(extension), false);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionNotAdmitted.selector));
        _install();
    }

    function test_installExtension_revertsWhenExtensionHasNoCode() public {
        vm.etch(address(extension), hex"");
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionCodeMismatch.selector));
        _install();
    }

    function test_installExtension_revertsWhenCodeHashChanges() public {
        vm.etch(address(extension), hex"60006000f3");
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionCodeMismatch.selector));
        _install();
    }

    function test_installExtension_revertsWhenAlreadyInstalled() public {
        _install();
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionAlreadyInstalled.selector));
        _install();
    }

    function test_installExtension_revertsWhenThirtyThirdExtensionIsInstalled() public {
        for (uint256 i; i < 32; ++i) {
            NoopExtension account = new NoopExtension(address(hook), CallbackType.BeforeSwap, 0, 0);
            _admit(address(account));
            hook.installExtension(poolKey, account, _settings(SWAP_CALLBACKS, false, false, 10_000));
        }
        assertEq(hook.installedExtensions(poolId).length, 32);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.TooManyExtensions.selector));
        _install();
    }

    function test_installExtension_revertsWhenLateInstallationIsUnsupported() public {
        _initialize();
        CodexLifecycleExtension restricted = _restrictedExtension(true, true, false, SWAP_CALLBACKS);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.LateInstallationNotSupported.selector));
        hook.installExtension(poolKey, restricted, _settings(SWAP_CALLBACKS, false, false));
    }

    function testFuzz_installExtension_revertsWhenInitializationCallbacksAreTooLate(uint16 mask) public {
        _initialize();
        mask = uint16(bound(mask, 1, 3));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InitializationCallbacksTooLate.selector));
        hook.installExtension(poolKey, extension, _settings(mask, false, false));
    }

    function test_installExtension_revertsWhenCallbackMaskIsEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackMask.selector));
        hook.installExtension(poolKey, extension, _settings(0, false, false));
    }

    function test_installExtension_revertsWhenCallbackIsUnsupported() public {
        CodexLifecycleExtension restricted = _restrictedExtension(true, true, true, CallbackType.BeforeSwap.mask());
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackMask.selector));
        hook.installExtension(poolKey, restricted, _settings(SWAP_CALLBACKS, false, false));
    }

    function testFuzz_installExtension_revertsWhenCallbackMaskHasUnknownBits(uint16 mask) public {
        mask = uint16(bound(mask, 1024, type(uint16).max));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackMask.selector));
        hook.installExtension(poolKey, extension, _settings(mask, false, false));
    }

    function testFuzz_installExtension_revertsWhenConfigurationIsTooLarge(uint16 length) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.configuration = new bytes(bound(length, 8193, 9000));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ConfigurationTooLarge.selector));
        hook.installExtension(poolKey, extension, settings);
    }

    function testFuzz_installExtension_acceptsConfigurationWithinMaximum(uint16 length) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.configuration = new bytes(bound(length, 0, 8192));
        hook.installExtension(poolKey, extension, settings);
        (, ExtensionSettings memory stored,) = hook.extensionConfiguration(poolId, address(extension));
        assertEq(stored.configuration.length, settings.configuration.length);
    }

    function test_installExtension_revertsWhenOptionalCallbacksAreUnsupported() public {
        CodexLifecycleExtension restricted = _restrictedExtension(false, true, true, SWAP_CALLBACKS);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.UnsupportedCapability.selector));
        hook.installExtension(poolKey, restricted, _settings(SWAP_CALLBACKS, true, false));
    }

    function test_installExtension_revertsWhenNestingIsUnsupported() public {
        CodexLifecycleExtension restricted = _restrictedExtension(true, false, true, SWAP_CALLBACKS);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.UnsupportedCapability.selector));
        hook.installExtension(poolKey, restricted, _settings(SWAP_CALLBACKS, false, true));
    }

    function testFuzz_installExtension_revertsWhenLifecycleGasIsTooLow(uint32 gasLimit) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.lifecycleGasLimit = uint32(bound(gasLimit, 0, 9999));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasLimitOutOfRange.selector));
        hook.installExtension(poolKey, extension, settings);
    }

    function testFuzz_installExtension_revertsWhenLifecycleGasIsTooHigh(uint32 gasLimit) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.lifecycleGasLimit = uint32(bound(gasLimit, 5_000_001, type(uint32).max));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasLimitOutOfRange.selector));
        hook.installExtension(poolKey, extension, settings);
    }

    function testFuzz_installExtension_revertsWhenCallbackGasIsTooLow(uint32 gasLimit, uint8 callback) public {
        callback = uint8(bound(callback, 2, 3));
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.callbackGasLimits[callback] = uint32(bound(gasLimit, 0, 9999));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasLimitOutOfRange.selector));
        hook.installExtension(poolKey, extension, settings);
    }

    function testFuzz_installExtension_revertsWhenCallbackGasIsTooHigh(uint32 gasLimit, uint8 callback) public {
        callback = uint8(bound(callback, 2, 3));
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.callbackGasLimits[callback] = uint32(bound(gasLimit, 5_000_001, type(uint32).max));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasLimitOutOfRange.selector));
        hook.installExtension(poolKey, extension, settings);
    }

    function testFuzz_installExtension_acceptsGasLimitsWithinRange(uint32 gasLimit) public {
        gasLimit = uint32(bound(gasLimit, 10_000, 5_000_000));
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false, gasLimit);
        settings.lifecycleGasLimit = gasLimit;
        hook.installExtension(poolKey, extension, settings);
        (, ExtensionSettings memory stored,) = hook.extensionConfiguration(poolId, address(extension));
        assertEq(stored.callbackGasLimits[2], gasLimit);
        assertEq(stored.lifecycleGasLimit, gasLimit);
    }

    function test_installExtension_ignoresGasLimitsOfUnsubscribedCallbacks() public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.callbackGasLimits[0] = 0;
        settings.callbackGasLimits[9] = type(uint32).max;
        hook.installExtension(poolKey, extension, settings);
        assertTrue(hook.isInstalled(poolId, address(extension)));
    }

    function test_installExtension_revertsWhenSubscriberIsActive() public {
        CodexLifecycleExtension second = _installSecond(SWAP_CALLBACKS);
        hook.activateExtension(poolKey, second);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.SubscribersActive.selector));
        _install();
    }

    function testFuzz_installExtension_revertsWhenOnInstallResponseIsInvalid(uint8 mode) public {
        mode = uint8(bound(mode, 1, 4));
        extension.setResponseMode(IKernelHookExtension.onInstall.selector, mode);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidResponse.selector));
        _install();
        assertFalse(hook.isInstalled(poolId, address(extension)));
        assertEq(hook.callbackOrder(poolId, CallbackType.BeforeSwap).length, 0);
    }

    function test_installExtension_revertsWhenCallerIsUnauthorized() public {
        _expectUnauthorized(0, true, OUTSIDER);
    }

    function test_installExtension_revertsWhenCallerIsOnlyConfigurer() public {
        _initialize();
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        _install();
    }

    function test_installExtension_revertsWhenPreparedPoolCallerIsOnlyConfigurer() public {
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        _install();
    }
}

contract ExtensionConfigurationTest is CodexLifecycleFixture {
    using CallbackLibrary for CallbackType;

    function setUp() public override {
        super.setUp();
        _install();
    }

    function test_configureExtension_replacesSettings() public {
        ExtensionSettings memory settings = _settings(CallbackType.AfterDonate.mask(), true, true, 700_000);
        settings.configuration = hex"ab12";
        hook.configureExtension(poolKey, extension, settings);
        (, ExtensionSettings memory stored,) = hook.extensionConfiguration(poolId, address(extension));
        assertEq(abi.encode(stored), abi.encode(settings));
    }

    function test_configureExtension_changesSubscriptions() public {
        hook.configureExtension(poolKey, extension, _settings(CallbackType.AfterDonate.mask(), false, false));
        assertEq(hook.callbackOrder(poolId, CallbackType.BeforeSwap).length, 0);
        assertEq(hook.callbackOrder(poolId, CallbackType.AfterSwap).length, 0);
        assertEq(hook.callbackOrder(poolId, CallbackType.AfterDonate), _order(address(extension)));
    }

    function test_configureExtension_emitsConfiguredEvent() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit IKernelHook.ExtensionConfigured(poolId, address(extension));
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false));
    }

    function test_configureExtension_callsOnConfigure() public {
        vm.expectEmit(false, false, false, true, address(extension));
        emit CodexLifecycleExtension.LifecycleCalled(IKernelHookExtension.onConfigure.selector);
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false));
    }

    function test_configureExtension_allowsSameMaskWhileAnotherSubscriberIsActive() public {
        CodexLifecycleExtension second = _installSecond(SWAP_CALLBACKS);
        hook.activateExtension(poolKey, second);
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, true, false));
        (, ExtensionSettings memory stored,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(stored.optionalCallbacks);
    }

    function test_configureExtension_revertsWhenMadeRequiredWhileAnotherSubscriberIsActive() public {
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, true, false));
        CodexLifecycleExtension second = _installSecond(SWAP_CALLBACKS);
        hook.activateExtension(poolKey, second);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.SubscribersActive.selector));
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false));
    }

    function test_configureExtension_revertsWhenOldSubscriberIsActive() public {
        CodexLifecycleExtension second = _installSecond(SWAP_CALLBACKS);
        hook.activateExtension(poolKey, second);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.SubscribersActive.selector));
        hook.configureExtension(poolKey, extension, _settings(CallbackType.AfterDonate.mask(), false, false));
    }

    function test_configureExtension_revertsWhenNewSubscriberIsActive() public {
        CodexLifecycleExtension second = _installSecond(CallbackType.AfterDonate.mask());
        hook.activateExtension(poolKey, second);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.SubscribersActive.selector));
        hook.configureExtension(poolKey, extension, _settings(CallbackType.AfterDonate.mask(), false, false));
    }

    function test_configureExtension_revertsWhenInitializationCallbackIsAddedTooLate() public {
        _initialize();
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InitializationCallbacksTooLate.selector));
        hook.configureExtension(poolKey, extension, _settings(3, false, false));
    }

    function test_configureExtension_keepsCompletedInitializationSubscriptions() public {
        hook.configureExtension(poolKey, extension, _settings(3, false, false));
        hook.activateExtension(poolKey, extension);
        _initialize();
        hook.deactivateExtension(poolKey, extension);
        hook.configureExtension(poolKey, extension, _settings(3, true, false));
        hook.activateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }

    function test_configureExtension_revertsWhenExtensionIsActive() public {
        hook.activateExtension(poolKey, extension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionActive.selector));
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false));
    }

    function test_configureExtension_revertsWhenCodeHashChanges() public {
        vm.etch(address(extension), hex"60006000f3");
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionCodeMismatch.selector));
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false));
    }

    function test_configureExtension_revertsWhenExtensionIsNotInstalled() public {
        hook.removeExtension(poolKey, extension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionNotInstalled.selector));
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false));
    }

    function test_configureExtension_revertsWhenCallbackMaskIsEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackMask.selector));
        hook.configureExtension(poolKey, extension, _settings(0, false, false));
    }

    function testFuzz_configureExtension_revertsWhenCallbackMaskHasUnknownBits(uint16 mask) public {
        mask = uint16(bound(mask, 1024, type(uint16).max));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackMask.selector));
        hook.configureExtension(poolKey, extension, _settings(mask, false, false));
    }

    function test_configureExtension_revertsWhenCallbackIsUnsupported() public {
        CodexLifecycleExtension restricted = _restrictedExtension(true, true, true, CallbackType.BeforeSwap.mask());
        hook.installExtension(poolKey, restricted, _settings(CallbackType.BeforeSwap.mask(), false, false));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackMask.selector));
        hook.configureExtension(poolKey, restricted, _settings(SWAP_CALLBACKS, false, false));
    }

    function testFuzz_configureExtension_revertsWhenConfigurationIsTooLarge(uint16 length) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.configuration = new bytes(bound(length, 8193, 9000));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ConfigurationTooLarge.selector));
        hook.configureExtension(poolKey, extension, settings);
    }

    function testFuzz_configureExtension_acceptsConfigurationWithinMaximum(uint16 length) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.configuration = new bytes(bound(length, 0, 8192));
        hook.configureExtension(poolKey, extension, settings);
        (, ExtensionSettings memory stored,) = hook.extensionConfiguration(poolId, address(extension));
        assertEq(stored.configuration.length, settings.configuration.length);
    }

    function test_configureExtension_revertsWhenOptionalCallbacksAreUnsupported() public {
        CodexLifecycleExtension restricted = _restrictedExtension(false, true, true, SWAP_CALLBACKS);
        hook.installExtension(poolKey, restricted, _settings(SWAP_CALLBACKS, false, false));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.UnsupportedCapability.selector));
        hook.configureExtension(poolKey, restricted, _settings(SWAP_CALLBACKS, true, false));
    }

    function test_configureExtension_revertsWhenNestingIsUnsupported() public {
        CodexLifecycleExtension restricted = _restrictedExtension(true, false, true, SWAP_CALLBACKS);
        hook.installExtension(poolKey, restricted, _settings(SWAP_CALLBACKS, false, false));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.UnsupportedCapability.selector));
        hook.configureExtension(poolKey, restricted, _settings(SWAP_CALLBACKS, false, true));
    }

    function testFuzz_configureExtension_revertsWhenLifecycleGasIsTooLow(uint32 gasLimit) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.lifecycleGasLimit = uint32(bound(gasLimit, 0, 9999));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasLimitOutOfRange.selector));
        hook.configureExtension(poolKey, extension, settings);
    }

    function testFuzz_configureExtension_revertsWhenLifecycleGasIsTooHigh(uint32 gasLimit) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.lifecycleGasLimit = uint32(bound(gasLimit, 5_000_001, type(uint32).max));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasLimitOutOfRange.selector));
        hook.configureExtension(poolKey, extension, settings);
    }

    function testFuzz_configureExtension_revertsWhenCallbackGasIsTooLow(uint32 gasLimit) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.callbackGasLimits[2] = uint32(bound(gasLimit, 0, 9999));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasLimitOutOfRange.selector));
        hook.configureExtension(poolKey, extension, settings);
    }

    function testFuzz_configureExtension_revertsWhenCallbackGasIsTooHigh(uint32 gasLimit) public {
        ExtensionSettings memory settings = _settings(SWAP_CALLBACKS, false, false);
        settings.callbackGasLimits[3] = uint32(bound(gasLimit, 5_000_001, type(uint32).max));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasLimitOutOfRange.selector));
        hook.configureExtension(poolKey, extension, settings);
    }

    function testFuzz_configureExtension_revertsWhenOnConfigureResponseIsInvalid(uint8 mode) public {
        mode = uint8(bound(mode, 1, 4));
        extension.setResponseMode(IKernelHookExtension.onConfigure.selector, mode);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidResponse.selector));
        hook.configureExtension(poolKey, extension, _settings(CallbackType.AfterDonate.mask(), false, false));
        assertEq(hook.callbackOrder(poolId, CallbackType.BeforeSwap), _order(address(extension)));
        assertEq(hook.callbackOrder(poolId, CallbackType.AfterDonate).length, 0);
    }

    function test_configureExtension_revertsWhenCallerIsUnauthorized() public {
        _initialize();
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false));
    }

    function test_configureExtension_allowsConfigurer() public {
        _initialize();
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        hook.configureExtension(poolKey, extension, _settings(SWAP_CALLBACKS, true, false));
        (, ExtensionSettings memory settings,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(settings.optionalCallbacks);
    }
}

contract ExtensionActivationTest is CodexLifecycleFixture {
    using CallbackLibrary for CallbackType;

    function test_activateExtension_activatesInstallation() public {
        _install();
        hook.activateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }

    function test_activateExtension_emitsActivationEvent() public {
        _install();
        vm.expectEmit(true, true, false, true, address(hook));
        emit IKernelHook.ExtensionActivationChanged(poolId, address(extension), true);
        hook.activateExtension(poolKey, extension);
    }

    function test_activateExtension_revertsWhenExtensionIsNotInstalled() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionNotInstalled.selector));
        hook.activateExtension(poolKey, extension);
    }

    function test_activateExtension_revertsWhenExtensionIsActive() public {
        _install();
        hook.activateExtension(poolKey, extension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionActive.selector));
        hook.activateExtension(poolKey, extension);
    }

    function test_activateExtension_revertsWhenCodeHashChanges() public {
        _install();
        vm.etch(address(extension), hex"60006000f3");
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionCodeMismatch.selector));
        hook.activateExtension(poolKey, extension);
    }

    function testFuzz_activateExtension_revertsWhenInitializationCallbacksAreIncomplete(uint16 mask) public {
        mask = uint16(bound(mask, 1, 3));
        hook.installExtension(poolKey, extension, _settings(mask, false, false));
        _initialize();
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InitializationCallbacksIncomplete.selector));
        hook.activateExtension(poolKey, extension);
    }

    function test_activateExtension_allowsCompletedRequiredInitializationCallbacks() public {
        hook.installExtension(poolKey, extension, _settings(3, false, false));
        hook.activateExtension(poolKey, extension);
        _initialize();
        hook.deactivateExtension(poolKey, extension);
        hook.activateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }

    function test_activateExtension_allowsOptionalInitializationCallbacksToBeIncomplete() public {
        hook.installExtension(poolKey, extension, _settings(3, true, false));
        _initialize();
        hook.activateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }

    function testFuzz_activateExtension_revertsWhenCanActivateResponseIsRejected(uint8 mode) public {
        mode = uint8(bound(mode, 1, 4));
        _install();
        extension.setResponseMode(IKernelHookExtension.canActivate.selector, mode);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ActivationRejected.selector));
        hook.activateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertFalse(active);
    }

    /// @dev The default budget is 4,000,000. One required swap extension needs limit + limit / 31 + 250,000
    /// (invocation reserves) + 80,000 (return) + 25,000 (sequence setup) + 25,000 (one iteration) + 12,000 (one
    /// subscriber). 3,495,251 + 112,750 + 392,000 = 4,000,001.
    function testFuzz_activateExtension_revertsWhenMandatoryGasExceedsBudget(uint32 gasLimit) public {
        gasLimit = uint32(bound(gasLimit, 3_495_251, 5_000_000));
        hook.installExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false, gasLimit));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector));
        hook.activateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertFalse(active);
    }

    /// @dev 3,495,250 + 112,750 + 392,000 = 4,000,000, exactly the default budget.
    function test_activateExtension_acceptsMandatoryGasAtBudgetBoundary() public {
        hook.installExtension(poolKey, extension, _settings(SWAP_CALLBACKS, false, false, 3_495_250));
        hook.activateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }

    function test_activateExtension_ignoresOptionalGasInMandatoryBudget() public {
        hook.installExtension(poolKey, extension, _settings(SWAP_CALLBACKS, true, false, 5_000_000));
        hook.activateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }

    /// @dev Each fits the default budget of 4,000,000 alone (the second needs 3,525,774, with both subscribers in the
    /// order). Together they need (500,000 + 16,129 + 250,000) + (3,000,000 + 96,774 + 250,000) + 80,000 + 25,000
    /// + 2 * (25,000 + 12,000) = 4,291,903.
    function test_activateExtension_revertsWhenCombinedMandatoryGasExceedsBudget() public {
        _install();
        CodexLifecycleExtension second = _installSecond(SWAP_CALLBACKS);
        hook.configureExtension(poolKey, second, _settings(SWAP_CALLBACKS, false, false, 3_000_000));
        hook.activateExtension(poolKey, extension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector));
        hook.activateExtension(poolKey, second);
    }

    function test_activateExtension_revertsWhenCallerIsUnauthorized() public {
        _expectUnauthorized(2, true, OUTSIDER);
    }

    function test_activateExtension_allowsConfigurer() public {
        _initialize();
        _install();
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        hook.activateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }

    function test_deactivateExtension_deactivatesInstallation() public {
        _install();
        hook.activateExtension(poolKey, extension);
        hook.deactivateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertFalse(active);
    }

    function test_deactivateExtension_stopsCallbacks() public {
        _initialize();
        _addLiquidity(poolKey);
        MockExtension observer = new MockExtension(address(hook));
        _installAndActivate(poolKey, address(observer), _settings(SWAP_CALLBACKS, false, false));
        hook.deactivateExtension(poolKey, observer);
        _swapExactInput(poolKey, true, 1e14);
        assertEq(observer.callCount(CallbackType.BeforeSwap), 0);
        assertEq(observer.callCount(CallbackType.AfterSwap), 0);
    }

    function test_deactivateExtension_emitsDeactivationEvent() public {
        _install();
        hook.activateExtension(poolKey, extension);
        vm.expectEmit(true, true, false, true, address(hook));
        emit IKernelHook.ExtensionActivationChanged(poolId, address(extension), false);
        hook.deactivateExtension(poolKey, extension);
    }

    function test_deactivateExtension_revertsWhenExtensionIsNotInstalled() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionNotInstalled.selector));
        hook.deactivateExtension(poolKey, extension);
    }

    function test_deactivateExtension_revertsWhenExtensionIsInactive() public {
        _install();
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionInactive.selector));
        hook.deactivateExtension(poolKey, extension);
    }

    function test_deactivateExtension_allowsShutdownAfterCodeHashChanges() public {
        _install();
        hook.activateExtension(poolKey, extension);
        vm.etch(address(extension), hex"60006000f3");
        hook.deactivateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertFalse(active);
    }

    function test_deactivateExtension_revertsWhenCallerIsUnauthorized() public {
        _expectUnauthorized(3, true, OUTSIDER);
    }

    function test_deactivateExtension_allowsConfigurer() public {
        _initialize();
        _install();
        hook.activateExtension(poolKey, extension);
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        hook.deactivateExtension(poolKey, extension);
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertFalse(active);
    }
}

contract ExtensionRemovalTest is CodexLifecycleFixture {
    using CallbackLibrary for CallbackType;

    function test_removeExtension_clearsInstallation() public {
        _install();
        hook.removeExtension(poolKey, extension);
        assertFalse(hook.isInstalled(poolId, address(extension)));
        assertEq(hook.installedExtensions(poolId).length, 0);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionNotInstalled.selector));
        hook.extensionConfiguration(poolId, address(extension));
    }

    function test_removeExtension_emitsRemovedEvent() public {
        _install();
        vm.expectEmit(true, true, false, true, address(hook));
        emit IKernelHook.ExtensionRemoved(poolId, address(extension));
        hook.removeExtension(poolKey, extension);
    }

    function test_removeExtension_callsOnUninstall() public {
        _install();
        vm.expectEmit(false, false, false, true, address(extension));
        emit CodexLifecycleExtension.LifecycleCalled(IKernelHookExtension.onUninstall.selector);
        hook.removeExtension(poolKey, extension);
    }

    function test_removeExtension_compactsExtensionIndices() public {
        _install();
        CodexLifecycleExtension second = _installSecond(SWAP_CALLBACKS);
        CodexLifecycleExtension third = _installSecond(SWAP_CALLBACKS);
        assertEq(_indexOf(address(extension)), 0);
        assertEq(_indexOf(address(second)), 1);
        assertEq(_indexOf(address(third)), 2);
        hook.removeExtension(poolKey, second);
        assertEq(_indexOf(address(extension)), 0);
        assertEq(_indexOf(address(third)), 1);
        CodexLifecycleExtension replacement = _installSecond(SWAP_CALLBACKS);
        assertEq(_indexOf(address(replacement)), 2);
    }

    function test_removeExtension_preservesCallbackOrderOfRemainingSubscribers() public {
        _install();
        CodexLifecycleExtension second = _installSecond(SWAP_CALLBACKS);
        CodexLifecycleExtension third = _installSecond(SWAP_CALLBACKS);
        address[] memory order = new address[](3);
        order[0] = address(third);
        order[1] = address(second);
        order[2] = address(extension);
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, order);
        hook.removeExtension(poolKey, second);
        address[] memory remaining = hook.callbackOrder(poolId, CallbackType.BeforeSwap);
        assertEq(remaining.length, 2);
        assertEq(remaining[0], address(third));
        assertEq(remaining[1], address(extension));
        assertEq(hook.callbackOrder(poolId, CallbackType.AfterSwap).length, 2);
    }

    function test_removeExtension_allowsReinstallation() public {
        _install();
        hook.removeExtension(poolKey, extension);
        _install();
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertFalse(active);
        assertEq(_indexOf(address(extension)), 0);
    }

    function test_removeExtension_revertsWhenExtensionIsNotInstalled() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionNotInstalled.selector));
        hook.removeExtension(poolKey, extension);
    }

    function test_removeExtension_revertsWhenExtensionIsActive() public {
        _install();
        hook.activateExtension(poolKey, extension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionActive.selector));
        hook.removeExtension(poolKey, extension);
    }

    function test_removeExtension_revertsWhenCodeHashChanges() public {
        _install();
        vm.etch(address(extension), hex"60006000f3");
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionCodeMismatch.selector));
        hook.removeExtension(poolKey, extension);
    }

    function test_removeExtension_revertsWhenAnotherSubscriberIsActive() public {
        _install();
        CodexLifecycleExtension second = _installSecond(SWAP_CALLBACKS);
        hook.activateExtension(poolKey, second);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.SubscribersActive.selector));
        hook.removeExtension(poolKey, extension);
    }

    function test_removeExtension_revertsWhenVaultFundsRemain() public {
        _install();
        MockERC20(Currency.unwrap(currency0)).mint(address(extension), 100);
        extension.deposit(poolId, currency0, 100);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.OutstandingObligations.selector));
        hook.removeExtension(poolKey, extension);
    }

    function testFuzz_removeExtension_revertsWhenCanUninstallResponseIsRejected(uint8 mode) public {
        mode = uint8(bound(mode, 1, 4));
        _install();
        extension.setResponseMode(IKernelHookExtension.canUninstall.selector, mode);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.OutstandingObligations.selector));
        hook.removeExtension(poolKey, extension);
    }

    function test_removeExtension_revertsWhenOnUninstallDepositsFunds() public {
        _install();
        MockERC20(Currency.unwrap(currency0)).mint(address(extension), 1);
        extension.setUninstallDeposit(currency0, 1);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.OutstandingObligations.selector));
        hook.removeExtension(poolKey, extension);
        assertTrue(hook.isInstalled(poolId, address(extension)));
        assertEq(hook.VAULT().balanceOf(poolId, address(extension), currency0), 0);
    }

    function testFuzz_removeExtension_revertsWhenOnUninstallResponseIsInvalid(uint8 mode) public {
        mode = uint8(bound(mode, 1, 4));
        _install();
        extension.setResponseMode(IKernelHookExtension.onUninstall.selector, mode);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidResponse.selector));
        hook.removeExtension(poolKey, extension);
        assertTrue(hook.isInstalled(poolId, address(extension)));
    }

    function test_removeExtension_revertsWhenOpenRoutePositionRemains() public {
        MockExtension positionOwner = _openRoutePosition();
        assertEq(hook.ROUTE_EXECUTOR().openPositionCount(poolId, address(positionOwner)), 1);
        assertEq(hook.VAULT().fundedCurrencyCount(poolId, address(positionOwner)), 0);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.OutstandingObligations.selector));
        hook.removeExtension(poolKey, positionOwner);
    }

    function _openRoutePosition() internal returns (MockExtension positionOwner) {
        _initialize();
        _addLiquidity(poolKey);
        PoolKey memory target = poolKey;
        target.fee = 500;
        _createPool(target);
        positionOwner = new MockExtension(address(hook));
        _admit(address(positionOwner));
        hook.installExtension(poolKey, positionOwner, _settings(CallbackType.AfterSwap.mask(), false, true, 1_500_000));
        MockERC20(Currency.unwrap(currency0)).mint(address(positionOwner), 1e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(positionOwner), 1e18);
        positionOwner.deposit(poolId, currency0, 1e18);
        positionOwner.deposit(poolId, currency1, 1e18);
        positionOwner.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction(target, Operation.ModifyLiquidity, abi.encode(_liquidityParameters(1e16)), "")
        );
        hook.activateExtension(poolKey, positionOwner);
        _swapExactInput(poolKey, true, 1e14);
        hook.deactivateExtension(poolKey, positionOwner);
        uint256 amount0 = hook.VAULT().balanceOf(poolId, address(positionOwner), currency0);
        uint256 amount1 = hook.VAULT().balanceOf(poolId, address(positionOwner), currency1);
        positionOwner.withdraw(poolId, currency0, amount0, address(this));
        positionOwner.withdraw(poolId, currency1, amount1, address(this));
    }

    function test_removeExtension_revertsWhenCallerIsUnauthorized() public {
        _expectUnauthorized(4, true, OUTSIDER);
    }

    function test_removeExtension_revertsWhenCallerIsOnlyConfigurer() public {
        _initialize();
        _install();
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        hook.removeExtension(poolKey, extension);
    }

    function test_removeExtension_revertsWhenPreparedPoolCallerIsOnlyConfigurer() public {
        _install();
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        hook.removeExtension(poolKey, extension);
    }
}

contract ExtensionOrderAndLimitsTest is CodexLifecycleFixture {
    using CallbackLibrary for CallbackType;

    function test_setCallbackOrder_reordersSubscribers() public {
        _install();
        CodexLifecycleExtension second = _installSecond(SWAP_CALLBACKS);
        address[] memory order = new address[](2);
        order[0] = address(second);
        order[1] = address(extension);
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, order);
        assertEq(hook.callbackOrder(poolId, CallbackType.BeforeSwap), order);
        assertEq(hook.callbackOrder(poolId, CallbackType.AfterSwap)[0], address(extension));
    }

    function test_setCallbackOrder_emitsOrderEvent() public {
        _install();
        address[] memory order = _order(address(extension));
        vm.expectEmit(true, true, false, true, address(hook));
        emit IKernelHook.CallbackOrderChanged(poolId, CallbackType.BeforeSwap, order);
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, order);
    }

    function test_setCallbackOrder_acceptsEmptyOrderForEmptyCallback() public {
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, new address[](0));
        assertEq(hook.callbackOrder(poolId, CallbackType.BeforeSwap).length, 0);
    }

    function test_setCallbackOrder_revertsWhenLengthIsTooShort() public {
        _install();
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackOrder.selector));
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, new address[](0));
    }

    function test_setCallbackOrder_revertsWhenLengthIsTooLong() public {
        _install();
        address[] memory order = new address[](2);
        order[0] = address(extension);
        order[1] = address(extension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackOrder.selector));
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, order);
    }

    function test_setCallbackOrder_revertsWhenExtensionIsNotSubscribed() public {
        _install();
        CodexLifecycleExtension second = _installSecond(CallbackType.AfterDonate.mask());
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackOrder.selector));
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, _order(address(second)));
    }

    function test_setCallbackOrder_revertsWhenExtensionIsDuplicated() public {
        _install();
        _installSecond(SWAP_CALLBACKS);
        address[] memory order = new address[](2);
        order[0] = address(extension);
        order[1] = address(extension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidCallbackOrder.selector));
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, order);
    }

    function test_setCallbackOrder_revertsWhenExtensionIsNotInstalled() public {
        _install();
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.ExtensionNotInstalled.selector));
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, _order(OUTSIDER));
    }

    function test_setCallbackOrder_revertsWhenSubscriberIsActive() public {
        _install();
        hook.activateExtension(poolKey, extension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.SubscribersActive.selector));
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, _order(address(extension)));
    }

    function test_setCallbackOrder_allowsOtherCallbackToRemainActive() public {
        _install();
        CodexLifecycleExtension second = _installSecond(CallbackType.AfterDonate.mask());
        hook.activateExtension(poolKey, second);
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, _order(address(extension)));
        assertEq(hook.callbackOrder(poolId, CallbackType.BeforeSwap), _order(address(extension)));
    }

    function test_setCallbackOrder_revertsWhenCallerIsUnauthorized() public {
        _expectUnauthorized(5, true, OUTSIDER);
    }

    function test_setCallbackOrder_allowsConfigurer() public {
        _initialize();
        _install();
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        hook.setCallbackOrder(poolKey, CallbackType.BeforeSwap, _order(address(extension)));
        assertEq(hook.callbackOrder(poolId, CallbackType.BeforeSwap), _order(address(extension)));
    }

    /// @dev 402,322 is the smallest budget of a callback that can return deltas: 80,000 (return) + 25,000 (sequence
    /// setup) + 25,000 (one iteration) + 12,000 (one subscriber) + 10,000 (MIN_CALL_GAS) + 322 + 250,000 (invocation
    /// reserves).
    function testFuzz_setExecutionLimits_storesValidLimits(uint8 depth, uint32 budget) public {
        depth = uint8(bound(depth, 1, 8));
        budget = uint32(bound(budget, 402_322, type(uint32).max));
        uint32[CALLBACK_COUNT] memory budgets = _budgets(budget);
        hook.setExecutionLimits(poolKey, depth, budgets);
        (,, uint8 storedDepth, uint32[CALLBACK_COUNT] memory storedBudgets) = hook.poolState(poolId);
        assertEq(storedDepth, depth);
        assertEq(abi.encode(storedBudgets), abi.encode(budgets));
    }

    function test_setExecutionLimits_emitsLimitsEvent() public {
        uint32[CALLBACK_COUNT] memory budgets = _budgets(1_000_000);
        vm.expectEmit(true, false, false, true, address(hook));
        emit IKernelHook.ExecutionLimitsChanged(poolId, 2, budgets);
        hook.setExecutionLimits(poolKey, 2, budgets);
    }

    function test_setExecutionLimits_revertsWhenDepthIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidExecutionLimits.selector));
        hook.setExecutionLimits(poolKey, 0, _budgets(2_000_000));
    }

    function testFuzz_setExecutionLimits_revertsWhenDepthIsAboveMaximum(uint8 depth) public {
        depth = uint8(bound(depth, 9, type(uint8).max));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidExecutionLimits.selector));
        hook.setExecutionLimits(poolKey, depth, _budgets(2_000_000));
    }

    function testFuzz_setExecutionLimits_revertsWhenCallbackBudgetIsTooLow(uint8 callback, uint32 budget) public {
        callback = uint8(bound(callback, 0, CALLBACK_COUNT - 1));
        uint32[CALLBACK_COUNT] memory budgets = _budgets(2_000_000);
        // The smallest budget is 80,000 + 25,000 + 25,000 + 12,000 + 10,322 + 40,000, plus 210,000 for a callback
        // that can return deltas.
        uint32 smallestBudget = CallbackLibrary.canReturnDeltas(CallbackType(callback)) ? 402_322 : 192_322;
        budgets[callback] = uint32(bound(budget, 0, smallestBudget - 1));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidExecutionLimits.selector));
        hook.setExecutionLimits(poolKey, 4, budgets);
    }

    function test_setExecutionLimits_revertsWhenSubscriberIsActive() public {
        _install();
        hook.activateExtension(poolKey, extension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.SubscribersActive.selector));
        hook.setExecutionLimits(poolKey, 4, _budgets(2_000_000));
    }

    function test_setExecutionLimits_defersMandatoryGasCheckUntilActivation() public {
        _install();
        hook.setExecutionLimits(poolKey, 4, _budgets(402_322));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector));
        hook.activateExtension(poolKey, extension);
    }

    function test_setExecutionLimits_revertsWhenCallerIsUnauthorized() public {
        _expectUnauthorized(6, true, OUTSIDER);
    }

    function test_setExecutionLimits_allowsConfigurer() public {
        _initialize();
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        hook.setExecutionLimits(poolKey, 2, _budgets(1_000_000));
        (,, uint8 depth,) = hook.poolState(poolId);
        assertEq(depth, 2);
    }
}

contract ExtensionManagementRulesTest is CodexLifecycleFixture {
    using CallbackLibrary for CallbackType;

    function testFuzz_management_revertsWhenPoolIsNotPrepared(uint8 operation) public {
        operation = uint8(bound(operation, 0, 6));
        PoolKey memory unknown = poolKey;
        unknown.fee = 500;
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.PoolNotPrepared.selector));
        _manage(operation, unknown);
    }

    function testFuzz_management_revertsWhenPoolKeyIsInvalid(uint8 operation) public {
        operation = uint8(bound(operation, 0, 6));
        PoolKey memory invalid = poolKey;
        invalid.hooks = IHooks(address(0));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.InvalidPool.selector));
        _manage(operation, invalid);
    }

    function testFuzz_management_revertsWhenPreparedPoolCallerIsNotInitializer(uint8 operation) public {
        operation = uint8(bound(operation, 0, 6));
        _expectUnauthorized(operation, false, OUTSIDER);
    }

    function testFuzz_management_allowsPreparedPoolInitializer(uint8 operation) public {
        operation = uint8(bound(operation, 0, 6));
        _prepareManagement(operation);
        _manageAndCheck(operation, poolKey);
    }

    function testFuzz_management_allowsInitializedPoolAdmin(uint8 operation) public {
        operation = uint8(bound(operation, 0, 6));
        _initialize();
        _prepareManagement(operation);
        hook.grantPoolRole(poolKey, hook.POOL_ADMIN_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        _manageAndCheck(operation, poolKey);
    }

    function testFuzz_management_allowsPreparedPoolConfigurerForConfiguration(uint8 operation) public {
        operation = uint8(bound(operation, 1, 6));
        if (operation == 4) operation = 5;
        _prepareManagement(operation);
        hook.grantPoolRole(poolKey, hook.CONFIGURER_ROLE(), CONFIGURER);
        vm.prank(CONFIGURER);
        _manageAndCheck(operation, poolKey);
    }

    function test_installExtension_revertsWhenCalledDuringCallback() public {
        _expectCallbackManagementFailure(
            abi.encodeCall(IKernelHook.installExtension, (poolKey, extension, _settings(SWAP_CALLBACKS, false, false)))
        );
    }

    function test_configureExtension_revertsWhenCalledDuringCallback() public {
        _expectCallbackManagementFailure(
            abi.encodeCall(
                IKernelHook.configureExtension, (poolKey, extension, _settings(SWAP_CALLBACKS, false, false))
            )
        );
    }

    function test_activateExtension_revertsWhenCalledDuringCallback() public {
        _expectCallbackManagementFailure(abi.encodeCall(IKernelHook.activateExtension, (poolKey, extension)));
    }

    function test_deactivateExtension_revertsWhenCalledDuringCallback() public {
        _expectCallbackManagementFailure(abi.encodeCall(IKernelHook.deactivateExtension, (poolKey, extension)));
    }

    function test_removeExtension_revertsWhenCalledDuringCallback() public {
        _expectCallbackManagementFailure(abi.encodeCall(IKernelHook.removeExtension, (poolKey, extension)));
    }

    function test_setCallbackOrder_revertsWhenCalledDuringCallback() public {
        _expectCallbackManagementFailure(
            abi.encodeCall(IKernelHook.setCallbackOrder, (poolKey, CallbackType.BeforeSwap, _order(address(extension))))
        );
    }

    function test_setExecutionLimits_revertsWhenCalledDuringCallback() public {
        _expectCallbackManagementFailure(
            abi.encodeCall(IKernelHook.setExecutionLimits, (poolKey, 4, _budgets(2_000_000)))
        );
    }
}
