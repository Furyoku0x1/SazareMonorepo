// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {
    CloseRequest,
    CurvePair,
    Ledger,
    OpenRequest,
    Position,
    Stream,
    VaultParameters
} from "../../src/metric/vault/VaultTypes.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {VaultFixture} from "./utils/VaultFixture.sol";

contract MetricLendingVaultTest is VaultFixture {
    uint256 internal constant WAD = 1e18;

    // ---------------------------------------------------------------- creation

    function test_createVault_onlyOwner() public {
        VaultParameters memory parameters = defaultParameters();
        vm.expectRevert();
        vault.createVault(parameters, defaultCurves());
    }

    function test_createVault_rejectsBadParameters() public {
        VaultParameters memory parameters = defaultParameters();
        parameters.utilizationCeilingBps = 0;
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.createVault(parameters, defaultCurves());
        parameters = defaultParameters();
        parameters.priceSource = address(0);
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.createVault(parameters, defaultCurves());
    }

    // ---------------------------------------------------------------- lenders

    function test_deposit_mintsSharesAndKeepsLedger() public {
        uint256 shares = deposit(lender, 10e18, 20_000e6);
        assertGt(shares, 0);
        assertEq(vault.sharesOf(vaultId, lender), shares);
        assertEq(vault.ledgerOf(vaultId).buffer0, 10e18);
        assertEq(vault.ledgerOf(vaultId).buffer1, 20_000e6);
        assertLedger();
    }

    function test_deposit_secondDepositIsProportional() public {
        uint256 first = deposit(lender, 0, 10_000e6);
        uint256 second = deposit(trader, 0, 10_000e6);
        // Equal deposits of token1 into a token1-only vault mint equal shares, up to the virtual offset.
        assertApproxEqRel(second, first, 1e12);
    }

    function test_withdraw_returnsProRataIdle() public {
        uint256 shares = deposit(lender, 10e18, 20_000e6);
        vm.prank(lender);
        (uint256 amount0, uint256 amount1, uint256 burned) = vault.withdraw(vaultId, shares / 2, 0, 0, lender);
        assertEq(burned, shares / 2);
        assertApproxEqRel(amount0, 5e18, 1e12);
        assertApproxEqRel(amount1, 10_000e6, 1e12);
        assertLedger();
    }

    function test_withdraw_whenLentPaysOnlyIdle() public {
        uint256 shares = deposit(lender, 0, 20_000e6);
        openLong(15_000e6, 300e6);
        vm.prank(lender);
        (, uint256 amount1, uint256 burned) = vault.withdraw(vaultId, shares, 0, 0, lender);
        assertLt(burned, shares, "only the covered shares burn");
        assertLe(amount1, 5_000e6 + 1);
        assertEq(vault.ledgerOf(vaultId).buffer1, 0);
        assertLedger();
    }

    // ---------------------------------------------------------------- opening

    function test_openLong_releasesToken1AndHoldsChord() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 200e6);
        Position memory position = vault.positionOf(positionId);
        assertEq(position.owner, trader);
        assertEq(position.reserve0, 0);
        assertApproxEqRel(position.released1, 10_000e6, 1e15);
        assertEq(position.reserve1, position.released1 + 200e6);
        assertEq(vault.accrualOf(vaultId).outstanding1, position.released1);
        assertLedger();
    }

    function test_openLong_withoutCollateralIsInsolvent() public {
        deposit(lender, 0, 100_000e6);
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, 10_000e6), 0);
        // The release alone is all token1, exactly M1 minus rounding: below the chord's rounded-up extreme.
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.Insolvent.selector);
        vault.open(request);
    }

    function test_open_belowMinimumBorrowReverts() public {
        deposit(lender, 0, 100_000e6);
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, 50e6), 100e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.BelowMinimumBorrow.selector);
        vault.open(request);
    }

    function test_open_utilizationCeiling() public {
        deposit(lender, 0, 10_000e6);
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, 9_500e6), 300e6);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.UtilizationCeiling.selector);
        vault.open(request);
    }

    function test_openShort_releasesToken0() public {
        deposit(lender, 100e18, 0);
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        uint128 liquidity = liquidityFor1(lower, upper, 10_000e6);
        uint256 positionId = open(openRequest(false, lower, upper, liquidity, 200e6));
        Position memory position = vault.positionOf(positionId);
        assertGt(position.released0, 0);
        assertEq(position.released1, 0);
        assertLedger();
    }

    // ---------------------------------------------------------------- closing

    function test_closeLong_atSamePriceReturnsCollateralLessShare() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 200e6);
        (uint256 repay0, uint256 repay1) = cheapestRepayment(positionId);
        (uint256 paid0, uint256 paid1) = closeFull(positionId, repay0, repay1);
        assertEq(paid0, 0);
        // No time passed: no premium. The trader gets back collateral and escrow, less rounding.
        assertApproxEqAbs(paid1, 300e6, 10);
        assertEq(vault.positionOf(positionId).owner, address(0));
        assertEq(vault.accrualOf(vaultId).outstanding1, 0);
        assertLedger();
    }

    function test_close_repaymentShortReverts() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 200e6);
        (, uint256 repay1) = cheapestRepayment(positionId);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.RepaymentShort.selector);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: 0, repay1: repay1 * 99 / 100}));
    }

    function test_close_onlyOwner() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 200e6);
        vm.prank(lender);
        vm.expectRevert(IMetricLendingVault.Unauthorized.selector);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: 0, repay1: 0}));
    }

    function test_partialClose_keepsRestSolvent() public {
        deposit(lender, 0, 100_000e6);
        uint256 positionId = openLong(10_000e6, 400e6);
        Position memory before = vault.positionOf(positionId);
        (, uint256 repay1) = cheapestRepayment(positionId);
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: 0.5e18, repay0: 0, repay1: repay1 / 2 + 2}));
        Position memory afterwards = vault.positionOf(positionId);
        assertApproxEqRel(afterwards.liquidity, before.liquidity / 2, 1e12);
        assertApproxEqRel(afterwards.reserve1, before.reserve1 / 2, 1e12);
        assertLedger();
    }

    // ---------------------------------------------------------------- premium

    function test_premium_accruesAndStreamsToLenders() public {
        deposit(lender, 100e18, 20_000e6);
        uint256 positionId = openLong(15_000e6, 300e6);
        _openBalancingShort(positionId);
        vm.warp(block.timestamp + 30 days);
        assertTrue(vault.settle(positionId));
        Position memory position = vault.positionOf(positionId);
        assertLt(position.escrow, 100e6, "escrow paid premium");
        uint256 paid = 100e6 - position.escrow;
        Ledger memory ledger = vault.ledgerOf(vaultId);
        // The protocol keeps 10%.
        assertApproxEqAbs(ledger.treasury1, paid / 10, 1);
        assertGt(vault.streamOf(vaultId).remaining1, 0);
        vm.warp(block.timestamp + 2 days);
        vault.settle(positionId);
        assertGt(vault.ledgerOf(vaultId).buffer1, ledger.buffer1, "vested premium joins idle");
        assertLedger();
    }

    /// @dev Sol's finding on the maker book holds here too: settlements anyone may call rounded each one up, so
    /// settling every second drained escrow faster than the rate. Six hundred one-second settlements now charge no
    /// more than one settlement over the same ten minutes, and at most a unit less.
    function test_settle_oftenChargesNoMoreThanOnce() public {
        deposit(lender, 100e18, 20_000e6);
        uint256 positionId = openLong(15_000e6, 300e6);
        _openBalancingShort(positionId);
        uint256 openedAt = block.timestamp;
        uint256 state = vm.snapshotState();
        // 600 one-second settlements
        for (uint256 second = 1; second <= 600; ++second) {
            vm.warp(openedAt + second);
            vault.settle(positionId);
        }
        uint256 often = 100e6 - vault.positionOf(positionId).escrow;
        vm.revertToState(state);
        vm.warp(openedAt + 600);
        vault.settle(positionId);
        uint256 once = 100e6 - vault.positionOf(positionId).escrow;
        assertGt(once, 0, "premium accrued");
        assertLe(often, once, "never more than one settlement");
        assertGe(often + 1, once, "at most a unit less");
    }

    function test_flagAndForceClose_afterGrace() public {
        deposit(lender, 100e18, 20_000e6);
        uint256 positionId = openLong(15_000e6, 300e6);
        _openBalancingShort(positionId);
        // Premium near 1.5 a day outruns the 100 escrow within about two months, but not the 300 collateral.
        vm.warp(block.timestamp + 80 days);
        vault.flag(positionId);
        vm.expectRevert(IMetricLendingVault.GracePeriodRunning.selector);
        vault.forceClose(positionId);
        vm.warp(block.timestamp + 1 days);
        uint256 traderBefore = quote.balanceOf(trader);
        vm.prank(closer);
        (, uint256 reward1) = vault.forceClose(positionId);
        assertGt(reward1, 0, "closer rewarded");
        assertGe(quote.balanceOf(trader), traderBefore);
        assertEq(vault.positionOf(positionId).owner, address(0));
        assertEq(vault.accrualOf(vaultId).outstanding1, 0);
        assertLedger();
    }

    function test_flag_rejectsSolventPosition() public {
        deposit(lender, 0, 20_000e6);
        uint256 positionId = openLong(15_000e6, 300e6);
        vm.expectRevert(IMetricLendingVault.NotDelinquent.selector);
        vault.flag(positionId);
    }

    function test_addEscrow_clearsDelinquency() public {
        deposit(lender, 0, 20_000e6);
        uint256 positionId = openLong(15_000e6, 300e6);
        vm.warp(block.timestamp + 400 days);
        vault.flag(positionId);
        vm.prank(trader);
        vault.addEscrow(positionId, 10_000e6);
        assertEq(vault.positionOf(positionId).delinquentSince, 0);
        assertLedger();
    }

    /// @dev Audit finding A1: with funding between sides, an attacker's own long and short let the short draw funding
    /// its long never paid, out of a pot that backed honest receivers. v1 has no funding; the pair, opened beside honest
    /// positions, must not end ahead of what it put in.
    function test_pairOfOwnPositionsCannotProfit() public {
        deposit(lender, 100e18, 400_000e6);
        uint256 honestLong = openLong(20_000e6, 400e6);
        vm.prank(trader);
        vault.addEscrow(honestLong, 2_000e6);
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        open(openRequest(false, lower, upper, liquidityFor1(lower, upper, 5_000e6), 200e6));
        vm.warp(block.timestamp + 30 days);

        address attacker = makeAddr("attacker");
        fundWith(attacker, base);
        fundWith(attacker, quote);
        uint256 base0 = base.balanceOf(attacker);
        uint256 quote0 = quote.balanceOf(attacker);
        (uint256 attackLong, uint256 attackShort) = _openPairAs(attacker, lower, upper);
        vm.warp(block.timestamp + 1 days);
        _closeAs(attacker, attackShort);
        _closeAs(attacker, attackLong);
        int256 quoteChange = int256(quote.balanceOf(attacker)) - int256(quote0);
        int256 baseChange = int256(base.balanceOf(attacker)) - int256(base0);
        int256 baseValue = baseChange >= 0
            ? int256(VaultMath.priceTimes(uint256(baseChange), source.sqrtAskX96(), true))
            : -int256(VaultMath.priceTimes(uint256(-baseChange), source.sqrtBidX96(), false));
        assertLe(quoteChange + baseValue, 0, "the pair ends no better than it started");
        assertLedger();
    }

    /// @dev A long four times the short, with the least collateral the chord allows and no escrow.
    function _openPairAs(address who, int24 shortLower, int24 shortUpper) internal returns (uint256, uint256) {
        int24 longLower = PRICE_TICK - 200;
        int24 longUpper = PRICE_TICK - 100;
        OpenRequest memory longRequest =
            openRequest(true, longLower, longUpper, liquidityFor1(longLower, longUpper, 60_000e6), 2);
        longRequest.escrow = 0;
        vm.prank(who);
        uint256 longId = vault.open(longRequest);
        OpenRequest memory shortRequest =
            openRequest(false, shortLower, shortUpper, liquidityFor1(shortLower, shortUpper, 15_000e6), 2);
        shortRequest.escrow = 0;
        vm.prank(who);
        uint256 shortId = vault.open(shortRequest);
        return (longId, shortId);
    }

    function _closeAs(address who, uint256 positionId) internal {
        (uint256 repay0, uint256 repay1) = repaymentFor(positionId, WAD);
        vm.prank(who);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: repay0, repay1: repay1}));
    }

    /// @dev Audit finding A3: deposit value left out income still vesting, so a deposit made just after income was
    /// paid took a share of it. At a fixed price with no spread, a lender who deposits after every position closed and
    /// leaves once the income has vested ends with no more than they put in.
    function test_deposit_cannotTakeIncomeEarnedBeforeIt() public {
        setPrice(PRICE_TICK, 0);
        deposit(lender, 100e18, 100_000e6);
        uint256 longId = openLong(15_000e6, 300e6);
        uint256 shortId = _openBalancingShort(longId);
        vm.prank(trader);
        vault.addEscrow(longId, 5_000e6);
        vm.warp(block.timestamp + 60 days);
        (uint256 repay0, uint256 repay1) = repaymentFor(longId, WAD);
        closeFull(longId, repay0, repay1);
        (repay0, repay1) = repaymentFor(shortId, WAD);
        closeFull(shortId, repay0, repay1);
        assertGt(vault.streamOf(vaultId).remaining1, 0, "income still vesting");
        address late = makeAddr("late");
        fundWith(late, base);
        fundWith(late, quote);
        uint256 shares = deposit(late, 0, 100_000e6);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(late);
        (uint256 amount0, uint256 amount1,) = vault.withdraw(vaultId, shares, 0, 0, late);
        uint256 value = VaultMath.priceTimes(amount0, source.sqrtAskX96(), true) + amount1;
        assertLe(value, 100_000e6, "no share of income earned before the deposit");
        assertLedger();
    }

    /// @dev Audit finding A5: with nothing lent, a lender's claim is their share of the idle tokens and needs no price,
    /// so a broken price source must not stop them leaving.
    function test_withdraw_needsNoPriceWhenNothingIsLent() public {
        uint256 shares = deposit(lender, 10e18, 20_000e6);
        source.setBroken(true);
        vm.prank(lender);
        (uint256 amount0, uint256 amount1, uint256 burned) = vault.withdraw(vaultId, shares, 0, 0, lender);
        assertEq(burned, shares, "every share");
        assertApproxEqAbs(amount0, 10e18, 1e12, "their token0");
        assertApproxEqAbs(amount1, 20_000e6, 1, "their token1");
        assertLedger();
    }

    /// @dev Audit finding C2, in the vault: both token curves must charge at least 100% a year at the utilization
    /// ceiling, so a borrower cannot hold lenders' last idle capital for free.
    function test_curves_mustChargeAtTheCeiling() public {
        CurvePair memory curves = defaultCurves();
        curves.token1.slope2Wad = 0;
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.appendCurves(vaultId, curves);
    }

    /// @dev Audit finding A6: an open with no escrow borrows on credit from its first second, and its premium is
    /// forgiven if it ends with nothing left. With a minimum escrow period, an open must escrow that long of premium at
    /// the rates its borrow leaves.
    function test_open_requiresTheMinimumEscrow() public {
        VaultParameters memory parameters = defaultParameters();
        parameters.minimumEscrowSeconds = 1 days;
        vm.prank(owner);
        uint256 escrowedVault = vault.createVault(parameters, defaultCurves());
        vm.prank(lender);
        vault.deposit(escrowedVault, 0, 100_000e6, 0, lender);
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, 20_000e6), 400e6);
        request.vaultId = escrowedVault;
        request.escrow = 0;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.EscrowTooSmall.selector);
        vault.open(request);
        // About 1% a year on 20,000 is about 0.55 a day, which 1 covers.
        request.escrow = 1e6;
        open(request);
        assertLedgerParts(escrowedVault);
    }

    /// @dev A short whose `M1` equals the long's.
    function _openBalancingShort(uint256 longId) internal returns (uint256) {
        uint256 maximum1 = vault.positionOf(longId).maximum1;
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        uint128 liquidity = liquidityFor1(lower, upper, maximum1 - 1);
        OpenRequest memory request = openRequest(false, lower, upper, liquidity, 10_000e6);
        request.escrow = 10_000e6;
        return open(request);
    }

    // ---------------------------------------------------------------- arrears and profit share

    /// @dev A short repaid in token1 keeps its token0. When the escrow and the token1 leftover fall short of what it
    /// owes, token0 at the strike pays the rest: the premium's protocol slice to the treasury, the rest vested to
    /// lenders, none of it straight into idle capital.
    function test_arrearsInToken0_keepProtocolSliceAndVest() public {
        deposit(lender, 100e18, 0);
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        uint128 liquidity = liquidityFor1(lower, upper, 10_000e6);
        uint256 shortId = _openShortWith(lower, upper, liquidity, 1e6, 2e6);
        vm.warp(block.timestamp + 365 days);
        uint256 buffer0Before = vault.ledgerOf(vaultId).buffer0;
        Position memory position = vault.positionOf(shortId);
        (uint256 paid0,) = closeFull(shortId, 0, position.maximum1);
        assertLt(paid0, position.reserve0, "token0 paid arrears");
        Ledger memory ledger = vault.ledgerOf(vaultId);
        assertGt(ledger.treasury0, 0, "protocol slice of premium in token0");
        assertGt(vault.streamOf(vaultId).remaining0, 0, "lenders' part vests");
        assertEq(ledger.buffer0, buffer0Before, "nothing jumps straight into idle");
        assertLedger();
    }

    /// @dev A winning short whose token1 leftover is small pays its profit share from the escrow refund before
    /// touching its token0.
    function test_profitShare_takenFromRefundBeforeToken0() public {
        deposit(lender, 100e18, 0);
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        uint128 liquidity = liquidityFor1(lower, upper, 5_000e6);
        uint256 shortId = _openShortWith(lower, upper, liquidity, 2_000e6, 1e6);
        setPrice(PRICE_TICK + 2_000, 1);
        Position memory position = vault.positionOf(shortId);
        Ledger memory before = vault.ledgerOf(vaultId);
        uint256 streamBefore = vault.streamOf(vaultId).remaining1;
        (uint256 paid0, uint256 paid1) = closeFull(shortId, 0, position.maximum1);
        assertEq(paid0, position.reserve0, "token0 untouched");
        uint256 share = 1e6 + position.escrow - paid1;
        assertGt(share, 1e6, "share exceeds the token1 leftover");
        Ledger memory afterwards = vault.ledgerOf(vaultId);
        uint256 received = afterwards.treasury1 - before.treasury1 + afterwards.feeVault1 - before.feeVault1
            + vault.streamOf(vaultId).remaining1 - streamBefore;
        assertEq(received, share, "the share went to the protocol and lenders");
        assertLedger();
    }

    /// @dev A short whose collateral is its full token1 debt plus `extra1`, so it can always repay in token1.
    function _openShortWith(int24 lower, int24 upper, uint128 liquidity, uint128 escrow, uint128 extra1)
        internal
        returns (uint256)
    {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(lower, upper);
        (, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        OpenRequest memory request = openRequest(false, lower, upper, liquidity, uint128(maximum1) + extra1);
        request.escrow = escrow;
        return open(request);
    }

    // ---------------------------------------------------------------- protocol

    function test_payProtocol_paysRecipients() public {
        deposit(lender, 0, 20_000e6);
        uint256 positionId = openLong(15_000e6, 300e6);
        vm.warp(block.timestamp + 30 days);
        vault.settle(positionId);
        uint256 owed = vault.ledgerOf(vaultId).treasury1;
        vault.payProtocol(vaultId);
        assertEq(quote.balanceOf(treasury), owed);
        assertEq(vault.ledgerOf(vaultId).treasury1, 0);
        assertLedger();
    }
}
