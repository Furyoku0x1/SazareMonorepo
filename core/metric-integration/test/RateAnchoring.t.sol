// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MetricOmmPoolDeployer} from "metric/MetricOmmPoolDeployer.sol";
import {BinState} from "metric/types/PoolStorage.sol";
import {OpenRequest, VaultParameters, Venue} from "vault/VaultTypes.sol";
import {MetricFixture, Trader} from "./utils/MetricFixture.sol";

/// @notice Audit finding X-3: each checkpoint used to re-read the vault's token mix from its bins, and that mix set
/// each token's utilization for the whole next interval. Anyone could swap through the vault's bins, call a
/// permissionless checkpoint and swap back: one push of 20 base took the quote rate from 3.99% to 303% a year. Rates
/// now read the vault's holdings as they would be with the pool at the reference.
contract RateAnchoringTest is MetricFixture {
    int24 internal constant PRICE_TICK = -200_311;

    Trader internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = new Trader();
        base.mint(address(attacker), 1e30);
        quote.mint(address(attacker), 1e30);
    }

    /// @dev Lenders' 50 base and 100,000 quote, a short borrowing 40 base and a long borrowing 80,000 quote: both
    /// tokens at the 80% kink, where the curve turns steep. A sandwiched checkpoint leaves the long's next day of
    /// premium at most 10% above where it would be without it; the slack is the one bin at the window's center whose
    /// mix still counts as held. Before the fix this sandwich took the quote rate from 3.99% to 303% a year.
    function test_sandwichedCheckpoint_leavesTheRateWhereItWas() public {
        deposit(lender, 50e18, 100_000e6);
        uint256 shortPositionId = _openShort(40e18, 2_000e6);
        uint256 longPositionId = _openLong(80_000e6, 2_000e6);
        vm.warp(block.timestamp + 1 hours);
        vault.settle(shortPositionId);
        vault.settle(longPositionId);
        uint256 snapshot = vm.snapshotState();
        uint256 untouchedPremium = _longPremiumOverADay(longPositionId);
        vm.revertToState(snapshot);
        // Sell base through the vault's quote bins, checkpoint, and buy it back.
        uint256 quoteBefore = quote.balanceOf(address(attacker));
        attacker.swap(pool, true, int128(int256(20e18)));
        vault.settle(shortPositionId);
        attacker.swap(pool, false, int128(int256(quote.balanceOf(address(attacker)) - quoteBefore)));
        uint256 sandwichedPremium = _longPremiumOverADay(longPositionId);
        assertGt(untouchedPremium, 0, "the long pays premium");
        assertLe(sandwichedPremium, untouchedPremium * 11 / 10, "the sandwich barely moves the rate");
        assertLedger();
    }

    /// @dev Sol's verification of X-3: anchoring on the window's center counted half a clamped window's base as quote.
    /// On a pool with only four bins below the reference the window clamps against its edge; anchored on the recorded
    /// reference instead, the rate holdings match what the vault holds while the pool sits at the reference, and a
    /// short at 60% utilization passes the 90% ceiling.
    function test_clampedWindow_anchorsOnTheReference() public {
        uint256 clampedVault = _vaultOnAPoolWithFourBinsBelow();
        vm.prank(lender);
        vault.deposit(clampedVault, 50e18, 100_000e6, 0, lender);
        Venue memory venue = vault.venueOf(clampedVault);
        assertEq(venue.lowestBin, -4, "the window is cut at the pool's lowest bin");
        assertEq(venue.highestBin, 7, "not shifted up to make room");
        assertApproxEqRel(venue.rateHoldings0, venue.holdings0, 0.01e18, "base counted as base");
        assertApproxEqRel(venue.rateHoldings1, venue.holdings1, 0.01e18, "quote counted as quote");
        uint256 shortPositionId = _openShortIn(clampedVault, 30e18);
        assertGt(shortPositionId, 0, "a 60% short passes the ceiling");
    }

    function _vaultOnAPoolWithFourBinsBelow() internal returns (uint256 clampedVault) {
        MetricOmmPoolDeployer.DeployParams memory parameters = poolParams();
        parameters.salt = keccak256("clamped-window");
        BinState[] memory below = new BinState[](4);
        // four bins
        for (uint256 index = 0; index < 4; ++index) {
            below[index].lengthE6 = BIN_LENGTH_E6;
        }
        parameters.negativeBinStates = below;
        MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(this));
        address deployed = deployer.deploy(parameters);
        deployedPools[deployed] = true;
        VaultParameters memory vaultParameters = defaultParameters();
        vaultParameters.pool = deployed;
        vm.prank(owner);
        clampedVault = vault.createVault(vaultParameters, defaultCurves());
    }

    function _openShortIn(uint256 someVault, uint256 amount0) internal returns (uint256) {
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        OpenRequest memory request = _request(false, lower, upper, 2_000e6);
        request.vaultId = someVault;
        request.liquidity = uint128(
            FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtLowerX96, 1 << 96), sqrtUpperX96, sqrtUpperX96 - sqrtLowerX96)
        );
        vm.prank(trader);
        return vault.open(request);
    }

    function _longPremiumOverADay(uint256 longPositionId) internal returns (uint256) {
        uint256 escrowBefore = vault.positionOf(longPositionId).escrow;
        vm.warp(block.timestamp + 1 days);
        vault.settle(longPositionId);
        return escrowBefore - vault.positionOf(longPositionId).escrow;
    }

    function _openLong(uint256 notional, uint128 escrow) internal returns (uint256) {
        int24 tickLower = PRICE_TICK - 200;
        int24 tickUpper = PRICE_TICK - 100;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        OpenRequest memory request = _request(true, tickLower, tickUpper, escrow);
        request.liquidity = uint128(notional * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        vm.prank(trader);
        return vault.open(request);
    }

    function _openShort(uint256 amount0, uint128 escrow) internal returns (uint256) {
        int24 tickLower = PRICE_TICK + 100;
        int24 tickUpper = PRICE_TICK + 200;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        OpenRequest memory request = _request(false, tickLower, tickUpper, escrow);
        request.liquidity = uint128(
            FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtLowerX96, 1 << 96), sqrtUpperX96, sqrtUpperX96 - sqrtLowerX96)
        );
        vm.prank(trader);
        return vault.open(request);
    }

    function _request(bool isLong, int24 tickLower, int24 tickUpper, uint128 escrow)
        internal
        view
        returns (OpenRequest memory request)
    {
        request.vaultId = vaultId;
        request.isLong = isLong;
        request.tickLower = tickLower;
        request.tickUpper = tickUpper;
        request.collateral = 300e6;
        request.escrow = escrow;
    }
}
