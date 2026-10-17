// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {
    BookSettings,
    Bucket,
    FloorRow,
    LegRequest,
    MakerCloseRequest,
    MakerOpenRequest,
    MakerPosition
} from "vault/MakerTypes.sol";
import {IMakerBook} from "vault/interfaces/IMakerBook.sol";
import {MakerMath} from "vault/libraries/MakerMath.sol";
import {Curve, VaultMath} from "vault/libraries/VaultMath.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice The maker book against Metric's own pool: oracle-gated fills at the makers' limit with the keeper's reward,
/// generations retiring, and a multi-leg force close buying its shortfall through the pool.
contract MakerFillsTest is MetricFixture {
    uint24 internal constant LEVEL_TICKS = 100;
    /// @dev About 1,943–1,962: below the 2,000 price.
    int24 internal constant BUY_LEVEL = -2_006;
    /// @dev About 2,038–2,059: above it.
    int24 internal constant SELL_LEVEL = -1_998;

    address internal makerA = makeAddr("makerA");
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        base.mint(makerA, 1e24);
        quote.mint(makerA, 1e14);
        vm.startPrank(makerA);
        base.approve(address(vault), type(uint256).max);
        quote.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(owner);
        vault.createBook(vaultId, _settings(), _curve(), _floors());
    }

    // ---------------------------------------------------------------- fills

    /// @dev Once the price has passed a buy level, a keeper fills its USD into base at no more than the level's
    /// bottom, takes 5 bp of the output, and the bucket retires so deposits open the next generation.
    function test_fill_buyLevelAtOrBelowItsBottom() public {
        (uint256 bucketId,) = _deposit(BUY_LEVEL, true, 50_000e6);
        _setPrice(1_900);
        vm.prank(keeper);
        (uint256 paid, uint256 received) = vault.fillBucket(vaultId, bucketId);
        assertEq(paid, 50_000e6, "the whole order filled");
        uint256 reward = received * 5 / 10_000;
        assertEq(base.balanceOf(keeper), reward, "keeper's 5 bp of the output");
        (uint160 sqrtLowerX96,) = MakerMath.levelRange(BUY_LEVEL, LEVEL_TICKS);
        assertGe(VaultMath.priceTimes(received - reward, sqrtLowerX96, false), paid, "makers paid at most the bottom");
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        assertTrue(bucket.retired, "retired");
        assertEq(bucket.balance1, 0);
        assertEq(bucket.balance0, received - reward);
        assertTrue(vault.currentBucketOf(vaultId, BUY_LEVEL, true) != bucketId, "next generation takes deposits");
        assertLedger();
    }

    function test_fill_sellLevelAtOrAboveItsTop() public {
        (uint256 bucketId,) = _deposit(SELL_LEVEL, false, 20e18);
        _setPrice(2_150);
        vm.prank(keeper);
        (uint256 paid, uint256 received) = vault.fillBucket(vaultId, bucketId);
        assertEq(paid, 20e18, "the whole order filled");
        uint256 reward = received * 5 / 10_000;
        (, uint160 sqrtUpperX96) = MakerMath.levelRange(SELL_LEVEL, LEVEL_TICKS);
        assertGe(received - reward, VaultMath.priceTimes(paid, sqrtUpperX96, true), "makers sold at least at the top");
        assertTrue(vault.bucketOf(vaultId, bucketId).retired);
        assertLedger();
    }

    /// @dev A band past the level is not enough when the pool's own price, fees included, is above the makers'
    /// limit: the pool stops at the limit with nothing filled and refuses the swap, so nothing changes.
    function test_fill_neverPaysAboveTheLimit() public {
        (uint256 bucketId,) = _deposit(BUY_LEVEL, true, 50_000e6);
        (uint160 sqrtLowerX96,) = MakerMath.levelRange(BUY_LEVEL, LEVEL_TICKS);
        // The reference just under the level's bottom: the ask is past it, Metric's buy price with fees is not.
        uint256 bottom = FullMath.mulDiv(uint256(sqrtLowerX96) * sqrtLowerX96, 1e12, 1 << 192);
        _setPrice(bottom - 1);
        vm.prank(keeper);
        vm.expectRevert(bytes4(keccak256("FinalAmountIsZero()")));
        vault.fillBucket(vaultId, bucketId);
        assertEq(vault.bucketOf(vaultId, bucketId).balance1, 50_000e6, "nothing filled");
    }

    /// @dev An order larger than the pool's depth below the makers' limit fills in part. The part stands, the bucket
    /// retires, and the rest waits for a residual fill once the price falls far enough to bring more depth under it.
    function test_fill_partialFillStandsAndTheRestFillsLater() public {
        uint256 amount = 1_000_000e6;
        (uint256 bucketId,) = _deposit(BUY_LEVEL, true, amount);
        _setPrice(1_900);
        vm.prank(keeper);
        (uint256 paid, uint256 received) = vault.fillBucket(vaultId, bucketId);
        assertGt(paid, 0, "filled in part");
        assertLt(paid, amount, "not in full");
        (uint160 sqrtLowerX96,) = MakerMath.levelRange(BUY_LEVEL, LEVEL_TICKS);
        uint256 reward = received * 5 / 10_000;
        assertGe(VaultMath.priceTimes(received - reward, sqrtLowerX96, false), paid, "makers paid at most the bottom");
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        assertTrue(bucket.retired, "a partial fill retires the bucket");
        assertEq(bucket.balance1, amount - paid, "the rest waits");
        assertLedger();

        _setPrice(1_850);
        vm.prank(keeper);
        (uint256 residualPaid,) = vault.fillBucket(vaultId, bucketId);
        assertGt(residualPaid, 0, "a residual fill on the retired bucket");
        assertEq(vault.bucketOf(vaultId, bucketId).balance1, amount - paid - residualPaid);
        assertLedger();
    }

    function test_fill_refusedBeforeThePricePassesTheLevel() public {
        (uint256 bucketId,) = _deposit(BUY_LEVEL, true, 50_000e6);
        vm.prank(keeper);
        vm.expectRevert(IMakerBook.NotFillable.selector);
        vault.fillBucket(vaultId, bucketId);
    }

    /// @dev Lent capital stays lent through a fill: the repayment later lands in the retired generation.
    function test_fill_leavesLentCapitalLentAndRetiredBucketsTakeRepayment() public {
        (uint256 bucketId,) = _deposit(BUY_LEVEL, true, 50_000e6);
        uint128 liquidity = _liquidityOn(BUY_LEVEL, 10_000e6);
        uint256 positionId = _openLong(bucketId, liquidity, 50e6, 2_000e6);
        _setPrice(1_900);
        vm.prank(keeper);
        vault.fillBucket(vaultId, bucketId);
        assertGt(vault.bucketOf(vaultId, bucketId).lent, 0, "the loan stays");
        // Back above the level, the trader repays in token1.
        _setPrice(2_000);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(BUY_LEVEL, LEVEL_TICKS);
        (, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        uint256[] memory repay0 = new uint256[](1);
        uint256[] memory repay1 = new uint256[](1);
        repay1[0] = maximum1;
        vm.prank(trader);
        vault.closeMaker(_closeRequest(positionId, repay0, repay1));
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        assertEq(bucket.lent, 0);
        assertGe(bucket.balance1, maximum1 - 1, "the repayment sits in the retired generation");
        assertLedger();
    }

    /// @dev A retired bucket takes no deposits, so its makers own it exactly: once its loans are repaid, its last
    /// maker withdraws every token, and the income still vesting goes to the treasury.
    function test_fill_retiredBucketPaysItsLastMakerInFull() public {
        (uint256 bucketId, uint256 shares) = _deposit(BUY_LEVEL, true, 50_000e6);
        uint128 liquidity = _liquidityOn(BUY_LEVEL, 10_000e6);
        uint256 positionId = _openLong(bucketId, liquidity, 50e6, 2_000e6);
        _setPrice(1_900);
        vm.prank(keeper);
        vault.fillBucket(vaultId, bucketId);
        _setPrice(2_000);
        vm.warp(block.timestamp + 5 days);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(BUY_LEVEL, LEVEL_TICKS);
        (, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        uint256[] memory repay0 = new uint256[](1);
        uint256[] memory repay1 = new uint256[](1);
        repay1[0] = maximum1;
        vm.prank(trader);
        vault.closeMaker(_closeRequest(positionId, repay0, repay1));
        Bucket memory before = vault.bucketOf(vaultId, bucketId);
        assertGt(before.stream1Remaining, 0, "premium still vesting");
        uint256 treasuryBefore = vault.ledgerOf(vaultId).treasury1;
        vm.prank(makerA);
        (uint256 amount0, uint256 amount1,) = vault.withdrawOrder(vaultId, bucketId, shares, 0, 0, makerA);
        assertEq(amount0, before.balance0, "every unit of token0");
        assertEq(amount1, before.balance1, "every unit of token1");
        Bucket memory afterwards = vault.bucketOf(vaultId, bucketId);
        assertEq(afterwards.totalShares, 0);
        assertEq(afterwards.stream1Remaining, 0);
        assertEq(
            vault.ledgerOf(vaultId).treasury1 - treasuryBefore, before.stream1Remaining, "unvested to the treasury"
        );
        assertLedger();
    }

    // ---------------------------------------------------------------- force close through the pool

    /// @dev A two-leg long holding only USD, after the price falls through both levels, repays by buying exactly the
    /// base its legs need through Metric.
    function test_forceClose_buysTheShortfallThroughThePool() public {
        (uint256 first,) = _deposit(BUY_LEVEL, true, 30_000e6);
        (uint256 second,) = _deposit(BUY_LEVEL - 1, true, 30_000e6);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = first < second ? (first, second) : (second, first);
        MakerOpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.legs = new LegRequest[](2);
        request.legs[0] = LegRequest({bucketId: ids[0], liquidity: _liquidityOf(ids[0], 5_000e6)});
        request.legs[1] = LegRequest({bucketId: ids[1], liquidity: _liquidityOf(ids[1], 5_000e6)});
        request.collateral = 300e6;
        // Two days of these levels' 250% floor prepaid and about a day more: the open's minimum, soon outrun.
        request.escrow = 220e6;
        request.maximumRateBps = type(uint256).max;
        vm.prank(trader);
        uint256 positionId = vault.openMaker(request);
        _setPrice(1_900);
        vm.warp(block.timestamp + 20 days);
        vault.flagMaker(positionId);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 poolBaseBefore = base.balanceOf(address(pool));
        vm.prank(closer);
        vault.forceCloseMaker(positionId);
        assertLt(base.balanceOf(address(pool)), poolBaseBefore, "bought base from the pool");
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed");
        assertEq(vault.bucketOf(vaultId, ids[0]).lent, 0);
        assertEq(vault.bucketOf(vaultId, ids[1]).lent, 0);
        assertGt(vault.bucketOf(vaultId, ids[0]).balance0, 0, "repaid in base");
        assertLedger();
    }

    // ---------------------------------------------------------------- closing

    /// @dev Sol's finding: a partial close small enough that a fraction of the leg's `M1` rounds to zero still closes
    /// liquidity and can owe a profit share. The makers' part must land in the ledger, so the closed part's extremes
    /// come from its own liquidity. A long bought into token0 at 2,000 and marked at 200,000 makes the tiny part win.
    function test_closeMaker_tinyPartialKeepsTheProfitShareInTheLedger() public {
        (uint256 bucketId,) = _deposit(BUY_LEVEL, true, 50_000e6);
        MakerOpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.legs = new LegRequest[](1);
        request.legs[0] = LegRequest({bucketId: bucketId, liquidity: _liquidityOn(BUY_LEVEL, 5_000e6)});
        request.collateral = 10_000e6;
        request.escrow = 2_000e6;
        request.entryAmountIn = 5_000e6;
        request.maximumRateBps = type(uint256).max;
        vm.prank(trader);
        uint256 positionId = vault.openMaker(request);
        _setPrice(200_000);
        // 1.5e-10 of a leg worth about 5,000: its `M1` part rounds to zero, its liquidity part does not.
        uint256 fractionWad = 1.5e8;
        assertEq(VaultMath.portionDown(vault.makerPositionOf(positionId).maximum1, fractionWad), 0);
        uint256[] memory repay0 = new uint256[](1);
        uint256[] memory repay1 = new uint256[](1);
        // The band is above the level, so the closed part holds token1, under one unit of it.
        repay1[0] = 1;
        (,, uint256 income0Before, uint256 income1Before) = vault.bookTotalsOf(vaultId);
        vm.prank(trader);
        vault.closeMaker(
            MakerCloseRequest({positionId: positionId, fractionWad: fractionWad, repay0: repay0, repay1: repay1})
        );
        (,, uint256 income0After, uint256 income1After) = vault.bookTotalsOf(vaultId);
        assertGt(income0After + income1After, income0Before + income1Before, "the makers' part reached the bucket");
        assertLedger();
    }

    // ---------------------------------------------------------------- helpers

    function _settings() internal pure returns (BookSettings memory settings) {
        settings.levelTicks = LEVEL_TICKS;
        settings.utilizationCeilingBps = 9_000;
        settings.fillRewardBps = 5;
        settings.graceSeconds = 1 hours;
        settings.minimumEscrowSeconds = 3 days;
        settings.minimumChargeSeconds = 2 days;
        settings.minimumNotional = 100e6;
    }

    function _curve() internal pure returns (Curve memory) {
        return Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0.05e18, slope2Wad: 12e18});
    }

    function _floors() internal pure returns (FloorRow[] memory rows) {
        rows = new FloorRow[](3);
        rows[0] = FloorRow({minimumDistanceBps: 1_500, rateBps: 5_000});
        rows[1] = FloorRow({minimumDistanceBps: 400, rateBps: 14_000});
        rows[2] = FloorRow({minimumDistanceBps: 0, rateBps: 25_000});
    }

    function _deposit(int24 level, bool isBuy, uint256 amount) internal returns (uint256 bucketId, uint256 shares) {
        vm.prank(makerA);
        return vault.depositOrder(vaultId, level, isBuy, amount, 0, makerA);
    }

    function _setPrice(uint256 wholePrice) internal {
        provider.set(uint128(wholePrice * Q64), HALF_SPREAD_E5);
    }

    function _liquidityOn(int24 level, uint256 amount1) internal pure returns (uint128) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, LEVEL_TICKS);
        return uint128(FullMath.mulDiv(amount1, 1 << 96, sqrtUpperX96 - sqrtLowerX96));
    }

    function _liquidityOf(uint256 bucketId, uint256 amount1) internal pure returns (uint128) {
        (int24 level,,) = MakerMath.decode(bucketId);
        return _liquidityOn(level, amount1);
    }

    function _openLong(uint256 bucketId, uint128 liquidity, uint128 collateral, uint128 escrow)
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
        request.maximumRateBps = type(uint256).max;
        vm.prank(trader);
        return vault.openMaker(request);
    }

    function _closeRequest(uint256 positionId, uint256[] memory repay0, uint256[] memory repay1)
        internal
        pure
        returns (MakerCloseRequest memory request)
    {
        request.positionId = positionId;
        request.fractionWad = 1e18;
        request.repay0 = repay0;
        request.repay1 = repay1;
    }
}
