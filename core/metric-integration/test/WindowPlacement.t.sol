// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "metric/MetricOmmPoolDeployer.sol";
import {LiquidityDelta} from "metric/types/PoolOperation.sol";
import {VaultParameters, Venue} from "vault/VaultTypes.sol";
import {MetricState} from "vault/libraries/MetricState.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice The vault's window is the `binCount / 2` bins on each side of the bin holding the oracle reference, the bin
/// next to the reference taking twice what each other bin takes: 40/20/20/20 of a side with four bins (owner,
/// 2026-10-19). Token0 goes only to bins above both the reference and the cursor, token1 only below both (audit finding
/// X-1), except the active bin: inside the window it takes its weight in both tokens, in the bin's ratio (owner,
/// 2026-10-19), so the only wrong-side tokens the vault places are in that one bin.
contract WindowPlacementTest is MetricFixture {
    /// @dev The owner's window for majors: four bins each side.
    uint8 internal constant BINS = 8;
    /// @dev Half a fixture bin (0.2%): an anchor that puts the reference inside bin 0 rather than on its lower edge.
    int24 internal constant HALF_BIN_E6 = -1_000;
    /// @dev Bounds the trades that walk a cursor to a target bin; each moves a small part of one bin.
    uint256 internal constant MAX_PUSH_TRADES = 400;

    MetricOmmPool internal edgePool;
    uint256 internal edgeVault;

    function setUp() public override {
        super.setUp();
        (edgePool, edgeVault) = _vaultOnNewPool("window-edge", 0);
    }

    /// @dev Reference on the edge below bin 0, cursor at it: token1 in bins -1..-4 weighted 2:1:1:1, token0 in bins
    /// 0..3 the same. Bin 0 is the active bin and takes its double share; with the cursor at its lower edge it holds
    /// only token0, so that is all it takes.
    function test_window_fourBinsEachSide_nearestTakesTwice() public {
        _depositInto(edgeVault, 40e18, 80_000e6);
        Venue memory venue = vault.venueOf(edgeVault);
        assertTrue(venue.referenceOnEdge, "reference on an edge");
        assertEq(venue.referenceBin, 0, "the first bin above it");
        assertEq(venue.lowestBin, -4, "four bins below");
        assertEq(venue.highestBin, 3, "four bins above");
        assertApproxEqRel(_quoteIn(edgePool, edgeVault, -1), 2 * _quoteIn(edgePool, edgeVault, -4), 0.01e18, "2:1");
        assertApproxEqRel(_quoteIn(edgePool, edgeVault, -2), _quoteIn(edgePool, edgeVault, -4), 0.01e18, "1:1");
        assertApproxEqRel(_quoteIn(edgePool, edgeVault, -3), _quoteIn(edgePool, edgeVault, -4), 0.01e18, "1:1");
        assertApproxEqRel(_baseIn(edgePool, edgeVault, 0), 2 * _baseIn(edgePool, edgeVault, 3), 0.01e18, "2:1 active");
        assertEq(_quoteIn(edgePool, edgeVault, 0), 0, "a bin of token0 alone takes no token1");
        assertApproxEqRel(_baseIn(edgePool, edgeVault, 1), _baseIn(edgePool, edgeVault, 3), 0.01e18, "1:1");
        assertApproxEqRel(_baseIn(edgePool, edgeVault, 2), _baseIn(edgePool, edgeVault, 3), 0.01e18, "1:1");
        _assertInside(edgePool, edgeVault);
    }

    /// @dev Reference inside bin 0: the window is nine bins, bin 0 straddles the reference and stays empty even as the
    /// active bin, and both sides weigh 2:1:1:1 from it outward.
    function test_window_referenceInsideABin_leavesItsBinEmpty() public {
        (MetricOmmPool insidePool, uint256 insideVault) = _vaultOnNewPool("window-inside", HALF_BIN_E6);
        _depositInto(insideVault, 40e18, 80_000e6);
        Venue memory venue = vault.venueOf(insideVault);
        assertFalse(venue.referenceOnEdge, "reference inside a bin");
        assertEq(venue.referenceBin, 0, "bin 0 holds it");
        assertEq(venue.lowestBin, -4, "four bins below");
        assertEq(venue.highestBin, 4, "four bins above");
        assertEq(_shares(insidePool, insideVault, 0), 0, "the reference bin stays empty");
        assertApproxEqRel(
            _quoteIn(insidePool, insideVault, -1), 2 * _quoteIn(insidePool, insideVault, -4), 0.01e18, "q"
        );
        assertApproxEqRel(_baseIn(insidePool, insideVault, 1), 2 * _baseIn(insidePool, insideVault, 4), 0.01e18, "b");
        _assertInside(insidePool, insideVault);
    }

    /// @dev With the cursor two bins below the reference, a deposit places token1 below the cursor (bins -3 and -4),
    /// token0 above the reference (bins 0..3), and both tokens in the active bin -2. Bin -1, between the cursor and the
    /// reference, gets nothing, so the only base placed below the reference is the active bin's.
    function test_displacedCursor_onlyTheActiveBinTakesBothTokens() public {
        _depositInto(edgeVault, 10e18, 20_000e6);
        _pushTo(edgePool, -2);
        uint256 betweenShares = _shares(edgePool, edgeVault, -1);
        uint256 activeShares = _shares(edgePool, edgeVault, -2);
        uint256 activeBase = _baseIn(edgePool, edgeVault, -2);
        uint256 activeQuote = _quoteIn(edgePool, edgeVault, -2);
        uint256 baseBelowOutsideActive = _baseBelow(edgePool, edgeVault, 0) - _baseIn(edgePool, edgeVault, -2);
        uint256 quoteAbove = _quoteFrom(edgePool, edgeVault, 0);
        uint256 quoteLow = _quoteIn(edgePool, edgeVault, -3) + _quoteIn(edgePool, edgeVault, -4);
        uint256 baseHigh = _baseIn(edgePool, edgeVault, 0) + _baseIn(edgePool, edgeVault, 1);
        _depositInto(edgeVault, 10e18, 20_000e6);
        assertEq(_shares(edgePool, edgeVault, -1), betweenShares, "nothing between the cursor and the reference");
        assertGt(_shares(edgePool, edgeVault, -2), activeShares, "the active bin takes its share");
        assertGt(_baseIn(edgePool, edgeVault, -2), activeBase, "in token0");
        assertGt(_quoteIn(edgePool, edgeVault, -2), activeQuote, "and in token1");
        assertEq(
            _baseBelow(edgePool, edgeVault, 0) - _baseIn(edgePool, edgeVault, -2),
            baseBelowOutsideActive,
            "no base below the reference outside the active bin"
        );
        assertEq(_quoteFrom(edgePool, edgeVault, 0), quoteAbove, "no quote above the reference");
        assertGt(_quoteIn(edgePool, edgeVault, -3) + _quoteIn(edgePool, edgeVault, -4), quoteLow, "quote placed below");
        assertGt(_baseIn(edgePool, edgeVault, 0) + _baseIn(edgePool, edgeVault, 1), baseHigh, "base placed above");
        _assertInside(edgePool, edgeVault);
    }

    /// @dev Quote placed below the reference, then the cursor pushed below it: bins -1 and -2 now hold the base the
    /// push sold into them. Gathering reads a bin by what Metric holds there now, not by the side it was placed on,
    /// so a full withdrawal reaches that base.
    function test_gather_reachesBinsTransformedPastTheReference() public {
        uint256 shares = _depositInto(edgeVault, 0, 80_000e6);
        _pushTo(edgePool, -3);
        assertGt(_baseIn(edgePool, edgeVault, -1), 0, "the push left base in bin -1");
        assertEq(vault.ledgerOf(edgeVault).buffer0, 0, "no base in the buffer");
        vm.prank(lender);
        (uint256 amount0,,) = vault.withdraw(edgeVault, shares, 0, 0, lender);
        assertGt(amount0, 0, "the transformed base is paid out");
        assertEq(_shares(edgePool, edgeVault, -1), 0, "bin -1 emptied");
    }

    /// @dev The first placement no longer waits for the cursor to hold the reference: it finds the reference bin by
    /// summing bin lengths from the cursor's bin, sets the window around it, and places on the agreed sides.
    function test_firstPlacement_findsTheReferenceWithTheCursorAway() public {
        (MetricOmmPool freshPool, uint256 freshVault) = _vaultOnNewPool("window-fresh", 0);
        _pushTo(freshPool, -3);
        _depositInto(freshVault, 10e18, 20_000e6);
        Venue memory venue = vault.venueOf(freshVault);
        assertTrue(venue.windowSet, "the window is set");
        assertEq(venue.referenceBin, 0, "the reference found two bins up and more");
        assertTrue(venue.referenceOnEdge, "on its edge");
        assertEq(venue.lowestBin, -4, "four below");
        assertEq(venue.highestBin, 3, "four above");
        assertEq(_baseBelow(freshPool, freshVault, 0), _baseIn(freshPool, freshVault, -3), "base below only in bin -3");
        assertGt(_quoteIn(freshPool, freshVault, -4), 0, "quote below the cursor");
        _assertInside(freshPool, freshVault);
    }

    // ---------------------------------------------------------------- helpers

    function _vaultOnNewPool(bytes32 salt, int24 anchorE6) internal returns (MetricOmmPool newPool, uint256 id) {
        MetricOmmPoolDeployer.DeployParams memory params = poolParams();
        params.salt = salt;
        params.curBinDistFromProvidedPriceE6 = anchorE6;
        MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(this));
        newPool = MetricOmmPool(deployer.deploy(params));
        deployedPools[address(newPool)] = true;
        outsider.addLiquidity(newPool, _outsideDeltas());
        VaultParameters memory parameters = defaultParameters();
        parameters.pool = address(newPool);
        parameters.binCount = BINS;
        vm.prank(owner);
        id = vault.createVault(parameters, defaultCurves());
    }

    /// @dev Ten shares a bin across the middle 40 bins, as the fixture's pool.
    function _outsideDeltas() internal pure returns (LiquidityDelta memory deltas) {
        deltas.binIdxs = new int256[](40);
        deltas.shares = new uint256[](40);
        // 40 bins
        for (uint256 index = 0; index < 40; ++index) {
            deltas.binIdxs[index] = int256(index) - 20;
            deltas.shares[index] = 10e18;
        }
    }

    function _depositInto(uint256 id, uint256 amount0, uint256 amount1) internal returns (uint256) {
        vm.prank(lender);
        return vault.deposit(id, amount0, amount1, 0, lender);
    }

    /// @dev Trades small amounts until the cursor sits in `targetBin`.
    function _pushTo(MetricOmmPool somePool, int16 targetBin) internal {
        // step < MAX_PUSH_TRADES
        for (uint256 step = 0; step < MAX_PUSH_TRADES; ++step) {
            int16 current = MetricState.cursor(address(somePool)).binIndex;
            if (current == targetBin) return;
            if (current > targetBin) outsider.swap(somePool, true, int128(int256(0.25e18)));
            else outsider.swap(somePool, false, int128(int256(500e6)));
        }
        revert("the cursor did not reach its target");
    }

    function _shares(MetricOmmPool somePool, uint256 id, int16 binIndex) internal view returns (uint256) {
        return MetricState.positionShares(address(somePool), address(vault), uint80(id), binIndex);
    }

    /// @dev The vault's token0 or token1 in a bin, in Metric's scaled units.
    function _part(MetricOmmPool somePool, uint256 id, int16 binIndex, bool isToken0) internal view returns (uint256) {
        uint256 ours = _shares(somePool, id, binIndex);
        if (ours == 0) return 0;
        MetricState.Bin memory state = MetricState.bin(address(somePool), binIndex);
        uint256 balance = isToken0 ? state.balance0Scaled : state.balance1Scaled;
        return ours * balance / state.totalShares;
    }

    function _baseIn(MetricOmmPool somePool, uint256 id, int16 binIndex) internal view returns (uint256) {
        return _part(somePool, id, binIndex, true);
    }

    function _quoteIn(MetricOmmPool somePool, uint256 id, int16 binIndex) internal view returns (uint256) {
        return _part(somePool, id, binIndex, false);
    }

    /// @dev The vault's base in every bin below `belowBin`.
    function _baseBelow(MetricOmmPool somePool, uint256 id, int16 belowBin) internal view returns (uint256 amount0) {
        // the pool's 40 bins below 0 at most
        for (int256 binIndex = -40; binIndex < belowBin; ++binIndex) {
            amount0 += _baseIn(somePool, id, int16(binIndex));
        }
    }

    /// @dev The vault's quote in every bin from `fromBin` up.
    function _quoteFrom(MetricOmmPool somePool, uint256 id, int16 fromBin) internal view returns (uint256 amount1) {
        // the pool's 40 bins from 0 up at most
        for (int256 binIndex = fromBin; binIndex < 40; ++binIndex) {
            amount1 += _quoteIn(somePool, id, int16(binIndex));
        }
    }

    function _assertInside(MetricOmmPool somePool, uint256 id) internal view {
        Venue memory venue = vault.venueOf(id);
        // every pool bin
        for (int256 binIndex = venue.poolLowestBin; binIndex <= venue.poolHighestBin; ++binIndex) {
            if (_shares(somePool, id, int16(binIndex)) == 0) continue;
            assertGe(binIndex, venue.lowestBin, "inside the window, low side");
            assertLe(binIndex, venue.highestBin, "inside the window, high side");
        }
    }
}
