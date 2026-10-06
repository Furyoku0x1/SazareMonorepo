// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelHook} from "../../src/KernelHook.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";
import {IKernelHookExtension} from "../../src/interfaces/IKernelHookExtension.sol";
import {CallbackResult, ExecutionContext, ExtensionSettings} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Exercises lifecycle response validation and management calls made by an extension.
contract CodexLifecycleExtension is IKernelHookExtension {
    address public immutable KERNEL_HOOK;
    KernelHookVault public immutable VAULT;
    mapping(bytes4 => uint8) public responseMode;
    bytes public managementCall;
    Currency public uninstallCurrency;
    uint256 public uninstallDeposit;

    error LifecycleReverted();
    event LifecycleCalled(bytes4 selector);

    constructor(address kernelHook) {
        KERNEL_HOOK = kernelHook;
        VAULT = KernelHook(kernelHook).VAULT();
    }

    /// @dev Modes: 0 correct, 1 revert, 2 wrong selector or false, 3 empty, 4 oversized, 5 invalid bool.
    function setResponseMode(bytes4 selector, uint8 mode) external {
        responseMode[selector] = mode;
    }

    function setManagementCall(bytes calldata data) external {
        managementCall = data;
    }

    function setUninstallDeposit(Currency currency, uint256 amount) external {
        uninstallCurrency = currency;
        uninstallDeposit = amount;
    }

    function deposit(PoolId poolId, Currency currency, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).approve(address(VAULT), amount);
        VAULT.deposit(poolId, address(this), currency, amount);
    }

    function withdraw(PoolId poolId, Currency currency, uint256 amount, address to) external {
        VAULT.withdraw(poolId, currency, amount, to);
    }

    function onInstall(PoolKey calldata, ExtensionSettings calldata) external returns (bytes4) {
        return _selectorResponse(msg.sig);
    }

    function onConfigure(PoolKey calldata, ExtensionSettings calldata, ExtensionSettings calldata)
        external
        returns (bytes4)
    {
        return _selectorResponse(msg.sig);
    }

    function canActivate(PoolKey calldata, ExtensionSettings calldata) external view returns (bool) {
        return _boolResponse(msg.sig);
    }

    function canUninstall(PoolKey calldata) external view returns (bool) {
        return _boolResponse(msg.sig);
    }

    function onUninstall(PoolKey calldata key, bytes calldata) external returns (bytes4) {
        if (uninstallDeposit != 0) {
            IERC20(Currency.unwrap(uninstallCurrency)).approve(address(VAULT), uninstallDeposit);
            VAULT.deposit(key.toId(), address(this), uninstallCurrency, uninstallDeposit);
        }
        return _selectorResponse(msg.sig);
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata, bytes calldata)
        external
        returns (CallbackResult memory result)
    {
        if (managementCall.length == 0) return result;
        (bool success, bytes memory reason) = KERNEL_HOOK.call(managementCall);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _selectorResponse(bytes4 selector) private returns (bytes4) {
        uint8 mode = responseMode[selector];
        _validateResponseLength(mode);
        emit LifecycleCalled(selector);
        return mode == 2 ? bytes4(0xdeadbeef) : selector;
    }

    function _boolResponse(bytes4 selector) private view returns (bool) {
        uint8 mode = responseMode[selector];
        _validateResponseLength(mode);
        if (mode == 5) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return mode != 2;
    }

    function _validateResponseLength(uint8 mode) private pure {
        if (mode == 1) revert LifecycleReverted();
        if (mode == 3) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == 4) {
            assembly ("memory-safe") {
                return(0, 64)
            }
        }
    }
}
