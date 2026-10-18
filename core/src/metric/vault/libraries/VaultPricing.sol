// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position, Vault} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {IVaultPriceSource} from "../interfaces/IVaultPriceSource.sol";
import {MetricPrice} from "./MetricPrice.sol";
import {VaultMath} from "./VaultMath.sol";

/// @notice The vault's only reads of a price: at open, for lender flows, and to value a close for the profit share.
/// Nothing else in the vault has a price in scope.
library VaultPricing {
    uint256 internal constant BPS = 10_000;
    /// @dev Native units a shortfall swap may pay beyond its cost at the edge: Metric rounds the input up in scaled
    /// units and again to native units, so even a deep pool can charge one or two more than the edge price (Sol's
    /// verification finding). Without them, a tiny deficit could fail to fill on every retry.
    uint256 internal constant ROUNDING_UNITS = 2;
    /// @dev How long past its grace period a force close waits for its pool to price again before scaling the reserves
    /// without a price (the owner's decision): pauses are usually brief, and scaling hands lenders whichever tokens the
    /// reserves hold rather than the debt's holdings at the bid, at a loss to one side or the other.
    uint256 internal constant NO_PRICE_WAIT_SECONDS = 30 days;
    /// @dev Bands are kept inside the ranges' price bounds, so every valuation stays in VaultMath's exact domain.
    uint160 internal constant MIN_SQRT_X96 = 18446744073709551616; // 2^64, tick -443636
    uint160 internal constant MAX_SQRT_X96 = 340282366920938463463374607431768211455; // just under 2^128

    /// @notice The band: from the Metric pool when the vault has one, otherwise from its price source. Reverts when
    /// the source does, or when the band is inverted or out of bounds.
    function band(Vault storage vault) internal returns (uint160 sqrtBidX96, uint160 sqrtAskX96) {
        address pool = vault.parameters.pool;
        if (pool != address(0)) {
            (sqrtBidX96, sqrtAskX96) = MetricPrice.band(pool, vault.venue.scale0, vault.venue.scale1);
        } else {
            (sqrtBidX96, sqrtAskX96) = IVaultPriceSource(vault.parameters.priceSource).sqrtBandX96();
        }
        // A view call under the singleton's reentrancy lock: the source could change nothing before these checks.
        if (sqrtBidX96 > sqrtAskX96) revert IMetricLendingVault.InvalidBand();
        if (sqrtBidX96 < MIN_SQRT_X96) revert IMetricLendingVault.InvalidBand();
        if (sqrtAskX96 > MAX_SQRT_X96) revert IMetricLendingVault.InvalidBand();
    }

    /// @notice Reverts while a force close on a pool without a price must still wait for one: until
    /// `NO_PRICE_WAIT_SECONDS` past the position's grace period.
    function requireNoPriceWaitOver(uint256 flaggedAt, uint256 graceSeconds) internal view {
        if (block.timestamp < flaggedAt + graceSeconds + NO_PRICE_WAIT_SECONDS) {
            revert IMetricLendingVault.PriceUnavailable();
        }
    }

    /// @notice The band a close prices at, or none if it cannot be read or fails the bounds `band` enforces. For a pool,
    /// it leaves out the fees Metric's factory may change, so the pool admin cannot move a force close or a profit
    /// share (audit finding W-1).
    function tryCloseBand(Vault storage vault) internal returns (bool ok, uint160 sqrtBidX96, uint160 sqrtAskX96) {
        address pool = vault.parameters.pool;
        if (pool != address(0)) {
            (ok, sqrtBidX96, sqrtAskX96) =
                MetricPrice.tryBandWithoutAdminFees(pool, vault.venue.scale0, vault.venue.scale1);
        } else {
            (ok, sqrtBidX96, sqrtAskX96) = _trySourceBand(vault);
        }
        if (!ok) return (false, 0, 0);
        if (sqrtBidX96 > sqrtAskX96) return (false, 0, 0);
        if (sqrtBidX96 < MIN_SQRT_X96) return (false, 0, 0);
        if (sqrtAskX96 > MAX_SQRT_X96) return (false, 0, 0);
        return (true, sqrtBidX96, sqrtAskX96);
    }

    /// @notice The most a force close may pay through the pool for `deficit` of the token it lacks: its cost at the
    /// close band's far edge plus the vault's slippage allowance, and never more than `surplus`. Bounding it keeps a
    /// trade just before the close from taking the trader's surplus (audit finding B3). Zero, so the caller scales
    /// instead, only where scaling costs the trader nothing they would otherwise keep: the band cannot be read, the
    /// deficit is too large for Metric's signed amount (C4), or what the surplus would leave after buying the deficit
    /// at the edge is within Metric's rounding or no more than `arrearsInSurplus`, the arrears the close then collects
    /// from it, in the surplus token as the close converts them, so the trader keeps nothing either way (W-3).
    /// Otherwise an unfilled swap waits for the pool rather than scale (Sol-2-1), and since arrears keep growing, a
    /// wait ends by itself.
    function shortfallBudget(
        Vault storage vault,
        bool buyToken0,
        uint256 deficit,
        uint256 surplus,
        uint256 arrearsInSurplus
    ) internal returns (uint256) {
        if (deficit > uint256(uint128(type(int128).max))) return 0;
        (bool ok, uint160 sqrtBidX96, uint160 sqrtAskX96) = tryCloseBand(vault);
        if (!ok) return 0;
        uint256 atEdge = buyToken0 ? VaultMath.priceTimes(deficit, sqrtAskX96, true) : token0At(sqrtBidX96, deficit);
        if (!_leavesTraderMore(surplus, atEdge, arrearsInSurplus)) return 0;
        uint256 budget = FullMath.mulDiv(atEdge, BPS + vault.parameters.forceCloseSlippageBps, BPS) + ROUNDING_UNITS;
        return budget < surplus ? budget : surplus;
    }

    /// @dev Whether buying the deficit at the edge would leave the trader more of the surplus than Metric's rounding
    /// and more than the arrears the close then takes from it. Both are in the surplus token: valuing the kept token0
    /// at the bid while the close takes arrears in token0 at the strike would scale away what the trader keeps (Sol).
    function _leavesTraderMore(uint256 surplus, uint256 atEdge, uint256 arrearsInSurplus) private pure returns (bool) {
        if (surplus < atEdge + ROUNDING_UNITS) return false;
        return surplus - atEdge > arrearsInSurplus;
    }

    /// @notice The bid of `tryCloseBand`, for a close's targets and for valuing its leftovers, or none if it cannot be
    /// read. A close must not depend on a price, so the caller falls back to the strike or to scaling.
    function tryCloseBid(Vault storage vault) internal returns (bool ok, uint160 sqrtBidX96) {
        address pool = vault.parameters.pool;
        if (pool != address(0)) {
            (ok, sqrtBidX96) = MetricPrice.tryBidWithoutAdminFees(pool, vault.venue.scale0, vault.venue.scale1);
        } else {
            (ok, sqrtBidX96) = _trySourceBid(vault);
        }
        if (!ok) return (false, 0);
        // The bounds `band` enforces: a zero bid would divide by zero where token0 is priced from it.
        if (sqrtBidX96 < MIN_SQRT_X96) return (false, 0);
        if (sqrtBidX96 > MAX_SQRT_X96) return (false, 0);
        return (true, sqrtBidX96);
    }

    function _trySourceBid(Vault storage vault) private returns (bool, uint160) {
        (bool ok, uint160 bid,) = _trySourceBand(vault);
        return (ok, bid);
    }

    function _trySourceBand(Vault storage vault) private returns (bool, uint160, uint160) {
        try IVaultPriceSource(vault.parameters.priceSource).sqrtBandX96() returns (uint160 bid, uint160 ask) {
            if (bid > ask) return (false, 0, 0);
            return (true, bid, ask);
        } catch {
            return (false, 0, 0);
        }
    }

    /// @notice The value of `amount0` in token1 at the position's strike `K = M1 / M0`, rounded down. The one price no
    /// caller can move.
    function atStrike(Position storage position, uint256 amount0) internal view returns (uint256) {
        return FullMath.mulDiv(amount0, position.maximum1, position.maximum0);
    }

    /// @notice How much token0 is worth `amount1` at the strike, rounded up.
    function token0AtStrike(Position storage position, uint256 amount1) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(amount1, position.maximum0, position.maximum1);
    }

    /// @notice How much token0 is worth `amount1` at a sqrt price, rounded up.
    function token0At(uint160 sqrtPriceX96, uint256 amount1) internal pure returns (uint256) {
        uint256 halfUp = FullMath.mulDivRoundingUp(amount1, 1 << 96, sqrtPriceX96);
        return FullMath.mulDivRoundingUp(halfUp, 1 << 96, sqrtPriceX96);
    }

    /// @notice The sqrt price at a tick; kept here so callers outside the math library need not import TickMath.
    function sqrtAtTick(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function value(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        return VaultMath.valueInToken1(amount0, amount1, sqrtPriceX96, roundUp);
    }
}
