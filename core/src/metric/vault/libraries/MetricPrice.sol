// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {IMetricPool} from "../interfaces/IMetricPool.sol";
import {MetricState} from "./MetricState.sol";

/// @notice The oracle band of a Metric pool, recovered through the pool itself.
/// @dev Metric's Chainlink and Pyth feeds may be read only by a registered pool during a swap, or by an approved
/// integrator. `getSellAndBuyPrices` runs under the pool's swap lock, so the pool's provider reads the oracle for it.
/// Its prices are the reference times `m = 1 + d`, where `d` is the cursor's position in the bins, with fees folded
/// in. A trade can move `d` within a transaction, so it is divided out; fees stay in and only widen the band.
library MetricPrice {
    uint256 internal constant E6 = 1e6;
    /// @dev Metric floors each bin bound and then the interpolated marginal, so its marginal can sit up to this many Q64
    /// units below the exact `reference · m`.
    uint256 internal constant MARGINAL_FLOOR_UNITS = 3;
    /// @dev Raw prices are kept below 2^64, the ranges' upper price bound.
    uint256 internal constant MAX_RAW_PRICE_X64 = 1 << 128;
    /// @dev Metric's `ReentrancyGuardReentrantCall()`, raised by any guarded call while one of its actions runs.
    bytes4 internal constant REENTRANT_CALL_SELECTOR = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    /// @notice The band as raw sqrt prices in Q96: bid rounded down, ask rounded up. Reverts if the pool cannot
    /// quote.
    function band(address pool, uint256 scale0, uint256 scale1)
        internal
        returns (uint160 sqrtBidX96, uint160 sqrtAskX96)
    {
        bool ok;
        (ok, sqrtBidX96, sqrtAskX96) = tryBand(pool, scale0, scale1);
        if (!ok) revert IMetricLendingVault.InvalidBand();
    }

    /// @notice The band, or none if the pool cannot quote or the quote does not convert.
    function tryBand(address pool, uint256 scale0, uint256 scale1)
        internal
        returns (bool ok, uint160 sqrtBidX96, uint160 sqrtAskX96)
    {
        try IMetricPool(pool).getSellAndBuyPrices() returns (uint128 sellX64, uint128 buyX64) {
            // Checked after the pool call: the singleton's reentrancy lock is held and no callback is expected, so
            // the pool could not have re-entered the vault.
            if (sellX64 == 0) return (false, 0, 0);
            return _toBand(pool, sellX64, buyX64, scale0, scale1);
        } catch (bytes memory reason) {
            _rethrowIfLocked(reason);
            return (false, 0, 0);
        }
    }

    /// @dev Metric refuses a quote while one of its own actions runs, which only a call made from inside a pool
    /// callback sees. Reading that as "no price" would let such a caller push a force close onto its price-free
    /// fallback, which can cost the trader far more than the range is worth, so the refusal is passed on (Sol's
    /// verification finding).
    function _rethrowIfLocked(bytes memory reason) private pure {
        if (reason.length < 4) return;
        if (bytes4(reason) != REENTRANT_CALL_SELECTOR) return;
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    /// @dev Divides the cursor's deviation out of the pool's quote and converts both edges to raw sqrt prices.
    function _toBand(address pool, uint256 sellX64, uint256 buyX64, uint256 scale0, uint256 scale1)
        private
        view
        returns (bool, uint160, uint160)
    {
        (uint256 numerator, uint256 denominator) = deviation(pool);
        uint256 bidX64 = FullMath.mulDiv(sellX64, denominator, numerator);
        uint256 askX64 = FullMath.mulDivRoundingUp(_askCeiling(sellX64, buyX64), denominator, numerator);
        (bool bidOk, uint160 sqrtBidX96) = toSqrtX96(bidX64, scale0, scale1, false);
        (bool askOk, uint160 sqrtAskX96) = toSqrtX96(askX64, scale0, scale1, true);
        if (!bidOk) return (false, 0, 0);
        if (!askOk) return (false, 0, 0);
        return (true, sqrtBidX96, sqrtAskX96);
    }

    /// @notice The band's bid, or none if the pool cannot quote.
    function tryBid(address pool, uint256 scale0, uint256 scale1) internal returns (bool ok, uint160 sqrtBidX96) {
        try IMetricPool(pool).getSellAndBuyPrices() returns (uint128 sellX64, uint128) {
            if (sellX64 == 0) return (false, 0);
            (uint256 numerator, uint256 denominator) = deviation(pool);
            return toSqrtX96(FullMath.mulDiv(sellX64, denominator, numerator), scale0, scale1, false);
        } catch (bytes memory reason) {
            _rethrowIfLocked(reason);
            return (false, 0);
        }
    }

    /// @dev `buy = ceil(marginal · (1 + fee))` with `marginal ≥ reference · m − 3`, so
    /// `reference · m · (1 + fee) ≤ buy + 3 · (1 + fee)`. The fee multiplier is at most `buy / sell`, because the
    /// marginal is at least `sell`. The bound is wide only for tiny prices or very wide quotes, where it must be.
    function _askCeiling(uint256 sellX64, uint256 buyX64) private pure returns (uint256) {
        uint256 feeMultiplierCeiling = (buyX64 + sellX64 - 1) / sellX64;
        return buyX64 + MARGINAL_FLOOR_UNITS * feeMultiplierCeiling + 1;
    }

    /// @notice `m = 1 + d` as `numerator / denominator`, from the cursor's bin distance and position in its bin, as
    /// Metric interpolates it.
    function deviation(address pool) internal view returns (uint256 numerator, uint256 denominator) {
        MetricState.Cursor memory current = MetricState.cursor(pool);
        MetricState.Bin memory state = MetricState.bin(pool, current.binIndex);
        uint256 maxPosition = MetricState.MAX_POSITION;
        denominator = E6 * maxPosition;
        // Metric requires the distance to stay above -100%, so the base is positive.
        uint256 base = uint256(int256(E6) + current.binDistanceE6) * maxPosition;
        numerator = base + uint256(state.lengthE6) * current.positionInBin;
    }

    /// @notice A whole-token Q64.64 price as a raw sqrt price in Q96. Metric scales both tokens to a common precision
    /// with `scale = 10^(precision − decimals)`, so the raw price is the whole price times `scale0 / scale1`.
    function toSqrtX96(uint256 priceX64, uint256 scale0, uint256 scale1, bool roundUp)
        internal
        pure
        returns (bool ok, uint160 sqrtPriceX96)
    {
        if (FullMath.mulDiv(priceX64, scale0, scale1) >= MAX_RAW_PRICE_X64) return (false, 0);
        uint256 rawX192 = roundUp
            ? FullMath.mulDivRoundingUp(priceX64, scale0 << 128, scale1)
            : FullMath.mulDiv(priceX64, scale0 << 128, scale1);
        uint256 root = Math.sqrt(rawX192, roundUp ? Math.Rounding.Ceil : Math.Rounding.Floor);
        return (true, uint160(root));
    }
}
