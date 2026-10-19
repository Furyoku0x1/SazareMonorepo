// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Book, Leg, MakerPosition} from "./MakerTypes.sol";
import {DebtTree} from "./libraries/DebtValuation.sol";
import {Curve, DebtTotals} from "./libraries/VaultMath.sol";

/// @notice A vault's settings, fixed when the vault is created.
struct VaultParameters {
    /// @notice The base token; Metric's `token0`.
    address token0;
    /// @notice The quote token; Metric's `token1`. Collateral, escrow and premium are paid in it.
    address token1;
    /// @notice The Metric pool idle capital sits in, or zero to keep idle capital in the vault.
    address pool;
    /// @notice The price band for a vault without a pool; ignored when `pool` is set.
    address priceSource;
    uint32 vestSeconds;
    uint32 graceSeconds;
    /// @notice An open must escrow at least this long of premium at the rates after its borrow, so a position cannot
    /// borrow from its first second on credit (audit finding A6).
    uint32 minimumEscrowSeconds;
    /// @notice The protocol's slice of premium, paid to the treasury.
    uint16 premiumProtocolBps;
    /// @notice The share of realized profit taken on a winning close.
    uint16 profitShareBps;
    /// @notice The treasury's and fee vault's parts of a profit share; lenders take the rest.
    uint16 profitTreasuryBps;
    uint16 profitFeeVaultBps;
    /// @notice A force closer's reward, in basis points of each token left after repayment, arrears and the profit
    /// share.
    uint16 forceCloseRewardBps;
    /// @notice How far past the band's edge a keeper's swap of someone else's tokens may fill, in basis points: a force
    /// close's shortfall swap may pay this much past the far edge, beyond which the close waits rather than scale at
    /// the trader's loss (audit finding Sol-2-1); a fill through a venue the keeper names may lose this much of what it
    /// sells. A keeper can take most of it (audit finding B-2), so keep it small.
    uint16 forceCloseSlippageBps;
    /// @notice The highest utilization of either token an open may leave.
    uint16 utilizationCeilingBps;
    /// @notice The smallest `M1` a position may borrow or keep after a partial close.
    uint128 minBorrowNotional;
    /// @notice Metric bins the vault places idle capital in, at most `MetricVenue.MAX_BINS`; even.
    uint8 binCount;
    /// @notice How far, in bins, the active bin may drift from the window's center before re-centering moves it.
    uint8 recenterDistance;
    /// @notice The most of a bin's shares the vault may hold, where others hold some; 10,000 for no cap.
    uint16 weightCapBps;
}

/// @notice One version of the two premium curves and the time it took effect. Rate indices integrate each version over
/// its own interval, so a new version never reprices the past.
struct CurvePair {
    Curve token0;
    Curve token1;
    uint40 startedAt;
}

/// @notice The premium rate indices and the released amounts they are computed on.
struct Accrual {
    uint40 updatedAt;
    /// @dev The curve version in force at `updatedAt`.
    uint16 curveVersion;
    /// @dev Integrals of each token's yearly rate over time, in RAY per unit of `M1`.
    uint128 rateIndex0Ray;
    uint128 rateIndex1Ray;
    /// @dev Tokens released at open and not yet repaid: the borrowed side of utilization.
    uint128 outstanding0;
    uint128 outstanding1;
}

/// @notice Every amount the vault's contract holds for one vault, by owner.
/// @dev `held0`/`held1` move only with tokens; the parts move with accounting. Invariants: `held0` equals the sum of
/// the token0 parts plus `Stream.remaining0`, `held1` the sum of the token1 parts plus `Stream.remaining1`, both plus
/// the maker book's balances and income, and across all vaults each token's `held` sums to the contract's balance.
struct Ledger {
    uint128 held0;
    uint128 held1;
    /// @dev Lenders' idle tokens not placed in Metric.
    uint128 buffer0;
    uint128 buffer1;
    /// @dev Traders' reserves and premium escrows.
    uint128 reserve0;
    uint128 reserve1;
    uint128 escrow;
    /// @dev Owed to the treasury and the fee vault.
    uint128 treasury0;
    uint128 treasury1;
    uint128 feeVault0;
    uint128 feeVault1;
    /// @dev Close payouts a transfer refused, kept for their owners to claim (audit finding X-5).
    uint128 unclaimed0;
    uint128 unclaimed1;
}

