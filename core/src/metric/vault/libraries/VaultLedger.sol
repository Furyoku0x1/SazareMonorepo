// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Vault} from "../VaultTypes.sol";
import {IMetricLendingVault} from "../interfaces/IMetricLendingVault.sol";

/// @notice Every token movement of the singleton. Each one changes exactly one vault's `held` balance, so the vaults'
/// balances always sum to the contract's: vaults that share a token never draw on each other's.
library VaultLedger {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Takes `amount` of the vault's token (0 or 1) from `from`, and credits the vault's `held`.
    /// @dev Requires the balance to rise by exactly `amount`, so a fee-on-transfer token cannot inflate `held`.
    function pull(Vault storage vault, uint256 tokenIndex, address from, uint256 amount) internal {
        if (amount == 0) return;
        IERC20 token = IERC20(tokenOf(vault, tokenIndex));
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        // The vault's nonReentrant lock is held, so the token cannot re-enter between the transfer and this check.
        if (token.balanceOf(address(this)) - balanceBefore != amount) revert IMetricLendingVault.InvalidParameters();
        credit(vault, tokenIndex, amount);
    }

    /// @notice Sends `amount` of the vault's token to `to`, debiting the vault's `held` first.
    function push(Vault storage vault, uint256 tokenIndex, address to, uint256 amount) internal {
        if (amount == 0) return;
        // A transfer to itself would leave the balance unchanged while `held` drops.
        if (to == address(this)) revert IMetricLendingVault.InvalidParameters();
        debit(vault, tokenIndex, amount);
        IERC20(tokenOf(vault, tokenIndex)).safeTransfer(to, amount);
    }

    /// @notice Sends a close's payout to the position's owner, or keeps it for them to claim when the token refuses the
    /// transfer, as a token that blocklists the owner does: a refused payout must not block a force close, or lent
    /// capital would wait on the owner (audit finding X-5).
    function pushOrKeep(Vault storage vault, uint256 tokenIndex, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(this)) revert IMetricLendingVault.InvalidParameters();
        debit(vault, tokenIndex, amount);
        if (IERC20(tokenOf(vault, tokenIndex)).trySafeTransfer(to, amount)) return;
        credit(vault, tokenIndex, amount);
        vault.unclaimed[to][tokenIndex] += amount;
        if (tokenIndex == 0) vault.ledger.unclaimed0 += amount.toUint128();
        else vault.ledger.unclaimed1 += amount.toUint128();
        emit IMetricLendingVault.PayoutKept(to, tokenIndex, amount);
    }

    /// @notice Records tokens that arrived for the vault by other means, such as a Metric removal or swap output.
    function credit(Vault storage vault, uint256 tokenIndex, uint256 amount) internal {
        if (tokenIndex == 0) vault.ledger.held0 = (vault.ledger.held0 + amount).toUint128();
        else vault.ledger.held1 = (vault.ledger.held1 + amount).toUint128();
    }

    /// @notice Records tokens that left the vault by other means, such as a Metric deposit or swap input.
    function debit(Vault storage vault, uint256 tokenIndex, uint256 amount) internal {
        if (tokenIndex == 0) vault.ledger.held0 -= amount.toUint128();
        else vault.ledger.held1 -= amount.toUint128();
    }

    function tokenOf(Vault storage vault, uint256 tokenIndex) internal view returns (address) {
        return tokenIndex == 0 ? vault.parameters.token0 : vault.parameters.token1;
    }
}
