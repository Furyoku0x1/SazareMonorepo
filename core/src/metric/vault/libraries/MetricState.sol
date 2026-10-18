// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IMetricPool} from "../interfaces/IMetricPool.sol";

/// @notice Reads of a Metric pool's storage. Slots and bit layouts are from Metric's `PoolStateLibrary` and
/// `Slot0Library` at pool-contracts 99aa896 (MIT).
library MetricState {
    uint256 internal constant SLOT0 = 0;
    uint256 internal constant MAPPING_BIN_STATES = 4;
    uint256 internal constant MAPPING_BIN_TOTAL_SHARES = 5;
    uint256 internal constant MAPPING_POSITION_BIN_SHARES = 6;
    /// @dev The last position in a bin, `type(uint104).max`.
    uint256 internal constant MAX_POSITION = type(uint104).max;

    struct Cursor {
        int16 binIndex;
        uint104 positionInBin;
        int24 binDistanceE6;
        /// @dev The pool-wide notional fee, in 1e-8; Metric's factory may change it.
        uint24 notionalFeeE8;
    }

    struct Bin {
        uint104 balance0Scaled;
        uint104 balance1Scaled;
        uint16 lengthE6;
        /// @dev The bin's additional fees, in 1e-6; Metric's factory may change them.
        uint16 addFeeBuyE6;
        uint16 addFeeSellE6;
        uint256 totalShares;
    }

    function cursor(address pool) internal view returns (Cursor memory current) {
        uint256 packed = uint256(IMetricPool(pool).extsload(bytes32(SLOT0)));
        int256 binIndexWide;
        int256 distanceWide;
        assembly ("memory-safe") {
            binIndexWide := signextend(1, shr(8, packed))
            distanceWide := signextend(2, shr(128, packed))
        }
        current.binIndex = int16(binIndexWide);
        current.positionInBin = uint104((packed >> 24) & type(uint104).max);
        current.binDistanceE6 = int24(distanceWide);
        current.notionalFeeE8 = uint24((packed >> 176) & 0xFFFFFF);
    }

    /// @notice A bin's balances, length, additional fees and total shares, in one storage read call.
    function bin(address pool, int16 binIndex) internal view returns (Bin memory state) {
        bytes32[] memory slots = new bytes32[](2);
        slots[0] = _slot(int256(binIndex), MAPPING_BIN_STATES);
        slots[1] = _slot(int256(binIndex), MAPPING_BIN_TOTAL_SHARES);
        bytes32[] memory words = IMetricPool(pool).extsload(slots);
        uint256 packed = uint256(words[0]);
        state.balance0Scaled = uint104(packed & type(uint104).max);
        state.balance1Scaled = uint104((packed >> 104) & type(uint104).max);
        state.lengthE6 = uint16((packed >> 208) & 0xFFFF);
        state.addFeeBuyE6 = uint16((packed >> 224) & 0xFFFF);
        state.addFeeSellE6 = uint16((packed >> 240) & 0xFFFF);
        state.totalShares = uint256(words[1]);
    }

    /// @notice `owner`'s shares in a bin under `salt`.
    function positionShares(address pool, address owner, uint80 salt, int16 binIndex) internal view returns (uint256) {
        bytes32 key = keccak256(abi.encode(owner, salt, binIndex));
        bytes32 slot = keccak256(abi.encode(key, MAPPING_POSITION_BIN_SHARES));
        return uint256(IMetricPool(pool).extsload(slot));
    }

    function _slot(int256 key, uint256 baseSlot) private pure returns (bytes32) {
        return keccak256(abi.encode(key, baseSlot));
    }
}
