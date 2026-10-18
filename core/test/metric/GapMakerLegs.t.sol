// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Ledger} from "../../src/metric/vault/VaultTypes.sol";
import {
    BookCurve,
    Bucket,
    Leg,
    MakerCloseRequest,
    MakerOpenRequest,
    MakerPosition
} from "../../src/metric/vault/MakerTypes.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {MakerMath} from "../../src/metric/vault/libraries/MakerMath.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {MakerFixture} from "./utils/MakerFixture.sol";

/// @notice Gaps G5 and G6 of the fresh audit (2026-10-17): a maker position with eight unequal legs through a partial,
/// a full and a forced close, and a repayment that overpays one leg to excuse another.
contract GapMakerLegsTest is MakerFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAY_PER_WAD = 1e9;
    uint256 internal constant LADDER_LEGS = 8;
    /// @dev Each sell bucket holds 20 token0, about 40,000 token1: the ladder's largest leg lends under a quarter
    /// of it.
    uint256 internal constant SELL_DEPOSIT0 = 20e18;
    /// @dev Covers the token1 the legs the price passes need at the bid, so the owner can repay at the bid.
    uint128 internal constant LADDER_COLLATERAL = 8_000e6;
    /// @dev The bid falls in level -1,998: the two legs below it hold only token1, it holds both, the five above only
    /// token0.
    int24 internal constant TICK_INSIDE_LADDER = -199_750;
    uint256 internal constant PARTIAL_FRACTION_WAD = 0.4e18;
    /// @dev The open's minimum (two days of floor prepaid plus a day more) with a little to spare, soon outrun.
    uint128 internal constant SHORT_ESCROW = 300e6;
    /// @dev valueInToken1 floors the token0 price twice, so two amounts of equal value can differ by two units.
    uint256 internal constant VALUE_ROUNDING_UNITS = 2;
    /// @dev Scaling rounds each token's part up by at most a unit, and the fraction by at most a WAD step.
    uint256 internal constant CHORD_ROUNDING_UNITS = 2;
    /// @dev The two-leg long of G6: about 10% and 50% below the price.
    int24 internal constant LEVEL_10X = -2_014;
    int24 internal constant LEVEL_2X = -2_073;

    /// @dev The state a close starts from, read before it runs: a full close deletes the legs.
    struct Snapshot {
        uint256 positionId;
        MakerPosition position;
        Leg[] legs;
        Bucket[] buckets;
        /// @dev Each leg's premium due at the close, rounded up as a close rounds it.
        uint256[] dues;
        Ledger ledger;
        uint256 bookIncome0;
        uint256 bookIncome1;
        uint256 trader0;
        uint256 trader1;
        uint256 closer0;
        uint256 closer1;
    }

    /// @dev What every leg's bucket received from a close.
    struct Receipts {
        uint256[] delta0;
        uint256[] delta1;
        uint256 total0;
        uint256 total1;
    }

    // ---------------------------------------------------------------- G5

    /// @dev G5, owner closes: eight unequal legs at eight levels, the bid inside the ladder so legs hold token1, both
    /// tokens or token0. A 40% close then a close of the rest each return every leg's repayment to that leg's own
    /// bucket and nowhere else, every repayment passes its leg's own rule, every bucket gets its leg's premium, and the
    /// payouts come from the closed part of the reserves. A mix-up between legs would let one leg's bucket fund
    /// another's debt.
    function test_eightLegs_partialThenFullClose_repayEveryBucketItsOwnLeg() public {
        uint256 positionId = _openLadder(2_000e6);
        vm.warp(block.timestamp + 5 days);
        setPrice(TICK_INSIDE_LADDER, 1);
        _assertLadderStraddlesTheBid(positionId);
        _closeByOwnerAndCheck(positionId, PARTIAL_FRACTION_WAD);
        MakerPosition memory rest = vault.makerPositionOf(positionId);
        assertEq(rest.legCount, LADDER_LEGS, "every leg stays open");
        assertTrue(
            MakerMath.aggregateChordHolds(rest.reserve0, rest.reserve1, rest.maximum0, rest.maximum1, LADDER_LEGS),
            "the rest holds the aggregate chord"
        );
        vm.warp(block.timestamp + 5 days);
        _closeByOwnerAndCheck(positionId, WAD);
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "deleted");
        _assertNothingLeftOpen();
    }

    /// @dev G5, force close without a pool: the scaling fallback splits the reserves across the eight legs by their
    /// extremes. Each bucket's receipt passes its own leg's rule on the whole leg, stays within the leg's allocation so
    /// no leg is paid from another's part, and every bucket still gets its leg's premium. The reward and the trader's
    /// payout fit what the repayments, arrears and share leave, and every token is accounted for.
    function test_eightLegs_forceCloseWithoutAPool_scalesEveryLegToItsOwnRule() public {
        uint256 positionId = _openLadder(SHORT_ESCROW);
        vm.warp(block.timestamp + 10 days);
        setPrice(TICK_INSIDE_LADDER, 1);
        vault.flagMaker(positionId);
        vm.warp(block.timestamp + defaultBookSettings().graceSeconds);
        Snapshot memory before = _snapshot(positionId);
        assertLt(
            before.position.escrow, _totalDue(before), "premise: the escrow is short, so arrears come from reserves"
        );
        vm.prank(closer);
        (uint256 reward0, uint256 reward1) = vault.forceCloseMaker(positionId);
        Receipts memory receipts = _assertEveryLegRepaid(before, WAD);
        _assertWithinAllocations(before, receipts);
        assertEq(quote.balanceOf(closer) - before.closer1, reward1, "closer paid its reward1");
        assertEq(base.balanceOf(closer) - before.closer0, reward0, "closer paid its reward0");
        uint256 payout0 = base.balanceOf(trader) - before.trader0 + reward0;
        uint256 payout1 = quote.balanceOf(trader) - before.trader1 + reward1;
        assertLe(payout0 + receipts.total0, before.position.reserve0, "token0 payouts fit the reserves");
        assertLe(
            payout1 + receipts.total1,
            uint256(before.position.reserve1) + before.position.escrow,
            "token1 payouts fit the reserves and escrow"
        );
        _assertConserved(before, receipts);
        assertEq(vault.ledgerOf(vaultId).reserve0, 0, "no reserve0 left");
        assertEq(vault.ledgerOf(vaultId).reserve1, 0, "no reserve1 left");
        assertEq(vault.ledgerOf(vaultId).escrow, 0, "no escrow left");
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "deleted");
        _assertNothingLeftOpen();
        assertLedger();
    }

    // ---------------------------------------------------------------- G6

    /// @dev G6: the repayment rule is per leg. Moving one unit of token1 from the first leg's least repayment to the
    /// second's keeps the total but leaves the first short, and the close reverts with RepaymentShort. The exact split
    /// then closes, so the unit is what decided it: a total-only check would let one bucket fund another's debt.
    function test_twoLegs_unitMovedFromTheFirstLeg_revertsAndChangesNothing() public {
        _assertUnitMoveReverts(0, 1);
    }

    /// @dev G6, the other direction: the first leg is overpaid and passes its rule before the second leg, one unit
    /// short, is checked. The rule must still run on every leg after an earlier one passed, not stop at the first.
    function test_twoLegs_unitMovedFromTheSecondLeg_revertsAfterTheFirstWasRepaid() public {
        _assertUnitMoveReverts(1, 0);
    }

    // ---------------------------------------------------------------- G5 helpers

    function _ladderLevels() internal pure returns (int24[LADDER_LEGS] memory) {
        return [int24(-2_003), -2_001, -1_998, -1_994, -1_990, -1_985, -1_975, -1_960];
    }

    /// @dev Unequal all-token1 amounts, so the legs' weights, floors and allocations all differ.
    function _ladderNotionals() internal pure returns (uint256[LADDER_LEGS] memory) {
        return [uint256(1_500e6), 2_200e6, 3_100e6, 4_000e6, 5_300e6, 6_100e6, 7_700e6, 9_000e6];
    }

    /// @dev An eight-leg short across sell levels from 0.6% to 55% above the price, in ascending bucket order.
    function _openLadder(uint128 escrow) internal returns (uint256 positionId) {
        int24[LADDER_LEGS] memory levels = _ladderLevels();
        uint256[LADDER_LEGS] memory notionals = _ladderNotionals();
        uint256[] memory bucketIds = new uint256[](LADDER_LEGS);
        uint128[] memory liquidities = new uint128[](LADDER_LEGS);
        // index < LADDER_LEGS = 8
        for (uint256 index = 0; index < LADDER_LEGS; ++index) {
            (bucketIds[index],) = depositSell(makerA, levels[index], SELL_DEPOSIT0);
            liquidities[index] = liquidityOn(levels[index], notionals[index]);
        }
        MakerOpenRequest memory request = makerRequest(false, bucketIds, liquidities, LADDER_COLLATERAL);
        request.escrow = escrow;
        positionId = openMaker(request);
        assertEq(vault.makerPositionOf(positionId).legCount, LADDER_LEGS, "eight legs");
    }

    /// @dev The scenario's premise: at the bid the first leg holds only token1, the third both, the last only token0.
    function _assertLadderStraddlesTheBid(uint256 positionId) internal view {
        (uint256 first0, uint256 first1) = _holdingsAtBid(vault.legOf(positionId, 0), WAD);
        (uint256 middle0, uint256 middle1) = _holdingsAtBid(vault.legOf(positionId, 2), WAD);
        (uint256 last0, uint256 last1) = _holdingsAtBid(vault.legOf(positionId, LADDER_LEGS - 1), WAD);
        assertEq(first0, 0, "a passed leg holds no token0");
        assertGt(first1, 0, "a passed leg holds token1");
        assertGt(middle0, 0, "the straddled leg holds token0");
        assertGt(middle1, 0, "the straddled leg holds token1");
        assertGt(last0, 0, "a far leg holds token0");
        assertEq(last1, 0, "a far leg holds no token1");
    }

    /// @dev Closes `fractionWad` of every leg at the bid's repayments and checks every leg, the payouts and the ledger.
    function _closeByOwnerAndCheck(uint256 positionId, uint256 fractionWad) internal {
        Snapshot memory before = _snapshot(positionId);
        (uint256[] memory repay0, uint256[] memory repay1) = repaymentsAtBid(positionId, fractionWad);
        vm.prank(trader);
        (uint256 paid0, uint256 paid1) = vault.closeMaker(
            MakerCloseRequest({positionId: positionId, fractionWad: fractionWad, repay0: repay0, repay1: repay1})
        );
        Receipts memory receipts = _assertEveryLegRepaid(before, fractionWad);
        // index < LADDER_LEGS = 8
        for (uint256 index = 0; index < LADDER_LEGS; ++index) {
            assertEq(receipts.delta0[index], repay0[index], "the bucket got its leg's token0, no more, no less");
            assertEq(receipts.delta1[index], repay1[index], "the bucket got its leg's token1, no more, no less");
        }
        assertEq(base.balanceOf(trader) - before.trader0, paid0, "paid0 reached the trader");
        assertEq(quote.balanceOf(trader) - before.trader1, paid1, "paid1 reached the trader");
        _assertOwnerPayoutFits(before, fractionWad, paid0, paid1, receipts);
        _assertConserved(before, receipts);
        assertLedger();
    }

    /// @dev The payouts come from the closed part: the ledger's reserves fall by exactly that part, and the trader's
    /// payout plus the repayments fit within it (plus the escrow, which a full close refunds).
    function _assertOwnerPayoutFits(
        Snapshot memory before,
        uint256 fractionWad,
        uint256 paid0,
        uint256 paid1,
        Receipts memory receipts
    ) internal view {
        uint256 portion0 = VaultMath.portionDown(before.position.reserve0, fractionWad);
        uint256 portion1 = VaultMath.portionDown(before.position.reserve1, fractionWad);
        Ledger memory ledger = vault.ledgerOf(vaultId);
        assertEq(before.ledger.reserve0 - ledger.reserve0, portion0, "reserve0 falls by the closed part");
        assertEq(before.ledger.reserve1 - ledger.reserve1, portion1, "reserve1 falls by the closed part");
        assertLe(paid0 + receipts.total0, portion0, "token0 payout fits the closed part");
        assertLe(paid1 + receipts.total1, portion1 + before.position.escrow, "token1 payout fits the closed part");
        if (fractionWad == WAD) return;
        MakerPosition memory rest = vault.makerPositionOf(before.positionId);
        assertEq(rest.reserve0, before.position.reserve0 - portion0, "the rest keeps its reserve0");
        assertEq(rest.reserve1, before.position.reserve1 - portion1, "the rest keeps its reserve1");
    }

    /// @dev Every leg's bucket: its balances grew by a repayment that passes the leg's own rule on the closed liquidity
    /// and is worth at least the range's holdings at the bid; its loan fell by exactly that liquidity; and it received
    /// at least the leg's premium due, net of the protocol's slice.
    function _assertEveryLegRepaid(Snapshot memory before, uint256 fractionWad)
        internal
        view
        returns (Receipts memory receipts)
    {
        uint256 legCount = before.legs.length;
        receipts.delta0 = new uint256[](legCount);
        receipts.delta1 = new uint256[](legCount);
        // legCount <= MakerMath.MAX_LEGS = 8
        for (uint256 index = 0; index < legCount; ++index) {
            (uint256 delta0, uint256 delta1) = _assertLegRepaid(before, index, fractionWad);
            receipts.delta0[index] = delta0;
            receipts.delta1[index] = delta1;
            receipts.total0 += delta0;
            receipts.total1 += delta1;
        }
    }

    function _assertLegRepaid(Snapshot memory before, uint256 index, uint256 fractionWad)
        internal
        view
        returns (uint256 delta0, uint256 delta1)
    {
        Leg memory leg = before.legs[index];
        Bucket memory bucketBefore = before.buckets[index];
        Bucket memory bucketAfter = vault.bucketOf(vaultId, leg.bucketId);
        assertGe(bucketAfter.balance0, bucketBefore.balance0, "a bucket's token0 never falls in a close");
        assertGe(bucketAfter.balance1, bucketBefore.balance1, "a bucket's token1 never falls in a close");
        delta0 = bucketAfter.balance0 - bucketBefore.balance0;
        delta1 = bucketAfter.balance1 - bucketBefore.balance1;
        uint128 closedLiquidity = uint128(VaultMath.portionDown(leg.liquidity, fractionWad));
        assertEq(bucketBefore.lent - bucketAfter.lent, closedLiquidity, "the loan falls by the closed liquidity");
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = _legRange(leg);
        assertTrue(VaultMath.repays(delta0, delta1, closedLiquidity, sqrtLowerX96, sqrtUpperX96), "the leg's own rule");
        _assertWorthTheHoldings(leg, fractionWad, delta0, delta1);
        _assertPremiumReached(before.dues[index], bucketBefore, bucketAfter);
    }

    /// @dev A repayment on the curve is worth at least the range's own holdings at any price; at the bid here.
    function _assertWorthTheHoldings(Leg memory leg, uint256 fractionWad, uint256 delta0, uint256 delta1)
        internal
        view
    {
        (uint256 held0, uint256 held1) = _holdingsAtBid(leg, fractionWad);
        uint160 sqrtBidX96 = source.sqrtBidX96();
        uint256 received = VaultMath.valueInToken1(delta0, delta1, sqrtBidX96, false);
        uint256 holdings = VaultMath.valueInToken1(held0, held1, sqrtBidX96, false);
        assertGe(received + VALUE_ROUNDING_UNITS, holdings, "worth at least the range's holdings at the bid");
    }

    /// @dev Every earlier stream had fully vested, so what a bucket's token1 stream holds after the close is what the
    /// close paid it: at least its leg's due less the protocol's slice.
    function _assertPremiumReached(uint256 due, Bucket memory bucketBefore, Bucket memory bucketAfter) internal view {
        assertGt(due, 0, "premise: the leg owes premium");
        assertLe(bucketBefore.stream1End, block.timestamp, "premise: earlier income fully vested");
        uint256 protocolPart = due * vault.parametersOf(vaultId).premiumProtocolBps / BPS;
        assertGe(bucketAfter.stream1Remaining, due - protocolPart, "the bucket received its leg's premium");
    }

    /// @dev The scaling fallback's bounds. Each leg's receipt is within its own allocation of the reserves, so no leg
    /// is paid from another's part, and on or under the leg's own chord, so scaling hands the makers no more than the
    /// debt at the strike: the whole allocation, unscaled, would sit well above it.
    function _assertWithinAllocations(Snapshot memory before, Receipts memory receipts) internal pure {
        MakerPosition memory position = before.position;
        // before.legs.length <= MakerMath.MAX_LEGS = 8
        for (uint256 index = 0; index < before.legs.length; ++index) {
            Leg memory leg = before.legs[index];
            uint256 part0 = MakerMath.allocation(position.reserve0, LADDER_LEGS, leg.maximum0, position.maximum0);
            uint256 part1 = MakerMath.allocation(position.reserve1, LADDER_LEGS, leg.maximum1, position.maximum1);
            assertLe(receipts.delta0[index], part0, "token0 within the leg's allocation");
            assertLe(receipts.delta1[index], part1, "token1 within the leg's allocation");
            uint256 onChord = receipts.delta1[index] * leg.maximum0 + leg.maximum1 * receipts.delta0[index];
            uint256 rounding = CHORD_ROUNDING_UNITS * (uint256(leg.maximum0) + leg.maximum1);
            assertLe(onChord, uint256(leg.maximum1) * leg.maximum0 + rounding, "on or under the leg's chord");
        }
    }

    function _totalDue(Snapshot memory before) internal pure returns (uint256 total) {
        // before.dues.length <= MakerMath.MAX_LEGS = 8
        for (uint256 index = 0; index < before.dues.length; ++index) {
            total += before.dues[index];
        }
    }

    /// @dev Every token the close consumed (reserves and escrow) went to a bucket's balances, the trader, the closer,
    /// the treasury, the fee vault or makers' income: nothing appears or disappears.
    function _assertConserved(Snapshot memory before, Receipts memory receipts) internal view {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        (,, uint256 income0, uint256 income1) = vault.bookTotalsOf(vaultId);
        uint256 consumed0 = before.ledger.reserve0 - ledger.reserve0;
        uint256 consumed1 = before.ledger.reserve1 - ledger.reserve1 + before.ledger.escrow - ledger.escrow;
        uint256 paidOut0 = base.balanceOf(trader) - before.trader0 + base.balanceOf(closer) - before.closer0;
        uint256 paidOut1 = quote.balanceOf(trader) - before.trader1 + quote.balanceOf(closer) - before.closer1;
        uint256 fees0 = ledger.treasury0 - before.ledger.treasury0 + ledger.feeVault0 - before.ledger.feeVault0;
        uint256 fees1 = ledger.treasury1 - before.ledger.treasury1 + ledger.feeVault1 - before.ledger.feeVault1;
        assertEq(consumed0, receipts.total0 + paidOut0 + fees0 + income0 - before.bookIncome0, "token0 conserved");
        assertEq(consumed1, receipts.total1 + paidOut1 + fees1 + income1 - before.bookIncome1, "token1 conserved");
    }

    /// @dev With the only position closed, every ladder bucket has nothing lent.
    function _assertNothingLeftOpen() internal view {
        int24[LADDER_LEGS] memory levels = _ladderLevels();
        // index < LADDER_LEGS = 8
        for (uint256 index = 0; index < LADDER_LEGS; ++index) {
            uint256 bucketId = vault.currentBucketOf(vaultId, levels[index], false);
            assertEq(vault.bucketOf(vaultId, bucketId).lent, 0, "nothing lent");
        }
    }

    // ---------------------------------------------------------------- G6 helpers

    /// @dev Opens the two-leg long, moves one unit of token1 from leg `shortLeg`'s least repayment to leg
    /// `overpaidLeg`'s, expects RepaymentShort, then closes with the exact split.
    function _assertUnitMoveReverts(uint256 shortLeg, uint256 overpaidLeg) internal {
        uint256 positionId = _openTwoLegLong();
        vm.warp(block.timestamp + 3 days);
        (uint256[] memory repay0, uint256[] memory repay1) = _leastRepayments(positionId);
        repay1[shortLeg] -= 1;
        repay1[overpaidLeg] += 1;
        Leg memory shorted = vault.legOf(positionId, shortLeg);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = _legRange(shorted);
        assertFalse(
            VaultMath.repays(repay0[shortLeg], repay1[shortLeg], shorted.liquidity, sqrtLowerX96, sqrtUpperX96),
            "premise: one unit short fails the rule"
        );
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.RepaymentShort.selector);
        vault.closeMaker(MakerCloseRequest({positionId: positionId, fractionWad: WAD, repay0: repay0, repay1: repay1}));
        repay1[shortLeg] += 1;
        repay1[overpaidLeg] -= 1;
        Snapshot memory before = _snapshot(positionId);
        closeMakerFull(positionId, repay0, repay1);
        Receipts memory receipts = _assertEveryLegRepaid(before, WAD);
        assertEq(receipts.delta1[shortLeg], repay1[shortLeg], "the exact split repays the first leg");
        assertEq(receipts.delta1[overpaidLeg], repay1[overpaidLeg], "the exact split repays the second leg");
        assertLedger();
    }

    /// @dev Two buy legs of unequal size, 10% and 50% below the price; at the bid both hold only token1.
    function _openTwoLegLong() internal returns (uint256 positionId) {
        uint256[] memory bucketIds = new uint256[](2);
        uint128[] memory liquidities = new uint128[](2);
        (bucketIds[0],) = depositBuy(makerA, LEVEL_2X, 30_000e6);
        (bucketIds[1],) = depositBuy(makerB, LEVEL_10X, 30_000e6);
        assertLt(bucketIds[0], bucketIds[1], "premise: ids ascend");
        liquidities[0] = liquidityOn(LEVEL_2X, 4_321e6);
        liquidities[1] = liquidityOn(LEVEL_10X, 7_654e6);
        positionId = openMaker(makerRequest(true, bucketIds, liquidities, 50e6));
    }

    /// @dev Each leg's least token1-only repayment: the exact inverse of the rule at no token0. One unit less fails.
    function _leastRepayments(uint256 positionId)
        internal
        view
        returns (uint256[] memory repay0, uint256[] memory repay1)
    {
        repay0 = new uint256[](2);
        repay1 = new uint256[](2);
        // index < 2: the two legs of `_openTwoLegLong`
        for (uint256 index = 0; index < 2; ++index) {
            Leg memory leg = vault.legOf(positionId, index);
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = _legRange(leg);
            repay1[index] = minimumRepay1(0, leg.liquidity, sqrtLowerX96, sqrtUpperX96);
            assertTrue(VaultMath.repays(0, repay1[index], leg.liquidity, sqrtLowerX96, sqrtUpperX96), "least passes");
        }
    }

    // ---------------------------------------------------------------- shared helpers

    function _snapshot(uint256 positionId) internal view returns (Snapshot memory snapshot) {
        snapshot.positionId = positionId;
        snapshot.position = vault.makerPositionOf(positionId);
        uint256 legCount = snapshot.position.legCount;
        snapshot.legs = new Leg[](legCount);
        snapshot.buckets = new Bucket[](legCount);
        snapshot.dues = new uint256[](legCount);
        // legCount <= MakerMath.MAX_LEGS = 8
        for (uint256 index = 0; index < legCount; ++index) {
            snapshot.legs[index] = vault.legOf(positionId, index);
            snapshot.buckets[index] = vault.bucketOf(vaultId, snapshot.legs[index].bucketId);
            snapshot.dues[index] = _legDue(snapshot.legs[index]);
        }
        snapshot.ledger = vault.ledgerOf(vaultId);
        (,, snapshot.bookIncome0, snapshot.bookIncome1) = vault.bookTotalsOf(vaultId);
        snapshot.trader0 = base.balanceOf(trader);
        snapshot.trader1 = quote.balanceOf(trader);
        snapshot.closer0 = base.balanceOf(closer);
        snapshot.closer1 = quote.balanceOf(closer);
    }

    /// @dev A leg's premium due now, recomputed from the bucket's last checkpoint rather than read from the contract:
    /// the curve's integral since the leg's snapshot plus the floor since its settled time, rounded up once as a close
    /// rounds. Utilization is constant since the checkpoint, and the book has one curve version.
    function _legDue(Leg memory leg) internal view returns (uint256) {
        uint256 curveWad = FullMath.mulDiv(leg.maximum1, _rateIndexNowRay(leg.bucketId) - leg.rateIndexRay, RAY_PER_WAD);
        uint256 floorSeconds = block.timestamp > leg.settledAt ? block.timestamp - leg.settledAt : 0;
        uint256 floorWad = FullMath.mulDiv(uint256(leg.maximum1) * leg.floorRateBps * WAD, floorSeconds, BPS * 365 days);
        return FullMath.mulDivRoundingUp(curveWad + floorWad + leg.owedFractionWad, 1, WAD);
    }

    /// @dev A bucket's rate index run to now from its last checkpoint at the utilization it has had since.
    function _rateIndexNowRay(uint256 bucketId) internal view returns (uint256) {
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        BookCurve[] memory curves = vault.bookCurvesOf(vaultId);
        assertEq(curves.length, 1, "premise: one curve version");
        (int24 level, bool isBuy,) = MakerMath.decode(bucketId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(level);
        uint256 waiting = isBuy ? bucket.balance1 : bucket.balance0;
        uint256 supplied = bucket.lent + MakerMath.liquidityFor(isBuy, waiting, sqrtLowerX96, sqrtUpperX96);
        uint256 elapsedSeconds = block.timestamp - bucket.updatedAt;
        return bucket.rateIndexRay + VaultMath.indexGrowthRay(curves[0].curve, bucket.lent, supplied, elapsedSeconds);
    }

    function _legRange(Leg memory leg) internal pure returns (uint160, uint160) {
        (int24 level,,) = MakerMath.decode(leg.bucketId);
        return levelSqrtPrices(level);
    }

    /// @dev What `fractionWad` of a leg's range holds at the bid, rounded down.
    function _holdingsAtBid(Leg memory leg, uint256 fractionWad) internal view returns (uint256, uint256) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = _legRange(leg);
        uint128 liquidity = uint128(VaultMath.portionDown(leg.liquidity, fractionWad));
        return VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96());
    }
}
