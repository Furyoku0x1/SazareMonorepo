// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "metric/MetricOmmPoolDeployer.sol";
import {IMetricOmmExtensions} from "metric/interfaces/extensions/IMetricOmmExtensions.sol";
import {LiquidityDelta} from "metric/types/PoolOperation.sol";
import {CloseRequest, Ledger, OpenRequest, Stream, VaultParameters} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MetricState} from "vault/libraries/MetricState.sol";
import {DebtTotals} from "vault/libraries/VaultMath.sol";
import {IntegrationToken, MetricFixture, SettableProvider} from "./utils/MetricFixture.sol";

/// @notice A Metric extension that answers every extension point and, while set, refuses swaps sent by one address: a
/// StopLoss-style or allowlist swap extension that the vault happens to fail.
contract SwapGate is IMetricOmmExtensions {
    error Blocked();

    address public blocked;

    function setBlocked(address sender) external {
        blocked = sender;
    }

    function initialize(address, bytes calldata) external pure returns (bytes4) {
        return IMetricOmmExtensions.initialize.selector;
    }

    function beforeAddLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IMetricOmmExtensions.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IMetricOmmExtensions.afterAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IMetricOmmExtensions.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, address, uint80, LiquidityDelta calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IMetricOmmExtensions.afterRemoveLiquidity.selector;
    }

    function beforeSwap(
        address sender,
        address,
        bool,
        int128,
        uint128,
        uint256,
        uint128,
        uint128,
        uint128,
        bytes calldata
    ) external view returns (bytes4) {
        if (sender == blocked) revert Blocked();
        return IMetricOmmExtensions.beforeSwap.selector;
    }

    function afterSwap(
        address,
        address,
        bool,
        int128,
        uint128,
        uint256,
        uint256,
        uint128,
        uint128,
        uint128,
        int128,
        int128,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IMetricOmmExtensions.afterSwap.selector;
    }
}

/// @notice Pool building and position requests shared by the two suites below.
abstract contract GapPoolsBase is MetricFixture {
    /// @dev Raw price 2e-9 (2,000 quote per 18-decimal base) is about tick -200,311.
    int24 internal constant PRICE_TICK = -200_311;
    uint256 internal constant NOTIONAL = 10_000e6;
    uint256 internal constant WAD = 1e18;

    uint256 internal poolNonce;

    /// @dev Deploys a pool from `poolParameters` as its factory, so `isPool` answers for it; every call gets its own
    /// salt.
    function _deployWith(MetricOmmPoolDeployer.DeployParams memory poolParameters) internal returns (MetricOmmPool) {
        MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(this));
        poolParameters.salt = keccak256(abi.encode("gap-pools", ++poolNonce));
        address deployed = deployer.deploy(poolParameters);
        deployedPools[deployed] = true;
        return MetricOmmPool(deployed);
    }

    /// @dev The fixture's outside depth: ten base per bin at and above the cursor, 20,000 quote per bin below.
    function _outsideDeltas() internal pure returns (LiquidityDelta memory deltas) {
        deltas.binIdxs = new int256[](40);
        deltas.shares = new uint256[](40);
        // 40 bins
        for (uint256 index = 0; index < 40; ++index) {
            deltas.binIdxs[index] = int256(index) - 20;
            deltas.shares[index] = 10e18;
        }
    }

    /// @dev A long of `NOTIONAL` quote over a range just below the price, with 300 quote of collateral.
    function _longRequest(uint256 targetVaultId, uint128 escrow, uint256 entryAmountIn)
        internal
        pure
        returns (OpenRequest memory request)
    {
        int24 tickLower = PRICE_TICK - 200;
        int24 tickUpper = PRICE_TICK - 100;
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        request.vaultId = targetVaultId;
        request.isLong = true;
        request.tickLower = tickLower;
        request.tickUpper = tickUpper;
        request.liquidity = uint128(NOTIONAL * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        request.collateral = 300e6;
        request.escrow = escrow;
        request.entryAmountIn = entryAmountIn;
    }

    /// @dev Opens a long that buys base on entry with a dollar of escrow: premium outruns it well within the warps.
    function _openSwappedLong(uint256 targetVaultId) internal returns (uint256) {
        vm.prank(trader);
        return vault.open(_longRequest(targetVaultId, 1e6, 10_200e6));
    }

    /// @dev Flags each position once its premium has outrun its escrow, then lets the grace period pass.
    function _pastGrace(uint256 firstPositionId, uint256 secondPositionId) internal {
        vm.warp(block.timestamp + 120 days);
        vault.flag(firstPositionId);
        if (secondPositionId != 0) vault.flag(secondPositionId);
        vm.warp(block.timestamp + 1 days + 1);
    }
}

