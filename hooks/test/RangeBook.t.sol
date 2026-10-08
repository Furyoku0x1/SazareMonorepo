// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {RangeBook} from "../src/libraries/RangeBook.sol";

/// @dev The range book alone: no escrow, Kernel or AMM. `sweep` is the walk a swap runs over one side.
contract RangeBookHarness {
    RangeBook.Book internal _book;

    struct Sweep {
        uint256 steps;
        uint256 area; // sum of |step price change| x range liquidity (wrapping)
        uint256 feeArea; // the same with fee-weighted liquidity
        uint256 paid; // taker input, rounded up per step
        uint256 received; // taker output, rounded down per step
        bool recorded;
    }

    function place(bool sell0, int24 lower, int24 upper, uint128 liquidity, uint24 feePips)
        external
        returns (uint256)
    {
        return RangeBook.place(_book, msg.sender, sell0, lower, upper, liquidity, feePips);
    }

    function cancel(uint256 id) external returns (uint256) {
        return RangeBook.cancel(_book, id, msg.sender);
    }

    function claim(uint256 id) external returns (uint256 proceeds, uint24 feePips) {
        return RangeBook.claim(_book, id, msg.sender);
    }

    function frontierOf(uint256 id) external view returns (uint160) {
        return RangeBook.frontierOf(_book, id);
    }

    /// @dev Begins a walk at `start` and crosses at `point`, without recording.
    function crossAt(bool sell0, uint160 start, uint160 point) external view {
        RangeBook.Side storage side = _book.sides[sell0 ? 0 : 1];
        (RangeBook.Cursor memory c,) = RangeBook.begin(side, !sell0, start);
        RangeBook.cross(side, c, point);
    }

    function bitmapWord(bool sell0, int16 word) external view returns (uint256) {
        return _book.sides[sell0 ? 0 : 1].bitmap[word];
    }

    function newestStop(bool sell0) external view returns (bool any, uint160 price) {
        RangeBook.Side storage side = _book.sides[sell0 ? 0 : 1];
        uint256 n = side.stopCount;
        if (n != 0) return (true, side.stops[n - 1].price);
    }

    /// @dev Walks one side from `start` to `target`, crossing at every point `next` returns; then commits: clears
    /// the dead boundaries it found and records the stop if anything sold (or always, with `recordAll`). Each
    /// search gets between 1 and `maxWords` bitmap words, as a walk's remaining allowance would vary.
    function sweep(bool sell0, uint160 start, uint160 target, uint256 maxWords, bool recordAll)
        external
        returns (Sweep memory s)
    {
        RangeBook.Side storage side = _book.sides[sell0 ? 0 : 1];
        (RangeBook.Cursor memory c, bool dead) = RangeBook.begin(side, !sell0, start);
        if (dead) _dead.push(TickMath.getTickAtSqrtPrice(start));
        while (c.price != target) {
            uint256 words = 1 + uint256(keccak256(abi.encode(start, target, s.steps))) % maxWords;
            (uint160 point,) = RangeBook.next(side, c, target, words);
            require(sell0 ? point > c.price && point <= target : point < c.price && point >= target, "no progress");
            _account(s, sell0, c, point);
            if (RangeBook.cross(side, c, point)) _dead.push(TickMath.getTickAtSqrtPrice(point));
        }
        for (uint256 i; i < _dead.length; ++i) {
            RangeBook.clearDead(side, _dead[i]);
        }
        delete _dead;
        if (s.paid != 0 || recordAll) {
            RangeBook.record(side, c);
            s.recorded = true;
        }
    }

    int24[] private _dead; // the dead boundaries a walk found, cleared when it commits

    /// @dev One step from the cursor to `point`: the swept integrals and the taker's amounts.
    function _account(Sweep memory s, bool sell0, RangeBook.Cursor memory c, uint160 point) private pure {
        (uint160 a, uint160 b) = sell0 ? (c.price, point) : (point, c.price);
        unchecked {
            s.area += uint256(b - a) * c.liquidity;
            s.feeArea += uint256(b - a) * c.feeLiquidity;
        }
        ++s.steps;
        if (c.liquidity == 0) return;
        uint128 l = uint128(c.liquidity);
        if (sell0) {
            s.paid += SqrtPriceMath.getAmount1Delta(a, b, l, true);
            s.received += SqrtPriceMath.getAmount0Delta(a, b, l, false);
        } else {
            s.paid += SqrtPriceMath.getAmount0Delta(a, b, l, true);
            s.received += SqrtPriceMath.getAmount1Delta(a, b, l, false);
        }
    }
}

