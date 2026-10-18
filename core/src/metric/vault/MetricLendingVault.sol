// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    Accrual,
    CloseRequest,
    CurvePair,
    Ledger,
    OpenRequest,
    Position,
    Stream,
    Vault,
    VaultParameters,
    VaultStore,
    Venue
} from "./VaultTypes.sol";
import {
    Book,
    BookCurve,
    BookSettings,
    Bucket,
    FloorRow,
    Leg,
    MakerCloseRequest,
    MakerOpenRequest,
    MakerPosition,
    MakerShare
} from "./MakerTypes.sol";
import {IMakerBook} from "./interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "./interfaces/IMetricLendingVault.sol";
import {IMetricLiquidityCallback, IMetricSwapCallback} from "./interfaces/IMetricPool.sol";
import {MakerBook} from "./libraries/MakerBook.sol";
import {MakerClosing} from "./libraries/MakerClosing.sol";
import {MakerMath} from "./libraries/MakerMath.sol";
import {MakerPositions} from "./libraries/MakerPositions.sol";
import {DebtValuation} from "./libraries/DebtValuation.sol";
import {Curve, DebtTotals} from "./libraries/VaultMath.sol";
import {VaultAdmin} from "./libraries/VaultAdmin.sol";
import {VaultCallback} from "./libraries/VaultCallback.sol";
import {VaultClosing} from "./libraries/VaultClosing.sol";
import {VaultLending} from "./libraries/VaultLending.sol";
import {VaultPositions} from "./libraries/VaultPositions.sol";

