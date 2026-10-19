// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {VaultMath} from "./VaultMath.sol";

/// @notice A trader's swap through the venue they choose, and what its fill lost against the band. Any fill stands; the
/// caller counts the loss as taken out of the position, so the profit share is measured as if the swap had filled at
/// the band. `MetricVenue.swapForTrader` runs the swap.
library VenueSwap {
    /// @dev One swap: its direction, size and the trader's minimum, the venue (zero for the vault's Metric pool), and
    /// the band its fill is measured at.
    struct Trade {
        bool zeroForOne;
        uint256 amountIn;
        uint256 minimumOut;
        address venue;
        uint160 sqrtBidX96;
        uint160 sqrtAskX96;
    }

    /// @notice What a fill lost against the band's edge it crosses, in token1 and rounded against the trader: a long's
    /// token0 valued at the ask, a short's token0 at the bid. Zero at the edge or better: a better fill is the trader's
    /// own, and counts as profit when the reserves do.
    function shortfall(Trade memory trade, uint256 paid, uint256 received) internal pure returns (uint256) {
        uint256 valueIn = trade.zeroForOne ? VaultMath.priceTimes(paid, trade.sqrtBidX96, true) : paid;
        uint256 valueOut = trade.zeroForOne ? received : VaultMath.priceTimes(received, trade.sqrtAskX96, false);
        if (valueOut >= valueIn) return 0;
        return valueIn - valueOut;
    }
}