/// @notice G2: two real Metric pools sharing the quote token, one vault on each. The singleton holds both vaults'
/// quote in one balance, so every action on one vault must leave the other's ledger, venue and Metric holdings as they
/// were, and the vaults' `held` amounts must sum to the singleton's balance of each token.
contract GapPoolsIsolationTest is GapPoolsBase {
    struct Side {
        uint256 vaultId;
        MetricOmmPool pool;
        IntegrationToken base;
        uint256 positionId;
    }

    IntegrationToken internal secondBase;
    SettableProvider internal secondProvider;
    Side internal first;
    Side internal second;
    /// @dev The vault the actions under test must not touch, and its fingerprint before them.
    Side internal watched;
    bytes32 internal watchedFingerprint;

    function setUp() public override {
        super.setUp();
        secondBase = new IntegrationToken("BASE2", 18);
        secondProvider = new SettableProvider(address(secondBase), address(quote));
        secondProvider.set(uint128(2_000 * Q64), HALF_SPREAD_E5);
        MetricOmmPoolDeployer.DeployParams memory poolParameters = poolParams();
        poolParameters.token0 = address(secondBase);
        poolParameters.priceProvider = address(secondProvider);
        MetricOmmPool secondPool = _deployWith(poolParameters);
        secondBase.mint(address(outsider), 1e30);
        outsider.addLiquidity(secondPool, _outsideDeltas());
        VaultParameters memory parameters = defaultParameters();
        parameters.token0 = address(secondBase);
        parameters.pool = address(secondPool);
        vm.prank(owner);
        uint256 secondVaultId = vault.createVault(parameters, defaultCurves());
        _fundSecondBase(lender);
        _fundSecondBase(trader);
        first = Side(vaultId, pool, base, 0);
        second = Side(secondVaultId, secondPool, secondBase, 0);
        first.positionId = _seed(first.vaultId);
        second.positionId = _seed(second.vaultId);
        _assertCustody();
    }

    /// @dev Every action on the first vault (deposit, outside swap and re-centering, opens with and without an entry
    /// swap, partial and full closes, a force close buying its shortfall, protocol payment and a gathering withdrawal)
    /// leaves the second vault's ledger, venue, accrual, debts, position, Metric shares and pool exactly as they were,
    /// while the shared quote balance stays split between the two ledgers. The singleton holds every vault's quote in
    /// one balance, so an action that touched another vault's books would pay one vault's lenders with another's.
    function test_actionsOnTheFirstVault_leaveTheSecondUnchanged() public {
        _watch(second);
        bytes32 actingBefore = _fingerprint(first);
        _ownerCycle(first);
        _forceCycle(first);
        assertTrue(_fingerprint(first) != actingBefore, "the acting vault itself changed");
    }

    /// @dev The same lifecycle run on the second vault leaves the first, the fixture's own vault, unchanged. Run both
    /// ways, so the isolation does not hinge on which vault id or which base token does the acting.
    function test_actionsOnTheSecondVault_leaveTheFirstUnchanged() public {
        _watch(first);
        bytes32 actingBefore = _fingerprint(second);
        _ownerCycle(second);
        _forceCycle(second);
        assertTrue(_fingerprint(second) != actingBefore, "the acting vault itself changed");
    }

    /// @dev A force close waiting on its own paused pool (Sol-2-1) holds only its own vault: the other vault's force
    /// close runs meanwhile and leaves the waiting vault untouched, which closes once its pool resumes. A pause that
    /// held up every vault would let one pool's admin stall the closes of vaults on other pools.
    function test_forceClose_aPausedPoolHoldsOnlyItsOwnVault() public {
        uint256 firstPositionId = _openSwappedLong(first.vaultId);
        uint256 secondPositionId = _openSwappedLong(second.vaultId);
        _pastGrace(firstPositionId, secondPositionId);
        pool.setPause(1);
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.ShortfallUnfilled.selector);
        vault.forceClose(firstPositionId);
        first.positionId = firstPositionId;
        _watch(first);
        vm.prank(closer);
        vault.forceClose(secondPositionId);
        assertEq(vault.positionOf(secondPositionId).owner, address(0), "the other pool's close runs");
        _check("force close on the other pool");
        pool.setPause(0);
        vm.prank(closer);
        vault.forceClose(firstPositionId);
        assertEq(vault.positionOf(firstPositionId).owner, address(0), "closes once its own pool resumes");
        _assertCustody();
    }

    // ---------------------------------------------------------------- lifecycles

    /// @dev Lender and owner actions: deposit, open, an outside swap that pushes the cursor (the window holds still,
    /// audit finding X-1), partial and full close.
    function _ownerCycle(Side memory acting) internal {
        vm.prank(lender);
        vault.deposit(acting.vaultId, 20e18, 100_000e6, 0, lender);
        _check("deposit");
        vm.prank(trader);
        uint256 positionId = vault.open(_longRequest(acting.vaultId, 100e6, 0));
        _check("open");
        // Buying base walks the acting pool's cursor several bins up, past the re-centering distance.
        (int128 baseOut,) = outsider.swap(acting.pool, false, int128(int256(250_000e6)));
        _check("outside swap");
        assertFalse(vault.recenter(acting.vaultId), "a pushed cursor does not move the acting window");
        _check("recenter");
        // Selling it back returns the cursor near the band, so a later entry swap is not priced above it.
        outsider.swap(acting.pool, true, -baseOut);
        _check("outside swap back");
        uint256 halfRepayment = vault.positionOf(positionId).maximum1 / 2 + 1;
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD / 2, repay0: 0, repay1: halfRepayment}));
        _check("partial close");
        uint256 restRepayment = vault.positionOf(positionId).maximum1;
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: 0, repay1: restRepayment}));
        assertEq(vault.positionOf(positionId).owner, address(0), "closed by its owner");
        _check("close");
    }

    /// @dev Forced and protocol actions: an entry swap, flag, a force close buying its shortfall, protocol payment and
    /// a withdrawal that gathers from Metric.
    function _forceCycle(Side memory acting) internal {
        uint256 positionId = _openSwappedLong(acting.vaultId);
        _check("open with an entry swap");
        _pastGrace(positionId, 0);
        _check("flag");
        uint256 poolBaseBefore = acting.base.balanceOf(address(acting.pool));
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).owner, address(0), "force closed");
        assertGt(acting.base.balanceOf(address(acting.pool)), poolBaseBefore, "sold base for the shortfall");
        _check("force close");
        vault.payProtocol(acting.vaultId);
        _check("pay protocol");
        uint256 shares = vault.sharesOf(acting.vaultId, lender) / 2;
        vm.prank(lender);
        (uint256 amount0, uint256 amount1,) = vault.withdraw(acting.vaultId, shares, 0, 0, lender);
        assertGt(amount0 + amount1, 0, "the withdrawal paid");
        _check("withdraw");
    }

    // ---------------------------------------------------------------- checks

    function _watch(Side memory side) internal {
        watched = side;
        watchedFingerprint = _fingerprint(side);
    }

    function _check(string memory step) internal view {
        assertEq(_fingerprint(watched), watchedFingerprint, step);
        _assertCustody();
    }

    /// @dev Everything of a vault an action elsewhere could disturb: its books, its position, its Metric shares, and
    /// its pool's balances and cursor.
    function _fingerprint(Side memory side) internal view returns (bytes32) {
        (DebtTotals memory longDebts, DebtTotals memory shortDebts) = vault.debtsOf(side.vaultId);
        (uint256 book0, uint256 book1, uint256 income0, uint256 income1) = vault.bookTotalsOf(side.vaultId);
        bytes32 books = keccak256(
            abi.encode(
                vault.ledgerOf(side.vaultId),
                vault.venueOf(side.vaultId),
                vault.accrualOf(side.vaultId),
                vault.streamOf(side.vaultId),
                longDebts,
                shortDebts
            )
        );
        bytes32 holdings = keccak256(
            abi.encode(
                vault.totalSharesOf(side.vaultId),
                vault.positionOf(side.positionId),
                book0 + book1 + income0 + income1,
                _poolShares(side)
            )
        );
        bytes32 venue = keccak256(
            abi.encode(
                side.base.balanceOf(address(side.pool)),
                quote.balanceOf(address(side.pool)),
                side.pool.extsload(bytes32(0))
            )
        );
        return keccak256(abi.encode(books, holdings, venue));
    }

    /// @dev The vault's shares in every bin of its pool, under its own salt.
    function _poolShares(Side memory side) internal view returns (bytes32 digest) {
        // 80 pool bins, -40 to 39
        for (int256 binIndex = -40; binIndex < 40; ++binIndex) {
            uint256 ours =
                MetricState.positionShares(address(side.pool), address(vault), uint80(side.vaultId), int16(binIndex));
            digest = keccak256(abi.encode(digest, ours));
        }
    }

    /// @dev Each vault's parts sum to its `held`, and the vaults' `held` amounts sum to the singleton's balance of each
    /// token: base and the second base are one vault's alone, quote is shared.
    function _assertCustody() internal view {
        Ledger memory firstLedger = _assertParts(first.vaultId);
        Ledger memory secondLedger = _assertParts(second.vaultId);
        assertEq(uint256(firstLedger.held0), base.balanceOf(address(vault)), "base custody");
        assertEq(uint256(secondLedger.held0), secondBase.balanceOf(address(vault)), "second base custody");
        assertEq(
            uint256(firstLedger.held1) + secondLedger.held1, quote.balanceOf(address(vault)), "shared quote custody"
        );
    }

    function _assertParts(uint256 targetVaultId) internal view returns (Ledger memory ledger) {
        ledger = vault.ledgerOf(targetVaultId);
        Stream memory stream = vault.streamOf(targetVaultId);
        (uint256 book0, uint256 book1, uint256 income0, uint256 income1) = vault.bookTotalsOf(targetVaultId);
        assertEq(
            uint256(ledger.held0),
            uint256(ledger.buffer0) + ledger.reserve0 + ledger.treasury0 + ledger.feeVault0 + ledger.unclaimed0
                + stream.remaining0 + book0 + income0,
            "held0 parts"
        );
        assertEq(
            uint256(ledger.held1),
            uint256(ledger.buffer1) + ledger.reserve1 + ledger.escrow + ledger.treasury1 + ledger.feeVault1
                + ledger.unclaimed1 + stream.remaining1 + book1 + income1,
            "held1 parts"
        );
    }

    // ---------------------------------------------------------------- setup

    /// @dev Gives a vault lenders and an open position, so it has reserves, escrow, debt and Metric shares to disturb.
    function _seed(uint256 targetVaultId) internal returns (uint256) {
        vm.prank(lender);
        vault.deposit(targetVaultId, 20e18, 100_000e6, 0, lender);
        vm.prank(trader);
        return vault.open(_longRequest(targetVaultId, 100e6, 0));
    }

    function _fundSecondBase(address holder) internal {
        secondBase.mint(holder, 1e30);
        vm.prank(holder);
        secondBase.approve(address(vault), type(uint256).max);
    }
}

