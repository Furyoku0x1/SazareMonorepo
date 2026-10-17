// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {OrderBook} from "../src/orderbook/OrderBook.sol";
import {RevenueSplitter} from "../src/orderbook/RevenueSplitter.sol";
import {OrderBookFixture} from "./utils/OrderBookFixture.sol";

/// @dev Reports a treasury share it never pays.
contract LyingBook {
    function ledger(PoolId) external pure returns (OrderBook.Ledger memory owed) {
        owed.treasury[0] = 1e18;
        owed.treasury[1] = 1e18;
    }

    function withdrawTreasury(PoolId, Currency, uint256, address, bool) external {}
}

/// @dev Reports a share too large for one vault redemption, and records what it is asked for.
contract HugeBook {
    uint256 public requested;

    function ledger(PoolId) external pure returns (OrderBook.Ledger memory owed) {
        owed.treasury[1] = 1 << 200;
    }

    function withdrawTreasury(PoolId, Currency, uint256 amount, address, bool) external {
        requested = amount;
    }
}

/// @dev Owes a share larger than one vault redemption, and pays each withdrawal in full from its own tokens.
contract LargeShareBook {
    MockERC20 public immutable TOKEN;
    uint256 public owed;

    constructor(MockERC20 token, uint256 share) {
        (TOKEN, owed) = (token, share);
    }

    function ledger(PoolId) external view returns (OrderBook.Ledger memory book) {
        book.treasury[1] = owed;
    }

    function withdrawTreasury(PoolId, Currency, uint256 amount, address recipient, bool) external {
        owed -= amount;
        TOKEN.mint(recipient, amount);
    }
}

