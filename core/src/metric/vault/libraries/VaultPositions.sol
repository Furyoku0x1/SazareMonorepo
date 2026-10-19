// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PositionIndex} from "./PositionIndex.sol";
import {ChargeStart, IncreaseRequest, OpenRequest, Position, Vault, VaultStore} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {Charge, VaultAccrual} from "./VaultAccrual.sol";
import {VaultBook} from "./VaultBook.sol";
import {VaultLedger} from "./VaultLedger.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultPricing} from "./VaultPricing.sol";
import {MetricVenue} from "./MetricVenue.sol";
import {RealizedCharge} from "./RealizedCharge.sol";
import {VenueSwap} from "./VenueSwap.sol";

/// @notice Opening positions, topping them up, settling their premium, and flagging delinquent ones.
/// @dev An external library: the singleton delegatecalls it, so `msg.sender` is the trader and token movements are
/// the singleton's.
library VaultPositions {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @dev What an open computes before it records the position; a struct keeps the stack shallow.
    struct Opening {
        uint160 sqrtLowerX96;
        uint160 sqrtUpperX96;
        uint160 sqrtBidX96;
        uint160 sqrtAskX96;
        uint256 maximum0;
        uint256 maximum1;
        uint256 release0;
        uint256 release1;
    }

    /// @notice Opens a position: releases the range's tokens from the lenders' idle capital, adds the trader's
    /// collateral, optionally swaps into the target asset, and requires the chord.
    function open(VaultStore storage store, OpenRequest calldata request) external returns (uint256 positionId) {
        Vault storage vault = _vault(store, request.vaultId);
        if (request.liquidity == 0) revert IMetricLendingVault.ZeroAmount();
        VaultAccrual.checkpoint(vault, request.vaultId);
        Opening memory opening = _price(vault, request.tickLower, request.tickUpper, request.liquidity);
        // Read before the release gathers from the pool, in the same state as the band the open priced at.
        uint160 sqrtMidX96 = _mid(vault);
        _release(vault, request.vaultId, opening);
        positionId = ++store.lastPositionId;
        Position storage position = store.positions[positionId];
        _record(vault, position, request, opening);
        RealizedCharge.start(vault, position, store.chargeStarts[positionId], sqrtMidX96);
        PositionIndex.add(store.passivePositionIds[position.owner], store.indexInOwnerList, positionId);
        _fund(vault, position, request.collateral, request.escrow);
        uint256 sellable = _sellable(opening, request.isLong, request.collateral);
        VenueSwap.Trade memory trade =
            _trade(opening, request.isLong, request.entryAmountIn, request.entryMinimumOut, request.entryVenue);
        _enter(vault, request.vaultId, position, trade, request.entryRoute, sellable);
        _requireSolvent(position);
        _requireEscrow(vault, position);
        MetricVenue.place(vault, request.vaultId);
        emit IMetricLendingVault.Opened(
            positionId,
            request.vaultId,
            msg.sender,
            request.isLong,
            request.tickLower,
            request.tickUpper,
            request.liquidity,
            opening.release0,
            opening.release1
        );
    }

    /// @notice Adds liquidity to the caller's position on its own range: settles the premium owed at the old size, then
    /// borrows the added liquidity as an open of that size would, merged into the same position, and requires every
    /// check an open makes of the combined position.
    function increase(VaultStore storage store, IncreaseRequest calldata request) external {
        Position storage position = _owned(store, request.positionId);
        if (request.liquidity == 0) revert IMetricLendingVault.ZeroAmount();
        uint256 vaultId = position.vaultId;
        Vault storage vault = store.vaults[vaultId];
        // Settled at the old size first, so the added liquidity pays nothing for the time before it was borrowed. A
        // flagged position always has a shortfall (only a settlement clears the flag), so this refuses it too; the
        // trader cures it with `addEscrow`.
        ChargeStart storage start = store.chargeStarts[request.positionId];
        if (!_trySettle(vault, request.positionId, position, start)) revert IMetricLendingVault.PremiumUnpaid();
        uint160 sqrtMidX96 = _mid(vault);
        _payStub(vault, position, start, sqrtMidX96);
        Opening memory opening = _price(vault, position.tickLower, position.tickUpper, request.liquidity);
        _release(vault, vaultId, opening);
        _merge(vault, position, request.liquidity, opening);
        RealizedCharge.start(vault, position, start, sqrtMidX96);
        _fund(vault, position, request.collateral, request.escrow);
        uint256 sellable = _sellable(opening, position.isLong, request.collateral);
        VenueSwap.Trade memory trade =
            _trade(opening, position.isLong, request.entryAmountIn, request.entryMinimumOut, request.entryVenue);
        _enter(vault, vaultId, position, trade, request.entryRoute, sellable);
        _requireSolvent(position);
        _requireEscrow(vault, position);
        MetricVenue.place(vault, vaultId);
        emit IMetricLendingVault.Increased(request.positionId, request.liquidity, opening.release0, opening.release1);
    }

    /// @notice Adds token1 to the premium escrow, then settles; a settled position is no longer delinquent.
    function addEscrow(VaultStore storage store, uint256 positionId, uint256 amount) external {
        Position storage position = _owned(store, positionId);
        if (amount == 0) revert IMetricLendingVault.ZeroAmount();
        Vault storage vault = store.vaults[position.vaultId];
        VaultLedger.pull(vault, 1, msg.sender, amount);
        position.escrow += amount.toUint128();
        vault.ledger.escrow += amount.toUint128();
        position.basis += amount.toUint128();
        emit IMetricLendingVault.EscrowAdded(positionId, amount);
        _trySettle(vault, positionId, position, store.chargeStarts[positionId]);
    }

    /// @notice Adds token1 collateral to the reserves.
    function addCollateral(VaultStore storage store, uint256 positionId, uint256 amount) external {
        Position storage position = _owned(store, positionId);
        if (amount == 0) revert IMetricLendingVault.ZeroAmount();
        Vault storage vault = store.vaults[position.vaultId];
        VaultLedger.pull(vault, 1, msg.sender, amount);
        position.reserve1 += amount.toUint128();
        vault.ledger.reserve1 += amount.toUint128();
        position.basis += amount.toUint128();
        emit IMetricLendingVault.CollateralAdded(positionId, amount);
    }

    /// @notice Adds token0 to the reserves, so a position that holds token1 and owes token0 can repay in kind with no
    /// swap, even while the pool cannot fill one (audit finding W-4). The basis counts it at the close band's bid, the
    /// price a close values returned token0 at, so adding token0 and taking it back leaves the profit share exactly
    /// where it was; at the ask, a round trip would cut the share by the spread on whatever was added (Sol).
    function addCollateral0(VaultStore storage store, uint256 positionId, uint256 amount) external {
        Position storage position = _owned(store, positionId);
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

    /// @notice Settles a position's premium from its escrow, if the escrow covers it; otherwise does nothing. Anyone
    /// may call, so lenders' income need not wait for a close.
    function settle(VaultStore storage store, uint256 positionId) external returns (bool settled) {
        Position storage position = store.positions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        Vault storage vault = store.vaults[position.vaultId];
        return _trySettle(vault, positionId, position, store.chargeStarts[positionId]);
    }

    /// @notice Starts a delinquent position's grace period. Anyone may flag; the clock does not restart while the
    /// position stays flagged.
    function flag(VaultStore storage store, uint256 positionId) external {
        Position storage position = store.positions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        Vault storage vault = store.vaults[position.vaultId];
        VaultAccrual.checkpoint(vault, position.vaultId);
        if (VaultBook.shortfall(vault, position, store.chargeStarts[positionId]) == 0) {
            revert IMetricLendingVault.NotDelinquent();
        }
        if (position.delinquentSince != 0) return;
        position.delinquentSince = uint40(block.timestamp);
        emit IMetricLendingVault.Flagged(positionId);
    }

    // ---------------------------------------------------------------- opening

    /// @dev Prices borrowing `liquidity` on a range now: its extremes, which must reach the minimum borrow, and its
    /// release across the band. An increase prices only the liquidity it adds, as an open of that size would.
    function _price(Vault storage vault, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        returns (Opening memory opening)
    {
        (opening.sqrtLowerX96, opening.sqrtUpperX96) = VaultMath.rangeSqrtPrices(tickLower, tickUpper);
        (opening.maximum0, opening.maximum1) =
            VaultMath.debtExtremes(liquidity, opening.sqrtLowerX96, opening.sqrtUpperX96);
        if (opening.maximum1 < vault.parameters.minBorrowNotional) revert IMetricLendingVault.BelowMinimumBorrow();
        (opening.sqrtBidX96, opening.sqrtAskX96) = VaultPricing.band(vault);
        (opening.release0, opening.release1) = VaultMath.releaseAcrossBand(
            liquidity, opening.sqrtLowerX96, opening.sqrtUpperX96, opening.sqrtBidX96, opening.sqrtAskX96
        );
    }

    /// @dev Moves the release from the lenders' idle capital to the trader's reserves, within the utilization ceiling.
    function _release(Vault storage vault, uint256 vaultId, Opening memory opening) private {
        _requireIdle(VaultAccrual.idle0(vault), opening.release0);
        _requireIdle(VaultAccrual.idle1(vault), opening.release1);
        _requireCeiling(vault, vault.accrual.outstanding0, VaultAccrual.rateIdle0(vault), opening.release0);
        _requireCeiling(vault, vault.accrual.outstanding1, VaultAccrual.rateIdle1(vault), opening.release1);
        if (!MetricVenue.gather(vault, vaultId, opening.release0, opening.release1)) {
            revert IMetricLendingVault.InsufficientIdle();
        }
        vault.ledger.buffer0 -= opening.release0.toUint128();
        vault.ledger.buffer1 -= opening.release1.toUint128();
        vault.ledger.reserve0 += opening.release0.toUint128();
        vault.ledger.reserve1 += opening.release1.toUint128();
        vault.accrual.outstanding0 += opening.release0.toUint128();
        vault.accrual.outstanding1 += opening.release1.toUint128();
    }

    /// @dev Releasing moves tokens from idle to outstanding, so the supplied total is unchanged: utilization after is
    /// `(outstanding + release) / (outstanding + idle)`.
    /// @dev The release must be idle in fact, in the token itself.
    function _requireIdle(uint256 idle, uint256 release) private pure {
        if (release > idle) revert IMetricLendingVault.InsufficientIdle();
    }

    /// @dev The ceiling is measured on the anchored idle, so a swap in the same transaction cannot pass it (X-3).
    function _requireCeiling(Vault storage vault, uint256 outstanding, uint256 idle, uint256 release) private view {
        if (release == 0) return;
        uint256 supplied = outstanding + idle;
        if ((outstanding + release) * BPS > supplied * vault.parameters.utilizationCeilingBps) {
            revert IMetricLendingVault.UtilizationCeiling();
        }
    }

    function _record(
        Vault storage vault,
        Position storage position,
        OpenRequest calldata request,
        Opening memory opening
    ) private {
        position.owner = msg.sender;
        position.vaultId = request.vaultId.toUint32();
        position.isLong = request.isLong;
        position.tickLower = request.tickLower;
        position.tickUpper = request.tickUpper;
        position.liquidity = request.liquidity;
        position.maximum0 = opening.maximum0.toUint128();
        position.maximum1 = opening.maximum1.toUint128();
        position.reserve0 = opening.release0.toUint128();
        position.reserve1 = opening.release1.toUint128();
        position.released0 = opening.release0.toUint128();
        position.released1 = opening.release1.toUint128();
        position.weight0Wad = _weight0(opening).toUint64();
        VaultAccrual.snapshot(vault, position);
        VaultBook.addDebt(vault, position, request.liquidity);
    }

    /// @dev Merges added liquidity into the position as one debt on its range: extremes from the total liquidity, as a
    /// partial close recomputes them, and the debt tree's entry replaced whole, since its terms round per entry.
    function _merge(Vault storage vault, Position storage position, uint128 added, Opening memory opening) private {
        uint128 liquidity = position.liquidity;
        uint128 total = liquidity + added;
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(total, opening.sqrtLowerX96, opening.sqrtUpperX96);
        uint256 weight0Wad = _mergedWeight0(position.weight0Wad, position.maximum1, _weight0(opening), opening.maximum1);
        VaultBook.removeDebt(vault, position, liquidity);
        position.liquidity = total;
        position.maximum0 = maximum0.toUint128();
        position.maximum1 = maximum1.toUint128();
        position.weight0Wad = weight0Wad.toUint64();
        position.reserve0 += opening.release0.toUint128();
        position.reserve1 += opening.release1.toUint128();
        position.released0 += opening.release0.toUint128();
        position.released1 += opening.release1.toUint128();
        VaultBook.addDebt(vault, position, total);
    }

    /// @dev Each part's weight by its own `M1`, since each part's premium is its `M1` at its own blend. Divided by the
    /// parts' sum, not the merged `M1`, which is a unit or two less (each extreme rounds up and adds one): the weight
    /// stays at most WAD, and the merged premium is the parts' at most two units of notional less.
    function _mergedWeight0(uint256 weight0Wad, uint256 maximum1, uint256 addedWeight0Wad, uint256 addedMaximum1)
        private
        pure
        returns (uint256)
    {
        return (weight0Wad * maximum1 + addedWeight0Wad * addedMaximum1) / (maximum1 + addedMaximum1);
    }

    /// @dev The premium blend: token0's share of the release's value at the bid.
    function _weight0(Opening memory opening) private pure returns (uint256) {
        uint256 value0 = VaultMath.priceTimes(opening.release0, opening.sqrtBidX96, false);
        uint256 total = value0 + opening.release1;
        if (total == 0) return 0;
        return FullMath.mulDiv(value0, WAD, total);
    }

    /// @dev Adds the trader's token1: collateral to the reserves, escrow to the premium escrow, both to the basis.
    function _fund(Vault storage vault, Position storage position, uint128 collateral, uint128 escrow) private {
        uint256 paidIn = uint256(collateral) + escrow;
        VaultLedger.pull(vault, 1, msg.sender, paidIn);
        position.reserve1 += collateral;
        vault.ledger.reserve1 += collateral;
        position.escrow += escrow;
        vault.ledger.escrow += escrow;
        position.basis += paidIn.toUint128();
    }

    /// @dev What an entry swap may sell: only what this call adds, in the token sold, as an open of the added size
    /// alone could. A long sells token1, its release and collateral; a short sells token0, its release.
    function _sellable(Opening memory opening, bool isLong, uint256 collateral) private pure returns (uint256) {
        if (isLong) return opening.release1 + collateral;
        return opening.release0;
    }

    /// @dev The entry swap a request asks for: a long sells token1 for token0, a short token0 for token1, its fill
    /// measured at the band the release was priced at.
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

    /// @dev The entry swap, through the venue the trader chose, of no more than this call adds.
    function _enter(
        Vault storage vault,
        uint256 vaultId,
        Position storage position,
        VenueSwap.Trade memory trade,
        bytes calldata route,
        uint256 sellable
    ) private {
        if (trade.amountIn == 0) return;
        if (trade.amountIn > sellable) revert IMetricLendingVault.InvalidParameters();
        (uint256 paid, uint256 received, uint256 lost) = MetricVenue.swapForTrader(vault, vaultId, trade, route);
        _moveReserves(vault, position, trade.zeroForOne, paid, received);
        _chargeToBasis(position, lost);
    }

    /// @dev A fill's loss against the band counts as taken out of the position: a venue the trader controls could
    /// return less than the market and keep the rest, so the profit share is measured as if the swap had filled at the
    /// band. The chord bounds what any fill can take to collateral the trader put in, all of it in the basis.
    function _chargeToBasis(Position storage position, uint256 lost) private {
        uint256 basis = position.basis;
        position.basis = (lost < basis ? basis - lost : 0).toUint128();
    }

    /// @dev The chord on the position as it now stands: an increase checks the combined position, as an open would.
    function _requireSolvent(Position storage position) private view {
        if (!VaultMath.chordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1)) {
            revert IMetricLendingVault.Insolvent();
        }
    }

    function _moveReserves(
        Vault storage vault,
        Position storage position,
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

    // ---------------------------------------------------------------- settling

    function _trySettle(Vault storage vault, uint256 positionId, Position storage position, ChargeStart storage start)
        private
        returns (bool)
    {
        VaultAccrual.checkpoint(vault, position.vaultId);
        if (VaultBook.shortfall(vault, position, start) != 0) return false;
        Charge memory owed = VaultAccrual.charge(vault, position, start, false, 0);
        Charge memory unpaid = VaultBook.collect(vault, position, start, false, 0);
        // The shortfall, rounded up, was zero, so the escrow covered everything.
        assert(VaultBook.total(unpaid) == 0);
        position.delinquentSince = 0;
        emit IMetricLendingVault.Settled(positionId, owed.premium);
        return true;
    }

    /// @dev The band's mid an open or increase starts the realized charge at; both already need a price.
    function _mid(Vault storage vault) private returns (uint160 sqrtMidX96) {
        bool priced;
        (priced, sqrtMidX96) = RealizedCharge.mid(vault);
        if (!priced) revert IMetricLendingVault.InvalidBand();
    }

    /// @dev Charges the old liquidity from where the settlement left its start to the price now, before the increase
    /// restarts the charge there. Paid from the escrow; an escrow that cannot pay it refuses the increase, as a
    /// shortfall does.
    function _payStub(Vault storage vault, Position storage position, ChargeStart storage start, uint160 sqrtMidX96)
        private
    {
        uint256 stubWad = RealizedCharge.stubWad(vault, position, start, sqrtMidX96);
        Charge memory unpaid = VaultBook.collect(vault, position, start, true, stubWad);
        if (VaultBook.total(unpaid) != 0) revert IMetricLendingVault.PremiumUnpaid();
    }

    /// @dev The escrow must cover the premium over `minimumEscrowSeconds` at the rates the borrow left, blended by the
    /// position's weights as its premium is, and rounded up as settlement rounds a close; and `minimumEscrowBps` of
    /// `M1`, since the realized charge is zero at the open and only a share of the notional can stand for it.
    function _requireEscrow(Vault storage vault, Position storage position) private view {
        uint256 notionalShare = FullMath.mulDivRoundingUp(position.maximum1, vault.parameters.minimumEscrowBps, BPS);
        if (position.escrow < notionalShare) revert IMetricLendingVault.EscrowTooSmall();
        (uint256 rate0Wad, uint256 rate1Wad) = VaultAccrual.currentRates(vault);
        uint256 weight0Wad = position.weight0Wad;
        uint256 wad = VaultAccrual.WAD;
        uint256 blendedWad = FullMath.mulDivRoundingUp(rate0Wad, weight0Wad, wad)
            + FullMath.mulDivRoundingUp(rate1Wad, wad - weight0Wad, wad);
        uint256 needed = FullMath.mulDivRoundingUp(
            uint256(position.maximum1) * blendedWad,
            vault.parameters.minimumEscrowSeconds,
            wad * VaultAccrual.YEAR_SECONDS
        );
        if (position.escrow < needed) revert IMetricLendingVault.EscrowTooSmall();
    }

    function _vault(VaultStore storage store, uint256 vaultId) private view returns (Vault storage vault) {
        if (vaultId == 0) revert IMetricLendingVault.UnknownVault();
        if (vaultId > store.vaultCount) revert IMetricLendingVault.UnknownVault();
        return store.vaults[vaultId];
    }

    function _owned(VaultStore storage store, uint256 positionId) private view returns (Position storage position) {
        position = store.positions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        if (position.owner != msg.sender) revert IMetricLendingVault.Unauthorized();
    }
}
