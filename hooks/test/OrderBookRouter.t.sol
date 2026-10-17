// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Plan, Planner} from "v4-periphery/test/shared/Planner.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {PathKey} from "v4-periphery/src/libraries/PathKey.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {OrderBook} from "../src/orderbook/OrderBook.sol";
import {OrderBookFixture} from "./utils/OrderBookFixture.sol";

/// @dev The periphery's MockV4Router (V4Router pins solc 0.8.26, so it is deployed from its artifact).
interface IMockV4Router {
    function executeActions(bytes calldata params) external payable;
    function executeActionsAndSweepExcessETH(bytes calldata params) external payable;
}

/// @dev The order book in Kernel pools, driven through Uniswap's own periphery (lib/v4-periphery): V4Router, through the
/// periphery's MockV4Router (which pays with transferFrom where UniversalRouter pays through Permit2), and
/// PositionManager. Both pay with DeltaResolver._settle, which syncs, pays and settles in one step, so no sync is pending
/// when a Kernel operation begins.
contract OrderBookRouterTest is OrderBookFixture {
    using StateLibrary for IPoolManager;

    IMockV4Router internal router;

    function setUp() public override {
        super.setUp();
        router = IMockV4Router(deployCode("MockV4Router.sol:MockV4Router", abi.encode(manager)));
        _approveRouter(currency0);
        _approveRouter(currency1);
    }

    // ---------------------------------------------------------------- V4Router

    /// @dev Exact input: the book fills, and the router's slippage check sees the price the book gave.
    function test_exactInputFillsTheBook() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 20, 1e11);
        uint256 snapshot = vm.snapshotState();
        uint256 before = currency0.balanceOfSelf();
        router.executeActions(_exactIn(false, 1e17, 0));
        uint256 received = currency0.balanceOfSelf() - before;
        assertGt(_filled(ask), 0, "the book filled");
        _checkBacking();
        vm.revertToState(snapshot);
        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector, received + 1, received));
        router.executeActions(_exactIn(false, 1e17, uint128(received + 1)));
        router.executeActions(_exactIn(false, 1e17, uint128(received)));
    }

    /// @dev Exact output: the book fills, and the router's input cap sees the price the book gave.
    function test_exactOutputFillsTheBook() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 bid = _placeFixed(false, -20, 1e11);
        uint256 snapshot = vm.snapshotState();
        uint256 before = currency0.balanceOfSelf();
        router.executeActions(_exactOut(true, 5e16, type(uint128).max));
        uint256 paid = before - currency0.balanceOfSelf();
        assertGt(_filled(bid), 0, "the book filled");
        _checkBacking();
        vm.revertToState(snapshot);
        vm.expectRevert(abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector, paid - 1, paid));
        router.executeActions(_exactOut(true, 5e16, uint128(paid - 1)));
        router.executeActions(_exactOut(true, 5e16, uint128(paid)));
    }

    /// @dev Paying first: SETTLE, then a swap of the open credit. The router's settle closes its sync, so the Kernel's
    /// SyncPending rule does not fire.
    function test_payFirstThenSwap() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 20, 1e11);
        Plan memory plan = Planner.init();
        plan = plan.add(Actions.SETTLE, abi.encode(currency1, uint256(1e17), true));
        plan = plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(IV4Router.ExactInputSingleParams(key, false, ActionConstants.OPEN_DELTA, 0, 0, ""))
        );
        plan = plan.add(Actions.TAKE_ALL, abi.encode(currency0, uint256(0)));
        router.executeActions(plan.encode());
        assertGt(_filled(ask), 0, "the book filled");
        _checkBacking();
    }

    /// @dev The book's per-pool callback flag clears on every exit, including the early return when it fills
    /// nothing: in one unlock, a sale into the empty bid side, then a buy that fills the ask. The two net to a debt in
    /// currency1 and a credit in currency0.
    function test_flagClearsAfterAnEarlyReturnInTheSameUnlock() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 20, 1e11);
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.SWAP_EXACT_IN_SINGLE, abi.encode(IV4Router.ExactInputSingleParams(key, true, 1e12, 0, 0, ""))
        );
        plan = plan.add(
            Actions.SWAP_EXACT_IN_SINGLE, abi.encode(IV4Router.ExactInputSingleParams(key, false, 1e17, 0, 0, ""))
        );
        plan = plan.add(Actions.SETTLE_ALL, abi.encode(currency1, type(uint256).max));
        plan = plan.add(Actions.TAKE_ALL, abi.encode(currency0, uint256(0)));
        vm.recordLogs();
        router.executeActions(plan.encode());
        assertFalse(_skippedIn(vm.getRecordedLogs()), "the book ran in both swaps");
        assertGt(_filled(ask), 0, "the second swap filled the ask");
        _checkBacking();
    }

    /// @dev SETTLE from the router's own balance (CONTRACT_BALANCE, payer not the user), then a swap of the open delta.
    function test_settleFromTheRoutersBalanceThenSwap() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 20, 1e11);
        MockERC20(Currency.unwrap(currency1)).transfer(address(router), 1e17);
        Plan memory plan = Planner.init();
        plan = plan.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.CONTRACT_BALANCE, false));
        plan = plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(IV4Router.ExactInputSingleParams(key, false, ActionConstants.OPEN_DELTA, 0, 0, ""))
        );
        plan = plan.add(Actions.TAKE_ALL, abi.encode(currency0, uint256(0)));
        router.executeActions(plan.encode());
        assertGt(_filled(ask), 0, "the book filled");
        _checkBacking();
    }

    /// @dev A two-hop exact input through two Kernel pools, each with a book: two root operations in one unlock.
    function test_multiHopExactInputThroughTwoBooks() public {
        (PoolKey memory first, MockERC20 third, uint256 orderA, uint256 orderB) = _twoBooks();
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(currency1, first.fee, first.tickSpacing, first.hooks, "");
        path[1] = PathKey(Currency.wrap(address(third)), key.fee, key.tickSpacing, key.hooks, "");
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.SWAP_EXACT_IN, abi.encode(IV4Router.ExactInputParams(currency0, path, new uint256[](0), 5e16, 0))
        );
        uint256 before = third.balanceOf(address(this));
        router.executeActions(plan.finalizeSwap(currency0, Currency.wrap(address(third)), ActionConstants.MSG_SENDER));
        assertGt(third.balanceOf(address(this)), before, "received the last currency");
        _checkBothBooks(first, orderA, orderB);
    }

    /// @dev The same route as an exact output, which the router runs from the last hop backwards.
    function test_multiHopExactOutputThroughTwoBooks() public {
        (PoolKey memory first, MockERC20 third, uint256 orderA, uint256 orderB) = _twoBooks();
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey(currency0, first.fee, first.tickSpacing, first.hooks, "");
        path[1] = PathKey(currency1, key.fee, key.tickSpacing, key.hooks, "");
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.SWAP_EXACT_OUT,
            abi.encode(
                IV4Router.ExactOutputParams(
                    Currency.wrap(address(third)), path, new uint256[](0), 5e16, type(uint128).max
                )
            )
        );
        uint256 before = third.balanceOf(address(this));
        router.executeActions(plan.finalizeSwap(currency0, Currency.wrap(address(third)), ActionConstants.MSG_SENDER));
        assertEq(third.balanceOf(address(this)) - before, 5e16, "received exactly the output");
        _checkBothBooks(first, orderA, orderB);
    }

    /// @dev Native currency in: the router settles ETH with msg.value, and the book fills.
    function test_nativeInputFillsTheBook() public {
        key = PoolKey(Currency.wrap(address(0)), currency1, 3000, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        vm.deal(address(this), 100 ether);
        lpRouter.modifyLiquidity{value: 10 ether}(key, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
        _install(_policy());
        uint256 bid = _placeFixed(false, -20, 1e11);
        uint256 before = address(this).balance;
        router.executeActionsAndSweepExcessETH{value: 1 ether}(_exactIn(true, 5e16, 0));
        assertEq(before - address(this).balance, 5e16, "paid the input in ETH, the rest swept back");
        assertGt(_filled(bid), 0, "the book filled");
        _checkBacking();
    }

    /// @dev A pool with no AMM liquidity: V4Router's single swaps use the extreme price limit, so the input beyond the
    /// book runs the price there; the book moves it back to its last trade.
    function test_emptyPoolPriceComesBackFromTheRoutersLimit() public {
        _install(_policy());
        uint256 ask = _placeFixed(true, 200, 1e6);
        vm.recordLogs();
        router.executeActions(_exactIn(false, 1e15, 0));
        assertTrue(_emitted(OrderBook.PriceMoved.selector), "the book moved the price");
        assertEq(_filled(ask), 1e6, "the book sold out");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, TickMath.getSqrtPriceAtTick(200), "back at the last trade");
        _checkBacking();
    }

    /// @dev Two swaps of the same pool with no AMM liquidity in one unlock: each runs to the router's limit and is
    /// moved back to its own last trade; the first swap's record does not leak into the second.
    function test_emptyPoolTwoSwapsInOneUnlock() public {
        _install(_policy());
        uint256 low = _placeFixed(true, 200, 1e6);
        uint256 high = _placeFixed(true, 300, 1e6);
        IV4Router.ExactInputSingleParams memory buy = IV4Router.ExactInputSingleParams(key, false, 1e12, 0, 0, "");
        Plan memory plan = Planner.init();
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(buy));
        buy.amountIn = 1e15;
        plan = plan.add(Actions.SWAP_EXACT_IN_SINGLE, abi.encode(buy));
        router.executeActions(plan.finalizeSwap(currency1, currency0, ActionConstants.MSG_SENDER));
        assertEq(_filled(low), 1e6);
        assertEq(_filled(high), 1e6);
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, TickMath.getSqrtPriceAtTick(300), "at the second swap's last trade");
        _checkBacking();
    }

    /// @dev At any gas limit, a router swap through the book either reverts or runs the book in both callbacks: too
    /// little gas never skips it. (The pool has AMM liquidity, so the book makes no nested price move.) Logs the smallest
    /// gas limit that succeeds and the gas the swap uses.
    function test_gasLimitEitherFillsTheBookOrReverts() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 20, 1e11);
        bytes memory call = abi.encodeCall(IMockV4Router.executeActions, (_exactIn(false, 1e17, 0)));
        uint256 least = type(uint256).max;
        for (uint256 limit = 250_000; limit <= 10_000_000; limit += 250_000) {
            if (_tryWithGas(call, limit, ask)) least = limit < least ? limit : least;
        }
        assertLt(least, type(uint256).max, "some limit succeeds");
        // Finer, around the smallest limit that succeeded.
        for (uint256 limit = least - 250_000; limit < least + 250_000; limit += 2500) {
            if (_tryWithGas(call, limit, ask)) least = limit < least ? limit : least;
        }
        emit log_named_uint("smallest gas limit that succeeds", least);
        uint256 start = gasleft();
        router.executeActions(_exactIn(false, 1e17, 0));
        emit log_named_uint("gas used by the swap", start - gasleft());
    }

    // ---------------------------------------------------------------- PositionManager

    /// @dev An LP mints through PositionManager (Permit2 pays), a swap fills the book and the AMM, and the LP decreases
    /// and takes its tokens back.
    function test_positionManagerMintsAndDecreases() public {
        IAllowanceTransfer permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        IPositionManager posm = IPositionManager(
            deployCode(
                "PositionManager.sol:PositionManager",
                abi.encode(manager, permit2, uint256(100_000), address(0), address(weth))
            )
        );
        for (uint256 c; c < 2; ++c) {
            address token = Currency.unwrap(c == 0 ? currency0 : currency1);
            MockERC20(token).approve(address(permit2), type(uint256).max);
            permit2.approve(token, address(posm), type(uint160).max, type(uint48).max);
        }
        _install(_policy());
        uint256 ask = _placeFixed(true, 20, 1e11);
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                key, int24(-6000), int24(6000), uint256(1e18), type(uint128).max, type(uint128).max, address(this), ""
            )
        );
        posm.modifyLiquidities(plan.finalizeModifyLiquidityWithSettlePair(key), block.timestamp);
        uint256 tokenId = posm.nextTokenId() - 1;
        assertEq(manager.getLiquidity(pool), 1e18, "minted");
        router.executeActions(_exactIn(false, 1e17, 0));
        assertGt(_filled(ask), 0, "the book filled");
        vm.recordLogs();
        _donateReleased();
        assertTrue(_emitted(OrderBook.LpFeesDonated.selector), "the book's LP share went to the position");
        plan = Planner.init();
        plan = plan.add(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(1e18), uint128(0), uint128(0), ""));
        uint256 before0 = currency0.balanceOfSelf();
        uint256 before1 = currency1.balanceOfSelf();
        posm.modifyLiquidities(plan.finalizeModifyLiquidityWithTakePair(key, address(this)), block.timestamp);
        assertEq(manager.getLiquidity(pool), 0, "decreased");
        assertGt(currency0.balanceOfSelf(), before0);
        assertGt(currency1.balanceOfSelf(), before1);
        _checkBacking();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The fixture's pool with a bid, and a second Kernel pool (currency1 and a third token) whose book the second
    /// hop of currency0 -> currency1 -> third meets. Leaves `key` at the second pool.
    function _twoBooks() private returns (PoolKey memory first, MockERC20 third, uint256 orderA, uint256 orderB) {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        orderA = _placeFixed(false, -20, 1e11);
        first = key;
        third = new MockERC20("C", "C", 18);
        _fund(third);
        _approveRouter(Currency.wrap(address(third)));
        bool firstIsZero = Currency.unwrap(currency1) < address(third);
        key = firstIsZero
            ? PoolKey(currency1, Currency.wrap(address(third)), 500, 20, IHooks(address(hook)))
            : PoolKey(Currency.wrap(address(third)), currency1, 500, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        // The second hop sells currency1: it meets bids if currency1 is the pool's currency0, asks otherwise.
        orderB = _placeFixed(!firstIsZero, firstIsZero ? int24(-20) : int24(20), 1e11);
    }

    function _checkBothBooks(PoolKey memory first, uint256 orderA, uint256 orderB) private {
        assertGt(_filled(orderB), 0, "the second book filled");
        _checkBacking();
        (key, pool) = (first, first.toId());
        assertGt(_filled(orderA), 0, "the first book filled");
        _checkBacking();
    }

    function _exactIn(bool zeroForOne, uint128 amountIn, uint128 minOut) private view returns (bytes memory) {
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(IV4Router.ExactInputSingleParams(key, zeroForOne, amountIn, minOut, 0, ""))
        );
        return zeroForOne
            ? plan.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER)
            : plan.finalizeSwap(key.currency1, key.currency0, ActionConstants.MSG_SENDER);
    }

    function _exactOut(bool zeroForOne, uint128 amountOut, uint128 maxIn) private view returns (bytes memory) {
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(IV4Router.ExactOutputSingleParams(key, zeroForOne, amountOut, maxIn, 0, ""))
        );
        return zeroForOne
            ? plan.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER)
            : plan.finalizeSwap(key.currency1, key.currency0, ActionConstants.MSG_SENDER);
    }

    /// @dev Calls the router with a gas limit; if it succeeds, the book must have filled and not been skipped in either
    /// callback. The state is restored.
    function _tryWithGas(bytes memory call, uint256 limit, uint256 order) private returns (bool ok) {
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        (ok,) = address(router).call{gas: limit}(call);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok) {
            assertGt(_filled(order), 0, "succeeded without the book");
            assertFalse(_skippedIn(logs), "succeeded with the book skipped");
        }
        vm.revertToState(snapshot);
    }

    function _filled(uint256 id) private view returns (uint64 filled) {
        (, filled) = book.fixedOrder(pool, id);
    }

    function _approveRouter(Currency currency) private {
        MockERC20(Currency.unwrap(currency)).approve(address(router), type(uint256).max);
    }
}
