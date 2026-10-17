// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {KernelExtension} from "../base/KernelExtension.sol";
import {NetworkState, PoolRecord, TopEntry, Partner, Pair} from "./NetworkTypes.sol";
import {MAX_SYNC_POOLS} from "../libraries/arbitrage/NetworkConstants.sol";
import {NetworkLibrary} from "../libraries/arbitrage/NetworkLibrary.sol";
import {LoopRefresh} from "../libraries/arbitrage/LoopRefresh.sol";
import {NetworkWrites} from "../libraries/arbitrage/NetworkWrites.sol";

/// @notice Directory of Kernel pools for on-chain cycle search: tokens, pools, each pair's deepest pools, each
/// token's deepest partners, and each pair's saved loops through other pairs.
/// @dev Every write is bounded by a cap, so the cost of adding a pool does not grow with the network. Depths come
/// only from live PoolManager reads, never from caller input, so a registrant cannot claim a depth it does not have.
abstract contract NetworkRegistry is KernelExtension {
    using StateLibrary for IPoolManager;

    uint32 public tokenCount;
    uint32 public poolCount;
    mapping(Currency currency => uint32 token) public tokenIdOf;
    mapping(uint32 token => Currency currency) public currencyOf;
    mapping(PoolId id => uint32 pool) public poolIndexOf;
    NetworkState internal _state;

    error AlreadyRegistered();
    error NotRegistered();
    error TooManyPools();

    event PoolRegistered(PoolId indexed id, uint32 indexed pool);
    event PoolUnregistered(PoolId indexed id, uint32 indexed pool);
    event DepthSynced(uint32 indexed pool, uint96 liquidity);
    event LoopsRefreshed(uint32 indexed low, uint32 indexed high, uint8 triangles, uint8 quads);

    constructor(IKernelHook kernel) KernelExtension(kernel) {}

    /// @notice Adds an initialized Kernel pool to the network. A pool role of that pool must call it.
    function register(PoolKey calldata key) external publicMutation returns (uint32 pool) {
        PoolId id = _validateKey(key);
        _requireRole(id);
        if (!KERNEL.isPoolInitialized(id)) revert InvalidPool();
        pool = poolIndexOf[id];
        if (pool == 0) pool = _createRecord(id, key);
        PoolRecord storage record = _state.pools[pool];
        if (record.active) revert AlreadyRegistered();
        record.active = true;
        (uint96 reserve0, uint96 reserve1) = _readReserves(record);
        ++_state.pairs[NetworkLibrary.pairKey(record.token0, record.token1)].activeCount;
        NetworkWrites.place(_state, pool, reserve0, reserve1);
        _bumpRevisions(record);
        emit PoolRegistered(id, pool);
    }

    /// @notice Removes a pool from the network. A pool role of that pool must call it.
    /// @dev Saved loops that use the pool keep it until their pair is refreshed; the search skips inactive pools.
    function unregister(PoolId id) external publicMutation {
        _requireRole(id);
        uint32 pool = poolIndexOf[id];
        PoolRecord storage record = _state.pools[pool];
        if (!record.active) revert NotRegistered();
        record.active = false;
        --_state.pairs[NetworkLibrary.pairKey(record.token0, record.token1)].activeCount;
        NetworkWrites.remove(_state, pool);
        _bumpRevisions(record);
        emit PoolUnregistered(id, pool);
    }

    /// @notice Rereads the live liquidity of registered pools and reorders the lists that hold them.
    /// @dev Anyone can call it. It also refills a pair's list after a removal left a gap.
    function syncDepth(uint32[] calldata pools) external publicMutation {
        if (pools.length > MAX_SYNC_POOLS) revert TooManyPools();
        // pools.length <= MAX_SYNC_POOLS
        for (uint256 i; i < pools.length; ++i) {
            PoolRecord storage record = _state.pools[pools[i]];
            if (!record.active) revert NotRegistered();
            (uint96 reserve0, uint96 reserve1) = _readReserves(record);
            NetworkWrites.place(_state, pools[i], reserve0, reserve1);
            emit DepthSynced(pools[i], record.liquidity);
        }
    }

    /// @notice Recomputes a pair's saved three- and four-pool loops from the capped partner lists.
    /// @dev Anyone can call it, and the caller pays; a swap never runs it. See LoopRefresh for the bounds.
    function refresh(uint32 tokenA, uint32 tokenB) external publicMutation {
        (uint32 low, uint32 high) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (_state.pairs[NetworkLibrary.pairKey(low, high)].topCount == 0) revert NotRegistered();
        (uint8 triangles, uint8 quads) = LoopRefresh.refresh(_state, low, high);
        emit LoopsRefreshed(low, high, triangles, quads);
    }

    function poolRecord(uint32 pool) external view returns (PoolRecord memory) {
        return _state.pools[pool];
    }

    function tokenRevision(uint32 token) external view returns (uint64) {
        return _state.tokenRevision[token];
    }

    /// @notice A pair's deepest registered pools, deepest first, and its number of active pools.
    function pairTop(uint32 tokenA, uint32 tokenB) external view returns (TopEntry[] memory entries, uint32 active) {
        Pair storage pair = _state.pairs[NetworkLibrary.pairKey(tokenA, tokenB)];
        entries = new TopEntry[](pair.topCount);
        // entries.length <= MAX_TOP_POOLS
        for (uint256 i; i < entries.length; ++i) {
            entries[i] = pair.top[i];
        }
        active = pair.activeCount;
    }

    /// @notice A token's deepest partners, deepest first.
    function partners(uint32 token) external view returns (Partner[] memory entries) {
        entries = new Partner[](_state.partnerCount[token]);
        // entries.length <= MAX_PARTNERS
        for (uint256 i; i < entries.length; ++i) {
            entries[i] = _state.partners[token][i];
        }
    }

    /// @notice A pair's saved loops and the token revisions they were built from.
    function pairLoops(uint32 tokenA, uint32 tokenB)
        external
        view
        returns (uint32[2][] memory triangles, uint32[3][] memory quads, uint64 revisionLow, uint64 revisionHigh)
    {
        Pair storage pair = _state.pairs[NetworkLibrary.pairKey(tokenA, tokenB)];
        triangles = new uint32[2][](pair.triangleCount);
        // triangles.length <= MAX_TRIANGLES
        for (uint256 i; i < triangles.length; ++i) {
            triangles[i] = pair.triangles[i];
        }
        quads = new uint32[3][](pair.quadCount);
        // quads.length <= MAX_QUADS
        for (uint256 i; i < quads.length; ++i) {
            quads[i] = pair.quads[i];
        }
        return (triangles, quads, pair.refreshedRevisionLow, pair.refreshedRevisionHigh);
    }

    function _createRecord(PoolId id, PoolKey calldata key) private returns (uint32 pool) {
        pool = ++poolCount;
        poolIndexOf[id] = pool;
        PoolRecord storage record = _state.pools[pool];
        record.id = id;
        record.token0 = _tokenId(key.currency0);
        record.token1 = _tokenId(key.currency1);
        record.fee = key.fee;
        record.tickSpacing = key.tickSpacing;
    }

    function _tokenId(Currency currency) private returns (uint32 token) {
        token = tokenIdOf[currency];
        if (token != 0) return token;
        token = ++tokenCount;
        tokenIdOf[currency] = token;
        currencyOf[token] = currency;
    }

    /// @dev Stores the live liquidity and returns the live virtual reserves, each from the full-width liquidity and
    /// price and saturated on its own, so a saturated value never distorts the other.
    function _readReserves(PoolRecord storage record) private returns (uint96 reserve0, uint96 reserve1) {
        (uint160 sqrtPriceX96,,,) = MANAGER.getSlot0(record.id);
        uint128 liquidity = MANAGER.getLiquidity(record.id);
        record.liquidity = NetworkLibrary.saturate96(liquidity);
        reserve0 = NetworkLibrary.saturate96(FullMath.mulDiv(liquidity, 1 << 96, sqrtPriceX96));
        reserve1 = NetworkLibrary.saturate96(FullMath.mulDiv(liquidity, sqrtPriceX96, 1 << 96));
    }

    function _bumpRevisions(PoolRecord storage record) private {
        ++_state.tokenRevision[record.token0];
        ++_state.tokenRevision[record.token1];
    }
}
