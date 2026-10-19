// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OpenRequest, VaultParameters, CurvePair} from "../../src/metric/vault/VaultTypes.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {Curve, VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {VaultFixture} from "./utils/VaultFixture.sol";

/// @notice The realized charge through the singleton (owner, 2026-10-19): the escrow's floor at a share of `M1`, the
/// protocol's tenth on top of the charge so lenders receive all of it, and the surcharge on positions opened at
/// 500x or more. Each test runs its own vaults, so the fixture's single-vault ledger check does not apply.
contract RealizedChargeVaultTest is VaultFixture {
    /// @dev Hourly prices, in ticks from the start: down through both test ranges and back, twice.
    int24[6] internal pathOffsetTicks = [int24(-50), -10, -80, -5, -120, 0];

    struct Pair {
        uint256 near;
        uint256 far;
    }

    function test_open_requiresAShareOfTheNotionalInEscrow() public {
        VaultParameters memory parameters = defaultParameters();
        parameters.minimumEscrowBps = 500;
        uint256 id = _vaultWith(parameters);
        vm.prank(lender);
        vault.deposit(id, 0, 100_000e6, 0, lender);
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        uint128 liquidity = liquidityFor1(lower, upper, 10_000e6);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(lower, upper);
        (, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        uint256 needed = (maximum1 * 500 + 9_999) / 10_000;
        OpenRequest memory request = _request(id, lower, upper, liquidity);
        request.escrow = uint128(needed - 1);
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.EscrowTooSmall.selector);
        vault.open(request);
        request.escrow = uint128(needed);
        vm.prank(trader);
        vault.open(request);
    }

    /// @dev The same positions and price path in three vaults: lenders take the same income whether the protocol keeps
    /// a tenth or nothing, since its tenth comes on top; and a position opened at 1,000x or more pays 5% more, one at
    /// about 150x nothing more.
    function test_realizedCharge_tenthOnTopAndSurcharge() public {
        uint256 plain = _vaultWith(_parameters(1_000, 0));
        uint256 surcharged = _vaultWith(_parameters(1_000, 500));
        uint256 untaxed = _vaultWith(_parameters(0, 0));
        Pair memory inPlain = _openPair(plain);
        Pair memory inSurcharged = _openPair(surcharged);
        Pair memory inUntaxed = _openPair(untaxed);
        uint256 treasuryPlain = vault.ledgerOf(plain).treasury1;
        uint256 treasuryUntaxed = vault.ledgerOf(untaxed).treasury1;
        _walk([plain, surcharged, untaxed]);
        Pair memory spentPlain = _settlePair(inPlain);
        Pair memory spentSurcharged = _settlePair(inSurcharged);
        Pair memory spentUntaxed = _settlePair(inUntaxed);
        assertGt(spentPlain.near, 1e6, "the near range paid a realized charge");
        assertGt(spentPlain.far, 1e6, "so did the far one");
        uint256 lendersPlain = spentPlain.near + spentPlain.far - (vault.ledgerOf(plain).treasury1 - treasuryPlain);
        uint256 lendersUntaxed = spentUntaxed.near + spentUntaxed.far;
        assertEq(vault.ledgerOf(untaxed).treasury1, treasuryUntaxed, "no protocol share there");
        assertApproxEqAbs(lendersPlain, lendersUntaxed, 4, "lenders receive the whole charge either way");
        assertApproxEqAbs(spentSurcharged.near, spentPlain.near * 10_500 / 10_000, 2, "5% more at high leverage");
        assertApproxEqAbs(spentSurcharged.far, spentPlain.far, 1, "nothing more at about 150x");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A near long, its strike about 0.07% under the price (over 1,000x), and a far one about 0.65% under it
    /// (about 150x), each 10,000 of token1 with a large escrow.
    function _openPair(uint256 id) internal returns (Pair memory pair) {
        vm.prank(lender);
        vault.deposit(id, 0, 1_000_000e6, 0, lender);
        pair.near = _openFunded(id, PRICE_TICK - 12, PRICE_TICK - 2);
        pair.far = _openFunded(id, PRICE_TICK - 100, PRICE_TICK - 30);
    }

    function _openFunded(uint256 id, int24 lower, int24 upper) internal returns (uint256) {
        OpenRequest memory request = _request(id, lower, upper, liquidityFor1(lower, upper, 10_000e6));
        request.escrow = 2_000e6;
        vm.prank(trader);
        return vault.open(request);
    }

    function _request(uint256 id, int24 lower, int24 upper, uint128 liquidity)
        internal
        view
        returns (OpenRequest memory request)
    {
        uint256 collateral = minimumCollateral(lower, upper, liquidity) + 100e6;
        request = openRequest(true, lower, upper, liquidity, uint128(collateral));
        request.vaultId = id;
    }

    /// @dev Moves the price along `pathOffsetTicks`, an hour a step, recording a point in each vault.
    function _walk(uint256[3] memory ids) internal {
        uint256 begin = vm.getBlockTimestamp();
        // pathOffsetTicks.length steps, each recorded in every vault
        for (uint256 step = 0; step < pathOffsetTicks.length; ++step) {
            vm.warp(begin + (step + 1) * 1 hours);
            setPrice(PRICE_TICK + pathOffsetTicks[step], 1);
            // ids.length == 3
            for (uint256 index = 0; index < ids.length; ++index) {
                assertTrue(vault.recordPrice(ids[index]), "an hourly point");
            }
        }
    }

    function _settlePair(Pair memory ids) internal returns (Pair memory spent) {
        spent.near = _settleSpent(ids.near);
        spent.far = _settleSpent(ids.far);
    }

    function _settleSpent(uint256 positionId) internal returns (uint256) {
        uint256 before = vault.positionOf(positionId).escrow;
        assertTrue(vault.settle(positionId), "settled from escrow");
        return before - vault.positionOf(positionId).escrow;
    }

    /// @dev Default parameters with the protocol's premium share and the surcharge given.
    function _parameters(uint16 protocolBps, uint16 surchargeBps)
        internal
        view
        returns (VaultParameters memory parameters)
    {
        parameters = defaultParameters();
        parameters.premiumProtocolBps = protocolBps;
        parameters.highLeverageSurchargeBps = surchargeBps;
    }

    /// @dev A vault whose curves charge nothing below the kink, so every unit of premium here is realized charge.
    function _vaultWith(VaultParameters memory parameters) internal returns (uint256 id) {
        Curve memory curve = Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0, slope2Wad: 3e18});
        vm.prank(owner);
        id = vault.createVault(parameters, CurvePair(curve, curve, 0));
    }
}
