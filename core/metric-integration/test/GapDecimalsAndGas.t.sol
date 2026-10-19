// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "metric/MetricOmmPoolDeployer.sol";
import {LiquidityDelta} from "metric/types/PoolOperation.sol";
import {IMetricOmmPoolActions} from "metric/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {Vm} from "forge-std/Vm.sol";
import {CloseRequest, Ledger, OpenRequest, Position, Stream, VaultParameters, Venue} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MetricPrice} from "vault/libraries/MetricPrice.sol";
import {MetricState} from "vault/libraries/MetricState.sol";
import {DebtTotals} from "vault/libraries/VaultMath.sol";
import {IntegrationToken, MetricFixture, SettableProvider} from "./utils/MetricFixture.sol";

/// @notice Exposes the vault's Metric price reader for any pool and scale multipliers.
contract DecimalsBandReader {
    function band(address pool, uint256 scale0, uint256 scale1) external returns (bool, uint160, uint160) {
        return MetricPrice.tryBand(pool, scale0, scale1);
    }
}

/// @notice One pool's tokens, price and amounts, all in raw units of each token.
struct MarketConfiguration {
    bytes32 salt;
    uint8 decimals0;
    uint8 decimals1;
    /// @dev The provider's whole-token Q64.64 reference.
    uint128 priceX64;
    uint256 halfSpreadE5;
    /// @dev The outsider's token0 per bin at and above the cursor, and token1 per bin below it.
    uint256 depth0;
    uint256 depth1;
    uint256 deposit0;
    uint256 deposit1;
    /// @dev The long's `M1`, about a fifth of the lender's token1.
    uint256 borrow1;
    uint8 binCount;
}

/// @notice A Metric pool with its own tokens and oracle, an outside LP, and a vault on the fixture's singleton.
struct Market {
    IntegrationToken token0;
    IntegrationToken token1;
    SettableProvider provider;
    MetricOmmPool pool;
    uint256 vaultId;
    uint256 scale0;
    uint256 scale1;
    MarketConfiguration configuration;
}

