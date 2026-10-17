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

    /// @notice The band, or none if it cannot be read or fails the bounds `band` enforces.
    function tryBand(Vault storage vault) internal returns (bool ok, uint160 sqrtBidX96, uint160 sqrtAskX96) {
        address pool = vault.parameters.pool;
        if (pool != address(0)) {
            (ok, sqrtBidX96, sqrtAskX96) = MetricPrice.tryBand(pool, vault.venue.scale0, vault.venue.scale1);
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
    /// band's far edge plus the vault's slippage allowance, and never more than `surplus`. Zero when the band cannot
    /// be read, so the caller scales instead. Bounding it keeps a trade just before the close from taking the
    /// trader's surplus (audit finding B3).
    function shortfallBudget(Vault storage vault, bool buyToken0, uint256 deficit, uint256 surplus)
        internal
        returns (uint256)
    {
        (bool ok, uint160 sqrtBidX96, uint160 sqrtAskX96) = tryBand(vault);
        if (!ok) return 0;
        uint256 atEdge = buyToken0 ? VaultMath.priceTimes(deficit, sqrtAskX96, true) : token0At(sqrtBidX96, deficit);
        uint256 budget = FullMath.mulDiv(atEdge, BPS + vault.parameters.forceCloseSlippageBps, BPS);
        return budget < surplus ? budget : surplus;
    }

    /// @notice The band's bid for valuing a close's leftovers, or none if the band cannot be read. A close must not
    /// depend on a price, so the caller falls back to the strike.
    function tryBid(Vault storage vault) internal returns (bool ok, uint160 sqrtBidX96) {
        address pool = vault.parameters.pool;
        if (pool != address(0)) (ok, sqrtBidX96) = MetricPrice.tryBid(pool, vault.venue.scale0, vault.venue.scale1);
        else (ok, sqrtBidX96) = _trySourceBid(vault);
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
