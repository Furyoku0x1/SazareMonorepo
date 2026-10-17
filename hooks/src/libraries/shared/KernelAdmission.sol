// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {KernelHookConstants} from "core/src/libraries/KernelHookConstants.sol";
import {CallbackType} from "core/src/types/KernelHookTypes.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ExtensionRead} from "./ExtensionRead.sol";
import {KernelExtension} from "../../base/KernelExtension.sol";

/// @dev Role and callback admission checks shared by KernelExtension and the libraries of its inheritors. Internal, so
/// each caller compiles its own copy: no library to deploy or link.
library KernelAdmission {
    using ExtensionRead for address;

    function callbackFits(
        IKernelHook kernel,
        PoolId pool,
        CallbackType callback,
        uint32 limitGas,
        uint256 subscribers,
        bool nesting
    ) internal view returns (bool) {
        // poolState: status, initializer, depth, then ten budget words. Read only the needed fields.
        (bool success, bytes memory stateBytes) =
            address(kernel).read(50_000, 416, abi.encodeCall(IKernelHook.poolState, (pool)));
        if (!success) return false;
        if (stateBytes.length != 416) return false;
        if (nesting) {
            if (_word(stateBytes, 64) < 2) return false;
        }
        uint256 requiredGas = uint256(limitGas) + uint256(limitGas) / 31 + KernelHookConstants.INVOCATION_GAS_RESERVE
            + KernelHookConstants.SETTLEMENT_GAS_RESERVE + KernelHookConstants.RETURN_GAS_RESERVE
            + KernelHookConstants.SEQUENCE_GAS_RESERVE + subscribers
            * (KernelHookConstants.ITERATION_GAS_RESERVE + KernelHookConstants.SUBSCRIBER_GAS_RESERVE);
        return _word(stateBytes, 96 + uint256(uint8(callback)) * 32) >= requiredGas;
    }

    function _word(bytes memory dataBytes, uint256 offset) private pure returns (uint256 value) {
        assembly ("memory-safe") { value := mload(add(add(dataBytes, 32), offset)) }
    }

    /// @dev Checks msg.sender: in an extension, or in a library function it delegatecalls, that is the extension's caller.
    function requireRole(IKernelHook kernel, PoolId pool) internal view {
        if (kernel.hasPoolRole(pool, KernelHookConstants.POOL_ADMIN_ROLE, msg.sender)) return;
        if (!kernel.hasPoolRole(pool, KernelHookConstants.CONFIGURER_ROLE, msg.sender)) {
            revert KernelExtension.Unauthorized();
        }
    }
}