/// @notice G15: vault creation refuses a factory pool failing one eligibility check at a time; and what it does with a
/// pool that runs a swap extension.
contract GapPoolsCreationTest is GapPoolsBase {
    SwapGate internal gate;

    function setUp() public override {
        super.setUp();
        gate = new SwapGate();
    }

    /// @dev Control for the refusals below: the fixture's pool parameters, deployed by the factory, are accepted. Each
    /// refusal differs from this pool in one field, so it is that field the vault refuses.
    function test_createVault_acceptsTheUnalteredFactoryPool() public {
        MetricOmmPool candidate = _deployWith(poolParams());
        uint256 newVaultId = _create(candidate, defaultParameters());
        assertEq(newVaultId, 2, "a second vault");
        assertEq(vault.vaultCount(), 2, "counted");
        assertEq(vault.vaultOfPool(address(candidate)), newVaultId, "registered");
    }

    /// @dev A factory pool whose tokens are in the other order is refused for the fixture's parameters, and the same
    /// pool is accepted once the parameters name its tokens in its order: the order alone was refused. A vault bound
    /// to a pool whose tokens it reads the other way round would price every open and close upside down.
    function test_createVault_refusesAPoolWithTheTokensInTheOtherOrder() public {
        MetricOmmPoolDeployer.DeployParams memory poolParameters = poolParams();
        (poolParameters.token0, poolParameters.token1) = (address(quote), address(base));
        (poolParameters.token0ScaleMultiplier, poolParameters.token1ScaleMultiplier) = (1e12, 1);
        MetricOmmPool candidate = _deployWith(poolParameters);
        _assertRefused(candidate, defaultParameters());
        VaultParameters memory matching = defaultParameters();
        (matching.token0, matching.token1) = (address(quote), address(base));
        uint256 newVaultId = _create(candidate, matching);
        assertEq(vault.vaultOfPool(address(candidate)), newVaultId, "accepted in its own order");
    }

    /// @dev Each token is checked on its own: a pool matching the quote but not the base is refused, and one matching
    /// the base but not the quote. A check on one token alone would let the vault place its lenders' capital in a pool
    /// trading it for a token they never deposited.
    function test_createVault_refusesAPoolWhoseOneTokenDiffers() public {
        IntegrationToken stranger = new IntegrationToken("STRANGER", 18);
        MetricOmmPoolDeployer.DeployParams memory strangerBaseParameters = poolParams();
        strangerBaseParameters.token0 = address(stranger);
        _assertRefused(_deployWith(strangerBaseParameters), defaultParameters());
        IntegrationToken strangerQuote = new IntegrationToken("STRANGERQ", 6);
        MetricOmmPoolDeployer.DeployParams memory strangerQuoteParameters = poolParams();
        strangerQuoteParameters.token1 = address(strangerQuote);
        _assertRefused(_deployWith(strangerQuoteParameters), defaultParameters());
    }

    /// @dev A pool whose price provider its admin can replace could be pointed at one that prices the vault's opens.
    function test_createVault_refusesAMutablePriceProvider() public {
        MetricOmmPoolDeployer.DeployParams memory poolParameters = poolParams();
        poolParameters.immutablePriceProvider = false;
        _assertRefused(_deployWith(poolParameters), defaultParameters());
    }

    /// @dev An extension run before removals could block every exit of the vault's idle capital.
    function test_createVault_refusesABeforeRemovalExtension() public {
        MetricOmmPoolDeployer.DeployParams memory poolParameters = poolParams();
        poolParameters.extensions.extension1 = address(gate);
        poolParameters.extensionOrders.beforeRemoveLiquidity = 1;
        _assertRefused(_deployWith(poolParameters), defaultParameters());
    }

    /// @dev An extension run after removals could equally block them.
    function test_createVault_refusesAnAfterRemovalExtension() public {
        MetricOmmPoolDeployer.DeployParams memory poolParameters = poolParams();
        poolParameters.extensions.extension1 = address(gate);
        poolParameters.extensionOrders.afterRemoveLiquidity = 1;
        _assertRefused(_deployWith(poolParameters), defaultParameters());
    }

    /// @dev Swap extensions are not screened: a pool running one before and after every swap is accepted, as the
    /// spec's eligible-pools rule allows (StopLoss-style extensions).
    function test_createVault_acceptsAPoolWithSwapExtensions() public {
        MetricOmmPool gated = _gatedPool();
        uint256 newVaultId = _create(gated, defaultParameters());
        assertEq(vault.vaultOfPool(address(gated)), newVaultId, "registered");
        assertEq(vault.vaultCount(), 2, "counted");
    }

    /// @dev A swap extension that refuses the vault's swaps makes a force close wait: the band still reads, so the
    /// shortfall swap is budgeted, refused, and the close reverts `ShortfallUnfilled` while outsiders trade freely. The
    /// owner can still close, since a close swaps nothing, and the force close runs once the extension relents. The
    /// wait is bounded (audit finding W-3): years on, the arrears exceed all the trader would keep, and the close
    /// scales though the extension still refuses.
    function test_forceClose_waitsAsLongAsASwapExtensionRefusesTheVault() public {
        MetricOmmPool gated = _gatedPool();
        outsider.addLiquidity(gated, _outsideDeltas());
        uint256 gatedVaultId = _create(gated, defaultParameters());
        vm.prank(lender);
        vault.deposit(gatedVaultId, 0, 100_000e6, 0, lender);
        uint256 positionId = _openSwappedLong(gatedVaultId);
        _pastGrace(positionId, 0);
        gate.setBlocked(address(vault));
        uint256 reserve0 = vault.positionOf(positionId).reserve0;
        _assertWaits(positionId);
        (, int128 outsiderQuoteDelta) = outsider.swap(gated, true, int128(int256(1e18)));
        assertLt(outsiderQuoteDelta, 0, "outsiders still trade through the gate");
        _assertWaits(positionId);
        uint256 snapshot = vm.snapshotState();
        vm.prank(trader);
        vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: reserve0, repay1: 0}));
        assertEq(vault.positionOf(positionId).owner, address(0), "its owner can still close");
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();
        gate.setBlocked(address(0));
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).owner, address(0), "force closed once the extension relents");
        vm.revertToState(snapshot);
        vm.warp(block.timestamp + 3_650 days);
        vm.prank(closer);
        vault.forceClose(positionId);
        assertEq(vault.positionOf(positionId).owner, address(0), "the wait ends once arrears take the trader's stake");
    }

    // ---------------------------------------------------------------- helpers

    function _assertWaits(uint256 positionId) internal {
        vm.prank(closer);
        vm.expectRevert(IMetricLendingVault.ShortfallUnfilled.selector);
        vault.forceClose(positionId);
    }

    /// @dev The fixture's pool with the gate run before and after every swap.
    function _gatedPool() internal returns (MetricOmmPool) {
        MetricOmmPoolDeployer.DeployParams memory poolParameters = poolParams();
        poolParameters.extensions.extension1 = address(gate);
        poolParameters.extensionOrders.beforeSwap = 1;
        poolParameters.extensionOrders.afterSwap = 1;
        return _deployWith(poolParameters);
    }

    function _create(MetricOmmPool candidate, VaultParameters memory parameters) internal returns (uint256) {
        parameters.pool = address(candidate);
        vm.prank(owner);
        return vault.createVault(parameters, defaultCurves());
    }

    /// @dev The pool is the factory's, so the refusal is the eligibility check's and not the factory check's: creation
    /// reverts with InvalidParameters, which leaves nothing registered.
    function _assertRefused(MetricOmmPool candidate, VaultParameters memory parameters) internal {
        assertTrue(this.isPool(address(candidate)), "a factory pool");
        parameters.pool = address(candidate);
        vm.prank(owner);
        vm.expectRevert(IMetricLendingVault.InvalidParameters.selector);
        vault.createVault(parameters, defaultCurves());
    }
}
