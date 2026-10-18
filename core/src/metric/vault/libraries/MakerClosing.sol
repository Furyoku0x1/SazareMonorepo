// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Book, Bucket, Leg, MakerCloseRequest, MakerPosition} from "../MakerTypes.sol";
import {Vault, VaultStore} from "../VaultTypes.sol";
import {IMakerBook} from "../interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {MakerAccounting} from "./MakerAccounting.sol";
import {MakerMath} from "./MakerMath.sol";
import {MakerSettlement} from "./MakerSettlement.sol";
import {MetricVenue} from "./MetricVenue.sol";
import {VaultBook} from "./VaultBook.sol";
import {VaultLedger} from "./VaultLedger.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultPricing} from "./VaultPricing.sol";

/// @notice Closing maker positions: by their owner, in full or in part, and by anyone once a delinquent position's
/// grace period has passed. Every leg's repayment returns to its own bucket; repayment needs no price.
/// @dev An external library: the singleton delegatecalls it.
library MakerClosing {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;

    /// @dev The closed part of a position and what becomes of it; a struct keeps the stack shallow.
    struct Closing {
        uint256 fractionWad;
        uint256 portion0;
        uint256 portion1;
        uint256 repay0;
        uint256 repay1;
        uint256 leftover0;
        uint256 leftover1;
        uint256 basis;
        uint256 refund;
        /// @dev The closed legs' extremes, for the closed part's strike and the profit share's weights.
        uint256 closedMaximum0;
        uint256 closedMaximum1;
        uint256[8] closedMaximum1ByLeg;
        uint256[8] closedLiquidity;
        /// @dev Premium a force close collects from the leftover, in token1: a wait that would leave the trader no
        /// more than this protects no one, so the close scales instead (audit finding W-3).
        uint256 arrears;
    }

    /// @notice Closes `fractionWad` of every leg of the caller's position, repaying each leg from the closed part of
    /// the reserves. A partial close must pay all premium owed and leave the rest solvent and above the minimums.
    function close(VaultStore storage store, MakerCloseRequest calldata request)
        external
        returns (uint256 paid0, uint256 paid1)
    {
        uint256 positionId = request.positionId;
        MakerPosition storage position = store.makerPositions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        if (position.owner != msg.sender) revert IMetricLendingVault.Unauthorized();
        if (request.repay0.length != position.legCount) revert IMakerBook.InvalidLegs();
        if (request.repay1.length != position.legCount) revert IMakerBook.InvalidLegs();
        Vault storage vault = store.vaults[position.vaultId];
        Closing memory closing = _portion(store, vault, positionId, request.fractionWad);
        MakerSettlement.Dues memory dues = MakerSettlement.collect(store, vault, positionId, true);
        _repayOwner(store, vault, positionId, request, closing);
        _payArrears(store, vault, positionId, closing, dues, closing.fractionWad != WAD);
        position.delinquentSince = 0;
        uint256 share = _takeProfitShare(store, vault, positionId, closing);
        (paid0, paid1) = _payOut(vault, position, closing, msg.sender);
        _shrinkOrDelete(store, vault, positionId, closing);
        emit IMetricLendingVault.Closed(positionId, closing.fractionWad, paid0, paid1, share);
    }

    /// @notice Closes a delinquent position whose grace period has passed, for a reward. Buys only the shortfall
    /// through Metric for every leg's holdings at the close band's bid, which leaves out the fees the pool admin may
    /// change (W-1). Splits the reserves across legs in proportion to their extremes and scales each part down to its
    /// leg's repayment rule only where that costs the trader nothing they would keep: no pool, no price, or a surplus
    /// that after buying the deficit would leave no more than the arrears (W-3). A swap that could pay but does not
    /// fill reverts, to be retried (Sol-2-1). The profit share is measured at the bid and before the reward (Sol-1-2).
    function forceClose(VaultStore storage store, uint256 positionId)
        external
        returns (uint256 reward0, uint256 reward1)
    {
        MakerPosition storage position = store.makerPositions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        Vault storage vault = store.vaults[position.vaultId];
        _requireForceClosable(store, vault, positionId);
        MakerSettlement.Dues memory dues = MakerSettlement.collect(store, vault, positionId, true);
        Closing memory closing = _portion(store, vault, positionId, WAD);
        closing.arrears = dues.total;
        _repayForced(store, vault, positionId, closing);
        _payArrears(store, vault, positionId, closing, dues, false);
        _takeProfitShare(store, vault, positionId, closing);
        (reward0, reward1) = _reward(vault, closing);
        _payOut(vault, position, closing, position.owner);
        _shrinkOrDelete(store, vault, positionId, closing);
        emit IMetricLendingVault.ForceClosed(positionId, msg.sender, reward0, reward1);
    }

    // ---------------------------------------------------------------- portions

    /// @dev The closed fraction of the reserves and every leg. Each leg's closed extremes come from its closed
    /// liquidity, not a fraction of its extremes: a tiny close can round the latter to zero while closing liquidity,
    /// leaving the profit share with no weights and the strike undefined (Sol's finding).
    function _portion(VaultStore storage store, Vault storage vault, uint256 positionId, uint256 fractionWad)
        private
        view
        returns (Closing memory closing)
    {
        if (fractionWad == 0) revert IMetricLendingVault.InvalidFraction();
        if (fractionWad > WAD) revert IMetricLendingVault.InvalidFraction();
        MakerPosition storage position = store.makerPositions[positionId];
        closing.fractionWad = fractionWad;
        closing.portion0 = VaultMath.portionDown(position.reserve0, fractionWad);
        closing.portion1 = VaultMath.portionDown(position.reserve1, fractionWad);
        uint256 legCount = position.legCount;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            Leg storage leg = store.legs[positionId][index];
            uint256 liquidity = VaultMath.portionDown(leg.liquidity, fractionWad);
            if (liquidity == 0) revert IMetricLendingVault.InvalidFraction();
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerAccounting.range(vault.book, leg.bucketId);
            (uint256 maximum0, uint256 maximum1) =
                VaultMath.debtExtremes(liquidity.toUint128(), sqrtLowerX96, sqrtUpperX96);
            closing.closedLiquidity[index] = liquidity;
            closing.closedMaximum1ByLeg[index] = maximum1;
            closing.closedMaximum0 += maximum0;
            closing.closedMaximum1 += maximum1;
        }
    }

    // ---------------------------------------------------------------- repayment

    /// @dev Checks each leg's repayment against its own repayment rule and returns it to the leg's bucket.
    function _repayOwner(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        MakerCloseRequest calldata request,
        Closing memory closing
    ) private {
        uint256 legCount = store.makerPositions[positionId].legCount;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            Leg storage leg = store.legs[positionId][index];
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerAccounting.range(vault.book, leg.bucketId);
            uint256 repay0 = request.repay0[index];
            uint256 repay1 = request.repay1[index];
            uint128 liquidity = closing.closedLiquidity[index].toUint128();
            if (!VaultMath.repays(repay0, repay1, liquidity, sqrtLowerX96, sqrtUpperX96)) {
                revert IMetricLendingVault.RepaymentShort();
            }
            _returnToBucket(vault, positionId, leg.bucketId, liquidity, repay0, repay1);
            closing.repay0 += repay0;
            closing.repay1 += repay1;
        }
        if (closing.repay0 > closing.portion0) revert IMetricLendingVault.RepaymentShort();
        if (closing.repay1 > closing.portion1) revert IMetricLendingVault.RepaymentShort();
        closing.leftover0 = closing.portion0 - closing.repay0;
        closing.leftover1 = closing.portion1 - closing.repay1;
    }

    /// @dev A force close's repayment: every leg's holdings at the band's bid plus a unit of each, buying only the token
    /// the reserves lack; otherwise the scaling fallback.
    function _repayForced(VaultStore storage store, Vault storage vault, uint256 positionId, Closing memory closing)
        private
    {
        MakerPosition storage position = store.makerPositions[positionId];
        uint256[8] memory repay0;
        uint256[8] memory repay1;
        bool atBid = _targetsAtBid(store, vault, positionId, repay0, repay1, closing.arrears);
        if (!atBid) _scaledRepayments(store, vault, positionId, repay0, repay1);
        uint256 legCount = position.legCount;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            Leg storage leg = store.legs[positionId][index];
            _returnToBucket(vault, positionId, leg.bucketId, leg.liquidity, repay0[index], repay1[index]);
            closing.repay0 += repay0[index];
            closing.repay1 += repay1[index];
        }
        // The swap may have changed the reserves, so the closed portion is read after it.
        closing.portion0 = position.reserve0;
        closing.portion1 = position.reserve1;
        closing.leftover0 = closing.portion0 - closing.repay0;
        closing.leftover1 = closing.portion1 - closing.repay1;
    }

    /// @dev Fills `repay0`/`repay1` with each leg's holdings at the bid plus a unit of each held token, and buys the
    /// one token the reserves lack through Metric. Returns false, changing nothing, if there is no pool, the pool has
    /// had no bid for the whole wait, the amounts fail a leg's rule, both tokens fall short, or
    /// `VaultPricing.shortfallBudget` finds no swap can help; reverts while that wait runs.
    function _targetsAtBid(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        uint256[8] memory repay0,
        uint256[8] memory repay1,
        uint256 arrears
    ) private returns (bool) {
        if (vault.parameters.pool == address(0)) return false;
        (bool ok, uint160 sqrtBidX96) = VaultPricing.tryCloseBid(vault);
        if (!ok) {
            uint256 flaggedAt = store.makerPositions[positionId].delinquentSince;
            VaultPricing.requireNoPriceWaitOver(flaggedAt, vault.book.settings.graceSeconds);
            return false;
        }
        (bool repaid, uint256 target0, uint256 target1) =
            _holdingsAt(store, vault, positionId, sqrtBidX96, repay0, repay1);
        if (!repaid) return false;
        return _buyShortfall(vault, store.makerPositions[positionId], target0, target1, arrears);
    }

    /// @dev Buys the one token the reserves lack for the targets, paying at most the other token's surplus. Returns
    /// false, changing nothing, when both fall short or no swap can help; reverts when a swap that could pay does not
    /// fill, since scaling would hand the trader's surplus to makers (audit finding Sol-2-1).
    function _buyShortfall(
        Vault storage vault,
        MakerPosition storage position,
        uint256 target0,
        uint256 target1,
        uint256 arrears
    ) private returns (bool) {
        uint256 reserve0 = position.reserve0;
        uint256 reserve1 = position.reserve1;
        if (reserve0 >= target0) {
            if (reserve1 >= target1) return true;
        }
        if (reserve0 < target0) {
            if (reserve1 < target1) return false;
        }
        bool buyToken0 = reserve0 < target0;
        uint256 deficit = buyToken0 ? target0 - reserve0 : target1 - reserve1;
        uint256 surplus = buyToken0 ? reserve1 - target1 : reserve0 - target0;
        uint256 maximumIn = _budget(vault, position, buyToken0, deficit, surplus, arrears);
        if (maximumIn == 0) return false;
        _swapShortfall(vault, position, buyToken0, deficit, maximumIn);
        return true;
    }

    /// @dev The shortfall swap's budget, with the arrears as `_payArrears` takes them from the surplus: token1 as it
    /// is, token0 at the position's strike.
    function _budget(
        Vault storage vault,
        MakerPosition storage position,
        bool buyToken0,
        uint256 deficit,
        uint256 surplus,
        uint256 arrears
    ) private returns (uint256) {
        uint256 arrearsInSurplus = buyToken0
            ? arrears
            : FullMath.mulDivRoundingUp(arrears, position.maximum0, position.maximum1);
        return VaultPricing.shortfallBudget(vault, buyToken0, deficit, surplus, arrearsInSurplus);
    }

    /// @dev Buys exactly `deficit` through the pool for at most `maximumIn`, or reverts so the close waits for a pool
    /// that can fill it (audit finding Sol-2-1).
    function _swapShortfall(
        Vault storage vault,
        MakerPosition storage position,
        bool buyToken0,
        uint256 deficit,
        uint256 maximumIn
    ) private {
        (bool filled, uint256 paid, uint256 received) =
            MetricVenue.trySwapExactOut(vault, position.vaultId, !buyToken0, deficit, maximumIn);
        // Checked after the pool call: MetricLendingVault's nonReentrant lock is held, and a partial fill reverts
        // inside the swap, so an unfilled swap moved nothing.
        if (!filled) revert IMetricLendingVault.ShortfallUnfilled();
        _applySwap(vault, position, !buyToken0, paid, received);
    }

    /// @dev Each leg's holdings at a price plus a unit of each held token, and whether every leg's amounts pass its
    /// repayment rule; they always should, and a failure sends the force close to the scaling fallback before any swap.
    function _holdingsAt(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        uint160 sqrtPriceX96,
        uint256[8] memory amount0,
        uint256[8] memory amount1
    ) private view returns (bool repaid, uint256 total0, uint256 total1) {
        uint256 legCount = store.makerPositions[positionId].legCount;
        repaid = true;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            bool legRepaid;
            (amount0[index], amount1[index], legRepaid) = _legTarget(vault, store.legs[positionId][index], sqrtPriceX96);
            if (!legRepaid) repaid = false;
            total0 += amount0[index];
            total1 += amount1[index];
        }
    }

    /// @dev One leg's holdings at a price plus a unit of each held token, and whether they pass its repayment rule.
    function _legTarget(Vault storage vault, Leg storage leg, uint160 sqrtPriceX96)
        private
        view
        returns (uint256 amount0, uint256 amount1, bool repaid)
    {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerAccounting.range(vault.book, leg.bucketId);
        (amount0, amount1) = VaultMath.holdingsAt(leg.liquidity, sqrtLowerX96, sqrtUpperX96, sqrtPriceX96);
        if (amount0 != 0) amount0 += 1;
        if (amount1 != 0) amount1 += 1;
        repaid = VaultMath.repays(amount0, amount1, leg.liquidity, sqrtLowerX96, sqrtUpperX96);
    }

    /// @dev The scaling fallback. Each leg takes `ceil(kept · M_i / ΣM)` of each token, `kept` excluding one raw unit
    /// per leg; the aggregate chord on `kept` puts every such part on its leg's own chord, so each repays, and the
    /// ceilings sum to at most the reserves. Each part then scales down to its leg's repayment rule.
    function _scaledRepayments(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        uint256[8] memory repay0,
        uint256[8] memory repay1
    ) private view {
        MakerPosition storage position = store.makerPositions[positionId];
        uint256 legCount = position.legCount;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            Leg storage leg = store.legs[positionId][index];
            uint256 part0 = MakerMath.allocation(position.reserve0, legCount, leg.maximum0, position.maximum0);
            uint256 part1 = MakerMath.allocation(position.reserve1, legCount, leg.maximum1, position.maximum1);
            (repay0[index], repay1[index]) = _scaled(vault, leg, part0, part1);
        }
    }

    /// @dev The least fraction of a leg's part that repays it, rounded up; the whole part should it ever fail the rule.
    function _scaled(Vault storage vault, Leg storage leg, uint256 part0, uint256 part1)
        private
        view
        returns (uint256, uint256)
    {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerAccounting.range(vault.book, leg.bucketId);
        if (!VaultMath.repays(part0, part1, leg.liquidity, sqrtLowerX96, sqrtUpperX96)) return (part0, part1);
        uint256 fractionWad = VaultMath.scaleToRepay(part0, part1, leg.liquidity, sqrtLowerX96, sqrtUpperX96);
        uint256 scaled0 = VaultMath.portionUp(part0, fractionWad);
        uint256 scaled1 = VaultMath.portionUp(part1, fractionWad);
        return (scaled0 < part0 ? scaled0 : part0, scaled1 < part1 ? scaled1 : part1);
    }

    /// @dev Returns a leg's repayment to its bucket: the liquidity stops counting as lent, and the tokens leave the
    /// position's reserves for the bucket's balances. Keepers watch `LegRepaid` for buckets the price has passed.
    function _returnToBucket(
        Vault storage vault,
        uint256 positionId,
        uint256 bucketId,
        uint256 liquidity,
        uint256 repay0,
        uint256 repay1
    ) private {
        Book storage book = vault.book;
        Bucket storage bucket = MakerAccounting.checkpoint(book, bucketId);
        bucket.lent -= liquidity.toUint128();
        bucket.balance0 = (bucket.balance0 + repay0).toUint128();
        bucket.balance1 = (bucket.balance1 + repay1).toUint128();
        book.balance0 = (book.balance0 + repay0).toUint128();
        book.balance1 = (book.balance1 + repay1).toUint128();
        vault.ledger.reserve0 -= repay0.toUint128();
        vault.ledger.reserve1 -= repay1.toUint128();
        emit IMakerBook.LegRepaid(positionId, bucketId, repay0, repay1);
    }

    function _applySwap(
        Vault storage vault,
        MakerPosition storage position,
        bool zeroForOne,
        uint256 paid,
        uint256 received
    ) private {
        if (zeroForOne) {
            position.reserve0 -= paid.toUint128();
            vault.ledger.reserve0 -= paid.toUint128();
            position.reserve1 += received.toUint128();
            vault.ledger.reserve1 += received.toUint128();
            return;
        }
        position.reserve1 -= paid.toUint128();
        vault.ledger.reserve1 -= paid.toUint128();
        position.reserve0 += received.toUint128();
        vault.ledger.reserve0 += received.toUint128();
    }

    // ---------------------------------------------------------------- force closing

    function _requireForceClosable(VaultStore storage store, Vault storage vault, uint256 positionId) private {
        uint256 flaggedAt = store.makerPositions[positionId].delinquentSince;
        if (flaggedAt == 0) revert IMetricLendingVault.NotDelinquent();
        if (block.timestamp < flaggedAt + vault.book.settings.graceSeconds) {
            revert IMetricLendingVault.GracePeriodRunning();
        }
        if (MakerSettlement.shortfall(store, vault, positionId) == 0) revert IMetricLendingVault.NotDelinquent();
    }

    function _reward(Vault storage vault, Closing memory closing) private returns (uint256 reward0, uint256 reward1) {
        uint256 rewardBps = vault.parameters.forceCloseRewardBps;
        reward0 = closing.leftover0 * rewardBps / MakerMath.BPS;
        reward1 = closing.leftover1 * rewardBps / MakerMath.BPS;
        closing.leftover0 -= reward0;
        closing.leftover1 -= reward1;
        vault.ledger.reserve0 -= reward0.toUint128();
        vault.ledger.reserve1 -= reward1.toUint128();
        VaultLedger.push(vault, 0, msg.sender, reward0);
        VaultLedger.push(vault, 1, msg.sender, reward1);
    }

    // ---------------------------------------------------------------- settlement

    /// @dev Pays premium the escrow did not cover from the closed part's token1 leftover. A partial close must cover
    /// it all there. A full close then takes token0 at the closed part's strike for what remains, and forgoes anything
    /// beyond.
    function _payArrears(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        Closing memory closing,
        MakerSettlement.Dues memory dues,
        bool partialClose
    ) private {
        if (dues.total == 0) return;
        if (partialClose) {
            if (dues.total > closing.leftover1) revert IMetricLendingVault.PremiumUnpaid();
        }
        uint256 from1 = _min(dues.total, closing.leftover1);
        closing.leftover1 -= from1;
        vault.ledger.reserve1 -= from1.toUint128();
        MakerSettlement.payArrears1(store, vault, positionId, dues, from1);
        if (dues.total == 0) return;
        uint256 owed0 = FullMath.mulDivRoundingUp(dues.total, closing.closedMaximum0, closing.closedMaximum1);
        uint256 from0 = _min(owed0, closing.leftover0);
        if (from0 == 0) return;
        closing.leftover0 -= from0;
        vault.ledger.reserve0 -= from0.toUint128();
        uint256 value = _min(FullMath.mulDiv(from0, closing.closedMaximum1, closing.closedMaximum0), dues.total);
        MakerSettlement.payArrears0(store, vault, positionId, dues, from0, value == 0 ? 1 : value);
    }

    /// @dev The profit share on a winning close: proceeds (leftovers, and a full close's escrow refund) valued at the
    /// band's bid, or at the closed part's strike when the band cannot be read, less the basis closed. Taken from the
    /// token1 leftover, then the refund, then token0.
    function _takeProfitShare(VaultStore storage store, Vault storage vault, uint256 positionId, Closing memory closing)
        private
        returns (uint256 share)
    {
        MakerPosition storage position = store.makerPositions[positionId];
        closing.basis = VaultBook.closedBasis(position.basis, position.escrow, closing.fractionWad);
        if (closing.fractionWad == WAD) closing.refund = position.escrow;
        (bool ok, uint160 sqrtBidX96) = VaultPricing.tryCloseBid(vault);
        share = _shareOwed(vault, closing, ok, sqrtBidX96);
        if (share == 0) return 0;
        (uint256 share0, uint256 share1) = _takeShare(vault, position, closing, share, ok, sqrtBidX96);
        MakerSettlement.payProfitShare(store, vault, positionId, closing.closedMaximum1ByLeg, share0, share1);
    }

    /// @dev The profit share owed: proceeds valued at the bid when `priced`, else at the closed part's strike, less the
    /// basis closed.
    function _shareOwed(Vault storage vault, Closing memory closing, bool priced, uint160 sqrtBidX96)
        private
        view
        returns (uint256)
    {
        uint256 value0 = priced
            ? VaultMath.priceTimes(closing.leftover0, sqrtBidX96, false)
            : FullMath.mulDiv(closing.leftover0, closing.closedMaximum1, closing.closedMaximum0);
        uint256 proceeds = value0 + closing.leftover1 + closing.refund;
        return VaultBook.profit(proceeds, closing.basis) * vault.parameters.profitShareBps / MakerMath.BPS;
    }

    /// @dev Takes the share from the token1 leftover, then the refund, then token0, and returns it by token.
    function _takeShare(
        Vault storage vault,
        MakerPosition storage position,
        Closing memory closing,
        uint256 share,
        bool priced,
        uint160 sqrtBidX96
    ) private returns (uint256 share0, uint256 share1) {
        uint256 fromLeftover1 = _min(share, closing.leftover1);
        uint256 fromRefund = _min(share - fromLeftover1, closing.refund);
        uint256 rest = share - fromLeftover1 - fromRefund;
        uint256 owed0 = priced
            ? VaultPricing.token0At(sqrtBidX96, rest)
            : FullMath.mulDivRoundingUp(rest, closing.closedMaximum0, closing.closedMaximum1);
        share0 = _min(owed0, closing.leftover0);
        share1 = fromLeftover1 + fromRefund;
        closing.leftover0 -= share0;
        closing.leftover1 -= fromLeftover1;
        closing.refund -= fromRefund;
        vault.ledger.reserve0 -= share0.toUint128();
        vault.ledger.reserve1 -= fromLeftover1.toUint128();
        position.escrow -= fromRefund.toUint128();
        vault.ledger.escrow -= fromRefund.toUint128();
    }

    function _payOut(Vault storage vault, MakerPosition storage position, Closing memory closing, address recipient)
        private
        returns (uint256 paid0, uint256 paid1)
    {
        paid0 = closing.leftover0;
        paid1 = closing.leftover1 + closing.refund;
        vault.ledger.reserve0 -= closing.leftover0.toUint128();
        vault.ledger.reserve1 -= closing.leftover1.toUint128();
        if (closing.refund != 0) {
            position.escrow -= closing.refund.toUint128();
            vault.ledger.escrow -= closing.refund.toUint128();
        }
        VaultLedger.pushOrKeep(vault, 0, recipient, paid0);
        VaultLedger.pushOrKeep(vault, 1, recipient, paid1);
    }

    // ---------------------------------------------------------------- the rest of the position

    /// @dev A full close deletes the position and its legs. A partial close keeps the rest of every leg, with extremes
    /// recomputed from its own liquidity, and requires each leg above the minimum notional and the aggregate chord.
    function _shrinkOrDelete(VaultStore storage store, Vault storage vault, uint256 positionId, Closing memory closing)
        private
    {
        MakerPosition storage position = store.makerPositions[positionId];
        uint256 legCount = position.legCount;
        if (closing.fractionWad == WAD) {
            // legCount <= MAX_LEGS
            for (uint256 index = 0; index < legCount; ++index) {
                delete store.legs[positionId][index];
            }
            delete store.makerPositions[positionId];
            return;
        }
        (uint256 maximum0, uint256 maximum1) = _shrinkLegs(store, vault, positionId, closing);
        position.maximum0 = maximum0.toUint128();
        position.maximum1 = maximum1.toUint128();
        position.reserve0 -= closing.portion0.toUint128();
        position.reserve1 -= closing.portion1.toUint128();
        position.basis -= closing.basis.toUint128();
        bool solvent = MakerMath.aggregateChordHolds(position.reserve0, position.reserve1, maximum0, maximum1, legCount);
        if (!solvent) revert IMetricLendingVault.Insolvent();
    }

    function _shrinkLegs(VaultStore storage store, Vault storage vault, uint256 positionId, Closing memory closing)
        private
        returns (uint256 maximum0, uint256 maximum1)
    {
        uint256 legCount = store.makerPositions[positionId].legCount;
        uint256 minimumNotional = vault.book.settings.minimumNotional;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            Leg storage leg = store.legs[positionId][index];
            uint128 remaining = leg.liquidity - closing.closedLiquidity[index].toUint128();
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerAccounting.range(vault.book, leg.bucketId);
            (uint256 legMaximum0, uint256 legMaximum1) = VaultMath.debtExtremes(remaining, sqrtLowerX96, sqrtUpperX96);
            if (legMaximum1 < minimumNotional) revert IMakerBook.BelowMinimumNotional();
            leg.liquidity = remaining;
            leg.maximum0 = legMaximum0.toUint128();
            leg.maximum1 = legMaximum1.toUint128();
            maximum0 += legMaximum0;
            maximum1 += legMaximum1;
        }
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }
}
