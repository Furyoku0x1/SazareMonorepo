// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {
    Bucket,
    FloorRow,
    Leg,
    LegRequest,
    MakerCloseRequest,
    MakerIncreaseRequest,
    MakerOpenRequest,
    MakerPosition
} from "../../src/metric/vault/MakerTypes.sol";
import {VaultParameters} from "../../src/metric/vault/VaultTypes.sol";
import {IMakerBook} from "../../src/metric/vault/interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {MakerMath} from "../../src/metric/vault/libraries/MakerMath.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {MakerFixture} from "./utils/MakerFixture.sol";

contract MakerIncreaseTest is MakerFixture {
    uint256 internal constant WAD = 1e18;
    int24 internal constant LEVEL_10X = -2_014;
    int24 internal constant LEVEL_2X = -2_073;
    int24 internal constant LEVEL_NEAR = -2_005;
    int24 internal constant LEVEL_SHORT = -1_994;

    function _increaseRequest(uint256 positionId, uint256 bucketId, uint128 liquidity, uint128 collateral)
        internal
        pure
        returns (MakerIncreaseRequest memory request)
    {
        request.positionId = positionId;
        request.legs = new LegRequest[](1);
        request.legs[0] = LegRequest({bucketId: bucketId, liquidity: liquidity});
        request.collateral = collateral;
        request.escrow = 2_000e6;
        request.maximumRateBps = type(uint256).max;
    }

    function _increase(MakerIncreaseRequest memory request) internal {
        vm.prank(trader);
        vault.increaseMaker(request);
    }

    function _assertLegsEqual(Leg memory left, Leg memory right) internal pure {
        assertEq(left.bucketId, right.bucketId, "bucket");
        assertEq(left.liquidity, right.liquidity, "liquidity");
        assertEq(left.maximum0, right.maximum0, "maximum0");
        assertEq(left.maximum1, right.maximum1, "maximum1");
        assertEq(left.rateIndexRay, right.rateIndexRay, "rate index");
        assertEq(left.floorRateBps, right.floorRateBps, "floor");
        assertEq(left.settledAt, right.settledAt, "settled at");
        assertEq(left.owedFractionWad, right.owedFractionWad, "carried fraction");
    }

    function _assertBucketsEqual(Bucket memory left, Bucket memory right) internal pure {
        assertEq(left.balance0, right.balance0, "bucket balance0");
        assertEq(left.balance1, right.balance1, "bucket balance1");
        assertEq(left.lent, right.lent, "bucket lent");
        assertEq(left.rateIndexRay, right.rateIndexRay, "bucket index");
        assertEq(left.stream1Remaining, right.stream1Remaining, "bucket stream");
    }

    /// @dev What the increase left, kept in memory: reverting to the snapshot also reverts this contract's storage.
    struct Merged {
        MakerPosition position;
        Leg[3] legs;
        Bucket bucket;
        uint256 treasury1;
        uint256 escrowLater;
    }

    /// @dev The owner's target: increasing equals settling at the old size now, then opening the added legs now.
    function test_increaseMaker_equalsSettlingThenOpeningTheAddedLegs() public {
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        (uint256 two,) = depositBuy(makerA, LEVEL_2X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(ten), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        vm.warp(block.timestamp + 1 days);
        uint256 snapshot = vm.snapshotState();
        MakerIncreaseRequest memory increase = _twoLegIncrease(positionId, ten, two);
        Merged memory merged = _increaseAndRecord(increase, ten);
        vm.revertToState(snapshot);
        assertTrue(vault.settleMaker(positionId));
        uint256 addedId = openMaker(_asOpen(increase));
        _assertMergedEqualsSeparate(merged, positionId, addedId, ten);
        vm.warp(block.timestamp + 10 days);
        assertTrue(vault.settleMaker(positionId));
        assertTrue(vault.settleMaker(addedId));
        uint256 separateEscrowLater = vault.makerPositionOf(positionId).escrow + vault.makerPositionOf(addedId).escrow;
        assertEq(merged.escrowLater, separateEscrowLater, "the same premium later");
        assertLedger();
    }

    function _increaseAndRecord(MakerIncreaseRequest memory increase, uint256 ten)
        internal
        returns (Merged memory merged)
    {
        uint256 positionId = increase.positionId;
        _increase(increase);
        merged.position = vault.makerPositionOf(positionId);
        // three legs
        for (uint256 index = 0; index < 3; ++index) {
            merged.legs[index] = vault.legOf(positionId, index);
        }
        merged.bucket = vault.bucketOf(vaultId, ten);
        merged.treasury1 = vault.ledgerOf(vaultId).treasury1;
        vm.warp(block.timestamp + 10 days);
        assertTrue(vault.settleMaker(positionId));
        merged.escrowLater = vault.makerPositionOf(positionId).escrow;
        vm.warp(block.timestamp - 10 days);
    }

    function _twoLegIncrease(uint256 positionId, uint256 ten, uint256 two)
        internal
        pure
        returns (MakerIncreaseRequest memory increase)
    {
        increase = _increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 5_000e6), 10e6);
        increase.legs = new LegRequest[](2);
        increase.legs[0] = LegRequest({bucketId: two, liquidity: liquidityOn(LEVEL_2X, 4_000e6)});
        increase.legs[1] = LegRequest({bucketId: ten, liquidity: liquidityOn(LEVEL_10X, 5_000e6)});
        if (two > ten) (increase.legs[0], increase.legs[1]) = (increase.legs[1], increase.legs[0]);
    }

    function _asOpen(MakerIncreaseRequest memory increase) internal view returns (MakerOpenRequest memory added) {
        added.vaultId = vaultId;
        added.isLong = true;
        added.legs = increase.legs;
        added.collateral = increase.collateral;
        added.escrow = increase.escrow;
        added.maximumRateBps = type(uint256).max;
    }

    function _assertMergedEqualsSeparate(Merged memory merged, uint256 positionId, uint256 addedId, uint256 ten)
        internal
        view
    {
        MakerPosition memory old = vault.makerPositionOf(positionId);
        MakerPosition memory fresh = vault.makerPositionOf(addedId);
        _assertLegsEqual(merged.legs[0], vault.legOf(positionId, 0));
        _assertLegsEqual(merged.legs[1], vault.legOf(addedId, 0));
        _assertLegsEqual(merged.legs[2], vault.legOf(addedId, 1));
        assertEq(merged.position.legCount, 3, "legs");
        assertEq(merged.position.maximum0, old.maximum0 + fresh.maximum0, "maximum0");
        assertEq(merged.position.maximum1, old.maximum1 + fresh.maximum1, "maximum1");
        assertEq(merged.position.reserve0, old.reserve0 + fresh.reserve0, "reserve0");
        assertEq(merged.position.reserve1, old.reserve1 + fresh.reserve1, "reserve1");
        assertEq(merged.position.escrow, old.escrow + fresh.escrow, "escrow");
        assertEq(merged.position.basis, old.basis + fresh.basis, "basis");
        _assertBucketsEqual(merged.bucket, vault.bucketOf(vaultId, ten));
        assertEq(merged.treasury1, vault.ledgerOf(vaultId).treasury1, "protocol's slice");
    }

    function test_increaseMaker_newLegTakesTheCurrentFloorAndItsOwnMinimumCharge() public {
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(ten), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        uint40 oldSettledAt = vault.legOf(positionId, 0).settledAt;
        FloorRow[] memory rows = new FloorRow[](1);
        rows[0] = FloorRow({minimumDistanceBps: 0, rateBps: 5_000});
        vm.prank(owner);
        vault.appendFloorTable(vaultId, rows);
        vm.warp(block.timestamp + 1 days);
        uint256 escrowBefore = vault.makerPositionOf(positionId).escrow;
        _increase(_increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 5_000e6), 10e6));
        Leg memory oldLeg = vault.legOf(positionId, 0);
        Leg memory newLeg = vault.legOf(positionId, 1);
        assertEq(oldLeg.floorRateBps, 11_500, "the old leg keeps its row");
        assertEq(newLeg.floorRateBps, 5_000, "the new leg takes today's row");
        assertEq(oldLeg.settledAt, oldSettledAt, "the old leg's prepaid window is untouched");
        assertEq(newLeg.settledAt, block.timestamp + 2 days, "the new leg prepays its own two days");
        uint256 charge = MakerMath.owed(newLeg.maximum1, 0, 5_000, 2 days);
        assertGt(charge, 0);
        assertLt(vault.makerPositionOf(positionId).escrow, escrowBefore + 2_000e6 - charge + 1, "prepaid");
        assertLedger();
    }

    /// @dev A short adds a sell-side leg: its release is token0, and a buy bucket is refused as the wrong side.
    function test_increaseMaker_shortAddsALegOnTheSellSide() public {
        (uint256 sell,) = depositSell(makerA, LEVEL_SHORT, 20e18);
        (uint256 buy,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint128 liquidity = liquidityOn(LEVEL_SHORT, 5_000e6);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(LEVEL_SHORT);
        (, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        uint256 positionId =
            openMaker(makerRequest(false, single(sell), single128(liquidity), uint128(maximum1 + 10e6)));
        uint256 reserve0Before = vault.makerPositionOf(positionId).reserve0;
        vm.prank(trader);
        vm.expectRevert(IMakerBook.InvalidLegs.selector);
        vault.increaseMaker(_increaseRequest(positionId, buy, liquidityOn(LEVEL_10X, 5_000e6), 10e6));
        _increase(_increaseRequest(positionId, sell, liquidity, uint128(maximum1 + 10e6)));
        MakerPosition memory position = vault.makerPositionOf(positionId);
        assertEq(position.legCount, 2);
        assertGt(position.reserve0, reserve0Before, "the new leg released token0");
        assertTrue(
            MakerMath.aggregateChordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1, 2)
        );
        assertLedger();
    }

    /// @dev `positionsOf` lists the trader's open maker positions: an increase keeps the id and mints none, and a full
    /// close takes the closed one out.
    function test_positionsOf_listsOpenMakerPositions() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint128 liquidity = liquidityOn(LEVEL_10X, 5_000e6);
        uint256 first = openMaker(makerRequest(true, single(bucketId), single128(liquidity), 10e6));
        uint256 second = openMaker(makerRequest(true, single(bucketId), single128(liquidity), 10e6));
        _increase(_increaseRequest(second, bucketId, liquidity, 10e6));
        assertEq(vault.lastPositionId(), second, "an increase mints no id");
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(first, WAD);
        closeMakerFull(first, repay0, repay1);
        (uint256[] memory passive, uint256[] memory maker) = vault.positionsOf(trader);
        assertEq(passive.length, 0, "no passive positions");
        assertEq(maker.length, 1, "one maker position left");
        assertEq(maker[0], second, "the increased position stays listed");
        assertLedger();
    }

    /// @dev The makers' profit share is weighed by each leg's `M1` and the time it was out (the verification of
    /// increases): a trader with a gain on a leg from makerA's bucket appended, just before closing, a 750,000 USDC leg
    /// on a bucket only it funded, and took 91 of the makers' 97 USDC. A leg out for a second now earns a sliver.
    function test_increaseMaker_lateLegTakesNoneOfTheOlderLegsProfitShare() public {
        (uint256 older,) = depositBuy(makerA, LEVEL_10X, 100_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(older), single128(liquidityOn(LEVEL_10X, 50_000e6)), 10e6));
        // Base exposure, so the rise below is a gain the older leg carried.
        vm.prank(trader);
        vault.addMakerCollateral0(positionId, 50e18);
        vm.warp(block.timestamp + 1 days);
        setPrice(PRICE_TICK + 953, 1);
        uint256 snapshot = vm.snapshotState();
        uint256 alone = _closeAndClaimOlder(positionId, older);
        vm.revertToState(snapshot);
        (uint256 own,) = depositBuy(trader, LEVEL_2X, 1_000_000e6);
        MakerIncreaseRequest memory request = _increaseRequest(positionId, own, liquidityOn(LEVEL_2X, 750_000e6), 10e6);
        request.escrow = 20_000e6;
        _increase(request);
        uint256 netted = _shareOnPrepay(positionId);
        uint256 withLateLeg = _closeAndClaimOlder(positionId, older);
        assertGt(alone, 0, "makerA earned premium and share");
        // The merged position pays its share on its net gain, so the late leg's own prepaid charge lowers makerA's
        // part by the makers' part of the share on that charge (about 4 USDC here), which costs the trader ten times
        // that in the protocol's cut of the prepay; the weighting itself hands the late leg nothing.
        assertGe(withLateLeg + netted + 0.1e6, alone, "makerA keeps its share");
    }

    /// @dev The makers' part of the profit share on the late leg's prepaid minimum charge.
    function _shareOnPrepay(uint256 positionId) internal view returns (uint256) {
        Leg memory late = vault.legOf(positionId, 1);
        uint256 chargeSeconds = vault.bookSettingsOf(vaultId).minimumChargeSeconds;
        uint256 prepay = MakerMath.owed(late.maximum1, 0, late.floorRateBps, chargeSeconds);
        VaultParameters memory parameters = vault.parametersOf(vaultId);
        uint256 makersBps = 10_000 - parameters.profitTreasuryBps - parameters.profitFeeVaultBps;
        return prepay * parameters.profitShareBps * makersBps / 1e8;
    }

    /// @dev Closes the position in full, waits out the vesting, and returns makerA's token1 income from `older`.
    function _closeAndClaimOlder(uint256 positionId, uint256 older) internal returns (uint256 income1) {
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, WAD);
        closeMakerFull(positionId, repay0, repay1);
        vm.warp(block.timestamp + 2 days);
        vm.prank(makerA);
        (, income1) = vault.claimOrderIncome(vaultId, older, makerA);
    }

    function test_increaseMaker_refusals() public {
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(ten), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        MakerIncreaseRequest memory request = _increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 5_000e6), 10e6);
        vm.prank(makerA);
        vm.expectRevert(IMetricLendingVault.Unauthorized.selector);
        vault.increaseMaker(request);
        request.legs = new LegRequest[](0);
        vm.prank(trader);
        vm.expectRevert(IMakerBook.InvalidLegs.selector);
        vault.increaseMaker(request);
        request = _increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 50e6), 10e6);
        vm.prank(trader);
        vm.expectRevert(IMakerBook.BelowMinimumNotional.selector);
        vault.increaseMaker(request);
        request = _increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 40_000e6), 10e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.UtilizationCeiling.selector);
        vault.increaseMaker(request);
    }

    /// @dev The chord holds on the whole position with a unit kept back per leg: a position at its own chord's edge
    /// needs collateral for the new leg too.
    function test_increaseMaker_requiresTheCombinedChord() public {
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint128 liquidity = liquidityOn(LEVEL_10X, 10_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(ten), single128(liquidity), _edgeCollateral(liquidity, 1)));
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.Insolvent.selector);
        vault.increaseMaker(_increaseRequest(positionId, ten, liquidity, 0));
        _increase(_increaseRequest(positionId, ten, liquidity, uint128(_edgeCollateral(liquidity, 2) - 1)));
        assertLedger();
    }

    /// @dev Token1 a long on LEVEL_10X needs beyond its release to sit on the chord with `units` kept back.
    function _edgeCollateral(uint128 liquidity, uint256 units) internal view returns (uint128) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(LEVEL_10X);
        (, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        (, uint256 release1) = VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96());
        return uint128(maximum1 + units - release1);
    }

    /// @dev The escrow minimum covers every leg after the increase, not only the new one.
    function test_increaseMaker_escrowMustCoverTheWholePosition() public {
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(ten), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        vm.warp(block.timestamp + 61 days);
        assertTrue(vault.settleMaker(positionId));
        MakerIncreaseRequest memory request = _increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 1_000e6), 10e6);
        // The new leg alone needs about 9.5 of prepaid charge and horizon; the old one about 95 more.
        request.escrow = 15e6;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.EscrowTooSmall.selector);
        vault.increaseMaker(request);
        request.escrow = 200e6;
        _increase(request);
        assertLedger();
    }

    function test_increaseMaker_refusesAShortfallAndAFlag() public {
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(ten), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        vm.warp(block.timestamp + 90 days);
        MakerIncreaseRequest memory request = _increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 1_000e6), 10e6);
        request.escrow = 10_000e6;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.PremiumUnpaid.selector);
        vault.increaseMaker(request);
        vault.flagMaker(positionId);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.PremiumUnpaid.selector);
        vault.increaseMaker(request);
        vm.prank(trader);
        vault.addMakerEscrow(positionId, 5_000e6);
        request.escrow = 0;
        _increase(request);
        assertLedger();
    }

    function test_increaseMaker_refusesMoreThanEightLegs() public {
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 500_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(ten), single128(liquidityOn(LEVEL_10X, 1_000e6)), 10e6));
        // seven increases fill the eight legs
        for (uint256 step = 0; step < 7; ++step) {
            _increase(_increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 1_000e6), 10e6));
        }
        assertEq(vault.makerPositionOf(positionId).legCount, 8);
        vm.prank(trader);
        vm.expectRevert(IMakerBook.InvalidLegs.selector);
        vault.increaseMaker(_increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 1_000e6), 10e6));
        assertLedger();
    }

    function test_increaseMaker_refusesALevelThePriceEntered() public {
        (uint256 near,) = depositBuy(makerA, LEVEL_NEAR, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(near), single128(liquidityOn(LEVEL_NEAR, 5_000e6)), 10e6));
        setPrice(-200_450, 1);
        vm.prank(trader);
        vm.expectRevert(IMakerBook.WrongSideOfPrice.selector);
        vault.increaseMaker(_increaseRequest(positionId, near, liquidityOn(LEVEL_NEAR, 1_000e6), 10e6));
    }

    /// @dev The rate limit covers every leg at the rates after the increase: a borrow from the existing leg's bucket
    /// raises that leg's curve too.
    function test_increaseMaker_rateLimitCountsTheExistingLegsAfterTheBorrow() public {
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 20_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(ten), single128(liquidityOn(LEVEL_10X, 9_000e6)), 10e6));
        MakerIncreaseRequest memory request = _increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 7_000e6), 10e6);
        request.escrow = 20_000e6;
        uint256 snapshot = vm.snapshotState();
        _increase(request);
        uint256 blendedBps = _blendedBps(positionId);
        vm.revertToState(snapshot);
        request.maximumRateBps = blendedBps - 1;
        vm.prank(trader);
        vm.expectRevert(IMakerBook.RateAboveMaximum.selector);
        vault.increaseMaker(request);
        request.maximumRateBps = blendedBps;
        _increase(request);
        assertLedger();
    }

    function test_increaseMaker_partialAndFullCloseWithTwoLegsOnOneBucket() public {
        (uint256 ten,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(ten), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        vm.warp(block.timestamp + 1 days);
        _increase(_increaseRequest(positionId, ten, liquidityOn(LEVEL_10X, 5_000e6), 10e6));
        vm.warp(block.timestamp + 1 days);
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, 0.5e18);
        vm.prank(trader);
        vault.closeMaker(
            MakerCloseRequest({positionId: positionId, fractionWad: 0.5e18, repay0: repay0, repay1: repay1})
        );
        Bucket memory bucket = vault.bucketOf(vaultId, ten);
        assertEq(bucket.lent, vault.legOf(positionId, 0).liquidity + vault.legOf(positionId, 1).liquidity, "lent");
        (repay0, repay1) = repaymentsAtBid(positionId, WAD);
        closeMakerFull(positionId, repay0, repay1);
        assertEq(vault.bucketOf(vaultId, ten).lent, 0, "all repaid");
        assertEq(vault.legOf(positionId, 1).liquidity, 0, "second leg deleted");
        assertLedger();
    }

    function _blendedBps(uint256 positionId) internal view returns (uint256) {
        MakerPosition memory position = vault.makerPositionOf(positionId);
        uint256 weighted;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < position.legCount; ++index) {
            Leg memory leg = vault.legOf(positionId, index);
            Bucket memory bucket = vault.bucketOf(vaultId, leg.bucketId);
            (int24 level,,) = MakerMath.decode(leg.bucketId);
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(level);
            uint256 supplied = bucket.lent + MakerMath.liquidityFor(true, bucket.balance1, sqrtLowerX96, sqrtUpperX96);
            uint256 utilizationWad = bucket.lent * WAD / supplied;
            uint256 curveWad = utilizationWad <= 0.8e18
                ? 0.05e18 * utilizationWad / 0.8e18
                : 0.05e18 + 12e18 * (utilizationWad - 0.8e18) / 0.2e18;
            weighted += uint256(leg.maximum1) * (curveWad + uint256(leg.floorRateBps) * 1e14);
        }
        return (weighted * 10_000 + WAD * position.maximum1 - 1) / (WAD * position.maximum1);
    }
}
