// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// The PoolManager pins solc 0.8.26 and the KernelHook sources pin 0.8.37, so no compilation unit can import both.
// This file makes forge build the PoolManager artifact; the fixture deploys it with StdCheats.deployCode.
import {PoolManager} from "v4-core/src/PoolManager.sol";
