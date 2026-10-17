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
import {CallbackType, ExtensionSettings, Operation, RouteAction} from "core/src/types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IExtensionVault, KernelExtension} from "../../base/KernelExtension.sol";
import {KernelAdmission} from "../shared/KernelAdmission.sol";
import {OrderBook} from "../../orderbook/OrderBook.sol";
import {ExtensionRead} from "../shared/ExtensionRead.sol";
import {KernelHookConstants} from "core/src/libraries/KernelHookConstants.sol";

interface IDepositVault {
    function deposit(PoolId pool, address extension, Currency currency, uint256 amount) external payable;
}

/// @notice The deployed form of the makers' operations on a pool's book: placing, cancelling and claiming fixed and
/// range orders; and of the book's same-pool routes from afterSwap. The order book extension delegates to it and keeps
/// custody, fees and payments itself.
library BookOrders {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using ExtensionRead for address;

    uint256 internal constant PIPS = 1_000_000;
    // The maker fee ceiling is one tenth of the full PIPS rate.
    uint24 internal constant MAX_MAKER_FEE = 100_000;
    /// @dev Covers the commit and the settlement after the walk's gas stop: 150,000 ran out for a busy, cold book
    /// under a 600k beforeSwap limit, and the Kernel then skipped the book (round 4, R4-3).
    uint32 internal constant MINIMUM_GAS_RESERVE = 200_000;
    /// @dev A single order, and a fixed level's live total and its cost, stay below these, so a level always fits the
    /// walk's amounts.
    uint256 internal constant MAX_ORDER_AMOUNT = 1 << 120;
    // A level can hold sixteen MAX_ORDER_AMOUNT deposits before its proceeds bound also needs checking.
    uint256 internal constant MAX_LEVEL_AMOUNT = 1 << 124;
    uint256 private constant OPTIONAL = 2;

    error InvalidOrder();
    error Crossing();
    error InvalidAmount();
    error TransferMismatch();
    error RouteMismatch();

    /// @dev Keep policy checks in the delegatecalled maker library to leave deployment room in the book.
    function validatePolicy(
        OrderBook.Policy calldata proposedPolicy,
        OrderBook.Policy storage currentPolicy,
        uint256 openOrders
    ) external view {
        _validateLotSizes(proposedPolicy);
        _validateMakerTerms(proposedPolicy);
        _validateWalkLimits(proposedPolicy.limits);
        // Open orders and claims use lots, so changing their units would change the makers' balances.
        if (openOrders == 0) return;
        if (proposedPolicy.lotSize0 != currentPolicy.lotSize0) revert OrderBook.OrdersOpen();
        if (proposedPolicy.lotSize1 != currentPolicy.lotSize1) revert OrderBook.OrdersOpen();
    }

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
        // OrderBook.publicMutation holds _entered across token calls and the vault deposit.
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
    function placeFixed(BookWalk.PoolBook storage book, Placement memory placement, int24 tick, uint64 lots)
        external
        returns (uint256 id, uint256 amount)
    {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        _postOnly(book, placement, sqrtPriceX96);
        id = FixedBook.place(book.fixedOrders, placement.owner, placement.sell0, tick, lots, placement.feePips);
        BookWalk.noteOrder(book, placement.sell0, sqrtPriceX96, sqrtPriceX96);
        amount = uint256(lots) * placement.lotSize;
        uint256 level =
            uint256(FixedBook.live(book.fixedOrders.sides[placement.sell0 ? 0 : 1], tick)) * placement.lotSize;
        if (amount > MAX_ORDER_AMOUNT) revert InvalidOrder();
        if (level > MAX_LEVEL_AMOUNT) revert InvalidOrder();
        if (_proceeds(placement.sell0, sqrtPriceX96, level) >= MAX_LEVEL_AMOUNT) revert InvalidOrder();
    }

    /// @notice Places a range order, post-only, of at least the minimum liquidity.
    /// @return id The order.
    /// @return amount Its deposit, rounded up.
    function placeRange(
        BookWalk.PoolBook storage book,
        Placement memory placement,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) external returns (uint256 id, uint256 amount) {
        if (liquidity < placement.minLiquidity) revert InvalidOrder();
        uint160 lowerSqrtPriceX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 upperSqrtPriceX96 = TickMath.getSqrtPriceAtTick(upper);
        _postOnly(book, placement, placement.sell0 ? lowerSqrtPriceX96 : upperSqrtPriceX96);
        id = RangeBook.place(book.ranges, placement.owner, placement.sell0, lower, upper, liquidity, placement.feePips);
        BookWalk.noteOrder(
            book,
            placement.sell0,
            placement.sell0 ? lowerSqrtPriceX96 : upperSqrtPriceX96,
            placement.sell0 ? upperSqrtPriceX96 : lowerSqrtPriceX96
        );
        amount = placement.sell0
            ? SqrtPriceMath.getAmount0Delta(lowerSqrtPriceX96, upperSqrtPriceX96, liquidity, true)
            : SqrtPriceMath.getAmount1Delta(lowerSqrtPriceX96, upperSqrtPriceX96, liquidity, true);
        // Its whole proceeds stay below the level bound too, so a claim always fits one vault withdrawal.
        uint256 proceeds = placement.sell0
            ? SqrtPriceMath.getAmount1Delta(lowerSqrtPriceX96, upperSqrtPriceX96, liquidity, true)
            : SqrtPriceMath.getAmount0Delta(lowerSqrtPriceX96, upperSqrtPriceX96, liquidity, true);
        if (amount > MAX_ORDER_AMOUNT) revert InvalidOrder();
        if (proceeds >= MAX_LEVEL_AMOUNT) revert InvalidOrder();
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
        if (refund != 0) BookWalk.noteCancel(book, sell0); // a second cancel refunds nothing
        settled = _fixedSettled(book, id);
    }

    function cancelRange(BookWalk.PoolBook storage book, uint256 id, address caller)
        external
        returns (uint256 refund, bool sell0, bool settled)
    {
        bool open = book.ranges.ranges[id].frozen == 0;
        refund = RangeBook.cancel(book.ranges, id, caller);
        sell0 = book.ranges.ranges[id].sell0;
        if (open) BookWalk.noteCancel(book, sell0);
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
        uint256 claimedBefore = order.claimed;
        (uint64 lots, uint24 feePips) = FixedBook.claim(book.fixedOrders, id, caller);
        sell0 = order.sell0;
        if (lots != 0) {
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(order.tick);
            net = _net(_proceeds(sell0, sqrtPriceX96, (claimedBefore + lots) * lotSize), feePips)
                - _net(_proceeds(sell0, sqrtPriceX96, claimedBefore * lotSize), feePips);
        }
        settled = _fixedSettled(book, id);
    }

    /// @notice A range order's net proceeds since its last claim, as for fixed orders.
    function claimRange(BookWalk.PoolBook storage book, uint256 id, address caller)
        external
        returns (uint256 net, bool sell0, bool settled)
    {
        uint256 claimedBefore = book.ranges.ranges[id].claimed;
        (uint256 proceeds, uint24 feePips) = RangeBook.claim(book.ranges, id, caller);
        if (proceeds != 0) net = _net(claimedBefore + proceeds, feePips) - _net(claimedBefore, feePips);
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
    function _postOnly(BookWalk.PoolBook storage book, Placement memory placement, uint160 nearSqrtPriceX96)
        private
        view
    {
        (uint160 poolSqrtPriceX96,,,) = placement.manager.getSlot0(placement.pool);
        uint160 otherSqrtPriceX96 = book.start[placement.sell0 ? 1 : 0];
        if (placement.sell0) {
            if (nearSqrtPriceX96 < poolSqrtPriceX96) revert Crossing();
            if (otherSqrtPriceX96 == 0) return;
            if (nearSqrtPriceX96 < otherSqrtPriceX96) revert Crossing();
            return;
        }
        if (nearSqrtPriceX96 > poolSqrtPriceX96) revert Crossing();
        if (otherSqrtPriceX96 == 0) return;
        if (nearSqrtPriceX96 > otherSqrtPriceX96) revert Crossing();
    }

    /// @dev A maker's net of gross proceeds x at fee rate r: x - ceil(r x).
    function _net(uint256 gross, uint24 feePips) private pure returns (uint256) {
        return gross - FullMath.mulDivRoundingUp(gross, feePips, PIPS);
    }

    /// @dev What `out` of a fixed order at sqrt price `price` earns, rounded down: the price applied once while its
    /// square fits 256 bits.
    function _proceeds(bool sell0, uint160 sqrtPriceX96, uint256 out) private pure returns (uint256) {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 squared = uint256(sqrtPriceX96) * sqrtPriceX96;
            return sell0 ? FullMath.mulDiv(out, squared, 1 << 192) : FullMath.mulDiv(out, 1 << 192, squared);
        }
        return sell0
            ? FullMath.mulDiv(FullMath.mulDiv(out, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(out, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    /// @dev Filled in full (or cancelled) and claimed in full.
    function _fixedSettled(BookWalk.PoolBook storage book, uint256 id) private view returns (bool) {
        FixedBook.Order storage order = book.fixedOrders.orders[id];
        if (order.claimed != order.lots) return false;
        return FixedBook.filledLots(book.fixedOrders, id) == order.lots;
    }

    /// @dev Sold out (or cancelled) and claimed in full.
    function _rangeSettled(BookWalk.PoolBook storage book, uint256 id) private view returns (bool) {
        RangeBook.Range storage range = book.ranges.ranges[id];
        uint160 farSqrtPriceX96 = TickMath.getSqrtPriceAtTick(range.sell0 ? range.upper : range.lower);
        if (range.frozen == 0) {
            if (RangeBook.frontierOf(book.ranges, id) != farSqrtPriceX96) return false;
        }
        return range.claimed == RangeBook.proceedsOf(book.ranges, id);
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
            (uint160 currentSqrtPriceX96,,,) = manager.getSlot0(pool);
            actions[0] =
                RouteAction(key, Operation.Swap, abi.encode(SwapParams(target < currentSqrtPriceX96, -1, target)), "");
        }
        uint256 held0 = vault.balanceOf(pool, address(this), key.currency0);
        uint256 held1 = vault.balanceOf(pool, address(this), key.currency1);
        kernel.executeRoute(actions);
        // OrderBook._enterPool holds the pool callback lock; _requireIdle closes public mutations during routing.
        if (target != 0) {
            (uint160 currentSqrtPriceX96,,,) = manager.getSlot0(pool);
            if (currentSqrtPriceX96 != target) revert RouteMismatch();
        }
        // A balance that rose reverts here too.
        if (held0 - vault.balanceOf(pool, address(this), key.currency0) != amount0) revert RouteMismatch();
        if (held1 - vault.balanceOf(pool, address(this), key.currency1) != amount1) revert RouteMismatch();
    }

    function _validateLotSizes(OrderBook.Policy calldata proposedPolicy) private pure {
        if (proposedPolicy.lotSize0 == 0) revert KernelExtension.InvalidConfiguration();
        if (proposedPolicy.lotSize1 == 0) revert KernelExtension.InvalidConfiguration();
        if (proposedPolicy.lotSize0 > type(uint96).max) revert KernelExtension.InvalidConfiguration();
        if (proposedPolicy.lotSize1 > type(uint96).max) revert KernelExtension.InvalidConfiguration();
    }

    function _validateMakerTerms(OrderBook.Policy calldata proposedPolicy) private pure {
        if (proposedPolicy.makerFeePips > MAX_MAKER_FEE) revert KernelExtension.InvalidConfiguration();
        if (proposedPolicy.gasReserve < MINIMUM_GAS_RESERVE) revert KernelExtension.InvalidConfiguration();
    }

    function _validateWalkLimits(BookWalk.Limits calldata limits) private pure {
        if (limits.ammSteps == 0) revert KernelExtension.InvalidConfiguration();
        if (limits.ammSteps > 4096) revert KernelExtension.InvalidConfiguration();
        if (limits.bookPoints == 0) revert KernelExtension.InvalidConfiguration();
        if (limits.bookPoints > 1024) revert KernelExtension.InvalidConfiguration();
        if (limits.words == 0) revert KernelExtension.InvalidConfiguration();
        if (limits.words > 64) revert KernelExtension.InvalidConfiguration();
        if (limits.chunks == 0) revert KernelExtension.InvalidConfiguration();
        if (limits.chunks > 256) revert KernelExtension.InvalidConfiguration();
    }

    /// @dev Delegatecall preserves address(this) for callback-order and code-hash checks, while keeping views off the book's runtime.
    function activationFits(
        IKernelHook kernel,
        PoolId pool,
        OrderBook.Installation storage installation,
        OrderBook.Policy storage poolPolicy,
        ExtensionSettings calldata settings
    ) external view returns (bool) {
        if (!_activationPolicyFits(kernel, pool, installation, poolPolicy, settings)) return false;
        address[] memory beforeOrder = kernel.callbackOrder(pool, CallbackType.BeforeSwap);
        if (beforeOrder.length == 0) return false;
        if (beforeOrder[beforeOrder.length - 1] != address(this)) return false;
        address[] memory afterOrder = kernel.callbackOrder(pool, CallbackType.AfterSwap);
        if (!_afterOrderFits(kernel, pool, afterOrder)) return false;
        if (!KernelAdmission.callbackFits(
                kernel,
                pool,
                CallbackType.BeforeSwap,
                settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)],
                beforeOrder.length,
                false
            )) return false;
        return KernelAdmission.callbackFits(
            kernel,
            pool,
            CallbackType.AfterSwap,
            settings.callbackGasLimits[uint8(CallbackType.AfterSwap)],
            afterOrder.length,
            true
        );
    }

    function _activationPolicyFits(
        IKernelHook kernel,
        PoolId pool,
        OrderBook.Installation storage installation,
        OrderBook.Policy storage poolPolicy,
        ExtensionSettings calldata settings
    ) private view returns (bool) {
        if (!installation.installed) return false;
        if (installation.policyVersion == 0) return false;
        if (poolPolicy.lotSize0 == 0) return false;
        if (installation.policyVersion != _version(settings.configuration)) return false;
        if (installation.configuredVersion != installation.policyVersion) return false;
        return kernel.isPoolInitialized(pool);
    }

    function _afterOrderFits(IKernelHook kernel, PoolId pool, address[] memory afterOrder)
        private
        view
        returns (bool seen)
    {
        // afterOrder.length <= KernelHookConstants.MAX_EXTENSIONS (Kernel's subscriber cap).
        for (uint256 i; i < afterOrder.length; ++i) {
            if (afterOrder[i] == address(this)) {
                seen = true;
                continue;
            }
            if (!seen) continue;
            (bool readable, uint256 flags) = _profile(kernel, pool, afterOrder[i]);
            if (!readable) return false;
            if (flags & OPTIONAL == 0) return false;
        }
    }

    // ExtensionRead uses STATICCALL, whose read-only execution prevents reentry from mutating checked state.
    function _profile(IKernelHook kernel, PoolId pool, address extension)
        private
        view
        returns (bool readable, uint256 flags)
    {
        // Match KernelExtension's bounded profile read: callback-order members need no dynamic configuration copy.
        (bool success, bytes memory profileBytes) =
            address(kernel).read(100_000, 2048, abi.encodeCall(IKernelHook.extensionConfiguration, (pool, extension)));
        // ABI header: active, settings offset, seven static Catalog.Entry words. Settings has
        // mask, optional, nesting, lifecycle limit, ten callback limits, then a bytes offset.
        // Read only fixed fields instead of decoding/copying the whole dynamic configuration.
        if (!success) return (false, 0);
        if (profileBytes.length < 800) return (false, 0);
        if (_word(profileBytes, 32) != 288) return (false, 0);
        uint256 active = _word(profileBytes, 0);
        uint256 mask = _word(profileBytes, 288);
        uint256 optional = _word(profileBytes, 320);
        uint256 nesting = _word(profileBytes, 352);
        if (active > 1) return (false, 0);
        if (mask > type(uint16).max) return (false, 0);
        if (optional > 1) return (false, 0);
        if (nesting > 1) return (false, 0);
        flags = active | (optional << 1) | (nesting << 2) | (mask << 16);
        // Kernel checks the copied hash before callbacks; quotes also exclude changed code.
        readable = extension.codehash == bytes32(_word(profileBytes, 64));
    }

    function _word(bytes memory dataBytes, uint256 offset) private pure returns (uint256 value) {
        assembly ("memory-safe") { value := mload(add(add(dataBytes, 32), offset)) }
    }

    function _version(bytes calldata configuration) private pure returns (uint64) {
        if (configuration.length != 32) revert KernelExtension.InvalidConfiguration();
        return abi.decode(configuration, (uint64));
    }
}
