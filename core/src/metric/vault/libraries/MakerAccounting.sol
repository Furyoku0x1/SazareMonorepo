// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Book, BookCurve, Bucket, MakerShare} from "../MakerTypes.sol";
import {Vault} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {MakerMath} from "./MakerMath.sol";
import {VaultMath} from "./VaultMath.sol";

/// @notice A bucket's running state: its rate index, its income streams, and each maker's accrued income. Every
/// change to a bucket's balances, loans or shares checkpoints it first, so each interval is priced at the utilization
/// it had and paid to the makers it had.
library MakerAccounting {
    using SafeCast for uint256;

    /// @notice The sqrt prices bounding a bucket's level.
    function range(Book storage book, uint256 bucketId) internal view returns (uint160, uint160) {
        (int24 level,,) = MakerMath.decode(bucketId);
        return MakerMath.levelRange(level, book.settings.levelTicks);
    }

    /// @notice The range liquidity the bucket's waiting token could still lend: token1 in a buy bucket, token0 in a
    /// sell bucket.
    function lendable(Bucket storage bucket, bool isBuy, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        view
        returns (uint256)
    {
        uint256 waiting = isBuy ? bucket.balance1 : bucket.balance0;
        return MakerMath.liquidityFor(isBuy, waiting, sqrtLowerX96, sqrtUpperX96);
    }

    /// @notice Runs the bucket's rate index and income streams to now. A bucket seen for the first time starts now,
    /// at the current curve.
    function checkpoint(Book storage book, uint256 bucketId) internal returns (Bucket storage bucket) {
        bucket = book.buckets[bucketId];
        uint256 updatedAt = bucket.updatedAt;
        if (updatedAt == 0) {
            bucket.updatedAt = uint40(block.timestamp);
            bucket.curveVersion = uint16(book.curves.length - 1);
            return bucket;
        }
        uint256 elapsedSeconds = block.timestamp - updatedAt;
        if (elapsedSeconds == 0) return bucket;
        _growRateIndex(book, bucket, bucketId);
        _release(bucket, elapsedSeconds);
        bucket.updatedAt = uint40(block.timestamp);
        bucket.curveVersion = uint16(book.curves.length - 1);
    }

    /// @notice Adds income to the bucket's streams, vesting over `vestSeconds` from now. The bucket must be
    /// checkpointed now, so none of it reaches makers of the time before.
    function fundIncome(Book storage book, Bucket storage bucket, uint256 amount0, uint256 amount1, uint256 vestSeconds)
        internal
    {
        uint40 vestingEnd = uint40(block.timestamp + vestSeconds);
        if (amount0 != 0) {
            bucket.stream0Remaining = (bucket.stream0Remaining + amount0).toUint128();
            bucket.stream0End = vestingEnd;
            book.income0 = (book.income0 + amount0).toUint128();
        }
        if (amount1 != 0) {
            bucket.stream1Remaining = (bucket.stream1Remaining + amount1).toUint128();
            bucket.stream1End = vestingEnd;
            book.income1 = (book.income1 + amount1).toUint128();
        }
    }

    /// @notice Moves the bucket's released income into the maker's accrued balance. Call before the maker's shares
    /// change, with the bucket checkpointed now.
    function accrueMaker(Bucket storage bucket, MakerShare storage holding) internal {
        uint256 shares = holding.shares;
        uint256 perShare0 = bucket.income0PerShareX128;
        uint256 perShare1 = bucket.income1PerShareX128;
        if (shares != 0) {
            uint256 earned0 = FullMath.mulDiv(shares, perShare0 - holding.income0PerShareLastX128, MakerMath.Q128);
            uint256 earned1 = FullMath.mulDiv(shares, perShare1 - holding.income1PerShareLastX128, MakerMath.Q128);
            holding.income0 = (holding.income0 + earned0).toUint128();
            holding.income1 = (holding.income1 + earned1).toUint128();
        }
        holding.income0PerShareLastX128 = perShare0;
        holding.income1PerShareLastX128 = perShare1;
    }

    /// @notice Moves what a bucket's streams still hold to the treasury, for a bucket with no shares: no maker is left
    /// to earn it.
    function forfeitStreams(Vault storage vault, Bucket storage bucket) internal {
        uint256 remaining0 = bucket.stream0Remaining;
        uint256 remaining1 = bucket.stream1Remaining;
        bucket.stream0Remaining = 0;
        bucket.stream1Remaining = 0;
        vault.book.income0 -= remaining0.toUint128();
        vault.book.income1 -= remaining1.toUint128();
        vault.ledger.treasury0 += remaining0.toUint128();
        vault.ledger.treasury1 += remaining1.toUint128();
    }

    /// @notice The curve's yearly rate in WAD at the bucket's utilization now, under the current curve.
    function curveRateWad(
        Book storage book,
        Bucket storage bucket,
        bool isBuy,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) internal view returns (uint256) {
        uint256 supplied = rateSupplied(book, bucket, isBuy, sqrtLowerX96, sqrtUpperX96);
        return VaultMath.rateWad(book.curves[book.curves.length - 1].curve, bucket.lent, supplied);
    }

    /// @notice The supply a bucket's rate is priced on: its loans plus its waiting token as range liquidity. A retired
    /// bucket's fill converted that token, so it counts the converted one too, and never less than the utilization
    /// ceiling allows: a fill cannot raise its loans' rate past the ceiling rate, the most makers could impose on an
    /// active bucket by withdrawing (audit finding X-4).
    function rateSupplied(
        Book storage book,
        Bucket storage bucket,
        bool isBuy,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) internal view returns (uint256 supplied) {
        uint256 borrowed = bucket.lent;
        supplied = borrowed + lendable(bucket, isBuy, sqrtLowerX96, sqrtUpperX96);
        if (!bucket.retired) return supplied;
        uint256 converted = isBuy ? bucket.balance0 : bucket.balance1;
        supplied += MakerMath.liquidityFor(!isBuy, converted, sqrtLowerX96, sqrtUpperX96);
        uint256 atCeiling = FullMath.mulDivRoundingUp(borrowed, MakerMath.BPS, book.settings.utilizationCeilingBps);
        if (supplied < atCeiling) supplied = atCeiling;
    }

    /// @notice Requires the bucket's loans to stay within the ceiling of its capacity.
    function requireCeiling(
        Book storage book,
        Bucket storage bucket,
        bool isBuy,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) internal view {
        uint256 borrowed = bucket.lent;
        if (borrowed == 0) return;
        uint256 supplied = borrowed + lendable(bucket, isBuy, sqrtLowerX96, sqrtUpperX96);
        if (borrowed * MakerMath.BPS > supplied * book.settings.utilizationCeilingBps) {
            revert IMetricLendingVault.UtilizationCeiling();
        }
    }

    /// @dev Utilization was constant since the last checkpoint; the curve may have changed, so each version prices
    /// its own part of the interval.
    function _growRateIndex(Book storage book, Bucket storage bucket, uint256 bucketId) private {
        (, bool isBuy,) = MakerMath.decode(bucketId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = range(book, bucketId);
        uint256 borrowed = bucket.lent;
        uint256 supplied = rateSupplied(book, bucket, isBuy, sqrtLowerX96, sqrtUpperX96);
        uint256 versions = book.curves.length;
        uint256 fromTime = bucket.updatedAt;
        uint256 growthRay;
        // versions <= MAX_VERSIONS
        for (uint256 version = bucket.curveVersion; version < versions; ++version) {
            uint256 untilTime = version + 1 < versions ? book.curves[version + 1].startedAt : block.timestamp;
            if (untilTime <= fromTime) continue;
            BookCurve storage current = book.curves[version];
            growthRay += VaultMath.indexGrowthRay(current.curve, borrowed, supplied, untilTime - fromTime);
            fromTime = untilTime;
        }
        bucket.rateIndexRay = (bucket.rateIndexRay + growthRay).toUint128();
    }

    /// @dev Releases both streams' vested parts to the bucket's shares. With no shares there is no one to pay, so the
    /// streams pause: each end moves out by the elapsed time.
    function _release(Bucket storage bucket, uint256 elapsedSeconds) private {
        uint256 totalShares = bucket.totalShares;
        if (totalShares == 0) {
            if (bucket.stream0Remaining != 0) bucket.stream0End += uint40(elapsedSeconds);
            if (bucket.stream1Remaining != 0) bucket.stream1End += uint40(elapsedSeconds);
            return;
        }
        uint256 from = bucket.updatedAt;
        uint256 released0 = _releasable(bucket.stream0Remaining, bucket.stream0End, from, elapsedSeconds);
        uint256 released1 = _releasable(bucket.stream1Remaining, bucket.stream1End, from, elapsedSeconds);
        bucket.stream0Remaining -= uint128(released0);
        bucket.stream1Remaining -= uint128(released1);
        bucket.income0PerShareX128 += FullMath.mulDiv(released0, MakerMath.Q128, totalShares);
        bucket.income1PerShareX128 += FullMath.mulDiv(released1, MakerMath.Q128, totalShares);
    }

    function _releasable(uint256 remaining, uint256 vestingEnd, uint256 from, uint256 elapsedSeconds)
        private
        pure
        returns (uint256)
    {
        if (remaining == 0) return 0;
        if (vestingEnd <= from) return remaining;
        uint256 leftSeconds = vestingEnd - from;
        if (elapsedSeconds >= leftSeconds) return remaining;
        return remaining * elapsedSeconds / leftSeconds;
    }
}
