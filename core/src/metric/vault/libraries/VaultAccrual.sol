// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CurvePair, Position, Vault} from "../VaultTypes.sol";
import {VaultMath} from "./VaultMath.sol";
import {MetricVenue} from "./MetricVenue.sol";

/// @notice What a position owes since its last settlement, in token1.
struct Charge {
    uint256 premium;
    /// @dev What a settlement rounding down leaves of `premium` for the next, in WAD of a unit; see `Position`.
    uint256 premiumFractionWad;
}

/// @notice Premium indices, the lenders' income stream, and what each position owes.
/// @dev Utilization changes only at checkpoints, so each index grows by an exact integral of a constant rate over the
/// interval. v1 has no funding between longs and shorts: the audit found its pay-as-collected design let a trader's
/// own long and short draw funding never paid (finding A1), and the owner removed it.
library VaultAccrual {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant YEAR_SECONDS = 365 days;
    /// @dev Bounds the rate-index loop: a vault untouched across every change evaluates one rate per version. Fits
    /// the uint16 `Accrual.curveVersion`.
    uint256 internal constant MAX_CURVE_VERSIONS = 64;

    /// @notice Runs the vault's indices and income streams to now, at the utilization in force since the last
    /// checkpoint, then re-reads the vault's Metric holdings: that sample is the idle balance for the interval that
    /// follows. Every change to utilization or lender shares must checkpoint first.
    function checkpoint(Vault storage vault, uint256 vaultId) internal {
        uint256 elapsedSeconds = block.timestamp - vault.accrual.updatedAt;
        if (elapsedSeconds != 0) {
            _growRateIndices(vault);
            release(vault, elapsedSeconds);
            vault.accrual.updatedAt = uint40(block.timestamp);
            vault.accrual.curveVersion = uint16(vault.curves.length - 1);
        }
        MetricVenue.refresh(vault, vaultId);
    }

    /// @notice Each token's premium rate now, in WAD a year, on the current curves.
    function currentRates(Vault storage vault) internal view returns (uint256 rate0Wad, uint256 rate1Wad) {
        CurvePair storage curves = vault.curves[vault.curves.length - 1];
        uint256 outstanding0 = vault.accrual.outstanding0;
        uint256 outstanding1 = vault.accrual.outstanding1;
        rate0Wad = VaultMath.rateWad(curves.token0, outstanding0, outstanding0 + idle0(vault));
        rate1Wad = VaultMath.rateWad(curves.token1, outstanding1, outstanding1 + idle1(vault));
    }

    /// @notice Lenders' idle token0: the buffer plus the Metric position at its last read.
    function idle0(Vault storage vault) internal view returns (uint256) {
        return uint256(vault.ledger.buffer0) + vault.venue.holdings0;
    }

    function idle1(Vault storage vault) internal view returns (uint256) {
        return uint256(vault.ledger.buffer1) + vault.venue.holdings1;
    }

    /// @notice What the position owes since its snapshots, at the vault's current indices, including the fraction the
    /// last settlement carried. The vault must be checkpointed first.
    /// @dev Rounds up when `roundUp`, as closes and delinquency checks need; otherwise down, leaving the rest in the
    /// fraction, so anyone settling often cannot charge more than one settlement would (Sol's finding on the maker
    /// book, which applies here too).
    function charge(Vault storage vault, Position storage position, bool roundUp)
        internal
        view
        returns (Charge memory owed)
    {
        uint256 maximum1 = position.maximum1;
        uint256 weight0Wad = position.weight0Wad;
        uint256 delta0Ray = vault.accrual.rateIndex0Ray - position.rateIndex0Ray;
        uint256 delta1Ray = vault.accrual.rateIndex1Ray - position.rateIndex1Ray;
        uint256 blendedRay = FullMath.mulDivRoundingUp(delta0Ray, weight0Wad, WAD)
            + FullMath.mulDivRoundingUp(delta1Ray, WAD - weight0Wad, WAD);
        uint256 premiumWad = FullMath.mulDiv(maximum1, blendedRay, RAY / WAD) + position.premiumFractionWad;
        (owed.premium, owed.premiumFractionWad) = _units(premiumWad, roundUp);
    }

    /// @dev Whole units of an amount in WAD of a unit, and the fraction left: rounded up with none left, or down.
    function _units(uint256 amountWad, bool roundUp) private pure returns (uint256 units, uint256 fractionWad) {
        if (roundUp) return (FullMath.mulDivRoundingUp(amountWad, 1, WAD), 0);
        return (amountWad / WAD, amountWad % WAD);
    }

    /// @notice Moves the position's snapshots to the vault's current indices.
    function snapshot(Vault storage vault, Position storage position) internal {
        position.rateIndex0Ray = vault.accrual.rateIndex0Ray;
        position.rateIndex1Ray = vault.accrual.rateIndex1Ray;
    }

    /// @notice Adds lenders' token0 income to its stream, restarting the stream's vesting over `vestSeconds`.
    function fund0(Vault storage vault, uint256 amount) internal {
        if (amount == 0) return;
        vault.stream.remaining0 = (vault.stream.remaining0 + amount).toUint128();
        vault.stream.vestingEnd0 = uint40(block.timestamp + vault.parameters.vestSeconds);
    }

    /// @notice Adds lenders' token1 income to its stream, restarting the stream's vesting over `vestSeconds`.
    function fund(Vault storage vault, uint256 amount) internal {
        if (amount == 0) return;
        vault.stream.remaining1 = (vault.stream.remaining1 + amount).toUint128();
        vault.stream.vestingEnd1 = uint40(block.timestamp + vault.parameters.vestSeconds);
    }

    /// @notice Releases both streams' vested parts into the lenders' buffer. With no lenders they wait: each vesting
    /// end moves out by the elapsed time.
    function release(Vault storage vault, uint256 elapsedSeconds) internal {
        if (vault.totalShares == 0) {
            if (vault.stream.remaining0 != 0) vault.stream.vestingEnd0 += uint40(elapsedSeconds);
            if (vault.stream.remaining1 != 0) vault.stream.vestingEnd1 += uint40(elapsedSeconds);
            return;
        }
        uint256 released0 = releasable(vault.stream.remaining0, vault.stream.vestingEnd0, vault, elapsedSeconds);
        uint256 released1 = releasable(vault.stream.remaining1, vault.stream.vestingEnd1, vault, elapsedSeconds);
        vault.stream.remaining0 -= uint128(released0);
        vault.stream.remaining1 -= uint128(released1);
        vault.ledger.buffer0 += uint128(released0);
        vault.ledger.buffer1 += uint128(released1);
    }

    function releasable(uint256 remaining, uint256 vestingEnd, Vault storage vault, uint256 elapsedSeconds)
        internal
        view
        returns (uint256)
    {
        if (remaining == 0) return 0;
        uint256 from = vault.accrual.updatedAt;
        if (vestingEnd <= from) return remaining;
        uint256 leftSeconds = vestingEnd - from;
        if (elapsedSeconds >= leftSeconds) return remaining;
        return remaining * elapsedSeconds / leftSeconds;
    }

    function _growRateIndices(Vault storage vault) private {
        uint256 versions = vault.curves.length;
        uint256 fromTime = vault.accrual.updatedAt;
        uint256 outstanding0 = vault.accrual.outstanding0;
        uint256 outstanding1 = vault.accrual.outstanding1;
        uint256 supplied0 = outstanding0 + idle0(vault);
        uint256 supplied1 = outstanding1 + idle1(vault);
        uint256 growth0Ray;
        uint256 growth1Ray;
        // versions <= MAX_CURVE_VERSIONS
        for (uint256 version = vault.accrual.curveVersion; version < versions; ++version) {
            uint256 untilTime = version + 1 < versions ? vault.curves[version + 1].startedAt : block.timestamp;
            if (untilTime <= fromTime) continue;
            CurvePair storage curves = vault.curves[version];
            growth0Ray += VaultMath.indexGrowthRay(curves.token0, outstanding0, supplied0, untilTime - fromTime);
            growth1Ray += VaultMath.indexGrowthRay(curves.token1, outstanding1, supplied1, untilTime - fromTime);
            fromTime = untilTime;
        }
        vault.accrual.rateIndex0Ray = (vault.accrual.rateIndex0Ray + growth0Ray).toUint128();
        vault.accrual.rateIndex1Ray = (vault.accrual.rateIndex1Ray + growth1Ray).toUint128();
    }
}
