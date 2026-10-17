// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {NetworkState, Pair} from "../../arbitrage/NetworkTypes.sol";
import {MAX_TRIANGLES, MAX_QUADS, MAX_QUAD_FIRST_TOKENS} from "./NetworkConstants.sol";
import {NetworkLibrary} from "./NetworkLibrary.sol";

/// @notice Rebuilds a pair's saved three- and four-pool loops from the capped partner lists.
/// @dev External library: ArbitrageNetwork runs it through delegatecall on its own storage, which keeps the
/// network contract under the size limit. Its work is bounded by MAX_PARTNERS and MAX_QUAD_FIRST_TOKENS, not by
/// the size of the network. Candidates are ranked by their shallowest edge depth in units of the pair's low token,
/// converted with the reserve ratios of each edge's deepest pool.
library LoopRefresh {
    /// @dev Working state of one refresh: the pair, its partner lists, and the best loops found so far.
    struct Refresh {
        uint32 low;
        uint32 high;
        /// @dev Reserves of low and high in the pair's deepest pool; their ratio converts high amounts to low.
        uint256 rootLow;
        uint256 rootHigh;
        uint32[] lowPartners;
        uint32[] highPartners;
        /// @dev lowEdges[i] is the deepest pool of (lowPartners[i], low), read once and shared by all loops.
        Edge[] lowEdges;
        uint32[2][MAX_TRIANGLES] triangles;
        uint256[MAX_TRIANGLES] triangleScores;
        uint256 triangleCount;
        uint32[3][MAX_QUADS] quads;
        uint256[MAX_QUADS] quadScores;
        uint256 quadCount;
    }

    /// @dev The deepest pool of a pair and its reserves at the last read, oriented from one token to the other.
    struct Edge {
        uint32 pool;
        uint256 reserveFrom;
        uint256 reserveTo;
    }

    /// @notice Saves the best loops of pair (low, high), low < high, and records the tokens' revisions.
    function refresh(NetworkState storage state, uint32 low, uint32 high)
        external
        returns (uint8 triangleCount, uint8 quadCount)
    {
        Pair storage pair = state.pairs[NetworkLibrary.pairKey(low, high)];
        Refresh memory context = _begin(state, pair, low, high);
        // Without reserves on both sides there is no rate to compare edges with, so the pair saves no loops.
        if (context.rootLow != 0 && context.rootHigh != 0) {
            _rankTriangles(state, context);
            // MAX_QUAD_FIRST_TOKENS <= MAX_PARTNERS
            for (uint256 i; i < context.highPartners.length && i < MAX_QUAD_FIRST_TOKENS; ++i) {
                _rankQuadsThrough(state, context, context.highPartners[i]);
            }
        }
        _save(pair, context);
        pair.refreshedRevisionLow = state.tokenRevision[low];
        pair.refreshedRevisionHigh = state.tokenRevision[high];
        return (pair.triangleCount, pair.quadCount);
    }

    function _begin(NetworkState storage state, Pair storage pair, uint32 low, uint32 high)
        private
        view
        returns (Refresh memory context)
    {
        context.low = low;
        context.high = high;
        (uint96 reserve0, uint96 reserve1) = NetworkLibrary.deepestReserves(pair);
        bool lowIsToken0 = state.pools[pair.top[0].pool].token0 == low;
        (context.rootLow, context.rootHigh) = lowIsToken0 ? (reserve0, reserve1) : (reserve1, reserve0);
        context.lowPartners = _partnerTokens(state, low);
        context.highPartners = _partnerTokens(state, high);
        context.lowEdges = new Edge[](context.lowPartners.length);
        // lowPartners.length <= MAX_PARTNERS
        for (uint256 i; i < context.lowPartners.length; ++i) {
            context.lowEdges[i] = _edge(state, context.lowPartners[i], low);
        }
    }

    /// @dev Middle tokens come from both partner lists, so a triangle is found from either side of the pair.
    function _rankTriangles(NetworkState storage state, Refresh memory context) private view {
        // lowPartners.length <= MAX_PARTNERS
        for (uint256 i; i < context.lowPartners.length; ++i) {
            uint32 middle = context.lowPartners[i];
            if (middle == context.high) continue;
            _rankTriangle(state, context, middle, context.lowEdges[i]);
        }
        // highPartners.length <= MAX_PARTNERS
        for (uint256 i; i < context.highPartners.length; ++i) {
            uint32 middle = context.highPartners[i];
            if (middle == context.low) continue;
            if (_contains(context.lowPartners, middle)) continue;
            _rankTriangle(state, context, middle, _edge(state, middle, context.low));
        }
    }

    function _rankTriangle(NetworkState storage state, Refresh memory context, uint32 middle, Edge memory middleLow)
        private
        view
    {
        if (middleLow.pool == 0) return;
        Edge memory highMiddle = _edge(state, context.high, middle);
        if (highMiddle.pool == 0) return;
        uint256 highSide = FullMath.mulDiv(highMiddle.reserveFrom, context.rootLow, context.rootHigh);
        uint256 score = _min(middleLow.reserveTo, highSide);
        if (score == 0) return;
        _insertTriangle(context, [highMiddle.pool, middleLow.pool], score);
    }

    /// @dev Four-pool loops low -> high -> first -> second -> low, with second taken from the low partner list.
    function _rankQuadsThrough(NetworkState storage state, Refresh memory context, uint32 first) private view {
        if (first == context.low) return;
        Edge memory highFirst = _edge(state, context.high, first);
        if (highFirst.pool == 0) return;
        uint256 highSide = FullMath.mulDiv(highFirst.reserveFrom, context.rootLow, context.rootHigh);
        // lowPartners.length <= MAX_PARTNERS
        for (uint256 i; i < context.lowPartners.length; ++i) {
            uint32 second = context.lowPartners[i];
            if (second == context.high || second == first) continue;
            _rankQuad(state, context, [highFirst.pool, first, second], highSide, context.lowEdges[i]);
        }
    }

    /// @dev path holds the (high, first) pool, then the first and second middle tokens.
    function _rankQuad(
        NetworkState storage state,
        Refresh memory context,
        uint32[3] memory path,
        uint256 highSide,
        Edge memory secondLow
    ) private view {
        if (secondLow.pool == 0) return;
        Edge memory middle = _edge(state, path[1], path[2]);
        if (middle.pool == 0) return;
        // The middle edge's second-token reserve, in low units at the second-low pool's reserve ratio.
        uint256 middleSide = FullMath.mulDiv(middle.reserveTo, secondLow.reserveTo, secondLow.reserveFrom);
        uint256 score = _min(_min(highSide, secondLow.reserveTo), middleSide);
        if (score == 0) return;
        _insertQuad(context, [path[0], middle.pool, secondLow.pool], score);
    }

    function _insertTriangle(Refresh memory context, uint32[2] memory entry, uint256 score) private pure {
        uint256 count = context.triangleCount;
        uint256 position = count;
        // position <= MAX_TRIANGLES
        while (position > 0 && context.triangleScores[position - 1] < score) {
            if (position < MAX_TRIANGLES) {
                context.triangleScores[position] = context.triangleScores[position - 1];
                context.triangles[position] = context.triangles[position - 1];
            }
            --position;
        }
        if (position >= MAX_TRIANGLES) return;
        context.triangleScores[position] = score;
        context.triangles[position] = entry;
        if (count < MAX_TRIANGLES) context.triangleCount = count + 1;
    }

    function _insertQuad(Refresh memory context, uint32[3] memory entry, uint256 score) private pure {
        uint256 count = context.quadCount;
        uint256 position = count;
        // position <= MAX_QUADS
        while (position > 0 && context.quadScores[position - 1] < score) {
            if (position < MAX_QUADS) {
                context.quadScores[position] = context.quadScores[position - 1];
                context.quads[position] = context.quads[position - 1];
            }
            --position;
        }
        if (position >= MAX_QUADS) return;
        context.quadScores[position] = score;
        context.quads[position] = entry;
        if (count < MAX_QUADS) context.quadCount = count + 1;
    }

    function _save(Pair storage pair, Refresh memory context) private {
        // triangleCount <= MAX_TRIANGLES
        for (uint256 i; i < context.triangleCount; ++i) {
            pair.triangles[i] = context.triangles[i];
        }
        // quadCount <= MAX_QUADS
        for (uint256 i; i < context.quadCount; ++i) {
            pair.quads[i] = context.quads[i];
        }
        pair.triangleCount = uint8(context.triangleCount);
        pair.quadCount = uint8(context.quadCount);
    }

    /// @dev Zero pool when the pair has no listed pool or its deepest pool has a zero reserve: ratios through such an
    /// edge are undefined, and one unusable edge must not stop the refresh of a healthy pair.
    function _edge(NetworkState storage state, uint32 from, uint32 to) private view returns (Edge memory edge) {
        Pair storage pair = state.pairs[NetworkLibrary.pairKey(from, to)];
        (uint96 reserve0, uint96 reserve1) = NetworkLibrary.deepestReserves(pair);
        if (reserve0 == 0 || reserve1 == 0) return edge;
        edge.pool = pair.top[0].pool;
        bool fromIsToken0 = state.pools[edge.pool].token0 == from;
        (edge.reserveFrom, edge.reserveTo) = fromIsToken0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function _partnerTokens(NetworkState storage state, uint32 owner) private view returns (uint32[] memory tokens) {
        tokens = new uint32[](state.partnerCount[owner]);
        // tokens.length <= MAX_PARTNERS
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i] = state.partners[owner][i].token;
        }
    }

    function _contains(uint32[] memory list, uint32 token) private pure returns (bool) {
        // list.length <= MAX_PARTNERS
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == token) return true;
        }
        return false;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
