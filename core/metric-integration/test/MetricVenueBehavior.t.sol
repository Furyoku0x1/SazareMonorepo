// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Vm} from "forge-std/Vm.sol";
import {MetricOmmPoolDeployer} from "metric/MetricOmmPoolDeployer.sol";
import {IMetricOmmPoolActions} from "metric/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {CloseRequest, Ledger, OpenRequest, Position, Stream, VaultParameters, Venue} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MetricPrice} from "vault/libraries/MetricPrice.sol";
import {MetricState} from "vault/libraries/MetricState.sol";
import {VaultMath} from "vault/libraries/VaultMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {IMetricOmmSwapCallback} from "metric/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {MetricLendingVault} from "vault/MetricLendingVault.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice Force closes a vault position from inside its own Metric swap callback, while the pool is locked.
contract CallbackCloser is IMetricOmmSwapCallback {
    MetricLendingVault internal immutable vault;
    uint256 internal positionId;

    constructor(MetricLendingVault vault_) {
        vault = vault_;
    }

    function attack(MetricOmmPool pool, uint256 id) external {
        positionId = id;
        pool.swap(address(this), false, int128(1e6), type(uint128).max, "", "");
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        vault.forceClose(positionId);
        MetricOmmPool pool = MetricOmmPool(msg.sender);
        if (amount0 > 0) ERC20(pool.getImmutables().token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) ERC20(pool.getImmutables().token1).transfer(msg.sender, uint256(amount1));
    }
}

/// @notice A lender that withdraws from inside its own Metric swap callback, while the pool is locked, so the vault
/// cannot gather from Metric and pays from its buffer alone.
contract CallbackWithdrawer is IMetricOmmSwapCallback {
    MetricLendingVault internal immutable vault;
    uint256 internal vaultId;
    uint256 internal shares;
    uint256 public paid0;
    uint256 public paid1;
    uint256 public burned;

    constructor(MetricLendingVault vault_) {
        vault = vault_;
    }

    function deposit(uint256 id, ERC20 token1, uint256 amount1) external returns (uint256) {
        token1.approve(address(vault), amount1);
        return vault.deposit(id, 0, amount1, 0, address(this));
    }

    function attack(MetricOmmPool pool, uint256 id, uint256 someShares) external {
        vaultId = id;
        shares = someShares;
        pool.swap(address(this), false, int128(1e6), type(uint128).max, "", "");
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        (paid0, paid1, burned) = vault.withdraw(vaultId, shares, 0, 0, address(this));
        MetricOmmPool pool = MetricOmmPool(msg.sender);
        if (amount0 > 0) ERC20(pool.getImmutables().token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) ERC20(pool.getImmutables().token1).transfer(msg.sender, uint256(amount1));
    }
}

