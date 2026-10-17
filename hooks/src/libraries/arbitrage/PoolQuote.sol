// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {OrderMath} from "../limitorder/OrderMath.sol";

/// @dev Read-only quotes within current active liquidity, using upstream rounding/fee math.
/// Crossing an initialized tick or a nonzero-length bitmap step is excluded. Empty zero-length
/// boundaries can be skipped, up to four reads. This preserves v4's per-step fee rounding.
/// This conservative scope keeps a single Arbitrage deployment small and bounds cold reads.
library PoolQuote {
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    struct Quote {
        uint128 input;
        uint128 output;
        bool complete;
    }

    struct State {
        uint160 price;
        int24 tick;
        uint128 liquidity;
        uint24 fee;
        uint256 input;
        uint256 output;
    }

    function quote(IPoolManager manager, PoolKey memory key, bool zeroForOne, int256 amount)
        internal
        view
        returns (Quote memory result)
    {
        if (amount == 0) return Quote(0, 0, true);
        PoolId pool = key.toId();
        State memory state;
        {
            uint24 protocolFee;
            uint24 lpFee;
            (state.price, state.tick, protocolFee, lpFee) = manager.getSlot0(pool);
            uint16 directionalFee = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
            state.fee = directionalFee.calculateSwapFee(lpFee);
        }
        if (state.price < TickMath.MIN_SQRT_PRICE || state.price >= TickMath.MAX_SQRT_PRICE) return result;
        if (state.fee >= 1_000_000) return result;
        state.liquidity = manager.getLiquidity(pool);
        if (state.liquidity == 0) return result;
        uint160 endPrice = _amounts(state, amount, zeroForOne);
        if (state.input > OrderMath.MAX_DELTA || state.output > OrderMath.MAX_DELTA) return result;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if ((zeroForOne && endPrice <= limit) || (!zeroForOne && endPrice >= limit)) return result;
        for (uint256 reads; reads < 4; ++reads) {
            (int24 next, bool initialized) = _nextTick(manager, pool, state.tick, key.tickSpacing, zeroForOne);
            if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            uint160 boundary = TickMath.getSqrtPriceAtTick(next);
            bool inside = zeroForOne ? endPrice > boundary : endPrice < boundary;
            if (inside) return Quote(uint128(state.input), uint128(state.output), true);
            if (initialized || boundary != state.price) return result;
            state.tick = zeroForOne ? next - 1 : next;
        }
    }

    function _amounts(State memory state, int256 amount, bool zeroForOne) private pure returns (uint160 endPrice) {
        if (amount < 0) {
            state.input = uint256(-amount);
            uint256 netInput = FullMath.mulDiv(state.input, 1_000_000 - state.fee, 1_000_000);
            endPrice = SqrtPriceMath.getNextSqrtPriceFromInput(state.price, state.liquidity, netInput, zeroForOne);
            state.output = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(endPrice, state.price, state.liquidity, false)
                : SqrtPriceMath.getAmount0Delta(state.price, endPrice, state.liquidity, false);
        } else {
            state.output = uint256(amount);
            endPrice = SqrtPriceMath.getNextSqrtPriceFromOutput(state.price, state.liquidity, state.output, zeroForOne);
            uint256 input = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(endPrice, state.price, state.liquidity, true)
                : SqrtPriceMath.getAmount1Delta(state.price, endPrice, state.liquidity, true);
            state.input = input + FullMath.mulDivRoundingUp(input, state.fee, 1_000_000 - state.fee);
        }
    }

    /// @dev Same word selection as v4 TickBitmap, with bitmap storage read through StateLibrary.
    function _nextTick(IPoolManager manager, PoolId pool, int24 tick, int24 spacing, bool lte)
        private
        view
        returns (int24 next, bool initialized)
    {
        int24 compressed = TickBitmap.compress(tick, spacing);
        if (!lte) ++compressed;
        (int16 word, uint8 bit) = TickBitmap.position(compressed);
        uint256 bitmap = manager.getTickBitmap(pool, word);
        uint256 masked = lte ? bitmap & (type(uint256).max >> (255 - bit)) : bitmap & ~((uint256(1) << bit) - 1);
        initialized = masked != 0;
        int24 offset = lte
            ? int24(uint24(initialized ? bit - BitMath.mostSignificantBit(masked) : bit))
            : int24(uint24(initialized ? BitMath.leastSignificantBit(masked) - bit : 255 - bit));
        next = (lte ? compressed - offset : compressed + offset) * spacing;
    }
}
