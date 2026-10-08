// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {AmmReplay} from "./AmmReplay.sol";
import {BookWalk} from "./BookWalk.sol";

/// @notice The deployed form of the swap walk: the order book extension delegates to it, so the walk's code does not
/// count against the extension's size. It holds no state; the extension passes its pool's book as storage.
library BookEngine {
    using StateLibrary for IPoolManager;

    uint256 internal constant REPLAY_CAP = 4096;

    /// @notice Plans and commits a swap's book fills.
    /// @return fill What the book trades with the taker.
    /// @return makerFee Maker fees on the fills, rounded down, in the input currency.
    function execute(BookWalk.PoolBook storage book, BookWalk.Request memory request)
        external
        returns (BookWalk.Fill memory fill, uint256 makerFee)
    {
        BookWalk.Plan memory plan = BookWalk.plan(book, request);
        makerFee = BookWalk.commit(book, request, plan);
        fill = plan.fill;
    }

    /// @notice What a swap's book fills would be, by the same code without writes.
    function quote(BookWalk.PoolBook storage book, BookWalk.Request memory request)
        external
        view
        returns (BookWalk.Fill memory)
    {
        return BookWalk.plan(book, request).fill;
    }

    /// @notice With no AMM liquidity between the pool price and the book's frontier, the price the pool can move to
    /// with a swap that trades nothing, so it shows the last trade; 0 when it cannot.
    /// @param lpFee The pool's LP fee; with no liquidity between, only the step schedule matters.
    function syncTarget(IPoolManager manager, PoolId id, int24 tickSpacing, uint24 lpFee, uint160 frontier)
        external
        view
        returns (uint160 target)
    {
        AmmReplay.Pool memory pool;
        pool.manager = manager;
        pool.id = id;
        AmmReplay.Cursor memory c = AmmReplay.load(pool);
        if (frontier == c.sqrtPriceX96) return 0;
        // A swap limit must lie strictly inside the price bounds.
        if (frontier <= TickMath.MIN_SQRT_PRICE || frontier >= TickMath.MAX_SQRT_PRICE) return 0;
        bool down = frontier < c.sqrtPriceX96;
        pool.tickSpacing = tickSpacing;
        pool.zeroForOne = down;
        pool.limit = frontier;
        pool.fee = AmmReplay.swapFee(manager, id, down, lpFee);
        AmmReplay.Result memory r = AmmReplay.swapFrom(pool, c, -1, REPLAY_CAP);
        if (r.complete && r.specified == 0 && r.sqrtPriceX96 == frontier) return frontier;
    }
}
