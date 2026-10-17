// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OpenRequest, Position, Vault, VaultStore} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {Charge, VaultAccrual} from "./VaultAccrual.sol";
import {VaultBook} from "./VaultBook.sol";
import {VaultLedger} from "./VaultLedger.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultPricing} from "./VaultPricing.sol";
import {MetricVenue} from "./MetricVenue.sol";

/// @notice Opening positions, topping them up, settling their premium and funding, and flagging delinquent ones.
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
        Opening memory opening = _price(vault, request);
        _release(vault, request.vaultId, opening);
        positionId = ++store.lastPositionId;
        Position storage position = store.positions[positionId];
        _record(vault, position, request, opening);
        _fund(vault, position, request);
        _enter(vault, request.vaultId, position, request);
        if (!VaultMath.chordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1)) {
            revert IMetricLendingVault.Insolvent();
        }
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
        _trySettle(vault, positionId, position);
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

    /// @notice Settles a position's premium and funding from its escrow, if the escrow covers them; otherwise does
    /// nothing. Anyone may call: it is how funding is collected for receivers between closes.
    function settle(VaultStore storage store, uint256 positionId) external returns (bool settled) {
        Position storage position = store.positions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        Vault storage vault = store.vaults[position.vaultId];
        return _trySettle(vault, positionId, position);
    }

    /// @notice Starts a delinquent position's grace period. Anyone may flag; the clock does not restart while the
    /// position stays flagged.
    function flag(VaultStore storage store, uint256 positionId) external {
        Position storage position = store.positions[positionId];
        if (position.owner == address(0)) revert IMetricLendingVault.UnknownPosition();
        Vault storage vault = store.vaults[position.vaultId];
        VaultAccrual.checkpoint(vault, position.vaultId);
        if (VaultBook.shortfall(vault, position) == 0) revert IMetricLendingVault.NotDelinquent();
        if (position.delinquentSince != 0) return;
        position.delinquentSince = uint40(block.timestamp);
        emit IMetricLendingVault.Flagged(positionId);
    }

    // ---------------------------------------------------------------- opening

    function _price(Vault storage vault, OpenRequest calldata request) private returns (Opening memory opening) {
        (opening.sqrtLowerX96, opening.sqrtUpperX96) = VaultMath.rangeSqrtPrices(request.tickLower, request.tickUpper);
        (opening.maximum0, opening.maximum1) =
            VaultMath.debtExtremes(request.liquidity, opening.sqrtLowerX96, opening.sqrtUpperX96);
        if (opening.maximum1 < vault.parameters.minBorrowNotional) revert IMetricLendingVault.BelowMinimumBorrow();
        uint160 sqrtAskX96;
        (opening.sqrtBidX96, sqrtAskX96) = VaultPricing.band(vault);
        (opening.release0, opening.release1) = VaultMath.releaseAcrossBand(
            request.liquidity, opening.sqrtLowerX96, opening.sqrtUpperX96, opening.sqrtBidX96, sqrtAskX96
        );
    }

    /// @dev Moves the release from the lenders' idle capital to the trader's reserves, within the utilization ceiling.
    function _release(Vault storage vault, uint256 vaultId, Opening memory opening) private {
        _requireCeiling(vault, vault.accrual.outstanding0, VaultAccrual.idle0(vault), opening.release0);
        _requireCeiling(vault, vault.accrual.outstanding1, VaultAccrual.idle1(vault), opening.release1);
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
    function _requireCeiling(Vault storage vault, uint256 outstanding, uint256 idle, uint256 release) private view {
        if (release == 0) return;
        if (release > idle) revert IMetricLendingVault.InsufficientIdle();
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

    /// @dev The premium blend: token0's share of the release's value at the bid.
    function _weight0(Opening memory opening) private pure returns (uint256) {
        uint256 value0 = VaultMath.priceTimes(opening.release0, opening.sqrtBidX96, false);
        uint256 total = value0 + opening.release1;
        if (total == 0) return 0;
        return FullMath.mulDiv(value0, WAD, total);
    }

    function _fund(Vault storage vault, Position storage position, OpenRequest calldata request) private {
        VaultLedger.pull(vault, 1, msg.sender, uint256(request.collateral) + request.escrow);
        position.reserve1 += request.collateral;
        vault.ledger.reserve1 += request.collateral;
        position.escrow = request.escrow;
        vault.ledger.escrow += request.escrow;
        position.basis = uint128(uint256(request.collateral) + request.escrow);
    }

    /// @dev The entry swap: a long sells token1 for token0, a short token0 for token1, through the vault's pool.
    function _enter(Vault storage vault, uint256 vaultId, Position storage position, OpenRequest calldata request)
        private
    {
        if (request.entryAmountIn == 0) return;
        if (vault.parameters.pool == address(0)) revert IMetricLendingVault.InvalidParameters();
        bool zeroForOne = !request.isLong;
        uint256 available = zeroForOne ? position.reserve0 : position.reserve1;
        if (request.entryAmountIn > available) revert IMetricLendingVault.InvalidParameters();
        (uint256 paid, uint256 received) =
            MetricVenue.swapExactIn(vault, vaultId, zeroForOne, request.entryAmountIn, request.entryMinimumOut);
        _moveReserves(vault, position, zeroForOne, paid, received);
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

    function _trySettle(Vault storage vault, uint256 positionId, Position storage position) private returns (bool) {
        VaultAccrual.checkpoint(vault, position.vaultId);
        if (VaultBook.shortfall(vault, position) != 0) return false;
        Charge memory owed = VaultAccrual.charge(vault, position, false);
        Charge memory unpaid = VaultBook.collect(vault, position, false);
        // The shortfall, rounded up, was zero, so the escrow covered everything.
        assert(VaultBook.total(unpaid) == 0);
        position.delinquentSince = 0;
        emit IMetricLendingVault.Settled(positionId, owed.premium);
        return true;
    }

    /// @dev The escrow must cover the premium over `minimumEscrowSeconds` at the rates the borrow left, blended by the
    /// position's weights as its premium is, and rounded up as settlement rounds a close.
    function _requireEscrow(Vault storage vault, Position storage position) private view {
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