contract RevenueSplitterTest is OrderBookFixture {
    address internal constant SAZARE = address(0x5A2E);
    address internal constant OPERATOR = address(0x0BE7);
    address internal constant STRANGER = address(0x5742);
    uint256 internal constant HALF_PIPS = 500_000;

    RevenueSplitter internal splitter;

    function setUp() public override {
        super.setUp();
        splitter = new RevenueSplitter(IKernelHook(address(hook)), SAZARE, HALF_PIPS);
        _deployBook(address(splitter));
    }

    function test_collectSplitsAPoolsShareInHalf() public {
        uint256 owed = _earnTreasuryShare();
        vm.prank(STRANGER);
        splitter.collect(book, pool);
        assertEq(book.ledger(pool).treasury[1], 0, "the book paid the whole share");
        uint256 sazareAmount = owed / 2;
        assertEq(splitter.sazareOwed(currency1), sazareAmount, "Sazare's half, rounded down");
        assertEq(splitter.operatorOwed(pool, currency1), owed - sazareAmount, "the operator's half and any odd unit");
        assertEq(_balance(currency1, address(splitter)), owed, "all of it held here");
        _checkBacking();
    }

    function test_poolAdminClaimsTheOperatorShare() public {
        uint256 owed = _earnTreasuryShare();
        splitter.collect(book, pool);
        uint256 operatorAmount = splitter.operatorOwed(pool, currency1);
        vm.prank(STRANGER);
        vm.expectRevert(RevenueSplitter.Unauthorized.selector);
        splitter.claim(pool, currency1, operatorAmount, STRANGER);
        vm.expectRevert(RevenueSplitter.InvalidAmount.selector);
        splitter.claim(pool, currency1, operatorAmount + 1, OPERATOR);
        // This test contract initialized the pool, so it is the pool's admin.
        splitter.claim(pool, currency1, operatorAmount, OPERATOR);
        assertEq(_balance(currency1, OPERATOR), operatorAmount, "the operator's share");
        assertEq(splitter.operatorOwed(pool, currency1), 0, "nothing left for the operator");
        vm.prank(STRANGER);
        splitter.paySazare(currency1);
        assertEq(_balance(currency1, SAZARE), owed - operatorAmount, "Sazare's share");
        assertEq(_balance(currency1, address(splitter)), 0, "nothing left here");
    }

    /// @dev R3-7: removal waits until the treasury's share is paid out. Anyone may collect it, so a book is removed
    /// without the operator or Sazare acting.
    function test_anyoneCollectsSoRemovalNeverWaits() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 100, 1e11);
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        vm.startPrank(MAKER);
        book.cancelFixed(pool, ask, MAKER);
        book.claimFixed(pool, ask, MAKER);
        vm.stopPrank();
        book.sweep(pool);
        vm.prank(STRANGER);
        splitter.collect(book, pool);
        _donateReleased();
        hook.deactivateExtension(key, IHookExtension(address(book)));
        hook.removeExtension(key, IHookExtension(address(book)));
        assertFalse(hook.isInstalled(pool, address(book)), "removed without the operator or Sazare acting");
    }

    function test_nativeShareIsPaidInEth() public {
        key = PoolKey(Currency.wrap(address(0)), currency1, 3000, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        vm.deal(address(this), 100 ether);
        lpRouter.modifyLiquidity{value: 10 ether}(key, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
        _install(_policy());
        _placeFixed(false, -100, 1e11);
        swapRouter.swap{value: 5e17}(
            key, SwapParams(true, -5e17, MIN_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        Currency native = Currency.wrap(address(0));
        uint256 owed = book.ledger(pool).treasury[0];
        assertGt(owed, 0, "the book owes the treasury");
        splitter.collect(book, pool);
        uint256 operatorAmount = splitter.operatorOwed(pool, native);
        splitter.claim(pool, native, operatorAmount, OPERATOR);
        splitter.paySazare(native);
        assertEq(OPERATOR.balance, operatorAmount, "the operator's share in ETH");
        assertEq(SAZARE.balance, owed - operatorAmount, "Sazare's share in ETH");
        _checkBacking();
    }

    /// @dev The book is an argument anyone passes: only what arrives is credited.
    function test_untrustedBookIsCreditedOnlyWhatArrives() public {
        LyingBook liar = new LyingBook();
        splitter.collect(OrderBook(payable(address(liar))), pool);
        assertEq(splitter.operatorOwed(pool, currency0), 0, "nothing credited to the operator");
        assertEq(splitter.operatorOwed(pool, currency1), 0, "nothing credited to the operator");
        assertEq(splitter.sazareOwed(currency1), 0, "nothing credited to Sazare");
    }

    /// @dev The vault redeems at most 2^127 - 1 at once: a larger share is collected in parts, never all at once.
    function test_collectsALargeShareInParts() public {
        HugeBook huge = new HugeBook();
        splitter.collect(OrderBook(payable(address(huge))), pool);
        assertEq(huge.requested(), uint256(uint128(type(int128).max)), "one redemption's worth");
    }

    /// @dev Sol's coverage note: a share above one redemption drains completely over repeated collects, and each part
    /// is split.
    function test_collectsALargeShareCompletelyOverSeveralCalls() public {
        uint256 maximum = uint256(uint128(type(int128).max));
        uint256 share = 2 * maximum + 3;
        LargeShareBook large = new LargeShareBook(MockERC20(Currency.unwrap(currency1)), share);
        OrderBook book = OrderBook(payable(address(large)));
        splitter.collect(book, pool);
        assertEq(large.owed(), share - maximum, "the first call takes one redemption's worth");
        splitter.collect(book, pool);
        splitter.collect(book, pool);
        assertEq(large.owed(), 0, "three calls take it all");
        uint256 credited = splitter.operatorOwed(pool, currency1) + splitter.sazareOwed(currency1);
        assertEq(credited, share, "all of it credited");
        assertEq(_balance(currency1, address(splitter)), share, "all of it held");
    }

    /// @dev A fill of the default ask pays the treasury its half of the maker fee, in currency1.
    function _earnTreasuryShare() private returns (uint256 owed) {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        _placeFixed(true, 100, 1e11);
        _swap(SwapParams(false, -3e16, MAX_LIMIT));
        owed = book.ledger(pool).treasury[1];
        assertGt(owed, 0, "the book owes the treasury");
    }

    function _balance(Currency currency, address account) private view returns (uint256) {
        return MockERC20(Currency.unwrap(currency)).balanceOf(account);
    }
}
