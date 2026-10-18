// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {
    BookSettings,
    FloorRow,
    LegRequest,
    MakerIncreaseRequest,
    MakerOpenRequest,
    MakerPosition
} from "vault/MakerTypes.sol";
import {IncreaseRequest, OpenRequest, Position} from "vault/VaultTypes.sol";
import {IMakerBook} from "vault/interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MakerMath} from "vault/libraries/MakerMath.sol";
import {Curve} from "vault/libraries/VaultMath.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice Increases against Metric's own pool: the entry swap of an increase may sell only what the increase itself
/// brings in (the added release and collateral), never reserves the position already held; and a maker increase
/// cannot borrow from a bucket a fill has retired.
contract IncreaseOnPoolTest is MetricFixture {
    int24 internal constant PRICE_TICK = -200_311;
    uint24 internal constant LEVEL_TICKS = 100;
    /// @dev About 1,943–1,962: below the 2,000 price.
    int24 internal constant BUY_LEVEL = -2_006;

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

    // ---------------------------------------------------------------- passive

    /// @dev The position holds about 11,000 USDC from its open; the increase adds about 10,500 (release and
    /// collateral). Selling 15,000 would reach into the open's reserves, so it is refused; 5,000 buys base.
    function test_increase_entrySwapSellsOnlyWhatItAdds() public {
        deposit(lender, 100e18, 200_000e6);
        uint256 positionId = _openLong(10_000e6, 1_000e6);
        IncreaseRequest memory request;
        request.positionId = positionId;
        request.liquidity = _passiveLiquidity(10_000e6);
        request.collateral = 500e6;
        request.entryAmountIn = 15_000e6;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.increase(request);
        uint256 reserve0Before = vault.positionOf(positionId).reserve0;
        request.entryAmountIn = 5_000e6;
        vm.prank(trader);
        vault.increase(request);
        Position memory position = vault.positionOf(positionId);
        assertGt(position.reserve0, reserve0Before, "bought base with the added quote");
        assertEq(position.liquidity, 2 * request.liquidity, "one position of twice the liquidity");
        assertLedger();
    }

    // ---------------------------------------------------------------- maker

    /// @dev The same cap on a maker increase: the open's 10,000 USDC leg is untouchable; the new 5,000 leg and its
    /// 500 of collateral may be sold.
    function test_increaseMaker_entrySwapSellsOnlyWhatItAdds() public {
        (uint256 bucketId,) = _deposit(BUY_LEVEL, 50_000e6);
        uint256 positionId = _openMakerLong(bucketId, 10_000e6);
        MakerIncreaseRequest memory request = _makerIncrease(positionId, bucketId, 5_000e6);
        request.entryAmountIn = 8_000e6;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.increaseMaker(request);
        uint256 reserve0Before = vault.makerPositionOf(positionId).reserve0;
        request.entryAmountIn = 2_000e6;
        vm.prank(trader);
        vault.increaseMaker(request);
        MakerPosition memory position = vault.makerPositionOf(positionId);
        assertEq(position.legCount, 2, "a leg appended");
        assertGt(position.reserve0, reserve0Before, "bought base with the added quote");
        assertLedger();
    }

    /// @dev A fill retires a bucket; with the price back above its level, an increase naming it is refused, as an open
    /// would be, while the position's own leg elsewhere is untouched.
    function test_increaseMaker_refusesARetiredBucket() public {
        (uint256 retiring,) = _deposit(BUY_LEVEL, 30_000e6);
        (uint256 lending,) = _deposit(BUY_LEVEL - 1, 30_000e6);
        uint256 positionId = _openMakerLong(lending, 5_000e6);
        _setPrice(1_900);
        vm.prank(keeper);
        vault.fillBucket(vaultId, retiring);
        assertTrue(vault.bucketOf(vaultId, retiring).retired, "retired by the fill");
        _setPrice(2_000);
        vm.prank(trader);
        vm.expectRevert(IMakerBook.BucketRetired.selector);
        vault.increaseMaker(_makerIncrease(positionId, retiring, 5_000e6));
        assertEq(vault.makerPositionOf(positionId).legCount, 1, "nothing appended");
        assertLedger();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A long on [PRICE_TICK - 200, PRICE_TICK - 100), below the price: its release is all quote.
    function _openLong(uint256 notional, uint128 collateral) internal returns (uint256) {
        OpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.tickLower = PRICE_TICK - 200;
        request.tickUpper = PRICE_TICK - 100;
        request.liquidity = _passiveLiquidity(notional);
        request.collateral = collateral;
        request.escrow = 100e6;
        vm.prank(trader);
        return vault.open(request);
    }

    function _passiveLiquidity(uint256 notional) internal pure returns (uint128) {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(PRICE_TICK - 200);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(PRICE_TICK - 100);
        return uint128(FullMath.mulDiv(notional, 1 << 96, sqrtUpperX96 - sqrtLowerX96));
    }

    function _openMakerLong(uint256 bucketId, uint256 notional) internal returns (uint256) {
        MakerOpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.legs = new LegRequest[](1);
        request.legs[0] = LegRequest({bucketId: bucketId, liquidity: _makerLiquidity(bucketId, notional)});
        request.collateral = 1_000e6;
        request.escrow = 500e6;
        request.maximumRateBps = type(uint256).max;
        vm.prank(trader);
        return vault.openMaker(request);
    }

    /// @dev One new leg of `notional` on `bucketId`, with 500 of collateral and escrow enough for its prepaid charge
    /// and the whole position's minimum escrow.
    function _makerIncrease(uint256 positionId, uint256 bucketId, uint256 notional)
        internal
        pure
        returns (MakerIncreaseRequest memory request)
    {
        request.positionId = positionId;
        request.legs = new LegRequest[](1);
        request.legs[0] = LegRequest({bucketId: bucketId, liquidity: _makerLiquidity(bucketId, notional)});
        request.collateral = 500e6;
        request.escrow = 500e6;
        request.maximumRateBps = type(uint256).max;
    }

    function _makerLiquidity(uint256 bucketId, uint256 notional) internal pure returns (uint128) {
        (int24 level,,) = MakerMath.decode(bucketId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, LEVEL_TICKS);
        return uint128(FullMath.mulDiv(notional, 1 << 96, sqrtUpperX96 - sqrtLowerX96));
    }

    function _deposit(int24 level, uint256 amount) internal returns (uint256 bucketId, uint256 shares) {
        vm.prank(makerA);
        return vault.depositOrder(vaultId, level, true, amount, 0, makerA);
    }

    function _setPrice(uint256 wholePrice) internal {
        provider.set(uint128(wholePrice * Q64), HALF_SPREAD_E5);
    }

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
}
