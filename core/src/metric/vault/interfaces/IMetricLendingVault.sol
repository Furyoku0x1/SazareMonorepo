// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Errors and events of the Metric Lending Vault, shared by the contract and its libraries.
interface IMetricLendingVault {
    error Unauthorized();
    error InvalidParameters();
    error UnknownVault();
    error UnknownPosition();
    error PoolTaken();
    error TooManyCurveVersions();
    error ZeroAmount();
    error InsufficientShares();
    error SlippageExceeded();
    /// @dev The vault's idle capital cannot cover the release.
    error InsufficientIdle();
    error UtilizationCeiling();
    error BelowMinimumBorrow();
    /// @dev The reserves fail the chord: the position could not repay at every price.
    error Insolvent();
    /// @dev The repayment fails the repayment rule, or takes more than the closed part of the reserves.
    error RepaymentShort();
    /// @dev A partial close or an increase must pay all premium owed first; an increase is also refused while the
    /// position is flagged.
    error PremiumUnpaid();
    error NotDelinquent();
    error GracePeriodRunning();
    error InvalidFraction();
    error UnexpectedCallback();
    error InvalidBand();
    /// @notice An open's escrow does not cover its premium over the minimum escrow period.
    error EscrowTooSmall();
    /// @notice A force close's shortfall swap did not fill though the reserves could pay at the band; retry once the
    /// pool can fill it, rather than scale at a loss to the trader.
    error ShortfallUnfilled();
    /// @notice A force close found no price on its pool; retry once the pool prices again, or once the wait without a
    /// price is over and the close may scale the reserves instead.
    error PriceUnavailable();

    event VaultCreated(uint256 indexed vaultId, address indexed pool, address token0, address token1);
    event CurvesAppended(uint256 indexed vaultId, uint256 version);
    event Deposited(uint256 indexed vaultId, address indexed lender, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdrawn(uint256 indexed vaultId, address indexed lender, uint256 amount0, uint256 amount1, uint256 shares);
    event Opened(
        uint256 indexed positionId,
        uint256 indexed vaultId,
        address indexed owner,
        bool isLong,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 released0,
        uint256 released1
    );
    /// @notice Liquidity added to an open position; `released0`/`released1` are the added part's release.
    event Increased(uint256 indexed positionId, uint128 liquidity, uint256 released0, uint256 released1);
    event Closed(uint256 indexed positionId, uint256 fractionWad, uint256 paid0, uint256 paid1, uint256 profitShare);
    event ForceClosed(uint256 indexed positionId, address indexed closer, uint256 reward0, uint256 reward1);
    event Flagged(uint256 indexed positionId);
    event Settled(uint256 indexed positionId, uint256 premium);
    event EscrowAdded(uint256 indexed positionId, uint256 amount);
    event CollateralAdded(uint256 indexed positionId, uint256 amount);
    event Collateral0Added(uint256 indexed positionId, uint256 amount);
    event ProtocolPaid(uint256 indexed vaultId, address indexed recipient, uint256 amount0, uint256 amount1);
    /// @notice A close's payout the token refused to transfer, kept for `owner` to claim.
    event PayoutKept(address indexed owner, uint256 tokenIndex, uint256 amount);
    event PayoutClaimed(uint256 indexed vaultId, address indexed owner, uint256 tokenIndex, uint256 amount);
}
