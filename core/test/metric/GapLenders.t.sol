// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Ledger} from "../../src/metric/vault/VaultTypes.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {VaultFixture} from "./utils/VaultFixture.sol";

/// @notice Lender edge cases from the fresh audit's gap list (2026-10-17): many small withdrawals against one (G10), a
/// first depositor's donation (G11), and entries and exits around a stream's vesting end and a new payment (G12).
contract GapLendersTest is VaultFixture {
    uint256 internal constant WAD = 1e18;
    /// @dev `VaultLending.VIRTUAL_SHARES`: a withdrawal's ownership is over the supply plus these.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    /// @dev The most pieces a G10 withdrawal is split into.
    uint256 internal constant MAX_PIECES = 24;
    /// @dev `VIRTUAL_SHARES / VIRTUAL_VALUE`: the shares one raw unit of value buys at this vault's first deposit.
    uint256 internal constant SHARES_PER_UNIT = 1e6;
    /// @dev Each G10 lender's deposit: about 50,000 USDC of value, 40% of it in base.
    uint256 internal constant LENDER_BASE = 10e18;
    uint256 internal constant LENDER_QUOTE = 30_000e6;
    /// @dev The G12 vault's capital, in quote only, so every amount is exact without a price.
    uint256 internal constant CAPITAL = 100_000e6;
    /// @dev What a quote-only round trip may lose to its own rounding: the share mint and the payout each round down,
    /// and the virtual shares keep a fraction of a unit.
    uint256 internal constant ROUND_TRIP_UNITS = 3;

    address internal otherLender = makeAddr("otherLender");
    address internal entrant = makeAddr("entrant");
    address internal donor = makeAddr("donor");
    address internal victim = makeAddr("victim");

    /// @dev Totals over one or more withdrawals.
    struct Withdrawal {
        uint256 amount0;
        uint256 amount1;
        uint256 burned;
    }

    function setUp() public override {
        super.setUp();
        _fundBoth(otherLender);
        _fundBoth(entrant);
        _fundBoth(donor);
        _fundBoth(victim);
    }

    // ---------------------------------------------------------------- G10: many small withdrawals against one

    /// @dev G10: splitting a withdrawal must neither pay more nor burn less than making it at once, or a lender could
    /// drain rounding from those who stay one piece at a time. On a partially lent vault, beside another lender (the
    /// claim fits the idle basket, so the payout is what can differ) or alone (the claim exceeds it, so both drain it
    /// and the burn is what can differ), the pieces pay each token no more than the single withdrawal plus one
    /// withdrawal's rounding, which does not grow with the number of pieces. They burn no fewer shares, less under one
    /// raw unit of value per piece: each piece prices its shares from rounded values, so a split that drains the idle
    /// basket may keep a fraction of a unit (0.18 of a unit over three pieces in one run), far below its gas.
    function testFuzz_smallWithdrawals_payNoMoreAndBurnNoFewerThanOne(uint256 pieces, uint256 borrowed, bool alone)
        public
    {
        pieces = bound(pieces, 2, MAX_PIECES);
        borrowed = bound(borrowed, 1_000e6, 25_000e6);
        uint256 shares = deposit(lender, LENDER_BASE, LENDER_QUOTE);
        if (!alone) deposit(otherLender, LENDER_BASE, LENDER_QUOTE);
        _openLongBorrowing(borrowed);
        Ledger memory idle = vault.ledgerOf(vaultId);
        uint256 idleValue = VaultMath.valueInToken1(idle.buffer0, idle.buffer1, source.sqrtBidX96(), true);
        uint256 rounding0 = _oneRounding(idle.buffer0, idleValue);
        uint256 rounding1 = _oneRounding(idle.buffer1, idleValue);
        uint256 snapshot = vm.snapshotState();
        Withdrawal memory once = _withdrawInPieces(lender, shares, 1);
        vm.revertToState(snapshot);
        Withdrawal memory split = _withdrawInPieces(lender, shares, pieces);
        if (alone) assertLt(once.burned, shares, "the claim exceeded the idle basket");
        else assertEq(once.burned, shares, "the claim fit the idle basket");
        assertLe(split.amount0, once.amount0 + rounding0, "token0: no more than one withdrawal");
        assertLe(split.amount1, once.amount1 + rounding1, "token1: no more than one withdrawal");
        assertGe(split.burned + pieces * SHARES_PER_UNIT, once.burned, "no fewer shares burned, but rounding");
        // Each piece rounds down on its own, so the split may pay less, by at most a rounding per piece.
        assertGe(split.amount1 + pieces * rounding1, once.amount1, "token1: a rounding per piece");
        assertLedger();
    }

    // ---------------------------------------------------------------- G11: a first depositor's donation

    /// @dev G11: the classic first-depositor attack mints a few shares, donates straight to the contract so the share
    /// price jumps, and lets a victim's deposit round to nothing. The vault prices shares from its ledger, never its
    /// balance, so a donation in either token books nothing, leaves the victim's shares and redemption exactly what
    /// they are without it, lets the donor redeem no more than it deposited, and stays in custody as surplus nobody
    /// owns.
    function testFuzz_donationBeforeAVictim_movesNeitherPriceNorRedemption(
        uint256 donorDeposit,
        uint256 donation0,
        uint256 donation1,
        uint256 victimDeposit
    ) public {
        donorDeposit = bound(donorDeposit, 1, 1_000e6);
        donation0 = bound(donation0, 0, 1e27);
        donation1 = bound(donation1, 1, 1e24);
        victimDeposit = bound(victimDeposit, 1e6, 1e15);
        deposit(donor, 0, donorDeposit);
        uint256 snapshot = vm.snapshotState();
        Withdrawal memory plain = _victimRoundTrip(victimDeposit);
        vm.revertToState(snapshot);
        Ledger memory before = vault.ledgerOf(vaultId);
        vm.startPrank(donor);
        base.transfer(address(vault), donation0);
        quote.transfer(address(vault), donation1);
        vm.stopPrank();
        assertEq(abi.encode(vault.ledgerOf(vaultId)), abi.encode(before), "the donation books nothing");
        Withdrawal memory donated = _victimRoundTrip(victimDeposit);
        assertEq(donated.burned, plain.burned, "the victim's shares are unmoved");
        assertEq(donated.amount1, plain.amount1, "the victim's redemption is unmoved");
        assertEq(donated.amount0, 0, "no donated base is paid out");
        assertGe(donated.amount1 + 2, victimDeposit, "the victim gets its deposit back, less rounding");
        (uint256 donor0, uint256 donor1) = _redeemAll(donor);
        assertEq(donor0, 0, "the donor redeems no base");
        assertLe(donor1, donorDeposit, "the donor redeems no more than it deposited");
        assertEq(base.balanceOf(address(vault)) - vault.ledgerOf(vaultId).held0, donation0, "base surplus unowned");
        assertEq(quote.balanceOf(address(vault)) - vault.ledgerOf(vaultId).held1, donation1, "quote surplus unowned");
        assertLedgerParts(vaultId);
    }

    // ---------------------------------------------------------------- G12: entrants around vesting

    /// @dev G12: a deposit values income still vesting at the ask, so an entrant pays for income earned before it. A
    /// second before the vesting end a second's income still vests; at and after the end all of it has, into idle
    /// capital. In each case an entrant who stays until everything vests leaves with no more than it put in, and the
    /// lender who earned the income keeps all of it.
    function test_entrantAroundTheVestingEnd_capturesNoEarlierIncome() public {
        deposit(lender, 0, CAPITAL);
        uint256 vestingEnd = _payIncome();
        // offsetSeconds in [-1, 1]: three entry times, a second before the vesting end, at it, a second after
        for (int256 offsetSeconds = -1; offsetSeconds <= 1; ++offsetSeconds) {
            uint256 snapshot = vm.snapshotState();
            uint256 unvested = _assertEntrantTakesNoIncome(uint256(int256(vestingEnd) + offsetSeconds));
            if (offsetSeconds < 0) assertGt(unvested, 0, "income still vesting at entry");
            else assertEq(unvested, 0, "all of it vested at the end");
            vm.revertToState(snapshot);
        }
    }

    /// @dev G12, at any entry time from the payment to a day past the vesting end: the entrant takes no earlier income.
    /// The fixed cases pin the edges; this rules out a window between them where entering would buy income cheaply.
    function testFuzz_entrantAnyTime_capturesNoEarlierIncome(uint256 delaySeconds) public {
        deposit(lender, 0, CAPITAL);
        uint256 openedAt = block.timestamp;
        _payIncome();
        _assertEntrantTakesNoIncome(openedAt + 30 days + bound(delaySeconds, 0, 2 days));
    }

    /// @dev G12: a new payment restarts the vesting of everything still unvested. An entrant in the same block pays for
    /// the old remainder and the new payment alike, so it takes neither.
    function test_entrantRightAfterANewPayment_capturesNoEarlierIncome() public {
        deposit(lender, 0, CAPITAL);
        uint256 unvestedBefore = _payTwice();
        uint256 unvested = _assertEntrantTakesNoIncome(block.timestamp);
        assertGt(unvested, unvestedBefore, "the new payment joined the stream");
    }

    /// @dev G12: when every lender has left, income still vesting goes to the treasury, as the maker book's does (D22),
    /// instead of waiting with the virtual shares, where nobody could claim it. The next entrant finds nothing to pay
    /// for and takes back its capital, less rounding.
    function test_entrantIntoAnEmptiedVault_findsNoWaitingIncome() public {
        deposit(lender, 0, CAPITAL);
        _payIncome();
        uint256 vesting = vault.streamOf(vaultId).remaining1;
        uint256 treasuryBefore = vault.ledgerOf(vaultId).treasury1;
        _redeemAll(lender);
        assertEq(vault.totalSharesOf(vaultId), 0, "every lender left");
        assertGt(vesting, 0, "income was vesting");
        assertEq(vault.streamOf(vaultId).remaining1, 0, "nothing waits");
        assertEq(vault.ledgerOf(vaultId).treasury1 - treasuryBefore, vesting, "it went to the treasury");
        vm.warp(block.timestamp + 3 days);
        uint256 shares = deposit(entrant, 0, CAPITAL);
        vm.warp(block.timestamp + 2 days);
        vm.prank(entrant);
        (, uint256 paid1,) = vault.withdraw(vaultId, shares, 0, 0, entrant);
        assertApproxEqAbs(paid1, CAPITAL, ROUND_TRIP_UNITS, "its capital back");
        assertLedger();
    }

    // ---------------------------------------------------------------- G12: leavers around vesting

    /// @dev G12: a withdrawal pays a share of idle capital only, so a lender who leaves forgoes income still vesting,
    /// and the lenders who stay receive it. A second before the vesting end the leaver forgoes the last second's
    /// income; at and after it, nothing.
    function test_leaverAroundTheVestingEnd_forgoesUnvestedIncome() public {
        deposit(lender, 0, CAPITAL / 2);
        deposit(otherLender, 0, CAPITAL / 2);
        uint256 vestingEnd = _payIncome();
        // offsetSeconds in [-1, 1]: three exit times, a second before the vesting end, at it, a second after
        for (int256 offsetSeconds = -1; offsetSeconds <= 1; ++offsetSeconds) {
            uint256 snapshot = vm.snapshotState();
            uint256 unvested = _assertLeaverForgoesUnvested(uint256(int256(vestingEnd) + offsetSeconds));
            if (offsetSeconds < 0) assertGt(unvested, 0, "income still vesting at exit");
            else assertEq(unvested, 0, "all of it vested at the end");
            vm.revertToState(snapshot);
        }
    }

    /// @dev G12: a lender leaving in the block of a new payment forgoes all of it and the old remainder it restarted,
    /// so the lenders who stay, and funded the loans that earned it, receive it.
    function test_leaverRightAfterANewPayment_forgoesIt() public {
        deposit(lender, 0, CAPITAL / 2);
        deposit(otherLender, 0, CAPITAL / 2);
        uint256 unvestedBefore = _payTwice();
        uint256 unvested = _assertLeaverForgoesUnvested(block.timestamp);
        assertGt(unvested, unvestedBefore, "the new payment joined the stream");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Withdraws `shares` in `pieces` equal parts, the last taking the remainder, stopping once the idle basket is
    /// empty: a claim beyond it has nothing left to take.
    function _withdrawInPieces(address who, uint256 shares, uint256 pieces) internal returns (Withdrawal memory total) {
        uint256 piece = shares / pieces;
        // index < pieces <= MAX_PIECES = 24
        for (uint256 index = 0; index < pieces; ++index) {
            if (_idleEmpty()) break;
            uint256 requested = index + 1 == pieces ? shares - piece * index : piece;
            vm.prank(who);
            (uint256 amount0, uint256 amount1, uint256 burned) = vault.withdraw(vaultId, requested, 0, 0, who);
            total.amount0 += amount0;
            total.amount1 += amount1;
            total.burned += burned;
        }
    }

    function _idleEmpty() internal view returns (bool) {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        if (ledger.buffer0 != 0) return false;
        return ledger.buffer1 == 0;
    }

    /// @dev One withdrawal's rounding on an idle balance, all of it against the withdrawer. The entitlement is the
    /// ownership times the vault's value over its idle value: the value rounds down by under five units of token1 (a
    /// unit on the idle basket, four on the debts' lower bound) and the idle value up by under one, so the fraction
    /// errs by under `6 / idleValue` of itself, at most of the whole idle balance. The ownership and the entitlement
    /// each round down a WAD unit, the first scaled by the value over the idle value (at most 10 at the 90% ceiling),
    /// and the payout and this bound's own division a unit each.
    function _oneRounding(uint256 idleAmount, uint256 idleValue) internal pure returns (uint256) {
        return idleAmount * 6 / idleValue + idleAmount * 11 / WAD + 2;
    }

    /// @dev The victim deposits quote and withdraws every share at once; `burned` is the shares it was minted.
    function _victimRoundTrip(uint256 amount) internal returns (Withdrawal memory trip) {
        uint256 shares = deposit(victim, 0, amount);
        vm.prank(victim);
        (trip.amount0, trip.amount1, trip.burned) = vault.withdraw(vaultId, shares, 0, 0, victim);
        assertEq(trip.burned, shares, "nothing lent: every share burns");
    }

    /// @dev Withdraws all of a lender's shares; a claim that rounds to nothing pays nothing.
    function _redeemAll(address who) internal returns (uint256, uint256) {
        uint256 shares = vault.sharesOf(vaultId, who);
        vm.prank(who);
        try vault.withdraw(vaultId, shares, 0, 0, who) returns (uint256 amount0, uint256 amount1, uint256) {
            return (amount0, amount1);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IMetricLendingVault.InsufficientIdle.selector, "only a claim of nothing");
            return (0, 0);
        }
    }

    /// @dev Enters with `CAPITAL` at `enterAt`, stays until everything has vested, and leaves; then the incumbent
    /// leaves. Returns the income still vesting at entry.
    function _assertEntrantTakesNoIncome(uint256 enterAt) internal returns (uint256 unvestedAtEntry) {
        vm.warp(enterAt);
        // Release moves income from the stream to the buffer, so this sum is the incumbent's, released or not.
        uint256 earned = uint256(vault.ledgerOf(vaultId).buffer1) + vault.streamOf(vaultId).remaining1;
        uint256 shares = deposit(entrant, 0, CAPITAL);
        unvestedAtEntry = vault.streamOf(vaultId).remaining1;
        vm.warp(enterAt + 2 days);
        vm.prank(entrant);
        (uint256 entrant0, uint256 entrant1,) = vault.withdraw(vaultId, shares, 0, 0, entrant);
        assertEq(entrant0, 0, "a quote-only vault");
        assertLe(entrant1, CAPITAL, "the entrant takes no earlier income");
        assertGe(entrant1 + ROUND_TRIP_UNITS, CAPITAL, "and loses only rounding");
        (, uint256 incumbent1) = _redeemAll(lender);
        assertGe(incumbent1 + ROUND_TRIP_UNITS, earned, "the incumbent keeps all it earned");
        assertLedger();
    }

    /// @dev `lender` leaves at `exitAt`; `otherLender` stays until everything has vested. Returns the income still
    /// vesting at the exit.
    function _assertLeaverForgoesUnvested(uint256 exitAt) internal returns (uint256 unvestedAtExit) {
        vm.warp(exitAt);
        // A checkpoint, as the withdrawal's own: what has vested joins the buffer.
        vault.recenter(vaultId);
        unvestedAtExit = vault.streamOf(vaultId).remaining1;
        uint256 shares = vault.sharesOf(vaultId, lender);
        uint256 ownershipWad = FullMath.mulDiv(shares, WAD, vault.totalSharesOf(vaultId) + VIRTUAL_SHARES);
        uint256 vestedShare = FullMath.mulDiv(vault.ledgerOf(vaultId).buffer1, ownershipWad, WAD);
        (, uint256 leaver1) = _redeemAll(lender);
        assertEq(leaver1, vestedShare, "a share of vested capital only");
        assertEq(vault.streamOf(vaultId).remaining1, unvestedAtExit, "the unvested income stays");
        vm.warp(exitAt + 2 days);
        (, uint256 stayer1) = _redeemAll(otherLender);
        assertApproxEqAbs(stayer1, leaver1 + unvestedAtExit, ROUND_TRIP_UNITS, "the stayer receives it");
        assertLedger();
    }

    /// @dev Lets a 40,000 USDC long run 30 days on the quote-only vault and closes it: its premium starts vesting to
    /// lenders, and nothing stays lent. Returns the stream's vesting end.
    function _payIncome() internal returns (uint256 vestingEnd) {
        uint256 positionId = _openLongBorrowing(40_000e6);
        vm.warp(block.timestamp + 30 days);
        _closeAtBid(positionId);
        assertGt(vault.streamOf(vaultId).remaining1, 0, "income vesting");
        vestingEnd = vault.streamOf(vaultId).vestingEnd1;
        assertEq(vestingEnd, block.timestamp + 1 days, "vests over a day");
    }

    /// @dev Two 20,000 USDC longs: the first closes after 30 days, the second half a day later, a new payment into a
    /// stream half vested. Nothing stays lent. Returns the income still vesting just before the second payment.
    function _payTwice() internal returns (uint256 unvestedBefore) {
        uint256 firstPositionId = _openLongBorrowing(20_000e6);
        uint256 secondPositionId = _openLongBorrowing(20_000e6);
        vm.warp(block.timestamp + 30 days);
        _closeAtBid(firstPositionId);
        vm.warp(block.timestamp + 12 hours);
        vault.recenter(vaultId);
        unvestedBefore = vault.streamOf(vaultId).remaining1;
        assertGt(unvestedBefore, 0, "half vested");
        _closeAtBid(secondPositionId);
        assertEq(vault.streamOf(vaultId).vestingEnd1, block.timestamp + 1 days, "vesting restarts");
    }

    /// @dev A long one to two percent below the price, borrowing `notional` of quote, with a little more collateral
    /// than the chord needs.
    function _openLongBorrowing(uint256 notional) internal returns (uint256) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        uint128 liquidity = liquidityFor1(lower, upper, notional);
        uint256 collateral = minimumCollateral(lower, upper, liquidity) + 100e6;
        return open(openRequest(true, lower, upper, liquidity, uint128(collateral)));
    }

    function _closeAtBid(uint256 positionId) internal {
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        closeFull(positionId, repay0, repay1);
    }

    function _fundBoth(address who) internal {
        fundWith(who, base);
        fundWith(who, quote);
    }
}
