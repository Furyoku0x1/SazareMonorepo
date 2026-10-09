// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedBook} from "./FixedBook.sol";
import {RangeBook} from "./RangeBook.sol";
import {BookWalk} from "./BookWalk.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {Operation, RouteAction} from "core/src/types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IExtensionVault} from "../base/KernelExtension.sol";

interface IDepositVault {
    function deposit(PoolId pool, address extension, Currency currency, uint256 amount) external payable;
}

/// @notice The deployed form of the makers' operations on a pool's book: placing, cancelling and claiming fixed and
/// range orders; and of the book's same-pool routes from afterSwap. The order book extension delegates to it and keeps
/// custody, fees and payments itself.
library BookOrders {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint256 internal constant PIPS = 1_000_000;
    /// @dev A single order, and a fixed level's live total and its cost, stay below these, so a level always fits the
    /// walk's amounts.
    uint256 internal constant MAX_ORDER_AMOUNT = 1 << 120;
    uint256 internal constant MAX_LEVEL_AMOUNT = 1 << 124;

    error InvalidOrder();
    error Crossing();
    error InvalidAmount();
    error TransferMismatch();
    error RouteMismatch();

    /// @notice Moves a maker's deposit into the extension's vault balance, with exact-amount checks. Runs in the
    /// extension's context: the maker is msg.sender, and pays msg.value for native currency.
    function deposit(address vault, PoolId pool, Currency currency, uint256 amount) external {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            if (msg.value != amount) revert InvalidAmount();
            IDepositVault(vault).deposit{value: amount}(pool, address(this), currency, amount);
            return;
        }
        if (msg.value != 0) revert InvalidAmount();
        IERC20 asset = IERC20(token);
        uint256 held = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (asset.balanceOf(address(this)) - held != amount) revert TransferMismatch();
        asset.forceApprove(vault, amount);
        IDepositVault(vault).deposit(pool, address(this), currency, amount);
        asset.forceApprove(vault, 0);
        if (asset.balanceOf(address(this)) != held) revert TransferMismatch();
    }

    /// @dev Where an order goes, and the pool's terms for it.
    struct Placement {
        IPoolManager manager;
        PoolId pool;
        address owner;
        bool sell0;
        uint24 feePips;
        uint256 lotSize; // the sold currency's, for fixed orders
        uint128 minLiquidity; // for range orders
    }

    /// @notice Places a fixed order, post-only, within the level bounds.
    /// @return id The order.
    /// @return amount Its deposit: lots times the lot size.
    function placeFixed(BookWalk.PoolBook storage book, Placement memory o, int24 tick, uint64 lots)
        external
        returns (uint256 id, uint256 amount)
    {
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        _postOnly(book, o, price);
        id = FixedBook.place(book.fixedOrders, o.owner, o.sell0, tick, lots, o.feePips);
        BookWalk.noteOrder(book, o.sell0, price, price);
        amount = uint256(lots) * o.lotSize;
        uint256 level = uint256(FixedBook.live(book.fixedOrders.sides[o.sell0 ? 0 : 1], tick)) * o.lotSize;
        if (amount > MAX_ORDER_AMOUNT || level > MAX_LEVEL_AMOUNT || _proceeds(o.sell0, price, level) >= MAX_LEVEL_AMOUNT) {
            revert InvalidOrder();
        }
    }

    /// @notice Places a range order, post-only, of at least the minimum liquidity.
    /// @return id The order.
    /// @return amount Its deposit, rounded up.
    function placeRange(BookWalk.PoolBook storage book, Placement memory o, int24 lower, int24 upper, uint128 liquidity)
        external
        returns (uint256 id, uint256 amount)
    {
        if (liquidity < o.minLiquidity) revert InvalidOrder();
        uint160 low = TickMath.getSqrtPriceAtTick(lower);
        uint160 high = TickMath.getSqrtPriceAtTick(upper);
        _postOnly(book, o, o.sell0 ? low : high);
        id = RangeBook.place(book.ranges, o.owner, o.sell0, lower, upper, liquidity, o.feePips);
        BookWalk.noteOrder(book, o.sell0, o.sell0 ? low : high, o.sell0 ? high : low);
        amount = o.sell0
            ? SqrtPriceMath.getAmount0Delta(low, high, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(low, high, liquidity, true);
        if (amount > MAX_ORDER_AMOUNT) revert InvalidOrder();
    }

    /// @return refund Unfilled lots returned.
    /// @return sell0 The order's side.
    /// @return settled Whether nothing is left to claim.
    function cancelFixed(BookWalk.PoolBook storage book, uint256 id, address caller)
        external
        returns (uint64 refund, bool sell0, bool settled)
    {
        (, refund) = FixedBook.cancel(book.fixedOrders, id, caller);
        sell0 = book.fixedOrders.orders[id].sell0;
        settled = _fixedSettled(book, id);
    }

    function cancelRange(BookWalk.PoolBook storage book, uint256 id, address caller)
        external
        returns (uint256 refund, bool sell0, bool settled)
    {
        refund = RangeBook.cancel(book.ranges, id, caller);
        sell0 = book.ranges.ranges[id].sell0;
        settled = _rangeSettled(book, id);
    }

    /// @notice A fixed order's net proceeds since its last claim: x - ceil(r x) of its cumulative gross proceeds x
    /// (filled lots at its price, rounded down), less what earlier claims paid.
    /// @param lotSize The sold currency's lot size.
    function claimFixed(BookWalk.PoolBook storage book, uint256 id, address caller, uint256 lotSize)
        external
        returns (uint256 net, bool sell0, bool settled)
    {
        FixedBook.Order storage order = book.fixedOrders.orders[id];
        uint256 before = order.claimed;
        (uint64 lots, uint24 feePips) = FixedBook.claim(book.fixedOrders, id, caller);
        sell0 = order.sell0;
        if (lots != 0) {
            uint160 price = TickMath.getSqrtPriceAtTick(order.tick);
            net = _net(_proceeds(sell0, price, (before + lots) * lotSize), feePips)
                - _net(_proceeds(sell0, price, before * lotSize), feePips);
        }
        settled = _fixedSettled(book, id);
    }

    /// @notice A range order's net proceeds since its last claim, as for fixed orders.
    function claimRange(BookWalk.PoolBook storage book, uint256 id, address caller)
        external
        returns (uint256 net, bool sell0, bool settled)
    {
        uint256 before = book.ranges.ranges[id].claimed;
        (uint256 proceeds, uint24 feePips) = RangeBook.claim(book.ranges, id, caller);
        if (proceeds != 0) net = _net(before + proceeds, feePips) - _net(before, feePips);
        sell0 = book.ranges.ranges[id].sell0;
        settled = _rangeSettled(book, id);
    }

    function fixedOrder(BookWalk.PoolBook storage book, uint256 id)
        external
        view
        returns (FixedBook.Order memory, uint64 filled)
    {
        return (book.fixedOrders.orders[id], FixedBook.filledLots(book.fixedOrders, id));
    }

    function rangeOrder(BookWalk.PoolBook storage book, uint256 id)
        external
        view
        returns (RangeBook.Range memory, uint160 frontier)
    {
        return (book.ranges.ranges[id], RangeBook.frontierOf(book.ranges, id));
    }

    /// @dev Asks at or above the pool price and every unfilled bid; bids at or below the pool price and every unfilled
    /// ask. A side's start bounds its unfilled orders.
    function _postOnly(BookWalk.PoolBook storage book, Placement memory o, uint160 near) private view {
        (uint160 price,,,) = o.manager.getSlot0(o.pool);
        uint160 other = book.start[o.sell0 ? 1 : 0];
        bool crosses = o.sell0
            ? near < price || (other != 0 && near < other)
            : near > price || (other != 0 && near > other);
        if (crosses) revert Crossing();
    }

    /// @dev A maker's net of gross proceeds x at fee rate r: x - ceil(r x).
    function _net(uint256 gross, uint24 feePips) private pure returns (uint256) {
        return gross - FullMath.mulDivRoundingUp(gross, feePips, PIPS);
    }

    /// @dev What `out` of a fixed order at sqrt price `price` earns, rounded down: the price applied once while its
    /// square fits 256 bits.
    function _proceeds(bool sell0, uint160 price, uint256 out) private pure returns (uint256) {
        if (price <= type(uint128).max) {
            uint256 squared = uint256(price) * price;
            return sell0 ? FullMath.mulDiv(out, squared, 1 << 192) : FullMath.mulDiv(out, 1 << 192, squared);
        }
        return sell0
            ? FullMath.mulDiv(FullMath.mulDiv(out, price, 1 << 96), price, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(out, 1 << 96, price), 1 << 96, price);
    }

    /// @dev Filled in full (or cancelled) and claimed in full.
    function _fixedSettled(BookWalk.PoolBook storage book, uint256 id) private view returns (bool) {
        FixedBook.Order storage order = book.fixedOrders.orders[id];
        return order.claimed == order.lots && FixedBook.filledLots(book.fixedOrders, id) == order.lots;
    }

    /// @dev Sold out (or cancelled) and claimed in full.
    function _rangeSettled(BookWalk.PoolBook storage book, uint256 id) private view returns (bool) {
        RangeBook.Range storage range = book.ranges.ranges[id];
        uint160 far = TickMath.getSqrtPriceAtTick(range.sell0 ? range.upper : range.lower);
        bool closed = range.frozen != 0 || RangeBook.frontierOf(book.ranges, id) == far;
        return closed && range.claimed == RangeBook.proceedsOf(book.ranges, id);
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
