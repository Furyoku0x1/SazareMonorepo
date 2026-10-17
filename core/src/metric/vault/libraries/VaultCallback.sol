// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @notice The one Metric callback the singleton expects next: set just before it calls a pool, cleared by the
/// callback. A callback from any other pool, or a second one, or one asking for more than the call was meant to pay,
/// is refused.
library VaultCallback {
    using TransientSlot for *;

    bytes32 internal constant POOL_SLOT = keccak256("sazare.metricVault.callback.pool");
    bytes32 internal constant VAULT_SLOT = keccak256("sazare.metricVault.callback.vault");
    bytes32 internal constant MAXIMUM0_SLOT = keccak256("sazare.metricVault.callback.maximum0");
    bytes32 internal constant MAXIMUM1_SLOT = keccak256("sazare.metricVault.callback.maximum1");
    bytes32 internal constant MINIMUM_OUT0_SLOT = keccak256("sazare.metricVault.callback.minimumOut0");
    bytes32 internal constant MINIMUM_OUT1_SLOT = keccak256("sazare.metricVault.callback.minimumOut1");
    bytes32 internal constant BALANCE0_SLOT = keccak256("sazare.metricVault.callback.balance0");
    bytes32 internal constant BALANCE1_SLOT = keccak256("sazare.metricVault.callback.balance1");

    function expect(address pool, uint256 vaultId, uint256 maximum0, uint256 maximum1) internal {
        POOL_SLOT.asAddress().tstore(pool);
        VAULT_SLOT.asUint256().tstore(vaultId);
        MAXIMUM0_SLOT.asUint256().tstore(maximum0);
        MAXIMUM1_SLOT.asUint256().tstore(maximum1);
        MINIMUM_OUT0_SLOT.asUint256().tstore(0);
        MINIMUM_OUT1_SLOT.asUint256().tstore(0);
    }

    /// @notice Also requires a swap to deliver at least these amounts, measured from the singleton's balances before
    /// the swap: Metric pays the output before it calls back, so the callback sees what actually arrived. The swap
    /// callback reverts below them, which undoes the whole swap: Metric fills partially rather than failing, and a
    /// partial fill must never stand.
    function expectOutput(uint256 minimumOut0, uint256 minimumOut1, uint256 balance0Before, uint256 balance1Before)
        internal
    {
        MINIMUM_OUT0_SLOT.asUint256().tstore(minimumOut0);
        MINIMUM_OUT1_SLOT.asUint256().tstore(minimumOut1);
        BALANCE0_SLOT.asUint256().tstore(balance0Before);
        BALANCE1_SLOT.asUint256().tstore(balance1Before);
    }

    function balancesBefore() internal view returns (uint256 balance0, uint256 balance1) {
        balance0 = BALANCE0_SLOT.asUint256().tload();
        balance1 = BALANCE1_SLOT.asUint256().tload();
    }

    function minimumOutputs() internal view returns (uint256 minimumOut0, uint256 minimumOut1) {
        minimumOut0 = MINIMUM_OUT0_SLOT.asUint256().tload();
        minimumOut1 = MINIMUM_OUT1_SLOT.asUint256().tload();
    }

    /// @notice Consumes the expectation, returning the vault and the most it may pay of each token.
    function take(address caller) internal returns (bool ok, uint256 vaultId, uint256 maximum0, uint256 maximum1) {
        address pool = POOL_SLOT.asAddress().tload();
        if (pool == address(0)) return (false, 0, 0, 0);
        if (pool != caller) return (false, 0, 0, 0);
        vaultId = VAULT_SLOT.asUint256().tload();
        maximum0 = MAXIMUM0_SLOT.asUint256().tload();
        maximum1 = MAXIMUM1_SLOT.asUint256().tload();
        POOL_SLOT.asAddress().tstore(address(0));
        return (true, vaultId, maximum0, maximum1);
    }

    /// @notice Clears an expectation the pool did not use, such as an add that needed no payment.
    function clear() internal {
        POOL_SLOT.asAddress().tstore(address(0));
    }
}
