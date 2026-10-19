// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ISwapVenue} from "../interfaces/ISwapVenue.sol";

/// @notice A venue that runs whatever route its caller scripts: approvals, then calls in order, so one swap can go
/// through any router or aggregator (1inch, 0x, ParaSwap, Odos, KyberSwap, Uniswap, Metric), hop through other tokens,
/// split across several venues, or combine all three. The route is what an aggregator's API or a router of one's own
/// returns; the swap's recipient in it may be this contract or the vault, which counts what reaches it either way.
/// @dev Stateless and permissionless. Each approval is granted before the calls and revoked after them, so no allowance
/// outlives the swap; then everything it holds of the vault's two tokens goes back to its caller, and any other token
/// the route names (an intermediate hop's dust) to the route's `refund`. It keeps nothing between calls and holds no
/// one's allowance, so anyone may call it and can move only what they sent it. The vault, not this contract, judges the
/// fill.
contract RouterVenue is ISwapVenue {
    using SafeERC20 for IERC20;

    /// @dev Bounds every loop over a route.
    uint256 public constant MAX_STEPS = 8;

    error TooManySteps();

    /// @notice `amount` of `token` for `spender` while the calls run; the maximum suits an intermediate token whose
    /// amount is only known once an earlier call has run.
    struct Approval {
        address token;
        address spender;
        uint256 amount;
    }

    /// @notice One call: a swap, a hop, a split's leg, or anything else a route needs.
    struct Call {
        address target;
        bytes data;
    }

    /// @notice A script: approvals granted first, calls made in order, approvals revoked, then the vault's tokens back to
    /// the caller and `sweep`'s tokens to `refund`.
    struct Route {
        Approval[] approvals;
        Call[] calls;
        address[] sweep;
        address refund;
    }

    /// @inheritdoc ISwapVenue
    function swapForVault(address tokenIn, address tokenOut, uint256, bytes calldata route) external {
        Route memory script = abi.decode(route, (Route));
        _requireBounded(script);
        _approve(script.approvals, false);
        _call(script.calls);
        // Revoked at once, so no allowance outlives the call that needed it.
        _approve(script.approvals, true);
        _sendAll(IERC20(tokenOut), msg.sender);
        _sendAll(IERC20(tokenIn), msg.sender);
        _sweep(script.sweep, script.refund);
    }

    function _requireBounded(Route memory script) private pure {
        if (script.approvals.length > MAX_STEPS) revert TooManySteps();
        if (script.calls.length > MAX_STEPS) revert TooManySteps();
        if (script.sweep.length > MAX_STEPS) revert TooManySteps();
    }

    function _approve(Approval[] memory approvals, bool revoke) private {
        // approvals.length <= MAX_STEPS
        for (uint256 index = 0; index < approvals.length; ++index) {
            Approval memory approval = approvals[index];
            uint256 amount = revoke ? 0 : approval.amount;
            IERC20(approval.token).forceApprove(approval.spender, amount);
        }
    }

    function _call(Call[] memory calls) private {
        // calls.length <= MAX_STEPS
        for (uint256 index = 0; index < calls.length; ++index) {
            Address.functionCall(calls[index].target, calls[index].data);
        }
    }

    /// @dev Tokens other than the vault's go to `refund`: the vault counts only its own two, so anything else sent to it
    /// would be stranded.
    function _sweep(address[] memory tokens, address refund) private {
        // tokens.length <= MAX_STEPS
        for (uint256 index = 0; index < tokens.length; ++index) {
            _sendAll(IERC20(tokens[index]), refund);
        }
    }

    function _sendAll(IERC20 token, address to) private {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        token.safeTransfer(to, balance);
    }
}
