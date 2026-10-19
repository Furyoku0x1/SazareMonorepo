// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Accrual, Ledger, Position, VaultParameters} from "../../../src/metric/vault/VaultTypes.sol";
import {DebtTotals, VaultMath} from "../../../src/metric/vault/libraries/VaultMath.sol";
import {TestToken, VaultFixture} from "../utils/VaultFixture.sol";
import {VaultHandler} from "./VaultHandler.sol";

/// @notice Random sequences of lender, trader, keeper and market actions on two no-pool vaults of one singleton that
/// share the quote token, with the books checked after every call.
/// @dev The handler's actions never revert; unexpected reverts and cross-vault changes surface as handler violations.
/// All checks live in one invariant function: each invariant function is its own campaign, and one keeps the suite
/// fast while every property still asserts on its own line with its own message.
contract VaultInvariantTest is VaultFixture {
    /// @dev Sums over one vault's open positions, to compare with the vault's running totals.
    struct PositionSums {
        uint256 reserve0;
        uint256 reserve1;
        uint256 escrow;
        uint256 released0;
        uint256 released1;
        DebtTotals longTerms;
        DebtTotals shortTerms;
        /// @dev The open positions, and their holdings summed one by one at the bid and the ask, each rounded down.
        uint256 count;
        uint256 bid0;
        uint256 bid1;
        uint256 ask0;
        uint256 ask1;
    }

    TestToken internal secondBase;
    uint256 internal secondVaultId;
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        secondBase = new TestToken("BASE2", 18);
        VaultParameters memory parameters = defaultParameters();
        parameters.token0 = address(secondBase);
        // The second vault runs the transformation rate (k = 2) and the high-leverage surcharge.
        parameters.transformationRateBps = 20_000;
        parameters.highLeverageSurchargeBps = 500;
        vm.prank(owner);
        secondVaultId = vault.createVault(parameters, defaultCurves());
        handler = new VaultHandler(vault, base, secondBase, quote, source, vaultId, secondVaultId);
        // Every lender starts with capital in both vaults, so opens and withdrawals are possible from the first call.
        // 2 vaults x 3 lenders
        for (uint256 actorChoice = 0; actorChoice < 6; ++actorChoice) {
            handler.actDeposit(actorChoice, 50e18, 200_000e6);
        }
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    /// forge-config: default.invariant.runs = 200
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_vaultBooks() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
        _assertCustody();
        _assertVault(vaultId);
        _assertVault(secondVaultId);
        _assertOwnerLists();
    }

    /// @dev A fixed walk through every action, so a handler whose actions all fail cannot pass the campaign quietly.
    function test_handlerReachesEveryAction() public {
        handler.actDeposit(0, 100e18, 300_000e6);
        handler.actDeposit(1, 100e18, 300_000e6);
        // Vault one: a generous long with escrow, and a barely solvent long with none.
        handler.actOpenLong(0, 100, 500, 10_000e6, 2 + 3 * 1_000, 2 + 3 * 50e6);
        handler.actOpenLong(2, 300, 300, 2_000e6, 0, 0);
        // Vault two: a short.
        handler.actOpenShort(1, 100, 500, 5_000e6, 1 + 3 * 100, 2 + 3 * 10e6);
        assertEq(handler.opens(), 3, "three opens");
        // Through a named venue: a fair long, a short 0.5% short of the band, and a long filled at half, all charged.
        handler.actOpenThroughVenue(0, true, 200, 3_000e6, 2 + 3 * 2_000, 50 + 100 * 80);
        handler.actOpenThroughVenue(1, false, 200, 3_000e6, 2 + 3 * 2_000, 50 + 100 * 80 + 10_000);
        // Selling 1% at half value: more would break the chord, which the vault refuses as it should.
        handler.actOpenThroughVenue(0, true, 200, 3_000e6, 2 + 3 * 2_000, 30_000);
        assertEq(handler.venueOpens(), 3, "every fill stands");
        // The first venue long holds base: close it by selling all of it at the bid.
        handler.actCloseThroughVenue(3, 99);
        assertEq(handler.venueCloses(), 1, "closed through a venue");
        handler.actWarp(1 days);
        handler.actRecordPrice(0);
        handler.actRecordPrice(1);
        assertEq(handler.pricePoints(), 2, "a point in each vault");
        handler.actFlag(1);
        handler.actWarp(2 days);
        handler.actForceClose(1);
        assertEq(handler.forceCloses(), 1, "the unfunded long is force closed");
        handler.actSettle(0);
        handler.actAddEscrow(0, 10e6);
        handler.actAddCollateral(2, 10e6);
        handler.actIncrease(0, 1_000e6, 2 + 3 * 100, 2 + 3 * 10e6);
        assertEq(handler.increases(), 1, "increased");
        handler.actMovePrice(-150, 0);
        handler.actClosePartial(0, 0.5e18);
        handler.actCloseFull(0);
        handler.actCloseFull(2);
        handler.actWithdraw(0, 0.5e18);
        handler.actPayProtocol(0);
        assertEq(handler.violations(), 0, handler.lastViolation());
        assertGt(handler.flags(), 0, "flagged");
        assertGt(handler.settlements(), 0, "settled");
        assertGt(handler.escrowTopUps(), 0, "escrow added");
        assertGt(handler.collateralTopUps(), 0, "collateral added");
        assertGt(handler.partialCloses(), 0, "partially closed");
        assertEq(handler.fullCloses(), 2, "both remaining positions closed in full");
        assertGt(handler.withdrawals(), 0, "withdrew");
        assertGt(handler.protocolPayments(), 0, "protocol paid");
        invariant_vaultBooks();
    }

    // ---------------------------------------------------------------- properties

    /// @dev The vaults share the quote token, so only the sum of their quote balances equals the contract's.
    function _assertCustody() private view {
        Ledger memory first = vault.ledgerOf(vaultId);
        Ledger memory second = vault.ledgerOf(secondVaultId);
        assertEq(uint256(first.held0), base.balanceOf(address(vault)), "custody: first base");
        assertEq(uint256(second.held0), secondBase.balanceOf(address(vault)), "custody: second base");
        assertEq(uint256(first.held1) + second.held1, quote.balanceOf(address(vault)), "custody: shared quote");
    }

    function _assertVault(uint256 someVaultId) private view {
        assertLedgerParts(someVaultId);
        PositionSums memory sums = _sumPositions(someVaultId);
        _assertPositionSums(someVaultId, sums);
        _assertDebts(someVaultId, sums);
        _assertShares(someVaultId);
        _assertValueBounds(someVaultId, sums);
    }

    function _assertPositionSums(uint256 someVaultId, PositionSums memory sums) private view {
        Ledger memory ledger = vault.ledgerOf(someVaultId);
        Accrual memory accrual = vault.accrualOf(someVaultId);
        assertEq(sums.reserve0, ledger.reserve0, "positions' reserve0 vs ledger");
        assertEq(sums.reserve1, ledger.reserve1, "positions' reserve1 vs ledger");
        assertEq(sums.escrow, ledger.escrow, "positions' escrow vs ledger");
        assertEq(sums.released0, accrual.outstanding0, "positions' released0 vs outstanding0");
        assertEq(sums.released1, accrual.outstanding1, "positions' released1 vs outstanding1");
    }

    /// @dev The running debt totals and open interest must equal the terms of the open positions, side by side.
    function _assertDebts(uint256 someVaultId, PositionSums memory sums) private view {
        (DebtTotals memory longDebts, DebtTotals memory shortDebts) = vault.debtsOf(someVaultId);
        _assertTotals(longDebts, sums.longTerms, "long");
        _assertTotals(shortDebts, sums.shortTerms, "short");
    }

    function _assertTotals(DebtTotals memory totals, DebtTotals memory terms, string memory side) private pure {
        assertEq(totals.liquidity, terms.liquidity, string.concat(side, " debts: liquidity"));
    }

    function _assertShares(uint256 someVaultId) private view {
        uint256 lenderShares;
        // three lenders
        for (uint256 index = 0; index < 3; ++index) {
            lenderShares += vault.sharesOf(someVaultId, handler.lenders(index));
        }
        assertEq(vault.totalSharesOf(someVaultId), lenderShares, "total shares vs lenders' shares");
    }

    /// @dev Withdrawals value debts at the bid and deposits at the ask with the debt tree (audit finding H1): each must
    /// match the open positions' holdings summed one by one, the low value below them and the high above, within the
    /// tree's rounding slack.
    function _assertValueBounds(uint256 someVaultId, PositionSums memory sums) private view {
        uint160 sqrtBidX96 = source.sqrtBidX96();
        uint160 sqrtAskX96 = source.sqrtAskX96();
        uint256 bidValue = VaultMath.valueInToken1(sums.bid0, sums.bid1, sqrtBidX96, false);
        // Rounded down in both steps: the sums and their valuation, so it never exceeds the exact value.
        uint256 askValue = VaultMath.valueInToken1(sums.ask0, sums.ask1, sqrtAskX96, false);
        (uint256 low,) = vault.debtValuesAt(someVaultId, sqrtBidX96);
        (, uint256 high) = vault.debtValuesAt(someVaultId, sqrtAskX96);
        // Each position's holdings round down by under a unit of each token, so the exact value lies between the sums
        // and the sums plus a unit of each token per position.
        uint256 bidAbove = sums.count + VaultMath.priceTimes(sums.count, sqrtBidX96, true);
        uint256 askAbove = sums.count + VaultMath.priceTimes(sums.count, sqrtAskX96, true);
        assertLe(low, bidValue + bidAbove, "withdrawals value debts at most at their holdings");
        assertGe(high, askValue, "deposits value debts at least at their holdings");
        // The tree rounds in 2^-64 units, so each bound is within a few units of the exact value.
        assertLe(bidValue, low + 3, "withdrawals: exact");
        assertLe(high, askValue + askAbove + 4, "deposits: exact");
    }

    /// @dev Sums the open positions of one vault, and checks each one's solvency on the way: every open position must
    /// pass the chord, and so the repayment rule, at every moment.
    function _sumPositions(uint256 someVaultId) private view returns (PositionSums memory sums) {
        uint256 count = handler.positionCount();
        // count <= the run's depth
        for (uint256 index = 0; index < count; ++index) {
            Position memory position = vault.positionOf(handler.positionIds(index));
            if (position.owner == address(0)) continue;
            if (position.vaultId != someVaultId) continue;
            _assertSolvent(position);
            sums.reserve0 += position.reserve0;
            sums.reserve1 += position.reserve1;
            sums.escrow += position.escrow;
            sums.released0 += position.released0;
            sums.released1 += position.released1;
            DebtTotals memory side = position.isLong ? sums.longTerms : sums.shortTerms;
            side.liquidity += position.liquidity;
            _addHoldings(position, sums);
        }
    }

    function _addHoldings(Position memory position, PositionSums memory sums) private view {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        (uint256 bid0, uint256 bid1) =
            VaultMath.holdingsAt(position.liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96());
        (uint256 ask0, uint256 ask1) =
            VaultMath.holdingsAt(position.liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtAskX96());
        sums.count += 1;
        sums.bid0 += bid0;
        sums.bid1 += bid1;
        sums.ask0 += ask0;
        sums.ask1 += ask1;
    }

    function _assertSolvent(Position memory position) private pure {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        assertTrue(
            VaultMath.chordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1),
            "open position fails the chord"
        );
        assertTrue(
            VaultMath.repays(position.reserve0, position.reserve1, position.liquidity, sqrtLowerX96, sqrtUpperX96),
            "open position's reserves fail the repayment rule"
        );
    }

    function _actions() private view returns (bytes4[] memory selectors) {
        selectors = new bytes4[](18);
        selectors[0] = handler.actDeposit.selector;
        selectors[1] = handler.actWithdraw.selector;
        selectors[2] = handler.actPayProtocol.selector;
        selectors[3] = handler.actOpenLong.selector;
        selectors[4] = handler.actOpenShort.selector;
        selectors[5] = handler.actAddEscrow.selector;
        selectors[6] = handler.actAddCollateral.selector;
        selectors[7] = handler.actCloseFull.selector;
        selectors[8] = handler.actClosePartial.selector;
        selectors[9] = handler.actSettle.selector;
        selectors[10] = handler.actFlag.selector;
        selectors[11] = handler.actForceClose.selector;
        selectors[12] = handler.actWarp.selector;
        selectors[13] = handler.actMovePrice.selector;
        selectors[14] = handler.actIncrease.selector;
        selectors[15] = handler.actOpenThroughVenue.selector;
        selectors[16] = handler.actCloseThroughVenue.selector;
        selectors[17] = handler.actRecordPrice.selector;
    }

    /// @dev Each owner's listed passive positions are exactly their open ones (`positionsOf`): opens list them, increases
    /// keep them, and full and forced closes take them out however the list is reordered.
    function _assertOwnerLists() private view {
        uint256 count = handler.positionCount();
        address[] memory owners = new address[](count);
        uint256 ownerCount;
        uint256 open;
        // count <= the run's opens
        for (uint256 index = 0; index < count; ++index) {
            uint256 positionId = handler.positionIds(index);
            address owner = vault.positionOf(positionId).owner;
            if (owner == address(0)) continue;
            open += 1;
            assertTrue(_contains(_listed(owner), positionId), "an open position is in its owner's list");
            ownerCount = _addOwner(owners, ownerCount, owner);
        }
        uint256 listedTotal;
        // ownerCount <= count
        for (uint256 index = 0; index < ownerCount; ++index) {
            listedTotal += _listed(owners[index]).length;
        }
        assertEq(listedTotal, open, "the lists hold only open positions");
    }

    function _listed(address owner) private view returns (uint256[] memory listed) {
        (listed,) = vault.positionsOf(owner);
    }

    function _contains(uint256[] memory positionIds, uint256 positionId) private pure returns (bool) {
        // positionIds.length <= the owner's open positions
        for (uint256 index = 0; index < positionIds.length; ++index) {
            if (positionIds[index] == positionId) return true;
        }
        return false;
    }

    /// @dev Appends `owner` to the first `ownerCount` owners if it is not there yet; returns the new count.
    function _addOwner(address[] memory owners, uint256 ownerCount, address owner) private pure returns (uint256) {
        // ownerCount <= owners.length
        for (uint256 index = 0; index < ownerCount; ++index) {
            if (owners[index] == owner) return ownerCount;
        }
        owners[ownerCount] = owner;
        return ownerCount + 1;
    }
}
