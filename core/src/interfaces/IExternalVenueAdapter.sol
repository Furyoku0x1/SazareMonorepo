// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "v4-core/src/types/Currency.sol";

/// @notice An adapter that swaps on one kind of venue outside the PoolManager for an ExternalSwap route action.
/// @dev The route executor calls it while the PoolManager is unlocked, so the Catalog admits only reviewed, immutable
/// adapters. The executor checks the input that leaves the PoolManager and reaches the adapter, the sync, the exact
/// settlement of the output and its own deltas, so a wrong amount reverts the route. Its check of the PoolManager's
/// nonzero-delta count is only a tripwire: an adapter, venue or token that leaves its own debt open can still revert
/// the whole unlock, including the root swap. An adapter must therefore authenticate its venue (for example against
/// the venue's factory), must not call the PoolManager, and supports only ordinary, non-rebasing ERC20 tokens.
interface IExternalVenueAdapter {
    /// @notice Returns the input that an exact output of amountOut needs on venue now.
    /// @param venue The venue
    /// @param currencyIn The currency that the venue receives
    /// @param currencyOut The currency that the venue pays
    /// @param amountOut The exact output
    /// @param data The action's hookData
    /// @return amountIn The input, rounded up
    function quoteExactOutput(
        address venue,
        Currency currencyIn,
        Currency currencyOut,
        uint256 amountOut,
        bytes calldata data
    ) external view returns (uint256 amountIn);

    /// @notice Swaps amountIn of currencyIn, which the executor has already sent to this adapter, and sends the output
    /// to recipient. Only the route executor may call this.
    /// @param venue The venue
    /// @param currencyIn The currency that the venue receives
    /// @param currencyOut The currency that the venue pays
    /// @param amountIn The input that this adapter holds for the swap
    /// @param amountSpecified Negative for an exact input; positive for an exact output of exactly this amount
    /// @param recipient The receiver of the output (the PoolManager)
    /// @param data The action's hookData
    /// @return amountOut The output sent to recipient
    function swap(
        address venue,
        Currency currencyIn,
        Currency currencyOut,
        uint256 amountIn,
        int256 amountSpecified,
        address recipient,
        bytes calldata data
    ) external returns (uint256 amountOut);
}
