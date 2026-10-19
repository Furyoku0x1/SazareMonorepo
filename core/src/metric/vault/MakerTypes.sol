// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Curve} from "./libraries/VaultMath.sol";

/// @notice A book's settings, fixed when the owner creates it. See `hooks/docs/metric-maker-ranges-design.md`.
struct BookSettings {
    /// @notice Each level spans this many ticks; fixed for the book's life, since it sets the levels' geometry.
    uint24 levelTicks;
    /// @notice The highest share of a bucket's capacity that may be lent, after a borrow or a withdrawal.
    uint16 utilizationCeilingBps;
    /// @notice A fill's keeper reward, in basis points of the fill's output, paid by the bucket's makers.
    uint16 fillRewardBps;
    /// @notice How long a flagged maker position has before anyone may force close it.
    uint32 graceSeconds;
    /// @notice An open must escrow, beyond the prepaid floor, what its legs owe over this long from the open at the
    /// rates in force after the borrow.
    uint32 minimumEscrowSeconds;
    /// @notice Every leg prepays this long of its floor at open, from the escrow: makers' cost per year is highest on
    /// short holds near the price, which a pro-rata floor alone undercharges.
    uint32 minimumChargeSeconds;
    /// @notice The smallest deposit, leg and partial-close remainder, as token1 value.
    uint96 minimumNotional;
}

/// @notice A floor row: positions opened at least `minimumDistanceBps` from the price pay `rateBps` a year on `M1`.
struct FloorRow {
    uint32 minimumDistanceBps;
    uint32 rateBps;
}

/// @notice One version of the floor table: rows from the farthest distance to zero, and when it took effect.
struct FloorTable {
    FloorRow[] rows;
    uint40 startedAt;
}

/// @notice One version of the book's utilization curve and when it took effect.
struct BookCurve {
    Curve curve;
    uint40 startedAt;
}

/// @notice One generation of makers at one level and side: their tokens, the range liquidity lent from them, and the
/// premium and profit share they earn.
/// @dev `balance0`/`balance1` are unlent by definition: lent capital sits in positions' reserves until repaid.
struct Bucket {
    uint128 balance0;
    uint128 balance1;
    /// @dev Range liquidity lent to open legs.
    uint128 lent;
    /// @dev The integral of the curve's yearly rate over time, in RAY per unit of `M1`.
    uint128 rateIndexRay;
    uint40 updatedAt;
    /// @dev The curve version in force at `updatedAt`.
    uint16 curveVersion;
    /// @dev Set at the first non-zero fill: no deposits or loans after it.
    bool retired;
    uint256 totalShares;
    /// @dev Income released to the makers per share, in Q128, per token.
    uint256 income0PerShareX128;
    uint256 income1PerShareX128;
    /// @dev Income paid in and not yet released; it vests linearly until its end.
    uint128 stream0Remaining;
    uint128 stream1Remaining;
    uint40 stream0End;
    uint40 stream1End;
}

/// @notice A maker's shares of one bucket and the income accrued on them.
struct MakerShare {
    uint256 shares;
    uint256 income0PerShareLastX128;
    uint256 income1PerShareLastX128;
    uint128 income0;
    uint128 income1;
}

/// @notice A vault's maker book.
/// @dev Invariants: `balance0`/`balance1` are the sums of every bucket's balances, and `income0`/`income1` the sums
/// of every bucket's streams plus income released and not yet claimed.
struct Book {
    bool enabled;
    BookSettings settings;
    /// @dev The current versions are the last; each array's length <= `MakerMath.MAX_VERSIONS`.
    BookCurve[] curves;
    FloorTable[] floorTables;
    uint128 balance0;
    uint128 balance1;
    uint128 income0;
    uint128 income1;
    /// @dev The generation taking deposits at each level and side; `MakerMath.levelKey` names the pair.
    mapping(uint256 levelKey => uint32 generation) generations;
    mapping(uint256 bucketId => Bucket) buckets;
    mapping(uint256 bucketId => mapping(address maker => MakerShare)) shares;
}

