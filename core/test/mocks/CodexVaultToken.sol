// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";

/// @notice A token that can charge transfer fees and observe or call back during vault transfers.
contract CodexVaultToken is MockERC20 {
    uint256 public feeBasisPoints;
    KernelHookVault public observedVault;
    address public callbackTarget;
    bytes public callbackData;
    bool public observedTransferInProgress;
    bool public callbackSucceeded;
    bytes public callbackResponse;

    constructor() MockERC20("Vault token", "VAULT", 18) {}

    function setFeeBasisPoints(uint256 fee) external {
        require(fee <= 10_000);
        feeBasisPoints = fee;
    }

    function setCallback(KernelHookVault vault, address target, bytes calldata data) external {
        observedVault = vault;
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        _afterTransfer(to, amount);
        return result;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        _afterTransfer(to, amount);
        return result;
    }

    function _afterTransfer(address to, uint256 amount) private {
        uint256 fee = amount * feeBasisPoints / 10_000;
        if (fee != 0) _burn(to, fee);
        if (address(observedVault) == address(0)) return;
        observedTransferInProgress = observedVault.transferInProgress();
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackResponse) = callbackTarget.call(callbackData);
        }
    }
}

/// @notice Models a recipient that cannot accept a native-currency withdrawal.
contract CodexVaultRejectNative {
    receive() external payable {
        revert();
    }
}
