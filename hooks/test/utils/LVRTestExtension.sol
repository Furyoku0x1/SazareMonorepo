// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "core/src/interfaces/IKernelHookExtension.sol";
import {CallbackResult, ExecutionContext, ExtensionSettings, RouteAction} from "core/src/types/KernelHookTypes.sol";
import {IExtensionVault, IKernelVaultHost} from "../../src/base/KernelExtension.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only required-failure, competing-fee and single-route extension.
contract LVRTestExtension is IKernelHookExtension {
    IKernelHook private immutable _kernel;
    bool public fail;
    uint24 public feeOverride;
    int128 private _delta0;
    int128 private _delta1;
    bool private _routeEnabled;
    RouteAction private _route;
    uint256 public routedCount;

    constructor(IKernelHook kernel) {
        _kernel = kernel;
    }

    function setBehavior(bool fail_, uint24 fee_) external {
        fail = fail_;
        feeOverride = fee_;
    }

    function setDeltas(int128 delta0, int128 delta1) external {
        _delta0 = delta0;
        _delta1 = delta1;
    }

    function setRoute(RouteAction memory route) external {
        _route = route;
        _routeEnabled = true;
    }

    function deposit(PoolId pool, Currency currency, uint256 amount) external {
        IExtensionVault vault = IKernelVaultHost(address(_kernel)).VAULT();
        IERC20(Currency.unwrap(currency)).approve(address(vault), amount);
        vault.deposit(pool, address(this), currency, amount);
    }

    function onInstall(PoolKey calldata, ExtensionSettings calldata) external view returns (bytes4) {
        _checkKernel();
        return this.onInstall.selector;
    }

    function onConfigure(PoolKey calldata, ExtensionSettings calldata, ExtensionSettings calldata)
        external
        view
        returns (bytes4)
    {
        _checkKernel();
        return this.onConfigure.selector;
    }

    function onUninstall(PoolKey calldata, bytes calldata) external view returns (bytes4) {
        _checkKernel();
        return this.onUninstall.selector;
    }

    function canActivate(PoolKey calldata, ExtensionSettings calldata) external pure returns (bool) {
        return true;
    }

    function canUninstall(PoolKey calldata) external pure returns (bool) {
        return true;
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata)
        external
        returns (CallbackResult memory)
    {
        _checkKernel();
        require(!fail, "test callback failure");
        if (_routeEnabled) {
            RouteAction[] memory actions = new RouteAction[](1);
            actions[0] = _route;
            routedCount = _kernel.executeRoute(actions).length;
        }
        return CallbackResult(_delta0, _delta1, feeOverride);
    }

    function _checkKernel() private view {
        require(msg.sender == address(_kernel), "kernel only");
    }
}
