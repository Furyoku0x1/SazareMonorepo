// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {KernelHookConstants} from "../../src/libraries/KernelHookConstants.sol";
import {CALLBACK_COUNT, CallbackType, PoolStatus} from "../../src/types/KernelHookTypes.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Pool preparation, initialization, roles and the pool read functions.
contract PoolLifecycleTest is KernelHookFixture {
    PoolKey internal poolKey;
    PoolId internal poolId;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    bytes32 internal adminRole;
    bytes32 internal configurerRole;

    uint16 internal constant INITIALIZATION_CALLBACKS =
        uint16(1) << uint8(CallbackType.BeforeInitialize) | uint16(1) << uint8(CallbackType.AfterInitialize);

    function setUp() public override {
        super.setUp();
        poolKey = _poolKey();
        poolId = poolKey.toId();
        adminRole = hook.POOL_ADMIN_ROLE();
        configurerRole = hook.CONFIGURER_ROLE();
    }

    // ---------------------------------------------------------------- preparePool

    function test_preparePool_recordsInitializerAndDefaultLimits() public {
        vm.expectEmit(true, true, false, false, address(hook));
        emit IKernelHook.PoolPrepared(poolId, address(this));
        hook.preparePool(poolKey);

        (PoolStatus status, address initializer, uint8 maxOperationDepth, uint32[CALLBACK_COUNT] memory budgets) =
            hook.poolState(poolId);
        assertEq(uint8(status), uint8(PoolStatus.Prepared));
        assertEq(initializer, address(this));
        assertEq(maxOperationDepth, KernelHookConstants.DEFAULT_MAX_OPERATION_DEPTH);
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            assertEq(budgets[i], KernelHookConstants.DEFAULT_CALLBACK_GAS_BUDGET);
        }
        assertEq(PoolId.unwrap(hook.poolKey(poolId).toId()), PoolId.unwrap(poolId));
        assertFalse(hook.isPoolInitialized(poolId));
    }

    function test_preparePool_revertsWhenAlreadyPrepared() public {
        hook.preparePool(poolKey);
        vm.expectRevert(IKernelHook.PoolAlreadyPrepared.selector);
        hook.preparePool(poolKey);
    }

    /// @dev Records a design property: the first caller reserves a pool key, and nothing releases it.
    /// A key that is prepared and never initialized stays blocked for all other callers.
    function test_preparePool_firstCallerReservesKeyPermanently() public {
        vm.prank(alice);
        hook.preparePool(poolKey);

        vm.expectRevert(IKernelHook.PoolAlreadyPrepared.selector);
        hook.preparePool(poolKey);
        vm.expectRevert(
            _hookRevert(IHooks.beforeInitialize.selector, abi.encodeWithSelector(IKernelHook.Unauthorized.selector))
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function test_preparePool_revertsWhenHookIsNotKernelHook() public {
        poolKey.hooks = IHooks(address(0xBEEF));
        vm.expectRevert(IKernelHook.InvalidPool.selector);
        hook.preparePool(poolKey);
    }

    function test_preparePool_revertsWhenCurrenciesAreNotSorted() public {
        (poolKey.currency0, poolKey.currency1) = (poolKey.currency1, poolKey.currency0);
        vm.expectRevert(IKernelHook.InvalidPool.selector);
        hook.preparePool(poolKey);
    }

    function test_preparePool_revertsWhenCurrenciesAreEqual() public {
        poolKey.currency1 = poolKey.currency0;
        vm.expectRevert(IKernelHook.InvalidPool.selector);
        hook.preparePool(poolKey);
    }

    function testFuzz_preparePool_revertsWhenTickSpacingIsOutOfRange(int24 tickSpacing) public {
        vm.assume(tickSpacing < 1 || tickSpacing > type(int16).max);
        poolKey.tickSpacing = tickSpacing;
        vm.expectRevert(IKernelHook.InvalidPool.selector);
        hook.preparePool(poolKey);
    }

    function testFuzz_preparePool_revertsWhenStaticFeeIsTooLarge(uint24 fee) public {
        fee = uint24(bound(fee, LPFeeLibrary.MAX_LP_FEE + 1, LPFeeLibrary.DYNAMIC_FEE_FLAG - 1));
        poolKey.fee = fee;
        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, fee));
        hook.preparePool(poolKey);
    }

    function test_preparePool_acceptsDynamicFee() public {
        poolKey.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        hook.preparePool(poolKey);
        (PoolStatus status,,,) = hook.poolState(poolKey.toId());
        assertEq(uint8(status), uint8(PoolStatus.Prepared));
    }

    // ---------------------------------------------------------------- initialize

    function test_initialize_makesInitializerTheFirstAdmin() public {
        hook.preparePool(poolKey);

        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.PoolRoleChanged(poolId, adminRole, address(this), true);
        vm.expectEmit(true, true, false, false, address(hook));
        emit IKernelHook.PoolRegistered(poolId, address(this));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        (PoolStatus status,,,) = hook.poolState(poolId);
        assertEq(uint8(status), uint8(PoolStatus.Initialized));
        assertTrue(hook.isPoolInitialized(poolId));
        assertTrue(hook.hasPoolRole(poolId, adminRole, address(this)));
        // The initializer is the only admin, so the last-admin rule applies to it at once.
        vm.expectRevert(IKernelHook.LastAdmin.selector);
        hook.revokePoolRole(poolKey, adminRole, address(this));
    }

    function test_initialize_revertsWhenPoolIsNotPrepared() public {
        vm.expectRevert(
            _hookRevert(IHooks.beforeInitialize.selector, abi.encodeWithSelector(IKernelHook.PoolNotPrepared.selector))
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function test_initialize_revertsWhenCallerIsNotTheInitializer() public {
        hook.preparePool(poolKey);
        vm.prank(alice);
        vm.expectRevert(
            _hookRevert(IHooks.beforeInitialize.selector, abi.encodeWithSelector(IKernelHook.Unauthorized.selector))
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function test_initialize_runsInitializationCallbacksOfExtensionsInstalledBefore() public {
        hook.preparePool(poolKey);
        MockExtension extension = new MockExtension(address(hook));
        uint16 initializationCallbacks =
            uint16(1) << uint8(CallbackType.BeforeInitialize) | uint16(1) << uint8(CallbackType.AfterInitialize);
        _installAndActivate(poolKey, address(extension), _settings(initializationCallbacks, false, false));

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        assertEq(extension.callCount(CallbackType.BeforeInitialize), 1);
        assertEq(extension.callCount(CallbackType.AfterInitialize), 1);
        assertEq(extension.lastContext().sender, address(this));
        assertEq(extension.lastContext().depth, 1);
    }

    function test_initialize_distinctInitializerBecomesFirstAdmin() public {
        vm.prank(alice);
        hook.preparePool(poolKey);
        vm.prank(alice);
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        assertTrue(hook.hasPoolRole(poolId, adminRole, alice));
        assertFalse(hook.hasPoolRole(poolId, adminRole, address(this)));
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.grantPoolRole(poolKey, configurerRole, bob);
    }

    /// @dev A failed required AfterInitialize reverts the whole initialize call: the pool stays prepared, and the
    /// initializer can repair the extension and try again.
    function test_initialize_requiredAfterFailureRollsBackAndCanRetry() public {
        hook.preparePool(poolKey);
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(poolKey, address(extension), _settings(INITIALIZATION_CALLBACKS, false, false));
        extension.setBehavior(CallbackType.AfterInitialize, MockExtension.Behavior(0, 0, 0, true, 0));
        bytes memory failure = abi.encodeWithSelector(
            IKernelHook.ExtensionFailed.selector,
            address(extension),
            CallbackType.AfterInitialize,
            abi.encodeWithSelector(MockExtension.MockRevert.selector, CallbackType.AfterInitialize)
        );
        vm.expectRevert(_hookRevert(IHooks.afterInitialize.selector, failure));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        (PoolStatus status,,,) = hook.poolState(poolId);
        assertEq(uint8(status), uint8(PoolStatus.Prepared));
        assertFalse(hook.hasPoolRole(poolId, adminRole, address(this)));
        assertEq(extension.callCount(CallbackType.BeforeInitialize), 0);

        extension.setBehavior(CallbackType.AfterInitialize, MockExtension.Behavior(0, 0, 0, false, 0));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        assertTrue(hook.isPoolInitialized(poolId));
        assertEq(extension.callCount(CallbackType.AfterInitialize), 1);
    }

    // ---------------------------------------------------------------- roles before initialization

    function test_grantPoolRole_initializerCanGrantConfigurerBeforeInitialization() public {
        hook.preparePool(poolKey);
        hook.grantPoolRole(poolKey, configurerRole, alice);
        assertTrue(hook.hasPoolRole(poolId, configurerRole, alice));
    }

    function test_initialize_preservesPreparedConfigurer() public {
        hook.preparePool(poolKey);
        hook.grantPoolRole(poolKey, configurerRole, alice);
        MockExtension extension = new MockExtension(address(hook));
        _admit(address(extension));
        hook.installExtension(poolKey, IHookExtension(address(extension)), _settings(SWAP_CALLBACKS, false, false));

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        assertTrue(hook.hasPoolRole(poolId, configurerRole, alice));
        vm.prank(alice);
        hook.activateExtension(poolKey, IHookExtension(address(extension)));
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }

    function test_grantPoolRole_revertsWhenAdminIsGrantedBeforeInitialization() public {
        hook.preparePool(poolKey);
        vm.expectRevert(IKernelHook.InvalidRole.selector);
        hook.grantPoolRole(poolKey, adminRole, alice);
    }

    function test_grantPoolRole_revertsWhenCallerIsNotTheInitializerOfAPreparedPool() public {
        hook.preparePool(poolKey);
        vm.prank(alice);
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.grantPoolRole(poolKey, configurerRole, alice);
    }

    function test_grantPoolRole_revertsWhenPoolIsNotPrepared() public {
        vm.expectRevert(IKernelHook.PoolNotPrepared.selector);
        hook.grantPoolRole(poolKey, configurerRole, alice);
    }

    // ---------------------------------------------------------------- roles after initialization

    function test_grantPoolRole_adminGrantsAdmin() public {
        _createPool(poolKey);
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.PoolRoleChanged(poolId, adminRole, alice, true);
        hook.grantPoolRole(poolKey, adminRole, alice);
        assertTrue(hook.hasPoolRole(poolId, adminRole, alice));
    }

    function test_grantPoolRole_secondGrantChangesNothing() public {
        _createPool(poolKey);
        hook.grantPoolRole(poolKey, adminRole, alice);
        vm.recordLogs();
        hook.grantPoolRole(poolKey, adminRole, alice);
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(hook.hasPoolRole(poolId, adminRole, alice));
        // A second grant must not count alice twice: after revoking alice, this contract is the last admin again.
        hook.revokePoolRole(poolKey, adminRole, alice);
        assertFalse(hook.hasPoolRole(poolId, adminRole, alice));
        vm.expectRevert(IKernelHook.LastAdmin.selector);
        hook.revokePoolRole(poolKey, adminRole, address(this));
    }

    function test_grantPoolRole_revertsWhenAccountIsZero() public {
        _createPool(poolKey);
        vm.expectRevert(IKernelHook.InvalidRole.selector);
        hook.grantPoolRole(poolKey, configurerRole, address(0));
    }

    function testFuzz_grantPoolRole_revertsWhenRoleIsUnknown(bytes32 role) public {
        vm.assume(role != adminRole && role != configurerRole);
        _createPool(poolKey);
        vm.expectRevert(IKernelHook.InvalidRole.selector);
        hook.grantPoolRole(poolKey, role, alice);
    }

    function test_grantPoolRole_revertsWhenCallerIsOnlyConfigurer() public {
        _createPool(poolKey);
        hook.grantPoolRole(poolKey, configurerRole, alice);
        vm.prank(alice);
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.grantPoolRole(poolKey, configurerRole, bob);
    }

    function test_revokePoolRole_revertsWhenLastAdminIsRevoked() public {
        _createPool(poolKey);
        vm.expectRevert(IKernelHook.LastAdmin.selector);
        hook.revokePoolRole(poolKey, adminRole, address(this));
    }

    function test_revokePoolRole_roleThatIsNotHeldChangesNothing() public {
        _createPool(poolKey);
        vm.recordLogs();
        hook.revokePoolRole(poolKey, configurerRole, alice);
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(hook.hasPoolRole(poolId, configurerRole, alice));
        assertTrue(hook.hasPoolRole(poolId, adminRole, address(this)));
        vm.expectRevert(IKernelHook.LastAdmin.selector);
        hook.revokePoolRole(poolKey, adminRole, address(this));
    }

    /// @dev Isolates the admin check of revokePoolRole: the pool is known, so only that check can reject.
    function test_revokePoolRole_rejectsOutsiderAndConfigurer() public {
        _createPool(poolKey);
        hook.grantPoolRole(poolKey, configurerRole, alice);

        vm.prank(bob);
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.revokePoolRole(poolKey, configurerRole, alice);
        vm.prank(alice);
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.revokePoolRole(poolKey, adminRole, address(this));

        assertTrue(hook.hasPoolRole(poolId, configurerRole, alice));
        assertTrue(hook.hasPoolRole(poolId, adminRole, address(this)));
    }

    function test_revokePoolRole_clearsHeldConfigurerAndEmitsEvent() public {
        _createPool(poolKey);
        hook.grantPoolRole(poolKey, configurerRole, alice);
        MockExtension extension = new MockExtension(address(hook));
        _admit(address(extension));
        hook.installExtension(poolKey, IHookExtension(address(extension)), _settings(SWAP_CALLBACKS, false, false));

        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.PoolRoleChanged(poolId, configurerRole, alice, false);
        hook.revokePoolRole(poolKey, configurerRole, alice);

        assertFalse(hook.hasPoolRole(poolId, configurerRole, alice));
        vm.prank(alice);
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.activateExtension(poolKey, IHookExtension(address(extension)));
    }

    /// @dev Roles belong to one PoolId. A role in pool A gives no right in pool B, and a change in B leaves A as it is.
    function test_poolRoles_areScopedPerPool() public {
        PoolKey memory otherKey = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        PoolId otherId = otherKey.toId();
        _createPool(poolKey);
        _createPool(otherKey);
        hook.grantPoolRole(poolKey, configurerRole, alice);
        hook.grantPoolRole(otherKey, configurerRole, bob);

        assertFalse(hook.hasPoolRole(otherId, configurerRole, alice));
        uint32[CALLBACK_COUNT] memory budgets;
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            budgets[i] = KernelHookConstants.DEFAULT_CALLBACK_GAS_BUDGET;
        }
        vm.prank(alice);
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.setExecutionLimits(otherKey, 2, budgets);

        hook.revokePoolRole(otherKey, configurerRole, bob);
        assertTrue(hook.hasPoolRole(poolId, configurerRole, alice));
        assertFalse(hook.hasPoolRole(otherId, configurerRole, bob));
        vm.prank(alice);
        hook.setExecutionLimits(poolKey, 2, budgets);
    }

    /// @dev An extension calls each function from inside a swap. The management lock rejects the call first; without
    /// the lock, preparePool would succeed and the role calls would fail with Unauthorized instead.
    function test_preparePool_andRoleChangesRevertDuringCallback() public {
        _createPool(poolKey);
        _addLiquidity(poolKey);
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(poolKey, address(extension), _settings(SWAP_CALLBACKS, false, false));
        PoolKey memory freshKey = PoolKey(currency0, currency1, 100, 1, IHooks(address(hook)));
        bytes[3] memory calls = [
            abi.encodeCall(IKernelHook.preparePool, (freshKey)),
            abi.encodeCall(IKernelHook.grantPoolRole, (poolKey, configurerRole, alice)),
            abi.encodeCall(IKernelHook.revokePoolRole, (poolKey, adminRole, address(this)))
        ];
        bytes memory failure = abi.encodeWithSelector(
            IKernelHook.ExtensionFailed.selector,
            address(extension),
            CallbackType.BeforeSwap,
            abi.encodeWithSelector(IKernelHook.ExecutionInProgress.selector)
        );
        // i < 3
        for (uint256 i; i < 3; ++i) {
            extension.setExternalCall(CallbackType.BeforeSwap, address(hook), calls[i]);
            vm.expectRevert(_hookRevert(IHooks.beforeSwap.selector, failure));
            _swapExactInput(poolKey, true, 1e14);
        }
    }

    function test_revokePoolRole_revertsWhenRoleIsUnknown() public {
        _createPool(poolKey);
        vm.expectRevert(IKernelHook.InvalidRole.selector);
        hook.revokePoolRole(poolKey, keccak256("UNKNOWN_ROLE"), alice);
    }

    /// @dev The factory pattern: the initializer hands the pool to its user and gives up all rights.
    function test_revokePoolRole_initializerHandsPoolToUser() public {
        _createPool(poolKey);
        hook.grantPoolRole(poolKey, adminRole, alice);
        hook.revokePoolRole(poolKey, adminRole, address(this));

        assertFalse(hook.hasPoolRole(poolId, adminRole, address(this)));
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.grantPoolRole(poolKey, configurerRole, bob);
        vm.prank(alice);
        hook.grantPoolRole(poolKey, configurerRole, bob);
        assertTrue(hook.hasPoolRole(poolId, configurerRole, bob));
    }

    function test_configurer_canActivateButCannotInstall() public {
        _createPool(poolKey);
        hook.grantPoolRole(poolKey, configurerRole, alice);
        MockExtension extension = new MockExtension(address(hook));
        _admit(address(extension));

        vm.prank(alice);
        vm.expectRevert(IKernelHook.Unauthorized.selector);
        hook.installExtension(poolKey, IHookExtension(address(extension)), _settings(SWAP_CALLBACKS, false, false));

        hook.installExtension(poolKey, IHookExtension(address(extension)), _settings(SWAP_CALLBACKS, false, false));
        vm.prank(alice);
        hook.activateExtension(poolKey, IHookExtension(address(extension)));
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertTrue(active);
    }
}
