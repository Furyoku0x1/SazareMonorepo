// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Book, BookSettings, Bucket, FloorRow, MakerShare} from "../MakerTypes.sol";
import {Vault, VaultStore} from "../VaultTypes.sol";
import {IMakerBook} from "../interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {Curve, VaultMath} from "./VaultMath.sol";
import {MakerAccounting} from "./MakerAccounting.sol";
import {MakerMath} from "./MakerMath.sol";
import {MetricVenue} from "./MetricVenue.sol";
import {VaultLedger} from "./VaultLedger.sol";
import {VaultPricing} from "./VaultPricing.sol";

/// @notice The maker book's orders: creating a vault's book, makers' deposits, withdrawals and income, and fills.
/// @dev An external library: the singleton delegatecalls it. Shares are priced on a bucket's value (balances plus the
/// holdings of the liquidity it lent), deposits at the ask and withdrawals at the bid, as the vault's lenders are.
library MakerBook {
    using SafeCast for uint256;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_VALUE = 1;
    uint256 internal constant MAX_LEVEL_TICKS = 10_000;
    uint256 internal constant MAX_FILL_REWARD_BPS = 100;
    uint256 internal constant MAX_PERIOD_SECONDS = 30 days;
    /// @dev 1,000% a year: a floor above it would drain any escrow within weeks.
    uint256 internal constant MAX_FLOOR_RATE_BPS = 100_000;
    /// @dev 100% a year: the least a curve may charge at the utilization ceiling.
    uint256 internal constant MIN_CEILING_RATE_WAD = 1e18;

    /// @dev A withdrawal's amounts and the shares they burn; a struct keeps the stack shallow.
    struct Withdrawal {
        uint256 amount0;
        uint256 amount1;
        uint256 burned;
    }

    // ---------------------------------------------------------------- administration

    /// @notice Creates a vault's book, once, with its settings, first curve and first floor table.
    function createBook(
        VaultStore storage store,
        uint256 vaultId,
        BookSettings calldata settings,
        Curve calldata curve,
        FloorRow[] calldata rows
    ) external {
        Vault storage vault = _vault(store, vaultId);
        Book storage book = vault.book;
        if (book.enabled) revert IMakerBook.BookExists();
        _validateSettings(settings);
        book.enabled = true;
        book.settings = settings;
        _pushCurve(book, curve);
        _pushFloorTable(book, rows);
        emit IMakerBook.BookCreated(vaultId, settings.levelTicks);
    }

    /// @notice Adds a curve version, in force from now. Buckets integrate each version over its own interval at their
    /// next checkpoint, so the past is never repriced.
    function appendCurve(VaultStore storage store, uint256 vaultId, Curve calldata curve) external {
        Book storage book = _book(_vault(store, vaultId));
        if (book.curves.length >= MakerMath.MAX_VERSIONS) revert IMetricLendingVault.TooManyCurveVersions();
        _pushCurve(book, curve);
        emit IMakerBook.BookCurveAppended(vaultId, book.curves.length - 1);
    }

    /// @notice Adds a floor table, used by legs opened from now; open legs keep the floor they opened with.
    function appendFloorTable(VaultStore storage store, uint256 vaultId, FloorRow[] calldata rows) external {
        Book storage book = _book(_vault(store, vaultId));
        if (book.floorTables.length >= MakerMath.MAX_VERSIONS) revert IMetricLendingVault.TooManyCurveVersions();
        _pushFloorTable(book, rows);
        emit IMakerBook.FloorTableAppended(vaultId, book.floorTables.length - 1);
    }

    // ---------------------------------------------------------------- makers

    /// @notice Deposits a limit order into the current generation at a level: token1 for a buy level wholly below
    /// the band, token0 for a sell level wholly above it. Shares are priced on the bucket's value at the ask.
    function deposit(
        VaultStore storage store,
        uint256 vaultId,
        int24 level,
        bool isBuy,
        uint256 amount,
        uint256 minimumShares,
        address receiver
    ) external returns (uint256 bucketId, uint256 shares) {
        Vault storage vault = _vault(store, vaultId);
        Book storage book = _book(vault);
        if (amount == 0) revert IMetricLendingVault.ZeroAmount();
        if (receiver == address(0)) revert IMetricLendingVault.InvalidParameters();
        bucketId = MakerMath.bucketId(level, isBuy, book.generations[MakerMath.levelKey(level, isBuy)]);
        Bucket storage bucket = MakerAccounting.checkpoint(book, bucketId);
        // The current generation advances when its bucket retires, so it is never retired.
        assert(!bucket.retired);
        shares = _depositShares(vault, bucket, level, isBuy, amount);
        if (shares == 0) revert IMetricLendingVault.ZeroAmount();
        if (shares < minimumShares) revert IMetricLendingVault.SlippageExceeded();
        VaultLedger.pull(vault, isBuy ? 1 : 0, msg.sender, amount);
        _mint(book, bucket, bucketId, receiver, shares);
        _addBalance(book, bucket, isBuy ? 0 : amount, isBuy ? amount : 0);
        emit IMakerBook.OrderDeposited(vaultId, bucketId, receiver, amount, shares);
    }

    /// @notice Burns shares for the bucket's unlent balances, pro rata by value at the bid. Only unlent capital can
    /// leave, and an active bucket's loans must stay within the ceiling: what cannot leave now stays, and only the
    /// shares paid for are burned, rounded up.
    function withdraw(
        VaultStore storage store,
        uint256 vaultId,
        uint256 bucketId,
        uint256 shares,
        uint256 minimum0,
        uint256 minimum1,
        address receiver
    ) external returns (uint256 amount0, uint256 amount1, uint256 burned) {
        Vault storage vault = _vault(store, vaultId);
        Withdrawal memory result = _withdrawShares(vault, bucketId, shares);
        if (result.amount0 < minimum0) revert IMetricLendingVault.SlippageExceeded();
        if (result.amount1 < minimum1) revert IMetricLendingVault.SlippageExceeded();
        VaultLedger.push(vault, 0, receiver, result.amount0);
        VaultLedger.push(vault, 1, receiver, result.amount1);
        emit IMakerBook.OrderWithdrawn(vaultId, bucketId, msg.sender, result.amount0, result.amount1, result.burned);
        return (result.amount0, result.amount1, result.burned);
    }

    /// @notice Pays the caller's vested income from a bucket, in both tokens.
    function claim(VaultStore storage store, uint256 vaultId, uint256 bucketId, address receiver)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Vault storage vault = _vault(store, vaultId);
        Book storage book = _book(vault);
        Bucket storage bucket = MakerAccounting.checkpoint(book, bucketId);
        MakerShare storage holding = book.shares[bucketId][msg.sender];
        MakerAccounting.accrueMaker(bucket, holding);
        amount0 = holding.income0;
        amount1 = holding.income1;
        if (amount0 == 0) {
            if (amount1 == 0) revert IMetricLendingVault.ZeroAmount();
        }
        holding.income0 = 0;
        holding.income1 = 0;
        book.income0 -= amount0.toUint128();
        book.income1 -= amount1.toUint128();
        VaultLedger.push(vault, 0, receiver, amount0);
        VaultLedger.push(vault, 1, receiver, amount1);
        emit IMakerBook.IncomeClaimed(vaultId, bucketId, msg.sender, amount0, amount1);
    }

    /// @notice Fills a bucket's waiting tokens once the whole band has passed its level: a buy bucket buys token0 at
    /// no more than the level's bottom, a sell bucket sells at no less than its top, both net of the keeper's reward.
    /// Partial fills stand; the first non-zero fill retires the bucket.
    function fill(VaultStore storage store, uint256 vaultId, uint256 bucketId)
        external
        returns (uint256 paid, uint256 received)
    {
        Vault storage vault = _vault(store, vaultId);
        Book storage book = _book(vault);
        if (vault.parameters.pool == address(0)) revert IMakerBook.NotFillable();
        Bucket storage bucket = MakerAccounting.checkpoint(book, bucketId);
        uint256 netReceived;
        (paid, received, netReceived) = _swapWaiting(vault, vaultId, bucket, bucketId);
        (, bool isBuy,) = MakerMath.decode(bucketId);
        _settleFill(book, bucket, isBuy, paid, netReceived);
        VaultLedger.push(vault, isBuy ? 0 : 1, msg.sender, received - netReceived);
        _retire(book, bucket, bucketId);
        emit IMakerBook.BucketFilled(vaultId, bucketId, msg.sender, paid, received);
    }

    // ---------------------------------------------------------------- deposits

    /// @dev The shares a deposit buys: its value at the bid (token0 for a sell level) against the bucket's value at the
    /// ask, with the virtual offset. The level must lie wholly on the waiting side of the band. The bucket's value
    /// counts its income still vesting, so the new shares pay for income earned before them (audit finding A3).
    function _depositShares(Vault storage vault, Bucket storage bucket, int24 level, bool isBuy, uint256 amount)
        private
        returns (uint256)
    {
        Book storage book = vault.book;
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, book.settings.levelTicks);
        (uint160 sqrtBidX96, uint160 sqrtAskX96) = VaultPricing.band(vault);
        MakerMath.requireWaitingSide(isBuy, sqrtBidX96, sqrtAskX96, sqrtLowerX96, sqrtUpperX96);
        uint256 valueIn = isBuy ? amount : VaultMath.priceTimes(amount, sqrtBidX96, false);
        if (valueIn < book.settings.minimumNotional) revert IMakerBook.BelowMinimumNotional();
        uint256 valueHigh = MakerMath.bucketValue(bucket, sqrtLowerX96, sqrtUpperX96, sqrtAskX96, true)
            + _vestingValue(bucket, sqrtAskX96);
        return FullMath.mulDiv(valueIn, bucket.totalShares + VIRTUAL_SHARES, valueHigh + VIRTUAL_VALUE);
    }

    /// @dev The income still vesting, at the ask and rounded up. It vests to real shares only, while the deposit is
    /// priced against real and virtual ones, so it is grossed up by `(S + virtual) / S` (Sol). A bucket with no shares
    /// has nothing vesting (D22).
    function _vestingValue(Bucket storage bucket, uint160 sqrtAskX96) private view returns (uint256) {
        uint256 totalShares = bucket.totalShares;
        if (totalShares == 0) return 0;
        uint256 vesting = VaultMath.valueInToken1(bucket.stream0Remaining, bucket.stream1Remaining, sqrtAskX96, true);
        return FullMath.mulDivRoundingUp(vesting, totalShares + VIRTUAL_SHARES, totalShares);
    }

    // ---------------------------------------------------------------- withdrawals

    /// @dev Burns the caller's shares for what the bucket can pay now, and takes the tokens out of its balances.
    function _withdrawShares(Vault storage vault, uint256 bucketId, uint256 shares)
        private
        returns (Withdrawal memory result)
    {
        Book storage book = _book(vault);
        MakerShare storage holding = book.shares[bucketId][msg.sender];
        if (shares > holding.shares) revert IMetricLendingVault.InsufficientShares();
        Bucket storage bucket = MakerAccounting.checkpoint(book, bucketId);
        // While loans are out the bucket keeps an owner for their repayment and premium, even where their value at
        // the bid rounds to nothing (Sol's finding): the last share stays.
        if (bucket.lent != 0) {
            if (shares == bucket.totalShares) shares -= 1;
        }
        if (shares == 0) revert IMetricLendingVault.ZeroAmount();
        result = _withdrawal(vault, book, bucket, bucketId, shares);
        _burn(vault, bucket, bucketId, msg.sender, result.burned);
        _subtractBalance(book, bucket, result.amount0, result.amount1);
    }

    function _withdrawal(
        Vault storage vault,
        Book storage book,
        Bucket storage bucket,
        uint256 bucketId,
        uint256 shares
    ) private returns (Withdrawal memory result) {
        (, bool isBuy,) = MakerMath.decode(bucketId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerAccounting.range(book, bucketId);
        uint256 entitlementWad = _entitlement(vault, bucket, shares, sqrtLowerX96, sqrtUpperX96);
        uint256 payWad = entitlementWad < MakerMath.WAD ? entitlementWad : MakerMath.WAD;
        uint256 ceilingWad = _ceilingFraction(book, bucket, isBuy, sqrtLowerX96, sqrtUpperX96);
        if (payWad > ceilingWad) payWad = ceilingWad;
        result.amount0 = VaultMath.portionDown(bucket.balance0, payWad);
        result.amount1 = VaultMath.portionDown(bucket.balance1, payWad);
        if (result.amount0 == 0) {
            if (result.amount1 == 0) revert IMetricLendingVault.InsufficientIdle();
        }
        // Only the shares paid for burn, against the uncapped entitlement (Sol: dividing by a capped one could burn
        // everything for a partial payout).
        result.burned = payWad >= entitlementWad ? shares : FullMath.mulDivRoundingUp(shares, payWad, entitlementWad);
    }

    /// @dev The fraction of the bucket's balances `shares` are entitled to, uncapped: their share of the bucket, scaled
    /// by its value over its balances' value. An active bucket counts the virtual shares, as deposits do; a retired one
    /// takes no deposits, so its makers own it exactly. Ownership leaves out the virtual value, which would otherwise
    /// dominate where values round to a few units (audit finding C3). With nothing lent the bucket is its balances, so
    /// the share needs no price (audit finding A5).
    function _entitlement(
        Vault storage vault,
        Bucket storage bucket,
        uint256 shares,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) private returns (uint256 entitlementWad) {
        uint256 outstanding = bucket.retired ? bucket.totalShares : bucket.totalShares + VIRTUAL_SHARES;
        uint256 ownershipWad = FullMath.mulDiv(shares, MakerMath.WAD, outstanding);
        if (ownershipWad == 0) revert IMetricLendingVault.ZeroAmount();
        if (bucket.lent == 0) return ownershipWad;
        (uint160 sqrtBidX96,) = VaultPricing.band(vault);
        uint256 value = MakerMath.bucketValue(bucket, sqrtLowerX96, sqrtUpperX96, sqrtBidX96, false);
        // Balances' value rounds up, so its rounding cannot inflate the fraction.
        uint256 idleValue = VaultMath.valueInToken1(bucket.balance0, bucket.balance1, sqrtBidX96, true);
        if (idleValue == 0) revert IMetricLendingVault.InsufficientIdle();
        entitlementWad = FullMath.mulDiv(ownershipWad, value, idleValue);
        if (entitlementWad == 0) revert IMetricLendingVault.ZeroAmount();
    }

    /// @dev The largest fraction of an active bucket's balances that leaves its loans within the ceiling. A retired
    /// bucket lends nothing more, so its makers may take everything unlent.
    function _ceilingFraction(
        Book storage book,
        Bucket storage bucket,
        bool isBuy,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) private view returns (uint256) {
        if (bucket.retired) return MakerMath.WAD;
        uint256 waiting = isBuy ? bucket.balance1 : bucket.balance0;
        return MakerMath.ceilingFractionWad(
            isBuy, bucket.lent, waiting, book.settings.utilizationCeilingBps, sqrtLowerX96, sqrtUpperX96
        );
    }

    // ---------------------------------------------------------------- fills

    /// @dev Swaps the bucket's waiting tokens through Metric up to the makers' limit, once the whole band has passed
    /// the level, and returns what was paid, received, and received net of the keeper's reward.
    function _swapWaiting(Vault storage vault, uint256 vaultId, Bucket storage bucket, uint256 bucketId)
        private
        returns (uint256 paid, uint256 received, uint256 netReceived)
    {
        (int24 level, bool isBuy,) = MakerMath.decode(bucketId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, vault.book.settings.levelTicks);
        _requirePassed(vault, isBuy, sqrtLowerX96, sqrtUpperX96);
        uint256 waiting = isBuy ? bucket.balance1 : bucket.balance0;
        if (waiting == 0) revert IMakerBook.NotFillable();
        uint128 limitX64 = _fillLimit(vault, isBuy, isBuy ? sqrtLowerX96 : sqrtUpperX96);
        (paid, received) = MetricVenue.swapExactInToLimit(vault, vaultId, !isBuy, waiting, limitX64);
        // Checked after the pool call: MetricLendingVault's nonReentrant lock is held, so nothing ran in between.
        if (received == 0) revert IMakerBook.NotFillable();
        netReceived = received - received * vault.book.settings.fillRewardBps / MakerMath.BPS;
        _requireFillPrice(isBuy, paid, netReceived, sqrtLowerX96, sqrtUpperX96);
    }

    /// @dev A buy level fills only once the ask is at or below its bottom; a sell level once the bid is at or above
    /// its top.
    function _requirePassed(Vault storage vault, bool isBuy, uint160 sqrtLowerX96, uint160 sqrtUpperX96) private {
        (uint160 sqrtBidX96, uint160 sqrtAskX96) = VaultPricing.band(vault);
        if (isBuy) {
            if (sqrtAskX96 > sqrtLowerX96) revert IMakerBook.NotFillable();
            return;
        }
        if (sqrtBidX96 < sqrtUpperX96) revert IMakerBook.NotFillable();
    }

    /// @dev The pool's limit, net of the keeper's reward: a buy pays at most `P_lower · (1 − reward)` gross, so the
    /// makers pay at most `P_lower` net; a sell receives at least `P_upper / (1 − reward)` gross.
    function _fillLimit(Vault storage vault, bool isBuy, uint160 sqrtLimitX96) private view returns (uint128) {
        uint256 rewardBps = vault.book.settings.fillRewardBps;
        uint256 scale0 = vault.venue.scale0;
        uint256 scale1 = vault.venue.scale1;
        if (isBuy) {
            uint256 ceilingX64 = MakerMath.toPriceX64(sqrtLimitX96, scale0, scale1, false);
            return (ceilingX64 * (MakerMath.BPS - rewardBps) / MakerMath.BPS).toUint128();
        }
        uint256 floorX64 = MakerMath.toPriceX64(sqrtLimitX96, scale0, scale1, true);
        uint256 grossFloorX64 = FullMath.mulDivRoundingUp(floorX64, MakerMath.BPS, MakerMath.BPS - rewardBps);
        return grossFloorX64 > type(uint128).max ? type(uint128).max : uint128(grossFloorX64);
    }

    /// @dev The makers' net price, checked on what the swap actually took and gave: a buy's token0 at the level's
    /// bottom covers what it paid, and a sell's token1 covers its token0 at the level's top.
    function _requireFillPrice(
        bool isBuy,
        uint256 paid,
        uint256 netReceived,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96
    ) private pure {
        if (isBuy) {
            if (VaultMath.priceTimes(netReceived, sqrtLowerX96, false) < paid) {
                revert IMetricLendingVault.SlippageExceeded();
            }
            return;
        }
        if (netReceived < VaultMath.priceTimes(paid, sqrtUpperX96, true)) {
            revert IMetricLendingVault.SlippageExceeded();
        }
    }

    function _settleFill(Book storage book, Bucket storage bucket, bool isBuy, uint256 paid, uint256 netReceived)
        private
    {
        if (isBuy) {
            _subtractBalance(book, bucket, 0, paid);
            _addBalance(book, bucket, netReceived, 0);
            return;
        }
        _subtractBalance(book, bucket, paid, 0);
        _addBalance(book, bucket, 0, netReceived);
    }

    /// @dev Retires the bucket at its first fill; if it was taking deposits, the next generation takes them.
    function _retire(Book storage book, Bucket storage bucket, uint256 bucketId) private {
        if (bucket.retired) return;
        bucket.retired = true;
        (int24 level, bool isBuy, uint32 generation) = MakerMath.decode(bucketId);
        uint256 key = MakerMath.levelKey(level, isBuy);
        if (book.generations[key] == generation) book.generations[key] = generation + 1;
    }

    // ---------------------------------------------------------------- shares and balances

    function _mint(Book storage book, Bucket storage bucket, uint256 bucketId, address maker, uint256 shares) private {
        MakerShare storage holding = book.shares[bucketId][maker];
        MakerAccounting.accrueMaker(bucket, holding);
        holding.shares += shares;
        bucket.totalShares += shares;
    }

    /// @dev Income still vesting belongs to whoever holds shares as it vests, so a maker who leaves forgoes theirs, as the
    /// vault's lenders do. When the last shares leave no one is left to earn it, and a retired bucket never mints again,
    /// so it goes to the treasury rather than waiting (Sol's findings: stranded income, then last-holder capture).
    function _burn(Vault storage vault, Bucket storage bucket, uint256 bucketId, address maker, uint256 shares)
        private
    {
        Book storage book = vault.book;
        MakerShare storage holding = book.shares[bucketId][maker];
        MakerAccounting.accrueMaker(bucket, holding);
        holding.shares -= shares;
        bucket.totalShares -= shares;
        if (bucket.totalShares == 0) MakerAccounting.forfeitStreams(vault, bucket);
    }

    function _addBalance(Book storage book, Bucket storage bucket, uint256 amount0, uint256 amount1) private {
        bucket.balance0 = (bucket.balance0 + amount0).toUint128();
        bucket.balance1 = (bucket.balance1 + amount1).toUint128();
        book.balance0 = (book.balance0 + amount0).toUint128();
        book.balance1 = (book.balance1 + amount1).toUint128();
    }

    function _subtractBalance(Book storage book, Bucket storage bucket, uint256 amount0, uint256 amount1) private {
        bucket.balance0 -= amount0.toUint128();
        bucket.balance1 -= amount1.toUint128();
        book.balance0 -= amount0.toUint128();
        book.balance1 -= amount1.toUint128();
    }

    // ---------------------------------------------------------------- validation

    function _validateSettings(BookSettings calldata settings) private pure {
        if (settings.levelTicks == 0) revert IMetricLendingVault.InvalidParameters();
        if (settings.levelTicks > MAX_LEVEL_TICKS) revert IMetricLendingVault.InvalidParameters();
        if (settings.utilizationCeilingBps == 0) revert IMetricLendingVault.InvalidParameters();
        if (settings.utilizationCeilingBps > MakerMath.BPS) revert IMetricLendingVault.InvalidParameters();
        if (settings.fillRewardBps > MAX_FILL_REWARD_BPS) revert IMetricLendingVault.InvalidParameters();
        if (settings.graceSeconds > MAX_PERIOD_SECONDS) revert IMetricLendingVault.InvalidParameters();
        if (settings.minimumEscrowSeconds > MAX_PERIOD_SECONDS) revert IMetricLendingVault.InvalidParameters();
        if (settings.minimumChargeSeconds > MAX_PERIOD_SECONDS) revert IMetricLendingVault.InvalidParameters();
        if (settings.minimumNotional == 0) revert IMetricLendingVault.InvalidParameters();
    }

    /// @dev At the utilization ceiling a borrower must pay at least `MIN_CEILING_RATE_WAD`, so one cannot hold makers'
    /// last idle capital for free (audit finding C2).
    function _pushCurve(Book storage book, Curve calldata curve) private {
        if (curve.kinkWad == 0) revert IMetricLendingVault.InvalidParameters();
        if (curve.kinkWad >= MakerMath.WAD) revert IMetricLendingVault.InvalidParameters();
        uint256 ceilingBps = book.settings.utilizationCeilingBps;
        if (VaultMath.rateWad(curve, ceilingBps, MakerMath.BPS) < MIN_CEILING_RATE_WAD) {
            revert IMetricLendingVault.InvalidParameters();
        }
        book.curves.push();
        book.curves[book.curves.length - 1].curve = curve;
        book.curves[book.curves.length - 1].startedAt = uint40(block.timestamp);
    }

    /// @dev Rows run from the farthest distance down to a last row at zero, strictly descending, so every distance
    /// matches exactly one row.
    function _pushFloorTable(Book storage book, FloorRow[] calldata rows) private {
        uint256 count = rows.length;
        if (count == 0) revert IMetricLendingVault.InvalidParameters();
        if (count > MakerMath.MAX_FLOOR_ROWS) revert IMetricLendingVault.InvalidParameters();
        if (rows[count - 1].minimumDistanceBps != 0) revert IMetricLendingVault.InvalidParameters();
        book.floorTables.push();
        uint256 version = book.floorTables.length - 1;
        book.floorTables[version].startedAt = uint40(block.timestamp);
        // count <= MAX_FLOOR_ROWS
        for (uint256 index = 1; index < count; ++index) {
            if (rows[index].minimumDistanceBps >= rows[index - 1].minimumDistanceBps) {
                revert IMetricLendingVault.InvalidParameters();
            }
        }
        // count <= MAX_FLOOR_ROWS
        for (uint256 index = 0; index < count; ++index) {
            if (rows[index].rateBps > MAX_FLOOR_RATE_BPS) revert IMetricLendingVault.InvalidParameters();
            book.floorTables[version].rows.push(rows[index]);
        }
    }

    function _vault(VaultStore storage store, uint256 vaultId) private view returns (Vault storage) {
        if (vaultId == 0) revert IMetricLendingVault.UnknownVault();
        if (vaultId > store.vaultCount) revert IMetricLendingVault.UnknownVault();
        return store.vaults[vaultId];
    }

    function _book(Vault storage vault) private view returns (Book storage book) {
        book = vault.book;
        if (!book.enabled) revert IMakerBook.BookDisabled();
    }
}
