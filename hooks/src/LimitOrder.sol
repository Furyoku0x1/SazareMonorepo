// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";

/// @notice Uniswap V4 Hook contract that allows for limit orders for any tokens.
/// @author Furyoku0x1 https://x.com/Furyoku0x1
contract LimitOrder is IHookExtension {
    using SafeERC20 for IERC20;

    /// Data types
    struct Order {
        address owner;
        address fromToken;
        address toToken;
        uint256 amount;
        uint256 price;
        uint256 filled;
    }

    /// Storage
    mapping(bytes32 => Order) public orders;
    mapping(address => uint256) public nextOrderNonce;

    /// Errors and Events

    constructor() {}

    /// External Functions

    function placeOrder(Order calldata order) external {
        IERC20(order.fromToken).safeTransferFrom(msg.sender, address(this), order.amount);
        bytes32 orderId = keccak256(abi.encode(msg.sender, nextOrderNonce[msg.sender]));
        nextOrderNonce[msg.sender] += 1;
    }

    function cancelOrder() external {}

    function claimTokens() external {}

    /// View Functions
    /// Internal Functions
}
