// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @notice Read-only copy of the step loop of v4 `Pool.swap` (Pool.sol:344-427) over a live pool: the same
/// step schedule (initialized ticks and bitmap-word edges), tick tracking and `SwapMath` rounding.
library AmmReplay {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    /// @dev Remaining amounts large enough that every step reaches its target.
    int256 internal constant ALL_IN = type(int256).min + 1;
    int256 internal constant ALL_OUT = type(int256).max;

    struct Pool {
        IPoolManager manager;
        PoolId id;
        int24 tickSpacing;
        bool zeroForOne;
        uint160 limit;
        uint24 fee;
    }

    struct Cursor {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
    }

    struct Step {
        uint160 start;
        uint160 tickPrice; // Pool.swap's sqrtPriceNextX96
        uint160 target;
        int24 tickNext;
        bool initialized;
    }

    struct Result {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 specified; // consumed (exact input) or delivered (exact output)
        uint256 other;
        uint256 steps;
        bool complete;
    }

    function load(Pool memory pool) internal view returns (Cursor memory cursor) {
        (cursor.sqrtPriceX96, cursor.tick,,) = pool.manager.getSlot0(pool.id);
        cursor.liquidity = pool.manager.getLiquidity(pool.id);
    }

    /// @notice The fee `Pool.swap` charges: the LP fee combined with the directional protocol fee.
    function swapFee(IPoolManager manager, PoolId id, bool zeroForOne, uint24 lpFeePips)
        internal
        view
        returns (uint24)
    {
        (,, uint24 protocolFeePips,) = manager.getSlot0(id);
        uint16 feePips = zeroForOne ? protocolFeePips.getZeroForOneFee() : protocolFeePips.getOneForZeroFee();
        return feePips == 0 ? lpFeePips : feePips.calculateSwapFee(lpFeePips);
    }

    function next(Pool memory pool, Cursor memory cursor) internal view returns (Step memory step) {
        step.start = cursor.sqrtPriceX96;
        (step.tickNext, step.initialized) = _nextInitializedTickWithinOneWord(pool, cursor.tick);
        if (step.tickNext <= TickMath.MIN_TICK) step.tickNext = TickMath.MIN_TICK;
        if (step.tickNext >= TickMath.MAX_TICK) step.tickNext = TickMath.MAX_TICK;
        step.tickPrice = TickMath.getSqrtPriceAtTick(step.tickNext);
        step.target = SwapMath.getSqrtPriceTarget(pool.zeroForOne, step.tickPrice, pool.limit);
    }

    /// @notice Moves the cursor to `price` at the end of step `s`, as `Pool.swap` does.
    function move(Pool memory pool, Cursor memory cursor, Step memory step, uint160 sqrtPriceX96) internal view {
        cursor.sqrtPriceX96 = sqrtPriceX96;
        if (sqrtPriceX96 == step.tickPrice) {
            if (step.initialized) _crossTick(pool, cursor, step.tickNext);
            cursor.tick = pool.zeroForOne ? step.tickNext - 1 : step.tickNext;
        } else if (sqrtPriceX96 != step.start) {
            cursor.tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        }
    }

    /// @notice Where `Pool.swap(amountSpecified)` leaves the pool, and its amounts. `complete` is false when
    /// the swap needs more than `maxSteps` steps; the result is then where the replay stopped.
    /// @dev Preconditions, which `Pool.swap` checks and this replay does not: the price limit lies on the swap's
    /// side of the price and within the price bounds; no exact output at a 100% fee; totals fit int128. The
    /// caller resolves any dynamic LP fee override into `pool.fee`.
    function swap(Pool memory pool, int256 amountSpecified, uint256 maxSteps)
        internal
        view
        returns (Result memory result)
    {
        return swapFrom(pool, load(pool), amountSpecified, maxSteps);
    }

    /// @notice As `swap`, starting from cursor `c` instead of the pool's current state. Tick data is read
    /// from the pool, so `c` must be a state the pool could be in now.
    function swapFrom(Pool memory pool, Cursor memory cursor, int256 amountSpecified, uint256 maxSteps)
        internal
        view
        returns (Result memory result)
    {
        int256 remaining = amountSpecified;
        result.complete = true;
        // result.steps <= maxSteps; one final iteration may detect the cap.
        while (amountSpecified != 0) {
            if (remaining == 0) break;
            if (cursor.sqrtPriceX96 == pool.limit) break;
            if (result.steps == maxSteps) {
                result.complete = false;
                break;
            }
            ++result.steps;
            Step memory step = next(pool, cursor);
            (uint160 sqrtPriceX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
                SwapMath.computeSwapStep(cursor.sqrtPriceX96, step.target, cursor.liquidity, remaining, pool.fee);
            if (amountSpecified > 0) {
                remaining -= int256(amountOut);
                result.other += amountIn + feeAmount;
            } else {
                remaining += int256(amountIn + feeAmount);
                result.other += amountOut;
            }
            move(pool, cursor, step, sqrtPriceX96);
        }
        result.sqrtPriceX96 = cursor.sqrtPriceX96;
        result.tick = cursor.tick;
        result.liquidity = cursor.liquidity;
        result.specified =
            amountSpecified > 0 ? uint256(amountSpecified - remaining) : uint256(remaining - amountSpecified);
    }

    /// @dev TickBitmap.nextInitializedTickWithinOneWord, reading the pool's words through StateLibrary.
    function _nextInitializedTickWithinOneWord(Pool memory pool, int24 tick)
        private
        view
        returns (int24 tickNext, bool initialized)
    {
        unchecked {
            int24 spacing = pool.tickSpacing;
            int24 compressed = TickBitmap.compress(tick, spacing);
            if (pool.zeroForOne) return _nextDown(pool, compressed, spacing);
            return _nextUp(pool, compressed, spacing);
        }
    }

    function _nextDown(Pool memory pool, int24 compressed, int24 spacing)
        private
        view
        returns (int24 tickNext, bool initialized)
    {
        unchecked {
            (int16 wordPosition, uint8 bitPosition) = TickBitmap.position(compressed);
            uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPosition);
            uint256 masked = pool.manager.getTickBitmap(pool.id, wordPosition) & mask;
            initialized = masked != 0;
            tickNext = initialized
                ? (compressed - int24(uint24(bitPosition - BitMath.mostSignificantBit(masked)))) * spacing
                : (compressed - int24(uint24(bitPosition))) * spacing;
        }
    }

    function _nextUp(Pool memory pool, int24 compressed, int24 spacing)
        private
        view
        returns (int24 tickNext, bool initialized)
    {
        unchecked {
            (int16 wordPosition, uint8 bitPosition) = TickBitmap.position(++compressed);
            uint256 mask = ~((1 << bitPosition) - 1);
            uint256 masked = pool.manager.getTickBitmap(pool.id, wordPosition) & mask;
            initialized = masked != 0;
            tickNext = initialized
                ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPosition))) * spacing
                : (compressed + int24(uint24(type(uint8).max - bitPosition))) * spacing;
        }
    }

    function _crossTick(Pool memory pool, Cursor memory cursor, int24 nextTick) private view {
        (, int128 net) = pool.manager.getTickLiquidity(pool.id, nextTick);
        if (pool.zeroForOne) net = -net;
        cursor.liquidity = LiquidityMath.addDelta(cursor.liquidity, net);
    }
}
