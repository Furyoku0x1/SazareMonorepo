// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MetricOmmPoolDeployer} from "metric/MetricOmmPoolDeployer.sol";
import {OpenRequest, VaultParameters} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice An open's minimum-escrow check (audit finding A6) prices premium at the rates after its own release. The
/// release gathers liquidity out of Metric, and the rates read the vault's anchored holdings, so those must be re-read
/// after the gather (finding X-3's verification): read before it, the check saw the old, lower utilization and took
/// about a thirty-fourth of the escrow the position then burned through.
contract EscrowCheckTest is MetricFixture {
    int24 internal constant PRICE_TICK = -200_311;
    uint32 internal constant MINIMUM_ESCROW_SECONDS = 30 days;

    uint256 internal escrowedVault;

    function setUp() public override {
        super.setUp();
        MetricOmmPoolDeployer.DeployParams memory parameters = poolParams();
        parameters.salt = keccak256("escrow-check");
        MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(this));
        address deployed = deployer.deploy(parameters);
        deployedPools[deployed] = true;
        VaultParameters memory vaultParameters = defaultParameters();
        vaultParameters.pool = deployed;
        vaultParameters.minimumEscrowSeconds = MINIMUM_ESCROW_SECONDS;
        vm.prank(owner);
        escrowedVault = vault.createVault(vaultParameters, defaultCurves());
        vm.prank(lender);
        vault.deposit(escrowedVault, 0, 100_000e6, 0, lender);
    }

    /// @dev The least escrow an 85,000 USD open is allowed lasts the minimum period at the rates after the open: the
    /// position is not delinquent a day before it ends.
    function test_leastAcceptedEscrow_lastsTheMinimumPeriod() public {
        uint128 least = _leastAcceptedEscrow();
        uint256 positionId = this.openLong(least);
        vm.warp(block.timestamp + MINIMUM_ESCROW_SECONDS - 1 days);
        vm.expectRevert(IMetricLendingVault.NotDelinquent.selector);
        vault.flag(positionId);
    }

    /// @dev The least escrow the open accepts, by bisection.
    function _leastAcceptedEscrow() internal returns (uint128 low) {
        low = 1;
        uint128 high = 100_000e6;
        // log2(100_000e6) < 37 halvings
        while (low < high) {
            uint128 middle = (low + high) / 2;
            if (_accepted(middle)) high = middle;
            else low = middle + 1;
        }
    }

    function _accepted(uint128 escrow) internal returns (bool accepted) {
        uint256 snapshot = vm.snapshotState();
        try this.openLong(escrow) returns (uint256) {
            accepted = true;
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), IMetricLendingVault.EscrowTooSmall.selector, "only the escrow check refuses");
        }
        vm.revertToState(snapshot);
    }

    function openLong(uint128 escrow) external returns (uint256) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        OpenRequest memory request;
        request.vaultId = escrowedVault;
        request.isLong = true;
        request.tickLower = lower;
        request.tickUpper = upper;
        request.liquidity = uint128(uint256(85_000e6) * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        request.collateral = 300e6;
        request.escrow = escrow;
        vm.prank(trader);
        return vault.open(request);
    }
}
