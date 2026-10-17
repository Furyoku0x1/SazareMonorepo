// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Caps of the arbitrage network. Each one bounds a list, so every write and every search reads a fixed amount of
// storage whatever the size of the network. File-level constants, because struct array lengths need them.

/// @dev Most pools kept in a pair's depth-ordered list. Same-pair search reads at most this many peers.
uint256 constant MAX_TOP_POOLS = 16;
/// @dev Most partners kept per token, deepest first. Loop refresh draws its candidates from these lists.
uint256 constant MAX_PARTNERS = 32;
/// @dev Most saved three-pool loops (triangles) per pair.
uint256 constant MAX_TRIANGLES = 8;
/// @dev Most saved four-pool loops per pair.
uint256 constant MAX_QUADS = 16;
/// @dev Most middle tokens next to the pair's high token that one refresh tries for four-pool loops. The refresh checks
/// at most MAX_QUAD_FIRST_TOKENS * MAX_PARTNERS candidate pairs.
uint256 constant MAX_QUAD_FIRST_TOKENS = 16;
/// @dev Most pools that one syncDepth call reads.
uint256 constant MAX_SYNC_POOLS = 64;
/// @dev Most cycles one search sizes with live liquidity and tries to quote.
uint256 constant MAX_SIZED_CYCLES = 8;
/// @dev Search gas guard: one quote attempt (compatibility reads, up to 3 exact-output quotes and the closing quote
/// with its capped book preview). A measured upper estimate.
uint256 constant SEARCH_ATTEMPT_RESERVE_GAS = 350_000;
/// @dev Search gas guard: sizing one cycle with live liquidity. A measured upper estimate.
uint256 constant SEARCH_SIZE_GAS = 40_000;
