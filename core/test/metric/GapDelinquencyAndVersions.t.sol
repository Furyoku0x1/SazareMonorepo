// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Accrual, CurvePair, Ledger, OpenRequest, Position} from "../../src/metric/vault/VaultTypes.sol";
import {BookCurve, Bucket, FloorRow, Leg, MakerOpenRequest} from "../../src/metric/vault/MakerTypes.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {Curve, VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {MakerFixture} from "./utils/MakerFixture.sol";

/// @notice The fresh audit's gaps G13 and G14 (`hooks/docs/metric-lending-vault-spec.md`): a relapse after a cured
/// delinquency, and curve versions over an untouched position or bucket.
contract GapDelinquencyAndVersionsTest is MakerFixture {
    uint256 internal constant WAD = 1e18;
    /// @dev RAY / WAD: a RAY index times a raw `M1` is premium in WAD of a unit after dividing by this.
    uint256 internal constant RAY_PER_WAD = 1e9;
    /// @dev About 10% below the price: ticks [-201,400, -201,300); its floor row is 115% a year.
    int24 internal constant LEVEL_10X = -2_014;
    /// @dev The vault's grace period in the fixture's parameters, and the book's in its settings.
    uint256 internal constant VAULT_GRACE_SECONDS = 1 days;
    uint256 internal constant BOOK_GRACE_SECONDS = 1 hours;

    // ---------------------------------------------------------------- G13: a relapse after a cure

    /// @dev G13 on the passive vault. A cured position's flag is cleared, so once it lapses again (after the first
    /// flag's grace has long passed) the old flag cannot authorize a force close: someone must flag it anew, and the
    /// grace period runs from that new flag. Otherwise a trader who once cured could be force closed the moment any
    /// later shortfall appears, with no grace at all.
    function test_relapse_oldFlagCannotForceCloseAndGraceRestarts() public {
        deposit(lender, 0, 20_000e6);
        uint256 positionId = openLong(15_000e6, 300e6);
        // Premium near 1.5 a day outruns the 100 escrow within about two months.
        vm.warp(block.timestamp + 80 days);
        vault.flag(positionId);
        uint256 firstFlagAt = block.timestamp;
        assertEq(vault.positionOf(positionId).delinquentSince, firstFlagAt, "first flag");
        _cureExactly(positionId, firstFlagAt);
        // Past the first flag's grace; the unit of escrow the cure may leave is outrun within the day.
        vm.warp(firstFlagAt + VAULT_GRACE_SECONDS + 1);
        assertFalse(vault.settle(positionId), "lapsed again");
        vm.expectRevert(IMetricLendingVault.NotDelinquent.selector);
        vault.forceClose(positionId);
        vault.flag(positionId);
        uint256 secondFlagAt = block.timestamp;
        assertEq(vault.positionOf(positionId).delinquentSince, secondFlagAt, "the grace runs from the new flag");
        vm.warp(secondFlagAt + VAULT_GRACE_SECONDS - 1);
        vm.expectRevert(IMetricLendingVault.GracePeriodRunning.selector);
        vault.forceClose(positionId);
        vm.warp(secondFlagAt + VAULT_GRACE_SECONDS);
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).owner, address(0), "closed once the new grace ends");
        assertEq(vault.accrualOf(vaultId).outstanding1, 0, "the loan is back");
        assertLedger();
    }

    /// @dev G13 on the maker book: the same relapse, under the book's own grace period. A top-up short of the
    /// shortfall keeps the first flag's clock; a cure clears it; the relapse needs a new flag and a new grace, so a
    /// cured maker position is never force closed on a stale flag.
    function test_makerRelapse_oldFlagCannotForceCloseAndGraceRestarts() public {
        (uint256 positionId, uint256 bucketId) = _openThinlyEscrowedMakerLong();
        // After the two prepaid days the 28 or so of escrow left covers under two days of the 115% floor.
        vm.warp(block.timestamp + 10 days);
        vault.flagMaker(positionId);
        uint256 firstFlagAt = block.timestamp;
        vm.prank(trader);
        vault.addMakerEscrow(positionId, 1);
        assertEq(vault.makerPositionOf(positionId).delinquentSince, firstFlagAt, "a short top-up keeps the clock");
        // About 99 is owed beyond the escrow; 300 cures it with about 13 days of floor to spare.
        vm.prank(trader);
        vault.addMakerEscrow(positionId, 300e6);
        assertEq(vault.makerPositionOf(positionId).delinquentSince, 0, "cured");
        assertTrue(vault.settleMaker(positionId), "settles once cured");
        vm.expectRevert(IMetricLendingVault.NotDelinquent.selector);
        vault.flagMaker(positionId);
        vm.warp(firstFlagAt + 20 days);
        assertFalse(vault.settleMaker(positionId), "lapsed again");
        vm.expectRevert(IMetricLendingVault.NotDelinquent.selector);
        vault.forceCloseMaker(positionId);
        vault.flagMaker(positionId);
        uint256 secondFlagAt = block.timestamp;
        assertEq(vault.makerPositionOf(positionId).delinquentSince, secondFlagAt, "the grace runs from the new flag");
        vm.warp(secondFlagAt + BOOK_GRACE_SECONDS - 1);
        vm.expectRevert(IMetricLendingVault.GracePeriodRunning.selector);
        vault.forceCloseMaker(positionId);
        vm.warp(secondFlagAt + BOOK_GRACE_SECONDS);
        vm.prank(closer);
        vault.forceCloseMaker(positionId);
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed once the new grace ends");
        assertEq(vault.bucketOf(vaultId, bucketId).lent, 0, "the leg is back in its bucket");
        assertLedger();
    }

    // ---------------------------------------------------------------- G14: curve versions over untouched state

    /// @dev G14 on the passive vault. Across four curve versions, one of them in force for no time, an untouched
    /// position's indices grow by exactly each version's growth over its own interval at the constant utilization,
    /// computed here with `VaultMath.indexGrowthRay`, and its premium is exactly the blend of that growth on `M1`. A
    /// version must never reprice another's interval: the owner's curve power reaches only the future.
    function test_curveVersions_passiveIndexIsTheSumOfEachIntervalsGrowth() public {
        uint256 positionId = _openStraddle();
        Position memory opened = vault.positionOf(positionId);
        // A straddle borrows both tokens, so both curves price its premium.
        assertGt(opened.weight0Wad, 0, "token0 weighs");
        assertLt(opened.weight0Wad, WAD, "token1 weighs");
        Accrual memory start = vault.accrualOf(vaultId);
        Ledger memory idle = vault.ledgerOf(vaultId);
        assertEq(opened.rateIndex0Ray, start.rateIndex0Ray, "token0 snapshot at open");
        assertEq(opened.rateIndex1Ray, start.rateIndex1Ray, "token1 snapshot at open");
        _appendPassiveVersions();
        vm.warp(block.timestamp + 11 days);
        assertEq(vault.positionOf(positionId).rateIndex1Ray, opened.rateIndex1Ray, "untouched across the versions");
        assertTrue(vault.settle(positionId), "escrow covers it");
        (uint256 growth0Ray, uint256 growth1Ray) = _expectedPassiveGrowthRay(start, idle);
        Accrual memory end = vault.accrualOf(vaultId);
        assertEq(end.rateIndex0Ray - start.rateIndex0Ray, growth0Ray, "token0 index: each version on its interval");
        assertEq(end.rateIndex1Ray - start.rateIndex1Ray, growth1Ray, "token1 index: each version on its interval");
        assertEq(vault.ledgerOf(vaultId).buffer1, idle.buffer1, "utilization was constant");
        uint256 premiumWad = _blendedPremiumWad(opened.maximum1, opened.weight0Wad, growth0Ray, growth1Ray);
        assertEq(opened.escrow - vault.positionOf(positionId).escrow, premiumWad / WAD, "premium charged");
        assertEq(vault.positionOf(positionId).premiumFractionWad, premiumWad % WAD, "fraction carried");
        uint256 wholeSpanSeconds = block.timestamp - start.updatedAt;
        uint256 supplied1 = uint256(start.outstanding1) + idle.buffer1;
        Curve memory latest = vault.curvesOf(vaultId)[3].token1;
        assertNotEq(
            growth1Ray,
            VaultMath.indexGrowthRay(latest, start.outstanding1, supplied1, wholeSpanSeconds),
            "discriminates"
        );
        assertLedger();
    }

    /// @dev G14 on the maker book. A book's curve append does not checkpoint its buckets, so a bucket untouched across
    /// four versions (one in force for no time) integrates them all at its next checkpoint. Its index must equal each
    /// version's growth over its own interval at the bucket's constant utilization, and the leg's premium (floor zero)
    /// exactly that growth on its `M1`. A version that repriced another's interval would let a curve change reach
    /// back into premium the book had already earned at the old rate.
    function test_bookCurveVersions_untouchedBucketIndexIsTheSumOfEachIntervalsGrowth() public {
        _appendZeroFloorTable();
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        uint256 positionId =
            openMaker(makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 10_000e6)), 10e6));
        Bucket memory opened = vault.bucketOf(vaultId, bucketId);
        Leg memory leg = vault.legOf(positionId, 0);
        uint256 escrowBefore = vault.makerPositionOf(positionId).escrow;
        _appendBookVersions();
        vm.warp(block.timestamp + 4 days);
        assertEq(vault.bucketOf(vaultId, bucketId).updatedAt, opened.updatedAt, "untouched across the versions");
        assertTrue(vault.settleMaker(positionId), "escrow covers it");
        Bucket memory settled = vault.bucketOf(vaultId, bucketId);
        uint256 supplied = uint256(opened.lent) + liquidityOn(LEVEL_10X, opened.balance1);
        (Curve[] memory curves, uint256[] memory startedAt) = _bookVersions();
        uint256 growthRay =
            _growthAcrossRay(curves, startedAt, opened.updatedAt, block.timestamp, opened.lent, supplied);
        assertEq(settled.rateIndexRay - opened.rateIndexRay, growthRay, "bucket index: each version on its interval");
        assertEq(settled.curveVersion, curves.length - 1, "now on the latest version");
        assertEq(leg.rateIndexRay, opened.rateIndexRay, "leg snapshot at open");
        uint256 premiumWad = FullMath.mulDiv(leg.maximum1, growthRay, RAY_PER_WAD);
        assertEq(escrowBefore - vault.makerPositionOf(positionId).escrow, premiumWad / WAD, "premium charged");
        uint256 wholeSpanSeconds = block.timestamp - opened.updatedAt;
        uint256 latestGrowthRay = VaultMath.indexGrowthRay(curves[3], opened.lent, supplied, wholeSpanSeconds);
        assertNotEq(growthRay, latestGrowthRay, "discriminates");
        assertLedger();
    }

    // ---------------------------------------------------------------- helpers: delinquency

    /// @dev Tops up one unit short of the exact shortfall, which must leave the first flag's clock alone, then the
    /// last unit, which must cure and clear the flag.
    function _cureExactly(uint256 positionId, uint256 firstFlagAt) internal {
        uint256 shortfall = _passiveShortfall(positionId);
        assertGt(shortfall, 1, "delinquent by more than a unit");
        vm.prank(trader);
        vault.addEscrow(positionId, shortfall - 1);
        assertEq(vault.positionOf(positionId).delinquentSince, firstFlagAt, "a short top-up keeps the clock");
        vm.prank(trader);
        vault.addEscrow(positionId, 1);
        assertEq(vault.positionOf(positionId).delinquentSince, 0, "cured");
        assertTrue(vault.settle(positionId), "settles once cured");
        vm.expectRevert(IMetricLendingVault.NotDelinquent.selector);
        vault.flag(positionId);
    }

    /// @dev The shortfall as `VaultBook.shortfall` defines it, at the vault's indices as last checkpointed: the blended
    /// index growth on `M1` plus the carried fraction, rounded up, beyond the escrow.
    function _passiveShortfall(uint256 positionId) internal view returns (uint256) {
        Position memory position = vault.positionOf(positionId);
        Accrual memory accrual = vault.accrualOf(vaultId);
        uint256 delta0Ray = accrual.rateIndex0Ray - position.rateIndex0Ray;
        uint256 delta1Ray = accrual.rateIndex1Ray - position.rateIndex1Ray;
        uint256 premiumWad = _blendedPremiumWad(position.maximum1, position.weight0Wad, delta0Ray, delta1Ray)
            + position.premiumFractionWad;
        uint256 due = FullMath.mulDivRoundingUp(premiumWad, 1, WAD);
        return due > position.escrow ? due - position.escrow : 0;
    }

    /// @dev A single leg borrowing about 5,000 at 115% a year, escrowed just over the open's minimum.
    function _openThinlyEscrowedMakerLong() internal returns (uint256 positionId, uint256 bucketId) {
        (bucketId,) = depositBuy(makerA, LEVEL_10X, 50_000e6);
        MakerOpenRequest memory request =
            makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_10X, 5_000e6)), 10e6);
        // The open prepays about 31.5 and needs about 16 more; this leaves about 28.5.
        request.escrow = 60e6;
        positionId = openMaker(request);
    }

    // ---------------------------------------------------------------- helpers: versions

    /// @dev A long over a range straddling the price, about 10,000 of `M1`, borrowing about 25% of the token0 and half
    /// of the token1 lenders supply.
    function _openStraddle() internal returns (uint256) {
        deposit(lender, 10e18, 10_000e6);
        int24 lower = PRICE_TICK - 100;
        int24 upper = PRICE_TICK + 100;
        uint128 liquidity = liquidityFor1(lower, upper, 10_000e6);
        uint256 collateral = minimumCollateral(lower, upper, liquidity) + 100e6;
        OpenRequest memory request = openRequest(true, lower, upper, liquidity, uint128(collateral));
        request.escrow = 2_000e6;
        return open(request);
    }

    /// @dev Seven days on the first curves, three on steep ones, none on a 500% pair, then the last pair from there.
    function _appendPassiveVersions() internal {
        CurvePair memory steep;
        steep.token0 = Curve({kinkWad: 0.1e18, baseRateWad: 0.03e18, slope1Wad: 0.05e18, slope2Wad: 2e18});
        steep.token1 = Curve({kinkWad: 0.3e18, baseRateWad: 0, slope1Wad: 0.2e18, slope2Wad: 1.5e18});
        CurvePair memory instant = CurvePair({token0: _instantCurve(), token1: _instantCurve(), startedAt: 0});
        CurvePair memory late;
        late.token0 = Curve({kinkWad: 0.8e18, baseRateWad: 0.01e18, slope1Wad: 0.04e18, slope2Wad: 3e18});
        late.token1 = Curve({kinkWad: 0.5e18, baseRateWad: 0.005e18, slope1Wad: 0.1e18, slope2Wad: 2e18});
        vm.startPrank(owner);
        vm.warp(block.timestamp + 7 days);
        vault.appendCurves(vaultId, steep);
        vm.warp(block.timestamp + 3 days);
        vault.appendCurves(vaultId, instant);
        vault.appendCurves(vaultId, late);
        vm.stopPrank();
    }

    /// @dev Five days on the first curve, two on one whose kink lies below the bucket's 20% utilization, none on a 500%
    /// curve, then the last from there.
    function _appendBookVersions() internal {
        vm.startPrank(owner);
        vm.warp(block.timestamp + 5 days);
        vault.appendBookCurve(
            vaultId, Curve({kinkWad: 0.1e18, baseRateWad: 0.02e18, slope1Wad: 0.1e18, slope2Wad: 3e18})
        );
        vm.warp(block.timestamp + 2 days);
        vault.appendBookCurve(vaultId, _instantCurve());
        vault.appendBookCurve(
            vaultId, Curve({kinkWad: 0.8e18, baseRateWad: 0.01e18, slope1Wad: 0.2e18, slope2Wad: 5e18})
        );
        vm.stopPrank();
    }

    /// @dev 500% a year at any utilization: in force for no time, so it must price nothing.
    function _instantCurve() internal pure returns (Curve memory) {
        return Curve({kinkWad: 0.5e18, baseRateWad: 5e18, slope1Wad: 0, slope2Wad: 1e18});
    }

    /// @dev A one-row table at zero, so a leg opened after it owes the curve only.
    function _appendZeroFloorTable() internal {
        FloorRow[] memory rows = new FloorRow[](1);
        rows[0] = FloorRow({minimumDistanceBps: 0, rateBps: 0});
        vm.prank(owner);
        vault.appendFloorTable(vaultId, rows);
    }

    /// @dev Each token's expected index growth from `start` to now, at the utilization the open left.
    function _expectedPassiveGrowthRay(Accrual memory start, Ledger memory idle)
        internal
        view
        returns (uint256 growth0Ray, uint256 growth1Ray)
    {
        CurvePair[] memory pairs = vault.curvesOf(vaultId);
        uint256 versions = pairs.length;
        Curve[] memory curves0 = new Curve[](versions);
        Curve[] memory curves1 = new Curve[](versions);
        uint256[] memory startedAt = new uint256[](versions);
        // versions <= VaultAccrual.MAX_CURVE_VERSIONS = 64
        for (uint256 version = 0; version < versions; ++version) {
            curves0[version] = pairs[version].token0;
            curves1[version] = pairs[version].token1;
            startedAt[version] = pairs[version].startedAt;
        }
        uint256 supplied0 = uint256(start.outstanding0) + idle.buffer0;
        uint256 supplied1 = uint256(start.outstanding1) + idle.buffer1;
        growth0Ray =
            _growthAcrossRay(curves0, startedAt, start.updatedAt, block.timestamp, start.outstanding0, supplied0);
        growth1Ray =
            _growthAcrossRay(curves1, startedAt, start.updatedAt, block.timestamp, start.outstanding1, supplied1);
    }

    function _bookVersions() internal view returns (Curve[] memory curves, uint256[] memory startedAt) {
        BookCurve[] memory versions = vault.bookCurvesOf(vaultId);
        uint256 count = versions.length;
        curves = new Curve[](count);
        startedAt = new uint256[](count);
        // count <= MakerMath.MAX_VERSIONS = 64
        for (uint256 version = 0; version < count; ++version) {
            curves[version] = versions[version].curve;
            startedAt[version] = versions[version].startedAt;
        }
    }

    /// @dev The spec's integral, stated independently of the contract's loop: each version prices
    /// `[max(its start, from), next version's start or end)`, at a constant utilization, rounded down per interval.
    function _growthAcrossRay(
        Curve[] memory curves,
        uint256[] memory startedAt,
        uint256 from,
        uint256 end,
        uint256 borrowed,
        uint256 supplied
    ) internal pure returns (uint256 growthRay) {
        uint256 versions = curves.length;
        // versions <= 64: VaultAccrual.MAX_CURVE_VERSIONS and MakerMath.MAX_VERSIONS are both 64
        for (uint256 version = 0; version < versions; ++version) {
            uint256 intervalStart = startedAt[version] > from ? startedAt[version] : from;
            uint256 intervalEnd = version + 1 < versions ? startedAt[version + 1] : end;
            if (intervalEnd <= intervalStart) continue;
            growthRay += VaultMath.indexGrowthRay(curves[version], borrowed, supplied, intervalEnd - intervalStart);
        }
    }

    /// @dev Premium in WAD of a unit for index growth on each token, blended by the token0 weight as the spec states:
    /// each part of the blend rounds up, then `M1` times the blend.
    function _blendedPremiumWad(uint256 maximum1, uint256 weight0Wad, uint256 delta0Ray, uint256 delta1Ray)
        internal
        pure
        returns (uint256)
    {
        uint256 blendedRay = FullMath.mulDivRoundingUp(delta0Ray, weight0Wad, WAD)
            + FullMath.mulDivRoundingUp(delta1Ray, WAD - weight0Wad, WAD);
        return FullMath.mulDiv(maximum1, blendedRay, RAY_PER_WAD);
    }
}