/// @notice Lenders' income paid in and not yet released, per token: it vests linearly until its end, so a deposit made
/// around a payment takes none of it.
struct Stream {
    uint128 remaining0;
    uint128 remaining1;
    uint40 vestingEnd0;
    uint40 vestingEnd1;
}

/// @notice The vault's liquidity in its Metric pool.
/// @dev All of it lies in the window `[lowestBin, lowestBin + binCount)`; re-centering moves the window only after
/// emptying the bins it leaves.
struct Venue {
    int16 lowestBin;
    /// @dev Whether the window has been set; it is set at the first placement, centered on the active bin.
    bool windowSet;
    /// @dev Where the oracle reference sits in the pool's fixed grid, recorded when the window is set, since the
    /// cursor's bin holds it then: the bin containing it, or, when it lies on a bin edge (`referenceOnEdge`), the first
    /// bin above it. With the pool at the reference, bins above hold only token0 and bins below only token1; premium
    /// rates anchor on this (audit finding X-3).
    int16 referenceBin;
    bool referenceOnEdge;
    /// @dev The pool's scale multipliers, `10^(precision − decimals)`, read once at creation.
    uint64 scale0;
    uint64 scale1;
    /// @dev The pool's bin bounds, minimum share delta and empty-bin mint rates, read once at creation.
    int16 poolLowestBin;
    int16 poolHighestBin;
    uint128 minimumShares;
    uint128 initial0PerShareE18;
    uint128 initial1PerShareE18;
    /// @dev Token amounts of the vault's Metric position at the last read.
    uint128 holdings0;
    uint128 holdings1;
    /// @dev The same position as it would be with the pool at the reference: bins above the window's center as token0,
    /// below it as token1. Premium rates and the utilization ceiling read these, so a swap that moves the pool's token
    /// mix cannot move a rate (audit finding X-3).
    uint128 rateHoldings0;
    uint128 rateHoldings1;
}

struct Vault {
    VaultParameters parameters;
    /// @dev The current curves are the last; curves.length <= MAX_CURVE_VERSIONS.
    CurvePair[] curves;
    Accrual accrual;
    Ledger ledger;
    Stream stream;
    Venue venue;
    DebtTotals longDebts;
    DebtTotals shortDebts;
    /// @dev Every open debt, long or short, by its range ends: what lenders' shares are priced with.
    DebtTree debts;
    uint256 totalShares;
    mapping(address lender => uint256) shares;
    /// @dev Each owner's close payouts a transfer refused, by token index; their sums are `Ledger.unclaimed0/1`.
    mapping(address owner => uint256[2]) unclaimed;
    /// @dev Limit-order makers' buckets, lent to maker positions; separate from the lenders above.
    Book book;
}

struct Position {
    address owner;
    uint32 vaultId;
    bool isLong;
    int24 tickLower;
    int24 tickUpper;
    /// @dev When someone flagged the position delinquent; zero when it is not flagged.
    uint40 delinquentSince;
    /// @dev The share of the premium on the token0 curve, in WAD, fixed at open by the value of each token released.
    uint64 weight0Wad;
    uint128 liquidity;
    /// @dev `M0` and `M1` of the borrowed liquidity, rounded up plus one unit. The strike is `M1 / M0`.
    uint128 maximum0;
    uint128 maximum1;
    uint128 reserve0;
    uint128 reserve1;
    /// @dev Tokens released at open and not yet returned, the position's part of `Accrual.outstanding`.
    uint128 released0;
    uint128 released1;
    /// @dev Token1 the trader put in (collateral and escrow) and has not yet recovered: the profit share's cost basis.
    uint128 basis;
    uint128 escrow;
    /// @dev Snapshots of the vault's indices at the last settlement.
    uint128 rateIndex0Ray;
    uint128 rateIndex1Ray;
    /// @dev Premium under one raw unit, in WAD of a unit, that the last settlement left for the next.
    uint64 premiumFractionWad;
}

