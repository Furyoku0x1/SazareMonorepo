// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {ExecutionContext, CallbackType} from "core/src/types/KernelHookTypes.sol";
import {KernelHookConstants} from "core/src/libraries/KernelHookConstants.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ExtensionRead} from "../libraries/ExtensionRead.sol";

interface IExtensionVault {
    function KERNEL_HOOK() external view returns (address);
    function POOL_MANAGER() external view returns (IPoolManager);
    function routeExecutor() external view returns (address);
    function balanceOf(PoolId pool, address extension, Currency currency) external view returns (uint256);
    function transferInProgress() external view returns (bool);
    function deposit(PoolId pool, address extension, Currency currency, uint256 amount) external payable;
    function withdraw(PoolId pool, Currency currency, uint256 amount, address recipient) external;
}

interface IKernelVaultHost {
    function VAULT() external view returns (IExtensionVault);
}

/// @dev Shared, inlined authentication. This abstract contract is not a separately deployed component.
abstract contract KernelExtension {
    using ExtensionRead for address;

    IKernelHook public immutable KERNEL;
    IExtensionVault internal immutable VAULT;
    IPoolManager internal immutable MANAGER;
    address internal immutable ROUTE_EXECUTOR;

    bytes32 internal constant ADMIN_ROLE = keccak256("POOL_ADMIN_ROLE");
    bytes32 internal constant CONFIGURER_ROLE = keccak256("CONFIGURER_ROLE");
    uint256 internal constant PROFILE_GAS = 100_000;
    uint256 internal constant PROFILE_BYTES = 2048;
    uint256 internal constant ACTIVE = 1;
    uint256 internal constant OPTIONAL = 2;
    uint256 internal constant NESTING = 4;

    bool internal transient _entered;

    error Unauthorized();
    error InvalidConfiguration();
    error ExecutionInProgress();
    error InvalidPool();
    error InvalidVersion();
    error InvalidAmount();
    error OutstandingObligations();

    constructor(IKernelHook kernel) {
        if (address(kernel).code.length == 0) revert InvalidConfiguration();
        IExtensionVault vault = IKernelVaultHost(address(kernel)).VAULT();
        if (address(vault).code.length == 0 || vault.KERNEL_HOOK() != address(kernel)) {
            revert InvalidConfiguration();
        }
        KERNEL = kernel;
        VAULT = vault;
        MANAGER = vault.POOL_MANAGER();
        ROUTE_EXECUTOR = vault.routeExecutor();
    }

    modifier onlyKernel() {
        _requireKernel();
        _;
    }

    modifier publicMutation() {
        _requireIdle();
        _entered = true;
        _;
        _entered = false;
    }

    modifier lifecycle() {
        _requireKernel();
        if (_entered) revert ExecutionInProgress();
        _entered = true;
        _;
        _entered = false;
    }

    function _requireKernel() internal view {
        if (msg.sender != address(KERNEL)) revert Unauthorized();
    }

    function _requireIdle() internal view {
        if (_entered || _vaultTransferInProgress() || _contextDepth() != 0 || KERNEL.ticketCount() != 0) {
            revert ExecutionInProgress();
        }
    }

    function _vaultTransferInProgress() internal view returns (bool) {
        return VAULT.transferInProgress();
    }

    /// @dev Read only the context fields used by public-entry and preview guards.
    /// The immutable Kernel returns twelve static ABI words; avoid decoding and
    /// allocating the unused root ID, sender, callback, origin and prior fields.
    function _contextState() internal view returns (PoolId pool, address extension, uint8 depth) {
        (bool success, bytes memory data) =
            address(KERNEL).read(50_000, 384, abi.encodeCall(IKernelHook.currentContext, ()));
        if (!success || data.length != 384) revert InvalidConfiguration();
        uint256 extensionWord = _word(data, 128);
        uint256 depthWord = _word(data, 192);
        if (extensionWord > type(uint160).max || depthWord > type(uint8).max) revert InvalidConfiguration();
        return (PoolId.wrap(bytes32(_word(data, 64))), address(uint160(extensionWord)), uint8(depthWord));
    }

    function _contextDepth() internal view returns (uint8 depth) {
        (,, depth) = _contextState();
    }

    function _requireRole(PoolId pool) internal view {
        if (!KERNEL.hasPoolRole(pool, ADMIN_ROLE, msg.sender) && !KERNEL.hasPoolRole(pool, CONFIGURER_ROLE, msg.sender))
        {
            revert Unauthorized();
        }
    }

    function _validateKey(PoolKey memory key) internal view returns (PoolId pool) {
        if (address(key.hooks) != address(KERNEL) || key.currency0 >= key.currency1 || key.tickSpacing <= 0) {
            revert InvalidPool();
        }
        pool = key.toId();
    }

    function _profile(PoolId pool, address extension) internal view returns (bool readable, uint256 flags) {
        // Callers only query locally installed instances or members returned by callbackOrder.
        (bool success, bytes memory data) = address(KERNEL)
            .read(PROFILE_GAS, PROFILE_BYTES, abi.encodeCall(IKernelHook.extensionConfiguration, (pool, extension)));
        // ABI header: active, settings offset, seven static Catalog.Entry words. Settings has
        // mask, optional, nesting, lifecycle limit, ten callback limits, then a bytes offset.
        // Read only fixed fields instead of decoding/copying the whole dynamic configuration.
        if (!success || data.length < 800 || _word(data, 32) != 288) return (false, 0);
        uint256 active = _word(data, 0);
        uint256 mask = _word(data, 288);
        uint256 optional = _word(data, 320);
        uint256 nesting = _word(data, 352);
        if (active > 1 || mask > type(uint16).max || optional > 1 || nesting > 1) return (false, 0);
        flags = active | (optional << 1) | (nesting << 2) | (mask << 16);
        // Kernel checks the copied hash before callbacks; quotes also exclude changed code.
        readable = extension.codehash == bytes32(_word(data, 64));
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (uint256 value) {
        assembly ("memory-safe") { value := mload(add(add(data, 32), offset)) }
    }

    function _callbackFits(PoolId pool, CallbackType callback, uint32 limit, uint256 subscribers, bool nesting)
        internal
        view
        returns (bool)
    {
        // poolState: status, initializer, depth, then ten budget words. Read only the needed fields.
        (bool success, bytes memory data) =
            address(KERNEL).read(50_000, 416, abi.encodeCall(IKernelHook.poolState, (pool)));
        if (!success || data.length != 416 || (nesting && _word(data, 64) < 2)) return false;
        uint256 required = uint256(limit) + uint256(limit) / 31 + KernelHookConstants.INVOCATION_GAS_RESERVE
            + KernelHookConstants.SETTLEMENT_GAS_RESERVE + KernelHookConstants.RETURN_GAS_RESERVE
            + KernelHookConstants.SEQUENCE_GAS_RESERVE + subscribers
            * (KernelHookConstants.ITERATION_GAS_RESERVE + KernelHookConstants.SUBSCRIBER_GAS_RESERVE);
        return _word(data, 96 + uint256(uint8(callback)) * 32) >= required;
    }

    function _version(bytes calldata configuration) internal pure returns (uint64) {
        if (configuration.length != 32) revert InvalidConfiguration();
        return abi.decode(configuration, (uint64));
    }

    function _authenticate(ExecutionContext memory context, PoolKey memory key) internal view {
        if (_entered || _vaultTransferInProgress()) revert ExecutionInProgress();
        _authenticateContext(context, key);
    }

    function _authenticateContext(ExecutionContext memory context, PoolKey memory key) internal view {
        if (
            context.extension != address(this) || context.depth == 0
                || PoolId.unwrap(key.toId()) != PoolId.unwrap(context.poolId)
        ) {
            revert Unauthorized();
        }
        if (context.depth > 1 && context.sender != ROUTE_EXECUTOR) revert Unauthorized();
        _validateKey(key);
    }
}
