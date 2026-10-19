// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ChargeNode, ChargeStart, Position, PricePoint, PriceRecord, Vault} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {DebtValuation} from "./DebtValuation.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultPricing} from "./VaultPricing.sol";

/// @notice The realized charge and the transformation rate (owner, 2026-10-19; hooks/docs/metric-lender-hedge-spec.md).
/// A borrowed range costs its lenders the rebalancing loss `ℓ = x(P)·ΔP − ΔV` of every price move inside it, and while
/// it is fully past the price, all in the token they did not lend, it keeps them in that token. Inside the range a
/// position pays the `ℓ` of each interval between hourly price points; fully past it, `k·σ` a year on its `M1`, with
/// `σ` from a volatility oracle on the same points. Both read three Fenwick trees keyed by the tick of each interval's
/// first point, so a position's charge over any number of points takes two tree walks.
/// @dev A linked library: the singleton delegatecalls its public functions, so the tree code is deployed once rather
/// than inlined into every library that charges premium. Amounts are in 2^-64 units of token1 until converted to WAD.
library RealizedCharge {
    using SafeCast for uint256;

    /// @dev The shortest interval between points: shorter ones would charge the oracle's noise as moves.
    uint256 internal constant MIN_INTERVAL_SECONDS = 1 hours;
    /// @dev The leverage `P / |P − K|`, at the strike `K = M1 / M0`, from which the surcharge applies (owner,
    /// 2026-10-19: the backtest's realized charge fell short by 3–6% from 500x).
    uint256 internal constant MIN_SURCHARGE_LEVERAGE = 500;
    /// @dev σ never falls below 30% a year, so a calm stretch does not make the transformation rate free.
    uint256 internal constant MIN_SIGMA_WAD = 0.3e18;
    /// @dev Both averages start at 60% a year: a new vault charges a cautious rate until it has its own data.
    uint256 internal constant START_VARIANCE_WAD = 0.36e18;
    /// @dev The averages' time constants, with weight `Δt / (τ + Δt)` per interval: about a day and about thirty days.
    /// A missed point weighs its longer return by its longer interval, so gaps do not bias the estimate.
    uint256 internal constant FAST_SECONDS = 1 days;
    uint256 internal constant SLOW_SECONDS = 30 days;
    /// @dev One interval counts at most ten times the slow average, so a single bad print cannot set σ.
    uint256 internal constant MAX_SAMPLE_MULTIPLE = 10;
    /// @dev The floor's variance, `MIN_SIGMA_WAD²`: the cap's base never falls below it, since after a long calm the
    /// slow average decays toward zero and the cap with it, and a real crash would then count for almost nothing.
    uint256 internal constant MIN_VARIANCE_WAD = MIN_SIGMA_WAD * MIN_SIGMA_WAD / WAD;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR_SECONDS = 365 days;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant X64 = 1 << 64;
    /// @dev `X64 · Q96`: a token0 term `L/√P` in 2^-64 units.
    uint256 internal constant X64_Q96 = 1 << 160;
    /// @dev `Q96 / X64`: a token1 term `L·√P` in 2^-64 units.
    uint256 internal constant Q96_PER_X64 = 1 << 32;

    /// @dev A position's range, with its token0 terms at both ends precomputed.
    struct Range {
        uint256 liquidity;
        uint160 sqrtLowerX96;
        uint160 sqrtUpperX96;
        /// @dev `L/√b`, and `M0 = L/√a − L/√b`, in 2^-64 units of token0.
        uint256 upper0X64;
        uint256 maximum0X64;
    }

    /// @dev The trees' sums for one position: over the intervals starting inside its range and below it, and the rent
    /// over the intervals starting past it.
    struct Sums {
        int256 rootInsideX96;
        int256 moveInsideX96;
        int256 moveBelowX96;
        int256 rentPastBpsSeconds;
    }

    // ---------------------------------------------------------------- price points

    /// @notice Records a price point once an interval has passed since the last and the pool prices. Anyone may call.
    /// Returns whether it recorded. Without a price nothing changes, and the next point spans the longer interval.
    function record(Vault storage vault, uint256 vaultId) public returns (bool) {
        PriceRecord storage prices = vault.prices;
        uint256 count = prices.count;
        if (count != 0) {
            if (block.timestamp < prices.points[count - 1].recordedAt + MIN_INTERVAL_SECONDS) return false;
        }
        (bool priced, uint160 sqrtMidX96) = mid(vault);
        if (!priced) return false;
        // The band call ran under the singleton's reentrancy lock, so `count` and the points are as read above.
        _append(vault, sqrtMidX96);
        emit IMetricLendingVault.PriceRecorded(vaultId, count, sqrtMidX96, sigmaWad(vault));
        return true;
    }

    /// @notice The geometric mid of the band without the fees the pool admin sets. It moves only with the reference:
    /// a bid would fall as the spread widens, and every interval would then charge a squared move that never happened.
    function mid(Vault storage vault) public returns (bool priced, uint160 sqrtMidX96) {
        (bool ok, uint160 sqrtBidX96, uint160 sqrtAskX96) = VaultPricing.tryCloseBand(vault);
        if (!ok) return (false, 0);
        // Both edges are under 2^128, so their product fits.
        return (true, Math.sqrt(uint256(sqrtBidX96) * sqrtAskX96).toUint160());
    }

    /// @notice The oracle's σ, a year in WAD: the larger of the fast and slow averages, never below the floor. The
    /// larger one, so a trader timing a calm spell before a storm still pays the storm's rate once it starts.
    function sigmaWad(Vault storage vault) public view returns (uint256) {
        uint256 fastWad = vault.prices.varianceFastWad;
        uint256 slowWad = vault.prices.varianceSlowWad;
        uint256 volatilityWad = Math.sqrt((fastWad > slowWad ? fastWad : slowWad) * WAD);
        return volatilityWad > MIN_SIGMA_WAD ? volatilityWad : MIN_SIGMA_WAD;
    }

    /// @dev Adds a point: the interval from the last point goes into the trees at that point's tick, the oracle takes
    /// the interval's return, and the new point carries the rate the oracle then gives. The first point has no
    /// interval, and starts the oracle.
    function _append(Vault storage vault, uint160 sqrtPriceX96) private {
        PriceRecord storage prices = vault.prices;
        uint256 count = prices.count;
        if (count == 0) {
            prices.varianceFastWad = uint112(START_VARIANCE_WAD);
            prices.varianceSlowWad = uint112(START_VARIANCE_WAD);
        } else {
            PricePoint memory last = prices.points[count - 1];
            uint256 elapsedSeconds = block.timestamp - last.recordedAt;
            _addInterval(prices, last, sqrtPriceX96, elapsedSeconds);
            _observe(prices, last.sqrtPriceX96, sqrtPriceX96, elapsedSeconds);
        }
        prices.points[count] = PricePoint(sqrtPriceX96, uint40(block.timestamp), _rentRateBps(vault));
        prices.count = (count + 1).toUint32();
    }

    /// @dev One interval's terms at its first point's tick: `ΔP/√P` and `ΔP` from `P = s²/2^192`, each rounded once,
    /// and the rent the first point's rate accrues over it.
    function _addInterval(
        PriceRecord storage prices,
        PricePoint memory last,
        uint160 sqrtPriceX96,
        uint256 elapsedSeconds
    ) private {
        uint256 sqrtPreviousX96 = last.sqrtPriceX96;
        uint256 sqrtCurrentX96 = sqrtPriceX96;
        uint256 sqrtChangeX96 =
            sqrtCurrentX96 > sqrtPreviousX96 ? sqrtCurrentX96 - sqrtPreviousX96 : sqrtPreviousX96 - sqrtCurrentX96;
        int256 sign = sqrtCurrentX96 >= sqrtPreviousX96 ? int256(1) : int256(-1);
        uint256 sqrtSumX96 = sqrtCurrentX96 + sqrtPreviousX96;
        ChargeNode memory delta;
        // `s₁² − s₀² = (s₁ − s₀)(s₁ + s₀)`: ΔP/√P · 2^96 divides by `s₀`, ΔP · 2^96 by 2^96.
        delta.perRootX96 = sign * FullMath.mulDiv(sqrtChangeX96, sqrtSumX96, sqrtPreviousX96).toInt256();
        delta.perMoveX96 = sign * FullMath.mulDiv(sqrtChangeX96, sqrtSumX96, Q96).toInt256();
        delta.rentBpsSeconds = (uint256(last.rentRateBps) * elapsedSeconds).toInt256();
        prices.rentTotalBpsSeconds += delta.rentBpsSeconds;
        _addAt(prices, _priceIndex(last.sqrtPriceX96), delta);
    }

    /// @dev Folds one interval's return into both averages as a yearly variance, `r²·year/Δt`. The return of
    /// `P = s²` is taken as `2(s/s₀ − 1)`, which differs from the log return by about its square: under 1% of it for
    /// moves under 1%, and the backtest's oracle used the log return.
    function _observe(
        PriceRecord storage prices,
        uint256 sqrtPreviousX96,
        uint256 sqrtCurrentX96,
        uint256 elapsedSeconds
    ) private {
        uint256 sqrtChangeX96 = sqrtCurrentX96 > sqrtPreviousX96
            ? sqrtCurrentX96 - sqrtPreviousX96
            : sqrtPreviousX96 - sqrtCurrentX96;
        uint256 returnWad = FullMath.mulDiv(2 * sqrtChangeX96, WAD, sqrtPreviousX96);
        uint256 sampleWad = FullMath.mulDiv(FullMath.mulDiv(returnWad, returnWad, WAD), YEAR_SECONDS, elapsedSeconds);
        uint256 slowWad = prices.varianceSlowWad;
        uint256 capWad = (slowWad > MIN_VARIANCE_WAD ? slowWad : MIN_VARIANCE_WAD) * MAX_SAMPLE_MULTIPLE;
        if (sampleWad > capWad) sampleWad = capWad;
        uint256 fastWad = _average(prices.varianceFastWad, sampleWad, elapsedSeconds, FAST_SECONDS);
        prices.varianceFastWad = fastWad.toUint112();
        prices.varianceSlowWad = _average(slowWad, sampleWad, elapsedSeconds, SLOW_SECONDS).toUint112();
    }

    /// @dev `v + (s − v)·Δt/(τ + Δt)`.
    function _average(uint256 averageWad, uint256 sampleWad, uint256 elapsedSeconds, uint256 timeConstantSeconds)
        private
        pure
        returns (uint256)
    {
        return (averageWad * timeConstantSeconds + sampleWad * elapsedSeconds) / (timeConstantSeconds + elapsedSeconds);
    }

    /// @dev `k·σ` a year in basis points.
    function _rentRateBps(Vault storage vault) private view returns (uint32) {
        return FullMath.mulDiv(sigmaWad(vault), vault.parameters.transformationRateBps, WAD).toUint32();
    }

    // ---------------------------------------------------------------- a position's start

    /// @notice Starts the position's charge at the price now: at an open, and when an increase has charged the old
    /// liquidity's stub. Records the vault's first point if it has none, so every start follows a point. Sets the
    /// surcharge from the leverage at this price.
    function start(Vault storage vault, Position storage position, ChargeStart storage charge, uint160 sqrtNowX96)
        public
    {
        if (vault.prices.count == 0) _append(vault, sqrtNowX96);
        charge.sqrtPriceX96 = sqrtNowX96;
        charge.point = uint32(vault.prices.count - 1);
        charge.startedAt = uint40(block.timestamp);
        charge.highLeverage = _isHighLeverage(position, sqrtNowX96);
        _snapshotSums(vault, position, charge);
    }

    /// @notice Moves the start to the last point once the position has been charged through it. With no point since
    /// the start, the start stays: moving it would drop the stretch from the start's own price.
    function restart(Vault storage vault, Position storage position, ChargeStart storage charge) public {
        uint256 count = vault.prices.count;
        if (count == 0) return;
        uint256 last = count - 1;
        if (charge.point >= last) return;
        PricePoint memory point = vault.prices.points[last];
        charge.sqrtPriceX96 = point.sqrtPriceX96;
        charge.point = uint32(last);
        charge.startedAt = point.recordedAt;
        _snapshotSums(vault, position, charge);
    }

    function _snapshotSums(Vault storage vault, Position storage position, ChargeStart storage charge) private {
        Sums memory sums = _sums(vault, position);
        charge.rootInsideX96 = sums.rootInsideX96;
        charge.moveInsideX96 = sums.moveInsideX96;
        charge.moveBelowX96 = sums.moveBelowX96;
        charge.rentPastBpsSeconds = sums.rentPastBpsSeconds;
    }

    /// @dev `MIN_SURCHARGE_LEVERAGE · |P − K| ≤ P`, with both prices in Q96.
    function _isHighLeverage(Position storage position, uint160 sqrtPriceX96) private view returns (bool) {
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        uint256 strikeX96 = FullMath.mulDiv(position.maximum1, Q96, position.maximum0);
        uint256 gapX96 = priceX96 > strikeX96 ? priceX96 - strikeX96 : strikeX96 - priceX96;
        return gapX96 * MIN_SURCHARGE_LEVERAGE <= priceX96;
    }

    // ---------------------------------------------------------------- what a position owes

    /// @notice What the position owes from its start through the vault's last point, in WAD of token1, before the
    /// surcharge and the protocol's tenth: `Σ ℓ` over the intervals, and the rent for those it spent past its range.
    /// Zero with no point since the start. Reads no price.
    function owedWad(Vault storage vault, Position storage position, ChargeStart storage charge)
        public
        view
        returns (uint256)
    {
        uint256 count = vault.prices.count;
        if (count == 0) return 0;
        if (uint256(charge.point) + 1 >= count) return 0;
        ChargeStart memory begin = charge;
        Range memory range = _range(position);
        Sums memory sums = _sums(vault, position);
        uint160 sqrtLastX96 = vault.prices.points[count - 1].sqrtPriceX96;
        int256 lossX64 = _treeTermsX64(range, begin, sums) + _firstIntervalX64(vault, range, begin)
            - _valueChangeX64(range, begin.sqrtPriceX96, sqrtLastX96);
        uint256 rentBpsSeconds = _rentThroughLastBpsSeconds(vault, position, range, begin, sums);
        return _toWad(lossX64) + _rentWad(position, rentBpsSeconds);
    }

    /// @notice What the position owes from where a settlement now would leave its start to `sqrtNowX96`, in WAD of
    /// token1, before the surcharge and the protocol's tenth: the stub `x(P_s)·(P_now − P_s) − (V(P_now) − V(P_s))`,
    /// and the rent since then if the range was past at `P_s`. Closes and increases charge it; settlements, which read
    /// no price, do not.
    function stubWad(Vault storage vault, Position storage position, ChargeStart storage charge, uint160 sqrtNowX96)
        public
        view
        returns (uint256)
    {
        (uint160 sqrtFromX96, uint256 fromTimestamp, uint256 rateBps) = _settledStart(vault, charge);
        Range memory range = _range(position);
        int256 lossX64 =
            _holdingTimesMoveX64(range, sqrtFromX96, sqrtNowX96) - _valueChangeX64(range, sqrtFromX96, sqrtNowX96);
        uint256 rentBpsSeconds;
        if (_isPast(position, range, sqrtFromX96)) rentBpsSeconds = rateBps * (block.timestamp - fromTimestamp);
        return _toWad(lossX64) + _rentWad(position, rentBpsSeconds);
    }

    /// @dev Where a settlement now would leave the start: the last point if one came after the start, otherwise the
    /// start itself. The rate in force from there is the last point's either way.
    function _settledStart(Vault storage vault, ChargeStart storage charge)
        private
        view
        returns (uint160 sqrtPriceX96, uint256 startedAt, uint256 rateBps)
    {
        uint256 last = vault.prices.count - 1;
        PricePoint memory point = vault.prices.points[last];
        if (charge.point < last) return (point.sqrtPriceX96, point.recordedAt, point.rentRateBps);
        return (charge.sqrtPriceX96, charge.startedAt, point.rentRateBps);
    }

    /// @dev `Σ x(P_i)·ΔP_i` over the intervals since the start's point, from the trees: `x = M0` below the range,
    /// `L/√P − L/√b` inside it, and none above.
    function _treeTermsX64(Range memory range, ChargeStart memory begin, Sums memory sums)
        private
        pure
        returns (int256)
    {
        int256 belowX64 = _times(range.maximum0X64, sums.moveBelowX96 - begin.moveBelowX96, Q96);
        int256 insideX64 = _times(range.liquidity, sums.rootInsideX96 - begin.rootInsideX96, Q96_PER_X64);
        int256 atUpperX64 = _times(range.liquidity << 64, sums.moveInsideX96 - begin.moveInsideX96, range.sqrtUpperX96);
        return belowX64 + insideX64 - atUpperX64;
    }

    /// @dev The trees count the start's interval from its first point; the position began at its own price inside it,
    /// so that interval's term is replaced by the one from the start's price.
    function _firstIntervalX64(Vault storage vault, Range memory range, ChargeStart memory begin)
        private
        view
        returns (int256)
    {
        uint160 sqrtPointX96 = vault.prices.points[begin.point].sqrtPriceX96;
        uint160 sqrtNextX96 = vault.prices.points[uint256(begin.point) + 1].sqrtPriceX96;
        return _holdingTimesMoveX64(range, begin.sqrtPriceX96, sqrtNextX96)
            - _holdingTimesMoveX64(range, sqrtPointX96, sqrtNextX96);
    }

    /// @dev The rent from the start through the last point. The trees count the start's interval at its first point's
    /// rate for its whole length; the position began inside it, so that interval is replaced by the stretch from the
    /// start's own time, past or not at the start's own price.
    function _rentThroughLastBpsSeconds(
        Vault storage vault,
        Position storage position,
        Range memory range,
        ChargeStart memory begin,
        Sums memory sums
    ) private view returns (uint256) {
        PricePoint memory point = vault.prices.points[begin.point];
        uint256 nextRecordedAt = vault.prices.points[uint256(begin.point) + 1].recordedAt;
        int256 rentBpsSeconds = sums.rentPastBpsSeconds - begin.rentPastBpsSeconds;
        if (_isPast(position, range, point.sqrtPriceX96)) {
            rentBpsSeconds -= (uint256(point.rentRateBps) * (nextRecordedAt - point.recordedAt)).toInt256();
        }
        if (_isPast(position, range, begin.sqrtPriceX96)) {
            rentBpsSeconds += (uint256(point.rentRateBps) * (nextRecordedAt - begin.startedAt)).toInt256();
        }
        return rentBpsSeconds > 0 ? uint256(rentBpsSeconds) : 0;
    }

    /// @dev Whether the range is fully past a price on a side lenders lent from: below it when they released token1,
    /// above it when they released token0. Keyed on the release, not on the position's side, so a label cannot avoid
    /// it; a range that straddled the price pays on both sides.
    function _isPast(Position storage position, Range memory range, uint160 sqrtPriceX96) private view returns (bool) {
        if (sqrtPriceX96 < range.sqrtLowerX96) return position.released1 != 0;
        if (sqrtPriceX96 >= range.sqrtUpperX96) return position.released0 != 0;
        return false;
    }

    /// @dev `M1 · rate · Δt / year`, the rate in basis points, in WAD of token1.
    function _rentWad(Position storage position, uint256 rentBpsSeconds) private view returns (uint256) {
        if (rentBpsSeconds == 0) return 0;
        return FullMath.mulDiv(position.maximum1, rentBpsSeconds * WAD, BPS * YEAR_SECONDS);
    }

    // ---------------------------------------------------------------- range terms

    function _range(Position storage position) private view returns (Range memory range) {
        range.liquidity = position.liquidity;
        (range.sqrtLowerX96, range.sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        range.upper0X64 = FullMath.mulDiv(range.liquidity, X64_Q96, range.sqrtUpperX96);
        range.maximum0X64 = FullMath.mulDiv(range.liquidity, X64_Q96, range.sqrtLowerX96) - range.upper0X64;
    }

    /// @dev The range's holdings at a price in 2^-64 units: `L/√P − L/√b` token0 and `L(√P − √a)` token1, with `√P`
    /// held to the range.
    function _heldX64(Range memory range, uint160 sqrtPriceX96)
        private
        pure
        returns (uint256 amount0X64, uint256 amount1X64)
    {
        uint160 sqrtInsideX96 = sqrtPriceX96 < range.sqrtLowerX96 ? range.sqrtLowerX96 : sqrtPriceX96;
        if (sqrtInsideX96 > range.sqrtUpperX96) sqrtInsideX96 = range.sqrtUpperX96;
        amount0X64 = FullMath.mulDiv(range.liquidity, X64_Q96, sqrtInsideX96) - range.upper0X64;
        amount1X64 = FullMath.mulDiv(range.liquidity, sqrtInsideX96 - range.sqrtLowerX96, Q96_PER_X64);
    }

    /// @dev `V(P) = x(P)·P + y(P)` in 2^-64 units of token1.
    function _valueX64(Range memory range, uint160 sqrtPriceX96) private pure returns (uint256) {
        (uint256 amount0X64, uint256 amount1X64) = _heldX64(range, sqrtPriceX96);
        return FullMath.mulDiv(FullMath.mulDiv(amount0X64, sqrtPriceX96, Q96), sqrtPriceX96, Q96) + amount1X64;
    }

    function _valueChangeX64(Range memory range, uint160 sqrtFromX96, uint160 sqrtToX96) private pure returns (int256) {
        return _valueX64(range, sqrtToX96).toInt256() - _valueX64(range, sqrtFromX96).toInt256();
    }

    /// @dev `x(P_from)·(P_to − P_from)` in 2^-64 units of token1, from `P = s²/2^192`.
    function _holdingTimesMoveX64(Range memory range, uint160 sqrtFromX96, uint160 sqrtToX96)
        private
        pure
        returns (int256)
    {
        (uint256 amount0X64,) = _heldX64(range, sqrtFromX96);
        uint256 sqrtChangeX96 = sqrtToX96 > sqrtFromX96 ? sqrtToX96 - sqrtFromX96 : sqrtFromX96 - sqrtToX96;
        uint256 sqrtSumX96 = uint256(sqrtToX96) + sqrtFromX96;
        uint256 magnitude = FullMath.mulDiv(FullMath.mulDiv(amount0X64, sqrtChangeX96, Q96), sqrtSumX96, Q96);
        return sqrtToX96 >= sqrtFromX96 ? magnitude.toInt256() : -magnitude.toInt256();
    }

    // ---------------------------------------------------------------- trees

    /// @dev The trees' sums for a position now. Intervals are keyed by the tick of their first point, so those
    /// starting below the range sit at ticks under `tickLower`, those inside at ticks under `tickUpper` and not below.
    function _sums(Vault storage vault, Position storage position) private view returns (Sums memory sums) {
        PriceRecord storage prices = vault.prices;
        ChargeNode memory below = _prefix(prices, _belowIndex(position.tickLower));
        ChargeNode memory underUpper = _prefix(prices, _belowIndex(position.tickUpper));
        sums.rootInsideX96 = underUpper.perRootX96 - below.perRootX96;
        sums.moveInsideX96 = underUpper.perMoveX96 - below.perMoveX96;
        sums.moveBelowX96 = below.perMoveX96;
        if (position.released1 != 0) sums.rentPastBpsSeconds += below.rentBpsSeconds;
        if (position.released0 != 0) {
            sums.rentPastBpsSeconds += prices.rentTotalBpsSeconds - underUpper.rentBpsSeconds;
        }
    }

    function _addAt(PriceRecord storage prices, uint256 index, ChargeNode memory delta) private {
        // index <= SIZE < 2^20, and each step moves past index's lowest set bit: at most 20 steps
        while (index <= DebtValuation.SIZE) {
            ChargeNode storage node = prices.nodes[index];
            node.perRootX96 += delta.perRootX96;
            node.perMoveX96 += delta.perMoveX96;
            node.rentBpsSeconds += delta.rentBpsSeconds;
            index += index & (~index + 1);
        }
    }

    /// @dev The sums over every interval keyed at an index up to `index`.
    function _prefix(PriceRecord storage prices, uint256 index) private view returns (ChargeNode memory sum) {
        // index <= SIZE < 2^20, and each step clears index's lowest set bit: at most 20 steps
        while (index > 0) {
            ChargeNode storage node = prices.nodes[index];
            sum.perRootX96 += node.perRootX96;
            sum.perMoveX96 += node.perMoveX96;
            sum.rentBpsSeconds += node.rentBpsSeconds;
            index &= index - 1;
        }
    }

    /// @dev The index of a price's tick, the greatest whose price is at or below it, on `DebtValuation`'s index scale.
    /// Band prices lie within the ranges' bounds; the clamp keeps an add's walk from starting at zero, where it would
    /// never end.
    function _priceIndex(uint160 sqrtPriceX96) private pure returns (uint256) {
        int256 index = int256(TickMath.getTickAtSqrtPrice(sqrtPriceX96)) + DebtValuation.OFFSET;
        if (index < 1) return 1;
        if (index > int256(DebtValuation.SIZE)) return DebtValuation.SIZE;
        return uint256(index);
    }

    /// @dev The last index below a range end's tick: a prefix to it covers the intervals keyed under that tick.
    function _belowIndex(int24 tick) private pure returns (uint256) {
        return uint256(int256(tick) + DebtValuation.OFFSET - 1);
    }

    // ---------------------------------------------------------------- arithmetic

    /// @dev `amount · signed / divisor`, its magnitude rounded down.
    function _times(uint256 amount, int256 signed, uint256 divisor) private pure returns (int256) {
        uint256 magnitude = FullMath.mulDiv(amount, signed < 0 ? uint256(-signed) : uint256(signed), divisor);
        return signed < 0 ? -magnitude.toInt256() : magnitude.toInt256();
    }

    /// @dev A loss in 2^-64 units of token1 as WAD of a unit; a loss under zero is only rounding, and charges nothing.
    function _toWad(int256 lossX64) private pure returns (uint256) {
        if (lossX64 <= 0) return 0;
        return FullMath.mulDiv(uint256(lossX64), WAD, X64);
    }
}
