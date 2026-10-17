// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Pair, TopEntry} from "../../arbitrage/NetworkTypes.sol";

/// @notice Small helpers shared by ArbitrageNetwork and LoopRefresh.
library NetworkLibrary {
    function pairKey(uint32 tokenA, uint32 tokenB) internal pure returns (uint64) {
        (uint32 low, uint32 high) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return uint64(low) << 32 | high;
    }

    /// @dev Reserves of the pair's deepest pool at its last read, both zero for an empty list.
    function deepestReserves(Pair storage pair) internal view returns (uint96 reserve0, uint96 reserve1) {
        if (pair.topCount == 0) return (0, 0);
        TopEntry memory deepest = pair.top[0];
        return (deepest.reserve0, deepest.reserve1);
    }

    function saturate96(uint256 value) internal pure returns (uint96) {
        return value > type(uint96).max ? type(uint96).max : uint96(value);
    }
}
