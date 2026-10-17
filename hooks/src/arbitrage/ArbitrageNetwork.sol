// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {CallbackType} from "core/src/types/KernelHookTypes.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {NetworkRegistry} from "./NetworkRegistry.sol";
import {Pair, PoolRecord} from "./NetworkTypes.sol";
import {
    MAX_TOP_POOLS,
    MAX_TRIANGLES,
    MAX_QUADS,
    MAX_SIZED_CYCLES,
    SEARCH_ATTEMPT_RESERVE_GAS,
    SEARCH_SIZE_GAS
} from "../libraries/arbitrage/NetworkConstants.sol";
import {NetworkLibrary} from "../libraries/arbitrage/NetworkLibrary.sol";
import {LimitOrder} from "../limitorder/LimitOrder.sol";
import {CycleMath} from "../libraries/arbitrage/CycleMath.sol";
import {PoolQuote} from "../libraries/arbitrage/PoolQuote.sol";
import {OrderMath} from "../libraries/limitorder/OrderMath.sol";
import {ExtensionRead} from "../libraries/shared/ExtensionRead.sol";

/// @notice Pool network and on-chain cycle search for ArbitrageHook. After a swap, it finds the most profitable cycle
/// of two to four pools through the swapped pool and quotes it exactly.
/// @dev Same-pair peers come first, then the pair's saved triangles and four-pool loops. Every list is capped, so a
/// search reads at most MAX_SNAPSHOTS pools whatever the size of the network. The search is a view; the hook executes
/// the returned plan and checks the actual balances.
contract ArbitrageNetwork is NetworkRegistry {
    using ExtensionRead for address;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    /// @dev The swapped pool plus every pool the capped lists can name.
    uint256 private constant MAX_SNAPSHOTS = 1 + MAX_TOP_POOLS + 2 * MAX_TRIANGLES + 3 * MAX_QUADS;
    /// @dev Each loop is tried in both directions.
    uint256 private constant MAX_CYCLES = 2 * (MAX_TOP_POOLS + MAX_TRIANGLES + MAX_QUADS);
    /// @dev Open-addressing table from pool to snapshot index. Larger than MAX_SNAPSHOTS, so a probe always ends.
    uint256 private constant SNAPSHOT_TABLE_SIZE = 128;
    /// @dev Gas guards, so a search that runs low returns the best plan found so far instead of running out of gas.
    /// Before each step the search keeps enough for every later step: one quote attempt (compatibility reads, up to
    /// 3 exact-output quotes and the closing quote with its PREVIEW_GAS-capped book preview), sizing, the price batch
    /// and scoring. Loops are added in priority order (same pair, triangles, four-pool loops), so the guards always
    /// drop the lowest-priority work. Per-item costs are measured cold upper estimates: the price batch costs about
    /// 4,200 per pool, and scoring a four-pool cycle that passes the gate about 6,000.
    uint256 private constant PRICE_GAS_PER_POOL = 4_500;
    uint256 private constant SCORE_GAS_PER_CYCLE = 6_000;
    /// @dev Gas and return-size caps of the bounded LimitOrder preview read.
    uint256 private constant PREVIEW_GAS = 180_000;
    uint256 private constant PREVIEW_BYTES = 256;

    LimitOrder public immutable LIMIT_ORDERS;

    /// @notice Per-search work caps, set by each pool's Arbitrage policy.
    struct Limits {
        uint8 samePair;
        uint8 triangles;
        uint8 quads;
        uint8 sized;
        uint128 minimumSurplus;
        uint128 maximumInput;
    }

    /// @notice A cycle ready to execute, legs in order. Every leg except the last is an exact-output swap of
    /// amounts[i]; the last is an exact-input swap of amounts[legs - 1]. So each middle currency nets to zero.
    /// @dev Static ABI (31 words), so the hook can read it with a bounded staticcall and an exact length check.
    struct Plan {
        uint8 legs;
        PoolKey[4] keys;
        bool[4] zeroForOne;
        uint128[4] amounts;
        uint128 input;
        uint128 proceeds;
    }

    struct Snapshot {
        uint32 pool;
        uint32 token0;
        uint32 token1;
        uint24 keyFee;
        int24 tickSpacing;
        bool usable;
        /// @dev 0 unknown, 1 compatible, 2 incompatible extensions.
        uint8 compatibility;
        /// @dev 0 unknown, 1 LimitOrder is the only BeforeSwap subscriber, 2 not.
        uint8 book;
        bool liquidityRead;
        uint96 syncedLiquidity;
        uint128 liquidity;
        uint160 sqrtPriceX96;
        uint24 fee0;
        uint24 fee1;
        PoolId id;
        /// @dev Scaled virtual reserves (CycleMath), from synced liquidity until the live liquidity is read. Zero when
        /// the pool is not usable.
        uint256 reserve0;
        uint256 reserve1;
    }

    /// @dev Packed, so the cycle array holds no nested arrays: byte k of path is leg k's snapshot index, and bit k of
    /// directions is set when leg k swaps token0 for token1.
    struct Cycle {
        uint8 legs;
        bool sized;
        bool tried;
        uint8 directions;
        uint32 path;
        uint256 score;
        uint256 input;
        uint256 profit;
    }

    struct Search {
        uint32 origin;
        uint32 tokenX;
        uint32 low;
        uint32 high;
        uint256 snapshotCount;
        uint256 cycleCount;
        /// @dev Gas kept for sizing and one quote attempt: SEARCH_ATTEMPT_RESERVE_GAS + limits.sized * SEARCH_SIZE_GAS.
        uint256 finishGas;
        Snapshot[] snapshots;
        Cycle[] cycles;
        uint16[SNAPSHOT_TABLE_SIZE] table;
    }

    error InvalidLimits();

    constructor(IKernelHook kernel, LimitOrder limitOrders) NetworkRegistry(kernel) {
        if (address(limitOrders) != address(0) && address(limitOrders.KERNEL()) != address(kernel)) {
            revert InvalidConfiguration();
        }
        LIMIT_ORDERS = limitOrders;
    }

    /// @notice Finds the most profitable cycle through the swapped pool and quotes it exactly. Zero legs means none.
    /// @dev msg.sender is the calling hook: a cycle pool may have it as its only AfterSwap subscriber.
    function findCycle(PoolId origin, bool profitCurrency0, Limits calldata limits)
        external
        view
        returns (Plan memory plan)
    {
        _checkLimits(limits);
        Search memory search = _beginSearch(origin, profitCurrency0, limits);
        if (search.snapshotCount == 0) return plan;
        Pair storage pair = _state.pairs[NetworkLibrary.pairKey(search.low, search.high)];
        _addSamePair(search, pair, limits.samePair);
        _addTriangles(search, pair, limits.triangles);
        _addQuads(search, pair, limits.quads);
        _readPrices(search);
        _scoreCycles(search, limits.maximumInput);
        _sizeBest(search, limits);
        return _bestBookPlan(search, limits, _bestPlan(search, limits));
    }

    /// @notice One exact single-pool quote. External so the search can call it through try/catch: a quote that reverts
    /// in the price math (an output at or beyond a pool's virtual reserve) rejects only its own candidate.
    function quoteLeg(PoolKey calldata key, bool zeroForOne, int256 amount)
        external
        view
        returns (PoolQuote.Quote memory)
    {
        return PoolQuote.quote(MANAGER, key, zeroForOne, amount);
    }

    function _checkLimits(Limits calldata limits) private pure {
        if (limits.samePair > MAX_TOP_POOLS) revert InvalidLimits();
        if (limits.triangles > MAX_TRIANGLES) revert InvalidLimits();
        if (limits.quads > MAX_QUADS) revert InvalidLimits();
        if (limits.sized > MAX_SIZED_CYCLES) revert InvalidLimits();
        if (limits.maximumInput > OrderMath.MAX_DELTA) revert InvalidLimits();
    }

    /// @dev Sizes the working arrays to the lists this search reads, not to the caps: memory cost grows with the
    /// square of its size, so a small search stays cheap.
    function _beginSearch(PoolId origin, bool profitCurrency0, Limits calldata limits)
        private
        view
        returns (Search memory search)
    {
        uint32 pool = poolIndexOf[origin];
        PoolRecord storage record = _state.pools[pool];
        if (!record.active) return search;
        (uint32 token0, uint32 token1) = (record.token0, record.token1);
        (search.low, search.high) = token0 < token1 ? (token0, token1) : (token1, token0);
        Pair storage pair = _state.pairs[NetworkLibrary.pairKey(search.low, search.high)];
        uint256 peers = _min(limits.samePair, pair.topCount);
        uint256 triangles = _min(limits.triangles, pair.triangleCount);
        uint256 quads = _min(limits.quads, pair.quadCount);
        search.snapshots = new Snapshot[](1 + peers + 2 * triangles + 3 * quads);
        search.cycles = new Cycle[](2 * (peers + triangles + quads));
        search.origin = pool;
        search.finishGas = SEARCH_ATTEMPT_RESERVE_GAS + uint256(limits.sized) * SEARCH_SIZE_GAS;
        search.tokenX = profitCurrency0 ? token0 : token1;
        _snapshot(search, pool);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _addSamePair(Search memory search, Pair storage pair, uint256 limit) private view {
        uint256 count = pair.topCount;
        uint256 added;
        // count <= MAX_TOP_POOLS
        for (uint256 i; i < count && added < limit; ++i) {
            uint32 peer = pair.top[i].pool;
            if (peer == search.origin) continue;
            ++added;
            _addLoop(search, [search.origin, peer, 0, 0], 2);
        }
    }

    function _addTriangles(Search memory search, Pair storage pair, uint256 limit) private view {
        uint256 count = pair.triangleCount < limit ? pair.triangleCount : limit;
        // count <= MAX_TRIANGLES
        for (uint256 i; i < count; ++i) {
            uint32[2] memory entry = pair.triangles[i];
            _addLoop(search, [search.origin, entry[0], entry[1], 0], 3);
        }
    }

    function _addQuads(Search memory search, Pair storage pair, uint256 limit) private view {
        uint256 count = pair.quadCount < limit ? pair.quadCount : limit;
        // count <= MAX_QUADS
        for (uint256 i; i < count; ++i) {
            uint32[3] memory entry = pair.quads[i];
            _addLoop(search, [search.origin, entry[0], entry[1], entry[2]], 4);
        }
    }

    /// @dev pools[0] is the origin; the saved loop walks from low through each pool's other token back to low. Adds the
    /// loop in both directions, starting and ending at the profit token. The walk reads each leg once: byte i of
    /// loopPath is pools[i]'s snapshot index, and bit i of forwardBits is set when pools[i] swaps token0 for token1 on
    /// the forward walk. The backward walk swaps every pool the other way.
    function _addLoop(Search memory search, uint32[4] memory pools, uint256 legs) private view {
        // This loop adds up to 4 pools and 2 cycles; keep their price and score cost plus everything already added.
        uint256 pricing = (search.snapshotCount + 4) * PRICE_GAS_PER_POOL;
        if (gasleft() < search.finishGas + pricing + (search.cycleCount + 2) * SCORE_GAS_PER_CYCLE) return;
        uint256 loopPath;
        uint256 forwardBits;
        uint32 from = search.low;
        // legs <= 4
        for (uint256 i; i < legs; ++i) {
            uint8 index = _snapshot(search, pools[i]);
            Snapshot memory snapshot = search.snapshots[index];
            bool zeroForOne = snapshot.token0 == from;
            loopPath |= uint256(index) << (i << 3);
            if (zeroForOne) forwardBits |= 1 << i;
            from = zeroForOne ? snapshot.token1 : snapshot.token0;
        }
        // The profit token is low or high, so a cycle starts at pool 0 (from low) or pool 1 (from high).
        uint256 start = search.low == search.tokenX ? 0 : 1;
        _addCycle(search, loopPath, forwardBits, legs, start, true);
        _addCycle(search, loopPath, forwardBits ^ ((1 << legs) - 1), legs, start, false);
    }

    /// @dev Leg k uses pool start + k on the forward walk, or pool start - 1 - k on the backward walk, modulo legs.
    function _addCycle(
        Search memory search,
        uint256 loopPath,
        uint256 directionBits,
        uint256 legs,
        uint256 start,
        bool forward
    ) private pure {
        uint256 path;
        uint256 directions;
        // 2 <= legs <= 4 and start <= 1, so no step below can overflow or underflow.
        unchecked {
            for (uint256 k; k < legs; ++k) {
                uint256 edge = forward ? (start + k) % legs : (start + legs - 1 - k) % legs;
                path |= ((loopPath >> (edge << 3)) & 0xff) << (k << 3);
                directions |= ((directionBits >> edge) & 1) << k;
            }
        }
        Cycle memory cycle = search.cycles[search.cycleCount++];
        cycle.legs = uint8(legs);
        cycle.path = uint32(path);
        cycle.directions = uint8(directions);
    }

    /// @dev Returns the pool's snapshot index, loading its record the first time.
    function _snapshot(Search memory search, uint32 pool) private view returns (uint8 index) {
        // Fibonacci hashing: the top 7 bits of the 32-bit product, so ids that share low bits spread out.
        uint256 slot = ((uint256(pool) * 2_654_435_761) & type(uint32).max) >> 25;
        // At most SNAPSHOT_TABLE_SIZE probes; the table always has an empty slot.
        for (uint256 probe; probe < SNAPSHOT_TABLE_SIZE; ++probe) {
            uint16 entry = search.table[slot];
            if (entry == 0) break;
            if (search.snapshots[entry - 1].pool == pool) return uint8(entry - 1);
            slot = (slot + 1) % SNAPSHOT_TABLE_SIZE;
        }
        index = uint8(search.snapshotCount++);
        search.table[slot] = uint16(index) + 1;
        Snapshot memory snapshot = search.snapshots[index];
        PoolRecord storage record = _state.pools[pool];
        snapshot.pool = pool;
        snapshot.id = record.id;
        snapshot.token0 = record.token0;
        snapshot.token1 = record.token1;
        snapshot.keyFee = record.fee;
        snapshot.tickSpacing = record.tickSpacing;
        snapshot.usable = record.active;
        snapshot.syncedLiquidity = record.liquidity;
    }

    /// @dev One batch read of every snapshot's slot0. Pools outside the valid price range or with a 100% fee are
    /// not usable.
    function _readPrices(Search memory search) private view {
        bytes32[] memory slots = new bytes32[](search.snapshotCount);
        // snapshotCount <= MAX_SNAPSHOTS
        for (uint256 i; i < slots.length; ++i) {
            slots[i] = _stateSlot(search.snapshots[i].id);
        }
        bytes32[] memory values = MANAGER.extsload(slots);
        // snapshotCount <= MAX_SNAPSHOTS
        for (uint256 i; i < values.length; ++i) {
            _parseSlot0(search.snapshots[i], uint256(values[i]));
        }
    }

    function _parseSlot0(Snapshot memory snapshot, uint256 value) private pure {
        uint160 sqrtPriceX96 = uint160(value);
        uint24 protocolFee = uint24(value >> 184);
        uint24 lpFee = uint24(value >> 208);
        snapshot.sqrtPriceX96 = sqrtPriceX96;
        snapshot.fee0 = protocolFee.getZeroForOneFee().calculateSwapFee(lpFee);
        snapshot.fee1 = protocolFee.getOneForZeroFee().calculateSwapFee(lpFee);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE) snapshot.usable = false;
        if (sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) snapshot.usable = false;
        if (snapshot.fee0 >= CycleMath.FEE_DENOMINATOR) snapshot.usable = false;
        if (snapshot.fee1 >= CycleMath.FEE_DENOMINATOR) snapshot.usable = false;
        if (!snapshot.usable) return;
        (snapshot.reserve0, snapshot.reserve1) = CycleMath.reserves(sqrtPriceX96, snapshot.syncedLiquidity);
    }

    /// @dev Live prices with the liquidity of the last sync: the gate is exact (it does not depend on liquidity)
    /// and the profit is an estimate that weights the price gap by stored depth.
    function _scoreCycles(Search memory search, uint256 maximumInput) private view {
        // cycleCount <= MAX_CYCLES
        for (uint256 i; i < search.cycleCount; ++i) {
            if (gasleft() < search.finishGas + SCORE_GAS_PER_CYCLE) return;
            Cycle memory cycle = search.cycles[i];
            (uint256 reserveIn, uint256 reserveOut, uint24 fee) = _fold(search, cycle);
            (, cycle.score) = CycleMath.optimize(reserveIn, reserveOut, fee, maximumInput);
        }
    }

    /// @dev Sizes the best-scored cycles with live liquidity. Only these cycles pay for liquidity reads.
    function _sizeBest(Search memory search, Limits calldata limits) private view {
        // limits.sized <= MAX_SIZED_CYCLES
        for (uint256 round; round < limits.sized; ++round) {
            (bool found, uint256 index) = _bestBy(search, true);
            if (!found) return;
            Cycle memory cycle = search.cycles[index];
            cycle.sized = true;
            _readLiquidity(search, cycle);
            (uint256 reserveIn, uint256 reserveOut, uint24 fee) = _fold(search, cycle);
            (cycle.input, cycle.profit) = CycleMath.optimize(reserveIn, reserveOut, fee, limits.maximumInput);
        }
    }

    /// @dev Tries sized cycles from the most profitable down: compatibility, then the exact quote.
    function _bestPlan(Search memory search, Limits calldata limits) private view returns (Plan memory plan) {
        // limits.sized <= MAX_SIZED_CYCLES
        for (uint256 round; round < limits.sized; ++round) {
            if (gasleft() < SEARCH_ATTEMPT_RESERVE_GAS) break;
            (bool found, uint256 index) = _bestBy(search, false);
            if (!found) break;
            Cycle memory cycle = search.cycles[index];
            cycle.tried = true;
            // Cycles come in falling profit order, so no later one meets the minimum either.
            if (cycle.profit < limits.minimumSurplus) break;
            if (!_compatibleCycle(search, cycle)) continue;
            (bool valid, Plan memory candidate) = _quote(search, cycle, limits);
            if (valid) return candidate;
        }
    }

    /// @dev Book-only opportunities. A resting LimitOrder order priced better than its pool's AMM is invisible to the
    /// AMM gate. Every same-pair cycle closes by buying the profit token, so each same-pair pool's book is previewed
    /// once in that direction, and its cycle is quoted at the size the book fills. The best exact surplus wins against
    /// the AMM plan. At most limits.sized candidates with orders, each with up to two previews, each behind the attempt
    /// gas guard. Known limits: the closing leg takes the whole affordable book (no partial sizing), and triangles and
    /// four-pool loops do not probe books.
    function _bestBookPlan(Search memory search, Limits calldata limits, Plan memory best)
        private
        view
        returns (Plan memory)
    {
        if (address(LIMIT_ORDERS) == address(0)) return best;
        uint256 bestSurplus = best.legs == 0 ? 0 : best.proceeds - best.input;
        uint256 filled;
        bool originDone;
        // cycleCount <= MAX_CYCLES; same-pair cycles come first and are the only two-leg cycles.
        for (uint256 i; i < search.cycleCount && filled < limits.sized; ++i) {
            Cycle memory cycle = search.cycles[i];
            if (cycle.legs != 2 || gasleft() < SEARCH_ATTEMPT_RESERVE_GAS) break;
            // Snapshot 0 is the origin, which closes one cycle per peer. Its book is tried with each peer in depth
            // order until one gives a plan, so a peer that cannot deliver the first leg does not hide the book.
            (uint256 closing,) = _leg(cycle, 1);
            if (closing == 0 && originDone) continue;
            (bool found, bool valid, Plan memory candidate) = _bookQuote(search, cycle, limits);
            if (found) ++filled;
            if (closing == 0 && valid) originDone = true;
            if (!valid || candidate.proceeds - candidate.input <= bestSurplus) continue;
            (best, bestSurplus) = (candidate, candidate.proceeds - candidate.input);
        }
        return best;
    }

    /// @dev Quotes a same-pair cycle whose closing leg fills the book; the first leg is quoted exactly for the book's
    /// input. found reports a preview that found orders.
    function _bookQuote(Search memory search, Cycle memory cycle, Limits calldata limits)
        private
        view
        returns (bool found, bool valid, Plan memory plan)
    {
        (uint256 closing,) = _leg(cycle, 1);
        // A preview costs about three times this read; most pools have no book.
        if (!_hasBook(search.snapshots[closing])) return (false, false, plan);
        uint128 bookInput = _bookFill(search, cycle, limits.maximumInput);
        if (bookInput == 0) return (false, false, plan);
        found = true;
        // The rest needs a second preview and the first-leg quote: one more attempt reserve.
        if (gasleft() < SEARCH_ATTEMPT_RESERVE_GAS) return (found, false, plan);
        if (!_compatibleCycle(search, cycle)) return (found, false, plan);
        plan.legs = 2;
        // legs == 2
        for (uint256 k; k < 2; ++k) {
            (uint256 index, bool zeroForOne) = _leg(cycle, k);
            (plan.keys[k], plan.zeroForOne[k]) = (_poolKey(search.snapshots[index]), zeroForOne);
        }
        uint256 required = _quoteBackward(plan, bookInput);
        if (required == 0 || required > limits.maximumInput) return (found, false, plan);
        // A book can fill differently at an exact input than under a larger budget (a range order can fill or be
        // skipped), so quote the closing leg again at the exact input, book first and then the AMM, as the route runs.
        PoolQuote.Quote memory sell = _quoteSell(plan.keys[1], plan.zeroForOne[1], bookInput);
        if (!sell.complete || sell.input != bookInput) return (found, false, plan);
        if (sell.output <= required || sell.output - required < limits.minimumSurplus) return (found, false, plan);
        (plan.amounts[1], plan.input, plan.proceeds) = (bookInput, uint128(required), sell.output);
        valid = true;
    }

    /// @dev The input the closing pool's book takes within the most the first leg can deliver for maximumInput, on
    /// live reserves. Zero when the first leg is not usable, nothing fills or the preview fails.
    function _bookFill(Search memory search, Cycle memory cycle, uint256 maximumInput) private view returns (uint128) {
        _readLiquidity(search, cycle);
        (uint256 reserveIn, uint256 reserveOut, uint24 fee) = _hop(search, cycle, 0);
        if (reserveIn == 0) return 0;
        uint256 budget = _min(CycleMath.output(reserveIn, reserveOut, fee, maximumInput), OrderMath.MAX_DELTA);
        (uint256 closing, bool zeroForOne) = _leg(cycle, 1);
        (bool valid, uint128 input,) = _previewBook(_poolKey(search.snapshots[closing]), zeroForOne, uint128(budget));
        return valid ? input : 0;
    }

    /// @dev byScore: the best unsized cycle by score. Otherwise: the best sized, untried cycle by profit.
    function _bestBy(Search memory search, bool byScore) private pure returns (bool found, uint256 best) {
        uint256 bestValue;
        // cycleCount <= MAX_CYCLES
        for (uint256 i; i < search.cycleCount; ++i) {
            Cycle memory cycle = search.cycles[i];
            uint256 value = byScore ? (cycle.sized ? 0 : cycle.score) : (cycle.sized && !cycle.tried ? cycle.profit : 0);
            if (value <= bestValue) continue;
            (found, best, bestValue) = (true, i, value);
        }
    }

    /// @dev Snapshot index and direction of leg k. Returns the index, not the struct: under the legacy code generator
    /// a memory struct return value allocates a zeroed copy on every call, and memory cost grows with its square.
    function _leg(Cycle memory cycle, uint256 k) private pure returns (uint256 index, bool zeroForOne) {
        index = uint8(cycle.path >> (k << 3));
        zeroForOne = (cycle.directions >> k) & 1 == 1;
    }

    /// @dev Leg k's reserves in its swap direction and its fee. Zero reserves when the pool is not usable.
    function _hop(Search memory search, Cycle memory cycle, uint256 k)
        private
        pure
        returns (uint256 reserveIn, uint256 reserveOut, uint24 fee)
    {
        (uint256 index, bool zeroForOne) = _leg(cycle, k);
        Snapshot memory snapshot = search.snapshots[index];
        if (zeroForOne) return (snapshot.reserve0, snapshot.reserve1, snapshot.fee0);
        return (snapshot.reserve1, snapshot.reserve0, snapshot.fee1);
    }

    /// @dev Folds the cycle into one equivalent pool and returns it with the first leg's fee. Zeros when a leg is not
    /// usable.
    function _fold(Search memory search, Cycle memory cycle)
        private
        pure
        returns (uint256 reserveIn, uint256 reserveOut, uint24 firstFee)
    {
        (uint256 path, uint256 directions) = (cycle.path, cycle.directions);
        // legs <= 4
        for (uint256 k; k < cycle.legs; ++k) {
            Snapshot memory snapshot = search.snapshots[(path >> (k << 3)) & 0xff];
            (uint256 hopIn, uint256 hopOut, uint24 fee) = (directions >> k) & 1 == 1
                ? (snapshot.reserve0, snapshot.reserve1, snapshot.fee0)
                : (snapshot.reserve1, snapshot.reserve0, snapshot.fee1);
            if (hopIn == 0) return (0, 0, 0);
            if (k == 0) (reserveIn, reserveOut, firstFee) = (hopIn, hopOut, fee);
            else (reserveIn, reserveOut) = CycleMath.fold(reserveIn, reserveOut, hopIn, hopOut, fee);
        }
    }

    /// @dev Reads each leg's live liquidity once and moves its reserves from synced to live.
    function _readLiquidity(Search memory search, Cycle memory cycle) private view {
        // legs <= 4
        for (uint256 k; k < cycle.legs; ++k) {
            (uint256 index,) = _leg(cycle, k);
            Snapshot memory snapshot = search.snapshots[index];
            if (snapshot.liquidityRead) continue;
            snapshot.liquidity = uint128(uint256(MANAGER.extsload(bytes32(uint256(_stateSlot(snapshot.id)) + 3))));
            snapshot.liquidityRead = true;
            if (snapshot.usable) {
                (snapshot.reserve0, snapshot.reserve1) = CycleMath.reserves(snapshot.sqrtPriceX96, snapshot.liquidity);
            }
        }
    }

    /// @dev Only reviewed pricing profiles: at most the LimitOrder book before swaps and the calling hook after.
    function _compatibleCycle(Search memory search, Cycle memory cycle) private view returns (bool) {
        // legs <= 4
        for (uint256 k; k < cycle.legs; ++k) {
            (uint256 index,) = _leg(cycle, k);
            Snapshot memory snapshot = search.snapshots[index];
            if (snapshot.compatibility == 0) snapshot.compatibility = _compatible(snapshot.id) ? 1 : 2;
            if (snapshot.compatibility == 2) return false;
        }
        return true;
    }

    /// @dev LimitOrder is the pool's only BeforeSwap subscriber, the one book setup that _compatible accepts.
    /// Read once per pool and kept in the snapshot, because the origin's book can be tried with several peers.
    function _hasBook(Snapshot memory snapshot) private view returns (bool) {
        if (snapshot.book == 0) {
            address[] memory beforeOrder = KERNEL.callbackOrder(snapshot.id, CallbackType.BeforeSwap);
            snapshot.book = beforeOrder.length == 1 && beforeOrder[0] == address(LIMIT_ORDERS) ? 1 : 2;
        }
        return snapshot.book == 1;
    }

    function _compatible(PoolId id) private view returns (bool) {
        address[] memory beforeOrder = KERNEL.callbackOrder(id, CallbackType.BeforeSwap);
        address[] memory afterOrder = KERNEL.callbackOrder(id, CallbackType.AfterSwap);
        if (beforeOrder.length > 1 || afterOrder.length > 1) return false;
        if (beforeOrder.length == 1 && beforeOrder[0] != address(LIMIT_ORDERS)) return false;
        if (afterOrder.length == 1 && afterOrder[0] != msg.sender) return false;
        return true;
    }

    /// @dev Exact quote of the cycle: closing input from the closed-form size, then exact-output quotes from the
    /// second-to-last leg back to the first, then the closing exact-input quote including the LimitOrder book.
    function _quote(Search memory search, Cycle memory cycle, Limits calldata limits)
        private
        view
        returns (bool valid, Plan memory plan)
    {
        uint256 legs = cycle.legs;
        uint256 closingInput = cycle.input;
        plan.legs = uint8(legs);
        // legs <= 4
        for (uint256 k; k < legs; ++k) {
            (uint256 index, bool zeroForOne) = _leg(cycle, k);
            plan.keys[k] = _poolKey(search.snapshots[index]);
            plan.zeroForOne[k] = zeroForOne;
            if (k + 1 == legs) break;
            (uint256 reserveIn, uint256 reserveOut, uint24 fee) = _hop(search, cycle, k);
            closingInput = CycleMath.output(reserveIn, reserveOut, fee, closingInput);
        }
        if (closingInput == 0 || closingInput > OrderMath.MAX_DELTA) return (false, plan);
        uint256 required = _quoteBackward(plan, closingInput);
        // The closed form caps its estimate; the exact first-leg input can round above it, so check it too.
        if (required == 0 || required > limits.maximumInput) return (false, plan);
        PoolQuote.Quote memory sell = _quoteSell(plan.keys[legs - 1], plan.zeroForOne[legs - 1], uint128(closingInput));
        if (!sell.complete || sell.input != closingInput) return (false, plan);
        if (sell.output <= required || sell.output - required < limits.minimumSurplus) return (false, plan);
        plan.amounts[legs - 1] = uint128(closingInput);
        plan.input = uint128(required);
        plan.proceeds = sell.output;
        valid = true;
    }

    /// @dev Returns the first leg's input in the profit currency, or zero when a leg cannot be quoted exactly.
    function _quoteBackward(Plan memory plan, uint256 closingInput) private view returns (uint256 required) {
        required = closingInput;
        // legs <= 4
        for (uint256 k = plan.legs - 1; k > 0; --k) {
            uint256 leg = k - 1;
            PoolQuote.Quote memory quote = _safeQuote(plan.keys[leg], plan.zeroForOne[leg], int256(required));
            if (!quote.complete || quote.output != required || quote.input == 0) return 0;
            plan.amounts[leg] = uint128(required);
            required = quote.input;
        }
    }

    /// @dev Exact-input quote: the bounded LimitOrder preview first, then the AMM for the remainder.
    function _quoteSell(PoolKey memory key, bool zeroForOne, uint128 quantity)
        private
        view
        returns (PoolQuote.Quote memory result)
    {
        if (address(LIMIT_ORDERS) != address(0)) {
            (bool valid, uint128 bookInput, uint128 bookOutput) = _previewBook(key, zeroForOne, quantity);
            if (!valid) return result;
            (result.input, result.output) = (bookInput, bookOutput);
        }
        PoolQuote.Quote memory amm = _safeQuote(key, zeroForOne, -int256(uint256(quantity - result.input)));
        uint256 totalOutput = uint256(result.output) + amm.output;
        if (!amm.complete || totalOutput > OrderMath.MAX_DELTA) return result;
        result.input += amm.input;
        result.output = uint128(totalOutput);
        result.complete = result.input == quantity;
    }

    /// @dev The bounded, nested LimitOrder preview of an exact-input fill. valid is false when the read fails or
    /// returns values out of range; a pool without a ready book returns valid with zero amounts.
    function _previewBook(PoolKey memory key, bool zeroForOne, uint128 budget)
        private
        view
        returns (bool valid, uint128 input, uint128 output)
    {
        (bool success, bytes memory data) = address(LIMIT_ORDERS)
            .read(
                PREVIEW_GAS,
                PREVIEW_BYTES,
                abi.encodeCall(LimitOrder.previewFill, (key.toId(), zeroForOne, budget, true))
            );
        if (!success || data.length != PREVIEW_BYTES) return (false, 0, 0);
        // FillPreview has eight static words: input, output, ..., available.
        uint256 orderInput = _word(data, 0);
        uint256 orderOutput = _word(data, 32);
        uint256 available = _word(data, 224);
        if (orderInput > budget || orderOutput > OrderMath.MAX_DELTA || available > 1) return (false, 0, 0);
        if (available == 0) return (true, 0, 0);
        return (true, uint128(orderInput), uint128(orderOutput));
    }

    /// @dev An incomplete quote when the quote reverts. An out-of-gas quote leaves 1/64 of the gas; the search then
    /// stops at its next gas guard, and the hook's bounded read treats a failed search as no plan.
    function _safeQuote(PoolKey memory key, bool zeroForOne, int256 amount)
        private
        view
        returns (PoolQuote.Quote memory quote)
    {
        try this.quoteLeg(key, zeroForOne, amount) returns (PoolQuote.Quote memory result) {
            quote = result;
        } catch {}
    }

    function _poolKey(Snapshot memory snapshot) private view returns (PoolKey memory) {
        return PoolKey(
            currencyOf[snapshot.token0],
            currencyOf[snapshot.token1],
            snapshot.keyFee,
            snapshot.tickSpacing,
            IHooks(address(KERNEL))
        );
    }

    function _stateSlot(PoolId id) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(id), StateLibrary.POOLS_SLOT));
    }
}
