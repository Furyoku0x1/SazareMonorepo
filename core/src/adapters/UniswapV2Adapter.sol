// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IExternalVenueAdapter} from "../interfaces/IExternalVenueAdapter.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev The two Uniswap v2 calls this adapter needs. Declared here: the vendored interfaces pin another compiler.
interface IUniswapV2PairMinimal {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV2FactoryMinimal {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice ExternalSwap adapter for Uniswap v2 pairs of one factory, and of v2 forks with another swap fee.
/// @dev Immutable, so the Catalog's code hash pins its behaviour. It trusts only pairs that its factory returns for
/// the action's two currencies, and only the route executor can make it swap. The executor sends the input here
/// first; this adapter forwards it to the pair and asks for the output, which the pair sends to the PoolManager.
contract UniswapV2Adapter is IExternalVenueAdapter {
    /// @notice The only caller of swap.
    address public immutable EXECUTOR;
    /// @notice The factory whose pairs this adapter trusts.
    IUniswapV2FactoryMinimal public immutable FACTORY;
    /// @notice The pair's swap fee in basis points: 30 for Uniswap v2.
    uint256 public immutable FEE_BASIS_POINTS;

    uint256 private constant BASIS_POINTS = 10_000;

    error NotExecutor();
    error InvalidVenue();
    error InsufficientLiquidity();
    error InsufficientInput();
    error TransferMismatch();

    constructor(address executor, IUniswapV2FactoryMinimal factory, uint256 feeBasisPoints) {
        if (feeBasisPoints >= BASIS_POINTS) revert InvalidVenue();
        EXECUTOR = executor;
        FACTORY = factory;
        FEE_BASIS_POINTS = feeBasisPoints;
    }

    /// @inheritdoc IExternalVenueAdapter
    function quoteExactOutput(
        address venue,
        Currency currencyIn,
        Currency currencyOut,
        uint256 amountOut,
        bytes calldata
    ) external view returns (uint256) {
        (uint256 reserveIn, uint256 reserveOut) = _reserves(venue, currencyIn, currencyOut);
        return _amountIn(amountOut, reserveIn, reserveOut);
    }

    /// @inheritdoc IExternalVenueAdapter
    function swap(
        address venue,
        Currency currencyIn,
        Currency currencyOut,
        uint256 amountIn,
        int256 amountSpecified,
        address recipient,
        bytes calldata
    ) external returns (uint256 amountOut) {
        if (msg.sender != EXECUTOR) revert NotExecutor();
        (uint256 reserveIn, uint256 reserveOut) = _reserves(venue, currencyIn, currencyOut);
        amountOut = _output(amountIn, amountSpecified, reserveIn, reserveOut);
        // The pair infers its input from its balance, so it must receive exactly amountIn; a sender surcharge would
        // spend more than this swap's input.
        uint256 held = currencyIn.balanceOf(venue);
        uint256 own = currencyIn.balanceOfSelf();
        currencyIn.transfer(venue, amountIn);
        if (currencyIn.balanceOf(venue) != held + amountIn) revert TransferMismatch();
        if (currencyIn.balanceOfSelf() != own - amountIn) revert TransferMismatch();
        bool zeroForOne = Currency.unwrap(currencyIn) < Currency.unwrap(currencyOut);
        (uint256 amount0Out, uint256 amount1Out) = zeroForOne ? (uint256(0), amountOut) : (amountOut, uint256(0));
        IUniswapV2PairMinimal(venue).swap(amount0Out, amount1Out, recipient, "");
    }

    /// @dev An exact input gets v2's output. An exact output is the requested amount, not the output of the rounded-up
    /// input; reserves can change between the quote and the swap, so the input is checked again.
    function _output(uint256 amountIn, int256 amountSpecified, uint256 reserveIn, uint256 reserveOut)
        private
        view
        returns (uint256 amountOut)
    {
        if (amountSpecified < 0) return _amountOut(amountIn, reserveIn, reserveOut);
        amountOut = uint256(amountSpecified);
        if (amountIn < _amountIn(amountOut, reserveIn, reserveOut)) revert InsufficientInput();
    }

    /// @dev Reserves in the swap direction of the factory's pair for the two currencies.
    function _reserves(address venue, Currency currencyIn, Currency currencyOut)
        private
        view
        returns (uint256 reserveIn, uint256 reserveOut)
    {
        if (venue == address(0)) revert InvalidVenue();
        if (FACTORY.getPair(Currency.unwrap(currencyIn), Currency.unwrap(currencyOut)) != venue) revert InvalidVenue();
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2PairMinimal(venue).getReserves();
        bool zeroForOne = Currency.unwrap(currencyIn) < Currency.unwrap(currencyOut);
        (reserveIn, reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @dev Uniswap v2 getAmountOut, with the fee in basis points (997/1000 = 9970/10000 gives the same result).
    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) private view returns (uint256) {
        uint256 amountInWithFee = amountIn * (BASIS_POINTS - FEE_BASIS_POINTS);
        return amountInWithFee * reserveOut / (reserveIn * BASIS_POINTS + amountInWithFee);
    }

    /// @dev Uniswap v2 getAmountIn: rounded up, so the pair's K check passes.
    function _amountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) private view returns (uint256) {
        if (amountOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();
        uint256 numerator = reserveIn * amountOut * BASIS_POINTS;
        uint256 denominator = (reserveOut - amountOut) * (BASIS_POINTS - FEE_BASIS_POINTS);
        return numerator / denominator + 1;
    }
}
