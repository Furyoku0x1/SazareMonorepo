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
import {BookWalk} from "../src/libraries/BookWalk.sol";
import {FixedBook} from "../src/libraries/FixedBook.sol";
import {RangeBook} from "../src/libraries/RangeBook.sol";

/// @dev Phase 3 harness: a plain v4 hook (no Kernel) over the stored books. beforeSwap plans and commits the walk;
/// afterSwap requires the pool to land where AmmReplay predicted, pays the book's output and takes its input as
/// ERC-6909 claims, and moves an empty pool's price to the book's frontier. Escrow is minted, not accounted.
contract BookHook is IHooks {
    using StateLibrary for IPoolManager;

    uint256 public constant REPLAY_CAP = 4096;
    IPoolManager public immutable MANAGER;
    BookWalk.PoolBook internal _book;
    BookWalk.Limits public limits = BookWalk.Limits(512, 128, 8, 64);
    uint256[2] public lotSize = [uint256(1), 1]; // per side: [0] asks sell currency0, [1] bids sell currency1
    uint24 public makerFeePips = 3000;
    uint256 public minGas;
    bool public skipBook; // the book's callback "fails": the AMM takes the whole swap
    uint160 public lastSync;
    int24 public lastSyncTick;
    uint256 public walkGas;
    uint256 public commitGas;
    uint256[2] public principal; // cumulative per input currency
    uint256[2] public takerFees;
    uint256[2] public makerFees;
    uint256[2] public bookOut; // cumulative per output currency
    BookWalk.Fill internal _fill;
    AmmReplay.Result internal _expected;

    struct Quote {
        uint256 bookSpecified;
        uint256 bookOther;
        uint256 ammSpecified;
        uint256 ammOther;
        uint160 landing;
        uint160 finalPrice;
        uint160 frontier;
        uint8 stop;
        bool complete;
    }

    constructor(IPoolManager manager) {
        MANAGER = manager;
    }

    function setLimits(BookWalk.Limits calldata value) external {
        limits = value;
    }

    function setLotSizes(uint256 asks, uint256 bids) external {
        lotSize = [asks, bids];
    }

    function setMakerFee(uint24 value) external {
        makerFeePips = value;
    }

    function setMinGas(uint256 value) external {
        minGas = value;
    }

    function setSkipBook(bool value) external {
        skipBook = value;
    }

    /// @dev Post-only: asks at or above the pool price, bids at or below it.
    function placeFixed(PoolKey calldata key, bool sell0, int24 tick, uint64 lots) external returns (uint256 id) {
        uint160 price = TickMath.getSqrtPriceAtTick(tick);
        _postOnly(key, sell0, price);
        id = FixedBook.place(_book.fixedOrders, msg.sender, sell0, tick, lots, makerFeePips);
        BookWalk.noteOrder(_book, sell0, price, price);
    }

    function placeRange(PoolKey calldata key, bool sell0, int24 lower, int24 upper, uint128 liquidity)
        external
        returns (uint256 id)
    {
        uint160 near = TickMath.getSqrtPriceAtTick(sell0 ? lower : upper);
        _postOnly(key, sell0, near);
        id = RangeBook.place(_book.ranges, msg.sender, sell0, lower, upper, liquidity, makerFeePips);
        BookWalk.noteOrder(_book, sell0, near, TickMath.getSqrtPriceAtTick(sell0 ? upper : lower));
    }

    function cancelFixed(uint256 id) external returns (uint64 kept, uint64 refund) {
        return FixedBook.cancel(_book.fixedOrders, id, msg.sender);
    }

    function cancelRange(uint256 id) external returns (uint256 refund) {
        return RangeBook.cancel(_book.ranges, id, msg.sender);
    }

    function filledLots(uint256 id) external view returns (uint64) {
        return FixedBook.filledLots(_book.fixedOrders, id);
    }

    function fixedOrder(uint256 id) external view returns (FixedBook.Order memory) {
        return _book.fixedOrders.orders[id];
    }

    function rangeOrder(uint256 id) external view returns (RangeBook.Range memory) {
        return _book.ranges.ranges[id];
    }

    function rangeFrontier(uint256 id) external view returns (uint160) {
        return RangeBook.frontierOf(_book.ranges, id);
    }

    function live(bool sell0, int24 tick) external view returns (uint128) {
        return FixedBook.live(_book.fixedOrders.sides[sell0 ? 0 : 1], tick);
    }

    function start(bool sell0) external view returns (uint160) {
        return _book.start[sell0 ? 0 : 1];
    }

    /// @notice The AMM's output from the pool price to `limit` alone, crossing ticks as a swap would.
    function ammOutputTo(PoolKey calldata key, bool zeroForOne, uint160 limit) external view returns (uint256) {
        PoolId id = key.toId();
        (,,, uint24 lpFee) = MANAGER.getSlot0(id);
        AmmReplay.Pool memory pool = AmmReplay.Pool(
            MANAGER, id, key.tickSpacing, zeroForOne, limit, AmmReplay.swapFee(MANAGER, id, zeroForOne, lpFee)
        );
        return AmmReplay.swap(pool, -int256(uint256(uint128(type(int128).max))), REPLAY_CAP).other;
    }

    function last() external view returns (BookWalk.Fill memory, AmmReplay.Result memory) {
        return (_fill, _expected);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(msg.sender == address(MANAGER));
        if (skipBook || params.amountSpecified == type(int256).min) {
            delete _fill;
            _expected.complete = false;
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        BookWalk.Request memory r = _request(key, params, minGas);
        uint256 gas = gasleft();
        BookWalk.Plan memory p = BookWalk.plan(_book, r);
        walkGas = gas - gasleft();
        gas = gasleft();
        uint256 makerFee = BookWalk.commit(_book, r, p);
        commitGas = gas - gasleft();
        BookWalk.Fill memory f = p.fill;
        uint256 input = params.zeroForOne ? 0 : 1;
        principal[input] += f.principal;
        takerFees[input] += f.takerFee;
        makerFees[input] += makerFee;
        bookOut[1 - input] += params.amountSpecified < 0 ? f.other : f.specified;
        _fill = f;
        uint256 rest = r.budget - f.specified;
        _expected = AmmReplay.swap(r.pool, r.exactIn ? -int256(rest) : int256(rest), REPLAY_CAP);
        int128 spec = SafeCast.toInt128(f.specified);
        int128 other = SafeCast.toInt128(f.other);
        BeforeSwapDelta delta = r.exactIn ? toBeforeSwapDelta(spec, -other) : toBeforeSwapDelta(-spec, other);
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    function quote(PoolKey calldata key, SwapParams calldata params) external view returns (Quote memory q) {
        if (skipBook || params.amountSpecified == type(int256).min) return q;
        BookWalk.Request memory r = _request(key, params, 0);
        BookWalk.Fill memory f = BookWalk.plan(_book, r).fill;
        uint256 rest = r.budget - f.specified;
        AmmReplay.Result memory e = AmmReplay.swap(r.pool, r.exactIn ? -int256(rest) : int256(rest), REPLAY_CAP);
        q = Quote(f.specified, f.other, e.specified, e.other, e.sqrtPriceX96, e.sqrtPriceX96, f.frontier, f.stop, e.complete);
        if (f.specified == 0 && f.other == 0) return q;
        (uint160 target,) = _syncTarget(key, AmmReplay.Cursor(e.sqrtPriceX96, e.tick, e.liquidity), f.frontier);
        if (target != 0) q.finalPrice = target;
    }

    function _request(PoolKey calldata key, SwapParams calldata params, uint256 guard)
        private
        view
        returns (BookWalk.Request memory r)
    {
        PoolId id = key.toId();
        (,,, uint24 lpFee) = MANAGER.getSlot0(id);
        r.pool = AmmReplay.Pool(
            MANAGER,
            id,
            key.tickSpacing,
            params.zeroForOne,
            params.sqrtPriceLimitX96,
            AmmReplay.swapFee(MANAGER, id, params.zeroForOne, lpFee)
        );
        r.exactIn = params.amountSpecified < 0;
        r.budget = r.exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        r.lotSize = lotSize[params.zeroForOne ? 1 : 0];
        r.limits = limits;
        r.minGas = guard;
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
        (uint256 bookIn, uint256 out) = exactIn ? (_fill.specified, _fill.other) : (_fill.other, _fill.specified);
        if (out != 0) {
            MANAGER.sync(output);
            MockERC20(Currency.unwrap(output)).transfer(address(MANAGER), out);
            MANAGER.settle();
        }
        // Claims instead of a take: no PoolManager float is needed before the taker pays.
        if (bookIn != 0) MANAGER.mint(address(this), input.toId(), bookIn);
        _sync(key);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev With no AMM liquidity between the pool price and the book's frontier, the pool price moves there with a
    /// swap that trades nothing. Returns 0 when it cannot.
    function _syncTarget(PoolKey calldata key, AmmReplay.Cursor memory c, uint160 frontier)
        private
        view
        returns (uint160 target, int24 tick)
    {
        if (frontier == c.sqrtPriceX96) return (0, 0);
        if (frontier <= TickMath.MIN_SQRT_PRICE || frontier >= TickMath.MAX_SQRT_PRICE) return (0, 0);
        bool down = frontier < c.sqrtPriceX96;
        PoolId id = key.toId();
        (,,, uint24 lpFee) = MANAGER.getSlot0(id);
        AmmReplay.Pool memory pool =
            AmmReplay.Pool(MANAGER, id, key.tickSpacing, down, frontier, AmmReplay.swapFee(MANAGER, id, down, lpFee));
        AmmReplay.Result memory r = AmmReplay.swapFrom(pool, c, -1, REPLAY_CAP);
        if (r.complete && r.specified == 0 && r.sqrtPriceX96 == frontier) return (frontier, r.tick);
    }

    function _sync(PoolKey calldata key) private {
        lastSync = 0;
        if (_fill.specified == 0 && _fill.other == 0) return;
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

    function _postOnly(PoolKey calldata key, bool sell0, uint160 near) private view {
        (uint160 price,,,) = MANAGER.getSlot0(key.toId());
        require(sell0 ? near >= price : near <= price, "crosses");
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

contract BookWalkTest is Test {
    using StateLibrary for IPoolManager;

    uint160 private constant PRICE_1 = 1 << 96;
    uint160 private constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    /// @dev Integer-optimum gap allowed in the brute force: each source and each book piece rounds once.
    uint256 private constant ROUNDING = 8;
    // beforeSwap, afterSwap and beforeSwapReturnDelta flags only.
    address private constant HOOK = address(uint160(0x5555) << 144 | 0xC8);

    IPoolManager private manager;
    PoolSwapTest private swapRouter;
    PoolModifyLiquidityTest private lpRouter;
    BookHook private hook;
    MockERC20 private token0;
    MockERC20 private token1;
    PoolKey private key;
    PoolId private id;
    PoolKey private twin; // the same liquidity without the hook, for the brute force
    uint256[2] private claimed;

    /// @dev The test's own record of the orders it placed, for the independent book oracle and solvency.
    struct FixedModel {
        bool sell0;
        int24 tick;
        uint64 lots;
        uint256 id;
        uint24 fee; // the maker fee when placed
    }

    struct RangeModel {
        bool sell0;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 id;
    }

    FixedModel[] private fixedOrders;
    RangeModel[] private rangeOrders;

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
            token.mint(HOOK, 1e36); // book escrow; the walk does not account it
        }
        deployCodeTo("BookWalk.t.sol:BookHook", abi.encode(manager), HOOK);
        hook = BookHook(HOOK);
        _pool(3000);
    }

    // ---------------------------------------------------------------- fuzz

    /// @dev Pool shapes and books of several fixed levels and ranges per side; a swap series in both modes and
    /// directions. Every swap lands exactly where the walk sized it, matches its quote, meets the request, leaves no
    /// book liquidity better than the AMM's landing, and keeps the book solvent.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_landsWhereTheWalkSized(uint256 seed) public {
        bool zeroForOne = seed & 1 == 1;
        bool exactIn = (seed >> 1) & 1 == 1;
        bool thin = _shape((seed >> 2) % 5);
        _randomBook(seed >> 8, thin);
        uint256 amount = 1 + (seed >> 40) % (10 ** (1 + (seed >> 200) % (thin ? 4 : 21)));
        _swapSeries(zeroForOne, exactIn ? -int256(amount) : int256(amount), _limit(zeroForOne));
        _checkSolvency();
    }

    /// @dev Also varies the fee, protocol fee, limits, lot sizes, maker fees and price limit, with placements and
    /// cancellations between swaps.
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
        if ((seed >> 8) & 1 == 1 && !thin) hook.setLotSizes(1e12, 1e10);
        hook.setMakerFee(uint24((seed >> 9) % 4) * 1000);
        _randomBook(seed >> 16, thin);
        uint256 caps = (seed >> 48) % 6;
        if (caps == 1) hook.setLimits(BookWalk.Limits(1, 128, 8, 64)); // one AMM step
        if (caps == 2) hook.setLimits(BookWalk.Limits(512, 3, 8, 64)); // three book points
        if (caps == 3) hook.setLimits(BookWalk.Limits(512, 128, 1, 64)); // one word per search
        if (caps == 4) hook.setLimits(BookWalk.Limits(0, 128, 8, 64)); // no AMM step
        bool zeroForOne = seed & 1 == 1;
        uint160 limit = (seed >> 52) & 3 == 0
            ? TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-400) : int24(400))
            : _limit(zeroForOne);
        uint256 amount = 1 + (seed >> 56) % (10 ** (1 + (seed >> 200) % (thin ? 4 : 21)));
        int256 specified = (seed >> 1) & 1 == 1 ? -int256(amount) : int256(amount);
        _swapChecked(zeroForOne, specified, limit);
        hook.setLimits(BookWalk.Limits(512, 128, 8, 64));
        _placeMore(seed >> 100, thin);
        _swapSeries(zeroForOne, specified, limit);
        _checkSolvency();
    }

    /// @dev A swap and two smaller ones in the same direction, then one the other way.
    function _swapSeries(bool zeroForOne, int256 specified, uint160 limit) private {
        (uint160 first,,,) = manager.getSlot0(id);
        if (zeroForOne ? first > limit : first < limit) _swapChecked(zeroForOne, specified, limit);
        for (uint256 i = 3; i <= 7; i += 4) {
            (uint160 price,,,) = manager.getSlot0(id);
            if (zeroForOne ? price <= limit : price >= limit) break;
            int256 next = specified / int256(i) == 0 ? specified : specified / int256(i);
            _swapChecked(zeroForOne, next, limit);
        }
        (uint160 now_,,,) = manager.getSlot0(id);
        if (now_ != _limit(!zeroForOne)) _swapChecked(!zeroForOne, specified, _limit(!zeroForOne));
    }

    /// @dev Found by the fuzz: exact output reaches the book's point limit; the AMM delivers the rest (CAP).
    function test_regression_exactOutputAtPointLimit() public {
        testFuzz_configurations(115652277280435404051552445127770301823901364);
    }

    /// @dev Found by the fuzz: in the guess, a fixed level uses up what is left exactly.
    function test_regression_guessSpendsLevelExactly() public {
        testFuzz_landsWhereTheWalkSized(631682016546349535228549558658161829151258732591948541454451);
    }

    /// @dev Found by the fuzz: a fixed level uses up exact input exactly, before range liquidity at the same point.
    function test_regression_levelSpendsInputExactly() public {
        testFuzz_configurations(4046508001838812194343114);
    }

    /// @dev Found by the fuzz: exact output whose last part is below one lot of a bid level placed between swaps.
    function test_regression_subLotExactOutputSeed() public {
        testFuzz_configurations(265538579985779784692144312363740070813977619671784637120716769612);
    }

    /// @dev Exact output of 3.5 lots against a level of 10 lots: the book fills 3, the AMM the half lot, passing the
    /// level by that much; the next swap fills the level first, four whole lots, and the AMM takes the rest.
    function test_exactOutputBelowOneLotGoesToTheAmm() public {
        _lp(-6000, 6000, 1e14); // up to tick 100 the AMM delivers about half a lot
        hook.setLotSizes(1e12, 1e12);
        _fixed(true, 100, 10);
        _swapChecked(false, 36e11, MAX_LIMIT);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.frontier, TickMath.getSqrtPriceAtTick(100));
        assertEq(f.specified, 3e12, "three whole lots");
        assertEq(hook.live(true, 100), 7);
        (uint160 price,,,) = manager.getSlot0(id);
        assertGt(price, f.frontier, "the AMM delivered the rest, past the level");
        _swapChecked(false, -5e12, MAX_LIMIT);
        (f,) = hook.last();
        assertEq(hook.live(true, 100), 3, "the level, behind the pool price, fills first");
        assertLt(f.ammShare, 2e12, "the AMM takes what is short of a lot's cost");
    }

    // ---------------------------------------------------------------- edge cases

    /// @dev The PoolManager never held the input token: only minting claims makes this work. With no AMM liquidity,
    /// the pool price then moves to the book's frontier.
    function test_zeroLiquidity_bookFillsWholeSwap() public {
        _books(1e18, 1e17);
        assertEq(token1.balanceOf(address(manager)), 0);
        _swapChecked(false, -1e15, MAX_LIMIT);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.ammShare, 0);
        assertEq(f.specified, 1e15);
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, f.frontier);
        _swapChecked(true, -1e15, MIN_LIMIT);
    }

    /// @dev The book runs out: the AMM runs to the limit trading nothing, then the price moves back to the
    /// frontier; the taker pays only for what filled.
    function test_zeroLiquidity_bookRunsOut() public {
        _range(true, 20, 100, 1e15);
        _fixed(true, 300, 1e10);
        BalanceDelta delta = _swapChecked(false, -1e18, TickMath.getSqrtPriceAtTick(500));
        (BookWalk.Fill memory f, AmmReplay.Result memory e) = hook.last();
        assertEq(f.stop, BookWalk.BOOK_DONE);
        assertEq(e.sqrtPriceX96, TickMath.getSqrtPriceAtTick(500));
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, f.frontier);
        assertEq(uint256(int256(-delta.amount1())), f.specified, "charged only the book's take");
        assertEq(uint256(int256(delta.amount0())), f.other, "received only the book's output");
        assertEq(hook.live(true, 300), 0, "level filled");
    }

    /// @dev Several orders at one price fill FIFO; a level the swap cannot finish keeps its later orders.
    function test_fixedLevelsFillFifo() public {
        _lp(-6000, 6000, 1e14);
        uint256 first = _fixed(true, 200, 3e15);
        uint256 second = _fixed(true, 200, 2e15);
        uint256 third = _fixed(true, 200, 5e15);
        _fixed(true, 400, 1e16);
        _swapChecked(false, 4e15, MAX_LIMIT); // exact output of 4e15: the AMM below 200, then the level
        assertEq(hook.filledLots(fixedOrders[first].id), 3e15, "first filled");
        assertGt(hook.filledLots(fixedOrders[second].id), 0, "second partly");
        assertEq(hook.filledLots(fixedOrders[third].id), 0, "third waits");
    }

    /// @dev An early stop (one AMM step) leaves book liquidity behind the pool price; the next swaps fill it first.
    function test_catchUpAfterEarlyStop() public {
        _shape(1);
        _books(1e18, 1e17);
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i & 1 == 1;
            bool exactIn = i < 2;
            uint256 snapshot = vm.snapshotState();
            hook.setLimits(BookWalk.Limits(1, 128, 8, 64));
            _swapChecked(zeroForOne, exactIn ? -1e17 : int256(6e16), _limit(zeroForOne));
            (BookWalk.Fill memory f,) = hook.last();
            assertEq(f.stop, BookWalk.CAP);
            hook.setLimits(BookWalk.Limits(512, 128, 8, 64));
            _swapChecked(zeroForOne, exactIn ? -1e15 : int256(1e15), _limit(zeroForOne));
            (f,) = hook.last();
            assertEq(f.ammShare, 0, "filled from book liquidity behind the pool price");
            _swapChecked(zeroForOne, exactIn ? -3e17 : int256(2e17), _limit(zeroForOne));
            (, AmmReplay.Result memory e) = hook.last();
            assertGt(e.specified, 0, "the AMM traded after the catch-up");
            vm.revertToState(snapshot);
        }
    }

    /// @dev The book's callback is skipped: the AMM moves past unsold book liquidity with no walk. The side's start
    /// stays, so the next swap fills that liquidity first.
    function test_skippedBookCatchesUp() public {
        _lp(-6000, 6000, 1e18);
        _books(1e18, 1e17);
        hook.setSkipBook(true);
        _swap(false, -3e17, MAX_LIMIT);
        hook.setSkipBook(false);
        (uint160 price,,,) = manager.getSlot0(id);
        assertGt(price, TickMath.getSqrtPriceAtTick(300), "past the fixed level");
        _swapChecked(false, -1e15, MAX_LIMIT);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.ammShare, 0, "book liquidity behind the pool price first");
        _swapChecked(false, -1e18, MAX_LIMIT);
        _checkSolvency();
    }

    /// @dev A level with more chunks than one walk may visit: the book stops there, the AMM goes on, and later swaps
    /// finish the level.
    function test_chunkLimitStopsAtLevel() public {
        _lp(-6000, 6000, 1e18);
        hook.setLimits(BookWalk.Limits(512, 128, 8, 2));
        for (uint256 i; i < 600; ++i) {
            _fixed(true, 100, 1e12);
        }
        _swapChecked(false, -1e17, MAX_LIMIT);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.stop, BookWalk.CAP);
        assertEq(f.frontier, TickMath.getSqrtPriceAtTick(100));
        assertEq(hook.live(true, 100), 600e12 - 512e12, "two chunks filled");
        _swapChecked(false, -1e14, MAX_LIMIT);
        _swapChecked(false, -1e17, MAX_LIMIT);
        assertEq(hook.live(true, 100), 0, "level finished");
        _checkSolvency();
    }

    function test_gasGuardStopsCleanly() public {
        _lp(-6000, 6000, 1e18);
        _books(1e18, 1e17);
        hook.setMinGas(type(uint256).max);
        _swapChecked(false, -1e17, MAX_LIMIT);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.stop, BookWalk.GAS);
        assertEq(f.specified, 0);
    }

    function test_fullFeeLeavesBookOut() public {
        _pool(1_000_000);
        _lp(-6000, 6000, 1e18);
        _books(1e18, 1e17);
        _swapChecked(false, -1e15, MAX_LIMIT);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.specified, 0);
    }

    function test_fixedAtLimitFills() public {
        _lp(-6000, 6000, 1e18);
        _fixed(true, 300, 1e15);
        _swapChecked(false, -1e17, TickMath.getSqrtPriceAtTick(300));
        assertEq(hook.live(true, 300), 0);
    }

    /// @dev Sol's review: a cancelled head chunk used up a one-chunk limit, so the level looked empty and the book
    /// passed its live orders. The book now stops at the level, the commit moves past the empty chunk, and the next
    /// swap fills the live order.
    function test_regression_emptyHeadChunkDoesNotHideALevel() public {
        _lp(-6000, 6000, 1e18);
        uint256 first = _fixed(true, 100, 1e15);
        hook.setMakerFee(500); // a fee change starts a new chunk
        uint256 second = _fixed(true, 100, 1e15);
        hook.cancelFixed(fixedOrders[first].id); // the head chunk is now empty
        hook.setLimits(BookWalk.Limits(512, 128, 8, 1));
        _swapChecked(false, -1e17, MAX_LIMIT);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.frontier, TickMath.getSqrtPriceAtTick(100), "the book stops at the level");
        assertEq(f.stop, BookWalk.CAP);
        _swapChecked(false, -1e17, MAX_LIMIT);
        assertEq(hook.filledLots(fixedOrders[second].id), 1e15, "the live order fills");
    }

    /// @dev Sol's review: levels each within the amount bound could add up past it. Four asks of about 2^125 output
    /// below a price of 1: an exact input of 2^126 would buy 2^127 output, beyond the hook's int128 deltas. The third
    /// level now ends the book.
    function test_regression_cumulativeAmountBound() public {
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 10, IHooks(HOOK));
        key.fee = 500;
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(-10_100));
        claimed[0] = manager.balanceOf(HOOK, key.currency0.toId());
        claimed[1] = manager.balanceOf(HOOK, key.currency1.toId());
        uint256 lot = 1 << 69;
        hook.setLotSizes(lot, lot);
        token0.mint(HOOK, 1 << 128);
        token1.mint(address(this), 1 << 128);
        uint64 lots = FixedBook.MAX_ORDER_LOTS;
        for (int24 t = -10_000; t < -9996; ++t) {
            _fixed(true, t, lots);
        }
        _swapChecked(false, -int256(1 << 126), MAX_LIMIT);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.stop, BookWalk.CAP);
        assertLe(f.other, BookWalk.MAX_BOOK_AMOUNT, "output within the bound");
        assertEq(hook.live(true, -9998), lots, "the third level untouched");
    }

    /// @dev Sol's review: at a fee near 100%, an oversized fixed level's fee overflowed before its bound was checked.
    /// It is now left unfillable and the swap goes on.
    function test_regression_extremePriceWithFeeNearFull() public {
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 999_999, 10, IHooks(HOOK));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK + 20));
        claimed[0] = manager.balanceOf(HOOK, key.currency0.toId());
        claimed[1] = manager.balanceOf(HOOK, key.currency1.toId());
        hook.setLotSizes(1, 1 << 60);
        _fixed(false, TickMath.MIN_TICK + 1, uint64(1 << 50)); // 2^110 of currency1 at the lowest price
        _swapChecked(true, -1e6, MIN_LIMIT);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.specified, 0, "the level is never filled");
    }

    /// @dev Sol's review: range amounts inside a segment whose far point the walk never loaded skipped the amount
    /// bound. Near the top price, one unit of an ask range costs about 3.3e38 input, beyond the hook's int128 deltas.
    /// The book now ends at the range and the empty AMM takes the swap.
    function test_regression_rangeAmountBoundAtTopPrice() public {
        _poolAt(0, 887_000);
        _range(true, 887_000, 887_100, 1 << 96);
        _swapChecked(false, 1, TickMath.getSqrtPriceAtTick(887_001));
        _checkEndedAt(887_000);
    }

    function test_regression_rangeAmountBoundAtBottomPrice() public {
        _poolAt(0, -887_000);
        _range(false, -887_100, -887_000, 1 << 96);
        _swapChecked(true, 1, TickMath.getSqrtPriceAtTick(-887_001));
        _checkEndedAt(-887_000);
    }

    /// @dev A range up to the limit whose input, about 1.3 * 2^126, would fit int128 but not the book's bound.
    function test_regression_rangeAmountBoundBelowInt128() public {
        _rangeToLimit(480_000, 481_000);
        _checkEndedAt(480_000);
    }

    /// @dev The same over a stretch wider than one search: the book fills up to a searched word edge, within its bound.
    function test_rangeAmountBoundEndsAtAPoint() public {
        _rangeToLimit(430_000, 440_000);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.stop, BookWalk.CAP);
        assertGt(f.specified, 0);
        assertLe(f.other, BookWalk.MAX_BOOK_AMOUNT);
    }

    /// @dev Sol's review: the output side of the bound under exact input, with AMM liquidity. Near the bottom price an
    /// ask range's output across a stretch dwarfs the input: the book ends at the range and the AMM takes the swap.
    function test_rangeOutputBoundWithAmmLiquidity() public {
        _poolAt(500, -880_000);
        _lp(-880_000, -870_000, 1e15);
        _range(true, -880_000, -879_000, RangeBook.MAX_RANGE_LIQUIDITY);
        uint160 low = TickMath.getSqrtPriceAtTick(-880_000);
        uint160 limit = TickMath.getSqrtPriceAtTick(-879_500);
        assertGt(SqrtPriceMath.getAmount0Delta(low, limit, RangeBook.MAX_RANGE_LIQUIDITY, false), BookWalk.MAX_BOOK_AMOUNT);
        _swapChecked(false, -1e10, limit);
        (BookWalk.Fill memory f, AmmReplay.Result memory e) = hook.last();
        assertEq(f.stop, BookWalk.CAP);
        assertEq(f.specified, 0);
        assertGt(e.specified, 0, "the AMM took the swap");
    }

    /// @dev Sol's review: a stretch whose principal fits the bound but not with the taker fee (50%).
    function test_rangeAmountBoundWithTheFee() public {
        _poolAt(500_000, 480_000);
        uint128 liquidity = RangeBook.MAX_RANGE_LIQUIDITY;
        _range(true, 480_000, 481_500, liquidity);
        uint160 low = TickMath.getSqrtPriceAtTick(480_000);
        uint160 limit = TickMath.getSqrtPriceAtTick(480_500);
        uint256 principal = SqrtPriceMath.getAmount1Delta(low, limit, liquidity, true);
        assertLt(principal, BookWalk.MAX_BOOK_AMOUNT);
        assertGt(2 * principal, BookWalk.MAX_BOOK_AMOUNT);
        token1.mint(address(this), 1 << 128);
        _swapChecked(false, int256(SqrtPriceMath.getAmount0Delta(low, limit, liquidity, false) + 1000), limit);
        _checkEndedAt(480_000);
    }

    /// @dev Sol's review: a level fills, then an oversized range stretch from the same price ends the book there. The
    /// fill stands; the range stays unsold and blocks its side (conservatively) until it is cancelled.
    function test_levelFillsBeforeAnOversizedRangeAtTheSamePrice() public {
        _poolAt(0, 480_000);
        uint256 level = _fixed(true, 480_010, 1000);
        uint256 range = _range(true, 480_010, 482_000, RangeBook.MAX_RANGE_LIQUIDITY);
        uint160 at = TickMath.getSqrtPriceAtTick(480_010);
        uint160 limit = TickMath.getSqrtPriceAtTick(481_000);
        token1.mint(address(this), 1 << 128);
        _swapChecked(false, 5000, limit);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.stop, BookWalk.CAP);
        assertEq(f.specified, 1000, "the level filled");
        assertEq(f.frontier, at, "the book ended at the range");
        assertEq(hook.filledLots(fixedOrders[level].id), 1000);
        assertEq(hook.rangeFrontier(rangeOrders[range].id), at, "the range unsold");
        _checkSolvency();
        hook.cancelRange(rangeOrders[range].id);
        _fixed(true, 480_100, 1000);
        _swapChecked(false, 1000, limit);
        (f,) = hook.last();
        assertEq(f.specified, 1000, "after the cancel the side fills again");
    }

    /// @dev Sol's review: exact output whose last part is below one lot, where the AMM runs out of liquidity before
    /// delivering it: the AMM passes the level up to the limit. Later exact input there fills whole lots of the level
    /// first; with no AMM liquidity where the pool price stands, what is short of a lot's cost stays with the book as
    /// dust (handing it to the AMM would trade none of it and only run the price to the limit).
    function test_exactOutputShortfallPastTheAmmsLiquidity() public {
        _lp(-6000, 200, 1e13); // about 1e11 of output up to tick 200, none beyond
        hook.setLotSizes(1e12, 1e12);
        _fixed(true, 100, 10);
        _swapChecked(false, 36e11, TickMath.getSqrtPriceAtTick(1000));
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.specified, 3e12, "three whole lots");
        assertEq(hook.live(true, 100), 7);
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, TickMath.getSqrtPriceAtTick(1000), "the AMM ran out and went to the limit");
        BalanceDelta delta = _swapChecked(false, -5e12, TickMath.getSqrtPriceAtTick(3000));
        (f,) = hook.last();
        assertEq(hook.live(true, 100), 3, "four lots");
        assertEq(uint256(int256(delta.amount0())), 4e12);
        assertGt(f.dust, 0, "the rest is dust");
        assertLt(f.dust, _proceeds(true, TickMath.getSqrtPriceAtTick(100), 1e12) * 2, "below a lot's cost");
        (price,,,) = manager.getSlot0(id);
        assertEq(price, TickMath.getSqrtPriceAtTick(1000), "the price stays");
        _checkSolvency();
    }

    /// @dev Sol's review: no AMM liquidity at the pool price, but some across a gap before the limit. Exact input
    /// short of a lot's cost goes to the AMM, which crosses the gap and trades; it is not kept as dust.
    function test_regression_subLotExactInputCrossesAGap_asks() public {
        _gapCase(false);
    }

    function test_regression_subLotExactInputCrossesAGap_bids() public {
        _gapCase(true);
    }

    function _gapCase(bool zeroForOne) private {
        hook.setLotSizes(1e12, 1e12);
        if (zeroForOne) {
            _fixed(false, -100, 10);
            _lp(-3000, -1000, 1e18);
        } else {
            _fixed(true, 100, 10);
            _lp(1000, 3000, 1e18);
        }
        BalanceDelta delta =
            _swapChecked(zeroForOne, -5e11, TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-3000) : int24(3000)));
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.dust, 0, "not kept");
        assertGt(zeroForOne ? delta.amount1() : delta.amount0(), 0, "the AMM traded across the gap");
        assertEq(hook.live(!zeroForOne, zeroForOne ? int24(-100) : int24(100)), 10, "no lot filled");
    }

    /// @dev The same in catch-up: the level is behind the pool price, which sits in a gap before more liquidity.
    function test_regression_subLotExactInputCrossesAGapInCatchUp() public {
        _gapInCatchUp(false);
    }

    function test_regression_subLotExactInputCrossesAGapInCatchUp_bids() public {
        _gapInCatchUp(true);
    }

    function _gapInCatchUp(bool zeroForOne) private {
        int24 sign = zeroForOne ? int24(-1) : int24(1);
        if (zeroForOne) _lp(-200, 6000, 1e13);
        else _lp(-6000, 200, 1e13);
        _lp(sign > 0 ? int24(1500) : int24(-3000), sign > 0 ? int24(3000) : int24(-1500), 1e18);
        hook.setLotSizes(1e12, 1e12);
        _fixed(!zeroForOne, 100 * sign, 10);
        // Exact output short of a lot: the AMM runs out and stops at the limit, in the gap.
        _swapChecked(zeroForOne, 36e11, TickMath.getSqrtPriceAtTick(1000 * sign));
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, TickMath.getSqrtPriceAtTick(1000 * sign));
        BalanceDelta delta = _swapChecked(zeroForOne, -5e11, TickMath.getSqrtPriceAtTick(3000 * sign));
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.dust, 0, "not kept");
        assertGt(zeroForOne ? delta.amount1() : delta.amount0(), 0, "the AMM traded across the gap");
        assertEq(hook.live(!zeroForOne, 100 * sign), 7, "the level still behind");
    }

    /// @dev Sol's review: liquidity that starts exactly at the limit cannot trade (the swap stops there), so exact
    /// input short of a lot's cost stays as dust.
    function test_subLotExactInputWithLiquidityOnlyAtTheLimit() public {
        _subLotDust(false, 1000, 3000, 1000);
        _subLotDust(true, -3000, -1000, -1000);
    }

    /// @dev Sol's review: liquidity where the price stands that a downward swap removes by crossing that tick before
    /// moving. In catch-up (a bid level left above the pool price), with only a position [-1000, -940) at the pool's
    /// tick -1000 and nothing below, exact input short of a lot's cost stays as dust.
    function test_subLotExactInputWithLiquidityCrossedAway() public {
        _lp(-200, 6000, 1e13);
        hook.setLotSizes(1e12, 1e12);
        _fixed(false, -100, 10);
        _swapChecked(true, 36e11, TickMath.getSqrtPriceAtTick(-1000)); // exact output short of a lot: to the limit
        (, int24 tick,,) = manager.getSlot0(id);
        assertEq(tick, -1000);
        _lp(-1000, -940, 1e18);
        assertGt(manager.getLiquidity(id), 0, "liquidity where the price stands");
        BalanceDelta delta = _swapChecked(true, -5e11, TickMath.getSqrtPriceAtTick(-3000));
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.dust, 5e11, "kept as dust");
        assertEq(delta.amount1(), 0, "nothing received");
    }

    /// @dev Sol's review: the look-ahead's boundary. With one word per search, liquidity found after one empty step
    /// takes the input; liquidity two steps out counts as none.
    function test_subLotExactInputLookAheadBoundary() public {
        hook.setLimits(BookWalk.Limits(512, 128, 1, 64));
        uint256 snapshot = vm.snapshotState();
        _lp(1000, 3000, 1e18); // in the first word of the bitmap
        _subLotSwap(false, 6000);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.dust, 0, "one empty step: traded");
        vm.revertToState(snapshot);
        hook.setLimits(BookWalk.Limits(512, 128, 1, 64));
        _lp(3000, 5000, 1e18); // across a word edge
        _subLotSwap(false, 6000);
        (f,) = hook.last();
        assertGt(f.dust, 0, "two empty steps: none");
    }

    /// @dev On a fresh pool at tick 0 with this AMM position, exact input short of a lot's cost stays as dust.
    function _subLotDust(bool zeroForOne, int24 lower, int24 upper, int24 limitTick) private {
        uint256 snapshot = vm.snapshotState();
        _lp(lower, upper, 1e18);
        BalanceDelta delta = _subLotSwap(zeroForOne, limitTick);
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.dust, 5e11, "kept as dust");
        assertEq(zeroForOne ? delta.amount1() : delta.amount0(), 0, "nothing received");
        vm.revertToState(snapshot);
    }

    /// @dev A level of 1e12 lots at 100 (or -100), and exact input of about half a lot's cost.
    function _subLotSwap(bool zeroForOne, int24 limitTick) private returns (BalanceDelta) {
        hook.setLotSizes(1e12, 1e12);
        _fixed(!zeroForOne, zeroForOne ? int24(-100) : int24(100), 10);
        return _swapChecked(zeroForOne, -5e11, TickMath.getSqrtPriceAtTick(limitTick));
    }

    /// @dev Exact input worth less than one lot, with the pool price at a partly filled level: the book cannot fill
    /// a whole lot, so the AMM takes the input. (The book used to keep it as dust, and the taker received nothing.)
    function test_regression_subLotExactInputGoesToTheAmm() public {
        _subLotAtALevel(false);
    }

    function test_regression_subLotExactInputGoesToTheAmm_bids() public {
        _subLotAtALevel(true);
    }

    function _subLotAtALevel(bool zeroForOne) private {
        _lp(-6000, 6000, 1e18);
        hook.setLotSizes(1e12, 1e12);
        int24 tick = zeroForOne ? int24(-100) : int24(100);
        _fixed(!zeroForOne, tick, 1000);
        _swapChecked(zeroForOne, -55e14, _limit(zeroForOne)); // through the AMM up to the level, and part of it
        uint128 live = hook.live(!zeroForOne, tick);
        assertGt(live, 0);
        assertLt(live, 1000);
        BalanceDelta delta = _swapChecked(zeroForOne, -5e11, _limit(zeroForOne)); // about half a lot's cost
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.dust, 0);
        assertEq(zeroForOne ? delta.amount0() : delta.amount1(), -5e11, "paid the request");
        assertGt(zeroForOne ? delta.amount1() : delta.amount0(), 0, "received the AMM's output");
        assertEq(hook.live(!zeroForOne, tick), live, "no lot filled");
    }

    /// @dev Sol's review: the solvency oracle at a price whose square does not fit 256 bits, and its mirror for bids
    /// near the bottom price.
    function test_solvencyAtAWidePrice() public {
        _poolAt(500, 600_000);
        assertGt(TickMath.getSqrtPriceAtTick(600_010), type(uint128).max);
        _fixed(true, 600_010, 1000);
        _range(true, 600_020, 600_200, 1e9);
        _swapChecked(false, -1e33, MAX_LIMIT);
        assertEq(hook.live(true, 600_010), 0, "the level filled");
        _checkSolvency();
    }

    function test_solvencyAtAWidePrice_bids() public {
        _poolAt(500, -600_000);
        _fixed(false, -600_010, 1000);
        _range(false, -600_200, -600_020, 1e9);
        _swapChecked(true, -1e33, MIN_LIMIT);
        assertEq(hook.live(false, -600_010), 0, "the level filled");
        _checkSolvency();
    }

    /// @dev An ask range of the largest liquidity from `lower`, and an exact output past what it holds up to `upper`,
    /// with the limit there.
    function _rangeToLimit(int24 lower, int24 upper) private {
        _poolAt(0, lower);
        uint128 liquidity = RangeBook.MAX_RANGE_LIQUIDITY;
        _range(true, lower, upper + 1000, liquidity);
        uint160 low = TickMath.getSqrtPriceAtTick(lower);
        uint160 limit = TickMath.getSqrtPriceAtTick(upper);
        uint256 cost = SqrtPriceMath.getAmount1Delta(low, limit, liquidity, true);
        assertGt(cost, BookWalk.MAX_BOOK_AMOUNT);
        assertLt(cost, uint128(type(int128).max));
        token1.mint(address(this), 1 << 128);
        _swapChecked(false, int256(SqrtPriceMath.getAmount0Delta(low, limit, liquidity, false) + 1000), limit);
    }

    function _checkEndedAt(int24 tick) private view {
        (BookWalk.Fill memory f,) = hook.last();
        assertEq(f.stop, BookWalk.CAP);
        assertEq(f.specified, 0);
        assertEq(f.other, 0);
        assertEq(f.frontier, TickMath.getSqrtPriceAtTick(tick), "the book ends at the range");
    }

    // ---------------------------------------------------------------- brute force

    function test_bruteForce_exactInput() public {
        _bruteForce(true, PLAIN);
    }

    function test_bruteForce_exactOutput() public {
        _bruteForce(false, PLAIN);
    }

    /// @dev Sol's review: lots of three units, so levels fill in steps the request does not divide.
    function test_bruteForce_lots_exactInput() public {
        _bruteForce(true, LOTS);
    }

    function test_bruteForce_lots_exactOutput() public {
        _bruteForce(false, LOTS);
    }

    /// @dev Sol's review: a protocol fee on both pools; the book charges the combined rate.
    function test_bruteForce_protocolFee_exactInput() public {
        _bruteForce(true, PROTOCOL_FEE);
    }

    function test_bruteForce_protocolFee_exactOutput() public {
        _bruteForce(false, PROTOCOL_FEE);
    }

    /// @dev Sol's review: after earlier swaps in both directions and a cancelled level and range per side, so levels
    /// are partly filled and ranges resume from their frontiers.
    function test_bruteForce_afterFills_exactInput() public {
        _bruteForce(true, AFTER_FILLS);
    }

    function test_bruteForce_afterFills_exactOutput() public {
        _bruteForce(false, AFTER_FILLS);
    }

    /// @dev Sol's review: all three together.
    function test_bruteForce_combined_exactInput() public {
        _bruteForce(true, LOTS | PROTOCOL_FEE | AFTER_FILLS);
    }

    function test_bruteForce_combined_exactOutput() public {
        _bruteForce(false, LOTS | PROTOCOL_FEE | AFTER_FILLS);
    }

    uint256 private constant PLAIN = 0;
    uint256 private constant LOTS = 1;
    uint256 private constant PROTOCOL_FEE = 2;
    uint256 private constant AFTER_FILLS = 4;

    /// @dev Every amount from 1 to 40 (and a few larger exact inputs) against every split: the AMM side swaps for
    /// real in a hook-free twin pool, the book side comes from the test's own record of the orders.
    function _bruteForce(bool exactIn, uint256 variant) private {
        vm.pauseGasMetering();
        _twin();
        if (variant & LOTS != 0) hook.setLotSizes(3, 3);
        if (variant & PROTOCOL_FEE != 0) {
            manager.setProtocolFeeController(address(this));
            manager.setProtocolFee(key, 500 | (300 << 12));
            manager.setProtocolFee(twin, 500 | (300 << 12));
        }
        _lpBoth(-6000, 6000, 100);
        _range(true, 20, 900, 1000);
        _range(true, 150, 400, 700);
        _fixed(true, 300, 20);
        _fixed(true, 60, 7);
        _range(false, -900, -20, 1000);
        _range(false, -400, -150, 700);
        _fixed(false, -300, 20);
        _fixed(false, -60, 7);
        if (variant & AFTER_FILLS != 0) _fillAndCancel(variant & LOTS != 0 ? 3 : 1);
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
                if (exactIn) {
                    assertGe(uint256(int256(received)) + ROUNDING, best, "worse than the best split");
                } else if (feasible) {
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

    function test_gas_bookSwap() public {
        if (!vm.isIsolateMode()) vm.skip(true);
        _lp(-6000, 6000, 1e18);
        _range(true, 20, 900, 1e18);
        _range(true, 100, 500, 5e17);
        _fixedAmount(true, 300, 1e17);
        _fixedAmount(true, 150, 5e16);
        PoolKey memory plain = PoolKey(key.currency0, key.currency1, 3000, 10, IHooks(address(0)));
        manager.initialize(plain, PRICE_1);
        lpRouter.modifyLiquidity(plain, ModifyLiquidityParams(-6000, 6000, 1e18, 0), "");
        swapRouter.swap(plain, SwapParams(false, -1e17, MAX_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        _record("plain_swap");
        _swap(false, -1e17, MAX_LIMIT);
        _record("book_swap_2_ranges_2_levels");
        (BookWalk.Fill memory f,) = hook.last();
        vm.snapshotValue("BookWalkGas", "book_swap_probes", f.probes);
        vm.snapshotValue("BookWalkGas", "book_swap_points", f.points);
        vm.snapshotValue("BookWalkGas", "book_walk_plan", hook.walkGas());
        vm.snapshotValue("BookWalkGas", "book_walk_commit", hook.commitGas());
    }

    /// @dev The walk's plan and commit for books of growing size against the same swap.
    function test_gas_byBook() public {
        if (!vm.isIsolateMode()) vm.skip(true);
        _lp(-6000, 6000, 1e18);
        string[5] memory names = ["empty", "far_order", "one_level", "one_range", "range_and_level"];
        uint256 snapshot = vm.snapshotState();
        for (uint256 k; k < 5; ++k) {
            if (k == 1) _fixedAmount(true, 5000, 1e10); // nothing near the swap
            if (k == 2) _fixedAmount(true, 300, 1e17);
            if (k == 3) _range(true, 20, 900, 1e18);
            if (k == 4) {
                _range(true, 20, 900, 1e18);
                _fixedAmount(true, 300, 1e17);
            }
            _swap(false, -1e17, MAX_LIMIT);
            vm.snapshotValue("BookWalkGas", string.concat("plan_", names[k]), hook.walkGas());
            vm.snapshotValue("BookWalkGas", string.concat("commit_", names[k]), hook.commitGas());
            vm.revertToState(snapshot);
        }
    }

    function _record(string memory label) private {
        Vm.Gas memory measured = vm.lastFrameGas();
        vm.snapshotValue("BookWalkGas", string.concat(label, "_gross"), measured.gasTotalUsed);
    }

    // ---------------------------------------------------------------- checks

    /// @dev Quotes the swap, runs it, and checks it against the quote, the replay and the book.
    function _swapChecked(bool zeroForOne, int256 specified, uint160 limit) private returns (BalanceDelta delta) {
        BookHook.Quote memory q = hook.quote(key, SwapParams(zeroForOne, specified, limit));
        // The AMM's output up to the book's quoted frontier, to measure how far past it the AMM goes.
        (uint160 price,,,) = manager.getSlot0(id);
        uint256 toFrontier = _beyond(zeroForOne, q.frontier, price) ? hook.ammOutputTo(key, zeroForOne, q.frontier) : 0;
        delta = _swap(zeroForOne, specified, limit);
        _check(zeroForOne, specified < 0, delta, toFrontier);
        _checkQuote(q);
        _checkRequest(zeroForOne, specified, delta);
        _checkStart();
    }

    function _check(bool zeroForOne, bool exactIn, BalanceDelta delta, uint256 toFrontier) private {
        (BookWalk.Fill memory f, AmmReplay.Result memory e) = hook.last();
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
        // The book's start is where it stopped. When the request ran out and the AMM traded, the book left nothing
        // unfilled before the AMM's landing, except that what is below one lot of a partly filled level (exact output
        // short of a lot, or exact input short of a lot's cost) goes to the AMM, which then trades that little past
        // the level.
        assertEq(hook.start(!zeroForOne), f.frontier, "book start");
        if (f.stop == BookWalk.INSIDE && e.specified != 0 && _beyond(zeroForOne, e.sqrtPriceX96, f.frontier)) {
            // The AMM's output beyond the frontier: its whole output less what it had delivered by the frontier
            // (replayed across ticks before the swap), each step rounding once.
            uint256 past = (exactIn ? e.other : e.specified) - toFrontier;
            assertLe(past, hook.lotSize(zeroForOne ? 1 : 0) + 2, "AMM past the book by more than a lot");
        }
    }

    /// @dev The taker pays and receives exactly the book's share plus the AMM's.
    function _checkAmounts(
        bool zeroForOne,
        bool exactIn,
        BalanceDelta delta,
        BookWalk.Fill memory f,
        AmmReplay.Result memory e
    ) private pure {
        (uint256 bookIn, uint256 out) = exactIn ? (f.specified, f.other) : (f.other, f.specified);
        (uint256 ammIn, uint256 ammOut) = exactIn ? (e.specified, e.other) : (e.other, e.specified);
        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        int128 received = zeroForOne ? delta.amount1() : delta.amount0();
        assertEq(uint256(int256(-paid)), bookIn + ammIn, "taker paid");
        assertEq(uint256(int256(received)), out + ammOut, "taker received");
        assertEq(bookIn, f.principal + f.takerFee + f.dust, "input split");
    }

    /// @dev Exact input never pays more than requested, exact output never receives more; when the walk finished
    /// inside the request, it is met exactly.
    function _checkRequest(bool zeroForOne, int256 specified, BalanceDelta delta) private view {
        (BookWalk.Fill memory f,) = hook.last();
        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        int128 received = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 amount = specified < 0 ? uint256(-specified) : uint256(specified);
        uint256 met = specified < 0 ? uint256(int256(-paid)) : uint256(int256(received));
        assertLe(met, amount, "beyond the request");
        if (f.stop == BookWalk.INSIDE) {
            assertEq(met, amount, "request not met");
            // The walk sized the AMM's share as the PoolManager swapped it.
            assertEq(f.ammShare + f.specified, amount, "planned AMM share");
        }
    }

    /// @dev Inspected order by order: every fixed order with unfilled lots, and every range with unsold liquidity, lies
    /// at or beyond its side's start, so the next walk reaches it.
    function _checkStart() private view {
        for (uint256 i; i < fixedOrders.length; ++i) {
            FixedModel memory o = fixedOrders[i];
            uint160 start = hook.start(o.sell0);
            if (start == 0 || hook.fixedOrder(o.id).lots == hook.filledLots(o.id)) continue;
            uint160 price = TickMath.getSqrtPriceAtTick(o.tick);
            assertTrue(o.sell0 ? price >= start : price <= start, "a live fixed order lies before the start");
        }
        for (uint256 i; i < rangeOrders.length; ++i) {
            RangeModel memory o = rangeOrders[i];
            uint160 start = hook.start(o.sell0);
            uint160 frontier = hook.rangeFrontier(o.id);
            if (start == 0 || hook.rangeOrder(o.id).frozen != 0) continue; // cancelled: nothing left to sell
            if (frontier == TickMath.getSqrtPriceAtTick(o.sell0 ? o.upper : o.lower)) continue;
            assertTrue(o.sell0 ? frontier >= start : frontier <= start, "an unsold range lies before the start");
        }
    }

    /// @dev Quote and execution run the same code with the same limits; only the gas guard can differ.
    function _checkQuote(BookHook.Quote memory q) private view {
        (BookWalk.Fill memory f, AmmReplay.Result memory e) = hook.last();
        if (f.stop == BookWalk.GAS || hook.skipBook()) return;
        assertTrue(q.complete, "quote complete");
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(q.bookSpecified, f.specified, "quote: book specified");
        assertEq(q.bookOther, f.other, "quote: book other");
        assertEq(q.ammSpecified, e.specified, "quote: AMM specified");
        assertEq(q.ammOther, e.other, "quote: AMM other");
        assertEq(q.landing, e.sqrtPriceX96, "quote: landing");
        assertEq(q.finalPrice, price, "quote: final price");
        assertEq(q.frontier, f.frontier, "quote: frontier");
        assertEq(q.stop, f.stop, "quote: stop");
    }

    /// @dev Makers' gross entitlements (fixed fills at their price, ranges up to their frontier, rounded down) never
    /// exceed the principal takers paid, per currency; the book never pays out more than makers sold; maker fees stay
    /// within the fee-weighted principal.
    function _checkSolvency() private view {
        uint256[2] memory owed; // per input currency: makers' proceeds
        uint256[2] memory net; // per input currency: makers' net claims, x - ceil(r x) each
        uint256[2] memory sold; // per output currency: what makers delivered
        for (uint256 i; i < fixedOrders.length; ++i) {
            FixedModel memory o = fixedOrders[i];
            uint256 filled = uint256(hook.filledLots(o.id)) * hook.lotSize(o.sell0 ? 0 : 1);
            // An ask sells currency0 for currency1 at price^2; a bid the reverse.
            uint256 proceeds = _proceeds(o.sell0, TickMath.getSqrtPriceAtTick(o.tick), filled);
            owed[o.sell0 ? 1 : 0] += proceeds;
            net[o.sell0 ? 1 : 0] += proceeds - FullMath.mulDivRoundingUp(proceeds, o.fee, 1_000_000);
            sold[o.sell0 ? 0 : 1] += filled;
        }
        for (uint256 i; i < rangeOrders.length; ++i) {
            RangeModel memory o = rangeOrders[i];
            uint160 frontier = hook.rangeFrontier(o.id);
            uint160 lower = TickMath.getSqrtPriceAtTick(o.lower);
            uint160 upper = TickMath.getSqrtPriceAtTick(o.upper);
            uint256 x = o.sell0
                ? SqrtPriceMath.getAmount1Delta(lower, frontier, o.liquidity, false)
                : SqrtPriceMath.getAmount0Delta(frontier, upper, o.liquidity, false);
            owed[o.sell0 ? 1 : 0] += x;
            net[o.sell0 ? 1 : 0] += x - FullMath.mulDivRoundingUp(x, hook.rangeOrder(o.id).feePips, 1_000_000);
            sold[o.sell0 ? 0 : 1] += o.sell0
                ? SqrtPriceMath.getAmount0Delta(lower, frontier, o.liquidity, true)
                : SqrtPriceMath.getAmount1Delta(frontier, upper, o.liquidity, true);
        }
        for (uint256 c; c < 2; ++c) {
            assertLe(owed[c], hook.principal(c), "makers owed more than takers paid");
            assertLe(hook.bookOut(c), sold[c], "book paid out more than makers sold");
            assertLe(net[c] + hook.makerFees(c), hook.principal(c), "net claims plus maker fees beyond principal");
        }
    }

    /// @dev What `out` sold at sqrt price `price` earns, rounded down; the price is applied in two steps when its
    /// square would not fit.
    function _proceeds(bool sell0, uint160 price, uint256 out) private pure returns (uint256) {
        if (price <= type(uint128).max) {
            uint256 squared = uint256(price) * price;
            return sell0 ? FullMath.mulDiv(out, squared, 1 << 192) : FullMath.mulDiv(out, 1 << 192, squared);
        }
        return sell0
            ? FullMath.mulDiv(FullMath.mulDiv(out, price, 1 << 96), price, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(out, 1 << 96, price), 1 << 96, price);
    }

    // ---------------------------------------------------------------- setup helpers

    function _pool(uint24 fee) private {
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), fee, 10, IHooks(HOOK));
        id = key.toId();
        manager.initialize(key, PRICE_1);
        claimed[0] = manager.balanceOf(HOOK, key.currency0.toId());
        claimed[1] = manager.balanceOf(HOOK, key.currency1.toId());
    }

    /// @dev A pool at `tick` with no AMM liquidity.
    function _poolAt(uint24 fee, int24 tick) private {
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), fee, 10, IHooks(HOOK));
        id = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
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

    /// @dev Up to four ranges and four fixed levels per side, mirrored for bids, across bitmap word edges.
    function _randomBook(uint256 r, bool thin) private {
        uint256 ranges = r % 5;
        uint256 levels = (r >> 3) % 5;
        if (ranges + levels == 0) ranges = 1;
        for (uint256 i; i < ranges; ++i) {
            uint256 x = uint256(keccak256(abi.encode(r, "range", i)));
            int24 lower = int24(int256(x % 1200));
            int24 upper = lower + 1 + int24(int256((x >> 16) % 600));
            uint128 liquidity = uint128(thin ? 1 + (x >> 32) % 2000 : 1e15 + (x >> 32) % 2e18);
            _range(true, lower, upper, liquidity);
            _range(false, -upper, -lower, liquidity);
        }
        for (uint256 i; i < levels; ++i) {
            uint256 x = uint256(keccak256(abi.encode(r, "fixed", i)));
            int24 tick = int24(int256(x % 1500));
            uint256 amount = thin ? 1 + (x >> 16) % 100 : 1e14 + (x >> 16) % 2e17;
            _fixedAmount(true, tick, amount);
            _fixedAmount(false, -tick, amount);
        }
    }

    /// @dev More orders where the post-only rule allows, and cancellations, between swaps.
    function _placeMore(uint256 r, bool thin) private {
        (, int24 tick,,) = manager.getSlot0(id);
        if (tick < -880_000 || tick > 880_000) return; // the price ran to a limit
        _fixedAmount(true, tick + 1 + int24(int256(r % 300)), thin ? 7 : 3e16);
        _fixedAmount(false, tick - 1 - int24(int256((r >> 9) % 300)), thin ? 7 : 3e16);
        _range(true, tick + 1, tick + 50 + int24(int256((r >> 18) % 300)), thin ? 500 : 5e17);
        if (fixedOrders.length != 0) {
            FixedModel memory o = fixedOrders[(r >> 30) % fixedOrders.length];
            hook.cancelFixed(o.id);
        }
        RangeModel memory range = rangeOrders[(r >> 40) % rangeOrders.length];
        if (hook.rangeOrder(range.id).frozen == 0) hook.cancelRange(range.id);
    }

    function _books(uint128 liquidity, uint128 fixedAmount) private {
        _range(true, 20, 900, liquidity);
        _fixedAmount(true, 300, fixedAmount);
        _range(false, -900, -20, liquidity);
        _fixedAmount(false, -300, fixedAmount);
    }

    function _range(bool sell0, int24 lower, int24 upper, uint128 liquidity) private returns (uint256 i) {
        uint256 orderId = hook.placeRange(key, sell0, lower, upper, liquidity);
        rangeOrders.push(RangeModel(sell0, lower, upper, liquidity, orderId));
        i = rangeOrders.length - 1;
    }

    function _fixed(bool sell0, int24 tick, uint64 lots) private returns (uint256 i) {
        uint256 orderId = hook.placeFixed(key, sell0, tick, lots);
        fixedOrders.push(FixedModel(sell0, tick, lots, orderId, hook.makerFeePips()));
        i = fixedOrders.length - 1;
    }

    /// @dev `amount` of output at a tick, in orders of at most the per-order cap.
    function _fixedAmount(bool sell0, int24 tick, uint256 amount) private {
        uint256 lots = amount / hook.lotSize(sell0 ? 0 : 1);
        while (lots != 0) {
            uint256 part = lots < FixedBook.MAX_ORDER_LOTS ? lots : FixedBook.MAX_ORDER_LOTS;
            _fixed(sell0, tick, uint64(part));
            lots -= part;
        }
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

    function _limit(bool zeroForOne) private pure returns (uint160) {
        return zeroForOne ? MIN_LIMIT : MAX_LIMIT;
    }

    function _beyond(bool zeroForOne, uint160 a, uint160 b) private pure returns (bool) {
        return zeroForOne ? a < b : a > b;
    }

    // ---------------------------------------------------------------- independent oracle

    /// @dev The best split by brute force. Each AMM share runs as a real swap in the twin pool, reverted afterwards;
    /// the book side comes from `bookAlone`.
    /// @dev Swaps part way into each side, cancels the first level and range of each side, and moves the twin pool
    /// to the hooked pool's price so both AMMs start alike.
    function _fillAndCancel(uint256 lot) private {
        int256 amount = lot == 1 ? int256(-50) : int256(-100);
        _swapChecked(false, amount, MAX_LIMIT);
        _swapChecked(true, amount, MIN_LIMIT);
        assertGt(hook.rangeFrontier(rangeOrders[0].id), TickMath.getSqrtPriceAtTick(20), "the ask range partly sold");
        assertLt(hook.rangeFrontier(rangeOrders[2].id), TickMath.getSqrtPriceAtTick(-20), "the bid range partly sold");
        // Sol's review: a live, partly filled level on each side (the levels at 300 and -300, of 20 lots).
        for (uint256 k; k < 2; ++k) {
            uint256 live = hook.live(k == 0, k == 0 ? int24(300) : int24(-300));
            assertGt(live, 0, "the level is live");
            assertLt(live, 20, "the level is partly filled");
        }
        hook.cancelFixed(fixedOrders[1].id); // the ask at 60
        hook.cancelFixed(fixedOrders[3].id); // the bid at -60
        hook.cancelRange(rangeOrders[1].id); // the ask range [150, 400]
        hook.cancelRange(rangeOrders[3].id); // the bid range [-400, -150]
        (uint160 price,,,) = manager.getSlot0(id);
        (uint160 twinPrice,,,) = manager.getSlot0(twin.toId());
        if (twinPrice != price) {
            swapRouter.swap(
                twin, SwapParams(price < twinPrice, -1e30, price), PoolSwapTest.TestSettings(false, false), ""
            );
        }
        (twinPrice,,,) = manager.getSlot0(twin.toId());
        assertEq(twinPrice, price, "twin in step");
    }

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
    }

    /// @dev The book alone, from the test's record of a fresh book, in price order from its best price: the output
    /// for an input budget, or the input for an output and whether the book can deliver it. Written independently of
    /// BookWalk: every order's price points are visited in order, with the range liquidity active between them.
    function bookAlone(bool zeroForOne, bool exactIn, uint256 amount) external view returns (uint256, bool) {
        bool sell0 = !zeroForOne;
        (,,, uint24 lpFee) = manager.getSlot0(id);
        uint24 fee = AmmReplay.swapFee(manager, id, zeroForOne, lpFee);
        uint160[] memory points = _points(sell0);
        if (points.length == 0) return (0, exactIn || amount == 0);
        Oracle memory o = Oracle(zeroForOne, exactIn, fee, amount, 0, points[0]);
        uint256 lot = hook.lotSize(sell0 ? 0 : 1);
        for (uint256 k; k < points.length && o.left != 0; ++k) {
            o.price = points[k];
            uint256 lots = _lotsAt(sell0, o.price);
            if (lots != 0 && !_oracleFixed(o, lots, lot)) break;
            if (k + 1 == points.length) break;
            uint256 liquidity = _liquidityBetween(sell0, o.price, points[k + 1]);
            if (liquidity != 0 && !_oracleRange(o, points[k + 1], uint128(liquidity))) break;
        }
        return (o.sum, exactIn || o.left == 0);
    }

    /// @dev Every order's price points on a side, sorted in walk order, without duplicates.
    function _points(bool sell0) private view returns (uint160[] memory points) {
        uint160[] memory all = new uint160[](fixedOrders.length + 3 * rangeOrders.length);
        uint256 n;
        for (uint256 i; i < fixedOrders.length; ++i) {
            if (fixedOrders[i].sell0 == sell0) all[n++] = TickMath.getSqrtPriceAtTick(fixedOrders[i].tick);
        }
        for (uint256 i; i < rangeOrders.length; ++i) {
            if (rangeOrders[i].sell0 != sell0) continue;
            all[n++] = TickMath.getSqrtPriceAtTick(rangeOrders[i].lower);
            all[n++] = TickMath.getSqrtPriceAtTick(rangeOrders[i].upper);
            all[n++] = hook.rangeFrontier(rangeOrders[i].id); // where a partly sold range resumes
        }
        // Insertion sort in walk order: asks upward, bids downward.
        for (uint256 i = 1; i < n; ++i) {
            uint160 v = all[i];
            uint256 j = i;
            while (j != 0 && (sell0 ? all[j - 1] > v : all[j - 1] < v)) {
                all[j] = all[j - 1];
                --j;
            }
            all[j] = v;
        }
        points = new uint160[](n);
        uint256 m;
        for (uint256 i; i < n; ++i) {
            if (m == 0 || points[m - 1] != all[i]) points[m++] = all[i];
        }
        assembly ("memory-safe") {
            mstore(points, m)
        }
    }

    /// @dev The level's live lots: placed, less fills and cancellations (the FixedBook tests check those).
    function _lotsAt(bool sell0, uint160 price) private view returns (uint256) {
        if (TickMath.getSqrtPriceAtTick(TickMath.getTickAtSqrtPrice(price)) != price) return 0;
        return hook.live(sell0, TickMath.getTickAtSqrtPrice(price));
    }

    function _liquidityBetween(bool sell0, uint160 a, uint160 b) private view returns (uint256 liquidity) {
        for (uint256 i; i < rangeOrders.length; ++i) {
            RangeModel memory o = rangeOrders[i];
            if (o.sell0 != sell0 || hook.rangeOrder(o.id).frozen != 0) continue;
            // Only the unsold part: an ask from its frontier up, a bid from its frontier down.
            uint160 frontier = hook.rangeFrontier(o.id);
            uint160 lower = sell0 ? frontier : TickMath.getSqrtPriceAtTick(o.lower);
            uint160 upper = sell0 ? TickMath.getSqrtPriceAtTick(o.upper) : frontier;
            (uint160 lo, uint160 hi) = a < b ? (a, b) : (b, a);
            if (lower <= lo && hi <= upper) liquidity += o.liquidity;
        }
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
    function _oracleFixed(Oracle memory o, uint256 lots, uint256 lot) private pure returns (bool more) {
        uint256 t;
        if (o.exactIn) {
            while (t < lots && _gross(o, (t + 1) * lot) <= o.left) ++t;
            o.sum += t * lot;
            o.left -= _gross(o, t * lot);
        } else {
            t = o.left / lot < lots ? o.left / lot : lots;
            o.sum += _gross(o, t * lot);
            o.left -= t * lot;
        }
        return t == lots;
    }

    /// @dev ceil(out * price^2 / 2^192) or its inverse, plus the fee, in 512-bit arithmetic.
    function _gross(Oracle memory o, uint256 out) private pure returns (uint256) {
        if (out == 0) return 0;
        uint256 squared = uint256(o.price) * o.price;
        uint256 amountIn = o.zeroForOne
            ? FullMath.mulDivRoundingUp(out, 1 << 192, squared)
            : FullMath.mulDivRoundingUp(out, squared, 1 << 192);
        return amountIn + FullMath.mulDivRoundingUp(amountIn, o.fee, 1_000_000 - o.fee);
    }
}
