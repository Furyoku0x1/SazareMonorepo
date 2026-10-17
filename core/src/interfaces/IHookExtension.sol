// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Marks a contract as a KernelHook extension.
/// @dev An executable extension implements IKernelHookExtension, which extends this interface.
/// Draft extensions can inherit only this marker until they implement the full interface.
interface IHookExtension {}
