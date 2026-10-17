// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "oz/contracts/utils/math/SafeCast.sol";
import {Curve, LeverageMath} from "./LeverageMath.sol";

struct Bin {
    /// @dev Lenders' liquidity: idle (the v4 position) plus borrowed.
    uint128 liquidity;
    uint128 borrowed;
    uint256 fee0PerLiquidityX128;
    uint256 fee1PerLiquidityX128;
    /// @dev Quote released from the stream: premium and the lenders' part of profit shares.
    uint256 releasedPerLiquidityX128;
    /// @dev The integral of the yearly rate over time, in RAY per unit of quote notional.
    uint128 rateIndexRay;
    uint40 updatedAt;
    /// @dev The curve version in force at updatedAt.
    uint16 curveVersion;
    /// @dev Quote paid in and not yet released: it vests linearly to the bin's lenders until streamEnd, so only
    /// lenders present while it vests share it (audit L3-2).
    uint128 streamRemaining;
    uint40 streamEnd;
}

/// @dev A curve and the time it took effect. The rate index integrates each version over its own interval, so the
/// curve can change while positions are open without repricing the past (audit L3-4).
struct CurveVersion {
    Curve curve;
    uint40 startedAt;
}

/// @dev A lender's liquidity in one bin. Liquidity units are the shares: a close returns exactly the borrowed
/// liquidity, so a bin's liquidity changes only through deposits and withdrawals and needs no exchange rate.
struct Lender {
    uint128 liquidity;
    uint256 fee0PerLiquidityLastX128;
    uint256 fee1PerLiquidityLastX128;
    uint256 releasedPerLiquidityLastX128;
}

struct Owed {
    uint128 amount0;
    uint128 amount1;
}

struct Position {
    address owner;
    int24 lowerBin;
    uint8 binCount;
    /// @dev When someone flagged the position delinquent; zero when it is not flagged. A force close waits out the
    /// grace period from here (audit L3-1).
    uint40 delinquentSince;
    uint128 reserve0;
    uint128 reserve1;
    /// @dev `M0` and `M1`: the extremes of the borrowed liquidity. The strike is `M1 / M0`.
    uint128 maximum0;
    uint128 maximum1;
    /// @dev The cost basis still open: quote collateral deposited, and escrowed premium paid to lenders.
    uint128 collateral;
    uint128 premiumPaid;
    uint128 escrow;
}

struct Borrow {
    uint128 liquidity;
    /// @dev The bin's rate index when this borrow's premium was last settled.
    uint128 rateIndexRay;
}

/// @notice All storage of a Leverage deployment, shared by the contract and its position library.
struct LeverageState {
    /// @dev The current curve is the last; curves.length <= MAX_CURVE_VERSIONS.
    CurveVersion[] curves;
    bool installed;
    uint128 totalLiquidity;
    uint256 openPositions;
    uint256 lastPositionId;
    /// @dev Sums of every owed balance, so canUninstall needs no enumeration.
    uint256 totalOwed0;
    uint256 totalOwed1;
    mapping(int24 binIndex => Bin) bins;
    mapping(address account => mapping(int24 binIndex => Lender)) lenders;
    mapping(address account => Owed) owed;
    mapping(uint256 positionId => Position) positions;
    mapping(uint256 positionId => mapping(uint256 offset => Borrow)) borrows;
}

/// @notice The deployment's immutables, passed into library code that cannot read them.
struct LeverageContext {
    IPoolManager manager;
    PoolKey key;
    bool quoteIsCurrency0;
    uint256 utilizationCeilingBps;
    uint256 profitShareBps;
    uint256 treasuryShareBps;
    uint256 feeVaultShareBps;
    address treasury;
    address feeVault;
    uint256 vestSeconds;
    uint256 minBorrowNotional;
}

