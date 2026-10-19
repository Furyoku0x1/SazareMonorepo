// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "metric/MetricOmmPoolDeployer.sol";
import {BinState} from "metric/types/PoolStorage.sol";
import {LiquidityDelta} from "metric/types/PoolOperation.sol";
import {VaultParameters, Venue} from "vault/VaultTypes.sol";
import {MetricState} from "vault/libraries/MetricState.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice The weight cap on pools others also hold, and what the window's size costs in gas.
contract MetricVenueCapAndGasTest is MetricFixture {
    /// @dev A second vault on a fresh pool, with the given cap and window.
    function _vaultOnNewPool(bytes32 salt, uint16 weightCapBps, uint8 binCount)
        internal
        returns (MetricOmmPool newPool, uint256 newVaultId)
    {
        newPool = _newPool(salt);
        outsider.addLiquidity(newPool, _outsideDeltas());
        VaultParameters memory parameters = defaultParameters();
        parameters.pool = address(newPool);
        parameters.weightCapBps = weightCapBps;
        parameters.binCount = binCount;
        vm.prank(owner);
        newVaultId = vault.createVault(parameters, defaultCurves());
    }

    /// @dev With a 50% cap and an outsider holding ten base per bin, the vault never holds more than half of a bin's
    /// shares where the outsider also holds some; the rest of its deposit waits in the buffer.
    function test_weightCap_holdsAtMostHalfOfSharedBins() public {
        (MetricOmmPool capped, uint256 cappedId) = _vaultOnNewPool("capped", 5_000, 16);
        vm.prank(lender);
        vault.deposit(cappedId, 100e18, 200_000e6, 0, lender);
        Venue memory venue = vault.venueOf(cappedId);
        // window bins
        for (uint256 offset = 0; offset < 16; ++offset) {
            int16 binIndex = int16(int256(venue.lowestBin) + int256(offset));
            uint256 ours = MetricState.positionShares(address(capped), address(vault), uint80(cappedId), binIndex);
            uint256 total = MetricState.bin(address(capped), binIndex).totalShares;
            if (ours == total) continue;
            assertLe(ours * 10_000, total * 5_000 + 10_000, "at most half of a shared bin");
        }
        assertGt(vault.ledgerOf(cappedId).buffer0, 0, "the excess waits in the buffer");
    }

    /// @dev Reports deposit gas with a 16-bin and a 32-bin window, each already placed.
    function test_gas_windowSixteenVersusThirtyTwo() public {
        (, uint256 sixteen) = _vaultOnNewPool("sixteen", 10_000, 16);
        (, uint256 thirtyTwo) = _vaultOnNewPool("thirtyTwo", 10_000, 32);
        uint256 gas16 = _depositGas(sixteen);
        uint256 gas32 = _depositGas(thirtyTwo);
        emit log_named_uint("deposit gas, 16-bin window", gas16);
        emit log_named_uint("deposit gas, 32-bin window", gas32);
        assertGt(gas32, gas16, "a wider window costs more");
    }

    function _depositGas(uint256 id) internal returns (uint256) {
        vm.prank(lender);
        vault.deposit(id, 20e18, 40_000e6, 0, lender);
        uint256 gasBefore = gasleft();
        vm.prank(lender);
        vault.deposit(id, 1e18, 2_000e6, 0, lender);
        return gasBefore - gasleft();
    }

    function _newPool(bytes32 salt) internal returns (MetricOmmPool) {
        MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(this));
        MetricOmmPoolDeployer.DeployParams memory params;
        params.salt = salt;
        params.factory = address(this);
        params.token0 = address(base);
        params.token1 = address(quote);
        params.priceProvider = address(provider);
        params.immutablePriceProvider = true;
        params.token0ScaleMultiplier = 1;
        params.token1ScaleMultiplier = 1e12;
        params.initialScaledAmount0PerShareE18 = 1e18;
        params.initialScaledAmount1PerShareE18 = 2_000e18;
        params.minimalOperationalLiquidity = 1e6;
        params.spreadFeeE6 = 300_000;
        params.bidAskRefAsymmetryX8 = 512;
        params.nonNegativeBinStates = _binsOf(40);
        params.negativeBinStates = _binsOf(40);
        address deployed = deployer.deploy(params);
        deployedPools[deployed] = true;
        return MetricOmmPool(deployed);
    }

    function _binsOf(uint256 count) internal pure returns (BinState[] memory bins) {
        bins = new BinState[](count);
        // count bins
        for (uint256 index = 0; index < count; ++index) {
            bins[index].lengthE6 = BIN_LENGTH_E6;
        }
    }

    function _outsideDeltas() internal pure returns (LiquidityDelta memory deltas) {
        deltas.binIdxs = new int256[](40);
        deltas.shares = new uint256[](40);
        // 40 bins
        for (uint256 index = 0; index < 40; ++index) {
            deltas.binIdxs[index] = int256(index) - 20;
            deltas.shares[index] = 10e18;
        }
    }
}
