// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ChargeStart, Position, PricePoint, Vault} from "../../src/metric/vault/VaultTypes.sol";
import {RealizedCharge} from "../../src/metric/vault/libraries/RealizedCharge.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {MockPriceSource} from "./utils/VaultFixture.sol";

/// @notice One vault's price record and one position, driven directly, so the trees can be checked against the
/// realized charge computed interval by interval.
contract ChargeHarness {
    Vault internal vault;
    Position internal position;
    ChargeStart internal start;

    constructor(address source, uint16 transformationRateBps) {
        vault.parameters.priceSource = source;
        vault.parameters.transformationRateBps = transformationRateBps;
    }

    /// @dev A position on `[tickLower, tickUpper)` that released token1, token0 or both, started at the mid now.
    function open(int24 tickLower, int24 tickUpper, uint128 liquidity, bool lent1, bool lent0) external {
        position.tickLower = tickLower;
        position.tickUpper = tickUpper;
        position.liquidity = liquidity;
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(tickLower, tickUpper);
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        position.maximum0 = uint128(maximum0);
        position.maximum1 = uint128(maximum1);
        position.released1 = lent1 ? 1 : 0;
        position.released0 = lent0 ? 1 : 0;
        (bool priced, uint160 sqrtMidX96) = RealizedCharge.mid(vault);
        require(priced, "no price");
        RealizedCharge.start(vault, position, start, sqrtMidX96);
    }

    function record() external returns (bool) {
        return RealizedCharge.record(vault, 1);
    }

    /// @dev What a settlement charges now, then moves the start as `VaultBook.collect` does.
    function settle() external returns (uint256 owedWad) {
        owedWad = RealizedCharge.owedWad(vault, position, start);
        RealizedCharge.restart(vault, position, start);
    }

    function owed() external view returns (uint256) {
        return RealizedCharge.owedWad(vault, position, start);
    }

    function stub(uint160 sqrtNowX96) external view returns (uint256) {
        return RealizedCharge.stubWad(vault, position, start, sqrtNowX96);
    }

    function point(uint256 index) external view returns (PricePoint memory) {
        return vault.prices.points[index];
    }

    function count() external view returns (uint256) {
        return vault.prices.count;
    }

    function sigma() external view returns (uint256) {
        return RealizedCharge.sigmaWad(vault);
    }

    function startOf() external view returns (ChargeStart memory) {
        return start;
    }

    function maximum1() external view returns (uint256) {
        return position.maximum1;
    }
}

