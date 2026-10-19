// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    Accrual,
    CloseRequest,
    CurvePair,
    ExitSwap,
    IncreaseRequest,
    Ledger,
    OpenRequest,
    Position,
    PricePoint,
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
    MakerIncreaseRequest,
    MakerOpenRequest,
    MakerPosition,
    MakerShare
} from "./MakerTypes.sol";
import {IMakerBook} from "./interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "./interfaces/IMetricLendingVault.sol";
import {IMetricLiquidityCallback, IMetricSwapCallback} from "./interfaces/IMetricPool.sol";
import {MakerBook} from "./libraries/MakerBook.sol";
import {MetricVenue} from "./libraries/MetricVenue.sol";
import {MakerClosing} from "./libraries/MakerClosing.sol";
import {MakerMath} from "./libraries/MakerMath.sol";
import {MakerPositions} from "./libraries/MakerPositions.sol";
import {DebtValuation} from "./libraries/DebtValuation.sol";
import {Curve, DebtTotals} from "./libraries/VaultMath.sol";
import {VaultAdmin} from "./libraries/VaultAdmin.sol";
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

    function withdrawAfterSwap(
        uint256 vaultId,
        uint256 shares,
        uint256 minimum0,
        uint256 minimum1,
        address receiver,
        ExitSwap calldata swap
    ) external nonReentrant returns (uint256 amount0, uint256 amount1, uint256 burned) {
        return VaultLending.withdrawAfterSwap(_store, vaultId, shares, minimum0, minimum1, receiver, swap);
    }

    // ---------------------------------------------------------------- traders

    function open(OpenRequest calldata request) external nonReentrant returns (uint256) {
        return VaultPositions.open(_store, request);
    }

    function increase(IncreaseRequest calldata request) external nonReentrant {
        VaultPositions.increase(_store, request);
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

    /// @notice Records a price point for the realized charge and the transformation rate, once an hour has passed since
    /// the last. Anyone may call; a keeper is expected to, hourly. Returns whether it recorded.
    function recordPrice(uint256 vaultId) external nonReentrant returns (bool) {
        return VaultAdmin.recordPrice(_store, vaultId);
    }

    function flag(uint256 positionId) external nonReentrant {
        VaultPositions.flag(_store, positionId);
    }

    function close(CloseRequest calldata request) external nonReentrant returns (uint256 paid0, uint256 paid1) {
        return VaultClosing.close(_store, request);
    }

    function closeAfterSwap(CloseRequest calldata request, ExitSwap calldata exit)
        external
        nonReentrant
        returns (uint256 paid0, uint256 paid1)
    {
        return VaultClosing.closeAfterSwap(_store, request, exit);
    }

    function forceClose(uint256 positionId) external nonReentrant returns (uint256 reward0, uint256 reward1) {
        return VaultClosing.forceClose(_store, positionId);
    }

    function forceCloseThrough(uint256 positionId, address venue, bytes calldata route)
        external
        nonReentrant
        returns (uint256 reward0, uint256 reward1)
    {
        return VaultClosing.forceCloseThrough(_store, positionId, venue, route);
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

    function withdrawOrderAfterSwap(
        uint256 vaultId,
        uint256 bucketId,
        uint256 shares,
        uint256 minimum0,
        uint256 minimum1,
        address receiver,
        ExitSwap calldata swap
    ) external nonReentrant returns (uint256 amount0, uint256 amount1, uint256 burned) {
        return MakerBook.withdrawAfterSwap(_store, vaultId, bucketId, shares, minimum0, minimum1, receiver, swap);
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

    function fillBucketThrough(uint256 vaultId, uint256 bucketId, address venue, bytes calldata route)
        external
        nonReentrant
        returns (uint256 paid, uint256 received)
    {
        return MakerBook.fillThrough(_store, vaultId, bucketId, venue, route);
    }

    function openMaker(MakerOpenRequest calldata request) external nonReentrant returns (uint256) {
        return MakerPositions.open(_store, request);
    }

    function increaseMaker(MakerIncreaseRequest calldata request) external nonReentrant {
        MakerPositions.increase(_store, request);
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

    function closeMakerAfterSwap(MakerCloseRequest calldata request, ExitSwap calldata exit)
        external
        nonReentrant
        returns (uint256 paid0, uint256 paid1)
    {
        return MakerClosing.closeAfterSwap(_store, request, exit);
    }

    function forceCloseMaker(uint256 positionId) external nonReentrant returns (uint256 reward0, uint256 reward1) {
        return MakerClosing.forceClose(_store, positionId);
    }

    function forceCloseMakerThrough(uint256 positionId, address venue, bytes calldata route)
        external
        nonReentrant
        returns (uint256 reward0, uint256 reward1)
    {
        return MakerClosing.forceCloseThrough(_store, positionId, venue, route);
    }

    // ---------------------------------------------------------------- Metric callbacks

    /// @inheritdoc IMetricLiquidityCallback
    function metricOmmModifyLiquidityCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        MetricVenue.payLiquidityCallback(_store, amount0, amount1);
    }

    /// @inheritdoc IMetricSwapCallback
    function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        MetricVenue.paySwapCallback(_store, amount0Delta, amount1Delta);
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

    /// @notice The vault's price point count, the oracle's σ in WAD, and the point at `index`.
    function priceOf(uint256 vaultId, uint256 index)
        external
        view
        returns (uint256 count, uint256 sigmaWad, PricePoint memory point)
    {
        return VaultAdmin.priceOf(_store, vaultId, index);
    }

    /// @notice The owner's open position ids in each book, in no fixed order: a full close moves the list's last id
    /// into the closed one's place.
    function positionsOf(address owner) external view returns (uint256[] memory passive, uint256[] memory maker) {
        return (_store.passivePositionIds[owner], _store.makerPositionIds[owner]);
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
}
