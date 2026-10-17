// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Plan, Planner} from "v4-periphery/test/shared/Planner.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {OrderBookFixture} from "./utils/OrderBookFixture.sol";

/// @dev Permit2V4Router (./utils/Permit2V4Router.sol), deployed from its artifact because V4Router pins solc 0.8.26.
interface IPermit2V4Router {
    function executeActions(bytes calldata params) external payable;
}

/// @dev A contract that composes its own v4 calls: it unlocks the PoolManager itself and hands actions to
/// PositionManager.modifyLiquiditiesWithoutUnlock, first leaving an ERC20 sync open (never settled) when asked to.
contract PendingSyncComposer is IUnlockCallback {
    IPoolManager internal immutable MANAGER;
    IPositionManager internal immutable POSITIONS;

    constructor(IPoolManager manager, IPositionManager positions) {
        MANAGER = manager;
        POSITIONS = positions;
    }

    /// @param pending The ERC20 to leave synced, or the zero address for no sync.
    function run(Currency pending, bytes calldata actions, bytes[] calldata params) external {
        MANAGER.unlock(abi.encode(pending, actions, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), "only the PoolManager");
        (Currency pending, bytes memory actions, bytes[] memory params) = abi.decode(data, (Currency, bytes, bytes[]));
        if (!pending.isAddressZero()) MANAGER.sync(pending);
        POSITIONS.modifyLiquiditiesWithoutUnlock(actions, params);
        return "";
    }
}

