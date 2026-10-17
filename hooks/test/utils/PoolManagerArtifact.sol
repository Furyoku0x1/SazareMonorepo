// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Build v4's pinned compiler unit separately from extensions and Kernel (0.8.37); tests deploy these with deployCode.
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {MockV4Router} from "v4-periphery/test/mocks/MockV4Router.sol";