contract RangeBookTest is Test {
    /// @dev The independent model: each range's frontier is the running furthest stop on its side since it was
    /// placed, clamped to the range, frozen on cancellation.
    struct Model {
        bool sell0;
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint24 fee;
        bool cancelled;
        uint160 frontier;
        uint256 claimed;
    }

    /// @dev What a fuzz run varies.
    struct Mode {
        bool oneWord; // one bitmap word per search: walks stop at word edges
        bool recordAll; // record every stop, not only stops that sold something
        bool sameLiquidity; // equal liquidity: nets cancel where a range ends and the next starts
        bool sameFee;
        bool bigLiquidity; // up to MAX_RANGE_LIQUIDITY
    }

    int24 private constant LO = -700; // ticks used: across bitmap word edges at -512, -256, 0, 256 and 512
    int24 private constant HI = 700;

    RangeBookHarness private book;
    Model[] private ranges;
    uint256[] private ids;
    Mode private mode;
    uint160 private market; // the AMM price
    /// @dev Per side, where the book last stopped, pulled back by placements: no unsold range lies before it.
    /// 0 until the side's first walk or placement.
    uint160[2] private cursor;
    /// @dev Book backing per side: [0] the currency the side sells, [1] the currency it earns.
    uint256[2][2] private vault;
    uint256[2] private roundings; // each may leave at most one unit behind
    bool private lastSide;

    function setUp() public {
        book = new RangeBookHarness();
        market = TickMath.getSqrtPriceAtTick(0);
    }

    /// @dev Random placements, cancellations, claims and walks on both sides, including walks that stop behind
    /// the AMM price and catch up later, and swaps whose book callback was skipped. Every walk's swept liquidity
    /// and fee-weighted liquidity must equal exactly what the model's frontiers moved, every frontier must match
    /// after each walk, and the backing must cover every payout, leaving at most rounding dust once everything is
    /// cancelled and claimed.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_matchesFrontierModel(uint256 seed) public {
        vm.pauseGasMetering();
        mode = Mode(seed & 1 == 1, (seed >> 1) & 1 == 1, (seed >> 2) & 1 == 1, (seed >> 3) & 1 == 1, (seed >> 4) & 1 == 1);
        for (uint256 step; step < 160; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 20;
            if (op < 7) _placeRandom(r >> 8);
            else if (op < 10 && ranges.length != 0) _cancel((r >> 8) % ranges.length);
            else if (op < 12 && ranges.length != 0) _claim((r >> 8) % ranges.length);
            else if (op == 19) _skipBook(r >> 8);
            else if (op >= 12) _sweepRandom(op < 15 ? lastSide : !lastSide, r >> 8); // runs of one side catch up
        }
        _closeAll();
    }

    /// @dev The design document's worked case, in ticks: A sells [10, 100); the book stops at 50; the price
    /// falls back; B sells [5, 30); a walk to 70 must skip A's dead start and resume A at 50.
    function test_workedCase() public {
        uint256 a = _place(true, 10, 100, 1e18, 3000);
        _sweepTo(true, _p(50));
        _sweepTo(false, _p(0));
        uint256 b = _place(true, 5, 30, 2e18, 500);
        _sweepTo(true, _p(70));
        assertEq(book.frontierOf(ids[a]), _p(70), "A resumed at 50");
        assertEq(book.frontierOf(ids[b]), _p(30), "B sold out");
        _closeAll();
    }

    /// @dev The price returns exactly to a stop and a range starts there: the walk applies the stop's G and
    /// the new boundary at its start. Cancelled once touched and once untouched.
    function test_rangeAtWalkStart() public {
        uint256 a = _place(true, 10, 40, 1e18, 3000);
        _sweepTo(true, _p(20));
        uint256 b = _place(true, 20, 30, 3e18, 500);
        uint256 c = _place(true, 20, 35, 5e18, 3000);
        _cancel(c); // untouched: both boundaries removed
        _sweepTo(true, _p(25));
        assertEq(book.frontierOf(ids[b]), _p(25), "B sold from its start");
        _cancel(b); // touched: removed from the stop's G
        _sweepTo(true, _p(45));
        assertEq(book.frontierOf(ids[a]), _p(40), "A sold out");
        _closeAll();
    }

    /// @dev A walk past a range's end with nothing else open records a stop with G = 0; the range's claim
    /// depends on it, also after a newer, nearer stop.
    function test_zeroGStopKeepsClaims() public {
        uint256 a = _place(true, 10, 20, 1e18, 3000);
        _sweepTo(true, _p(30));
        (bool any, uint160 newest) = book.newestStop(true);
        assertTrue(any && newest == _p(30), "stop recorded");
        _claim(a);
        _sweepTo(false, _p(0));
        _place(true, 5, 15, 1e18, 3000);
        _sweepTo(true, _p(12));
        assertEq(book.frontierOf(ids[a]), _p(20), "A still sold out");
        _sweepTo(true, _p(40));
        _closeAll();
    }

    /// @dev The book stops behind the AMM (gas allowance), a range is placed beyond the book's stop, and the
    /// next walk catches up from the stop. Asks, then bids.
    function test_catchUpBothSides() public {
        uint256 a = _place(true, 10, 50, 1e18, 3000);
        _sweep(true, _p(20), _p(40) + 12345);
        uint256 b = _place(true, 41, 60, 2e18, 500);
        _sweepTo(true, _p(30)); // still behind: the AMM stays put
        assertEq(market, _p(40) + 12345, "AMM unchanged");
        _sweepTo(true, _p(55));
        assertEq(book.frontierOf(ids[a]), _p(50), "A sold out");
        assertEq(book.frontierOf(ids[b]), _p(55), "B from its start");

        uint256 c = _place(false, -50, -10, 1e18, 3000);
        _sweep(false, _p(-20), _p(-40) - 999);
        uint256 d = _place(false, -60, -41, 2e18, 500);
        _sweepTo(false, _p(-55));
        assertEq(book.frontierOf(ids[c]), _p(-50), "C sold out");
        assertEq(book.frontierOf(ids[d]), _p(-55), "D from its start");
        _closeAll();
    }

    /// @dev One range ends where the next starts: equal liquidity and fee cancel to nothing; equal liquidity
    /// and different fees leave a boundary with zero net and a fee-weighted change.
    function test_sharedBoundaries() public {
        _sharedBoundaries(true);
        _sharedBoundaries(false);
        _closeAll();
    }

    function _sharedBoundaries(bool sell0) private {
        _placeMirrored(sell0, 10, 20, 3000);
        _placeMirrored(sell0, 20, 30, 3000);
        _placeMirrored(sell0, 40, 50, 3000);
        uint256 d = _placeMirrored(sell0, 50, 60, 500);
        _sweepTo(sell0, _p(sell0 ? int24(55) : -55));
        _cancel(d);
        _placeMirrored(sell0, 60, 70, 500);
        _sweepTo(sell0, _p(sell0 ? int24(80) : -80));
        _sweepTo(!sell0, _p(0));
    }

    /// @dev Asks at [from, to); bids at the mirror image [-to, -from), sold from -from downward.
    function _placeMirrored(bool sell0, int24 from, int24 to, uint24 fee) private returns (uint256) {
        return sell0 ? _place(true, from, to, 1e18, fee) : _place(false, -to, -from, 1e18, fee);
    }

    /// @dev A stop exactly at a range's start (nothing sold), at its end (sold out, then the shared boundary
    /// is rewritten by a new range), and a frontier stop replaced by a later one through truncation; each
    /// range then cancelled.
    function test_stopsAtEndpointsThenCancel() public {
        uint256 a = _place(true, 10, 20, 1e18, 3000);
        _sweepTo(true, _p(10)); // A touched, nothing sold
        assertEq(book.frontierOf(ids[a]), _p(10), "A at its start");
        _cancel(a); // full refund, removed from the stop's G

        uint256 b = _place(true, 30, 40, 1e18, 3000);
        _sweepTo(true, _p(40)); // B sold out exactly
        uint256 c = _place(true, 40, 60, 2e18, 500); // writes over B's dead end
        _cancel(b);
        _sweepTo(true, _p(45));
        _sweepTo(false, _p(0));
        _place(true, 5, 15, 1e18, 3000);
        _sweepTo(true, _p(12)); // stops [45, 12]
        _sweepTo(true, _p(50)); // truncates both; C's frontier now set by the stop at 50
        assertEq(book.frontierOf(ids[c]), _p(50), "C after truncation");
        _cancel(c);
        _sweepTo(true, _p(70));
        _closeAll();
    }

    /// @dev Ranges at the extreme ticks: an ask up to MAX_TICK walked to just below the maximum price, a bid
    /// from MIN_TICK walked to the minimum price.
    function test_extremeTicks() public {
        int24 maxTick = TickMath.MAX_TICK;
        int24 minTick = TickMath.MIN_TICK;
        uint256 a = _place(true, maxTick - 10, maxTick, 1e18, type(uint24).max);
        uint256 b = _place(false, minTick, minTick + 10, 1e18, type(uint24).max);
        _sweepTo(true, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(book.frontierOf(ids[a]), TickMath.MAX_SQRT_PRICE - 1, "ask up to the maximum price");
        _sweepTo(false, TickMath.MIN_SQRT_PRICE);
        assertEq(book.frontierOf(ids[b]), TickMath.MIN_SQRT_PRICE, "bid sold out");
        _claim(a);
        _cancel(a);
        _cancel(b);
        _claim(b);
    }

    /// @dev Events at the cursor are applied once: crossing at the current price reverts.
    function test_crossMustAdvance() public {
        _place(true, 10, 20, 1e18, 3000);
        vm.expectRevert(RangeBook.NoProgress.selector);
        book.crossAt(true, _p(10), _p(10));
        vm.expectRevert(RangeBook.NoProgress.selector);
        book.crossAt(false, _p(10), _p(11));
        book.crossAt(true, _p(10), _p(11));
    }

    /// @dev One bitmap word per search, ranges across word edges, and a stop exactly on a word's last tick
    /// ahead of the walk.
    function test_wordEdges() public {
        mode.oneWord = true;
        _place(true, 250, 260, 1e18, 3000);
        _place(false, -260, -250, 1e18, 3000);
        _sweepTo(true, _p(255)); // stop on word 0's last tick
        _sweepTo(false, _p(50));
        _place(true, 60, 70, 1e18, 3000);
        _sweepTo(true, _p(100)); // stops [255, 100]
        _sweepTo(true, _p(300)); // passes the dead start at 250, then the stop at 255 with nothing else in the word
        _sweepTo(false, _p(-300));
        _closeAll();
    }

    function test_onlyOwnerCancelsAndClaims() public {
        uint256 i = _place(true, 10, 20, 1e18, 3000);
        vm.startPrank(address(0xBEEF));
        vm.expectRevert(RangeBook.NotOwner.selector);
        book.cancel(ids[i]);
        vm.expectRevert(RangeBook.NotOwner.selector);
        book.claim(ids[i]);
        vm.stopPrank();
        _cancel(i);
        assertEq(book.cancel(ids[i]), 0, "second cancel refunds nothing");
    }

    function test_rejectsInvalidRanges() public {
        vm.expectRevert(RangeBook.InvalidRange.selector);
        book.place(true, 10, 10, 1, 0);
        vm.expectRevert(RangeBook.InvalidRange.selector);
        book.place(true, TickMath.MIN_TICK - 1, 0, 1, 0);
        vm.expectRevert(RangeBook.InvalidRange.selector);
        book.place(false, 0, TickMath.MAX_TICK + 1, 1, 0);
        vm.expectRevert(RangeBook.InvalidAmount.selector);
        book.place(true, 0, 1, 0, 0);
        vm.expectRevert(RangeBook.InvalidAmount.selector);
        book.place(true, 0, 1, RangeBook.MAX_RANGE_LIQUIDITY + 1, 0);
    }

    // ---------------------------------------------------------------- operations with model checks

    function _place(bool sell0, int24 lower, int24 upper, uint128 liquidity, uint24 fee) private returns (uint256 i) {
        // Post-only: asks at or above the AMM price, bids at or below it.
        if (sell0) require(_p(lower) >= market, "ask below market");
        else require(_p(upper) <= market, "bid above market");
        ids.push(book.place(sell0, lower, upper, liquidity, fee));
        // A placement before the side's cursor pulls it back, so the next walk starts at or before the range.
        uint160 near = _p(sell0 ? lower : upper);
        uint160 current = cursor[sell0 ? 0 : 1];
        if (current == 0 || (sell0 ? near < current : near > current)) cursor[sell0 ? 0 : 1] = near;
        ranges.push(Model(sell0, lower, upper, liquidity, fee, false, _p(sell0 ? lower : upper), 0));
        i = ranges.length - 1;
        uint256 k = sell0 ? 0 : 1;
        vault[k][0] += sell0
            ? SqrtPriceMath.getAmount0Delta(_p(lower), _p(upper), liquidity, true)
            : SqrtPriceMath.getAmount1Delta(_p(lower), _p(upper), liquidity, true);
        roundings[k] += 2;
        assertEq(book.frontierOf(ids[i]), ranges[i].frontier, "new frontier");
    }

    function _cancel(uint256 i) private {
        Model storage m = ranges[i];
        uint256 refund = book.cancel(ids[i]);
        if (m.cancelled) {
            assertEq(refund, 0, "second cancel");
        } else {
            uint256 expected = m.sell0
                ? SqrtPriceMath.getAmount0Delta(m.frontier, _p(m.upper), m.liquidity, false)
                : SqrtPriceMath.getAmount1Delta(_p(m.lower), m.frontier, m.liquidity, false);
            assertEq(refund, expected, "refund");
            m.cancelled = true;
            vault[m.sell0 ? 0 : 1][0] -= refund;
        }
        assertEq(book.frontierOf(ids[i]), m.frontier, "frozen frontier");
    }

    function _claim(uint256 i) private {
        Model storage m = ranges[i];
        (uint256 proceeds, uint24 fee) = book.claim(ids[i]);
        uint256 total = m.sell0
            ? SqrtPriceMath.getAmount1Delta(_p(m.lower), m.frontier, m.liquidity, false)
            : SqrtPriceMath.getAmount0Delta(m.frontier, _p(m.upper), m.liquidity, false);
        assertEq(proceeds, total - m.claimed, "proceeds");
        assertEq(fee, m.fee, "fee");
        m.claimed = total;
        vault[m.sell0 ? 0 : 1][1] -= proceeds;
    }

    /// @dev A swap's walk over one side to `target`; the AMM ends at `marketAfter` (beyond `target` when the
    /// book stopped early, unchanged while the book is still catching up).
    function _sweep(bool sell0, uint160 target, uint160 marketAfter) private {
        RangeBookHarness.Sweep memory s =
            book.sweep(sell0, _start(sell0), target, mode.oneWord ? 1 : 8, mode.recordAll);
        cursor[sell0 ? 0 : 1] = target;
        (uint256 area, uint256 feeArea) = s.recorded ? _advance(sell0, target) : (0, 0);
        assertEq(s.area, area, "liquidity swept");
        assertEq(s.feeArea, feeArea, "fee-weighted liquidity swept");
        uint256 k = sell0 ? 0 : 1;
        vault[k][0] -= s.received;
        vault[k][1] += s.paid;
        roundings[k] += s.steps;
        market = marketAfter;
        for (uint256 i; i < ranges.length; ++i) {
            assertEq(book.frontierOf(ids[i]), ranges[i].frontier, "frontier");
        }
    }

    /// @dev A complete walk: the AMM lands where the book stops, unless the book is still behind it.
    function _sweepTo(bool sell0, uint160 target) private {
        bool ahead = sell0 ? target > market : target < market;
        _sweep(sell0, target, ahead ? target : market);
    }

    /// @dev Model: a stop moves every open range on its side whose frontier it passes.
    function _advance(bool sell0, uint160 stop) private returns (uint256 area, uint256 feeArea) {
        for (uint256 i; i < ranges.length; ++i) {
            Model storage m = ranges[i];
            if (m.sell0 != sell0 || m.cancelled) continue;
            uint160 f = m.frontier;
            if (sell0 ? stop <= f : stop >= f) continue;
            uint160 far = _p(sell0 ? m.upper : m.lower);
            uint160 nf = (sell0 ? stop > far : stop < far) ? far : stop;
            uint256 d = sell0 ? nf - f : f - nf;
            unchecked {
                area += d * m.liquidity;
                feeArea += d * m.liquidity * m.fee;
            }
            m.frontier = nf;
        }
    }

    /// @dev Cancels and claims everything; walks across each side find nothing and clear every boundary left
    /// behind; the backing covered every payout and keeps only rounding dust.
    function _closeAll() private {
        for (uint256 i; i < ranges.length; ++i) {
            if (!ranges[i].cancelled) _cancel(i);
            _claim(i);
        }
        _sweepTo(false, _min(_start(false), _p(LO))); // the AMM to the bottom, so the asks walk covers everything
        _sweepTo(true, _max(_start(true), _p(HI + 1)));
        _sweepTo(false, _min(_start(false), _p(LO)));
        for (int16 w = -3; w <= 2; ++w) {
            assertEq(book.bitmapWord(true, w), 0, "ask boundaries cleared");
            assertEq(book.bitmapWord(false, w), 0, "bid boundaries cleared");
        }
        for (uint256 k; k < 2; ++k) {
            assertLe(vault[k][0], roundings[k], "sold currency dust");
            assertLe(vault[k][1], roundings[k], "earned currency dust");
        }
    }

    // ---------------------------------------------------------------- random operations

    function _placeRandom(uint256 r) private {
        bool sell0 = r & 1 == 1;
        int24 width = int24(int256(1 + (r >> 8) % 40));
        int24 edge = sell0 ? _ceilTick(market) : TickMath.getTickAtSqrtPrice(market); // post-only limit
        int24 near = sell0 ? edge + int24(int256((r >> 16) % 60)) : edge - int24(int256((r >> 16) % 60));
        uint256 pick = (r >> 24) % 4;
        if (pick == 0 && ranges.length != 0) {
            // Start where another range on this side ends.
            Model storage o = ranges[(r >> 32) % ranges.length];
            if (o.sell0 == sell0) near = sell0 ? o.upper : o.lower;
        } else if (pick == 1) {
            // Start exactly at the side's newest stop.
            (bool any, uint160 p) = book.newestStop(sell0);
            int24 t = TickMath.getTickAtSqrtPrice(any ? p : market);
            if (any && _p(t) == p) near = t;
        }
        if (sell0 ? near < edge : near > edge) return;
        (int24 lower, int24 upper) = sell0 ? (near, near + width) : (near - width, near);
        if (lower < LO || upper > HI) return;
        (uint128 liquidity, uint24 fee) = _size(r >> 40);
        _place(sell0, lower, upper, liquidity, fee);
    }

    function _size(uint256 r) private view returns (uint128 liquidity, uint24 fee) {
        if (mode.sameLiquidity) liquidity = 1e18;
        else if (mode.bigLiquidity) liquidity = uint128(1 + (r >> 24) % RangeBook.MAX_RANGE_LIQUIDITY);
        else if (r % 3 == 0) liquidity = uint128(1 + (r >> 24) % 1000);
        else liquidity = uint128(1 + (r >> 24) % 1e20);
        uint24[4] memory fees = [uint24(0), 500, 3000, type(uint24).max];
        fee = mode.sameFee ? 3000 : fees[(r >> 8) % 4];
    }

    /// @dev A swap whose book callback was skipped: the AMM moves anywhere, no walk runs, the cursors stay.
    function _skipBook(uint256 r) private {
        market = _priceIn(r >> 16, LO + int24(int256(r % uint256(int256(HI - LO)))));
    }

    function _sweepRandom(bool sell0, uint256 r) private {
        lastSide = sell0;
        uint160 start = _start(sell0);
        int24 t = TickMath.getTickAtSqrtPrice(start);
        int24 d = int24(int256(r % 50));
        int24 tt = sell0 ? t + d : t - d;
        if (tt > HI) tt = HI;
        if (tt < LO) tt = LO;
        uint160 target = _priceIn(r >> 8, tt);
        if (sell0 ? target < start : target > start) target = start;
        bool ahead = sell0 ? target > market : target < market;
        uint160 marketAfter = ahead ? target : market;
        if (ahead && (r >> 72) % 4 == 0) {
            // The book stopped early; the AMM went further.
            int24 extra = int24(int256(1 + (r >> 80) % 30));
            int24 mt = TickMath.getTickAtSqrtPrice(target);
            mt = sell0 ? mt + extra : mt - extra;
            if (mt <= HI && mt >= LO) {
                uint160 p = _priceIn(r >> 96, mt);
                if (sell0 ? p > target : p < target) marketAfter = p;
            }
        }
        _sweep(sell0, target, marketAfter);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Where a walk starts: the AMM price, or the side's cursor if the book is behind it.
    function _start(bool sell0) private view returns (uint160) {
        uint160 p = cursor[sell0 ? 0 : 1];
        if (p == 0) return market;
        return sell0 ? (p < market ? p : market) : (p > market ? p : market);
    }

    /// @dev A tick's price, or a price strictly inside the tick.
    function _priceIn(uint256 r, int24 tick) private pure returns (uint160) {
        uint160 p = _p(tick);
        if (r & 1 == 0) return p;
        return p + 1 + uint160((r >> 1) % (_p(tick + 1) - p - 1));
    }

    function _min(uint160 a, uint160 b) private pure returns (uint160) {
        return a < b ? a : b;
    }

    function _max(uint160 a, uint160 b) private pure returns (uint160) {
        return a > b ? a : b;
    }

    function _ceilTick(uint160 price) private pure returns (int24 t) {
        t = TickMath.getTickAtSqrtPrice(price);
        if (_p(t) != price) ++t;
    }

    function _p(int24 tick) private pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }
}
