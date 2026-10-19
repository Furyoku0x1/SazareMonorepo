// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ChargeStart, Position, Vault} from "../VaultTypes.sol";
import {Charge, VaultAccrual} from "./VaultAccrual.sol";
import {DebtValuation} from "./DebtValuation.sol";
import {DebtTotals, VaultMath} from "./VaultMath.sol";
import {RealizedCharge} from "./RealizedCharge.sol";

/// @notice The bookkeeping shared by opening and closing: debt totals, collecting premium, and the profit share.
library VaultBook {
    using SafeCast for uint256;

    uint256 internal constant BPS = 10_000;

    /// @notice Adds a debt of `liquidity` on the position's range to the vault's totals.
    function addDebt(Vault storage vault, Position storage position, uint128 liquidity) internal {
        DebtTotals storage totals = position.isLong ? vault.longDebts : vault.shortDebts;
        totals.liquidity += liquidity;
        DebtValuation.add(vault.debts, liquidity, position.tickLower, position.tickUpper);
    }

    /// @notice Removes a debt previously added with the same liquidity; its terms are deterministic, so this subtracts
    /// exactly what `addDebt` added.
    function removeDebt(Vault storage vault, Position storage position, uint128 liquidity) internal {
        DebtTotals storage totals = position.isLong ? vault.longDebts : vault.shortDebts;
        totals.liquidity -= liquidity;
        DebtValuation.remove(vault.debts, liquidity, position.tickLower, position.tickUpper);
    }

    /// @notice The premium the position owes beyond its escrow, rounded up, through the last price point. Does not
    /// change state.
    function shortfall(Vault storage vault, Position storage position, ChargeStart storage start)
        internal
        view
        returns (uint256)
    {
        uint256 due = VaultAccrual.charge(vault, position, start, true, 0).premium;
        uint256 escrow = position.escrow;
        return due > escrow ? due - escrow : 0;
    }

    /// @notice Settles the position's premium from its escrow, with `stubWad` from the last price point to now where a
    /// close or increase charges it. Returns what is still unpaid; the caller decides whether that is allowed. Moves
    /// the snapshots and the realized charge's start: anything unpaid is either collected by the caller or forgone.
    /// Closes round what is owed up once (`roundUp`); settlements anyone may call round down and carry the rest.
    function collect(
        Vault storage vault,
        Position storage position,
        ChargeStart storage start,
        bool roundUp,
        uint256 stubWad
    ) internal returns (Charge memory unpaid) {
        Charge memory owed = VaultAccrual.charge(vault, position, start, roundUp, stubWad);
        VaultAccrual.snapshot(vault, position);
        RealizedCharge.restart(vault, position, start);
        position.premiumFractionWad = owed.premiumFractionWad.toUint64();
        uint256 due = owed.premium;
        uint256 fromEscrow = due < position.escrow ? due : position.escrow;
        position.escrow -= uint128(fromEscrow);
        vault.ledger.escrow -= uint128(fromEscrow);
        unpaid = _pay(vault, owed, fromEscrow);
    }

    /// @notice Pays up to `amount` of the arrears `collect` returned, from token1 already in the vault's custody.
    /// Returns what is left unpaid.
    function payArrears(Vault storage vault, Charge memory unpaid, uint256 amount)
        internal
        returns (Charge memory remaining)
    {
        uint256 due = unpaid.premium;
        uint256 paid = amount < due ? amount : due;
        return _pay(vault, unpaid, paid);
    }

    /// @notice The total of an unpaid charge.
    function total(Charge memory unpaid) internal pure returns (uint256) {
        return unpaid.premium;
    }

    /// @notice Splits a profit share of `share0` token0 and `share1` token1 between lenders, the treasury and the fee
    /// vault. The tokens are already in the vault's custody.
    function payProfitShare(Vault storage vault, uint256 share0, uint256 share1) internal {
        uint256 treasuryBps = vault.parameters.profitTreasuryBps;
        uint256 feeVaultBps = vault.parameters.profitFeeVaultBps;
        (uint256 lender0, uint256 treasury0, uint256 feeVault0) = VaultMath.splitShare(share0, treasuryBps, feeVaultBps);
        (uint256 lender1, uint256 treasury1, uint256 feeVault1) = VaultMath.splitShare(share1, treasuryBps, feeVaultBps);
        vault.ledger.treasury0 += treasury0.toUint128();
        vault.ledger.feeVault0 += feeVault0.toUint128();
        vault.ledger.treasury1 += treasury1.toUint128();
        vault.ledger.feeVault1 += feeVault1.toUint128();
        VaultAccrual.fund0(vault, lender0);
        VaultAccrual.fund(vault, lender1);
    }

    /// @notice Pays premium arrears in token0 when token1 ran out: the protocol keeps its slice, the rest vests to
    /// lenders.
    function payArrearsInToken0(Vault storage vault, uint256 amount0) internal {
        if (amount0 == 0) return;
        uint256 protocol0 = amount0 * vault.parameters.premiumProtocolBps / BPS;
        vault.ledger.treasury0 += protocol0.toUint128();
        VaultAccrual.fund0(vault, amount0 - protocol0);
    }

    /// @notice The profit on a close: what the trader leaves with, valued in token1, less the cost basis closed.
    function profit(uint256 proceeds, uint256 basisClosed) internal pure returns (uint256) {
        return proceeds > basisClosed ? proceeds - basisClosed : 0;
    }

    /// @notice The basis a close takes. The escrow stays with the position until its final close refunds it, so a
    /// partial close takes its fraction of the rest only; taking the escrow's part early would tax its refund as profit
    /// (audit finding Sol-1-1). Call after premium is collected, when `escrow` is what remains.
    function closedBasis(uint256 basis, uint256 escrow, uint256 fractionWad) internal pure returns (uint256) {
        if (fractionWad == VaultMath.WAD) return basis;
        uint256 withoutEscrow = basis > escrow ? basis - escrow : 0;
        return VaultMath.portionDown(withoutEscrow, fractionWad);
    }

    /// @dev Pays `paid` token1 of the premium owed. Returns the part of `owed` still unpaid.
    function _pay(Vault storage vault, Charge memory owed, uint256 paid) private returns (Charge memory unpaid) {
        _creditPremium(vault, paid);
        unpaid.premium = owed.premium - paid;
    }

    function _creditPremium(Vault storage vault, uint256 amount) private {
        uint256 protocolPart = amount * vault.parameters.premiumProtocolBps / BPS;
        vault.ledger.treasury1 += protocolPart.toUint128();
        VaultAccrual.fund(vault, amount - protocolPart);
    }
}
