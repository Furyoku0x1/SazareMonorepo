// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {CloseRequest, Ledger, OpenRequest, Position, Stream} from "../../src/metric/vault/VaultTypes.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {VaultFixture} from "./utils/VaultFixture.sol";

/// @notice Property fuzz tests of the no-pool vault: closes, lender round trips, force closes, partial closes, the
/// profit share's sources.
contract VaultFuzzTest is VaultFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MIN_NOTIONAL = 101e6;
    uint256 internal constant MAX_NOTIONAL = 500_000e6;
    /// @dev A close moves a unit or two either way through the rounded release and repayment.
    uint256 internal constant CLOSE_ROUNDING = 3;
    /// @dev Values at the bid round down twice; two units cover it.
    uint256 internal constant VALUE_ROUNDING = 2;

    /// @dev A position's range and size, chosen from fuzzed inputs.
    struct Shape {
        bool isLong;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 notional;
    }

    /// @dev Lenders hold four times the largest notional, so no bounded open meets the utilization ceiling.
    function setUp() public override {
        super.setUp();
        deposit(lender, 2_000e18, 2_000_000e6);
    }

    // ---------------------------------------------------------------- open then close

    function testFuzz_openThenClose_keepsLendersAndTraderWhole(
        bool isLong,
        uint256 distanceTicks,
        uint256 widthTicks,
        uint256 notional,
        uint256 collateralExtra,
        uint256 escrow
    ) public {
        Shape memory shape = _shape(isLong, distanceTicks, widthTicks, bound(notional, MIN_NOTIONAL, MAX_NOTIONAL));
        uint256 collateral = minimumCollateral(shape.tickLower, shape.tickUpper, shape.liquidity)
            + bound(collateralExtra, 0, shape.notional / 10);
        escrow = bound(escrow, 0, 1_000e6);
        uint160 sqrtBidX96 = source.sqrtBidX96();
        uint256 lendersBefore = _lendersValue(sqrtBidX96);
        uint256 positionId = _open(shape, collateral, escrow);
        (uint256 repay0, uint256 repay1) = repaymentFor(positionId, WAD);
        (uint256 paid0, uint256 paid1) = closeFull(positionId, repay0, repay1);
        uint256 traderValue = VaultMath.valueInToken1(paid0, paid1, sqrtBidX96, false);
        // The release is the range's holdings across the band, rounded down, and the repayment rounds up.
        assertGe(_lendersValue(sqrtBidX96) + CLOSE_ROUNDING, lendersBefore, "lenders lose nothing on a round trip");
        assertGe(traderValue + CLOSE_ROUNDING, collateral + escrow, "trader recovers collateral and escrow");
        assertLe(traderValue, collateral + escrow, "trader takes nothing beyond what was put in");
        assertLedger();
    }

    // ---------------------------------------------------------------- close after a price move

    function testFuzz_closeAfterPriceMove_lendersGetAtLeastHoldings(
        bool isLong,
        uint256 distanceTicks,
        uint256 widthTicks,
        uint256 notional,
        uint256 collateralExtra,
        int256 moveTicks
    ) public {
        Shape memory shape = _shape(isLong, distanceTicks, widthTicks, bound(notional, MIN_NOTIONAL, MAX_NOTIONAL));
        uint256 collateral = minimumCollateral(shape.tickLower, shape.tickUpper, shape.liquidity)
            + bound(collateralExtra, 0, shape.notional / 10);
        uint256 positionId = _open(shape, collateral, 100e6);
        setPrice(PRICE_TICK + int24(bound(moveTicks, -5_000, 5_000)), 1);
        uint160 sqrtBidX96 = source.sqrtBidX96();
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(shape.tickLower, shape.tickUpper);
        (uint256 cheapest0, uint256 cheapest1) = cheapestRepayment(positionId);
        assertTrue(
            VaultMath.repays(cheapest0, cheapest1, shape.liquidity, sqrtLowerX96, sqrtUpperX96),
            "the cheapest repayment at the new bid passes the rule"
        );
        (uint256 holdings0, uint256 holdings1) =
            VaultMath.holdingsAt(shape.liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96);
        uint256 holdingsValue = VaultMath.valueInToken1(holdings0, holdings1, sqrtBidX96, false);
        uint256 lendersBefore = _lendersValue(sqrtBidX96);
        // The reserves may lack the cheapest mix (a long holds no token0), so pay what they hold; any passing
        // repayment is worth at least the range's holdings at the bid, the cheapest point of the rule's curve.
        (uint256 repay0, uint256 repay1) = repaymentFor(positionId, WAD);
        closeFull(positionId, repay0, repay1);
        assertGe(
            _lendersValue(sqrtBidX96) + VALUE_ROUNDING,
            lendersBefore + holdingsValue,
            "lenders receive at least the range's holdings at the bid"
        );
        assertLedger();
    }

    // ---------------------------------------------------------------- lenders

    function testFuzz_depositThenWithdraw_neverGainsValue(
        uint256 amount0,
        uint256 amount1,
        bool withDebt,
        bool isLong,
        uint256 notional,
        int256 moveTicks
    ) public {
        // An open debt makes the deposit and withdrawal value bounds differ; a price move pulls them apart.
        if (withDebt) {
            Shape memory shape = _shape(isLong, 200, 1_000, bound(notional, MIN_NOTIONAL, MAX_NOTIONAL));
            _open(shape, minimumCollateral(shape.tickLower, shape.tickUpper, shape.liquidity) + 1e6, 100e6);
        }
        setPrice(PRICE_TICK + int24(bound(moveTicks, -3_000, 3_000)), 1);
        amount0 = bound(amount0, 0, 500e18);
        amount1 = bound(amount1, 0, 1_000_000e6);
        // A dust deposit mints no shares and reverts by design.
        if (amount1 < 1e6) amount1 = 1e6;
        address depositor = makeAddr("depositor");
        fundWith(depositor, base);
        fundWith(depositor, quote);
        uint256 shares = deposit(depositor, amount0, amount1);
        vm.prank(depositor);
        (uint256 out0, uint256 out1,) = vault.withdraw(vaultId, shares, 0, 0, depositor);
        uint160 sqrtBidX96 = source.sqrtBidX96();
        assertLe(
            VaultMath.valueInToken1(out0, out1, sqrtBidX96, false),
            VaultMath.valueInToken1(amount0, amount1, sqrtBidX96, false),
            "a deposit and withdrawal at one band never gain value"
        );
        assertLedger();
    }

    // ---------------------------------------------------------------- force close

    function testFuzz_forceClose_afterGraceNeverReverts(
        bool isLong,
        uint256 distanceTicks,
        uint256 widthTicks,
        uint256 notional,
        uint256 collateralExtra,
        uint256 delinquentSeconds,
        uint256 lateSeconds
    ) public {
        Shape memory shape = _shape(isLong, distanceTicks, widthTicks, bound(notional, MIN_NOTIONAL, MAX_NOTIONAL));
        uint256 collateral = minimumCollateral(shape.tickLower, shape.tickUpper, shape.liquidity)
            + bound(collateralExtra, 0, shape.notional / 10);
        // No escrow: premium rounds up to at least a unit, so the position is delinquent after one second.
        uint256 positionId = _open(shape, collateral, 0);
        vm.warp(block.timestamp + bound(delinquentSeconds, 1, 365 days));
        vault.flag(positionId);
        vm.warp(block.timestamp + defaultParameters().graceSeconds + bound(lateSeconds, 0, 30 days));
        (uint256 left0, uint256 left1) = _leftAfterScaledRepayment(vault.positionOf(positionId));
        Ledger memory before = vault.ledgerOf(vaultId);
        uint256 vesting0Before = vault.streamOf(vaultId).remaining0;
        vm.prank(closer);
        (uint256 reward0, uint256 reward1) = vault.forceClose(positionId);
        uint256 rewardBps = defaultParameters().forceCloseRewardBps;
        // Arrears are paid before the reward, so what was left after repayment bounds it.
        assertLe(reward0 * BPS, left0 * rewardBps, "reward0 at most its share of what was left");
        assertLe(reward1 * BPS, left1 * rewardBps, "reward1 at most its share of what was left");
        assertEq(vault.accrualOf(vaultId).outstanding0, 0, "nothing outstanding0 after the only position");
        assertEq(vault.accrualOf(vaultId).outstanding1, 0, "nothing outstanding1 after the only position");
        _assertToken0ArrearsSlice(before, vesting0Before);
        assertLedger();
    }

    // ---------------------------------------------------------------- partial close

    function testFuzz_partialClose_restKeepsChord(
        bool isLong,
        uint256 distanceTicks,
        uint256 widthTicks,
        uint256 notional,
        uint256 fractionWad,
        int256 moveTicks
    ) public {
        Shape memory shape = _shape(isLong, distanceTicks, widthTicks, bound(notional, 2_000e6, MAX_NOTIONAL));
        // A 1% margin over the chord absorbs the rest's rounded-up extremes. An escrow of the whole notional pays any
        // realized charge the move costs, so the partial close is never refused for its premium.
        uint256 collateral = minimumCollateral(shape.tickLower, shape.tickUpper, shape.liquidity) + shape.notional / 100;
        uint256 positionId = _open(shape, collateral, shape.notional);
        setPrice(PRICE_TICK + int24(bound(moveTicks, -5_000, 5_000)), 1);
        // At most 90% closed keeps the rest's notional above the 100e6 minimum borrow.
        fractionWad = bound(fractionWad, 0.01e18, 0.9e18);
        uint128 closingLiquidity = uint128(VaultMath.portionDown(shape.liquidity, fractionWad));
        (uint256 repay0, uint256 repay1) = repaymentFor(positionId, fractionWad);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(shape.tickLower, shape.tickUpper);
        assertTrue(
            VaultMath.repays(repay0, repay1, closingLiquidity, sqrtLowerX96, sqrtUpperX96),
            "the closed fraction's repayment passes the rule"
        );
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: fractionWad, repay0: repay0, repay1: repay1}));
        Position memory rest = vault.positionOf(positionId);
        assertEq(rest.liquidity, shape.liquidity - closingLiquidity, "the rest keeps the unclosed liquidity");
        assertTrue(
            VaultMath.chordHolds(rest.reserve0, rest.reserve1, rest.maximum0, rest.maximum1),
            "the rest passes the chord"
        );
        assertTrue(
            VaultMath.repays(rest.reserve0, rest.reserve1, rest.liquidity, sqrtLowerX96, sqrtUpperX96),
            "the rest's reserves repay it"
        );
        assertLedger();
    }

    // ---------------------------------------------------------------- profit share

    /// @dev A winning short whose token1 leftover is small pays its profit share from the escrow refund, and the share
    /// is still exactly the profit share of what the trader would otherwise take.
    function testFuzz_profitShare_takenFromRefund(uint256 extraSeed, uint256 escrowSeed, uint256 moveSeed) public {
        deposit(lender, 100e18, 0);
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        uint128 liquidity = liquidityFor1(lower, upper, 5_000e6);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(lower, upper);
        (, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        uint256 extra1 = bound(extraSeed, 0, 1e6);
        OpenRequest memory request = openRequest(false, lower, upper, liquidity, uint128(maximum1 + extra1));
        request.escrow = uint128(bound(escrowSeed, 500e6, 5_000e6));
        uint256 shortId = open(request);
        // The price rises through the range: it repays all in token1 and the trader keeps its token0. Hourly points
        // at the range's top and at the end, as a keeper records them, so the realized charge is the crossing's alone.
        setPrice(upper, 1);
        vm.warp(block.timestamp + 1 hours);
        vault.recordPrice(vaultId);
        setPrice(PRICE_TICK + int24(int256(bound(moveSeed, 1_000, 5_000))), 1);
        vm.warp(block.timestamp + 1 hours);
        vault.recordPrice(vaultId);
        uint256 basis = vault.positionOf(shortId).basis;
        vm.recordLogs();
        (uint256 paid0, uint256 paid1) = closeFull(shortId, 0, maximum1);
        uint256 share = _closedShare(vm.getRecordedLogs());
        assertGt(share, extra1, "scenario: the share exceeds the token1 leftover, so the refund pays the rest");
        uint256 proceeds = VaultMath.priceTimes(paid0, source.sqrtBidX96(), false) + paid1 + share;
        uint256 expected = (proceeds - basis) * defaultParameters().profitShareBps / BPS;
        assertApproxEqAbs(share, expected, 1, "the share is the profit share of the proceeds");
        assertLedger();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A long lies wholly below the band, a short wholly above it, so each borrows a single token.
    function _shape(bool isLong, uint256 distanceTicks, uint256 widthTicks, uint256 notional)
        internal
        pure
        returns (Shape memory shape)
    {
        int24 distance = int24(int256(bound(distanceTicks, 0, 3_000)));
        int24 width = int24(int256(bound(widthTicks, 1, 3_000)));
        shape.isLong = isLong;
        shape.tickUpper = isLong ? PRICE_TICK - 1 - distance : PRICE_TICK + 1 + distance + width;
        shape.tickLower = shape.tickUpper - width;
        shape.liquidity = liquidityFor1(shape.tickLower, shape.tickUpper, notional);
        shape.notional = notional;
    }

    function _open(Shape memory shape, uint256 collateral, uint256 escrow) internal returns (uint256) {
        OpenRequest memory request =
            openRequest(shape.isLong, shape.tickLower, shape.tickUpper, shape.liquidity, uint128(collateral));
        request.escrow = uint128(escrow);
        return open(request);
    }

    /// @dev What a no-pool force close leaves after its repayment: the reserves scaled down to the repayment rule.
    function _leftAfterScaledRepayment(Position memory position) internal pure returns (uint256 left0, uint256 left1) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        uint256 fractionWad = VaultMath.scaleToRepay(
            position.reserve0, position.reserve1, position.liquidity, sqrtLowerX96, sqrtUpperX96
        );
        uint256 repay0 = VaultMath.portionUp(position.reserve0, fractionWad);
        uint256 repay1 = VaultMath.portionUp(position.reserve1, fractionWad);
        left0 = repay0 < position.reserve0 ? position.reserve0 - repay0 : 0;
        left1 = repay1 < position.reserve1 ? position.reserve1 - repay1 : 0;
    }

    /// @dev Token0 arrears keep at most the protocol's premium slice for the treasury; the rest vests to lenders. A
    /// token0 profit share pays the treasury and the fee vault the same 25% each, so the treasury's arrears part is
    /// its gain less the fee vault's.
    function _assertToken0ArrearsSlice(Ledger memory before, uint256 vesting0Before) internal view {
        Ledger memory afterwards = vault.ledgerOf(vaultId);
        uint256 arrearsProtocol0 = (afterwards.treasury0 - before.treasury0) - (afterwards.feeVault0 - before.feeVault0);
        uint256 vesting0Gain = vault.streamOf(vaultId).remaining0 - vesting0Before;
        assertLe(
            arrearsProtocol0 * BPS,
            (arrearsProtocol0 + vesting0Gain) * defaultParameters().premiumProtocolBps,
            "token0 arrears keep at most the protocol's premium slice"
        );
    }

    /// @dev The lenders' side of the books at a price: idle buffer and income still vesting.
    function _lendersValue(uint160 sqrtPriceX96) internal view returns (uint256) {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        Stream memory stream = vault.streamOf(vaultId);
        return VaultMath.valueInToken1(
            uint256(ledger.buffer0) + stream.remaining0,
            uint256(ledger.buffer1) + stream.remaining1,
            sqrtPriceX96,
            false
        );
    }

    function _protocolAndVesting1() internal view returns (uint256) {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        return uint256(ledger.treasury1) + ledger.feeVault1 + vault.streamOf(vaultId).remaining1;
    }

    function _closedShare(Vm.Log[] memory logs) internal pure returns (uint256 share) {
        // logs.length is bounded by the close's events
        for (uint256 index = 0; index < logs.length; ++index) {
            if (logs[index].topics[0] != IMetricLendingVault.Closed.selector) continue;
            (,,, share) = abi.decode(logs[index].data, (uint256, uint256, uint256, uint256));
        }
    }
}
