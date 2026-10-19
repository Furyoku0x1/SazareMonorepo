// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PositionIndex} from "./PositionIndex.sol";
import {
    Book,
    BookSettings,
    Bucket,
    Leg,
    LegRequest,
    MakerIncreaseRequest,
    MakerOpenRequest,
    MakerPosition
} from "../MakerTypes.sol";
import {Vault, VaultStore} from "../VaultTypes.sol";
import {IMakerBook} from "../interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {MakerAccounting} from "./MakerAccounting.sol";
import {MakerMath} from "./MakerMath.sol";
import {MakerSettlement} from "./MakerSettlement.sol";
import {MetricVenue} from "./MetricVenue.sol";
import {VenueSwap} from "./VenueSwap.sol";
import {VaultLedger} from "./VaultLedger.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultPricing} from "./VaultPricing.sol";

/// @notice Opening maker positions, topping them up, settling their premium and flagging delinquent ones.
/// @dev An external library: the singleton delegatecalls it, so `msg.sender` is the trader. A maker position borrows
/// up to `MakerMath.MAX_LEGS` ranges from makers' buckets on one side of the price and must hold the aggregate chord.
library MakerPositions {
    using SafeCast for uint256;

    /// @dev Running totals of an open across its legs; a struct keeps the stack shallow.
    struct Opening {
        uint160 sqrtBidX96;
        uint160 sqrtAskX96;
        /// @dev Ids must ascend strictly: the next leg's id is at least this.
        uint256 nextMinimumBucketId;
        uint256 maximum0;
        uint256 maximum1;
        uint256 release0;
        uint256 release1;
        /// @dev Σ M1 · yearly rate in WAD, after the borrow. Kept at full precision: whole basis points would let a
        /// fraction of a basis point pass the trader's maximum and the escrow minimum (Sol's finding).
        uint256 rateWeightedWad;
        /// @dev What the escrow must hold after the prepayment: Σ of each leg's dues over the minimum escrow period.
        uint256 escrowNeeded;
    }

    /// @notice Opens a maker position: borrows each leg from its bucket, adds the trader's collateral and escrow,
    /// prepays each leg's minimum charge from the escrow, optionally swaps into the target asset, and requires the
    /// aggregate chord, the trader's rate limit and the minimum escrow.
    function open(VaultStore storage store, MakerOpenRequest calldata request) external returns (uint256 positionId) {
        Vault storage vault = _vault(store, request.vaultId);
        Book storage book = _book(vault);
        uint256 legCount = request.legs.length;
        if (legCount == 0) revert IMakerBook.InvalidLegs();
        if (legCount > MakerMath.MAX_LEGS) revert IMakerBook.InvalidLegs();
        Opening memory opening;
        (opening.sqrtBidX96, opening.sqrtAskX96) = VaultPricing.band(vault);
        positionId = ++store.lastPositionId;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            _openLeg(vault, book, store.legs[positionId][index], request.legs[index], request.isLong, opening);
        }
        MakerPosition storage position = store.makerPositions[positionId];
        position.owner = msg.sender;
        position.vaultId = request.vaultId.toUint32();
        position.isLong = request.isLong;
        _record(position, legCount, opening);
        PositionIndex.add(store.makerPositionIds[position.owner], store.indexInOwnerList, positionId);
        _fund(vault, position, request.collateral, request.escrow);
        _prepay(store, vault, position, positionId, 0);
        uint256 available = request.isLong ? position.reserve1 : position.reserve0;
        VenueSwap.Trade memory trade =
            _trade(opening, request.isLong, request.entryAmountIn, request.entryMinimumOut, request.entryVenue);
        _enter(vault, position, trade, request.entryRoute, available);
        _priceLegs(store, book, positionId, legCount, opening);
        _requireOpenable(position, request.maximumRateBps, opening);
        emit IMakerBook.MakerOpened(
            positionId, request.vaultId, msg.sender, request.isLong, legCount, opening.maximum0, opening.maximum1
        );
    }

    /// @notice Adds legs to the caller's position, as an open of them would and under the same checks applied to the
    /// whole position after it. Settles first, so the position must owe nothing beyond its escrow and not be flagged.
    function increase(VaultStore storage store, MakerIncreaseRequest calldata request) external {
        uint256 positionId = request.positionId;
        MakerPosition storage position = _owned(store, positionId);
        Vault storage vault = store.vaults[position.vaultId];
        Book storage book = _book(vault);
        if (request.legs.length == 0) revert IMakerBook.InvalidLegs();
        uint256 firstIndex = position.legCount;
        uint256 legCount = firstIndex + request.legs.length;
        if (legCount > MakerMath.MAX_LEGS) revert IMakerBook.InvalidLegs();
        // A flagged position always has a shortfall (only a settlement clears the flag), so this refuses it too.
        if (!_trySettle(store, vault, positionId)) revert IMetricLendingVault.PremiumUnpaid();
        Opening memory opening;
        (opening.sqrtBidX96, opening.sqrtAskX96) = VaultPricing.band(vault);
        // legCount <= MAX_LEGS
        for (uint256 index = firstIndex; index < legCount; ++index) {
            LegRequest calldata legRequest = request.legs[index - firstIndex];
            _openLeg(vault, book, store.legs[positionId][index], legRequest, position.isLong, opening);
        }
        _record(position, legCount, opening);
        _fund(vault, position, request.collateral, request.escrow);
        _prepay(store, vault, position, positionId, firstIndex);
        uint256 available = position.isLong ? opening.release1 + request.collateral : opening.release0;
        VenueSwap.Trade memory trade =
            _trade(opening, position.isLong, request.entryAmountIn, request.entryMinimumOut, request.entryVenue);
        _enter(vault, position, trade, request.entryRoute, available);
        _priceLegs(store, book, positionId, legCount, opening);
        _requireOpenable(position, request.maximumRateBps, opening);
        emit IMakerBook.MakerIncreased(positionId, legCount - firstIndex, opening.maximum0, opening.maximum1);
    }

    /// @notice Adds token1 to the escrow, then settles; a settled position is no longer delinquent.
    function addEscrow(VaultStore storage store, uint256 positionId, uint256 amount) external {
        MakerPosition storage position = _owned(store, positionId);
        if (amount == 0) revert IMetricLendingVault.ZeroAmount();
        Vault storage vault = store.vaults[position.vaultId];
        VaultLedger.pull(vault, 1, msg.sender, amount);
        position.escrow += amount.toUint128();
        vault.ledger.escrow += amount.toUint128();
        position.basis += amount.toUint128();
        emit IMetricLendingVault.EscrowAdded(positionId, amount);
        _trySettle(store, vault, positionId);
    }

    /// @notice Adds token1 to the reserves.
    function addCollateral(VaultStore storage store, uint256 positionId, uint256 amount) external {
        MakerPosition storage position = _owned(store, positionId);
        if (amount == 0) revert IMetricLendingVault.ZeroAmount();
        Vault storage vault = store.vaults[position.vaultId];
        VaultLedger.pull(vault, 1, msg.sender, amount);
        position.reserve1 += amount.toUint128();
        vault.ledger.reserve1 += amount.toUint128();
        position.basis += amount.toUint128();
        emit IMetricLendingVault.CollateralAdded(positionId, amount);
    }

    /// @notice Adds token0 to the reserves, so a position that owes token0 can repay in kind with no swap (audit
    /// finding W-4). The basis counts it at the close band's bid, the price a close values returned token0 at, so a
    /// round trip leaves the profit share exactly where it was (Sol).
    function addCollateral0(VaultStore storage store, uint256 positionId, uint256 amount) external {
        MakerPosition storage position = _owned(store, positionId);
        if (amount == 0) revert IMetricLendingVault.ZeroAmount();
        Vault storage vault = store.vaults[position.vaultId];
        (bool priced, uint160 sqrtBidX96) = VaultPricing.tryCloseBid(vault);
        if (!priced) revert IMetricLendingVault.InvalidBand();
        VaultLedger.pull(vault, 0, msg.sender, amount);
        position.reserve0 += amount.toUint128();
        vault.ledger.reserve0 += amount.toUint128();
        position.basis += VaultMath.priceTimes(amount, sqrtBidX96, false).toUint128();
        emit IMetricLendingVault.Collateral0Added(positionId, amount);
    }

    /// @notice Settles the position's premium from its escrow if the escrow covers it; otherwise does nothing.
    function settle(VaultStore storage store, uint256 positionId) external returns (bool) {
        MakerPosition storage position = store.makerPositions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        return _trySettle(store, store.vaults[position.vaultId], positionId);
    }

    /// @notice Starts a delinquent position's grace period. Anyone may flag; the clock does not restart while the
    /// position stays flagged.
    function flag(VaultStore storage store, uint256 positionId) external {
        MakerPosition storage position = store.makerPositions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        Vault storage vault = store.vaults[position.vaultId];
        if (MakerSettlement.shortfall(store, vault, positionId) == 0) revert IMetricLendingVault.NotDelinquent();
        if (position.delinquentSince != 0) return;
        position.delinquentSince = uint40(block.timestamp);
        emit IMetricLendingVault.Flagged(positionId);
    }

    // ---------------------------------------------------------------- legs

    /// @dev Borrows one leg: its bucket must be active, on the position's side and wholly on its waiting side of the
    /// band, and must stay within the ceiling after lending. Ids ascend strictly, so no bucket is borrowed twice.
    function _openLeg(
        Vault storage vault,
        Book storage book,
        Leg storage leg,
        LegRequest calldata request,
        bool isLong,
        Opening memory opening
    ) private {
        // Extremes round a zero liquidity up to a unit each, so it would pass every check and never repay (audit
        // finding C1).
        if (request.liquidity == 0) revert IMakerBook.InvalidLegs();
        if (request.bucketId < opening.nextMinimumBucketId) revert IMakerBook.InvalidLegs();
        opening.nextMinimumBucketId = request.bucketId + 1;
        (, bool isBuy,) = MakerMath.decode(request.bucketId);
        if (isBuy != isLong) revert IMakerBook.InvalidLegs();
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerAccounting.range(book, request.bucketId);
        MakerMath.requireWaitingSide(isBuy, opening.sqrtBidX96, opening.sqrtAskX96, sqrtLowerX96, sqrtUpperX96);
        Bucket storage bucket = MakerAccounting.checkpoint(book, request.bucketId);
        if (bucket.totalShares == 0) revert IMakerBook.UnknownBucket();
        if (bucket.retired) revert IMakerBook.BucketRetired();
        _borrow(vault, book, bucket, leg, request, sqrtLowerX96, sqrtUpperX96, opening);
        MakerAccounting.requireCeiling(book, bucket, isBuy, sqrtLowerX96, sqrtUpperX96);
    }

    /// @dev Adds every leg's rate and dues at the rates after all of the call's borrows: an increase may borrow from a
    /// bucket an existing leg uses, which raises that leg's curve too.
    function _priceLegs(
        VaultStore storage store,
        Book storage book,
        uint256 positionId,
        uint256 legCount,
        Opening memory opening
    ) private view {
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < legCount; ++index) {
            _priceLeg(book, store.legs[positionId][index], opening);
        }
    }

    function _priceLeg(Book storage book, Leg storage leg, Opening memory opening) private view {
        uint256 bucketId = leg.bucketId;
        (, bool isBuy,) = MakerMath.decode(bucketId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerAccounting.range(book, bucketId);
        Bucket storage bucket = book.buckets[bucketId];
        uint256 curveRateWad = MakerAccounting.curveRateWad(book, bucket, isBuy, sqrtLowerX96, sqrtUpperX96);
        uint256 floorRateWad = uint256(leg.floorRateBps) * (MakerMath.WAD / MakerMath.BPS);
        opening.rateWeightedWad += uint256(leg.maximum1) * (curveRateWad + floorRateWad);
        opening.escrowNeeded += _horizonDues(book.settings, leg, curveRateWad);
    }

    /// @dev What a leg owes over the minimum escrow period from the open at the rates in force now: the curve over the
    /// whole period, the floor over what is left of it after the prepaid charge. Rounded as settlement rounds.
    function _horizonDues(BookSettings storage settings, Leg storage leg, uint256 curveRateWad)
        private
        view
        returns (uint256)
    {
        uint256 escrowSeconds = settings.minimumEscrowSeconds;
        uint256 horizonEnd = block.timestamp + escrowSeconds;
        uint256 floorStart = leg.settledAt > block.timestamp ? leg.settledAt : block.timestamp;
        uint256 floorSeconds = horizonEnd > floorStart ? horizonEnd - floorStart : 0;
        uint256 growthRay = VaultMath.growthAtRateRay(curveRateWad, escrowSeconds);
        return MakerMath.owed(leg.maximum1, growthRay, leg.floorRateBps, floorSeconds);
    }

    /// @dev Moves the leg's release from the bucket to the position's reserves and records the leg's debt, floor and
    /// snapshot.
    function _borrow(
        Vault storage vault,
        Book storage book,
        Bucket storage bucket,
        Leg storage leg,
        LegRequest calldata request,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        Opening memory opening
    ) private {
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(request.liquidity, sqrtLowerX96, sqrtUpperX96);
        if (maximum1 < book.settings.minimumNotional) revert IMakerBook.BelowMinimumNotional();
        (uint256 release0, uint256 release1) = VaultMath.releaseAcrossBand(
            request.liquidity, sqrtLowerX96, sqrtUpperX96, opening.sqrtBidX96, opening.sqrtAskX96
        );
        if (release0 > bucket.balance0) revert IMetricLendingVault.InsufficientIdle();
        if (release1 > bucket.balance1) revert IMetricLendingVault.InsufficientIdle();
        bucket.balance0 -= release0.toUint128();
        bucket.balance1 -= release1.toUint128();
        book.balance0 -= release0.toUint128();
        book.balance1 -= release1.toUint128();
        bucket.lent += request.liquidity;
        vault.ledger.reserve0 += release0.toUint128();
        vault.ledger.reserve1 += release1.toUint128();
        leg.bucketId = request.bucketId;
        leg.liquidity = request.liquidity;
        leg.maximum0 = maximum0.toUint128();
        leg.maximum1 = maximum1.toUint128();
        leg.rateIndexRay = bucket.rateIndexRay;
        leg.floorRateBps = _floorRateBps(book, request.bucketId, sqrtLowerX96, sqrtUpperX96, opening).toUint32();
        // The open prepays the floor's first `minimumChargeSeconds`, so it accrues from then.
        leg.settledAt = uint40(block.timestamp + book.settings.minimumChargeSeconds);
        leg.openedAt = uint40(block.timestamp);
        opening.maximum0 += maximum0;
        opening.maximum1 += maximum1;
        opening.release0 += release0;
        opening.release1 += release1;
    }

    /// @dev The floor for a leg opened now: the current table's row for the distance between the nearer band edge and
    /// the level's geometric strike.
    function _floorRateBps(
        Book storage book,
        uint256 bucketId,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        Opening memory opening
    ) private view returns (uint256) {
        (, bool isBuy,) = MakerMath.decode(bucketId);
        uint160 sqrtEdgeX96 = isBuy ? opening.sqrtBidX96 : opening.sqrtAskX96;
        uint256 distanceBps = MakerMath.strikeDistanceBps(isBuy, sqrtEdgeX96, sqrtLowerX96, sqrtUpperX96);
        return MakerMath.floorRateBps(book.floorTables[book.floorTables.length - 1].rows, distanceBps);
    }

    // ---------------------------------------------------------------- the position

    /// @dev Adds the call's legs and releases to the position; an open starts from a zeroed position.
    function _record(MakerPosition storage position, uint256 legCount, Opening memory opening) private {
        position.legCount = uint8(legCount);
        position.maximum0 += opening.maximum0.toUint128();
        position.maximum1 += opening.maximum1.toUint128();
        position.reserve0 += opening.release0.toUint128();
        position.reserve1 += opening.release1.toUint128();
    }

    function _fund(Vault storage vault, MakerPosition storage position, uint128 collateral, uint128 escrow) private {
        VaultLedger.pull(vault, 1, msg.sender, uint256(collateral) + escrow);
        position.reserve1 += collateral;
        vault.ledger.reserve1 += collateral;
        position.escrow += escrow;
        vault.ledger.escrow += escrow;
        position.basis += (uint256(collateral) + escrow).toUint128();
    }

    /// @dev Pays each leg's minimum charge, `minimumChargeSeconds` of its floor, from the escrow to its bucket. It stays
    /// in the trader's basis, like any premium.
    function _prepay(
        VaultStore storage store,
        Vault storage vault,
        MakerPosition storage position,
        uint256 positionId,
        uint256 firstIndex
    ) private {
        uint256 chargeSeconds = vault.book.settings.minimumChargeSeconds;
        uint256 legCount = position.legCount;
        uint256 total;
        // legCount <= MAX_LEGS
        for (uint256 index = firstIndex; index < legCount; ++index) {
            Leg storage leg = store.legs[positionId][index];
            uint256 charge = MakerMath.owed(leg.maximum1, 0, leg.floorRateBps, chargeSeconds);
            total += charge;
            // Each leg's bucket was checkpointed now when the leg borrowed.
            MakerSettlement.payPremium(vault, leg.bucketId, charge);
        }
        if (total > position.escrow) revert IMetricLendingVault.EscrowTooSmall();
        position.escrow -= total.toUint128();
        vault.ledger.escrow -= total.toUint128();
    }

    /// @dev The entry swap a request asks for: a long sells token1 for token0, a short token0 for token1, its fill
    /// measured at the band the legs were priced at.
    function _trade(Opening memory opening, bool isLong, uint256 amountIn, uint256 minimumOut, address venue)
        private
        pure
        returns (VenueSwap.Trade memory)
    {
        return VenueSwap.Trade({
            zeroForOne: !isLong,
            amountIn: amountIn,
            minimumOut: minimumOut,
            venue: venue,
            sqrtBidX96: opening.sqrtBidX96,
            sqrtAskX96: opening.sqrtAskX96
        });
    }

    /// @dev The entry swap, through the venue the trader chose, from no more than `available`, what the call itself
    /// put in.
    function _enter(
        Vault storage vault,
        MakerPosition storage position,
        VenueSwap.Trade memory trade,
        bytes calldata route,
        uint256 available
    ) private {
        if (trade.amountIn == 0) return;
        if (trade.amountIn > available) revert IMetricLendingVault.InvalidParameters();
        (uint256 paid, uint256 received, uint256 lost) =
            MetricVenue.swapForTrader(vault, position.vaultId, trade, route);
        _moveReserves(vault, position, paid, received, trade.zeroForOne);
        _chargeToBasis(position, lost);
    }

    /// @dev A fill's loss against the band counts as taken out of the position, as in `VaultPositions`: the profit
    /// share is measured as if the swap had filled at the band.
    function _chargeToBasis(MakerPosition storage position, uint256 lost) private {
        uint256 basis = position.basis;
        position.basis = (lost < basis ? basis - lost : 0).toUint128();
    }

    function _moveReserves(
        Vault storage vault,
        MakerPosition storage position,
        uint256 paid,
        uint256 received,
        bool zeroForOne
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

    /// @dev The aggregate chord, with its per-leg rounding reserve; the trader's rate limit on the blended rate after
    /// the borrow, rounded up to a whole basis point; and, after the prepayment, an escrow covering every leg's dues
    /// over the minimum escrow period.
    function _requireOpenable(MakerPosition storage position, uint256 maximumRateBps, Opening memory opening)
        private
        view
    {
        uint256 maximum1 = position.maximum1;
        bool solvent = MakerMath.aggregateChordHolds(
            position.reserve0, position.reserve1, position.maximum0, maximum1, position.legCount
        );
        if (!solvent) revert IMetricLendingVault.Insolvent();
        uint256 blendedBps = FullMath.mulDivRoundingUp(opening.rateWeightedWad, MakerMath.BPS, MakerMath.WAD * maximum1);
        if (blendedBps > maximumRateBps) revert IMakerBook.RateAboveMaximum();
        if (position.escrow < opening.escrowNeeded) revert IMetricLendingVault.EscrowTooSmall();
    }

    // ---------------------------------------------------------------- settling

    function _trySettle(VaultStore storage store, Vault storage vault, uint256 positionId) private returns (bool) {
        if (MakerSettlement.shortfall(store, vault, positionId) != 0) return false;
        MakerSettlement.Dues memory dues = MakerSettlement.collect(store, vault, positionId, false);
        // The shortfall, rounded up, was zero, so the escrow covered everything.
        assert(dues.total == 0);
        store.makerPositions[positionId].delinquentSince = 0;
        emit IMetricLendingVault.Settled(positionId, dues.collected);
        return true;
    }

    function _vault(VaultStore storage store, uint256 vaultId) private view returns (Vault storage) {
        if (vaultId == 0) revert IMetricLendingVault.UnknownVault();
        if (vaultId > store.vaultCount) revert IMetricLendingVault.UnknownVault();
        return store.vaults[vaultId];
    }

    function _book(Vault storage vault) private view returns (Book storage book) {
        book = vault.book;
        if (!book.enabled) revert IMakerBook.BookDisabled();
    }

    function _owned(VaultStore storage store, uint256 positionId)
        private
        view
        returns (MakerPosition storage position)
    {
        position = store.makerPositions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        if (position.owner != msg.sender) revert IMetricLendingVault.Unauthorized();
    }
}
