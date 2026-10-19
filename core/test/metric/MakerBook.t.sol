// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Accrual, Ledger} from "../../src/metric/vault/VaultTypes.sol";
import {
    BookSettings,
    Bucket,
    FloorRow,
    Leg,
    MakerCloseRequest,
    MakerOpenRequest,
    MakerPosition,
    MakerShare
} from "../../src/metric/vault/MakerTypes.sol";
import {IMakerBook} from "../../src/metric/vault/interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {MakerMath} from "../../src/metric/vault/libraries/MakerMath.sol";
import {Curve, VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {MakerFixture} from "./utils/MakerFixture.sol";

contract MakerBookTest is MakerFixture {
    uint256 internal constant WAD = 1e18;
    /// @dev About 10% below the price: ticks [-201,400, -201,300); about 10x for a long.
    int24 internal constant LEVEL_10X = -2_014;
    /// @dev About 50% below: ticks [-207,300, -207,200); about 2x.
    int24 internal constant LEVEL_2X = -2_073;
    /// @dev Just below the price level: ticks [-200,500, -200,400); about 70x.
    int24 internal constant LEVEL_NEAR = -2_005;
    /// @dev About 10% above: ticks [-199,400, -199,300); about 10x for a short.
    int24 internal constant LEVEL_SHORT = -1_994;

    // ---------------------------------------------------------------- creation

    function test_createBook_onlyOwnerAndOnce() public {
        vm.prank(lender);
        vm.expectRevert();
        vault.createBook(vaultId, defaultBookSettings(), defaultBookCurve(), defaultFloorRows());
        vm.prank(owner);
        vm.expectRevert(IMakerBook.BookExists.selector);
        vault.createBook(vaultId, defaultBookSettings(), defaultBookCurve(), defaultFloorRows());
    }

    function test_createBook_rejectsBadSettingsAndRows() public {
        uint256 secondVault = _secondVault();
        BookSettings memory settings = defaultBookSettings();
        settings.levelTicks = 0;
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.createBook(secondVault, settings, defaultBookCurve(), defaultFloorRows());
        FloorRow[] memory rows = defaultFloorRows();
        rows[rows.length - 1].minimumDistanceBps = 1;
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.createBook(secondVault, defaultBookSettings(), defaultBookCurve(), rows);
        rows = defaultFloorRows();
        rows[1].minimumDistanceBps = 5_000;
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.createBook(secondVault, defaultBookSettings(), defaultBookCurve(), rows);
    }

    // ---------------------------------------------------------------- deposits

    function test_deposit_buyBelowPriceMintsShares() public {
        (uint256 bucketId, uint256 shares) = depositBuy(makerA, LEVEL_10X, 100_000e6);
        assertEq(bucketId, vault.currentBucketOf(vaultId, LEVEL_10X, true), "current generation");
        assertEq(shares, 100_000e6 * 1e6, "first deposit: value times the virtual offset");
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        assertEq(bucket.balance1, 100_000e6);
        assertEq(bucket.totalShares, shares);
        assertLedger();
    }

    function test_deposit_secondMakerIsProportional() public {
        (, uint256 sharesA) = depositBuy(makerA, LEVEL_10X, 100_000e6);
        (, uint256 sharesB) = depositBuy(makerB, LEVEL_10X, 50_000e6);
        assertApproxEqRel(sharesB * 2, sharesA, 1e12);
        assertLedger();
    }

    function test_deposit_mustSitWhollyOnItsSideOfThePrice() public {
        vm.prank(makerA);
        vm.expectRevert(IMakerBook.WrongSideOfPrice.selector);
        vault.depositOrder(vaultId, PRICE_LEVEL, true, 1_000e6, 0, makerA);
        vm.prank(makerA);
        vm.expectRevert(IMakerBook.WrongSideOfPrice.selector);
        vault.depositOrder(vaultId, LEVEL_SHORT, true, 1_000e6, 0, makerA);
        vm.prank(makerA);
        vm.expectRevert(IMakerBook.WrongSideOfPrice.selector);
        vault.depositOrder(vaultId, LEVEL_10X, false, 1e18, 0, makerA);
    }

    function test_deposit_belowMinimumNotionalReverts() public {
        vm.prank(makerA);
        vm.expectRevert(IMakerBook.BelowMinimumNotional.selector);
        vault.depositOrder(vaultId, LEVEL_10X, true, 99e6, 0, makerA);
    }

    // ---------------------------------------------------------------- withdrawals

    function test_withdraw_unlentReturnsEverything() public {
        (uint256 bucketId, uint256 shares) = depositBuy(makerA, LEVEL_10X, 100_000e6);
        uint256 before = quote.balanceOf(makerA);
        vm.prank(makerA);
        (, uint256 amount1, uint256 burned) = vault.withdrawOrder(vaultId, bucketId, shares, 0, 0, makerA);
        assertApproxEqAbs(amount1, 100_000e6, 1);
        assertEq(burned, shares);
        assertEq(quote.balanceOf(makerA) - before, amount1);
        assertLedger();
    }

    /// @dev Sol's finding: when lent capital has lost value, an early leaver must not take the idle tokens at full
    /// value. Two equal makers end with equal value.
    function test_withdraw_isFairWhenLentValueFell() public {
        (uint256 bucketId, uint256 sharesA) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        depositBuy(makerB, LEVEL_10X, 50_000e6);
        // A fifth lent, so the ceiling does not limit the withdrawal.
        uint128 liquidity = liquidityOn(LEVEL_10X, 20_000e6);
        openMaker(makerRequest(true, single(bucketId), single128(liquidity), 10e6));
        // The price falls through the level: the lent liquidity now holds token0 worth less than it released.
        setPrice(-202_500, 1);
        vm.prank(makerA);
        (uint256 amount0, uint256 amount1,) = vault.withdrawOrder(vaultId, bucketId, sharesA, 0, 0, makerA);
        uint160 sqrtBidX96 = source.sqrtBidX96();
        uint256 withdrawnValue = VaultMath.valueInToken1(amount0, amount1, sqrtBidX96, false);
        uint256 remainingValue = _bucketValue(bucketId, sqrtBidX96);
        assertLt(withdrawnValue, 49_000e6, "less than the idle half: the lent half lost value");
        assertApproxEqRel(withdrawnValue, remainingValue, 1e15, "both makers end with equal value");
        assertLedger();
    }

    /// @dev Sol's finding: deposit, borrow more, then withdraw must not leave a bucket above the ceiling.
    function test_withdraw_cannotPushAnActiveBucketPastTheCeiling() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 100_000e6);
        MakerOpenRequest memory first =
            makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 89_000e6)), 10e6);
        // At 89% lent the curve is past its kink: about 545% a year on top of the floor.
        first.escrow = 20_000e6;
        openMaker(first);
        (, uint256 sharesB) = depositBuy(makerB, LEVEL_10X, 100_000e6);
        MakerOpenRequest memory second =
            makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 50_000e6)), 10e6);
        second.escrow = 20_000e6;
        openMaker(second);
        vm.prank(makerB);
        vault.withdrawOrder(vaultId, bucketId, sharesB, 0, 0, makerB);
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        uint256 capacity = liquidityOn(LEVEL_10X, bucket.balance1);
        assertLe(uint256(bucket.lent) * 10_000, (uint256(bucket.lent) + capacity) * 9_000, "within ceiling");
        assertGt(vault.makerShareOf(vaultId, bucketId, makerB).shares, 0, "part of the deposit stays");
        assertLedger();
    }

    // ---------------------------------------------------------------- opening

    function test_openMaker_recordsTheFloorByDistance() public {
        (uint256 near,) = depositBuy(makerA, LEVEL_NEAR, 50_000e6);
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        (uint256 two,) = depositBuy(makerA, LEVEL_2X, 50_000e6);
        uint256 nearPosition =
            openMaker(makerRequest(true, single(near), single128(liquidityOn(LEVEL_NEAR, 5_000e6)), 10e6));
        uint256 tenPosition =
            openMaker(makerRequest(true, single(ten), single128(liquidityOn(LEVEL_10X, 5_000e6)), 10e6));
        uint256 twoPosition =
            openMaker(makerRequest(true, single(two), single128(liquidityOn(LEVEL_2X, 5_000e6)), 10e6));
        assertEq(vault.legOf(nearPosition, 0).floorRateBps, 27_000, "under 2% away");
        assertEq(vault.legOf(tenPosition, 0).floorRateBps, 11_500, "8-10% away");
        assertEq(vault.legOf(twoPosition, 0).floorRateBps, 1_000, "40% and more away");
        assertLedger();
    }

    function test_openMaker_ladderUnderOneChord() public {
        uint256[] memory bucketIds = new uint256[](3);
        uint128[] memory liquidities = new uint128[](3);
        int24[3] memory levels = [LEVEL_2X, LEVEL_10X, LEVEL_NEAR];
        // three levels
        for (uint256 index = 0; index < 3; ++index) {
            (bucketIds[index],) = depositBuy(makerA, levels[index], 20_000e6);
            liquidities[index] = liquidityOn(levels[index], 5_000e6);
        }
        uint256 positionId =
            openMaker(makerRequest(true, _ascending(bucketIds), _alignedLiquidity(bucketIds, liquidities), 20e6));
        MakerPosition memory position = vault.makerPositionOf(positionId);
        assertEq(position.legCount, 3);
        assertApproxEqRel(position.maximum1, 15_000e6, 1e12, "three legs of 5,000");
        assertTrue(
            MakerMath.aggregateChordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1, 3)
        );
        assertLedger();
    }

    function test_openMaker_rejectsBadLegs() public {
        (uint256 first,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        (uint256 second,) = depositBuy(makerA, LEVEL_2X, 50_000e6);
        uint128 liquidity = liquidityOn(LEVEL_10X, 1_000e6);
        uint256[] memory ids = new uint256[](2);
        uint128[] memory liquidities = new uint128[](2);
        (ids[0], ids[1]) = first > second ? (first, second) : (second, first);
        liquidities[0] = liquidity;
        liquidities[1] = liquidity;
        vm.prank(trader);
        vm.expectRevert(IMakerBook.InvalidLegs.selector);
        vault.openMaker(makerRequest(true, ids, liquidities, 10e6));
        ids[1] = ids[0];
        vm.prank(trader);
        vm.expectRevert(IMakerBook.InvalidLegs.selector);
        vault.openMaker(makerRequest(true, ids, liquidities, 10e6));
        vm.prank(trader);
        vm.expectRevert(IMakerBook.InvalidLegs.selector);
        vault.openMaker(makerRequest(false, single(first), single128(liquidity), 10e6));
    }

    function test_openMaker_withoutCollateralIsInsolvent() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.Insolvent.selector);
        vault.openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 5_000e6)), 0));
    }

    function test_openMaker_rateLimitAndEscrowMinimum() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        MakerOpenRequest memory request =
            makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 5_000e6)), 10e6);
        request.maximumRateBps = 10_000;
        vm.prank(trader);
        vm.expectRevert(IMakerBook.RateAboveMaximum.selector);
        vault.openMaker(request);
        request.maximumRateBps = type(uint256).max;
        request.escrow = 1e6;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.EscrowTooSmall.selector);
        vault.openMaker(request);
    }

    /// @dev Sol's finding: rates truncated to whole basis points let a fraction of a basis point through. A curve at
    /// 0.9 bp a year with no floor still needs escrow and still exceeds a zero maximum.
    function test_openMaker_ratesKeepFullPrecision() public {
        FloorRow[] memory rows = new FloorRow[](1);
        rows[0] = FloorRow({minimumDistanceBps: 0, rateBps: 0});
        vm.startPrank(owner);
        vault.appendFloorTable(vaultId, rows);
        // A fifth lent on a 0.8 kink is a quarter of slope1: 0.9 bp a year.
        vault.appendBookCurve(vaultId, Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 3.6e14, slope2Wad: 12e18}));
        vm.stopPrank();
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 1_000e6);
        MakerOpenRequest memory request =
            makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 200e6)), 10e6);
        request.escrow = 0;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.EscrowTooSmall.selector);
        vault.openMaker(request);
        // Three days at 0.9 bp a year on about 200 is about 148 raw units.
        request.escrow = 148;
        request.maximumRateBps = 0;
        vm.prank(trader);
        vm.expectRevert(IMakerBook.RateAboveMaximum.selector);
        vault.openMaker(request);
        request.maximumRateBps = 1;
        openMaker(request);
        assertLedger();
    }

    function test_openMaker_respectsTheBucketCeiling() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 10_000e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.UtilizationCeiling.selector);
        vault.openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 9_500e6)), 10e6));
    }

    // ---------------------------------------------------------------- premium

    /// @dev The open prepays two days of the leg's floor; the floor then accrues from the third day and the curve from
    /// the open. Of everything paid, the protocol keeps 10% and the bucket's makers the rest.
    function test_premium_prepaysTheMinimumThenVestsToTheBucketsMakers() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        uint256 escrowAfterOpen = vault.makerPositionOf(positionId).escrow;
        uint256 prepaid = 2_000e6 - escrowAfterOpen;
        // Two days of the 115% floor on about 10,000.
        assertApproxEqRel(prepaid, 63.01e6, 0.001e18, "the minimum charge");
        vm.warp(block.timestamp + 1 days);
        assertTrue(vault.settleMaker(positionId));
        uint256 firstDay = escrowAfterOpen - vault.makerPositionOf(positionId).escrow;
        // Within the prepaid days only the curve accrues: a fifth lent is 1.25% a year, about 0.34 a day.
        assertApproxEqRel(firstDay, 0.342e6, 0.01e18, "curve only");
        vm.warp(block.timestamp + 29 days);
        assertTrue(vault.settleMaker(positionId));
        uint256 paid = escrowAfterOpen - vault.makerPositionOf(positionId).escrow;
        // The curve for 30 days plus the floor for the 28 after the prepaid two: about 10.27 + 882.19.
        assertApproxEqRel(paid, 892.47e6, 0.001e18, "floor after the prepaid days, plus the curve");
        uint256 treasury = vault.ledgerOf(vaultId).treasury1;
        assertApproxEqAbs(treasury, (prepaid + paid) / 10, 3, "protocol keeps 10%");
        vm.warp(block.timestamp + 2 days);
        vm.prank(makerA);
        (, uint256 income1) = vault.claimOrderIncome(vaultId, bucketId, makerA);
        assertApproxEqAbs(income1, prepaid + paid - treasury, 3, "makers get the rest once vested");
        assertLedger();
    }

    /// @dev Sol's findings: income still vesting when the last maker leaves must not be stranded, nor go to whoever
    /// leaves last. The maker keeps what has vested; the rest goes to the treasury.
    function test_withdraw_lastMakerOutForfeitsIncomeStillVestingToTheTreasury() public {
        (uint256 bucketId, uint256 shares) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        vm.warp(block.timestamp + 10 days);
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, WAD);
        closeMakerFull(positionId, repay0, repay1);
        uint256 vesting = vault.bucketOf(vaultId, bucketId).stream1Remaining;
        assertGt(vesting, 0, "income still vesting");
        uint256 treasuryBefore = vault.ledgerOf(vaultId).treasury1;
        vm.prank(makerA);
        vault.withdrawOrder(vaultId, bucketId, shares, 0, 0, makerA);
        assertEq(vault.bucketOf(vaultId, bucketId).totalShares, 0, "every share burned");
        assertEq(vault.bucketOf(vaultId, bucketId).stream1Remaining, 0, "nothing left vesting");
        assertEq(vault.ledgerOf(vaultId).treasury1 - treasuryBefore, vesting, "the unvested part to the treasury");
        vm.prank(makerA);
        (, uint256 income1) = vault.claimOrderIncome(vaultId, bucketId, makerA);
        assertGt(income1, 0, "the maker keeps what vested");
        assertLedger();
    }

    /// @dev Sol's finding: where lent liquidity's value at the bid rounds to nothing, a sole maker could burn every
    /// share while loans were out, leaving their repayment and premium with no owner. The last share stays. Sol's
    /// numbers: a buy level at 4,400 (ticks 440,000–440,100), 6 units of liquidity lent, then the price at tick 0.
    /// Sol's case was a retired bucket, where no ceiling holds capital back; a 100% ceiling stands in for it here.
    function test_withdraw_keepsAnOwnerWhileLoansAreOut() public {
        uint256 otherVault = _secondVault();
        BookSettings memory settings = defaultBookSettings();
        settings.utilizationCeilingBps = 10_000;
        vm.prank(owner);
        vault.createBook(otherVault, settings, defaultBookCurve(), defaultFloorRows());
        setPrice(443_000, 1);
        vm.prank(makerA);
        (uint256 bucketId, uint256 shares) = vault.depositOrder(otherVault, 4_400, true, 323_078_339, 0, makerA);
        MakerOpenRequest memory request = makerRequest(true, single(bucketId), single128(6), 10e6);
        request.vaultId = otherVault;
        uint256 positionId = openMaker(request);
        setPrice(0, 1);
        vm.prank(makerA);
        vault.withdrawOrder(otherVault, bucketId, shares, 0, 0, makerA);
        assertEq(vault.makerShareOf(otherVault, bucketId, makerA).shares, 1, "the last share stays");
        uint256 vestingBefore = vault.bucketOf(otherVault, bucketId).stream1Remaining;
        vm.warp(block.timestamp + 10 days);
        assertTrue(vault.settleMaker(positionId));
        assertGt(vault.bucketOf(otherVault, bucketId).stream1Remaining, vestingBefore, "premium still has an owner");
        assertLedgerParts(otherVault);
    }

    /// @dev Sol's finding: settlements anyone may call rounded each one up, so settling every second drained escrow
    /// far faster than the rate. At 0.9 bp a year on about 200, 148 one-second settlements owe under a unit.
    function test_settleMaker_oftenChargesNoMoreThanOnce() public {
        FloorRow[] memory rows = new FloorRow[](1);
        rows[0] = FloorRow({minimumDistanceBps: 0, rateBps: 0});
        vm.startPrank(owner);
        vault.appendFloorTable(vaultId, rows);
        vault.appendBookCurve(vaultId, Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 3.6e14, slope2Wad: 12e18}));
        vm.stopPrank();
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 1_000e6);
        MakerOpenRequest memory request =
            makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 200e6)), 10e6);
        request.escrow = 1_000;
        uint256 positionId = openMaker(request);
        // 148 one-second settlements
        for (uint256 second = 0; second < 148; ++second) {
            vm.warp(block.timestamp + 1);
            vault.settleMaker(positionId);
        }
        assertLe(1_000 - vault.makerPositionOf(positionId).escrow, 1, "under a unit, as one settlement would charge");
        assertLedger();
    }

    // ---------------------------------------------------------------- closing

    function test_closeMaker_fullReturnsEveryLegToItsBucket() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, WAD);
        closeMakerFull(positionId, repay0, repay1);
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        assertEq(bucket.lent, 0, "nothing lent");
        assertGe(bucket.balance1, 50_000e6, "repaid in full");
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "deleted");
        assertLedger();
    }

    function test_closeMaker_partialKeepsTheRestSolvent() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, 0.5e18);
        vm.prank(trader);
        vault.closeMaker(
            MakerCloseRequest({positionId: positionId, fractionWad: 0.5e18, repay0: repay0, repay1: repay1})
        );
        Leg memory leg = vault.legOf(positionId, 0);
        assertApproxEqRel(leg.maximum1, 5_000e6, 1e12);
        MakerPosition memory position = vault.makerPositionOf(positionId);
        assertTrue(
            MakerMath.aggregateChordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1, 1)
        );
        assertLedger();
    }

    function test_closeMaker_repaymentShortReverts() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, WAD);
        repay1[0] = repay1[0] * 99 / 100;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.RepaymentShort.selector);
        vault.closeMaker(MakerCloseRequest({positionId: positionId, fractionWad: WAD, repay0: repay0, repay1: repay1}));
    }

    /// @dev A winning short repaid in token1 keeps its token0; the makers' half of the 2% profit share vests to the
    /// leg's bucket.
    function test_closeMaker_profitShareGoesToTheBucket() public {
        (uint256 bucketId,) = depositSell(makerA, LEVEL_SHORT, 20e18);
        uint128 liquidity = liquidityOn(LEVEL_SHORT, 10_000e6);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(LEVEL_SHORT);
        (, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        uint256 positionId =
            openMaker(makerRequest(false, single(bucketId), single128(liquidity), uint128(maximum1 + 10e6)));
        setPrice(-198_000, 1);
        (, uint256 income1Before,,) = vault.bookTotalsOf(vaultId);
        uint256[] memory repay0 = single(0);
        uint256[] memory repay1 = single(maximum1);
        (uint256 paid0,) = closeMakerFull(positionId, repay0, repay1);
        assertGt(paid0, 0, "the trader keeps token0");
        (,, uint256 income0After, uint256 income1After) = vault.bookTotalsOf(vaultId);
        assertGt(income0After + income1After, income1Before, "makers' half of the share");
        assertGt(vault.ledgerOf(vaultId).treasury1 + vault.ledgerOf(vaultId).treasury0, 0, "treasury's part");
        assertLedger();
    }

    // ---------------------------------------------------------------- delinquency

    function test_forceCloseMaker_scalesEveryLegWithoutAPool() public {
        uint256[] memory bucketIds = new uint256[](2);
        uint128[] memory liquidities = new uint128[](2);
        (bucketIds[0],) = depositBuy(makerA, LEVEL_2X, 30_000e6);
        (bucketIds[1],) = depositBuy(makerA, LEVEL_10X, 30_000e6);
        liquidities[0] = liquidityOn(LEVEL_2X, 5_000e6);
        liquidities[1] = liquidityOn(LEVEL_10X, 5_000e6);
        MakerOpenRequest memory request =
            makerRequest(true, _ascending(bucketIds), _alignedLiquidity(bucketIds, liquidities), 50e6);
        // Two days' floor prepaid and about a day more: the open's minimum, soon outrun.
        request.escrow = 60e6;
        uint256 positionId = openMaker(request);
        vm.warp(block.timestamp + 30 days);
        vault.flagMaker(positionId);
        vm.expectRevert(IMetricLendingVault.GracePeriodRunning.selector);
        vault.forceCloseMaker(positionId);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(closer);
        vault.forceCloseMaker(positionId);
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed");
        assertEq(vault.bucketOf(vaultId, bucketIds[0]).lent, 0);
        assertEq(vault.bucketOf(vaultId, bucketIds[1]).lent, 0);
        assertLedger();
    }

    function test_flagMaker_rejectsASolventPosition() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        vm.expectRevert(IMetricLendingVault.NotDelinquent.selector);
        vault.flagMaker(positionId);
    }

    // ---------------------------------------------------------------- isolation

    function test_makerActivityLeavesVaultLendersUntouched() public {
        deposit(lender, 10e18, 20_000e6);
        Accrual memory accrualBefore = vault.accrualOf(vaultId);
        Ledger memory ledgerBefore = vault.ledgerOf(vaultId);
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        vm.warp(block.timestamp + 10 days);
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, WAD);
        closeMakerFull(positionId, repay0, repay1);
        Accrual memory accrualAfter = vault.accrualOf(vaultId);
        Ledger memory ledgerAfter = vault.ledgerOf(vaultId);
        assertEq(accrualAfter.outstanding0, accrualBefore.outstanding0);
        assertEq(accrualAfter.outstanding1, accrualBefore.outstanding1);
        assertEq(ledgerAfter.buffer0, ledgerBefore.buffer0);
        assertEq(ledgerAfter.buffer1, ledgerBefore.buffer1);
        assertLedger();
    }

    // ---------------------------------------------------------------- audit

    /// @dev Audit finding C1: a leg of zero liquidity passed the open, since its extremes round up to one unit, and
    /// then no close could ever repay it. An open must refuse it.
    function test_openMaker_refusesALegWithNoLiquidity() public {
        uint256 otherVault = _bookWithMinimumNotional(1);
        vm.prank(makerA);
        (uint256 bucketId,) = vault.depositOrder(otherVault, LEVEL_10X, true, 100, 0, makerA);
        MakerOpenRequest memory request = makerRequest(true, single(bucketId), single128(0), 2);
        request.vaultId = otherVault;
        request.escrow = 10;
        vm.prank(trader);
        vm.expectRevert(IMakerBook.InvalidLegs.selector);
        vault.openMaker(request);
    }

    /// @dev Audit finding C3: where a bucket's value rounds to one raw unit, the virtual value in a withdrawal claim
    /// let one maker take another's tokens. Sol's numbers: a sell level at 1, makers of 90 and 10 token0, then the
    /// price at 1/64.
    function test_withdraw_cannotTakeAnotherMakersTokensAtTinyValues() public {
        uint256 otherVault = _bookWithMinimumNotional(1);
        source.set(uint160(1 << 96), uint160(1 << 96));
        vm.prank(makerA);
        (uint256 bucketId, uint256 sharesA) = vault.depositOrder(otherVault, 1, false, 90, 0, makerA);
        vm.prank(makerB);
        vault.depositOrder(otherVault, 1, false, 10, 0, makerB);
        source.set(uint160(1 << 93), uint160(1 << 93));
        vm.prank(makerA);
        (uint256 amount0,,) = vault.withdrawOrder(otherVault, bucketId, sharesA, 0, 0, makerA);
        assertLe(amount0, 90, "no more than their own tokens");
        assertLedgerParts(otherVault);
    }

    /// @dev Audit finding C2: with zero rates a borrower could hold a bucket at its ceiling for free, keeping makers'
    /// last idle capital. A curve must charge at least 100% a year at the ceiling.
    function test_bookCurve_mustChargeAtTheCeiling() public {
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.appendBookCurve(vaultId, Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0, slope2Wad: 0}));
        vm.prank(owner);
        vault.appendBookCurve(vaultId, Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0, slope2Wad: 2e18}));
    }

    /// @dev Owner's decision, 2026-10-19 (replacing audit finding A3), in the maker book: a maker who deposits while
    /// income is still vesting in the bucket and withdraws in the same block gets back what they put in, less
    /// rounding, and claims no income.
    function test_deposit_sameBlockRoundTripReturnsTheDeposit() public {
        setPrice(PRICE_TICK, 0);
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        vm.warp(block.timestamp + 30 days);
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, WAD);
        closeMakerFull(positionId, repay0, repay1);
        assertGt(vault.bucketOf(vaultId, bucketId).stream1Remaining, 0, "income still vesting");
        (, uint256 shares) = depositBuy(makerB, LEVEL_10X, 50_000e6);
        vm.startPrank(makerB);
        (uint256 amount0, uint256 amount1,) = vault.withdrawOrder(vaultId, bucketId, shares, 0, 0, makerB);
        // No income vested in the same block, so there is nothing to claim.
        vm.expectRevert(IMetricLendingVault.ZeroAmount.selector);
        vault.claimOrderIncome(vaultId, bucketId, makerB);
        vm.stopPrank();
        uint256 value = VaultMath.valueInToken1(amount0, amount1, source.sqrtAskX96(), false);
        assertLe(value, 50_000e6, "no more than the deposit");
        assertApproxEqAbs(value, 50_000e6, 3, "the deposit back, less rounding");
        assertLedger();
    }

    /// @dev Audit finding A-2: a maker leaving one share in an unlent bucket while income vests must not dilute the
    /// next depositor. With the vesting no longer grossed up by `(S + virtual) / S`, the next maker's deposit buys
    /// shares at the bucket's value, so it gets its deposit back whether it leaves first or last.
    function test_deposit_afterOneShareIsLeft_isNotDiluted() public {
        (uint256 bucketId, uint256 attackerShares) = depositBuy(makerA, LEVEL_2X, 1_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_2X, 500e6)), 10e6));
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, WAD);
        closeMakerFull(positionId, repay0, repay1);
        assertGt(vault.bucketOf(vaultId, bucketId).stream1Remaining, 0, "income still vesting");
        vm.prank(makerA);
        vault.withdrawOrder(vaultId, bucketId, attackerShares - 1, 0, 0, makerA);
        assertEq(vault.bucketOf(vaultId, bucketId).totalShares, 1, "one share left");
        (uint256 sameBucket, uint256 victimShares) = depositBuy(makerB, LEVEL_2X, 10_000e6);
        assertEq(sameBucket, bucketId, "the same bucket");
        vm.warp(block.timestamp + 1 hours);
        uint256 before = quote.balanceOf(makerB);
        vm.prank(makerB);
        vault.withdrawOrder(vaultId, bucketId, victimShares, 0, 0, makerB);
        assertGe(quote.balanceOf(makerB) - before + 3, 10_000e6, "the deposit back, less rounding");
        assertLedger();
    }

    /// @dev A second vault with a book whose minimum notional is `minimumNotional`, for raw-unit cases.
    function _bookWithMinimumNotional(uint96 minimumNotional) internal returns (uint256 otherVault) {
        otherVault = _secondVault();
        BookSettings memory settings = defaultBookSettings();
        settings.minimumNotional = minimumNotional;
        vm.prank(owner);
        vault.createBook(otherVault, settings, defaultBookCurve(), defaultFloorRows());
    }

    // ---------------------------------------------------------------- helpers

    function _secondVault() internal returns (uint256 id) {
        vm.prank(owner);
        id = vault.createVault(defaultParameters(), defaultCurves());
    }

    function _bucketValue(uint256 bucketId, uint160 sqrtPriceX96) internal view returns (uint256) {
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        (int24 level,,) = MakerMath.decode(bucketId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(level);
        (uint256 lent0, uint256 lent1) = VaultMath.holdingsAt(bucket.lent, sqrtLowerX96, sqrtUpperX96, sqrtPriceX96);
        return VaultMath.valueInToken1(bucket.balance0 + lent0, bucket.balance1 + lent1, sqrtPriceX96, false);
    }

    function _ascending(uint256[] memory ids) internal pure returns (uint256[] memory sorted) {
        sorted = new uint256[](ids.length);
        // ids.length <= MAX_LEGS
        for (uint256 index = 0; index < ids.length; ++index) {
            sorted[index] = ids[index];
        }
        // insertion sort over at most MAX_LEGS ids
        for (uint256 index = 1; index < sorted.length; ++index) {
            uint256 current = sorted[index];
            uint256 cursor = index;
            while (cursor > 0 && sorted[cursor - 1] > current) {
                sorted[cursor] = sorted[cursor - 1];
                cursor -= 1;
            }
            sorted[cursor] = current;
        }
    }

    /// @dev Reorders `liquidities` to follow the ascending order of `ids`.
    function _alignedLiquidity(uint256[] memory ids, uint128[] memory liquidities)
        internal
        pure
        returns (uint128[] memory aligned)
    {
        uint256[] memory sorted = _ascending(ids);
        aligned = new uint128[](ids.length);
        // sorted.length <= MAX_LEGS
        for (uint256 index = 0; index < sorted.length; ++index) {
            // ids.length <= MAX_LEGS
            for (uint256 source_ = 0; source_ < ids.length; ++source_) {
                if (ids[source_] == sorted[index]) aligned[index] = liquidities[source_];
            }
        }
    }
}
