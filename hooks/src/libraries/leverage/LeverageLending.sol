// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Bin, LeverageBins, LeverageContext, LeverageState} from "./LeverageBins.sol";

/// @dev A lender's request over `binCount` bins from `lowerBin`. The limits are maximums for a deposit and minimums
/// for a withdrawal.
struct BinRequest {
    address account;
    int24 lowerBin;
    uint8 binCount;
    uint128 liquidityPerBin;
    uint256 limit0;
    uint256 limit1;
}

/// @notice Deposits, withdrawals and collections for Leverage, inside its PoolManager unlock. Linked, and
/// delegatecalled by Leverage, whose storage and token balances it runs in.
library LeverageLending {
    error SlippageExceeded();

    /// @notice Adds `liquidityPerBin` to each bin and pulls what the pool charged from the lender.
    function deposit(LeverageState storage state, LeverageContext memory context, BinRequest memory request)
        external
        returns (bytes memory)
    {
        uint256 paid0;
        uint256 paid1;
        // request.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < request.binCount; ++offset) {
            int24 binIndex = LeverageBins.binAt(request.lowerBin, offset);
            (uint256 cost0, uint256 cost1) =
                LeverageBins.addToBin(state, context, request.account, binIndex, request.liquidityPerBin);
            paid0 += cost0;
            paid1 += cost1;
        }
        // Checked after the pool calls: safe under Leverage's publicMutation lock and its own unlock.
        if (paid0 > request.limit0) revert SlippageExceeded();
        if (paid1 > request.limit1) revert SlippageExceeded();
        LeverageBins.pull(context.key.currency0, request.account, paid0);
        LeverageBins.pull(context.key.currency1, request.account, paid1);
        return abi.encode(paid0, paid1);
    }

    /// @notice Removes `liquidityPerBin` of idle liquidity from each bin; the caller pays the lender after settling.
    function withdraw(LeverageState storage state, LeverageContext memory context, BinRequest memory request)
        external
        returns (bytes memory)
    {
        uint256 amount0;
        uint256 amount1;
        // request.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < request.binCount; ++offset) {
            int24 binIndex = LeverageBins.binAt(request.lowerBin, offset);
            (uint256 received0, uint256 received1) =
                LeverageBins.removeFromBin(state, context, request.account, binIndex, request.liquidityPerBin);
            amount0 += received0;
            amount1 += received1;
        }
        // Checked after the pool calls: safe under Leverage's publicMutation lock and its own unlock.
        if (amount0 < request.limit0) revert SlippageExceeded();
        if (amount1 < request.limit1) revert SlippageExceeded();
        return abi.encode(amount0, amount1);
    }

    /// @notice Releases the bins' streams to now, collects their swap fees, and credits the lender's earnings in them
    /// to its owed balance.
    function collect(LeverageState storage state, LeverageContext memory context, BinRequest memory request)
        external
        returns (bytes memory)
    {
        // request.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < request.binCount; ++offset) {
            int24 binIndex = LeverageBins.binAt(request.lowerBin, offset);
            Bin storage target = state.bins[binIndex];
            LeverageBins.checkpoint(state, target);
            // v4 refuses to touch an empty position; a fully borrowed bin has no idle liquidity to earn fees.
            if (target.liquidity != target.borrowed) _pokeFees(state, context, binIndex);
            LeverageBins.accrueLender(state, context, request.account, binIndex);
        }
        return "";
    }

    function _pokeFees(LeverageState storage state, LeverageContext memory context, int24 binIndex) private {
        BalanceDelta principal = LeverageBins.modifyBin(state, context, binIndex, 0);
        // A poke moves only fees. An extension's hook delta here would be paid from other users' custody (audit L1-3).
        if (BalanceDelta.unwrap(principal) != 0) revert LeverageBins.UnexpectedDelta();
    }
}
