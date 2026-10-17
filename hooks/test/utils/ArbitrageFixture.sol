// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {NetworkFixture} from "./NetworkFixture.sol";
import {ArbitrageHook} from "../../src/arbitrage/ArbitrageHook.sol";
import {OrderMath} from "../../src/libraries/limitorder/OrderMath.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {ExtensionSettings, CallbackType} from "core/src/types/KernelHookTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

abstract contract ArbitrageFixture is NetworkFixture {
    /// @dev Fits the default 4M callback budget with the 1.5M search and 1.5M execution reserve below.
    uint32 internal constant ARBITRAGE_CALLBACK_GAS = 3_300_000;

    ArbitrageHook internal arbitrage;

    function setUp() public virtual override {
        super.setUp();
        arbitrage = new ArbitrageHook(IKernelHook(address(hook)), network);
        uint16 mask = uint16(1) << uint8(CallbackType.AfterSwap);
        catalog.admit(
            address(arbitrage), IHookCatalog.Entry(address(arbitrage).codehash, mask, true, true, false, true, true)
        );
    }

    function _policy() internal view returns (ArbitrageHook.Policy memory policy) {
        policy.samePair = 16;
        policy.triangles = 8;
        policy.quads = 16;
        policy.sized = 4;
        policy.minimumSurplus = 1;
        policy.maximumInput = uint128(OrderMath.MAX_DELTA);
        policy.searchGasLimit = 1_500_000;
        policy.executionGasReserve = 1_500_000;
        policy.profitCurrency0 = true;
        policy.beneficiary = address(this);
    }

    function _arbitrageSettings(uint64 version) internal pure returns (ExtensionSettings memory settings) {
        settings = _settings(uint16(1) << uint8(CallbackType.AfterSwap), true, true, ARBITRAGE_CALLBACK_GAS);
        settings.lifecycleGasLimit = 500_000;
        settings.configuration = abi.encode(version);
    }

    /// @dev Registers the origin in the network if needed, installs Arbitrage, sets the default policy and activates.
    function _installArbitrage(PoolKey memory origin) internal {
        _installArbitrage(origin, _policy());
    }

    function _installArbitrage(PoolKey memory origin, ArbitrageHook.Policy memory policy) internal {
        _ensureRegistered(origin);
        hook.installExtension(origin, IHookExtension(address(arbitrage)), _arbitrageSettings(0));
        arbitrage.setPolicy(origin, 0, policy);
        hook.configureExtension(origin, IHookExtension(address(arbitrage)), _arbitrageSettings(1));
        hook.activateExtension(origin, IHookExtension(address(arbitrage)));
    }

    function _ensureRegistered(PoolKey memory target) internal returns (uint32 index) {
        PoolId id = target.toId();
        index = network.poolIndexOf(id);
        if (index == 0 || !network.poolRecord(index).active) index = network.register(target);
    }

    function _refreshRoot() internal {
        network.refresh(network.tokenIdOf(currency0), network.tokenIdOf(currency1));
    }
}
