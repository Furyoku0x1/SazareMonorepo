// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Errors and events of the maker book: limit orders lent to traders as ranges. Errors a caller handles the
/// same way as the vault's reuse `IMetricLendingVault`'s.
interface IMakerBook {
    /// @dev The vault has no book, or already has one.
    error BookDisabled();
    error BookExists();
    /// @dev The level's range falls outside the vault's tick bounds.
    error InvalidLevel();
    /// @dev The band is not wholly on the bucket's waiting side: a deposit or loan would sit inside or across its level.
    error WrongSideOfPrice();
    /// @dev The bucket has filled once: it takes no deposits and lends nothing.
    error BucketRetired();
    error UnknownBucket();
    /// @dev A request's legs must name distinct buckets in ascending order, all on the position's side, and a position
    /// holds at most `MakerMath.MAX_LEGS`. An increase's new legs may name a bucket an older leg borrows from.
    error InvalidLegs();
    error BelowMinimumNotional();
    /// @dev The blended rate after the borrow is above the trader's limit.
    error RateAboveMaximum();
    /// @dev The band has not passed the whole level, or the bucket has nothing waiting to fill.
    error NotFillable();

    event BookCreated(uint256 indexed vaultId, uint24 levelTicks);
    event BookCurveAppended(uint256 indexed vaultId, uint256 version);
    event FloorTableAppended(uint256 indexed vaultId, uint256 version);
    event OrderDeposited(
        uint256 indexed vaultId, uint256 indexed bucketId, address indexed maker, uint256 amount, uint256 shares
    );
    event OrderWithdrawn(
        uint256 indexed vaultId,
        uint256 indexed bucketId,
        address indexed maker,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );
    event IncomeClaimed(
        uint256 indexed vaultId, uint256 indexed bucketId, address indexed maker, uint256 amount0, uint256 amount1
    );
    event BucketFilled(
        uint256 indexed vaultId, uint256 indexed bucketId, address indexed keeper, uint256 paid, uint256 received
    );
    event MakerOpened(
        uint256 indexed positionId,
        uint256 indexed vaultId,
        address indexed owner,
        bool isLong,
        uint256 legCount,
        uint256 maximum0,
        uint256 maximum1
    );
    /// @notice Legs added to an open position: how many, and their extremes.
    event MakerIncreased(uint256 indexed positionId, uint256 legsAdded, uint256 maximum0, uint256 maximum1);
    /// @notice A leg's repayment reached its bucket; keepers watch for buckets whose level the price has passed.
    event LegRepaid(uint256 indexed positionId, uint256 indexed bucketId, uint256 repay0, uint256 repay1);
}
