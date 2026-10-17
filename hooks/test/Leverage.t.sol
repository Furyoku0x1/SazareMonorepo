// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {LeverageFixture} from "./utils/LeverageFixture.sol";
import {Leverage} from "../src/leverage/Leverage.sol";
import {KernelExtension} from "../src/base/KernelExtension.sol";
import {Curve, LeverageMath} from "../src/libraries/leverage/LeverageMath.sol";
import {Bin, Borrow, LeverageBins, Position} from "../src/libraries/leverage/LeverageBins.sol";
import {LeverageEngine} from "../src/libraries/leverage/LeverageEngine.sol";
import {LeverageLending} from "../src/libraries/leverage/LeverageLending.sol";
import {LeverageTestLib} from "./utils/LeverageFixture.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {CallbackResult, CallbackType, ExecutionContext} from "core/src/types/KernelHookTypes.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract LeverageTest is LeverageFixture {
    uint256 internal constant Q128 = 1 << 128;
    bytes32 internal constant CLOSED_TOPIC = keccak256("Closed(uint256,address,uint256,uint256,uint256)");

    // ---------------------------------------------------------------- lending

    function test_depositPaysWhatThePoolChargesAndBinsMatchThePool() public {
        (uint256 paid0, uint256 paid1) = _deposit(lenderA, -2, 4, LENDER_LIQUIDITY);
        (uint256 expected0, uint256 expected1) = _addCost(-2, 4, LENDER_LIQUIDITY);
        assertEq(paid0, expected0, "paid0");
        assertEq(paid1, expected1, "paid1");
        // binIndex in [-2, 1]
        for (int24 binIndex = -2; binIndex < 2; ++binIndex) {
            assertEq(leverage.binOf(binIndex).liquidity, LENDER_LIQUIDITY);
            assertEq(leverage.lenderOf(lenderA, binIndex).liquidity, LENDER_LIQUIDITY);
            _assertBinMatchesPool(binIndex);
        }
        (uint256 totalLiquidity,,,) = leverage.totals();
        assertEq(totalLiquidity, 4 * uint256(LENDER_LIQUIDITY));
        _assertActiveLiquidityIsBins();
    }

    function test_directAddIsRefused() public {
        _seedLenders();
        uint128 before = StateLibrary.getLiquidity(manager, leveragePool);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(leverageKey, ModifyLiquidityParams(-600, 600, 1e18, 0), "");
        assertEq(StateLibrary.getLiquidity(manager, leveragePool), before);
    }

    function test_depositSlippageLimitReverts() public {
        (uint256 expected0,) = _addCost(-2, 4, LENDER_LIQUIDITY);
        vm.prank(lenderA);
        vm.expectRevert(LeverageLending.SlippageExceeded.selector);
        leverage.deposit(-2, 4, LENDER_LIQUIDITY, expected0 - 1, type(uint256).max);
    }

    function test_depositRejectsBadBinCounts() public {
        vm.startPrank(lenderA);
        vm.expectRevert(KernelExtension.InvalidAmount.selector);
        leverage.deposit(0, 0, LENDER_LIQUIDITY, type(uint256).max, type(uint256).max);
        vm.expectRevert(KernelExtension.InvalidAmount.selector);
        leverage.deposit(0, 17, LENDER_LIQUIDITY, type(uint256).max, type(uint256).max);
        vm.expectRevert(KernelExtension.InvalidAmount.selector);
        leverage.deposit(0, 1, 0, type(uint256).max, type(uint256).max);
        vm.stopPrank();
    }

    function test_depositOutsideTheTickRangeReverts() public {
        vm.prank(lenderA);
        vm.expectRevert(LeverageMath.InvalidBin.selector);
        leverage.deposit(1478, 1, LENDER_LIQUIDITY, type(uint256).max, type(uint256).max);
    }

    function test_withdrawReturnsPrincipalAndTakesOnlyIdle() public {
        _seedLenders();
        // Lend 75% of bin -3: 5e20 of its 2e21 stays idle, and either lender may take it.
        uint256 id = _open(trader, _openRequest(-3, _uniform(1, 1.5e21), true, 3e19, 1e17));
        vm.prank(lenderA);
        vm.expectRevert(LeverageBins.InsufficientLiquidity.selector);
        leverage.withdraw(-3, 1, 5e20 + 1, 0, 0, lenderA);
        uint256 before1 = _balance(currency1, lenderA);
        vm.prank(lenderA);
        (, uint256 amount1) = leverage.withdraw(-3, 1, 5e20, 0, 0, lenderA);
        assertGt(amount1, 0);
        assertEq(_balance(currency1, lenderA), before1 + amount1);
        vm.prank(lenderB);
        vm.expectRevert(LeverageBins.InsufficientLiquidity.selector);
        leverage.withdraw(-3, 1, 1, 0, 0, lenderB);
        _assertBinMatchesPool(-3);
        vm.prank(trader);
        leverage.close(id, 1e18, 0, trader);
        vm.prank(lenderB);
        leverage.withdraw(-3, 1, LENDER_LIQUIDITY, 0, 0, lenderB);
        _assertBinMatchesPool(-3);
    }

    function test_withdrawMoreThanOwnReverts() public {
        _deposit(lenderA, 0, 1, LENDER_LIQUIDITY);
        _deposit(lenderB, 0, 1, LENDER_LIQUIDITY);
        vm.prank(lenderA);
        vm.expectRevert(LeverageBins.InsufficientLiquidity.selector);
        leverage.withdraw(0, 1, LENDER_LIQUIDITY + 1, 0, 0, lenderA);
    }

    function test_swapFeesSplitAcrossLentAndIdleLiquidity() public {
        _seedLenders();
        // Lend 40% of bin -1, then trade inside it: its idle liquidity is 60% of the lenders'.
        _open(trader, _openRequest(-1, _uniform(1, 8e20), true, 5e19, 1e17));
        vm.prank(swapper);
        swapRouter.swap(
            leverageKey,
            SwapParams(true, -1e30, TickMath.getSqrtPriceAtTick(-300)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(_binOfTick(_currentTick()), -1);
        vm.prank(lenderA);
        leverage.collect(-1, 1, lenderA);
        vm.prank(lenderB);
        leverage.collect(-1, 1, lenderB);
        _swapAs(swapper, true, 1e18);
        _swapAs(swapper, false, 1e18);
        vm.prank(lenderA);
        (uint256 earnedA0, uint256 earnedA1) = leverage.collect(-1, 1, lenderA);
        vm.prank(lenderB);
        (uint256 earnedB0, uint256 earnedB1) = leverage.collect(-1, 1, lenderB);
        assertGt(earnedA0, 0);
        assertGt(earnedA1, 0);
        // Equal liquidity earns equal fees, though part of it is lent.
        assertApproxEqAbs(earnedA0, earnedB0, 1);
        assertApproxEqAbs(earnedA1, earnedB1, 1);
        // Both lenders together earn the whole 0.05% fee of each swap, less rounding.
        assertApproxEqAbs(earnedA0 + earnedB0, 5e14, 2);
        assertApproxEqAbs(earnedA1 + earnedB1, 5e14, 2);
    }

    // ---------------------------------------------------------------- opening

    function test_openLongBorrowsLiquidityAndHoldsBase() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        Position memory held = leverage.positionOf(id);
        assertEq(held.owner, trader);
        assertGt(held.reserve0, held.maximum0, "long covers M0 in base");
        assertEq(held.reserve1, 0, "long sold all quote");
        assertEq(held.collateral, 1e19);
        assertEq(held.escrow, 1e17);
        assertTrue(LeverageMath.chordHolds(held.reserve0, held.reserve1, held.maximum0, held.maximum1));
        (uint256 expected0, uint256 expected1) = _extremes(-3, 3, 2e20);
        assertEq(held.maximum0, expected0);
        assertEq(held.maximum1, expected1);
        // binIndex in [-3, -1]
        for (int24 binIndex = -3; binIndex < 0; ++binIndex) {
            assertEq(leverage.binOf(binIndex).borrowed, 2e20);
            _assertBinMatchesPool(binIndex);
        }
        (, uint256 openPositions,,) = leverage.totals();
        assertEq(openPositions, 1);
        _assertActiveLiquidityIsBins();
    }

    function test_openShortHoldsQuote() public {
        _seedLenders();
        uint256 id = _openShort(2e20, 1e19, 1e17);
        Position memory held = leverage.positionOf(id);
        assertEq(held.reserve0, 0, "short sold all base");
        assertGt(held.reserve1, held.maximum1, "short covers M1 in quote");
        assertTrue(LeverageMath.chordHolds(held.reserve0, held.reserve1, held.maximum0, held.maximum1));
    }

    function test_openUndercollateralizedReverts() public {
        _seedLenders();
        vm.expectRevert(LeverageEngine.Undercollateralized.selector);
        _openLong(2e20, 1e15, 1e17);
    }

    function test_openAboveUtilizationCeilingReverts() public {
        _seedLenders();
        uint128 aboveCeiling = uint128(uint256(2 * LENDER_LIQUIDITY) * 9501 / 10_000);
        vm.expectRevert(LeverageBins.UtilizationCeiling.selector);
        _open(trader, _openRequest(-1, _uniform(1, aboveCeiling), true, 1e20, 1e17));
        uint128 atCeiling = uint128(uint256(2 * LENDER_LIQUIDITY) * 9500 / 10_000);
        _open(trader, _openRequest(-1, _uniform(1, atCeiling), true, 1e20, 1e17));
        _assertBinMatchesPool(-1);
    }

    function test_openRejectsZeroCollateralAndEmptyBins() public {
        _seedLenders();
        vm.expectRevert(KernelExtension.InvalidAmount.selector);
        _openLong(2e20, 0, 1e17);
        uint128[] memory amounts = _uniform(3, 2e20);
        amounts[1] = 0;
        vm.expectRevert(LeverageEngine.InvalidAmount.selector);
        _open(trader, _openRequest(-3, amounts, true, 1e19, 1e17));
    }

    function test_inactiveInstallationRefusesNewRiskButLetsPositionsLeave() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        hook.deactivateExtension(leverageKey, IHookExtension(address(leverage)));
        vm.expectRevert(Leverage.InstallationInactive.selector);
        _deposit(lenderA, 0, 1, LENDER_LIQUIDITY);
        vm.expectRevert(Leverage.InstallationInactive.selector);
        _openLong(2e20, 1e19, 1e17);
        vm.prank(trader);
        leverage.close(id, 1e18, 0, trader);
        vm.prank(lenderA);
        leverage.withdraw(-5, 10, LENDER_LIQUIDITY, 0, 0, lenderA);
    }

    // ---------------------------------------------------------------- closing

    function test_fullCloseReturnsExactLiquidityAndDeletesPosition() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        vm.warp(block.timestamp + 7 days);
        uint256 before1 = _balance(currency1, trader);
        vm.prank(trader);
        uint256 payout = leverage.close(id, 1e18, 0, trader);
        assertEq(_balance(currency1, trader), before1 + payout);
        // binIndex in [-5, 4]
        for (int24 binIndex = -5; binIndex < 5; ++binIndex) {
            assertEq(leverage.binOf(binIndex).borrowed, 0);
            assertEq(leverage.binOf(binIndex).liquidity, 2 * LENDER_LIQUIDITY);
            _assertBinMatchesPool(binIndex);
        }
        assertEq(leverage.positionOf(id).owner, address(0));
        assertEq(leverage.borrowOf(id, 0).liquidity, 0);
        (, uint256 openPositions,,) = leverage.totals();
        assertEq(openPositions, 0);
        _assertActiveLiquidityIsBins();
    }

    function test_closeByAnotherAccountReverts() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        vm.prank(closer);
        vm.expectRevert(KernelExtension.Unauthorized.selector);
        leverage.close(id, 1e18, 0, closer);
    }

    function test_closeRejectsBadFractions() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        vm.startPrank(trader);
        vm.expectRevert(KernelExtension.InvalidAmount.selector);
        leverage.close(id, 0, 0, trader);
        vm.expectRevert(KernelExtension.InvalidAmount.selector);
        leverage.close(id, 1e18 + 1, 0, trader);
        vm.stopPrank();
    }

    function test_closeBelowMinimumProceedsReverts() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        vm.prank(trader);
        vm.expectRevert(LeverageEngine.InsufficientProceeds.selector);
        leverage.close(id, 1e18, 1e19, trader);
    }

    function test_partialCloseKeepsStrikeAndEscrow() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        Position memory before = leverage.positionOf(id);
        vm.prank(trader);
        leverage.close(id, 0.5e18, 0, trader);
        Position memory remaining = leverage.positionOf(id);
        assertEq(leverage.borrowOf(id, 0).liquidity, 1e20);
        assertEq(leverage.binOf(-3).borrowed, 1e20);
        assertEq(remaining.collateral, 0.5e19);
        assertEq(remaining.escrow, before.escrow, "no premium accrued in the same block");
        assertEq(remaining.reserve0, before.reserve0 - before.reserve0 / 2);
        assertTrue(
            LeverageMath.chordHolds(remaining.reserve0, remaining.reserve1, remaining.maximum0, remaining.maximum1)
        );
        // The strike is unchanged up to the extremes' rounding.
        assertApproxEqRel(
            uint256(remaining.maximum1) * 1e18 / remaining.maximum0,
            uint256(before.maximum1) * 1e18 / before.maximum0,
            1e3
        );
        vm.prank(trader);
        leverage.close(id, 1e18, 0, trader);
        assertEq(leverage.binOf(-3).borrowed, 0);
        _assertBinMatchesPool(-3);
    }

    function test_partialCloseRoundsReturnedLiquidityUp() public {
        _seedLenders();
        uint128[] memory amounts = _uniform(3, 2e20 + 1);
        uint256 id = _open(trader, _openRequest(-3, amounts, true, 1e19, 1e17));
        vm.prank(trader);
        leverage.close(id, 0.5e18, 0, trader);
        // ceil((2e20 + 1) / 2) returned, so the lenders get back at least their half.
        assertEq(leverage.borrowOf(id, 0).liquidity, 1e20);
        assertEq(leverage.binOf(-3).borrowed, 1e20);
    }

    function test_partialCloseLeavingNoStrikeIsRefused() public {
        _seedLenders();
        uint256 id = _open(trader, _openRequest(-3, _uniform(3, 1e18), true, 1e18, 1e17));
        // Returns all but one unit per bin: a remainder whose extremes round to zero has no strike to close at.
        vm.prank(trader);
        vm.expectRevert(LeverageEngine.InvalidAmount.selector);
        leverage.close(id, 1e18 - 1, 0, trader);
        vm.prank(trader);
        leverage.close(id, 1e18, 0, trader);
        assertEq(leverage.binOf(-3).borrowed, 0);
    }

    // ---------------------------------------------------------------- profit share

    /// @dev The lenders' part goes to the closed position's own bins and vests there with its premium; a bin the
    /// position never borrowed gets none of it (audit L1-2).
    function test_profitableLongPaysOnePercentSplitThreeWays() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        _swapAs(swapper, false, 4e19);
        (uint256 payout, uint256 proceeds, uint256 share) = _closeAndRecord(id);
        assertGt(share, 0, "a winning close pays the share");
        uint256 premiumPaid = 1e17 - (payout - proceeds);
        uint256 basis = 1e19 + premiumPaid;
        assertEq(share, (proceeds + share - basis) * 100 / 10_000, "1% of profit after costs");
        (, uint256 treasuryOwed) = leverage.owedOf(treasury);
        (, uint256 vaultOwed) = leverage.owedOf(address(feeVault));
        assertEq(treasuryOwed, share * 2500 / 10_000);
        assertEq(vaultOwed, share * 2500 / 10_000);
        uint256 lenderPart = share - treasuryOwed - vaultOwed;
        vm.warp(block.timestamp + VEST_SECONDS);
        uint256 vested;
        // binIndex in [-3, -1]: the position's bins
        for (int24 binIndex = -3; binIndex < 0; ++binIndex) {
            (, uint256 pendingA) = leverage.pendingEarnings(lenderA, binIndex);
            (, uint256 pendingB) = leverage.pendingEarnings(lenderB, binIndex);
            vested += pendingA + pendingB;
        }
        assertApproxEqAbs(vested, premiumPaid + lenderPart, 12, "premium and the lenders' part, fully vested");
        (, uint256 untouched) = leverage.pendingEarnings(lenderA, -5);
        assertEq(untouched, 0, "a bin the position never borrowed gets no share");
    }

    function test_losingLongPaysNoShare() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        _swapAs(swapper, true, 2e19);
        (,, uint256 share) = _closeAndRecord(id);
        assertEq(share, 0);
        (, uint256 treasuryOwed) = leverage.owedOf(treasury);
        assertEq(treasuryOwed, 0);
    }

    function test_addedCollateralRaisesTheBasis() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        vm.prank(trader);
        leverage.addCollateral(id, 5e18);
        Position memory held = leverage.positionOf(id);
        assertEq(held.collateral, 1.5e19);
        assertEq(held.reserve1, 5e18, "added collateral stays in quote");
        _swapAs(swapper, false, 4e19);
        (uint256 payout, uint256 proceeds, uint256 share) = _closeAndRecord(id);
        uint256 basis = 1.5e19 + (1e17 - (payout - proceeds));
        assertEq(share, (proceeds + share - basis) * 100 / 10_000);
    }

    function test_feeVaultFlushPullsItsPart() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        _swapAs(swapper, false, 4e19);
        _closeAndRecord(id);
        (, uint256 vaultOwed) = leverage.owedOf(address(feeVault));
        assertGt(vaultOwed, 0);
        uint256 flushed = leverage.flushFeeVault();
        assertEq(flushed, vaultOwed);
        assertEq(feeVault.received(Currency.unwrap(currency1)), vaultOwed);
        (,,, uint256 totalOwed1) = leverage.totals();
        (, uint256 treasuryOwed) = leverage.owedOf(treasury);
        assertEq(totalOwed1, treasuryOwed);
        assertEq(leverage.flushFeeVault(), 0);
    }

    function test_feeVaultThatPullsNothingReverts() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        _swapAs(swapper, false, 4e19);
        _closeAndRecord(id);
        feeVault.setPullNothing(true);
        vm.expectRevert(LeverageBins.UnexpectedDelta.selector);
        leverage.flushFeeVault();
    }

    // ---------------------------------------------------------------- premium

    function test_premiumAccruesAtTheTwoSlopeRateAndPaysLenders() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        uint256 elapsed = 30 days;
        vm.warp(block.timestamp + elapsed);
        // Utilization 10%, below the 80% kink: 4% · 0.1 / 0.8 = 0.5% a year on each bin's quote notional.
        (, uint256 notional1) = _extremes(-3, 3, 2e20);
        uint256 rateWad = LeverageMath.rateWad(_curve(), 2e20, 2 * uint256(LENDER_LIQUIDITY));
        assertEq(rateWad, 0.005e18);
        uint256 expected = notional1 * rateWad * elapsed / 365 days / 1e18;
        assertApproxEqAbs(leverage.premiumOwed(id), expected, 3);
        assertFalse(leverage.isDelinquent(id));
        uint256 owed = leverage.premiumOwed(id);
        uint256 paid = leverage.settlePremium(id);
        assertEq(paid, owed);
        Position memory held = leverage.positionOf(id);
        assertEq(held.escrow, 1e17 - paid);
        assertEq(held.premiumPaid, paid);
        assertEq(leverage.premiumOwed(id), 0);
        (, uint256 binNotional1) = _extremes(-2, 1, 2e20);
        (, uint256 pendingNow) = leverage.pendingEarnings(lenderA, -2);
        assertEq(pendingNow, 0, "paid premium vests: nothing is the lenders' yet");
        vm.warp(block.timestamp + VEST_SECONDS / 2);
        (, uint256 pendingHalf) = leverage.pendingEarnings(lenderA, -2);
        vm.warp(block.timestamp + VEST_SECONDS / 2);
        (, uint256 pendingA) = leverage.pendingEarnings(lenderA, -2);
        (, uint256 pendingB) = leverage.pendingEarnings(lenderB, -2);
        uint256 binPremium = binNotional1 * rateWad * elapsed / 365 days / 1e18;
        assertApproxEqAbs(pendingA + pendingB, binPremium, 3, "each bin's lenders get its own premium");
        assertApproxEqAbs(pendingHalf, pendingA / 2, 2, "linearly over the vesting period");
    }

    function test_rateIsSteepAboveTheKink() public {
        _seedLenders();
        uint128 ninetyPercent = uint128(uint256(2 * LENDER_LIQUIDITY) * 9 / 10);
        uint256 id = _open(trader, _openRequest(-1, _uniform(1, ninetyPercent), true, 2e20, 1e19));
        // 4% + 300% · (0.9 − 0.8) / 0.2 = 154% a year.
        assertEq(LeverageMath.rateWad(_curve(), ninetyPercent, 2 * uint256(LENDER_LIQUIDITY)), 1.54e18);
        vm.warp(block.timestamp + 1 days);
        (, uint256 notional1) = _extremes(-1, 1, ninetyPercent);
        assertApproxEqAbs(leverage.premiumOwed(id), notional1 * 1.54e18 * 1 days / 365 days / 1e18, 1);
    }

    function test_premiumIntegralIsExactAcrossUtilizationChanges() public {
        _seedLenders();
        uint256 first = _open(trader, _openRequest(-1, _uniform(1, 2e20), true, 1e19, 1e18));
        vm.warp(block.timestamp + 10 days);
        _open(trader, _openRequest(-1, _uniform(1, 1.4e21), true, 1e20, 1e18));
        vm.warp(block.timestamp + 10 days);
        (, uint256 notional1) = _extremes(-1, 1, 2e20);
        uint256 liquidity = 2 * uint256(LENDER_LIQUIDITY);
        uint256 lowRate = LeverageMath.rateWad(_curve(), 2e20, liquidity);
        uint256 highRate = LeverageMath.rateWad(_curve(), 1.6e21, liquidity);
        uint256 expected = notional1 * (lowRate * 10 days + highRate * 10 days) / 365 days / 1e18;
        assertApproxEqAbs(leverage.premiumOwed(first), expected, 3);
    }

    function test_addPremiumCuresAndSettles() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.warp(block.timestamp + 1 days);
        assertTrue(leverage.isDelinquent(id));
        assertEq(leverage.settlePremium(id), 0, "a delinquent escrow settles nothing");
        vm.prank(trader);
        leverage.addPremium(id, 1e17);
        assertFalse(leverage.isDelinquent(id));
        assertEq(leverage.premiumOwed(id), 0);
    }

    function test_onlyTheOwnerAddsToAPosition() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        vm.startPrank(closer);
        vm.expectRevert(KernelExtension.Unauthorized.selector);
        leverage.addPremium(id, 1e17);
        vm.expectRevert(KernelExtension.Unauthorized.selector);
        leverage.addCollateral(id, 1e17);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- force close

    /// @dev A force close needs a delinquent position flagged at least the grace period ago (audit L3-1).
    function test_forceCloseRequiresDelinquencyFlagAndGrace() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.expectRevert(Leverage.NotDelinquent.selector);
        leverage.flagDelinquent(id);
        vm.prank(closer);
        vm.expectRevert(Leverage.NotDelinquent.selector);
        leverage.forceClose(99, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(closer);
        vm.expectRevert(Leverage.NotFlagged.selector);
        leverage.forceClose(id, type(uint256).max);
        leverage.flagDelinquent(id);
        assertEq(leverage.positionOf(id).delinquentSince, block.timestamp);
        vm.warp(block.timestamp + GRACE_SECONDS - 1);
        // Flagging again does not restart the clock.
        leverage.flagDelinquent(id);
        vm.prank(closer);
        vm.expectRevert(Leverage.GracePending.selector);
        leverage.forceClose(id, type(uint256).max);
        vm.warp(block.timestamp + 1);
        vm.prank(closer);
        leverage.forceClose(id, type(uint256).max);
        assertEq(leverage.positionOf(id).owner, address(0));
    }

    /// @dev The grace period is the owner's time to cure: paying the premium clears the flag, and a later relapse waits
    /// out a fresh grace period.
    function test_curingDuringGraceClearsTheFlag() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.warp(block.timestamp + 1 days);
        leverage.flagDelinquent(id);
        vm.prank(trader);
        leverage.addPremium(id, 1e15);
        assertEq(leverage.positionOf(id).delinquentSince, 0);
        vm.warp(block.timestamp + GRACE_SECONDS);
        vm.prank(closer);
        vm.expectRevert(Leverage.NotDelinquent.selector);
        leverage.forceClose(id, type(uint256).max);
        vm.warp(block.timestamp + 365 days);
        vm.prank(closer);
        vm.expectRevert(Leverage.NotFlagged.selector);
        leverage.forceClose(id, type(uint256).max);
    }

    /// @dev A long's bins sit below the price, so their return needs quote and the long holds base. The force close
    /// buys exactly that quote, sells a little more base for the premium, and settles the rest in kind: the closer
    /// pays nothing and takes a share of the base left (audit L2-1).
    function test_forceCloseLongBuysOnlyTheDeficitAndSettlesInKind() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.warp(block.timestamp + 30 days);
        uint256 premium = leverage.premiumOwed(id);
        Position memory held = leverage.positionOf(id);
        _flagAndWaitGrace(id);
        premium = leverage.premiumOwed(id);
        uint256 closerQuoteBefore = _balance(currency1, closer);
        uint256 closerBaseBefore = _balance(currency0, closer);
        vm.prank(closer);
        uint256 reward = leverage.forceClose(id, type(uint256).max);
        assertEq(reward, 0, "no quote is left after the deficit to reward");
        assertEq(_balance(currency1, closer), closerQuoteBefore, "the closer pays nothing");
        uint256 baseReward = _balance(currency0, closer) - closerBaseBefore;
        assertGt(baseReward, 0, "the reward is a share of the base left");
        (uint256 ownerBase, uint256 ownerQuote) = leverage.owedOf(trader);
        assertGt(ownerBase, 0, "the owner keeps the base surplus in kind");
        assertApproxEqRel(baseReward * 10_000 / 100, ownerBase + baseReward, 0.02e18);
        assertLt(ownerQuote, premium, "at most the strike sale's extra unit of quote");
        // The premium reached the bins' streams.
        vm.warp(block.timestamp + VEST_SECONDS);
        (, uint256 binNotional1) = _extremes(-2, 1, 2e20);
        (, uint256 pendingA) = leverage.pendingEarnings(lenderA, -2);
        assertGt(pendingA, binNotional1 * 0.005e18 * 31 days / 365 days / 1e18 / 2 * 99 / 100);
        // binIndex in [-3, -1]
        for (int24 binIndex = -3; binIndex < 0; ++binIndex) {
            assertEq(leverage.binOf(binIndex).borrowed, 0);
            _assertBinMatchesPool(binIndex);
        }
        assertGt(held.reserve0, ownerBase);
    }

    /// @dev A short's bins sit above the price, so their return needs base and the short holds quote: the force close
    /// buys exactly the base, and the quote left pays premium, reward and owner.
    function test_forceCloseShortBuysTheBaseDeficitAndKeepsQuote() public {
        _seedLenders();
        uint256 id = _openShort(2e20, 1e19, 1);
        vm.warp(block.timestamp + 30 days);
        _flagAndWaitGrace(id);
        uint256 closerQuoteBefore = _balance(currency1, closer);
        vm.prank(closer);
        uint256 reward = leverage.forceClose(id, type(uint256).max);
        assertGt(reward, 0);
        assertEq(_balance(currency1, closer), closerQuoteBefore + reward);
        (uint256 ownerBase, uint256 ownerQuote) = leverage.owedOf(trader);
        assertEq(ownerBase, 0, "exactly the deficit was bought");
        assertApproxEqRel(reward * 10_000 / 100, ownerQuote + reward + leverage.premiumOwed(id), 0.02e18);
    }

    /// @dev Reserves that already cover the return need no trade at all: the force close leaves the price alone.
    function test_forceCloseWithNoDeficitMakesNoTrade() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.prank(trader);
        leverage.addCollateral(id, 1e20);
        vm.warp(block.timestamp + 30 days);
        _flagAndWaitGrace(id);
        (uint160 priceBefore,,,) = StateLibrary.getSlot0(manager, leveragePool);
        vm.prank(closer);
        leverage.forceClose(id, type(uint256).max);
        (uint160 priceAfter,,,) = StateLibrary.getSlot0(manager, leveragePool);
        assertEq(priceAfter, priceBefore);
        assertEq(leverage.positionOf(id).owner, address(0));
    }

    /// @dev Audit L2-1: borrowing the depth below a long for free no longer forces the strike. The deficit is bought from
    /// the liquidity the close itself returns, so the pool path completes and the closer pays nothing.
    function test_drainingDepthDoesNotForceTheStrike() public {
        _deposit(lenderA, -8, 13, LENDER_LIQUIDITY);
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.warp(block.timestamp + 30 days);
        _flagAndWaitGrace(id);
        uint128 drained = uint128(uint256(LENDER_LIQUIDITY) * 95 / 100);
        uint128[] memory amounts = _uniform(8, drained);
        // offset in [5, 7]: bins -3..-1, which the victim already borrows from
        for (uint256 offset = 5; offset < 8; ++offset) {
            amounts[offset] = drained - 2e20;
        }
        _open(closer, _openRequest(-8, amounts, false, 1e18, 1e18));
        uint256 closerQuoteBefore = _balance(currency1, closer);
        vm.prank(closer);
        leverage.forceClose(id, type(uint256).max);
        assertEq(_balance(currency1, closer), closerQuoteBefore, "no strike: the closer paid nothing");
        assertEq(leverage.positionOf(id).owner, address(0));
    }

    function test_strikeFallbackOnLongCloserPaysQuoteDeficit() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.warp(block.timestamp + 30 days);
        _flagAndWaitGrace(id);
        Position memory held = leverage.positionOf(id);
        // The bins sit below the price, so returning them needs quote only, and the long holds base only.
        (, uint256 needed1) = _addCost(-3, 3, 2e20);
        assertTrue(_failDeficitPurchase(id));
        uint256 closerQuoteBefore = _balance(currency1, closer);
        uint256 closerBaseBefore = _balance(currency0, closer);
        vm.prank(closer);
        leverage.forceClose(id, type(uint256).max);
        assertEq(closerQuoteBefore - _balance(currency1, closer), needed1, "closer pays exactly the deficit");
        uint256 strikeOut = needed1 * held.maximum0 / held.maximum1;
        uint256 baseReward = (held.reserve0 - strikeOut) * 100 / 10_000;
        assertEq(_balance(currency0, closer) - closerBaseBefore, strikeOut + baseReward, "at the strike K = M1 / M0");
        (uint256 ownerBase,) = leverage.owedOf(trader);
        assertLt(ownerBase, held.reserve0 - strikeOut - baseReward, "less the base sold for the premium");
        // binIndex in [-3, -1]
        for (int24 binIndex = -3; binIndex < 0; ++binIndex) {
            assertEq(leverage.binOf(binIndex).borrowed, 0);
            _assertBinMatchesPool(binIndex);
        }
    }

    function test_strikeFallbackOnShortCloserPaysBaseDeficit() public {
        _seedLenders();
        uint256 id = _openShort(2e20, 1e19, 1);
        vm.warp(block.timestamp + 30 days);
        _flagAndWaitGrace(id);
        Position memory held = leverage.positionOf(id);
        (uint256 needed0,) = _addCost(1, 3, 2e20);
        assertTrue(_failDeficitPurchase(id));
        uint256 closerBaseBefore = _balance(currency0, closer);
        uint256 closerQuoteBefore = _balance(currency1, closer);
        vm.prank(closer);
        uint256 reward = leverage.forceClose(id, type(uint256).max);
        assertEq(closerBaseBefore - _balance(currency0, closer), needed0, "closer pays exactly the base deficit");
        uint256 strikeOut = needed0 * held.maximum1 / held.maximum0;
        assertEq(reward, (held.reserve1 - strikeOut) * 100 / 10_000);
        assertEq(_balance(currency1, closer) - closerQuoteBefore, strikeOut + reward);
        (uint256 ownerBase, uint256 ownerQuote) = leverage.owedOf(trader);
        assertEq(ownerBase, 0);
        assertGt(ownerQuote, 0);
    }

    function test_strikeFallbackRespectsMaximumPaid() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.warp(block.timestamp + 30 days);
        _flagAndWaitGrace(id);
        (, uint256 needed1) = _addCost(-3, 3, 2e20);
        assertTrue(_failDeficitPurchase(id));
        vm.prank(closer);
        vm.expectRevert(LeverageEngine.SlippageExceeded.selector);
        leverage.forceClose(id, needed1 - 1);
    }

    /// @dev Only the pool's own shortfalls fall back. Any other failure, a Kernel callback starved of gas included,
    /// reverts the force close, so a closer cannot steer it to the strike.
    function test_forceCloseDoesNotFallBackOnOtherFailures() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.warp(block.timestamp + 30 days);
        _flagAndWaitGrace(id);
        bytes memory call = LeverageTestLib.deficitSwapCall(leverage, manager, id);
        vm.mockCallRevert(address(manager), call, abi.encodePacked(IKernelHook.GasBudgetExceeded.selector));
        vm.prank(closer);
        vm.expectRevert(IKernelHook.GasBudgetExceeded.selector);
        leverage.forceClose(id, type(uint256).max);
    }

    function test_attemptPoolCloseOnlyFromItself() public {
        vm.expectRevert(KernelExtension.Unauthorized.selector);
        leverage.attemptPoolClose("");
    }

    // ---------------------------------------------------------------- lifecycle and access

    function test_roundTripLeavesNothingAndAllowsRemoval() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        _swapAs(swapper, false, 4e19);
        vm.warp(block.timestamp + 10 days);
        vm.prank(trader);
        leverage.close(id, 1e18, 0, trader);
        // Lenders who leave before the premium vests forfeit what has not vested; these stay until it has.
        vm.warp(block.timestamp + VEST_SECONDS);
        hook.deactivateExtension(leverageKey, IHookExtension(address(leverage)));
        vm.expectRevert();
        hook.removeExtension(leverageKey, IHookExtension(address(leverage)));
        assertEq(leverage.lenderOf(lenderA, -3).liquidity, LENDER_LIQUIDITY, "lenders are whole in liquidity");
        vm.prank(lenderA);
        leverage.withdraw(-5, 10, LENDER_LIQUIDITY, 0, 0, lenderA);
        vm.prank(lenderB);
        leverage.withdraw(-5, 10, LENDER_LIQUIDITY, 0, 0, lenderB);
        vm.prank(lenderA);
        (uint256 earned0, uint256 earned1) = leverage.collect(-5, 10, lenderA);
        assertGt(earned0 + earned1, 0, "fees, premium and profit share");
        vm.prank(lenderB);
        leverage.collect(-5, 10, lenderB);
        vm.prank(treasury);
        leverage.collect(0, 0, treasury);
        leverage.flushFeeVault();
        (uint256 totalLiquidity, uint256 openPositions, uint256 owed0, uint256 owed1) = leverage.totals();
        assertEq(totalLiquidity + openPositions + owed0 + owed1, 0);
        assertEq(StateLibrary.getLiquidity(manager, leveragePool), 0);
        hook.removeExtension(leverageKey, IHookExtension(address(leverage)));
        assertFalse(leverage.installed());
    }

    /// @dev Audit L3-4: the curve changes as a new version, even with a position open; the rate index prices each
    /// interval at the version in force then. The bin width still needs empty bins.
    function test_curveChangesWithPositionsOpenPriceEachIntervalAtItsVersion() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        vm.warp(block.timestamp + 10 days);
        Curve memory next = _curve();
        next.slope1Wad = 0.08e18;
        hook.deactivateExtension(leverageKey, IHookExtension(address(leverage)));
        hook.configureExtension(leverageKey, IHookExtension(address(leverage)), _leverageSettings(next));
        hook.activateExtension(leverageKey, IHookExtension(address(leverage)));
        assertEq(leverage.curveVersionCount(), 2);
        assertEq(leverage.curve().slope1Wad, 0.08e18);
        vm.warp(block.timestamp + 10 days);
        (, uint256 notional1) = _extremes(-3, 3, 2e20);
        uint256 rateBefore = LeverageMath.rateWad(_curve(), 2e20, 2 * uint256(LENDER_LIQUIDITY));
        uint256 rateAfter = LeverageMath.rateWad(next, 2e20, 2 * uint256(LENDER_LIQUIDITY));
        assertEq(rateAfter, 2 * rateBefore);
        uint256 expected = notional1 * (rateBefore * 10 days + rateAfter * 10 days) / 365 days / 1e18;
        assertApproxEqAbs(leverage.premiumOwed(id), expected, 4);
        next.binWidth = 20;
        hook.deactivateExtension(leverageKey, IHookExtension(address(leverage)));
        vm.expectRevert();
        hook.configureExtension(leverageKey, IHookExtension(address(leverage)), _leverageSettings(next));
    }

    /// @dev Audit L3-4: a borrow below the deployment's minimum quote notional is refused, at open and as a partial
    /// close's remainder.
    function test_borrowsBelowTheMinimumAreRefused() public {
        _seedLenders();
        vm.expectRevert(LeverageEngine.BelowMinimumBorrow.selector);
        _open(trader, _openRequest(-3, _uniform(3, 1e4), true, 1e4, 1));
        uint256 id = _open(trader, _openRequest(-3, _uniform(3, 1e6), true, 1e6, 1e10));
        vm.prank(trader);
        vm.expectRevert(LeverageEngine.BelowMinimumBorrow.selector);
        leverage.close(id, 0.99e18, 0, trader);
        vm.prank(trader);
        leverage.close(id, 0.5e18, 0, trader);
    }

    /// @dev Audit L3-2: premium vests to the lenders present while it vests, so a deposit made around a settlement and
    /// withdrawn right after takes none of it.
    function test_sameTransactionDepositTakesNoPremium() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1e17);
        vm.warp(block.timestamp + 30 days);
        address attacker = makeAddr("attacker");
        _fundActor(attacker);
        _deposit(attacker, -3, 3, 200 * LENDER_LIQUIDITY);
        assertGt(leverage.settlePremium(id), 0);
        vm.prank(attacker);
        leverage.withdraw(-3, 3, 200 * LENDER_LIQUIDITY, 0, 0, attacker);
        vm.prank(attacker);
        (, uint256 taken) = leverage.collect(-3, 3, attacker);
        assertEq(taken, 0, "nothing vested while the attacker was in");
        vm.warp(block.timestamp + VEST_SECONDS);
        (, uint256 pendingA) = leverage.pendingEarnings(lenderA, -2);
        assertGt(pendingA, 0, "the lenders who stay get it");
    }

    /// @dev A stream with no lenders pauses: premium that vests while a bin is empty waits for the next lender, who
    /// collects it over the time that was left.
    function test_streamPausesWhileTheBinIsEmpty() public {
        _deposit(lenderA, -3, 6, LENDER_LIQUIDITY);
        uint256 id = _open(trader, _openRequest(-1, _uniform(1, 2e20), true, 1e19, 1e17));
        vm.warp(block.timestamp + 30 days);
        vm.prank(trader);
        leverage.close(id, 1e18, 0, trader);
        (uint256 remaining,) = leverage.streamOf(-1);
        assertGt(remaining, 0);
        vm.warp(block.timestamp + VEST_SECONDS / 4);
        vm.prank(lenderA);
        leverage.withdraw(-1, 1, LENDER_LIQUIDITY, 0, 0, lenderA);
        (uint256 left,) = leverage.streamOf(-1);
        assertApproxEqRel(left, remaining * 3 / 4, 1e15, "a quarter vested to lenderA before it left");
        vm.warp(block.timestamp + 30 days);
        (uint256 paused, uint256 vested) = leverage.streamOf(-1);
        assertEq(paused, left, "nothing vests to an empty bin");
        assertEq(vested, 0);
        _deposit(lenderB, -1, 1, LENDER_LIQUIDITY);
        vm.warp(block.timestamp + VEST_SECONDS * 3 / 4);
        vm.prank(lenderB);
        (, uint256 collected) = leverage.collect(-1, 1, lenderB);
        assertApproxEqAbs(collected, left, 2, "the next lender gets the rest over the time that was left");
        (uint256 drained,) = leverage.streamOf(-1);
        assertEq(drained, 0);
    }

    /// @dev Audit L1-2: dust liquidity far from the price takes none of the profit share: the lenders' part goes to the
    /// closed position's bins.
    function test_farBinDustTakesNoProfitShare() public {
        _seedLenders();
        address attacker = makeAddr("attacker");
        _fundActor(attacker);
        _deposit(attacker, -1478, 1, 1e30);
        uint256 id = _openLong(2e20, 1e19, 1e17);
        _swapAs(swapper, false, 4e19);
        (,, uint256 share) = _closeAndRecord(id);
        assertGt(share, 0);
        vm.warp(block.timestamp + VEST_SECONDS);
        (, uint256 attackerPending) = leverage.pendingEarnings(attacker, -1478);
        assertEq(attackerPending, 0);
    }

    function test_installRejectsCurvesOutsideTheDeploymentBounds() public {
        PoolKey memory other = PoolKey(currency0, currency1, 100, LEVERAGE_TICK_SPACING, leverageKey.hooks);
        Leverage second = new Leverage(IKernelHook(address(hook)), _deployment(other));
        catalog.admit(
            address(second),
            IHookCatalog.Entry(address(second).codehash, second.CALLBACK_MASK(), false, false, false, false, true)
        );
        hook.preparePool(other);
        Curve memory badCurve = _curve();
        badCurve.kinkWad = 1e18;
        vm.expectRevert();
        hook.installExtension(other, IHookExtension(address(second)), _leverageSettings(badCurve));
        badCurve = _curve();
        badCurve.forceCloseRewardBps = 1001;
        vm.expectRevert();
        hook.installExtension(other, IHookExtension(address(second)), _leverageSettings(badCurve));
        badCurve = _curve();
        badCurve.slope2Wad = 10e18;
        vm.expectRevert();
        hook.installExtension(other, IHookExtension(address(second)), _leverageSettings(badCurve));
        hook.installExtension(other, IHookExtension(address(second)), _leverageSettings(_curve()));
        assertTrue(second.installed());
    }

    function test_installOnAnotherPoolIsRefused() public {
        PoolKey memory other = PoolKey(currency0, currency1, 100, LEVERAGE_TICK_SPACING, leverageKey.hooks);
        hook.preparePool(other);
        vm.expectRevert();
        hook.installExtension(other, IHookExtension(address(leverage)), _leverageSettings(_curve()));
    }

    function test_constructorRejectsBadDeployments() public {
        Leverage.Deployment memory deployment = _deployment(leverageKey);
        deployment.utilizationCeilingBps = 10_000;
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        new Leverage(IKernelHook(address(hook)), deployment);
        deployment = _deployment(leverageKey);
        deployment.maxBinsPerPosition = 33;
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        new Leverage(IKernelHook(address(hook)), deployment);
        deployment = _deployment(leverageKey);
        deployment.treasuryShareBps = 7501;
        deployment.feeVaultShareBps = 2500;
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        new Leverage(IKernelHook(address(hook)), deployment);
        deployment = _deployment(leverageKey);
        deployment.feeVault = makeAddr("no code");
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        new Leverage(IKernelHook(address(hook)), deployment);
        deployment = _deployment(leverageKey);
        deployment.minRewardBps = 2;
        deployment.maxRewardBps = 1;
        vm.expectRevert(KernelExtension.InvalidConfiguration.selector);
        new Leverage(IKernelHook(address(hook)), deployment);
    }

    function test_callbacksAcceptOnlyTheirCallers() public {
        vm.expectRevert(KernelExtension.Unauthorized.selector);
        leverage.unlockCallback("");
        ExecutionContext memory context;
        vm.expectRevert(KernelExtension.Unauthorized.selector);
        leverage.onCallback(context, leverageKey, "");
    }

    function test_publicMutationsRefuseKernelReentry() public {
        // A Kernel operation in progress makes every public mutation refuse, so no extension callback can open or
        // close positions mid-swap.
        vm.mockCall(address(hook), abi.encodeCall(IKernelHook.ticketCount, ()), abi.encode(uint256(1)));
        vm.expectRevert(KernelExtension.ExecutionInProgress.selector);
        _deposit(lenderA, 0, 1, LENDER_LIQUIDITY);
    }

    // ---------------------------------------------------------------- audit regressions

    /// @dev Audit L1-1 (also L3-3, Sol-1): a partial close settles the whole position's premium, so it must pay it
    /// all. Before the fix a one-millionth close forgave a year of arrears and cleared delinquency.
    function test_partialCloseMustPayAllUnpaidPremium() public {
        _seedLenders();
        uint256 id = _openLong(2e20, 1e19, 1);
        vm.warp(block.timestamp + 365 days);
        assertTrue(leverage.isDelinquent(id));
        vm.prank(trader);
        vm.expectRevert(LeverageEngine.PremiumUnpaid.selector);
        leverage.close(id, 1e12, 0, trader);
        // A partial close whose proceeds cover the arrears goes through, and pays them in full.
        uint256 arrears = leverage.premiumOwed(id);
        vm.prank(trader);
        leverage.close(id, 0.5e18, 0, trader);
        assertEq(leverage.premiumOwed(id), 0);
        assertFalse(leverage.isDelinquent(id));
        vm.warp(block.timestamp + VEST_SECONDS);
        (, uint256 pendingA) = leverage.pendingEarnings(lenderA, -2);
        (, uint256 pendingB) = leverage.pendingEarnings(lenderB, -2);
        (, uint256 binNotional1) = _extremes(-2, 1, 2e20);
        assertApproxEqRel(pendingA + pendingB, binNotional1 * 0.005e18 * 365 days / 365 days / 1e18, 1e15);
        assertGt(arrears, 0);
    }

    /// @dev Audit L1-4 (also L3-5): the reward comes before premium, so a closer is paid even once the unpaid premium
    /// has eaten the equity. Before the fix the reward fell to zero exactly when lenders most needed a closer.
    function test_forceCloseRewardSurvivesDeepDelinquency() public {
        _seedLenders();
        uint128 ninetyPercent = uint128(uint256(2 * LENDER_LIQUIDITY) * 9 / 10);
        uint256 id = _open(trader, _openRequest(-1, _uniform(1, ninetyPercent), true, 2e20, 1));
        // 154% a year for ten years is far more premium than the position holds.
        vm.warp(block.timestamp + 3650 days);
        _flagAndWaitGrace(id);
        uint256 closerBaseBefore = _balance(currency0, closer);
        vm.prank(closer);
        leverage.forceClose(id, type(uint256).max);
        assertGt(_balance(currency0, closer), closerBaseBefore, "the closer still gets its share of what is left");
        (, uint256 ownerQuote) = leverage.owedOf(trader);
        assertEq(ownerQuote, 0, "the premium took all the quote");
    }

    /// @dev Audit Sol-3: premium rounds up, so settling every few minutes cannot floor a small borrow's premium to
    /// zero. A borrow settled often pays at least as much as its twin settled once.
    function test_frequentSettlementCannotFloorPremiumAway() public {
        _seedLenders();
        hook.deactivateExtension(leverageKey, IHookExtension(address(leverage)));
        Curve memory withBase = _curve();
        withBase.baseRateWad = 0.05e18;
        hook.configureExtension(leverageKey, IHookExtension(address(leverage)), _leverageSettings(withBase));
        hook.activateExtension(leverageKey, IHookExtension(address(leverage)));
        uint256 settledOften = _open(trader, _openRequest(-1, _uniform(1, 1e7), true, 1e7, 1e9));
        uint256 settledOnce = _open(trader, _openRequest(-1, _uniform(1, 1e7), true, 1e7, 1e9));
        uint256 paidOften;
        // Ten ten-minute intervals.
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 600);
            paidOften += leverage.settlePremium(settledOften);
        }
        uint256 paidOnce = leverage.settlePremium(settledOnce);
        assertGt(paidOnce, 0);
        assertGe(paidOften, paidOnce);
        assertGe(paidOften, 10, "at least a unit an interval");
    }

    /// @dev Audit Sol-2: v4 checks a tick's liquidity only as it is added, so a deposit could fill the room borrowed
    /// liquidity needs to return. Each bin, idle plus borrowed, is held to half the per-tick cap.
    function test_depositPastHalfTheTickCapIsRefused() public {
        uint128 binCap = Pool.tickSpacingToMaxLiquidityPerTick(LEVERAGE_TICK_SPACING) / 2;
        // A bin far below the price costs almost nothing per unit of liquidity.
        _deposit(lenderA, -1470, 1, binCap);
        vm.prank(lenderB);
        vm.expectRevert(LeverageBins.BinFull.selector);
        leverage.deposit(-1470, 1, 1, type(uint256).max, type(uint256).max);
        vm.prank(lenderA);
        leverage.withdraw(-1470, 1, 1, 0, 0, lenderA);
        _deposit(lenderB, -1470, 1, 1);
    }

    /// @dev Audit L1-3: a fee poke moves only fees. If another extension's hook delta changed what the pool pays or
    /// charges on it, the difference would come out of other users' custody, so collect refuses it.
    function test_feePokeWithAHookDeltaIsRefused() public {
        _seedLenders();
        (int24 tickLower, int24 tickUpper) = leverage.binTicks(0);
        ModifyLiquidityParams memory poke = ModifyLiquidityParams(tickLower, tickUpper, 0, bytes32(uint256(0)));
        vm.mockCall(
            address(manager),
            abi.encodeCall(IPoolManager.modifyLiquidity, (leverageKey, poke, "")),
            abi.encode(toBalanceDelta(-1, 0), toBalanceDelta(0, 0))
        );
        vm.prank(lenderA);
        vm.expectRevert(LeverageBins.UnexpectedDelta.selector);
        leverage.collect(0, 1, lenderA);
    }

    /// @dev Audit L2-3: liquidity added while the installation is inactive (every reconfiguration opens such a window)
    /// must not block reactivation. A check of the pool's liquidity at activation let a dust LP brick it; it is gone.
    function test_liquidityAddedWhileInactiveDoesNotBlockReactivation() public {
        _seedLenders();
        hook.deactivateExtension(leverageKey, IHookExtension(address(leverage)));
        int24 lowest = TickMath.minUsableTick(LEVERAGE_TICK_SPACING);
        int24 highest = TickMath.maxUsableTick(LEVERAGE_TICK_SPACING);
        modifyLiquidityRouter.modifyLiquidity(leverageKey, ModifyLiquidityParams(lowest, highest, 1, 0), "");
        hook.activateExtension(leverageKey, IHookExtension(address(leverage)));
        (, bool active,,) = hook.installationFlags(leveragePool, address(leverage));
        assertTrue(active);
    }

    // ---------------------------------------------------------------- helpers

    function _valueInQuote(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96) + amount1;
    }

    function _closeAndRecord(uint256 positionId) internal returns (uint256 payout, uint256 proceeds, uint256 share) {
        vm.recordLogs();
        vm.prank(trader);
        payout = leverage.close(positionId, 1e18, 0, trader);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // logs.length is bounded by the close's events
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != CLOSED_TOPIC) continue;
            (,, proceeds, share) = abi.decode(logs[i].data, (address, uint256, uint256, uint256));
        }
    }

    /// @dev What v4 charges to add `liquidity` to each of `binCount` bins at the current price, rounded up.
    function _addCost(int24 lowerBin, uint8 binCount, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = StateLibrary.getSlot0(manager, leveragePool);
        // binCount <= MAX_BINS
        for (uint256 offset; offset < binCount; ++offset) {
            (int24 tickLower, int24 tickUpper) = leverage.binTicks(lowerBin + int24(int256(offset)));
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
            if (tick < tickLower) {
                amount0 += SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
            } else if (tick < tickUpper) {
                amount0 += SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
                amount1 += SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
            } else {
                amount1 += SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
            }
        }
    }

    function _extremes(int24 lowerBin, uint8 binCount, uint128 liquidity)
        internal
        view
        returns (uint256 maximum0, uint256 maximum1)
    {
        // binCount <= MAX_BINS
        for (uint256 offset; offset < binCount; ++offset) {
            (int24 tickLower, int24 tickUpper) = leverage.binTicks(lowerBin + int24(int256(offset)));
            (uint256 binMaximum0, uint256 binMaximum1) = LeverageMath.extremes(liquidity, tickLower, tickUpper);
            maximum0 += binMaximum0;
            maximum1 += binMaximum1;
        }
    }
}
