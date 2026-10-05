// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Limits, gas reserves and role identifiers shared by KernelHook and its libraries.
library KernelHookConstants {
    /// @notice The maximum number of extensions installed in one pool.
    /// @dev Must be at most 32: OperationFrame.skippedExtensions is a uint32 bitmap indexed by extensionIndex.
    uint256 internal constant MAX_EXTENSIONS = 32;

    /// @notice The highest maximum operation depth that a pool can set. Depth counts the root operation and
    /// the nested operations, without the synthetic frame of unwindPositions.
    uint8 internal constant MAX_OPERATION_DEPTH = 8;

    /// @notice The operation depth of a newly prepared pool.
    uint8 internal constant DEFAULT_MAX_OPERATION_DEPTH = 4;

    /// @notice The gas budget of each callback sequence in a newly prepared pool.
    uint32 internal constant DEFAULT_CALLBACK_GAS_BUDGET = 2_000_000;

    /// @notice The lower bound of the lifecycle gas limit and of each subscribed callback gas limit.
    uint32 internal constant MIN_CALL_GAS = 10_000;

    /// @notice The upper bound of the lifecycle gas limit and of each subscribed callback gas limit.
    uint32 internal constant MAX_CALL_GAS = 5_000_000;

    /// @notice The gas kept for the work after the last extension of a callback sequence returns.
    uint256 internal constant RETURN_GAS_RESERVE = 80_000;

    /// @notice The gas kept for the loop overhead of each extension in a sequence that has not run yet.
    uint256 internal constant ITERATION_GAS_RESERVE = 25_000;

    /// @notice The maximum size of ExtensionSettings.configuration.
    uint256 internal constant MAX_CONFIGURATION_BYTES = 8192;

    /// @notice The ABI size of a CallbackResult: three 32-byte words.
    uint256 internal constant CALLBACK_RESULT_BYTES = 96;

    /// @notice The ABI size of one word, which holds a padded bytes4 selector or a bool.
    uint256 internal constant ABI_WORD_BYTES = 32;

    /// @notice A pool role that can configure, activate, deactivate and order extensions, and set execution limits.
    bytes32 internal constant CONFIGURER_ROLE = keccak256("CONFIGURER_ROLE");

    /// @notice A pool role with all configurer rights, plus installing and removing extensions and managing roles.
    bytes32 internal constant POOL_ADMIN_ROLE = keccak256("POOL_ADMIN_ROLE");
}
