// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookCatalog} from "./interfaces/IHookCatalog.sol";
import {CallbackLibrary} from "./libraries/CallbackLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice The Sazare registry of extensions that pools may install.
/// @dev Sazare controls admission only, not existing pool installations. Admit immutable implementations
/// only: a proxy's code hash does not pin its implementation. Entries cannot be rewritten, so a new
/// implementation needs a new extension address.
contract HookCatalog is IHookCatalog, Ownable2Step {
    mapping(address => Entry) private _entries;

    constructor() Ownable(msg.sender) {}

    /// @inheritdoc IHookCatalog
    function admit(address extension, Entry calldata entry) external onlyOwner {
        if (extension.code.length == 0) revert InvalidExtension();
        if (entry.codeHash != extension.codehash) revert InvalidExtension();
        if (!entry.admitted) revert InvalidExtension();
        if (entry.callbackMask == 0) revert InvalidCallbackMask();
        if (entry.callbackMask > CallbackLibrary.ALL_CALLBACKS_MASK) revert InvalidCallbackMask();
        if (_entries[extension].codeHash != bytes32(0)) revert AlreadyCatalogued();
        _entries[extension] = entry;
        emit ExtensionAdmitted(extension, entry.codeHash, entry.callbackMask);
    }

    /// @inheritdoc IHookCatalog
    function setAdmission(address extension, bool admitted) external onlyOwner {
        if (_entries[extension].codeHash == bytes32(0)) revert UnknownExtension();
        _entries[extension].admitted = admitted;
        emit AdmissionChanged(extension, admitted);
    }

    /// @inheritdoc IHookCatalog
    function getEntry(address extension) external view returns (Entry memory) {
        return _entries[extension];
    }
}
