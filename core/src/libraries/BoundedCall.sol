// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Calls to untrusted extensions that copy at most MAX_RETURNDATA_BYTES of their return or revert data.
/// @dev A callee can return or revert with a very large payload. A normal Solidity call copies all of it
/// into memory, so the caller pays unbounded memory gas (a "returndata bomb"). These calls copy a bounded prefix.
library BoundedCall {
    /// @notice The maximum number of return or revert bytes that a call copies.
    uint256 internal constant MAX_RETURNDATA_BYTES = 256;

    /// @notice Calls target, and reports success only if target returns exactly expectedSize bytes.
    /// @dev A call that returns more than MAX_RETURNDATA_BYTES, or a size other than expectedSize, is a failure.
    /// @return success True if the call succeeded and returned exactly expectedSize bytes.
    /// @return output Up to MAX_RETURNDATA_BYTES of the return or revert data.
    function tryCall(address target, uint256 gasLimit, bytes memory input, uint256 expectedSize)
        internal
        returns (bool success, bytes memory output)
    {
        assembly ("memory-safe") {
            success := call(gasLimit, target, 0, add(input, 32), mload(input), 0, 0)
            let size := returndatasize()
            if gt(size, MAX_RETURNDATA_BYTES) {
                size := MAX_RETURNDATA_BYTES
                success := 0
            }
            if and(success, iszero(eq(size, expectedSize))) { success := 0 }
            output := mload(0x40)
            mstore(output, size)
            returndatacopy(add(output, 32), 0, size)
            mstore(0x40, and(add(add(output, 63), size), not(31)))
        }
    }

    /// @notice Delegatecalls target, and reports success only if target returns exactly expectedSize bytes.
    /// @dev The same bounds as tryCall. The target's code runs in the caller's context, and all of its effects
    /// (storage, transient storage, logs and nested calls) roll back if it reverts, as with a call.
    /// @return success True if the delegatecall succeeded and returned exactly expectedSize bytes.
    /// @return output Up to MAX_RETURNDATA_BYTES of the return or revert data.
    function tryDelegateCall(address target, uint256 gasLimit, bytes memory input, uint256 expectedSize)
        internal
        returns (bool success, bytes memory output)
    {
        assembly ("memory-safe") {
            success := delegatecall(gasLimit, target, add(input, 32), mload(input), 0, 0)
            let size := returndatasize()
            if gt(size, MAX_RETURNDATA_BYTES) {
                size := MAX_RETURNDATA_BYTES
                success := 0
            }
            if and(success, iszero(eq(size, expectedSize))) { success := 0 }
            output := mload(0x40)
            mstore(output, size)
            returndatacopy(add(output, 32), 0, size)
            mstore(0x40, and(add(add(output, 63), size), not(31)))
        }
    }

    /// @notice Static-calls target, and reports success only if target returns exactly one 32-byte word.
    /// @dev Return or revert data whose size is not 32 bytes is discarded: output is then empty.
    /// @return success True if the call succeeded and returned exactly 32 bytes.
    /// @return output The 32-byte return or revert data, or empty bytes when its size differs.
    function tryStaticCall(address target, uint256 gasLimit, bytes memory input)
        internal
        view
        returns (bool success, bytes memory output)
    {
        assembly ("memory-safe") {
            success := staticcall(gasLimit, target, add(input, 32), mload(input), 0, 0)
            let size := returndatasize()
            if iszero(eq(size, 32)) {
                size := 0
                success := 0
            }
            output := mload(0x40)
            mstore(output, size)
            returndatacopy(add(output, 32), 0, size)
            mstore(0x40, add(add(output, 32), size))
        }
    }
}
