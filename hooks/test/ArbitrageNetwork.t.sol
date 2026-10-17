// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NetworkFixture} from "./utils/NetworkFixture.sol";
import {ArbitrageNetwork} from "../src/arbitrage/ArbitrageNetwork.sol";
import {MAX_TOP_POOLS, MAX_PARTNERS, MAX_SYNC_POOLS} from "../src/libraries/arbitrage/NetworkConstants.sol";
import {PoolRecord, TopEntry, Partner} from "../src/arbitrage/NetworkTypes.sol";
import {NetworkRegistry} from "../src/arbitrage/NetworkRegistry.sol";
import {KernelExtension} from "../src/base/KernelExtension.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract ArbitrageNetworkTest is NetworkFixture {
    function test_registerRecordsLiveReservesAndLists() public {
        uint32 index = network.register(key);
        PoolRecord memory record = network.poolRecord(index);
        assertTrue(record.active);
        assertEq(PoolId.unwrap(record.id), PoolId.unwrap(pool));
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, pool);
        uint128 liquidity = StateLibrary.getLiquidity(manager, pool);
        uint256 reserve0 = FullMath.mulDiv(liquidity, 1 << 96, sqrtPriceX96);
        uint256 reserve1 = FullMath.mulDiv(liquidity, sqrtPriceX96, 1 << 96);
        assertEq(record.liquidity, liquidity);
        (TopEntry[] memory top, uint32 active) = network.pairTop(record.token0, record.token1);
        assertEq(active, 1);
        assertEq(top.length, 1);
        assertEq(top[0].pool, index);
        assertEq(top[0].reserve0, reserve0);
        assertEq(top[0].reserve1, reserve1);
        Partner[] memory partners0 = network.partners(record.token0);
        assertEq(partners0.length, 1);
        assertEq(partners0[0].token, record.token1);
        assertEq(partners0[0].depth, reserve0);
        Partner[] memory partners1 = network.partners(record.token1);
        assertEq(partners1[0].token, record.token0);
        assertEq(partners1[0].depth, reserve1);
        assertEq(network.tokenRevision(record.token0), 1);
        assertEq(network.tokenRevision(record.token1), 1);
    }

    function test_pairListKeepsDeepestFirst() public {
        PoolKey memory shallow = _kernelPool(currency0, currency1, 500, SQRT_PRICE_1_1, 5e17);
        PoolKey memory deep = _kernelPool(currency0, currency1, 10_000, SQRT_PRICE_1_1, 2e18);
        uint32 middleIndex = network.register(key);
        uint32 shallowIndex = network.register(shallow);
        uint32 deepIndex = network.register(deep);
        PoolRecord memory record = network.poolRecord(deepIndex);
        (TopEntry[] memory top,) = network.pairTop(record.token0, record.token1);
        assertEq(top.length, 3);
        assertEq(top[0].pool, deepIndex);
        assertEq(top[1].pool, middleIndex);
        assertEq(top[2].pool, shallowIndex);
        // The partner depth follows the pair's deepest pool.
        assertEq(network.partners(record.token0)[0].depth, top[0].reserve0);
    }

    function test_pairListCapsAtSixteenDeepest() public {
        uint256 pools = MAX_TOP_POOLS + 4;
        uint32[] memory indexes = new uint32[](pools);
        // pools = 20
        for (uint256 i; i < pools; ++i) {
            PoolKey memory target =
                _kernelPool(currency0, currency1, uint24(100 + i), SQRT_PRICE_1_1, uint128(1e17 * (i + 1)));
            indexes[i] = network.register(target);
        }
        PoolRecord memory record = network.poolRecord(indexes[0]);
        (TopEntry[] memory top, uint32 active) = network.pairTop(record.token0, record.token1);
        assertEq(active, pools);
        assertEq(top.length, MAX_TOP_POOLS);
        // MAX_TOP_POOLS = 16
        for (uint256 i; i < top.length; ++i) {
            assertEq(top[i].pool, indexes[pools - 1 - i]);
        }
    }

    function test_partnerListCapsAtThirtyTwoDeepest() public {
        uint256 tokens = MAX_PARTNERS + 2;
        uint32[] memory partnerTokens = new uint32[](tokens);
        // tokens = 34
        for (uint256 i; i < tokens; ++i) {
            Currency other = _newCurrency();
            PoolKey memory target = _kernelPool(currency0, other, 3000, SQRT_PRICE_1_1, uint128(1e17 * (i + 1)));
            network.register(target);
            partnerTokens[i] = network.tokenIdOf(other);
        }
        Partner[] memory hubPartners = network.partners(network.tokenIdOf(currency0));
        assertEq(hubPartners.length, MAX_PARTNERS);
        // MAX_PARTNERS = 32; the two shallowest partners were dropped.
        for (uint256 i; i < hubPartners.length; ++i) {
            assertEq(hubPartners[i].token, partnerTokens[tokens - 1 - i]);
        }
    }

    function test_unregisterRemovesPoolAndEmptyPairPartners() public {
        uint32 index = network.register(key);
        PoolRecord memory record = network.poolRecord(index);
        network.unregister(pool);
        (TopEntry[] memory top, uint32 active) = network.pairTop(record.token0, record.token1);
        assertEq(top.length, 0);
        assertEq(active, 0);
        assertEq(network.partners(record.token0).length, 0);
        assertEq(network.partners(record.token1).length, 0);
        assertEq(network.tokenRevision(record.token0), 2);
        assertFalse(network.poolRecord(index).active);
        // A pool keeps its index when it comes back.
        assertEq(network.register(key), index);
    }

    function test_registerRequiresPoolRole() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(KernelExtension.Unauthorized.selector);
        network.register(key);
    }

    function test_unregisterRequiresPoolRole() public {
        network.register(key);
        vm.prank(address(0xBAD));
        vm.expectRevert(KernelExtension.Unauthorized.selector);
        network.unregister(pool);
    }

    function test_registerTwiceReverts() public {
        network.register(key);
        vm.expectRevert(NetworkRegistry.AlreadyRegistered.selector);
        network.register(key);
    }

    function test_unregisterUnknownPoolReverts() public {
        vm.expectRevert(NetworkRegistry.NotRegistered.selector);
        network.unregister(pool);
    }

    function test_syncDepthReordersAfterLiquidityChange() public {
        PoolKey memory other = _kernelPool(currency0, currency1, 500, SQRT_PRICE_1_1, 5e17);
        uint32 first = network.register(key);
        uint32 second = network.register(other);
        PoolRecord memory record = network.poolRecord(first);
        assertEq(_topPool(record, 0), first);
        _addLiquidity(other, 2e18);
        uint32[] memory pools = new uint32[](1);
        pools[0] = second;
        network.syncDepth(pools);
        assertEq(_topPool(record, 0), second);
        (TopEntry[] memory top,) = network.pairTop(record.token0, record.token1);
        assertEq(network.partners(record.token0)[0].depth, top[0].reserve0);
    }

    function test_syncDepthRefillsGapAfterRemoval() public {
        uint256 pools = MAX_TOP_POOLS + 1;
        uint32[] memory indexes = new uint32[](pools);
        PoolKey[] memory keys = new PoolKey[](pools);
        // pools = 17; the first one is the shallowest and stays out of the full list.
        for (uint256 i; i < pools; ++i) {
            keys[i] = _kernelPool(currency0, currency1, uint24(100 + i), SQRT_PRICE_1_1, uint128(1e17 * (i + 1)));
            indexes[i] = network.register(keys[i]);
        }
        PoolRecord memory record = network.poolRecord(indexes[0]);
        network.unregister(keys[pools - 1].toId());
        (TopEntry[] memory top,) = network.pairTop(record.token0, record.token1);
        assertEq(top.length, MAX_TOP_POOLS - 1);
        uint32[] memory sync = new uint32[](1);
        sync[0] = indexes[0];
        network.syncDepth(sync);
        (top,) = network.pairTop(record.token0, record.token1);
        assertEq(top.length, MAX_TOP_POOLS);
        assertEq(top[top.length - 1].pool, indexes[0]);
    }

    function test_syncDepthRejectsTooManyPools() public {
        uint32[] memory pools = new uint32[](MAX_SYNC_POOLS + 1);
        vm.expectRevert(NetworkRegistry.TooManyPools.selector);
        network.syncDepth(pools);
    }

    function _topPool(PoolRecord memory record, uint256 position) private view returns (uint32) {
        (TopEntry[] memory top,) = network.pairTop(record.token0, record.token1);
        return top[position].pool;
    }
}
