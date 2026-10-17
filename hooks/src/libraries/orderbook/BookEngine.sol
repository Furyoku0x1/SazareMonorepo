// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BookWalk} from "./BookWalk.sol";

/// @notice The deployed form of the swap walk: the order book extension delegates to it, so the walk's code does not
/// count against the extension's size. It holds no state; the extension passes its pool's book as storage.
library BookEngine {
    /// @notice Plans and commits a swap's book fills.
    /// @return fill What the book trades with the taker.
    /// @return makerFee Maker fees on the fills, rounded down, in the input currency.
    function execute(BookWalk.PoolBook storage book, BookWalk.Request memory request)
        external
        returns (BookWalk.Fill memory fill, uint256 makerFee)
    {
        BookWalk.Plan memory plan = BookWalk.plan(book, request);
        makerFee = BookWalk.commit(book, request, plan);
        fill = plan.fill;
    }

    /// @notice What a swap's book fills would be, by the same code without writes.
    function quote(BookWalk.PoolBook storage book, BookWalk.Request memory request)
        external
        view
        returns (BookWalk.Fill memory)
    {
        return BookWalk.plan(book, request).fill;
    }
}
