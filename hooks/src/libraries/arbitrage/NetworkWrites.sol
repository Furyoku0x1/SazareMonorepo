// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NetworkState, PoolRecord, TopEntry, Partner, Pair} from "../../arbitrage/NetworkTypes.sol";
import {MAX_TOP_POOLS, MAX_PARTNERS} from "./NetworkConstants.sol";
import {NetworkLibrary} from "./NetworkLibrary.sol";

/// @notice Keeps a pair's depth-ordered pool list and its tokens' partner lists current when a pool is added,
/// resynced or removed.
/// @dev External library: ArbitrageNetwork runs it through delegatecall on its own storage, which keeps the network
/// contract under the size limit. Every loop is bounded by MAX_TOP_POOLS or MAX_PARTNERS.
library NetworkWrites {
    /// @notice Puts the pool at its reserve0 depth in its pair's list, then updates both tokens' partner entries.
    function place(NetworkState storage state, uint32 pool, uint96 reserve0, uint96 reserve1) external {
        PoolRecord storage record = state.pools[pool];
        Pair storage pair = state.pairs[NetworkLibrary.pairKey(record.token0, record.token1)];
        _placeInTop(pair, TopEntry(pool, reserve0, reserve1));
        _updatePartners(state, record.token0, record.token1, pair);
    }

    /// @notice Takes the pool out of its pair's list, then updates both tokens' partner entries.
    function remove(NetworkState storage state, uint32 pool) external {
        PoolRecord storage record = state.pools[pool];
        Pair storage pair = state.pairs[NetworkLibrary.pairKey(record.token0, record.token1)];
        _removeFromTop(pair, pool);
        _updatePartners(state, record.token0, record.token1, pair);
    }

    /// @dev Removes the pool if listed, then inserts it at its depth. A pool shallower than a full list stays out.
    function _placeInTop(Pair storage pair, TopEntry memory entry) private {
        _removeFromTop(pair, entry.pool);
        uint256 count = pair.topCount;
        uint256 position = count;
        // position <= MAX_TOP_POOLS
        while (position > 0 && pair.top[position - 1].reserve0 < entry.reserve0) {
            if (position < MAX_TOP_POOLS) pair.top[position] = pair.top[position - 1];
            --position;
        }
        if (position >= MAX_TOP_POOLS) return;
        pair.top[position] = entry;
        if (count < MAX_TOP_POOLS) pair.topCount = uint8(count + 1);
    }

    function _removeFromTop(Pair storage pair, uint32 pool) private {
        uint256 count = pair.topCount;
        // count <= MAX_TOP_POOLS
        for (uint256 i; i < count; ++i) {
            if (pair.top[i].pool != pool) continue;
            // count <= MAX_TOP_POOLS
            for (uint256 j = i; j + 1 < count; ++j) {
                pair.top[j] = pair.top[j + 1];
            }
            delete pair.top[count - 1];
            pair.topCount = uint8(count - 1);
            return;
        }
    }

    /// @dev Each token lists the other with its own reserve in the pair's deepest pool; an empty pair is unlisted.
    function _updatePartners(NetworkState storage state, uint32 token0, uint32 token1, Pair storage pair) private {
        (uint96 depth0, uint96 depth1) = NetworkLibrary.deepestReserves(pair);
        _placePartner(state, token0, token1, depth0);
        _placePartner(state, token1, token0, depth1);
    }

    /// @dev Same insertion as the pair list, keyed by partner token. Depth zero only removes the entry.
    function _placePartner(NetworkState storage state, uint32 owner, uint32 partner, uint96 depth) private {
        Partner[MAX_PARTNERS] storage list = state.partners[owner];
        uint256 count = _removePartner(list, state.partnerCount[owner], partner);
        if (depth != 0) {
            uint256 position = count;
            // position <= MAX_PARTNERS
            while (position > 0 && list[position - 1].depth < depth) {
                if (position < MAX_PARTNERS) list[position] = list[position - 1];
                --position;
            }
            if (position < MAX_PARTNERS) {
                list[position] = Partner(partner, depth);
                if (count < MAX_PARTNERS) ++count;
            }
        }
        state.partnerCount[owner] = uint8(count);
    }

    function _removePartner(Partner[MAX_PARTNERS] storage list, uint256 count, uint32 partner)
        private
        returns (uint256)
    {
        // count <= MAX_PARTNERS
        for (uint256 i; i < count; ++i) {
            if (list[i].token != partner) continue;
            // count <= MAX_PARTNERS
            for (uint256 j = i; j + 1 < count; ++j) {
                list[j] = list[j + 1];
            }
            delete list[count - 1];
            return count - 1;
        }
        return count;
    }
}