/// @dev Router paths into the order book's Kernel pools that OrderBookRouter.t.sol does not reach: a V4Router paying
/// through Permit2 (this replicates UniversalRouter's Permit2 payment logic in a minimal router; it does not use
/// UniversalRouter itself), and PositionManager's CLEAR_OR_TAKE, WRAP and UNWRAP actions and
/// modifyLiquiditiesWithoutUnlock.
contract OrderBookRouterCoverageTest is OrderBookFixture {
    using StateLibrary for IPoolManager;

    IAllowanceTransfer internal permit2;
    IPermit2V4Router internal router;
    IPositionManager internal positionManager;

    function setUp() public override {
        super.setUp();
        permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        router = IPermit2V4Router(deployCode("Permit2V4Router.sol:Permit2V4Router", abi.encode(manager, permit2)));
        positionManager = IPositionManager(
            deployCode(
                "PositionManager.sol:PositionManager",
                abi.encode(manager, permit2, uint256(100_000), address(0), address(weth))
            )
        );
        _approveThroughPermit2(currency0, address(positionManager), type(uint160).max);
        _approveThroughPermit2(currency1, address(positionManager), type(uint160).max);
    }

    // ---------------------------------------------------------------- V4Router paying through Permit2

    /// @dev Exact input through a router that pays as UniversalRouter does: the book fills, and the input comes out of
    /// the Permit2 allowance. The router has no ERC20 allowance, so a payment by plain transferFrom could not succeed.
    function test_permit2ExactInputFillsTheBook() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 ask = _placeFixed(true, 20, 1e11);
        _approveThroughPermit2(currency1, address(router), 1e18);
        assertEq(_erc20Allowance(currency1, address(router)), 0, "no ERC20 allowance to the router");
        uint256 before1 = currency1.balanceOfSelf();
        uint256 before0 = currency0.balanceOfSelf();
        router.executeActions(_exactIn(false, 1e17));
        assertEq(before1 - currency1.balanceOfSelf(), 1e17, "paid the exact input");
        assertEq(_permit2Allowance(currency1, address(router)), 1e18 - 1e17, "paid through Permit2");
        assertGt(currency0.balanceOfSelf(), before0, "received the output");
        assertGt(_filled(ask), 0, "the book filled");
        _checkBacking();
    }

    /// @dev Exact output through the same router: the book fills, and the input the book and AMM priced comes out of
    /// the Permit2 allowance.
    function test_permit2ExactOutputFillsTheBook() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 bid = _placeFixed(false, -20, 1e11);
        _approveThroughPermit2(currency0, address(router), 1e18);
        assertEq(_erc20Allowance(currency0, address(router)), 0, "no ERC20 allowance to the router");
        uint256 before0 = currency0.balanceOfSelf();
        uint256 before1 = currency1.balanceOfSelf();
        router.executeActions(_exactOut(true, 5e16));
        uint256 paid = before0 - currency0.balanceOfSelf();
        assertGt(paid, 0, "paid an input");
        assertEq(_permit2Allowance(currency0, address(router)), 1e18 - paid, "paid through Permit2");
        assertEq(currency1.balanceOfSelf() - before1, 5e16, "received exactly the output");
        assertGt(_filled(bid), 0, "the book filled");
        _checkBacking();
    }

    // ---------------------------------------------------------------- PositionManager

    /// @dev CLEAR_OR_TAKE after a decrease in a book pool: a credit at its threshold is forfeited (cleared, left in
    /// the PoolManager), a credit one above its threshold is taken. A dry run of the same decrease measures the
    /// credits, so both thresholds sit on the boundary.
    function test_positionManagerClearOrTakeAfterDecrease() public {
        uint256 tokenId = _bookPoolPosition(address(this));
        uint256 before0 = currency0.balanceOfSelf();
        uint256 before1 = currency1.balanceOfSelf();
        uint256 snap = vm.snapshotState();
        positionManager.modifyLiquidities(
            _decreasePlan(tokenId, 1e17).finalizeModifyLiquidityWithTakePair(key, address(this)), block.timestamp
        );
        uint256 credit0 = currency0.balanceOfSelf() - before0;
        uint256 credit1 = currency1.balanceOfSelf() - before1;
        assertGt(credit0, 0);
        assertGt(credit1, 0);
        vm.revertToState(snap);
        uint256 held0 = currency0.balanceOf(address(manager));
        uint256 held1 = currency1.balanceOf(address(manager));
        Plan memory plan = _decreasePlan(tokenId, 1e17);
        plan = plan.add(Actions.CLEAR_OR_TAKE, abi.encode(currency0, credit0));
        plan = plan.add(Actions.CLEAR_OR_TAKE, abi.encode(currency1, credit1 - 1));
        positionManager.modifyLiquidities(plan.encode(), block.timestamp);
        assertEq(manager.getLiquidity(pool), 1e18 - 1e17, "decreased");
        assertEq(currency0.balanceOfSelf(), before0, "at the threshold: not taken");
        assertEq(currency0.balanceOf(address(manager)), held0, "at the threshold: cleared into the PoolManager");
        assertEq(currency1.balanceOfSelf() - before1, credit1, "over the threshold: taken");
        assertEq(held1 - currency1.balanceOf(address(manager)), credit1, "over the threshold: left the PoolManager");
        _checkBacking();
    }

    /// @dev A pool of WETH and a token, with the book: an LP mints paying the WETH side in native ETH (WRAP), a swap
    /// paying WETH fills the book, and the LP decreases and receives the WETH side as native ETH (UNWRAP).
    function test_positionManagerWrapsAndUnwrapsNative() public {
        Currency wrapped = Currency.wrap(address(weth));
        bool wethIsZero = address(weth) < Currency.unwrap(currency1);
        key = wethIsZero
            ? PoolKey(wrapped, currency1, 3000, 20, IHooks(address(hook)))
            : PoolKey(currency1, wrapped, 3000, 20, IHooks(address(hook)));
        pool = key.toId();
        hook.preparePool(key);
        manager.initialize(key, PRICE_1);
        _install(_policy());
        // The order sells the token, so a swap that pays WETH meets it.
        uint256 order = _placeFixed(!wethIsZero, wethIsZero ? int24(-20) : int24(20), 1e11);

        uint256 tokenId = _mintPayingNative(wrapped);

        weth.deposit{value: 1e17}();
        weth.approve(address(swapRouter), type(uint256).max);
        _swap(SwapParams(wethIsZero, -1e17, wethIsZero ? MIN_LIMIT : MAX_LIMIT));
        assertGt(_filled(order), 0, "the book filled");

        _decreaseToNative(tokenId, wrapped);
        _checkBacking();
    }

    /// @dev Mints in the WETH pool, paying the WETH side in native ETH through WRAP.
    function _mintPayingNative(Currency wrapped) private returns (uint256 tokenId) {
        vm.deal(address(this), 10 ether);
        uint256 held = weth.balanceOf(address(manager));
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.MINT_POSITION,
            abi.encode(
                key, int24(-6000), int24(6000), uint256(1e18), type(uint128).max, type(uint128).max, address(this), ""
            )
        );
        // OPEN_DELTA wraps exactly the WETH the mint owes; PositionManager then pays it from its own balance.
        plan = plan.add(Actions.WRAP, abi.encode(ActionConstants.OPEN_DELTA));
        plan = plan.add(Actions.SETTLE, abi.encode(wrapped, ActionConstants.OPEN_DELTA, false));
        plan = plan.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.OPEN_DELTA, true));
        plan = plan.add(Actions.SWEEP, abi.encode(Currency.wrap(address(0)), ActionConstants.MSG_SENDER));
        positionManager.modifyLiquidities{value: 10 ether}(plan.encode(), block.timestamp);
        tokenId = positionManager.nextTokenId() - 1;
        uint256 paid = 10 ether - address(this).balance;
        assertGt(paid, 0, "paid in native ETH");
        assertEq(weth.balanceOf(address(manager)) - held, paid, "the native ETH paid arrived as WETH");
        assertEq(
            address(positionManager).balance + weth.balanceOf(address(positionManager)),
            0,
            "the unused ETH was swept back"
        );
        assertEq(manager.getLiquidity(pool), 1e18, "minted");
    }

    /// @dev Decreases the whole position, taking the WETH side as native ETH through UNWRAP.
    function _decreaseToNative(uint256 tokenId, Currency wrapped) private {
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = currency1.balanceOfSelf();
        uint256 held = weth.balanceOf(address(manager));
        Plan memory plan = _decreasePlan(tokenId, 1e18);
        plan = plan.add(Actions.TAKE, abi.encode(wrapped, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        plan = plan.add(Actions.UNWRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        plan = plan.add(Actions.SWEEP, abi.encode(Currency.wrap(address(0)), ActionConstants.MSG_SENDER));
        plan = plan.add(Actions.TAKE, abi.encode(currency1, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        positionManager.modifyLiquidities(plan.encode(), block.timestamp);
        uint256 received = address(this).balance - ethBefore;
        assertGt(received, 0, "received native ETH");
        assertEq(held - weth.balanceOf(address(manager)), received, "the WETH side left the pool as native ETH");
        assertEq(weth.balanceOf(address(positionManager)), 0, "nothing left in PositionManager");
        assertGt(currency1.balanceOfSelf(), tokenBefore, "received the token side");
        assertEq(manager.getLiquidity(pool), 0, "decreased");
    }

    /// @dev IKernelHook: "Operations revert with SyncPending while the PoolManager has an ERC20 sync pending". A
    /// contract that unlocks the PoolManager, syncs an ERC20 without settling, then decreases liquidity in a book pool
    /// through modifyLiquiditiesWithoutUnlock gets SyncPending from beforeRemoveLiquidity, wrapped by the PoolManager.
    /// The contrast: the same actions with no sync pending decrease the position.
    function test_withoutUnlockRevertsWhileASyncIsPending() public {
        PendingSyncComposer composer = new PendingSyncComposer(manager, positionManager);
        // The composer is the actions' sender, so it owns the position; the mint paid from this contract.
        uint256 tokenId = _bookPoolPosition(address(composer));
        Plan memory plan = _decreasePlan(tokenId, 1e17);
        plan = plan.add(Actions.TAKE_PAIR, abi.encode(currency0, currency1, address(composer)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeRemoveLiquidity.selector,
                abi.encodeWithSelector(IKernelHook.SyncPending.selector),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        composer.run(currency0, plan.actions, plan.params);

        composer.run(Currency.wrap(address(0)), plan.actions, plan.params);
        assertEq(manager.getLiquidity(pool), 1e18 - 1e17, "decreased");
        assertGt(currency0.balanceOf(address(composer)), 0, "took currency0");
        assertGt(currency1.balanceOf(address(composer)), 0, "took currency1");
        _checkBacking();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Installs the book with an ask, mints a PositionManager position for `owner` (paid by this contract through
    /// Permit2), and fills the ask with a swap.
    function _bookPoolPosition(address owner) private returns (uint256 tokenId) {
        _install(_policy());
        uint256 ask = _placeFixed(true, 20, 1e11);
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.MINT_POSITION,
            abi.encode(key, int24(-6000), int24(6000), uint256(1e18), type(uint128).max, type(uint128).max, owner, "")
        );
        positionManager.modifyLiquidities(plan.finalizeModifyLiquidityWithSettlePair(key), block.timestamp);
        tokenId = positionManager.nextTokenId() - 1;
        _swap(SwapParams(false, -1e17, MAX_LIMIT));
        assertGt(_filled(ask), 0, "the book filled");
    }

    /// @dev A fresh plan each time: Planner's finalize helpers append to the plan they are given.
    function _decreasePlan(uint256 tokenId, uint256 liquidity) private pure returns (Plan memory plan) {
        plan = Planner.init();
        plan = plan.add(Actions.DECREASE_LIQUIDITY, abi.encode(tokenId, liquidity, uint128(0), uint128(0), ""));
    }

    function _exactIn(bool zeroForOne, uint128 amountIn) private view returns (bytes memory) {
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.SWAP_EXACT_IN_SINGLE,
            abi.encode(IV4Router.ExactInputSingleParams(key, zeroForOne, amountIn, 0, 0, ""))
        );
        return zeroForOne
            ? plan.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER)
            : plan.finalizeSwap(key.currency1, key.currency0, ActionConstants.MSG_SENDER);
    }

    function _exactOut(bool zeroForOne, uint128 amountOut) private view returns (bytes memory) {
        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.SWAP_EXACT_OUT_SINGLE,
            abi.encode(IV4Router.ExactOutputSingleParams(key, zeroForOne, amountOut, type(uint128).max, 0, ""))
        );
        return zeroForOne
            ? plan.finalizeSwap(key.currency0, key.currency1, ActionConstants.MSG_SENDER)
            : plan.finalizeSwap(key.currency1, key.currency0, ActionConstants.MSG_SENDER);
    }

    function _approveThroughPermit2(Currency currency, address spender, uint160 amount) private {
        address token = Currency.unwrap(currency);
        MockERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, spender, amount, type(uint48).max);
    }

    function _permit2Allowance(Currency currency, address spender) private view returns (uint160 amount) {
        (amount,,) = permit2.allowance(address(this), Currency.unwrap(currency), spender);
    }

    function _erc20Allowance(Currency currency, address spender) private view returns (uint256) {
        return MockERC20(Currency.unwrap(currency)).allowance(address(this), spender);
    }

    function _filled(uint256 id) private view returns (uint64 filled) {
        (, filled) = book.fixedOrder(pool, id);
    }
}
