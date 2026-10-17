// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {MockExtension} from "./MockExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {RouteAction} from "../../src/types/KernelHookTypes.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Lets one installed extension request a route from another extension's callback.
contract CodexRouteCaller is MockExtension {
    constructor(address kernelHook) MockExtension(kernelHook) {}

    function callRoute(RouteAction[] calldata actions) external returns (BalanceDelta[] memory) {
        return IKernelHook(KERNEL_HOOK).executeRoute(actions);
    }
}
