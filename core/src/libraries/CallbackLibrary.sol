// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CallbackType, CALLBACK_COUNT, Operation} from "../types/KernelHookTypes.sol";

/// @notice Helpers for CallbackType values and callback masks. In a mask, bit i stands for CallbackType(i).
library CallbackLibrary {
    /// @notice A mask with all callbacks.
    uint16 internal constant ALL_CALLBACKS_MASK = uint16((1 << CALLBACK_COUNT) - 1);

    /// @notice A mask with BeforeInitialize and AfterInitialize.
    uint16 internal constant INITIALIZATION_CALLBACKS_MASK = 0x0003;

    /// @notice Returns the mask bit of callback.
    function mask(CallbackType callback) internal pure returns (uint16) {
        return uint16(1) << uint8(callback);
    }

    /// @notice Returns true if callbackMask includes callback.
    function includes(uint16 callbackMask, CallbackType callback) internal pure returns (bool) {
        return callbackMask & mask(callback) != 0;
    }

    /// @notice Returns true for BeforeInitialize and AfterInitialize.
    function isInitialization(CallbackType callback) internal pure returns (bool) {
        return callback == CallbackType.BeforeInitialize || callback == CallbackType.AfterInitialize;
    }

    /// @notice Returns true for the callbacks whose result can contain deltas: both swap callbacks and the after
    /// callbacks of a liquidity change. The result of every other callback must be zero.
    function canReturnDeltas(CallbackType callback) internal pure returns (bool) {
        return callback == CallbackType.BeforeSwap || callback == CallbackType.AfterSwap
            || callback == CallbackType.AfterAddLiquidity || callback == CallbackType.AfterRemoveLiquidity;
    }

    /// @notice Returns true for the after callback of a swap, a liquidity change, or a donation.
    /// @dev AfterInitialize is not included: initialization is not a route Operation.
    function isAfterOperation(CallbackType callback) internal pure returns (bool) {
        return callback == CallbackType.AfterSwap || callback == CallbackType.AfterAddLiquidity
            || callback == CallbackType.AfterRemoveLiquidity || callback == CallbackType.AfterDonate;
    }

    /// @notice Returns the before callback of operation.
    /// @dev For ModifyLiquidity, BeforeAddLiquidity is a placeholder: the PoolManager calls BeforeRemoveLiquidity
    /// when liquidityDelta <= 0, and KernelHookOperations.actionHash replaces the placeholder accordingly.
    /// Never called with ForeignSwap: a hookless pool has no before callback, and authorizeAction returns first.
    function beforeCallbackOf(Operation operation) internal pure returns (CallbackType) {
        if (operation == Operation.Swap) return CallbackType.BeforeSwap;
        if (operation == Operation.ModifyLiquidity) return CallbackType.BeforeAddLiquidity;
        return CallbackType.BeforeDonate;
    }
}
