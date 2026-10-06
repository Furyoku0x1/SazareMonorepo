// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KernelHook} from "../../src/KernelHook.sol";
import {KernelHookVault} from "../../src/KernelHookVault.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "../../src/interfaces/IKernelHookExtension.sol";
import {
    CallbackResult,
    CallbackType,
    ExecutionContext,
    ExtensionSettings,
    RouteAction
} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice A configurable extension for behavior tests. For each callback, a test sets the result, a revert, an
/// amount of gas to burn, a route to run, and an external call to make. The extension keeps a count of the calls for
/// each callback, and the context and data hash of the latest call.
/// @dev Its storage writes cost gas, so most gas benchmarks use NoopExtension. The Mock benchmarks measure the full
/// Mock scenario, including these writes.
contract MockExtension is IKernelHookExtension {
    struct Behavior {
        int128 delta0;
        int128 delta1;
        uint24 feeOverride;
        bool shouldRevert;
        uint256 gasToBurn;
    }

    address public immutable KERNEL_HOOK;
    KernelHookVault public immutable VAULT;

    mapping(CallbackType => Behavior) public behaviorOf;
    mapping(CallbackType => uint256) public callCount;
    ExecutionContext internal _lastContext;
    /// @dev A hash, not the full data, so that the storage cost does not change with the size of the data.
    bytes32 public lastCallbackDataHash;

    bool public canActivateResult = true;
    bool public canUninstallResult = true;
    bool public lifecycleReverts;
    uint256 public lifecycleCallCount;

    mapping(CallbackType => RouteAction[]) internal _routes;
    BalanceDelta[] internal _lastRouteResults;

    mapping(CallbackType => address) internal _callTargets;
    mapping(CallbackType => bytes) internal _callData;

    error NotKernelHook();
    error MockRevert(CallbackType callback);

    constructor(address kernelHook) {
        KERNEL_HOOK = kernelHook;
        VAULT = KernelHook(kernelHook).VAULT();
    }

    modifier onlyKernelHook() {
        if (msg.sender != KERNEL_HOOK) revert NotKernelHook();
        _;
    }

    function setBehavior(CallbackType callback, Behavior calldata behavior) external {
        behaviorOf[callback] = behavior;
    }

    function setLifecycle(bool canActivate_, bool canUninstall_, bool lifecycleReverts_) external {
        canActivateResult = canActivate_;
        canUninstallResult = canUninstall_;
        lifecycleReverts = lifecycleReverts_;
    }

    /// @notice Adds an action to the route that the extension starts from callback.
    function addRouteAction(CallbackType callback, RouteAction memory action) external {
        _routes[callback].push(action);
    }

    function clearRoute(CallbackType callback) external {
        delete _routes[callback];
    }

    /// @notice Makes the extension call target with data from callback. If that call fails, the callback reverts
    /// with the same data. Tests use it to call a contract from inside an operation as an untrusted caller.
    function setExternalCall(CallbackType callback, address target, bytes calldata data) external {
        _callTargets[callback] = target;
        _callData[callback] = data;
    }

    /// @notice Deposits tokens that this contract holds, or the native currency sent with this call, into its own
    /// vault balance for the pool.
    function deposit(PoolId poolId, Currency currency, uint256 amount) external payable {
        if (Currency.unwrap(currency) == address(0)) {
            VAULT.deposit{value: amount}(poolId, address(this), currency, amount);
            return;
        }
        IERC20(Currency.unwrap(currency)).approve(address(VAULT), amount);
        VAULT.deposit(poolId, address(this), currency, amount);
    }

    function withdraw(PoolId poolId, Currency currency, uint256 amount, address to) external {
        VAULT.withdraw(poolId, currency, amount, to);
    }

    function unwindPositions(PoolKey calldata key, RouteAction[] calldata actions)
        external
        returns (BalanceDelta[] memory)
    {
        return IKernelHook(KERNEL_HOOK).unwindPositions(key, actions);
    }

    function lastContext() external view returns (ExecutionContext memory) {
        return _lastContext;
    }

    function lastRouteResults() external view returns (BalanceDelta[] memory) {
        return _lastRouteResults;
    }

    function onInstall(PoolKey calldata, ExtensionSettings calldata) external onlyKernelHook returns (bytes4) {
        return _lifecycleSelector(IKernelHookExtension.onInstall.selector);
    }

    function onConfigure(PoolKey calldata, ExtensionSettings calldata, ExtensionSettings calldata)
        external
        onlyKernelHook
        returns (bytes4)
    {
        return _lifecycleSelector(IKernelHookExtension.onConfigure.selector);
    }

    function canActivate(PoolKey calldata, ExtensionSettings calldata) external view returns (bool) {
        return canActivateResult;
    }

    function canUninstall(PoolKey calldata) external view returns (bool) {
        return canUninstallResult;
    }

    function onUninstall(PoolKey calldata, bytes calldata) external onlyKernelHook returns (bytes4) {
        return _lifecycleSelector(IKernelHookExtension.onUninstall.selector);
    }

    function onCallback(
        ExecutionContext calldata context,
        PoolKey calldata,
        bytes calldata,
        bytes calldata callbackData
    ) external onlyKernelHook returns (CallbackResult memory) {
        _lastContext = context;
        lastCallbackDataHash = keccak256(callbackData);
        ++callCount[context.callback];
        Behavior memory behavior = behaviorOf[context.callback];
        if (behavior.shouldRevert) revert MockRevert(context.callback);
        _burnGas(behavior.gasToBurn);
        address callTarget = _callTargets[context.callback];
        if (callTarget != address(0)) _callExternal(callTarget, _callData[context.callback]);
        if (_routes[context.callback].length != 0) {
            BalanceDelta[] memory results = IKernelHook(KERNEL_HOOK).executeRoute(_routes[context.callback]);
            delete _lastRouteResults;
            // results.length <= MAX_ACTIONS
            for (uint256 i; i < results.length; ++i) {
                _lastRouteResults.push(results[i]);
            }
        }
        return CallbackResult(behavior.delta0, behavior.delta1, behavior.feeOverride);
    }

    function _lifecycleSelector(bytes4 selector) private returns (bytes4) {
        if (lifecycleReverts) revert MockRevert(CallbackType.BeforeInitialize);
        ++lifecycleCallCount;
        return selector;
    }

    function _callExternal(address target, bytes memory data) private {
        (bool success, bytes memory reason) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _burnGas(uint256 amount) private view {
        uint256 start = gasleft();
        // The loop ends when amount gas is used, or the call runs out of gas.
        while (start - gasleft() < amount) {}
    }
}
