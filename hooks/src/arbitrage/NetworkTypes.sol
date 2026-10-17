// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {MAX_TOP_POOLS, MAX_PARTNERS, MAX_TRIANGLES, MAX_QUADS} from "../libraries/arbitrage/NetworkConstants.sol";

/// @dev Two slots: identity, then static key fields, status and the liquidity of the last live read.
struct PoolRecord {
    PoolId id;
    uint32 token0;
    uint32 token1;
    uint24 fee;
    int24 tickSpacing;
    bool active;
    /// @dev Active liquidity at the last live read, saturated at the uint96 maximum.
    uint96 liquidity;
}

/// @dev Virtual reserves L * 2^96 / sqrtP and L * sqrtP / 2^96 at the pool's last live read, each saturated at the
/// uint96 maximum on its own. The list is ordered by reserve0: every pool of a pair has the same token0.
struct TopEntry {
    uint32 pool;
    uint96 reserve0;
    uint96 reserve1;
}

/// @dev Depth is the list owner's reserve in the pair's deepest pool, so depths in one partner list compare.
struct Partner {
    uint32 token;
    uint96 depth;
}

/// @dev Loops of pair (low, high), low < high by token id. A triangle with middle token C holds the deepest pools of
/// (high, C) and (C, low). A four-pool loop with middle tokens C and D holds those of (high, C), (C, D) and (D, low).
/// With the swapped pool on (low, high), each one closes a cycle low -> high -> ... -> low.
struct Pair {
    uint32 activeCount;
    uint8 topCount;
    uint8 triangleCount;
    uint8 quadCount;
    uint64 refreshedRevisionLow;
    uint64 refreshedRevisionHigh;
    TopEntry[MAX_TOP_POOLS] top;
    uint32[2][MAX_TRIANGLES] triangles;
    uint32[3][MAX_QUADS] quads;
}

/// @dev Storage shared by ArbitrageNetwork and the LoopRefresh library, which runs on it through delegatecall.
struct NetworkState {
    mapping(uint32 pool => PoolRecord record) pools;
    mapping(uint64 pairKey => Pair pair) pairs;
    mapping(uint32 token => Partner[MAX_PARTNERS] partners) partners;
    mapping(uint32 token => uint8 count) partnerCount;
    /// @dev Incremented when a pool of one of the token's pairs is added or removed.
    mapping(uint32 token => uint64 revision) tokenRevision;
}
