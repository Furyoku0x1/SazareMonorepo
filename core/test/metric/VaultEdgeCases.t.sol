// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Accrual, CloseRequest, OpenRequest, Position, VaultParameters} from "../../src/metric/vault/VaultTypes.sol";
import {Leg, MakerCloseRequest, MakerOpenRequest, MakerPosition} from "../../src/metric/vault/MakerTypes.sol";
import {IMakerBook} from "../../src/metric/vault/interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {Vm} from "forge-std/Vm.sol";
import {MakerFixture} from "./utils/MakerFixture.sol";
import {TestToken} from "./utils/VaultFixture.sol";

/// @notice A quote token that refuses transfers to or from a blocklisted address, as USDC does.
contract BlocklistToken is TestToken {
    mapping(address => bool) public blocked;

    constructor() TestToken("BLOCKLIST USD", 6) {}

    function setBlocked(address who, bool value) external {
        blocked[who] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from], "blocked");
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// @notice Edge cases the fresh audit (2026-10-17) found no test for: unknown and crossed ids, shares not owned,
/// version caps, books not created, and collateral top-ups.
contract VaultEdgeCasesTest is MakerFixture {
    uint256 internal constant WAD = 1e18;
    /// @dev About 10% below the price: ticks [-201,400, -201,300).
    int24 internal constant LEVEL_10X = -2_014;
    /// @dev Equals `VaultAccrual.MAX_CURVE_VERSIONS` and `MakerMath.MAX_VERSIONS`, both 64. The vault and the book
    /// start with one version each, so `MAX_VERSIONS - 1` appends reach the cap.
    uint256 internal constant MAX_VERSIONS = 64;
    /// @dev A withdrawal burns only the shares the idle basket covers; eight rounds are ample to empty one lender or
    /// maker.
    uint256 internal constant MAX_WITHDRAWAL_ROUNDS = 8;

    // ---------------------------------------------------------------- ids

    /// @dev Ids 0 and 999 were never issued, so every passive and maker entry point refuses them with UnknownPosition:
    /// an unissued id must not read as a zeroed position that settles, flags or closes for nobody.
    function test_unknownPositions_areRefusedEverywhere() public {
        _expectUnknownPassive(0);
        _expectUnknownMaker(0);
        _expectUnknownPassive(999);
        _expectUnknownMaker(999);
    }

    /// @dev Passive and maker positions share one id counter but live in separate maps, so an id from one book is
    /// unknown to the other's entry points, even to its owner.
    function test_positionIds_doNotCrossBooks() public {
        deposit(lender, 0, 100_000e6);
        uint256 passivePositionId = openLong(10_000e6, 300e6);
        uint256 makerPositionId = _openMakerLong();
        assertTrue(passivePositionId != makerPositionId, "one counter");
        _expectUnknownMaker(passivePositionId);
        _expectUnknownPassive(makerPositionId);
        assertLedger();
    }

    /// @dev A closed passive or maker position is deleted, so its id is refused everywhere afterwards: a deleted
    /// position's zeroed storage must read as unknown, not as an ownerless live position anyone could act on.
    function test_closedPosition_isUnknown() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 300e6);
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        closeFull(positionId, repay0, repay1);
        _expectUnknownPassive(positionId);
        uint256 makerPositionId = _openMakerLong();
        (uint256[] memory makerRepay0, uint256[] memory makerRepay1) = repaymentsAtBid(makerPositionId, WAD);
        closeMakerFull(makerPositionId, makerRepay0, makerRepay1);
        _expectUnknownMaker(makerPositionId);
    }

    /// @dev Vault 0 and the id past the last created vault are refused by every lender, maker, trader and owner entry
    /// point with UnknownVault, so no call can write to, or create a book on, a vault that was never created.
    function test_unknownVaults_areRefused() public {
        _expectUnknownVault(0);
        _expectUnknownVault(vault.vaultCount() + 1);
    }

    // ---------------------------------------------------------------- shares

    /// @dev A lender or maker can burn only shares it holds: a stranger's single share and an owner's balance plus one
    /// both refuse with InsufficientShares, in the passive vault and in a bucket alike, so no one withdraws another's
    /// capital.
    function test_withdraw_cannotSpendSharesNotOwned() public {
        uint256 shares = deposit(lender, 10e18, 20_000e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.InsufficientShares.selector);
        vault.withdraw(vaultId, 1, 0, 0, trader);
        vm.prank(lender);
        vm.expectRevert(IMetricLendingVault.InsufficientShares.selector);
        vault.withdraw(vaultId, shares + 1, 0, 0, lender);
        (uint256 bucketId, uint256 makerShares) = depositBuy(makerA, LEVEL_10X, 1_000e6);
        vm.prank(makerB);
        vm.expectRevert(IMetricLendingVault.InsufficientShares.selector);
        vault.withdrawOrder(vaultId, bucketId, 1, 0, 0, makerB);
        vm.prank(makerA);
        vm.expectRevert(IMetricLendingVault.InsufficientShares.selector);
        vault.withdrawOrder(vaultId, bucketId, makerShares + 1, 0, 0, makerA);
        assertLedger();
    }

    // ---------------------------------------------------------------- versions

    /// @dev The cap only stops the owner: open positions keep accruing and close normally, and appending the same
    /// curve many times prices premium as one version would.
    function test_curveVersions_stopAtTheCapAndPositionsStillClose() public {
        (uint256 twinVaultId, uint256 twinPositionId) = _twinVaultWithAPosition();
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 300e6);
        vm.startPrank(owner);
        // version < MAX_VERSIONS = 64: 63 appends after the first version
        for (uint256 version = 1; version < MAX_VERSIONS; ++version) {
            vm.warp(block.timestamp + 1 hours);
            vault.appendCurves(vaultId, defaultCurves());
        }
        vm.expectRevert(IMetricLendingVault.TooManyCurveVersions.selector);
        vault.appendCurves(vaultId, defaultCurves());
        vm.stopPrank();
        assertEq(vault.curvesOf(vaultId).length, MAX_VERSIONS, "at the cap");
        vm.warp(block.timestamp + 1 days);
        vault.settle(positionId);
        vault.settle(twinPositionId);
        Accrual memory capped = vault.accrualOf(vaultId);
        Accrual memory twin = vault.accrualOf(twinVaultId);
        assertApproxEqAbs(capped.rateIndex1Ray, twin.rateIndex1Ray, MAX_VERSIONS, "same premium as one version");
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        closeFull(positionId, repay0, repay1);
        assertEq(vault.positionOf(positionId).owner, address(0), "closed at the cap");
        assertLedgerParts(vaultId);
        assertLedgerParts(twinVaultId);
        uint256 held1 = uint256(vault.ledgerOf(vaultId).held1) + vault.ledgerOf(twinVaultId).held1;
        assertEq(held1, quote.balanceOf(address(vault)), "both vaults' held1 vs balance");
    }

    /// @dev The book's curve and floor-table versions each stop at the cap, and an open leg still settles and closes
    /// across all of them: the cap bounds the owner's appends without trapping a position behind a long version list.
    function test_bookVersions_stopAtTheCapAndLegsStillClose() public {
        uint256 makerPositionId = _openMakerLong();
        vm.startPrank(owner);
        // version < MAX_VERSIONS = 64: 63 appends of each after the first version
        for (uint256 version = 1; version < MAX_VERSIONS; ++version) {
            vm.warp(block.timestamp + 1 hours);
            vault.appendBookCurve(vaultId, defaultBookCurve());
            vault.appendFloorTable(vaultId, defaultFloorRows());
        }
        vm.expectRevert(IMetricLendingVault.TooManyCurveVersions.selector);
        vault.appendBookCurve(vaultId, defaultBookCurve());
        vm.expectRevert(IMetricLendingVault.TooManyCurveVersions.selector);
        vault.appendFloorTable(vaultId, defaultFloorRows());
        vm.stopPrank();
        vault.settleMaker(makerPositionId);
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(makerPositionId, WAD);
        closeMakerFull(makerPositionId, repay0, repay1);
        assertEq(vault.makerPositionOf(makerPositionId).owner, address(0), "closed at the cap");
        assertLedger();
    }

    // ---------------------------------------------------------------- books

    /// @dev A vault created without a book refuses maker deposits, maker opens and book curve appends with
    /// BookDisabled: a missing book must not act as a book with zeroed settings.
    function test_vaultWithoutABook_refusesMakerActions() public {
        vm.prank(owner);
        uint256 bareVaultId = vault.createVault(defaultParameters(), defaultCurves());
        vm.prank(makerA);
        vm.expectRevert(IMakerBook.BookDisabled.selector);
        vault.depositOrder(bareVaultId, LEVEL_10X, true, 1_000e6, 0, makerA);
        MakerOpenRequest memory request = makerRequest(true, single(1), single128(1), 10e6);
        request.vaultId = bareVaultId;
        vm.prank(trader);
        vm.expectRevert(IMakerBook.BookDisabled.selector);
        vault.openMaker(request);
        vm.prank(owner);
        vm.expectRevert(IMakerBook.BookDisabled.selector);
        vault.appendBookCurve(bareVaultId, defaultBookCurve());
    }

    // ---------------------------------------------------------------- bands

    /// @dev A band the vault cannot use refuses priced actions, but closes need no price: a full close and a force
    /// close both still run, so no position is trapped by a failed price.
    function test_invalidBand_refusesPricedActionsButNotCloses() public {
        uint256 shares = deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 300e6);
        uint256 delinquentPositionId = _openDelinquentLong();
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        // Bid above ask.
        setPrice(PRICE_TICK, -1);
        vm.startPrank(lender);
        vm.expectRevert(IMetricLendingVault.InvalidBand.selector);
        vault.deposit(vaultId, 0, 1_000e6, 0, lender);
        vm.expectRevert(IMetricLendingVault.InvalidBand.selector);
        vault.withdraw(vaultId, shares / 10, 0, 0, lender);
        vm.stopPrank();
        vm.expectRevert(IMetricLendingVault.InvalidBand.selector);
        open(openRequest(true, PRICE_TICK - 200, PRICE_TICK - 100, 1e15, 300e6));
        closeFull(positionId, repay0, repay1);
        assertEq(vault.positionOf(positionId).owner, address(0), "closed without a price");
        vm.warp(block.timestamp + 30 days);
        vault.flag(delinquentPositionId);
        vm.warp(block.timestamp + 2 days);
        source.setBroken(true);
        vm.prank(closer);
        vault.forceClose(delinquentPositionId);
        assertEq(vault.positionOf(delinquentPositionId).owner, address(0), "force closed without a price");
        assertLedger();
    }

    /// @dev A level whose range leaves the tick bounds is refused before any price or token moves: no sqrt price
    /// exists past the bounds, so a deposit there could never be valued or filled.
    function test_depositOrder_refusesALevelOutsideTheTickBounds() public {
        vm.startPrank(makerA);
        vm.expectRevert(IMakerBook.InvalidLevel.selector);
        vault.depositOrder(vaultId, 10_000, false, 1e18, 0, makerA);
        vm.expectRevert(IMakerBook.InvalidLevel.selector);
        vault.depositOrder(vaultId, -10_000, true, 1_000e6, 0, makerA);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- top-ups

    /// @dev Collateral added later counts in the basis, so it comes back whole: no profit share is taken on it. Only
    /// the owner may add it, so no one else can change a position's basis.
    function test_addCollateral_comesBackWholeAndOnlyFromTheOwner() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 300e6);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.Unauthorized.selector);
        vault.addCollateral(positionId, 1);
        uint256 snapshot = vm.snapshotState();
        (, uint256 plainPaid1) = _closePassive(positionId);
        vm.revertToState(snapshot);
        vm.prank(trader);
        vault.addCollateral(positionId, 500e6);
        assertLedger();
        (, uint256 toppedPaid1) = _closePassive(positionId);
        assertEq(toppedPaid1, plainPaid1 + 500e6, "returned whole");
        assertLedger();
    }

    /// @dev The maker book's counterpart: only the owner may top up, a zero top-up refuses, and the collateral joins
    /// both the reserves and the basis, so a full close returns it whole with no profit share taken on it.
    function test_addMakerCollateral_comesBackWholeAndOnlyFromTheOwner() public {
        uint256 positionId = _openMakerLong();
        vm.prank(makerB);
        vm.expectRevert(IMetricLendingVault.Unauthorized.selector);
        vault.addMakerCollateral(positionId, 1);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.ZeroAmount.selector);
        vault.addMakerCollateral(positionId, 0);
        uint256 snapshot = vm.snapshotState();
        (, uint256 plainPaid1) = _closeMaker(positionId);
        vm.revertToState(snapshot);
        MakerPosition memory before = vault.makerPositionOf(positionId);
        vm.prank(trader);
        vault.addMakerCollateral(positionId, 500e6);
        MakerPosition memory afterwards = vault.makerPositionOf(positionId);
        assertEq(afterwards.reserve1, before.reserve1 + 500e6, "reserves");
        assertEq(afterwards.basis, before.basis + 500e6, "basis");
        assertLedger();
        (, uint256 toppedPaid1) = _closeMaker(positionId);
        assertEq(toppedPaid1, plainPaid1 + 500e6, "returned whole");
        assertLedger();
    }

    // ---------------------------------------------------------------- audit fixes (2026-10-17)

    /// @dev Audit finding Sol-1-1: a partial close took its fraction of the escrow's basis while the escrow stayed, so
    /// the final close taxed the escrow's refund as profit. Closing in two halves now pays what one close pays, after
    /// premium has used some escrow and a top-up added more.
    function test_partialCloses_payWhatOneClosePays() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = _openEscrowedLong(1_000e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(trader);
        vault.addEscrow(positionId, 50e6);
        uint256 snapshot = vm.snapshotState();
        uint256 balanceBefore = quote.balanceOf(trader);
        _closePassive(positionId);
        uint256 oneClose = quote.balanceOf(trader) - balanceBefore;
        vm.revertToState(snapshot);
        uint256 halfRepay1 = vault.positionOf(positionId).maximum1 / 2 + 1;
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: 0.5e18, repay0: 0, repay1: halfRepay1}));
        _closePassive(positionId);
        assertApproxEqAbs(quote.balanceOf(trader) - balanceBefore, oneClose, 2, "two halves pay as one close");
        assertLedger();
    }

    /// @dev Audit finding Sol-1-1 on the maker book: closing in two halves, after premium has used some escrow and a
    /// top-up added more, pays within rounding what one close pays, so no escrow refund is taxed as profit.
    function test_partialMakerCloses_payWhatOneClosePays() public {
        uint256 positionId = _openMakerLong();
        vm.warp(block.timestamp + 1 days);
        vm.prank(trader);
        vault.addMakerEscrow(positionId, 50e6);
        uint256 snapshot = vm.snapshotState();
        uint256 balanceBefore = quote.balanceOf(trader);
        _closeMaker(positionId);
        uint256 oneClose = quote.balanceOf(trader) - balanceBefore;
        vm.revertToState(snapshot);
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, 0.5e18);
        vm.prank(trader);
        vault.closeMaker(
            MakerCloseRequest({positionId: positionId, fractionWad: 0.5e18, repay0: repay0, repay1: repay1})
        );
        _closeMaker(positionId);
        assertApproxEqAbs(quote.balanceOf(trader) - balanceBefore, oneClose, 3, "two halves pay as one close");
        assertLedger();
    }

    /// @dev Audit finding Sol-3-2: the virtual offset left a unit in a bucket its last maker emptied, and the next
    /// maker into it lost two. An unlent bucket now retires when its last shares leave, so each exit pays in full.
    function test_withdrawOrder_lastMakerOutTakesEveryUnit() public {
        (uint256 bucketId, uint256 shares) = depositBuy(makerA, LEVEL_10X, 100_000e6);
        vm.prank(makerA);
        (, uint256 amount1,) = vault.withdrawOrder(vaultId, bucketId, shares, 0, 0, makerA);
        assertEq(amount1, 100_000e6, "every unit back");
        assertTrue(vault.bucketOf(vaultId, bucketId).retired, "retired");
        assertEq(vault.bucketOf(vaultId, bucketId).balance1, 0, "nothing left behind");
        (uint256 nextBucketId, uint256 nextShares) = depositBuy(makerB, LEVEL_10X, 100_000e6);
        assertTrue(nextBucketId != bucketId, "a fresh generation");
        vm.prank(makerB);
        (, uint256 nextAmount1,) = vault.withdrawOrder(vaultId, nextBucketId, nextShares, 0, 0, makerB);
        assertEq(nextAmount1, 100_000e6, "the next maker too");
        assertLedger();
    }

    /// @dev Audit finding H1: withdrawals valued a debt off the price near zero, so a lender exiting while one was out
    /// forfeited its value to whoever held the remaining shares. A 1 USDC deposit placed before a 20,000 USDC lender's
    /// exit then took most of a 10,000 USDC debt's repayment. Debts are now valued at their holdings: the exit keeps the
    /// shares the debt backs, the 1 USDC deposit leaves with about 1 USDC, and the lender recovers the repayment.
    function test_exitWhileAFarDebtIsOut_forfeitsNothingToAJustInTimeDeposit() public {
        address attacker = makeAddr("attacker");
        fundWith(attacker, quote);
        uint256 lenderBefore = quote.balanceOf(lender);
        deposit(lender, 0, 20_000e6);
        uint256 positionId = _openFarLong();
        vm.warp(block.timestamp + 10 days);
        vault.settle(positionId);
        uint256 attackerShares = deposit(attacker, 0, 1e6);
        uint256 shares = vault.sharesOf(vaultId, lender);
        vm.prank(lender);
        (,, uint256 burned) = vault.withdraw(vaultId, shares, 0, 0, lender);
        assertLt(burned, shares, "the exit keeps the shares the debt backs");
        vm.warp(block.timestamp + 1 days);
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        closeFull(positionId, repay0, repay1);
        vm.warp(block.timestamp + 2 days);
        vm.prank(attacker);
        (, uint256 attackerPayout,) = vault.withdraw(vaultId, attackerShares, 0, 0, attacker);
        assertLe(attackerPayout, 1.01e6, "the deposit takes none of the debt's value");
        _withdrawEverything(lender);
        assertGe(quote.balanceOf(lender), lenderBefore, "the lender recovers the repayment");
        assertLedger();
    }

    /// @dev Audit finding H1's other face: a last lender's full exit while a far debt was out burned every share for the
    /// idle capital alone, so the debt's later repayment had no lender to go to. The exit now keeps the debt's shares.
    function test_lastLenderExit_keepsTheSharesAFarDebtBacks() public {
        uint256 lenderBefore = quote.balanceOf(lender);
        deposit(lender, 0, 20_000e6);
        uint256 positionId = _openFarLong();
        vm.warp(block.timestamp + 10 days);
        vault.settle(positionId);
        uint256 shares = vault.sharesOf(vaultId, lender);
        vm.prank(lender);
        (,, uint256 burned) = vault.withdraw(vaultId, shares, 0, 0, lender);
        assertLt(burned, shares, "shares left for the debt");
        vm.warp(block.timestamp + 5 days);
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        closeFull(positionId, repay0, repay1);
        vm.warp(block.timestamp + 2 days);
        _withdrawEverything(lender);
        assertGe(quote.balanceOf(lender), lenderBefore, "the lender recovers the repayment");
        assertEq(vault.totalSharesOf(vaultId), 0, "every share redeemed");
        assertLedger();
    }

    /// @dev Sol's verification of H1: the debt tree's rounding slack was whole units of each token. With a base of no
    /// decimals worth 10,000 USDC, a 101 USDC debt holding no base was priced for deposits at 30,065 USDC, and a
    /// victim's 10,000 USDC deposit beside it came back as 4,003. It now comes back whole.
    function test_depositBesideADebt_onABaseWithoutDecimals_comesBackWhole() public {
        uint256 zeroVaultId = _openOnABaseWithoutDecimals();
        address victim = makeAddr("victim");
        fundWith(victim, quote);
        vm.prank(victim);
        uint256 shares = vault.deposit(zeroVaultId, 0, 10_000e6, 0, victim);
        uint256 positionId = vault.lastPositionId();
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        closeFull(positionId, repay0, repay1);
        uint256 balanceBefore = quote.balanceOf(victim);
        vm.prank(victim);
        vault.withdraw(zeroVaultId, shares, 0, 0, victim);
        assertGe(quote.balanceOf(victim) - balanceBefore, 9_999e6, "the deposit comes back whole");
        assertLedgerParts(zeroVaultId);
    }

    /// @dev A vault on a base of no decimals worth 10,000 USDC, with 10,000 USDC lent and a 101 USDC long far below.
    function _openOnABaseWithoutDecimals() internal returns (uint256 zeroVaultId) {
        VaultParameters memory parameters = defaultParameters();
        parameters.token0 = address(new TestToken("WHOLE", 0));
        vm.prank(owner);
        zeroVaultId = vault.createVault(parameters, defaultCurves());
        // A raw price of 1e10: 10,000 USDC of six decimals per unit.
        setPrice(230_258, 0);
        vm.prank(lender);
        vault.deposit(zeroVaultId, 0, 10_000e6, 0, lender);
        int24 lower = 200_000;
        int24 upper = 201_000;
        uint128 liquidity = liquidityFor1(lower, upper, 101e6);
        OpenRequest memory request = openRequest(true, lower, upper, liquidity, 0);
        request.vaultId = zeroVaultId;
        request.collateral = uint128(minimumCollateral(lower, upper, liquidity) + 1);
        request.escrow = 10e6;
        vm.prank(trader);
        vault.open(request);
    }

    /// @dev A 10,000 USDC long 3,000 ticks below the price: all token1, which the old lower bound valued at nothing.
    function _openFarLong() internal returns (uint256) {
        int24 lower = PRICE_TICK - 3_000;
        int24 upper = PRICE_TICK - 2_900;
        uint128 liquidity = liquidityFor1(lower, upper, 10_000e6);
        OpenRequest memory request = openRequest(true, lower, upper, liquidity, 0);
        request.collateral = uint128(minimumCollateral(lower, upper, liquidity) + 1);
        request.escrow = 2_000e6;
        return open(request);
    }

    function _withdrawEverything(address who) internal {
        uint256 shares = vault.sharesOf(vaultId, who);
        // round < MAX_WITHDRAWAL_ROUNDS = 8: each burns what the idle basket covers; a few rounds empty a lender
        for (uint256 round = 0; round < MAX_WITHDRAWAL_ROUNDS; ++round) {
            if (shares == 0) break;
            vm.prank(who);
            (,, uint256 burned) = vault.withdraw(vaultId, shares, 0, 0, who);
            shares -= burned;
        }
        assertEq(shares, 0, "fully out");
    }

    /// @dev Audit finding X-5: a force close pushed the leftover to the owner, so a quote token that blocklists the
    /// owner made every force close revert until premium ate the leftover, holding lent capital meanwhile. The close
    /// now goes through and keeps the refused payout for the owner, who claims it to their own address once allowed.
    function test_forceClose_keepsAPayoutTheTokenRefuses() public {
        BlocklistToken blockedQuote = new BlocklistToken();
        VaultParameters memory parameters = defaultParameters();
        parameters.token1 = address(blockedQuote);
        vm.prank(owner);
        uint256 blockedVaultId = vault.createVault(parameters, defaultCurves());
        fundWith(lender, blockedQuote);
        fundWith(trader, blockedQuote);
        vm.prank(lender);
        vault.deposit(blockedVaultId, 0, 100_000e6, 0, lender);
        OpenRequest memory request = openRequest(true, PRICE_TICK - 200, PRICE_TICK - 100, 0, 300e6);
        request.liquidity = liquidityFor1(PRICE_TICK - 200, PRICE_TICK - 100, 10_000e6);
        request.vaultId = blockedVaultId;
        request.escrow = 1;
        vm.prank(trader);
        uint256 positionId = vault.open(request);
        blockedQuote.setBlocked(trader, true);
        vm.warp(block.timestamp + 30 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).owner, address(0), "force closed though the owner is blocked");
        (, uint256 kept) = vault.unclaimedOf(blockedVaultId, trader);
        assertGt(kept, 0, "the payout is kept");
        assertEq(vault.ledgerOf(blockedVaultId).unclaimed1, kept, "and counted in the ledger");
        vm.prank(trader);
        vm.expectRevert();
        vault.claimPayout(blockedVaultId, 1);
        blockedQuote.setBlocked(trader, false);
        uint256 balanceBefore = blockedQuote.balanceOf(trader);
        vm.prank(trader);
        vault.claimPayout(blockedVaultId, 1);
        assertEq(blockedQuote.balanceOf(trader) - balanceBefore, kept, "claimed in full once allowed");
        assertEq(vault.ledgerOf(blockedVaultId).unclaimed1, 0, "nothing left kept");
        assertLedgerParts(blockedVaultId);
    }

    /// @dev Audit finding W-4: collateral was token1 only, so a position that held token1 and owed token0 had no exit
    /// that kept its value while the pool could not swap. A long carried below its range now posts base, repays in
    /// kind with no swap and takes its quote back. The base enters the basis at the close bid, so the profit share is
    /// taken only on what the fall in its debt's value earned it.
    function test_addCollateral0_letsAPositionRepayInKind() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 300e6);
        Position memory opened = vault.positionOf(positionId);
        // Below the range the debt is all base, and the long holds only quote.
        setPrice(PRICE_TICK - 400, 1);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.Unauthorized.selector);
        vault.addCollateral0(positionId, 1);
        vm.prank(trader);
        vault.addCollateral0(positionId, opened.maximum0);
        uint256 basis = vault.positionOf(positionId).basis;
        assertGt(basis, opened.basis + 9_000e6, "the base enters the basis at the bid");
        uint256 quoteBefore = quote.balanceOf(trader);
        uint256 incomeBefore = _income1();
        vm.recordLogs();
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: opened.maximum0, repay1: 0}));
        assertEq(vault.positionOf(positionId).owner, address(0), "closed in kind");
        // The crossing's realized charge comes out of the escrow; what lenders and the protocol took is that charge
        // and the profit share.
        uint256 share = _closedShare(vm.getRecordedLogs());
        uint256 premium = _income1() - incomeBefore - share;
        assertGt(premium, 0, "the crossing pays its realized charge");
        uint256 proceeds = uint256(opened.reserve1) + opened.escrow - premium;
        uint256 profit = proceeds > basis ? proceeds - basis : 0;
        uint256 profitShare = profit * vault.parametersOf(vaultId).profitShareBps / 10_000;
        assertApproxEqAbs(share, profitShare, 1, "the share of the proceeds");
        assertApproxEqAbs(quote.balanceOf(trader) - quoteBefore, proceeds - share, 1, "its quote, less the share");
        assertLedger();
    }

    /// @dev Audit finding W-4 on the maker book: a long carried far below its leg posts base and repays in kind, with
    /// no token1 and no swap, so a maker position also keeps an exit while the pool cannot swap.
    /// @dev Sol's finding on W-4: adding token0 and taking it back in the same close must leave the profit share where
    /// it was. Counted at the ask while the close values it at the bid, a large enough round trip erased the share.
    function test_addCollateral0_roundTripLeavesTheProfitShare() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 300e6);
        Position memory opened = vault.positionOf(positionId);
        setPrice(PRICE_TICK - 400, 30);
        vm.prank(trader);
        vault.addCollateral0(positionId, opened.maximum0);
        uint256 snapshot = vm.snapshotState();
        uint256 plainShare = _treasuryAfterClosingInKind(positionId, opened.maximum0);
        vm.revertToState(snapshot);
        vm.prank(trader);
        vault.addCollateral0(positionId, 100e18);
        uint256 roundTripShare = _treasuryAfterClosingInKind(positionId, opened.maximum0);
        assertGt(plainShare, 0, "a winning close pays a share");
        assertApproxEqAbs(roundTripShare, plainShare, 1, "the round trip leaves it");
    }

    function _treasuryAfterClosingInKind(uint256 positionId, uint256 repay0) internal returns (uint256) {
        uint256 before = vault.ledgerOf(vaultId).treasury1 + vault.ledgerOf(vaultId).feeVault1;
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: repay0, repay1: 0}));
        return vault.ledgerOf(vaultId).treasury1 + vault.ledgerOf(vaultId).feeVault1 - before;
    }

    function test_addMakerCollateral0_letsAPositionRepayInKind() public {
        uint256 positionId = _openMakerLong();
        Leg memory leg = vault.legOf(positionId, 0);
        setPrice(PRICE_TICK - 1_500, 1);
        vm.prank(trader);
        vault.addMakerCollateral0(positionId, leg.maximum0);
        uint256[] memory repay0 = single(leg.maximum0);
        uint256[] memory repay1 = new uint256[](1);
        vm.prank(trader);
        vault.closeMaker(MakerCloseRequest({positionId: positionId, fractionWad: WAD, repay0: repay0, repay1: repay1}));
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed in kind");
        assertLedger();
    }

    /// @dev Income still vesting when the last lender leaves goes to the treasury, as the maker book's does (D22),
    /// rather than wait for the next deposit and vest partly to the virtual shares.
    function test_withdraw_lastLenderOutSendsIncomeStillVestingToTheTreasury() public {
        uint256 shares = deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 300e6);
        vm.warp(block.timestamp + 30 days);
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        closeFull(positionId, repay0, repay1);
        uint256 vesting = vault.streamOf(vaultId).remaining1;
        assertGt(vesting, 0, "premium still vesting");
        uint256 treasuryBefore = vault.ledgerOf(vaultId).treasury1;
        vm.prank(lender);
        vault.withdraw(vaultId, shares, 0, 0, lender);
        assertEq(vault.totalSharesOf(vaultId), 0, "the last lender left");
        assertEq(vault.streamOf(vaultId).remaining1, 0, "nothing left vesting");
        assertEq(vault.ledgerOf(vaultId).treasury1 - treasuryBefore, vesting, "to the treasury");
        assertLedger();
    }

    // ---------------------------------------------------------------- helpers

    function _openMakerLong() internal returns (uint256) {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        return openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
    }

    function _openEscrowedLong(uint128 escrow) internal returns (uint256) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, 10_000e6), 400e6);
        request.escrow = escrow;
        return open(request);
    }

    /// @dev A long with one unit of escrow, delinquent within days.
    function _openDelinquentLong() internal returns (uint256) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, 10_000e6), 300e6);
        request.escrow = 1;
        return open(request);
    }

    function _closePassive(uint256 positionId) internal returns (uint256, uint256) {
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        return closeFull(positionId, repay0, repay1);
    }

    function _closeMaker(uint256 positionId) internal returns (uint256, uint256) {
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, WAD);
        return closeMakerFull(positionId, repay0, repay1);
    }

    /// @dev A second vault, funded and borrowed from as the first will be.
    function _twinVaultWithAPosition() internal returns (uint256 twinVaultId, uint256 twinPositionId) {
        vm.prank(owner);
        twinVaultId = vault.createVault(defaultParameters(), defaultCurves());
        vm.prank(lender);
        vault.deposit(twinVaultId, 0, 100_000e6, 0, lender);
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, 10_000e6), 300e6);
        request.vaultId = twinVaultId;
        vm.prank(trader);
        twinPositionId = vault.open(request);
    }

    function _expectUnknownPassive(uint256 positionId) internal {
        vm.startPrank(trader);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.settle(positionId);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.flag(positionId);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.forceClose(positionId);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.addEscrow(positionId, 1);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.addCollateral(positionId, 1);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: 0, repay1: 0}));
        vm.stopPrank();
    }

    function _expectUnknownMaker(uint256 positionId) internal {
        vm.startPrank(trader);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.settleMaker(positionId);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.flagMaker(positionId);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.forceCloseMaker(positionId);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.addMakerEscrow(positionId, 1);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.addMakerCollateral(positionId, 1);
        vm.expectRevert(IMetricLendingVault.UnknownPosition.selector);
        vault.closeMaker(
            MakerCloseRequest({
                positionId: positionId, fractionWad: WAD, repay0: new uint256[](0), repay1: new uint256[](0)
            })
        );
        vm.stopPrank();
    }

    function _expectUnknownVault(uint256 unknownVaultId) internal {
        vm.startPrank(lender);
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.deposit(unknownVaultId, 1e18, 1_000e6, 0, lender);
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.withdraw(unknownVaultId, 1, 0, 0, lender);
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.payProtocol(unknownVaultId);
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.depositOrder(unknownVaultId, LEVEL_10X, true, 1_000e6, 0, lender);
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.withdrawOrder(unknownVaultId, 1, 1, 0, 0, lender);
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.claimOrderIncome(unknownVaultId, 1, lender);
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.fillBucket(unknownVaultId, 1);
        OpenRequest memory request = openRequest(true, PRICE_TICK - 200, PRICE_TICK - 100, 1e15, 300e6);
        request.vaultId = unknownVaultId;
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.open(request);
        MakerOpenRequest memory makerOpen = makerRequest(true, single(1), single128(1), 10e6);
        makerOpen.vaultId = unknownVaultId;
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.openMaker(makerOpen);
        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.appendCurves(unknownVaultId, defaultCurves());
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.appendBookCurve(unknownVaultId, defaultBookCurve());
        vm.expectRevert(IMetricLendingVault.UnknownVault.selector);
        vault.createBook(unknownVaultId, defaultBookSettings(), defaultBookCurve(), defaultFloorRows());
        vm.stopPrank();
    }

    /// @dev Token1 the lenders' stream, the treasury and the fee vault have taken in so far.
    function _income1() internal view returns (uint256) {
        return uint256(vault.streamOf(vaultId).remaining1) + vault.ledgerOf(vaultId).treasury1
            + vault.ledgerOf(vaultId).feeVault1;
    }

    /// @dev The profit share a close's `Closed` event reports.
    function _closedShare(Vm.Log[] memory logs) internal pure returns (uint256 share) {
        // logs.length is bounded by the close's events
        for (uint256 index = 0; index < logs.length; ++index) {
            if (logs[index].topics[0] != IMetricLendingVault.Closed.selector) continue;
            (,,, share) = abi.decode(logs[index].data, (uint256, uint256, uint256, uint256));
        }
    }
}
