// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {HookCatalog} from "../../src/HookCatalog.sol";
import {IHookCatalog} from "../../src/interfaces/IHookCatalog.sol";
import {CallbackLibrary} from "../../src/libraries/CallbackLibrary.sol";
import {CallbackType} from "../../src/types/KernelHookTypes.sol";
import {NoopExtension} from "../mocks/NoopExtension.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract HookCatalogTest is Test {
    HookCatalog internal catalog;
    NoopExtension internal extension;
    address internal constant NEXT_OWNER = address(0xA11CE);
    address internal constant OUTSIDER = address(0xB0B);

    function setUp() public {
        catalog = new HookCatalog();
        extension = new NoopExtension(address(this), CallbackType.BeforeSwap, 0, 0);
    }

    function test_constructor_setsDeployerAsOwner() public view {
        assertEq(catalog.owner(), address(this));
        assertEq(catalog.pendingOwner(), address(0));
    }

    function test_admit_recordsEveryEntryField() public {
        IHookCatalog.Entry memory entry = _entry();
        catalog.admit(address(extension), entry);

        assertEq(abi.encode(catalog.getEntry(address(extension))), abi.encode(entry));
    }

    function test_admit_emitsExtensionAdmitted() public {
        IHookCatalog.Entry memory entry = _entry();
        vm.expectEmit(true, true, false, true, address(catalog));
        emit IHookCatalog.ExtensionAdmitted(address(extension), entry.codeHash, entry.callbackMask);

        catalog.admit(address(extension), entry);
    }

    function test_admit_revertsWhenExtensionHasNoCode() public {
        IHookCatalog.Entry memory entry = _entry();
        entry.codeHash = OUTSIDER.codehash;
        vm.expectRevert(abi.encodeWithSelector(IHookCatalog.InvalidExtension.selector));

        catalog.admit(OUTSIDER, entry);
    }

    function test_admit_revertsWhenExtensionIsZeroAddress() public {
        IHookCatalog.Entry memory entry = _entry();
        entry.codeHash = address(0).codehash;
        vm.expectRevert(abi.encodeWithSelector(IHookCatalog.InvalidExtension.selector));

        catalog.admit(address(0), entry);
    }

    function testFuzz_admit_revertsWhenCodeHashDiffers(bytes32 codeHash) public {
        IHookCatalog.Entry memory entry = _entry();
        vm.assume(codeHash != entry.codeHash);
        entry.codeHash = codeHash;
        vm.expectRevert(abi.encodeWithSelector(IHookCatalog.InvalidExtension.selector));

        catalog.admit(address(extension), entry);
    }

    function test_admit_revertsWhenEntryIsNotAdmitted() public {
        IHookCatalog.Entry memory entry = _entry();
        entry.admitted = false;
        vm.expectRevert(abi.encodeWithSelector(IHookCatalog.InvalidExtension.selector));

        catalog.admit(address(extension), entry);
    }

    function test_admit_revertsWhenCallbackMaskIsEmpty() public {
        IHookCatalog.Entry memory entry = _entry();
        entry.callbackMask = 0;
        vm.expectRevert(abi.encodeWithSelector(IHookCatalog.InvalidCallbackMask.selector));

        catalog.admit(address(extension), entry);
    }

    function testFuzz_admit_revertsWhenCallbackMaskExceedsAllCallbacks(uint16 mask) public {
        IHookCatalog.Entry memory entry = _entry();
        entry.callbackMask = uint16(bound(mask, uint256(CallbackLibrary.ALL_CALLBACKS_MASK) + 1, type(uint16).max));
        vm.expectRevert(abi.encodeWithSelector(IHookCatalog.InvalidCallbackMask.selector));

        catalog.admit(address(extension), entry);
    }

    function testFuzz_admit_acceptsEveryNonemptySupportedMask(uint16 mask) public {
        IHookCatalog.Entry memory entry = _entry();
        entry.callbackMask = uint16(bound(mask, 1, CallbackLibrary.ALL_CALLBACKS_MASK));

        catalog.admit(address(extension), entry);

        assertEq(catalog.getEntry(address(extension)).callbackMask, entry.callbackMask);
    }

    function testFuzz_admit_preservesCapabilityFlags(bool optional, bool nesting, bool reentrancy, bool late) public {
        IHookCatalog.Entry memory entry = _entry();
        entry.supportsOptionalCallbacks = optional;
        entry.supportsNesting = nesting;
        entry.supportsReentrancy = reentrancy;
        entry.supportsLateInstallation = late;

        catalog.admit(address(extension), entry);

        assertEq(abi.encode(catalog.getEntry(address(extension))), abi.encode(entry));
    }

    function test_admit_revertsWhenAlreadyCatalogued() public {
        IHookCatalog.Entry memory entry = _entry();
        catalog.admit(address(extension), entry);
        vm.expectRevert(abi.encodeWithSelector(IHookCatalog.AlreadyCatalogued.selector));

        catalog.admit(address(extension), entry);
    }

    function test_admit_revertsWhenAlreadyCataloguedButAdmissionRevoked() public {
        IHookCatalog.Entry memory entry = _entry();
        catalog.admit(address(extension), entry);
        catalog.setAdmission(address(extension), false);
        vm.expectRevert(abi.encodeWithSelector(IHookCatalog.AlreadyCatalogued.selector));

        catalog.admit(address(extension), entry);
    }

    function test_admit_revertsWhenCallerIsNotOwner() public {
        IHookCatalog.Entry memory entry = _entry();
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUTSIDER));

        catalog.admit(address(extension), entry);
    }

    function test_setAdmission_revertsWhenExtensionIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(IHookCatalog.UnknownExtension.selector));

        catalog.setAdmission(address(extension), false);
    }

    function test_setAdmission_revertsWhenCallerIsNotOwner() public {
        catalog.admit(address(extension), _entry());
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUTSIDER));

        catalog.setAdmission(address(extension), false);
    }

    function testFuzz_setAdmission_preservesImmutableEntryFields(bool admitted) public {
        IHookCatalog.Entry memory entry = _entry();
        catalog.admit(address(extension), entry);

        catalog.setAdmission(address(extension), admitted);

        entry.admitted = admitted;
        assertEq(abi.encode(catalog.getEntry(address(extension))), abi.encode(entry));
    }

    function test_setAdmission_emitsRevocation() public {
        catalog.admit(address(extension), _entry());
        vm.expectEmit(true, false, false, true, address(catalog));
        emit IHookCatalog.AdmissionChanged(address(extension), false);

        catalog.setAdmission(address(extension), false);
    }

    function test_setAdmission_emitsReadmission() public {
        catalog.admit(address(extension), _entry());
        catalog.setAdmission(address(extension), false);
        vm.expectEmit(true, false, false, true, address(catalog));
        emit IHookCatalog.AdmissionChanged(address(extension), true);

        catalog.setAdmission(address(extension), true);
    }

    function test_setAdmission_emitsWhenValueDoesNotChange() public {
        catalog.admit(address(extension), _entry());
        vm.expectEmit(true, false, false, true, address(catalog));
        emit IHookCatalog.AdmissionChanged(address(extension), true);

        catalog.setAdmission(address(extension), true);
    }

    function test_getEntry_returnsEmptyEntryForUnknownExtension() public view {
        IHookCatalog.Entry memory empty;

        assertEq(abi.encode(catalog.getEntry(OUTSIDER)), abi.encode(empty));
    }

    function test_transferOwnership_setsPendingOwnerWithoutTransferringControl() public {
        catalog.transferOwnership(NEXT_OWNER);

        assertEq(catalog.owner(), address(this));
        assertEq(catalog.pendingOwner(), NEXT_OWNER);
        catalog.admit(address(extension), _entry());
        assertTrue(catalog.getEntry(address(extension)).admitted);
    }

    function test_transferOwnership_emitsOwnershipTransferStarted() public {
        vm.expectEmit(true, true, false, true, address(catalog));
        emit Ownable2Step.OwnershipTransferStarted(address(this), NEXT_OWNER);

        catalog.transferOwnership(NEXT_OWNER);
    }

    function test_transferOwnership_revertsWhenCallerIsNotOwner() public {
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUTSIDER));

        catalog.transferOwnership(NEXT_OWNER);
    }

    function test_admit_revertsWhenCallerIsOnlyPendingOwner() public {
        catalog.transferOwnership(NEXT_OWNER);
        IHookCatalog.Entry memory entry = _entry();
        vm.prank(NEXT_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEXT_OWNER));

        catalog.admit(address(extension), entry);
    }

    function test_acceptOwnership_transfersControlAndClearsPendingOwner() public {
        catalog.transferOwnership(NEXT_OWNER);
        vm.prank(NEXT_OWNER);
        catalog.acceptOwnership();

        assertEq(catalog.owner(), NEXT_OWNER);
        assertEq(catalog.pendingOwner(), address(0));
        IHookCatalog.Entry memory entry = _entry();
        vm.prank(NEXT_OWNER);
        catalog.admit(address(extension), entry);
        assertTrue(catalog.getEntry(address(extension)).admitted);
    }

    function test_acceptOwnership_emitsOwnershipTransferred() public {
        catalog.transferOwnership(NEXT_OWNER);
        vm.expectEmit(true, true, false, true, address(catalog));
        emit Ownable.OwnershipTransferred(address(this), NEXT_OWNER);
        vm.prank(NEXT_OWNER);

        catalog.acceptOwnership();
    }

    function test_acceptOwnership_revertsWhenCallerIsNotPendingOwner() public {
        catalog.transferOwnership(NEXT_OWNER);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OUTSIDER));

        catalog.acceptOwnership();
    }

    function test_acceptOwnership_revertsWhenTransferWasNotStarted() public {
        vm.prank(NEXT_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEXT_OWNER));

        catalog.acceptOwnership();
    }

    function test_setAdmission_revertsWhenCallerIsFormerOwner() public {
        catalog.admit(address(extension), _entry());
        catalog.transferOwnership(NEXT_OWNER);
        vm.prank(NEXT_OWNER);
        catalog.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));

        catalog.setAdmission(address(extension), false);
    }

    function test_transferOwnership_zeroAddressCancelsPendingTransfer() public {
        catalog.transferOwnership(NEXT_OWNER);

        catalog.transferOwnership(address(0));

        assertEq(catalog.owner(), address(this));
        assertEq(catalog.pendingOwner(), address(0));
        vm.prank(NEXT_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEXT_OWNER));
        catalog.acceptOwnership();
    }

    function test_transferOwnership_replacesPendingOwner() public {
        catalog.transferOwnership(NEXT_OWNER);

        catalog.transferOwnership(OUTSIDER);

        assertEq(catalog.pendingOwner(), OUTSIDER);
        vm.prank(NEXT_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEXT_OWNER));
        catalog.acceptOwnership();
        vm.prank(OUTSIDER);
        catalog.acceptOwnership();
        assertEq(catalog.owner(), OUTSIDER);
    }

    function _entry() internal view returns (IHookCatalog.Entry memory) {
        return IHookCatalog.Entry({
            codeHash: address(extension).codehash,
            callbackMask: CallbackLibrary.ALL_CALLBACKS_MASK,
            supportsOptionalCallbacks: true,
            supportsNesting: true,
            supportsReentrancy: true,
            supportsLateInstallation: true,
            admitted: true
        });
    }
}
