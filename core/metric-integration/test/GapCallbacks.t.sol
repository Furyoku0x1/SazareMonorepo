// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "metric/MetricOmmPoolDeployer.sol";
import {IMetricOmmPoolActions} from "metric/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmSwapCallback} from "metric/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {IMetricOmmExtensions} from "metric/interfaces/extensions/IMetricOmmExtensions.sol";
import {ExtensionOrders} from "metric/types/PoolExtensionsConfig.sol";
import {LiquidityDelta} from "metric/types/PoolOperation.sol";
import {MetricReentrancyGuardTransient} from "metric/utils/MetricReentrancyGuardTransient.sol";
import {BookSettings, FloorRow, LegRequest, MakerOpenRequest} from "vault/MakerTypes.sol";
import {MetricLendingVault} from "vault/MetricLendingVault.sol";
import {Ledger, OpenRequest, VaultParameters} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MakerMath} from "vault/libraries/MakerMath.sol";
import {MetricState} from "vault/libraries/MetricState.sol";
import {Curve} from "vault/libraries/VaultMath.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice Swaps on a pool and, from inside its own swap callback while the pool holds its lock, makes one call to the
/// vault and records how it ended, then pays the pool.
contract InsideSwapCallback is IMetricOmmSwapCallback {
    address internal immutable vault;
    bytes internal pendingCall;
    bool public succeeded;
    bytes public result;

    constructor(address vault_) {
        vault = vault_;
    }

    function swapAndCall(MetricOmmPool pool, bytes calldata vaultCall) external {
        pendingCall = vaultCall;
        pool.swap(address(this), false, int128(1e6), type(uint128).max, "", "");
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        (succeeded, result) = vault.call(pendingCall);
        MetricOmmPool pool = MetricOmmPool(msg.sender);
        if (amount0 > 0) ERC20(pool.getImmutables().token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) ERC20(pool.getImmutables().token1).transfer(msg.sender, uint256(amount1));
    }
}

enum ProbeMode {
    Passive,
    ProbeSwaps,
    ProbeAdds,
    RefuseAdds
}