/// @notice The lending book: bins, lenders' accumulators and owed balances, and every change to a bin's v4 position.
library LeverageBins {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant Q128 = 1 << 128;
    /// @dev Bounds the rate-index loop: a bin untouched across every change evaluates one rate per version. Fits the
    /// uint16 Bin.curveVersion.
    uint256 internal constant MAX_CURVE_VERSIONS = 64;

    error InsufficientLiquidity();
    error UtilizationCeiling();
    error UnexpectedDelta();
    /// @dev The deposit would take the bin past its share of v4's per-tick liquidity cap: deposit less.
    error BinFull();

    function addToBin(
        LeverageState storage state,
        LeverageContext memory context,
        address account,
        int24 binIndex,
        uint128 liquidity
    ) internal returns (uint256 cost0, uint256 cost1) {
        Bin storage target = state.bins[binIndex];
        // Utilization changes below, so the rate index first runs to now at the old utilization.
        checkpoint(state, target);
        BalanceDelta principal = modifyBin(state, context, binIndex, int256(uint256(liquidity)));
        accrueLender(state, context, account, binIndex);
        state.lenders[account][binIndex].liquidity += liquidity;
        target.liquidity += liquidity;
        state.totalLiquidity += liquidity;
        // Adjacent bins share a boundary tick, whose v4 liquidity is capped. v4 checks only the idle part as it is
        // added, so a deposit could fill the room borrowed liquidity needs to return. Half the cap per bin, idle plus
        // borrowed, keeps every borrow returnable (audit Sol-2).
        if (target.liquidity > Pool.tickSpacingToMaxLiquidityPerTick(context.key.tickSpacing) / 2) revert BinFull();
        return (spent(principal.amount0()), spent(principal.amount1()));
    }

    function removeFromBin(
        LeverageState storage state,
        LeverageContext memory context,
        address account,
        int24 binIndex,
        uint128 liquidity
    ) internal returns (uint256 amount0, uint256 amount1) {
        Bin storage target = state.bins[binIndex];
        Lender storage holder = state.lenders[account][binIndex];
        if (holder.liquidity < liquidity) revert InsufficientLiquidity();
        // A withdrawal takes only idle liquidity; the borrowed part returns when its positions close.
        if (target.liquidity - target.borrowed < liquidity) revert InsufficientLiquidity();
        checkpoint(state, target);
        BalanceDelta principal = modifyBin(state, context, binIndex, -int256(uint256(liquidity)));
        accrueLender(state, context, account, binIndex);
        holder.liquidity -= liquidity;
        target.liquidity -= liquidity;
        state.totalLiquidity -= liquidity;
        return (received(principal.amount0()), received(principal.amount1()));
    }

    function borrowFromBin(
        LeverageState storage state,
        LeverageContext memory context,
        int24 binIndex,
        uint128 liquidity
    ) internal returns (uint256 amount0, uint256 amount1) {
        Bin storage target = state.bins[binIndex];
        checkpoint(state, target);
        BalanceDelta principal = modifyBin(state, context, binIndex, -int256(uint256(liquidity)));
        target.borrowed += liquidity;
        // The ceiling keeps idle liquidity in every bin, so no lent price range is left without depth. Checked after
        // the pool call: safe under Leverage's publicMutation lock and its own unlock.
        if (uint256(target.borrowed) * LeverageMath.BPS > uint256(target.liquidity) * context.utilizationCeilingBps) {
            revert UtilizationCeiling();
        }
        return (received(principal.amount0()), received(principal.amount1()));
    }

    function returnToBin(LeverageState storage state, LeverageContext memory context, int24 binIndex, uint128 liquidity)
        internal
        returns (uint256 cost0, uint256 cost1)
    {
        Bin storage target = state.bins[binIndex];
        checkpoint(state, target);
        BalanceDelta principal = modifyBin(state, context, binIndex, int256(uint256(liquidity)));
        target.borrowed -= liquidity;
        return (spent(principal.amount0()), spent(principal.amount1()));
    }

    /// @dev Every change to a bin's v4 position goes through here, so the swap fees it collects are always credited to
    /// the bin's lenders before its liquidity changes.
    function modifyBin(LeverageState storage state, LeverageContext memory context, int24 binIndex, int256 delta)
        internal
        returns (BalanceDelta principal)
    {
        (int24 tickLower, int24 tickUpper) = binTicks(state, context, binIndex);
        ModifyLiquidityParams memory liquidityParameters =
            ModifyLiquidityParams(tickLower, tickUpper, delta, bytes32(uint256(uint24(binIndex))));
        (BalanceDelta callerDelta, BalanceDelta fees) =
            context.manager.modifyLiquidity(context.key, liquidityParameters, "");
        creditFees(state.bins[binIndex], fees);
        return callerDelta - fees;
    }

    function creditFees(Bin storage target, BalanceDelta fees) internal {
        // Fees accrue only to the bin's v4 position, whose liquidity is part of target.liquidity.
        if (target.liquidity == 0) return;
        uint256 fee0 = received(fees.amount0());
        uint256 fee1 = received(fees.amount1());
        // Accumulators wrap like v4's fee growth; differences are taken unchecked too.
        unchecked {
            target.fee0PerLiquidityX128 += FullMath.mulDiv(fee0, Q128, target.liquidity);
            target.fee1PerLiquidityX128 += FullMath.mulDiv(fee1, Q128, target.liquidity);
        }
    }

    /// @dev Adds quote to the bin's stream. The bin is checkpointed at now first, so the amount vests from now and none
    /// of it reaches the lenders of the time before. A new amount restarts the vesting of what remains.
    function fundStream(Bin storage target, uint256 amount, uint256 vestSeconds) internal {
        if (amount == 0) return;
        target.streamRemaining = (target.streamRemaining + amount).toUint128();
        target.streamEnd = uint40(block.timestamp + vestSeconds);
    }

    /// @dev Runs the rate index and the stream to now. Call before anything changes the bin's liquidity or
    /// utilization, so each interval is priced at the utilization it had and released to the lenders it had.
    function checkpoint(LeverageState storage state, Bin storage target) internal {
        uint256 elapsedSeconds = block.timestamp - target.updatedAt;
        if (elapsedSeconds == 0) return;
        if (target.borrowed != 0) target.rateIndexRay = (target.rateIndexRay + indexGrowth(state, target)).toUint128();
        release(target, elapsedSeconds);
        target.updatedAt = uint40(block.timestamp);
        target.curveVersion = uint16(state.curves.length - 1);
    }

    /// @dev Releases the stream linearly over the time left. With no liquidity there is no one to pay, so the stream
    /// pauses: its end moves out by the elapsed time.
    function release(Bin storage target, uint256 elapsedSeconds) internal {
        if (target.streamRemaining == 0) return;
        if (target.liquidity == 0) {
            target.streamEnd += uint40(elapsedSeconds);
            return;
        }
        uint256 released = releasable(target, elapsedSeconds);
        target.streamRemaining -= uint128(released);
        // Rounds down: never releases more than was paid in; the dust stays in this contract.
        unchecked {
            target.releasedPerLiquidityX128 += FullMath.mulDiv(released, Q128, target.liquidity);
        }
    }

    /// @dev What the stream releases over `elapsedSeconds` from the last checkpoint: linear in the time left.
    /// streamEnd >= updatedAt while anything remains: funding sets the end from a same-block checkpoint, a pause moves
    /// the end exactly as far as updatedAt, and a release past the end empties the stream.
    function releasable(Bin storage target, uint256 elapsedSeconds) internal view returns (uint256) {
        uint256 remaining = target.streamRemaining;
        if (remaining == 0) return 0;
        uint256 leftSeconds = target.streamEnd - target.updatedAt;
        if (elapsedSeconds >= leftSeconds) return remaining;
        return remaining * elapsedSeconds / leftSeconds;
    }

    /// @dev The rate index's growth since the last checkpoint. Utilization was constant over the interval; the curve
    /// may have changed, so each version prices its own part.
    function indexGrowth(LeverageState storage state, Bin storage target) internal view returns (uint256 growthRay) {
        uint256 versions = state.curves.length;
        uint256 fromTime = target.updatedAt;
        // versions <= MAX_CURVE_VERSIONS
        for (uint256 version = target.curveVersion; version < versions; ++version) {
            uint256 untilTime = version + 1 < versions ? state.curves[version + 1].startedAt : block.timestamp;
            if (untilTime <= fromTime) continue;
            Curve memory curve = state.curves[version].curve;
            growthRay += LeverageMath.indexGrowthRay(curve, target.borrowed, target.liquidity, untilTime - fromTime);
            fromTime = untilTime;
        }
    }

    function currentRateIndex(LeverageState storage state, Bin storage target) internal view returns (uint256) {
        if (target.borrowed == 0) return target.rateIndexRay;
        return target.rateIndexRay + indexGrowth(state, target);
    }

    function currentCurve(LeverageState storage state) internal view returns (Curve memory) {
        return state.curves[state.curves.length - 1].curve;
    }

    function accrueLender(LeverageState storage state, LeverageContext memory context, address account, int24 binIndex)
        internal
    {
        Lender storage holder = state.lenders[account][binIndex];
        Bin storage target = state.bins[binIndex];
        (uint256 earned0, uint256 earned1) = earnings(context, holder, target);
        credit(state, account, earned0, earned1);
        holder.fee0PerLiquidityLastX128 = target.fee0PerLiquidityX128;
        holder.fee1PerLiquidityLastX128 = target.fee1PerLiquidityX128;
        holder.releasedPerLiquidityLastX128 = target.releasedPerLiquidityX128;
    }

    /// @dev Earnings released to the bin at its last checkpoint; what still vests in its stream is not yet the lender's.
    function earnings(LeverageContext memory context, Lender storage holder, Bin storage target)
        internal
        view
        returns (uint256 earned0, uint256 earned1)
    {
        uint256 liquidity = holder.liquidity;
        if (liquidity == 0) return (0, 0);
        earned0 = earned(liquidity, target.fee0PerLiquidityX128, holder.fee0PerLiquidityLastX128);
        earned1 = earned(liquidity, target.fee1PerLiquidityX128, holder.fee1PerLiquidityLastX128);
        uint256 earnedQuote = earned(liquidity, target.releasedPerLiquidityX128, holder.releasedPerLiquidityLastX128);
        if (context.quoteIsCurrency0) earned0 += earnedQuote;
        else earned1 += earnedQuote;
    }

    function earned(uint256 liquidity, uint256 growthX128, uint256 lastX128) internal pure returns (uint256) {
        uint256 deltaX128;
        unchecked {
            deltaX128 = growthX128 - lastX128;
        }
        return FullMath.mulDiv(liquidity, deltaX128, Q128);
    }

    function credit(LeverageState storage state, address account, uint256 amount0, uint256 amount1) internal {
        Owed storage balance = state.owed[account];
        balance.amount0 = (balance.amount0 + amount0).toUint128();
        balance.amount1 = (balance.amount1 + amount1).toUint128();
        state.totalOwed0 += amount0;
        state.totalOwed1 += amount1;
    }

    function creditQuote(LeverageState storage state, LeverageContext memory context, address account, uint256 amount)
        internal
    {
        if (context.quoteIsCurrency0) credit(state, account, amount, 0);
        else credit(state, account, 0, amount);
    }

    /// @dev The premium of `liquidity` borrowed from `binIndex`: its quote-currency notional times the index growth.
    function premium(
        LeverageState storage state,
        LeverageContext memory context,
        int24 binIndex,
        uint128 liquidity,
        uint256 indexDeltaRay
    ) internal view returns (uint256) {
        (uint256 maximum0, uint256 maximum1) = extremesOf(state, context, binIndex, liquidity);
        uint256 notional = context.quoteIsCurrency0 ? maximum0 : maximum1;
        // Rounded up, for the lenders: down, a borrower settling every few seconds could floor each interval to zero
        // (audit Sol-3).
        return FullMath.mulDivRoundingUp(notional, indexDeltaRay, LeverageMath.RAY);
    }

    function extremesOf(LeverageState storage state, LeverageContext memory context, int24 binIndex, uint128 liquidity)
        internal
        view
        returns (uint256, uint256)
    {
        (int24 tickLower, int24 tickUpper) = binTicks(state, context, binIndex);
        return LeverageMath.extremes(liquidity, tickLower, tickUpper);
    }

    function binTicks(LeverageState storage state, LeverageContext memory context, int24 binIndex)
        internal
        view
        returns (int24, int24)
    {
        return LeverageMath.binTicks(binIndex, currentCurve(state).binWidth, context.key.tickSpacing);
    }

    function binAt(int24 lowerBin, uint256 offset) internal pure returns (int24) {
        int256 binIndex = int256(lowerBin) + int256(offset);
        if (binIndex > type(int24).max) revert LeverageMath.InvalidBin();
        return int24(binIndex);
    }

    function swap(LeverageContext memory context, bool zeroForOne, int256 amountSpecified, uint160 limitX96)
        internal
        returns (BalanceDelta)
    {
        return context.manager.swap(context.key, SwapParams(zeroForOne, amountSpecified, limitX96), "");
    }

    function quote(LeverageContext memory context) internal pure returns (Currency) {
        return context.quoteIsCurrency0 ? context.key.currency0 : context.key.currency1;
    }

    function pull(Currency currency, address from, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(Currency.unwrap(currency)).safeTransferFrom(from, address(this), amount);
    }

    /// @dev A removal's principal is paid to this contract.
    function received(int128 amount) internal pure returns (uint256) {
        if (amount < 0) revert UnexpectedDelta();
        return uint256(int256(amount));
    }

    /// @dev An add's principal is paid by this contract.
    function spent(int128 amount) internal pure returns (uint256) {
        if (amount > 0) revert UnexpectedDelta();
        return uint256(-int256(amount));
    }
}
