// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ExtensionFixture} from "./utils/ExtensionFixture.sol";
import {LVRHook} from "../src/lvr/uniswap-v4/LVRHook.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Run --isolate --hardfork cancun: each router call has cold transaction access state.
contract LVRGasTest is ExtensionFixture {
    LVRHook private lvr;
    PoolKey private guarded;

    function setUp() public override {
        if (!vm.isIsolateMode()) vm.skip(true);
        super.setUp();
        vm.warp(100);
        lvr = LVRHook(deployCode("LVRHook.sol:LVRHook", abi.encode(IKernelHook(address(hook)))));
        catalog.admit(
            address(lvr),
            IHookCatalog.Entry(address(lvr).codehash, lvr.CALLBACK_MASK(), false, false, false, true, true)
        );
        guarded = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        _createPool(guarded);
        _wideLiquidity(guarded);
        ExtensionSettings memory settings = _settings(lvr.CALLBACK_MASK(), false, false, 150_000);
        settings.lifecycleGasLimit = 500_000;
        settings.configuration = abi.encode(uint64(0));
        hook.installExtension(guarded, IHookExtension(address(lvr)), settings);
        lvr.setPolicy(guarded, 0, LVRHook.Policy(3000, 10_000, 2000, 10, 60, 10, 2));
        settings.configuration = abi.encode(uint64(1));
        hook.configureExtension(guarded, IHookExtension(address(lvr)), settings);
        hook.activateExtension(guarded, IHookExtension(address(lvr)));
    }

    function test_gas_kernelBaseline() public {
        _swapExactInput(key, true, 1e14);
        _record("kernel_baseline");
    }

    function test_gas_firstObservation() public {
        _swapExactInput(guarded, true, 1e14);
        _record("first_observation");
    }

    function test_gas_sameWindowSubsequentTransaction() public {
        _swapExactInput(guarded, true, 1e14);
        _swapExactInput(guarded, true, 1e14);
        _record("same_window_subsequent_tx");
    }

    function test_gas_newWindowSubsequentTransaction() public {
        _swapExactInput(guarded, true, 1e14);
        vm.warp(110);
        _swapExactInput(guarded, true, 1e14);
        _record("new_window_subsequent_tx");
    }

    function test_gas_cappedPriceMove() public {
        _swapExactInput(guarded, true, 1e17);
        _record("capped_price_move");
    }

    function _record(string memory label) private {
        Vm.Gas memory measured = vm.lastFrameGas();
        assertEq(measured.gasStateUsed, 0);
        uint256 gross = measured.gasTotalUsed;
        uint256 refund = uint256(uint64(measured.gasRefunded));
        assertLe(refund, gross / 5);
        vm.snapshotValue("LVRGas", string.concat(label, "_gross"), gross);
        vm.snapshotValue("LVRGas", string.concat(label, "_net"), gross - refund);
        emit log_string(label);
        emit log_named_uint("receipt_gas_gross", gross);
        emit log_named_uint("receipt_gas_net", gross - refund);
    }
}
