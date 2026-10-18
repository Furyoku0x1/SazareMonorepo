// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Each owner's open position ids, one list per book, so `positionsOf` can list them on chain.
/// @dev O(1) both ways: an id's index in its list is kept beside it, and a removal moves the list's last id into the
/// removed one's place, so order is not preserved. Ids are unique across both books (one counter), so one index map
/// serves both lists.
library PositionIndex {
    /// @notice Appends a newly minted position id to its owner's list.
    function add(uint256[] storage positionIds, mapping(uint256 => uint256) storage indexOf, uint256 positionId)
        internal
    {
        indexOf[positionId] = positionIds.length;
        positionIds.push(positionId);
    }

    /// @notice Removes an open position's id from its owner's list. Branch-free: when the id is already last, it
    /// overwrites itself before the pop.
    function remove(uint256[] storage positionIds, mapping(uint256 => uint256) storage indexOf, uint256 positionId)
        internal
    {
        uint256 index = indexOf[positionId];
        // Callers remove only open positions, which open added; a missing id would read index zero and clobber it.
        assert(positionIds[index] == positionId);
        uint256 lastId = positionIds[positionIds.length - 1];
        positionIds[index] = lastId;
        indexOf[lastId] = index;
        positionIds.pop();
        delete indexOf[positionId];
    }
}
