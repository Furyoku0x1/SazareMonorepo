// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice A token that burns a surcharge from the sender on each transfer, on top of the amount sent.
contract SurchargeToken is MockERC20 {
    uint256 public surchargeBasisPoints;

    constructor() MockERC20("Surcharge token", "SURCHARGE", 18) {}

    function setSurchargeBasisPoints(uint256 surcharge) external {
        surchargeBasisPoints = surcharge;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        _burn(msg.sender, amount * surchargeBasisPoints / 10_000);
        return result;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        _burn(from, amount * surchargeBasisPoints / 10_000);
        return result;
    }
}
