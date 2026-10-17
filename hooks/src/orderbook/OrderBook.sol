// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "core/src/interfaces/IKernelHookExtension.sol";
import {
    CallbackResult,
    CallbackType,
    ExecutionContext,
    ExtensionSettings,
    Operation,
    RouteAction
} from "core/src/types/KernelHookTypes.sol";
import {BeforeSwapLibrary} from "core/src/libraries/BeforeSwapLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {KernelExtension} from "../base/KernelExtension.sol";
import {AmmReplay} from "../libraries/orderbook/AmmReplay.sol";
import {FixedBook} from "../libraries/orderbook/FixedBook.sol";
import {RangeBook} from "../libraries/orderbook/RangeBook.sol";
import {BookWalk} from "../libraries/orderbook/BookWalk.sol";
import {BookEngine} from "../libraries/orderbook/BookEngine.sol";
import {BookOrders} from "../libraries/orderbook/BookOrders.sol";

interface IWETH {
    function deposit() external payable;
}

/// @notice An order book inside Kernel pools: fixed-price orders (FIFO per tick, in lots) and range orders (liquidity
/// sold along a price range), filled ahead of and together with the AMM in each swap so the taker gets the best price
/// across both. Replaces LimitOrder. See hooks/docs/order-book-design.md.
/// @dev Book fills settle as PoolManager claims in the Kernel vault. Takers pay the swap's full fee rate on book
/// fills: the LP part goes to LPs, the protocol-sized part half to the SZR treasury and half to LPs. Makers pay the
/// pool's maker fee (set per order when placed) out of their proceeds, half to the treasury and half to LPs. The
/// treasury is one address for every pool, fixed at deployment. LP shares are released gradually and donated to
/// the pool after swaps. Standard ERC20 and native currencies only.
contract OrderBook is KernelExtension, IKernelHookExtension {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint24;

    uint16 public constant CALLBACK_MASK =
        uint16(1) << uint8(CallbackType.BeforeSwap) | uint16(1) << uint8(CallbackType.AfterSwap);
    uint24 public constant DEFAULT_MAKER_FEE = 3000; // 0.3%
    uint256 internal constant PIPS = 1_000_000;
    bytes32 private constant SWAP_RECORD = keccak256("OrderBook.swap");
    /// @dev LP shares are released for donation at locked x elapsed / LP_FEE_PERIOD_SECONDS, so liquidity added for one
    /// swap takes only what was released since the last one.
    /// ponytail: one period for every pool; a policy field if pools need their own.
    uint256 internal constant LP_FEE_PERIOD_SECONDS = 1 days;

    IWETH public immutable WETH;
    /// @notice The Sazare (SZR) treasury, which takes the treasury share in every pool.
    address public immutable TREASURY;

    struct Policy {
        uint128 lotSize0; // currency0 per lot of a fixed order selling currency0
        uint128 lotSize1;
        uint128 minRangeLiquidity;
        uint24 makerFeePips;
        bool nestedFills; // fill orders inside nested routes, for example Arbitrage's
        uint32 gasReserve; // the walk stops while this much gas is left, for its commit and the settlement
        BookWalk.Limits limits;
    }

    struct Installation {
        bool installed;
        uint64 policyVersion;
        uint64 configuredVersion;
    }

    /// @dev Per currency. The vault holds their sum plus nothing else.
    struct Ledger {
        uint256[2] escrow; // makers' unsold deposits
        uint256[2] makers; // principal accrued to makers, less maker fees and net claims paid
        uint256[2] treasury; // owed to the treasury
        uint256[2] lpFees; // owed to LPs, donated after swaps
        uint256[2] reserve; // rounding the book kept
        uint256 openOrders; // orders not yet settled: cancelled or sold out, and claimed in full
    }

    mapping(PoolId => Installation) private _installations;
    mapping(PoolId => Policy) private _policies;
    mapping(PoolId => PoolKey) private _keys;
    mapping(PoolId => BookWalk.PoolBook) private _books;
    mapping(PoolId => Ledger) private _ledgers;
    mapping(PoolId => mapping(uint256 => bool)) private _fixedSettled;
    mapping(PoolId => mapping(uint256 => bool)) private _rangeSettled;

    /// @dev Per pool: LP shares not yet released for donation, per currency (never more than `lpFees`), and when
    /// shares were last released.
    struct LpStream {
        uint128[2] locked;
        uint64 last;
    }

    mapping(PoolId => LpStream) private _lpStreams;

    error InvalidOrder();
    error OrdersOpen();
    error MoveOutOfDepth();

    event PolicyUpdated(PoolId indexed pool, uint64 version);
    /// @dev Order details are in fixedOrder and rangeOrder.
    event OrderPlaced(PoolId indexed pool, bool range, uint256 indexed id, address indexed owner, uint256 deposit);
    event OrderCancelled(PoolId indexed pool, bool range, uint256 indexed id, uint256 refund);
    event Claimed(PoolId indexed pool, bool range, uint256 indexed id, uint256 net, address recipient);
    event BookFilled(
        PoolId indexed pool, uint64 rootOperation, uint256 specified, uint256 other, uint256 makerFee, uint8 stop
    );
    event LpFeesDonated(PoolId indexed pool, uint256 amount0, uint256 amount1);
    event PriceMoved(PoolId indexed pool, uint160 sqrtPriceX96);
    event TreasuryWithdrawn(PoolId indexed pool, Currency currency, uint256 amount, address recipient, bool wrapped);

    constructor(IKernelHook kernel, IWETH weth, address treasury) KernelExtension(kernel) {
        if (treasury == address(0)) revert InvalidConfiguration();
        WETH = weth;
        TREASURY = treasury;
    }

    /// @notice Accepts native currency from the vault only, when the treasury withdraws it as WETH.
    receive() external payable {
        if (msg.sender != address(VAULT)) revert Unauthorized();
    }

    // ---------------------------------------------------------------- policy and lifecycle

    /// @notice Sets a pool's policy while the installation is inactive. Lot sizes cannot change while orders are open.
    function setPolicy(PoolKey calldata key, uint64 expectedVersion, Policy calldata policy) external publicMutation {
        PoolId pool = _validateKey(key);
        _requireRole(pool);
        Installation storage installation = _installations[pool];
        if (!installation.installed) revert InvalidPool();
        if (!KERNEL.isPoolInitialized(pool)) revert InvalidPool();
        (bool readable, uint256 flags) = _profile(pool, address(this));
        if (!readable) revert InvalidConfiguration();
        if (flags & ACTIVE != 0) revert InvalidConfiguration();
        if (installation.policyVersion != expectedVersion) revert InvalidVersion();
        _validatePolicy(pool, policy);
        _policies[pool] = policy;
        ++installation.policyVersion;
        emit PolicyUpdated(pool, installation.policyVersion);
    }

    function onInstall(PoolKey calldata key, ExtensionSettings calldata settings) external lifecycle returns (bytes4) {
        PoolId pool = _validateKey(key);
        _checkSettings(settings);
        Installation storage installation = _installations[pool];
        if (installation.installed) revert InvalidConfiguration();
        installation.installed = true;
        installation.configuredVersion = _version(settings.configuration);
        if (installation.configuredVersion != 0) {
            if (installation.configuredVersion != installation.policyVersion) revert InvalidVersion();
        }
        _keys[pool] = key;
        return this.onInstall.selector;
    }

    function onConfigure(PoolKey calldata key, ExtensionSettings calldata, ExtensionSettings calldata settings)
        external
        lifecycle
        returns (bytes4)
    {
        _checkSettings(settings);
        Installation storage installation = _installations[_validateKey(key)];
        if (!installation.installed) revert InvalidPool();
        uint64 version = _version(settings.configuration);
        if (version != installation.policyVersion) revert InvalidVersion();
        installation.configuredVersion = version;
        return this.onConfigure.selector;
    }

    /// @notice The book runs last in beforeSwap, and in afterSwap every extension after it is optional: a required one
    /// would deny the book's same-pool routes (the LP donation and the empty-pool price move).
    function canActivate(PoolKey calldata key, ExtensionSettings calldata settings)
        external
        view
        onlyKernel
        returns (bool)
    {
        _checkSettings(settings);
        PoolId pool = _validateKey(key);
        return BookOrders.activationFits(KERNEL, pool, _installations[pool], _policies[pool], settings);
    }

    /// @notice Removable once every order is settled and every share paid out.
    function canUninstall(PoolKey calldata key) external view onlyKernel returns (bool) {
        if (_entered) return false;
        return _empty(key.toId());
    }

    function onUninstall(PoolKey calldata key, bytes calldata) external lifecycle returns (bytes4) {
        PoolId pool = key.toId();
        if (!_empty(pool)) revert OutstandingObligations();
        _installations[pool].installed = false;
        _installations[pool].configuredVersion = 0;
        delete _policies[pool];
        return this.onUninstall.selector;
    }

    // ---------------------------------------------------------------- makers

    /// @notice Places a fixed-price order of `lots` lots at `tick`: an ask sells currency0 at or above the pool price,
    /// a bid sells currency1 at or below it (post-only). The deposit is lots times the sold currency's lot size.
    /// @param policyVersion The policy the maker read (`policy`): a policy changed since then refuses the order, so
    /// lot sizes and the maker fee cannot change under it.
    function placeFixed(PoolKey calldata key, bool sell0, int24 tick, uint64 lots, uint64 policyVersion)
        external
        payable
        publicMutation
        returns (uint256 id)
    {
        PoolId pool = _readyPool(key, policyVersion);
        uint256 amount;
        (id, amount) = BookOrders.placeFixed(_books[pool], _placement(pool, sell0), tick, lots);
        _escrow(pool, sell0, amount);
        emit OrderPlaced(pool, false, id, msg.sender, amount);
    }

    /// @notice Places a range order of `liquidity` over [lower, upper), sold like an LP position: an ask from lower
    /// upward, a bid from upper downward. Post-only, at least the pool's minimum liquidity.
    /// @param policyVersion As for `placeFixed`.
    function placeRange(
        PoolKey calldata key,
        bool sell0,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint64 policyVersion
    ) external payable publicMutation returns (uint256 id) {
        PoolId pool = _readyPool(key, policyVersion);
        uint256 amount;
        (id, amount) = BookOrders.placeRange(_books[pool], _placement(pool, sell0), lower, upper, liquidity);
        _escrow(pool, sell0, amount);
        emit OrderPlaced(pool, true, id, msg.sender, amount);
    }

    /// @notice Cancels a fixed order: refunds its unfilled lots to `recipient`; filled lots stay claimable.
    function cancelFixed(PoolId pool, uint256 id, address recipient) external publicMutation returns (uint256 refund) {
        (uint64 lots, bool sell0, bool settled) = BookOrders.cancelFixed(_books[pool], id, msg.sender);
        refund = uint256(lots) * _lotSize(pool, sell0);
        _refund(pool, sell0, refund, recipient);
        if (settled) _settle(pool, false, id);
        emit OrderCancelled(pool, false, id, refund);
    }

    /// @notice Cancels a range order: refunds its unsold part to `recipient`; proceeds stay claimable.
    function cancelRange(PoolId pool, uint256 id, address recipient) external publicMutation returns (uint256 refund) {
        bool sell0;
        bool settled;
        (refund, sell0, settled) = BookOrders.cancelRange(_books[pool], id, msg.sender);
        _refund(pool, sell0, refund, recipient);
        if (settled) _settle(pool, true, id);
        emit OrderCancelled(pool, true, id, refund);
    }

    /// @notice Pays a fixed order's net proceeds since its last claim.
    function claimFixed(PoolId pool, uint256 id, address recipient) external publicMutation returns (uint256 net) {
        bool sell0 = _books[pool].fixedOrders.orders[id].sell0;
        bool settled;
        (net, sell0, settled) = BookOrders.claimFixed(_books[pool], id, msg.sender, _lotSize(pool, sell0));
        _payMaker(pool, !sell0, net, recipient);
        if (settled) _settle(pool, false, id);
        emit Claimed(pool, false, id, net, recipient);
    }

    /// @notice Pays a range order's net proceeds since its last claim.
    function claimRange(PoolId pool, uint256 id, address recipient) external publicMutation returns (uint256 net) {
        (uint256 paid, bool sell0, bool settled) = BookOrders.claimRange(_books[pool], id, msg.sender);
        _payMaker(pool, !sell0, paid, recipient);
        if (settled) _settle(pool, true, id);
        emit Claimed(pool, true, id, paid, recipient);
        return paid;
    }

    // ---------------------------------------------------------------- treasury

    /// @notice The treasury withdraws its share; native currency can be taken as WETH. Only the treasury: a
    /// RevenueSplitter treasury splits each withdrawal by its pool, which a payment pushed to it would not name. The
    /// splitter's collect is open to anyone, so removing a book never waits on a person (R3-7).
    function withdrawTreasury(PoolId pool, Currency currency, uint256 amount, address recipient, bool asWeth)
        external
        publicMutation
    {
        if (msg.sender != TREASURY) revert Unauthorized();
        if (recipient == address(0)) revert Unauthorized();
        uint256 currencyIndex = _currencyIndex(pool, currency);
        _ledgers[pool].treasury[currencyIndex] -= amount;
        if (asWeth) {
            if (!currency.isAddressZero()) revert InvalidAmount();
            if (address(WETH) == address(0)) revert InvalidAmount();
            VAULT.withdraw(pool, currency, amount, address(this));
            WETH.deposit{value: amount}();
            // publicMutation's lock holds across these calls, and the ledger was debited before them.
            if (!IERC20(address(WETH)).transfer(recipient, amount)) revert InvalidAmount();
        } else {
            VAULT.withdraw(pool, currency, amount, recipient);
        }
        emit TreasuryWithdrawn(pool, currency, amount, recipient, asWeth);
    }

    /// @notice Once every order is settled, moves what is left of the makers' shares, escrow rounding and the book's
    /// reserve to the treasury.
    function sweep(PoolId pool) external publicMutation {
        Ledger storage ledger = _ledgers[pool];
        if (ledger.openOrders != 0) revert OrdersOpen();
        // currencyIndex < 2 currencies.
        for (uint256 currencyIndex; currencyIndex < 2; ++currencyIndex) {
            ledger.treasury[currencyIndex] += ledger.escrow[currencyIndex] + ledger.makers[currencyIndex]
            + ledger.reserve[currencyIndex];
            (ledger.escrow[currencyIndex], ledger.makers[currencyIndex], ledger.reserve[currencyIndex]) = (0, 0, 0);
        }
    }

    // ---------------------------------------------------------------- views

    /// @notice The book's part of a swap with `amountSpecified` left after earlier extensions and this LP fee, by the
    /// same code the swap runs.
    function quote(PoolKey calldata key, SwapParams calldata params, uint24 lpFee)
        external
        view
        returns (BookWalk.Fill memory)
    {
        PoolId pool = key.toId();
        return BookEngine.quote(_books[pool], _request(pool, key, params, params.amountSpecified, lpFee, 0));
    }

    function policy(PoolId pool) external view returns (Policy memory, uint64 version, uint64 configured) {
        Installation storage installation = _installations[pool];
        return (_policies[pool], installation.policyVersion, installation.configuredVersion);
    }

    function ledger(PoolId pool) external view returns (Ledger memory) {
        return _ledgers[pool];
    }

    function fixedOrder(PoolId pool, uint256 id) external view returns (FixedBook.Order memory, uint64 filled) {
        return BookOrders.fixedOrder(_books[pool], id);
    }

    function rangeOrder(PoolId pool, uint256 id) external view returns (RangeBook.Range memory, uint160 frontier) {
        return BookOrders.rangeOrder(_books[pool], id);
    }

    /// @return start Per side, where no unfilled liquidity lies before.
    /// @return extent Per side, the furthest price an order has reached.
    function bookBounds(PoolId pool) external view returns (uint160[2] memory start, uint160[2] memory extent) {
        BookWalk.PoolBook storage book = _books[pool];
        return (book.start, book.extent);
    }

    // ---------------------------------------------------------------- swaps

    function onCallback(ExecutionContext calldata context, PoolKey calldata key, bytes calldata data)
        external
        onlyKernel
        returns (CallbackResult memory result)
    {
        _authenticate(context, key);
        // Per pool: afterSwap's routes may enter another pool's book. Public functions stay closed while any Kernel
        // operation runs (`_requireIdle` reads the Kernel's context).
        _enterPool(context.poolId);
        if (context.callback == CallbackType.BeforeSwap) result = _beforeSwap(context, key, data);
        else if (context.callback == CallbackType.AfterSwap) _afterSwap(context, key);
        else revert Unauthorized();
        _exitPool(context.poolId);
    }

    function _beforeSwap(ExecutionContext calldata context, PoolKey calldata key, bytes calldata data)
        private
        returns (CallbackResult memory result)
    {
        PoolId pool = context.poolId;
        (uint160 startSqrtPriceX96,,, uint24 lpFeePips) = MANAGER.getSlot0(pool);
        _requireRoomToMove(context);
        // The price this swap starts from, where an empty pool returns if the book trades nothing (round 3, R3-2). It
        // also replaces a record whose afterSwap did not run (skipped, or out of gas).
        _recordSwap(pool, context.depth, startSqrtPriceX96, false);
        Policy storage policy = _policies[pool];
        if (context.depth > 1) {
            if (!policy.nestedFills) return result;
        }
        // SwapParams is the static prefix of the Kernel's (params, hookData) encoding.
        SwapParams memory params = abi.decode(data, (SwapParams));
        int256 remaining = BeforeSwapLibrary.remainingAmountSpecified(params, context.prior);
        if (remaining == 0) return result;
        if (remaining == type(int256).min) return result;
        // The walk refuses a price limit not ahead of the pool price; v4 then rejects the swap.
        // An earlier extension's override is this swap's LP fee.
        if (context.prior.feeOverride != 0) lpFeePips = context.prior.feeOverride.removeOverrideFlag();
        BookWalk.Request memory request = _request(pool, key, params, remaining, lpFeePips, policy.gasReserve);
        (BookWalk.Fill memory fill, uint256 makerFee) = BookEngine.execute(_books[pool], request);
        // _enterPool holds the pool callback lock, and _requireIdle blocks maker mutations during the delegated fill.
        if (fill.specified == 0) {
            if (fill.other == 0) return result;
        }
        // A fill of dust alone trades at no price: it must not erase the start or the transaction's last trade.
        if (fill.traded != 0) _recordSwap(pool, context.depth, fill.traded, true);
        result = _settle(pool, params.zeroForOne, request, fill, makerFee);
        emit BookFilled(pool, context.rootOperationId, fill.specified, fill.other, makerFee, fill.stop);
    }

    /// @dev Books the fill and returns its deltas. The input currency's shares: principal to makers less their fee;
    /// the taker fee's protocol-sized part and the maker fee half to the treasury, the rest to LPs; exact-input dust to
    /// the reserve. The output leaves escrow.
    function _settle(
        PoolId pool,
        bool zeroForOne,
        BookWalk.Request memory request,
        BookWalk.Fill memory fill,
        uint256 makerFee
    ) private returns (CallbackResult memory) {
        (uint256 input, uint256 output) = request.exactIn ? (fill.specified, fill.other) : (fill.other, fill.specified);
        uint256 toTreasury = _protocolPart(pool, zeroForOne, request.pool.fee, fill) / 2 + makerFee / 2;
        (uint256 inputIndex, uint256 outputIndex) = zeroForOne ? (0, 1) : (1, 0);
        Ledger storage ledger = _ledgers[pool];
        ledger.escrow[outputIndex] -= output;
        ledger.makers[inputIndex] += fill.principal - makerFee;
        uint256 toLiquidityProviders = fill.takerFee + makerFee - toTreasury;
        // With no liquidity in range, no LP earns the share: it goes to the treasury, so no backlog builds up for the
        // first position to enter (round 3, R3-4).
        if (_liquidity(pool) == 0) (toTreasury, toLiquidityProviders) = (toTreasury + toLiquidityProviders, 0);
        ledger.treasury[inputIndex] += toTreasury;
        ledger.lpFees[inputIndex] += toLiquidityProviders;
        _release(pool, inputIndex, toLiquidityProviders);
        ledger.reserve[inputIndex] += fill.dust;
        int128 paid = SafeCast.toInt128(input);
        int128 received = -SafeCast.toInt128(output);
        return zeroForOne ? CallbackResult(paid, received, 0) : CallbackResult(received, paid, 0);
    }

    /// @dev The protocol-sized part of the taker fee on book fills, as v4 splits a step's fee: the protocol's rate of
    /// the gross input, or the whole fee when the LP fee is zero.
    function _protocolPart(PoolId pool, bool zeroForOne, uint24 swapFeePips, BookWalk.Fill memory fill)
        private
        view
        returns (uint256 part)
    {
        (,, uint24 protocolFeePipsByDirection,) = MANAGER.getSlot0(pool);
        uint24 protocolFeePips =
            zeroForOne ? protocolFeePipsByDirection.getZeroForOneFee() : protocolFeePipsByDirection.getOneForZeroFee();
        if (protocolFeePips == 0) return 0;
        // As in v4: the gross input fits int128 and the protocol fee is at most 1,000 pips, so this cannot overflow.
        part =
            protocolFeePips == swapFeePips ? fill.takerFee : (fill.principal + fill.takerFee) * protocolFeePips / PIPS;
        if (part > fill.takerFee) part = fill.takerFee;
    }

    /// @dev Donates the LPs' released fees when liquidity is in range. With none, the book's price is the pool's: the
    /// price moves to the book's last trade, or back to where the swap started when the book has not traded. Both are
    /// same-pool routes; a failed donation leaves the shares for a later swap. The move is a swap of one unit that must
    /// land on the target with the vault unchanged, so it trades nothing; where liquidity lies on the way, or the target
    /// is out of bounds, it reverts and the price stays. The move is limited by this pool's depth limit only (not by a
    /// route's root pool). Admins: keep the depth limit at 3 or more, give extensions that route back into this pool
    /// enough gas for the book, and order the book after them in afterSwap, or such a route's fill may not show in the
    /// price (R3-8, accepted). Install no extension that swaps in this pool from afterAddLiquidity,
    /// afterRemoveLiquidity or afterDonate (see _requireRoomToMove). A required extension of this pool that routes into
    /// another pool from beforeSwap also runs in the move, so that pool's admin can refuse the move (accepted: that
    /// admin can already block the extension).
    function _afterSwap(ExecutionContext calldata context, PoolKey calldata key) private {
        PoolId pool = context.poolId;
        uint160 targetSqrtPriceX96 = _takeSwapTarget(pool, context.depth);
        if (_liquidity(pool) != 0) {
            _donate(pool, key);
            return;
        }
        if (targetSqrtPriceX96 == 0) return;
        (uint160 currentSqrtPriceX96,,,) = MANAGER.getSlot0(pool);
        if (targetSqrtPriceX96 == currentSqrtPriceX96) return;
        try this.route(key, 0, 0, targetSqrtPriceX96) {
            emit PriceMoved(pool, targetSqrtPriceX96);
        } catch {}
    }

    /// @dev With no liquidity in range, the move back after a nested swap is a route one level deeper, which this
    /// pool's depth limit must allow. Another pool's routes, through a chain of the attacker's own pools, could
    /// otherwise enter at the limit, push the price, and leave it there. Refusing fails such a route (the Kernel's
    /// backstop: a route entering from another pool is strict). Not checked: a root swap, which always has room; a
    /// route this pool's own extension started, which the Kernel lets skip the book and this pool's outer move corrects
    /// (R3-8); and a pool with liquidity in range, where the swap trades on the AMM as at the root and needs no move.
    /// That outer move exists only when this pool's extension routes from afterSwap. Admins: in a book pool, install
    /// no extension that swaps in the pool from afterAddLiquidity, afterRemoveLiquidity or afterDonate. An attacker's
    /// chain could trigger that callback deep enough that the move back has no room, with no outer swap to correct the
    /// price (round-4 pre-audit, accepted and documented).
    function _requireRoomToMove(ExecutionContext calldata context) private view {
        if (context.depth == 1) return;
        PoolId pool = context.poolId;
        if (PoolId.unwrap(context.originPoolId) == PoolId.unwrap(pool)) return;
        if (_liquidity(pool) != 0) return;
        if (!KERNEL.hasDepthForRoute(pool)) revert MoveOutOfDepth();
    }

    function _donate(PoolId pool, PoolKey calldata key) private {
        Ledger storage ledger = _ledgers[pool];
        LpStream storage stream = _release(pool, 0, 0);
        uint256 amount0 = ledger.lpFees[0] - stream.locked[0];
        uint256 amount1 = ledger.lpFees[1] - stream.locked[1];
        if (amount0 == 0) {
            if (amount1 == 0) return;
        }
        uint256 cap = uint256(uint128(type(int128).max));
        if (amount0 > cap) amount0 = cap;
        if (amount1 > cap) amount1 = cap;
        // _enterPool holds this pool's callback lock; _requireIdle closes public mutations during the route.
        try this.route(key, amount0, amount1, 0) {
            ledger.lpFees[0] -= amount0;
            ledger.lpFees[1] -= amount1;
            emit LpFeesDonated(pool, amount0, amount1);
        } catch {}
    }

    /// @notice The book's same-pool routes from afterSwap (see `BookOrders.route`), in a call to itself so that a
    /// route that left the vault apart from the ledger rolls back. Only the book calls it.
    function route(PoolKey calldata key, uint256 amount0, uint256 amount1, uint160 target) external {
        if (msg.sender != address(this)) revert Unauthorized();
        BookOrders.route(KERNEL, VAULT, MANAGER, key, amount0, amount1, target);
    }

    function _request(
        PoolId pool,
        PoolKey calldata key,
        SwapParams memory params,
        int256 remaining,
        uint24 lpFeePips,
        uint256 reserveGas
    ) private view returns (BookWalk.Request memory request) {
        Policy storage policy = _policies[pool];
        request.pool = AmmReplay.Pool(
            MANAGER,
            pool,
            key.tickSpacing,
            params.zeroForOne,
            params.sqrtPriceLimitX96,
            AmmReplay.swapFee(MANAGER, pool, params.zeroForOne, lpFeePips)
        );
        request.exactIn = remaining < 0;
        uint256 budget = request.exactIn ? uint256(-remaining) : uint256(remaining);
        request.budget = budget > BookWalk.MAX_BOOK_AMOUNT ? BookWalk.MAX_BOOK_AMOUNT : budget;
        request.lotSize = params.zeroForOne ? policy.lotSize1 : policy.lotSize0; // the output currency's
        request.limits = policy.limits;
        request.reserveGas = reserveGas;
    }

    /// @dev Records the swap at this depth: the price it starts from, then the price it traded at if the book filled,
    /// which is also the pool's last trade in this transaction.
    function _recordSwap(PoolId pool, uint8 depth, uint160 sqrtPriceX96, bool traded) private {
        (bytes32 slot, bytes32 last) = _swapSlots(pool, depth);
        assembly ("memory-safe") {
            tstore(slot, sqrtPriceX96)
            if traded { tstore(last, sqrtPriceX96) }
        }
    }

    /// @dev Where an empty pool's price belongs after the swap at this depth: the pool's last trade in this transaction
    /// (this swap's, or a newer nested fill's whose own move may have failed), or else where this swap started. 0 when
    /// the book did not see the swap.
    function _takeSwapTarget(PoolId pool, uint8 depth) private returns (uint160 targetSqrtPriceX96) {
        (bytes32 slot, bytes32 last) = _swapSlots(pool, depth);
        uint160 startSqrtPriceX96;
        assembly ("memory-safe") {
            startSqrtPriceX96 := tload(slot)
        }
        if (startSqrtPriceX96 == 0) return 0;
        assembly ("memory-safe") {
            tstore(slot, 0)
            targetSqrtPriceX96 := tload(last)
        }
        if (targetSqrtPriceX96 == 0) targetSqrtPriceX96 = startSqrtPriceX96;
    }

    function _liquidity(PoolId pool) private view returns (uint128) {
        return MANAGER.getLiquidity(pool);
    }

    /// @dev The transient slots of the swap at this depth and of the pool's last trade in this transaction.
    function _swapSlots(PoolId pool, uint8 depth) private pure returns (bytes32 slot, bytes32 last) {
        slot = keccak256(abi.encode(SWAP_RECORD, pool, depth));
        last = keccak256(abi.encode(SWAP_RECORD, pool));
    }

    // ---------------------------------------------------------------- internals

    function _readyPool(PoolKey calldata key, uint64 policyVersion) private view returns (PoolId pool) {
        pool = _validateKey(key);
        Installation storage installation = _installations[pool];
        if (!installation.installed) revert InvalidPool();
        if (installation.configuredVersion != installation.policyVersion) revert InvalidPool();
        if (policyVersion != installation.policyVersion) revert InvalidVersion();
        (bool readable, uint256 flags) = _profile(pool, address(this));
        if (!readable) revert InvalidPool();
        if (flags & ACTIVE == 0) revert InvalidPool();
    }

    function _placement(PoolId pool, bool sell0) private view returns (BookOrders.Placement memory) {
        Policy storage poolPolicy = _policies[pool];
        return BookOrders.Placement(
            MANAGER,
            pool,
            msg.sender,
            sell0,
            poolPolicy.makerFeePips,
            sell0 ? poolPolicy.lotSize0 : poolPolicy.lotSize1,
            poolPolicy.minRangeLiquidity
        );
    }

    // publicMutation holds _entered across the withdrawal so the caller can safely settle the order afterward.
    function _refund(PoolId pool, bool sell0, uint256 amount, address recipient) private {
        _checkRecipient(recipient);
        if (amount == 0) return;
        uint256 currencyIndex = sell0 ? 0 : 1;
        _ledgers[pool].escrow[currencyIndex] -= amount;
        VAULT.withdraw(pool, currencyIndex == 0 ? _keys[pool].currency0 : _keys[pool].currency1, amount, recipient);
    }

    /// @dev publicMutation holds _entered across the withdrawal so the caller can safely settle the order afterward.
    /// @param currency0 Whether the proceeds are in currency0 (a bid's).
    function _payMaker(PoolId pool, bool currency0, uint256 net, address recipient) private {
        _checkRecipient(recipient);
        uint256 currencyIndex = currency0 ? 0 : 1;
        _ledgers[pool].makers[currencyIndex] -= net;
        if (net != 0) {
            VAULT.withdraw(pool, currencyIndex == 0 ? _keys[pool].currency0 : _keys[pool].currency1, net, recipient);
        }
    }

    /// @dev Releases locked LP shares for the time since the last release (all of them after a whole period), then
    /// locks `amount` more of currency `currencyIndex`. Above uint128, the excess is released at once. The release
    /// rounds up: rounded down, a small share would release nothing in a busy pool and block removal.
    function _release(PoolId pool, uint256 currencyIndex, uint256 amount) private returns (LpStream storage stream) {
        stream = _lpStreams[pool];
        uint256 elapsed = block.timestamp - stream.last;
        if (elapsed != 0) {
            if (elapsed > LP_FEE_PERIOD_SECONDS) elapsed = LP_FEE_PERIOD_SECONDS;
            // lockedIndex < 2 currencies.
            for (uint256 lockedIndex; lockedIndex < 2; ++lockedIndex) {
                uint256 locked = stream.locked[lockedIndex];
                stream.locked[
                    lockedIndex
                ] -= uint128((locked * elapsed + LP_FEE_PERIOD_SECONDS - 1) / LP_FEE_PERIOD_SECONDS);
            }
            stream.last = uint64(block.timestamp);
        }
        if (amount != 0) {
            uint256 locked = stream.locked[currencyIndex] + amount;
            stream.locked[currencyIndex] = locked > type(uint128).max ? type(uint128).max : uint128(locked);
        }
    }

    /// @dev Funds sent to the book or the Kernel's contracts would be lost to the maker: anyone can take tokens the
    /// PoolManager holds unaccounted for (round 3, FX-6).
    function _checkRecipient(address recipient) private view {
        if (recipient == address(0)) revert InvalidAmount();
        if (recipient == address(this)) revert InvalidAmount();
        if (recipient == address(VAULT)) revert InvalidAmount();
        if (recipient == address(KERNEL)) revert InvalidAmount();
        if (recipient == ROUTE_EXECUTOR) revert InvalidAmount();
        if (recipient == address(MANAGER)) revert InvalidAmount();
    }

    /// @dev An order with nothing left to claim no longer counts as open; once only.
    function _settle(PoolId pool, bool range, uint256 id) private {
        mapping(uint256 => bool) storage settled = range ? _rangeSettled[pool] : _fixedSettled[pool];
        if (settled[id]) return;
        settled[id] = true;
        --_ledgers[pool].openOrders;
    }

    /// @dev Takes a maker's deposit. Each currency's escrow stays below the walk's amount bound, so no swap's book
    /// output can exceed the hook's int128 deltas.
    function _escrow(PoolId pool, bool sell0, uint256 amount) private {
        Ledger storage ledger = _ledgers[pool];
        uint256 total = ledger.escrow[sell0 ? 0 : 1] + amount;
        if (total > BookWalk.MAX_BOOK_AMOUNT) revert InvalidOrder();
        ledger.escrow[sell0 ? 0 : 1] = total;
        ++ledger.openOrders;
        _deposit(pool, sell0, amount);
    }

    function _empty(PoolId pool) private view returns (bool) {
        Ledger storage ledger = _ledgers[pool];
        // currencyIndex < 2 currencies.
        for (uint256 currencyIndex; currencyIndex < 2; ++currencyIndex) {
            if (ledger.escrow[currencyIndex] != 0) return false;
            if (ledger.makers[currencyIndex] != 0) return false;
            if (ledger.treasury[currencyIndex] != 0) return false;
            if (ledger.lpFees[currencyIndex] != 0) return false;
            if (ledger.reserve[currencyIndex] != 0) return false;
        }
        return ledger.openOrders == 0;
    }

    function _lotSize(PoolId pool, bool sell0) private view returns (uint256) {
        Policy storage policy = _policies[pool];
        return sell0 ? policy.lotSize0 : policy.lotSize1;
    }

    function _currencyIndex(PoolId pool, Currency currency) private view returns (uint256) {
        PoolKey storage key = _keys[pool];
        if (currency == key.currency0) return 0;
        if (currency == key.currency1) return 1;
        revert InvalidPool();
    }

    function _deposit(PoolId pool, bool sell0, uint256 amount) private {
        BookOrders.deposit(address(VAULT), pool, sell0 ? _keys[pool].currency0 : _keys[pool].currency1, amount);
    }

    function _validatePolicy(PoolId pool, Policy calldata proposedPolicy) private view {
        BookOrders.validatePolicy(proposedPolicy, _policies[pool], _ledgers[pool].openOrders);
    }

    function _checkSettings(ExtensionSettings calldata settings) private pure {
        // Optional: a failed or skipped book leaves the swap to the AMM. Nesting: the LP donation and the empty-pool
        // price move are same-pool routes from afterSwap.
        if (settings.callbackMask != CALLBACK_MASK) revert InvalidConfiguration();
        if (!settings.optionalCallbacks) revert InvalidConfiguration();
        if (!settings.allowNesting) revert InvalidConfiguration();
    }
}