/// @notice A Metric extension on a second pool. While the vault is mid-call into that pool and expecting its callback,
/// it sends the vault forged callbacks: from the wrong pool, one unit over the cap, and a replay of the genuine one,
/// recording how each ended. Refusing, it reverts every add, so the pool refuses the vault's placement.
contract CallbackProbe is IMetricOmmExtensions {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Attempt {
        string label;
        bool accepted;
        bytes4 reason;
        bool paid;
    }

    error AddRefused();

    MetricLendingVault internal immutable vault;
    ERC20 internal immutable token0;
    ERC20 internal immutable token1;
    address internal homePool;
    address internal otherPool;
    ProbeMode public mode;
    Attempt[] internal attempts;
    /// @dev The vault's cap on token0 for the add being probed, rebuilt from the add's own deltas.
    uint256 public addCap0;
    /// @dev The genuine callback's amounts, as the pool reported them to the after hook.
    int256 public genuine0;
    int256 public genuine1;

    constructor(MetricLendingVault vault_, ERC20 token0_, ERC20 token1_) {
        vault = vault_;
        token0 = token0_;
        token1 = token1_;
    }

    function setPools(address home, address other) external {
        homePool = home;
        otherPool = other;
    }

    function setMode(ProbeMode newMode) external {
        mode = newMode;
    }

    function attemptCount() external view returns (uint256) {
        return attempts.length;
    }

    function attemptAt(uint256 index) external view returns (Attempt memory) {
        return attempts[index];
    }

    function initialize(address, bytes calldata) external pure returns (bytes4) {
        return IMetricOmmExtensions.initialize.selector;
    }

    function beforeAddLiquidity(address sender, address, uint80, LiquidityDelta calldata deltas, bytes calldata)
        external
        returns (bytes4)
    {
        if (mode == ProbeMode.RefuseAdds) revert AddRefused();
        if (!_probing(sender, ProbeMode.ProbeAdds)) return IMetricOmmExtensions.beforeAddLiquidity.selector;
        addCap0 = _cost0(deltas);
        // The vault's cap on token0 is positive here, so one unit of it is within the cap.
        _attempt("liquidity, wrong pool", otherPool, false, 1, 0);
        _attempt("liquidity, one unit over the token0 cap", homePool, false, int256(addCap0) + 1, 0);
        // A token0-only placement: the vault's cap on token1 is zero.
        _attempt("liquidity, one unit over the token1 cap", homePool, false, 0, 1);
        return IMetricOmmExtensions.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        address,
        uint80,
        LiquidityDelta calldata,
        uint256 amount0Added,
        uint256 amount1Added,
        bytes calldata
    ) external returns (bytes4) {
        if (!_probing(sender, ProbeMode.ProbeAdds)) {
            return IMetricOmmExtensions.afterAddLiquidity.selector;
        }
        genuine0 = int256(amount0Added);
        genuine1 = int256(amount1Added);
        _attempt("liquidity, replay", homePool, false, int256(amount0Added), int256(amount1Added));
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
        bool zeroForOne,
        int128 amountSpecified,
        uint128,
        uint256,
        uint128,
        uint128,
        uint128,
        bytes calldata
    ) external returns (bytes4) {
        if (_probing(sender, ProbeMode.ProbeSwaps)) _probeSwap(zeroForOne, amountSpecified);
        return IMetricOmmExtensions.beforeSwap.selector;
    }

    function afterSwap(
        address sender,
        address,
        bool,
        int128,
        uint128,
        uint256,
        uint256,
        uint128,
        uint128,
        uint128,
        int128 amount0Delta,
        int128 amount1Delta,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        if (!_probing(sender, ProbeMode.ProbeSwaps)) return IMetricOmmExtensions.afterSwap.selector;
        genuine0 = amount0Delta;
        genuine1 = amount1Delta;
        _attempt("swap, replay", homePool, true, amount0Delta, amount1Delta);
        return IMetricOmmExtensions.afterSwap.selector;
    }

    /// @dev An exact-input swap: the vault expects to pay at most `amountSpecified` of the input token, none of the
    /// other.
    function _probeSwap(bool zeroForOne, int128 amountSpecified) internal {
        (int256 withinCap0, int256 withinCap1) = zeroForOne ? (int256(1), int256(0)) : (int256(0), int256(1));
        _attempt("swap, wrong pool", otherPool, true, withinCap0, withinCap1);
        int256 overCap = int256(amountSpecified) + 1;
        (int256 overCap0, int256 overCap1) = zeroForOne ? (overCap, int256(0)) : (int256(0), overCap);
        _attempt("swap, one unit over the input cap", homePool, true, overCap0, overCap1);
        _attempt("swap, one unit of the token it does not pay", homePool, true, withinCap1, withinCap0);
    }

    function _probing(address sender, ProbeMode wanted) internal view returns (bool) {
        if (mode != wanted) return false;
        return sender == address(vault);
    }

    /// @dev What the vault planned to pay in token0 for these deltas, as `MetricVenue._planBin` computes it: each bin's
    /// share of its balance rounded up. Token0's scale is one, so scaled and native units agree.
    function _cost0(LiquidityDelta calldata deltas) internal view returns (uint256 total) {
        uint256 count = deltas.binIdxs.length;
        // count <= MetricVenue.MAX_BINS + 1
        for (uint256 index = 0; index < count; ++index) {
            MetricState.Bin memory state = MetricState.bin(homePool, int16(deltas.binIdxs[index]));
            // An empty bin mints a share per scaled unit: the fixture's initial rate is 1e18 per 1e18 shares.
            if (state.totalShares == 0) total += deltas.shares[index];
            else total += FullMath.mulDivRoundingUp(state.balance0Scaled, deltas.shares[index], state.totalShares);
        }
    }

    /// @dev Sends one forged callback as `caller` and records whether the vault took it and paid anything.
    function _attempt(string memory label, address caller, bool swapCallback, int256 amount0, int256 amount1) internal {
        uint256 vault0Before = token0.balanceOf(address(vault));
        uint256 vault1Before = token1.balanceOf(address(vault));
        bytes memory data = swapCallback
            ? abi.encodeCall(MetricLendingVault.metricOmmSwapCallback, (amount0, amount1, ""))
            : abi.encodeCall(
                MetricLendingVault.metricOmmModifyLiquidityCallback, (uint256(amount0), uint256(amount1), "")
            );
        vm.prank(caller);
        (bool accepted, bytes memory reason) = address(vault).call(data);
        bool paid = token0.balanceOf(address(vault)) != vault0Before;
        if (token1.balanceOf(address(vault)) != vault1Before) paid = true;
        attempts.push(Attempt({label: label, accepted: accepted, reason: bytes4(reason), paid: paid}));
    }
}

