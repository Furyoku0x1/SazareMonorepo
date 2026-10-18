// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BookSettings, Bucket, FloorRow, LegRequest, MakerCloseRequest, MakerOpenRequest} from "vault/MakerTypes.sol";
import {Ledger, OpenRequest, Venue} from "vault/VaultTypes.sol";
import {IMakerBook} from "vault/interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MakerMath} from "vault/libraries/MakerMath.sol";
import {MetricState} from "vault/libraries/MetricState.sol";
import {Curve, DebtTotals} from "vault/libraries/VaultMath.sol";
import {IntegrationToken, MetricFixture} from "./utils/MetricFixture.sol";

/// @notice Gap tests G7, G18 and G19 of the fresh audit (2026-10-17): maker fills and a maker force close trading
/// through the pool that holds the passive vault's own position; the keeper's reward at 0 and 100 bp on tiny outputs;
/// and a level's next generation after a bucket retires with loans out and income vesting.
contract GapMakerFillsTest is MetricFixture {
    uint24 internal constant LEVEL_TICKS = 100;
    /// @dev About 1,943–1,962: below the 2,000 price.
    int24 internal constant BUY_LEVEL = -2_006;
    /// @dev About 2,105–2,126: above it.
    int24 internal constant SELL_LEVEL = -1_998;
    /// @dev Raw price 2e-9 is about tick -200,311.
    int24 internal constant PRICE_TICK = -200_311;
    uint256 internal constant BPS = 10_000;
    /// @dev A fresh bucket's share price: `MakerBook.VIRTUAL_SHARES / MakerBook.VIRTUAL_VALUE`.
    uint256 internal constant FRESH_SHARES_PER_UNIT = 1e6;
    uint256 internal constant Q192 = 1 << 192;

    address internal makerA = makeAddr("makerA");
    address internal makerB = makeAddr("makerB");
    address internal keeper = makeAddr("keeper");

    /// @dev The passive vault's books that maker flows must leave alone.
    struct Passive {
        uint256 buffer0;
        uint256 buffer1;
        uint256 outstanding0;
        uint256 outstanding1;
        bytes32 debts;
        bytes32 lenders;
        uint256[] binShares;
    }

    /// @dev Custody and the ledger around a fill.
    struct Custody {
        Ledger ledger;
        uint256 book0;
        uint256 book1;
        uint256 income0;
        uint256 income1;
        uint256 vault0;
        uint256 vault1;
    }

    function setUp() public override {
        super.setUp();
        _fundMaker(makerA);
        _fundMaker(makerB);
    }

    // ---------------------------------------------------------------- G7: the passive vault's own pool

    /// @dev G7: a buy fill large enough to cross into the bins holding the passive vault's base trades against its
    /// position. The passive vault's pool shares, buffers, debt totals, accrual, stream and lender shares stay exactly
    /// as they were; only the pool's own pricing moves its holdings, at no worse than the reference. Maker custody
    /// moves by exactly the fill's payment and net output, and the cached holdings, once refreshed, match the shares.
    /// Makers and the passive lenders share one pool and one ledger, so a fill that wrote to the passive books would
    /// move value between them.
    function test_fill_tradesThroughThePassivePositionWithoutTouchingItsBooks() public {
        _createBook(5, 100e6);
        uint256 passivePositionId = _lendAndBorrowPassively();
        (uint256 bucketId,) = _deposit(makerA, BUY_LEVEL, true, 50_000e6);
        _setPrice(1_900);
        Passive memory passiveBefore = _passive(passivePositionId);
        Custody memory custodyBefore = _custody();
        (uint256 holdings0Before, uint256 holdings1Before) = _poolHoldings();
        vm.prank(keeper);
        (uint256 paid, uint256 received) = vault.fillBucket(vaultId, bucketId);
        uint256 reward = received * 5 / BPS;
        assertEq(paid, 50_000e6, "the whole order filled");
        assertEq(base.balanceOf(keeper), reward, "the keeper's reward");
        _assertPassiveUnchanged(passiveBefore, passivePositionId);
        _assertFillCustody(custodyBefore, received - reward, paid);
        (uint256 holdings0After, uint256 holdings1After) = _poolHoldings();
        assertLt(holdings0After, holdings0Before, "the fill bought base out of the passive bins");
        assertGt(holdings1After, holdings1Before, "and paid quote into them");
        assertGe(
            _valueAt(holdings0After, holdings1After, 1_900),
            _valueAt(holdings0Before, holdings1Before, 1_900),
            "the passive bins sold at the pool's price, at or above the reference"
        );
        assertLedger();
        _assertHoldingsMatchShares();
        assertLedger();
    }

    /// @dev G7: a maker long's entry swap and its force close both buy base through the passive vault's bins. Neither
    /// touches the passive vault's shares, buffers, debts, accrual or lenders, and once the position is gone the shared
    /// reserve and escrow parts of the ledger hold exactly the passive position's again. Maker reserve or escrow left
    /// in the shared ledger after the close would be tokens no position owns.
    function test_makerEntryAndForceClose_tradeThroughThePassivePositionWithoutTouchingItsBooks() public {
        _createBook(5, 100e6);
        uint256 passivePositionId = _lendAndBorrowPassively();
        (uint256 bucketId,) = _deposit(makerA, BUY_LEVEL, true, 100_000e6);
        Passive memory passiveBefore = _passive(passivePositionId);
        Ledger memory ledgerBefore = vault.ledgerOf(vaultId);
        (uint256 holdings0Before, uint256 holdings1Before) = _poolHoldings();
        // 25,000 USD buys about 12.5 base: through the outsider's ten in the active bin into the vault's next bin.
        // Enough collateral that the trader keeps more than the arrears, so the close buys rather than scale (W-3).
        uint256 positionId = _openLong(bucketId, _liquidityOn(BUY_LEVEL, 30_000e6), 6_000e6, 700e6, 25_000e6);
        _assertPassiveUnchanged(passiveBefore, passivePositionId);
        (uint256 holdings0Open, uint256 holdings1Open) = _poolHoldings();
        assertLt(holdings0Open, holdings0Before, "the entry bought base out of the passive bins");
        assertGt(holdings1Open, holdings1Before, "and paid quote into them");
        _setPrice(1_900);
        vm.warp(block.timestamp + 20 days);
        vault.flagMaker(positionId);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(closer);
        vault.forceCloseMaker(positionId);
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed");
        _assertPassiveUnchanged(passiveBefore, passivePositionId);
        (uint256 holdings0Close, uint256 holdings1Close) = _poolHoldings();
        assertLt(holdings0Close, holdings0Open, "the force close bought its shortfall out of the passive bins");
        assertGt(holdings1Close, holdings1Open, "and paid quote into them");
        Ledger memory ledgerAfter = vault.ledgerOf(vaultId);
        assertEq(ledgerAfter.reserve0, ledgerBefore.reserve0, "only the passive position's base reserve is left");
        assertEq(ledgerAfter.reserve1, ledgerBefore.reserve1, "only the passive position's quote reserve is left");
        assertEq(ledgerAfter.escrow, ledgerBefore.escrow, "only the passive position's escrow is left");
        assertLedger();
        _assertHoldingsMatchShares();
        assertLedger();
    }

    // ---------------------------------------------------------------- G18: the keeper's reward

    /// @dev G18: with no fill reward the keeper is paid nothing and the makers keep the whole output, on tiny and
    /// ordinary fills of both sides, and every fill meets its level's limit. Any reward paid at 0 bp would come out
    /// of the makers' output.
    function test_fillReward_zeroBasisPointsPaysTheKeeperNothing() public {
        _createBook(0, 1);
        _fillLadder(0);
    }

    /// @dev G18: at the 100 bp maximum the keeper's reward is the floor of 1% of the output, zero on an output under
    /// 100 units and truncated on the others, and the makers' net output still meets the level's limit. A reward
    /// rounded up would take a unit from the makers on every tiny fill.
    function test_fillReward_hundredBasisPointsFloorsOnTinyOutputs() public {
        _createBook(100, 1);
        _fillLadder(100);
    }

    /// @dev G18: a sell so small that Metric's output, rounded down to whole quote units, falls under the level's top
    /// is refused rather than filled below the limit. A later deposit still joins the same bucket, and the whole order,
    /// the refused part included, fills at the limit. Without a reward rounding is the only thing between the pool's
    /// price and the makers' limit.
    function test_fillReward_zeroBasisPointsRefusesAnOutputRoundedBelowTheLimit() public {
        _createBook(0, 1);
        _assertRoundedOutputWaits(0);
    }

    /// @dev G18: as above at the 100 bp maximum, where the gross limit is tightened for the reward. There the reward
    /// and Metric's rounding together must still leave the makers their limit.
    function test_fillReward_hundredBasisPointsRefusesAnOutputRoundedBelowTheLimit() public {
        _createBook(100, 1);
        _assertRoundedOutputWaits(100);
    }

    // ---------------------------------------------------------------- G19: the next generation

    /// @dev G19: a bucket retires by a fill while a leg is still out and its prepaid premium is still vesting. Back on
    /// the waiting side, a deposit at the level opens a new bucket id priced fresh, as an empty bucket, with none of
    /// the old bucket's balances, debt, rate index or income. The leg's later repayment and premium land in the old
    /// bucket and reach its makers alone; the new maker takes back exactly what they put in. A generation that
    /// inherited any of these would hand one set of makers another's repayments or income.
    function test_nextGeneration_isPricedFreshAndLeavesTheOldBucketItsRepaymentsAndIncome() public {
        (uint256 oldBucketId, uint256 oldShares, uint256 positionId) = _retireWithDebtAndIncome();
        uint256 amount = 50_000e6;
        (uint256 newBucketId, uint256 newShares) = _depositIntoNextGeneration(oldBucketId, oldShares, amount);
        bytes32 newBucketBefore = keccak256(abi.encode(vault.bucketOf(vaultId, newBucketId)));
        Bucket memory oldBucketBefore = vault.bucketOf(vaultId, oldBucketId);
        (,,, uint256 income1Before) = vault.bookTotalsOf(vaultId);
        vm.warp(block.timestamp + 1 days);
        uint256 maximum1 = _repayInFull(positionId);
        Bucket memory oldBucketAfter = vault.bucketOf(vaultId, oldBucketId);
        (,,, uint256 income1After) = vault.bookTotalsOf(vaultId);
        assertEq(oldBucketAfter.lent, 0, "the old bucket's loan is repaid");
        assertEq(oldBucketAfter.balance1, oldBucketBefore.balance1 + maximum1, "the repayment lands in the old bucket");
        // The new bucket is untouched (below), so the premium the book gained went to the old bucket's makers.
        assertGt(income1After, income1Before, "and so does the leg's premium");
        assertEq(
            keccak256(abi.encode(vault.bucketOf(vaultId, newBucketId))), newBucketBefore, "the new bucket is untouched"
        );
        _assertIncomeStaysWithTheOldMakers(oldBucketId, newBucketId);
        _assertEachGenerationExitsWithItsOwn(oldBucketId, newBucketId, newShares, amount);
        assertLedger();
    }

    // ---------------------------------------------------------------- G7 helpers

    /// @dev A lender's capital in the pool, base above the cursor and quote below, and a passive long borrowing from
    /// it, so the passive vault has debts to keep.
    function _lendAndBorrowPassively() internal returns (uint256 passivePositionId) {
        deposit(lender, 200e18, 400_000e6);
        int24 tickLower = PRICE_TICK - 200;
        int24 tickUpper = PRICE_TICK - 100;
        OpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.tickLower = tickLower;
        request.tickUpper = tickUpper;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        request.liquidity = uint128(FullMath.mulDiv(10_000e6, 1 << 96, sqrtUpperX96 - sqrtLowerX96));
        request.collateral = 300e6;
        request.escrow = 100e6;
        vm.prank(trader);
        passivePositionId = vault.open(request);
        (DebtTotals memory longDebts,) = vault.debtsOf(vaultId);
        assertGt(longDebts.liquidity, 0, "the passive vault has debt");
        assertGt(vault.accrualOf(vaultId).outstanding1, 0, "and quote outstanding");
    }

    function _passive(uint256 passivePositionId) internal view returns (Passive memory snapshot) {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        snapshot.buffer0 = ledger.buffer0;
        snapshot.buffer1 = ledger.buffer1;
        snapshot.outstanding0 = vault.accrualOf(vaultId).outstanding0;
        snapshot.outstanding1 = vault.accrualOf(vaultId).outstanding1;
        (DebtTotals memory longDebts, DebtTotals memory shortDebts) = vault.debtsOf(vaultId);
        snapshot.debts = keccak256(abi.encode(longDebts, shortDebts, vault.accrualOf(vaultId)));
        snapshot.lenders = keccak256(
            abi.encode(
                vault.streamOf(vaultId),
                vault.totalSharesOf(vaultId),
                vault.sharesOf(vaultId, lender),
                vault.positionOf(passivePositionId)
            )
        );
        snapshot.binShares = _windowShares();
    }

    function _assertPassiveUnchanged(Passive memory before, uint256 passivePositionId) internal view {
        Passive memory afterwards = _passive(passivePositionId);
        assertEq(afterwards.buffer0, before.buffer0, "passive buffer0");
        assertEq(afterwards.buffer1, before.buffer1, "passive buffer1");
        assertEq(afterwards.outstanding0, before.outstanding0, "passive outstanding0");
        assertEq(afterwards.outstanding1, before.outstanding1, "passive outstanding1");
        assertEq(afterwards.debts, before.debts, "passive debt totals and accrual");
        assertEq(afterwards.lenders, before.lenders, "passive stream, shares and position");
        assertEq(
            keccak256(abi.encode(afterwards.binShares)),
            keccak256(abi.encode(before.binShares)),
            "the passive vault's pool shares"
        );
    }

    /// @dev The passive vault's shares in each bin of its window, read from the pool.
    function _windowShares() internal view returns (uint256[] memory shares) {
        Venue memory venue = vault.venueOf(vaultId);
        uint256 count = vault.parametersOf(vaultId).binCount;
        shares = new uint256[](count);
        // count <= MetricVenue.MAX_BINS
        for (uint256 offset = 0; offset < count; ++offset) {
            int16 binIndex = int16(int256(venue.lowestBin) + int256(offset));
            shares[offset] = MetricState.positionShares(address(pool), address(vault), uint80(vaultId), binIndex);
        }
    }

    /// @dev What the passive vault's pool position holds, from its shares and each bin's balances, in native units.
    function _poolHoldings() internal view returns (uint256 amount0, uint256 amount1) {
        Venue memory venue = vault.venueOf(vaultId);
        uint256 count = vault.parametersOf(vaultId).binCount;
        // count <= MetricVenue.MAX_BINS
        for (uint256 offset = 0; offset < count; ++offset) {
            int16 binIndex = int16(int256(venue.lowestBin) + int256(offset));
            uint256 ours = MetricState.positionShares(address(pool), address(vault), uint80(vaultId), binIndex);
            if (ours == 0) continue;
            MetricState.Bin memory state = MetricState.bin(address(pool), binIndex);
            amount0 += FullMath.mulDiv(ours, state.balance0Scaled, state.totalShares) / venue.scale0;
            amount1 += FullMath.mulDiv(ours, state.balance1Scaled, state.totalShares) / venue.scale1;
        }
    }

    /// @dev Re-reads the passive holdings through a lender-side call and compares them with the pool's shares.
    function _assertHoldingsMatchShares() internal {
        vault.recenter(vaultId);
        (uint256 amount0, uint256 amount1) = _poolHoldings();
        Venue memory venue = vault.venueOf(vaultId);
        assertEq(venue.holdings0, amount0, "cached base holdings match the pool's shares");
        assertEq(venue.holdings1, amount1, "cached quote holdings match the pool's shares");
    }

    function _custody() internal view returns (Custody memory snapshot) {
        snapshot.ledger = vault.ledgerOf(vaultId);
        (snapshot.book0, snapshot.book1, snapshot.income0, snapshot.income1) = vault.bookTotalsOf(vaultId);
        snapshot.vault0 = base.balanceOf(address(vault));
        snapshot.vault1 = quote.balanceOf(address(vault));
    }

    /// @dev A buy fill moves the book and custody by its net output and payment, and nothing else in the ledger.
    function _assertFillCustody(Custody memory before, uint256 netReceived, uint256 paid) internal view {
        Custody memory afterwards = _custody();
        assertEq(afterwards.book0, before.book0 + netReceived, "the book's base rose by the net output");
        assertEq(afterwards.book1, before.book1 - paid, "the book's quote fell by the payment");
        assertEq(afterwards.vault0, before.vault0 + netReceived, "custody's base rose by the net output alone");
        assertEq(afterwards.vault1, before.vault1 - paid, "custody's quote fell by the payment alone");
        assertEq(afterwards.ledger.held0, before.ledger.held0 + netReceived, "held0");
        assertEq(afterwards.ledger.held1, before.ledger.held1 - paid, "held1");
        assertEq(_otherParts(afterwards.ledger), _otherParts(before.ledger), "no other part of the ledger moved");
        assertEq(afterwards.income0, before.income0, "maker income0");
        assertEq(afterwards.income1, before.income1, "maker income1");
    }

    function _otherParts(Ledger memory ledger) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ledger.buffer0,
                ledger.buffer1,
                ledger.reserve0,
                ledger.reserve1,
                ledger.escrow,
                ledger.treasury0,
                ledger.treasury1,
                ledger.feeVault0,
                ledger.feeVault1
            )
        );
    }

    function _valueAt(uint256 amount0, uint256 amount1, uint256 wholePrice) internal pure returns (uint256) {
        return amount0 * wholePrice / 1e12 + amount1;
    }

    // ---------------------------------------------------------------- G18 helpers

    /// @dev Fills orders of three sizes on each side: tiny, middling and ordinary.
    function _fillLadder(uint256 rewardBps) internal {
        // About 87, 12,500 and 2.2 billion quote units out.
        uint256[3] memory sellAmounts = [uint256(4e10), 5.7e12, 1e18];
        // About 5e8, 5e10 and 5e17 base wei out.
        uint256[3] memory buyAmounts = [uint256(1), 99, 1_000e6];
        // 3 sizes per side
        for (uint256 index = 0; index < 3; ++index) {
            uint256 received = _fillAndCheck(SELL_LEVEL, false, sellAmounts[index], rewardBps);
            if (index == 0) assertLt(received * 100, BPS, "the tiny sell's output floors a 100 bp reward to zero");
            if (index == 1) assertGe(received * 100, BPS, "the middling sell's output earns a reward at 100 bp");
            _fillAndCheck(BUY_LEVEL, true, buyAmounts[index], rewardBps);
        }
    }

    /// @dev Deposits an order on the waiting side, moves the band past the level and fills it, then checks the keeper's
    /// reward, the makers' net and the level's limit.
    function _fillAndCheck(int24 level, bool isBuy, uint256 amount, uint256 rewardBps)
        internal
        returns (uint256 received)
    {
        _setPrice(2_000);
        (uint256 bucketId,) = _deposit(makerA, level, isBuy, amount);
        _setPrice(isBuy ? 1_850 : 2_200);
        IntegrationToken output = isBuy ? base : quote;
        uint256 keeperBefore = output.balanceOf(keeper);
        uint256 paid;
        vm.prank(keeper);
        (paid, received) = vault.fillBucket(vaultId, bucketId);
        uint256 reward = output.balanceOf(keeper) - keeperBefore;
        assertEq(reward, received * rewardBps / BPS, "the keeper's reward is the floor of its share");
        assertLe(reward * BPS, received * rewardBps, "never rounded up");
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        uint256 netReceived = isBuy ? bucket.balance0 : bucket.balance1;
        assertEq(netReceived, received - reward, "the makers keep the rest of the output");
        assertEq(isBuy ? bucket.balance1 : bucket.balance0, amount - paid, "the unfilled rest waits");
        assertGt(paid, 0, "something filled");
        _assertMeetsLimit(level, isBuy, paid, netReceived);
        assertLedger();
    }

    /// @dev A billion wei of base is worth about 2.2 quote units at 2,200: Metric pays 2, under the 3 the level's top
    /// requires once its 2.13 is rounded up, so the fill reverts. Twenty billion more wei fill the bucket's whole
    /// balance, the refused billion included, at no less than the top.
    function _assertRoundedOutputWaits(uint256 rewardBps) internal {
        (uint256 bucketId,) = _deposit(makerA, SELL_LEVEL, false, 1e9);
        _setPrice(2_200);
        vm.prank(keeper);
        vm.expectRevert(IMetricLendingVault.SlippageExceeded.selector);
        vault.fillBucket(vaultId, bucketId);
        _setPrice(2_000);
        (uint256 sameBucketId,) = _deposit(makerA, SELL_LEVEL, false, 2e10);
        assertEq(sameBucketId, bucketId, "the next deposit joins it");
        _setPrice(2_200);
        vm.prank(keeper);
        (uint256 paid, uint256 received) = vault.fillBucket(vaultId, bucketId);
        assertEq(paid, 2.1e10, "the whole bucket filled");
        uint256 reward = received * rewardBps / BPS;
        assertEq(quote.balanceOf(keeper), reward, "the keeper's reward is the floor of its share");
        assertEq(vault.bucketOf(vaultId, bucketId).balance1, received - reward, "the makers keep the rest");
        _assertMeetsLimit(SELL_LEVEL, false, paid, received - reward);
        assertLedger();
    }

    /// @dev The level's limit, recomputed exactly: a buy's net base at the level's bottom covers what it paid; a sell's
    /// net quote covers its base at the level's top.
    function _assertMeetsLimit(int24 level, bool isBuy, uint256 paid, uint256 netReceived) internal pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, LEVEL_TICKS);
        if (isBuy) {
            uint256 worth = FullMath.mulDiv(netReceived, uint256(sqrtLowerX96) * sqrtLowerX96, Q192);
            assertGe(worth, paid, "a buy pays at most the level's bottom, net of the reward");
            return;
        }
        uint256 owed = FullMath.mulDivRoundingUp(paid, uint256(sqrtUpperX96) * sqrtUpperX96, Q192);
        assertGe(netReceived, owed, "a sell receives at least the level's top, net of the reward");
    }

    // ---------------------------------------------------------------- G19 helpers

    /// @dev Maker A's bucket lends a leg whose prepaid floor vests to A, then fills and retires with the leg still out.
    function _retireWithDebtAndIncome() internal returns (uint256 bucketId, uint256 shares, uint256 positionId) {
        _createBook(5, 100e6);
        (bucketId, shares) = _deposit(makerA, BUY_LEVEL, true, 50_000e6);
        assertEq(shares, 50_000e6 * FRESH_SHARES_PER_UNIT, "the first generation's price");
        positionId = _openLong(bucketId, _liquidityOn(BUY_LEVEL, 10_000e6), 50e6, 2_000e6, 0);
        vm.warp(block.timestamp + 1 hours);
        _setPrice(1_900);
        vm.prank(keeper);
        vault.fillBucket(vaultId, bucketId);
        Bucket memory retired = vault.bucketOf(vaultId, bucketId);
        assertTrue(retired.retired, "retired");
        assertGt(retired.lent, 0, "with a loan out");
        assertGt(retired.stream1Remaining, 0, "and income vesting");
        assertGt(retired.rateIndexRay, 0, "and a rate index of its own");
    }

    /// @dev Past the level no deposit is taken; back on the waiting side one opens the next generation, priced as an
    /// empty bucket however much the retired one holds, owes or is owed.
    function _depositIntoNextGeneration(uint256 oldBucketId, uint256 oldShares, uint256 amount)
        internal
        returns (uint256 newBucketId, uint256 newShares)
    {
        vm.prank(makerB);
        vm.expectRevert(IMakerBook.WrongSideOfPrice.selector);
        vault.depositOrder(vaultId, BUY_LEVEL, true, amount, 0, makerB);
        _setPrice(2_000);
        bytes32 oldBucketBefore = keccak256(abi.encode(vault.bucketOf(vaultId, oldBucketId)));
        (newBucketId, newShares) = _deposit(makerB, BUY_LEVEL, true, amount);
        (int24 level, bool isBuy, uint32 generation) = MakerMath.decode(newBucketId);
        (,, uint32 oldGeneration) = MakerMath.decode(oldBucketId);
        assertTrue(newBucketId != oldBucketId, "a new bucket id");
        assertEq(newBucketId, vault.currentBucketOf(vaultId, BUY_LEVEL, true), "the level's current bucket");
        assertEq(level, BUY_LEVEL, "the same level");
        assertTrue(isBuy, "the same side");
        assertEq(generation, oldGeneration + 1, "the next generation");
        assertEq(newShares, amount * FRESH_SHARES_PER_UNIT, "priced as an empty bucket");
        assertEq(newShares, oldShares, "as the first generation was, for the same amount");
        _assertFresh(vault.bucketOf(vaultId, newBucketId), newShares, amount);
        assertEq(
            keccak256(abi.encode(vault.bucketOf(vaultId, oldBucketId))), oldBucketBefore, "the old bucket is untouched"
        );
    }

    function _assertFresh(Bucket memory bucket, uint256 shares, uint256 amount) internal view {
        assertFalse(bucket.retired, "active");
        assertEq(bucket.totalShares, shares, "only the new maker's shares");
        assertEq(bucket.balance1, amount, "only the new maker's quote");
        assertEq(bucket.balance0, 0, "none of the old bucket's base");
        assertEq(bucket.lent, 0, "none of its debt");
        assertEq(bucket.rateIndexRay, 0, "a rate index from zero");
        assertEq(bucket.stream0Remaining, 0, "none of its base income");
        assertEq(bucket.stream1Remaining, 0, "none of its quote income");
        assertEq(bucket.income0PerShareX128, 0, "no base income released");
        assertEq(bucket.income1PerShareX128, 0, "no quote income released");
        assertEq(bucket.updatedAt, block.timestamp, "started now");
        assertEq(bucket.curveVersion, vault.bookCurvesOf(vaultId).length - 1, "on the current curve");
    }

    /// @dev Above the level the leg holds token1, so the trader repays its `M1` in token1.
    function _repayInFull(uint256 positionId) internal returns (uint256 maximum1) {
        maximum1 = vault.legOf(positionId, 0).maximum1;
        uint256[] memory repay0 = new uint256[](1);
        uint256[] memory repay1 = new uint256[](1);
        repay1[0] = maximum1;
        MakerCloseRequest memory request =
            MakerCloseRequest({positionId: positionId, fractionWad: 1e18, repay0: repay0, repay1: repay1});
        vm.prank(trader);
        vault.closeMaker(request);
    }

    /// @dev Once it vests, the old bucket's income all goes to its maker; the new bucket's maker has none to claim.
    function _assertIncomeStaysWithTheOldMakers(uint256 oldBucketId, uint256 newBucketId) internal {
        vm.warp(block.timestamp + 2 days);
        (,,, uint256 income1Before) = vault.bookTotalsOf(vaultId);
        assertGt(income1Before, 0, "income to pay");
        vm.prank(makerB);
        vm.expectRevert(IMetricLendingVault.ZeroAmount.selector);
        vault.claimOrderIncome(vaultId, newBucketId, makerB);
        vm.prank(makerA);
        (, uint256 claimed1) = vault.claimOrderIncome(vaultId, oldBucketId, makerA);
        (,,, uint256 income1After) = vault.bookTotalsOf(vaultId);
        assertEq(income1After, income1Before - claimed1, "claimed from the book's income");
        assertLe(income1After, 2, "the old maker took it all, up to release rounding");
        assertEq(vault.makerShareOf(vaultId, oldBucketId, makerB).shares, 0, "the new maker owns none of the old");
        assertEq(vault.makerShareOf(vaultId, newBucketId, makerA).shares, 0, "the old maker owns none of the new");
        vm.prank(makerB);
        vm.expectRevert(IMetricLendingVault.InsufficientShares.selector);
        vault.withdrawOrder(vaultId, oldBucketId, 1, 0, 0, makerB);
    }

    /// @dev Each maker leaves with their own generation's tokens: the old maker the fill's base and the repayment, the
    /// new maker exactly their deposit.
    function _assertEachGenerationExitsWithItsOwn(
        uint256 oldBucketId,
        uint256 newBucketId,
        uint256 newShares,
        uint256 amount
    ) internal {
        Bucket memory oldBucket = vault.bucketOf(vaultId, oldBucketId);
        uint256 oldShares = vault.makerShareOf(vaultId, oldBucketId, makerA).shares;
        vm.prank(makerA);
        (uint256 oldAmount0, uint256 oldAmount1,) = vault.withdrawOrder(vaultId, oldBucketId, oldShares, 0, 0, makerA);
        assertEq(oldAmount0, oldBucket.balance0, "the old maker takes the fill's base");
        assertEq(oldAmount1, oldBucket.balance1, "and the repayment");
        vm.prank(makerB);
        (uint256 newAmount0, uint256 newAmount1,) = vault.withdrawOrder(vaultId, newBucketId, newShares, 0, 0, makerB);
        assertEq(newAmount0, 0, "the new maker takes no base");
        assertEq(newAmount1, amount, "and exactly their deposit");
    }

    // ---------------------------------------------------------------- shared helpers

    function _createBook(uint16 fillRewardBps, uint96 minimumNotional) internal {
        BookSettings memory settings;
        settings.levelTicks = LEVEL_TICKS;
        settings.utilizationCeilingBps = 9_000;
        settings.fillRewardBps = fillRewardBps;
        settings.graceSeconds = 1 hours;
        settings.minimumEscrowSeconds = 3 days;
        settings.minimumChargeSeconds = 2 days;
        settings.minimumNotional = minimumNotional;
        FloorRow[] memory rows = new FloorRow[](3);
        rows[0] = FloorRow({minimumDistanceBps: 1_500, rateBps: 5_000});
        rows[1] = FloorRow({minimumDistanceBps: 400, rateBps: 14_000});
        rows[2] = FloorRow({minimumDistanceBps: 0, rateBps: 25_000});
        Curve memory curve = Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0.05e18, slope2Wad: 12e18});
        vm.prank(owner);
        vault.createBook(vaultId, settings, curve, rows);
    }

    function _fundMaker(address maker) internal {
        base.mint(maker, 1e24);
        quote.mint(maker, 1e14);
        vm.startPrank(maker);
        base.approve(address(vault), type(uint256).max);
        quote.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address maker, int24 level, bool isBuy, uint256 amount)
        internal
        returns (uint256 bucketId, uint256 shares)
    {
        vm.prank(maker);
        return vault.depositOrder(vaultId, level, isBuy, amount, 0, maker);
    }

    function _setPrice(uint256 wholePrice) internal {
        provider.set(uint128(wholePrice * Q64), HALF_SPREAD_E5);
    }

    function _liquidityOn(int24 level, uint256 amount1) internal pure returns (uint128) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, LEVEL_TICKS);
        return uint128(FullMath.mulDiv(amount1, 1 << 96, sqrtUpperX96 - sqrtLowerX96));
    }

    function _openLong(uint256 bucketId, uint128 liquidity, uint128 collateral, uint128 escrow, uint256 entryAmountIn)
        internal
        returns (uint256)
    {
        MakerOpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.legs = new LegRequest[](1);
        request.legs[0] = LegRequest({bucketId: bucketId, liquidity: liquidity});
        request.collateral = collateral;
        request.escrow = escrow;
        request.entryAmountIn = entryAmountIn;
        request.maximumRateBps = type(uint256).max;
        vm.prank(trader);
        return vault.openMaker(request);
    }
}
