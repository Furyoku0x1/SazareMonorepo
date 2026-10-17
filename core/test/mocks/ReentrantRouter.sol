// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockExtension} from "./MockExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {RouteAction} from "../../src/types/KernelHookTypes.sol";

/// @notice A MockExtension that anyone can make start a second route while its callback runs, to test reentry from
/// code that runs inside a route (an adapter, a venue or a token callback).
contract ReentrantRouter is MockExtension {
    RouteAction[] private _reentryRoute;

    constructor(address kernelHook) MockExtension(kernelHook) {}

    function addReentryAction(RouteAction memory action) external {
        _reentryRoute.push(action);
    }

    function reenter() external {
        IKernelHook(KERNEL_HOOK).executeRoute(_reentryRoute);
    }
}
