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
import {KernelExtension} from "./base/KernelExtension.sol";
import {AmmReplay} from "./libraries/AmmReplay.sol";
import {FixedBook} from "./libraries/FixedBook.sol";
import {RangeBook} from "./libraries/RangeBook.sol";
import {BookWalk} from "./libraries/BookWalk.sol";
import {BookEngine} from "./libraries/BookEngine.sol";
import {BookOrders} from "./libraries/BookOrders.sol";

interface IWETH {
    function deposit() external payable;
}

/// @notice An order book inside Kernel pools: fixed-price orders (FIFO per tick, in lots) and range orders (liquidity
/// sold along a price range), filled ahead of and together with the AMM in each swap so the taker gets the best price
/// across both. Replaces LimitOrder. See hooks/docs/order-book-design.md.
/// @dev Book fills settle as PoolManager claims in the Kernel vault. Takers pay the swap's full fee rate on book
/// fills: the LP part goes to LPs, the protocol-sized part half to the treasury and half to LPs. Makers pay the pool's
/// maker fee (set per order when placed) out of their proceeds, half to the treasury and half to LPs. LP shares are
/// donated to the pool after each swap. Standard ERC20 and native currencies only.
contract OrderBook is KernelExtension, IKernelHookExtension {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint24;

    uint16 public constant CALLBACK_MASK =
        uint16(1) << uint8(CallbackType.BeforeSwap) | uint16(1) << uint8(CallbackType.AfterSwap);
    uint24 public constant DEFAULT_MAKER_FEE = 3000; // 0.3%
    uint24 internal constant MAX_MAKER_FEE = 100_000; // 10%
    uint256 internal constant PIPS = 1_000_000;
    bytes32 private constant SWAP_RECORD = keccak256("OrderBook.swap");

    IWETH public immutable WETH;

    struct Policy {
        uint128 lotSize0; // currency0 per lot of a fixed order selling currency0
        uint128 lotSize1;
        uint128 minRangeLiquidity;
        uint24 makerFeePips;
        bool nestedFills; // fill orders inside nested routes, for example Arbitrage's
        uint32 gasReserve; // the walk stops while this much gas is left, for its commit and the settlement
        address treasury;
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

    error InvalidOrder();
    error OrdersOpen();

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

    constructor(IKernelHook kernel, IWETH weth) KernelExtension(kernel) {
        WETH = weth;
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
        if (!installation.installed || !KERNEL.isPoolInitialized(pool)) revert InvalidPool();
        (bool readable, uint256 flags) = _profile(pool, address(this));
        if (!readable || flags & ACTIVE != 0) revert InvalidConfiguration();
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
        if (installation.configuredVersion != 0 && installation.configuredVersion != installation.policyVersion) {
            revert InvalidVersion();
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
        Installation storage installation = _installations[pool];
        if (
            !installation.installed || installation.policyVersion == 0 || _policies[pool].treasury == address(0)
                || installation.policyVersion != _version(settings.configuration)
                || installation.configuredVersion != installation.policyVersion || !KERNEL.isPoolInitialized(pool)
        ) return false;
        address[] memory before = KERNEL.callbackOrder(pool, CallbackType.BeforeSwap);
        if (before.length == 0 || before[before.length - 1] != address(this)) return false;
        address[] memory afterOrder = KERNEL.callbackOrder(pool, CallbackType.AfterSwap);
        bool seen;
        for (uint256 i; i < afterOrder.length; ++i) {
            if (afterOrder[i] == address(this)) {
                seen = true;
            } else if (seen) {
                (bool readable, uint256 flags) = _profile(pool, afterOrder[i]);
                if (!readable || flags & OPTIONAL == 0) return false;
            }
        }
        return seen
            && _callbackFits(
                pool,
                CallbackType.BeforeSwap,
                settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)],
                before.length,
                false
            )
            && _callbackFits(
                pool,
                CallbackType.AfterSwap,
                settings.callbackGasLimits[uint8(CallbackType.AfterSwap)],
                afterOrder.length,
                true
            );
    }

    /// @notice Removable once every order is settled and every share paid out.
    function canUninstall(PoolKey calldata key) external view onlyKernel returns (bool) {
        return !_entered && _empty(key.toId());
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

    /// @notice The treasury withdraws its share; native currency can be taken as WETH.
    function withdrawTreasury(PoolId pool, Currency currency, uint256 amount, address recipient, bool asWeth)
        external
        publicMutation
    {
        if (msg.sender != _policies[pool].treasury || recipient == address(0)) revert Unauthorized();
        uint256 c = _currencyIndex(pool, currency);
        _ledgers[pool].treasury[c] -= amount;
        if (asWeth) {
            if (!currency.isAddressZero() || address(WETH) == address(0)) revert InvalidAmount();
            VAULT.withdraw(pool, currency, amount, address(this));
            WETH.deposit{value: amount}();
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
        for (uint256 c; c < 2; ++c) {
            ledger.treasury[c] += ledger.escrow[c] + ledger.makers[c] + ledger.reserve[c];
            (ledger.escrow[c], ledger.makers[c], ledger.reserve[c]) = (0, 0, 0);
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
        _entered = true;
        if (context.callback == CallbackType.BeforeSwap) result = _beforeSwap(context, key, data);
        else if (context.callback == CallbackType.AfterSwap) _afterSwap(context, key);
        else revert Unauthorized();
        _entered = false;
    }

    function _beforeSwap(ExecutionContext calldata context, PoolKey calldata key, bytes calldata data)
        private
        returns (CallbackResult memory result)
    {
        PoolId pool = context.poolId;
        // A record whose afterSwap did not run (skipped, or out of gas) must not reach this swap's.
        _setSwapFrontier(pool, context.depth, 0);
        Policy storage policy = _policies[pool];
        if (context.depth > 1 && !policy.nestedFills) return result;
        // SwapParams is the static prefix of the Kernel's (params, hookData) encoding.
        SwapParams memory params = abi.decode(data, (SwapParams));
        int256 remaining = BeforeSwapLibrary.remainingAmountSpecified(params, context.prior);
        if (remaining == 0 || remaining == type(int256).min) return result;
        // The walk refuses a price limit not ahead of the pool price; v4 then rejects the swap.
        (,,, uint24 lpFee) = MANAGER.getSlot0(pool);
        // An earlier extension's override is this swap's LP fee.
        if (context.prior.feeOverride != 0) lpFee = context.prior.feeOverride.removeOverrideFlag();
        BookWalk.Request memory r = _request(pool, key, params, remaining, lpFee, policy.gasReserve);
        (BookWalk.Fill memory fill, uint256 makerFee) = BookEngine.execute(_books[pool], r);
        if (fill.specified == 0 && fill.other == 0) return result;
        _setSwapFrontier(pool, context.depth, fill.frontier);
        result = _settle(pool, params.zeroForOne, r, fill, makerFee);
        emit BookFilled(pool, context.rootOperationId, fill.specified, fill.other, makerFee, fill.stop);
    }

    /// @dev Books the fill and returns its deltas. The input currency's shares: principal to makers less their fee;
    /// the taker fee's protocol-sized part and the maker fee half to the treasury, the rest to LPs; exact-input dust to
    /// the reserve. The output leaves escrow.
    function _settle(
        PoolId pool,
        bool zeroForOne,
        BookWalk.Request memory r,
        BookWalk.Fill memory fill,
        uint256 makerFee
    ) private returns (CallbackResult memory) {
        (uint256 input, uint256 output) = r.exactIn ? (fill.specified, fill.other) : (fill.other, fill.specified);
        uint256 toTreasury = _protocolPart(pool, zeroForOne, r.pool.fee, fill) / 2 + makerFee / 2;
        (uint256 i, uint256 o) = zeroForOne ? (0, 1) : (1, 0);
        Ledger storage ledger = _ledgers[pool];
        ledger.escrow[o] -= output;
        ledger.makers[i] += fill.principal - makerFee;
        ledger.treasury[i] += toTreasury;
        ledger.lpFees[i] += fill.takerFee + makerFee - toTreasury;
        ledger.reserve[i] += fill.dust;
        int128 paid = SafeCast.toInt128(input);
        int128 received = -SafeCast.toInt128(output);
        return zeroForOne ? CallbackResult(paid, received, 0) : CallbackResult(received, paid, 0);
    }

    /// @dev The protocol-sized part of the taker fee on book fills, as v4 splits a step's fee: the protocol's rate of
    /// the gross input, or the whole fee when the LP fee is zero.
    function _protocolPart(PoolId pool, bool zeroForOne, uint24 swapFee, BookWalk.Fill memory fill)
        private
        view
        returns (uint256 part)
    {
        (,, uint24 protocolFees,) = MANAGER.getSlot0(pool);
        uint24 protocolFee = zeroForOne ? protocolFees.getZeroForOneFee() : protocolFees.getOneForZeroFee();
        if (protocolFee == 0) return 0;
        // As in v4: the gross input fits int128 and the protocol fee is at most 1,000 pips, so this cannot overflow.
        part = protocolFee == swapFee ? fill.takerFee : (fill.principal + fill.takerFee) * protocolFee / PIPS;
        if (part > fill.takerFee) part = fill.takerFee;
    }

    /// @dev Donates the LPs' accrued fees when liquidity is in range; with none, moves an empty pool's price to the
    /// book's frontier. Both are same-pool routes; a failure leaves the shares for a later swap.
    function _afterSwap(ExecutionContext calldata context, PoolKey calldata key) private {
        PoolId pool = context.poolId;
        uint160 frontier = _takeSwapFrontier(pool, context.depth);
        if (MANAGER.getLiquidity(pool) != 0) {
            _donate(pool, key);
        } else if (frontier != 0) {
            (,,, uint24 lpFee) = MANAGER.getSlot0(pool);
            uint160 target = BookEngine.syncTarget(MANAGER, pool, key.tickSpacing, lpFee, frontier);
            if (target != 0) {
                try this.route(key, 0, 0, target) {
                    emit PriceMoved(pool, target);
                } catch {}
            }
        }
    }

    function _donate(PoolId pool, PoolKey calldata key) private {
        Ledger storage ledger = _ledgers[pool];
        uint256 amount0 = ledger.lpFees[0];
        uint256 amount1 = ledger.lpFees[1];
        if (amount0 == 0 && amount1 == 0) return;
        uint256 cap = uint256(uint128(type(int128).max));
        if (amount0 > cap) amount0 = cap;
        if (amount1 > cap) amount1 = cap;
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
        uint24 lpFee,
        uint256 gasReserve
    ) private view returns (BookWalk.Request memory r) {
        Policy storage policy = _policies[pool];
        r.pool = AmmReplay.Pool(
            MANAGER,
            pool,
            key.tickSpacing,
            params.zeroForOne,
            params.sqrtPriceLimitX96,
            AmmReplay.swapFee(MANAGER, pool, params.zeroForOne, lpFee)
        );
        r.exactIn = remaining < 0;
        uint256 budget = r.exactIn ? uint256(-remaining) : uint256(remaining);
        r.budget = budget > BookWalk.MAX_BOOK_AMOUNT ? BookWalk.MAX_BOOK_AMOUNT : budget;
        r.lotSize = params.zeroForOne ? policy.lotSize1 : policy.lotSize0; // the output currency's
        r.limits = policy.limits;
        r.minGas = gasReserve;
    }

    /// @dev Records a fill's frontier (0 clears the record), tagged with the pool's count of book fills in this
    /// transaction, which each fill advances.
    function _setSwapFrontier(PoolId pool, uint8 depth, uint160 frontier) private {
        bytes32 slot = keccak256(abi.encode(SWAP_RECORD, pool, depth));
        bytes32 fills = keccak256(abi.encode(SWAP_RECORD, pool));
        assembly ("memory-safe") {
            let record := 0
            if frontier {
                let n := add(tload(fills), 1)
                tstore(fills, n)
                record := or(frontier, shl(160, n))
            }
            tstore(slot, record)
        }
    }

    /// @dev The recorded frontier, unless a later fill in the pool (a nested swap's) has superseded it.
    function _takeSwapFrontier(PoolId pool, uint8 depth) private returns (uint160 frontier) {
        bytes32 slot = keccak256(abi.encode(SWAP_RECORD, pool, depth));
        bytes32 fills = keccak256(abi.encode(SWAP_RECORD, pool));
        assembly ("memory-safe") {
            let record := tload(slot)
            tstore(slot, 0)
            if eq(shr(160, record), tload(fills)) { frontier := and(record, sub(shl(160, 1), 1)) }
        }
    }

    // ---------------------------------------------------------------- internals

    function _readyPool(PoolKey calldata key, uint64 policyVersion) private view returns (PoolId pool) {
        pool = _validateKey(key);
        Installation storage installation = _installations[pool];
        if (!installation.installed || installation.configuredVersion != installation.policyVersion) {
            revert InvalidPool();
        }
        if (policyVersion != installation.policyVersion) revert InvalidVersion();
        (bool readable, uint256 flags) = _profile(pool, address(this));
        if (!readable || flags & ACTIVE == 0) revert InvalidPool();
    }

    function _placement(PoolId pool, bool sell0) private view returns (BookOrders.Placement memory) {
        Policy storage p = _policies[pool];
        return BookOrders.Placement(
            MANAGER, pool, msg.sender, sell0, p.makerFeePips, sell0 ? p.lotSize0 : p.lotSize1, p.minRangeLiquidity
        );
    }

    function _refund(PoolId pool, bool sell0, uint256 amount, address recipient) private {
        if (amount == 0) return;
        uint256 c = sell0 ? 0 : 1;
        _ledgers[pool].escrow[c] -= amount;
        VAULT.withdraw(pool, c == 0 ? _keys[pool].currency0 : _keys[pool].currency1, amount, recipient);
    }

    /// @param currency0 Whether the proceeds are in currency0 (a bid's).
    function _payMaker(PoolId pool, bool currency0, uint256 net, address recipient) private {
        if (recipient == address(0)) revert InvalidAmount();
        uint256 c = currency0 ? 0 : 1;
        _ledgers[pool].makers[c] -= net;
        if (net != 0) VAULT.withdraw(pool, c == 0 ? _keys[pool].currency0 : _keys[pool].currency1, net, recipient);
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
        for (uint256 c; c < 2; ++c) {
            if (
                ledger.escrow[c] != 0 || ledger.makers[c] != 0 || ledger.treasury[c] != 0 || ledger.lpFees[c] != 0
                    || ledger.reserve[c] != 0
            ) return false;
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

    function _validatePolicy(PoolId pool, Policy calldata p) private view {
        BookWalk.Limits calldata l = p.limits;
        if (
            p.lotSize0 == 0 || p.lotSize1 == 0 || p.lotSize0 > type(uint96).max || p.lotSize1 > type(uint96).max
                || p.makerFeePips > MAX_MAKER_FEE || p.treasury == address(0) || p.gasReserve < 100_000
                || l.ammSteps == 0 || l.ammSteps > 4096 || l.bookPoints == 0 || l.bookPoints > 1024 || l.words == 0
                || l.words > 64 || l.chunks == 0 || l.chunks > 256
        ) revert InvalidConfiguration();
        // Lot sizes are fixed while orders exist: open orders and claims are kept in lots.
        Policy storage current = _policies[pool];
        if (
            _ledgers[pool].openOrders != 0 && (p.lotSize0 != current.lotSize0 || p.lotSize1 != current.lotSize1)
        ) revert OrdersOpen();
    }

    function _checkSettings(ExtensionSettings calldata settings) private pure {
        // Optional: a failed or skipped book leaves the swap to the AMM. Nesting: the LP donation and the empty-pool
        // price move are same-pool routes from afterSwap.
        if (settings.callbackMask != CALLBACK_MASK || !settings.optionalCallbacks || !settings.allowNesting) {
            revert InvalidConfiguration();
        }
    }
}