/// @notice The singleton's Metric callback guard: a maker force close from inside a pool callback meets Metric's
/// lock (G1); forged callbacks from the wrong pool, over the cap, or replayed are refused while a genuine one is
/// expected (G3); and a caught pool failure leaves no expectation a later callback could take payment from (G4).
contract GapCallbacksTest is MetricFixture {
    int24 internal constant PRICE_TICK = -200_311;
    uint24 internal constant LEVEL_TICKS = 100;
    /// @dev About 1,943–1,962: below the 2,000 price.
    int24 internal constant BUY_LEVEL = -2_006;
    uint256 internal constant ENTRY_AMOUNT_IN = 10_200e6;

    CallbackProbe internal probe;
    MetricOmmPool internal probedPool;
    uint256 internal probedVaultId;

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        vault.createBook(vaultId, _settings(), _curve(), _floors());
        _deployProbedPool();
        outsider.addLiquidity(probedPool, _outsideDepth());
        VaultParameters memory parameters = defaultParameters();
        parameters.pool = address(probedPool);
        vm.prank(owner);
        probedVaultId = vault.createVault(parameters, defaultCurves());
    }

    // ---------------------------------------------------------------- G1: maker force close from a callback

    /// @dev A maker force close called from inside a Metric swap callback reads its price while the pool holds its
    /// lock. Read as "no price", that would push the close onto its scaling fallback, which can cost the trader far
    /// more than the range is worth. It must stop on Metric's lock and change nothing, then close normally outside.
    function test_forceCloseMaker_fromASwapCallbackMeetsMetricsLockAndChangesNothing() public {
        (uint256 positionId, uint256 bucketId) = _delinquentMakerLong();
        bytes32 stateBefore = _makerState(positionId, bucketId);
        InsideSwapCallback attacker = new InsideSwapCallback(address(vault));
        quote.mint(address(attacker), 10e6);
        attacker.swapAndCall(pool, abi.encodeCall(vault.forceCloseMaker, (positionId)));
        assertFalse(attacker.succeeded(), "refused inside the callback");
        assertEq(
            bytes32(bytes4(attacker.result())),
            bytes32(MetricReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector),
            "stopped by Metric's lock"
        );
        assertEq(_makerState(positionId, bucketId), stateBefore, "position, leg, bucket, book and ledger unchanged");
        vm.recordLogs();
        vm.prank(closer);
        vault.forceCloseMaker(positionId);
        assertEq(_poolSwaps(vm.getRecordedLogs()), 1, "outside the callback it buys its shortfall");
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed");
        assertEq(vault.bucketOf(vaultId, bucketId).lent, 0, "repaid to its bucket");
        assertLedger();
    }

    // ---------------------------------------------------------------- G3: forged callbacks while one is expected

    /// @dev While the vault's entry swap is expected to call back, a swap callback from another registered pool, one
    /// asking a unit over the input cap, one asking a unit of the token the swap does not pay, and a replay of the
    /// genuine one after it was paid are each refused and move no token, and none is left to take after the open.
    /// The genuine callback asked exactly the cap and was paid, so the refusals are the guard's, not a broken
    /// expectation's. An accepted forgery would pay its sender from the singleton, which holds every vault's tokens.
    function test_swapCallback_refusesTheWrongPoolOneUnitOverTheCapAndAReplay() public {
        _depositInto(probedVaultId, 0, 100_000e6);
        OpenRequest memory request = _longRequest(probedVaultId, 10_000e6, 300e6);
        request.entryAmountIn = ENTRY_AMOUNT_IN;
        probe.setMode(ProbeMode.ProbeSwaps);
        uint256 positionId = this.openThenProbeInOneTransaction(request);
        probe.setMode(ProbeMode.Passive);
        _assertAllRefused(4);
        assertEq(probe.genuine1(), int256(ENTRY_AMOUNT_IN), "the genuine callback asked exactly the cap");
        assertLt(probe.genuine0(), 0, "and the pool paid base out");
        assertEq(vault.positionOf(positionId).reserve0, uint256(-probe.genuine0()), "the swap's base is the reserve");
        _assertCustody();
    }

    /// @dev While the vault's placement is expected to call back, a liquidity callback from another registered pool,
    /// one asking a unit over the token0 cap, one asking a unit of token1 the placement does not pay, and a replay of
    /// the genuine one are each refused and move no token, and none is left to take after the deposit. Metric charged
    /// exactly the cap rebuilt from the add's deltas, so the over-cap probe was exactly one unit over. An accepted
    /// forgery would pay its sender from the singleton, which holds every vault's tokens.
    function test_liquidityCallback_refusesTheWrongPoolOneUnitOverTheCapAndAReplay() public {
        probe.setMode(ProbeMode.ProbeAdds);
        this.depositThenProbeInOneTransaction(probedVaultId, 20e18, 0);
        probe.setMode(ProbeMode.Passive);
        _assertAllRefused(4);
        assertGt(probe.addCap0(), 0, "a token0 placement");
        assertEq(probe.genuine0(), int256(probe.addCap0()), "Metric charged exactly the vault's cap");
        assertEq(probe.genuine1(), 0, "and no token1");
        assertEq(vault.venueOf(probedVaultId).holdings0, probe.addCap0(), "the genuine callback was paid and placed");
        _assertCustody();
    }

    /// @dev Foundry clears transient storage after each top-level call of a test, so an expectation a vault call left
    /// behind is visible only within that call: the open and the forged callbacks after it share this one.
    function openThenProbeInOneTransaction(OpenRequest calldata request) external returns (uint256 positionId) {
        vm.prank(trader);
        positionId = vault.open(request);
        _assertNoExpectationLeft(address(probedPool));
        _assertNoExpectationLeft(address(pool));
    }

    /// @dev One transaction, as in `openThenProbeInOneTransaction`.
    function depositThenProbeInOneTransaction(uint256 targetVaultId, uint256 amount0, uint256 amount1) external {
        _depositInto(targetVaultId, amount0, amount1);
        _assertNoExpectationLeft(address(probedPool));
        _assertNoExpectationLeft(address(pool));
    }

    // ---------------------------------------------------------------- G4: caught pool failures

    /// @dev A placement the pool refuses, by its extension and then by Metric's own lock inside a swap callback, is
    /// caught and leaves the deposit in the buffer. Each time, and after a later vault call in the same transaction
    /// places it, a callback from the pool asking for a unit of either token is refused and moves nothing: the
    /// expectation set before the refused add did not outlive it. A stale expectation would let a later callback from
    /// that pool draw tokens the vault never meant to pay.
    function test_refusedPlacements_leaveNoExpectationForALaterCallback() public {
        InsideSwapCallback caller = new InsideSwapCallback(address(vault));
        quote.mint(address(caller), 10e6);
        this.refusedPlacementsInOneTransaction(caller);
        assertGt(vault.venueOf(probedVaultId).holdings1, 49_000e6, "placed in the pool");
        _assertCustody();
    }

    /// @dev One transaction, as in `openThenProbeInOneTransaction`: two refused adds, each probed at once, then a
    /// vault call that places.
    function refusedPlacementsInOneTransaction(InsideSwapCallback caller) external {
        probe.setMode(ProbeMode.RefuseAdds);
        // The caller holds the shares, so it can withdraw from inside the swap callback below.
        vm.prank(lender);
        vault.deposit(probedVaultId, 0, 50_000e6, 0, address(caller));
        probe.setMode(ProbeMode.Passive);
        assertEq(vault.ledgerOf(probedVaultId).buffer1, 50_000e6, "the refused add left the deposit in the buffer");
        assertEq(vault.venueOf(probedVaultId).holdings1, 0, "nothing placed");
        _assertNoExpectationLeft(address(probedPool));
        // With nothing lent a withdrawal needs no price, so it reaches its placement inside the swap callback.
        uint256 shares = vault.sharesOf(probedVaultId, address(caller)) / 10_000;
        caller.swapAndCall(probedPool, abi.encodeCall(vault.withdraw, (probedVaultId, shares, 0, 0, address(caller))));
        assertTrue(caller.succeeded(), "the withdrawal caught Metric's refusal");
        assertEq(vault.venueOf(probedVaultId).holdings1, 0, "Metric's lock refused the add");
        assertGt(vault.ledgerOf(probedVaultId).buffer1, 49_990e6, "the rest waits in the buffer");
        _assertNoExpectationLeft(address(probedPool));
        // Another vault call, outside the lock: it sets, and is paid on, its own expectation.
        _depositInto(probedVaultId, 0, 1e6);
        assertLt(vault.ledgerOf(probedVaultId).buffer1, 1_000e6, "placed once Metric accepts the add");
        _assertNoExpectationLeft(address(probedPool));
    }

    /// @dev A maker force close whose shortfall swap Metric refuses while paused waits, reverting with
    /// ShortfallUnfilled. A later deposit in the same transaction still places on the paused pool, and no callback
    /// from the pool can take payment before or after it. Weaker than the placement case: the whole close reverts, so
    /// the expectation set for its swap is undone with it; this pins that the wait stays a revert.
    function test_forceCloseMakerWaiting_leavesNoExpectationForALaterCallback() public {
        (uint256 positionId,) = _delinquentMakerLong();
        pool.setPause(1);
        this.waitingForceCloseInOneTransaction(positionId);
        pool.setPause(0);
        vm.prank(closer);
        vault.forceCloseMaker(positionId);
        assertEq(vault.makerPositionOf(positionId).owner, address(0), "closed once swaps resume");
        assertLedger();
    }

    /// @dev One transaction, as in `openThenProbeInOneTransaction`.
    function waitingForceCloseInOneTransaction(uint256 positionId) external {
        vm.prank(closer);
        (bool closed, bytes memory reason) = address(vault).call(abi.encodeCall(vault.forceCloseMaker, (positionId)));
        assertFalse(closed, "waits while swaps are paused");
        assertEq(bytes32(bytes4(reason)), bytes32(IMetricLendingVault.ShortfallUnfilled.selector), "ShortfallUnfilled");
        _assertNoExpectationLeft(address(pool));
        uint256 holdings1Before = vault.venueOf(vaultId).holdings1;
        deposit(lender, 0, 10_000e6);
        assertGt(
            vault.venueOf(vaultId).holdings1, holdings1Before + 9_000e6, "the later deposit placed on the paused pool"
        );
        _assertNoExpectationLeft(address(pool));
    }

    // ---------------------------------------------------------------- assertions

    /// @dev Every forged callback the probe sent was refused with UnexpectedCallback and moved no token.
    function _assertAllRefused(uint256 expectedCount) internal view {
        uint256 count = probe.attemptCount();
        assertEq(count, expectedCount, "every forged callback was sent");
        // count <= 4
        for (uint256 index = 0; index < count; ++index) {
            CallbackProbe.Attempt memory attempt = probe.attemptAt(index);
            assertFalse(attempt.accepted, attempt.label);
            assertEq(bytes32(attempt.reason), bytes32(IMetricLendingVault.UnexpectedCallback.selector), attempt.label);
            assertFalse(attempt.paid, attempt.label);
        }
    }

    /// @dev With no vault call into `caller` under way, a callback from it asking a unit of either token, through
    /// either callback, is refused and moves no token. Meaningful only inside the transaction under test.
    function _assertNoExpectationLeft(address caller) internal {
        uint256 vault0Before = base.balanceOf(address(vault));
        uint256 vault1Before = quote.balanceOf(address(vault));
        _expectRefused(caller, false, 1, 0);
        _expectRefused(caller, false, 0, 1);
        _expectRefused(caller, true, 1, 0);
        _expectRefused(caller, true, 0, 1);
        assertEq(base.balanceOf(address(vault)), vault0Before, "no token0 paid");
        assertEq(quote.balanceOf(address(vault)), vault1Before, "no token1 paid");
    }

    function _expectRefused(address caller, bool swapCallback, uint256 amount0, uint256 amount1) internal {
        bytes memory data = swapCallback
            ? abi.encodeCall(vault.metricOmmSwapCallback, (int256(amount0), int256(amount1), ""))
            : abi.encodeCall(vault.metricOmmModifyLiquidityCallback, (amount0, amount1, ""));
        vm.prank(caller);
        (bool accepted, bytes memory reason) = address(vault).call(data);
        assertFalse(accepted, "a callback with no vault call under way is refused");
        assertEq(bytes32(bytes4(reason)), bytes32(IMetricLendingVault.UnexpectedCallback.selector), "refused");
    }

    /// @dev The two vaults share their tokens, so the singleton holds exactly what both ledgers record.
    function _assertCustody() internal view {
        Ledger memory first = vault.ledgerOf(vaultId);
        Ledger memory second = vault.ledgerOf(probedVaultId);
        assertEq(uint256(first.held0) + second.held0, base.balanceOf(address(vault)), "token0 custody");
        assertEq(uint256(first.held1) + second.held1, quote.balanceOf(address(vault)), "token1 custody");
    }

    function _makerState(uint256 positionId, uint256 bucketId) internal view returns (bytes32) {
        (uint256 book0, uint256 book1, uint256 income0, uint256 income1) = vault.bookTotalsOf(vaultId);
        return keccak256(
            abi.encode(
                vault.makerPositionOf(positionId),
                vault.legOf(positionId, 0),
                vault.bucketOf(vaultId, bucketId),
                vault.ledgerOf(vaultId),
                book0,
                book1,
                income0,
                income1
            )
        );
    }

    /// @dev How many swaps the fixture's pool emitted.
    function _poolSwaps(Vm.Log[] memory logs) internal view returns (uint256 count) {
        bytes32 swapTopic = IMetricOmmPoolActions.Swap.selector;
        // logs.length < 20: one force close's events, 8 in this test
        for (uint256 index = 0; index < logs.length; ++index) {
            if (logs[index].emitter != address(pool)) continue;
            if (logs[index].topics[0] == swapTopic) ++count;
        }
    }

    // ---------------------------------------------------------------- setup helpers

    /// @dev A second pool on the same tokens, Metric's own code from a factory this fixture answers for, with the
    /// probe as its add and swap extension. The vault refuses only remove extensions, so it accepts this pool.
    function _deployProbedPool() internal {
        probe = new CallbackProbe(vault, ERC20(address(base)), ERC20(address(quote)));
        MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(this));
        MetricOmmPoolDeployer.DeployParams memory poolParameters = poolParams();
        poolParameters.salt = keccak256("probed");
        poolParameters.extensions.extension1 = address(probe);
        poolParameters.extensionOrders = ExtensionOrders({
            beforeAddLiquidity: 1,
            afterAddLiquidity: 1,
            beforeRemoveLiquidity: 0,
            afterRemoveLiquidity: 0,
            beforeSwap: 1,
            afterSwap: 1
        });
        probedPool = MetricOmmPool(deployer.deploy(poolParameters));
        deployedPools[address(probedPool)] = true;
        probe.setPools(address(probedPool), address(pool));
    }

    /// @dev The fixture's outside depth: ten base per bin at and above the cursor, 20,000 quote per bin below.
    function _outsideDepth() internal pure returns (LiquidityDelta memory deltas) {
        deltas.binIdxs = new int256[](40);
        deltas.shares = new uint256[](40);
        // 40 bins
        for (uint256 index = 0; index < 40; ++index) {
            deltas.binIdxs[index] = int256(index) - 20;
            deltas.shares[index] = 10e18;
        }
    }

    function _depositInto(uint256 targetVaultId, uint256 amount0, uint256 amount1) internal {
        vm.prank(lender);
        vault.deposit(targetVaultId, amount0, amount1, 0, lender);
    }

    function _longRequest(uint256 targetVaultId, uint256 notional, uint128 collateral)
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
        request.liquidity = uint128(notional * (1 << 96) / (sqrtUpperX96 - sqrtLowerX96));
        request.collateral = collateral;
        request.escrow = 100e6;
    }

    /// @dev A one-leg maker long on the fixture's vault, past its grace period after the price fell through its level,
    /// as `MakerFills.test_forceCloseMaker_waitsWhileMetricIsPaused` builds it.
    function _delinquentMakerLong() internal returns (uint256 positionId, uint256 bucketId) {
        vm.prank(lender);
        (bucketId,) = vault.depositOrder(vaultId, BUY_LEVEL, true, 30_000e6, 0, lender);
        MakerOpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = true;
        request.legs = new LegRequest[](1);
        request.legs[0] = LegRequest({bucketId: bucketId, liquidity: _liquidityOn(BUY_LEVEL, 10_000e6)});
        // Enough collateral that the trader keeps more than the arrears, so the close buys or waits rather than scale
        // (audit finding W-3).
        request.collateral = 3_000e6;
        request.escrow = 220e6;
        request.maximumRateBps = type(uint256).max;
        vm.prank(trader);
        positionId = vault.openMaker(request);
        provider.set(uint128(1_900 * Q64), HALF_SPREAD_E5);
        vm.warp(block.timestamp + 20 days);
        vault.flagMaker(positionId);
        vm.warp(block.timestamp + 1 hours + 1);
    }

    function _liquidityOn(int24 level, uint256 amount1) internal pure returns (uint128) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = MakerMath.levelRange(level, LEVEL_TICKS);
        return uint128(FullMath.mulDiv(amount1, 1 << 96, sqrtUpperX96 - sqrtLowerX96));
    }

    function _settings() internal pure returns (BookSettings memory settings) {
        settings.levelTicks = LEVEL_TICKS;
        settings.utilizationCeilingBps = 9_000;
        settings.fillRewardBps = 5;
        settings.graceSeconds = 1 hours;
        settings.minimumEscrowSeconds = 3 days;
        settings.minimumChargeSeconds = 2 days;
        settings.minimumNotional = 100e6;
    }

    function _curve() internal pure returns (Curve memory) {
        return Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0.05e18, slope2Wad: 12e18});
    }

    function _floors() internal pure returns (FloorRow[] memory rows) {
        rows = new FloorRow[](3);
        rows[0] = FloorRow({minimumDistanceBps: 1_500, rateBps: 5_000});
        rows[1] = FloorRow({minimumDistanceBps: 400, rateBps: 14_000});
        rows[2] = FloorRow({minimumDistanceBps: 0, rateBps: 25_000});
    }
}
