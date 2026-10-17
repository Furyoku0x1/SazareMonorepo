// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice A price band for a vault without a Metric pool: raw token1 per raw token0, as v4 sqrt prices in Q96.
/// @dev Not a view: a source may refresh a cache. It must return `sqrtBidX96 <= sqrtAskX96`, and should revert rather
/// than return a stale band. The vault calls it only at open, for lender deposits and withdrawals, and to value a
/// close's leftovers for the profit share.
interface IVaultPriceSource {
    function sqrtBandX96() external returns (uint160 sqrtBidX96, uint160 sqrtAskX96);
}