/// @notice All storage of the singleton.
struct VaultStore {
    uint256 vaultCount;
    uint256 lastPositionId;
    mapping(uint256 vaultId => Vault) vaults;
    mapping(uint256 positionId => Position) positions;
    mapping(address pool => uint256 vaultId) vaultOfPool;
    /// @dev Maker positions share the position id counter, so an id names one kind of position only.
    mapping(uint256 positionId => MakerPosition) makerPositions;
    mapping(uint256 positionId => mapping(uint256 legIndex => Leg)) legs;
    /// @dev Each owner's open position ids by book, for `positionsOf`; a close reorders them (`PositionIndex`).
    mapping(address owner => uint256[] positionIds) passivePositionIds;
    mapping(address owner => uint256[] positionIds) makerPositionIds;
    /// @dev Each open position's index in its owner's list for its book.
    mapping(uint256 positionId => uint256 index) indexInOwnerList;
}

struct OpenRequest {
    uint256 vaultId;
    bool isLong;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    /// @notice Token1 added to the reserves.
    uint128 collateral;
    /// @notice Token1 prepaid into the premium escrow.
    uint128 escrow;
    /// @notice Reserve tokens sold into the target asset after the release; zero for none.
    uint256 entryAmountIn;
    /// @notice The least the entry swap must return.
    uint256 entryMinimumOut;
    /// @notice Where the entry swap trades: zero for the vault's Metric pool, otherwise any `ISwapVenue` the trader
    /// names, such as an aggregator's adapter. Any fill stands; what it loses against the band is charged to the basis.
    address entryVenue;
    /// @notice Passed to `entryVenue` untouched: the route.
    bytes entryRoute;
}

struct IncreaseRequest {
    uint256 positionId;
    /// @notice Liquidity added on the position's range. Its own `M1` must reach the minimum borrow, as an open's must.
    uint128 liquidity;
    /// @notice Token1 added to the reserves.
    uint128 collateral;
    /// @notice Token1 added to the premium escrow, after the premium owed at the old size is settled.
    uint128 escrow;
    /// @notice Tokens this call adds sold into the target asset after the release, as an open's entry swap; zero for
    /// none. Reserves the position already held are not sold.
    uint256 entryAmountIn;
    /// @notice The least the entry swap must return.
    uint256 entryMinimumOut;
    /// @notice As an open's: zero for the vault's Metric pool, otherwise the `ISwapVenue` the trader names.
    address entryVenue;
    bytes entryRoute;
}

/// @notice A swap of tokens leaving the vault, through the venue their owner names: a close's closed reserves before
/// it repays (for the token the repayment needs, or the tokens the trader wants to leave with), or a withdrawal's
/// payout. Any fill stands. On a close, what it loses against the close band counts as taken out, so the profit share
/// is measured as if it had filled at the band; a payout is the owner's alone.
struct ExitSwap {
    /// @notice True to sell token0 for token1.
    bool zeroForOne;
    /// @notice At most what the closed part of the reserves, or the payout, holds of the token sold.
    uint256 amountIn;
    uint256 minimumOut;
    /// @notice Zero for the vault's Metric pool, otherwise any `ISwapVenue` the trader names.
    address venue;
    bytes route;
}

/// @notice A venue a keeper names for a swap of someone else's tokens, and its route; a zero venue is the vault's pool.
struct NamedVenue {
    address venue;
    bytes route;
}

struct CloseRequest {
    uint256 positionId;
    /// @notice The fraction closed, in WAD; WAD closes in full.
    uint256 fractionWad;
    /// @notice The repayment, taken from the closed part of the reserves; it must pass the repayment rule.
    uint256 repay0;
    uint256 repay1;
}
