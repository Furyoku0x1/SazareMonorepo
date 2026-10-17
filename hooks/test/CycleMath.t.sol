// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {CycleMath} from "../src/libraries/arbitrage/CycleMath.sol";

/// @dev Rounding cases where a cycle must not fold to a zero input reserve.
contract CycleMathTest is Test {
    uint160 private constant Q96 = uint160(1 << 96);

    /// @dev The first pool's input reserve is a third of one unit; unscaled, it rounds to zero.
    function test_foldKeepsReserveBelowOneUnit() public pure {
        // First leg token0 -> token1, second leg token1 -> token0, no fees.
        (uint256 reserveIn, uint256 reserveOut) = CycleMath.reserves(3 * Q96, 1);
        (uint256 second0, uint256 second1) = CycleMath.reserves(Q96 / 4, 4);
        (reserveIn, reserveOut) = CycleMath.fold(reserveIn, reserveOut, second1, second0, 0);
        assertGt(reserveIn, 0);
        assertGt(reserveOut, reserveIn);
    }

    /// @dev Two pools that each pay 2^80 per unit: the folded input reserve is below 2^-48 units, so rounding down
    /// would hide the cycle.
    function test_largeMispricingKeepsInput() public pure {
        (uint256 hopIn, uint256 hopOut) = CycleMath.reserves(uint160(1 << 136), 1 << 40);
        (uint256 reserveIn, uint256 reserveOut) = CycleMath.fold(hopIn, hopOut, hopIn, hopOut, 0);
        (uint256 input, uint256 profit) = CycleMath.optimize(reserveIn, reserveOut, 0, type(uint128).max);
        assertGt(input, 0);
        assertGt(profit, 0);
    }
}
