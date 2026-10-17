// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "oz/contracts/utils/math/SafeCast.sol";
import {LeverageMath} from "./LeverageMath.sol";
import {Bin, Borrow, LeverageBins, LeverageContext, LeverageState, Position} from "./LeverageBins.sol";

struct OpenRequest {
    int24 lowerBin;
    /// @dev Liquidity borrowed from each consecutive bin, starting at lowerBin.
    uint128[] liquidity;
    /// @dev True to hold the base asset after the entry swap, false to hold the quote currency.
    bool long;
    uint128 collateral;
    uint128 premium;
    uint160 sqrtPriceLimitX96;
}

struct CloseRequest {
    uint256 positionId;
    uint256 fractionWad;
    uint256 minimumProceeds;
    /// @dev Zero for the owner's close; the caller for a force close.
    address closer;
    bool atStrike;
    uint256 maximumPaid;
}

struct CloseResult {
    /// @dev The quote the owner ends with from the closed part.
    uint256 proceeds;
    /// @dev Owed to the owner's recipient by the caller: proceeds plus, on a full close, the escrow refund. Zero for a
    /// force close, which credits the owner instead.
    uint256 payout;
    uint256 share;
    /// @dev The quote part of a force close's reward; the closer also gets its base part.
    uint256 reward;
    uint256 closerOut0;
    uint256 closerOut1;
}

