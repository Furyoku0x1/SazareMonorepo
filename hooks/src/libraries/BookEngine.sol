// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {Operation, RouteAction} from "core/src/types/KernelHookTypes.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IExtensionVault} from "../base/KernelExtension.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {AmmReplay} from "./AmmReplay.sol";
import {BookWalk} from "./BookWalk.sol";

/// @notice The deployed form of the swap walk: the order book extension delegates to it, so the walk's code does not
/// count against the extension's size. It holds no state; the extension passes its pool's book as storage.
library BookEngine {
    using StateLibrary for IPoolManager;

    uint256 internal constant REPLAY_CAP = 4096;

    error RouteMismatch();

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

    /// @notice Runs one of the book's same-pool routes, in the book's context: with no target, a donation of the
    /// amounts to LPs; with one, a swap that moves an empty pool's price there and trades nothing. It reverts unless
    /// the book's vault balances fell by exactly the amounts and a move landed on its target. Another extension's
    /// charge or credit on the route, or a payment settled for the route executor, would otherwise leave the vault
    /// apart from the ledger.
    function route(
        IKernelHook kernel,
        IExtensionVault vault,
        IPoolManager manager,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        uint160 target
    ) external {
        PoolId pool = key.toId();
        RouteAction[] memory actions = new RouteAction[](1);
        if (target == 0) {
            actions[0] = RouteAction(key, Operation.Donate, abi.encode(amount0, amount1), "");
        } else {
            (uint160 price,,,) = manager.getSlot0(pool);
            actions[0] = RouteAction(key, Operation.Swap, abi.encode(SwapParams(target < price, -1, target)), "");
        }
        uint256 held0 = vault.balanceOf(pool, address(this), key.currency0);
        uint256 held1 = vault.balanceOf(pool, address(this), key.currency1);
        kernel.executeRoute(actions);
        if (target != 0) {
            (uint160 price,,,) = manager.getSlot0(pool);
            if (price != target) revert RouteMismatch();
        }
        // A balance that rose reverts here too.
        if (
            held0 - vault.balanceOf(pool, address(this), key.currency0) != amount0
                || held1 - vault.balanceOf(pool, address(this), key.currency1) != amount1
        ) revert RouteMismatch();
    }
}
