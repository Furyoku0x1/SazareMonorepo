// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {BookOrders} from "../src/libraries/BookOrders.sol";
import {FixedBook} from "../src/libraries/FixedBook.sol";
import {RangeBook} from "../src/libraries/RangeBook.sol";
import {OrderBookFixture} from "./utils/OrderBookFixture.sol";

/// @dev A maker contract that, when it receives native currency, tries one armed call back into the book.
contract Reenterer {
    address public immutable BOOK;
    bytes internal _payload;
    bool public attempted;
    bool public reentered;
    bytes public reason;

    constructor(address book) {
        BOOK = book;
    }

    /// @dev Also clears the last attempt's result, so each arming is checked on its own.
    function arm(bytes calldata payload) external {
        (_payload, attempted, reentered, reason) = (payload, false, false, "");
    }

    /// @dev Acts as the maker: forwards a call with value, bubbling a revert.
    function exec(address target, uint256 value, bytes calldata data) external payable returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call{value: value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    receive() external payable {
        if (_payload.length == 0) return;
        bytes memory payload = _payload;
        delete _payload;
        attempted = true;
        (reentered, reason) = BOOK.call(payload);
    }
}

/// @dev A token that makes one armed call on its next transfer, as tokens with transfer hooks can.
contract CallbackToken is MockERC20 {
    address internal _target;
    bytes internal _payload;
    bool public attempted;
    bool public reentered;
    bytes public reason;

    constructor() MockERC20("C", "C", 18) {}

    /// @dev Also clears the last attempt's result, so each arming is checked on its own.
    function arm(address target, bytes calldata payload) external {
        (_target, _payload, attempted, reentered, reason) = (target, payload, false, false, "");
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _hook();
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _hook();
        return ok;
    }

    function _hook() private {
        if (_target == address(0)) return;
        address target = _target;
        _target = address(0);
        attempted = true;
        (reentered, reason) = target.call(_payload);
    }
}

/// @dev Makers' funds through the book's life: reentrancy through native payments and token hooks, an inactive or
/// reinstalled book, policy changes, native ranges, and pending LP shares at removal.
contract OrderBookMakersTest is OrderBookFixture {
    using StateLibrary for IPoolManager;

    bytes4 internal constant EXECUTION_IN_PROGRESS = bytes4(keccak256("ExecutionInProgress()"));

    // ---------------------------------------------------------------- reentrancy

    /// @dev A bid's proceeds are native currency: the recipient's reentry into the book during the payment fails, and
    /// the claim completes once.
    function test_nativeClaimRecipientCannotReenter() public {
        _nativePool();
        _install(_policy());
        Reenterer maker = _reenterer();
        uint256 id = abi.decode(
            maker.exec(address(book), 0, abi.encodeCall(book.placeFixed, (key, false, -100, 1e11, _version()))), (uint256)
        );
        swapRouter.swap{value: 5e17}(key, SwapParams(true, -5e17, MIN_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        maker.arm(abi.encodeCall(book.claimFixed, (pool, id, address(maker))));
        uint256 net = abi.decode(
            maker.exec(address(book), 0, abi.encodeCall(book.claimFixed, (pool, id, address(maker)))), (uint256)
        );
        _assertReentryFailed(maker.attempted(), maker.reentered(), maker.reason());
        assertGt(net, 0);
        assertEq(address(maker).balance, net, "paid once");
        _checkBacking();
    }

    /// @dev A native ask's refund: the maker's reentry (here a second cancel) during the refund fails.
    function test_nativeRefundRecipientCannotReenter() public {
        _nativePool();
        _install(_policy());
        Reenterer maker = _reenterer();
        vm.deal(address(maker), 1e11);
        uint256 id = abi.decode(
            maker.exec(address(book), 1e11, abi.encodeCall(book.placeFixed, (key, true, 100, 1e5, _version()))), (uint256)
        );
        maker.arm(abi.encodeCall(book.cancelFixed, (pool, id, address(maker))));
        maker.exec(address(book), 0, abi.encodeCall(book.cancelFixed, (pool, id, address(maker))));
        _assertReentryFailed(maker.attempted(), maker.reentered(), maker.reason());
        assertEq(address(maker).balance, 1e11, "refunded once");
        _checkBacking();
    }

    /// @dev The treasury's native withdrawal: its reentry fails.
    function test_nativeTreasuryCannotReenter() public {
        _nativePool();
        Reenterer treasury = new Reenterer(address(book));
        OrderBook.Policy memory p = _policy();
        p.treasury = address(treasury);
        _install(p);
        _placeFixed(false, -100, 1e11);
        swapRouter.swap{value: 5e17}(key, SwapParams(true, -5e17, MIN_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        uint256 owed = book.ledger(pool).treasury[0];
        assertGt(owed, 0);
        Currency native = Currency.wrap(address(0));
        treasury.arm(abi.encodeCall(book.withdrawTreasury, (pool, native, 1, address(treasury), false)));
        treasury.exec(
            address(book), 0, abi.encodeCall(book.withdrawTreasury, (pool, native, owed, address(treasury), false))
        );
        _assertReentryFailed(treasury.attempted(), treasury.reentered(), treasury.reason());
        assertEq(address(treasury).balance, owed);
        _checkBacking();
    }

    /// @dev A token with transfer hooks reenters the book while the deposit moves it, and while a refund pays it out.
    function test_tokenHooksCannotReenter() public {
        CallbackToken token = new CallbackToken();
        MockERC20 other = MockERC20(Currency.unwrap(currency1));
        (address a, address b) = address(token) < address(other) ? (address(token), address(other)) : (address(other), address(token));
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 10, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        token.mint(MAKER, 1e30);
        vm.prank(MAKER);
        token.approve(address(book), type(uint256).max);
        _install(_policy());
        bool sell0 = address(token) == a; // the order sells the hooked token
        int24 tick = sell0 ? int24(100) : int24(-100);
        bytes memory sweep = abi.encodeCall(book.sweep, (pool));

        token.arm(address(book), sweep);
        uint256 id = _placeFixed(sell0, tick, 1e5);
        _assertReentryFailed(token.attempted(), token.reentered(), token.reason());

        token.arm(address(book), sweep);
        vm.prank(MAKER);
        assertEq(book.cancelFixed(pool, id, MAKER), 1e11, "refunded");
        _assertReentryFailed(token.attempted(), token.reentered(), token.reason());
        _checkBacking();
    }

    // ---------------------------------------------------------------- inactive, repeated, policy

    /// @dev While the book is inactive, makers can still cancel and claim; placing fails and swaps skip the book.
    function test_makersLeaveWhileInactive() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 fixedId = _placeFixed(true, 100, 1e11);
        uint256 rangeId = _placeRange(true, 50, 600, 1e18);
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        hook.deactivateExtension(key, IHookExtension(address(book)));
        vm.expectRevert(bytes4(keccak256("InvalidPool()")));
        _placeFixed(true, 100, 1e5);
        OrderBook.Ledger memory before = book.ledger(pool);
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        assertEq(keccak256(abi.encode(book.ledger(pool))), keccak256(abi.encode(before)), "swaps skip the book");
        vm.startPrank(MAKER);
        assertGt(book.cancelFixed(pool, fixedId, MAKER) + book.cancelRange(pool, rangeId, MAKER), 0, "refunds");
        assertGt(book.claimFixed(pool, fixedId, MAKER) + book.claimRange(pool, rangeId, MAKER), 0, "proceeds");
        vm.stopPrank();
        assertEq(book.ledger(pool).openOrders, 0);
        _checkBacking();
    }

    /// @dev Cancelling or claiming again pays nothing and settles an order only once.
    function test_repeatedCancelAndClaim() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 a = _placeFixed(true, 100, 1e11);
        uint256 b = _placeRange(true, 50, 600, 1e18);
        _placeFixed(true, 700, 1e5); // stays open
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        vm.startPrank(MAKER);
        for (uint256 i; i < 2; ++i) {
            uint256 refunds = book.cancelFixed(pool, a, MAKER) + book.cancelRange(pool, b, MAKER);
            uint256 proceeds = book.claimFixed(pool, a, MAKER) + book.claimRange(pool, b, MAKER);
            if (i == 0) assertGt(refunds + proceeds, 0);
            else assertEq(refunds + proceeds, 0, "nothing the second time");
        }
        vm.stopPrank();
        assertEq(book.ledger(pool).openOrders, 1, "settled once each");
        _checkBacking();
    }

    /// @dev Lot sizes cannot change while orders are open; once all are settled they can.
    function test_lotSizesFixedWhileOrdersOpen() public {
        _install(_policy());
        uint256 id = _placeFixed(true, 100, 1e5);
        hook.deactivateExtension(key, IHookExtension(address(book)));
        OrderBook.Policy memory p = _policy();
        p.lotSize0 = 2e6;
        vm.expectRevert(OrderBook.OrdersOpen.selector);
        book.setPolicy(key, 1, p);
        vm.prank(MAKER);
        book.cancelFixed(pool, id, MAKER);
        book.setPolicy(key, 1, p);
        (OrderBook.Policy memory stored,,) = book.policy(pool);
        assertEq(stored.lotSize0, 2e6);
    }

    /// @dev A new treasury takes the whole accrued share; the old one no longer can.
    function test_newTreasuryTakesTheShare() public {
        _lp(-6000, 6000, 1e18);
        OrderBook.Policy memory p = _policy();
        _install(p);
        _placeFixed(true, 100, 1e11);
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        uint256 owed = book.ledger(pool).treasury[1];
        assertGt(owed, 0);
        _reconfigure(p, address(0xBEEF));
        vm.prank(TREASURY);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        book.withdrawTreasury(pool, currency1, owed, TREASURY, false);
        vm.prank(address(0xBEEF));
        book.withdrawTreasury(pool, currency1, owed, address(0xBEEF), false);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(0xBEEF)), owed);
        _checkBacking();
    }

    /// @dev After a full close and removal, the book installs again on the same pool, keeps its old book state, and
    /// trades both sides normally.
    function test_reinstallAfterRemoval() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 100, 1e11);
        uint256 bid = _placeRange(false, -600, -50, 1e18);
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        _swap(SwapParams(true, -6e16, MIN_LIMIT));
        vm.startPrank(MAKER);
        book.cancelFixed(pool, ask, MAKER);
        book.cancelRange(pool, bid, MAKER);
        book.claimFixed(pool, ask, MAKER);
        book.claimRange(pool, bid, MAKER);
        vm.stopPrank();
        _closeAndRemove();

        (, uint64 version,) = book.policy(pool);
        ExtensionSettings memory settings = _settings();
        settings.configuration = abi.encode(uint64(0));
        hook.installExtension(key, IHookExtension(address(book)), settings);
        book.setPolicy(key, version, _policy());
        settings.configuration = abi.encode(version + 1);
        hook.configureExtension(key, IHookExtension(address(book)), settings);
        hook.activateExtension(key, IHookExtension(address(book)));

        (, int24 tick,,) = manager.getSlot0(pool);
        uint256 ask2 = _placeFixed(true, tick + 10, 1e11);
        uint256 bid2 = _placeFixed(false, tick - 10, 1e11);
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        _swap(SwapParams(true, -6e16, MIN_LIMIT));
        (, uint64 askFilled) = book.fixedOrder(pool, ask2);
        (, uint64 bidFilled) = book.fixedOrder(pool, bid2);
        assertGt(askFilled, 0, "asks fill again");
        assertGt(bidFilled, 0, "bids fill again");
        _checkBacking();
    }

    // ---------------------------------------------------------------- native ranges, payments

    /// @dev A native ask range: the deposit is exact, a cancel refunds the unsold native part, the proceeds are
    /// claimed; and a bid range's native proceeds.
    function test_nativeRanges() public {
        _nativePool();
        _install(_policy());
        uint256 deposit = _rangeDeposit(true, 50, 600, 1e18);
        vm.deal(MAKER, 10 ether);
        vm.prank(MAKER);
        vm.expectRevert(BookOrders.InvalidAmount.selector);
        book.placeRange{value: deposit - 1}(key, true, 50, 600, 1e18, _version());
        vm.prank(MAKER);
        uint256 ask = book.placeRange{value: deposit}(key, true, 50, 600, 1e18, _version());
        uint256 bid = _placeRange(false, -600, -50, 1e18);
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        swapRouter.swap{value: 1e17}(key, SwapParams(true, -1e17, MIN_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        uint256 balance = MAKER.balance;
        vm.startPrank(MAKER);
        uint256 refund = book.cancelRange(pool, ask, MAKER);
        assertEq(MAKER.balance - balance, refund, "native refund");
        (RangeBook.Range memory range, uint160 frontier) = book.rangeOrder(pool, ask);
        assertEq(
            refund,
            SqrtPriceMath.getAmount0Delta(frontier, TickMath.getSqrtPriceAtTick(range.upper), range.liquidity, false),
            "refund: the unsold part, rounded down"
        );
        book.claimRange(pool, ask, MAKER);
        balance = MAKER.balance;
        uint256 net = book.claimRange(pool, bid, MAKER);
        assertGt(net, 0);
        assertEq(MAKER.balance - balance, net, "native proceeds");
        vm.stopPrank();
        _checkBacking();
    }

    /// @dev Native currency sent with an ERC20 order is refused.
    function test_valueWithAnErc20OrderIsRefused() public {
        _install(_policy());
        vm.deal(MAKER, 1);
        vm.prank(MAKER);
        vm.expectRevert(BookOrders.InvalidAmount.selector);
        book.placeFixed{value: 1}(key, true, 100, 1e5, _version());
    }

    // ---------------------------------------------------------------- removal

    /// @dev In a pool with no liquidity the LPs' share cannot be donated, so it blocks removal; once liquidity enters,
    /// the next swap donates it and the book can be removed.
    function test_pendingLpSharesBlockRemovalUntilLiquidityEnters() public {
        _install(_policy());
        uint256 id = _placeFixed(true, 200, 1e11);
        _swap(SwapParams(false, -5e16, MAX_LIMIT));
        vm.startPrank(MAKER);
        book.cancelFixed(pool, id, MAKER);
        book.claimFixed(pool, id, MAKER);
        vm.stopPrank();
        book.sweep(pool);
        _withdrawTreasury();
        assertGt(book.ledger(pool).lpFees[1], 0, "the LPs' share is pending");
        hook.deactivateExtension(key, IHookExtension(address(book)));
        vm.expectRevert();
        hook.removeExtension(key, IHookExtension(address(book)));
        hook.activateExtension(key, IHookExtension(address(book)));
        _lp(150, 250, 1e18);
        _swap(SwapParams(true, -1e6, MIN_LIMIT));
        assertEq(book.ledger(pool).lpFees[1], 0, "donated");
        _closeAndRemove();
    }

    // ---------------------------------------------------------------- helpers

    function _nativePool() private {
        key = PoolKey(Currency.wrap(address(0)), currency1, 3000, 10, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        vm.deal(address(this), 100 ether);
        lpRouter.modifyLiquidity{value: 10 ether}(key, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
    }

    function _reenterer() private returns (Reenterer maker) {
        maker = new Reenterer(address(book));
        MockERC20 token = MockERC20(Currency.unwrap(currency1));
        token.mint(address(maker), 1e30);
        maker.exec(address(token), 0, abi.encodeCall(token.approve, (address(book), type(uint256).max)));
    }

    function _assertReentryFailed(bool attempted, bool reentered, bytes memory reason) private pure {
        assertTrue(attempted, "a reentry was tried");
        assertFalse(reentered, "the reentry failed");
        assertEq(bytes4(reason), EXECUTION_IN_PROGRESS, "stopped by the book's guard");
    }

    /// @dev Deactivates, sets a policy with this treasury, and reactivates.
    function _reconfigure(OrderBook.Policy memory p, address treasury) private {
        hook.deactivateExtension(key, IHookExtension(address(book)));
        (, uint64 version,) = book.policy(pool);
        p.treasury = treasury;
        book.setPolicy(key, version, p);
        ExtensionSettings memory settings = _settings();
        settings.configuration = abi.encode(version + 1);
        hook.configureExtension(key, IHookExtension(address(book)), settings);
        hook.activateExtension(key, IHookExtension(address(book)));
    }

    function _withdrawTreasury() private {
        OrderBook.Ledger memory l = book.ledger(pool);
        (OrderBook.Policy memory p,,) = book.policy(pool);
        vm.startPrank(p.treasury);
        if (l.treasury[0] != 0) book.withdrawTreasury(pool, key.currency0, l.treasury[0], p.treasury, false);
        if (l.treasury[1] != 0) book.withdrawTreasury(pool, key.currency1, l.treasury[1], p.treasury, false);
        vm.stopPrank();
    }

    /// @dev Sweeps, pays the treasury, donates what LPs are owed with a small swap, and removes the book.
    function _closeAndRemove() private {
        assertEq(book.ledger(pool).openOrders, 0, "every order settled");
        book.sweep(pool);
        _withdrawTreasury();
        OrderBook.Ledger memory l = book.ledger(pool);
        if (l.lpFees[0] + l.lpFees[1] != 0) _swap(SwapParams(true, -1e6, MIN_LIMIT));
        hook.deactivateExtension(key, IHookExtension(address(book)));
        hook.removeExtension(key, IHookExtension(address(book)));
        assertFalse(hook.isInstalled(pool, address(book)));
        assertEq(hook.VAULT().fundedCurrencyCount(pool, address(book)), 0, "vault emptied");
    }
}
