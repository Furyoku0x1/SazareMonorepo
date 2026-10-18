// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BookSettings, Bucket, FloorRow} from "vault/MakerTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MakerMath} from "vault/libraries/MakerMath.sol";
import {Curve, VaultMath} from "vault/libraries/VaultMath.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice A maker fill's limit net of the keeper's reward, at the 100 bp maximum with the band just past the level,
/// where the reward alone decides whether a fill meets the makers' limit: the pool's gross limit is tightened by the
/// reward, and the makers' price is checked on the output net of it.
contract GapFillLimitsTest is MetricFixture {
    uint24 internal constant LEVEL_TICKS = 100;
    /// @dev About 1,943–1,962: below the 2,000 price.
    int24 internal constant BUY_LEVEL = -2_006;
    /// @dev About 2,105–2,126: above it.
    int24 internal constant SELL_LEVEL = -1_998;
    uint256 internal constant BPS = 10_000;
    /// @dev `MakerBook.MAX_FILL_REWARD_BPS`: the widest gap between the pool's gross price and the makers' net one.
    uint16 internal constant FILL_REWARD_BPS = 100;
    /// @dev How far past the gross limit the pool's price starts: inside the reward, so a pool limit at the level
    /// itself would let the fill run on to prices the reward takes below the makers' limit.
    uint256 internal constant START_PAST_GROSS_LIMIT_BPS = 10;
    /// @dev A tiny sell is sized to be worth 99.5 quote units at the level's top, so it owes 100 once rounded up.
    uint256 internal constant TINY_SELL_WORTH_E1 = 995;

    address internal maker = makeAddr("makerA");
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        base.mint(maker, 1e24);
        quote.mint(maker, 1e14);
        vm.startPrank(maker);
        base.approve(address(vault), type(uint256).max);
        quote.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.prank(owner);
        vault.createBook(vaultId, _settings(), _curve(), _floors());
    }

    // ---------------------------------------------------------------- the pool's gross limit

    /// @dev Pins the sell limit's gross-up, `P_upper / (1 − reward)`. The pool's sell price starts 10 bp past that
    /// gross limit, so the band is just past the level. A 100-base order fills only down to the gross limit, in part,
    /// and the makers' net output still covers the level's top. A pool limit at the top itself (the reward adjustment
    /// deleted) would sell on down to the top at gross prices the 1% reward takes below it, and the fill would revert.
    function test_fill_sellJustPastTheLevelStopsAtTheTopGrossedUpForTheReward() public {
        uint256 amount = 100e18;
        (uint256 bucketId,) = _deposit(SELL_LEVEL, false, amount);
        (, uint160 sqrtUpperX96) = MakerMath.levelRange(SELL_LEVEL, LEVEL_TICKS);
        uint256 topX64 = MakerMath.toPriceX64(sqrtUpperX96, 1, 1e12, true);
        uint256 grossLimitX64 = FullMath.mulDivRoundingUp(topX64, BPS, BPS - FILL_REWARD_BPS);
        _setSellPrice(grossLimitX64 * (BPS + START_PAST_GROSS_LIMIT_BPS) / BPS);
        (uint128 sellBeforeX64,) = pool.getSellAndBuyPrices();
        assertGt(sellBeforeX64, grossLimitX64, "the pool's sell price starts past the gross limit");
        assertLt(sellBeforeX64, grossLimitX64 * (BPS + FILL_REWARD_BPS) / BPS, "past it by less than the reward");

        vm.prank(keeper);
        (uint256 paid, uint256 received) = vault.fillBucket(vaultId, bucketId);
        assertGt(paid, 0, "filled in part");
        assertLt(paid, amount, "not in full: the pool stopped at the gross limit");
        (uint128 sellAfterX64,) = pool.getSellAndBuyPrices();
        assertGe(sellAfterX64, grossLimitX64, "the pool sold no lower than the gross limit");
        assertLt(sellAfterX64, sellBeforeX64, "and moved down to it");
        uint256 reward = received * FILL_REWARD_BPS / BPS;
        assertEq(quote.balanceOf(keeper), reward, "the keeper's 1% of the output");
        assertGe(received - reward, VaultMath.priceTimes(paid, sqrtUpperX96, true), "makers sold at least at the top");
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        assertTrue(bucket.retired, "a partial fill retires the bucket");
        assertEq(bucket.balance0, amount - paid, "the rest waits");
        assertEq(bucket.balance1, received - reward, "the makers keep the net output");
        assertLedger();
    }

    /// @dev Pins the buy limit's tightening, `P_lower · (1 − reward)`. The pool's buy price starts 10 bp under that
    /// gross limit, so the band is just past the level. A 1,000,000 USD order fills only up to the gross limit, in
    /// part, and the makers' net base still costs no more than the level's bottom. A pool limit at the bottom itself
    /// (the reward adjustment deleted) would buy on up to the bottom at gross prices the 1% reward lifts above it, and
    /// the fill would revert.
    function test_fill_buyJustPastTheLevelStopsAtTheBottomTightenedForTheReward() public {
        uint256 amount = 1_000_000e6;
        (uint256 bucketId,) = _deposit(BUY_LEVEL, true, amount);
        (uint160 sqrtLowerX96,) = MakerMath.levelRange(BUY_LEVEL, LEVEL_TICKS);
        uint256 bottomX64 = MakerMath.toPriceX64(sqrtLowerX96, 1, 1e12, false);
        uint256 grossLimitX64 = bottomX64 * (BPS - FILL_REWARD_BPS) / BPS;
        _setBuyPrice(grossLimitX64 * (BPS - START_PAST_GROSS_LIMIT_BPS) / BPS);
        (, uint128 buyBeforeX64) = pool.getSellAndBuyPrices();
        assertLt(buyBeforeX64, grossLimitX64, "the pool's buy price starts past the gross limit");
        assertGt(buyBeforeX64, grossLimitX64 * (BPS - FILL_REWARD_BPS) / BPS, "past it by less than the reward");

        vm.prank(keeper);
        (uint256 paid, uint256 received) = vault.fillBucket(vaultId, bucketId);
        assertGt(paid, 0, "filled in part");
        assertLt(paid, amount, "not in full: the pool stopped at the gross limit");
        (, uint128 buyAfterX64) = pool.getSellAndBuyPrices();
        assertLe(buyAfterX64, grossLimitX64, "the pool bought no higher than the gross limit");
        assertGt(buyAfterX64, buyBeforeX64, "and moved up to it");
        uint256 reward = received * FILL_REWARD_BPS / BPS;
        assertEq(base.balanceOf(keeper), reward, "the keeper's 1% of the output");
        assertGe(VaultMath.priceTimes(received - reward, sqrtLowerX96, false), paid, "makers paid at most the bottom");
        Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
        assertTrue(bucket.retired, "a partial fill retires the bucket");
        assertEq(bucket.balance1, amount - paid, "the rest waits");
        assertEq(bucket.balance0, received - reward, "the makers keep the net output");
        assertLedger();
    }

    // ---------------------------------------------------------------- the makers' net price

    /// @dev Pins the price check on the output net of the reward. A sell worth 99.5 quote units at the level's top
    /// owes 100 once rounded up. With the pool's price 10 bp past the gross limit its exact output is about 100.6
    /// units, which Metric pays as 100: the gross output covers the top, as an outside swap of the same size shows,
    /// but the 1-unit reward leaves the makers 99, so the fill reverts with SlippageExceeded. A check on the gross
    /// output would fill the makers a unit under their limit.
    function test_fill_refusesAnOutputThatMeetsTheTopOnlyBeforeTheReward() public {
        (, uint160 sqrtUpperX96) = MakerMath.levelRange(SELL_LEVEL, LEVEL_TICKS);
        uint256 amount = FullMath.mulDiv(TINY_SELL_WORTH_E1, 1 << 192, uint256(sqrtUpperX96) * sqrtUpperX96) / 10;
        uint256 owed = VaultMath.priceTimes(amount, sqrtUpperX96, true);
        assertEq(owed, 100, "the level's top, rounded up");
        (uint256 bucketId,) = _deposit(SELL_LEVEL, false, amount);
        uint256 topX64 = MakerMath.toPriceX64(sqrtUpperX96, 1, 1e12, true);
        uint256 grossLimitX64 = FullMath.mulDivRoundingUp(topX64, BPS, BPS - FILL_REWARD_BPS);
        _setSellPrice(grossLimitX64 * (BPS + START_PAST_GROSS_LIMIT_BPS) / BPS);
        uint256 grossOutput = _outsideSellOutput(amount);
        assertEq(grossOutput, owed, "the gross output covers the top");
        assertLt(grossOutput - grossOutput * FILL_REWARD_BPS / BPS, owed, "the net output does not");

        vm.prank(keeper);
        vm.expectRevert(IMetricLendingVault.SlippageExceeded.selector);
        vault.fillBucket(vaultId, bucketId);
    }

    // ---------------------------------------------------------------- helpers

    function _settings() internal pure returns (BookSettings memory settings) {
        settings.levelTicks = LEVEL_TICKS;
        settings.utilizationCeilingBps = 9_000;
        settings.fillRewardBps = FILL_REWARD_BPS;
        settings.graceSeconds = 1 hours;
        settings.minimumEscrowSeconds = 3 days;
        settings.minimumChargeSeconds = 2 days;
        // One unit, so the tiny sell's deposit is taken.
        settings.minimumNotional = 1;
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
        vm.prank(maker);
        return vault.depositOrder(vaultId, level, isBuy, amount, 0, maker);
    }

    /// @dev Scales the reference so Metric's marginal sell price, fees included, is `targetX64`: with the cursor and
    /// spread fixed, the pool's prices are proportional to the reference.
    function _setSellPrice(uint256 targetX64) internal {
        (uint128 sellX64,) = pool.getSellAndBuyPrices();
        provider.set(uint128(FullMath.mulDiv(provider.referenceX64(), targetX64, sellX64)), HALF_SPREAD_E5);
    }

    /// @dev As `_setSellPrice`, for Metric's marginal buy price.
    function _setBuyPrice(uint256 targetX64) internal {
        (, uint128 buyX64) = pool.getSellAndBuyPrices();
        provider.set(uint128(FullMath.mulDiv(provider.referenceX64(), targetX64, buyX64)), HALF_SPREAD_E5);
    }

    /// @dev The quote an outside swap of `amount` base gets from the pool now, with the pool's state rolled back after.
    function _outsideSellOutput(uint256 amount) internal returns (uint256) {
        uint256 snapshot = vm.snapshotState();
        (, int128 amount1) = outsider.swap(pool, true, int128(int256(amount)));
        vm.revertToState(snapshot);
        return uint256(int256(-amount1));
    }
}
