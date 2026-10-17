// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Book, Bucket, Leg, MakerPosition} from "../MakerTypes.sol";
import {Vault, VaultStore} from "../VaultTypes.sol";
import {MakerAccounting} from "./MakerAccounting.sol";
import {MakerMath} from "./MakerMath.sol";
import {VaultMath} from "./VaultMath.sol";

/// @notice Premium and income flows between a maker position and its legs' buckets, shared by opening and closing:
/// collecting what legs owe, arrears from reserves, the profit share, and the shortfall that makes a position
/// delinquent. Maker flows never touch the passive vault's income, funding or debt totals.
library MakerSettlement {
    using SafeCast for uint256;

    /// @dev What each leg owes and has not been paid, in token1, indexed by leg.
    struct Dues {
        uint256 total;
        uint256[8] unpaid;
        /// @dev What `collect` took from the escrow.
        uint256 collected;
    }

    /// @notice The premium the position owes beyond its escrow. Checkpoints the legs' buckets.
    function shortfall(VaultStore storage store, Vault storage vault, uint256 positionId) internal returns (uint256) {
        MakerPosition storage position = store.makerPositions[positionId];
        uint256 owed = _owedTotal(store, vault.book, positionId, position.legCount);
        uint256 escrow = position.escrow;
        return owed > escrow ? owed - escrow : 0;
    }

    /// @notice Pays what every leg owes from the escrow, as far as it reaches, in proportion to what each owes, and
    /// moves each leg's snapshot to now. Returns what is still unpaid; the caller decides whether that is allowed.
    /// Closes round each leg's dues up once (`roundUp`); settlements anyone may call round down and carry the rest.
    function collect(VaultStore storage store, Vault storage vault, uint256 positionId, bool roundUp)
        internal
        returns (Dues memory dues)
    {
        MakerPosition storage position = store.makerPositions[positionId];
        uint256 legCount = position.legCount;
        uint256[8] memory owed;
        uint256 total;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            owed[index] = _settleLeg(vault.book, store.legs[positionId][index], roundUp);
            total += owed[index];
        }
        uint256 fromEscrow = total < position.escrow ? total : position.escrow;
        position.escrow -= fromEscrow.toUint128();
        vault.ledger.escrow -= fromEscrow.toUint128();
        dues.collected = fromEscrow;
        // `dues.total` starts at zero and gathers what each leg still has unpaid.
        _distributeToken1(store, vault, positionId, legCount, owed, total, fromEscrow, dues);
    }

    /// @notice Pays up to `amount1` token1 of the unpaid dues, from tokens already in custody, in proportion to what
    /// each leg is still owed, and updates `dues` to what remains unpaid.
    function payArrears1(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        Dues memory dues,
        uint256 amount1
    ) internal {
        uint256 total = dues.total;
        uint256 paid = amount1 < total ? amount1 : total;
        uint256 legCount = store.makerPositions[positionId].legCount;
        uint256[8] memory owed;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            owed[index] = dues.unpaid[index];
        }
        dues.total = 0;
        _distributeToken1(store, vault, positionId, legCount, owed, total, paid, dues);
    }

    /// @notice Pays unpaid dues in token0, worth `value` token1 at the strike: the protocol keeps its slice and the rest
    /// vests to the legs' buckets in proportion to what each is still owed.
    function payArrears0(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        Dues memory dues,
        uint256 amount0,
        uint256 value
    ) internal {
        if (amount0 == 0) return;
        // A positive token0 payment is only ever taken against dues still unpaid.
        assert(dues.total != 0);
        uint256 protocol0 = amount0 * vault.parameters.premiumProtocolBps / MakerMath.BPS;
        vault.ledger.treasury0 += protocol0.toUint128();
        uint256 settledTotal = value < dues.total ? value : dues.total;
        _distributeToken0(store, vault, positionId, dues, amount0 - protocol0, settledTotal);
        dues.total -= settledTotal;
    }

    /// @notice Splits a profit share between the treasury, the fee vault and the makers. The makers' part goes to the
    /// legs' buckets in proportion to the `M1` each leg closed, in whichever tokens were collected.
    function payProfitShare(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        uint256[8] memory closedMaximum1,
        uint256 share0,
        uint256 share1
    ) internal {
        (uint256 makers0, uint256 makers1) = _payProtocolShare(vault, share0, share1);
        _fundByWeight(store, vault, positionId, closedMaximum1, makers0, makers1);
    }

    // ---------------------------------------------------------------- legs

    /// @dev Checkpoints the leg's bucket and returns what the leg owes since its last settlement, moving the leg's
    /// snapshot to now.
    function _settleLeg(Book storage book, Leg storage leg, bool roundUp) private returns (uint256) {
        Bucket storage bucket = MakerAccounting.checkpoint(book, leg.bucketId);
        return MakerMath.settleLeg(leg, bucket.rateIndexRay, block.timestamp, roundUp);
    }

    function _owedTotal(VaultStore storage store, Book storage book, uint256 positionId, uint256 legCount)
        private
        returns (uint256 total)
    {
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            Leg storage leg = store.legs[positionId][index];
            Bucket storage bucket = MakerAccounting.checkpoint(book, leg.bucketId);
            total += MakerMath.legOwed(leg, bucket.rateIndexRay, block.timestamp);
        }
    }

    /// @dev Pays `paid` token1 of `total` owed, in proportion to each leg's `owed`, and records what each leg still has
    /// unpaid in `dues`. Cumulative floors distribute exactly `paid`, and no leg is paid more than it is owed.
    function _distributeToken1(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        uint256 legCount,
        uint256[8] memory owed,
        uint256 total,
        uint256 paid,
        Dues memory dues
    ) private {
        if (total == 0) return;
        uint256 owedBefore;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            uint256 part = MakerMath.cumulativePart(paid, owedBefore, owed[index], total);
            owedBefore += owed[index];
            uint256 unpaid = owed[index] - part;
            dues.unpaid[index] = unpaid;
            dues.total += unpaid;
            payPremium(vault, store.legs[positionId][index].bucketId, part);
        }
    }

    /// @dev Funds the legs' buckets with `toMakers` token0 and settles `settledTotal` of their unpaid dues, both in
    /// proportion to what each leg is still owed; cumulative floors keep each leg's settlement within its dues.
    function _distributeToken0(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        Dues memory dues,
        uint256 toMakers,
        uint256 settledTotal
    ) private {
        uint256 legCount = store.makerPositions[positionId].legCount;
        uint256 total = dues.total;
        uint256 unpaidBefore;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            uint256 unpaid = dues.unpaid[index];
            uint256 part = MakerMath.cumulativePart(toMakers, unpaidBefore, unpaid, total);
            uint256 settled = MakerMath.cumulativePart(settledTotal, unpaidBefore, unpaid, total);
            unpaidBefore += unpaid;
            _fundBucket(vault, store.legs[positionId][index].bucketId, part, 0);
            dues.unpaid[index] = unpaid - settled;
        }
    }

    /// @notice Premium paid to a bucket from tokens already in custody: the protocol keeps its slice, the rest vests
    /// to the bucket's makers.
    function payPremium(Vault storage vault, uint256 bucketId, uint256 amount1) internal {
        if (amount1 == 0) return;
        uint256 protocolPart = amount1 * vault.parameters.premiumProtocolBps / MakerMath.BPS;
        vault.ledger.treasury1 += protocolPart.toUint128();
        _fundBucket(vault, bucketId, 0, amount1 - protocolPart);
    }

    /// @dev The treasury's and fee vault's parts of a profit share; returns the makers' part of each token.
    function _payProtocolShare(Vault storage vault, uint256 share0, uint256 share1)
        private
        returns (uint256 makers0, uint256 makers1)
    {
        uint256 treasuryBps = vault.parameters.profitTreasuryBps;
        uint256 feeVaultBps = vault.parameters.profitFeeVaultBps;
        uint256 treasury0;
        uint256 feeVault0;
        (makers0, treasury0, feeVault0) = VaultMath.splitShare(share0, treasuryBps, feeVaultBps);
        vault.ledger.treasury0 += treasury0.toUint128();
        vault.ledger.feeVault0 += feeVault0.toUint128();
        uint256 treasury1;
        uint256 feeVault1;
        (makers1, treasury1, feeVault1) = VaultMath.splitShare(share1, treasuryBps, feeVaultBps);
        vault.ledger.treasury1 += treasury1.toUint128();
        vault.ledger.feeVault1 += feeVault1.toUint128();
    }

    /// @dev Funds the legs' buckets in proportion to `weights`; cumulative floors distribute exactly the amounts given.
    function _fundByWeight(
        VaultStore storage store,
        Vault storage vault,
        uint256 positionId,
        uint256[8] memory weights,
        uint256 amount0,
        uint256 amount1
    ) private {
        uint256 legCount = store.makerPositions[positionId].legCount;
        uint256 weightTotal;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            weightTotal += weights[index];
        }
        // Every closed leg closed some liquidity, and `debtExtremes` adds a unit, so no weight is zero and nothing taken
        // is left outside the ledger (Sol's finding).
        assert(weightTotal != 0);
        uint256 weightBefore;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            uint256 part0 = MakerMath.cumulativePart(amount0, weightBefore, weights[index], weightTotal);
            uint256 part1 = MakerMath.cumulativePart(amount1, weightBefore, weights[index], weightTotal);
            weightBefore += weights[index];
            _fundBucket(vault, store.legs[positionId][index].bucketId, part0, part1);
        }
    }

    /// @dev The bucket is checkpointed now by the settlement that precedes every payment, so the income vests from now.
    /// A bucket keeps a share while it has loans out, so it has makers to pay; should it have none, the income goes to
    /// the treasury rather than a stream no one can earn.
    function _fundBucket(Vault storage vault, uint256 bucketId, uint256 amount0, uint256 amount1) private {
        if (amount0 == 0) {
            if (amount1 == 0) return;
        }
        Book storage book = vault.book;
        Bucket storage bucket = MakerAccounting.checkpoint(book, bucketId);
        if (bucket.totalShares == 0) {
            vault.ledger.treasury0 += amount0.toUint128();
            vault.ledger.treasury1 += amount1.toUint128();
            return;
        }
        MakerAccounting.fundIncome(book, bucket, amount0, amount1, vault.parameters.vestSeconds);
    }
}
