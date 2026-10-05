// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice A registry of extension implementations that pools are allowed to install.
/// @dev The catalog controls admission only. It cannot change or remove an existing installation,
/// because KernelHook copies the entry into the installation when it installs the extension.
interface IHookCatalog {
    /// @notice What the catalog records about one extension implementation.
    struct Entry {
        /// @notice The runtime code hash of the extension. A proxy's hash does not pin its implementation,
        /// so admit only immutable implementations.
        bytes32 codeHash;
        /// @notice The callbacks that the extension implements (bit i = CallbackType(i)).
        uint16 callbackMask;
        /// @notice True if the extension stays correct when KernelHook skips any one of its callbacks.
        bool supportsOptionalCallbacks;
        /// @notice True if the extension may start nested routes with executeRoute.
        bool supportsNesting;
        /// @notice True if the extension may be called again while one of its calls is in progress.
        bool supportsReentrancy;
        /// @notice True if a pool may install the extension after the pool is initialized.
        bool supportsLateInstallation;
        /// @notice True while new installations of the extension are allowed.
        bool admitted;
    }

    /// @notice Thrown when the extension has no code, its code hash differs from the entry, or the entry is not admitted.
    error InvalidExtension();

    /// @notice Thrown when the entry's callback mask is empty or includes bits beyond the ten callbacks.
    error InvalidCallbackMask();

    /// @notice Thrown when the extension already has an entry. Entries cannot be rewritten.
    error AlreadyCatalogued();

    /// @notice Thrown when the extension has no entry.
    error UnknownExtension();

    /// @notice Emitted when the owner adds an extension to the catalog.
    /// @param extension The extension address
    /// @param codeHash The runtime code hash recorded for the extension
    /// @param callbackMask The callbacks that the extension implements
    event ExtensionAdmitted(address indexed extension, bytes32 indexed codeHash, uint16 callbackMask);

    /// @notice Emitted when the owner allows or stops new installations of an extension.
    /// @param extension The extension address
    /// @param admitted True if new installations are now allowed
    event AdmissionChanged(address indexed extension, bool admitted);

    /// @notice Adds an extension to the catalog. Only the owner can call this.
    /// @dev A new implementation of an extension needs a new address and a new entry.
    /// @param extension The deployed extension
    /// @param entry The entry to record. entry.admitted must be true.
    function admit(address extension, Entry calldata entry) external;

    /// @notice Allows or stops new installations of a catalogued extension. Only the owner can call this.
    /// @dev Existing installations are not affected.
    /// @param extension The catalogued extension
    /// @param admitted True to allow new installations
    function setAdmission(address extension, bool admitted) external;

    /// @notice Returns the entry of an extension, or an empty entry if the extension is not catalogued.
    /// @param extension The extension address
    /// @return The recorded entry
    function getEntry(address extension) external view returns (Entry memory);
}