/// @notice Edge cases G16 (tokens of 6/18, 8/6 and 18/18 decimals, at ordinary prices and near the raw-price bounds)
/// and G17 (gas of a full 32-bin window's exit and force close) from the spec's untested table.
/// @dev Metric scales every token to 18 decimals with `scale = 10^(18 − decimals)`, so the raw price is the whole
/// price times `scale0 / scale1`. The vault refuses raw prices outside [2^-64, 2^64): the ceiling is reachable for
/// 6/18 and 18/18, the floor for 8/6 and 18/18. A 6/18 floor needs a Q64 reference under one unit, and an 8/6 ceiling
/// one above uint128, so neither can be quoted. A long below the bid needs room above the ranges' tick floor, so the
/// round trips sit inside a bound (about 6,100 to 6,900 ticks for 6/18, 8/6 and the 18/18 ceiling) and the
/// past-the-bound tests move the oracle once the long is open.
contract GapDecimalsAndGasTest is MetricFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 1 << 96;
    /// @dev `VaultLending.VIRTUAL_SHARES`: a first deposit mints its value in token1 units times this.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant OUTSIDE_BINS = 40;
    uint8 internal constant NARROW_WINDOW_BINS = 16;
    uint8 internal constant WIDE_WINDOW_BINS = 32;
    /// @dev The vault's raw-price floor, `VaultPricing.MIN_SQRT_X96`.
    uint160 internal constant MIN_SQRT_X96 = 1 << 64;
    /// @dev About half of a 30M-gas block: an action that fits leaves room for the rest of the block.
    uint256 internal constant GAS_BOUND = 15_000_000;
    uint256 internal constant HOLD_SECONDS = 30 days;
    /// @dev Raw units a Metric round trip may lose per bin: an add rounds its cost up and a read rounds down.
    uint256 internal constant DUST_PER_BIN = 4;

    DecimalsBandReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new DecimalsBandReader();
    }

    // ---------------------------------------------------------------- G16: the band

    /// @dev The band the vault reads through each pool brackets the provider's band converted to raw prices with the
    /// pool's own scales: the bid never above, the ask never below. A scale applied the wrong way round would move the
    /// band by orders of magnitude; a rounding toward the trader would put an edge on the wrong side.
    function test_band_bracketsTheProviderForEveryDecimalPair() public {
        MarketConfiguration[7] memory configurations = [
            _sixEighteenOrdinary(),
            _sixEighteenNearTheCeiling(),
            _eightSixOrdinary(),
            _eightSixNearTheFloor(),
            _eighteenEighteenOrdinary(),
            _eighteenEighteenNearTheCeiling(),
            _eighteenEighteenNearTheFloor()
        ];
        // configurations.length == 7
        for (uint256 index = 0; index < configurations.length; ++index) {
            Market memory market = _market(configurations[index]);
            _assertBandBrackets(market, _bandToleranceWad(configurations[index]));
        }
    }

    // ---------------------------------------------------------------- G16: round trips inside the bounds

    /// @dev A 6-decimal token0 priced in an 18-decimal token1 (USDC in ETH): deposit, a long, its close and the
    /// lender's full exit keep the ledger, repay lenders in full and pay the lender only what it put in and earned.
    /// A scale applied to the wrong token would misvalue every deposit and repayment by a factor of 10^12.
    function test_sixEighteen_ordinaryPrice_roundTripKeepsLendersWhole() public {
        _runRoundTrip(_sixEighteenOrdinary());
    }

    /// @dev The same round trip at a raw price of 1e19, about 6,100 ticks under the 2^64 ceiling, where one raw unit
    /// of token0 is worth ten whole token1, so every rounding of a token0 amount is worth whole tokens.
    function test_sixEighteen_nearTheRawCeiling_roundTripKeepsLendersWhole() public {
        _runRoundTrip(_sixEighteenNearTheCeiling());
    }

    /// @dev An 8-decimal token0 priced in a 6-decimal token1 (WBTC in USDC), the one pair whose scales differ on both
    /// sides, so a scale applied to the wrong token does not cancel out.
    function test_eightSix_ordinaryPrice_roundTripKeepsLendersWhole() public {
        _runRoundTrip(_eightSixOrdinary());
    }

    /// @dev The same round trip at a reference of 200 Q64 units, a raw price of 2·2^-64, about 6,900 ticks over the
    /// floor. The band is a few Q64 units wide, so this pins the floor-side rounding of every price read.
    function test_eightSix_nearTheRawFloor_roundTripKeepsLendersWhole() public {
        _runRoundTrip(_eightSixNearTheFloor());
    }

    /// @dev Two 18-decimal tokens at an ordinary price: no scaling at all. The baseline for the other pairs: with this
    /// one passing, a failure in them is the scaling's and not the round trip's.
    function test_eighteenEighteen_ordinaryPrice_roundTripKeepsLendersWhole() public {
        _runRoundTrip(_eighteenEighteenOrdinary());
    }

    /// @dev Two 18-decimal tokens at a raw price of 2^63, about 6,900 ticks under the ceiling, where Metric's bins can
    /// hold only millionths of a token0 and one wei of token0 is worth about 9.2 whole token1.
    function test_eighteenEighteen_nearTheRawCeiling_roundTripKeepsLendersWhole() public {
        _runRoundTrip(_eighteenEighteenNearTheCeiling());
    }

    /// @dev Two 18-decimal tokens at a reference of 200 Q64 units: with both scales one, the raw price is the Q64
    /// price itself, 200·2^-64, about 53,000 ticks over the floor, and a whole token0 is worth about 1e-17 of a
    /// token1. The band is the same few Q64 units wide as at the 8/6 floor, with no scale in the conversion, so this
    /// separates the floor-side rounding from the scaling.
    function test_eighteenEighteen_nearTheRawFloor_roundTripKeepsLendersWhole() public {
        _runRoundTrip(_eighteenEighteenNearTheFloor());
    }

    /// @dev Near the floor a modest token1 notional is an enormous token0 amount: 8,000 token1 at 1e-17 is an `M0`
    /// of about 7.7e38, past the uint128 a position stores. The open reverts on that cast with the exact `M0`. A
    /// silent truncation there would record a debt far below what the trader borrowed.
    function test_eighteenEighteen_nearTheRawFloor_openBeyondUint128Refuses() public {
        MarketConfiguration memory configuration = _eighteenEighteenNearTheFloor();
        configuration.borrow1 = 8_000e18;
        Market memory market = _market(configuration);
        _depositAndCheck(market);
        OpenRequest memory request = _openRequest(market);
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(request.tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(request.tickUpper);
        uint256 maximum0 = SqrtPriceMath.getAmount0Delta(sqrtLowerX96, sqrtUpperX96, request.liquidity, true) + 1;
        assertGt(maximum0, type(uint128).max, "M0 past uint128");
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, maximum0));
        vault.open(request);
    }

    // ---------------------------------------------------------------- G16: past the bounds

    /// @dev With a long open, the oracle moves to a raw price of 2e19, past the 2^64 ceiling: the reader reports no
    /// band, so deposits, opens and a withdrawal while lent refuse with InvalidBand, while the owner's close and the
    /// lender's exit still run and still keep the lender whole (the spec's exit without a price).
    function test_sixEighteen_pastTheRawCeiling_refusesPricedActionsButExits() public {
        uint128 pastPriceX64 = uint128(20_000_000 * Q64);
        Market memory market = _runPastTheBound(_sixEighteenNearTheCeiling(), pastPriceX64, HALF_SPREAD_E5);
        (bool quoted,,) = reader.band(address(market.pool), market.scale0, market.scale1);
        assertFalse(quoted, "a raw price past 2^64 is no price");
    }

    /// @dev The oracle moves to a reference of 90 Q64 units, a raw price under 2^-64: Metric still quotes, so the
    /// reader converts a bid under the vault's floor, and the vault refuses it as InvalidBand rather than price
    /// anything from it. Exits still run.
    function test_eightSix_pastTheRawFloor_refusesPricedActionsButExits() public {
        // A 5% half-spread keeps whole Q64 units on both sides of a reference this small, which Metric requires.
        Market memory market = _runPastTheBound(_eightSixNearTheFloor(), 90, 5_000);
        (bool quoted, uint160 sqrtBidX96,) = reader.band(address(market.pool), market.scale0, market.scale1);
        assertTrue(quoted, "Metric still quotes");
        assertLt(sqrtBidX96, MIN_SQRT_X96, "the bid is under the vault's floor");
    }

    /// @dev The oracle moves its ask to within a few Q64 units of uint128's limit: the ask's margin carries it past
    /// 2^64 raw (or Metric's own cast refuses it), so the band is no price. Exits still run.
    function test_eighteenEighteen_pastTheRawCeiling_refusesPricedActionsButExits() public {
        uint128 referenceX64 = uint128((uint256(type(uint128).max) - 1) * 1e5 / (1e5 + HALF_SPREAD_E5));
        Market memory market = _runPastTheBound(_eighteenEighteenNearTheCeiling(), referenceX64, HALF_SPREAD_E5);
        (bool quoted,,) = reader.band(address(market.pool), market.scale0, market.scale1);
        assertFalse(quoted, "an ask at uint128's limit is no price");
    }

    /// @dev The oracle's reference falls to one Q64 unit, so its bid rounds to zero and Metric refuses to quote: the
    /// vault reads no price, refuses priced actions, and still lets the trader and the lender out.
    function test_eighteenEighteen_zeroBid_refusesPricedActionsButExits() public {
        Market memory market = _runPastTheBound(_eighteenEighteenOrdinary(), 1, HALF_SPREAD_E5);
        (bool quoted,,) = reader.band(address(market.pool), market.scale0, market.scale1);
        assertFalse(quoted, "a zero bid is no price");
    }

    // ---------------------------------------------------------------- G17: a full 32-bin window

    /// @dev A lender's full exit from a vault holding shares in all 31 non-active bins of a 32-bin window, measured
    /// cold, gathers every bin in one removal and stays under the bound; the lender gets back what it put in. An exit
    /// costlier than a block can hold would lock the lender's capital in the vault.
    function test_gas_fullWithdrawalFromAFullThirtyTwoBinWindow() public {
        Market memory market = _market(_wideWindowConfiguration());
        uint256 shares = _depositAndCheck(market);
        _assertWindowFull(market);
        _coolMarket(market);
        vm.prank(lender);
        uint256 gasBefore = gasleft();
        (uint256 amount0, uint256 amount1, uint256 burned) =
            vault.withdraw{gas: GAS_BOUND}(market.vaultId, shares, 0, 0, lender);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("full withdrawal gas, 32-bin window", gasUsed);
        assertLt(gasUsed, GAS_BOUND, "within the operational bound");
        assertEq(burned, shares, "every share burned");
        assertEq(vault.totalSharesOf(market.vaultId), 0, "no lender left");
        assertApproxEqRel(amount0, market.configuration.deposit0, 1e9, "token0 back");
        assertApproxEqRel(amount1, market.configuration.deposit1, 1e9, "token1 back");
        _assertLedgerOf(market);
    }

    /// @dev A delinquent long on a full 32-bin window is force closed, measured cold, on its costliest path: it buys
    /// its shortfall through the pool, repays, and re-places the repayment across the window, all under the bound.
    /// The open's release empties the farthest token1 bins, so a second deposit refills the window before the close.
    /// A force close costlier than a block can hold would leave a delinquent debt that nobody can close.
    function test_gas_forceCloseOnAFullThirtyTwoBinWindow() public {
        Market memory market = _market(_wideWindowConfiguration());
        _depositAndCheck(market);
        OpenRequest memory request = _openRequest(market);
        request.entryAmountIn = market.configuration.borrow1;
        // A dollar of escrow: premium alone outruns it well within the warp.
        request.escrow = 1e6;
        vm.prank(trader);
        uint256 positionId = vault.open(request);
        // The release emptied the farthest token1 bins; a second deposit refills the whole window.
        vm.prank(lender);
        vault.deposit(market.vaultId, 10e18, 20_000e6, 0, lender);
        vm.warp(block.timestamp + 120 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        _assertWindowFull(market);
        _coolMarket(market);
        vm.recordLogs();
        vm.prank(closer);
        uint256 gasBefore = gasleft();
        vault.forceClose{gas: GAS_BOUND}(positionId);
        uint256 gasUsed = gasBefore - gasleft();
        assertEq(_poolSwaps(market, vm.getRecordedLogs()), 1, "bought its shortfall through the pool");
        emit log_named_uint("force close gas, 32-bin window", gasUsed);
        assertLt(gasUsed, GAS_BOUND, "within the operational bound");
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertEq(vault.accrualOf(market.vaultId).outstanding1, 0, "debt repaid");
        _assertLedgerOf(market);
    }

    // ---------------------------------------------------------------- flows

    function _runRoundTrip(MarketConfiguration memory configuration) internal {
        Market memory market = _market(configuration);
        uint256 shares = _depositAndCheck(market);
        uint256 positionId = _openAndCheck(market, _openRequest(market));
        vm.warp(block.timestamp + HOLD_SECONDS);
        uint256 traderCost = _closeAndCheck(market, positionId);
        vm.warp(block.timestamp + 1 days + 1);
        _withdrawAllAndCheck(market, shares, traderCost);
    }

    /// @dev The round trip with the oracle moved past a bound while the long is open.
    function _runPastTheBound(MarketConfiguration memory configuration, uint128 pastPriceX64, uint256 pastHalfSpreadE5)
        internal
        returns (Market memory market)
    {
        market = _market(configuration);
        uint256 shares = _depositAndCheck(market);
        OpenRequest memory request = _openRequest(market);
        uint256 positionId = _openAndCheck(market, request);
        vm.warp(block.timestamp + HOLD_SECONDS);
        market.provider.set(pastPriceX64, pastHalfSpreadE5);
        _assertPricedActionsRefused(market, request);
        uint256 traderCost = _closeAndCheck(market, positionId);
        vm.warp(block.timestamp + 1 days + 1);
        _withdrawAllAndCheck(market, shares, traderCost);
    }

    /// @dev The first deposit mints its value in token1 units times the virtual shares, so the shares show the price
    /// the vault used: at most the provider's bid, and close to it. The tokens reach Metric on both sides, and what
    /// the vault then counts as idle is the deposit less Metric's rounding, never more.
    function _depositAndCheck(Market memory market) internal returns (uint256 shares) {
        MarketConfiguration memory configuration = market.configuration;
        uint256 expected = _valueAtProviderBid(market, configuration.deposit0, configuration.deposit1);
        vm.prank(lender);
        shares = vault.deposit(market.vaultId, configuration.deposit0, configuration.deposit1, 0, lender);
        assertEq(shares % VIRTUAL_SHARES, 0, "a first deposit mints whole value units");
        assertLe(shares / VIRTUAL_SHARES, expected, "valued at or below the provider's bid");
        assertApproxEqRel(shares / VIRTUAL_SHARES, expected, 1e15, "valued near the provider's bid");
        Venue memory venue = vault.venueOf(market.vaultId);
        Ledger memory ledger = vault.ledgerOf(market.vaultId);
        assertGt(venue.holdings0, 0, "token0 reached Metric");
        assertGt(venue.holdings1, 0, "token1 reached Metric");
        uint256 idle0 = uint256(venue.holdings0) + ledger.buffer0;
        uint256 idle1 = uint256(venue.holdings1) + ledger.buffer1;
        assertLe(idle0, configuration.deposit0, "no token0 counted beyond the deposit");
        assertLe(idle1, configuration.deposit1, "no token1 counted beyond the deposit");
        assertGe(idle0 + _dust(market), configuration.deposit0, "token0 idle intact");
        assertGe(idle1 + _dust(market), configuration.deposit1, "token1 idle intact");
        _assertLedgerOf(market);
    }

    /// @dev A long on a range below the bid releases the range's token1 and no token0, exactly the range math at its
    /// liquidity: the release involves no scale.
    function _openAndCheck(Market memory market, OpenRequest memory request) internal returns (uint256 positionId) {
        vm.prank(trader);
        positionId = vault.open(request);
        Position memory position = vault.positionOf(positionId);
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(request.tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(request.tickUpper);
        uint256 rangeToken1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, request.liquidity, false);
        assertEq(position.released0, 0, "no token0 released below the bid");
        assertEq(position.released1, rangeToken1, "the range's token1 released");
        assertEq(vault.accrualOf(market.vaultId).outstanding1, rangeToken1, "outstanding");
        uint256 rangeToken1RoundedUp =
            SqrtPriceMath.getAmount1Delta(sqrtLowerX96, sqrtUpperX96, request.liquidity, true);
        assertEq(position.maximum1, rangeToken1RoundedUp + 1, "M1 rounds up, plus one unit");
        _assertLedgerOf(market);
    }

    /// @dev The owner repays `M1` in token1: the debt is gone, the repayment reaches the lenders' idle capital less
    /// Metric's rounding, and the trader takes back no more token1 than they put in. Returns what the trader paid.
    function _closeAndCheck(Market memory market, uint256 positionId) internal returns (uint256 traderCost) {
        Position memory position = vault.positionOf(positionId);
        uint256 idle1Before = _idle1(market);
        vm.prank(trader);
        (uint256 paid0, uint256 paid1) =
            vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: 0, repay1: position.maximum1}));
        uint256 paidIn = uint256(market.configuration.borrow1) * 3 / 100 + market.configuration.borrow1 / 100;
        assertEq(paid0, 0, "no token0 out");
        assertLe(paid1, paidIn, "no free token1 at an unchanged price");
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertEq(vault.accrualOf(market.vaultId).outstanding1, 0, "debt repaid");
        (DebtTotals memory longDebts,) = vault.debtsOf(market.vaultId);
        assertEq(longDebts.liquidity, 0, "no debt left");
        Ledger memory ledger = vault.ledgerOf(market.vaultId);
        assertEq(uint256(ledger.reserve1) + ledger.escrow, 0, "the trader's tokens all disbursed");
        assertGe(_idle1(market) + _dust(market), idle1Before + position.maximum1, "the repayment reached lenders");
        _assertLedgerOf(market);
        traderCost = paidIn - paid1;
    }

    /// @dev The lender's full exit, with nothing lent, burns every share and pays no more token0 than it put in and no
    /// more token1 than it put in plus what the trader paid; valued at the bid it leaves with more than it brought,
    /// since its premium income outweighs every rounding.
    function _withdrawAllAndCheck(Market memory market, uint256 shares, uint256 traderCost) internal {
        MarketConfiguration memory configuration = market.configuration;
        vm.prank(lender);
        (uint256 amount0, uint256 amount1, uint256 burned) = vault.withdraw(market.vaultId, shares, 0, 0, lender);
        assertEq(burned, shares, "every share burned");
        assertLe(amount0, configuration.deposit0, "no token0 beyond the deposit");
        assertLe(amount1, configuration.deposit1 + traderCost, "no token1 beyond the deposit and the trader's payment");
        uint256 valueIn = _valueAtProviderBid(market, configuration.deposit0, configuration.deposit1);
        uint256 valueOut = _valueAtProviderBid(market, amount0, amount1);
        assertGt(valueOut, valueIn, "the lender leaves with more than it brought");
        _assertLedgerOf(market);
    }

    /// @dev Past a bound the vault has no price: deposits and opens refuse, and so does a withdrawal while a position
    /// is open, since it values the debts.
    function _assertPricedActionsRefused(Market memory market, OpenRequest memory request) internal {
        vm.prank(lender);
        vm.expectRevert(IMetricLendingVault.InvalidBand.selector);
        vault.deposit(market.vaultId, market.configuration.deposit0, market.configuration.deposit1, 0, lender);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.InvalidBand.selector);
        vault.open(request);
        uint256 someShares = vault.sharesOf(market.vaultId, lender) / 10;
        vm.prank(lender);
        vm.expectRevert(IMetricLendingVault.InvalidBand.selector);
        vault.withdraw(market.vaultId, someShares, 0, 0, lender);
    }

    // ---------------------------------------------------------------- positions

    /// @dev A long on a hundred-tick range 200 to 300 ticks below the bid, borrowing the configuration's notional in
    /// token1, with 3% collateral and 1% escrow.
    function _openRequest(Market memory market) internal returns (OpenRequest memory request) {
        (bool quoted, uint160 sqrtBidX96,) = reader.band(address(market.pool), market.scale0, market.scale1);
        assertTrue(quoted, "a band to open against");
        int24 bidTick = TickMath.getTickAtSqrtPrice(sqrtBidX96);
        request.vaultId = market.vaultId;
        request.isLong = true;
        request.tickLower = bidTick - 300;
        request.tickUpper = bidTick - 200;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(request.tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(request.tickUpper);
        request.liquidity = uint128(FullMath.mulDiv(market.configuration.borrow1, Q96, sqrtUpperX96 - sqrtLowerX96));
        request.collateral = uint128(market.configuration.borrow1 * 3 / 100);
        request.escrow = uint128(market.configuration.borrow1 / 100);
    }

    // ---------------------------------------------------------------- markets

    function _market(MarketConfiguration memory configuration) internal returns (Market memory market) {
        market.configuration = configuration;
        market.token0 = new IntegrationToken("TOKEN0", configuration.decimals0);
        market.token1 = new IntegrationToken("TOKEN1", configuration.decimals1);
        // Metric's factory scales every token to 18 decimals.
        market.scale0 = 10 ** (18 - uint256(configuration.decimals0));
        market.scale1 = 10 ** (18 - uint256(configuration.decimals1));
        market.provider = new SettableProvider(address(market.token0), address(market.token1));
        market.provider.set(configuration.priceX64, configuration.halfSpreadE5);
        market.pool = _deployMarketPool(market);
        _fundMarket(market);
        outsider.addLiquidity(market.pool, _outsideDepth(market));
        VaultParameters memory parameters = defaultParameters();
        parameters.token0 = address(market.token0);
        parameters.token1 = address(market.token1);
        parameters.pool = address(market.pool);
        parameters.minBorrowNotional = uint128(configuration.borrow1 / 10);
        parameters.binCount = configuration.binCount;
        vm.prank(owner);
        market.vaultId = vault.createVault(parameters, defaultCurves());
    }

    function _deployMarketPool(Market memory market) internal returns (MetricOmmPool) {
        MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(this));
        MetricOmmPoolDeployer.DeployParams memory poolParameters = poolParams();
        poolParameters.salt = market.configuration.salt;
        poolParameters.token0 = address(market.token0);
        poolParameters.token1 = address(market.token1);
        poolParameters.priceProvider = address(market.provider);
        poolParameters.token0ScaleMultiplier = market.scale0;
        poolParameters.token1ScaleMultiplier = market.scale1;
        // One scaled unit per share on each side, so an empty bin's shares are its scaled amount.
        poolParameters.initialScaledAmount0PerShareE18 = 1e18;
        poolParameters.initialScaledAmount1PerShareE18 = 1e18;
        address deployed = deployer.deploy(poolParameters);
        deployedPools[deployed] = true;
        return MetricOmmPool(deployed);
    }

    function _fundMarket(Market memory market) internal {
        address[3] memory holders = [address(outsider), lender, trader];
        // holders.length == 3
        for (uint256 index = 0; index < holders.length; ++index) {
            market.token0.mint(holders[index], 1e36);
            market.token1.mint(holders[index], 1e36);
            vm.startPrank(holders[index]);
            market.token0.approve(address(vault), type(uint256).max);
            market.token1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev The configuration's depth in each of the middle 40 bins: token0 at and above the cursor, token1 below.
    function _outsideDepth(Market memory market) internal pure returns (LiquidityDelta memory deltas) {
        deltas.binIdxs = new int256[](OUTSIDE_BINS);
        deltas.shares = new uint256[](OUTSIDE_BINS);
        uint256 shares0 = market.configuration.depth0 * market.scale0;
        uint256 shares1 = market.configuration.depth1 * market.scale1;
        // OUTSIDE_BINS == 40
        for (uint256 index = 0; index < OUTSIDE_BINS; ++index) {
            int256 binIndex = int256(index) - int256(OUTSIDE_BINS / 2);
            deltas.binIdxs[index] = binIndex;
            deltas.shares[index] = binIndex < 0 ? shares1 : shares0;
        }
    }

    /// @dev A 6-decimal token0 at 0.0005 of an 18-decimal token1, as USDC priced in ETH: raw price 5e8.
    function _sixEighteenOrdinary() internal pure returns (MarketConfiguration memory configuration) {
        configuration = _configuration("6/18 ordinary", 6, 18, uint128(Q64 / 2_000), HALF_SPREAD_E5);
        configuration.depth0 = 20_000e6;
        configuration.depth1 = 10e18;
        configuration.deposit0 = 40_000e6;
        configuration.deposit1 = 20e18;
        configuration.borrow1 = 4e18;
    }

    /// @dev Ten million whole token1 per token0: raw price 1e19, under the 2^64 ≈ 1.84e19 ceiling.
    function _sixEighteenNearTheCeiling() internal pure returns (MarketConfiguration memory configuration) {
        configuration = _configuration("6/18 ceiling", 6, 18, uint128(10_000_000 * Q64), HALF_SPREAD_E5);
        configuration.depth0 = 10e6;
        configuration.depth1 = 1e26;
        configuration.deposit0 = 20e6;
        configuration.deposit1 = 2e26;
        configuration.borrow1 = 4e25;
    }

    /// @dev An 8-decimal token0 at 60,000 of a 6-decimal token1, as WBTC in USDC: raw price 600.
    function _eightSixOrdinary() internal pure returns (MarketConfiguration memory configuration) {
        configuration = _configuration("8/6 ordinary", 8, 6, uint128(60_000 * Q64), HALF_SPREAD_E5);
        configuration.depth0 = 1e8;
        configuration.depth1 = 60_000e6;
        configuration.deposit0 = 2e8;
        configuration.deposit1 = 120_000e6;
        configuration.borrow1 = 24_000e6;
    }

    /// @dev A reference of 200 Q64 units: raw price 2·2^-64. At this size a 5 bp band rounds onto the reference, which
    /// Metric refuses as asymmetric, so the band is 1% each side. Token0 is all but worthless here, and Metric's bins
    /// hold at most about 2e13 whole tokens, so the token0 side is a token amount, not a value.
    function _eightSixNearTheFloor() internal pure returns (MarketConfiguration memory configuration) {
        configuration = _configuration("8/6 floor", 8, 6, 200, 1_000);
        configuration.depth0 = 1e20;
        configuration.depth1 = 60_000e6;
        configuration.deposit0 = 1e20;
        configuration.deposit1 = 120_000e6;
        configuration.borrow1 = 24_000e6;
    }

    function _eighteenEighteenOrdinary() internal pure returns (MarketConfiguration memory configuration) {
        configuration = _configuration("18/18 ordinary", 18, 18, uint128(2_000 * Q64), HALF_SPREAD_E5);
        configuration.depth0 = 10e18;
        configuration.depth1 = 20_000e18;
        configuration.deposit0 = 20e18;
        configuration.deposit1 = 40_000e18;
        configuration.borrow1 = 8_000e18;
    }

    /// @dev Raw price 2^63, half the ceiling. A whole token0 is worth 9.2e18 whole token1, beyond a bin's uint104
    /// scaled balance, so token0 amounts are a ten-millionth or two of a token (1e11 and 2e11 wei).
    function _eighteenEighteenNearTheCeiling() internal pure returns (MarketConfiguration memory configuration) {
        configuration = _configuration("18/18 ceiling", 18, 18, uint128(1 << 127), HALF_SPREAD_E5);
        configuration.depth0 = 1e11;
        configuration.depth1 = 5e29;
        configuration.deposit0 = 2e11;
        configuration.deposit1 = 1e30;
        configuration.borrow1 = 2e29;
    }

    /// @dev The 8/6 floor case's reference and band with no scaling; token0 amounts again sized to the bins' cap.
    function _eighteenEighteenNearTheFloor() internal pure returns (MarketConfiguration memory configuration) {
        configuration = _configuration("18/18 floor", 18, 18, 200, 1_000);
        configuration.depth0 = 1e30;
        configuration.depth1 = 20_000e18;
        configuration.deposit0 = 1e30;
        configuration.deposit1 = 40_000e18;
        // 2,000 token1 at this price is an `M0` of about 1.9e38 token0, inside the uint128 a position stores.
        configuration.borrow1 = 2_000e18;
    }

    /// @dev The fixture's 18-decimal base at 2,000 of a 6-decimal quote, on a 32-bin window. The farthest token1 bin
    /// weighs 1 of 136, so 200,000 quote still puts far more than Metric's minimum share delta in it.
    function _wideWindowConfiguration() internal pure returns (MarketConfiguration memory configuration) {
        configuration = _configuration("wide window", 18, 6, uint128(2_000 * Q64), HALF_SPREAD_E5);
        configuration.depth0 = 10e18;
        configuration.depth1 = 20_000e6;
        configuration.deposit0 = 100e18;
        configuration.deposit1 = 200_000e6;
        configuration.borrow1 = 10_000e6;
        configuration.binCount = WIDE_WINDOW_BINS;
    }

    function _configuration(bytes32 salt, uint8 decimals0, uint8 decimals1, uint128 priceX64, uint256 halfSpreadE5)
        internal
        pure
        returns (MarketConfiguration memory configuration)
    {
        configuration.salt = salt;
        configuration.decimals0 = decimals0;
        configuration.decimals1 = decimals1;
        configuration.priceX64 = priceX64;
        configuration.halfSpreadE5 = halfSpreadE5;
        configuration.binCount = NARROW_WINDOW_BINS;
    }

    // ---------------------------------------------------------------- reads and checks

    /// @dev At a few hundred Q64 units the band's edges move by whole units and the ask's margin is several of them,
    /// so the band is a few percent wide; elsewhere it is within a basis point of the provider's.
    function _bandToleranceWad(MarketConfiguration memory configuration) internal pure returns (uint256) {
        if (configuration.priceX64 < 1e6) return 5e16;
        return 1e14;
    }

    function _assertBandBrackets(Market memory market, uint256 toleranceWad) internal {
        (bool quoted, uint160 sqrtBidX96, uint160 sqrtAskX96) =
            reader.band(address(market.pool), market.scale0, market.scale1);
        assertTrue(quoted, "the band reads");
        (uint128 bidX64, uint128 askX64,) = market.provider.getQuote();
        // Raw price = whole price · scale0 / scale1, as a Q192 square of the sqrt price.
        uint256 providerSqrtBidX96 = Math.sqrt(FullMath.mulDiv(bidX64, market.scale0 << 128, market.scale1));
        uint256 providerSqrtAskX96 =
            Math.sqrt(FullMath.mulDivRoundingUp(askX64, market.scale0 << 128, market.scale1), Math.Rounding.Ceil);
        assertLe(sqrtBidX96, providerSqrtBidX96, "bid at or below the provider's");
        assertGe(sqrtAskX96, providerSqrtAskX96, "ask at or above the provider's");
        assertApproxEqRel(sqrtBidX96, providerSqrtBidX96, toleranceWad, "bid near the provider's");
        assertApproxEqRel(sqrtAskX96, providerSqrtAskX96, toleranceWad, "ask near the provider's");
    }

    /// @dev Raw token1 units, at the provider's bid, computed without the vault's sqrt prices.
    function _valueAtProviderBid(Market memory market, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256)
    {
        (uint128 bidX64,,) = market.provider.getQuote();
        return amount1 + FullMath.mulDiv(amount0 * bidX64, market.scale0, market.scale1 << 64);
    }

    /// @dev How many swaps the market's pool emitted. A close's own placement adds liquidity, which is not a swap.
    function _poolSwaps(Market memory market, Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bytes32 swapTopic = IMetricOmmPoolActions.Swap.selector;
        // logs.length < 20: one force close's events, 9 in this test
        for (uint256 index = 0; index < logs.length; ++index) {
            if (logs[index].emitter != address(market.pool)) continue;
            if (logs[index].topics[0] == swapTopic) ++count;
        }
    }

    function _idle1(Market memory market) internal view returns (uint256) {
        return uint256(vault.venueOf(market.vaultId).holdings1) + vault.ledgerOf(market.vaultId).buffer1;
    }

    function _dust(Market memory market) internal pure returns (uint256) {
        return DUST_PER_BIN * market.configuration.binCount;
    }

    /// @dev Every token the vault contract holds of this market's tokens belongs to one part of its ledger.
    function _assertLedgerOf(Market memory market) internal view {
        Ledger memory ledger = vault.ledgerOf(market.vaultId);
        Stream memory stream = vault.streamOf(market.vaultId);
        (uint256 book0, uint256 book1, uint256 income0, uint256 income1) = vault.bookTotalsOf(market.vaultId);
        assertEq(uint256(ledger.held0), market.token0.balanceOf(address(vault)), "held0 vs balance");
        assertEq(uint256(ledger.held1), market.token1.balanceOf(address(vault)), "held1 vs balance");
        assertEq(
            uint256(ledger.held0),
            uint256(ledger.buffer0) + ledger.reserve0 + ledger.treasury0 + ledger.feeVault0 + ledger.unclaimed0
                + stream.remaining0 + book0 + income0,
            "held0 parts"
        );
        assertEq(
            uint256(ledger.held1),
            uint256(ledger.buffer1) + ledger.reserve1 + ledger.escrow + ledger.treasury1 + ledger.feeVault1
                + ledger.unclaimed1 + stream.remaining1 + book1 + income1,
            "held1 parts"
        );
    }

    /// @dev The window's 31 bins other than the active one each hold the vault's shares: the most a window holds.
    function _assertWindowFull(Market memory market) internal view {
        Venue memory venue = vault.venueOf(market.vaultId);
        uint256 heldBins;
        // binCount <= MetricVenue.MAX_BINS == 32
        for (uint256 offset = 0; offset < market.configuration.binCount; ++offset) {
            int16 binIndex = int16(int256(venue.lowestBin) + int256(offset));
            uint256 ours =
                MetricState.positionShares(address(market.pool), address(vault), uint80(market.vaultId), binIndex);
            if (ours != 0) ++heldBins;
        }
        assertGe(heldBins, uint256(market.configuration.binCount) - 1, "every bin but the active one holds shares");
    }

    function _assertInsideWindow(Market memory market) internal view {
        int256 lowestBin = vault.venueOf(market.vaultId).lowestBin;
        // every pool bin: 40 per side
        for (int256 binIndex = -40; binIndex < 40; ++binIndex) {
            uint256 ours = MetricState.positionShares(
                address(market.pool), address(vault), uint80(market.vaultId), int16(binIndex)
            );
            if (ours == 0) continue;
            assertGe(binIndex, lowestBin, "inside the window, low side");
            assertLt(
                binIndex, lowestBin + int256(uint256(market.configuration.binCount)), "inside the window, high side"
            );
        }
    }

    /// @dev Prices the measured call's storage and account access cold, as a fresh transaction pays them. On
    /// 2026-10-17 the three G17 measurements came out within 2,300 gas of each other with and without it, and the same
    /// under `forge test --isolate`, so they are cold costs.
    function _coolMarket(Market memory market) internal {
        vm.cool(address(vault));
        vm.cool(address(market.pool));
        vm.cool(address(market.token0));
        vm.cool(address(market.token1));
        vm.cool(address(market.provider));
    }
}