/// @notice The realized charge and the transformation rate against a direct, interval-by-interval computation
/// (hooks/docs/metric-lender-hedge-spec.md, sections 4.2–4.3 and 11): the trees must give each position exactly
/// `Σ ℓ` over its own path, from its start's price, through settlements that move the start, and the rent for the
/// time it spent past its range on a side it lent from.
contract RealizedChargeTest is Test {
    int24 internal constant PRICE_TICK = -200_311;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 1 << 96;
    /// @dev Points on one path, at most; enough to cross ranges both ways several times.
    uint256 internal constant MAX_POINTS = 14;

    MockPriceSource internal source;

    function setUp() public {
        source = new MockPriceSource();
        _price(PRICE_TICK);
    }

    /// @dev A fuzzed range below, across or above a fuzzed hourly path, opened inside the first interval and settled
    /// at random points: the charge equals `Σ ℓ` over the position's own path to a few units of token1 per interval.
    function testFuzz_realizedCharge_equalsTheSumOfIntervals(uint256 seed) public {
        ChargeHarness harness = new ChargeHarness(address(source), 0);
        (int24 tickLower, int24 tickUpper) = _range(seed);
        uint128 liquidity = _liquidity(tickLower, tickUpper);
        assertTrue(harness.record(), "the first point");
        vm.warp(block.timestamp + bound(uint256(keccak256(abi.encode(seed, "open"))), 0, 59 minutes));
        uint160 sqrtPreviousX96 = _price(_tick(seed, 0));
        harness.open(tickLower, tickUpper, liquidity, true, false);
        uint256 points = bound(seed % 1_000, 4, MAX_POINTS);
        int256 expected;
        uint256 chargedWad;
        // points <= MAX_POINTS; point 0 is at time 1, each next an hour on
        for (uint256 index = 1; index <= points; ++index) {
            vm.warp(1 + index * 1 hours);
            uint160 sqrtCurrentX96 = _price(_tick(seed, index));
            assertTrue(harness.record(), "an hourly point");
            expected += _ell(liquidity, tickLower, tickUpper, sqrtPreviousX96, sqrtCurrentX96);
            sqrtPreviousX96 = sqrtCurrentX96;
            if (uint256(keccak256(abi.encode(seed, index))) % 3 == 0) chargedWad += harness.settle();
        }
        chargedWad += harness.settle();
        assertApproxEqAbs(chargedWad / WAD, _atLeastZero(expected), 3 * points + 3, "trees against direct intervals");
        assertEq(harness.owed(), 0, "nothing more without a new point");
    }

    /// @dev Between points, a close's stub is the one interval from the settled start to the price now.
    function testFuzz_stub_isOneInterval(uint256 seed) public {
        ChargeHarness harness = new ChargeHarness(address(source), 0);
        (int24 tickLower, int24 tickUpper) = _range(seed);
        uint128 liquidity = _liquidity(tickLower, tickUpper);
        harness.record();
        uint160 sqrtOpenX96 = _price(_tick(seed, 0));
        harness.open(tickLower, tickUpper, liquidity, true, false);
        vm.warp(block.timestamp + 30 minutes);
        uint160 sqrtCloseX96 = TickMath.getSqrtPriceAtTick(_tick(seed, 1));
        int256 expected = _ell(liquidity, tickLower, tickUpper, sqrtOpenX96, sqrtCloseX96);
        assertApproxEqAbs(harness.stub(sqrtCloseX96) / WAD, _atLeastZero(expected), 3, "the stub from the open");
        vm.warp(block.timestamp + 1 hours);
        uint160 sqrtPointX96 = _price(_tick(seed, 2));
        harness.record();
        expected = _ell(liquidity, tickLower, tickUpper, sqrtPointX96, sqrtCloseX96);
        assertApproxEqAbs(harness.stub(sqrtCloseX96) / WAD, _atLeastZero(expected), 3, "the stub from the last point");
    }

    /// @dev A settlement with no point since the start charges nothing and leaves the start where it was.
    function test_settle_withNoNewPointKeepsTheStart() public {
        ChargeHarness harness = new ChargeHarness(address(source), 0);
        harness.record();
        vm.warp(block.timestamp + 10 minutes);
        _price(PRICE_TICK - 50);
        harness.open(PRICE_TICK - 300, PRICE_TICK - 10, _liquidity(PRICE_TICK - 300, PRICE_TICK - 10), true, false);
        ChargeStart memory before = harness.startOf();
        vm.warp(block.timestamp + 20 minutes);
        _price(PRICE_TICK - 200);
        assertFalse(harness.record(), "under an hour since the last point");
        assertEq(harness.settle(), 0, "no charge");
        ChargeStart memory after_ = harness.startOf();
        assertEq(after_.sqrtPriceX96, before.sqrtPriceX96, "the start's price stays");
        assertEq(after_.startedAt, before.startedAt, "the start's time stays");
    }

    /// @dev The transformation rate: a range that lent token1 pays `k·σ` on `M1` for exactly the time it spent below
    /// its lower end, counted from its own open inside the first interval, and nothing while above or inside it.
    function testFuzz_transformationRate_rentsOnlyTheTimePastTheRange(uint256 seed) public {
        ChargeHarness harness = new ChargeHarness(address(source), 20_000);
        int24 tickLower = PRICE_TICK - 400;
        int24 tickUpper = PRICE_TICK - 100;
        uint128 liquidity = _liquidity(tickLower, tickUpper);
        harness.record();
        uint256 opensAt = block.timestamp + bound(uint256(keccak256(abi.encode(seed, "open"))), 0, 59 minutes);
        vm.warp(opensAt);
        uint160 sqrtPreviousX96 = _price(bound(seed, 0, 1) == 0 ? PRICE_TICK - 600 : PRICE_TICK);
        harness.open(tickLower, tickUpper, liquidity, true, false);
        uint256 rentBpsSeconds;
        uint256 fromTimestamp = opensAt;
        uint256 points = bound(seed % 1_000, 3, MAX_POINTS);
        // points <= MAX_POINTS
        for (uint256 index = 1; index <= points; ++index) {
            vm.warp(1 + index * 1 hours);
            if (sqrtPreviousX96 < TickMath.getSqrtPriceAtTick(tickLower)) {
                uint256 rateBps = harness.point(index - 1).rentRateBps;
                rentBpsSeconds += rateBps * (vm.getBlockTimestamp() - fromTimestamp);
            }
            fromTimestamp = vm.getBlockTimestamp();
            bool below = uint256(keccak256(abi.encode(seed, index))) % 2 == 0;
            sqrtPreviousX96 = _price(below ? PRICE_TICK - 600 : PRICE_TICK);
            harness.record();
        }
        uint256 rentWad = FullMath.mulDiv(harness.maximum1(), rentBpsSeconds * WAD, 10_000 * 365 days);
        uint256 lossWad = harness.owed() - _owedWithoutRent(seed, points, opensAt);
        assertApproxEqAbs(lossWad, rentWad, 1e12, "rent for the time below the range only");
    }

    /// @dev The oracle: a flat price decays σ to the 30% floor, and a steady 1% move every hour gives about 1% times
    /// √(hours in a year).
    function test_oracle_flatFloorAndSteadyMove() public {
        ChargeHarness flat = new ChargeHarness(address(source), 0);
        flat.record();
        // 2,000 hourly points
        for (uint256 hour = 1; hour <= 2_000; ++hour) {
            vm.warp(1 + hour * 1 hours);
            flat.record();
        }
        assertEq(flat.sigma(), RealizedCharge.MIN_SIGMA_WAD, "flat: the floor");

        ChargeHarness steady = new ChargeHarness(address(source), 0);
        uint256 begin = vm.getBlockTimestamp();
        steady.record();
        // 400 hourly points, alternating 1% up and down in price
        for (uint256 hour = 1; hour <= 400; ++hour) {
            vm.warp(begin + hour * 1 hours);
            _price(hour % 2 == 0 ? PRICE_TICK : PRICE_TICK + 100);
            steady.record();
        }
        // ln(1.0001^100) ≈ 1.0%, so σ ≈ 0.01 · √8760 ≈ 93.6%; the slow average still remembers its 60% start.
        assertApproxEqRel(steady.sigma(), 0.936e18, 0.03e18, "steady: about 94% a year");
    }

    /// @dev One wild print counts at most `MAX_SAMPLE_MULTIPLE` times the slow average: a 20% jump in an hour, a
    /// yearly variance near 350 alone, moves the fast average from 0.36 to about 0.49 (σ about 70%), not to about 14.
    function test_oracle_capsOneWildPrint() public {
        ChargeHarness harness = new ChargeHarness(address(source), 0);
        harness.record();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        // 1,823 ticks is about a 20% rise in price.
        _price(PRICE_TICK + 1_823);
        harness.record();
        assertApproxEqRel(harness.sigma(), 0.6997e18, 0.01e18, "capped at ten times the slow average");
    }

    /// @dev After a long calm the slow average is near zero; the cap stands on the floor's variance instead, so six
    /// hours of 5% moves still lift σ above the floor (to about 44%), where a cap on the decayed average alone would
    /// leave it at 30% through a crash.
    function test_oracle_crashAfterALongCalmStillCounts() public {
        ChargeHarness harness = new ChargeHarness(address(source), 0);
        harness.record();
        // 2,000 flat hourly points
        for (uint256 hour = 1; hour <= 2_000; ++hour) {
            vm.warp(1 + hour * 1 hours);
            harness.record();
        }
        assertEq(harness.sigma(), RealizedCharge.MIN_SIGMA_WAD, "calm: the floor");
        // 6 hourly points, each about 5% from the last
        for (uint256 hour = 1; hour <= 6; ++hour) {
            vm.warp(1 + (2_000 + hour) * 1 hours);
            _price(hour % 2 == 0 ? PRICE_TICK : PRICE_TICK + 488);
            harness.record();
        }
        assertGt(harness.sigma(), 0.4e18, "the crash lifts sigma above the floor");
    }

    // ---------------------------------------------------------------- reference

    /// @dev `ℓ = x(P₀)·(P₁ − P₀) − (V(P₁) − V(P₀))` in token1 units, from v4's amount formulas rather than the trees.
    function _ell(uint128 liquidity, int24 tickLower, int24 tickUpper, uint160 sqrtFromX96, uint160 sqrtToX96)
        internal
        pure
        returns (int256)
    {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(tickLower, tickUpper);
        uint256 amount0 = _amount0(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtFromX96);
        uint256 sqrtChangeX96 = sqrtToX96 > sqrtFromX96 ? sqrtToX96 - sqrtFromX96 : sqrtFromX96 - sqrtToX96;
        uint256 move =
            FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtChangeX96, Q96), uint256(sqrtToX96) + sqrtFromX96, Q96);
        int256 hedge = sqrtToX96 >= sqrtFromX96 ? int256(move) : -int256(move);
        int256 valueChange = int256(_value(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtToX96))
            - int256(_value(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtFromX96));
        return hedge - valueChange;
    }

    function _value(uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256)
    {
        uint256 amount0 = _amount0(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtPriceX96);
        uint160 inside = _clamp(sqrtLowerX96, sqrtUpperX96, sqrtPriceX96);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, inside, liquidity, false);
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, Q96), sqrtPriceX96, Q96) + amount1;
    }

    function _amount0(uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256)
    {
        uint160 inside = _clamp(sqrtLowerX96, sqrtUpperX96, sqrtPriceX96);
        return SqrtPriceMath.getAmount0Delta(inside, sqrtUpperX96, liquidity, false);
    }

    function _clamp(uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint160 sqrtPriceX96) internal pure returns (uint160) {
        if (sqrtPriceX96 < sqrtLowerX96) return sqrtLowerX96;
        if (sqrtPriceX96 > sqrtUpperX96) return sqrtUpperX96;
        return sqrtPriceX96;
    }

    // ---------------------------------------------------------------- paths

    /// @dev The same position and path with no rent, so the rent test can take the realized charge out.
    function _owedWithoutRent(uint256 seed, uint256 points, uint256 opensAt) internal returns (uint256) {
        uint256 state = vm.snapshotState();
        vm.warp(1);
        _price(PRICE_TICK);
        ChargeHarness plain = new ChargeHarness(address(source), 0);
        plain.record();
        vm.warp(opensAt);
        _price(bound(seed, 0, 1) == 0 ? PRICE_TICK - 600 : PRICE_TICK);
        plain.open(PRICE_TICK - 400, PRICE_TICK - 100, _liquidity(PRICE_TICK - 400, PRICE_TICK - 100), true, false);
        // points <= MAX_POINTS
        for (uint256 index = 1; index <= points; ++index) {
            vm.warp(1 + index * 1 hours);
            bool below = uint256(keccak256(abi.encode(seed, index))) % 2 == 0;
            _price(below ? PRICE_TICK - 600 : PRICE_TICK);
            plain.record();
        }
        uint256 owedWad = plain.owed();
        vm.revertToState(state);
        return owedWad;
    }

    /// @dev A range 50 to 1,500 ticks wide, anywhere from 2,000 below the price to 2,000 above it.
    function _range(uint256 seed) internal pure returns (int24 tickLower, int24 tickUpper) {
        int256 offset = int256(bound(uint256(keccak256(abi.encode(seed, "lower"))), 0, 4_000)) - 2_000;
        int256 width = int256(bound(uint256(keccak256(abi.encode(seed, "width"))), 50, 1_500));
        tickLower = int24(int256(PRICE_TICK) + offset);
        tickUpper = int24(int256(tickLower) + width);
    }

    /// @dev Prices within 2,500 ticks of the start, about ±25%.
    function _tick(uint256 seed, uint256 index) internal pure returns (int24) {
        int256 offset = int256(bound(uint256(keccak256(abi.encode(seed, "tick", index))), 0, 5_000)) - 2_500;
        return int24(int256(PRICE_TICK) + offset);
    }

    /// @dev About 10,000 of token1 across the range.
    function _liquidity(int24 tickLower, int24 tickUpper) internal pure returns (uint128) {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        return uint128(FullMath.mulDiv(10_000e6, Q96, sqrtUpperX96 - sqrtLowerX96));
    }

    /// @dev A band with no spread, so the mid is the tick's price exactly.
    function _price(int24 tick) internal returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        source.set(sqrtPriceX96, sqrtPriceX96);
    }

    function _atLeastZero(int256 amount) internal pure returns (uint256) {
        return amount > 0 ? uint256(amount) : 0;
    }
}
