// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ArbitrageFixture} from "./utils/ArbitrageFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {ArbitrageHook} from "../src/arbitrage/ArbitrageHook.sol";
import {ArbitrageNetwork} from "../src/arbitrage/ArbitrageNetwork.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MAX_TOP_POOLS, MAX_PARTNERS, MAX_SIZED_CYCLES} from "../src/libraries/arbitrage/NetworkConstants.sol";
import {PoolRecord} from "../src/arbitrage/NetworkTypes.sol";

/// @dev Worst-case gas with every capped list full: 16 same-pair peers, 8 saved triangles, 16 saved four-pool loops,
/// 32 partners on both root tokens (so refresh checks 16 x 32 middle pairs). Per-transaction work depends only on
/// these caps, so the same numbers hold for a network of any size; the `_atScale` variants set the registry's
/// counters as if 1,000,000 pools and 250,000 tokens were registered, to show that ids at scale cost the same.
/// Run with --isolate --hardfork cancun.
contract ArbitrageScaleGasTest is ArbitrageFixture {
    uint256 private constant TRIANGLES = 8;
    uint256 private constant QUADS = 16;
    /// @dev Search gas that covers every full list at the fixture's sized count: about 1.44M of search work plus the
    /// finish reserve (SEARCH_ATTEMPT_RESERVE_GAS + 4 * SEARCH_SIZE_GAS) and the guards' price and score estimates.
    uint32 private constant FULL_SEARCH_GAS = 2_200_000;

    function setUp() public override {
        if (!vm.isIsolateMode()) vm.skip(true);
        super.setUp();
    }

    function test_gas_worstCaseSearchNoOpportunity() public {
        _fullNetwork(false, _policy().sized);
        _measureSwap("worst_case_search_no_opportunity", 1);
        assertEq(arbitrage.claimable(pool, address(this)), 0);
        // The search itself completes inside the policy's search budget instead of running out of gas.
        (ArbitrageHook.Policy memory policy,,,) = arbitrage.profitState(pool);
        vm.prank(address(arbitrage));
        assertEq(network.findCycle{gas: policy.searchGasLimit}(pool, true, _limits(policy)).legs, 0);
    }

    /// @dev Only the lowest-priority loop, the last saved four-pool loop, is mispriced. FULL_SEARCH_GAS reaches it with
    /// every list full; the fixture's 1.5M search budget stops before it and keeps the higher-priority loops.
    function test_gas_lastQuadFoundWithFullSearchBudget() public {
        _fullNetwork(false, _policy().sized);
        (, uint32[3][] memory quads,,) = network.pairLoops(network.tokenIdOf(currency0), network.tokenIdOf(currency1));
        PoolKey memory middle = _keyOf(quads[quads.length - 1][1]);
        swapRouter.swap(middle, SwapParams(true, -1e16, MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), "");
        ArbitrageNetwork.Limits memory limits = _limits(_policy());
        vm.prank(address(arbitrage));
        assertEq(network.findCycle{gas: FULL_SEARCH_GAS}(pool, true, limits).legs, 4);
        _record("full_search_last_quad", vm.lastFrameGas());
        vm.prank(address(arbitrage));
        assertEq(network.findCycle{gas: _policy().searchGasLimit}(pool, true, limits).legs, 0);
    }

    function test_gas_worstCaseSearchSuccess() public {
        _fullNetwork(false, _policy().sized);
        _measureSwap("worst_case_search_success", 1e16);
        assertGt(arbitrage.claimable(pool, address(this)), 0);
    }

    /// @dev Every cycle the policy allows is sized before the first exact quote.
    function test_gas_worstCaseSearchSuccessAllSized() public {
        _fullNetwork(false, uint8(MAX_SIZED_CYCLES));
        _measureSwap("worst_case_search_success_all_sized", 1e16);
        assertGt(arbitrage.claimable(pool, address(this)), 0);
    }

    function test_gas_worstCaseSearchNoOpportunityAtScale() public {
        _fullNetwork(true, _policy().sized);
        _measureSwap("worst_case_search_no_opportunity_at_scale", 1);
    }

    function test_gas_worstCaseRefresh() public {
        _fullNetwork(false, _policy().sized);
        network.refresh(network.tokenIdOf(currency0), network.tokenIdOf(currency1));
        _record("worst_case_refresh", vm.lastFrameGas());
    }

    function test_gas_worstCaseRegistration() public {
        _fullNetwork(false, _policy().sized);
        // Deeper than every listed pool: it enters the pair list and both partner lists at the top.
        PoolKey memory deepest = _kernelPool(currency0, currency1, 9_999, SQRT_PRICE_1_1, 1e20);
        network.register(deepest);
        _record("worst_case_registration", vm.lastFrameGas());
    }

    function test_gas_worstCaseRegistrationAtScale() public {
        _fullNetwork(true, _policy().sized);
        PoolKey memory deepest = _kernelPool(currency0, currency1, 9_999, SQRT_PRICE_1_1, 1e20);
        network.register(deepest);
        _record("worst_case_registration_at_scale", vm.lastFrameGas());
    }

    /// @dev Builds the full network around the root pool `key` (currency0/currency1) and activates Arbitrage on it.
    function _fullNetwork(bool atScale, uint8 sized) private {
        if (atScale) _setCounters(250_000, 1_000_000);
        network.register(key);
        // MAX_TOP_POOLS same-pair peers; key holds one of the 16 slots, so 15 peers plus key fill the list.
        for (uint256 i; i + 1 < MAX_TOP_POOLS; ++i) {
            network.register(_kernelPool(currency0, currency1, uint24(500 + i), SQRT_PRICE_1_1, 1e18));
        }
        // Triangles: currency1 - middle - currency0.
        for (uint256 i; i < TRIANGLES; ++i) {
            Currency middle = _newCurrency();
            network.register(_kernelPool(currency1, middle, 500, SQRT_PRICE_1_1, 1e18));
            network.register(_kernelPool(middle, currency0, 500, SQRT_PRICE_1_1, 1e18));
        }
        // Four-pool loops: currency1 - first - second - currency0. Deeper, so the first tokens lead the partner list.
        for (uint256 i; i < QUADS; ++i) {
            Currency first = _newCurrency();
            Currency second = _newCurrency();
            network.register(_kernelPool(currency1, first, 500, SQRT_PRICE_1_1, 2e18));
            network.register(_kernelPool(first, second, 500, SQRT_PRICE_1_1, 2e18));
            network.register(_kernelPool(second, currency0, 500, SQRT_PRICE_1_1, 2e18));
        }
        // Fill both partner lists to MAX_PARTNERS with shallow partners that close no loop.
        uint256 fillers = MAX_PARTNERS - TRIANGLES - QUADS;
        for (uint256 i; i < fillers; ++i) {
            network.register(_kernelPool(currency1, _newCurrency(), 500, SQRT_PRICE_1_1, 1e17));
            network.register(_kernelPool(currency0, _newCurrency(), 500, SQRT_PRICE_1_1, 1e17));
        }
        ArbitrageHook.Policy memory policy = _policy();
        policy.sized = sized;
        _installArbitrage(key, policy);
        _refreshRoot();
        (uint32[2][] memory triangles, uint32[3][] memory quads,,) =
            network.pairLoops(network.tokenIdOf(currency0), network.tokenIdOf(currency1));
        assertEq(triangles.length, TRIANGLES);
        assertEq(quads.length, QUADS);
    }

    function _limits(ArbitrageHook.Policy memory policy) private pure returns (ArbitrageNetwork.Limits memory) {
        return ArbitrageNetwork.Limits(
            policy.samePair, policy.triangles, policy.quads, policy.sized, policy.minimumSurplus, policy.maximumInput
        );
    }

    function _keyOf(uint32 index) private view returns (PoolKey memory) {
        PoolRecord memory record = network.poolRecord(index);
        return PoolKey(
            network.currencyOf(record.token0),
            network.currencyOf(record.token1),
            record.fee,
            record.tickSpacing,
            IHooks(address(hook))
        );
    }

    function _measureSwap(string memory name, uint256 input) private returns (BalanceDelta delta) {
        delta = swapRouter.swap{gas: 10_000_000}(
            key, SwapParams(true, -int256(input), MIN_PRICE_LIMIT), PoolSwapTest.TestSettings(false, false), ""
        );
        _record(name, vm.lastFrameGas());
    }

    function _record(string memory name, Vm.Gas memory measured) private {
        uint256 refund = uint256(uint64(measured.gasRefunded));
        uint256 gross = measured.gasTotalUsed;
        vm.snapshotValue("ArbitrageScaleGas", string.concat(name, "_gross"), gross);
        vm.snapshotValue("ArbitrageScaleGas", string.concat(name, "_net"), gross - refund);
        emit log_named_uint(name, gross);
    }
}