/// @notice A position borrowing from makers' buckets: up to `MakerMath.MAX_LEGS` ranges on one side, under one
/// aggregate chord.
struct MakerPosition {
    address owner;
    uint32 vaultId;
    /// @dev Longs borrow buy buckets (token1 below the price); shorts borrow sell buckets (token0 above it).
    bool isLong;
    uint8 legCount;
    /// @dev When someone flagged the position delinquent; zero when it is not flagged.
    uint40 delinquentSince;
    uint128 reserve0;
    uint128 reserve1;
    /// @dev The sums of the legs' `M0` and `M1`.
    uint128 maximum0;
    uint128 maximum1;
    /// @dev Token1 the trader put in and has not yet recovered: the profit share's cost basis.
    uint128 basis;
    uint128 escrow;
}

/// @notice One range a maker position borrows from one bucket.
struct Leg {
    uint256 bucketId;
    uint128 liquidity;
    uint128 maximum0;
    uint128 maximum1;
    /// @dev The bucket's rate index at the last settlement.
    uint128 rateIndexRay;
    /// @dev Fixed at open from the floor table.
    uint32 floorRateBps;
    /// @dev The floor is paid up to here. It starts `minimumChargeSeconds` after the open, since the open prepays that
    /// long, so it can be later than now.
    uint40 settledAt;
    /// @dev Dues under one raw unit, in WAD of a unit, that the last settlement left for the next.
    uint64 owedFractionWad;
    /// @dev When the leg was borrowed: the profit share weighs each leg by how long it was out, so a leg an increase
    /// appends just before a close earns little of a gain the older legs carried.
    uint40 openedAt;
}

struct LegRequest {
    uint256 bucketId;
    uint128 liquidity;
}

struct MakerOpenRequest {
    uint256 vaultId;
    bool isLong;
    /// @notice Bucket ids strictly ascending, all on the position's side.
    LegRequest[] legs;
    /// @notice Token1 added to the reserves.
    uint128 collateral;
    /// @notice Token1 prepaid into the premium escrow.
    uint128 escrow;
    /// @notice Reserve tokens sold into the target asset after the release; zero for none.
    uint256 entryAmountIn;
    uint256 entryMinimumOut;
    /// @notice The highest blended yearly rate the trader accepts, after the borrow, in basis points.
    uint256 maximumRateBps;
    /// @notice Where the entry swap trades: zero for the vault's Metric pool, otherwise any `ISwapVenue` the trader
    /// names. Any fill stands; what it loses against the band is charged to the basis.
    address entryVenue;
    /// @notice Passed to `entryVenue` untouched: the route.
    bytes entryRoute;
}

struct MakerIncreaseRequest {
    uint256 positionId;
    /// @notice New legs, appended after the position's own: bucket ids strictly ascending among themselves, all on the
    /// position's side. A bucket an existing leg borrows from may be named again; it becomes a leg of its own.
    LegRequest[] legs;
    /// @notice Token1 added to the reserves.
    uint128 collateral;
    /// @notice Token1 added to the premium escrow.
    uint128 escrow;
    /// @notice Tokens the new legs released, or the collateral added, sold into the target asset; zero for none.
    uint256 entryAmountIn;
    uint256 entryMinimumOut;
    /// @notice The highest blended yearly rate the trader accepts over every leg after the increase, in basis points.
    uint256 maximumRateBps;
    /// @notice As an open's: zero for the vault's Metric pool, otherwise the `ISwapVenue` the trader names.
    address entryVenue;
    bytes entryRoute;
}

struct MakerCloseRequest {
    uint256 positionId;
    /// @notice The fraction closed, in WAD; WAD closes in full. Every leg closes the same fraction.
    uint256 fractionWad;
    /// @notice Each leg's repayment, in leg order, taken from the closed part of the reserves.
    uint256[] repay0;
    uint256[] repay1;
}
