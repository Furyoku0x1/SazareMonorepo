// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LeverageFixture} from "./utils/LeverageFixture.sol";
import {Curve, LeverageMath} from "../src/libraries/leverage/LeverageMath.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {LeverageBins, Position} from "../src/libraries/leverage/LeverageBins.sol";
import {LeverageEngine} from "../src/libraries/leverage/LeverageEngine.sol";

/// forge-config: default.fuzz.runs = 256
contract LeverageFuzzTest is LeverageFixture {
    function setUp() public override {
        super.setUp();
        _seedLenders();
    }

    /// @dev A partial close returns at least its fraction of every borrow, the rest stays borrowed, the basis splits
    /// without loss, and the remainder is solvent.
    function testFuzz_partialCloseConservesLiquidityAndBasis(uint128 perBin, uint256 fractionWad) public {
        perBin = uint128(bound(perBin, 1e18, 5e20));
        // A dust fraction rounds its reserve portion to zero while its returned liquidity rounds up to a wei, so it
        // reverts for proceeds; from 1e-9 on, the portion holds far more than the rounding.
        fractionWad = bound(fractionWad, 1e9, 1e18 - 1);
        uint256 id = _openLong(perBin, perBin / 5, 1e17);
        Position memory before = leverage.positionOf(id);
        vm.prank(trader);
        try leverage.close(id, fractionWad, 0, trader) {}
        catch (bytes memory reason) {
            // Only a remainder too small to keep a strike, or below the minimum borrow, is refused; the owner closes it
            // in full instead.
            bool tooSmall = bytes4(reason) == LeverageEngine.InvalidAmount.selector
                || bytes4(reason) == LeverageEngine.BelowMinimumBorrow.selector;
            assertTrue(tooSmall);
            assertLe(LeverageMath.portionDown(perBin, 1e18 - fractionWad), 1e5);
            return;
        }
        Position memory remaining = leverage.positionOf(id);
        uint256 returned = perBin - leverage.borrowOf(id, 0).liquidity;
        assertGe(returned, LeverageMath.portionDown(perBin, fractionWad));
        assertLe(returned, LeverageMath.portionUp(perBin, fractionWad));
        // offset < 3: the position's bins
        for (uint256 offset; offset < 3; ++offset) {
            int24 binIndex = -3 + int24(int256(offset));
            assertEq(leverage.binOf(binIndex).borrowed, leverage.borrowOf(id, offset).liquidity);
            _assertBinMatchesPool(binIndex);
        }
        assertEq(remaining.collateral, before.collateral - LeverageMath.portionDown(before.collateral, fractionWad));
        assertEq(remaining.reserve0, before.reserve0 - LeverageMath.portionDown(before.reserve0, fractionWad));
        assertTrue(
            LeverageMath.chordHolds(remaining.reserve0, remaining.reserve1, remaining.maximum0, remaining.maximum1)
        );
        vm.prank(trader);
        leverage.close(id, 1e18, 0, trader);
        assertEq(leverage.binOf(-3).borrowed, 0);
    }

    /// @dev Settling at any intermediate time charges the same premium as settling once: the rate index is an exact
    /// integral. Two identical borrows, one settled twice and one once, pay the same up to the floors.
    function testFuzz_premiumDoesNotDependOnSettlementTiming(uint32 firstSeconds, uint32 secondSeconds) public {
        firstSeconds = uint32(bound(firstSeconds, 1, 365 days));
        secondSeconds = uint32(bound(secondSeconds, 1, 365 days));
        uint256 settledTwice = _openLong(2e20, 1e20, 1e19);
        uint256 settledOnce = _openLong(2e20, 1e20, 1e19);
        vm.warp(block.timestamp + firstSeconds);
        uint256 paid = leverage.settlePremium(settledTwice);
        vm.warp(block.timestamp + secondSeconds);
        paid += leverage.settlePremium(settledTwice);
        uint256 paidOnce = leverage.settlePremium(settledOnce);
        assertGt(paidOnce, 0);
        // Premium rounds up: settling more often never pays less, and at most a unit per bin per extra settlement more.
        assertGe(paid, paidOnce);
        assertApproxEqAbs(paid, paidOnce, 3);
    }

    /// @dev Near the chord's edge a price move can leave less equity than the close's swap costs, so the owner's own
    /// close reverts for its proceeds. Once delinquent, the force close then falls back to the strike on its own.
    function testFuzz_ownerShortfallFallsBackToTheStrike(uint128 perBin, uint128 collateral, bool long, int256 swapSeed)
        public
    {
        _setBaseRate(0.05e18);
        perBin = uint128(bound(perBin, 1e15, 4e20));
        collateral = uint128(bound(collateral, 1, perBin / 4 + 1));
        uint256 id;
        vm.prank(trader);
        try leverage.open(
            long
                ? _openRequest(-3, _uniform(3, perBin), true, collateral, 1)
                : _openRequest(1, _uniform(3, perBin), false, collateral, 1)
        ) returns (
            uint256 opened
        ) {
            id = opened;
        } catch {
            return;
        }
        int256 swapAmount = bound(swapSeed, -3e20, 3e20);
        if (swapAmount > 1e9) _swapAs(swapper, false, uint256(swapAmount));
        if (swapAmount < -1e9) _swapAs(swapper, true, uint256(-swapAmount));
        vm.warp(block.timestamp + 365 days);
        uint256 snapshot = vm.snapshotState();
        vm.prank(trader);
        try leverage.close(id, 1e18, 0, trader) {
            return;
        } catch (bytes memory reason) {
            bool shortfall = bytes4(reason) == LeverageEngine.InsufficientProceeds.selector
                || bytes4(reason) == LeverageBins.UnexpectedDelta.selector;
            assertTrue(shortfall, "an owner's close fails only for the pool's shortfall");
        }
        vm.revertToState(snapshot);
        _flagAndWaitGrace(id);
        vm.prank(closer);
        leverage.forceClose(id, type(uint256).max);
        (, uint256 openPositions,,) = leverage.totals();
        assertEq(openPositions, 0);
    }

    /// @dev A position opened as close to the chord's edge as the fuzzer finds still closes at the strike: the closer
    /// bears the rounding dust instead of the position being stranded.
    function testFuzz_strikeCloseCompletesAtTheChordEdge(uint128 perBin, uint128 collateral, bool long, int256 swapSeed)
        public
    {
        // A dust borrow at the default zero base rate pays almost nothing and never turns delinquent (see the
        // audit); a 5% base rate makes a year's premium of any borrow from 1e9 up exceed the one-wei escrow.
        _setBaseRate(0.05e18);
        perBin = uint128(bound(perBin, 1e9, 4e20));
        collateral = uint128(bound(collateral, 1, perBin / 4 + 1));
        uint256 id;
        vm.prank(trader);
        try leverage.open(
            long
                ? _openRequest(-3, _uniform(3, perBin), true, collateral, 1)
                : _openRequest(1, _uniform(3, perBin), false, collateral, 1)
        ) returns (
            uint256 opened
        ) {
            id = opened;
        } catch {
            return;
        }
        int256 swapAmount = bound(swapSeed, -3e20, 3e20);
        if (swapAmount > 1e9) _swapAs(swapper, false, uint256(swapAmount));
        if (swapAmount < -1e9) _swapAs(swapper, true, uint256(-swapAmount));
        vm.warp(block.timestamp + 365 days);
        _flagAndWaitGrace(id);
        // Force the fallback: the strike path is the one that must cope with the chord's edge. A position that needs
        // no purchase makes no pool trade and has no strike to test.
        vm.assume(_failDeficitPurchase(id));
        vm.prank(closer);
        leverage.forceClose(id, type(uint256).max);
        assertEq(leverage.binOf(-3).borrowed + leverage.binOf(1).borrowed, 0);
        (, uint256 openPositions,,) = leverage.totals();
        assertEq(openPositions, 0);
    }

    function _setBaseRate(uint64 baseRateWad) internal {
        hook.deactivateExtension(leverageKey, IHookExtension(address(leverage)));
        Curve memory next = _curve();
        next.baseRateWad = baseRateWad;
        hook.configureExtension(leverageKey, IHookExtension(address(leverage)), _leverageSettings(next));
        hook.activateExtension(leverageKey, IHookExtension(address(leverage)));
    }

    /// @dev A withdrawal succeeds exactly when it is within the lender's liquidity and the bin's idle liquidity.
    function testFuzz_withdrawalNeverTakesBorrowedLiquidity(uint128 borrowed, uint128 amount) public {
        borrowed = uint128(bound(borrowed, 1e18, 1.9e21));
        amount = uint128(bound(amount, 1, LENDER_LIQUIDITY));
        _open(trader, _openRequest(-3, _uniform(1, borrowed), true, borrowed / 2, 1e17));
        uint128 idle = _idle(-3);
        vm.prank(lenderA);
        if (amount > idle) vm.expectRevert(LeverageBins.InsufficientLiquidity.selector);
        leverage.withdraw(-3, 1, amount, 0, 0, lenderA);
        assertEq(leverage.binOf(-3).borrowed, borrowed);
        _assertBinMatchesPool(-3);
    }

    /// @dev After any price move a close either completes, returning every borrowed unit to its bin, or reverts only
    /// for proceeds: the fees and slippage of its own swap.
    function testFuzz_closeAfterAnyPriceMove(uint128 perBin, uint256 swapAmount, bool long, bool swapUp) public {
        perBin = uint128(bound(perBin, 1e18, 4e20));
        swapAmount = bound(swapAmount, 1e15, 3e20);
        uint256 id = long ? _openLong(perBin, perBin / 4, 1e17) : _openShort(perBin, perBin / 4, 1e17);
        _swapAs(swapper, !swapUp, swapAmount);
        vm.warp(block.timestamp + 3 days);
        vm.prank(trader);
        try leverage.close(id, 1e18, 0, trader) {
            // binIndex in [-5, 4]
            for (int24 binIndex = -5; binIndex < 5; ++binIndex) {
                assertEq(leverage.binOf(binIndex).borrowed, 0);
                assertEq(leverage.binOf(binIndex).liquidity, 2 * LENDER_LIQUIDITY);
                _assertBinMatchesPool(binIndex);
            }
            _assertActiveLiquidityIsBins();
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), LeverageEngine.InsufficientProceeds.selector);
        }
    }

    /// @dev Once delinquent, any position force closes, through the pool or its strike fallback, and the lenders get
    /// every unit back.
    function testFuzz_forceCloseAlwaysCompletes(uint128 perBin, uint256 swapAmount, bool long, bool swapUp) public {
        perBin = uint128(bound(perBin, 1e18, 4e20));
        swapAmount = bound(swapAmount, 1e15, 3e20);
        uint256 id = long ? _openLong(perBin, perBin / 4, 1) : _openShort(perBin, perBin / 4, 1);
        _swapAs(swapper, !swapUp, swapAmount);
        vm.warp(block.timestamp + 1 days);
        assertTrue(leverage.isDelinquent(id));
        _flagAndWaitGrace(id);
        vm.prank(closer);
        leverage.forceClose(id, type(uint256).max);
        // binIndex in [-5, 4]
        for (int24 binIndex = -5; binIndex < 5; ++binIndex) {
            assertEq(leverage.binOf(binIndex).borrowed, 0);
            _assertBinMatchesPool(binIndex);
        }
        assertEq(leverage.positionOf(id).owner, address(0));
    }
}