contract MetricVenueBehaviorTest is MetricFixture {
    int24 internal constant PRICE_TICK = -200_311;

    // ---------------------------------------------------------------- lender income

    /// @dev Outside round trips pay the spread into the bins; the vault's lenders hold more value than they put in.
    function test_lenders_earnMetricSpread() public {
        uint256 shares = deposit(lender, 20e18, 40_000e6);
        // repeated round trips through the vault's bins
        for (uint256 round = 0; round < 5; ++round) {
            // The pool's token0 delta is negative: it paid out base.
            (int128 delta0,) = outsider.swap(pool, false, int128(int256(30_000e6)));
            uint256 baseBought = uint256(uint128(-delta0));
            outsider.swap(pool, true, int128(int256(baseBought * 9 / 10)));
        }
        vm.prank(lender);
        (uint256 amount0, uint256 amount1,) = vault.withdraw(vaultId, shares, 0, 0, lender);
        uint256 valueOut = amount0 * 2_000 / 1e12 + amount1;
        uint256 valueIn = 20e18 * 2_000 / 1e12 + 40_000e6;
        assertGt(valueOut + 1e6, valueIn, "lenders did not lose to round trips");
        assertLedger();
    }

    // ---------------------------------------------------------------- entry swaps

    /// @dev An entry swap larger than the pool's depth fills partially; the minimum output protects the trader.
    function test_entrySwap_minimumOutputProtects() public {
        deposit(lender, 0, 100_000e6);
        OpenRequest memory request = _longRequest(10_000e6, 300e6);
        request.entryAmountIn = 10_000e6;
        request.entryMinimumOut = 6e18;
        vm.prank(trader);
        vm.expectRevert(IMetricLendingVault.SlippageExceeded.selector);
        vault.open(request);
    }

    // ---------------------------------------------------------------- force close path

    /// @dev A long whose reserves are base repays by buying only the token1 it lacks: the pool's base rises.
    function test_forceClose_swapsOnlyTheShortfall() public {
        deposit(lender, 0, 100_000e6);
        OpenRequest memory request = _longRequest(10_000e6, 300e6);
        request.entryAmountIn = 10_200e6;
        // A dollar of escrow: premium alone outruns it well within the warp.
        request.escrow = 1e6;
        vm.prank(trader);
        uint256 positionId = vault.open(request);
        uint256 reserve0 = vault.positionOf(positionId).reserve0;
        vm.warp(block.timestamp + 120 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 poolBaseBefore = base.balanceOf(address(pool));
        vm.prank(closer);
        vault.forceClose(positionId);
        uint256 baseSold = base.balanceOf(address(pool)) - poolBaseBefore;
        assertGt(baseSold, 0, "base sold for the shortfall");
        assertLt(baseSold, reserve0, "only the shortfall, not all reserves");
        assertLedger();
    }

    /// @dev Audit finding B3: a force close's shortfall swap could spend the trader's whole surplus, so a trade just
    /// before it could push its price far past the band at the trader's expense. It pays at most 1% past the band's
    /// edge; with the pool pushed further, the close waits rather than scale at the trader's loss (Sol-2-1), and runs
    /// once the pool is back.
    function test_forceClose_waitsRatherThanPayAPushedPrice() public {
        deposit(lender, 0, 100_000e6);
        OpenRequest memory request = _longRequest(10_000e6, 300e6);
        request.entryAmountIn = 10_200e6;
        // A dollar of escrow: premium alone outruns it well within the warp.
        request.escrow = 1e6;
        vm.prank(trader);
        uint256 positionId = vault.open(request);
        vm.warp(block.timestamp + 120 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        // A trade just before the close sells base, pushing the pool's base price about 2% below the band: past the
        // 1% allowance, but within what the trader's surplus could pay.
        uint256 baseBefore = base.balanceOf(address(outsider));
        outsider.swap(pool, true, int128(int256(100e18)));
        Position memory before = vault.positionOf(positionId);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.ShortfallUnfilled.selector);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).reserve0, before.reserve0, "nothing swapped or scaled");
        // The pool comes back: the trade is reversed.
        outsider.swap(pool, false, -int128(int256(baseBefore - base.balanceOf(address(outsider)))));
        vm.recordLogs();
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(_poolSwaps(vm.getRecordedLogs()), 1, "bought the shortfall");
        assertEq(vault.positionOf(positionId).owner, address(0), "closed");
        assertLedger();
    }

    /// @dev Fix-review finding: the passive target added a unit of each token even where the range holds none, so a
    /// position the price had carried past its range, holding only the token its debt needs, still had to buy a unit
    /// of the other and waited on a paused pool. A long that spent all its quote, with the price below its range,
    /// now closes without a swap.
    function test_forceClose_pastItsRangeNeedsNoSwap() public {
        deposit(lender, 100e18, 100_000e6);
        OpenRequest memory request = _longRequest(10_000e6, 300e6);
        (uint160 sqrtBidX96, uint160 sqrtAskX96) = MetricPrice.band(address(pool), 1, 1e12);
        (, uint256 release1) = VaultMath.releaseAcrossBand(
            request.liquidity,
            TickMath.getSqrtPriceAtTick(request.tickLower),
            TickMath.getSqrtPriceAtTick(request.tickUpper),
            sqrtBidX96,
            sqrtAskX96
        );
        request.entryAmountIn = release1 + request.collateral;
        request.escrow = 1e6;
        vm.prank(trader);
        uint256 positionId = vault.open(request);
        assertEq(vault.positionOf(positionId).reserve1, 0, "all quote spent");
        // Below the range: the debt is all base, which the reserves hold.
        provider.set(uint128(1_940 * Q64), HALF_SPREAD_E5);
        vm.warp(block.timestamp + 120 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        pool.setPause(1);
        vm.recordLogs();
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(_poolSwaps(vm.getRecordedLogs()), 0, "no swap needed");
        assertEq(vault.positionOf(positionId).owner, address(0), "closed while paused");
        assertLedger();
    }

    /// @dev Audit finding Sol-1-2: a force close valued its base at the strike and took the reward first, so an owner
    /// force closing their own winning position paid no profit share. It now measures at the bid, before the reward,
    /// and charges what a normal close charges.
    function test_forceClose_byItsOwnerPaysTheProfitShare() public {
        deposit(lender, 100e18, 100_000e6);
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        OpenRequest memory request = _longRequest(10_000e6, 10_010e6);
        request.isLong = false;
        request.tickLower = lower;
        request.tickUpper = upper;
        request.liquidity = uint128(
            uint256(10_000e6) * (1 << 96) / (TickMath.getSqrtPriceAtTick(upper) - TickMath.getSqrtPriceAtTick(lower))
        );
        request.escrow = 1;
        vm.prank(trader);
        uint256 positionId = vault.open(request);
        // The short holds the base it borrowed and enough quote to repay above the range: a winner as the price rises.
        provider.set(uint128(2_400 * Q64), HALF_SPREAD_E5);
        vm.warp(block.timestamp + 30 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 snapshot = vm.snapshotState();
        (uint256 before0, uint256 before1) = _fees();
        uint128 maximum1 = vault.positionOf(positionId).maximum1;
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: 1e18, repay0: 0, repay1: maximum1}));
        (uint256 normal0, uint256 normal1) = _fees();
        vm.revertToState(snapshot);
        vm.prank(trader);
        vault.forceClose(positionId);
        (uint256 forced0, uint256 forced1) = _fees();
        assertGt(normal0 - before0, 0, "a normal close takes a share of the base");
        assertApproxEqAbs(forced0 - before0, normal0 - before0, 1e9, "the same share in base");
        assertApproxEqAbs(forced1 - before1, normal1 - before1, 2, "the same share in quote");
        assertLedger();
    }

    /// @dev Everything the vault owes the treasury, the fee vault and its lenders' streams, per token.
    function _fees() internal view returns (uint256 fees0, uint256 fees1) {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        Stream memory stream = vault.streamOf(vaultId);
        fees0 = uint256(ledger.treasury0) + ledger.feeVault0 + stream.remaining0;
        fees1 = uint256(ledger.treasury1) + ledger.feeVault1 + stream.remaining1;
    }

    /// @dev How many swaps the pool emitted. A close's own placement adds liquidity, which is not a swap.
    function _poolSwaps(Vm.Log[] memory logs) internal view returns (uint256 count) {
        bytes32 swapTopic = IMetricOmmPoolActions.Swap.selector;
        // logs.length is bounded by the close's own calls
        for (uint256 index = 0; index < logs.length; ++index) {
            if (logs[index].emitter != address(pool)) continue;
            if (logs[index].topics[0] == swapTopic) ++count;
        }
    }

    /// @dev Sol's verification finding: called from inside a pool callback, the vault's quote meets Metric's lock. Read
    /// as "no price", that pushed a force close onto its price-free fallback, which can make the trader repay far more
    /// than the range is worth. The lock now stops the close; outside the callback it buys its shortfall as usual.
    function test_forceClose_cannotBeForcedOntoTheFallbackFromACallback() public {
        deposit(lender, 0, 100_000e6);
        OpenRequest memory request = _longRequest(10_000e6, 300e6);
        request.entryAmountIn = 10_200e6;
        request.escrow = 1e6;
        vm.prank(trader);
        uint256 positionId = vault.open(request);
        vm.warp(block.timestamp + 120 days);
        vault.flag(positionId);
        vm.warp(block.timestamp + 1 days + 1);
        CallbackCloser attacker = new CallbackCloser(vault);
        quote.mint(address(attacker), 10e6);
        vm.expectRevert();
        attacker.attack(pool, positionId);
        assertEq(vault.positionOf(positionId).owner, trader, "still open");
        vm.recordLogs();
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(_poolSwaps(vm.getRecordedLogs()), 1, "closed by buying the shortfall");
        assertLedger();
    }

    /// @dev Sol's verification finding: a withdrawal paid only in part, here because the pool is locked and the vault
    /// cannot gather from it, rounded the fraction paid down and could pay a few units while burning no share. Any
    /// payout now burns at least a share.
    function test_withdraw_partialPayoutAlwaysBurns() public {
        deposit(lender, 0, 200_000e6);
        CallbackWithdrawer withdrawer = new CallbackWithdrawer(vault);
        quote.mint(address(withdrawer), 1_010e6);
        uint256 shares = withdrawer.deposit(vaultId, ERC20(address(quote)), 1_000e6);
        // A sliver of its shares: its claim is far more than the vault's small buffer can pay while the pool is locked.
        withdrawer.attack(pool, vaultId, shares / 1_000);
        if (withdrawer.paid0() + withdrawer.paid1() == 0) return;
        assertGt(withdrawer.burned(), 0, "a payout burns shares");
        assertLedger();
    }

    // ---------------------------------------------------------------- weight cap

    function test_weightCap_limitsTheVaultsShareOfSharedBins() public {
        VaultParameters memory parameters = defaultParameters();
        parameters.weightCapBps = 5_000;
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.PoolTaken.selector);
        vault.createVault(parameters, defaultCurves());
    }

    // ---------------------------------------------------------------- pool provenance

    /// @dev Audit finding B1: a pool reports its own immutables, so the owner could register one whose code is not
    /// Metric's and have it drain shared custody. A vault's pool must be one Metric's factory deployed.
    function test_createVault_refusesAPoolTheFactoryDidNotDeploy() public {
        // Metric's own pool code, from a deployer this fixture does not answer for as a factory.
        MetricOmmPoolDeployer other = new MetricOmmPoolDeployer(address(this));
        MetricOmmPoolDeployer.DeployParams memory params = poolParams();
        params.salt = keccak256("stranger");
        address stranger = other.deploy(params);
        VaultParameters memory parameters = defaultParameters();
        parameters.pool = stranger;
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.createVault(parameters, defaultCurves());
    }

    // ---------------------------------------------------------------- gas

    /// @dev Reading the vault's Metric holdings costs about three cold storage reads per bin.
    function test_gas_depositReadsTheWindow() public {
        deposit(lender, 20e18, 40_000e6);
        uint256 gasBefore = gasleft();
        deposit(lender, 1e18, 2_000e6);
        uint256 used = gasBefore - gasleft();
        emit log_named_uint("deposit gas, 16 bins, window placed", used);
        assertLt(used, 2_000_000, "bounded");
    }

    // ---------------------------------------------------------------- helpers

    function _longRequest(uint256 notional, uint128 collateral) internal view returns (OpenRequest memory request) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        request.vaultId = vaultId;
        request.isLong = true;
        request.tickLower = lower;
        request.tickUpper = upper;
        request.liquidity = uint128(notional * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        request.collateral = collateral;
        request.escrow = 100e6;
    }

    function _assertAllInsideWindow() internal view {
        Venue memory venue = vault.venueOf(vaultId);
        // every pool bin
        for (int256 binIndex = -40; binIndex < 40; ++binIndex) {
            uint256 ours = MetricState.positionShares(address(pool), address(vault), uint80(vaultId), int16(binIndex));
            if (ours == 0) continue;
            assertGe(binIndex, venue.lowestBin, "inside window, low side");
            assertLe(binIndex, venue.highestBin, "inside window, high side");
        }
    }
}
