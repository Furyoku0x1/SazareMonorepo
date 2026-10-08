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

    function load(Pool memory pool) internal view returns (Cursor memory c) {
        (c.sqrtPriceX96, c.tick,,) = pool.manager.getSlot0(pool.id);
        c.liquidity = pool.manager.getLiquidity(pool.id);
    }

    /// @notice The fee `Pool.swap` charges: the LP fee combined with the directional protocol fee.
    function swapFee(IPoolManager manager, PoolId id, bool zeroForOne, uint24 lpFee) internal view returns (uint24) {
        (,, uint24 protocolFee,) = manager.getSlot0(id);
        uint16 fee = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        return fee == 0 ? lpFee : fee.calculateSwapFee(lpFee);
    }

    function next(Pool memory pool, Cursor memory c) internal view returns (Step memory s) {
        s.start = c.sqrtPriceX96;
        (s.tickNext, s.initialized) = _nextInitializedTickWithinOneWord(pool, c.tick);
        if (s.tickNext <= TickMath.MIN_TICK) s.tickNext = TickMath.MIN_TICK;
        if (s.tickNext >= TickMath.MAX_TICK) s.tickNext = TickMath.MAX_TICK;
        s.tickPrice = TickMath.getSqrtPriceAtTick(s.tickNext);
        s.target = SwapMath.getSqrtPriceTarget(pool.zeroForOne, s.tickPrice, pool.limit);
    }

    /// @notice Moves the cursor to `price` at the end of step `s`, as `Pool.swap` does.
    function move(Pool memory pool, Cursor memory c, Step memory s, uint160 price) internal view {
        c.sqrtPriceX96 = price;
        if (price == s.tickPrice) {
            if (s.initialized) {
                (, int128 net) = pool.manager.getTickLiquidity(pool.id, s.tickNext);
                if (pool.zeroForOne) net = -net;
                c.liquidity = LiquidityMath.addDelta(c.liquidity, net);
            }
            c.tick = pool.zeroForOne ? s.tickNext - 1 : s.tickNext;
        } else if (price != s.start) {
            c.tick = TickMath.getTickAtSqrtPrice(price);
        }
    }

    /// @notice Where `Pool.swap(amountSpecified)` leaves the pool, and its amounts. `complete` is false when
    /// the swap needs more than `maxSteps` steps; the result is then where the replay stopped.
    /// @dev Preconditions, which `Pool.swap` checks and this replay does not: the price limit lies on the swap's
    /// side of the price and within the price bounds; no exact output at a 100% fee; totals fit int128. The
    /// caller resolves any dynamic LP fee override into `pool.fee`.
    function swap(Pool memory pool, int256 amountSpecified, uint256 maxSteps) internal view returns (Result memory r) {
        return swapFrom(pool, load(pool), amountSpecified, maxSteps);
    }

    /// @notice As `swap`, starting from cursor `c` instead of the pool's current state. Tick data is read
    /// from the pool, so `c` must be a state the pool could be in now.
    function swapFrom(Pool memory pool, Cursor memory c, int256 amountSpecified, uint256 maxSteps)
        internal
        view
        returns (Result memory r)
    {
        int256 remaining = amountSpecified;
        r.complete = true;
        while (amountSpecified != 0 && !(remaining == 0 || c.sqrtPriceX96 == pool.limit)) {
            if (r.steps == maxSteps) {
                r.complete = false;
                break;
            }
            ++r.steps;
            Step memory s = next(pool, c);
            (uint160 price, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
                SwapMath.computeSwapStep(c.sqrtPriceX96, s.target, c.liquidity, remaining, pool.fee);
            if (amountSpecified > 0) {
                remaining -= int256(amountOut);
                r.other += amountIn + feeAmount;
            } else {
                remaining += int256(amountIn + feeAmount);
                r.other += amountOut;
            }
            move(pool, c, s, price);
        }
        r.sqrtPriceX96 = c.sqrtPriceX96;
        r.tick = c.tick;
        r.liquidity = c.liquidity;
        r.specified = amountSpecified > 0 ? uint256(amountSpecified - remaining) : uint256(remaining - amountSpecified);
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
            if (pool.zeroForOne) {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(compressed);
                uint256 mask = type(uint256).max >> (uint256(type(uint8).max) - bitPos);
                uint256 masked = pool.manager.getTickBitmap(pool.id, wordPos) & mask;
                initialized = masked != 0;
                tickNext = initialized
                    ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * spacing
                    : (compressed - int24(uint24(bitPos))) * spacing;
            } else {
                (int16 wordPos, uint8 bitPos) = TickBitmap.position(++compressed);
                uint256 mask = ~((1 << bitPos) - 1);
                uint256 masked = pool.manager.getTickBitmap(pool.id, wordPos) & mask;
                initialized = masked != 0;
                tickNext = initialized
                    ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * spacing
                    : (compressed + int24(uint24(type(uint8).max - bitPos))) * spacing;
            }
        }
    }
}
