// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A Uniswap v2 pair for tests: the same swap rules as v2 (optimistic output, input inferred from balances,
/// fee-adjusted K check, lock), without LP tokens, oracle or flash-swap callback.
contract TestUniswapV2Pair {
    address public immutable token0;
    address public immutable token1;
    uint112 private _reserve0;
    uint112 private _reserve1;
    bool private _locked;

    error Locked();
    error InsufficientOutputAmount();
    error InsufficientLiquidity();
    error InsufficientInputAmount();
    error ConstantProductBroken();

    constructor(address tokenA, address tokenB) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    modifier lock() {
        if (_locked) revert Locked();
        _locked = true;
        _;
        _locked = false;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, 0);
    }

    /// @notice Records the current balances as reserves. Tests add liquidity by transfer, then call this.
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external lock {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint256 reserve0, uint256 reserve1) = (_reserve0, _reserve1);
        if (amount0Out >= reserve0 || amount1Out >= reserve1) revert InsufficientLiquidity();
        if (amount0Out != 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out != 0) IERC20(token1).transfer(to, amount1Out);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();
        uint256 adjusted0 = balance0 * 1000 - amount0In * 3;
        uint256 adjusted1 = balance1 * 1000 - amount1In * 3;
        if (adjusted0 * adjusted1 < reserve0 * reserve1 * 1_000_000) revert ConstantProductBroken();
        _update(balance0, balance1);
    }

    function _update(uint256 balance0, uint256 balance1) private {
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
    }
}

/// @notice A Uniswap v2 factory for tests: getPair in both orders.
contract TestUniswapV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new TestUniswapV2Pair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}
