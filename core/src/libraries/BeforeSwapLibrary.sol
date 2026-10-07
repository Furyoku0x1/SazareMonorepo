// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CallbackResult} from "../types/KernelHookTypes.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Swap amount arithmetic that KernelHook and its extensions share, so both use the same rules.
library BeforeSwapLibrary {
    /// @notice Returns true if the specified currency of the swap is currency0: the input of an exact-input swap
    /// from currency0, or the output of an exact-output swap to currency0.
    function isSpecifiedCurrency0(SwapParams memory params) internal pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    /// @notice Returns the specified amount that remains for the next extension and the pool after the given
    /// beforeSwap deltas, with the sign convention of amountSpecified: negative for the input of an exact-input swap,
    /// positive for the output of an exact-output swap.
    /// @dev An extension calls this with ExecutionContext.prior to find the input that earlier extensions left.
    /// KernelHook calls it with the sum of all results, and rejects a sum that changes the sign.
    /// @param params The swap parameters of the beforeSwap callback
    /// @param deltas The sum of beforeSwap results in currency0/currency1 order
    function remainingAmountSpecified(SwapParams memory params, CallbackResult memory deltas)
        internal
        pure
        returns (int256)
    {
        int128 specified = isSpecifiedCurrency0(params) ? deltas.delta0 : deltas.delta1;
        return params.amountSpecified + specified;
    }
}
