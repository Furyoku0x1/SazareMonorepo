// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Vault} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {IMetricPool, LiquidityDelta} from "../interfaces/IMetricPool.sol";
import {MetricState} from "./MetricState.sol";
import {VaultCallback} from "./VaultCallback.sol";
import {VaultLedger} from "./VaultLedger.sol";

/// @notice The vault's idle capital in its Metric pool: placement around the active bin, withdrawal from the edges,
/// re-centering, and reads of what the position holds.
/// @dev A linked library: its public functions are delegatecalled from the vault's other libraries, so they run in the
/// singleton's context and keep the callers small. Every bin the vault holds lies in its window. Deposits go to the window's bins on the side of the cursor that
/// holds each token, never to the active bin, since Metric picks a deposit's token by the bin's side of the cursor at
/// the moment of the add. Withdrawals take the farthest bins first and leave the active bin to last.
library MetricVenue {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @dev Bounds every loop over the window. Fits the uint8 `binCount`.
    uint256 internal constant MAX_BINS = 32;
    /// @dev The most bins one re-centering moves, which bounds its removal and placement work.
    uint256 internal constant MAX_RECENTER_BINS = 4;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant E18 = 1e18;

    struct Plan {
        int256[] bins;
        uint256[] shares;
        uint256 count;
        uint256 cost0;
        uint256 cost1;
    }

    /// @notice Updates the cached holdings from the pool. A no-op without a pool.
    function refresh(Vault storage vault, uint256 vaultId) public {
        if (vault.parameters.pool == address(0)) return;
        (uint256 amount0, uint256 amount1) = holdings(vault, vaultId);
        vault.venue.holdings0 = amount0.toUint128();
        vault.venue.holdings1 = amount1.toUint128();
    }

    /// @notice What the vault's Metric position holds now, in native units, rounded down.
    function holdings(Vault storage vault, uint256 vaultId) internal view returns (uint256 amount0, uint256 amount1) {
        if (!vault.venue.windowSet) return (0, 0);
        address pool = vault.parameters.pool;
        uint256 count = vault.parameters.binCount;
        // count <= MAX_BINS
        for (uint256 offset = 0; offset < count; ++offset) {
            int16 binIndex = int16(int256(vault.venue.lowestBin) + int256(offset));
            uint256 ours = MetricState.positionShares(pool, address(this), uint80(vaultId), binIndex);
            if (ours == 0) continue;
            MetricState.Bin memory state = MetricState.bin(pool, binIndex);
            amount0 += FullMath.mulDiv(ours, state.balance0Scaled, state.totalShares) / vault.venue.scale0;
            amount1 += FullMath.mulDiv(ours, state.balance1Scaled, state.totalShares) / vault.venue.scale1;
        }
    }

    /// @notice Places the lenders' buffer in the window's bins, first moving the window toward the active bin if it
    /// has drifted (see `recenter`). What a bin cannot take (below Metric's minimum share delta, or past the weight
    /// cap) stays in the buffer. Every action that moves the vault's Metric holdings ends here, so the holdings are
    /// re-read last: the next accrual interval samples them after the action's own swaps and placement.
    function place(Vault storage vault, uint256 vaultId) public {
        address pool = vault.parameters.pool;
        if (pool == address(0)) return;
        int16 activeBin = MetricState.cursor(pool).binIndex;
        _shift(vault, vaultId, activeBin);
        _place(vault, vaultId, activeBin);
        refresh(vault, vaultId);
    }

    /// @dev Never reverts on the pool's account, so placement never blocks the action that calls it, closes included.
    function _place(Vault storage vault, uint256 vaultId, int16 activeBin) private {
        address pool = vault.parameters.pool;
        _ensureWindow(vault, activeBin);
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
        return vault.ledger.buffer0 >= need0 && vault.ledger.buffer1 >= need1;
    }

    /// @notice Moves the window toward the active bin once it has drifted more than `recenterDistance` bins from the
    /// window's center, then places and re-reads the holdings. Every placement does the same move; this lets anyone
    /// trigger it without another action. Returns whether the window moved.
    function recenter(Vault storage vault, uint256 vaultId) public returns (bool moved) {
        address pool = vault.parameters.pool;
        if (pool == address(0)) return false;
        int16 activeBin = MetricState.cursor(pool).binIndex;
        moved = _shift(vault, vaultId, activeBin);
        _place(vault, vaultId, activeBin);
        refresh(vault, vaultId);
    }

    /// @dev Moves the window at most MAX_RECENTER_BINS bins toward the active bin, emptying the bins it gives up. A
    /// window far behind a jump catches up over several calls. Nothing moves if the pool refuses the removal.
    function _shift(Vault storage vault, uint256 vaultId, int16 activeBin) private returns (bool) {
        if (!vault.venue.windowSet) return false;
        int256 lowest = vault.venue.lowestBin;
        uint256 count = vault.parameters.binCount;
        int256 drift = int256(activeBin) - (lowest + int256(count / 2));
        uint256 distance = drift < 0 ? uint256(-drift) : uint256(drift);
        if (distance <= vault.parameters.recenterDistance) return false;
        uint256 shift = distance < MAX_RECENTER_BINS ? distance : MAX_RECENTER_BINS;
        int256 newLowest = _clampWindow(vault, drift > 0 ? lowest + int256(shift) : lowest - int256(shift));
        if (newLowest == lowest) return false;
        // The vault's shares in the active bin can never all be removed, so a window holding the active bin must keep
        // it. Outside the old window the vault holds nothing there, and the window may pass it by.
        if (_inWindow(activeBin, lowest, count)) {
            if (!_inWindow(activeBin, newLowest, count)) return false;
        }
        if (!_emptyOutside(vault, vaultId, newLowest)) return false;
        vault.venue.lowestBin = int16(newLowest);
        return true;
    }

    function _inWindow(int256 binIndex, int256 lowest, uint256 count) private pure returns (bool) {
        if (binIndex < lowest) return false;
        return binIndex < lowest + int256(count);
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

    /// @notice Buys exactly `amountOut` of one token, paying at most `maximumIn` of the other, through the pool. Never
    /// reverts on the pool's account: the callback refuses a partial fill, so a swap either fills in full or moves
    /// nothing and reports `ok = false`, and a force close falls back to scaling on untouched reserves.
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

    function _ensureWindow(Vault storage vault, int16 activeBin) private {
        if (vault.venue.windowSet) return;
        int256 lowest = int256(activeBin) - int256(uint256(vault.parameters.binCount / 2));
        vault.venue.lowestBin = int16(_clampWindow(vault, lowest));
        vault.venue.windowSet = true;
    }

    function _clampWindow(Vault storage vault, int256 lowest) private view returns (int256) {
        int256 highestStart = int256(vault.venue.poolHighestBin) - int256(uint256(vault.parameters.binCount)) + 1;
        if (lowest > highestStart) lowest = highestStart;
        if (lowest < vault.venue.poolLowestBin) lowest = vault.venue.poolLowestBin;
        return lowest;
    }

    /// @dev Token0 goes to the window's bins above the active bin, token1 to those below, each in a linear taper that
    /// gives the bin next to the price the most.
    function _plan(Vault storage vault, uint256 vaultId, int16 activeBin) private view returns (Plan memory plan) {
        plan = _emptyPlan();
        _planSide(vault, vaultId, activeBin, plan, 0, vault.ledger.buffer0);
        _planSide(vault, vaultId, activeBin, plan, 1, vault.ledger.buffer1);
    }

    function _planSide(
        Vault storage vault,
        uint256 vaultId,
        int16 activeBin,
        Plan memory plan,
        uint256 tokenIndex,
        uint256 amount
    ) private view {
        if (amount == 0) return;
        uint256 totalWeight = _sideWeight(vault, activeBin, tokenIndex);
        if (totalWeight == 0) return;
        uint256 count = vault.parameters.binCount;
        // count <= MAX_BINS
        for (uint256 offset = 0; offset < count; ++offset) {
            int16 binIndex = int16(int256(vault.venue.lowestBin) + int256(offset));
            uint256 weight = _weight(vault, activeBin, binIndex, tokenIndex);
            if (weight == 0) continue;
            _planBin(vault, vaultId, plan, binIndex, tokenIndex, amount * weight / totalWeight);
        }
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
        uint256 count = vault.parameters.binCount;
        // count <= MAX_BINS
        for (uint256 offset = 0; offset < count; ++offset) {
            int16 binIndex = int16(int256(vault.venue.lowestBin) + int256(offset));
            total += _weight(vault, activeBin, binIndex, tokenIndex);
        }
    }

    /// @dev Token0 bins lie above the active bin and token1 bins below; the active bin takes neither. A bin at
    /// distance `k` weighs `half + 1 − k`, at least one.
    function _weight(Vault storage vault, int16 activeBin, int16 binIndex, uint256 tokenIndex)
        private
        view
        returns (uint256)
    {
        int256 distance = tokenIndex == 0 ? int256(binIndex) - activeBin : int256(activeBin) - binIndex;
        if (distance <= 0) return 0;
        int256 weight = int256(uint256(vault.parameters.binCount / 2)) + 1 - distance;
        return weight < 1 ? 1 : uint256(weight);
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
        uint256 count = vault.parameters.binCount;
        // count <= MAX_BINS
        for (uint256 step = 0; step < count; ++step) {
            if (short == 0) return 0;
            // Token0 bins are above the active bin, so walk down from the top; token1 bins walk up from the bottom.
            uint256 offset = tokenIndex == 0 ? count - 1 - step : step;
            int16 binIndex = int16(int256(vault.venue.lowestBin) + int256(offset));
            if (_weight(vault, activeBin, binIndex, tokenIndex) == 0) continue;
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
        if (!_inWindow(activeBin, vault.venue.lowestBin, vault.parameters.binCount)) return;
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

    /// @dev Empties every bin the window gives up when it moves to start at `newLowest`; the caller has checked the
    /// vault holds nothing in the active bin among them. Returns whether the pool allowed it.
    function _emptyOutside(Vault storage vault, uint256 vaultId, int256 newLowest) private returns (bool) {
        Plan memory plan = _emptyPlan();
        address pool = vault.parameters.pool;
        uint256 count = vault.parameters.binCount;
        // count <= MAX_BINS
        for (uint256 offset = 0; offset < count; ++offset) {
            int16 binIndex = int16(int256(vault.venue.lowestBin) + int256(offset));
            if (_inWindow(binIndex, newLowest, count)) continue;
            uint256 ours = MetricState.positionShares(pool, address(this), uint80(vaultId), binIndex);
            if (ours == 0) continue;
            _push(plan, binIndex, ours);
        }
        return _remove(vault, vaultId, plan);
    }

    /// @dev Returns false, changing nothing, if the pool refuses the removal; callers then see the buffer unchanged.
    function _remove(Vault storage vault, uint256 vaultId, Plan memory plan) private returns (bool) {
        if (plan.count == 0) return true;
        _trim(plan);
        (uint256 before0, uint256 before1) = _balances(vault);
        try IMetricPool(vault.parameters.pool)
            .removeLiquidity(address(this), uint80(vaultId), LiquidityDelta(plan.bins, plan.shares), "") returns (
            uint256, uint256
        ) {
            (uint256 after0, uint256 after1) = _balances(vault);
            _creditRemoval(vault, after0 - before0, after1 - before1);
            return true;
        } catch {
            return false;
        }
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

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }
}
