// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CloseRequest, OpenRequest, Position} from "vault/VaultTypes.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice The restore at close (owner, 2026-10-19): a close swaps the closed part's repayment back toward the tokens
/// it released, through the pool, so a range lent in token1 and crossed comes back to lenders in token1. It is
/// best-effort: a close on a paused pool goes through and restores nothing.
contract RestoreAtCloseTest is MetricFixture {
    int24 internal constant PRICE_TICK = -200_311;
    uint256 internal constant WAD = 1e18;
    /// @dev Metric's `Swap` event: its packed value types are all `uint256` underneath.
    bytes32 internal constant SWAP = keccak256("Swap(address,address,uint256,uint256,uint256)");
    /// @dev Hourly steps of the walk below the range, each recorded as a keeper would.
    uint256 internal constant STEPS = 20;

    /// @dev A long whose range the price fell through repays in token0; the close sells that token0 back for token1,
    /// within the slippage allowance of the bid.
    function test_crossedLong_closeSellsTheRepaidToken0() public {
        uint256 positionId = _crossedLong();
        Position memory position = vault.positionOf(positionId);
        vm.recordLogs();
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: position.maximum0, repay1: 0}));
        (uint256 sold0, uint256 bought1) = _vaultSwap(vm.getRecordedLogs());
        assertGt(sold0, 0, "the repaid token0 is sold");
        assertLe(sold0, position.maximum0, "no more than the repayment");
        uint256 floor = sold0 * 1_900 / 1e12 * (10_000 - vault.parametersOf(vaultId).forceCloseSlippageBps) / 10_000;
        assertGe(bought1, floor * 99 / 100, "near the bid");
        assertLedger();
    }

    /// @dev On a paused pool there is no price: the close repays, charges no stub and restores nothing, and still
    /// goes through.
    function test_pausedPool_closeGoesThroughWithoutARestore() public {
        uint256 positionId = _crossedLong();
        Position memory position = vault.positionOf(positionId);
        pool.setPause(1);
        vm.recordLogs();
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: position.maximum0, repay1: 0}));
        (uint256 sold0,) = _vaultSwap(vm.getRecordedLogs());
        assertEq(sold0, 0, "no restore without a price");
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        pool.setPause(0);
        assertLedger();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A 10,000 USD long from 3% to 1% below the price that bought base at open, then the price walked to 1,900,
    /// below its range.
    function _crossedLong() internal returns (uint256 positionId) {
        deposit(lender, 100e18, 100_000e6);
        int24 lower = PRICE_TICK - 300;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.tickLower = lower;
        request.tickUpper = upper;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        request.liquidity = uint128(uint256(10_000e6) * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        request.collateral = 2_500e6;
        request.escrow = 2_000e6;
        request.entryAmountIn = 12_000e6;
        vm.prank(trader);
        positionId = vault.open(request);
        // STEPS steps from 2,000 down to 1,900
        for (uint256 step = 1; step <= STEPS; ++step) {
            provider.set(uint128((2_000 * (STEPS - step) + 1_900 * step) * Q64 / STEPS), HALF_SPREAD_E5);
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            assertTrue(vault.recordPrice(vaultId), "an hourly point");
        }
    }

    /// @dev The token0 the vault sold to the pool, and the token1 it got, over the recorded logs.
    function _vaultSwap(Vm.Log[] memory logs) internal view returns (uint256 sold0, uint256 bought1) {
        // logs.length is bounded by the close's events
        for (uint256 index = 0; index < logs.length; ++index) {
            if (logs[index].emitter != address(pool)) continue;
            if (logs[index].topics[0] != SWAP) continue;
            if (address(uint160(uint256(logs[index].topics[1]))) != address(vault)) continue;
            (, uint256 amountDeltas,) = abi.decode(logs[index].data, (uint256, uint256, uint256));
            int128 delta0 = int128(int256(amountDeltas >> 128));
            int128 delta1 = int128(int256(amountDeltas & type(uint128).max));
            if (delta0 <= 0) continue;
            sold0 += uint256(uint128(delta0));
            bought1 += uint256(uint128(-delta1));
        }
    }
}
