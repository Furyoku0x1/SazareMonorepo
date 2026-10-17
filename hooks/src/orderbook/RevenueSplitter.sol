// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {KernelHookConstants} from "core/src/libraries/KernelHookConstants.sol";
import {ReentrancyGuardTransient} from "oz/contracts/utils/ReentrancyGuardTransient.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {OrderBook} from "./OrderBook.sol";

/// @notice An order book's treasury: splits each pool's treasury share between the pool's operator and Sazare.
/// @dev Deploy the book with this contract as its TREASURY. Sazare's share is fixed at deployment, so an operator's
/// share can never shrink. Any Kernel admin of a pool claims that pool's operator share. Anyone may collect a pool's
/// share from its book and pay Sazare what it is owed, so neither waits on a person. Standard, non-rebasing currencies
/// only, as for the Kernel's vault. Funds sent here other than through collect are not credited to anyone.
contract RevenueSplitter is ReentrancyGuardTransient {
    uint256 internal constant PIPS = 1_000_000;
    /// @dev The vault redeems at most this much of its PoolManager claims at once (their deltas are int128), so a
    /// larger share is collected in parts.
    uint256 internal constant MAX_COLLECTION = uint256(uint128(type(int128).max));

    IKernelHook public immutable KERNEL;
    /// @notice Receives Sazare's share.
    address public immutable SAZARE;
    /// @notice Sazare's part of every collected amount, in pips; the operator gets the rest.
    uint256 public immutable SAZARE_SHARE_PIPS;

    /// @notice Owed to the operator of a pool, per currency.
    mapping(PoolId => mapping(Currency => uint256)) public operatorOwed;
    /// @notice Owed to Sazare, per currency, across all pools.
    mapping(Currency => uint256) public sazareOwed;

    error Unauthorized();
    error InvalidAmount();

    event Collected(PoolId indexed pool, Currency currency, uint256 operatorAmount, uint256 sazareAmount);
    event OperatorClaimed(PoolId indexed pool, Currency currency, uint256 amount, address recipient);
    event SazarePaid(Currency currency, uint256 amount);

    constructor(IKernelHook kernel, address sazare, uint256 sazareSharePips) {
        if (sazare == address(0)) revert InvalidAmount();
        if (sazareSharePips > PIPS) revert InvalidAmount();
        KERNEL = kernel;
        SAZARE = sazare;
        SAZARE_SHARE_PIPS = sazareSharePips;
    }

    /// @dev A book pays native currency through the Kernel's vault.
    receive() external payable {}

    /// @notice Takes a pool's treasury share from its book, up to MAX_COLLECTION per currency, and splits it.
    /// @dev The book is not trusted: only what arrives here is credited, to the pool named.
    function collect(OrderBook book, PoolId pool) external nonReentrant {
        PoolKey memory key = KERNEL.poolKey(pool);
        OrderBook.Ledger memory ledger = book.ledger(pool);
        _collect(book, pool, key.currency0, ledger.treasury[0]);
        _collect(book, pool, key.currency1, ledger.treasury[1]);
    }

    /// @notice A Kernel admin of the pool takes the pool's operator share.
    function claim(PoolId pool, Currency currency, uint256 amount, address recipient) external nonReentrant {
        if (!KERNEL.hasPoolRole(pool, KernelHookConstants.POOL_ADMIN_ROLE, msg.sender)) revert Unauthorized();
        if (recipient == address(0)) revert Unauthorized();
        if (amount > operatorOwed[pool][currency]) revert InvalidAmount();
        operatorOwed[pool][currency] -= amount;
        currency.transfer(recipient, amount);
        emit OperatorClaimed(pool, currency, amount, recipient);
    }

    /// @notice Pays Sazare everything it is owed in a currency.
    function paySazare(Currency currency) external nonReentrant {
        uint256 amount = sazareOwed[currency];
        sazareOwed[currency] = 0;
        currency.transfer(SAZARE, amount);
        emit SazarePaid(currency, amount);
    }

    function _collect(OrderBook book, PoolId pool, Currency currency, uint256 amount) private {
        if (amount == 0) return;
        if (amount > MAX_COLLECTION) amount = MAX_COLLECTION;
        uint256 heldBefore = currency.balanceOfSelf();
        book.withdrawTreasury(pool, currency, amount, address(this), false);
        // The nonReentrant lock keeps claims and payments from moving this balance during the withdrawal.
        uint256 received = currency.balanceOfSelf() - heldBefore;
        // Rounds Sazare's part down: the operator gets any odd unit.
        uint256 sazareAmount = received * SAZARE_SHARE_PIPS / PIPS;
        sazareOwed[currency] += sazareAmount;
        operatorOwed[pool][currency] += received - sazareAmount;
        emit Collected(pool, currency, received - sazareAmount, sazareAmount);
    }
}
