// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {IMetricOmmPoolActions} from "metric/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmSwapCallback} from "metric/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {BookSettings, FloorRow, LegRequest, MakerCloseRequest, MakerOpenRequest} from "vault/MakerTypes.sol";
import {CloseRequest, ExitSwap, OpenRequest, Position} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {ISwapVenue} from "vault/interfaces/ISwapVenue.sol";
import {RouterVenue} from "vault/venues/RouterVenue.sol";
import {MetricPrice} from "vault/libraries/MetricPrice.sol";
import {MakerMath} from "vault/libraries/MakerMath.sol";
import {Curve, VaultMath} from "vault/libraries/VaultMath.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice An adapter that routes the vault's input through a Metric pool, as an aggregator routing there would: the
/// pool pays the vault directly, the adapter pays the pool from what the vault sent and returns what is left. A real
/// adapter would also check that its callback comes from the pool it called; this one holds nothing between swaps.
contract PoolRouteVenue is ISwapVenue, IMetricOmmSwapCallback {
    function swapForVault(address tokenIn, address, uint256 amountIn, bytes calldata route) external {
        (MetricOmmPool pool, bool zeroForOne) = abi.decode(route, (MetricOmmPool, bool));
        // No price limit: zero for a sell, the maximum for a buy, as the vault's own entry swap.
        uint128 limitX64 = zeroForOne ? 0 : type(uint128).max;
        pool.swap(msg.sender, zeroForOne, int128(int256(amountIn)), limitX64, "", "");
        ERC20(tokenIn).transfer(msg.sender, ERC20(tokenIn).balanceOf(address(this)));
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        MetricOmmPool pool = MetricOmmPool(msg.sender);
        if (amount0 > 0) ERC20(pool.getImmutables().token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) ERC20(pool.getImmutables().token1).transfer(msg.sender, uint256(amount1));
    }
}

/// @notice A venue elsewhere that fills from its own inventory as its route says: spend, then the output.
contract InventoryVenue is ISwapVenue {
    function swapForVault(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata route) external {
        (uint256 spend, uint256 amountOut) = abi.decode(route, (uint256, uint256));
        ERC20(tokenOut).transfer(msg.sender, amountOut);
        ERC20(tokenIn).transfer(msg.sender, amountIn - spend);
    }
}

/// @notice A router of the usual shape: pulls the input on an approval, swaps it through a Metric pool, and has the pool
/// pay the recipient.
contract MetricRouter is IMetricOmmSwapCallback {
    function swap(MetricOmmPool pool, address tokenIn, bool zeroForOne, uint256 amountIn, address recipient) external {
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        // No price limit: zero for a sell, the maximum for a buy.
        uint128 limitX64 = zeroForOne ? 0 : type(uint128).max;
        pool.swap(recipient, zeroForOne, int128(int256(amountIn)), limitX64, "", "");
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        MetricOmmPool pool = MetricOmmPool(msg.sender);
        if (amount0 > 0) ERC20(pool.getImmutables().token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) ERC20(pool.getImmutables().token1).transfer(msg.sender, uint256(amount1));
    }
}

/// @notice Swaps to a price limit and pays the pool: a push before a keeper's fill.
contract PushSwapper is IMetricOmmSwapCallback {
    function swapToLimit(MetricOmmPool pool, bool zeroForOne, int128 amount, uint128 limitX64) external {
        pool.swap(address(this), zeroForOne, amount, limitX64, "", "");
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        MetricOmmPool pool = MetricOmmPool(msg.sender);
        if (amount0 > 0) ERC20(pool.getImmutables().token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) ERC20(pool.getImmutables().token1).transfer(msg.sender, uint256(amount1));
    }
}

/// @notice A venue elsewhere that sells everything it is sent at a fixed rate from its own inventory.
contract RateVenue is ISwapVenue {
    function swapForVault(address, address tokenOut, uint256 amountIn, bytes calldata route) external {
        (uint256 numerator, uint256 denominator) = abi.decode(route, (uint256, uint256));
        ERC20(tokenOut).transfer(msg.sender, FullMath.mulDiv(amountIn, numerator, denominator));
    }
}

