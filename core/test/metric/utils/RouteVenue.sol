// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ISwapVenue} from "../../../src/metric/vault/interfaces/ISwapVenue.sol";

/// @notice A venue that fills as its route says, from its own inventory, as an aggregator's adapter would after routing:
/// it spends `spend` of the input, sends the rest back, and pays `amountOut`.
contract RouteVenue is ISwapVenue {
    function swapForVault(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata route) external {
        (uint256 spend, uint256 amountOut) = abi.decode(route, (uint256, uint256));
        IERC20(tokenOut).transfer(msg.sender, amountOut);
        IERC20(tokenIn).transfer(msg.sender, amountIn - spend);
    }
}

/// @notice A venue that sells everything it is sent at a fixed rate from its own inventory: `amountIn · numerator /
/// denominator` of the output, as a keeper's venue would when it cannot know the exact budget the vault sends.
contract RateVenue is ISwapVenue {
    function swapForVault(address, address tokenOut, uint256 amountIn, bytes calldata route) external {
        (uint256 numerator, uint256 denominator) = abi.decode(route, (uint256, uint256));
        IERC20(tokenOut).transfer(msg.sender, FullMath.mulDiv(amountIn, numerator, denominator));
    }
}

/// @notice Routes for the invariant handlers' venue opens.
library VenueRoutes {
    uint256 internal constant BPS = 10_000;

    /// @dev One route: what the vault sells, what the venue spends of it and pays back, and the route itself.
    struct Route {
        uint256 amountIn;
        uint256 spend;
        uint256 amountOut;
        bytes data;
    }

    /// @dev Sells 1–100% of `sellable` and spends 50–100% of that, so every fill is far above rounding, filling at the
    /// band's edge, 0.5% or 2% short of it, or at half, as `choice` picks.
    function route(bool isLong, uint256 sellable, uint256 choice, uint160 sqrtBidX96, uint160 sqrtAskX96)
        internal
        pure
        returns (Route memory chosen)
    {
        chosen.amountIn = sellable * (choice % 100 + 1) / 100;
        chosen.spend = chosen.amountIn * (50 + (choice / 100) % 51) / 100;
        uint256 fair = isLong ? _token0At(chosen.spend, sqrtAskX96) : _token1At(chosen.spend, sqrtBidX96);
        chosen.amountOut = fair * _fillBps(choice / 10_000) / BPS;
        chosen.data = abi.encode(chosen.spend, chosen.amountOut);
    }

    function _fillBps(uint256 choice) private pure returns (uint256) {
        uint256 kind = choice % 4;
        if (kind == 0) return BPS;
        if (kind == 1) return 9_950;
        if (kind == 2) return 9_800;
        return 5_000;
    }

    /// @dev Token0 for `amount1` at a sqrt price, rounded down.
    function _token0At(uint256 amount1, uint160 sqrtPriceX96) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount1, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    /// @dev Token1 for `amount0` at a sqrt price, rounded down.
    function _token1At(uint256 amount0, uint160 sqrtPriceX96) private pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96);
    }
}