/// @notice Opens and closes positions for Leverage, inside its PoolManager unlock. Linked, and delegatecalled by
/// Leverage, whose storage and token balances it runs in.
library LeverageEngine {
    using SafeCast for uint256;

    /// @dev v4 rounds each bin's add up by at most a wei per token against extremes rounded down at open, and the
    /// strike output floors once more: two wei of each token per bin. _dustLimit values
    /// both tokens' dust in the token the closer tops up, at the strike.
    uint256 internal constant MAX_CLOSE_DUST_PER_BIN = 2;
    uint256 internal constant WAD = LeverageMath.WAD;
    uint256 internal constant BPS = LeverageMath.BPS;

    /// @dev What a close owes and holds, in memory while it runs.
    struct Settlement {
        uint256 fractionWad;
        uint256[] premiumByBin;
        /// @dev The quote notional of the liquidity this close returned to each bin, which weights the lenders' part
        /// of the profit share.
        uint256[] notionalByBin;
        uint256 premiumOwed;
        uint256 premiumFromEscrow;
        uint256 notionalTotal;
        uint256 portion0;
        uint256 portion1;
        uint256 cost0;
        uint256 cost1;
    }

    error Undercollateralized();
    error InsufficientProceeds();
    error SlippageExceeded();
    error InvalidAmount();
    /// @dev A partial close's proceeds do not cover the position's unpaid premium: add premium, or close in full.
    error PremiumUnpaid();
    /// @dev The borrow, or what a partial close leaves, is below the deployment's minimum quote notional.
    error BelowMinimumBorrow();

    event Closed(uint256 indexed positionId, address closer, uint256 fractionWad, uint256 proceeds, uint256 share);
    event PremiumSettled(uint256 indexed positionId, uint256 amount);

    /// @notice Borrows the bins' liquidity, adds the collateral and runs the entry swap; the chord must then hold.
    function open(
        LeverageState storage state,
        LeverageContext memory context,
        address owner,
        uint256 positionId,
        OpenRequest memory request
    ) external {
        Position storage position = state.positions[positionId];
        position.owner = owner;
        position.lowerBin = request.lowerBin;
        position.binCount = uint8(request.liquidity.length);
        _borrowBins(state, context, positionId, request.liquidity);
        LeverageBins.pull(LeverageBins.quote(context), owner, uint256(request.collateral) + request.premium);
        _addQuoteReserve(context, position, request.collateral);
        position.collateral = request.collateral;
        position.escrow = request.premium;
        _entrySwap(context, position, request.long, request.sqrtPriceLimitX96);
        // Checked after the pool calls and pulls: safe under Leverage's publicMutation lock and its own unlock.
        _requireStrike(context, position);
        _requireSolvent(position);
        ++state.openPositions;
    }

    /// @notice Closes `fractionWad` of a position. The owner's close sells everything into quote through the pool. A
    /// force close buys only the deficit and settles the rest in kind; it runs at the strike only as a fallback.
    function close(LeverageState storage state, LeverageContext memory context, CloseRequest memory request)
        external
        returns (CloseResult memory result)
    {
        Settlement memory settlement = _startClose(state, context, request.positionId, request.fractionWad);
        if (request.closer == address(0)) {
            uint256 quoteProceeds = _recomposeThroughPool(context, settlement);
            _finishOwnerClose(state, context, request, settlement, quoteProceeds, result);
        } else {
            uint256[2] memory left = request.atStrike
                ? _recomposeAtStrike(state, context, request, settlement, result)
                : _buyDeficit(context, settlement);
            _finishForceClose(state, context, request, settlement, left, result);
        }
        emit Closed(request.positionId, request.closer, request.fractionWad, result.proceeds, result.share);
    }

    /// @notice Pays a position's accrued premium from its escrow, or nothing if the escrow cannot cover it.
    function settleEscrow(LeverageState storage state, LeverageContext memory context, uint256 positionId)
        external
        returns (uint256)
    {
        Position storage position = state.positions[positionId];
        if (premiumOwed(state, context, positionId) > position.escrow) return 0;
        Settlement memory settlement;
        _accruePremium(state, context, positionId, settlement);
        _creditPremium(state, context, position, settlement, settlement.premiumFromEscrow);
        emit PremiumSettled(positionId, settlement.premiumFromEscrow);
        return settlement.premiumFromEscrow;
    }

    /// @notice Premium accrued since the position's last settlement, at the bins' current rate indices.
    function premiumOwed(LeverageState storage state, LeverageContext memory context, uint256 positionId)
        public
        view
        returns (uint256 total)
    {
        Position storage position = state.positions[positionId];
        // position.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < position.binCount; ++offset) {
            Borrow storage borrowed = state.borrows[positionId][offset];
            if (borrowed.liquidity == 0) continue;
            int24 binIndex = LeverageBins.binAt(position.lowerBin, offset);
            uint256 indexDeltaRay = LeverageBins.currentRateIndex(state, state.bins[binIndex]) - borrowed.rateIndexRay;
            total += LeverageBins.premium(state, context, binIndex, borrowed.liquidity, indexDeltaRay);
        }
    }

    // ---------------------------------------------------------------- opening

    function _borrowBins(
        LeverageState storage state,
        LeverageContext memory context,
        uint256 positionId,
        uint128[] memory liquidity
    ) private {
        Position storage position = state.positions[positionId];
        uint256[4] memory sums; // reserve0, reserve1, maximum0, maximum1
        // liquidity.length <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < liquidity.length; ++offset) {
            if (liquidity[offset] == 0) revert InvalidAmount();
            int24 binIndex = LeverageBins.binAt(position.lowerBin, offset);
            (uint256 amount0, uint256 amount1) = LeverageBins.borrowFromBin(state, context, binIndex, liquidity[offset]);
            state.borrows[positionId][offset] = Borrow(liquidity[offset], state.bins[binIndex].rateIndexRay);
            (uint256 maximum0, uint256 maximum1) = LeverageBins.extremesOf(state, context, binIndex, liquidity[offset]);
            sums[0] += amount0;
            sums[1] += amount1;
            sums[2] += maximum0;
            sums[3] += maximum1;
        }
        position.reserve0 = sums[0].toUint128();
        position.reserve1 = sums[1].toUint128();
        position.maximum0 = sums[2].toUint128();
        position.maximum1 = sums[3].toUint128();
    }

    /// @dev The entry swap is the only reserve change at open. Manipulating it gains the trader nothing: the basis is
    /// the collateral deposited, and the chord is checked after it.
    function _entrySwap(LeverageContext memory context, Position storage position, bool long, uint160 limitX96)
        private
    {
        // A long holds the base asset, so it sells its quote; a short sells its base.
        bool zeroForOne = long == context.quoteIsCurrency0;
        uint256 amountIn = zeroForOne ? position.reserve0 : position.reserve1;
        if (amountIn == 0) return;
        BalanceDelta delta = LeverageBins.swap(context, zeroForOne, -amountIn.toInt256(), limitX96);
        position.reserve0 = _applyDelta(position.reserve0, delta.amount0()).toUint128();
        position.reserve1 = _applyDelta(position.reserve1, delta.amount1()).toUint128();
    }

    // ---------------------------------------------------------------- closing

    function _startClose(
        LeverageState storage state,
        LeverageContext memory context,
        uint256 positionId,
        uint256 fractionWad
    ) private returns (Settlement memory settlement) {
        Position storage position = state.positions[positionId];
        settlement.fractionWad = fractionWad;
        _accruePremium(state, context, positionId, settlement);
        _returnLiquidity(state, context, positionId, settlement);
        settlement.portion0 = LeverageMath.portionDown(position.reserve0, fractionWad);
        settlement.portion1 = LeverageMath.portionDown(position.reserve1, fractionWad);
        position.reserve0 -= uint128(settlement.portion0);
        position.reserve1 -= uint128(settlement.portion1);
    }

    /// @dev Settles all accrued premium, for the whole position: the escrow pays what it can, and a close pays the
    /// rest from its proceeds. A covered position is no longer delinquent, so its flag clears and a later relapse
    /// waits out a fresh grace period.
    function _accruePremium(
        LeverageState storage state,
        LeverageContext memory context,
        uint256 positionId,
        Settlement memory settlement
    ) private {
        Position storage position = state.positions[positionId];
        settlement.premiumByBin = new uint256[](position.binCount);
        // position.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < position.binCount; ++offset) {
            uint256 premium = _accrueBorrow(state, context, positionId, offset);
            settlement.premiumByBin[offset] = premium;
            settlement.premiumOwed += premium;
        }
        uint256 escrow = position.escrow;
        uint256 fromEscrow = settlement.premiumOwed < escrow ? settlement.premiumOwed : escrow;
        position.escrow = uint128(escrow - fromEscrow);
        position.premiumPaid += uint128(fromEscrow);
        settlement.premiumFromEscrow = fromEscrow;
        if (settlement.premiumOwed <= escrow) position.delinquentSince = 0;
    }

    function _accrueBorrow(
        LeverageState storage state,
        LeverageContext memory context,
        uint256 positionId,
        uint256 offset
    ) private returns (uint256 premium) {
        Borrow storage borrowed = state.borrows[positionId][offset];
        int24 binIndex = LeverageBins.binAt(state.positions[positionId].lowerBin, offset);
        Bin storage target = state.bins[binIndex];
        LeverageBins.checkpoint(state, target);
        if (borrowed.liquidity == 0) return 0;
        premium = LeverageBins.premium(
            state, context, binIndex, borrowed.liquidity, target.rateIndexRay - borrowed.rateIndexRay
        );
        borrowed.rateIndexRay = target.rateIndexRay;
    }

    /// @dev Returns `fractionWad` of every borrow, rounded up, so lenders get back at least their share.
    function _returnLiquidity(
        LeverageState storage state,
        LeverageContext memory context,
        uint256 positionId,
        Settlement memory settlement
    ) private {
        Position storage position = state.positions[positionId];
        settlement.notionalByBin = new uint256[](position.binCount);
        // position.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < position.binCount; ++offset) {
            Borrow storage borrowed = state.borrows[positionId][offset];
            uint128 returned = uint128(LeverageMath.portionUp(borrowed.liquidity, settlement.fractionWad));
            if (returned == 0) continue;
            int24 binIndex = LeverageBins.binAt(position.lowerBin, offset);
            (uint256 cost0, uint256 cost1) = LeverageBins.returnToBin(state, context, binIndex, returned);
            borrowed.liquidity -= returned;
            settlement.cost0 += cost0;
            settlement.cost1 += cost1;
            uint256 notional = _quoteNotional(state, context, binIndex, returned);
            settlement.notionalByBin[offset] = notional;
            settlement.notionalTotal += notional;
        }
    }

    /// @dev The liquidity is already back, so the pool is at full depth for this swap. One swap leaves the closed
    /// portion holding only quote: it sells the base surplus, or buys the base deficit with quote.
    function _recomposeThroughPool(LeverageContext memory context, Settlement memory settlement)
        private
        returns (uint256)
    {
        (uint256 basePortion, uint256 baseCost) = context.quoteIsCurrency0
            ? (settlement.portion1, settlement.cost1)
            : (settlement.portion0, settlement.cost0);
        (uint256 quotePortion, uint256 quoteCost) =
            context.quoteIsCurrency0 ? (settlement.portion0, settlement.cost0) : (settlement.portion1, settlement.cost1);
        int256 quoteNet = quotePortion.toInt256() - quoteCost.toInt256();
        if (basePortion > baseCost) quoteNet += _tradeBase(context, true, basePortion - baseCost);
        if (basePortion < baseCost) quoteNet += _tradeBase(context, false, baseCost - basePortion);
        if (quoteNet < 0) revert InsufficientProceeds();
        return uint256(quoteNet);
    }

    /// @dev Sells exactly `baseAmount` (exact input) or buys exactly `baseAmount` (exact output), and returns the
    /// signed quote delta.
    function _tradeBase(LeverageContext memory context, bool sell, uint256 baseAmount)
        private
        returns (int256 quoteDelta)
    {
        // The base asset is currency0 when the quote is currency1.
        bool zeroForOne = sell != context.quoteIsCurrency0;
        int256 amountSpecified = sell ? -baseAmount.toInt256() : baseAmount.toInt256();
        BalanceDelta delta = LeverageBins.swap(context, zeroForOne, amountSpecified, _limit(zeroForOne));
        (int128 baseDelta, int128 quoteAmount) =
            context.quoteIsCurrency0 ? (delta.amount1(), delta.amount0()) : (delta.amount0(), delta.amount1());
        // The pool moved exactly the base asked for, so no other position's custody covers a short fill. Checked after
        // the swap: safe under Leverage's publicMutation lock and its own unlock.
        if (int256(baseDelta) != amountSpecified) revert LeverageBins.UnexpectedDelta();
        return quoteAmount;
    }

    function _finishOwnerClose(
        LeverageState storage state,
        LeverageContext memory context,
        CloseRequest memory request,
        Settlement memory settlement,
        uint256 quoteProceeds,
        CloseResult memory result
    ) private {
        Position storage position = state.positions[request.positionId];
        uint256 proceeds = _payPremium(state, context, position, settlement, quoteProceeds);
        uint256 basis = _closeBasis(position, request.fractionWad);
        uint256 share = proceeds > basis ? (proceeds - basis) * context.profitShareBps / BPS : 0;
        _distributeShare(state, context, position, settlement, share);
        result.share = share;
        proceeds -= share;
        if (proceeds < request.minimumProceeds) revert InsufficientProceeds();
        result.proceeds = proceeds;
        result.payout = proceeds + _shrinkOrDelete(state, context, request.positionId, request.fractionWad);
    }

    /// @dev Premium the escrow could not cover comes out of the close's proceeds. A partial close must pay all of it:
    /// what it left unpaid would be forgiven while the rest stays open (audit L1-1). What a full close cannot cover is
    /// lost to the lenders; the liquidity itself always returns in full.
    function _payPremium(
        LeverageState storage state,
        LeverageContext memory context,
        Position storage position,
        Settlement memory settlement,
        uint256 available
    ) private returns (uint256) {
        uint256 unpaid = settlement.premiumOwed - settlement.premiumFromEscrow;
        if (settlement.fractionWad != WAD) {
            if (unpaid > available) revert PremiumUnpaid();
            position.delinquentSince = 0;
        }
        uint256 fromProceeds = unpaid < available ? unpaid : available;
        _creditPremium(state, context, position, settlement, settlement.premiumFromEscrow + fromProceeds);
        return available - fromProceeds;
    }

    // ---------------------------------------------------------------- force closing

    /// @dev Buys exactly the deficit the liquidity's return left. The liquidity just returned holds that much of the
    /// token, so depth cannot make this fail; only fees on a position at the chord's edge can, and then the strike
    /// fallback runs. No surplus is sold: what is left settles in kind, out of reach of a closer's price (audit L2-1).
    function _buyDeficit(LeverageContext memory context, Settlement memory settlement)
        private
        returns (uint256[2] memory left)
    {
        uint256[2] memory held = [settlement.portion0, settlement.portion1];
        uint256[2] memory needed = [settlement.cost0, settlement.cost1];
        uint256 deficitIndex = held[0] < needed[0] ? 0 : 1;
        if (held[deficitIndex] < needed[deficitIndex]) {
            _buyExactly(context, held, deficitIndex, needed[deficitIndex] - held[deficitIndex]);
        }
        // The deficit's price must leave the other token's cost covered; if not, the strike fallback runs.
        if (held[1 - deficitIndex] < needed[1 - deficitIndex]) revert InsufficientProceeds();
        return [held[0] - needed[0], held[1] - needed[1]];
    }

    function _buyExactly(LeverageContext memory context, uint256[2] memory held, uint256 index, uint256 amount)
        private
    {
        // Buying currency1 pays currency0.
        bool zeroForOne = index == 1;
        BalanceDelta delta = LeverageBins.swap(context, zeroForOne, amount.toInt256(), _limit(zeroForOne));
        (int128 bought, int128 paid) =
            index == 0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // Checked after the swap: safe under Leverage's publicMutation lock and its own unlock. A short fill, or a
        // price the other token cannot pay, sends the force close to the strike fallback.
        if (int256(bought) != amount.toInt256()) revert LeverageBins.UnexpectedDelta();
        uint256 spent = LeverageBins.spent(paid);
        if (spent > held[1 - index]) revert InsufficientProceeds();
        held[index] += amount;
        held[1 - index] -= spent;
    }

    function _recomposeAtStrike(
        LeverageState storage state,
        LeverageContext memory context,
        CloseRequest memory request,
        Settlement memory settlement,
        CloseResult memory result
    ) private returns (uint256[2] memory) {
        Position storage position = state.positions[request.positionId];
        uint256[2] memory held = [settlement.portion0, settlement.portion1];
        uint256[2] memory needed = [settlement.cost0, settlement.cost1];
        (uint256[2] memory paid, uint256[2] memory strikeOut) = _strikeSwap(held, needed, position);
        if (paid[0] > request.maximumPaid) revert SlippageExceeded();
        if (paid[1] > request.maximumPaid) revert SlippageExceeded();
        LeverageBins.pull(context.key.currency0, request.closer, paid[0]);
        LeverageBins.pull(context.key.currency1, request.closer, paid[1]);
        result.closerOut0 = strikeOut[0];
        result.closerOut1 = strikeOut[1];
        return [held[0] - needed[0], held[1] - needed[1]];
    }

    /// @dev A solvent position is short at most one token, and buying exactly that deficit at the
    /// strike `K = M1 / M0` covers both, up to rounding dust. The closer's capture is bounded by the deficit: it
    /// can never convert the whole reserve at the strike. The closer bears the dust both ways, a strike output capped
    /// at the surplus and a top-up of the other token, so a position on the chord's edge still closes.
    function _strikeSwap(uint256[2] memory held, uint256[2] memory needed, Position storage position)
        private
        view
        returns (uint256[2] memory paid, uint256[2] memory strikeOut)
    {
        uint256 deficitIndex = held[0] < needed[0] ? 0 : 1;
        uint256 otherIndex = 1 - deficitIndex;
        uint256 deficit = needed[deficitIndex] > held[deficitIndex] ? needed[deficitIndex] - held[deficitIndex] : 0;
        uint256 output = _strikeOutput(position, deficitIndex, deficit);
        if (output > held[otherIndex]) output = held[otherIndex];
        held[deficitIndex] += deficit;
        held[otherIndex] -= output;
        uint256 dust = needed[otherIndex] > held[otherIndex] ? needed[otherIndex] - held[otherIndex] : 0;
        if (dust > _dustLimit(position, otherIndex)) revert Undercollateralized();
        held[otherIndex] += dust;
        paid[deficitIndex] = deficit;
        paid[otherIndex] = dust;
        strikeOut[otherIndex] = output;
    }

    /// @dev The most a solvent position can be short in currency `index` after the strike swap: two wei of each token
    /// per bin, the other token's counted at the strike and rounded up.
    function _dustLimit(Position storage position, uint256 index) private view returns (uint256) {
        uint256 dustPerToken = MAX_CLOSE_DUST_PER_BIN * position.binCount;
        if (index == 1) {
            return dustPerToken + FullMath.mulDivRoundingUp(dustPerToken, position.maximum1, position.maximum0);
        }
        return dustPerToken + FullMath.mulDivRoundingUp(dustPerToken, position.maximum0, position.maximum1);
    }

    /// @dev What the strike `K = M1 / M0` pays for `amountIn` of currency `inIndex`, rounded down.
    function _strikeOutput(Position storage position, uint256 inIndex, uint256 amountIn)
        private
        view
        returns (uint256)
    {
        if (amountIn == 0) return 0;
        if (inIndex == 0) return FullMath.mulDiv(amountIn, position.maximum1, position.maximum0);
        return FullMath.mulDiv(amountIn, position.maximum0, position.maximum1);
    }

    /// @dev Settles what a force close left, in kind: the closer's reward, the premium, the profit share, then the
    /// owner, credited both tokens.
    function _finishForceClose(
        LeverageState storage state,
        LeverageContext memory context,
        CloseRequest memory request,
        Settlement memory settlement,
        uint256[2] memory left,
        CloseResult memory result
    ) private {
        Position storage position = state.positions[request.positionId];
        address owner = position.owner;
        uint256 quoteIndex = context.quoteIsCurrency0 ? 0 : 1;
        _takeReward(state, left, result, quoteIndex);
        uint256 unpaid = settlement.premiumOwed - settlement.premiumFromEscrow;
        uint256 share = _strikeShare(context, position, left, unpaid, quoteIndex);
        _raiseQuote(context, position, left, unpaid + share, quoteIndex);
        uint256 premiumPaid = unpaid < left[quoteIndex] ? unpaid : left[quoteIndex];
        left[quoteIndex] -= premiumPaid;
        _creditPremium(state, context, position, settlement, settlement.premiumFromEscrow + premiumPaid);
        result.share = share < left[quoteIndex] ? share : left[quoteIndex];
        left[quoteIndex] -= result.share;
        _distributeShare(state, context, position, settlement, result.share);
        result.proceeds = left[quoteIndex];
        left[quoteIndex] += _deletePosition(state, request.positionId);
        // Credited, so a token that blocks the owner cannot strand the close.
        LeverageBins.credit(state, owner, left[0], left[1]);
    }

    /// @dev The reward is a share of each leftover token, so it needs no price. Taken before premium, so a closer is
    /// paid however deep the delinquency (audit L1-4).
    function _takeReward(
        LeverageState storage state,
        uint256[2] memory left,
        CloseResult memory result,
        uint256 quoteIndex
    ) private view {
        uint256 rewardBps = LeverageBins.currentCurve(state).forceCloseRewardBps;
        uint256 reward0 = left[0] * rewardBps / BPS;
        uint256 reward1 = left[1] * rewardBps / BPS;
        left[0] -= reward0;
        left[1] -= reward1;
        result.closerOut0 += reward0;
        result.closerOut1 += reward1;
        result.reward = quoteIndex == 0 ? reward0 : reward1;
    }

    /// @dev A force close's profit counts the base left at the strike, the one price no closer can move. It undercounts
    /// a winning long's profit, in the owner's favor.
    function _strikeShare(
        LeverageContext memory context,
        Position storage position,
        uint256[2] memory left,
        uint256 unpaid,
        uint256 quoteIndex
    ) private returns (uint256) {
        uint256 value =
            left[quoteIndex] + _strikeOutput(position, 1 - quoteIndex, left[1 - quoteIndex]);
        uint256 basis = _closeBasis(position, WAD) + unpaid;
        if (value <= basis) return 0;
        return (value - basis) * context.profitShareBps / BPS;
    }

    /// @dev Sells base for the quote the premium and the share need, sized at the strike and capped at the base left.
    /// Exact input never spends more than asked; a short fill only raises less, which leaves premium and share
    /// partly unpaid rather than sending the close to the fallback.
    function _raiseQuote(
        LeverageContext memory context,
        Position storage position,
        uint256[2] memory left,
        uint256 neededQuote,
        uint256 quoteIndex
    ) private {
        if (left[quoteIndex] >= neededQuote) return;
        uint256 baseIndex = 1 - quoteIndex;
        // One unit more than the strike's floor.
        uint256 baseAmount = _strikeOutput(position, quoteIndex, neededQuote - left[quoteIndex]) + 1;
        if (baseAmount > left[baseIndex]) baseAmount = left[baseIndex];
        if (baseAmount == 0) return;
        bool zeroForOne = baseIndex == 0;
        BalanceDelta delta = LeverageBins.swap(context, zeroForOne, -baseAmount.toInt256(), _limit(zeroForOne));
        left[0] = _applyDelta(left[0], delta.amount0());
        left[1] = _applyDelta(left[1], delta.amount1());
    }

    // ---------------------------------------------------------------- premium and share

    function _creditPremium(
        LeverageState storage state,
        LeverageContext memory context,
        Position storage position,
        Settlement memory settlement,
        uint256 paid
    ) private {
        if (paid == 0) return;
        // position.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < position.binCount; ++offset) {
            uint256 owedByBin = settlement.premiumByBin[offset];
            if (owedByBin == 0) continue;
            uint256 credit =
                paid == settlement.premiumOwed ? owedByBin : FullMath.mulDiv(owedByBin, paid, settlement.premiumOwed);
            Bin storage target = state.bins[LeverageBins.binAt(position.lowerBin, offset)];
            LeverageBins.fundStream(target, credit, context.vestSeconds);
        }
    }

    /// @dev The lenders' part goes to the bins this close returned liquidity to, by that liquidity's quote notional,
    /// and vests there like premium. Liquidity far from the price cannot take it (audit L1-2), nor a deposit made at
    /// the close (audit L3-2). A close that returned no notional has no lenders of its own: the treasury takes it.
    function _distributeShare(
        LeverageState storage state,
        LeverageContext memory context,
        Position storage position,
        Settlement memory settlement,
        uint256 share
    ) private {
        if (share == 0) return;
        (uint256 lenderPart, uint256 treasuryPart, uint256 feeVaultPart) =
            LeverageMath.splitShare(share, context.treasuryShareBps, context.feeVaultShareBps);
        if (settlement.notionalTotal == 0) treasuryPart += lenderPart;
        else _streamByNotional(state, context, position, settlement, lenderPart);
        LeverageBins.creditQuote(state, context, context.treasury, treasuryPart);
        LeverageBins.creditQuote(state, context, context.feeVault, feeVaultPart);
    }

    /// @dev Rounds down per bin: never streams more than lenderPart; the dust stays in this contract.
    function _streamByNotional(
        LeverageState storage state,
        LeverageContext memory context,
        Position storage position,
        Settlement memory settlement,
        uint256 lenderPart
    ) private {
        // position.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < position.binCount; ++offset) {
            uint256 notional = settlement.notionalByBin[offset];
            if (notional == 0) continue;
            uint256 part = FullMath.mulDiv(lenderPart, notional, settlement.notionalTotal);
            Bin storage target = state.bins[LeverageBins.binAt(position.lowerBin, offset)];
            LeverageBins.fundStream(target, part, context.vestSeconds);
        }
    }

    /// @dev The cost basis splits with the position, so each partial close pays the share on its own portion only.
    function _closeBasis(Position storage position, uint256 fractionWad) private returns (uint256) {
        uint256 collateralPortion = LeverageMath.portionDown(position.collateral, fractionWad);
        uint256 premiumPortion = LeverageMath.portionDown(position.premiumPaid, fractionWad);
        position.collateral -= uint128(collateralPortion);
        position.premiumPaid -= uint128(premiumPortion);
        return collateralPortion + premiumPortion;
    }

    /// @dev A full close refunds the escrow; a partial close leaves it with the part still open (Q12). The remainder
    /// keeps its own liquidity, so its extremes are recomputed from it, not scaled.
    function _shrinkOrDelete(
        LeverageState storage state,
        LeverageContext memory context,
        uint256 positionId,
        uint256 fractionWad
    ) private returns (uint256 refund) {
        Position storage position = state.positions[positionId];
        if (fractionWad == WAD) return _deletePosition(state, positionId);
        uint256 maximum0;
        uint256 maximum1;
        // position.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < position.binCount; ++offset) {
            uint128 liquidity = state.borrows[positionId][offset].liquidity;
            int24 binIndex = LeverageBins.binAt(position.lowerBin, offset);
            (uint256 binMaximum0, uint256 binMaximum1) = LeverageBins.extremesOf(state, context, binIndex, liquidity);
            maximum0 += binMaximum0;
            maximum1 += binMaximum1;
        }
        position.maximum0 = maximum0.toUint128();
        position.maximum1 = maximum1.toUint128();
        _requireStrike(context, position);
        _requireSolvent(position);
        return 0;
    }

    function _deletePosition(LeverageState storage state, uint256 positionId) private returns (uint256 refund) {
        Position storage position = state.positions[positionId];
        refund = position.escrow;
        // position.binCount <= MAX_BINS_PER_POSITION
        for (uint256 offset; offset < position.binCount; ++offset) {
            delete state.borrows[positionId][offset];
        }
        delete state.positions[positionId];
        --state.openPositions;
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A position needs both extremes to have a strike, which every close path prices it at, and at least the
    /// minimum quote notional, so a dust borrow cannot hold lenders' liquidity for free (audit L3-4).
    function _requireStrike(LeverageContext memory context, Position storage position) private view {
        if (position.maximum0 == 0) revert InvalidAmount();
        if (position.maximum1 == 0) revert InvalidAmount();
        uint256 quoteNotional = context.quoteIsCurrency0 ? position.maximum0 : position.maximum1;
        if (quoteNotional < context.minBorrowNotional) revert BelowMinimumBorrow();
    }

    function _requireSolvent(Position storage position) private view {
        bool solvent =
            LeverageMath.chordHolds(position.reserve0, position.reserve1, position.maximum0, position.maximum1);
        if (!solvent) revert Undercollateralized();
    }

    function _quoteNotional(
        LeverageState storage state,
        LeverageContext memory context,
        int24 binIndex,
        uint128 liquidity
    ) private view returns (uint256) {
        (uint256 maximum0, uint256 maximum1) = LeverageBins.extremesOf(state, context, binIndex, liquidity);
        return context.quoteIsCurrency0 ? maximum0 : maximum1;
    }

    function _addQuoteReserve(LeverageContext memory context, Position storage position, uint256 amount) private {
        if (context.quoteIsCurrency0) position.reserve0 = (position.reserve0 + amount).toUint128();
        else position.reserve1 = (position.reserve1 + amount).toUint128();
    }

    function _limit(bool zeroForOne) private pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _applyDelta(uint256 amount, int128 delta) private pure returns (uint256) {
        int256 next = amount.toInt256() + delta;
        if (next < 0) revert LeverageBins.UnexpectedDelta();
        return uint256(next);
    }
}
