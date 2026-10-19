// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Bucket, MakerCloseRequest, MakerOpenRequest} from "../../src/metric/vault/MakerTypes.sol";
import {CloseRequest, ExitSwap, OpenRequest, Position} from "../../src/metric/vault/VaultTypes.sol";
import {IMakerBook} from "../../src/metric/vault/interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {MakerFixture} from "./utils/MakerFixture.sol";
import {RateVenue, RouteVenue} from "./utils/RouteVenue.sol";

/// @notice The rest of "any venue": a close may swap part of its closed reserves through the venue the trader names
/// before repaying, in both books; a keeper may name the venue for a force close's shortfall swap or a fill. All on a
/// vault without a pool, where none of these could swap before.
contract ExitAndKeeperVenueTest is MakerFixture {
    uint256 internal constant NOTIONAL = 20_000e6;
    uint256 internal constant Q192 = 1 << 192;
    bytes32 internal constant CLOSED_TOPIC = keccak256("Closed(uint256,uint256,uint256,uint256,uint256)");
    int24 internal constant LEVEL_BUY = -2_014;
    /// @dev Above the price: ticks [-199,400, -199,300).
    int24 internal constant LEVEL_SELL = -1_994;

    RouteVenue internal venue;
    RateVenue internal rateVenue;

    function setUp() public override {
        super.setUp();
        venue = new RouteVenue();
        rateVenue = new RateVenue();
        base.mint(address(venue), 1e30);
        quote.mint(address(venue), 1e30);
        base.mint(address(rateVenue), 1e30);
        quote.mint(address(rateVenue), 1e30);
        deposit(lender, 200e18, 400_000e6);
    }

    // ---------------------------------------------------------------- prices and routes

    function _atAsk(uint256 amount1) internal view returns (uint256) {
        uint160 sqrtAskX96 = source.sqrtAskX96();
        return FullMath.mulDiv(FullMath.mulDiv(amount1, 1 << 96, sqrtAskX96), 1 << 96, sqrtAskX96);
    }

    function _atBid(uint256 amount0) internal view returns (uint256) {
        return VaultMath.priceTimes(amount0, source.sqrtBidX96(), false);
    }

    /// @dev A rate route buying token0 at the ask times `priceBps` / 10,000 (above 10,000 pays more per token0).
    function _buyRoute(uint256 priceBps) internal view returns (bytes memory) {
        uint256 sqrtAskX96 = source.sqrtAskX96();
        return abi.encode(Q192 * 10_000, sqrtAskX96 * sqrtAskX96 * priceBps);
    }

    /// @dev A rate route selling token0 at the bid times `priceBps` / 10,000 (under 10,000 receives less).
    function _sellRoute(uint256 priceBps) internal view returns (bytes memory) {
        uint256 sqrtBidX96 = source.sqrtBidX96();
        return abi.encode(sqrtBidX96 * sqrtBidX96 * priceBps, Q192 * 10_000);
    }

    function _closedShare() internal returns (uint256 share) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        // every log of the close
        for (uint256 index = 0; index < entries.length; ++index) {
            if (entries[index].topics[0] != CLOSED_TOPIC) continue;
            (,,, share) = abi.decode(entries[index].data, (uint256, uint256, uint256, uint256));
        }
    }

    // ---------------------------------------------------------------- positions

    /// @dev A long below the price that bought base with its whole release and collateral through a venue: it holds
    /// only base.
    function _openBaseLong(uint128 collateral) internal returns (uint256 positionId) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, NOTIONAL), collateral);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(lower, upper);
        (, uint256 release1) = VaultMath.releaseAcrossBand(
            request.liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96(), source.sqrtAskX96()
        );
        uint256 amountIn = release1 + collateral;
        request.entryAmountIn = amountIn;
        request.entryVenue = address(venue);
        request.entryRoute = abi.encode(amountIn, _atAsk(amountIn));
        positionId = open(request);
        assertEq(vault.positionOf(positionId).reserve1, 0, "holds only base");
    }

    /// @dev Sells `amountIn` of base through the route venue, the venue paying `fillBps` of a fair fill at the bid.
    function _sellBase(uint256 amountIn, uint256 fillBps) internal view returns (ExitSwap memory exit) {
        exit.zeroForOne = true;
        exit.amountIn = amountIn;
        exit.venue = address(venue);
        exit.route = abi.encode(amountIn, _atBid(amountIn) * fillBps / 10_000);
    }

    function _closeAfterSwap(uint256 positionId, uint256 fractionWad, uint256 repay1, ExitSwap memory exit)
        internal
        returns (uint256 paid0, uint256 paid1, uint256 share)
    {
        return _closeAfterSwap(positionId, fractionWad, repay1, exit, 0);
    }

    function _closeAfterSwap(
        uint256 positionId,
        uint256 fractionWad,
        uint256 repay1,
        ExitSwap memory exit,
        uint256 repay0
    ) internal returns (uint256 paid0, uint256 paid1, uint256 share) {
        CloseRequest memory request = CloseRequest({
            positionId: positionId, fractionWad: fractionWad, repay0: repay0, repay1: repay1
        });
        vm.recordLogs();
        vm.prank(trader);
        (paid0, paid1) = vault.closeAfterSwap(request, exit);
        share = _closedShare();
    }

    // ---------------------------------------------------------------- exit swaps

    /// @dev A long holding only base leaves with only token1: the close sells its base through a venue, repays in
    /// token1 and pays the rest out.
    function test_close_exitSwapLeavesWithTheTokenTheTraderWants() public {
        uint256 positionId = _openBaseLong(2_000e6);
        Position memory position = vault.positionOf(positionId);
        uint256 baseBefore = base.balanceOf(trader);
        (uint256 paid0, uint256 paid1,) =
            _closeAfterSwap(positionId, 1e18, position.maximum1 + 1, _sellBase(position.reserve0, 10_000));
        assertEq(paid0, 0, "no base out");
        assertGt(paid1, 0, "token1 out");
        assertEq(base.balanceOf(trader), baseBefore);
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertLedger();
    }

    /// @dev A poor exit fill does not lower the profit share: what it lost against the band is counted back into the
    /// proceeds, so the share is that of a fair fill, and the trader's payout is short by what the venue kept.
    function test_close_poorExitFillOwesTheFairFillsShare() public {
        uint256 positionId = _openBaseLong(2_000e6);
        setPrice(PRICE_TICK + 953, 1);
        Position memory position = vault.positionOf(positionId);
        uint256 snapshot = vm.snapshotState();
        (, uint256 fairPaid1, uint256 fairShare) =
            _closeAfterSwap(positionId, 1e18, position.maximum1 + 1, _sellBase(position.reserve0, 10_000));
        vm.revertToState(snapshot);
        (, uint256 poorPaid1, uint256 poorShare) =
            _closeAfterSwap(positionId, 1e18, position.maximum1 + 1, _sellBase(position.reserve0, 9_000));
        assertGt(fairShare, 0, "a winning close owes a share");
        assertApproxEqAbs(poorShare, fairShare, 2, "the same share");
        uint256 kept = _atBid(position.reserve0) / 10;
        assertApproxEqAbs(fairPaid1 - poorPaid1, kept, 2, "the trader bears what the venue kept");
        assertLedger();
    }

    /// @dev On a partial close the swap moves only the closed part: the rest of the position keeps its reserves.
    function test_close_partialExitSwapLeavesTheRestUntouched() public {
        uint256 positionId = _openBaseLong(2_000e6);
        Position memory before = vault.positionOf(positionId);
        uint256 closed0 = VaultMath.portionDown(before.reserve0, 0.5e18);
        _closeAfterSwap(positionId, 0.5e18, before.maximum1 / 2 + 2, _sellBase(closed0, 10_000));
        Position memory remaining = vault.positionOf(positionId);
        assertEq(remaining.reserve0, before.reserve0 - closed0, "the unclosed base untouched");
        assertEq(remaining.reserve1, 0, "and no token1 added to it");
        assertLedger();
    }

    /// @dev The swap is valued at the close band, so it needs one; a close without a swap needs no price.
    function test_close_exitSwapNeedsAPriceAPlainCloseDoesNot() public {
        uint256 positionId = _openBaseLong(2_000e6);
        Position memory position = vault.positionOf(positionId);
        ExitSwap memory exit = _sellBase(position.reserve0, 10_000);
        source.setBroken(true);
        CloseRequest memory request =
            CloseRequest({positionId: positionId, fractionWad: 1e18, repay0: 0, repay1: position.maximum1 + 1});
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.InvalidBand.selector);
        vault.closeAfterSwap(request, exit);
        closeFull(positionId, position.maximum0 + 1, 0);
        assertEq(vault.positionOf(positionId).owner, address(0), "closed without a price");
        assertLedger();
    }

    function test_close_exitSwapSellsNoMoreThanTheClosedPart() public {
        uint256 positionId = _openBaseLong(2_000e6);
        Position memory position = vault.positionOf(positionId);
        uint256 closed0 = VaultMath.portionDown(position.reserve0, 0.5e18);
        CloseRequest memory request =
            CloseRequest({positionId: positionId, fractionWad: 0.5e18, repay0: 0, repay1: position.maximum1});
        ExitSwap memory exit = _sellBase(closed0 + 1, 10_000);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.closeAfterSwap(request, exit);
    }

    /// @dev The maker book's close swaps the same way; each leg is repaid from the closed part as the swap left it.
    function test_closeMaker_exitSwap() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_BUY, 100_000e6);
        MakerOpenRequest memory request =
            makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_BUY, 10_000e6)), 3_000e6);
        request.entryAmountIn = 10_000e6;
        request.entryVenue = address(venue);
        request.entryRoute = abi.encode(uint256(10_000e6), _atAsk(10_000e6));
        uint256 positionId = openMaker(request);
        uint256 reserve0 = vault.makerPositionOf(positionId).reserve0;
        uint256[] memory repay0 = new uint256[](1);
        uint256[] memory repay1 = single(vault.legOf(positionId, 0).maximum1 + 1);
        MakerCloseRequest memory close =
            MakerCloseRequest({positionId: positionId, fractionWad: 1e18, repay0: repay0, repay1: repay1});
        ExitSwap memory exit = _sellBase(reserve0, 10_000);
        vm.prank(trader);
        (uint256 paid0, uint256 paid1) = vault.closeMakerAfterSwap(close, exit);
        assertEq(paid0, 0, "no base out");
        assertGt(paid1, 0, "token1 out");
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed");
        assertLedger();
    }

    /// @dev A short that sold its base at entry holds token1 and owes base: the close buys base through a venue and
    /// repays in kind.
    function test_close_exitSwapBuysBaseToRepayInKind() public {
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        OpenRequest memory request =
            openRequest(false, lower, upper, liquidityFor1(lower, upper, NOTIONAL), uint128(2_000e6));
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(lower, upper);
        (uint256 release0,) = VaultMath.releaseAcrossBand(
            request.liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96(), source.sqrtAskX96()
        );
        request.entryAmountIn = release0;
        request.entryVenue = address(venue);
        request.entryRoute = abi.encode(release0, _atBid(release0));
        uint256 positionId = open(request);
        Position memory position = vault.positionOf(positionId);
        assertEq(position.reserve0, 0, "holds only token1");
        uint256 bought = _atAsk(position.reserve1);
        ExitSwap memory exit = ExitSwap({
            zeroForOne: false,
            amountIn: position.reserve1,
            minimumOut: 0,
            venue: address(venue),
            route: abi.encode(position.reserve1, bought)
        });
        (uint256 paid0, uint256 paid1,) = _closeAfterSwap(positionId, 1e18, 0, exit, position.maximum0 + 1);
        assertGt(paid0, 0, "base out");
        assertLe(paid1, position.escrow, "token1 out is only the escrow's refund");
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertLedger();
    }

    /// @dev The maker twin: a short on a sell level that sold its base buys it back through a venue at the close.
    function test_closeMaker_exitSwapBuysBase() public {
        (uint256 bucketId,) = depositSell(makerA, LEVEL_SELL, 20e18);
        MakerOpenRequest memory request =
            makerRequest(false, single(bucketId), single128(liquidityOn(LEVEL_SELL, 5_000e6)), 1_000e6);
        uint256 release0 = _makerRelease0(LEVEL_SELL, 5_000e6);
        request.entryAmountIn = release0;
        request.entryVenue = address(venue);
        request.entryRoute = abi.encode(release0, _atBid(release0));
        uint256 positionId = openMaker(request);
        uint256 reserve1 = vault.makerPositionOf(positionId).reserve1;
        uint256 escrow = vault.makerPositionOf(positionId).escrow;
        uint256[] memory repay1 = new uint256[](1);
        MakerCloseRequest memory close = MakerCloseRequest({
            positionId: positionId,
            fractionWad: 1e18,
            repay0: single(vault.legOf(positionId, 0).maximum0 + 1),
            repay1: repay1
        });
        ExitSwap memory exit = ExitSwap({
            zeroForOne: false,
            amountIn: reserve1,
            minimumOut: 0,
            venue: address(venue),
            route: abi.encode(reserve1, _atAsk(reserve1))
        });
        vm.prank(trader);
        (uint256 paid0, uint256 paid1) = vault.closeMakerAfterSwap(close, exit);
        assertGt(paid0, 0, "base out");
        assertLe(paid1, escrow, "token1 out is only the escrow's refund");
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed");
        assertLedger();
    }

    function _makerRelease0(int24 level, uint256 amount1) internal view returns (uint256 release0) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(level);
        (release0,) = VaultMath.releaseAcrossBand(
            liquidityOn(level, amount1), sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96(), source.sqrtAskX96()
        );
    }

    /// @dev The maker book counts a poor exit fill's loss back into the proceeds the same way: the same share as a fair
    /// fill.
    function test_closeMaker_poorExitFillOwesTheFairFillsShare() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_BUY, 100_000e6);
        MakerOpenRequest memory request =
            makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_BUY, 10_000e6)), 3_000e6);
        request.entryAmountIn = 10_000e6;
        request.entryVenue = address(venue);
        request.entryRoute = abi.encode(uint256(10_000e6), _atAsk(10_000e6));
        uint256 positionId = openMaker(request);
        setPrice(PRICE_TICK + 953, 1);
        uint256 reserve0 = vault.makerPositionOf(positionId).reserve0;
        MakerCloseRequest memory close = MakerCloseRequest({
            positionId: positionId,
            fractionWad: 1e18,
            repay0: new uint256[](1),
            repay1: single(vault.legOf(positionId, 0).maximum1 + 1)
        });
        uint256 snapshot = vm.snapshotState();
        uint256 fairShare = _closeMakerAfterSwap(close, _sellBase(reserve0, 10_000));
        vm.revertToState(snapshot);
        uint256 poorShare = _closeMakerAfterSwap(close, _sellBase(reserve0, 9_000));
        assertGt(fairShare, 0, "a winning close owes a share");
        assertApproxEqAbs(poorShare, fairShare, 2, "the same share");
        assertLedger();
    }

    function _closeMakerAfterSwap(MakerCloseRequest memory close, ExitSwap memory exit) internal returns (uint256) {
        vm.recordLogs();
        vm.prank(trader);
        vault.closeMakerAfterSwap(close, exit);
        return _closedShare();
    }

    // ---------------------------------------------------------------- keepers: force closes

    /// @dev A short above the price that sold its base at entry: it holds token1 and owes base. No escrow, so it is
    /// delinquent at once; the grace period is over.
    function _delinquentQuoteShort() internal returns (uint256 positionId) {
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        OpenRequest memory request =
            openRequest(false, lower, upper, liquidityFor1(lower, upper, NOTIONAL), uint128(15_000e6));
        request.escrow = 0;
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(lower, upper);
        (uint256 release0,) = VaultMath.releaseAcrossBand(
            request.liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96(), source.sqrtAskX96()
        );
        request.entryAmountIn = release0;
        request.entryVenue = address(venue);
        request.entryRoute = abi.encode(release0, _atBid(release0));
        positionId = open(request);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vault.flag(positionId);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
    }

    function _traderValue() internal view returns (uint256) {
        return quote.balanceOf(trader) + _atBid(base.balanceOf(trader));
    }

    /// @dev Without a pool a force close could only scale the reserves; through a keeper's venue it buys the base it
    /// lacks instead, and the trader keeps more.
    function test_forceClose_keeperVenueBuysInsteadOfScaling() public {
        uint256 positionId = _delinquentQuoteShort();
        uint256 snapshot = vm.snapshotState();
        uint256 before = _traderValue();
        vm.prank(closer);
        vault.forceClose(positionId);
        uint256 scaled = _traderValue() - before;
        vm.revertToState(snapshot);
        before = _traderValue();
        bytes memory atAsk = _buyRoute(10_000);
        vm.prank(closer);
        vault.forceCloseThrough(positionId, address(rateVenue), atAsk);
        uint256 bought = _traderValue() - before;
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertGt(bought, scaled, "the trader keeps more than scaling leaves");
        assertLedger();
    }

    /// @dev A venue that sends back less than the deficit fails the close, which waits for a better route.
    function test_forceClose_keeperVenueShortOfTheDeficitWaits() public {
        uint256 positionId = _delinquentQuoteShort();
        bytes memory halfFill = _buyRoute(20_000);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.ShortfallUnfilled.selector);
        vault.forceCloseThrough(positionId, address(rateVenue), halfFill);
        assertEq(vault.positionOf(positionId).owner, trader, "still open");
        assertLedger();
    }

    function test_forceCloseMaker_keeperVenueBuysTheShortfall() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_BUY, 100_000e6);
        MakerOpenRequest memory request =
            makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_BUY, 10_000e6)), 3_000e6);
        request.escrow = 300e6;
        uint256 positionId = openMaker(request);
        (uint160 sqrtLowerX96,) = levelSqrtPrices(LEVEL_BUY);
        setPrice(TickMath.getTickAtSqrtPrice(sqrtLowerX96) - 300, 1);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vault.flagMaker(positionId);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        bytes memory atAsk = _buyRoute(10_000);
        vm.prank(closer);
        vault.forceCloseMakerThrough(positionId, address(rateVenue), atAsk);
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed");
        assertGt(vault.bucketOf(vaultId, bucketId).balance0, 0, "repaid in base bought through the venue");
        assertLedger();
    }

    // ---------------------------------------------------------------- keepers: fills

    /// @dev A buy bucket, with the band moved below the level by `ticksBelow` ticks.
    function _fillableBuy(int24 ticksBelow) internal returns (uint256 bucketId) {
        (bucketId,) = depositBuy(makerA, LEVEL_BUY, 50_000e6);
        (uint160 sqrtLowerX96,) = levelSqrtPrices(LEVEL_BUY);
        setPrice(TickMath.getTickAtSqrtPrice(sqrtLowerX96) - ticksBelow, 1);
    }

    /// @dev Without a pool a bucket could never fill; through a keeper's venue it fills at the band.
    function test_fill_keeperVenueFillsWithoutAPool() public {
        uint256 bucketId = _fillableBuy(300);
        vm.prank(closer);
        vm.expectRevert(IMakerBook.NotFillable.selector);
        vault.fillBucket(vaultId, bucketId);
        bytes memory atAsk = _buyRoute(10_000);
        vm.prank(closer);
        (uint256 paid, uint256 received) = vault.fillBucketThrough(vaultId, bucketId, address(rateVenue), atAsk);
        assertEq(paid, 50_000e6, "the whole order");
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        assertTrue(bucket.retired, "retired");
        assertEq(bucket.balance0, received - received * 5 / 10_000, "the base, less the keeper's 5 bp");
        assertEq(base.balanceOf(closer), received * 5 / 10_000, "the keeper's reward");
        assertLedger();
    }

    /// @dev With the market 3% below the level, a venue filling at the makers' limit would keep the difference; a fill
    /// more than the 1% allowance short of the band is refused.
    function test_fill_keeperVenueMustFillNearTheBand() public {
        uint256 bucketId = _fillableBuy(300);
        bytes memory pastAllowance = _buyRoute(10_150);
        bytes memory insideAllowance = _buyRoute(10_050);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.VenueBelowBand.selector);
        vault.fillBucketThrough(vaultId, bucketId, address(rateVenue), pastAllowance);
        vm.prank(closer);
        vault.fillBucketThrough(vaultId, bucketId, address(rateVenue), insideAllowance);
        assertTrue(vault.bucketOf(vaultId, bucketId).retired, "a fill inside the allowance stands");
        assertLedger();
    }

    /// @dev The makers' limit still applies: with the band just under the level, a fill near the band but above the
    /// level's bottom is refused.
    function test_fill_keeperVenueStillMeetsTheMakersLimit() public {
        uint256 bucketId = _fillableBuy(10);
        bytes memory aboveTheLimit = _buyRoute(10_050);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.SlippageExceeded.selector);
        vault.fillBucketThrough(vaultId, bucketId, address(rateVenue), aboveTheLimit);
    }

    /// @dev A sell bucket, with the band moved above the level by `ticksAbove` ticks and `spreadTicks` either side.
    function _fillableSell(int24 ticksAbove, int24 spreadTicks) internal returns (uint256 bucketId) {
        (bucketId,) = depositSell(makerA, LEVEL_SELL, 20e18);
        (, uint160 sqrtUpperX96) = levelSqrtPrices(LEVEL_SELL);
        setPrice(TickMath.getTickAtSqrtPrice(sqrtUpperX96) + ticksAbove, spreadTicks);
    }

    /// @dev A sell bucket fills through a keeper's venue selling its base at the bid.
    function test_fill_keeperVenueFillsASellBucket() public {
        uint256 bucketId = _fillableSell(300, 1);
        bytes memory atBid = _sellRoute(10_000);
        vm.prank(closer);
        (uint256 paid, uint256 received) = vault.fillBucketThrough(vaultId, bucketId, address(rateVenue), atBid);
        assertEq(paid, 20e18, "the whole order");
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        assertTrue(bucket.retired, "retired");
        assertEq(bucket.balance1, received - received * 5 / 10_000, "the token1, less the keeper's 5 bp");
        assertLedger();
    }

    /// @dev A sell is measured at the bid, the edge it crosses: with a band about ±1% wide, a fill 1.01% under the bid
    /// is past the 1% allowance, though it would be inside it measured at the ask.
    function test_fill_sellBucketAllowanceIsMeasuredAtTheBid() public {
        uint256 bucketId = _fillableSell(300, 100);
        bytes memory pastAllowance = _sellRoute(9_899);
        bytes memory insideAllowance = _sellRoute(9_910);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.VenueBelowBand.selector);
        vault.fillBucketThrough(vaultId, bucketId, address(rateVenue), pastAllowance);
        vm.prank(closer);
        vault.fillBucketThrough(vaultId, bucketId, address(rateVenue), insideAllowance);
        assertTrue(vault.bucketOf(vaultId, bucketId).retired, "a fill inside the allowance stands");
        assertLedger();
    }

    // ---------------------------------------------------------------- withdrawals

    /// @dev What a plain withdrawal of `shares` would pay, read in a snapshot.
    function _payoutOf(uint256 shares) internal returns (uint256 amount0, uint256 amount1) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(lender);
        (amount0, amount1,) = vault.withdraw(vaultId, shares, 0, 0, lender);
        vm.revertToState(snapshot);
    }

    /// @dev A lender leaves with only token1: the payout's base is sold through a venue before it is paid.
    function test_withdraw_afterSwapLeavesWithOneToken() public {
        uint256 shares = vault.sharesOf(vaultId, lender) / 2;
        (uint256 payout0, uint256 payout1) = _payoutOf(shares);
        assertGt(payout0, 0, "the plain payout holds base");
        ExitSwap memory swap = _sellBase(payout0, 10_000);
        uint256 baseBefore = base.balanceOf(lender);
        uint256 quoteBefore = quote.balanceOf(lender);
        vm.prank(lender);
        (uint256 amount0, uint256 amount1, uint256 burned) =
            vault.withdrawAfterSwap(vaultId, shares, payout0, payout1, lender, swap);
        assertEq(amount0, 0, "no base out");
        assertEq(amount1, payout1 + _atBid(payout0), "the token1 and the base's proceeds");
        assertEq(burned, shares);
        assertEq(base.balanceOf(lender), baseBefore);
        assertEq(quote.balanceOf(lender), quoteBefore + amount1);
        assertLedger();
    }

    /// @dev The swap sells only from the payout, and its own minimum applies.
    function test_withdraw_afterSwapBounds() public {
        uint256 shares = vault.sharesOf(vaultId, lender) / 2;
        (uint256 payout0,) = _payoutOf(shares);
        ExitSwap memory tooMuch = _sellBase(payout0 + 1, 10_000);
        ExitSwap memory tooLittle = _sellBase(payout0, 10_000);
        tooLittle.minimumOut = _atBid(payout0) + 1;
        vm.startPrank(lender);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.withdrawAfterSwap(vaultId, shares, 0, 0, lender, tooMuch);
        vm.expectRevert(IMetricLendingVault.SlippageExceeded.selector);
        vault.withdrawAfterSwap(vaultId, shares, 0, 0, lender, tooLittle);
        vm.stopPrank();
    }

    /// @dev A maker leaves a buy bucket with base: the payout's token1 is spent through a venue before it is paid.
    function test_withdrawOrder_afterSwapLeavesWithBase() public {
        (uint256 bucketId, uint256 shares) = depositBuy(makerA, LEVEL_BUY, 10_000e6);
        uint256 snapshot = vm.snapshotState();
        vm.prank(makerA);
        (, uint256 payout1,) = vault.withdrawOrder(vaultId, bucketId, shares, 0, 0, makerA);
        vm.revertToState(snapshot);
        ExitSwap memory swap = ExitSwap({
            zeroForOne: false,
            amountIn: payout1,
            minimumOut: 0,
            venue: address(venue),
            route: abi.encode(payout1, _atAsk(payout1))
        });
        uint256 baseBefore = base.balanceOf(makerA);
        vm.prank(makerA);
        (uint256 amount0, uint256 amount1,) =
            vault.withdrawOrderAfterSwap(vaultId, bucketId, shares, 0, payout1, makerA, swap);
        assertEq(amount1, 0, "no token1 out");
        assertEq(amount0, _atAsk(payout1), "the base bought with the whole payout");
        assertEq(base.balanceOf(makerA), baseBefore + amount0);
        assertLedger();
    }
}
