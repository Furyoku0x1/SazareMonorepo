// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "core/src/interfaces/IKernelHookExtension.sol";
import {CallbackResult, CallbackType, ExecutionContext, ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {KernelExtension} from "./base/KernelExtension.sol";
import {OrderMath} from "./libraries/OrderMath.sol";
import {RangeOrderMath} from "./libraries/RangeOrderMath.sol";

/// @notice Escrowed maker-priced orders for Kernel pools. One contract contains every book and claim.
/// @dev Standard ERC20/native currencies only. Pool policy admits its pair; fee/rebasing tokens are unsupported.
contract LimitOrder is KernelExtension, IKernelHookExtension {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint16 public constant CALLBACK_MASK = uint16(1) << uint8(CallbackType.BeforeSwap);
    uint32 internal constant MAX_OPEN_ORDERS = 4096;
    uint8 internal constant MAX_FILLS = 4;
    uint8 internal constant MAX_INSPECTIONS = 8;
    uint8 internal constant MAX_CO_SUBSCRIBERS = 4;
    uint8 internal constant MAX_EXPIRATIONS = 64;

    enum OrderStatus {
        Unknown,
        Open,
        Filled,
        Cancelled,
        Expired
    }

    struct Policy {
        uint128 minimumOrder;
        uint40 maximumLifetime;
        uint32 maximumOpenOrders;
        uint16 feeBps;
        uint16 revenueShareBps;
        uint8 maximumFills;
        uint8 maximumInspections;
        uint8 maximumCoSubscribers;
        bool allowNested;
        address feeBeneficiary;
    }

    struct OrderRequest {
        bool sellCurrency0;
        bool allowNested;
        uint128 amount;
        uint128 priceNumerator;
        uint128 priceDenominator;
        uint40 expiry;
        uint16 maximumFeeBps;
        uint64 expectedPolicyVersion;
        uint64 predecessor;
        // Zero keeps a fixed-price order. Otherwise >= priceNumerator, in the
        // same received-per-sold raw units and with the same denominator.
        uint128 endPriceNumerator;
    }

    struct Order {
        address owner;
        uint40 expiry;
        bool sellCurrency0;
        bool allowNested;
        OrderStatus status;
        uint16 feeBps;
        uint16 revenueShareBps;
        address feeBeneficiary;
        uint64 predecessor;
        uint64 successor;
        uint64 policyVersion;
        uint128 originalAmount;
        // Unfilled quantity. On cancellation/expiry it records the refund;
        // only Open orders retain escrow. This preserves historical progress.
        uint128 remaining;
        uint128 priceNumerator;
        uint128 priceDenominator;
        uint128 endPriceNumerator;
    }

    struct Book {
        uint64 nextIndex;
        uint64 version;
        uint64[2] head;
        uint64[2] tail;
        uint32[2] openCount;
        uint256[2] liabilities;
    }

    /// @dev Static ABI (eight words) permits a tightly bounded cross-extension preview call.
    struct FillPreview {
        uint128 input;
        uint128 output;
        uint64 bookVersion;
        uint64 policyVersion;
        uint8 fills;
        uint8 inspections;
        bool limitReached;
        bool available;
    }

    struct PlannedFill {
        uint64 index;
        bool expired;
        OrderMath.Fill amounts;
    }

    struct MatchPlan {
        FillPreview preview;
        PlannedFill[8] entries;
        uint8 entryCount;
    }

    struct Installation {
        bool installed;
        uint64 policyVersion;
        uint64 configuredVersion;
    }

    mapping(PoolId => Installation) private _installations;
    mapping(PoolId => Policy) private _policies;
    mapping(PoolId => Book) private _books;
    mapping(PoolId => mapping(uint64 => Order)) private _orders;
    mapping(PoolId => mapping(address => uint256[2])) private _claims;
    mapping(PoolId => mapping(address => uint256[2])) private _revenue;

    error InvalidOrder();
    error InvalidHints();
    error BookFull();
    error TransferMismatch();
    error IncompatibleProfile();

    event PolicyUpdated(PoolId indexed pool, uint64 version);
    event OrderPlaced(
        PoolId indexed pool,
        uint64 indexed index,
        address indexed owner,
        bool sellCurrency0,
        uint128 amount,
        uint128 endPriceNumerator
    );
    event OrderClosed(PoolId indexed pool, uint64 indexed index, OrderStatus status, uint128 refund);
    event OrderFilled(
        PoolId indexed pool, uint64 indexed index, uint64 rootOperation, uint128 output, uint128 payment, uint128 fee
    );
    event Claimed(
        PoolId indexed pool, address indexed owner, Currency currency, uint256 amount, address recipient, bool revenue
    );
    event MatchingSkipped(PoolId indexed pool);

    constructor(IKernelHook kernel) KernelExtension(kernel) {}

    function setPolicy(PoolKey memory key, uint64 expectedVersion, Policy memory policy) external publicMutation {
        PoolId pool = _validateKey(key);
        _requireRole(pool);
        Installation storage installation = _installations[pool];
        if (!installation.installed || !KERNEL.isPoolInitialized(pool)) revert InvalidPool();
        (bool readable, uint256 flags) = _profile(pool, address(this));
        if (!readable || flags & ACTIVE != 0) revert InvalidConfiguration();
        if (installation.policyVersion != expectedVersion) revert InvalidVersion();
        _validatePolicy(policy);
        _policies[pool] = policy;
        ++installation.policyVersion;
        emit PolicyUpdated(pool, installation.policyVersion);
    }

    function placeOrder(PoolKey memory key, OrderRequest memory request)
        external
        payable
        publicMutation
        returns (uint64 index)
    {
        PoolId pool = _validateKey(key);
        Installation storage installation = _installations[pool];
        Policy memory policy = _policies[pool];
        if (!KERNEL.isPoolInitialized(pool) || !_ready(pool) || !_compatible(pool)) revert IncompatibleProfile();
        if (request.expectedPolicyVersion != installation.policyVersion) revert InvalidVersion();
        _validateOrder(request, policy);
        uint8 side = request.sellCurrency0 ? 0 : 1;
        Book storage book = _books[pool];
        if (book.openCount[side] >= policy.maximumOpenOrders) revert BookFull();
        uint64 next = _checkHints(pool, request, side);
        index = ++book.nextIndex;
        Order storage order = _orders[pool][index];
        order.owner = msg.sender;
        order.expiry = request.expiry;
        order.sellCurrency0 = request.sellCurrency0;
        order.allowNested = request.allowNested;
        order.status = OrderStatus.Open;
        order.feeBps = policy.feeBps;
        order.revenueShareBps = policy.revenueShareBps;
        order.feeBeneficiary = policy.feeBeneficiary;
        order.policyVersion = installation.policyVersion;
        order.originalAmount = request.amount;
        order.remaining = request.amount;
        order.priceNumerator = request.priceNumerator;
        order.priceDenominator = request.priceDenominator;
        order.endPriceNumerator = request.endPriceNumerator;
        _insert(pool, index, request.predecessor, next, side);
        ++book.openCount[side];
        ++book.version;
        book.liabilities[side] += request.amount;
        _deposit(pool, side == 0 ? key.currency0 : key.currency1, request.amount);
        emit OrderPlaced(pool, index, msg.sender, request.sellCurrency0, request.amount, request.endPriceNumerator);
    }

    function cancelOrder(PoolId pool, uint64 index) external publicMutation {
        Order storage order = _orders[pool][index];
        if (order.owner != msg.sender) revert Unauthorized();
        if (order.status != OrderStatus.Open) revert InvalidOrder();
        _close(pool, index, OrderStatus.Cancelled);
    }

    function expireOrders(PoolId pool, uint64[] calldata indices) external publicMutation {
        if (indices.length > MAX_EXPIRATIONS) revert InvalidAmount();
        for (uint256 i; i < indices.length; ++i) {
            Order storage order = _orders[pool][indices[i]];
            if (order.status == OrderStatus.Open && order.expiry <= block.timestamp) {
                _close(pool, indices[i], OrderStatus.Expired);
            }
        }
    }

    function claim(PoolId pool, Currency currency, uint256 amount, address recipient) external publicMutation {
        _claim(pool, currency, amount, recipient, false);
    }

    function claimRevenue(PoolId pool, Currency currency, uint256 amount, address recipient) external publicMutation {
        _claim(pool, currency, amount, recipient, true);
    }

    function getOrder(PoolId pool, uint64 index) external view returns (Order memory) {
        return _orders[pool][index];
    }

    function policyState(PoolId pool) external view returns (Policy memory, uint64, uint64) {
        Installation storage installation = _installations[pool];
        return (_policies[pool], installation.policyVersion, installation.configuredVersion);
    }

    function bookState(PoolId pool, bool sellCurrency0)
        external
        view
        returns (uint64 head, uint64 tail, uint32 openCount, uint64 version, uint256 liability)
    {
        Book storage book = _books[pool];
        uint8 side = sellCurrency0 ? 0 : 1;
        return (book.head[side], book.tail[side], book.openCount[side], book.version, book.liabilities[side]);
    }

    function claimable(PoolId pool, address owner, Currency currency)
        external
        view
        returns (uint256 maker, uint256 revenue)
    {
        uint8 side = _currencySide(pool, currency);
        return (_claims[pool][owner][side], _revenue[pool][owner][side]);
    }

    /// @notice Liabilities are authoritative; reconciliation is only reported outside all Kernel operations.
    function accountingState(PoolId pool)
        external
        view
        returns (uint256 liability0, uint256 liability1, bool reconciled)
    {
        reconciled = !_entered && !_vaultTransferInProgress() && _contextDepth() == 0;
        return (_books[pool].liabilities[0], _books[pool].liabilities[1], reconciled);
    }

    function previewFill(PoolId pool, bool zeroForOne, uint128 budget, bool nested)
        external
        view
        returns (FillPreview memory preview)
    {
        if (_entered || _vaultTransferInProgress()) return preview;
        (PoolId currentPool, address currentExtension,) = _contextState();
        if (PoolId.unwrap(currentPool) == PoolId.unwrap(pool) && currentExtension == address(this)) return preview;
        if (!_ready(pool) || !_compatible(pool)) return preview;
        (uint160 price,,,) = MANAGER.getSlot0(pool);
        return _plan(pool, zeroForOne, budget, nested, price).preview;
    }

    function onInstall(PoolKey memory key, ExtensionSettings calldata settings) external lifecycle returns (bytes4) {
        PoolId pool = _validateKey(key);
        _checkSettings(settings);
        Installation storage installation = _installations[pool];
        if (installation.installed) revert InvalidConfiguration();
        installation.installed = true;
        installation.configuredVersion = _version(settings.configuration);
        if (installation.configuredVersion != 0 && installation.configuredVersion != installation.policyVersion) {
            revert InvalidVersion();
        }
        return this.onInstall.selector;
    }

    function onConfigure(PoolKey memory key, ExtensionSettings calldata, ExtensionSettings calldata settings)
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

    function canActivate(PoolKey memory key, ExtensionSettings calldata settings)
        external
        view
        onlyKernel
        returns (bool)
    {
        _checkSettings(settings);
        PoolId pool = _validateKey(key);
        Installation storage installation = _installations[pool];
        return installation.installed && _policies[pool].minimumOrder != 0 && installation.policyVersion != 0
            && installation.policyVersion == _version(settings.configuration)
            && installation.configuredVersion == installation.policyVersion && KERNEL.isPoolInitialized(pool)
            && _compatible(pool)
            && _callbackFits(
            pool,
            CallbackType.BeforeSwap,
            settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)],
            KERNEL.callbackOrder(pool, CallbackType.BeforeSwap).length,
            false
        );
    }

    function canUninstall(PoolKey memory key) external view onlyKernel returns (bool) {
        Book storage book = _books[key.toId()];
        return !_entered && book.openCount[0] == 0 && book.openCount[1] == 0 && book.liabilities[0] == 0
            && book.liabilities[1] == 0;
    }

    function onUninstall(PoolKey memory key, bytes calldata) external lifecycle returns (bytes4) {
        PoolId pool = key.toId();
        Book storage book = _books[pool];
        if (book.openCount[0] != 0 || book.openCount[1] != 0 || book.liabilities[0] != 0 || book.liabilities[1] != 0) {
            revert OutstandingObligations();
        }
        _installations[pool].installed = false;
        _installations[pool].configuredVersion = 0;
        delete _policies[pool];
        return this.onUninstall.selector;
    }

    function onCallback(ExecutionContext memory context, PoolKey memory key, bytes calldata data)
        external
        onlyKernel
        returns (CallbackResult memory result)
    {
        _authenticate(context, key);
        if (context.callback != CallbackType.BeforeSwap) revert Unauthorized();
        if (!_compatible(context.poolId)) {
            emit MatchingSkipped(context.poolId);
            return result;
        }
        // SwapParams is the static prefix of Kernel's (params, hookData) encoding.
        SwapParams memory params = abi.decode(data, (SwapParams));
        if (params.amountSpecified >= 0) return result;
        (uint160 price,,,) = MANAGER.getSlot0(context.poolId);
        _checkPriceLimit(params, price);
        uint256 input = params.amountSpecified == type(int256).min
            ? uint256(type(int256).max) + 1
            : uint256(-params.amountSpecified);
        if (input > OrderMath.MAX_DELTA) input = OrderMath.MAX_DELTA;
        _entered = true;
        MatchPlan memory plan = _plan(context.poolId, params.zeroForOne, uint128(input), context.depth > 1, price);
        _applyPlan(context, plan);
        _entered = false;
        int128 gross = int128(plan.preview.input);
        int128 output = int128(plan.preview.output);
        return params.zeroForOne ? CallbackResult(gross, -output, 0) : CallbackResult(-output, gross, 0);
    }

    function _plan(PoolId pool, bool zeroForOne, uint128 budget, bool nested, uint160 price)
        private
        view
        returns (MatchPlan memory plan)
    {
        Policy storage policy = _policies[pool];
        Book storage book = _books[pool];
        plan.preview.bookVersion = book.version;
        plan.preview.policyVersion = _installations[pool].policyVersion;
        plan.preview.available = true;
        if (nested && !policy.allowNested) return plan;
        uint64 index = book.head[zeroForOne ? 1 : 0];
        uint256 cappedBudget = budget > OrderMath.MAX_DELTA ? OrderMath.MAX_DELTA : budget;
        while (
            index != 0 && plan.preview.inspections < policy.maximumInspections
                && plan.preview.fills < policy.maximumFills && plan.preview.input < cappedBudget
        ) {
            Order storage order = _orders[pool][index];
            ++plan.preview.inspections;
            if (order.expiry <= block.timestamp) {
                PlannedFill memory entry = plan.entries[plan.entryCount++];
                entry.index = index;
                entry.expired = true;
            } else if (!nested || order.allowNested) {
                OrderMath.Fill memory amounts = _quoteOrder(
                    order,
                    cappedBudget - plan.preview.input,
                    OrderMath.MAX_DELTA - plan.preview.output,
                    price,
                    zeroForOne
                );
                // A range's live price can move beyond its immutable placement
                // price. It must not hide a still-competitive successor.
                if (amounts.output == 0 && order.endPriceNumerator == 0) break;
                uint256 gross = uint256(amounts.payment) + amounts.fee;
                if (amounts.payment != 0) {
                    PlannedFill memory entry = plan.entries[plan.entryCount++];
                    entry.index = index;
                    entry.amounts = amounts;
                    plan.preview.input += uint128(gross);
                    plan.preview.output += amounts.output;
                    ++plan.preview.fills;
                }
            }
            index = order.successor;
        }
        plan.preview.limitReached = index != 0;
    }

    function _quoteOrder(Order storage order, uint256 budget, uint256 outputRoom, uint160 price, bool zeroForOne)
        private
        view
        returns (OrderMath.Fill memory amounts)
    {
        if (outputRoom > order.remaining) outputRoom = order.remaining;
        amounts = RangeOrderMath.fill(_curve(order), RangeOrderMath.Bounds(budget, outputRoom, price, zeroForOne));
        if (
            amounts.output != 0
                && !OrderMath.competitive(uint256(amounts.payment) + amounts.fee, amounts.output, price, zeroForOne)
        ) {
            // Keep output nonzero to distinguish a noncompetitive order from a non-fitting FIFO order.
            amounts.payment = 0;
            amounts.fee = 0;
        }
    }

    function _curve(Order storage order) private view returns (RangeOrderMath.Curve memory) {
        return RangeOrderMath.Curve(
            order.originalAmount,
            order.originalAmount - order.remaining,
            order.priceNumerator,
            order.endPriceNumerator,
            order.priceDenominator,
            order.feeBps
        );
    }

    function _applyPlan(ExecutionContext memory context, MatchPlan memory plan) private {
        PoolId pool = context.poolId;
        for (uint256 i; i < plan.entryCount; ++i) {
            PlannedFill memory fill = plan.entries[i];
            if (fill.expired) {
                _close(pool, fill.index, OrderStatus.Expired);
                continue;
            }
            Order storage order = _orders[pool][fill.index];
            uint8 sellSide = order.sellCurrency0 ? 0 : 1;
            uint8 receiveSide = 1 - sellSide;
            order.remaining -= fill.amounts.output;
            uint256 revenue =
                RangeOrderMath.revenue(_curve(order), fill.amounts.output, fill.amounts.fee, order.revenueShareBps);
            _claims[pool][order.owner][receiveSide] += uint256(fill.amounts.payment) + fill.amounts.fee - revenue;
            if (revenue != 0) _revenue[pool][order.feeBeneficiary][receiveSide] += revenue;
            Book storage book = _books[pool];
            book.liabilities[sellSide] -= fill.amounts.output;
            book.liabilities[receiveSide] += uint256(fill.amounts.payment) + fill.amounts.fee;
            ++book.version;
            if (order.remaining == 0) _close(pool, fill.index, OrderStatus.Filled);
            emit OrderFilled(
                pool, fill.index, context.rootOperationId, fill.amounts.output, fill.amounts.payment, fill.amounts.fee
            );
        }
    }

    function _validatePolicy(Policy memory policy) private pure {
        if (
            policy.minimumOrder == 0 || policy.minimumOrder > OrderMath.MAX_DELTA || policy.maximumLifetime == 0
                || policy.maximumOpenOrders == 0 || policy.maximumOpenOrders > MAX_OPEN_ORDERS
                || policy.maximumFills == 0 || policy.maximumFills > MAX_FILLS
                || policy.maximumInspections < policy.maximumFills || policy.maximumInspections > MAX_INSPECTIONS
                || policy.maximumCoSubscribers == 0 || policy.maximumCoSubscribers > MAX_CO_SUBSCRIBERS
                || policy.feeBps > 1000 || policy.revenueShareBps > OrderMath.BPS
                || (policy.revenueShareBps != 0 && policy.feeBeneficiary == address(0))
        ) revert InvalidConfiguration();
    }

    function _validateOrder(OrderRequest memory request, Policy memory policy) private view {
        if (
            request.amount < policy.minimumOrder || request.amount > OrderMath.MAX_DELTA || request.priceNumerator == 0
                || request.priceDenominator == 0 || request.expiry <= block.timestamp
                || uint256(request.expiry) - block.timestamp > policy.maximumLifetime
                || request.maximumFeeBps < policy.feeBps || (request.allowNested && !policy.allowNested)
        ) revert InvalidOrder();
        if (request.endPriceNumerator != 0 && request.endPriceNumerator < request.priceNumerator) {
            revert InvalidOrder();
        }
    }

    function _checkHints(PoolId pool, OrderRequest memory request, uint8 side) private view returns (uint64 next) {
        uint64 previous = request.predecessor;
        if (previous == 0) {
            next = _books[pool].head[side];
        } else {
            Order storage predecessor = _orders[pool][previous];
            if (
                predecessor.status != OrderStatus.Open || predecessor.sellCurrency0 != request.sellCurrency0
                    || OrderMath.compare(
                            predecessor.priceNumerator,
                            predecessor.priceDenominator,
                            request.priceNumerator,
                            request.priceDenominator
                        ) > 0
            ) revert InvalidHints();
            next = predecessor.successor;
        }
        if (next != 0) {
            Order storage successor = _orders[pool][next];
            if (
                OrderMath.compare(
                        request.priceNumerator,
                        request.priceDenominator,
                        successor.priceNumerator,
                        successor.priceDenominator
                    ) >= 0
            ) revert InvalidHints();
        }
    }

    function _insert(PoolId pool, uint64 index, uint64 previous, uint64 next, uint8 side) private {
        Order storage order = _orders[pool][index];
        order.predecessor = previous;
        order.successor = next;
        if (previous == 0) _books[pool].head[side] = index;
        else _orders[pool][previous].successor = index;
        if (next == 0) _books[pool].tail[side] = index;
        else _orders[pool][next].predecessor = index;
    }

    function _close(PoolId pool, uint64 index, OrderStatus status) private {
        Order storage order = _orders[pool][index];
        assert(order.status == OrderStatus.Open);
        uint8 side = order.sellCurrency0 ? 0 : 1;
        uint128 refund = order.remaining;
        if (order.predecessor == 0) _books[pool].head[side] = order.successor;
        else _orders[pool][order.predecessor].successor = order.successor;
        if (order.successor == 0) _books[pool].tail[side] = order.predecessor;
        else _orders[pool][order.successor].predecessor = order.predecessor;
        order.status = status;
        --_books[pool].openCount[side];
        ++_books[pool].version;
        if (refund != 0) _claims[pool][order.owner][side] += refund;
        emit OrderClosed(pool, index, status, refund);
    }

    function _claim(PoolId pool, Currency currency, uint256 amount, address recipient, bool revenue) private {
        if (amount == 0 || recipient == address(0)) revert InvalidAmount();
        uint8 side = _currencySide(pool, currency);
        uint256 balance = revenue ? _revenue[pool][msg.sender][side] : _claims[pool][msg.sender][side];
        if (amount > balance) revert InvalidAmount();
        if (revenue) _revenue[pool][msg.sender][side] = balance - amount;
        else _claims[pool][msg.sender][side] = balance - amount;
        _books[pool].liabilities[side] -= amount;
        VAULT.withdraw(pool, currency, amount, recipient);
        emit Claimed(pool, msg.sender, currency, amount, recipient, revenue);
    }

    function _deposit(PoolId pool, Currency currency, uint128 amount) private {
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            if (msg.value != amount) revert InvalidAmount();
            VAULT.deposit{value: amount}(pool, address(this), currency, amount);
        } else {
            if (msg.value != 0) revert InvalidAmount();
            IERC20 asset = IERC20(token);
            uint256 beforeBalance = asset.balanceOf(address(this));
            asset.safeTransferFrom(msg.sender, address(this), amount);
            if (asset.balanceOf(address(this)) - beforeBalance != amount) revert TransferMismatch();
            asset.forceApprove(address(VAULT), amount);
            VAULT.deposit(pool, address(this), currency, amount);
            asset.forceApprove(address(VAULT), 0);
            if (asset.balanceOf(address(this)) != beforeBalance) revert TransferMismatch();
        }
    }

    function _currencySide(PoolId pool, Currency currency) private view returns (uint8) {
        PoolKey memory key = KERNEL.poolKey(pool);
        if (currency == key.currency0) return 0;
        if (currency == key.currency1) return 1;
        revert InvalidPool();
    }

    function _ready(PoolId pool) private view returns (bool) {
        Installation storage installation = _installations[pool];
        if (
            !installation.installed || installation.policyVersion == 0
                || installation.configuredVersion != installation.policyVersion
        ) return false;
        (bool readable, uint256 flags) = _profile(pool, address(this));
        return readable && flags & ACTIVE != 0;
    }

    function _compatible(PoolId pool) private view returns (bool) {
        address[] memory order = KERNEL.callbackOrder(pool, CallbackType.BeforeSwap);
        if (order.length == 0 || order[0] != address(this) || order.length > _policies[pool].maximumCoSubscribers) {
            return false;
        }
        for (uint256 i = 1; i < order.length; ++i) {
            (bool readable, uint256 flags) = _profile(pool, order[i]);
            if (!readable || (flags & ACTIVE != 0 && flags & OPTIONAL == 0)) return false;
        }
        return true;
    }

    function _checkSettings(ExtensionSettings calldata settings) private pure {
        if (settings.callbackMask != CALLBACK_MASK || !settings.optionalCallbacks || settings.allowNesting) {
            revert InvalidConfiguration();
        }
    }

    function _checkPriceLimit(SwapParams memory params, uint160 price) private pure {
        uint160 limit = params.sqrtPriceLimitX96;
        if ((params.zeroForOne && limit >= price) || (!params.zeroForOne && limit <= price)) {
            revert Pool.PriceLimitAlreadyExceeded(price, limit);
        }
        if (
            (params.zeroForOne && limit <= TickMath.MIN_SQRT_PRICE)
                || (!params.zeroForOne && limit >= TickMath.MAX_SQRT_PRICE)
        ) revert Pool.PriceLimitOutOfBounds(limit);
    }
}
