// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// The parts of Metric's pool interface the vault uses, from Metricxyz/pool-contracts at 99aa896 (MIT-licensed
// interface and type files): `IMetricOmmPoolActions`, `IMetricOmmPool`, `IExtsload`, the two callbacks,
// `LiquidityDelta` and `PoolImmutables`.

/// @notice The part of Metric's pool factory the vault uses (`IMetricOmmPoolFactory.isPool`): whether it deployed a
/// pool, so the pool's code is Metric's own.
interface IMetricPoolFactory {
    function isPool(address pool) external view returns (bool);
}

/// @notice Batched per-bin liquidity add or remove payload (parallel arrays).
struct LiquidityDelta {
    int256[] binIdxs;
    uint256[] shares;
}

struct PoolImmutables {
    address factory;
    address token0;
    address token1;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
    uint256 initialScaledToken0PerShareE18;
    uint256 initialScaledToken1PerShareE18;
    uint256 minimalOperationalLiquidity;
    address immutablePriceProvider;
    int256 lowestBin;
    int256 highestBin;
    address extension1;
    address extension2;
    address extension3;
    address extension4;
    address extension5;
    address extension6;
    address extension7;
    uint256 beforeAddLiquidityOrder;
    uint256 afterAddLiquidityOrder;
    uint256 beforeRemoveLiquidityOrder;
    uint256 afterRemoveLiquidityOrder;
    uint256 beforeSwapOrder;
    uint256 afterSwapOrder;
}

interface IMetricPool {
    /// @notice Adds liquidity for `owner`; the caller pays in `metricOmmModifyLiquidityCallback`.
    function addLiquidity(
        address owner,
        uint80 salt,
        LiquidityDelta calldata deltas,
        bytes calldata callbackData,
        bytes calldata extensionData
    ) external returns (uint256 amount0Added, uint256 amount1Added);

    /// @notice Removes `owner`'s liquidity; only `owner` may call. Pays the caller.
    function removeLiquidity(address owner, uint80 salt, LiquidityDelta calldata deltas, bytes calldata extensionData)
        external
        returns (uint256 amount0Removed, uint256 amount1Removed);

    /// @notice Swaps. `amountSpecified` positive is exact input, negative exact output; partial fills succeed.
    /// Deltas are from the pool's side: positive means the pool receives. Output is sent before the callback.
    function swap(
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        bytes calldata callbackData,
        bytes calldata extensionData
    ) external returns (int128 amount0Delta, int128 amount1Delta);

    function getImmutables() external view returns (PoolImmutables memory);

    /// @notice Fee-inclusive marginal prices at the current position in the bins, whole token1 per whole token0 in
    /// Q64.64. Takes the pool's swap lock, so the provider's oracle read succeeds.
    function getSellAndBuyPrices() external returns (uint128 sellPriceX64, uint128 buyPriceX64);

    function extsload(bytes32 slot) external view returns (bytes32);

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory);
}

interface IMetricSwapCallback {
    function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata callbackData) external;
}

interface IMetricLiquidityCallback {
    function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata callbackData)
        external;
}
