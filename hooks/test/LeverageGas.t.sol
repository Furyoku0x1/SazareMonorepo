// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/console.sol";
import {LeverageFixture} from "./utils/LeverageFixture.sol";

/// @dev Measures open and close gas by bin count, to size maxBinsPerPosition for Ethereum (spec Q9, Q14).
contract LeverageGasTest is LeverageFixture {
    /// @dev Ethereum's per-transaction gas cap since EIP-7825 (Fusaka): 2^24.
    uint256 internal constant MAX_TRANSACTION_GAS = 16_777_216;

    function setUp() public override {
        super.setUp();
        _deposit(lenderA, -16, 16, 1e21);
        _deposit(lenderA, 0, 16, 1e21);
    }

    function test_gasByBinCount() public {
        uint8[4] memory counts = [1, 4, 8, 16];
        // counts.length == 4
        for (uint256 i; i < counts.length; ++i) {
            (uint256 openGas, uint256 closeGas) = _measure(counts[i]);
            console.log("bins", counts[i], "open gas", openGas);
            console.log("bins", counts[i], "close gas", closeGas);
            assertLt(openGas, MAX_TRANSACTION_GAS);
            assertLt(closeGas, MAX_TRANSACTION_GAS);
        }
    }

    function _measure(uint8 binCount) internal returns (uint256 openGas, uint256 closeGas) {
        int24 lowerBin = -int24(int256(uint256(binCount)));
        uint128[] memory amounts = _uniform(binCount, 1e20);
        vm.prank(trader);
        uint256 gasBefore = gasleft();
        uint256 id = leverage.open(_openRequest(lowerBin, amounts, true, 5e19, 1e17));
        openGas = gasBefore - gasleft();
        vm.warp(block.timestamp + 1 days);
        vm.prank(trader);
        gasBefore = gasleft();
        leverage.close(id, 1e18, 0, trader);
        closeGas = gasBefore - gasleft();
    }
}
