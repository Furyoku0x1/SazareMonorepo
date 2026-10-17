// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @dev Internal-only bounded calls: no library deployment/linking is required.
library ExtensionRead {
    function read(address target, uint256 gasLimit, uint256 maximumBytes, bytes memory input)
        internal
        view
        returns (bool success, bytes memory output)
    {
        assembly ("memory-safe") {
            success := staticcall(gasLimit, target, add(input, 32), mload(input), 0, 0)
            let size := returndatasize()
            if or(iszero(success), gt(size, maximumBytes)) {
                success := 0
                size := 0
            }
            output := mload(0x40)
            mstore(output, size)
            returndatacopy(add(output, 32), 0, size)
            mstore(0x40, and(add(add(output, 63), size), not(31)))
        }
    }
}
