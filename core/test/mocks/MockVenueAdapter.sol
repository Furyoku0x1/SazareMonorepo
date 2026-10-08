// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IExternalVenueAdapter} from "../../src/interfaces/IExternalVenueAdapter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @notice An adapter for adversarial ExternalSwap tests. It pays out of its own inventory at one unit out per unit
/// in, and its mode makes it misbehave in one way. Honest and Reenter pay correctly.
contract MockVenueAdapter is IExternalVenueAdapter {
    enum Mode {
        Honest,
        KeepInputPayNothing,
        PayHalf,
        PayInputCurrency,
        LeaveOwnDebt,
        SettleForExecutor,
        Reenter,
        Revert,
        ReturnTooMuchData,
        SettleTakeBackAndResync
    }

    IPoolManager public immutable POOL_MANAGER;
    address public immutable EXECUTOR;
    Mode public mode;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentrySucceeded;
    bytes public reentryReason;

    error AdapterRevert();

    constructor(IPoolManager manager, address executor) {
        POOL_MANAGER = manager;
        EXECUTOR = executor;
    }

    function setMode(Mode newMode) external {
        mode = newMode;
    }

    /// @notice Opens a PoolManager debt of this adapter before a route, for tests of debt that already exists.
    function takeOwnDebt(Currency currency, uint256 amount) external {
        POOL_MANAGER.take(currency, address(this), amount);
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function quoteExactOutput(address, Currency, Currency, uint256 amountOut, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return amountOut;
    }

    function swap(
        address,
        Currency currencyIn,
        Currency currencyOut,
        uint256 amountIn,
        int256 amountSpecified,
        address recipient,
        bytes calldata
    ) external returns (uint256 amountOut) {
        amountOut = amountSpecified < 0 ? amountIn : uint256(amountSpecified);
        Mode current = mode;
        if (current == Mode.Revert) revert AdapterRevert();
        if (current == Mode.ReturnTooMuchData) _returnTooMuchData();
        if (current == Mode.Reenter) _reenter();
        if (current == Mode.KeepInputPayNothing) return amountOut;
        if (current == Mode.PayHalf) currencyOut.transfer(recipient, amountOut / 2);
        if (current == Mode.PayInputCurrency) currencyIn.transfer(recipient, amountOut);
        if (current == Mode.LeaveOwnDebt) {
            // Pays the executor correctly, but takes one unit for itself and never settles it.
            currencyOut.transfer(recipient, amountOut);
            POOL_MANAGER.take(currencyIn, address(this), 1);
        }
        if (current == Mode.SettleForExecutor) {
            currencyOut.transfer(recipient, amountOut);
            POOL_MANAGER.settleFor(EXECUTOR);
        }
        if (current == Mode.SettleTakeBackAndResync) {
            // Credits the executor itself, takes the output back as more of its own debt, and restores the sync.
            currencyOut.transfer(recipient, amountOut);
            POOL_MANAGER.settleFor(EXECUTOR);
            POOL_MANAGER.take(currencyOut, address(this), amountOut);
            POOL_MANAGER.sync(currencyOut);
        }
        if (current == Mode.Honest || current == Mode.Reenter) currencyOut.transfer(recipient, amountOut);
    }

    /// @dev Records the result of the reentry attempt and continues, so a test can read why it failed.
    function _reenter() private {
        (reentrySucceeded, reentryReason) = reentryTarget.call(reentryData);
    }

    function _returnTooMuchData() private pure {
        assembly ("memory-safe") {
            return(0, 1024)
        }
    }
}
