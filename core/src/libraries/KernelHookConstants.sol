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
    /// @dev Fits 8 required extensions with a 100,000 gas limit each, on a callback that can
    /// return deltas: 8 * (100,000 + 3,225 + 250,000) + RETURN_GAS_RESERVE + SEQUENCE_GAS_RESERVE
    /// + 8 * (ITERATION_GAS_RESERVE + SUBSCRIBER_GAS_RESERVE) = 3,226,800.
    uint32 internal constant DEFAULT_CALLBACK_GAS_BUDGET = 4_000_000;

    /// @notice The lower bound of the lifecycle gas limit and of each subscribed callback gas limit.
    uint32 internal constant MIN_CALL_GAS = 10_000;

    /// @notice The upper bound of the lifecycle gas limit and of each subscribed callback gas limit.
    uint32 internal constant MAX_CALL_GAS = 5_000_000;

    /// @notice The gas kept for the work after the last extension of a callback sequence returns.
    uint256 internal constant RETURN_GAS_RESERVE = 80_000;

    /// @notice The gas that a callback sequence uses for its own setup and its first admission check, apart from the
    /// work for each subscriber. The callback's budget pays for it.
    /// @dev Measured at about 14,500 gas with cold storage.
    uint256 internal constant SEQUENCE_GAS_RESERVE = 25_000;

    /// @notice The gas that the setup of a callback sequence uses for each subscriber: it reads the subscriber's
    /// settings to sum the required invocation gas before the first extension runs. The callback's budget pays for it.
    /// @dev Measured at about 10,000 gas for a required subscriber with cold storage. The setup reads all subscribers
    /// before the first admission check, so a reserve for each subscriber is necessary: a fixed reserve does not
    /// cover a long callback order.
    uint256 internal constant SUBSCRIBER_GAS_RESERVE = 12_000;

    /// @notice The gas kept for the loop overhead of each extension in a sequence that has not run yet.
    uint256 internal constant ITERATION_GAS_RESERVE = 25_000;

    /// @notice The gas that KernelHook adds to each extension call for its own work: the delegatecall into the
    /// dispatch library, the checks, the reentry counter, the context, and the validation of the result.
    /// The extension's gas limit does not pay for it.
    /// @dev Measured at about 19,500 gas in the worst case: an initialization callback with cold storage, which also
    /// records the completed callback. KernelHook encodes the callback data twice on the way to the extension, so the
    /// margin also limits the hookData size that fits.
    uint256 internal constant INVOCATION_GAS_RESERVE = 40_000;

    /// @notice The gas that KernelHook also adds to each call of a callback that can return deltas, to settle
    /// them with the PoolManager and the vault.
    /// @dev The first vault credit of a currency costs about 100,000 gas with a standard ERC20 token, and a result
    /// has two currencies. A token with a more expensive transfer can need more: the call then fails.
    uint256 internal constant SETTLEMENT_GAS_RESERVE = 210_000;

    /// @notice The gas that a CALL to a cold account costs before it forwards gas (EIP-2929).
    uint256 internal constant COLD_CALL_GAS = 2600;

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