/// @notice Named venues on a vault backed by Metric's own pool: an adapter routing through that pool fills an entry or
/// an exit swap exactly as the vault's own venue does, and a venue elsewhere still serves a trader's entry, a keeper's
/// force close and a keeper's fill while the pool's swaps are paused, when the vault's own venue cannot.
contract VenuesOnPoolTest is MetricFixture {
    int24 internal constant PRICE_TICK = -200_311;
    uint256 internal constant NOTIONAL = 20_000e6;
    uint128 internal constant COLLATERAL = 2_000e6;

    uint256 internal constant Q192 = 1 << 192;
    /// @dev About 1,943–1,962: below the 2,000 price.
    int24 internal constant BUY_LEVEL = -2_006;

    PoolRouteVenue internal adapter;
    InventoryVenue internal elsewhere;
    RateVenue internal rateVenue;

    function setUp() public override {
        super.setUp();
        adapter = new PoolRouteVenue();
        elsewhere = new InventoryVenue();
        rateVenue = new RateVenue();
        base.mint(address(elsewhere), 1e24);
        base.mint(address(rateVenue), 1e24);
        quote.mint(address(rateVenue), 1e14);
        deposit(lender, 100e18, 200_000e6);
    }

    function _band() internal returns (uint160 sqrtBidX96, uint160 sqrtAskX96) {
        return MetricPrice.band(address(pool), 1, 1e12);
    }

    /// @dev A rate route selling token0 at the bid.
    function _sellRoute() internal returns (bytes memory) {
        (uint160 sqrtBidX96,) = _band();
        return abi.encode(uint256(sqrtBidX96) * sqrtBidX96, Q192);
    }

    /// @dev A rate route buying token0 at the ask.
    function _buyRoute() internal returns (bytes memory) {
        (, uint160 sqrtAskX96) = _band();
        return abi.encode(Q192, uint256(sqrtAskX96) * sqrtAskX96);
    }

    /// @dev A long one to two percent below the price, selling its whole release and collateral for base.
    function _longRequest() internal returns (OpenRequest memory request) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        request.vaultId = vaultId;
        request.isLong = true;
        request.tickLower = lower;
        request.tickUpper = upper;
        request.liquidity = uint128(FullMath.mulDiv(NOTIONAL, 1 << 96, sqrtUpperX96 - sqrtLowerX96));
        request.collateral = COLLATERAL;
        request.escrow = 100e6;
        (uint160 sqrtBidX96, uint160 sqrtAskX96) = MetricPrice.band(address(pool), 1, 1e12);
        (, uint256 release1) =
            VaultMath.releaseAcrossBand(request.liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96, sqrtAskX96);
        request.entryAmountIn = release1 + COLLATERAL;
    }

    function _open(OpenRequest memory request) internal returns (Position memory) {
        vm.prank(trader);
        return vault.positionOf(vault.open(request));
    }

    /// @dev The same swap, once through the vault's own venue and once through an adapter routing to the same pool,
    /// leaves the same reserves.
    function test_open_adapterRoutingThroughThePoolMatchesTheVaultsOwnVenue() public {
        uint256 snapshot = vm.snapshotState();
        Position memory own = _open(_longRequest());
        vm.revertToState(snapshot);
        OpenRequest memory request = _longRequest();
        request.entryVenue = address(adapter);
        request.entryRoute = abi.encode(pool, false);
        Position memory routed = _open(request);
        assertGt(own.reserve0, 0, "bought base");
        assertEq(routed.reserve0, own.reserve0, "the same base");
        assertEq(routed.reserve1, own.reserve1, "the same token1 left");
        assertEq(base.balanceOf(address(adapter)), 0, "the adapter kept nothing");
        assertEq(quote.balanceOf(address(adapter)), 0);
        assertLedger();
    }

    /// @dev The production `RouterVenue` driving an approval-based router through the same pool, as it would drive an
    /// aggregator: the same reserves as the vault's own venue, and nothing left in the venue.
    function test_open_routerVenueThroughARouterOnThePool() public {
        uint256 snapshot = vm.snapshotState();
        Position memory own = _open(_longRequest());
        vm.revertToState(snapshot);
        RouterVenue routerVenue = new RouterVenue();
        MetricRouter router = new MetricRouter();
        OpenRequest memory request = _longRequest();
        RouterVenue.Route memory script;
        script.approvals = new RouterVenue.Approval[](1);
        script.approvals[0] =
            RouterVenue.Approval({token: address(quote), spender: address(router), amount: request.entryAmountIn});
        script.calls = new RouterVenue.Call[](1);
        script.calls[0] = RouterVenue.Call({
            target: address(router),
            data: abi.encodeCall(
                MetricRouter.swap, (pool, address(quote), false, request.entryAmountIn, address(routerVenue))
            )
        });
        request.entryVenue = address(routerVenue);
        request.entryRoute = abi.encode(script);
        Position memory routed = _open(request);
        assertEq(routed.reserve0, own.reserve0, "the same base");
        assertEq(routed.reserve1, own.reserve1, "the same token1 left");
        assertEq(quote.balanceOf(address(routerVenue)), 0, "the venue kept nothing");
        assertEq(quote.allowance(address(routerVenue), address(router)), 0, "no allowance left");
        assertLedger();
    }

    /// @dev With Metric's swaps paused the vault's own venue cannot enter, but a venue elsewhere still can.
    function test_open_venueElsewhereFillsWhileThePoolIsPaused() public {
        pool.setPause(1);
        OpenRequest memory request = _longRequest();
        vm.prank(trader);
        vm.expectRevert(IMetricOmmPoolActions.PoolPaused.selector);
        vault.open(request);
        (, uint160 sqrtAskX96) = MetricPrice.band(address(pool), 1, 1e12);
        uint256 amountOut =
            FullMath.mulDiv(FullMath.mulDiv(request.entryAmountIn, 1 << 96, sqrtAskX96), 1 << 96, sqrtAskX96);
        request.entryVenue = address(elsewhere);
        request.entryRoute = abi.encode(request.entryAmountIn, amountOut);
        Position memory position = _open(request);
        assertEq(position.reserve0, amountOut, "filled at the band's ask elsewhere");
        assertEq(position.reserve1, 0);
        assertLedger();
    }

    // ---------------------------------------------------------------- exit swaps

    /// @dev A long that bought base through the vault's own venue closes by selling it through an adapter routing to
    /// the same pool, and leaves with only token1.
    function test_close_exitSwapThroughAnAdapterOnThePool() public {
        OpenRequest memory open = _longRequest();
        vm.prank(trader);
        uint256 positionId = vault.open(open);
        Position memory position = vault.positionOf(positionId);
        ExitSwap memory exit;
        exit.zeroForOne = true;
        exit.amountIn = position.reserve0;
        exit.venue = address(adapter);
        exit.route = abi.encode(pool, true);
        CloseRequest memory request =
            CloseRequest({positionId: positionId, fractionWad: 1e18, repay0: 0, repay1: position.maximum1 + 1});
        vm.prank(trader);
        (uint256 paid0, uint256 paid1) = vault.closeAfterSwap(request, exit);
        assertEq(paid0, 0, "no base out");
        assertGt(paid1, 0, "token1 out");
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertLedger();
    }

    /// @dev The default venue for an exit swap is the vault's own pool.
    function test_close_exitSwapThroughTheVaultsOwnPool() public {
        OpenRequest memory open = _longRequest();
        vm.prank(trader);
        uint256 positionId = vault.open(open);
        Position memory position = vault.positionOf(positionId);
        ExitSwap memory exit;
        exit.zeroForOne = true;
        exit.amountIn = position.reserve0;
        CloseRequest memory request =
            CloseRequest({positionId: positionId, fractionWad: 1e18, repay0: 0, repay1: position.maximum1 + 1});
        vm.prank(trader);
        (uint256 paid0, uint256 paid1) = vault.closeAfterSwap(request, exit);
        assertEq(paid0, 0, "no base out");
        assertGt(paid1, 0, "token1 out");
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertLedger();
    }

    // ---------------------------------------------------------------- keepers while the pool is paused

    /// @dev A delinquent long holding base owes token1. With swaps paused the pool cannot sell its base, so a plain
    /// force close waits; a keeper's venue elsewhere sells it and closes.
    function test_forceClose_keeperVenueClosesWhileThePoolIsPaused() public {
        OpenRequest memory request = _longRequest();
        request.escrow = 0;
        vm.prank(trader);
        uint256 positionId = vault.open(request);
        vm.warp(block.timestamp + 30 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        pool.setPause(1);
        bytes memory atBid = _sellRoute();
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.ShortfallUnfilled.selector);
        vault.forceClose(positionId);
        vm.prank(closer);
        vault.forceCloseThrough(positionId, address(rateVenue), atBid);
        assertEq(vault.positionOf(positionId).owner, address(0), "closed through the venue");
        assertLedger();
    }

    /// @dev A buy bucket the price has passed cannot fill through the paused pool; a keeper's venue fills it.
    function test_fill_keeperVenueFillsWhileThePoolIsPaused() public {
        vm.prank(owner);
        vault.createBook(vaultId, _settings(), _curve(), _floors());
        address maker = makeAddr("maker");
        quote.mint(maker, 1e14);
        vm.startPrank(maker);
        quote.approve(address(vault), type(uint256).max);
        (uint256 bucketId,) = vault.depositOrder(vaultId, BUY_LEVEL, true, 20_000e6, 0, maker);
        vm.stopPrank();
        provider.set(uint128(1_900 * Q64), HALF_SPREAD_E5);
        pool.setPause(1);
        vm.prank(closer);
        vm.expectRevert(IMetricOmmPoolActions.PoolPaused.selector);
        vault.fillBucket(vaultId, bucketId);
        bytes memory atAsk = _buyRoute();
        vm.prank(closer);
        (uint256 paid,) = vault.fillBucketThrough(vaultId, bucketId, address(rateVenue), atAsk);
        assertEq(paid, 20_000e6, "the whole order");
        assertTrue(vault.bucketOf(vaultId, bucketId).retired, "filled and retired");
        assertLedger();
    }

    function _settings() internal pure returns (BookSettings memory settings) {
        settings.levelTicks = 100;
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
        rows = new FloorRow[](1);
        rows[0] = FloorRow({minimumDistanceBps: 0, rateBps: 25_000});
    }

    // ---------------------------------------------------------------- maker book on the pool

    function _book() internal returns (uint256 bucketId) {
        vm.prank(owner);
        vault.createBook(vaultId, _settings(), _curve(), _floors());
        address maker = makeAddr("maker");
        quote.mint(maker, 1e14);
        vm.startPrank(maker);
        quote.approve(address(vault), type(uint256).max);
        (bucketId,) = vault.depositOrder(vaultId, BUY_LEVEL, true, 50_000e6, 0, maker);
        vm.stopPrank();
    }

    function _makerLong(uint256 bucketId, uint128 collateral, uint256 entryAmountIn)
        internal
        returns (uint256 positionId)
    {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(BUY_LEVEL, 100);
        MakerOpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.legs = new LegRequest[](1);
        request.legs[0] = LegRequest({
            bucketId: bucketId, liquidity: uint128(FullMath.mulDiv(10_000e6, 1 << 96, sqrtUpperX96 - sqrtLowerX96))
        });
        request.collateral = collateral;
        request.escrow = 220e6;
        request.entryAmountIn = entryAmountIn;
        request.maximumRateBps = type(uint256).max;
        vm.prank(trader);
        positionId = vault.openMaker(request);
    }

    /// @dev A maker long that bought base through the vault's own pool closes by selling it through an adapter
    /// routing to the same pool, and leaves with only token1.
    function test_closeMaker_exitSwapThroughAnAdapterOnThePool() public {
        uint256 bucketId = _book();
        uint256 positionId = _makerLong(bucketId, 3_000e6, 10_000e6);
        uint256 reserve0 = vault.makerPositionOf(positionId).reserve0;
        assertGt(reserve0, 0, "bought base");
        uint256[] memory repay1 = new uint256[](1);
        repay1[0] = vault.legOf(positionId, 0).maximum1 + 1;
        MakerCloseRequest memory close =
            MakerCloseRequest({positionId: positionId, fractionWad: 1e18, repay0: new uint256[](1), repay1: repay1});
        ExitSwap memory exit = ExitSwap({
            zeroForOne: true, amountIn: reserve0, minimumOut: 0, venue: address(adapter), route: abi.encode(pool, true)
        });
        vm.prank(trader);
        (uint256 paid0, uint256 paid1) = vault.closeMakerAfterSwap(close, exit);
        assertEq(paid0, 0, "no base out");
        assertGt(paid1, 0, "token1 out");
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed");
        assertLedger();
    }

    /// @dev A delinquent maker long holding only token1 owes base once the price falls through its level. With swaps
    /// paused a plain force close waits; a keeper's venue elsewhere buys the base and closes.
    function test_forceCloseMaker_keeperVenueClosesWhileThePoolIsPaused() public {
        uint256 bucketId = _book();
        uint256 positionId = _makerLong(bucketId, 3_000e6, 0);
        provider.set(uint128(1_900 * Q64), HALF_SPREAD_E5);
        vm.warp(block.timestamp + 20 days);
        vault.flagMaker(positionId);
        vm.warp(block.timestamp + 1 hours + 1);
        pool.setPause(1);
        bytes memory atAsk = _buyRoute();
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.ShortfallUnfilled.selector);
        vault.forceCloseMaker(positionId);
        vm.prank(closer);
        vault.forceCloseMakerThrough(positionId, address(rateVenue), atAsk);
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed through the venue");
        assertGt(vault.bucketOf(vaultId, bucketId).balance0, 0, "repaid in base");
        assertLedger();
    }

    /// @dev Audit finding B-1, closed: a keeper who pushes the pool past the band's allowance before a fill through the
    /// pool finds it refused, since the fill's limit is now the band's edge plus `forceCloseSlippageBps`, not the
    /// makers' limit alone; back at the market it fills, within the allowance of the band.
    function test_fill_poolFillStopsAtTheBandsAllowance() public {
        uint256 bucketId = _book();
        provider.set(uint128(1_900 * Q64), HALF_SPREAD_E5);
        PushSwapper pusher = new PushSwapper();
        quote.mint(address(pusher), 1e14);
        uint256 snapshot = vm.snapshotState();
        pusher.swapToLimit(pool, false, int128(int256(1e13)), uint128(1_900 * Q64 * 10_200 / 10_000));
        vm.prank(closer);
        vm.expectRevert(IMetricOmmPoolActions.FinalAmountIsZero.selector);
        vault.fillBucket(vaultId, bucketId);
        vm.revertToState(snapshot);
        (, uint160 sqrtAskX96) = _band();
        vm.prank(closer);
        (uint256 paid, uint256 received) = vault.fillBucket(vaultId, bucketId);
        assertEq(paid, 50_000e6, "the whole order at the market");
        uint256 allowedPaid = VaultMath.priceTimes(received, sqrtAskX96, false) * 10_100 / 10_000;
        assertLe(paid, allowedPaid, "no worse than the ask plus the allowance");
        assertLedger();
    }

    // ---------------------------------------------------------------- withdrawals

    /// @dev A lender leaves with only token1 through the vault's own pool, the default venue.
    function test_withdraw_afterSwapThroughTheVaultsOwnPool() public {
        uint256 shares = vault.sharesOf(vaultId, lender) / 2;
        uint256 snapshot = vm.snapshotState();
        vm.prank(lender);
        (uint256 payout0,,) = vault.withdraw(vaultId, shares, 0, 0, lender);
        vm.revertToState(snapshot);
        assertGt(payout0, 0, "the plain payout holds base");
        ExitSwap memory swap;
        swap.zeroForOne = true;
        swap.amountIn = payout0;
        uint256 baseBefore = base.balanceOf(lender);
        vm.prank(lender);
        (uint256 amount0, uint256 amount1,) = vault.withdrawAfterSwap(vaultId, shares, 0, 0, lender, swap);
        assertEq(amount0, 0, "no base out");
        assertGt(amount1, 0, "token1 out");
        assertEq(base.balanceOf(lender), baseBefore);
        assertLedger();
    }
}
