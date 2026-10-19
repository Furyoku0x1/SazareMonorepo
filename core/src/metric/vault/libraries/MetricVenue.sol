// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ExitSwap, Vault, VaultStore} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {IMetricPool, LiquidityDelta} from "../interfaces/IMetricPool.sol";
import {ISwapVenue} from "../interfaces/ISwapVenue.sol";
import {MetricPrice} from "./MetricPrice.sol";
import {MetricState} from "./MetricState.sol";
import {VaultCallback} from "./VaultCallback.sol";
import {VaultLedger} from "./VaultLedger.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultPricing} from "./VaultPricing.sol";
import {VenueSwap} from "./VenueSwap.sol";

/// @notice The vault's idle capital in its Metric pool: placement around the oracle reference, twice as much in the
/// nearest bin on each side as in the others, withdrawal from the edges, and reads of what the position holds.
/// @dev A linked library: its public functions are delegatecalled from the vault's other libraries, so they run in the
/// singleton's context and keep the callers small. Every bin the vault holds lies in its window: the `binCount / 2`
/// bins on each side of the bin holding the reference. Token0 goes only to bins above both the reference and the
/// cursor, token1 only to bins below both, since Metric picks a deposit's token by the bin's side of the cursor at the
/// moment of the add. The active bin, when it lies in the window, takes its weight in both tokens, in the bin's own
/// ratio (owner, 2026-10-19). Withdrawals take the farthest bins first and leave the active bin to last.
library MetricVenue {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @dev The most bins `binCount` may name; fits its uint8. The window holds at most `MAX_BINS + 1` bins, since the
    /// bin holding the reference is an extra middle bin, which bounds every loop over it. The first placement's search
    /// for the reference also stops after `MAX_BINS` bins: a reference farther from the cursor leaves the window unset
    /// and the buffer unplaced until a later action finds it.
    uint256 internal constant MAX_BINS = 32;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant E18 = 1e18;

    /// @dev The vault's Metric position as held and as anchored at the reference; a struct keeps the stack shallow.
    struct Holdings {
        uint256 amount0;
        uint256 amount1;
        uint256 anchored0;
        uint256 anchored1;
    }

    struct Plan {
        int256[] bins;
        uint256[] shares;
        uint256 count;
        uint256 cost0;
        uint256 cost1;
    }

    /// @notice Updates the cached holdings from the pool, and the holdings premium rates read: the same position as it
    /// would be with the pool at the reference, converted at the close band's bid, which no swap or pool setting moves.
    /// A no-op without a pool. Without a quote, including inside a Metric callback where the pool is mid-swap, the
    /// anchored holdings keep their last value: read as held, a swap's callback could skew them (audit finding X-3).
    function refresh(Vault storage vault, uint256 vaultId) public {
        address pool = vault.parameters.pool;
        if (pool == address(0)) return;
        (bool priced, uint160 sqrtBidX96) =
            MetricPrice.peekBidWithoutAdminFees(pool, vault.venue.scale0, vault.venue.scale1);
        Holdings memory read = _holdings(vault, vaultId, priced, sqrtBidX96);
        vault.venue.holdings0 = read.amount0.toUint128();
        vault.venue.holdings1 = read.amount1.toUint128();
        if (!priced) return;
        vault.venue.rateHoldings0 = read.anchored0.toUint128();
        vault.venue.rateHoldings1 = read.anchored1.toUint128();
    }

    /// @dev What the vault's Metric position holds now, in native units, rounded down, and the anchored amounts.
    function _holdings(Vault storage vault, uint256 vaultId, bool priced, uint160 sqrtBidX96)
        private
        view
        returns (Holdings memory read)
    {
        if (!vault.venue.windowSet) return read;
        uint256 count = _windowBins(vault);
        // count <= MAX_BINS + 1
        for (uint256 offset = 0; offset < count; ++offset) {
            int256 binIndex = int256(vault.venue.lowestBin) + int256(offset);
            (uint256 bin0, uint256 bin1) = _binHoldings(vault, vaultId, int16(binIndex));
            read.amount0 += bin0;
            read.amount1 += bin1;
            // Without a price nothing is anchored; the caller keeps the last anchored holdings.
            if (priced) _anchor(read, _side(vault, binIndex), bin0, bin1, sqrtBidX96);
        }
    }

    function _binHoldings(Vault storage vault, uint256 vaultId, int16 binIndex)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        address pool = vault.parameters.pool;
        uint256 ours = MetricState.positionShares(pool, address(this), uint80(vaultId), binIndex);
        if (ours == 0) return (0, 0);
        MetricState.Bin memory state = MetricState.bin(pool, binIndex);
        amount0 = FullMath.mulDiv(ours, state.balance0Scaled, state.totalShares) / vault.venue.scale0;
        amount1 = FullMath.mulDiv(ours, state.balance1Scaled, state.totalShares) / vault.venue.scale1;
    }

    /// @dev A bin's side of the recorded reference: 1 above it (token0 at the reference), -1 below it (token1), 0 for the
    /// bin that contains it, which straddles the price and takes nothing.
    function _side(Vault storage vault, int256 binIndex) private view returns (int256) {
        int256 referenceBin = vault.venue.referenceBin;
        if (binIndex > referenceBin) return 1;
        if (binIndex < referenceBin) return -1;
        return vault.venue.referenceOnEdge ? int256(1) : int256(0);
    }

    /// @dev Adds a bin to the anchored amounts: with the pool at the reference, a bin above it holds only token0 and a
    /// bin below only token1, so a push that trades the vault's bins cannot move them (audit finding X-3).
    function _anchor(Holdings memory read, int256 side, uint256 bin0, uint256 bin1, uint160 sqrtBidX96) private pure {
        if (side == 0) return _asHeld(read, bin0, bin1);
        if (side > 0) {
            read.anchored0 += bin0 + VaultPricing.token0At(sqrtBidX96, bin1);
            return;
        }
        read.anchored1 += bin1 + VaultMath.priceTimes(bin0, sqrtBidX96, false);
    }

    function _asHeld(Holdings memory read, uint256 bin0, uint256 bin1) private pure {
        read.anchored0 += bin0;
        read.anchored1 += bin1;
    }

    /// @notice Places the lenders' buffer in the window's bins. What a bin cannot take (below Metric's minimum share
    /// delta, or past the weight cap) stays in the buffer. Every action that moves the vault's Metric holdings ends
    /// here, so the holdings are re-read last: the next accrual interval samples them after the action's own swaps and
    /// placement.
    /// @dev Places whatever the cursor's position: token0 only above both the reference and the cursor, token1 only
    /// below both, so a pushed cursor can never make the vault place base below the oracle price or quote above it
    /// (audit finding X-1). The window never needs to move: it is set once around the bin holding the reference, and
    /// Metric's bins keep their distance from the reference, so the window follows the oracle by itself.
    function place(Vault storage vault, uint256 vaultId) public {
        address pool = vault.parameters.pool;
        if (pool == address(0)) return;
        MetricState.Cursor memory current = MetricState.cursor(pool);
        _ensureWindow(vault, pool, current);
        if (vault.venue.windowSet) _place(vault, vaultId, current.binIndex);
        refresh(vault, vaultId);
    }

    /// @dev Records where the reference lies and sets the window around it, once. Metric's bins never move against the
    /// reference, so both hold for the pool's life. The window is cut at the pool's bins, never shifted, so each bin
    /// keeps its distance from the reference.
    function _ensureWindow(Vault storage vault, address pool, MetricState.Cursor memory current) private {
        if (vault.venue.windowSet) return;
        (bool found, int256 referenceBin, bool onEdge) = _findReference(vault, pool, current);
        if (!found) return;
        int256 half = int256(uint256(vault.parameters.binCount / 2));
        // With the reference inside a bin, that bin is the window's empty middle; on an edge, there is none.
        int256 highest = onEdge ? referenceBin + half - 1 : referenceBin + half;
        vault.venue.referenceBin = int16(referenceBin);
        vault.venue.referenceOnEdge = onEdge;
        vault.venue.lowestBin = int16(_maxSigned(referenceBin - half, vault.venue.poolLowestBin));
        vault.venue.highestBin = int16(_minSigned(highest, vault.venue.poolHighestBin));
        vault.venue.windowSet = true;
    }

    /// @dev The bin holding the oracle reference, found from the cursor's bin by summing bin lengths: Metric prices
    /// every bin at a fixed distance from the reference, so the reference lies where the distance crosses zero. When it
    /// lies on a bin edge, the first bin above it, `onEdge`. Not found more than `MAX_BINS` bins away, or past the
    /// pool's bins.
    function _findReference(Vault storage vault, address pool, MetricState.Cursor memory current)
        private
        view
        returns (bool, int256, bool)
    {
        if (current.binDistanceE6 > 0) return _walkDown(vault, pool, current.binIndex, current.binDistanceE6);
        return _walkUp(vault, pool, current.binIndex, current.binDistanceE6);
    }

    /// @dev From a bin whose lower edge is at or below the reference, up to the bin holding it.
    function _walkUp(Vault storage vault, address pool, int256 binIndex, int256 lowerEdgeE6)
        private
        view
        returns (bool, int256, bool)
    {
        // step < MAX_BINS
        for (uint256 step = 0; step < MAX_BINS; ++step) {
            if (binIndex > vault.venue.poolHighestBin) return (false, 0, false);
            int256 upperEdgeE6 = lowerEdgeE6 + int256(uint256(MetricState.bin(pool, int16(binIndex)).lengthE6));
            if (upperEdgeE6 > 0) return (true, binIndex, lowerEdgeE6 == 0);
            binIndex += 1;
            lowerEdgeE6 = upperEdgeE6;
        }
        return (false, 0, false);
    }

    /// @dev From a bin whose lower edge is above the reference, down to the bin holding it.
    function _walkDown(Vault storage vault, address pool, int256 binIndex, int256 lowerEdgeE6)
        private
        view
        returns (bool, int256, bool)
    {
        // step < MAX_BINS
        for (uint256 step = 0; step < MAX_BINS; ++step) {
            binIndex -= 1;
            if (binIndex < vault.venue.poolLowestBin) return (false, 0, false);
            lowerEdgeE6 -= int256(uint256(MetricState.bin(pool, int16(binIndex)).lengthE6));
            if (lowerEdgeE6 <= 0) return (true, binIndex, lowerEdgeE6 == 0);
        }
        return (false, 0, false);
    }

    /// @dev Never reverts on the pool's account, so placement never blocks the action that calls it, closes included.
    function _place(Vault storage vault, uint256 vaultId, int16 activeBin) private {
        address pool = vault.parameters.pool;
        Plan memory plan = _plan(vault, vaultId, activeBin);
        if (plan.count == 0) return;
        _trim(plan);
        VaultCallback.expect(pool, vaultId, plan.cost0, plan.cost1);
        (uint256 before0, uint256 before1) = _balances(vault);
        // If the pool refuses the add, the tokens simply stay in the buffer until a later placement.
        try IMetricPool(pool)
            .addLiquidity(address(this), uint80(vaultId), LiquidityDelta(plan.bins, plan.shares), "", "") returns (
            uint256, uint256
        ) {}
        catch {
            VaultCallback.clear();
            return;
        }
        VaultCallback.clear();
        // What the callback actually paid, at most the plan's costs, not what the pool reports (audit finding B1).
        (uint256 after0, uint256 after1) = _balances(vault);
        uint256 added0 = before0 - after0;
        uint256 added1 = before1 - after1;
        vault.ledger.buffer0 -= added0.toUint128();
        vault.ledger.buffer1 -= added1.toUint128();
        VaultLedger.debit(vault, 0, added0);
        VaultLedger.debit(vault, 1, added1);
        vault.venue.holdings0 += added0.toUint128();
        vault.venue.holdings1 += added1.toUint128();
    }

    /// @notice Removes liquidity until the buffer holds `need0` and `need1`, farthest bins first. Returns whether it
    /// does. Removal rounds shares up and may take a whole bin, so the buffer can end with more than needed.
    function gather(Vault storage vault, uint256 vaultId, uint256 need0, uint256 need1) public returns (bool) {
        uint256 short0 = need0 > vault.ledger.buffer0 ? need0 - vault.ledger.buffer0 : 0;
        uint256 short1 = need1 > vault.ledger.buffer1 ? need1 - vault.ledger.buffer1 : 0;
        if (short0 == 0) {
            if (short1 == 0) return true;
        }
        if (vault.parameters.pool == address(0)) return false;
        if (!vault.venue.windowSet) return false;
        int16 activeBin = MetricState.cursor(vault.parameters.pool).binIndex;
        Plan memory plan = _emptyPlan();
        short0 = _gatherSide(vault, vaultId, activeBin, plan, 0, short0);
        short1 = _gatherSide(vault, vaultId, activeBin, plan, 1, short1);
        _gatherActive(vault, vaultId, activeBin, plan, short0, short1);
        _remove(vault, vaultId, plan);
        // An open's escrow check reads rates right after its release: they must count what just left (X-3).
        refresh(vault, vaultId);
        return vault.ledger.buffer0 >= need0 && vault.ledger.buffer1 >= need1;
    }

    function _inWindow(Vault storage vault, int256 binIndex) private view returns (bool) {
        if (binIndex < vault.venue.lowestBin) return false;
        return binIndex <= vault.venue.highestBin;
    }

    /// @dev The window's bins: `binCount` with the reference on a bin edge, one more with it inside a bin, fewer where
    /// the pool's bins end.
    function _windowBins(Vault storage vault) private view returns (uint256) {
        return uint256(int256(vault.venue.highestBin) - vault.venue.lowestBin + 1);
    }

    // ---------------------------------------------------------------- swaps

    /// @notice Sells up to `amountIn` of one token for the other through the pool, from tokens the vault holds.
    /// Metric fills partially when depth runs out, so this returns what was actually paid and received. Reverts below
    /// `minimumOut`.
    function swapExactIn(Vault storage vault, uint256 vaultId, bool zeroForOne, uint256 amountIn, uint256 minimumOut)
        public
        returns (uint256 paid, uint256 received)
    {
        address pool = vault.parameters.pool;
        VaultCallback.expect(pool, vaultId, zeroForOne ? amountIn : 0, zeroForOne ? 0 : amountIn);
        // No price limit: zero for a sell, the maximum for a buy (Metric reads a buy's zero limit as a ceiling).
        uint128 limitX64 = zeroForOne ? 0 : type(uint128).max;
        (uint256 before0, uint256 before1) = _balances(vault);
        IMetricPool(pool).swap(address(this), zeroForOne, amountIn.toInt256().toInt128(), limitX64, "", "");
        VaultCallback.clear();
        (paid, received) = _settleSwap(vault, zeroForOne, before0, before1);
        // Checked after the pool call: the singleton's reentrancy lock is still held, so nothing ran in between.
        if (received < minimumOut) revert IMetricLendingVault.SlippageExceeded();
    }

    /// @notice Sells up to `amountIn` of one token for the other, stopping where the pool's effective price, fees
    /// included, reaches `limitX64`: a floor for a sell, a ceiling for a buy. Partial fills stand; the caller checks
    /// the price it got.
    function swapExactInToLimit(
        Vault storage vault,
        uint256 vaultId,
        bool zeroForOne,
        uint256 amountIn,
        uint128 limitX64
    ) public returns (uint256 paid, uint256 received) {
        address pool = vault.parameters.pool;
        VaultCallback.expect(pool, vaultId, zeroForOne ? amountIn : 0, zeroForOne ? 0 : amountIn);
        (uint256 before0, uint256 before1) = _balances(vault);
        IMetricPool(pool).swap(address(this), zeroForOne, amountIn.toInt256().toInt128(), limitX64, "", "");
        VaultCallback.clear();
        (paid, received) = _settleSwap(vault, zeroForOne, before0, before1);
    }

    /// @notice As `swapExactInToLimit`, but never reverts on the pool's account: a swap the pool refuses moves nothing
    /// and returns zeros. For best-effort trades, such as a close's restore, that must not hold the close up.
    function trySwapExactInToLimit(
        Vault storage vault,
        uint256 vaultId,
        bool zeroForOne,
        uint256 amountIn,
        uint128 limitX64
    ) public returns (uint256 paid, uint256 received) {
        // Too large for Metric's signed amount: nothing is traded rather than revert (audit finding C4).
        if (amountIn > uint256(uint128(type(int128).max))) return (0, 0);
        address pool = vault.parameters.pool;
        VaultCallback.expect(pool, vaultId, zeroForOne ? amountIn : 0, zeroForOne ? 0 : amountIn);
        (uint256 before0, uint256 before1) = _balances(vault);
        try IMetricPool(pool).swap(address(this), zeroForOne, int128(int256(amountIn)), limitX64, "", "") returns (
            int128, int128
        ) {
            VaultCallback.clear();
            return _settleSwap(vault, zeroForOne, before0, before1);
        } catch {
            VaultCallback.clear();
            return (0, 0);
        }
    }

    /// @notice Buys exactly `amountOut` of one token, paying at most `maximumIn` of the other, through the pool. Never
    /// reverts on the pool's account: the callback refuses a partial fill, so a swap either fills in full or moves
    /// nothing and reports `ok = false`, and the force close decides whether to wait or scale.
    function trySwapExactOut(
        Vault storage vault,
        uint256 vaultId,
        bool zeroForOne,
        uint256 amountOut,
        uint256 maximumIn
    ) public returns (bool ok, uint256 paid, uint256 received) {
        // Too large for Metric's signed amount: the caller's fallback applies rather than a revert (audit finding C4).
        if (amountOut > uint256(uint128(type(int128).max))) return (false, 0, 0);
        address pool = vault.parameters.pool;
        (uint256 before0, uint256 before1) = _balances(vault);
        VaultCallback.expect(pool, vaultId, zeroForOne ? maximumIn : 0, zeroForOne ? 0 : maximumIn);
        VaultCallback.expectOutput(zeroForOne ? 0 : amountOut, zeroForOne ? amountOut : 0, before0, before1);
        // No price limit: zero for a sell, the maximum for a buy.
        uint128 limitX64 = zeroForOne ? 0 : type(uint128).max;
        int128 amountSpecified = -int128(int256(amountOut));
        try IMetricPool(pool).swap(address(this), zeroForOne, amountSpecified, limitX64, "", "") returns (
            int128, int128
        ) {
            VaultCallback.clear();
            (paid, received) = _settleSwap(vault, zeroForOne, before0, before1);
            // The callback refused anything short of `amountOut` arriving, so a swap that returned filled in full.
            assert(received >= amountOut);
            return (true, paid, received);
        } catch {
            VaultCallback.clear();
            return (false, 0, 0);
        }
    }

    // ---------------------------------------------------------------- Metric callbacks

    /// @notice The singleton's `metricOmmModifyLiquidityCallback`: pays the pool for a placement the vault expected,
    /// no more than it expected. Here rather than in the singleton for its size; delegatecalled, so `msg.sender` is
    /// still the pool and the expectation's transient slots are the singleton's.
    function payLiquidityCallback(VaultStore storage store, uint256 amount0, uint256 amount1) public {
        (uint256 vaultId, uint256 maximum0, uint256 maximum1) = _takeCallback();
        if (amount0 > maximum0) revert IMetricLendingVault.UnexpectedCallback();
        if (amount1 > maximum1) revert IMetricLendingVault.UnexpectedCallback();
        _payPool(store.vaults[vaultId], amount0, amount1);
    }

    /// @notice The singleton's `metricOmmSwapCallback`: pays the pool for a swap the vault expected, no more than it
    /// expected, once at least the expected output has arrived.
    function paySwapCallback(VaultStore storage store, int256 amount0Delta, int256 amount1Delta) public {
        (uint256 minimumOut0, uint256 minimumOut1) = VaultCallback.minimumOutputs();
        (uint256 vaultId, uint256 maximum0, uint256 maximum1) = _takeCallback();
        uint256 owed0 = amount0Delta > 0 ? uint256(amount0Delta) : 0;
        uint256 owed1 = amount1Delta > 0 ? uint256(amount1Delta) : 0;
        uint256 output0 = amount0Delta < 0 ? uint256(-amount0Delta) : 0;
        uint256 output1 = amount1Delta < 0 ? uint256(-amount1Delta) : 0;
        if (owed0 > maximum0) revert IMetricLendingVault.UnexpectedCallback();
        if (owed1 > maximum1) revert IMetricLendingVault.UnexpectedCallback();
        // A partial fill reverts here, undoing the whole swap.
        if (output0 < minimumOut0) revert IMetricLendingVault.SlippageExceeded();
        if (output1 < minimumOut1) revert IMetricLendingVault.SlippageExceeded();
        Vault storage vault = store.vaults[vaultId];
        _requireArrived(vault, minimumOut0, minimumOut1);
        _payPool(vault, owed0, owed1);
    }

    function _takeCallback() private returns (uint256 vaultId, uint256 maximum0, uint256 maximum1) {
        bool ok;
        (ok, vaultId, maximum0, maximum1) = VaultCallback.take(msg.sender);
        if (!ok) revert IMetricLendingVault.UnexpectedCallback();
    }

    /// @dev The caller's library records the ledger debit once the pool call returns, from the amounts the pool
    /// reports; this only moves the tokens.
    function _payPool(Vault storage vault, uint256 amount0, uint256 amount1) private {
        _payExactly(vault.parameters.token0, amount0);
        _payExactly(vault.parameters.token1, amount1);
    }

    /// @dev Pays the calling pool and requires custody to fall by exactly `amount`: a token that took more from the
    /// sender would leave the other vaults' tokens short (audit finding B2).
    function _payExactly(address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        SafeERC20.safeTransfer(IERC20(token), msg.sender, amount);
        // Checked after the transfer: the singleton's lock is held, so nothing else moved the balance.
        if (balanceBefore - IERC20(token).balanceOf(address(this)) != amount) {
            revert IMetricLendingVault.UnexpectedCallback();
        }
    }

    /// @dev Requires a minimum output to have actually arrived, not merely to be reported, measured from the balances
    /// saved before the swap: Metric pays the output before it calls back (audit finding B2).
    function _requireArrived(Vault storage vault, uint256 minimumOut0, uint256 minimumOut1) private view {
        (uint256 balance0Before, uint256 balance1Before) = VaultCallback.balancesBefore();
        uint256 balance0 = IERC20(vault.parameters.token0).balanceOf(address(this));
        uint256 balance1 = IERC20(vault.parameters.token1).balanceOf(address(this));
        uint256 arrived0 = balance0 > balance0Before ? balance0 - balance0Before : 0;
        uint256 arrived1 = balance1 > balance1Before ? balance1 - balance1Before : 0;
        if (arrived0 < minimumOut0) revert IMetricLendingVault.SlippageExceeded();
        if (arrived1 < minimumOut1) revert IMetricLendingVault.SlippageExceeded();
    }

    // ---------------------------------------------------------------- named venues

    /// @notice A trader's swap for their own position: through the vault's pool when `trade.venue` is zero, otherwise
    /// through the venue they named. Returns what was paid and received, and what the fill lost against the band,
    /// which the caller counts as taken out of the position.
    function swapForTrader(Vault storage vault, uint256 vaultId, VenueSwap.Trade memory trade, bytes memory route)
        public
        returns (uint256 paid, uint256 received, uint256 lost)
    {
        (paid, received) = trade.venue == address(0)
            ? _traderThroughPool(vault, vaultId, trade)
            : _traderThroughVenue(vault, trade, route);
        lost = VenueSwap.shortfall(trade, paid, received);
    }

    /// @notice A keeper's swap of a position's reserves for exactly the `amountOut` its repayment lacks: through the
    /// vault's pool when `venue` is zero, otherwise through the venue the keeper named, which is sent `maximumIn`, the
    /// most the pool swap could spend, and must send back at least `amountOut`. Returns whether it filled; an unfilled
    /// swap through a venue has moved tokens, so the caller must revert.
    function swapForKeeper(
        Vault storage vault,
        uint256 vaultId,
        bool zeroForOne,
        uint256 amountOut,
        uint256 maximumIn,
        address venue,
        bytes memory route
    ) public returns (bool filled, uint256 paid, uint256 received) {
        if (venue == address(0)) {
            return trySwapExactOut(vault, vaultId, zeroForOne, amountOut, maximumIn);
        }
        (paid, received) = swapThroughVenue(vault, zeroForOne, maximumIn, venue, route);
        filled = received >= amountOut;
    }

    /// @notice Swaps part of a payout leaving the vault, its owner's tokens, through the venue they name (the pool when
    /// none): `swap.amountIn` of the token sold, at most what the payout holds of it, for at least `swap.minimumOut`.
    /// Returns the payout as the swap left it.
    function swapPayout(Vault storage vault, uint256 vaultId, ExitSwap memory swap, uint256 amount0, uint256 amount1)
        public
        returns (uint256, uint256)
    {
        if (swap.amountIn == 0) return (amount0, amount1);
        uint256 held = swap.zeroForOne ? amount0 : amount1;
        if (swap.amountIn > held) revert IMetricLendingVault.InvalidParameters();
        VenueSwap.Trade memory trade;
        trade.zeroForOne = swap.zeroForOne;
        trade.amountIn = swap.amountIn;
        trade.minimumOut = swap.minimumOut;
        trade.venue = swap.venue;
        (uint256 paid, uint256 received) = trade.venue == address(0)
            ? _traderThroughPool(vault, vaultId, trade)
            : _traderThroughVenue(vault, trade, swap.route);
        if (swap.zeroForOne) return (amount0 - paid, amount1 + received);
        return (amount0 + received, amount1 - paid);
    }

    /// @notice A close's exit swap on the closed part of the reserves, which holds `closedHeld` of the token sold. It is
    /// measured at the close band, the band the profit share values leftovers at, and so needs it.
    function exitSwap(Vault storage vault, uint256 vaultId, ExitSwap memory exit, uint256 closedHeld)
        public
        returns (uint256 paid, uint256 received, uint256 lost)
    {
        if (exit.amountIn > closedHeld) revert IMetricLendingVault.InvalidParameters();
        (bool ok, uint160 sqrtBidX96, uint160 sqrtAskX96) = VaultPricing.tryCloseBand(vault);
        if (!ok) revert IMetricLendingVault.InvalidBand();
        VenueSwap.Trade memory trade = VenueSwap.Trade({
            zeroForOne: exit.zeroForOne,
            amountIn: exit.amountIn,
            minimumOut: exit.minimumOut,
            venue: exit.venue,
            sqrtBidX96: sqrtBidX96,
            sqrtAskX96: sqrtAskX96
        });
        return swapForTrader(vault, vaultId, trade, exit.route);
    }

    function _traderThroughPool(Vault storage vault, uint256 vaultId, VenueSwap.Trade memory trade)
        private
        returns (uint256, uint256)
    {
        if (vault.parameters.pool == address(0)) revert IMetricLendingVault.InvalidParameters();
        return swapExactIn(vault, vaultId, trade.zeroForOne, trade.amountIn, trade.minimumOut);
    }

    function _traderThroughVenue(Vault storage vault, VenueSwap.Trade memory trade, bytes memory route)
        private
        returns (uint256 paid, uint256 received)
    {
        (paid, received) = swapThroughVenue(vault, trade.zeroForOne, trade.amountIn, trade.venue, route);
        if (received < trade.minimumOut) revert IMetricLendingVault.SlippageExceeded();
    }

    /// @notice Sells up to `amountIn` of one token for the other through a venue someone names (`ISwapVenue`): an
    /// aggregator's adapter, a router, anything. Sends it the input, lets it trade, and measures what came back: the
    /// output, and whatever input it did not spend. The singleton's lock is held, so the venue cannot re-enter it, and
    /// the vault grants no allowance, so its balances move only by what the venue sends back. Callers judge the fill.
    function swapThroughVenue(Vault storage vault, bool zeroForOne, uint256 amountIn, address venue, bytes memory route)
        public
        returns (uint256 paid, uint256 received)
    {
        _requireOutsider(vault, venue);
        uint256 indexIn = zeroForOne ? 0 : 1;
        uint256 indexOut = 1 - indexIn;
        IERC20 tokenIn = IERC20(VaultLedger.tokenOf(vault, indexIn));
        IERC20 tokenOut = IERC20(VaultLedger.tokenOf(vault, indexOut));
        uint256 inBefore = tokenIn.balanceOf(address(this));
        uint256 outBefore = tokenOut.balanceOf(address(this));
        // No Metric callback may be pending while foreign code runs, or a venue trading through the pool could collect it.
        VaultCallback.clear();
        VaultLedger.push(vault, indexIn, venue, amountIn);
        ISwapVenue(venue).swapForVault(address(tokenIn), address(tokenOut), amountIn, route);
        uint256 unspent = tokenIn.balanceOf(address(this)) + amountIn - inBefore;
        // Underflows, and so reverts, if the venue sent back more input than it was given.
        paid = amountIn - unspent;
        received = tokenOut.balanceOf(address(this)) - outBefore;
        VaultLedger.credit(vault, indexIn, unspent);
        VaultLedger.credit(vault, indexOut, received);
    }

    /// @dev The vault calls the venue on someone's word, so it may not be one of the vault's tokens, its pool or the
    /// vault itself. The venue's selector matches none of their functions; this keeps it so should one ever gain it.
    function _requireOutsider(Vault storage vault, address venue) private view {
        if (venue == vault.parameters.token0) revert IMetricLendingVault.InvalidParameters();
        if (venue == vault.parameters.token1) revert IMetricLendingVault.InvalidParameters();
        if (venue == vault.parameters.pool) revert IMetricLendingVault.InvalidParameters();
        if (venue == address(this)) revert IMetricLendingVault.InvalidParameters();
    }

    /// @dev Records a swap's token movements as the singleton's balances moved, not as the pool reports them, so the
    /// ledger always matches custody (audit findings B1 and B2).
    function _settleSwap(Vault storage vault, bool zeroForOne, uint256 before0, uint256 before1)
        private
        returns (uint256 paid, uint256 received)
    {
        (uint256 after0, uint256 after1) = _balances(vault);
        paid = zeroForOne ? before0 - after0 : before1 - after1;
        received = zeroForOne ? after1 - before1 : after0 - before0;
        VaultLedger.debit(vault, zeroForOne ? 0 : 1, paid);
        VaultLedger.credit(vault, zeroForOne ? 1 : 0, received);
    }

    /// @dev The singleton's balances of the vault's tokens. Pool calls run under the singleton's lock, so a change
    /// across one is that call's alone.
    function _balances(Vault storage vault) private view returns (uint256 balance0, uint256 balance1) {
        balance0 = IERC20(vault.parameters.token0).balanceOf(address(this));
        balance1 = IERC20(vault.parameters.token1).balanceOf(address(this));
    }

    // ---------------------------------------------------------------- placement

    /// @dev Token0 goes to the window's bins above the reference, token1 to those below, the bin next to the reference
    /// taking twice what each other bin takes. Bins on the wrong side of the cursor take nothing, and their share goes
    /// to the side's other bins, so the whole buffer is placed. The active bin also needs the other token, so its side
    /// is planned first and the other side gets what that leaves.
    function _plan(Vault storage vault, uint256 vaultId, int16 activeBin) private view returns (Plan memory plan) {
        plan = _emptyPlan();
        uint256 buffer0 = vault.ledger.buffer0;
        uint256 buffer1 = vault.ledger.buffer1;
        if (_side(vault, activeBin) < 0) {
            _planSide(vault, vaultId, activeBin, plan, 1, buffer1, buffer0);
            _planSide(vault, vaultId, activeBin, plan, 0, buffer0 - plan.cost0, 0);
            return plan;
        }
        _planSide(vault, vaultId, activeBin, plan, 0, buffer0, buffer1);
        _planSide(vault, vaultId, activeBin, plan, 1, buffer1 - plan.cost1, 0);
    }

    /// @dev Places `amount` of one token across its side; `otherBudget` is what the active bin may take of the other.
    function _planSide(
        Vault storage vault,
        uint256 vaultId,
        int16 activeBin,
        Plan memory plan,
        uint256 tokenIndex,
        uint256 amount,
        uint256 otherBudget
    ) private view {
        if (amount == 0) return;
        uint256 totalWeight = _sideWeight(vault, activeBin, tokenIndex);
        if (totalWeight == 0) return;
        uint256 count = _windowBins(vault);
        // count <= MAX_BINS + 1
        for (uint256 offset = 0; offset < count; ++offset) {
            int16 binIndex = int16(int256(vault.venue.lowestBin) + int256(offset));
            uint256 weight = _weight(vault, activeBin, binIndex, tokenIndex);
            if (weight == 0) continue;
            uint256 part = amount * weight / totalWeight;
            if (binIndex == activeBin) _planActive(vault, vaultId, plan, binIndex, tokenIndex, part, otherBudget);
            else _planBin(vault, vaultId, plan, binIndex, tokenIndex, part);
        }
    }

    /// @dev The active bin holds both tokens, and Metric takes both in the bin's ratio. The shares are sized by
    /// `amount` of the side's token and limited by `otherBudget` of the other. Costs round up and shares down, so
    /// neither cost exceeds its budget. Skipped when the bin is empty, since Metric then splits by the cursor's
    /// position, or holds none of the side's token, since the vault would then place only the other token, on the
    /// wrong side.
    function _planActive(
        Vault storage vault,
        uint256 vaultId,
        Plan memory plan,
        int16 binIndex,
        uint256 tokenIndex,
        uint256 amount,
        uint256 otherBudget
    ) private view {
        MetricState.Bin memory state = MetricState.bin(vault.parameters.pool, binIndex);
        if (state.totalShares == 0) return;
        (uint256 balanceScaled, uint256 otherBalanceScaled) = tokenIndex == 0
            ? (state.balance0Scaled, state.balance1Scaled)
            : (state.balance1Scaled, state.balance0Scaled);
        if (balanceScaled == 0) return;
        (uint256 scale, uint256 otherScale) =
            tokenIndex == 0 ? (vault.venue.scale0, vault.venue.scale1) : (vault.venue.scale1, vault.venue.scale0);
        uint256 shares = FullMath.mulDiv(amount * scale, state.totalShares, balanceScaled);
        if (otherBalanceScaled > 0) {
            shares = _min(shares, FullMath.mulDiv(otherBudget * otherScale, state.totalShares, otherBalanceScaled));
        }
        shares = _capped(vault, vaultId, binIndex, state.totalShares, shares);
        if (shares < vault.venue.minimumShares) return;
        _push(plan, binIndex, shares);
        uint256 cost = _costOf(balanceScaled, shares, state.totalShares, scale);
        uint256 otherCost = _costOf(otherBalanceScaled, shares, state.totalShares, otherScale);
        (uint256 cost0, uint256 cost1) = tokenIndex == 0 ? (cost, otherCost) : (otherCost, cost);
        plan.cost0 += cost0;
        plan.cost1 += cost1;
    }

    /// @dev What `shares` of a bin holding `balanceScaled` cost in token units, rounded up as Metric rounds an add.
    function _costOf(uint256 balanceScaled, uint256 shares, uint256 totalShares, uint256 scale)
        private
        pure
        returns (uint256)
    {
        uint256 costScaled = FullMath.mulDivRoundingUp(balanceScaled, shares, totalShares);
        return (costScaled + scale - 1) / scale;
    }

    function _planBin(
        Vault storage vault,
        uint256 vaultId,
        Plan memory plan,
        int16 binIndex,
        uint256 tokenIndex,
        uint256 amount
    ) private view {
        uint256 scale = tokenIndex == 0 ? vault.venue.scale0 : vault.venue.scale1;
        MetricState.Bin memory state = MetricState.bin(vault.parameters.pool, binIndex);
        uint256 balanceScaled = tokenIndex == 0 ? state.balance0Scaled : state.balance1Scaled;
        uint256 shares;
        uint256 costScaled;
        if (state.totalShares == 0) {
            uint256 initialPerShare =
                tokenIndex == 0 ? vault.venue.initial0PerShareE18 : vault.venue.initial1PerShareE18;
            shares = FullMath.mulDiv(amount * scale, E18, initialPerShare);
            costScaled = FullMath.mulDivRoundingUp(initialPerShare, shares, E18);
        } else {
            if (balanceScaled == 0) return;
            uint256 wanted = FullMath.mulDiv(amount * scale, state.totalShares, balanceScaled);
            shares = _capped(vault, vaultId, binIndex, state.totalShares, wanted);
            costScaled = FullMath.mulDivRoundingUp(balanceScaled, shares, state.totalShares);
        }
        if (shares < vault.venue.minimumShares) return;
        _push(plan, binIndex, shares);
        uint256 cost = (costScaled + scale - 1) / scale;
        if (tokenIndex == 0) plan.cost0 += cost;
        else plan.cost1 += cost;
    }

    /// @dev Limits the vault to `weightCapBps` of a bin others also hold: `(ours + x) ≤ cap·(S + x)`.
    function _capped(Vault storage vault, uint256 vaultId, int16 binIndex, uint256 totalShares, uint256 shares)
        private
        view
        returns (uint256)
    {
        uint256 capBps = vault.parameters.weightCapBps;
        if (capBps >= BPS) return shares;
        uint256 ours = MetricState.positionShares(vault.parameters.pool, address(this), uint80(vaultId), binIndex);
        uint256 allowedTimesBps = capBps * totalShares;
        if (allowedTimesBps <= BPS * ours) return 0;
        uint256 limit = (allowedTimesBps - BPS * ours) / (BPS - capBps);
        return shares < limit ? shares : limit;
    }

    function _sideWeight(Vault storage vault, int16 activeBin, uint256 tokenIndex)
        private
        view
        returns (uint256 total)
    {
        uint256 count = _windowBins(vault);
        // count <= MAX_BINS + 1
        for (uint256 offset = 0; offset < count; ++offset) {
            int16 binIndex = int16(int256(vault.venue.lowestBin) + int256(offset));
            total += _weight(vault, activeBin, binIndex, tokenIndex);
        }
    }

    /// @dev A bin's placement weight for a token: 2 for the bin next to the reference on the token's side and 1 for
    /// the side's other bins, so four bins a side split a side 40/20/20/20 (owner, 2026-10-19, replacing a 4:3:2:1
    /// pyramid). The active bin counts on its side of the reference. Zero for the bin holding the reference, which
    /// straddles the price, and for any other bin Metric would not give this token, on the wrong side of the cursor.
    function _weight(Vault storage vault, int16 activeBin, int16 binIndex, uint256 tokenIndex)
        private
        view
        returns (uint256)
    {
        if (binIndex != activeBin) {
            if (!_holds(activeBin, binIndex, tokenIndex)) return 0;
        }
        int256 side = _side(vault, binIndex);
        if (side == 0) return 0;
        bool tokenSide = tokenIndex == 0 ? side > 0 : side < 0;
        if (!tokenSide) return 0;
        uint256 distance = _referenceDistance(vault, binIndex);
        if (distance > vault.parameters.binCount / 2) return 0;
        return distance == 1 ? 2 : 1;
    }

    /// @dev Whether Metric holds this token in a bin: token0 above the cursor's bin, token1 below it.
    function _holds(int16 activeBin, int16 binIndex, uint256 tokenIndex) private pure returns (bool) {
        if (tokenIndex == 0) return binIndex > activeBin;
        return binIndex < activeBin;
    }

    /// @dev How many bins from the reference a bin lies on its side: 1 for the nearest bin each side, 0 for the bin
    /// holding the reference.
    function _referenceDistance(Vault storage vault, int16 binIndex) private view returns (uint256) {
        int256 referenceBin = vault.venue.referenceBin;
        if (binIndex < referenceBin) return uint256(referenceBin - binIndex);
        if (vault.venue.referenceOnEdge) return uint256(int256(binIndex) - referenceBin) + 1;
        return uint256(int256(binIndex) - referenceBin);
    }

    // ---------------------------------------------------------------- removal

    /// @dev Takes `short` of one token from the single-token bins on its side, farthest first. Returns what is still
    /// short.
    function _gatherSide(
        Vault storage vault,
        uint256 vaultId,
        int16 activeBin,
        Plan memory plan,
        uint256 tokenIndex,
        uint256 short
    ) private view returns (uint256) {
        uint256 count = _windowBins(vault);
        // count <= MAX_BINS + 1
        for (uint256 step = 0; step < count; ++step) {
            if (short == 0) return 0;
            // Token0 bins are above the active bin, so walk down from the top; token1 bins walk up from the bottom. A
            // bin is read by what Metric holds there now, whatever the vault placed in it.
            uint256 offset = tokenIndex == 0 ? count - 1 - step : step;
            int16 binIndex = int16(int256(vault.venue.lowestBin) + int256(offset));
            if (!_holds(activeBin, binIndex, tokenIndex)) continue;
            short = _takeFromBin(vault, vaultId, plan, binIndex, tokenIndex, short, false);
        }
        return short;
    }

    /// @dev The active bin holds both tokens; it is used last, and never for the bin's last shares. One removal takes
    /// both tokens in proportion, so it removes enough shares for whichever token needs more.
    function _gatherActive(
        Vault storage vault,
        uint256 vaultId,
        int16 activeBin,
        Plan memory plan,
        uint256 short0,
        uint256 short1
    ) private view {
        if (short0 == 0) {
            if (short1 == 0) return;
        }
        if (!_inWindow(vault, activeBin)) return;
        uint256 ours = MetricState.positionShares(vault.parameters.pool, address(this), uint80(vaultId), activeBin);
        if (ours == 0) return;
        MetricState.Bin memory state = MetricState.bin(vault.parameters.pool, activeBin);
        uint256 wanted0 = _sharesOf(short0 * vault.venue.scale0, state.totalShares, state.balance0Scaled);
        uint256 wanted1 = _sharesOf(short1 * vault.venue.scale1, state.totalShares, state.balance1Scaled);
        uint256 shares = _sharesFor(vault, ours, state.totalShares, wanted0 > wanted1 ? wanted0 : wanted1, true);
        if (shares == 0) return;
        _push(plan, activeBin, shares);
    }

    /// @dev The shares holding `shortScaled` of a token the bin holds `balanceScaled` of, rounded up; none if the bin
    /// holds none of it.
    function _sharesOf(uint256 shortScaled, uint256 totalShares, uint256 balanceScaled) private pure returns (uint256) {
        if (shortScaled == 0) return 0;
        if (balanceScaled == 0) return 0;
        return FullMath.mulDivRoundingUp(shortScaled, totalShares, balanceScaled);
    }

    function _takeFromBin(
        Vault storage vault,
        uint256 vaultId,
        Plan memory plan,
        int16 binIndex,
        uint256 tokenIndex,
        uint256 short,
        bool active
    ) private view returns (uint256) {
        uint256 ours = MetricState.positionShares(vault.parameters.pool, address(this), uint80(vaultId), binIndex);
        if (ours == 0) return short;
        MetricState.Bin memory state = MetricState.bin(vault.parameters.pool, binIndex);
        uint256 balanceScaled = tokenIndex == 0 ? state.balance0Scaled : state.balance1Scaled;
        if (balanceScaled == 0) return short;
        uint256 scale = tokenIndex == 0 ? vault.venue.scale0 : vault.venue.scale1;
        uint256 wanted = _sharesOf(short * scale, state.totalShares, balanceScaled);
        uint256 shares = _sharesFor(vault, ours, state.totalShares, wanted, active);
        if (shares == 0) return short;
        _push(plan, binIndex, shares);
        uint256 taken = FullMath.mulDiv(shares, balanceScaled, state.totalShares) / scale;
        return taken >= short ? 0 : short - taken;
    }

    /// @dev The `wanted` shares made legal for Metric and, in the active bin, never the bin's last shares. Zero when
    /// no legal removal is left.
    function _sharesFor(Vault storage vault, uint256 ours, uint256 totalShares, uint256 wanted, bool active)
        private
        view
        returns (uint256 shares)
    {
        uint256 minimumShares = vault.venue.minimumShares;
        shares = _legalRemoval(wanted, ours, minimumShares);
        if (!active) return shares;
        if (ours != totalShares) return shares;
        uint256 removable = ours - _min(ours, minimumShares);
        if (shares <= removable) return shares;
        // Removing less than the minimum share delta is not a legal removal either.
        return removable < minimumShares ? 0 : removable;
    }

    /// @dev Metric requires a removal of at least the minimum share delta, leaving zero or at least the minimum.
    function _legalRemoval(uint256 shares, uint256 ours, uint256 minimumShares) private pure returns (uint256) {
        if (shares < minimumShares) shares = minimumShares;
        if (shares >= ours) return ours;
        if (ours - shares < minimumShares) return ours;
        return shares;
    }

    /// @dev Changes nothing if the pool refuses the removal; the caller then sees the buffer unchanged.
    function _remove(Vault storage vault, uint256 vaultId, Plan memory plan) private {
        if (plan.count == 0) return;
        _trim(plan);
        (uint256 before0, uint256 before1) = _balances(vault);
        try IMetricPool(vault.parameters.pool)
            .removeLiquidity(address(this), uint80(vaultId), LiquidityDelta(plan.bins, plan.shares), "") returns (
            uint256, uint256
        ) {
            (uint256 after0, uint256 after1) = _balances(vault);
            _creditRemoval(vault, after0 - before0, after1 - before1);
        } catch {}
    }

    /// @dev Credits what actually arrived from a removal, not what the pool reports (audit findings B1 and B2).
    function _creditRemoval(Vault storage vault, uint256 removed0, uint256 removed1) private {
        VaultLedger.credit(vault, 0, removed0);
        VaultLedger.credit(vault, 1, removed1);
        vault.ledger.buffer0 += removed0.toUint128();
        vault.ledger.buffer1 += removed1.toUint128();
        vault.venue.holdings0 = removed0 < vault.venue.holdings0 ? vault.venue.holdings0 - uint128(removed0) : 0;
        vault.venue.holdings1 = removed1 < vault.venue.holdings1 ? vault.venue.holdings1 - uint128(removed1) : 0;
    }

    // ---------------------------------------------------------------- plans

    function _emptyPlan() private pure returns (Plan memory plan) {
        plan.bins = new int256[](MAX_BINS + 1);
        plan.shares = new uint256[](MAX_BINS + 1);
    }

    /// @dev A bin can appear twice (as both a token0 and token1 removal only for the active bin, which is pushed once),
    /// so repeated bins merge.
    function _push(Plan memory plan, int16 binIndex, uint256 shares) private pure {
        // plan.count <= MAX_BINS + 1
        for (uint256 index = 0; index < plan.count; ++index) {
            if (plan.bins[index] != binIndex) continue;
            plan.shares[index] += shares;
            return;
        }
        plan.bins[plan.count] = binIndex;
        plan.shares[plan.count] = shares;
        plan.count += 1;
    }

    function _trim(Plan memory plan) private pure {
        int256[] memory bins = plan.bins;
        uint256[] memory shares = plan.shares;
        uint256 count = plan.count;
        assembly ("memory-safe") {
            mstore(bins, count)
            mstore(shares, count)
        }
    }

    function _maxSigned(int256 left, int256 right) private pure returns (int256) {
        return left > right ? left : right;
    }

    function _minSigned(int256 left, int256 right) private pure returns (int256) {
        return left < right ? left : right;
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }
}
