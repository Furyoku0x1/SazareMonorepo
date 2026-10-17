// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ExtensionFixture} from "./ExtensionFixture.sol";
import {ArbitrageNetwork} from "../../src/arbitrage/ArbitrageNetwork.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Builds multi-token Kernel pool networks for ArbitrageNetwork and cycle-search tests.
abstract contract NetworkFixture is ExtensionFixture {
    ArbitrageNetwork internal network;

    function setUp() public virtual override {
        super.setUp();
        network = new ArbitrageNetwork(IKernelHook(address(hook)), orders);
    }

    function _newCurrency() internal returns (Currency) {
        MockERC20 token = new MockERC20("N", "N", 18);
        token.mint(address(this), type(uint128).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        return Currency.wrap(address(token));
    }

    /// @dev A Kernel pool with liquidity over ticks -6000..6000. sqrtPriceX96 is token1 per token0 after sorting.
    function _kernelPool(Currency a, Currency b, uint24 fee, uint160 sqrtPriceX96, uint128 liquidity)
        internal
        returns (PoolKey memory target)
    {
        (Currency currency0_, Currency currency1_) = a < b ? (a, b) : (b, a);
        target = PoolKey(currency0_, currency1_, fee, 60, IHooks(address(hook)));
        hook.preparePool(target);
        manager.initialize(target, sqrtPriceX96);
        modifyLiquidityRouter.modifyLiquidity(
            target, ModifyLiquidityParams(-6000, 6000, int256(uint256(liquidity)), 0), ""
        );
    }

    /// @dev tokenCount and poolCount share slot 0 (uint32 each, in declaration order). The next pool gets pools + 1.
    function _setCounters(uint32 tokens, uint32 pools) internal {
        vm.store(address(network), bytes32(0), bytes32(uint256(tokens) | uint256(pools) << 32));
        assertEq(network.tokenCount(), tokens);
        assertEq(network.poolCount(), pools);
    }

    function _addLiquidity(PoolKey memory target, uint128 liquidity) internal {
        modifyLiquidityRouter.modifyLiquidity(
            target, ModifyLiquidityParams(-6000, 6000, int256(uint256(liquidity)), 0), ""
        );
    }
}
