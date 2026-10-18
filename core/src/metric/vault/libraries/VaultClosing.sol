// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CloseRequest, Position, Vault, VaultStore} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {Charge, VaultAccrual} from "./VaultAccrual.sol";
import {VaultBook} from "./VaultBook.sol";
import {VaultLedger} from "./VaultLedger.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultPricing} from "./VaultPricing.sol";
import {MetricVenue} from "./MetricVenue.sol";

/// @notice Closing positions: by their owner, in full or in part, and by anyone once a delinquent position's grace
/// period has passed.
/// @dev An external library: the singleton delegatecalls it. Repayment needs no price; the profit share values the
/// leftovers at the band's bid, or at the strike when the band cannot be read.
library VaultClosing {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @dev The closed part of a position and what becomes of it; a struct keeps the stack shallow.
    struct Closing {
        uint256 fractionWad;
        uint128 liquidity;
        uint256 portion0;
        uint256 portion1;
        uint256 repay0;
        uint256 repay1;
        uint256 released0;
        uint256 released1;
        uint256 basis;
        uint256 refund;
        uint256 leftover0;
        uint256 leftover1;
        /// @dev Premium a force close collects from the leftover, in token1: a wait that would leave the trader no
        /// more than this protects no one, so the close scales instead (audit finding W-3).
        uint256 arrears;
    }

    /// @notice Closes `fractionWad` of the caller's position, repaying with `repay0` and `repay1` from the closed part
    /// of the reserves. A partial close must pay all premium owed and leave the rest solvent.
    function close(VaultStore storage store, CloseRequest calldata request)
        external
        returns (uint256 paid0, uint256 paid1)
    {
        Position storage position = store.positions[request.positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        if (position.owner != msg.sender) revert IMetricLendingVault.Unauthorized();
        uint256 vaultId = position.vaultId;
        Vault storage vault = store.vaults[vaultId];
        VaultAccrual.checkpoint(vault, vaultId);
        Closing memory closing = _portion(position, request.fractionWad);
        _requireRepayment(position, closing, request.repay0, request.repay1);
        Charge memory unpaid = VaultBook.collect(vault, position, true);
        _payArrears(vault, position, closing, unpaid, closing.fractionWad != WAD);
        // Every charge is now paid (a partial close requires it), so the rest is not delinquent: a later lapse must
        // start a new grace period.
        position.delinquentSince = 0;
        _repay(vault, closing);
        uint256 share = _takeProfitShare(vault, position, closing);
        (paid0, paid1) = _payOut(vault, position, closing, msg.sender);
        _shrinkOrDelete(store, vault, request.positionId, position, closing);
        MetricVenue.place(vault, vaultId);
        emit IMetricLendingVault.Closed(request.positionId, closing.fractionWad, paid0, paid1, share);
    }

    /// @notice Closes a delinquent position whose grace period has passed, for a reward. Buys only the shortfall
    /// through Metric for the cheapest repayment at the close band's bid, which leaves out the fees the pool admin may
    /// change (W-1). Scales the reserves down to the repayment rule, which needs no price and no swap, only where that
    /// costs the trader nothing they would keep: no pool, no price, or a surplus that after buying the deficit would
    /// leave no more than the arrears (W-3). A swap that could pay but does not fill reverts, to be retried (Sol-2-1).
    /// The profit share is measured at the bid, as on an owner's close, and before the reward (Sol-1-2).
    function forceClose(VaultStore storage store, uint256 positionId)
        external
        returns (uint256 reward0, uint256 reward1)
    {
        Position storage position = store.positions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        uint256 vaultId = position.vaultId;
        Vault storage vault = store.vaults[vaultId];
        _requireForceClosable(vault, position);
        Charge memory unpaid = VaultBook.collect(vault, position, true);
        Closing memory closing = _portion(position, WAD);
        closing.arrears = unpaid.premium;
        _forcedRepayment(vault, position, closing);
        _payArrears(vault, position, closing, unpaid, false);
        _repay(vault, closing);
        _takeProfitShare(vault, position, closing);
        (reward0, reward1) = _reward(vault, closing);
        address owner = position.owner;
        _payOut(vault, position, closing, owner);
        _shrinkOrDelete(store, vault, positionId, position, closing);
        MetricVenue.place(vault, vaultId);
        emit IMetricLendingVault.ForceClosed(positionId, msg.sender, reward0, reward1);
    }

    // ---------------------------------------------------------------- portions

    function _portion(Position storage position, uint256 fractionWad) private view returns (Closing memory closing) {
        if (fractionWad == 0) revert IMetricLendingVault.InvalidFraction();
        if (fractionWad > WAD) revert IMetricLendingVault.InvalidFraction();
        closing.fractionWad = fractionWad;
        closing.liquidity = VaultMath.portionDown(position.liquidity, fractionWad).toUint128();
        if (closing.liquidity == 0) revert IMetricLendingVault.InvalidFraction();
        closing.portion0 = VaultMath.portionDown(position.reserve0, fractionWad);
        closing.portion1 = VaultMath.portionDown(position.reserve1, fractionWad);
        closing.released0 = VaultMath.portionUp(position.released0, fractionWad);
        closing.released1 = VaultMath.portionUp(position.released1, fractionWad);
    }

    function _requireRepayment(Position storage position, Closing memory closing, uint256 repay0, uint256 repay1)
        private
        view
    {
        if (repay0 > closing.portion0) revert IMetricLendingVault.RepaymentShort();
        if (repay1 > closing.portion1) revert IMetricLendingVault.RepaymentShort();
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        if (!VaultMath.repays(repay0, repay1, closing.liquidity, sqrtLowerX96, sqrtUpperX96)) {
            revert IMetricLendingVault.RepaymentShort();
        }
        closing.repay0 = repay0;
        closing.repay1 = repay1;
        closing.leftover0 = closing.portion0 - repay0;
        closing.leftover1 = closing.portion1 - repay1;
    }

    // ---------------------------------------------------------------- force closing

    function _requireForceClosable(Vault storage vault, Position storage position) private {
        uint256 flaggedAt = position.delinquentSince;
        if (flaggedAt == 0) revert IMetricLendingVault.NotDelinquent();
        if (block.timestamp < flaggedAt + vault.parameters.graceSeconds) {
            revert IMetricLendingVault.GracePeriodRunning();
        }
        VaultAccrual.checkpoint(vault, position.vaultId);
        if (VaultBook.shortfall(vault, position) == 0) revert IMetricLendingVault.NotDelinquent();
    }

    /// @dev Sets the repayment and leftovers of a full force close.
    function _forcedRepayment(Vault storage vault, Position storage position, Closing memory closing) private {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        if (_repayAtBid(vault, position, closing, sqrtLowerX96, sqrtUpperX96)) return;
        // The chord keeps the reserves repayable, and a failed swap leaves them untouched. Should they ever fail the
        // rule anyway, lenders take all of them rather than leave the position stuck.
        uint256 fractionWad = VaultMath.repays(
            position.reserve0, position.reserve1, position.liquidity, sqrtLowerX96, sqrtUpperX96
        )
            ? VaultMath.scaleToRepay(
                position.reserve0, position.reserve1, position.liquidity, sqrtLowerX96, sqrtUpperX96
            )
            : WAD;
        closing.repay0 = _min(VaultMath.portionUp(position.reserve0, fractionWad), position.reserve0);
        closing.repay1 = _min(VaultMath.portionUp(position.reserve1, fractionWad), position.reserve1);
        closing.portion0 = position.reserve0;
        closing.portion1 = position.reserve1;
        closing.leftover0 = position.reserve0 - closing.repay0;
        closing.leftover1 = position.reserve1 - closing.repay1;
    }

    /// @dev Repays the range's holdings at the band's bid, plus one unit of each token held, buying only the token the
    /// reserves lack. Returns false, with the reserves untouched, where the caller should scale them instead; a pool
    /// without a price reverts until `VaultPricing.NO_PRICE_WAIT_SECONDS` past the grace period.
    function _repayAtBid(
        Vault storage vault,
        Position storage position,
        Closing memory closing,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) private returns (bool) {
        if (vault.parameters.pool == address(0)) return false;
        (bool ok, uint160 sqrtBidX96) = VaultPricing.tryCloseBid(vault);
        if (!ok) {
            VaultPricing.requireNoPriceWaitOver(position.delinquentSince, vault.parameters.graceSeconds);
            return false;
        }
        (uint256 target0, uint256 target1) = _target(position.liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96);
        // The targets always pass; a failure would be a rounding surprise, and scaling needs no price.
        if (!VaultMath.repays(target0, target1, position.liquidity, sqrtLowerX96, sqrtUpperX96)) return false;
        if (!_buyShortfall(vault, position, target0, target1, closing.arrears)) return false;
        closing.repay0 = target0;
        closing.repay1 = target1;
        closing.portion0 = position.reserve0;
        closing.portion1 = position.reserve1;
        closing.leftover0 = position.reserve0 - target0;
        closing.leftover1 = position.reserve1 - target1;
        return true;
    }

    function _target(uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint160 sqrtPriceX96)
        private
        pure
        returns (uint256 target0, uint256 target1)
    {
        uint160 inside = sqrtPriceX96 < sqrtLowerX96 ? sqrtLowerX96 : sqrtPriceX96;
        inside = inside > sqrtUpperX96 ? sqrtUpperX96 : inside;
        target0 = SqrtPriceMath.getAmount0Delta(inside, sqrtUpperX96, liquidity, true);
        target1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, inside, liquidity, true);
        // A unit of each token the range holds at this price, for rounding; none of a token it does not hold, so a
        // position past its range never needs a swap for a unit its debt does not need (as `MakerClosing._legTarget`).
        if (target0 != 0) target0 += 1;
        if (target1 != 0) target1 += 1;
    }

    function _buyShortfall(
        Vault storage vault,
        Position storage position,
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
    /// is, token0 at the strike.
    function _budget(
        Vault storage vault,
        Position storage position,
        bool buyToken0,
        uint256 deficit,
        uint256 surplus,
        uint256 arrears
    ) private returns (uint256) {
        uint256 arrearsInSurplus = buyToken0 ? arrears : VaultPricing.token0AtStrike(position, arrears);
        return VaultPricing.shortfallBudget(vault, buyToken0, deficit, surplus, arrearsInSurplus);
    }

    /// @dev Buys exactly `deficit` through the pool for at most `maximumIn`, or reverts: the reserves could pay at the
    /// band, so scaling would hand the trader's surplus to lenders, and a paused or thin pool fills later, so the close
    /// waits for it (audit finding Sol-2-1).
    function _swapShortfall(
        Vault storage vault,
        Position storage position,
        bool buyToken0,
        uint256 deficit,
        uint256 maximumIn
    ) private {
        (bool filled, uint256 paid, uint256 received) =
            MetricVenue.trySwapExactOut(vault, position.vaultId, !buyToken0, deficit, maximumIn);
        if (!filled) revert IMetricLendingVault.ShortfallUnfilled();
        _applySwap(vault, position, !buyToken0, paid, received);
    }

    function _applySwap(Vault storage vault, Position storage position, bool zeroForOne, uint256 paid, uint256 received)
        private
    {
        if (paid == 0) {
            if (received == 0) return;
        }
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

    function _reward(Vault storage vault, Closing memory closing) private returns (uint256 reward0, uint256 reward1) {
        uint256 rewardBps = vault.parameters.forceCloseRewardBps;
        reward0 = closing.leftover0 * rewardBps / BPS;
        reward1 = closing.leftover1 * rewardBps / BPS;
        closing.leftover0 -= reward0;
        closing.leftover1 -= reward1;
        vault.ledger.reserve0 -= reward0.toUint128();
        vault.ledger.reserve1 -= reward1.toUint128();
        VaultLedger.push(vault, 0, msg.sender, reward0);
        VaultLedger.push(vault, 1, msg.sender, reward1);
    }

    // ---------------------------------------------------------------- settlement

    /// @dev Pays premium the escrow did not cover from the closed part's token1 leftover. A partial close
    /// must cover all of it there. A full close then takes token0 at the strike for what remains, keeping the
    /// premium's protocol slice and vesting the rest to lenders, and forgoes anything beyond.
    function _payArrears(
        Vault storage vault,
        Position storage position,
        Closing memory closing,
        Charge memory unpaid,
        bool partialClose
    ) private {
        uint256 due = VaultBook.total(unpaid);
        if (due == 0) return;
        if (partialClose) {
            if (due > closing.leftover1) revert IMetricLendingVault.PremiumUnpaid();
        }
        uint256 from1 = _min(due, closing.leftover1);
        closing.leftover1 -= from1;
        vault.ledger.reserve1 -= from1.toUint128();
        Charge memory remaining = VaultBook.payArrears(vault, unpaid, from1);
        uint256 remainingDue = VaultBook.total(remaining);
        if (remainingDue == 0) return;
        uint256 from0 = _min(VaultPricing.token0AtStrike(position, remainingDue), closing.leftover0);
        closing.leftover0 -= from0;
        vault.ledger.reserve0 -= from0.toUint128();
        VaultBook.payArrearsInToken0(vault, from0);
    }

    /// @dev The repayment joins the lenders' idle capital, and the released amounts stop counting as outstanding.
    function _repay(Vault storage vault, Closing memory closing) private {
        vault.ledger.reserve0 -= closing.repay0.toUint128();
        vault.ledger.reserve1 -= closing.repay1.toUint128();
        vault.ledger.buffer0 += closing.repay0.toUint128();
        vault.ledger.buffer1 += closing.repay1.toUint128();
        vault.accrual.outstanding0 -= _min(closing.released0, vault.accrual.outstanding0).toUint128();
        vault.accrual.outstanding1 -= _min(closing.released1, vault.accrual.outstanding1).toUint128();
    }

    /// @dev The profit share on a winning close: proceeds (leftovers, and a full close's escrow refund) valued at the
    /// band's bid, or at the strike when the band cannot be read, less the basis closed. Taken from token1 first, the
    /// leftover then the refund, and from token0 for the rest.
    function _takeProfitShare(Vault storage vault, Position storage position, Closing memory closing)
        private
        returns (uint256 share)
    {
        closing.basis = VaultBook.closedBasis(position.basis, position.escrow, closing.fractionWad);
        if (closing.fractionWad == WAD) closing.refund = position.escrow;
        (bool ok, uint160 sqrtBidX96) = VaultPricing.tryCloseBid(vault);
        uint256 value0 = ok
            ? VaultMath.priceTimes(closing.leftover0, sqrtBidX96, false)
            : VaultPricing.atStrike(position, closing.leftover0);
        uint256 proceeds = value0 + closing.leftover1 + closing.refund;
        share = VaultBook.profit(proceeds, closing.basis) * vault.parameters.profitShareBps / BPS;
        if (share == 0) return 0;
        uint256 fromLeftover1 = _min(share, closing.leftover1);
        uint256 fromRefund = _min(share - fromLeftover1, closing.refund);
        uint256 rest = share - fromLeftover1 - fromRefund;
        uint256 owed0 = ok ? VaultPricing.token0At(sqrtBidX96, rest) : VaultPricing.token0AtStrike(position, rest);
        uint256 share0 = _min(owed0, closing.leftover0);
        closing.leftover0 -= share0;
        closing.leftover1 -= fromLeftover1;
        closing.refund -= fromRefund;
        vault.ledger.reserve0 -= share0.toUint128();
        vault.ledger.reserve1 -= fromLeftover1.toUint128();
        position.escrow -= fromRefund.toUint128();
        vault.ledger.escrow -= fromRefund.toUint128();
        VaultBook.payProfitShare(vault, share0, fromLeftover1 + fromRefund);
    }

    function _payOut(Vault storage vault, Position storage position, Closing memory closing, address recipient)
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

    /// @dev A full close deletes the position. A partial close keeps the rest, with extremes recomputed from its own
    /// liquidity, and requires it to stay solvent and above the minimum borrow.
    function _shrinkOrDelete(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        Position storage position,
        Closing memory closing
    ) private {
        VaultBook.removeDebt(vault, position, position.liquidity);
        if (closing.fractionWad == WAD) {
            delete store.positions[positionId];
            return;
        }
        uint128 remaining = position.liquidity - closing.liquidity;
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(remaining, sqrtLowerX96, sqrtUpperX96);
        position.liquidity = remaining;
        position.maximum0 = maximum0.toUint128();
        position.maximum1 = maximum1.toUint128();
        position.reserve0 -= closing.portion0.toUint128();
        position.reserve1 -= closing.portion1.toUint128();
        position.released0 -= _min(closing.released0, position.released0).toUint128();
        position.released1 -= _min(closing.released1, position.released1).toUint128();
        position.basis -= closing.basis.toUint128();
        VaultBook.addDebt(vault, position, remaining);
        if (maximum1 < vault.parameters.minBorrowNotional) revert IMetricLendingVault.BelowMinimumBorrow();
        if (!VaultMath.chordHolds(position.reserve0, position.reserve1, maximum0, maximum1)) {
            revert IMetricLendingVault.Insolvent();
        }
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }
}
