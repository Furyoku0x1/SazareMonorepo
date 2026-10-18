// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Vault, VaultStore} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";
import {DebtValuation} from "./DebtValuation.sol";
import {VaultAccrual} from "./VaultAccrual.sol";
import {VaultLedger} from "./VaultLedger.sol";
import {VaultMath} from "./VaultMath.sol";
import {VaultPricing} from "./VaultPricing.sol";
import {MetricVenue} from "./MetricVenue.sol";

/// @notice Lenders' deposits and withdrawals, priced at the edge of the band that favors the lenders who stay.
/// @dev An external library: the singleton delegatecalls it.
library VaultLending {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;
    /// @dev Virtual shares and value, as in ERC-4626 with an offset: the first deposit cannot be front-run into
    /// inflating the share price, because an attacker's donation is shared with the virtual holder.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_VALUE = 1;

    /// @notice Deposits either token or both for shares. The deposit is valued at the bid and the vault at the ask, so
    /// the depositor never gains from a stale band at the expense of existing lenders.
    function deposit(
        VaultStore storage store,
        uint256 vaultId,
        uint256 amount0,
        uint256 amount1,
        uint256 minimumShares,
        address receiver
    ) external returns (uint256 shares) {
        Vault storage vault = _vault(store, vaultId);
        if (amount0 == 0) {
            if (amount1 == 0) revert IMetricLendingVault.ZeroAmount();
        }
        VaultAccrual.checkpoint(vault, vaultId);
        (uint160 sqrtBidX96, uint160 sqrtAskX96) = VaultPricing.band(vault);
        uint256 valueIn = VaultMath.valueInToken1(amount0, amount1, sqrtBidX96, false);
        // Income still vesting was earned before this deposit, so the new shares pay for it (audit finding A3). Premium
        // not yet collected is not counted (owner's decision on X-2): shares are priced on what is in the vault.
        uint256 vesting = VaultMath.valueInToken1(vault.stream.remaining0, vault.stream.remaining1, sqrtAskX96, true);
        uint256 vaultValue = valueHigh(vault, sqrtAskX96) + vesting;
        shares = FullMath.mulDiv(valueIn, vault.totalShares + VIRTUAL_SHARES, vaultValue + VIRTUAL_VALUE);
        if (shares == 0) revert IMetricLendingVault.ZeroAmount();
        if (shares < minimumShares) revert IMetricLendingVault.SlippageExceeded();
        VaultLedger.pull(vault, 0, msg.sender, amount0);
        VaultLedger.pull(vault, 1, msg.sender, amount1);
        vault.ledger.buffer0 += amount0.toUint128();
        vault.ledger.buffer1 += amount1.toUint128();
        vault.totalShares += shares;
        vault.shares[receiver] += shares;
        MetricVenue.place(vault, vaultId);
        emit IMetricLendingVault.Deposited(vaultId, receiver, amount0, amount1, shares);
    }

    /// @notice Burns shares for a fraction of the lenders' idle basket: the claim, valued at the bid, over the idle
    /// value. Only idle capital can leave: when the claim exceeds it, the whole idle basket is paid and only the shares
    /// it covers are burned. What Metric will not release now stays behind, the payout shrinks to the same fraction of
    /// each token, and only the shares paid for are burned. With no positions open the claim is a plain share of the
    /// idle tokens and needs no price (audit finding A5).
    function withdraw(
        VaultStore storage store,
        uint256 vaultId,
        uint256 shares,
        uint256 minimum0,
        uint256 minimum1,
        address receiver
    ) external returns (uint256 amount0, uint256 amount1, uint256 burned) {
        Vault storage vault = _vault(store, vaultId);
        if (shares == 0) revert IMetricLendingVault.ZeroAmount();
        if (shares > vault.shares[msg.sender]) revert IMetricLendingVault.InsufficientShares();
        VaultAccrual.checkpoint(vault, vaultId);
        (amount0, amount1, burned) = _payout(vault, vaultId, shares);
        if (amount0 < minimum0) revert IMetricLendingVault.SlippageExceeded();
        if (amount1 < minimum1) revert IMetricLendingVault.SlippageExceeded();
        vault.ledger.buffer0 -= amount0.toUint128();
        vault.ledger.buffer1 -= amount1.toUint128();
        vault.shares[msg.sender] -= burned;
        vault.totalShares -= burned;
        if (vault.totalShares == 0) VaultAccrual.forfeitToTreasury(vault);
        VaultLedger.push(vault, 0, receiver, amount0);
        VaultLedger.push(vault, 1, receiver, amount1);
        MetricVenue.place(vault, vaultId);
        emit IMetricLendingVault.Withdrawn(vaultId, msg.sender, amount0, amount1, burned);
    }

    /// @notice Moves the vault's Metric window toward the active bin. Anyone may call.
    function recenter(VaultStore storage store, uint256 vaultId) external returns (bool moved) {
        Vault storage vault = _vault(store, vaultId);
        VaultAccrual.checkpoint(vault, vaultId);
        return MetricVenue.recenter(vault, vaultId);
    }

    /// @notice The vault's value for deposits: idle at the ask plus the debts' holdings at the ask, rounded up.
    function valueHigh(Vault storage vault, uint160 sqrtAskX96) internal view returns (uint256) {
        uint256 idleValue =
            VaultMath.valueInToken1(VaultAccrual.idle0(vault), VaultAccrual.idle1(vault), sqrtAskX96, true);
        return idleValue + DebtValuation.valueHigh(vault.debts, sqrtAskX96);
    }

    /// @notice The vault's value for withdrawals: idle at the bid plus the debts' holdings at the bid, rounded down.
    function valueLow(Vault storage vault, uint160 sqrtBidX96) internal view returns (uint256) {
        uint256 idleValue =
            VaultMath.valueInToken1(VaultAccrual.idle0(vault), VaultAccrual.idle1(vault), sqrtBidX96, false);
        return idleValue + DebtValuation.valueLow(vault.debts, sqrtBidX96);
    }

    /// @dev What `shares` take from the idle basket and the shares that burns: the entitled fraction of each token, as
    /// far as the buffer can pay after gathering from Metric, and only the shares paid for.
    function _payout(Vault storage vault, uint256 vaultId, uint256 shares)
        private
        returns (uint256 amount0, uint256 amount1, uint256 burned)
    {
        uint256 entitlementWad = _entitlement(vault, shares);
        uint256 askedWad = entitlementWad < WAD ? entitlementWad : WAD;
        uint256 want0 = VaultMath.portionDown(VaultAccrual.idle0(vault), askedWad);
        uint256 want1 = VaultMath.portionDown(VaultAccrual.idle1(vault), askedWad);
        // Whether gathering reached `want` does not matter: the withdrawal pays what the buffer then holds.
        // forge-lint: disable-next-line(unused-return)
        MetricVenue.gather(vault, vaultId, want0, want1);
        uint256 filledWad = _filled(vault, want0, want1);
        amount0 = VaultMath.portionDown(want0, filledWad);
        amount1 = VaultMath.portionDown(want1, filledWad);
        if (amount0 == 0) {
            if (amount1 == 0) revert IMetricLendingVault.InsufficientIdle();
        }
        burned = VaultMath.sharesPaidFor(shares, entitlementWad, askedWad, filledWad);
    }

    /// @dev The fraction of the idle basket `shares` are entitled to, uncapped: their share of the vault, scaled by
    /// its value over the idle value. Ownership leaves out the virtual value, which would otherwise dominate when
    /// values round to a few units (audit finding C3). With no positions open the vault is its idle basket, so the
    /// share needs no price.
    function _entitlement(Vault storage vault, uint256 shares) private returns (uint256 entitlementWad) {
        uint256 ownershipWad = FullMath.mulDiv(shares, WAD, vault.totalShares + VIRTUAL_SHARES);
        if (ownershipWad == 0) revert IMetricLendingVault.ZeroAmount();
        if (_nothingLent(vault)) return ownershipWad;
        (uint160 sqrtBidX96,) = VaultPricing.band(vault);
        // Idle value rounds up, so its rounding cannot inflate the fraction.
        uint256 idleValue =
            VaultMath.valueInToken1(VaultAccrual.idle0(vault), VaultAccrual.idle1(vault), sqrtBidX96, true);
        if (idleValue == 0) revert IMetricLendingVault.InsufficientIdle();
        entitlementWad = FullMath.mulDiv(ownershipWad, valueLow(vault, sqrtBidX96), idleValue);
        if (entitlementWad == 0) revert IMetricLendingVault.ZeroAmount();
    }

    /// @dev The common fraction of `want` the buffer can pay in both tokens, so the payout stays the same mix as the
    /// claim and needs no price to burn for.
    function _filled(Vault storage vault, uint256 want0, uint256 want1) private view returns (uint256) {
        uint256 filled0 = want0 == 0 ? WAD : FullMath.mulDiv(_min(want0, vault.ledger.buffer0), WAD, want0);
        uint256 filled1 = want1 == 0 ? WAD : FullMath.mulDiv(_min(want1, vault.ledger.buffer1), WAD, want1);
        return _min(filled0, filled1);
    }

    /// @dev Whether no position is open: debt liquidity, unlike released tokens, is positive for every position.
    function _nothingLent(Vault storage vault) private view returns (bool) {
        if (vault.longDebts.liquidity != 0) return false;
        return vault.shortDebts.liquidity == 0;
    }

    function _min(uint256 left, uint256 right) private pure returns (uint256) {
        return left < right ? left : right;
    }

    function _vault(VaultStore storage store, uint256 vaultId) private view returns (Vault storage vault) {
        if (vaultId == 0) revert IMetricLendingVault.UnknownVault();
        if (vaultId > store.vaultCount) revert IMetricLendingVault.UnknownVault();
        return store.vaults[vaultId];
    }
}
