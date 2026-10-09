// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {NoopExtension} from "../mocks/NoopExtension.sol";
import {CodexVaultToken, CodexVaultRejectNative} from "../mocks/CodexVaultToken.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {CallbackType} from "../../src/types/KernelHookTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract VaultTest is KernelHookFixture, IUnlockCallback {
    KernelHookVault internal vault;
    PoolKey internal poolKey;
    PoolId internal poolId;
    NoopExtension internal extension;
    address internal constant RECIPIENT = address(0xA11CE);
    Currency internal constant NATIVE = Currency.wrap(address(0));

    /// @dev What unlockCallback does: the original debt settlement, minting claims to the vault, a debt that
    /// burns claims as KernelHook or the route executor would, or a withdrawal while the PoolManager is unlocked.
    enum Mode {
        Settle,
        MintClaims,
        ClaimDebt,
        WithdrawUnlocked
    }

    Mode internal mode;
    uint256 internal fromClaims;
    Currency internal syncCurrency; // what WithdrawUnlocked leaves synced, when asked to

    function setUp() public override {
        super.setUp();
        vault = hook.VAULT();
        poolKey = _poolKey();
        poolId = poolKey.toId();
        _createPool(poolKey);
        extension = _installExtension();
    }

    function test_deposit_revertsWhenCallerIsNotExtension() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.deposit(poolId, address(extension), currency0, 0);
    }

    function test_deposit_revertsWhenExtensionIsNotInstalled() public {
        address unknownExtension = address(0xBAD);
        vm.prank(unknownExtension);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.deposit(poolId, unknownExtension, currency0, 0);
    }

    function test_deposit_revertsWhenExtensionWasRemoved() public {
        hook.removeExtension(poolKey, extension);
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.deposit(poolId, address(extension), currency0, 0);
    }

    function testFuzz_deposit_creditsExactTokenAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        _deposit(currency0, amount);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), amount);
        assertEq(vault.accountedBalance(currency0), amount);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), amount);
    }

    function testFuzz_deposit_creditsExactNativeAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        _deposit(NATIVE, amount);
        assertEq(vault.balanceOf(poolId, address(extension), NATIVE), amount);
        assertEq(vault.accountedBalance(NATIVE), amount);
        assertEq(address(vault).balance, amount);
    }

    function test_deposit_acceptsInactiveExtension() public {
        (bool active,,) = hook.extensionConfiguration(poolId, address(extension));
        assertFalse(active);
        _deposit(currency0, 100);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 100);
    }

    function testFuzz_deposit_revertsWhenNativeValueIsTooSmall(uint256 amount, uint256 value) public {
        amount = bound(amount, 1, type(uint128).max);
        value = bound(value, 0, amount - 1);
        vm.deal(address(extension), value);
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.deposit{value: value}(poolId, address(extension), NATIVE, amount);
    }

    function testFuzz_deposit_revertsWhenNativeValueIsTooLarge(uint256 amount, uint256 excess) public {
        amount = bound(amount, 0, type(uint128).max);
        excess = bound(excess, 1, type(uint128).max);
        vm.deal(address(extension), amount + excess);
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.deposit{value: amount + excess}(poolId, address(extension), NATIVE, amount);
    }

    function test_deposit_revertsWhenTokenDepositHasNativeValue() public {
        vm.deal(address(extension), 1);
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.deposit{value: 1}(poolId, address(extension), currency0, 100);
    }

    function testFuzz_deposit_revertsWhenTokenChargesTransferFee(uint256 fee) public {
        fee = bound(fee, 1, 10_000);
        CodexVaultToken token = new CodexVaultToken();
        token.setFeeBasisPoints(fee);
        token.mint(address(extension), 10_000);
        vm.startPrank(address(extension));
        token.approve(address(vault), 10_000);
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.deposit(poolId, address(extension), Currency.wrap(address(token)), 10_000);
        vm.stopPrank();
        assertEq(token.balanceOf(address(extension)), 10_000);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 0);
    }

    function test_deposit_emitsDeposited() public {
        MockERC20 token = MockERC20(Currency.unwrap(currency0));
        token.mint(address(extension), 100);
        vm.startPrank(address(extension));
        token.approve(address(vault), 100);
        vm.expectEmit(true, true, false, true, address(vault));
        emit KernelHookVault.Deposited(poolId, address(extension), currency0, 100);
        vault.deposit(poolId, address(extension), currency0, 100);
        vm.stopPrank();
    }

    function test_deposit_zeroAmountDoesNotCreateFundedCurrency() public {
        _deposit(currency0, 0);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 0);
        assertEq(vault.accountedBalance(currency0), 0);
    }

    function test_deposit_sameCurrencyDoesNotIncreaseFundedCurrencyCountTwice() public {
        _deposit(currency0, 100);
        _deposit(currency0, 200);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 1);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 300);
    }

    function test_deposit_differentCurrenciesIncreaseFundedCurrencyCount() public {
        _deposit(currency0, 100);
        _deposit(currency1, 200);
        _deposit(NATIVE, 300);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 3);
    }

    function test_withdraw_revertsWhenCallerIsNotInstalled() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.withdraw(poolId, currency0, 0, RECIPIENT);
    }

    function test_withdraw_revertsWhenExtensionWasRemoved() public {
        hook.removeExtension(poolKey, extension);
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.withdraw(poolId, currency0, 0, RECIPIENT);
    }

    function test_withdraw_revertsWhenRecipientIsZero() public {
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.withdraw(poolId, currency0, 0, address(0));
    }

    function testFuzz_withdraw_revertsWhenAmountExceedsBalance(uint256 balance, uint256 excess) public {
        balance = bound(balance, 0, type(uint128).max);
        excess = bound(excess, 1, type(uint128).max);
        _deposit(currency0, balance);
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InsufficientBalance.selector));
        vault.withdraw(poolId, currency0, balance + excess, RECIPIENT);
    }

    function test_withdraw_sendsTokensWhileInactive() public {
        _deposit(currency0, 100);
        hook.activateExtension(poolKey, extension);
        hook.deactivateExtension(poolKey, extension);
        vm.prank(address(extension));
        vault.withdraw(poolId, currency0, 100, RECIPIENT);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(RECIPIENT), 100);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 0);
    }

    function testFuzz_withdraw_sendsNativeCurrency(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        _deposit(NATIVE, amount);
        vm.prank(address(extension));
        vault.withdraw(poolId, NATIVE, amount, RECIPIENT);
        assertEq(RECIPIENT.balance, amount);
        assertEq(address(vault).balance, 0);
    }

    function test_withdraw_revertsWhenNativeRecipientRejectsPayment() public {
        _deposit(NATIVE, 100);
        CodexVaultRejectNative recipient = new CodexVaultRejectNative();
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.withdraw(poolId, NATIVE, 100, address(recipient));
        assertEq(vault.balanceOf(poolId, address(extension), NATIVE), 100);
        assertEq(vault.accountedBalance(NATIVE), 100);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 1);
    }

    function test_withdraw_emitsWithdrawn() public {
        _deposit(currency0, 100);
        vm.prank(address(extension));
        vm.expectEmit(true, true, false, true, address(vault));
        emit KernelHookVault.Withdrawn(poolId, address(extension), currency0, 100, RECIPIENT);
        vault.withdraw(poolId, currency0, 100, RECIPIENT);
    }

    function test_withdraw_partialAmountKeepsFundedCurrency() public {
        _deposit(currency0, 100);
        vm.prank(address(extension));
        vault.withdraw(poolId, currency0, 40, RECIPIENT);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 60);
        assertEq(vault.accountedBalance(currency0), 60);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 1);
    }

    function test_withdraw_fullAmountRemovesFundedCurrency() public {
        _deposit(currency0, 100);
        _deposit(currency1, 200);
        vm.prank(address(extension));
        vault.withdraw(poolId, currency0, 100, RECIPIENT);
        assertEq(vault.accountedBalance(currency0), 0);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 1);
    }

    function test_withdraw_zeroAmountDoesNotRemoveFundedCurrency() public {
        _deposit(currency0, 100);
        vm.prank(address(extension));
        vault.withdraw(poolId, currency0, 0, RECIPIENT);
        assertEq(vault.accountedBalance(currency0), 100);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 1);
    }

    function test_credit_revertsWhenCallerIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.credit(poolId, address(extension), currency0, 0);
    }

    function test_credit_acceptsKernelHook() public {
        MockERC20(Currency.unwrap(currency0)).mint(address(vault), 100);
        vm.prank(address(hook));
        vault.credit(poolId, address(extension), currency0, 100);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 100);
        assertEq(vault.accountedBalance(currency0), 100);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 1);
    }

    function test_credit_acceptsRouteExecutor() public {
        MockERC20(Currency.unwrap(currency0)).mint(address(vault), 100);
        vm.prank(vault.routeExecutor());
        vault.credit(poolId, address(extension), currency0, 100);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 100);
    }

    function test_credit_acceptsNativeCurrencyReceivedFromPoolManager() public {
        vm.deal(address(manager), 100);
        vm.prank(address(manager));
        (bool success,) = address(vault).call{value: 100}("");
        assertTrue(success);
        vm.prank(address(hook));
        vault.credit(poolId, address(extension), NATIVE, 100);
        assertEq(vault.accountedBalance(NATIVE), 100);
    }

    function test_credit_revertsWhenFundsWereNotReceived() public {
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.credit(poolId, address(extension), currency0, 100);
    }

    function test_credit_revertsWhenNativeFundsWereNotReceived() public {
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.credit(poolId, address(extension), NATIVE, 100);
    }

    function test_credit_revertsWhenFundsWereAlreadyAccounted() public {
        _deposit(currency0, 100);
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.credit(poolId, address(extension), currency0, 1);
    }

    function test_credit_zeroAmountDoesNotCreateFundedCurrency() public {
        vm.prank(address(hook));
        vault.credit(poolId, address(extension), currency0, 0);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 0);
        assertEq(vault.accountedBalance(currency0), 0);
    }

    function test_accountedBalance_aggregatesIndependentInstallations() public {
        _deposit(currency0, 100);
        NoopExtension second = _installExtension();
        MockERC20 token = MockERC20(Currency.unwrap(currency0));
        token.mint(address(second), 200);
        vm.startPrank(address(second));
        token.approve(address(vault), 200);
        vault.deposit(poolId, address(second), currency0, 200);
        vm.stopPrank();
        assertEq(vault.accountedBalance(currency0), 300);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 100);
        assertEq(vault.balanceOf(poolId, address(second), currency0), 200);
        assertEq(vault.fundedCurrencyCount(poolId, address(second)), 1);
    }

    function test_accountedBalance_aggregatesSameExtensionInIndependentPools() public {
        _deposit(currency0, 100);
        PoolKey memory secondKey = poolKey;
        secondKey.fee = FEE + 1;
        PoolId secondId = secondKey.toId();
        hook.preparePool(secondKey);
        hook.installExtension(secondKey, extension, _settings(SWAP_CALLBACKS, false, false));
        MockERC20 token = MockERC20(Currency.unwrap(currency0));
        token.mint(address(extension), 200);
        vm.startPrank(address(extension));
        token.approve(address(vault), 200);
        vault.deposit(secondId, address(extension), currency0, 200);
        vm.stopPrank();
        assertEq(vault.accountedBalance(currency0), 300);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 100);
        assertEq(vault.balanceOf(secondId, address(extension), currency0), 200);
        assertEq(vault.fundedCurrencyCount(secondId, address(extension)), 1);
    }

    function test_withdraw_cannotSpendAnotherInstalledExtensionsBalance() public {
        _deposit(currency0, 100);
        NoopExtension second = _installExtension();
        vm.prank(address(second));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InsufficientBalance.selector));
        vault.withdraw(poolId, currency0, 100, RECIPIENT);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 100);
    }

    function test_settleDebtFor_revertsWhenCallerIsUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.settleDebtFor(poolId, address(extension), currency0, 0, RECIPIENT);
    }

    function test_settleDebtFor_revertsWhenBalanceIsInsufficient() public {
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InsufficientBalance.selector));
        vault.settleDebtFor(poolId, address(extension), currency0, 1, RECIPIENT);
    }

    function testFuzz_settleDebtFor_kernelHookSettlesTokenDebt(uint256 amount) public {
        amount = bound(amount, 1, uint256(uint128(type(int128).max)));
        _deposit(currency0, amount);
        MockERC20(Currency.unwrap(currency0)).mint(address(manager), amount);
        manager.unlock(abi.encode(currency0, amount, address(hook), false));
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 0);
        assertEq(vault.accountedBalance(currency0), 0);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 0);
    }

    function test_settleDebtFor_routeExecutorSettlesTokenDebt() public {
        _deposit(currency0, 100);
        MockERC20(Currency.unwrap(currency0)).mint(address(manager), 100);
        manager.unlock(abi.encode(currency0, 100, vault.routeExecutor(), false));
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 0);
        assertEq(vault.accountedBalance(currency0), 0);
    }

    function testFuzz_settleDebtFor_kernelHookSettlesNativeDebt(uint256 amount) public {
        amount = bound(amount, 1, uint256(uint128(type(int128).max)));
        _deposit(NATIVE, amount);
        vm.deal(address(manager), amount);
        manager.unlock(abi.encode(NATIVE, amount, address(hook), false));
        assertEq(vault.balanceOf(poolId, address(extension), NATIVE), 0);
        assertEq(vault.accountedBalance(NATIVE), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_settleDebtFor_routeExecutorSettlesNativeDebt() public {
        _deposit(NATIVE, 100);
        vm.deal(address(manager), 100);
        manager.unlock(abi.encode(NATIVE, 100, vault.routeExecutor(), false));
        assertEq(vault.balanceOf(poolId, address(extension), NATIVE), 0);
        assertEq(vault.accountedBalance(NATIVE), 0);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 0);
    }

    function test_settleDebtFor_revertsWithPreviousTokenSyncBeforeNativePayment() public {
        _deposit(NATIVE, 100);
        vm.deal(address(manager), 100);
        vm.expectRevert(KernelHookVault.RedemptionUnavailable.selector);
        manager.unlock(abi.encode(NATIVE, 100, address(hook), true));
        assertEq(vault.accountedBalance(NATIVE), 100);
    }

    function test_settleDebtFor_revertsWithPreviousTokenSyncBeforeTokenPayment() public {
        _deposit(currency0, 100);
        MockERC20(Currency.unwrap(currency0)).mint(address(manager), 100);
        vm.expectRevert(KernelHookVault.RedemptionUnavailable.selector);
        manager.unlock(abi.encode(currency0, 100, address(hook), true));
        assertEq(vault.accountedBalance(currency0), 100);
    }

    function test_settleDebtFor_revertsWithPreviousTokenSyncBeforeClaimsPayment() public {
        _creditClaims(currency0, 100);
        mode = Mode.ClaimDebt;
        vm.expectRevert(KernelHookVault.RedemptionUnavailable.selector);
        manager.unlock(abi.encode(currency0, 70, address(hook), true));
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 100);
    }

    function test_settleDebtFor_partialPaymentKeepsFundedCurrency() public {
        _deposit(currency0, 100);
        MockERC20(Currency.unwrap(currency0)).mint(address(manager), 40);
        manager.unlock(abi.encode(currency0, 40, address(hook), false));
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 60);
        assertEq(vault.accountedBalance(currency0), 60);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 1);
    }

    function test_settleDebtFor_revertsWhenTokenChargesTransferFee() public {
        CodexVaultToken token = new CodexVaultToken();
        Currency currency = Currency.wrap(address(token));
        _deposit(currency, 10_000);
        token.mint(address(manager), 10_000);
        token.setFeeBasisPoints(100);
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        manager.unlock(abi.encode(currency, 10_000, address(hook), false));
        assertEq(vault.balanceOf(poolId, address(extension), currency), 10_000);
        assertEq(vault.accountedBalance(currency), 10_000);
        assertEq(token.balanceOf(address(vault)), 10_000);
    }

    function test_setRouteExecutor_setsExecutorOnce() public {
        KernelHookVault separateVault = new KernelHookVault(manager);
        separateVault.setRouteExecutor(RECIPIENT);
        assertEq(separateVault.routeExecutor(), RECIPIENT);
    }

    function test_setRouteExecutor_revertsWhenCallerIsNotKernelHook() public {
        KernelHookVault separateVault = new KernelHookVault(manager);
        vm.prank(RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        separateVault.setRouteExecutor(RECIPIENT);
    }

    function test_setRouteExecutor_revertsWhenExecutorIsAlreadySet() public {
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.setRouteExecutor(RECIPIENT);
    }

    function test_setRouteExecutor_revertsWhenExecutorIsZero() public {
        KernelHookVault separateVault = new KernelHookVault(manager);
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        separateVault.setRouteExecutor(address(0));
    }

    function test_receive_acceptsOnlyPoolManager() public {
        vm.deal(address(manager), 100);
        vm.prank(address(manager));
        (bool success,) = address(vault).call{value: 100}("");
        assertTrue(success);
        assertEq(address(vault).balance, 100);
        assertEq(vault.accountedBalance(NATIVE), 0);
    }

    function test_receive_revertsWhenCallerIsNotPoolManager() public {
        vm.deal(address(this), 100);
        (bool success, bytes memory response) = address(vault).call{value: 100}("");
        assertFalse(success);
        assertEq(response, abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        assertEq(address(vault).balance, 0);
    }

    function test_transferInProgress_isFalseOutsideTransfers() public view {
        assertFalse(vault.transferInProgress());
    }

    function test_transferInProgress_isTrueDuringTokenDeposit() public {
        CodexVaultToken token = new CodexVaultToken();
        token.setCallback(vault, address(0), "");
        _deposit(Currency.wrap(address(token)), 100);
        assertTrue(token.observedTransferInProgress());
        assertFalse(vault.transferInProgress());
    }

    function test_transferInProgress_isTrueDuringTokenWithdrawal() public {
        CodexVaultToken token = new CodexVaultToken();
        Currency currency = Currency.wrap(address(token));
        _deposit(currency, 100);
        token.setCallback(vault, address(0), "");
        vm.prank(address(extension));
        vault.withdraw(poolId, currency, 100, RECIPIENT);
        assertTrue(token.observedTransferInProgress());
        assertFalse(vault.transferInProgress());
    }

    function test_transferInProgress_isTrueDuringDebtSettlement() public {
        CodexVaultToken token = new CodexVaultToken();
        Currency currency = Currency.wrap(address(token));
        _deposit(currency, 100);
        token.mint(address(manager), 100);
        token.setCallback(vault, address(0), "");
        manager.unlock(abi.encode(currency, 100, address(hook), false));
        assertTrue(token.observedTransferInProgress());
        assertFalse(vault.transferInProgress());
    }

    function test_deposit_blocksReentrantDepositDuringTokenCallback() public {
        CodexVaultToken token = new CodexVaultToken();
        token.setCallback(
            vault, address(vault), abi.encodeCall(KernelHookVault.deposit, (poolId, address(token), currency0, 0))
        );
        _deposit(Currency.wrap(address(token)), 100);
        assertFalse(token.callbackSucceeded());
        assertEq(
            token.callbackResponse(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_withdraw_blocksReentrantWithdrawalDuringTokenCallback() public {
        CodexVaultToken token = new CodexVaultToken();
        Currency currency = Currency.wrap(address(token));
        _deposit(currency, 100);
        token.setCallback(
            vault, address(vault), abi.encodeCall(KernelHookVault.withdraw, (poolId, currency, 0, RECIPIENT))
        );
        vm.prank(address(extension));
        vault.withdraw(poolId, currency, 100, RECIPIENT);
        assertFalse(token.callbackSucceeded());
        assertEq(
            token.callbackResponse(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_deposit_blocksManagementDuringTokenCallback() public {
        CodexVaultToken token = new CodexVaultToken();
        token.setCallback(
            vault,
            address(hook),
            abi.encodeCall(IKernelHook.removeExtension, (poolKey, IHookExtension(address(extension))))
        );
        _deposit(Currency.wrap(address(token)), 100);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResponse(), abi.encodeWithSelector(IKernelHook.ExecutionInProgress.selector));
        assertTrue(hook.isInstalled(poolId, address(extension)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (Currency currency, uint256 amount, address authority, bool leaveTokenSync) =
            abi.decode(data, (Currency, uint256, address, bool));
        if (mode == Mode.MintClaims) {
            // Pay the PoolManager, then mint the claims to the vault, as a taker's payment and a credit would.
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                MockERC20(Currency.unwrap(currency)).transfer(address(manager), amount);
                manager.settle();
            }
            manager.mint(address(vault), currency.toId(), amount);
            return "";
        }
        if (mode == Mode.ClaimDebt) {
            if (leaveTokenSync) manager.sync(currency1);
            // The authority owes the PoolManager; the vault pays from claims first and the authority burns them.
            vm.prank(authority);
            manager.take(currency, address(this), amount);
            vm.prank(authority);
            fromClaims = vault.settleDebtFor(poolId, address(extension), currency, amount, authority);
            if (fromClaims != 0) {
                vm.prank(authority);
                manager.burn(address(vault), currency.toId(), fromClaims);
            }
            return "";
        }
        if (mode == Mode.WithdrawUnlocked) {
            if (leaveTokenSync) manager.sync(syncCurrency);
            vm.prank(address(extension));
            vault.withdraw(poolId, currency, amount, RECIPIENT);
            return "";
        }
        // Taking funds establishes the debt that this installation pays for the unlock caller.
        manager.take(currency, address(this), amount);
        if (leaveTokenSync) manager.sync(currency0);
        vm.prank(authority);
        vault.settleDebtFor(poolId, address(extension), currency, amount, address(this));
        return "";
    }

    // ---------------------------------------------------------------- claim tokens

    function testFuzz_claims_backCredits(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1e30));
        _creditClaims(currency0, amount);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), amount);
        assertEq(manager.balanceOf(address(vault), currency0.toId()), amount);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 0);
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.credit(poolId, address(extension), currency0, 1);
    }

    function test_claims_realTokensAndClaimsBothBackCredits() public {
        _deposit(currency0, 40);
        _creditClaims(currency0, 60);
        assertEq(vault.accountedBalance(currency0), 100);
    }

    function test_settleDebtFor_paysFromClaimsOnly() public {
        _creditClaims(currency0, 100);
        _claimDebt(currency0, 70, address(hook));
        assertEq(fromClaims, 70);
        assertEq(manager.balanceOf(address(vault), currency0.toId()), 30);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 30);
    }

    function test_settleDebtFor_paysClaimsFirstThenTokens() public {
        _deposit(currency0, 40);
        _creditClaims(currency0, 60);
        MockERC20(Currency.unwrap(currency0)).mint(address(manager), 20); // custody for the debt's physical part
        _claimDebt(currency0, 80, vault.routeExecutor());
        assertEq(fromClaims, 60);
        assertEq(manager.balanceOf(address(vault), currency0.toId()), 0);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 20);
        assertEq(vault.balanceOf(poolId, address(extension), currency0), 20);
    }

    function test_settleDebtFor_paysNativeFromClaims() public {
        _creditClaims(NATIVE, 100);
        _deposit(NATIVE, 50);
        vm.deal(address(manager), address(manager).balance + 20); // custody for the debt's physical part
        _claimDebt(NATIVE, 120, address(hook));
        assertEq(fromClaims, 100);
        assertEq(address(vault).balance, 30);
        assertEq(vault.accountedBalance(NATIVE), 30);
    }

    function test_withdraw_redeemsClaimsWhilePoolManagerIsLocked() public {
        _creditClaims(currency0, 100);
        vm.prank(address(extension));
        vault.withdraw(poolId, currency0, 70, RECIPIENT);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(RECIPIENT), 70);
        assertEq(manager.balanceOf(address(vault), currency0.toId()), 30);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 0);
        assertEq(vault.accountedBalance(currency0), 30);
    }

    /// @dev Real 5 and claims 5 support a withdrawal of 8: the real tokens first, then 3 redeemed.
    function test_withdraw_paysRealTokensFirstThenRedeems() public {
        _deposit(currency0, 5);
        _creditClaims(currency0, 5);
        vm.prank(address(extension));
        vault.withdraw(poolId, currency0, 8, RECIPIENT);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(RECIPIENT), 8);
        assertEq(manager.balanceOf(address(vault), currency0.toId()), 2);
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 0);
    }

    function test_withdraw_redeemsNativeClaims() public {
        _creditClaims(NATIVE, 100);
        vm.prank(address(extension));
        vault.withdraw(poolId, NATIVE, 100, RECIPIENT);
        assertEq(RECIPIENT.balance, 100);
        assertEq(manager.balanceOf(address(vault), NATIVE.toId()), 0);
    }

    function test_withdraw_redeemsWhilePoolManagerIsUnlocked() public {
        _creditClaims(currency0, 100);
        mode = Mode.WithdrawUnlocked;
        manager.unlock(abi.encode(currency0, 60, address(0), false));
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(RECIPIENT), 60);
        assertEq(manager.balanceOf(address(vault), currency0.toId()), 40);
    }

    function test_withdraw_revertsRedemptionDuringPendingSync() public {
        _creditClaims(currency0, 100);
        mode = Mode.WithdrawUnlocked;
        syncCurrency = currency0;
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.RedemptionUnavailable.selector));
        manager.unlock(abi.encode(currency0, 60, address(0), true));
    }

    function test_withdraw_revertsRedemptionDuringOtherCurrencySync() public {
        _creditClaims(currency0, 100);
        mode = Mode.WithdrawUnlocked;
        syncCurrency = currency1;
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.RedemptionUnavailable.selector));
        manager.unlock(abi.encode(currency0, 60, address(0), true));
    }

    function test_withdraw_redeemsNativeWhilePoolManagerIsUnlocked() public {
        _creditClaims(NATIVE, 100);
        mode = Mode.WithdrawUnlocked;
        manager.unlock(abi.encode(NATIVE, 60, address(0), false));
        assertEq(RECIPIENT.balance, 60);
        assertEq(manager.balanceOf(address(vault), NATIVE.toId()), 40);
    }

    function test_settleDebtFor_routeExecutorPaysFromClaimsOnly() public {
        _creditClaims(currency1, 100);
        _claimDebt(currency1, 100, vault.routeExecutor());
        assertEq(fromClaims, 100);
        assertEq(manager.balanceOf(address(vault), currency1.toId()), 0);
        assertEq(vault.fundedCurrencyCount(poolId, address(extension)), 0);
    }

    function test_settleDebtFor_kernelHookPaysClaimsFirstThenTokens() public {
        _deposit(currency1, 30);
        _creditClaims(currency1, 50);
        MockERC20(Currency.unwrap(currency1)).mint(address(manager), 30); // custody for the debt's physical part
        _claimDebt(currency1, 70, address(hook));
        assertEq(fromClaims, 50);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault)), 10);
    }

    /// @dev A token taxing transfers out of the PoolManager is credited at its nominal amount, as claims; its
    /// redemption then fails the exact-receipt check and changes nothing.
    function test_withdraw_rejectsRedemptionOfTaxedToken() public {
        CodexVaultToken token = new CodexVaultToken();
        Currency currency = Currency.wrap(address(token));
        token.mint(address(this), 1000);
        _creditClaims(currency, 1000);
        token.setFeeBasisPoints(100);
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.withdraw(poolId, currency, 1000, RECIPIENT);
        assertEq(manager.balanceOf(address(vault), currency.toId()), 1000);
        assertEq(vault.balanceOf(poolId, address(extension), currency), 1000);
        assertEq(token.balanceOf(address(manager)), 1000);
    }

    function test_withdraw_realTokensNeedNoRedemptionDuringPendingSync() public {
        _deposit(currency0, 100);
        mode = Mode.WithdrawUnlocked;
        syncCurrency = currency0;
        manager.unlock(abi.encode(currency0, 60, address(0), true));
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(RECIPIENT), 60);
    }

    function test_withdraw_rejectedNativeRedemptionRollsBack() public {
        _creditClaims(NATIVE, 100);
        CodexVaultRejectNative rejecter = new CodexVaultRejectNative();
        vm.prank(address(extension));
        vm.expectRevert(abi.encodeWithSelector(KernelHookVault.InvalidPayment.selector));
        vault.withdraw(poolId, NATIVE, 100, address(rejecter));
        assertEq(manager.balanceOf(address(vault), NATIVE.toId()), 100);
        assertEq(vault.balanceOf(poolId, address(extension), NATIVE), 100);
    }

    function test_unlockCallback_rejectsOtherCallers() public {
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.unlockCallback(abi.encode(currency0, 1));
        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(IKernelHook.Unauthorized.selector));
        vault.unlockCallback(abi.encode(currency0, 1));
    }

    function test_operators_areKernelHookAndRouteExecutor() public view {
        assertTrue(manager.isOperator(address(vault), address(hook)));
        assertTrue(manager.isOperator(address(vault), vault.routeExecutor()));
    }

    /// @dev Mints claims to the vault and credits them to the extension, as a swap credit does.
    function _creditClaims(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) vm.deal(address(this), amount);
        mode = Mode.MintClaims;
        manager.unlock(abi.encode(currency, amount, address(0), false));
        mode = Mode.Settle;
        vm.prank(address(hook));
        vault.credit(poolId, address(extension), currency, amount);
    }

    function _claimDebt(Currency currency, uint256 amount, address authority) internal {
        mode = Mode.ClaimDebt;
        manager.unlock(abi.encode(currency, amount, authority, false));
        mode = Mode.Settle;
    }

    function _installExtension() internal returns (NoopExtension installed) {
        installed = new NoopExtension(address(hook), CallbackType.BeforeSwap, 0, 0);
        _admit(address(installed));
        hook.installExtension(poolKey, installed, _settings(SWAP_CALLBACKS, false, false));
    }

    function _deposit(Currency currency, uint256 amount) internal {
        if (Currency.unwrap(currency) == address(0)) {
            vm.deal(address(extension), amount);
            vm.prank(address(extension));
            vault.deposit{value: amount}(poolId, address(extension), currency, amount);
            return;
        }
        MockERC20 token = MockERC20(Currency.unwrap(currency));
        token.mint(address(extension), amount);
        vm.startPrank(address(extension));
        token.approve(address(vault), amount);
        vault.deposit(poolId, address(extension), currency, amount);
        vm.stopPrank();
    }

    receive() external payable {}
}
