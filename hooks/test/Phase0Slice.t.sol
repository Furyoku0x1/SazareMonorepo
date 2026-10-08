// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {AmmReplay} from "../src/libraries/AmmReplay.sol";
import {SliceWalk} from "../src/libraries/SliceWalk.sol";

/// @dev Phase 0 thin slice: a plain v4 hook (no Kernel) holding one book side per direction. beforeSwap sizes
/// the book's share with SliceWalk; afterSwap requires the pool to land where AmmReplay predicted, pays the
/// book's output and takes its input as ERC-6909 claims. Escrow accounting is out of scope.
contract SliceHook is IHooks {
    using StateLibrary for IPoolManager;

    uint256 public constant REPLAY_CAP = 4096;
    IPoolManager public immutable MANAGER;
    SliceWalk.Book public asks; // filled by oneForZero swaps
    SliceWalk.Book public bids; // filled by zeroForOne swaps
    uint256 public maxSteps = 512;
    uint256 public minGas;
    uint160 public lastSync; // where afterSwap moved an empty pool's price, or 0
    int24 public lastSyncTick;
    uint256 public walkGas; // gas of the last SliceWalk.allocate
    uint256 public replayGas; // gas of the last expected-landing replay (test check only)
    SliceWalk.Fill internal _fill;
    AmmReplay.Result internal _expected;

    /// @dev What a swap would do, computed by the same code without writes.
    struct Quote {
        uint256 bookSpecified;
        uint256 bookOther;
        uint256 ammSpecified;
        uint256 ammOther;
        uint160 landing; // where the AMM part ends
        uint160 finalPrice; // after an empty pool's price move
        uint8 stop;
        bool complete;
    }

    constructor(IPoolManager manager) {
        MANAGER = manager;
    }

    function setMaxSteps(uint256 value) external {
        maxSteps = value;
    }

    function setMinGas(uint256 value) external {
        minGas = value;
    }

    /// @dev Post-only: a side is placed at or beyond the pool price. It can fall behind later (early stops).
    function setBook(
        PoolKey calldata key,
        bool ask,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        int24 fixedTick,
        uint128 fixedAmount
    ) external {
        (uint160 price,,, uint24 lpFee) = MANAGER.getSlot0(key.toId());
        uint160 low = TickMath.getSqrtPriceAtTick(lower);
        uint160 high = TickMath.getSqrtPriceAtTick(upper);
        uint160 fixedPrice = TickMath.getSqrtPriceAtTick(fixedTick);
        // Admission bound: a whole fixed level must be payable within the hook's int128 deltas.
        require(fixedAmount < 1 << 126 && SliceWalk.fixedCost(!ask, fixedPrice, fixedAmount, lpFee) < 1 << 126, "too large");
        if (ask) {
            require(low >= price && fixedPrice >= price, "crosses");
            asks = SliceWalk.Book(low, high, liquidity, fixedPrice, fixedAmount);
        } else {
            require(high <= price && fixedPrice <= price, "crosses");
            bids = SliceWalk.Book(high, low, liquidity, fixedPrice, fixedAmount);
        }
    }

    function last() external view returns (SliceWalk.Fill memory, AmmReplay.Result memory) {
        return (_fill, _expected);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(MANAGER));
        if (params.amountSpecified == type(int256).min) {
            // Out of the book's domain; the PoolManager handles the swap alone.
            delete _fill;
            _expected.complete = false;
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        AmmReplay.Pool memory pool = _pool(key, params);
        bool exactIn = params.amountSpecified < 0;
        uint256 budget = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        SliceWalk.Book storage book = params.zeroForOne ? bids : asks;
        SliceWalk.Fill memory f = _walk(pool, exactIn, budget, book);
        _update(book, f, params.zeroForOne);
        _replay(pool, exactIn, budget - f.specified);
        _fill = f;
        int128 spec = SafeCast.toInt128(f.specified);
        int128 other = SafeCast.toInt128(f.other);
        BeforeSwapDelta delta = exactIn ? toBeforeSwapDelta(spec, -other) : toBeforeSwapDelta(-spec, other);
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    function quote(PoolKey calldata key, SwapParams calldata params) external view returns (Quote memory q) {
        if (params.amountSpecified == type(int256).min) return q;
        AmmReplay.Pool memory pool = _pool(key, params);
        bool exactIn = params.amountSpecified < 0;
        uint256 budget = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        SliceWalk.Fill memory f = SliceWalk.allocate(
            SliceWalk.Swap(pool, exactIn, budget, maxSteps, 0, 0), params.zeroForOne ? bids : asks
        );
        SafeCast.toInt128(f.specified);
        SafeCast.toInt128(f.other);
        uint256 rest = budget - f.specified;
        AmmReplay.Result memory e = AmmReplay.swap(pool, exactIn ? -int256(rest) : int256(rest), REPLAY_CAP);
        q = Quote(f.specified, f.other, e.specified, e.other, e.sqrtPriceX96, e.sqrtPriceX96, f.stop, e.complete);
        if (f.specified == 0 && f.other == 0) return q;
        (uint160 target,) = _syncTarget(key, AmmReplay.Cursor(e.sqrtPriceX96, e.tick, e.liquidity), f.frontier);
        if (target != 0) q.finalPrice = target;
    }

    /// @dev With no AMM liquidity between the pool price and the book's frontier, the pool price can move there
    /// with a swap that trades nothing, so it shows the last trade. Returns 0 when it cannot.
    function _syncTarget(PoolKey calldata key, AmmReplay.Cursor memory c, uint160 frontier)
        private
        view
        returns (uint160 target, int24 tick)
    {
        if (frontier == c.sqrtPriceX96) return (0, 0);
        // A swap limit must lie strictly inside the price bounds.
        if (frontier <= TickMath.MIN_SQRT_PRICE || frontier >= TickMath.MAX_SQRT_PRICE) return (0, 0);
        bool down = frontier < c.sqrtPriceX96;
        PoolId id = key.toId();
        (,,, uint24 lpFee) = MANAGER.getSlot0(id);
        AmmReplay.Pool memory pool = AmmReplay.Pool(
            MANAGER, id, key.tickSpacing, down, frontier, AmmReplay.swapFee(MANAGER, id, down, lpFee)
        );
        AmmReplay.Result memory r = AmmReplay.swapFrom(pool, c, -1, REPLAY_CAP);
        if (r.complete && r.specified == 0 && r.sqrtPriceX96 == frontier) return (frontier, r.tick);
    }

    function _pool(PoolKey calldata key, SwapParams calldata params) private view returns (AmmReplay.Pool memory) {
        PoolId id = key.toId();
        (,,, uint24 lpFee) = MANAGER.getSlot0(id);
        return AmmReplay.Pool(
            MANAGER,
            id,
            key.tickSpacing,
            params.zeroForOne,
            params.sqrtPriceLimitX96,
            AmmReplay.swapFee(MANAGER, id, params.zeroForOne, lpFee)
        );
    }

    function _walk(AmmReplay.Pool memory pool, bool exactIn, uint256 budget, SliceWalk.Book storage book)
        private
        returns (SliceWalk.Fill memory f)
    {
        uint256 gas = gasleft();
        f = SliceWalk.allocate(SliceWalk.Swap(pool, exactIn, budget, maxSteps, minGas, 0), book);
        walkGas = gas - gasleft();
    }

    /// @dev The expected landing, for the after-swap check only.
    function _replay(AmmReplay.Pool memory pool, bool exactIn, uint256 rest) private {
        uint256 gas = gasleft();
        _expected = AmmReplay.swap(pool, exactIn ? -int256(rest) : int256(rest), REPLAY_CAP);
        replayGas = gas - gasleft();
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        require(msg.sender == address(MANAGER));
        (uint160 price, int24 tick,,) = MANAGER.getSlot0(key.toId());
        if (_expected.complete) require(price == _expected.sqrtPriceX96 && tick == _expected.tick, "replay mismatch");
        bool exactIn = params.amountSpecified < 0;
        (Currency input, Currency output) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (uint256 bookIn, uint256 bookOut) = exactIn ? (_fill.specified, _fill.other) : (_fill.other, _fill.specified);
        if (bookOut != 0) {
            MANAGER.sync(output);
            MockERC20(Currency.unwrap(output)).transfer(address(MANAGER), bookOut);
            MANAGER.settle();
        }
        // Claims instead of a take: no PoolManager float is needed before the taker pays.
        if (bookIn != 0) MANAGER.mint(address(this), input.toId(), bookIn);
        _sync(key);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Moves an empty pool's price to the book's frontier; the PoolManager skips this hook's callbacks for
    /// its own swap.
    function _sync(PoolKey calldata key) private {
        lastSync = 0;
        if (_fill.specified == 0 && _fill.other == 0) return; // the book filled nothing
        PoolId id = key.toId();
        (uint160 price, int24 tick,,) = MANAGER.getSlot0(id);
        (uint160 target, int24 targetTick) =
            _syncTarget(key, AmmReplay.Cursor(price, tick, MANAGER.getLiquidity(id)), _fill.frontier);
        if (target == 0) return;
        BalanceDelta traded = MANAGER.swap(key, SwapParams(target < price, -1, target), "");
        require(BalanceDelta.unwrap(traded) == 0, "sync traded");
        (price, tick,,) = MANAGER.getSlot0(id);
        require(price == target && tick == targetTick, "sync mismatch");
        lastSync = target;
        lastSyncTick = targetTick;
    }

    function _update(SliceWalk.Book storage book, SliceWalk.Fill memory f, bool zeroForOne) private {
        book.fixedAmount -= f.fixedFilled;
        if (book.rangeLiquidity == 0) return;
        if (zeroForOne ? f.frontier >= book.rangeFrom : f.frontier <= book.rangeFrom) return;
        if (zeroForOne ? f.frontier <= book.rangeTo : f.frontier >= book.rangeTo) book.rangeLiquidity = 0;
        else book.rangeFrom = f.frontier;
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert("unused");
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert("unused");
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("unused");
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert("unused");
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert("unused");
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert("unused");
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("unused");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("unused");
    }
}


contract Phase0SliceTest is Test {
    using StateLibrary for IPoolManager;

    uint160 private constant PRICE_1 = 1 << 96;
    uint160 private constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    /// @dev Integer-optimum gap allowed in the brute force: each source and each book segment rounds once.
    uint256 private constant ROUNDING = 8;
    // beforeSwap, afterSwap and beforeSwapReturnDelta flags only.
    address private constant HOOK = address(uint160(0x4444) << 144 | 0xC8);

    IPoolManager private manager;
    PoolSwapTest private swapRouter;
    PoolModifyLiquidityTest private lpRouter;
    SliceHook private hook;
    MockERC20 private token0;
    MockERC20 private token1;
    PoolKey private key;
    PoolId private id;
    PoolKey private twin; // the same liquidity without the hook, for the brute force
    uint256[2] private claimed;

    function setUp() public {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        for (uint256 i; i < 2; ++i) {
            MockERC20 token = i == 0 ? token0 : token1;
            token.mint(address(this), 1e36);
            token.approve(address(swapRouter), type(uint256).max);
            token.approve(address(lpRouter), type(uint256).max);
            token.mint(HOOK, 1e36); // book escrow; Phase 0 does not account it
        }
        deployCodeTo("Phase0Slice.t.sol:SliceHook", abi.encode(manager), HOOK);
        hook = SliceHook(HOOK);
        _pool(3000);
    }

    // ---------------------------------------------------------------- fuzz

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_landsWhereTheWalkSized(uint256 seed) public {
        bool zeroForOne = seed & 1 == 1;
        bool exactIn = (seed >> 1) & 1 == 1;
        bool thin = _shape((seed >> 2) % 4);
        _books(thin ? 1000 : 1e18, thin ? 50 : 1e17);
        uint256 amount = 1 + (seed >> 8) % (10 ** (1 + (seed >> 200) % (thin ? 4 : 21)));
        _swapSeries(zeroForOne, exactIn ? -int256(amount) : int256(amount), _limit(zeroForOne));
    }

    /// @dev Varies the book layout, fee, protocol fee, step cap and price limit as well.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_configurations(uint256 seed) public {
        uint24[4] memory fees = [uint24(0), 500, 3000, 10_000];
        uint24 fee = fees[(seed >> 2) % 4];
        if (fee != key.fee) _pool(fee);
        if ((seed >> 4) & 1 == 1) {
            manager.setProtocolFeeController(address(this));
            manager.setProtocolFee(key, 500 | (300 << 12));
        }
        bool thin = _shape((seed >> 5) % 5);
        _layout((seed >> 8) % 6, thin ? 1000 : 1e18, thin ? 50 : 1e17);
        uint256[4] memory caps = [uint256(512), 512, 1, 0];
        hook.setMaxSteps(caps[(seed >> 11) % 4]);
        bool zeroForOne = seed & 1 == 1;
        uint160 limit = (seed >> 13) & 3 == 0 ? TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-400) : int24(400)) : _limit(zeroForOne);
        uint256 amount = 1 + (seed >> 16) % (10 ** (1 + (seed >> 200) % (thin ? 4 : 21)));
        int256 specified = (seed >> 1) & 1 == 1 ? -int256(amount) : int256(amount);
        _swapSeries(zeroForOne, specified, limit);
    }

    /// @dev A swap and two smaller ones in the same direction; the later ones start inside the partly sold
    /// book, or behind it after an early stop. The step cap is lifted after the first swap.
    function _swapSeries(bool zeroForOne, int256 specified, uint160 limit) private {
        _swapChecked(zeroForOne, specified, limit);
        hook.setMaxSteps(512);
        for (uint256 i = 3; i <= 7; i += 4) {
            (uint160 price,,,) = manager.getSlot0(id);
            if (zeroForOne ? price <= limit : price >= limit) break;
            int256 next = specified / int256(i) == 0 ? specified : specified / int256(i);
            _swapChecked(zeroForOne, next, limit);
        }
        // Then the other way, against the other side of the book.
        (uint160 now_,,,) = manager.getSlot0(id);
        if (now_ != _limit(!zeroForOne)) _swapChecked(!zeroForOne, specified, _limit(!zeroForOne));
    }

    // ---------------------------------------------------------------- edge cases

    /// @dev Codex's thin-AMM example: AMM liquidity 100, range liquidity 1,000 active at the start price.
    function test_thinAmmLandsExactly() public {
        _lp(-6000, 6000, 100);
        hook.setBook(key, true, 0, 6000, 1000, 6000, 0);
        uint256 snapshot = vm.snapshotState();
        _swapChecked(false, -500, MAX_LIMIT);
        vm.revertToState(snapshot);
        _swapChecked(false, 300, MAX_LIMIT);
    }

    /// @dev The PoolManager never held the input token: only minting claims, not a take, makes this work.
    /// With no AMM liquidity, the pool price then moves to the book's frontier.
    function test_zeroLiquidity_bookFillsWholeSwap_withoutPoolManagerFloat() public {
        hook.setBook(key, true, 20, 900, 1e18, 300, 1e17);
        assertEq(token1.balanceOf(address(manager)), 0);
        _swapChecked(false, -1e15, MAX_LIMIT);
        (SliceWalk.Fill memory f,) = hook.last();
        assertEq(f.ammShare, 0);
        assertEq(f.specified, 1e15);
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, f.frontier);
        assertEq(hook.lastSync(), f.frontier);
    }

    function test_zeroLiquidity_bookRunsOut_tightLimit() public {
        _bookRunsOut(TickMath.getSqrtPriceAtTick(500));
    }

    function test_zeroLiquidity_bookRunsOut_fullLimit() public {
        _bookRunsOut(MAX_LIMIT);
    }

    function test_fixedOnInitializedAmmTick() public {
        _lp(-6000, 6000, 1e18);
        _lp(-300, 300, 1e18);
        _books(1e18, 1e17);
        _sweepAmounts();
    }

    function test_fixedAtStartPrice() public {
        _lp(-6000, 6000, 1e18);
        hook.setBook(key, true, 20, 900, 1e18, 0, 1e17);
        hook.setBook(key, false, -900, -20, 1e18, 0, 1e17);
        _sweepAmounts();
    }

    function test_budgetEqualsStepBoundary() public {
        _lp(-100, 100, 1e18);
        hook.setBook(key, true, 100, 900, 1e18, 900, 0);
        uint160 target = TickMath.getSqrtPriceAtTick(100);
        (, uint256 amountIn,, uint256 fee) = SwapMath.computeSwapStep(PRICE_1, target, 1e18, AmmReplay.ALL_IN, 3000);
        _swapChecked(false, -int256(amountIn + fee), MAX_LIMIT);
        (uint160 price, int24 tick,,) = manager.getSlot0(id);
        assertEq(price, target);
        assertEq(tick, 100);
    }

    /// @dev An early stop leaves book liquidity behind the pool price; the next swaps fill it first.
    function test_catchUpAfterEarlyStop() public {
        _shape(1); // the first AMM step ends at tick 120 (or -120)
        _books(1e18, 1e17);
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i & 1 == 1;
            bool exactIn = i < 2;
            uint256 snapshot = vm.snapshotState();
            hook.setMaxSteps(1);
            _swapChecked(zeroForOne, exactIn ? -1e17 : int256(6e16), _limit(zeroForOne));
            (SliceWalk.Fill memory f,) = hook.last();
            assertEq(f.stop, SliceWalk.CAP);
            (uint160 price,,,) = manager.getSlot0(id);
            assertTrue(price != _limit(zeroForOne));
            hook.setMaxSteps(512);
            // Small: filled entirely from book liquidity behind the pool price.
            _swapChecked(zeroForOne, exactIn ? -1e15 : int256(1e15), _limit(zeroForOne));
            (f,) = hook.last();
            assertEq(f.ammShare, 0);
            // Larger: the rest of the catch-up, then book and AMM together.
            _swapChecked(zeroForOne, exactIn ? -3e17 : int256(2e17), _limit(zeroForOne));
            (, AmmReplay.Result memory e) = hook.last();
            assertGt(e.specified, 0, "the AMM traded after the catch-up");
            vm.revertToState(snapshot);
        }
    }

    function test_gasGuardStopsCleanly() public {
        _lp(-6000, 6000, 1e18);
        _books(1e18, 1e17);
        hook.setMinGas(type(uint256).max);
        _swapChecked(false, -1e17, MAX_LIMIT);
        (SliceWalk.Fill memory f,) = hook.last();
        assertEq(f.stop, SliceWalk.GAS);
        assertEq(f.specified, 0);
    }

    // ---------------------------------------------------------------- Sol 6.1 review regressions

    /// @dev A zero AMM share must not be read as exact output (review finding 1).
    function test_regression_liquidityOneZeroShare() public {
        _lp(-6000, 6000, 1);
        hook.setBook(key, true, 0, 900, 1e18, 900, 0);
        hook.setBook(key, false, -900, 0, 1e18, -900, 0);
        for (uint256 i; i < 4; ++i) {
            uint256 snapshot = vm.snapshotState();
            bool zeroForOne = i & 1 == 1;
            _swapChecked(zeroForOne, i < 2 ? int256(-1) : int256(1), _limit(zeroForOne));
            vm.revertToState(snapshot);
        }
    }

    /// @dev Fixed orders exactly at the price limit fill (review finding 2).
    function test_regression_fixedAtLimit() public {
        hook.setBook(key, true, 0, 0, 0, 300, 1e17);
        uint160 limit = TickMath.getSqrtPriceAtTick(300);
        int256[3] memory amounts = [int256(1), -1e15, -1e18];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _swapChecked(false, amounts[i], limit);
            (SliceWalk.Fill memory f,) = hook.last();
            assertEq(f.stop, SliceWalk.LIMIT);
            assertGt(f.fixedFilled, 0);
            vm.revertToState(snapshot);
        }
    }

    /// @dev At a 100% fee the book stays out and v4 takes the input as fees (review finding 3).
    function test_regression_fullFeeLeavesBookOut() public {
        _pool(1_000_000);
        _lp(-6000, 6000, 100);
        hook.setBook(key, true, 0, 900, 1000, 900, 0);
        _swapChecked(false, -10, MAX_LIMIT);
        (SliceWalk.Fill memory f,) = hook.last();
        assertEq(f.specified, 0);
    }

    /// @dev Outside the book's domain the PoolManager handles the swap alone (review finding 4).
    function test_regression_signedMinimum() public {
        hook.setBook(key, true, 20, 900, 1e18, 300, 1e17);
        _swap(false, type(int256).min, TickMath.getSqrtPriceAtTick(100));
        (SliceWalk.Fill memory f,) = hook.last();
        assertEq(f.specified, 0);
    }

    function test_regression_fixedLevelTooLargeForHookDeltas() public {
        vm.expectRevert(bytes("too large"));
        hook.setBook(key, true, 0, 0, 0, 6932, 1e38);
    }

    /// @dev One rounding of the squared price: principal 101 plus fee 1, not 111 plus 1 (review finding 6).
    function test_regression_fixedPriceRoundsOnce() public {
        hook.setBook(key, true, 0, 0, 0, 46_055, 1);
        _swapChecked(false, 1, MAX_LIMIT);
        (SliceWalk.Fill memory f,) = hook.last();
        assertEq(f.other, 102);
    }

    /// @dev The rounding allowance check must hold for a range of liquidity one (review finding 7).
    function test_regression_toleranceOnTinyRange() public {
        _lp(-6000, 6000, 100);
        hook.setBook(key, true, 0, 6000, 1, 6000, 0);
        _swapChecked(false, 1, MAX_LIMIT);
    }

    /// @dev Exact output stops where the request is met; range liquidity whose output rounds to zero is not
    /// charged (second review, finding 1). Asks, then bids mirrored.
    function test_regression_exactOutputStopsWhenMet() public {
        _poolAt(500, 200_000);
        hook.setBook(key, true, 200_000, 200_100, 1, 200_000, 1);
        _swapChecked(false, 1, TickMath.getSqrtPriceAtTick(200_200));
        (SliceWalk.Fill memory f,) = hook.last();
        assertEq(f.other, SliceWalk.fixedCost(false, TickMath.getSqrtPriceAtTick(200_000), 1, 500), "fixed only");
        (, , uint128 rangeLiquidity,,) = hook.asks();
        assertEq(rangeLiquidity, 1, "range untouched");

        _poolAt(100, -200_000);
        hook.setBook(key, false, -200_100, -200_000, 1, -200_000, 1);
        _swapChecked(true, 1, TickMath.getSqrtPriceAtTick(-200_200));
        (f,) = hook.last();
        assertEq(f.other, SliceWalk.fixedCost(true, TickMath.getSqrtPriceAtTick(-200_000), 1, 100), "fixed only");
    }

    /// @dev Catch-up that covers the request exactly stops where it is met (second review, finding 1).
    function test_regression_catchUpCoversExactly() public {
        _poolAt(500, 199_800);
        _lp(199_800, 200_000, 1);
        hook.setBook(key, true, 199_950, 200_100, 1, 199_900, 1);
        hook.setMaxSteps(0);
        _swapChecked(false, 1, TickMath.getSqrtPriceAtTick(200_000));
        hook.setMaxSteps(512);
        _swapChecked(false, 1, TickMath.getSqrtPriceAtTick(200_200));
        (SliceWalk.Fill memory f,) = hook.last();
        assertEq(f.other, SliceWalk.fixedCost(false, TickMath.getSqrtPriceAtTick(199_900), 1, 500), "fixed only");
        (, , uint128 rangeLiquidity,,) = hook.asks();
        assertEq(rangeLiquidity, 1, "range untouched");
    }

    /// @dev A pool initialized at the minimum price: no price move to an invalid limit (finding 2).
    function test_regression_noPriceMoveAtTheBounds() public {
        _poolAtPrice(500, TickMath.MIN_SQRT_PRICE);
        _swapChecked(false, -1, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(hook.lastSync(), 0);
    }

    /// @dev Admission bounds the fixed amount as well as its cost (finding 3).
    function test_regression_fixedAmountAdmission() public {
        _poolAt(500, -20_000);
        vm.expectRevert(bytes("too large"));
        hook.setBook(key, true, -20_000, -20_000, 0, -20_000, uint128(1) << 127);
    }

    /// @dev The gas guard also covers catch-up (finding 4).
    function test_regression_gasGuardBeforeCatchUp() public {
        _shape(1);
        _books(1e18, 1e17);
        hook.setMaxSteps(1);
        _swapChecked(false, -1e17, MAX_LIMIT);
        hook.setMaxSteps(512);
        hook.setMinGas(type(uint256).max);
        _swapChecked(false, -1e15, MAX_LIMIT);
        (SliceWalk.Fill memory f,) = hook.last();
        assertEq(f.stop, SliceWalk.GAS);
        assertEq(f.specified, 0);
    }

    /// @dev The price move works downwards too: the bid side fills a whole swap in an empty pool.
    function test_zeroLiquidity_bidsFillWholeSwap() public {
        hook.setBook(key, false, -900, -20, 1e18, -300, 1e17);
        _swapChecked(true, -1e15, MIN_LIMIT);
        (SliceWalk.Fill memory f,) = hook.last();
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, f.frontier);
        assertEq(hook.lastSync(), f.frontier);
    }

    // ---------------------------------------------------------------- brute force

    function test_bruteForce_exactInput() public {
        _bruteForce(true);
    }

    function test_bruteForce_exactOutput() public {
        _bruteForce(false);
    }

    /// @dev Every amount from 1 to 40 (and a few larger exact inputs) against every split: the AMM side swaps
    /// for real in a hook-free twin pool, the book side is written independently of the walk.
    function _bruteForce(bool exactIn) private {
        vm.pauseGasMetering();
        _twin();
        _lpBoth(-6000, 6000, 100);
        _books(1000, 50);
        for (uint256 d; d < 2; ++d) {
            bool zeroForOne = d == 1;
            for (uint256 amount = 1; amount <= 43; ++amount) {
                if (amount > 40) {
                    if (!exactIn) break;
                    amount = amount == 41 ? 80 : amount == 42 ? 150 : 400;
                }
                uint256 snapshot = vm.snapshotState();
                (uint256 best, bool feasible) = _best(zeroForOne, exactIn, amount);
                int256 specified = exactIn ? -int256(amount) : int256(amount);
                BalanceDelta delta = _swapChecked(zeroForOne, specified, _limit(zeroForOne));
                int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
                int128 received = zeroForOne ? delta.amount1() : delta.amount0();
                if (exactIn) assertGe(uint256(int256(received)) + ROUNDING, best, "worse than the best split");
                else if (feasible) {
                    assertEq(uint256(int256(received)), amount, "feasible output delivered");
                    assertLe(uint256(int256(-paid)), best + ROUNDING, "worse than the best split");
                }
                vm.revertToState(snapshot);
                if (amount >= 80 && amount < 400) amount = amount == 80 ? 41 : 42;
                if (amount == 400) break;
            }
        }
    }

    // ---------------------------------------------------------------- gas

    function test_gas_sliceSwap() public {
        if (!vm.isIsolateMode()) vm.skip(true);
        _lp(-6000, 6000, 1e18);
        hook.setBook(key, true, 20, 900, 1e18, 300, 1e17);
        PoolKey memory plain = PoolKey(key.currency0, key.currency1, 3000, 10, IHooks(address(0)));
        manager.initialize(plain, PRICE_1);
        lpRouter.modifyLiquidity(plain, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
        swapRouter.swap(plain, SwapParams(false, -1e17, MAX_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        _record("plain_swap");
        _swap(false, -1e17, MAX_LIMIT);
        _record("slice_swap");
        (SliceWalk.Fill memory f,) = hook.last();
        vm.snapshotValue("Phase0Gas", "slice_swap_search_probes", f.iterations);
        vm.snapshotValue("Phase0Gas", "slice_walk", hook.walkGas());
        vm.snapshotValue("Phase0Gas", "slice_replay_check_with_storage", hook.replayGas());
    }

    function _record(string memory label) private {
        Vm.Gas memory measured = vm.lastFrameGas();
        vm.snapshotValue("Phase0Gas", string.concat(label, "_gross"), measured.gasTotalUsed);
    }

    // ---------------------------------------------------------------- checks

    /// @dev Quotes the swap, runs it, and checks it against the quote, the replay and the walk.
    function _swapChecked(bool zeroForOne, int256 specified, uint160 limit) private returns (BalanceDelta delta) {
        SliceHook.Quote memory q = hook.quote(key, SwapParams(zeroForOne, specified, limit));
        SliceWalk.Book memory before = _side(zeroForOne);
        delta = _swap(zeroForOne, specified, limit);
        _check(zeroForOne, specified < 0, delta, before);
        _checkQuote(q);
        _checkRequest(zeroForOne, specified, delta);
    }

    function _check(bool zeroForOne, bool exactIn, BalanceDelta delta, SliceWalk.Book memory before) private {
        (SliceWalk.Fill memory f, AmmReplay.Result memory e) = hook.last();
        assertTrue(e.complete, "replay cap");
        (uint160 price, int24 tick,,) = manager.getSlot0(id);
        uint160 sync = hook.lastSync();
        assertEq(price, sync != 0 ? sync : e.sqrtPriceX96, "final price");
        assertEq(tick, sync != 0 ? hook.lastSyncTick() : e.tick, "final tick");
        _checkAmounts(zeroForOne, exactIn, delta, f, e);
        uint256 side = zeroForOne ? 0 : 1;
        claimed[side] += exactIn ? f.specified : f.other;
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        assertEq(manager.balanceOf(HOOK, input.toId()), claimed[side], "claims");
        if (f.stop == SliceWalk.INSIDE) _checkOptimal(zeroForOne, exactIn, e.sqrtPriceX96, f, before);
    }

    /// @dev The taker pays and receives exactly the book's share plus the AMM's.
    function _checkAmounts(
        bool zeroForOne,
        bool exactIn,
        BalanceDelta delta,
        SliceWalk.Fill memory f,
        AmmReplay.Result memory e
    ) private pure {
        (uint256 bookIn, uint256 bookOut) = exactIn ? (f.specified, f.other) : (f.other, f.specified);
        (uint256 ammIn, uint256 ammOut) = exactIn ? (e.specified, e.other) : (e.other, e.specified);
        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        int128 received = zeroForOne ? delta.amount1() : delta.amount0();
        assertEq(uint256(int256(-paid)), bookIn + ammIn, "taker paid");
        assertEq(uint256(int256(received)), bookOut + ammOut, "taker received");
    }

    /// @dev Exact input never pays more than requested, exact output never receives more; when the walk
    /// finished inside the budget, both are met exactly.
    function _checkRequest(bool zeroForOne, int256 specified, BalanceDelta delta) private view {
        (SliceWalk.Fill memory f,) = hook.last();
        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        int128 received = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 amount = specified < 0 ? uint256(-specified) : uint256(specified);
        uint256 met = specified < 0 ? uint256(int256(-paid)) : uint256(int256(received));
        assertLe(met, amount, "beyond the request");
        if (f.stop == SliceWalk.INSIDE) assertEq(met, amount, "request not met");
    }

    /// @dev Quote and execution run the same code with the same step cap; only the gas guard can differ.
    function _checkQuote(SliceHook.Quote memory q) private view {
        (SliceWalk.Fill memory f, AmmReplay.Result memory e) = hook.last();
        if (f.stop == SliceWalk.GAS) return;
        assertTrue(q.complete, "quote complete");
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(q.bookSpecified, f.specified, "quote: book specified");
        assertEq(q.bookOther, f.other, "quote: book other");
        assertEq(q.ammSpecified, e.specified, "quote: AMM specified");
        assertEq(q.ammOther, e.other, "quote: AMM other");
        assertEq(q.landing, e.sqrtPriceX96, "quote: landing");
        assertEq(q.finalPrice, price, "quote: final price");
        assertEq(q.stop, f.stop, "quote: stop");
    }

    function _checkOptimal(
        bool zeroForOne,
        bool exactIn,
        uint160 landing,
        SliceWalk.Fill memory f,
        SliceWalk.Book memory before
    ) private view {
        // The thesis: the AMM lands exactly where the walk sized it.
        assertEq(landing, f.ammShare == 0 ? f.start : f.ammLanding, "walk landing");
        (uint160 rangeFrom, uint160 rangeTo, uint128 rangeLiquidity, uint160 fixedPrice, uint128 fixedLeft) =
            zeroForOne ? hook.bids() : hook.asks();
        // When the AMM traded, it passed no unfilled fixed order and left nothing better than its price.
        if (f.ammShare == 0) return;
        if (fixedLeft != 0) assertFalse(_beyond(zeroForOne, landing, fixedPrice), "AMM passed a fixed order");
        if (_beyond(zeroForOne, landing, f.frontier)) {
            bool rangeBetween = rangeLiquidity != 0 && _beyond(zeroForOne, landing, rangeFrom)
                && _beyond(zeroForOne, rangeTo, f.frontier);
            bool fixedBetween = fixedLeft != 0 && _beyond(zeroForOne, landing, fixedPrice);
            assertFalse(rangeBetween || fixedBetween, "book left behind");
        }
        // The book stops at the AMM's next reachable price, give or take two units of its own rounding: its
        // leftover is bounded by a difference of two amounts each rounded from the walk's start, while it
        // spends that leftover in a segment rounded from the AMM's landing, which can differ by one unit
        // either way.
        if (before.rangeLiquidity == 0 || !_beyond(zeroForOne, f.frontier, f.ammNext)) return;
        uint160 from = _beyond(zeroForOne, before.rangeFrom, f.ammNext) ? before.rangeFrom : f.ammNext;
        if (!_beyond(zeroForOne, f.frontier, from)) return;
        bool inputIsZero = zeroForOne;
        bool specifiedIsZero = exactIn ? inputIsZero : !inputIsZero;
        uint256 past = specifiedIsZero
            ? SqrtPriceMath.getAmount0Delta(from, f.frontier, before.rangeLiquidity, false)
            : SqrtPriceMath.getAmount1Delta(from, f.frontier, before.rangeLiquidity, false);
        assertLe(past, 2, "book past the next AMM price");
    }

    function _bookRunsOut(uint160 limit) private {
        hook.setBook(key, true, 20, 100, 1e15, 300, 0);
        BalanceDelta delta = _swapChecked(false, -1e18, limit);
        (SliceWalk.Fill memory f, AmmReplay.Result memory e) = hook.last();
        assertEq(f.stop, SliceWalk.BOOK_DONE);
        assertLt(e.steps, hook.REPLAY_CAP() / 2, "replay cap margin");
        // The AMM ran to the limit trading nothing; the price then moved back to the book's frontier.
        assertEq(e.sqrtPriceX96, limit);
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, f.frontier);
        assertEq(uint256(int256(-delta.amount1())), f.specified, "charged only the book's take");
        assertEq(uint256(int256(delta.amount0())), f.other, "received only the book's output");
    }

    function _sweepAmounts() private {
        for (uint256 i = 10; i <= 22; ++i) {
            for (uint256 m; m < 4; ++m) {
                uint256 snapshot = vm.snapshotState();
                bool zeroForOne = m >= 2;
                int256 specified = int256(3 * 10 ** i / 2);
                if (m & 1 == 0) specified = -specified;
                _swapChecked(zeroForOne, specified, _limit(zeroForOne));
                vm.revertToState(snapshot);
            }
        }
    }

    // ---------------------------------------------------------------- setup helpers

    function _pool(uint24 fee) private {
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), fee, 10, IHooks(HOOK));
        id = key.toId();
        manager.initialize(key, PRICE_1);
    }

    /// @dev A fresh hooked pool at `tick`, replacing `key`.
    function _poolAt(uint24 fee, int24 tick) private {
        _poolAtPrice(fee, TickMath.getSqrtPriceAtTick(tick));
    }

    function _poolAtPrice(uint24 fee, uint160 price) private {
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), fee, 10, IHooks(HOOK));
        id = key.toId();
        manager.initialize(key, price);
        claimed[0] = manager.balanceOf(HOOK, key.currency0.toId());
        claimed[1] = manager.balanceOf(HOOK, key.currency1.toId());
    }

    function _twin() private {
        twin = PoolKey(key.currency0, key.currency1, key.fee, 10, IHooks(address(0)));
        manager.initialize(twin, PRICE_1);
    }

    /// @return thin Whether the shape is the thin AMM.
    function _shape(uint256 shape) private returns (bool thin) {
        if (shape == 0) {
            _lp(-6000, 6000, 1e18);
        } else if (shape == 1) {
            _lp(-6000, 6000, 1e17);
            _lp(-120, 120, 5e17);
            _lp(-600, 300, 1e18);
            _lp(200, 1500, 2e18);
            _lp(-1500, -200, 2e18);
        } else if (shape == 2) {
            _lp(-6000, 6000, 100);
            return true;
        } else if (shape == 4) {
            // No AMM liquidity before or during the book; positions further out.
            _lp(1000, 3000, 1e18);
            _lp(-3000, -1000, 1e18);
        }
    }

    /// @dev Book layouts, given for asks and mirrored for bids.
    function _layout(uint256 which, uint128 liquidity, uint128 fixedAmount) private {
        int24[4][6] memory shapes = [
            [int24(20), 900, 300, 1], // fixed inside the range
            [int24(20), 900, 1200, 1], // fixed beyond the range's end
            [int24(0), 900, 900, 1], // range from the pool price, fixed at its end
            [int24(0), 0, 0, 0], // fixed only, at the pool price
            [int24(20), 900, 900, 2], // range only
            [int24(20), 900, 20, 1] // fixed at the range's start
        ];
        int24[4] memory l = shapes[which];
        uint128 rangeLiquidity = l[3] == 0 ? 0 : liquidity;
        uint128 fixedLiquidity = l[3] == 2 ? 0 : fixedAmount;
        hook.setBook(key, true, l[0], l[1], rangeLiquidity, l[2], fixedLiquidity);
        hook.setBook(key, false, -l[1], -l[0], rangeLiquidity, -l[2], fixedLiquidity);
    }

    function _books(uint128 liquidity, uint128 fixedAmount) private {
        hook.setBook(key, true, 20, 900, liquidity, 300, fixedAmount);
        hook.setBook(key, false, -900, -20, liquidity, -300, fixedAmount);
    }

    function _lp(int24 lower, int24 upper, uint256 liquidity) private {
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(liquidity), 0), "");
    }

    function _lpBoth(int24 lower, int24 upper, uint256 liquidity) private {
        _lp(lower, upper, liquidity);
        lpRouter.modifyLiquidity(twin, ModifyLiquidityParams(lower, upper, int256(liquidity), 0), "");
    }

    function _swap(bool zeroForOne, int256 specified, uint160 limit) private returns (BalanceDelta) {
        return
            swapRouter.swap(key, SwapParams(zeroForOne, specified, limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function _side(bool zeroForOne) private view returns (SliceWalk.Book memory b) {
        (b.rangeFrom, b.rangeTo, b.rangeLiquidity, b.fixedPrice, b.fixedAmount) =
            zeroForOne ? hook.bids() : hook.asks();
    }

    function _limit(bool zeroForOne) private pure returns (uint160) {
        return zeroForOne ? MIN_LIMIT : MAX_LIMIT;
    }

    function _beyond(bool zeroForOne, uint160 a, uint160 b) private pure returns (bool) {
        return zeroForOne ? a < b : a > b;
    }

    // ---------------------------------------------------------------- independent oracle

    /// @dev The best split by brute force. Each AMM share runs as a real swap in the twin pool, reverted
    /// afterwards; the book side comes from `_bookAlone`.
    function _best(bool zeroForOne, bool exactIn, uint256 amount) private returns (uint256 best, bool feasible) {
        best = exactIn ? 0 : type(uint256).max;
        for (uint256 r; r <= amount; ++r) {
            (uint256 bookAmount, bool bookOk) = this.bookAlone(zeroForOne, exactIn, amount - r);
            if (!bookOk) continue;
            uint256 snapshot = vm.snapshotState();
            (uint256 ammAmount, bool ammOk) = this.twinSwap(zeroForOne, exactIn, r);
            vm.revertToState(snapshot);
            if (!ammOk) continue;
            uint256 total = ammAmount + bookAmount;
            if (exactIn ? total > best : total < best) best = total;
            feasible = true;
        }
    }

    /// @return other The other amount of an AMM-only swap of r in the twin pool.
    /// @return ok Whether it delivered all of r (exact output).
    function twinSwap(bool zeroForOne, bool exactIn, uint256 r) external returns (uint256 other, bool ok) {
        if (r == 0) return (0, true);
        BalanceDelta d = swapRouter.swap(
            twin,
            SwapParams(zeroForOne, exactIn ? -int256(r) : int256(r), _limit(zeroForOne)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        int128 paid = zeroForOne ? d.amount0() : d.amount1();
        int128 received = zeroForOne ? d.amount1() : d.amount0();
        if (exactIn) return (uint256(int256(received)), true);
        return (uint256(int256(-paid)), uint256(int256(received)) == r);
    }

    struct Oracle {
        bool zeroForOne;
        bool exactIn;
        uint24 fee;
        uint256 left;
        uint256 sum;
        uint160 price;
        uint128 fixedLeft;
    }

    /// @dev The book alone, in price order from its best price: the output for an input budget, or the input
    /// for an output and whether the book can deliver it. Written independently of SliceWalk.
    function bookAlone(bool zeroForOne, bool exactIn, uint256 amount) external view returns (uint256, bool) {
        SliceWalk.Book memory b = _side(zeroForOne);
        (,,, uint24 fee) = manager.getSlot0(id);
        Oracle memory o = Oracle(zeroForOne, exactIn, fee, amount, 0, b.rangeFrom, b.fixedAmount);
        if (b.fixedAmount != 0 && (b.rangeLiquidity == 0 || _beyond(zeroForOne, b.rangeFrom, b.fixedPrice))) {
            o.price = b.fixedPrice;
        }
        for (uint256 i; i < 6 && o.left != 0; ++i) {
            if (o.fixedLeft != 0 && o.price == b.fixedPrice) {
                if (!_oracleFixed(o, b.fixedPrice)) break;
                continue;
            }
            uint160 end = b.rangeTo;
            if (o.fixedLeft != 0 && _beyond(zeroForOne, b.fixedPrice, o.price) && _beyond(zeroForOne, end, b.fixedPrice)) {
                end = b.fixedPrice;
            }
            bool inRange = b.rangeLiquidity != 0 && !_beyond(zeroForOne, b.rangeFrom, o.price)
                && _beyond(zeroForOne, b.rangeTo, o.price);
            if (inRange) {
                if (!_oracleRange(o, end, b.rangeLiquidity)) break;
            } else if (o.fixedLeft != 0 && _beyond(zeroForOne, b.fixedPrice, o.price)) {
                o.price = b.fixedPrice;
            } else {
                break;
            }
        }
        return (o.sum, exactIn || o.left == 0);
    }

    /// @return more Whether the range was used up to `end` with budget left.
    function _oracleRange(Oracle memory o, uint160 end, uint128 liquidity) private pure returns (bool more) {
        (uint160 next, uint256 amountIn, uint256 amountOut, uint256 feeAmount) = SwapMath.computeSwapStep(
            o.price, end, liquidity, o.exactIn ? -int256(o.left) : int256(o.left), o.fee
        );
        if (o.exactIn) {
            o.sum += amountOut;
            o.left -= amountIn + feeAmount;
        } else {
            o.sum += amountIn + feeAmount;
            o.left -= amountOut;
        }
        o.price = next;
        return next == end;
    }

    /// @return more Whether the fixed level was used up with budget left.
    function _oracleFixed(Oracle memory o, uint160 price) private pure returns (bool more) {
        uint256 out;
        if (o.exactIn) {
            while (out < o.fixedLeft && _gross(o, price, out + 1) <= o.left) ++out;
            o.sum += out;
            o.left -= _gross(o, price, out);
        } else {
            out = o.left < o.fixedLeft ? o.left : o.fixedLeft;
            o.sum += _gross(o, price, out);
            o.left -= out;
        }
        o.fixedLeft -= uint128(out);
        return o.fixedLeft == 0;
    }

    /// @dev ceil(out * price^2 / 2^192) or its inverse, plus the fee, in 512-bit arithmetic.
    function _gross(Oracle memory o, uint160 price, uint256 out) private pure returns (uint256) {
        uint256 squared = uint256(price) * price;
        uint256 amountIn = o.zeroForOne
            ? FullMath.mulDivRoundingUp(out, 1 << 192, squared)
            : FullMath.mulDivRoundingUp(out, squared, 1 << 192);
        return amountIn + FullMath.mulDivRoundingUp(amountIn, o.fee, 1_000_000 - o.fee);
    }
}
