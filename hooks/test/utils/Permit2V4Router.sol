// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {V4Router} from "v4-periphery/src/V4Router.sol";
import {ReentrancyLock} from "v4-periphery/src/base/ReentrancyLock.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @dev A V4Router that pays as UniversalRouter does, through Permit2. This replicates UniversalRouter's Permit2
/// payment logic (Permit2Payments.payOrPermit2Transfer, as V4SwapRouter._pay calls it); it is not UniversalRouter,
/// which is not a dependency of this repository. V4Router pins solc 0.8.26, so tests deploy this from its artifact.
contract Permit2V4Router is V4Router, ReentrancyLock {
    using SafeCast for uint256;

    IAllowanceTransfer public immutable PERMIT2;

    constructor(IPoolManager manager, IAllowanceTransfer permit2) V4Router(manager) {
        PERMIT2 = permit2;
    }

    function executeActions(bytes calldata params) external payable isNotLocked {
        _executeActions(params);
    }

    /// @dev The router's own balance pays directly; anyone else pays through their Permit2 allowance to this router,
    /// never through an ERC20 allowance.
    function _pay(Currency token, address payer, uint256 amount) internal override {
        if (payer == address(this)) {
            token.transfer(address(poolManager), amount);
        } else {
            PERMIT2.transferFrom(payer, address(poolManager), amount.toUint160(), Currency.unwrap(token));
        }
    }

    /// @dev The caller of executeActions, as UniversalRouter's locker is.
    function msgSender() public view override returns (address) {
        return _getLocker();
    }
}
