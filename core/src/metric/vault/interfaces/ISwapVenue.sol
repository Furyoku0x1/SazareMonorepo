// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice A venue named for one of the vault's swaps: a trader's entry or exit swap, or a keeper's force close or fill.
/// An adapter for an aggregator or a router, or anything else that can turn one of the vault's tokens into the other.
interface ISwapVenue {
    /// @notice Called by the vault after it has sent `amountIn` of `tokenIn` here. Before returning, send the vault its
    /// `tokenOut` and any `tokenIn` left unspent. `route` is the caller's, passed through untouched. The vault grants no
    /// allowance and measures only what arrives, so a venue can lose nothing but what it was sent.
    function swapForVault(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata route) external;
}
