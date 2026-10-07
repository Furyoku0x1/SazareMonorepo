// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {BeforeSwapLibrary} from "../../src/libraries/BeforeSwapLibrary.sol";
import {CallbackResult} from "../../src/types/KernelHookTypes.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice The remaining specified amount in each of the four swap kinds. The specified currency is currency0 for an
/// exact-input swap from currency0 and an exact-output swap to currency0; the other delta must not count.
contract BeforeSwapLibraryTest is Test {
    function test_remainingAmountSpecified_exactInputZeroForOneUsesDelta0() public pure {
        assertEq(
            BeforeSwapLibrary.remainingAmountSpecified(SwapParams(true, -1000, 0), CallbackResult(100, 7, 0)), -900
        );
    }

    function test_remainingAmountSpecified_exactInputOneForZeroUsesDelta1() public pure {
        assertEq(
            BeforeSwapLibrary.remainingAmountSpecified(SwapParams(false, -1000, 0), CallbackResult(7, 100, 0)), -900
        );
    }

    function test_remainingAmountSpecified_exactOutputZeroForOneUsesDelta1() public pure {
        assertEq(BeforeSwapLibrary.remainingAmountSpecified(SwapParams(true, 1000, 0), CallbackResult(7, -100, 0)), 900);
    }

    function test_remainingAmountSpecified_exactOutputOneForZeroUsesDelta0() public pure {
        assertEq(
            BeforeSwapLibrary.remainingAmountSpecified(SwapParams(false, 1000, 0), CallbackResult(-100, 7, 0)), 900
        );
    }
}
