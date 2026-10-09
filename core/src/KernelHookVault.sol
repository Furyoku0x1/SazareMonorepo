// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "./interfaces/IKernelHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Funds are isolated by pool, extension and currency. Pool and catalog administrators cannot withdraw them.
/// @dev Extensions enforce their users' ownership and withdrawal rights. Withdrawal remains available
/// while an installation is inactive. Supported currencies are standard and non-rebasing. Tokens that charge
/// transfer fees are rejected on deposits and payments; a credit held as claims records the PoolManager's nominal
/// amount, so a token taxing transfers out of the PoolManager is only rejected when those claims are redeemed.
/// Backing is held as real tokens and as PoolManager claim tokens (ERC-6909): swap credits arrive as claims, so they
/// never need the PoolManager to hold the tokens at that moment. Debts are paid from claims first; withdrawals pay
/// real tokens first and redeem claims for the rest. KernelHook and the route executor are operators of the
/// vault's claims, so they can burn what a debt uses in the same call.
contract KernelHookVault is ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    /// @notice The kernel hook authorized to manage this vault.
    /// @return The kernel hook address.
    address public immutable KERNEL_HOOK;
    /// @notice The pool manager that receives debt payments.
    /// @return The pool manager interface.
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The route executor authorized to credit balances and settle debts.
    /// @return The route executor address.
    address public routeExecutor;
    /// @notice The balance held for a pool, extension and currency.
    /// @return The installation's balance in the currency.
    mapping(PoolId => mapping(address => mapping(Currency => uint256))) public balanceOf;
    /// @notice The number of currencies with a nonzero balance for a pool and extension.
    /// @return The installation's funded currency count.
    mapping(PoolId => mapping(address => uint256)) public fundedCurrencyCount;
    /// @notice The total credited balance across all pools and extensions for a currency.
    /// @return The accounted balance in the currency.
    mapping(Currency => uint256) public accountedBalance;
    /// @dev True while this vault's own redemption unlock runs. Transient.
    bool private transient _redeeming;

    error InvalidPayment();
    error InsufficientBalance();
    error RedemptionUnavailable();

    event Deposited(PoolId indexed poolId, address indexed extension, Currency currency, uint256 amount);
    event Withdrawn(PoolId indexed poolId, address indexed extension, Currency currency, uint256 amount, address to);

    /// @notice Creates the vault with the deploying kernel hook as its controller.
    /// @param manager The pool manager used for settlement.
    constructor(IPoolManager manager) {
        KERNEL_HOOK = msg.sender;
        POOL_MANAGER = manager;
        manager.setOperator(msg.sender, true);
    }

    modifier onlyKernelHookOrRouteExecutor() {
        if (msg.sender != KERNEL_HOOK) {
            if (msg.sender != routeExecutor) revert IKernelHook.Unauthorized();
        }
        _;
    }

    /// @notice Sets the route executor once, at the kernel hook's request.
    /// @param account The route executor address.
    function setRouteExecutor(address account) external {
        if (msg.sender != KERNEL_HOOK) revert IKernelHook.Unauthorized();
        if (routeExecutor != address(0)) revert IKernelHook.Unauthorized();
        if (account == address(0)) revert IKernelHook.Unauthorized();
        routeExecutor = account;
        POOL_MANAGER.setOperator(account, true);
    }

    /// @notice Deposits funds through the installed extension that owns the balance.
    /// @param poolId The pool whose installation receives the funds.
    /// @param extension The installed extension making the deposit.
    /// @param currency The deposited currency; native currency requires matching msg.value.
    /// @param amount The amount to deposit.
    function deposit(PoolId poolId, address extension, Currency currency, uint256 amount)
        external
        payable
        nonReentrant
    {
        // Funding goes through the installation's own contract, where user claims can be recorded.
        // Unsolicited deposits must not create balances that permanently block its removal.
        if (msg.sender != extension) revert IKernelHook.Unauthorized();
        if (!IKernelHook(KERNEL_HOOK).isInstalled(poolId, extension)) revert IKernelHook.Unauthorized();
        address token = Currency.unwrap(currency);
        if (token == address(0)) {
            if (msg.value != amount) revert InvalidPayment();
        } else {
            if (msg.value != 0) revert InvalidPayment();
            uint256 previous = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            // The nonReentrant lock excludes other deposits and withdrawals during the transfer.
            if (IERC20(token).balanceOf(address(this)) - previous != amount) revert InvalidPayment();
        }
        // managementLock observes the nonReentrant lock and blocks removal during the token callback.
        if (!IKernelHook(KERNEL_HOOK).isInstalled(poolId, extension)) revert IKernelHook.Unauthorized();
        _credit(poolId, extension, currency, amount);
        emit Deposited(poolId, extension, currency, amount);
    }

    /// @notice Withdraws the calling extension's funds while its installation exists.
    /// @dev Pays real tokens first and redeems claim tokens for the rest. A redemption burns and takes at most
    /// 2^127 - 1 (the PoolManager's int128 deltas); larger withdrawals are made in parts.
    /// @param poolId The pool whose installation owns the funds.
    /// @param currency The currency to withdraw.
    /// @param amount The amount to withdraw.
    /// @param to The recipient of the funds.
    function withdraw(PoolId poolId, Currency currency, uint256 amount, address to) external nonReentrant {
        if (to == address(0)) revert IKernelHook.Unauthorized();
        if (!IKernelHook(KERNEL_HOOK).isInstalled(poolId, msg.sender)) revert IKernelHook.Unauthorized();
        _debit(poolId, msg.sender, currency, amount);
        uint256 held = _held(currency);
        if (held < amount) _redeem(currency, amount - held);
        if (Currency.unwrap(currency) == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert InvalidPayment();
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
        emit Withdrawn(poolId, msg.sender, currency, amount, to);
    }

    /// @notice Credits funds already received by the vault to an installation.
    /// @dev The kernel hook or route executor must first mint the matching claims (or transfer the tokens) to this
    /// vault.
    /// @param poolId The pool whose installation receives the credit.
    /// @param extension The extension that owns the balance.
    /// @param currency The credited currency.
    /// @param amount The amount to credit.
    function credit(PoolId poolId, address extension, Currency currency, uint256 amount)
        external
        onlyKernelHookOrRouteExecutor
    {
        _credit(poolId, extension, currency, amount);
    }

    /// @notice Debits an installation's balance to pay the recipient's pool manager debt: from claim tokens first,
    /// the rest settled with real tokens.
    /// @dev The caller must burn `fromClaims` of the vault's claims in the same call, which credits its own delta;
    /// only KernelHook and the route executor call this, as the recipient, and they are operators of the claims.
    /// Reverts with RedemptionUnavailable if an ERC20 currency is already synced, preserving the caller's pending
    /// settlement instead of overwriting its sync, even when this payment uses only claims or native currency.
    /// @param poolId The pool whose installation pays the debt.
    /// @param extension The extension that owns the balance.
    /// @param currency The currency to settle.
    /// @param amount The amount to debit and settle.
    /// @param recipient The account whose pool manager debt is settled.
    /// @return fromClaims The part the caller burns from the vault's claims.
    function settleDebtFor(PoolId poolId, address extension, Currency currency, uint256 amount, address recipient)
        external
        onlyKernelHookOrRouteExecutor
        nonReentrant
        returns (uint256 fromClaims)
    {
        if (!POOL_MANAGER.getSyncedCurrency().isAddressZero()) revert RedemptionUnavailable();
        _debit(poolId, extension, currency, amount);
        uint256 claims = _claims(currency);
        fromClaims = claims < amount ? claims : amount;
        uint256 physical = amount - fromClaims;
        if (physical == 0) return fromClaims;
        uint256 settled;
        if (Currency.unwrap(currency) == address(0)) {
            settled = POOL_MANAGER.settleFor{value: physical}(recipient);
        } else {
            POOL_MANAGER.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(POOL_MANAGER), physical);
            settled = POOL_MANAGER.settleFor(recipient);
        }
        // The nonReentrant lock protects the debit until the settlement amount is verified.
        if (settled != physical) revert InvalidPayment();
    }

    /// @notice Runs this vault's redemption: burns its claims and takes the same amount of real tokens.
    /// @param data The encoded currency and amount.
    /// @return Nothing.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert IKernelHook.Unauthorized();
        if (!_redeeming) revert IKernelHook.Unauthorized();
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        _burnAndTake(currency, amount);
        return "";
    }

    /// @notice Reports whether a deposit, withdrawal or debt settlement holds the vault's lock.
    /// @return Whether the nonReentrant lock is entered.
    function transferInProgress() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    /// @notice Accepts native currency taken from the pool manager for subsequent credit.
    receive() external payable {
        if (msg.sender != address(POOL_MANAGER)) revert IKernelHook.Unauthorized();
    }

    /// @dev Turns claims into real tokens in this vault: inside a new PoolManager unlock, or directly when one is
    /// already running (the burn and the take cancel in this vault's deltas). Nothing may change the PoolManager's
    /// custody under a pending ERC20 sync, which belongs to a settlement in progress.
    function _redeem(Currency currency, uint256 amount) private {
        if (!POOL_MANAGER.getSyncedCurrency().isAddressZero()) revert RedemptionUnavailable();
        uint256 held = _held(currency);
        uint256 custody = currency.balanceOf(address(POOL_MANAGER));
        if (POOL_MANAGER.isUnlocked()) {
            _burnAndTake(currency, amount);
        } else {
            _redeeming = true;
            POOL_MANAGER.unlock(abi.encode(currency, amount));
            _redeeming = false;
        }
        // Exact receipt and exact custody change, as for deposits: no transfer-fee tokens.
        if (_held(currency) != held + amount) revert InvalidPayment();
        if (currency.balanceOf(address(POOL_MANAGER)) != custody - amount) revert InvalidPayment();
    }

    function _burnAndTake(Currency currency, uint256 amount) private {
        POOL_MANAGER.burn(address(this), currency.toId(), amount);
        POOL_MANAGER.take(currency, address(this), amount);
    }

    function _held(Currency currency) private view returns (uint256) {
        return Currency.unwrap(currency) == address(0)
            ? address(this).balance
            : IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    function _claims(Currency currency) private view returns (uint256) {
        return POOL_MANAGER.balanceOf(address(this), currency.toId());
    }

    function _credit(PoolId poolId, address extension, Currency currency, uint256 amount) private {
        if (amount == 0) return;
        uint256 total = accountedBalance[currency] + amount;
        // Real tokens and claims are both backing.
        if (total > _held(currency) + _claims(currency)) revert InvalidPayment();
        accountedBalance[currency] = total;
        if (balanceOf[poolId][extension][currency] == 0) ++fundedCurrencyCount[poolId][extension];
        balanceOf[poolId][extension][currency] += amount;
    }

    function _debit(PoolId poolId, address extension, Currency currency, uint256 amount) private {
        if (amount == 0) return;
        uint256 previous = balanceOf[poolId][extension][currency];
        if (amount > previous) revert InsufficientBalance();
        accountedBalance[currency] -= amount;
        balanceOf[poolId][extension][currency] = previous - amount;
        if (previous == amount) --fundedCurrencyCount[poolId][extension];
    }
}
