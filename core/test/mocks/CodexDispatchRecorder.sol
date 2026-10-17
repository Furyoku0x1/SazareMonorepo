// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHookExtension} from "../../src/interfaces/IKernelHookExtension.sol";
import {CallbackResult, CallbackType, ExecutionContext, ExtensionSettings} from "../../src/types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Emits a receipt so tests can observe the actual callback order.
contract CodexDispatchRecorder is IKernelHookExtension {
    event CallbackReceived(address indexed extension, CallbackType indexed callback);

    uint256 public gasToBurn;

    function setGasToBurn(uint256 amount) external {
        gasToBurn = amount;
    }

    function onInstall(PoolKey calldata, ExtensionSettings calldata) external pure returns (bytes4) {
        return IKernelHookExtension.onInstall.selector;
    }

    function onConfigure(PoolKey calldata, ExtensionSettings calldata, ExtensionSettings calldata)
        external
        pure
        returns (bytes4)
    {
        return IKernelHookExtension.onConfigure.selector;
    }

    function canActivate(PoolKey calldata, ExtensionSettings calldata) external pure returns (bool) {
        return true;
    }

    function canUninstall(PoolKey calldata) external pure returns (bool) {
        return true;
    }

    function onUninstall(PoolKey calldata, bytes calldata) external pure returns (bytes4) {
        return IKernelHookExtension.onUninstall.selector;
    }

    function onCallback(ExecutionContext calldata context, PoolKey calldata, bytes calldata)
        external
        returns (CallbackResult memory result)
    {
        emit CallbackReceived(address(this), context.callback);
        uint256 start = gasleft();
        while (start - gasleft() < gasToBurn) {}
        return result;
    }
}
