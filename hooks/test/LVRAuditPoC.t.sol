// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ExtensionFixture} from "./utils/ExtensionFixture.sol";
import {LVRHook} from "../src/lvr/uniswap-v4/LVRHook.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {CallbackType, ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @dev LVRHook audit findings (2026-10-10), open and deferred (hooks/docs/lvr-audit-2026-10-10.md): each test passes
/// while the behavior it describes is present. Invert it when the finding is fixed.
contract LVRAuditPoC is ExtensionFixture {
    LVRHook internal lvr;
    PoolKey internal dynamicKey;
    PoolId internal dynamicPool;

    function _deploy(LVRHook.Policy memory policy) private {
        vm.warp(100);
        lvr = LVRHook(deployCode("LVRHook.sol:LVRHook", abi.encode(IKernelHook(address(hook)))));
        catalog.admit(
            address(lvr),
            IHookCatalog.Entry(address(lvr).codehash, lvr.CALLBACK_MASK(), false, false, false, true, true)
        );
        dynamicKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        dynamicPool = dynamicKey.toId();
        _createPool(dynamicKey);
        _wideLiquidity(dynamicKey);
        ExtensionSettings memory s = _settings(lvr.CALLBACK_MASK(), false, false, 150_000);
        s.lifecycleGasLimit = 500_000;
        s.configuration = abi.encode(uint64(0));
        hook.installExtension(dynamicKey, IHookExtension(address(lvr)), s);
        lvr.setPolicy(dynamicKey, 0, policy);
        s.configuration = abi.encode(uint64(1));
        hook.configureExtension(dynamicKey, IHookExtension(address(lvr)), s);
        hook.activateExtension(dynamicKey, IHookExtension(address(lvr)));
    }

    /// @dev Sol M-3: decay is applied once per window opening, rounded down, so one-unit swaps in successive windows
    /// erase risk far faster than the formula applied once over the same time. One-second windows, 30-day decay.
    function test_poc_dustRefreshesEraseRisk() public {
        _deploy(LVRHook.Policy(3000, 10_000, 0, 10, 30 days, 1, 1));
        _swapExactInput(dynamicKey, true, 3e15); // a price move
        uint256 risk = lvr.observation(dynamicPool).windowMovement;
        emit log_named_uint("risk after the move (ticks)", risk);
        assertGt(risk, 50);
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + risk);
        _swapExactInput(dynamicKey, true, 1);
        uint256 once = lvr.observation(dynamicPool).volatilityTicks;
        vm.revertToState(snap);
        for (uint256 i; i < risk; ++i) {
            vm.warp(block.timestamp + 1);
            _swapExactInput(dynamicKey, true, 1);
        }
        uint256 refreshed = lvr.observation(dynamicPool).volatilityTicks;
        emit log_named_uint("risk after the same time, observed once", once);
        emit log_named_uint("risk after one dust swap per second", refreshed);
        assertGe(once, risk - 1, "observed once, almost nothing decays");
        assertLe(refreshed, 1, "refreshed every second, the risk is gone");
    }

    /// @dev Sol M-4: movement late in a window is aged from the window's opening. 60-second windows, 1-second decay:
    /// a move at second 59 is almost entirely decayed one second later.
    function test_poc_lateMovementDecaysWithTheWindowsAge() public {
        _deploy(LVRHook.Policy(3000, 10_000, 0, 10, 1, 1, 60));
        vm.warp(120); // a window opens at 120
        _swapExactInput(dynamicKey, true, 1);
        vm.warp(179);
        _swapExactInput(dynamicKey, true, 3e15); // the move, a second before the boundary
        uint256 moved = lvr.observation(dynamicPool).windowMovement;
        vm.warp(180);
        (uint24 fee,,) = lvr.previewFee(dynamicPool);
        emit log_named_uint("movement (ticks)", moved);
        emit log_named_uint("fee one second later", fee);
        assertLt(fee, 3000 + moved * 10 / 4, "most of a one-second-old move is gone");
    }

    /// @dev Sol L-5: the idle premium measures window openings, so a dust swap in one window lowers the next window's
    /// premium for a large swap.
    function test_poc_dustLowersTheIdlePremium() public {
        _deploy(LVRHook.Policy(3000, 10_000, 2000, 10, 60, 10, 2));
        vm.warp(110);
        _swapExactInput(dynamicKey, true, 1);
        assertEq(lvr.observation(dynamicPool).windowFee, 5000, "the full idle premium");
        vm.warp(112);
        (uint24 fee,,) = lvr.previewFee(dynamicPool);
        assertEq(fee, 3400, "two seconds later the next window opens near the base fee");
    }
}