/// @title MetricLendingVault
/// @notice Leveraged long and short positions with no liquidations, funded by lenders whose idle capital sits in a
/// Metric pool. One contract holds every vault, one per Metric pool. See `hooks/docs/metric-lending-vault-spec.md`.
/// @dev Logic lives in linked libraries, delegatecalled, so `msg.sender` stays the user. Every entry point holds a
/// transient reentrancy lock; Metric's callbacks arrive while it is held and are admitted only when the singleton
/// itself is mid-call into that pool and expecting them.
contract MetricLendingVault is
    IMetricLendingVault,
    IMakerBook,
    IMetricLiquidityCallback,
    IMetricSwapCallback,
    Ownable2Step,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;

    /// @notice Receives the protocol's slice of premium and part of each profit share.
    address public immutable treasury;
    /// @notice Receives the fee vault's part of each profit share.
    address public immutable feeVault;
    /// @notice Metric's pool factory: a vault's pool must be one it deployed, so the pool's code is Metric's own (audit
    /// finding B1). Zero allows only vaults with no pool.
    address public immutable metricFactory;

    VaultStore private _store;

    constructor(address initialOwner, address treasury_, address feeVault_, address metricFactory_)
        Ownable(initialOwner)
    {
        if (treasury_ == address(0)) revert InvalidParameters();
        if (feeVault_ == address(0)) revert InvalidParameters();
        treasury = treasury_;
        feeVault = feeVault_;
        metricFactory = metricFactory_;
    }

    // ---------------------------------------------------------------- administration

    function createVault(VaultParameters calldata parameters, CurvePair calldata curves)
        external
        onlyOwner
        nonReentrant
        returns (uint256)
    {
        return VaultAdmin.createVault(_store, parameters, curves, metricFactory);
    }

    function appendCurves(uint256 vaultId, CurvePair calldata curves) external onlyOwner nonReentrant {
        VaultAdmin.appendCurves(_store, vaultId, curves);
    }

    function payProtocol(uint256 vaultId) external nonReentrant {
        VaultAdmin.payProtocol(_store, vaultId, treasury, feeVault);
    }

    function claimPayout(uint256 vaultId, uint256 tokenIndex) external nonReentrant returns (uint256 amount) {
        return VaultAdmin.claimPayout(_store, vaultId, tokenIndex);
    }

    // ---------------------------------------------------------------- lenders

    function deposit(uint256 vaultId, uint256 amount0, uint256 amount1, uint256 minimumShares, address receiver)
        external
        nonReentrant
        returns (uint256)
    {
        return VaultLending.deposit(_store, vaultId, amount0, amount1, minimumShares, receiver);
    }

    function withdraw(uint256 vaultId, uint256 shares, uint256 minimum0, uint256 minimum1, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1, uint256 burned)
    {
        return VaultLending.withdraw(_store, vaultId, shares, minimum0, minimum1, receiver);
    }

    function recenter(uint256 vaultId) external nonReentrant returns (bool) {
        return VaultLending.recenter(_store, vaultId);
    }

    // ---------------------------------------------------------------- traders

    function open(OpenRequest calldata request) external nonReentrant returns (uint256) {
        return VaultPositions.open(_store, request);
    }

    function addEscrow(uint256 positionId, uint256 amount) external nonReentrant {
        VaultPositions.addEscrow(_store, positionId, amount);
    }

    function addCollateral(uint256 positionId, uint256 amount) external nonReentrant {
        VaultPositions.addCollateral(_store, positionId, amount);
    }

    function addCollateral0(uint256 positionId, uint256 amount) external nonReentrant {
        VaultPositions.addCollateral0(_store, positionId, amount);
    }

    function settle(uint256 positionId) external nonReentrant returns (bool) {
        return VaultPositions.settle(_store, positionId);
    }

    function flag(uint256 positionId) external nonReentrant {
        VaultPositions.flag(_store, positionId);
    }

    function close(CloseRequest calldata request) external nonReentrant returns (uint256 paid0, uint256 paid1) {
        return VaultClosing.close(_store, request);
    }

    function forceClose(uint256 positionId) external nonReentrant returns (uint256 reward0, uint256 reward1) {
        return VaultClosing.forceClose(_store, positionId);
    }

    // ---------------------------------------------------------------- maker book

    function createBook(uint256 vaultId, BookSettings calldata settings, Curve calldata curve, FloorRow[] calldata rows)
        external
        onlyOwner
        nonReentrant
    {
        MakerBook.createBook(_store, vaultId, settings, curve, rows);
    }

    function appendBookCurve(uint256 vaultId, Curve calldata curve) external onlyOwner nonReentrant {
        MakerBook.appendCurve(_store, vaultId, curve);
    }

    function appendFloorTable(uint256 vaultId, FloorRow[] calldata rows) external onlyOwner nonReentrant {
        MakerBook.appendFloorTable(_store, vaultId, rows);
    }

    function depositOrder(
        uint256 vaultId,
        int24 level,
        bool isBuy,
        uint256 amount,
        uint256 minimumShares,
        address receiver
    ) external nonReentrant returns (uint256 bucketId, uint256 shares) {
        return MakerBook.deposit(_store, vaultId, level, isBuy, amount, minimumShares, receiver);
    }

    function withdrawOrder(
        uint256 vaultId,
        uint256 bucketId,
        uint256 shares,
        uint256 minimum0,
        uint256 minimum1,
        address receiver
    ) external nonReentrant returns (uint256 amount0, uint256 amount1, uint256 burned) {
        return MakerBook.withdraw(_store, vaultId, bucketId, shares, minimum0, minimum1, receiver);
    }

    function claimOrderIncome(uint256 vaultId, uint256 bucketId, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        return MakerBook.claim(_store, vaultId, bucketId, receiver);
    }

    function fillBucket(uint256 vaultId, uint256 bucketId)
        external
        nonReentrant
        returns (uint256 paid, uint256 received)
    {
        return MakerBook.fill(_store, vaultId, bucketId);
    }

    function openMaker(MakerOpenRequest calldata request) external nonReentrant returns (uint256) {
        return MakerPositions.open(_store, request);
    }

    function addMakerEscrow(uint256 positionId, uint256 amount) external nonReentrant {
        MakerPositions.addEscrow(_store, positionId, amount);
    }

    function addMakerCollateral(uint256 positionId, uint256 amount) external nonReentrant {
        MakerPositions.addCollateral(_store, positionId, amount);
    }

    function addMakerCollateral0(uint256 positionId, uint256 amount) external nonReentrant {
        MakerPositions.addCollateral0(_store, positionId, amount);
    }

    function settleMaker(uint256 positionId) external nonReentrant returns (bool) {
        return MakerPositions.settle(_store, positionId);
    }

    function flagMaker(uint256 positionId) external nonReentrant {
        MakerPositions.flag(_store, positionId);
    }

    function closeMaker(MakerCloseRequest calldata request)
        external
        nonReentrant
        returns (uint256 paid0, uint256 paid1)
    {
        return MakerClosing.close(_store, request);
    }

    function forceCloseMaker(uint256 positionId) external nonReentrant returns (uint256 reward0, uint256 reward1) {
        return MakerClosing.forceClose(_store, positionId);
    }

    // ---------------------------------------------------------------- Metric callbacks

    /// @inheritdoc IMetricLiquidityCallback
    function metricOmmModifyLiquidityCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        (uint256 vaultId, uint256 maximum0, uint256 maximum1) = _takeCallback();
        if (amount0 > maximum0) revert UnexpectedCallback();
        if (amount1 > maximum1) revert UnexpectedCallback();
        _payPool(vaultId, amount0, amount1);
    }

    /// @inheritdoc IMetricSwapCallback
    function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        (uint256 minimumOut0, uint256 minimumOut1) = VaultCallback.minimumOutputs();
        (uint256 vaultId, uint256 maximum0, uint256 maximum1) = _takeCallback();
        uint256 owed0 = amount0Delta > 0 ? uint256(amount0Delta) : 0;
        uint256 owed1 = amount1Delta > 0 ? uint256(amount1Delta) : 0;
        uint256 output0 = amount0Delta < 0 ? uint256(-amount0Delta) : 0;
        uint256 output1 = amount1Delta < 0 ? uint256(-amount1Delta) : 0;
        if (owed0 > maximum0) revert UnexpectedCallback();
        if (owed1 > maximum1) revert UnexpectedCallback();
        // A partial fill reverts here, undoing the whole swap.
        if (output0 < minimumOut0) revert SlippageExceeded();
        if (output1 < minimumOut1) revert SlippageExceeded();
        _requireArrived(vaultId, minimumOut0, minimumOut1);
        _payPool(vaultId, owed0, owed1);
    }

    // ---------------------------------------------------------------- views

    function vaultCount() external view returns (uint256) {
        return _store.vaultCount;
    }

    function lastPositionId() external view returns (uint256) {
        return _store.lastPositionId;
    }

    function vaultOfPool(address pool) external view returns (uint256) {
        return _store.vaultOfPool[pool];
    }

    function parametersOf(uint256 vaultId) external view returns (VaultParameters memory) {
        return _store.vaults[vaultId].parameters;
    }

    function curvesOf(uint256 vaultId) external view returns (CurvePair[] memory) {
        return _store.vaults[vaultId].curves;
    }

    function ledgerOf(uint256 vaultId) external view returns (Ledger memory) {
        return _store.vaults[vaultId].ledger;
    }

    function accrualOf(uint256 vaultId) external view returns (Accrual memory) {
        return _store.vaults[vaultId].accrual;
    }

    function streamOf(uint256 vaultId) external view returns (Stream memory) {
        return _store.vaults[vaultId].stream;
    }

    function venueOf(uint256 vaultId) external view returns (Venue memory) {
        return _store.vaults[vaultId].venue;
    }

    function debtsOf(uint256 vaultId)
        external
        view
        returns (DebtTotals memory longDebts, DebtTotals memory shortDebts)
    {
        Vault storage vault = _store.vaults[vaultId];
        return (vault.longDebts, vault.shortDebts);
    }

    /// @notice The open debts' value in token1 at a price, as withdrawals (`low`) and deposits (`high`) price it.
    function debtValuesAt(uint256 vaultId, uint160 sqrtPriceX96) external view returns (uint256 low, uint256 high) {
        Vault storage vault = _store.vaults[vaultId];
        low = DebtValuation.valueLow(vault.debts, sqrtPriceX96);
        high = DebtValuation.valueHigh(vault.debts, sqrtPriceX96);
    }

    function totalSharesOf(uint256 vaultId) external view returns (uint256) {
        return _store.vaults[vaultId].totalShares;
    }

    function unclaimedOf(uint256 vaultId, address owner) external view returns (uint256 amount0, uint256 amount1) {
        uint256[2] storage held = _store.vaults[vaultId].unclaimed[owner];
        return (held[0], held[1]);
    }

    function sharesOf(uint256 vaultId, address lender) external view returns (uint256) {
        return _store.vaults[vaultId].shares[lender];
    }

    function positionOf(uint256 positionId) external view returns (Position memory) {
        return _store.positions[positionId];
    }

    function bookSettingsOf(uint256 vaultId) external view returns (BookSettings memory) {
        return _store.vaults[vaultId].book.settings;
    }

    /// @notice The book's totals: every bucket's balances, and the income its makers have not yet claimed.
    function bookTotalsOf(uint256 vaultId)
        external
        view
        returns (uint256 balance0, uint256 balance1, uint256 income0, uint256 income1)
    {
        Book storage book = _store.vaults[vaultId].book;
        return (book.balance0, book.balance1, book.income0, book.income1);
    }

    function bookCurvesOf(uint256 vaultId) external view returns (BookCurve[] memory) {
        return _store.vaults[vaultId].book.curves;
    }

    function floorTableOf(uint256 vaultId, uint256 version) external view returns (FloorRow[] memory) {
        return _store.vaults[vaultId].book.floorTables[version].rows;
    }

    /// @notice The bucket taking deposits at a level and side.
    function currentBucketOf(uint256 vaultId, int24 level, bool isBuy) external view returns (uint256) {
        uint32 generation = _store.vaults[vaultId].book.generations[MakerMath.levelKey(level, isBuy)];
        return MakerMath.bucketId(level, isBuy, generation);
    }

    function bucketOf(uint256 vaultId, uint256 bucketId) external view returns (Bucket memory) {
        return _store.vaults[vaultId].book.buckets[bucketId];
    }

    function makerShareOf(uint256 vaultId, uint256 bucketId, address maker) external view returns (MakerShare memory) {
        return _store.vaults[vaultId].book.shares[bucketId][maker];
    }

    function makerPositionOf(uint256 positionId) external view returns (MakerPosition memory) {
        return _store.makerPositions[positionId];
    }

    function legOf(uint256 positionId, uint256 index) external view returns (Leg memory) {
        return _store.legs[positionId][index];
    }

    // ---------------------------------------------------------------- internal

    function _takeCallback() private returns (uint256 vaultId, uint256 maximum0, uint256 maximum1) {
        bool ok;
        (ok, vaultId, maximum0, maximum1) = VaultCallback.take(msg.sender);
        if (!ok) revert UnexpectedCallback();
    }

    /// @dev The caller's library records the ledger debit once the pool call returns, from the amounts the pool
    /// reports; this only moves the tokens.
    function _payPool(uint256 vaultId, uint256 amount0, uint256 amount1) private {
        Vault storage vault = _store.vaults[vaultId];
        _payExactly(vault.parameters.token0, amount0);
        _payExactly(vault.parameters.token1, amount1);
    }

    /// @dev Pays the calling pool and requires custody to fall by exactly `amount`: a token that took more from the
    /// sender would leave the other vaults' tokens short (audit finding B2).
    function _payExactly(address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, amount);
        // Checked after the transfer: the singleton's lock is held, so nothing else moved the balance.
        if (balanceBefore - IERC20(token).balanceOf(address(this)) != amount) revert UnexpectedCallback();
    }

    /// @dev Requires a minimum output to have actually arrived, not merely to be reported, measured from the balances
    /// saved before the swap: Metric pays the output before it calls back (audit finding B2).
    function _requireArrived(uint256 vaultId, uint256 minimumOut0, uint256 minimumOut1) private view {
        Vault storage vault = _store.vaults[vaultId];
        (uint256 balance0Before, uint256 balance1Before) = VaultCallback.balancesBefore();
        uint256 balance0 = IERC20(vault.parameters.token0).balanceOf(address(this));
        uint256 balance1 = IERC20(vault.parameters.token1).balanceOf(address(this));
        uint256 arrived0 = balance0 > balance0Before ? balance0 - balance0Before : 0;
        uint256 arrived1 = balance1 > balance1Before ? balance1 - balance1Before : 0;
        if (arrived0 < minimumOut0) revert SlippageExceeded();
        if (arrived1 < minimumOut1) revert SlippageExceeded();
    }
}
