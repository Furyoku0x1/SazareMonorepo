// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {
    CloseRequest,
    CurvePair,
    OpenRequest,
    Position,
    PricePoint,
    VaultParameters
} from "../../../src/metric/vault/VaultTypes.sol";
import {Curve, VaultMath} from "../../../src/metric/vault/libraries/VaultMath.sol";
import {VaultFixture} from "../utils/VaultFixture.sol";

/// @notice Regression for rent after a public partial close clears a small
/// released counter. Uses the actual singleton and libraries. Only token funding, time and the external
/// price source are controlled by the existing fixture; no vault storage is set.
contract RentSnapshotTest is VaultFixture {
    int24 internal constant LOWER = PRICE_TICK - 100;
    int24 internal constant UPPER = PRICE_TICK + 100;
    uint256 internal constant WAD = 1e18;

    function test_partialClose_clearsSmallRelease_butKeepsWeightedRent() public {
        uint256 id = _createRentVault();
        uint128 liquidity = liquidityFor1(LOWER, UPPER, 10_000e6);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(LOWER);
        uint160 sqrtOpen = uint160(uint256(sqrtLower) + FullMath.mulDivRoundingUp(1, 1 << 96, liquidity));
        source.set(sqrtOpen, sqrtOpen);
        vm.prank(lender);
        vault.deposit(id, 100e18, 1_000_000e6, 0, lender);

        OpenRequest memory request = openRequest(true, LOWER, UPPER, liquidity, 100e6);
        request.vaultId = id;
        request.escrow = 2_000e6;
        uint256 positionId = open(request);
        Position memory original = vault.positionOf(positionId);
        assertEq(original.released1, 1, "one raw quote unit was lent");
        assertGt(original.released0, 1, "base was also lent");

        // Point zero starts just inside the range. Point one starts a long
        // interval below it. Point two ends that interval above the range.
        vm.warp(block.timestamp + 1 hours);
        setPrice(LOWER - 100, 0);
        assertTrue(vault.recordPrice(id));
        (, , PricePoint memory belowPoint) = vault.priceOf(id, 1);
        vm.warp(block.timestamp + 24 hours);
        setPrice(UPPER + 100, 0);
        assertTrue(vault.recordPrice(id));
        (, , PricePoint memory abovePoint) = vault.priceOf(id, 2);

        (uint256 repay0, uint256 repay1) = repaymentFor(positionId, 0.5e18);
        vm.prank(trader);
        vault.close(CloseRequest(positionId, 0.5e18, repay0, repay1));
        Position memory rest = vault.positionOf(positionId);
        assertEq(rest.released1, 0, "ceil-rounded half closes the one-unit counter");
        assertGt(rest.released0, 0, "the above-range rent selector stays on");
        assertGt(rest.liquidity, 0, "the position remains open");
        assertGe(rest.maximum1, vault.parametersOf(id).minBorrowNotional, "minimum borrow passes");
        assertTrue(VaultMath.chordHolds(rest.reserve0, rest.reserve1, rest.maximum0, rest.maximum1));

        // The next interval is flat and fully above the range. It has no price
        // loss, but must pay the token0-weighted rent. Historical rent below
        // the range must not cancel this new rent above it.
        assertGt(uint256(belowPoint.rentRateBps) * 24 hours, uint256(abovePoint.rentRateBps) * 1 hours);
        vm.warp(block.timestamp + 1 hours);
        assertTrue(vault.recordPrice(id));
        uint256 expectedWad = FullMath.mulDiv(
            rest.maximum1, uint256(abovePoint.rentRateBps) * 1 hours * rest.weight0Wad, 10_000 * 365 days
        );
        assertGt(expectedWad / WAD, 0, "this interval owes a positive whole raw quote amount");
        uint256 escrowBefore = rest.escrow;
        assertTrue(vault.settle(positionId));
        uint256 paid = escrowBefore - vault.positionOf(positionId).escrow;
        emit log_named_uint("Expected flat above-range rent (raw quote units)", expectedWad / WAD);
        emit log_named_uint("Actual premium collected (raw quote units)", paid);
        emit log_named_uint("Old below history (bps seconds)", uint256(belowPoint.rentRateBps) * 24 hours);
        emit log_named_uint("New above history (bps seconds)", uint256(abovePoint.rentRateBps) * 1 hours);
        assertEq(paid, expectedWad / WAD, "past below history does not cancel new above rent");
        assertLedgerParts(id);
    }

    function _createRentVault() private returns (uint256) {
        VaultParameters memory parameters = defaultParameters();
        parameters.premiumProtocolBps = 0;
        parameters.profitShareBps = 0;
        parameters.transformationRateBps = 20_000;
        Curve memory curve = Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0, slope2Wad: 3e18});
        vm.prank(owner);
        return vault.createVault(parameters, CurvePair(curve, curve, 0));
    }
}
