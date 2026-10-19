// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CurvePair, PricePoint, Vault, VaultParameters, VaultStore} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {IMetricPool, IMetricPoolFactory, PoolImmutables} from "../interfaces/IMetricPool.sol";
import {VaultAccrual} from "./VaultAccrual.sol";
import {VaultLedger} from "./VaultLedger.sol";
import {Curve, VaultMath} from "./VaultMath.sol";
import {MetricVenue} from "./MetricVenue.sol";
import {RealizedCharge} from "./RealizedCharge.sol";

/// @notice Creating vaults, versioning their premium curves, and paying the protocol its share.
/// @dev An external library: the singleton delegatecalls it, after checking the caller where needed.
library VaultAdmin {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev Longer, a delinquent position could hold lenders' liquidity, or lenders' income could vest, for too long.
    uint256 internal constant MAX_PERIOD_SECONDS = 30 days;
    /// @dev A force closer's reward of at most 10% of what is left.
    uint256 internal constant MAX_REWARD_BPS = 1_000;
    /// @dev 100% a year: the least a curve may charge at the utilization ceiling.
    uint256 internal constant MIN_CEILING_RATE_WAD = 1e18;
    /// @dev 10%: a force close paying more than that past the band is a sandwich, and the scaling fallback is better.
    uint256 internal constant MAX_FORCE_CLOSE_SLIPPAGE_BPS = 1_000;

    function createVault(
        VaultStore storage store,
        VaultParameters calldata parameters,
        CurvePair calldata curves,
        address metricFactory
    ) external returns (uint256 vaultId) {
        _validate(parameters);
        _validateCurves(curves, parameters.utilizationCeilingBps);
        vaultId = ++store.vaultCount;
        Vault storage vault = store.vaults[vaultId];
        vault.parameters = parameters;
        if (parameters.pool != address(0)) _bindPool(store, vault, vaultId, parameters, metricFactory);
        vault.curves.push(CurvePair(curves.token0, curves.token1, uint40(block.timestamp)));
        vault.accrual.updatedAt = uint40(block.timestamp);
        emit IMetricLendingVault.VaultCreated(vaultId, parameters.pool, parameters.token0, parameters.token1);
    }

    /// @notice Adds a curve version, in force from now. The indices are run to now at the old curves first, so the
    /// past is never repriced.
    function appendCurves(VaultStore storage store, uint256 vaultId, CurvePair calldata curves) external {
        if (vaultId == 0) revert IMetricLendingVault.UnknownVault();
        if (vaultId > store.vaultCount) revert IMetricLendingVault.UnknownVault();
        Vault storage vault = store.vaults[vaultId];
        _validateCurves(curves, vault.parameters.utilizationCeilingBps);
        if (vault.curves.length >= VaultAccrual.MAX_CURVE_VERSIONS) revert IMetricLendingVault.TooManyCurveVersions();
        VaultAccrual.checkpoint(vault, vaultId);
        vault.curves.push(CurvePair(curves.token0, curves.token1, uint40(block.timestamp)));
        vault.accrual.curveVersion = uint16(vault.curves.length - 1);
        emit IMetricLendingVault.CurvesAppended(vaultId, vault.curves.length - 1);
    }

    /// @notice Pays the treasury and the fee vault what the vault owes them. Anyone may call; the recipients are the
    /// singleton's immutables.
    function payProtocol(VaultStore storage store, uint256 vaultId, address treasury, address feeVault) external {
        if (vaultId == 0) revert IMetricLendingVault.UnknownVault();
        if (vaultId > store.vaultCount) revert IMetricLendingVault.UnknownVault();
        Vault storage vault = store.vaults[vaultId];
        uint256 treasury0 = vault.ledger.treasury0;
        uint256 treasury1 = vault.ledger.treasury1;
        uint256 feeVault0 = vault.ledger.feeVault0;
        uint256 feeVault1 = vault.ledger.feeVault1;
        vault.ledger.treasury0 = 0;
        vault.ledger.treasury1 = 0;
        vault.ledger.feeVault0 = 0;
        vault.ledger.feeVault1 = 0;
        VaultLedger.push(vault, 0, treasury, treasury0);
        VaultLedger.push(vault, 1, treasury, treasury1);
        VaultLedger.push(vault, 0, feeVault, feeVault0);
        VaultLedger.push(vault, 1, feeVault, feeVault1);
        emit IMetricLendingVault.ProtocolPaid(vaultId, treasury, treasury0, treasury1);
        emit IMetricLendingVault.ProtocolPaid(vaultId, feeVault, feeVault0, feeVault1);
    }

    /// @notice Pays the caller the close payouts in one token that a transfer refused, to the caller's own address
    /// only, so no one routes a blocklisted owner's funds elsewhere (audit finding X-5). One token at a time, so a token
    /// that still refuses cannot hold back the other. Reverts while the token refuses.
    function claimPayout(VaultStore storage store, uint256 vaultId, uint256 tokenIndex)
        external
        returns (uint256 amount)
    {
        if (vaultId == 0) revert IMetricLendingVault.UnknownVault();
        if (vaultId > store.vaultCount) revert IMetricLendingVault.UnknownVault();
        if (tokenIndex > 1) revert IMetricLendingVault.InvalidParameters();
        Vault storage vault = store.vaults[vaultId];
        amount = vault.unclaimed[msg.sender][tokenIndex];
        if (amount == 0) revert IMetricLendingVault.ZeroAmount();
        vault.unclaimed[msg.sender][tokenIndex] = 0;
        if (tokenIndex == 0) vault.ledger.unclaimed0 -= amount.toUint128();
        else vault.ledger.unclaimed1 -= amount.toUint128();
        VaultLedger.push(vault, tokenIndex, msg.sender, amount);
        emit IMetricLendingVault.PayoutClaimed(vaultId, msg.sender, tokenIndex, amount);
    }

    /// @notice Records a price point for the vault; see `RealizedCharge.record`.
    function recordPrice(VaultStore storage store, uint256 vaultId) external returns (bool) {
        if (vaultId == 0) revert IMetricLendingVault.UnknownVault();
        if (vaultId > store.vaultCount) revert IMetricLendingVault.UnknownVault();
        return RealizedCharge.record(store.vaults[vaultId], vaultId);
    }

    /// @notice The vault's price point count, the oracle's σ, and the point at `index`.
    function priceOf(VaultStore storage store, uint256 vaultId, uint256 index)
        external
        view
        returns (uint256 count, uint256 sigmaWad, PricePoint memory point)
    {
        Vault storage vault = store.vaults[vaultId];
        return (vault.prices.count, RealizedCharge.sigmaWad(vault), vault.prices.points[index]);
    }

    function _validate(VaultParameters calldata parameters) private pure {
        if (parameters.token0 == address(0)) revert IMetricLendingVault.InvalidParameters();
        if (parameters.token1 == address(0)) revert IMetricLendingVault.InvalidParameters();
        if (parameters.token0 == parameters.token1) revert IMetricLendingVault.InvalidParameters();
        if (parameters.vestSeconds == 0) revert IMetricLendingVault.InvalidParameters();
        if (parameters.vestSeconds > MAX_PERIOD_SECONDS) revert IMetricLendingVault.InvalidParameters();
        if (parameters.graceSeconds > MAX_PERIOD_SECONDS) revert IMetricLendingVault.InvalidParameters();
        if (parameters.minimumEscrowSeconds > MAX_PERIOD_SECONDS) revert IMetricLendingVault.InvalidParameters();
        // Under all of it: the realized charge is grossed up by what lenders keep of premium.
        if (parameters.premiumProtocolBps >= BPS) revert IMetricLendingVault.InvalidParameters();
        if (parameters.minimumEscrowBps > BPS) revert IMetricLendingVault.InvalidParameters();
        if (parameters.highLeverageSurchargeBps > BPS) revert IMetricLendingVault.InvalidParameters();
        if (parameters.profitShareBps > BPS) revert IMetricLendingVault.InvalidParameters();
        if (uint256(parameters.profitTreasuryBps) + parameters.profitFeeVaultBps > BPS) {
            revert IMetricLendingVault.InvalidParameters();
        }
        if (parameters.forceCloseRewardBps > MAX_REWARD_BPS) revert IMetricLendingVault.InvalidParameters();
        if (parameters.forceCloseSlippageBps > MAX_FORCE_CLOSE_SLIPPAGE_BPS) {
            revert IMetricLendingVault.InvalidParameters();
        }
        if (parameters.utilizationCeilingBps == 0) revert IMetricLendingVault.InvalidParameters();
        if (parameters.utilizationCeilingBps > BPS) revert IMetricLendingVault.InvalidParameters();
        _validateVenue(parameters);
    }

    function _validateVenue(VaultParameters calldata parameters) private pure {
        if (parameters.pool == address(0)) {
            // Without a pool, the band comes from the price source.
            if (parameters.priceSource == address(0)) revert IMetricLendingVault.InvalidParameters();
            return;
        }
        if (parameters.binCount < 2) revert IMetricLendingVault.InvalidParameters();
        if (parameters.binCount > MetricVenue.MAX_BINS) revert IMetricLendingVault.InvalidParameters();
        if (parameters.binCount % 2 != 0) revert IMetricLendingVault.InvalidParameters();
        if (parameters.weightCapBps == 0) revert IMetricLendingVault.InvalidParameters();
        if (parameters.weightCapBps > BPS) revert IMetricLendingVault.InvalidParameters();
    }

    function _validateCurves(CurvePair calldata curves, uint256 ceilingBps) private pure {
        _validateCurve(curves.token0, ceilingBps);
        _validateCurve(curves.token1, ceilingBps);
    }

    /// @dev At the utilization ceiling a borrower must pay at least `MIN_CEILING_RATE_WAD`, so one cannot hold lenders'
    /// last idle capital for free (audit finding C2).
    function _validateCurve(Curve calldata curve, uint256 ceilingBps) private pure {
        if (curve.kinkWad == 0) revert IMetricLendingVault.InvalidParameters();
        if (curve.kinkWad >= WAD) revert IMetricLendingVault.InvalidParameters();
        if (VaultMath.rateWad(curve, ceilingBps, BPS) < MIN_CEILING_RATE_WAD) {
            revert IMetricLendingVault.InvalidParameters();
        }
    }

    /// @dev v1 uses existing oracle-priced pools: the provider must be immutable, so it cannot be swapped for one that
    /// prices the vault's opens, and no extension may run on removals, since one could block the vault's exits.
    function _bindPool(
        VaultStore storage store,
        Vault storage vault,
        uint256 vaultId,
        VaultParameters calldata parameters,
        address metricFactory
    ) private {
        if (store.vaultOfPool[parameters.pool] != 0) revert IMetricLendingVault.PoolTaken();
        // The pool's own report of its factory proves nothing; the factory's record does.
        if (metricFactory == address(0)) revert IMetricLendingVault.InvalidParameters();
        if (!IMetricPoolFactory(metricFactory).isPool(parameters.pool)) revert IMetricLendingVault.InvalidParameters();
        PoolImmutables memory immutables = IMetricPool(parameters.pool).getImmutables();
        // A view call under the singleton's reentrancy lock: the pool could change nothing before these checks.
        if (immutables.token0 != parameters.token0) revert IMetricLendingVault.InvalidParameters();
        if (immutables.token1 != parameters.token1) revert IMetricLendingVault.InvalidParameters();
        if (immutables.immutablePriceProvider == address(0)) revert IMetricLendingVault.InvalidParameters();
        if (immutables.beforeRemoveLiquidityOrder != 0) revert IMetricLendingVault.InvalidParameters();
        if (immutables.afterRemoveLiquidityOrder != 0) revert IMetricLendingVault.InvalidParameters();
        if (immutables.lowestBin > immutables.highestBin) revert IMetricLendingVault.InvalidParameters();
        store.vaultOfPool[parameters.pool] = vaultId;
        vault.venue.scale0 = immutables.token0ScaleMultiplier.toUint64();
        vault.venue.scale1 = immutables.token1ScaleMultiplier.toUint64();
        vault.venue.poolLowestBin = immutables.lowestBin.toInt16();
        vault.venue.poolHighestBin = immutables.highestBin.toInt16();
        vault.venue.minimumShares = immutables.minimalOperationalLiquidity.toUint128();
        vault.venue.initial0PerShareE18 = immutables.initialScaledToken0PerShareE18.toUint128();
        vault.venue.initial1PerShareE18 = immutables.initialScaledToken1PerShareE18.toUint128();
        if (vault.parameters.binCount > uint256(int256(immutables.highestBin - immutables.lowestBin + 1))) {
            revert IMetricLendingVault.InvalidParameters();
        }
    }
}
