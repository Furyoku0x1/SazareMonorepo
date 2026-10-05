/// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookExtension} from "./interfaces/IHookExtension.sol";
import {IHookCatalog} from "./interfaces/IHookCatalog.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";

contract KernelHook is BaseHook {
    enum HookType {
        BeforeInitialize,
        AfterInitialize,
        BeforeSwap,
        AferSwap,
        BeforeAddLiquidity,
        AfterAddLiquidity,
        BeforeRemoveLiquidity,
        AfterRemoveLiquidity,
        BeforeDonate,
        AfterDonate
    }
    /// Storage
    mapping(PoolId => IHookExtension[]) public beforeInitializeExtensions;
    mapping(PoolId => IHookExtension[]) public afterInitializeExtensions;
    mapping(PoolId => IHookExtension[]) public beforeSwapExtensions;
    mapping(PoolId => IHookExtension[]) public afterSwapExtensions;
    mapping(PoolId => IHookExtension[]) public beforeAddLiquidityExtensions;
    mapping(PoolId => IHookExtension[]) public afterAddLiquidityExtensions;
    mapping(PoolId => IHookExtension[]) public beforeRemoveLiquidityExtensions;
    mapping(PoolId => IHookExtension[]) public afterRemoveLiquidityExtensions;
    mapping(PoolId => IHookExtension[]) public beforeDonateExtensions;
    mapping(PoolId => IHookExtension[]) public afterDonateExtensions;

    mapping(PoolId => bool) public isPoolInitialized;
    mapping(PoolId => mapping(bytes32 => mapping(address => bool))) public poolRoles;

    IHookCatalog public immutable CATALOG;

    bytes32 public constant CONFIGURER_ROLE = keccak256("CONFIGURER_ROLE");
    bytes32 public constant POOL_ADMIN_ROLE = keccak256("POOL_ADMIN_ROLE");

    /// EVENTS

    event KernelHook__PoolInitialized(address indexed initializer, PoolId poolId);
    event KernelHook__GrantRole(address indexed admin, address indexed user, PoolId poolId, bytes32 role);
    event KernelHook__RevokeRole(address indexed admin, address indexed user, PoolId poolId, bytes32 role);

    /// ERROR

    error KernelHook__PoolIsInitialized();
    error KernelHook__PoolAdminOnly();
    error KernelHook__InvalidRole();

    /// CONSTRUCTOR

    constructor(IPoolManager _poolManager, address _hookCatalog) BaseHook(_poolManager) {
        CATALOG = IHookCatalog(_hookCatalog);
    }

    /// HOOK ADMIN FUNCTIONS

    function activateHook(PoolKey calldata key, IHookExtension hook, HookType hookType) external {}

    function installHook(PoolKey calldata key, IHookExtension hook, HookType hookType) external {}

    function deactivateHook(PoolKey calldata key, IHookExtension hook, HookType hookType) external {}

    function removeHook(PoolKey calldata key, IHookExtension hook, HookType hookType) external {}

    function prepareHook(PoolKey calldata key) external {
        PoolId id = key.toId();
        if (isPoolInitialized[id]) revert KernelHook__PoolIsInitialized();
        isPoolInitialized[id] = true;
        _grantRole(id, msg.sender, POOL_ADMIN_ROLE);
        emit KernelHook__PoolInitialized(msg.sender, id);
    }

    function grantPoolRoles(PoolKey calldata key, address user, bytes32 role) external {
        PoolId id = key.toId();
        /// @dev this also checks if the pool has been initialized already so we do not need to check that.
        if (!_hasRole(id, msg.sender, POOL_ADMIN_ROLE)) revert KernelHook__PoolAdminOnly();
        if (role != POOL_ADMIN_ROLE || role != CONFIGURER_ROLE) revert KernelHook__InvalidRole();
        _grantRole(id, user, role);
        emit KernelHook__GrantRole(msg.sender, user, id, role);
    }

    function revokePoolRoles(PoolKey calldata key, address user, bytes32 role) external {
        PoolId id = key.toId();
        if (!_hasRole(id, msg.sender, POOL_ADMIN_ROLE)) revert KernelHook__PoolAdminOnly();
        if (role != POOL_ADMIN_ROLE || role != CONFIGURER_ROLE) revert KernelHook__InvalidRole();
        _revokeRole(id, user, role);
        emit KernelHook__RevokeRole(msg.sender, user, id, role);
    }

    /// HOOK FUNCTIONS

    /// @dev set all possible flags to true so that any future hooks added to the catalog can be integrated
    //  into the primary kernel hook.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /// VIEW FUNCTIONS

    /// INTERAL FUNCTIONS

    function _grantRole(PoolId id, address user, bytes32 role) private {
        poolRoles[id][role][user] = true;
    }

    function _revokeRole(PoolId id, address user, bytes32 role) private {
        poolRoles[id][role][user] = false;
    }

    function _hasRole(PoolId id, address user, bytes32 role) private view returns (bool) {
        return poolRoles[id][role][user];
    }
}
