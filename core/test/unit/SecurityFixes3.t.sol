// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {IHookCatalog} from "../../src/interfaces/IHookCatalog.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {CallbackLibrary} from "../../src/libraries/CallbackLibrary.sol";
import {BoundedCall} from "../../src/libraries/BoundedCall.sol";
import {CallbackType, Operation, RouteAction} from "../../src/types/KernelHookTypes.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @dev Receives native currency from the vault and, as a side effect, leaves an ERC20 sync pending.
contract SyncingRecipient {
    IPoolManager internal immutable MANAGER;
    Currency internal immutable TOKEN;

    constructor(IPoolManager manager, Currency token) {
        MANAGER = manager;
        TOKEN = token;
    }

    receive() external payable {
        MANAGER.sync(TOKEN);
    }
}

/// @dev Pays through the extension, then clears whatever sync the payee left, as an extension could after any untrusted
/// callee returns.
contract PayThenReset {
    function run(MockExtension payer, IPoolManager manager, PoolId pool, address to) external {
        payer.withdraw(pool, Currency.wrap(address(0)), 1, to);
        manager.sync(Currency.wrap(address(0)));
    }
}

contract Round3SecurityTest is KernelHookFixture {
    using CallbackLibrary for CallbackType;
    using StateLibrary for IPoolManager;

    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        key = _poolKey();
        _createPool(key);
        _addLiquidity(key);
    }

    function testFuzz_rootOptionalFailureStillSkips(bool afterSwap) public {
        CallbackType callback = afterSwap ? CallbackType.AfterSwap : CallbackType.BeforeSwap;
        MockExtension failing = _optionalExtension(key, SWAP_CALLBACKS, false, 300_000);
        bytes memory reason = _setOptionalFailure(failing, callback, 0);
        bytes32 stateBefore = _poolStateHash(key.toId());

        _expectOptionalSkip(key, failing, callback, reason);
        _swapExactInput(key, true, 1e14);

        assertNotEq(_poolStateHash(key.toId()), stateBefore);
        assertEq(failing.callCount(CallbackType.BeforeSwap), afterSwap ? 1 : 0);
        assertEq(failing.callCount(CallbackType.AfterSwap), 0);
        assertEq(hook.currentContext().depth, 0);
    }

    // R3-1: failures in a fresh target must roll back the route, including an already executed target swap.
    function testFuzz_freshPoolOptionalFailureSkipsOrigin(bool afterSwap, uint8 failureKind) public {
        failureKind = uint8(bound(failureKind, 0, 2));
        PoolKey memory target = _freshPool();
        CallbackType callback = afterSwap ? CallbackType.AfterSwap : CallbackType.BeforeSwap;
        MockExtension failing = _optionalExtension(target, SWAP_CALLBACKS, false, 300_000);
        MockExtension origin = _optionalExtension(key, CallbackType.AfterSwap.mask(), true, 2_500_000);
        _fundRoute(origin, key.toId());
        origin.addRouteAction(CallbackType.AfterSwap, _swapAction(target));
        bytes memory reason = _setOptionalFailure(failing, callback, failureKind);
        bytes memory failure = abi.encodeWithSelector(IKernelHook.ExtensionFailed.selector, failing, callback, reason);
        bytes4 selector = afterSwap ? IHooks.afterSwap.selector : IHooks.beforeSwap.selector;
        bytes memory routeReason = _hookRevert(selector, failure);
        // The originating attempt receives only BoundedCall's prefix of the PoolManager wrapper.
        uint256 maximumReasonBytes = BoundedCall.MAX_RETURNDATA_BYTES;
        if (routeReason.length > maximumReasonBytes) {
            assembly ("memory-safe") {
                mstore(routeReason, maximumReasonBytes)
            }
        }
        bytes32 targetStateBefore = _poolStateHash(target.toId());
        uint256 balance0Before = hook.VAULT().balanceOf(key.toId(), address(origin), currency0);
        uint256 balance1Before = hook.VAULT().balanceOf(key.toId(), address(origin), currency1);

        _expectOptionalSkip(key, origin, CallbackType.AfterSwap, routeReason);
        _swapExactInput(key, true, 1e14);

        assertEq(_poolStateHash(target.toId()), targetStateBefore);
        assertEq(origin.callCount(CallbackType.AfterSwap), 0);
        assertEq(origin.lastRouteResults().length, 0);
        assertEq(failing.callCount(CallbackType.BeforeSwap), 0);
        assertEq(failing.callCount(CallbackType.AfterSwap), 0);
        assertEq(hook.VAULT().balanceOf(key.toId(), address(origin), currency0), balance0Before);
        assertEq(hook.VAULT().balanceOf(key.toId(), address(origin), currency1), balance1Before);
        assertEq(Currency.unwrap(TransientStateLibrary.getSyncedCurrency(manager)), address(0));
        assertEq(hook.currentContext().depth, 0);
    }

    /// @dev Round-4 pre-audit: a route back into a pool further up the stack, started by another pool's extension, used
    /// to let that pool's optional extensions be skipped, so an attacker's pool could re-enter a book pool and have its
    /// book skipped. Such a reentry is now strict: the failure fails the returning route, then the route that entered
    /// the other pool, and the root skips only the originating extension.
    function test_reentryFromAnotherPoolIsStrict() public {
        PoolKey memory target = _freshPool();
        MockExtension failing = _optionalExtension(key, CallbackType.BeforeSwap.mask(), false, 300_000);
        MockExtension origin = _optionalExtension(key, CallbackType.AfterSwap.mask(), true, 2_500_000);
        MockExtension returning = _optionalExtension(target, CallbackType.AfterSwap.mask(), true, 1_200_000);
        _fundRoute(origin, key.toId());
        _fundRoute(returning, target.toId());
        origin.addRouteAction(CallbackType.AfterSwap, _swapAction(target));
        returning.addRouteAction(CallbackType.AfterSwap, _swapAction(key));
        _setOptionalFailure(failing, CallbackType.BeforeSwap, 0);
        bytes32 targetStateBefore = _poolStateHash(target.toId());

        vm.recordLogs();
        _swapExactInput(key, true, 1e14);

        assertEq(_skipsOf(vm.getRecordedLogs(), address(origin)), 1, "the root skips the originating extension");
        assertEq(origin.callCount(CallbackType.AfterSwap), 0, "its route rolled back");
        assertEq(returning.callCount(CallbackType.AfterSwap), 0, "the returning route rolled back");
        assertEq(_poolStateHash(target.toId()), targetStateBefore, "the other pool is untouched");
        assertEq(hook.currentContext().depth, 0);
    }

    /// @dev A route from a pool into itself is the pool's own (the order book's move back skips the book's own
    /// callbacks): an optional failure there still skips.
    function test_routeIntoItsOwnPoolStillSkips() public {
        MockExtension failing = _optionalExtension(key, CallbackType.BeforeSwap.mask(), false, 300_000);
        MockExtension origin = _optionalExtension(key, CallbackType.AfterSwap.mask(), true, 2_500_000);
        _fundRoute(origin, key.toId());
        origin.addRouteAction(CallbackType.AfterSwap, _swapAction(key));
        bytes memory reason = _setOptionalFailure(failing, CallbackType.BeforeSwap, 0);

        _expectOptionalSkip(key, failing, CallbackType.BeforeSwap, reason);
        _expectOptionalSkip(key, failing, CallbackType.BeforeSwap, reason);
        _swapExactInput(key, true, 1e14);

        assertEq(origin.callCount(CallbackType.AfterSwap), 1, "the same-pool route ran");
        assertEq(origin.lastRouteResults().length, 1);
        assertEq(failing.callCount(CallbackType.BeforeSwap), 0, "the failing extension was skipped both times");
        assertEq(hook.currentContext().depth, 0);
    }

    /// @dev Round 4, R4-1 (from reviewer K4's PoC): the route from the other pool back into the pool finds the
    /// pool's optional extension mid-call. It used to be skipped there, so another pool could run a swap in a book pool
    /// while the book was skipped. The returning route now fails, then the route that entered the other pool, and the
    /// root skips only the originating extension.
    function test_reentrySkipFromAnotherPoolIsStrict() public {
        PoolKey memory target = _freshPool();
        MockExtension origin =
            _optionalExtension(key, CallbackType.BeforeSwap.mask() | CallbackType.AfterSwap.mask(), true, 2_500_000);
        MockExtension returning = _optionalExtension(target, CallbackType.AfterSwap.mask(), true, 1_200_000);
        _fundRoute(origin, key.toId());
        _fundRoute(returning, target.toId());
        origin.addRouteAction(CallbackType.AfterSwap, _swapAction(target));
        returning.addRouteAction(CallbackType.AfterSwap, _swapAction(key));
        bytes32 targetStateBefore = _poolStateHash(target.toId());

        vm.recordLogs();
        _swapExactInput(key, true, 1e14);

        assertEq(_skipsOf(vm.getRecordedLogs(), address(origin)), 1, "the root skips the originating extension");
        assertEq(origin.callCount(CallbackType.BeforeSwap), 1, "it ran in the root swap only");
        assertEq(origin.callCount(CallbackType.AfterSwap), 0, "its route rolled back");
        assertEq(returning.lastRouteResults().length, 0, "the returning route rolled back");
        assertEq(_poolStateHash(target.toId()), targetStateBefore, "the other pool is untouched");
    }

    /// @dev Round 4, R4-4's counterpart: in a route from a pool into itself, an optional extension that the pool's
    /// budget cannot fit is still skipped, as in the root.
    function test_routeIntoItsOwnPoolStillSkipsOnTheBudget() public {
        MockExtension unaffordable = _optionalExtension(key, CallbackType.BeforeSwap.mask(), false, 3_600_000);
        MockExtension origin = _optionalExtension(key, CallbackType.AfterSwap.mask(), true, 2_500_000);
        _fundRoute(origin, key.toId());
        origin.addRouteAction(CallbackType.AfterSwap, _swapAction(key));
        bytes memory reason = abi.encodeWithSelector(IKernelHook.GasBudgetExceeded.selector);

        _expectOptionalSkip(key, unaffordable, CallbackType.BeforeSwap, reason);
        _expectOptionalSkip(key, unaffordable, CallbackType.BeforeSwap, reason);
        _swapExactInput(key, true, 1e14);

        assertEq(origin.lastRouteResults().length, 1, "the same-pool route ran");
        assertEq(unaffordable.callCount(CallbackType.BeforeSwap), 0);
    }

    function _skipsOf(Vm.Log[] memory logs, address extension) private pure returns (uint256 skips) {
        bytes32 topic = IKernelHook.ExtensionSkipped.selector;
        // i < logs.length
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            if (logs[i].topics.length < 3) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) == extension) ++skips;
        }
    }

    function test_unwindChildOptionalFailureStillSkips() public {
        PoolKey memory target = _freshPool();
        MockExtension failing = _optionalExtension(target, CallbackType.BeforeRemoveLiquidity.mask(), false, 300_000);
        MockExtension origin = _optionalExtension(key, CallbackType.AfterSwap.mask(), true, 2_500_000);
        _fundRoute(origin, key.toId());
        origin.addRouteAction(CallbackType.AfterSwap, _liquidityAction(target, 1e12));
        _swapExactInput(key, true, 1e14);
        assertEq(hook.ROUTE_EXECUTOR().openPositionCount(key.toId(), address(origin)), 1);
        hook.deactivateExtension(key, origin);
        bytes memory reason = _setOptionalFailure(failing, CallbackType.BeforeRemoveLiquidity, 0);
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _liquidityAction(target, -1e12);
        uint256 balanceBefore = hook.VAULT().balanceOf(key.toId(), address(origin), currency0);

        _expectOptionalSkip(target, failing, CallbackType.BeforeRemoveLiquidity, reason);
        origin.unwindPositions(key, actions);

        assertEq(hook.ROUTE_EXECUTOR().openPositionCount(key.toId(), address(origin)), 0);
        assertEq(
            hook.ROUTE_EXECUTOR().positionLiquidity(key.toId(), address(origin), target.toId(), -120, 120, bytes32(0)),
            0
        );
        assertGt(hook.VAULT().balanceOf(key.toId(), address(origin), currency0), balanceBefore);
        assertEq(failing.callCount(CallbackType.BeforeRemoveLiquidity), 0);
        assertEq(hook.currentContext().depth, 0);
    }

    function _freshPool() internal returns (PoolKey memory target) {
        target = key;
        target.fee = 500;
        _createPool(target);
        _addLiquidity(target);
    }

    function _optionalExtension(PoolKey memory pool, uint16 mask, bool nesting, uint32 gasLimit)
        internal
        returns (MockExtension extension)
    {
        extension = new MockExtension(address(hook));
        _installAndActivate(pool, address(extension), _settings(mask, true, nesting, gasLimit));
    }

    function _setOptionalFailure(MockExtension extension, CallbackType callback, uint8 failureKind)
        internal
        returns (bytes memory)
    {
        if (failureKind == 0) {
            extension.setBehavior(callback, MockExtension.Behavior(0, 0, 0, true, 0));
            return abi.encodeWithSelector(MockExtension.MockRevert.selector, callback);
        }
        if (failureKind == 1) {
            extension.setBehavior(callback, MockExtension.Behavior(0, 0, 1, false, 0));
            return abi.encodeWithSelector(IKernelHook.InvalidFeeOverride.selector);
        }
        extension.setExternalCall(callback, address(manager), abi.encodeCall(IPoolManager.sync, (currency0)));
        return abi.encodeWithSelector(IKernelHook.UnexpectedAccounting.selector);
    }

    function _fundRoute(MockExtension extension, PoolId pool) internal {
        MockERC20(Currency.unwrap(currency0)).mint(address(extension), 1e16);
        MockERC20(Currency.unwrap(currency1)).mint(address(extension), 1e16);
        extension.deposit(pool, currency0, 1e16);
        extension.deposit(pool, currency1, 1e16);
    }

    function _swapAction(PoolKey memory target) internal pure returns (RouteAction memory) {
        return RouteAction(target, Operation.Swap, abi.encode(_exactInputParameters(true, 1e12)), "");
    }

    function _liquidityAction(PoolKey memory target, int256 liquidityDelta) internal pure returns (RouteAction memory) {
        return RouteAction(target, Operation.ModifyLiquidity, abi.encode(_liquidityParameters(liquidityDelta)), "");
    }

    function _poolStateHash(PoolId pool) internal view returns (bytes32) {
        (uint160 squareRootPriceX96, int24 tick, uint24 protocolFee, uint24 liquidityProviderFee) =
            manager.getSlot0(pool);
        (uint256 feeGrowth0X128, uint256 feeGrowth1X128) = manager.getFeeGrowthGlobals(pool);
        return keccak256(
            abi.encode(
                squareRootPriceX96,
                tick,
                protocolFee,
                liquidityProviderFee,
                manager.getLiquidity(pool),
                feeGrowth0X128,
                feeGrowth1X128
            )
        );
    }

    function _expectOptionalSkip(
        PoolKey memory pool,
        MockExtension extension,
        CallbackType callback,
        bytes memory reason
    ) internal {
        vm.expectEmit(true, true, true, true, address(hook));
        emit IKernelHook.ExtensionSkipped(pool.toId(), address(extension), callback, reason);
    }

    // R3-6 / FX-7: preserve shared subscriptions and place new required ones before optional ones.
    function test_maskChangePreservesOrderNextToFundedOptional() public {
        MockExtension first = _extension(false, SWAP_CALLBACKS, false);
        MockExtension second = _extension(false, SWAP_CALLBACKS, false);
        MockExtension optional = _extension(true, SWAP_CALLBACKS, true);
        MockERC20(Currency.unwrap(currency0)).mint(address(optional), 1000);
        optional.deposit(key.toId(), currency0, 1000);
        vm.expectRevert(IKernelHook.OutstandingObligations.selector);
        hook.removeExtension(key, optional);
        hook.configureExtension(key, first, _settings(SWAP_CALLBACKS | CallbackType.AfterDonate.mask(), false, false));
        _assertSwapOrder(address(first), address(second), address(optional));
        hook.activateExtension(key, first);
        hook.activateExtension(key, second);
        hook.activateExtension(key, optional);
        _swapExactInput(key, true, 1e14);
        assertEq(optional.callCount(CallbackType.AfterSwap), 1);
    }

    function test_installRequiredAfterOptionalPlacesItBeforeOptional() public {
        MockExtension optional = _extension(true, SWAP_CALLBACKS, true);
        MockExtension first = _extension(false, SWAP_CALLBACKS, false);
        MockExtension second = _extension(false, SWAP_CALLBACKS, false);
        _assertSwapOrder(address(first), address(second), address(optional));
        hook.configureExtension(key, first, _settings(SWAP_CALLBACKS, false, false));
        hook.activateExtension(key, optional);
        hook.activateExtension(key, first);
        hook.activateExtension(key, second);
        _swapExactInput(key, true, 1e14);
        assertEq(second.callCount(CallbackType.AfterSwap), 1);
    }

    function test_newRequiredSubscriptionPrecedesOptional() public {
        MockExtension optional = _extension(true, SWAP_CALLBACKS, true);
        MockExtension requiredExtension = _extension(false, CallbackType.AfterDonate.mask(), false);
        hook.configureExtension(key, requiredExtension, _settings(SWAP_CALLBACKS, false, false));
        // the two swap callbacks
        for (uint8 i = uint8(CallbackType.BeforeSwap); i <= uint8(CallbackType.AfterSwap); ++i) {
            address[] memory order = hook.callbackOrder(key.toId(), CallbackType(i));
            assertEq(order.length, 2);
            assertEq(order[0], address(requiredExtension));
            assertEq(order[1], address(optional));
        }
        assertEq(hook.callbackOrder(key.toId(), CallbackType.AfterDonate).length, 0);
        hook.activateExtension(key, requiredExtension);
    }

    function test_optionalMadeRequiredMovesBeforeOptional() public {
        MockExtension first = _extension(true, SWAP_CALLBACKS, true);
        MockExtension changed = _extension(true, SWAP_CALLBACKS, true);
        MockExtension last = _extension(true, SWAP_CALLBACKS, true);
        hook.configureExtension(key, changed, _settings(SWAP_CALLBACKS, false, false));
        _assertSwapOrder(address(changed), address(first), address(last));
        hook.activateExtension(key, changed);
    }

    function test_requiredMadeOptionalMovesToEnd() public {
        MockExtension changed = _extension(true, SWAP_CALLBACKS, false);
        MockExtension requiredExtension = _extension(false, SWAP_CALLBACKS, false);
        MockExtension optional = _extension(true, SWAP_CALLBACKS, true);
        hook.activateExtension(key, requiredExtension);
        hook.configureExtension(key, changed, _settings(SWAP_CALLBACKS, true, false));
        _assertSwapOrder(address(requiredExtension), address(optional), address(changed));
        hook.activateExtension(key, changed);
    }

    function _extension(bool supportsOptional, uint16 mask, bool optional) internal returns (MockExtension extension) {
        extension = new MockExtension(address(hook));
        catalog.admit(
            address(extension),
            IHookCatalog.Entry(
                address(extension).codehash,
                CallbackLibrary.ALL_CALLBACKS_MASK,
                supportsOptional,
                true,
                true,
                true,
                true
            )
        );
        hook.installExtension(key, extension, _settings(mask, optional, false));
    }

    function _assertSwapOrder(address first, address second, address third) internal view {
        // the two swap callbacks
        for (uint8 i = uint8(CallbackType.BeforeSwap); i <= uint8(CallbackType.AfterSwap); ++i) {
            address[] memory order = hook.callbackOrder(key.toId(), CallbackType(i));
            assertEq(order.length, 3);
            assertEq(order[0], first);
            assertEq(order[1], second);
            assertEq(order[2], third);
        }
    }

    /// @dev The defence: sync(native) after the untrusted callee resets the synced currency, and getSyncedReserves
    /// then reads 0, so the attempt's (currency, reserves) snapshot of (0, 0) matches again.
    function test_syncNativeAfterUntrustedCalleeRestoresSnapshot() public {
        MockExtension payer = new MockExtension(address(hook));
        _installAndActivate(key, address(payer), _settings(CallbackType.BeforeSwap.mask(), true, false, 500_000));
        vm.deal(address(this), 1 ether);
        payer.deposit{value: 1 ether}(key.toId(), Currency.wrap(address(0)), 1 ether);
        SyncingRecipient griefer = new SyncingRecipient(manager, currency0);
        PayThenReset helper = new PayThenReset();
        payer.setExternalCall(
            CallbackType.BeforeSwap,
            address(helper),
            abi.encodeCall(PayThenReset.run, (payer, manager, key.toId(), address(griefer)))
        );
        _swapExactInput(key, true, 1e14);
        assertEq(payer.callCount(CallbackType.BeforeSwap), 1, "attempt kept after sync(native)");
        assertEq(address(griefer).balance, 1);
        assertEq(hook.VAULT().balanceOf(key.toId(), address(payer), Currency.wrap(address(0))), 1 ether - 1);
        assertEq(Currency.unwrap(TransientStateLibrary.getSyncedCurrency(manager)), address(0));
    }
}
