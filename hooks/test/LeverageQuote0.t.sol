// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LeverageFixture} from "./utils/LeverageFixture.sol";
import {LeverageMath} from "../src/libraries/leverage/LeverageMath.sol";
import {Position} from "../src/libraries/leverage/LeverageBins.sol";
import {LeverageEngine} from "../src/libraries/leverage/LeverageEngine.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev The quote-side branches with currency0 as the quote, so currency1 is the base: a long holds currency1 and
/// profits as the price (currency1 per currency0) falls. The main suites cover currency1 as the quote.
contract LeverageQuote0Test is LeverageFixture {
    uint256 internal constant Q128 = 1 << 128;

    function _quoteIsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        _seedLenders();
    }

    /// @dev Bins 1 to 3 sit above the price, so their liquidity is all quote; the long buys currency1 with it.
    function _openQuote0Long(uint128 perBin, uint128 collateral, uint128 premium) internal returns (uint256) {
        return _open(trader, _openRequest(1, _uniform(3, perBin), true, collateral, premium));
    }

    /// @dev Bins -3 to -1 sit below the price, so their liquidity is all base; the short sells it for currency0.
    function _openQuote0Short(uint128 perBin, uint128 collateral, uint128 premium) internal returns (uint256) {
        return _open(trader, _openRequest(-3, _uniform(3, perBin), false, collateral, premium));
    }

    function test_longHoldsCurrency1AndShortHoldsCurrency0() public {
        uint256 longId = _openQuote0Long(2e20, 1e19, 1e17);
        Position memory held = leverage.positionOf(longId);
        assertEq(held.reserve0, 0, "the long sold all its quote");
        assertGt(held.reserve1, held.maximum1);
        assertTrue(LeverageMath.chordHolds(held.reserve0, held.reserve1, held.maximum0, held.maximum1));
        uint256 shortId = _openQuote0Short(2e20, 1e19, 1e17);
        held = leverage.positionOf(shortId);
        assertEq(held.reserve1, 0, "the short sold all its base");
        assertGt(held.reserve0, held.maximum0);
        assertEq(_balance(currency0, address(leverage)), 2e17 + held.reserve0, "escrows and reserves in currency0");
    }

    function test_profitableLongPaysTheShareInCurrency0() public {
        uint256 id = _openQuote0Long(2e20, 1e19, 1e17);
        _swapAs(swapper, true, 4e19);
        uint256 before0 = _balance(currency0, trader);
        uint256 before1 = _balance(currency1, trader);
        vm.prank(trader);
        uint256 payout = leverage.close(id, 1e18, 0, trader);
        assertEq(_balance(currency0, trader), before0 + payout, "paid in currency0");
        assertEq(_balance(currency1, trader), before1, "nothing in the base");
        (uint256 treasuryOwed0, uint256 treasuryOwed1) = leverage.owedOf(treasury);
        (uint256 vaultOwed0,) = leverage.owedOf(address(feeVault));
        assertGt(treasuryOwed0, 0, "a winning close pays the share");
        assertEq(treasuryOwed1, 0);
        assertEq(vaultOwed0, treasuryOwed0);
        assertEq(leverage.flushFeeVault(), vaultOwed0);
        (,, uint256 totalOwed0,) = leverage.totals();
        assertEq(totalOwed0, treasuryOwed0, "only the treasury part is left owed");
    }

    function test_premiumIsChargedOnTheCurrency0NotionalAndPaidInCurrency0() public {
        uint256 id = _openQuote0Long(2e20, 1e19, 1e17);
        vm.warp(block.timestamp + 30 days);
        (int24 tickLower, int24 tickUpper) = leverage.binTicks(2);
        (uint256 notional0,) = LeverageMath.extremes(2e20, tickLower, tickUpper);
        uint256 rateWad = LeverageMath.rateWad(_curve(), 2e20, 2 * uint256(LENDER_LIQUIDITY));
        uint256 binPremium = notional0 * rateWad * 30 days / 365 days / 1e18;
        leverage.settlePremium(id);
        vm.warp(block.timestamp + VEST_SECONDS);
        (uint256 pendingA0, uint256 pendingA1) = leverage.pendingEarnings(lenderA, 2);
        (uint256 pendingB0,) = leverage.pendingEarnings(lenderB, 2);
        assertApproxEqAbs(pendingA0 + pendingB0, binPremium, 3);
        assertEq(pendingA1, 0);
    }

    /// @dev The long's bins sit above the price, so their return needs currency0, the quote, and the long holds
    /// currency1: the force close buys exactly that quote and settles the rest in kind.
    function test_forceCloseCreditsTheOwnerInKind() public {
        uint256 id = _openQuote0Long(2e20, 1e19, 1);
        vm.warp(block.timestamp + 30 days);
        _flagAndWaitGrace(id);
        uint256 closer0Before = _balance(currency0, closer);
        uint256 closer1Before = _balance(currency1, closer);
        vm.prank(closer);
        uint256 reward = leverage.forceClose(id, type(uint256).max);
        assertEq(reward, 0, "no quote is left after the deficit to reward");
        assertEq(_balance(currency0, closer), closer0Before, "the closer pays nothing");
        assertGt(_balance(currency1, closer), closer1Before, "the reward is a share of the base left");
        (, uint256 owner1) = leverage.owedOf(trader);
        assertGt(owner1, 0, "the owner keeps currency1, the base, in kind");
    }

    /// @dev The fallback: the closer pays the currency0 deficit and takes currency1 at the strike.
    function test_strikeFallbackOnLongPaysCurrency0AtTheStrike() public {
        uint256 id = _openQuote0Long(2e20, 1e19, 1);
        vm.warp(block.timestamp + 30 days);
        _flagAndWaitGrace(id);
        Position memory held = leverage.positionOf(id);
        uint256 needed0 = _quoteCost(1, 3, 2e20);
        assertTrue(_failDeficitPurchase(id));
        uint256 closer0Before = _balance(currency0, closer);
        uint256 closer1Before = _balance(currency1, closer);
        vm.prank(closer);
        leverage.forceClose(id, type(uint256).max);
        assertEq(closer0Before - _balance(currency0, closer), needed0, "the closer pays exactly the deficit");
        uint256 strikeOut = needed0 * held.maximum1 / held.maximum0;
        uint256 baseReward = (held.reserve1 - strikeOut) * 100 / 10_000;
        assertEq(_balance(currency1, closer) - closer1Before, strikeOut + baseReward);
    }

    function test_roundTripLeavesNothingOwed() public {
        uint256 longId = _openQuote0Long(2e20, 1e19, 1e17);
        uint256 shortId = _openQuote0Short(2e20, 1e19, 1e17);
        _swapAs(swapper, true, 1e19);
        vm.warp(block.timestamp + 10 days);
        vm.startPrank(trader);
        leverage.close(longId, 0.5e18, 0, trader);
        leverage.close(longId, 1e18, 0, trader);
        leverage.close(shortId, 1e18, 0, trader);
        vm.stopPrank();
        vm.prank(lenderA);
        leverage.withdraw(-5, 10, LENDER_LIQUIDITY, 0, 0, lenderA);
        vm.prank(lenderB);
        leverage.withdraw(-5, 10, LENDER_LIQUIDITY, 0, 0, lenderB);
        vm.prank(lenderA);
        leverage.collect(-5, 10, lenderA);
        vm.prank(lenderB);
        leverage.collect(-5, 10, lenderB);
        vm.prank(treasury);
        leverage.collect(0, 0, treasury);
        leverage.flushFeeVault();
        (uint256 totalLiquidity, uint256 openPositions, uint256 owed0, uint256 owed1) = leverage.totals();
        assertEq(totalLiquidity + openPositions + owed0 + owed1, 0);
    }

    /// @dev What v4 charges in currency0 to add `liquidity` to bins above the price.
    function _quoteCost(int24 lowerBin, uint8 binCount, uint128 liquidity) internal view returns (uint256 amount0) {
        // binCount <= MAX_BINS
        for (uint256 offset; offset < binCount; ++offset) {
            (int24 tickLower, int24 tickUpper) = leverage.binTicks(lowerBin + int24(int256(offset)));
            assertGt(tickLower, _currentTick());
            amount0 += SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidity, true
            );
        }
    }
}
