// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Test.sol";
import {Ledger, OpenRequest, Position, Stream, VaultParameters} from "../../src/metric/vault/VaultTypes.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {VaultFixture} from "./utils/VaultFixture.sol";

/// @notice Runs the Metric backtest's scripted sequence (hooks/research/metric-backtest/scripts/crosscheck.py) through
/// the real contracts and logs the lenders' balances as a `crosscheck|` line for the simulator to compare.
/// Run: forge test --match-contract BacktestCrossCheckTest -vv
contract BacktestCrossCheckTest is VaultFixture {
    int24 internal constant TICK0 = -200_311;
    int24 internal constant TICK_DOWN = TICK0 - 700;
    int24 internal constant TICK_UP = TICK0 + 300;
    uint256 internal constant DEPOSIT0 = 249994963894888955904;
    uint256 internal constant DEPOSIT1 = 500000000000;

    uint256 internal checkId;

    function test_logCrossCheck() public {
        VaultParameters memory parameters = defaultParameters();
        // The simulator's cross-check leaves the profit share out.
        parameters.profitShareBps = 0;
        vm.prank(owner);
        checkId = vault.createVault(parameters, defaultCurves());
        setPrice(TICK0, 1);
        vm.prank(lender);
        vault.deposit(checkId, DEPOSIT0, DEPOSIT1, 0, lender);
        uint256 start = block.timestamp;
        uint256 longA = _open(true, -201414, -201315, 95236190072619113);
        vm.warp(start + 1);
        uint256 shortB = _open(false, -198537, -198438, 61857610375359311);
        vm.warp(start + 1 days);
        uint256 longC = _open(true, -200874, -200774, 45885025930973858);
        vm.warp(start + 3 days);
        setPrice(TICK_DOWN, 1);
        _close(longA);
        vm.warp(start + 5 days);
        setPrice(TICK_UP, 1);
        _close(shortB);
        vm.warp(start + 6 days);
        _close(longC);
        vm.warp(start + 10 days);
        // A checkpoint releases the fully vested income into the buffer.
        vault.recenter(checkId);
        Ledger memory ledger = vault.ledgerOf(checkId);
        Stream memory stream = vault.streamOf(checkId);
        assertEq(stream.remaining0 + stream.remaining1, 0, "all income vested");
        console2.log(
            string.concat(
                "crosscheck|buffer0=",
                vm.toString(ledger.buffer0),
                "|buffer1=",
                vm.toString(ledger.buffer1),
                "|treasury1=",
                vm.toString(ledger.treasury1)
            )
        );
    }

    function _open(bool isLong, int24 tickLower, int24 tickUpper, uint128 liquidity) internal returns (uint256) {
        OpenRequest memory request = openRequest(isLong, tickLower, tickUpper, liquidity, 0);
        request.vaultId = checkId;
        request.collateral = uint128(minimumCollateral(tickLower, tickUpper, liquidity) + 1e6);
        request.escrow = 5_000e6;
        vm.prank(trader);
        return vault.open(request);
    }

    /// @dev Repays the range's holdings at the band's bid plus a unit of each held token, as the simulator does, where the
    /// reserves hold them.
    function _close(uint256 positionId) internal {
        Position memory position = vault.positionOf(positionId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        (uint256 repay0, uint256 repay1) =
            VaultMath.holdingsAt(position.liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96());
        if (repay0 != 0) repay0 += 1;
        if (repay1 != 0) repay1 += 1;
        // Without a pool the trader cannot buy the extra unit of token0: it repays all its token0 and the least token1
        // the rule then needs, a difference of one unit to the lenders.
        if (repay0 > position.reserve0) {
            repay0 = position.reserve0;
            repay1 = minimumRepay1(repay0, position.liquidity, sqrtLowerX96, sqrtUpperX96);
        }
        closeFull(positionId, repay0, repay1);
    }
}
