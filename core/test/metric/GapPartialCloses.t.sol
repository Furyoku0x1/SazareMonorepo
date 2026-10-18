// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {Accrual, CloseRequest, Ledger, OpenRequest, Position} from "../../src/metric/vault/VaultTypes.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {DebtTotals, VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {VaultFixture} from "./utils/VaultFixture.sol";

/// @notice Gap cases G8 and G9 of the fresh audit (2026-10-17): partial closes at the extreme fractions of 1 wei and
/// WAD − 1, twenty tiny partial closes against one full close, and the minimum borrow a partial close may leave.
/// @dev Every position is a long below the price with no entry swap, so its reserves hold token1 only and every
/// repayment is token1 alone: `minimumRepay1` then gives the least repayment the rule accepts, with no fixture padding.
/// A bystander long stays open throughout, so outstanding amounts and debt totals never fall to zero by accident.
contract GapPartialClosesTest is VaultFixture {
    uint256 internal constant WAD = 1e18;
    int24 internal constant LOWER_TICK = PRICE_TICK - 200;
    int24 internal constant UPPER_TICK = PRICE_TICK - 100;
    uint256 internal constant TINY_CLOSES = 20;
    /// @dev The first tiny fraction, 1e-8; each later one doubles it, so the twentieth is about 0.5%.
    uint256 internal constant SMALLEST_FRACTION_WAD = 1e10;
    /// @dev Large enough that one wei of fraction closes liquidity and reserves, and that WAD − 1 leaves a rest above
    /// the minimum borrow: the rest is `ceil(L / WAD)`, worth about `HUGE_NOTIONAL / WAD` of token1.
    uint256 internal constant HUGE_NOTIONAL = 1e27;
    /// @dev Bisection steps over a uint128 interval.
    uint256 internal constant SEARCH_STEPS = 128;

    uint256 internal bystanderPositionId;

    /// @dev What one way of closing a position produced, measured on the vault and the trader.
    struct Outcome {
        uint256 repaid1;
        uint256 income1;
        uint256 profitShare;
        uint256 closedEvents;
        uint256 paid0;
        uint256 paid1;
        uint256 outstanding1;
    }

    // ---------------------------------------------------------------- G8: extreme fractions

    /// @dev One wei of fraction closes no liquidity on an ordinary position, and the least fraction that closes one
    /// unit closes no reserve, so nothing can repay it. Both refuse with the specific reason, and the position still
    /// closes in full afterwards: a dust close can neither slip through nor wedge the position.
    function test_partialClose_oneWeiFraction_refusesWithNothingChanged() public {
        uint256 positionId = _openTenThousandLong(100e6);
        Position memory position = vault.positionOf(positionId);
        assertLt(position.liquidity, WAD, "one wei of fraction closes no liquidity");
        _expectRefusal(positionId, 1, 0, IMetricLendingVault.InvalidFraction.selector);
        uint256 oneUnitFractionWad = (WAD + position.liquidity - 1) / position.liquidity;
        assertEq(VaultMath.portionDown(position.liquidity, oneUnitFractionWad), 1, "closes one unit of liquidity");
        assertEq(VaultMath.portionDown(position.reserve1, oneUnitFractionWad), 0, "and no reserve");
        _expectRefusal(positionId, oneUnitFractionWad, 0, IMetricLendingVault.RepaymentShort.selector);
        _expectRefusal(positionId, oneUnitFractionWad, 1, IMetricLendingVault.RepaymentShort.selector);
        _closeWhole(positionId);
        _assertOnlyBystanderLeft();
        assertLedger();
    }

    /// @dev On a position large enough that one wei of fraction closes real liquidity, the close succeeds and moves
    /// exactly the rounded portions: liquidity and reserves down, the release up, the escrow untouched, the basis by
    /// its escrow-free fraction. The least repayment is exact (one unit less refuses), and the rest closes in full.
    /// Rounding the wrong way at the smallest fraction would let a close take a unit it did not repay.
    function test_partialClose_oneWeiFraction_ofAHugePosition_movesExactPortions() public {
        uint256 positionId = _openHugeLong();
        assertGt(VaultMath.portionDown(vault.positionOf(positionId).liquidity, 1), 0, "one wei closes liquidity");
        _closeAndCheck(positionId, 1);
        _closeWhole(positionId);
        _assertOnlyBystanderLeft();
        assertLedger();
    }

    /// @dev WAD − 1 on an ordinary position leaves one unit of liquidity, a debt of two units: far below the minimum
    /// borrow. The repayment is valid, so the minimum alone refuses it: otherwise a near-full close could leave dust
    /// positions too small to be worth force closing.
    function test_partialClose_wadMinusOne_leavingDust_refusesBelowTheMinimum() public {
        uint256 positionId = _openTenThousandLong(100e6);
        Position memory position = vault.positionOf(positionId);
        uint256 fractionWad = WAD - 1;
        assertEq(position.liquidity - VaultMath.portionDown(position.liquidity, fractionWad), 1, "leaves one unit");
        uint256 repay1 = _minimumRepay1For(positionId, fractionWad);
        assertLe(repay1, VaultMath.portionDown(position.reserve1, fractionWad), "the closed reserve repays");
        _expectRefusal(positionId, fractionWad, repay1, IMetricLendingVault.BelowMinimumBorrow.selector);
    }

    /// @dev On a huge position WAD − 1 leaves `ceil(L / WAD)` of liquidity, above the minimum borrow: the close
    /// succeeds with exact portions, the rest stays solvent and counted as outstanding, and it later closes in full.
    /// The largest fraction short of a full close must not strand or mis-count the rest it leaves.
    function test_partialClose_wadMinusOne_ofAHugePosition_leavesARestThatClosesLater() public {
        uint256 positionId = _openHugeLong();
        Position memory before = vault.positionOf(positionId);
        uint256 rest = before.liquidity - VaultMath.portionDown(before.liquidity, WAD - 1);
        assertEq(rest, (before.liquidity + WAD - 1) / WAD, "the rest is L / WAD rounded up");
        _closeAndCheck(positionId, WAD - 1);
        Position memory afterwards = vault.positionOf(positionId);
        assertGe(afterwards.maximum1, vault.parametersOf(vaultId).minBorrowNotional, "the rest meets the minimum");
        assertTrue(
            VaultMath.chordHolds(afterwards.reserve0, afterwards.reserve1, afterwards.maximum0, afterwards.maximum1),
            "the rest is solvent"
        );
        _closeWhole(positionId);
        _assertOnlyBystanderLeft();
        assertLedger();
    }

    // ---------------------------------------------------------------- G8: many tiny partial closes

    /// @dev Twenty partial closes of 1e-8 to 0.5%, then a full close, against one full close at the same moment, each
    /// repaying the least the rule accepts. Bounds: the split never repays less, and at most one unit more per partial
    /// close (each part's least repayment rounds up once); premium is charged once, so it matches exactly; neither way
    /// takes a profit share (the large escrow would show a regression of Sol-1-1 as one); every unit not repaid
    /// reaches the trader, so payouts differ by exactly the repayments' difference; outstanding and the debt totals
    /// end at the bystander's alone, and after each partial close outstanding equals what the two positions hold.
    function test_twentyTinyPartialCloses_matchOneFullClose() public {
        uint256 positionId = _openTenThousandLong(1_000e6);
        uint256 snapshot = vm.snapshotState();
        Outcome memory whole = _closeMeasured(positionId, false);
        vm.revertToState(snapshot);
        Outcome memory split = _closeMeasured(positionId, true);
        assertGe(split.repaid1, whole.repaid1, "splitting never repays less");
        assertLe(split.repaid1, whole.repaid1 + TINY_CLOSES, "at most one unit more per partial close");
        assertGt(whole.income1, 0, "premium accrued");
        assertEq(whole.closedEvents, 1, "one close reported");
        assertEq(split.closedEvents, TINY_CLOSES + 1, "every close reported");
        assertEq(whole.profitShare, 0, "no profit to share in one close");
        assertEq(split.profitShare, 0, "no escrow taxed as profit across partial closes");
        assertEq(split.income1, whole.income1, "premium is charged once, exactly");
        assertEq(whole.paid0, 0, "no token0 in one close");
        assertEq(split.paid0, 0, "no token0 across partial closes");
        assertEq(split.paid1 + split.repaid1, whole.paid1 + whole.repaid1, "every unit not repaid reaches the trader");
        assertEq(split.outstanding1, whole.outstanding1, "outstanding ends the same");
    }

    // ---------------------------------------------------------------- G9: the minimum borrow

    /// @dev A partial close leaving `maximum1` one unit below the minimum borrow refuses. The repayment passes the rule
    /// and the rest would pass the chord, so the minimum is the only reason: this pins the boundary to the unit.
    function test_partialClose_oneUnitBelowTheMinimumBorrow_refuses() public {
        uint256 positionId = _openTenThousandLong(100e6);
        (, uint256 fractionBelowWad, uint128 restAt) = _boundaryFractions(positionId);
        Position memory position = vault.positionOf(positionId);
        assertEq(position.liquidity - VaultMath.portionDown(position.liquidity, fractionBelowWad), restAt - 1, "rest");
        (uint256 maximum0, uint256 maximum1) = _extremes(restAt - 1);
        uint256 restReserve0 = position.reserve0 - VaultMath.portionDown(position.reserve0, fractionBelowWad);
        uint256 restReserve1 = position.reserve1 - VaultMath.portionDown(position.reserve1, fractionBelowWad);
        assertTrue(VaultMath.chordHolds(restReserve0, restReserve1, maximum0, maximum1), "the rest would be solvent");
        uint256 repay1 = _minimumRepay1For(positionId, fractionBelowWad);
        assertLe(repay1, VaultMath.portionDown(position.reserve1, fractionBelowWad), "the closed reserve repays");
        _expectRefusal(positionId, fractionBelowWad, repay1, IMetricLendingVault.BelowMinimumBorrow.selector);
    }

    /// @dev One unit of liquidity more, leaving `maximum1` exactly at the minimum borrow, succeeds; a day later the
    /// rest closes in full, and outstanding and the debt totals fall back to the bystander's. With the refusal one unit
    /// below, this shows the minimum is inclusive and a rest at it is an ordinary, closable position.
    function test_partialClose_atTheMinimumBorrow_succeedsAndTheRestClosesLater() public {
        uint256 positionId = _openTenThousandLong(100e6);
        (uint256 fractionAtWad,, uint128 restAt) = _boundaryFractions(positionId);
        _close(positionId, fractionAtWad, _minimumRepay1For(positionId, fractionAtWad));
        Position memory position = vault.positionOf(positionId);
        assertEq(position.liquidity, restAt, "the rest");
        assertEq(position.maximum1, vault.parametersOf(vaultId).minBorrowNotional, "left at the minimum exactly");
        assertTrue(
            VaultMath.chordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1),
            "the rest is solvent"
        );
        assertEq(
            vault.accrualOf(vaultId).outstanding1,
            vault.positionOf(bystanderPositionId).released1 + position.released1,
            "outstanding is what the positions hold"
        );
        assertLedger();
        vm.warp(block.timestamp + 1 days);
        _closeWhole(positionId);
        _assertOnlyBystanderLeft();
        assertLedger();
    }

    // ---------------------------------------------------------------- opening

    /// @dev A lender's 100,000 USDC, a 5,000 USDC bystander, and a 10,000 USDC long, then a day of premium.
    function _openTenThousandLong(uint128 escrow) internal returns (uint256 positionId) {
        deposit(lender, 0, 100_000e6);
        bystanderPositionId = _openLong(5_000e6, 300e6, 100e6);
        positionId = _openLong(10_000e6, 400e6, escrow);
        vm.warp(block.timestamp + 1 days);
    }

    /// @dev A long of `HUGE_NOTIONAL` with as much collateral, closed in the block it opens: no premium accrues.
    function _openHugeLong() internal returns (uint256 positionId) {
        deposit(lender, 0, 3 * HUGE_NOTIONAL);
        bystanderPositionId = _openLong(5_000e6, 300e6, 100e6);
        positionId = _openLong(HUGE_NOTIONAL, uint128(HUGE_NOTIONAL), 100e6);
    }

    function _openLong(uint256 notional, uint128 collateral, uint128 escrow) internal returns (uint256) {
        OpenRequest memory request =
            openRequest(true, LOWER_TICK, UPPER_TICK, liquidityFor1(LOWER_TICK, UPPER_TICK, notional), collateral);
        request.escrow = escrow;
        return open(request);
    }

    // ---------------------------------------------------------------- closing

    function _close(uint256 positionId, uint256 fractionWad, uint256 repay1) internal returns (uint256, uint256) {
        vm.prank(trader);
        return vault.close(CloseRequest({positionId: positionId, fractionWad: fractionWad, repay0: 0, repay1: repay1}));
    }

    /// @dev Closes in full with the least repayment, after one unit less refuses. Returns the repayment.
    function _closeWhole(uint256 positionId) internal returns (uint256 repay1) {
        repay1 = _minimumRepay1For(positionId, WAD);
        _expectRefusal(positionId, WAD, repay1 - 1, IMetricLendingVault.RepaymentShort.selector);
        _close(positionId, WAD, repay1);
        assertEq(vault.positionOf(positionId).owner, address(0), "deleted");
    }

    /// @dev `TINY_CLOSES` partial closes, each with the least repayment, then a full close. Returns the repayments.
    function _closeInTinySteps(uint256 positionId) internal returns (uint256 repaid1) {
        // step < TINY_CLOSES = 20
        for (uint256 step = 0; step < TINY_CLOSES; ++step) {
            repaid1 += _tinyClose(positionId, SMALLEST_FRACTION_WAD << step);
        }
        repaid1 += _closeWhole(positionId);
    }

    function _tinyClose(uint256 positionId, uint256 fractionWad) internal returns (uint256 repay1) {
        Position memory position = vault.positionOf(positionId);
        assertGt(VaultMath.portionDown(position.liquidity, fractionWad), 0, "closes some liquidity");
        repay1 = _minimumRepay1For(positionId, fractionWad);
        assertLe(repay1, VaultMath.portionDown(position.reserve1, fractionWad), "the closed reserve repays");
        _expectRefusal(positionId, fractionWad, repay1 - 1, IMetricLendingVault.RepaymentShort.selector);
        _close(positionId, fractionWad, repay1);
        assertEq(
            vault.accrualOf(vaultId).outstanding1,
            vault.positionOf(bystanderPositionId).released1 + vault.positionOf(positionId).released1,
            "outstanding is what the positions hold"
        );
    }

    /// @dev Closes `fractionWad` with the least repayment, after one unit less refuses, and checks every amount it
    /// moved. Only for closes in the block the position opened, where no premium or profit share applies.
    function _closeAndCheck(uint256 positionId, uint256 fractionWad) internal {
        Position memory before = vault.positionOf(positionId);
        uint256 repay1 = _minimumRepay1For(positionId, fractionWad);
        _expectRefusal(positionId, fractionWad, repay1 - 1, IMetricLendingVault.RepaymentShort.selector);
        uint256 buffer1 = vault.ledgerOf(vaultId).buffer1;
        uint256 balance1 = quote.balanceOf(trader);
        (uint256 paid0, uint256 paid1) = _close(positionId, fractionWad, repay1);
        assertEq(paid0, 0, "no token0");
        assertEq(paid1, VaultMath.portionDown(before.reserve1, fractionWad) - repay1, "the closed reserve less repaid");
        assertEq(quote.balanceOf(trader) - balance1, paid1, "paid to the trader");
        assertEq(vault.ledgerOf(vaultId).buffer1 - buffer1, repay1, "the repayment joins the buffer");
        _assertPortionsMoved(before, vault.positionOf(positionId), fractionWad);
        assertLedger();
    }

    /// @dev Closes the position one way or the other and measures what moved, from the vault's ledger, the trader's
    /// balances and the `Closed` events.
    function _closeMeasured(uint256 positionId, bool inTinySteps) internal returns (Outcome memory outcome) {
        uint256 income1 = _income1();
        uint256 buffer1 = vault.ledgerOf(vaultId).buffer1;
        uint256 balance0 = base.balanceOf(trader);
        uint256 balance1 = quote.balanceOf(trader);
        vm.recordLogs();
        outcome.repaid1 = inTinySteps ? _closeInTinySteps(positionId) : _closeWhole(positionId);
        (outcome.profitShare, outcome.closedEvents) = _profitShares(vm.getRecordedLogs());
        outcome.income1 = _income1() - income1;
        outcome.paid0 = base.balanceOf(trader) - balance0;
        outcome.paid1 = quote.balanceOf(trader) - balance1;
        outcome.outstanding1 = vault.accrualOf(vaultId).outstanding1;
        // No stream vests within the block, so the buffer gains the repayments alone.
        assertEq(vault.ledgerOf(vaultId).buffer1 - buffer1, outcome.repaid1, "the repayments join the buffer");
        _assertOnlyBystanderLeft();
        assertLedger();
    }

    // ---------------------------------------------------------------- the minimum borrow

    /// @dev The fractions leaving `maximum1` exactly at the minimum borrow and one unit below it, and the rest at the
    /// minimum: the least liquidity whose `maximum1` reaches it.
    function _boundaryFractions(uint256 positionId)
        internal
        view
        returns (uint256 fractionAtWad, uint256 fractionBelowWad, uint128 restAt)
    {
        uint256 minimum = vault.parametersOf(vaultId).minBorrowNotional;
        uint128 liquidity = vault.positionOf(positionId).liquidity;
        restAt = _leastLiquidityReaching(minimum, liquidity);
        (, uint256 maximumAt) = _extremes(restAt);
        (, uint256 maximumBelow) = _extremes(restAt - 1);
        assertEq(maximumAt, minimum, "the rest reaches the minimum exactly");
        assertEq(maximumBelow, minimum - 1, "one unit less of liquidity is one unit below");
        fractionAtWad = _fractionLeaving(liquidity, restAt);
        fractionBelowWad = _fractionLeaving(liquidity, restAt - 1);
    }

    /// @dev The least liquidity on the range whose `maximum1` reaches `target`, at most `high`.
    function _leastLiquidityReaching(uint256 target, uint128 high) internal pure returns (uint128) {
        (, uint256 maximumHigh) = _extremes(high);
        assertGe(maximumHigh, target, "the position reaches the target");
        // An empty debt's maximum1 is one unit, below any minimum that matters here.
        uint128 low = 0;
        // step < SEARCH_STEPS = 128: each halves an interval of at most 2^128, so 128 steps reach width 1
        for (uint256 step = 0; step < SEARCH_STEPS; ++step) {
            if (high - low <= 1) break;
            uint128 middle = low + (high - low) / 2;
            (, uint256 maximum1) = _extremes(middle);
            if (maximum1 >= target) high = middle;
            else low = middle;
        }
        return high;
    }

    /// @dev A fraction whose closed liquidity leaves exactly `rest`; exists for every rest as liquidity is below WAD.
    function _fractionLeaving(uint128 liquidity, uint128 rest) internal pure returns (uint256 fractionWad) {
        assertLt(liquidity, WAD, "each wei of fraction closes at most one unit");
        uint256 closing = liquidity - rest;
        fractionWad = (closing * WAD + liquidity - 1) / liquidity;
        assertEq(VaultMath.portionDown(liquidity, fractionWad), closing, "closes exactly the rest's complement");
    }

    // ---------------------------------------------------------------- measuring

    /// @dev The least token1 repayment the rule accepts for `fractionWad` of a token1-only position.
    function _minimumRepay1For(uint256 positionId, uint256 fractionWad) internal view returns (uint256) {
        Position memory position = vault.positionOf(positionId);
        uint128 closingLiquidity = uint128(VaultMath.portionDown(position.liquidity, fractionWad));
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        return minimumRepay1(0, closingLiquidity, sqrtLowerX96, sqrtUpperX96);
    }

    function _extremes(uint128 liquidity) internal pure returns (uint256 maximum0, uint256 maximum1) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(LOWER_TICK, UPPER_TICK);
        return VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
    }

    /// @dev Token1 owed to lenders and the protocol: the treasury's, the fee vault's, and the unvested stream.
    function _income1() internal view returns (uint256) {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        return uint256(ledger.treasury1) + ledger.feeVault1 + vault.streamOf(vaultId).remaining1;
    }

    /// @dev The profit shares the `Closed` events report, and how many there were.
    function _profitShares(Vm.Log[] memory logs) internal pure returns (uint256 total, uint256 closes) {
        // index < logs.length: every event of at most TINY_CLOSES + 1 = 21 closes, a handful per close
        for (uint256 index = 0; index < logs.length; ++index) {
            if (logs[index].topics[0] != IMetricLendingVault.Closed.selector) continue;
            (,,, uint256 share) = abi.decode(logs[index].data, (uint256, uint256, uint256, uint256));
            total += share;
            closes += 1;
        }
    }

    /// @dev Expects the close to revert with `reason`. A revert rolls back every write, so nothing is compared
    /// after it.
    function _expectRefusal(uint256 positionId, uint256 fractionWad, uint256 repay1, bytes4 reason) internal {
        vm.prank(trader);
        vm.expectRevert(reason);
        vault.close(CloseRequest({positionId: positionId, fractionWad: fractionWad, repay0: 0, repay1: repay1}));
    }

    // ---------------------------------------------------------------- assertions

    /// @dev The closed portions: liquidity and reserves rounded down, the release rounded up, the escrow kept, the
    /// basis by its escrow-free fraction (`VaultBook.basisClosed`), extremes recomputed, outstanding what the
    /// positions hold.
    function _assertPortionsMoved(Position memory before, Position memory afterwards, uint256 fractionWad)
        internal
        view
    {
        assertEq(
            afterwards.liquidity, before.liquidity - VaultMath.portionDown(before.liquidity, fractionWad), "liquidity"
        );
        assertEq(afterwards.reserve1, before.reserve1 - VaultMath.portionDown(before.reserve1, fractionWad), "reserve1");
        assertEq(
            afterwards.released1, before.released1 - VaultMath.portionUp(before.released1, fractionWad), "released1"
        );
        assertEq(afterwards.escrow, before.escrow, "the escrow stays");
        uint256 basisClosed = VaultMath.portionDown(before.basis - before.escrow, fractionWad);
        assertEq(afterwards.basis, before.basis - basisClosed, "the basis closes without the escrow");
        (uint256 maximum0, uint256 maximum1) = _extremes(afterwards.liquidity);
        assertEq(afterwards.maximum0, maximum0, "maximum0");
        assertEq(afterwards.maximum1, maximum1, "maximum1");
        assertEq(
            vault.accrualOf(vaultId).outstanding1,
            vault.positionOf(bystanderPositionId).released1 + afterwards.released1,
            "outstanding is what the positions hold"
        );
    }

    /// @dev Outstanding and the debt totals are exactly the bystander's: every closed part was released and removed.
    function _assertOnlyBystanderLeft() internal view {
        Position memory bystander = vault.positionOf(bystanderPositionId);
        Accrual memory accrual = vault.accrualOf(vaultId);
        assertEq(accrual.outstanding0, 0, "no token0 outstanding");
        assertEq(accrual.outstanding1, bystander.released1, "outstanding is the bystander's");
        (DebtTotals memory longDebts, DebtTotals memory shortDebts) = vault.debtsOf(vaultId);
        assertEq(longDebts.liquidity, bystander.liquidity, "long debts are the bystander's");
        assertEq(shortDebts.liquidity, 0, "no short debts");
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(LOWER_TICK, UPPER_TICK);
        uint160 sqrtBidX96 = source.sqrtBidX96();
        (uint256 held0, uint256 held1) =
            VaultMath.holdingsAt(bystander.liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96);
        (uint256 low,) = vault.debtValuesAt(vaultId, sqrtBidX96);
        // One debt's rounding slack: three units of each token.
        assertApproxEqAbs(
            low, VaultMath.valueInToken1(held0, held1, sqrtBidX96, false), 3 + VaultMath.priceTimes(3, sqrtBidX96, true)
        );
    }
}
