// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {
    BookSettings,
    FloorRow,
    LegRequest,
    MakerCloseRequest,
    MakerOpenRequest,
    Leg
} from "../../../src/metric/vault/MakerTypes.sol";
import {Curve, VaultMath} from "../../../src/metric/vault/libraries/VaultMath.sol";
import {MakerMath} from "../../../src/metric/vault/libraries/MakerMath.sol";
import {VaultFixture} from "./VaultFixture.sol";

/// @notice A no-pool vault with a maker book: 100-tick levels around ETH at about 2,000 (tick -200,311, level
/// -2,004), with the calibrated starting curve and floor table (`hooks/research/metric-backtest/MAKERS.md`).
abstract contract MakerFixture is VaultFixture {
    uint24 internal constant LEVEL_TICKS = 100;
    /// @dev The level holding the price: ticks [-200,400, -200,300).
    int24 internal constant PRICE_LEVEL = -2_004;

    address internal makerA = makeAddr("makerA");
    address internal makerB = makeAddr("makerB");

    function setUp() public virtual override {
        super.setUp();
        fundWith(makerA, base);
        fundWith(makerA, quote);
        fundWith(makerB, base);
        fundWith(makerB, quote);
        vm.prank(owner);
        vault.createBook(vaultId, defaultBookSettings(), defaultBookCurve(), defaultFloorRows());
    }

    function defaultBookSettings() internal pure returns (BookSettings memory settings) {
        settings.levelTicks = LEVEL_TICKS;
        settings.utilizationCeilingBps = 9_000;
        settings.fillRewardBps = 5;
        settings.graceSeconds = 1 hours;
        settings.minimumEscrowSeconds = 3 days;
        settings.minimumChargeSeconds = 2 days;
        settings.minimumNotional = 100e6;
    }

    function defaultBookCurve() internal pure returns (Curve memory) {
        return Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0.05e18, slope2Wad: 12e18});
    }

    /// @dev Distance at open, from the nearer band edge to the level's strike, and the yearly floor.
    function defaultFloorRows() internal pure returns (FloorRow[] memory rows) {
        rows = new FloorRow[](11);
        rows[0] = FloorRow({minimumDistanceBps: 4_000, rateBps: 1_000});
        rows[1] = FloorRow({minimumDistanceBps: 3_000, rateBps: 1_500});
        rows[2] = FloorRow({minimumDistanceBps: 2_500, rateBps: 2_000});
        rows[3] = FloorRow({minimumDistanceBps: 2_000, rateBps: 4_000});
        rows[4] = FloorRow({minimumDistanceBps: 1_500, rateBps: 6_500});
        rows[5] = FloorRow({minimumDistanceBps: 1_000, rateBps: 9_000});
        rows[6] = FloorRow({minimumDistanceBps: 800, rateBps: 11_500});
        rows[7] = FloorRow({minimumDistanceBps: 500, rateBps: 13_000});
        rows[8] = FloorRow({minimumDistanceBps: 400, rateBps: 17_000});
        rows[9] = FloorRow({minimumDistanceBps: 200, rateBps: 22_500});
        rows[10] = FloorRow({minimumDistanceBps: 0, rateBps: 27_000});
    }

    // ---------------------------------------------------------------- makers

    function depositBuy(address maker, int24 level, uint256 amount1)
        internal
        returns (uint256 bucketId, uint256 shares)
    {
        vm.prank(maker);
        return vault.depositOrder(vaultId, level, true, amount1, 0, maker);
    }

    function depositSell(address maker, int24 level, uint256 amount0)
        internal
        returns (uint256 bucketId, uint256 shares)
    {
        vm.prank(maker);
        return vault.depositOrder(vaultId, level, false, amount0, 0, maker);
    }

    function levelSqrtPrices(int24 level) internal pure returns (uint160, uint160) {
        return MakerMath.levelRange(level, LEVEL_TICKS);
    }

    /// @dev The range liquidity on a level whose all-token1 amount is `amount1`.
    function liquidityOn(int24 level, uint256 amount1) internal pure returns (uint128) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(level);
        return uint128(FullMath.mulDiv(amount1, 1 << 96, sqrtUpperX96 - sqrtLowerX96));
    }

    // ---------------------------------------------------------------- traders

    function makerRequest(bool isLong, uint256[] memory bucketIds, uint128[] memory liquidities, uint128 collateral)
        internal
        view
        returns (MakerOpenRequest memory request)
    {
        request.vaultId = vaultId;
        request.isLong = isLong;
        request.legs = new LegRequest[](bucketIds.length);
        // bucketIds.length <= MAX_LEGS
        for (uint256 index = 0; index < bucketIds.length; ++index) {
            request.legs[index] = LegRequest({bucketId: bucketIds[index], liquidity: liquidities[index]});
        }
        request.collateral = collateral;
        request.escrow = 2_000e6;
        request.maximumRateBps = type(uint256).max;
    }

    function openMaker(MakerOpenRequest memory request) internal returns (uint256 positionId) {
        vm.prank(trader);
        positionId = vault.openMaker(request);
    }

    /// @dev Repays every leg's closed part with its holdings at the band's bid plus a unit of each token the range holds
    /// there, even where the amount rounds to zero, so a tiny part still repays.
    function repaymentsAtBid(uint256 positionId, uint256 fractionWad)
        internal
        view
        returns (uint256[] memory repay0, uint256[] memory repay1)
    {
        uint256 legCount = vault.makerPositionOf(positionId).legCount;
        repay0 = new uint256[](legCount);
        repay1 = new uint256[](legCount);
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            Leg memory leg = vault.legOf(positionId, index);
            (int24 level,,) = MakerMath.decode(leg.bucketId);
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(level);
            uint128 liquidity = uint128(VaultMath.portionDown(leg.liquidity, fractionWad));
            uint160 sqrtBidX96 = source.sqrtBidX96();
            (uint256 held0, uint256 held1) = VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96);
            repay0[index] = sqrtBidX96 < sqrtUpperX96 ? held0 + 1 : 0;
            repay1[index] = sqrtBidX96 > sqrtLowerX96 ? held1 + 1 : 0;
        }
    }

    function closeMakerFull(uint256 positionId, uint256[] memory repay0, uint256[] memory repay1)
        internal
        returns (uint256, uint256)
    {
        vm.prank(trader);
        return vault.closeMaker(
            MakerCloseRequest({positionId: positionId, fractionWad: 1e18, repay0: repay0, repay1: repay1})
        );
    }

    function single(uint256 value) internal pure returns (uint256[] memory values) {
        values = new uint256[](1);
        values[0] = value;
    }

    function single128(uint128 value) internal pure returns (uint128[] memory values) {
        values = new uint128[](1);
        values[0] = value;
    }
}
