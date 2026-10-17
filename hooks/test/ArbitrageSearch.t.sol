// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NetworkFixture} from "./utils/NetworkFixture.sol";
import {ArbitrageNetwork} from "../src/arbitrage/ArbitrageNetwork.sol";
import {MAX_TOP_POOLS} from "../src/libraries/arbitrage/NetworkConstants.sol";
import {OrderMath} from "../src/libraries/limitorder/OrderMath.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract ArbitrageSearchTest is NetworkFixture {
    function test_findCycleSamePairMatchesExecution() public {
        PoolKey memory peer = _kernelPool(currency0, currency1, 500, SQRT_PRICE_1_1, 1e18);
        network.register(key);
        network.register(peer);
        _swapExactInput(key, true, 1e16);
        ArbitrageNetwork.Plan memory plan = network.findCycle(pool, true, _limits());
        assertEq(plan.legs, 2);
        _assertPlanExecutes(plan, currency0);
    }

    function test_findCycleTriangleAfterRefresh() public {
        Currency currency2 = _newCurrency();
        PoolKey memory highMiddle = _kernelPool(currency1, currency2, 500, SQRT_PRICE_1_1, 1e18);
        PoolKey memory middleLow = _kernelPool(currency2, currency0, 500, SQRT_PRICE_1_1, 1e18);
        network.register(key);
        network.register(highMiddle);
        network.register(middleLow);
        _refreshRoot();
        (uint32[2][] memory triangles, uint32[3][] memory quads,,) = _rootLoops();
        assertEq(triangles.length, 1);
        assertEq(quads.length, 0);
        _swapExactInput(key, true, 1e16);
        ArbitrageNetwork.Plan memory plan = network.findCycle(pool, true, _limits());
        assertEq(plan.legs, 3);
        _assertPlanExecutes(plan, currency0);
    }

    /// @dev Both profit currencies and both root swap directions: every rotation and direction of the triangle.
    function test_findCycleTriangleAllRotations() public {
        Currency currency2 = _newCurrency();
        network.register(key);
        network.register(_kernelPool(currency1, currency2, 500, SQRT_PRICE_1_1, 1e18));
        network.register(_kernelPool(currency2, currency0, 500, SQRT_PRICE_1_1, 1e18));
        _refreshRoot();
        uint256 state = vm.snapshotState();
        // 4 combinations
        for (uint256 i; i < 4; ++i) {
            bool profitCurrency0 = i % 2 == 0;
            _swapExactInput(key, i < 2, 1e16);
            ArbitrageNetwork.Plan memory plan = network.findCycle(pool, profitCurrency0, _limits());
            assertGt(plan.legs, 1);
            _assertPlanExecutes(plan, profitCurrency0 ? currency0 : currency1);
            vm.revertToState(state);
        }
    }

    /// @dev Pool ids 1, 90 and 234 share snapshot table slot 79, so each lookup must probe past the others.
    function test_findCycleTriangleWithCollidingPoolIds() public {
        Currency currency2 = _newCurrency();
        assertEq(network.register(key), 1);
        _setCounters(network.tokenCount(), 89);
        assertEq(network.register(_kernelPool(currency1, currency2, 500, SQRT_PRICE_1_1, 1e18)), 90);
        _setCounters(network.tokenCount(), 233);
        assertEq(network.register(_kernelPool(currency2, currency0, 500, SQRT_PRICE_1_1, 1e18)), 234);
        _refreshRoot();
        _swapExactInput(key, true, 1e16);
        ArbitrageNetwork.Plan memory plan = network.findCycle(pool, true, _limits());
        assertEq(plan.legs, 3);
        _assertPlanExecutes(plan, currency0);
    }

    function test_findCycleFourPoolLoopAfterRefresh() public {
        Currency currency2 = _newCurrency();
        Currency currency3 = _newCurrency();
        network.register(key);
        network.register(_kernelPool(currency1, currency2, 500, SQRT_PRICE_1_1, 1e18));
        network.register(_kernelPool(currency2, currency3, 500, SQRT_PRICE_1_1, 1e18));
        network.register(_kernelPool(currency3, currency0, 500, SQRT_PRICE_1_1, 1e18));
        _refreshRoot();
        (uint32[2][] memory triangles, uint32[3][] memory quads,,) = _rootLoops();
        assertEq(triangles.length, 0);
        assertEq(quads.length, 1);
        uint256 state = vm.snapshotState();
        // 4 combinations
        for (uint256 i; i < 4; ++i) {
            bool profitCurrency0 = i % 2 == 0;
            _swapExactInput(key, i < 2, 1e16);
            ArbitrageNetwork.Plan memory plan = network.findCycle(pool, profitCurrency0, _limits());
            assertEq(plan.legs, 4);
            _assertPlanExecutes(plan, profitCurrency0 ? currency0 : currency1);
            vm.revertToState(state);
        }
    }

    function test_findCycleWithoutOpportunityReturnsNoLegs() public {
        network.register(key);
        network.register(_kernelPool(currency0, currency1, 500, SQRT_PRICE_1_1, 1e18));
        _swapExactInput(key, true, 1);
        assertEq(network.findCycle(pool, true, _limits()).legs, 0);
    }

    function test_findCycleSkipsLoopWithRemovedPool() public {
        Currency currency2 = _newCurrency();
        network.register(key);
        network.register(_kernelPool(currency1, currency2, 500, SQRT_PRICE_1_1, 1e18));
        PoolKey memory middleLow = _kernelPool(currency2, currency0, 500, SQRT_PRICE_1_1, 1e18);
        network.register(middleLow);
        _refreshRoot();
        network.unregister(middleLow.toId());
        _swapExactInput(key, true, 1e16);
        assertEq(network.findCycle(pool, true, _limits()).legs, 0);
    }

    function test_findCycleForUnregisteredPoolReturnsNoLegs() public view {
        assertEq(network.findCycle(pool, true, _limits()).legs, 0);
    }

    function test_refreshRanksDeeperTriangleFirst() public {
        Currency shallowMiddle = _newCurrency();
        Currency deepMiddle = _newCurrency();
        network.register(key);
        network.register(_kernelPool(currency1, shallowMiddle, 500, SQRT_PRICE_1_1, 1e17));
        PoolKey memory shallowLow = _kernelPool(shallowMiddle, currency0, 500, SQRT_PRICE_1_1, 1e17);
        network.register(shallowLow);
        network.register(_kernelPool(currency1, deepMiddle, 500, SQRT_PRICE_1_1, 1e19));
        PoolKey memory deepLow = _kernelPool(deepMiddle, currency0, 500, SQRT_PRICE_1_1, 1e19);
        network.register(deepLow);
        _refreshRoot();
        (uint32[2][] memory triangles,,,) = _rootLoops();
        assertEq(triangles.length, 2);
        assertEq(triangles[0][1], network.poolIndexOf(deepLow.toId()));
        assertEq(triangles[1][1], network.poolIndexOf(shallowLow.toId()));
    }

    function test_findCycleRejectsLimitsAboveCaps() public {
        ArbitrageNetwork.Limits memory limits = _limits();
        limits.samePair = uint8(MAX_TOP_POOLS + 1);
        vm.expectRevert(ArbitrageNetwork.InvalidLimits.selector);
        network.findCycle(pool, true, limits);
    }

    function _limits() internal pure returns (ArbitrageNetwork.Limits memory) {
        return ArbitrageNetwork.Limits({
            samePair: 16,
            triangles: 8,
            quads: 16,
            sized: 4,
            minimumSurplus: 1,
            maximumInput: uint128(OrderMath.MAX_DELTA)
        });
    }

    function _refreshRoot() internal {
        network.refresh(network.tokenIdOf(currency0), network.tokenIdOf(currency1));
    }

    function _rootLoops() internal view returns (uint32[2][] memory, uint32[3][] memory, uint64, uint64) {
        return network.pairLoops(network.tokenIdOf(currency0), network.tokenIdOf(currency1));
    }

    /// @dev Runs the plan leg by leg through the swap router. Each middle currency must net to zero and the profit
    /// currency must change by exactly proceeds - input, so the plan's quotes match execution.
    function _assertPlanExecutes(ArbitrageNetwork.Plan memory plan, Currency profitCurrency) internal {
        Currency[8] memory currencies;
        uint256[8] memory before;
        // legs <= 4, two currencies each
        for (uint256 k; k < plan.legs; ++k) {
            (currencies[2 * k], currencies[2 * k + 1]) = (plan.keys[k].currency0, plan.keys[k].currency1);
        }
        // 8 entries
        for (uint256 i; i < 2 * plan.legs; ++i) {
            before[i] = _balance(currencies[i]);
        }
        // legs <= 4
        for (uint256 k; k < plan.legs; ++k) {
            int256 amount = int256(uint256(plan.amounts[k]));
            bool zeroForOne = plan.zeroForOne[k];
            swapRouter.swap(
                plan.keys[k],
                SwapParams(
                    zeroForOne, k + 1 < plan.legs ? amount : -amount, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                ),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
        }
        assertGt(plan.proceeds, plan.input);
        // 8 entries
        for (uint256 i; i < 2 * plan.legs; ++i) {
            int256 change = int256(_balance(currencies[i])) - int256(before[i]);
            if (Currency.unwrap(currencies[i]) == Currency.unwrap(profitCurrency)) {
                assertEq(change, int256(uint256(plan.proceeds)) - int256(uint256(plan.input)));
            } else {
                assertEq(change, 0);
            }
        }
    }

    function _balance(Currency currency) private view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }
}
