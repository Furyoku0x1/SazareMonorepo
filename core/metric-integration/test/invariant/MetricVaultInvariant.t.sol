// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IMetricOmmPoolActions} from "metric/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {PoolStateLibrary} from "metric/libraries/PoolStateLibrary.sol";
import {LiquidityDelta} from "metric/types/PoolOperation.sol";
import {Accrual, Position, Venue} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {DebtTotals, VaultMath} from "vault/libraries/VaultMath.sol";
import {MetricFixture} from "../utils/MetricFixture.sol";
import {MetricVaultHandler, PoolReads} from "./MetricVaultHandler.sol";

/// @notice Invariants of one Metric Lending Vault on a real Metric pool, under lenders, traders, force closes with
/// the pool live, paused or unpriced, outside trading, time and a moving reference.
contract MetricVaultInvariantTest is MetricFixture {
    MetricVaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        deposit(lender, 20e18, 40_000e6);
        handler = new MetricVaultHandler(vault, vaultId, pool, provider, base, quote, outsider, address(this));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = MetricVaultHandler.deposit.selector;
        selectors[1] = MetricVaultHandler.withdraw.selector;
        selectors[2] = MetricVaultHandler.open.selector;
        selectors[3] = MetricVaultHandler.open.selector;
        selectors[4] = MetricVaultHandler.close.selector;
        selectors[5] = MetricVaultHandler.settle.selector;
        selectors[6] = MetricVaultHandler.flag.selector;
        selectors[7] = MetricVaultHandler.forceClose.selector;
        selectors[8] = MetricVaultHandler.swapOutside.selector;
        selectors[9] = MetricVaultHandler.swapOutside.selector;
        selectors[10] = MetricVaultHandler.moveReference.selector;
        selectors[11] = MetricVaultHandler.warp.selector;
        selectors[12] = MetricVaultHandler.openThroughVenue.selector;
        selectors[13] = MetricVaultHandler.closeThroughVenue.selector;
        selectors[14] = MetricVaultHandler.withdrawThroughVenue.selector;
        selectors[15] = MetricVaultHandler.recordPrice.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev `held0`/`held1` equal the vault contract's balances and the sums of their ledger parts.
    function invariant_ledgerMatchesBalances() public view {
        assertLedger();
    }

    /// @dev Every bin where the vault holds shares, across the whole pool, lies in its window.
    function invariant_sharesInsideWindow() public view {
        Venue memory venue = vault.venueOf(vaultId);
        // every pool bin
        for (int256 binIndex = venue.poolLowestBin; binIndex <= venue.poolHighestBin; ++binIndex) {
            uint256 ours =
                PoolStateLibrary._positionBinShares(address(pool), address(vault), uint80(vaultId), int16(binIndex));
            if (ours == 0) continue;
            assertTrue(venue.windowSet, "shares before a window");
            assertGe(binIndex, venue.lowestBin, "below the window");
            assertLe(binIndex, venue.highestBin, "above the window");
        }
    }

    /// @dev Every open position passes the chord and the repayment rule; the vault's outstanding amounts, debt totals
    /// and open interest are exactly the sums over open positions.
    function invariant_positionsAndTotals() public view {
        uint256 released0;
        uint256 released1;
        DebtTotals memory longSum;
        DebtTotals memory shortSum;
        uint256 open;
        uint256 last = vault.lastPositionId();
        // every position ever opened
        for (uint256 positionId = 1; positionId <= last; ++positionId) {
            Position memory position = vault.positionOf(positionId);
            if (position.owner == address(0)) continue;
            open += 1;
            assertTrue(
                VaultMath.chordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1),
                "chord"
            );
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96) =
                VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
            assertTrue(
                VaultMath.repays(position.reserve0, position.reserve1, position.liquidity, sqrtLowerX96, sqrtUpperX96),
                "repays"
            );
            released0 += position.released0;
            released1 += position.released1;
            if (position.isLong) longSum.liquidity += position.liquidity;
            else shortSum.liquidity += position.liquidity;
        }
        assertEq(open, handler.openCount(), "open positions");
        Accrual memory accrual = vault.accrualOf(vaultId);
        assertEq(accrual.outstanding0, released0, "outstanding0");
        assertEq(accrual.outstanding1, released1, "outstanding1");
        (DebtTotals memory longDebts, DebtTotals memory shortDebts) = vault.debtsOf(vaultId);
        _assertTotals(longDebts, longSum, "long");
        _assertTotals(shortDebts, shortSum, "short");
    }

    /// @dev After a refresh, the cached holdings equal an independent read of the pool's storage, and removing the
    /// whole position returns them: exactly for token0 (scale 1), and up to one unit per bin more for token1, since
    /// Metric converts the sum of the bins' scaled amounts while the vault converts each bin's.
    function invariant_holdingsMatchPool() public {
        try this.probeHoldings() {
            fail();
        } catch (bytes memory reason) {
            assertEq(reason.length, 7 * 32, string(reason));
            (
                uint256 cached0,
                uint256 cached1,
                uint256 read0,
                uint256 read1,
                uint256 removed0,
                uint256 removed1,
                uint256 bins
            ) = abi.decode(reason, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            assertEq(cached0, read0, "holdings0 vs pool storage");
            assertEq(cached1, read1, "holdings1 vs pool storage");
            assertEq(removed0, read0, "removal of token0");
            assertGe(removed1, read1, "removal of token1 at least the holdings");
            assertLe(removed1 - read1, bins, "removal of token1 within a unit per bin");
        }
    }

    function invariant_noUnexpectedReverts() public view {
        assertEq(
            handler.unexpectedReverts(),
            0,
            string.concat(handler.lastUnexpectedAction(), ": ", vm.toString(handler.lastUnexpectedReason()))
        );
    }

    /// @dev The venue actions reach the vault and succeed: a long that buys 1% of what it adds through the venue, with
    /// a hundred quote of margin, then a full close that sells its base through the venue and repays.
    function test_venueActionsReachTheVault() public {
        handler.openThroughVenue(0, true, 0, 100, 1_000e6, 100e6 + 1, 0);
        assertEq(handler.venueOpens(), 1, "opened through the venue");
        assertEq(handler.venueMismatches(), 0, "the fill's loss charged exactly");
        handler.closeThroughVenue(0, 0);
        assertEq(handler.venueCloses(), 1, "closed through the venue");
        handler.deposit(0, 10e18, 20_000e6);
        handler.withdrawThroughVenue(0, 5_000, 0);
        assertEq(handler.venueWithdrawals(), 1, "withdrew through the venue");
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpectedAction());
        assertLedger();
    }

    /// @dev Every venue open's basis is its collateral and escrow less exactly what its fill lost against the band, and
    /// a withdrawal that sells its payout's token0 pays none.
    function invariant_venueResultsExact() public view {
        assertEq(handler.venueMismatches(), 0, "a venue action's result not what its fill implies");
    }

    /// @dev Deposits and withdrawals never lower the value per share, at the bid, of the lenders who stay.
    function invariant_lenderFlowsNeverDiluteStayers() public view {
        assertEq(handler.stayersDiluted(), 0, "a lender flow diluted the lenders who stay");
    }

    /// @dev A withdrawal claiming at least one quote is never refused for want of idle capital while at least one
    /// quote of it sits in the buffer and the vault's bins: everything but the active bin's last shares can leave.
    function invariant_withdrawalsReachIdleCapital() public view {
        assertEq(handler.withdrawalsRefusedWithIdle(), 0, "a withdrawal was refused while idle capital existed");
    }

    function invariant_vaultNeverEmptiesTheActiveBin() public view {
        assertEq(handler.activeBinEmptied(), 0, "a vault action emptied the active bin");
    }

    function afterInvariant() external {
        (uint256 live, uint256 paused, uint256 unpriced) = handler.forceClosesByMode();
        emit log_named_uint("deposits", handler.deposits());
        emit log_named_uint("withdrawals", handler.withdrawals());
        emit log_named_uint("opens", handler.opens());
        emit log_named_uint("opens refused", handler.opensRefused());
        emit log_named_uint("venue opens", handler.venueOpens());
        emit log_named_uint("venue closes", handler.venueCloses());
        emit log_named_uint("venue withdrawals", handler.venueWithdrawals());
        emit log_named_uint("full closes", handler.fullCloses());
        emit log_named_uint("partial closes", handler.partialCloses());
        emit log_named_uint("closes refused", handler.closesRefused());
        emit log_named_uint("closes at the bid's holdings", handler.closesAtBid());
        emit log_named_uint("closes with the whole portion", handler.closesWhole());
        emit log_named_uint("holdings at bid short of the rule", handler.holdingsAtBidShort());
        emit log_named_uint("force closes, pool live", live);
        emit log_named_uint("force closes, pool paused", paused);
        emit log_named_uint("force closes, provider failing", unpriced);
        emit log_named_uint("settles", handler.settles());
        emit log_named_uint("price points", handler.pricePoints());
        emit log_named_uint("flags", handler.flags());
        emit log_named_uint("outside swaps", handler.outsideSwaps());
        emit log_named_uint("open positions", handler.openCount());
        emit log_named_uint("dilution checks", handler.dilutionChecks());
        emit log_named_uint("refused: Insolvent", handler.refusals(IMetricLendingVault.Insolvent.selector));
        emit log_named_uint(
            "refused: InsufficientIdle", handler.refusals(IMetricLendingVault.InsufficientIdle.selector)
        );
        emit log_named_uint(
            "refused: UtilizationCeiling", handler.refusals(IMetricLendingVault.UtilizationCeiling.selector)
        );
        emit log_named_uint("refused: PremiumUnpaid", handler.refusals(IMetricLendingVault.PremiumUnpaid.selector));
        emit log_named_uint(
            "refused: BelowMinimumBorrow", handler.refusals(IMetricLendingVault.BelowMinimumBorrow.selector)
        );
        emit log_named_uint("refused: RepaymentShort", handler.refusals(IMetricLendingVault.RepaymentShort.selector));
        emit log_named_uint("refused: NotDelinquent", handler.refusals(IMetricLendingVault.NotDelinquent.selector));
        emit log_named_uint("refused: ZeroAmount", handler.refusals(IMetricLendingVault.ZeroAmount.selector));
        emit log_named_uint(
            "refused: FinalAmountIsZero", handler.refusals(IMetricOmmPoolActions.FinalAmountIsZero.selector)
        );
    }

    /// @notice Refreshes the holdings through a small deposit (every vault action ends with `refresh`; between the
    /// handler's actions the pool is live and priced), reads them independently, removes the whole position as the
    /// vault, and reverts with the results so nothing persists.
    function probeHoldings() external {
        deposit(lender, 0, 1e6);
        Venue memory venue = vault.venueOf(vaultId);
        uint256 binCount = uint256(int256(venue.highestBin) - venue.lowestBin + 1);
        (uint256 read0, uint256 read1) = PoolReads.holdings(
            address(pool), address(vault), vaultId, venue.lowestBin, binCount, venue.scale0, venue.scale1
        );
        LiquidityDelta memory deltas = _wholePosition(venue.lowestBin, binCount);
        vm.prank(address(vault));
        (uint256 removed0, uint256 removed1) = pool.removeLiquidity(address(vault), uint80(vaultId), deltas, "");
        bytes memory result =
            abi.encode(venue.holdings0, venue.holdings1, read0, read1, removed0, removed1, deltas.binIdxs.length);
        assembly ("memory-safe") {
            revert(add(result, 32), mload(result))
        }
    }

    function _wholePosition(int256 lowestBin, uint256 binCount) internal view returns (LiquidityDelta memory deltas) {
        uint256 count;
        uint256[] memory shares = new uint256[](binCount);
        // binCount bins
        for (uint256 offset = 0; offset < binCount; ++offset) {
            shares[offset] = PoolStateLibrary._positionBinShares(
                address(pool), address(vault), uint80(vaultId), int16(lowestBin + int256(offset))
            );
            if (shares[offset] != 0) count += 1;
        }
        deltas.binIdxs = new int256[](count);
        deltas.shares = new uint256[](count);
        uint256 next;
        // binCount bins
        for (uint256 offset = 0; offset < binCount; ++offset) {
            if (shares[offset] == 0) continue;
            deltas.binIdxs[next] = lowestBin + int256(offset);
            deltas.shares[next] = shares[offset];
            next += 1;
        }
    }

    function _assertTotals(DebtTotals memory totals, DebtTotals memory sum, string memory side) internal pure {
        assertEq(totals.liquidity, sum.liquidity, string.concat(side, " liquidity"));
    }
}
