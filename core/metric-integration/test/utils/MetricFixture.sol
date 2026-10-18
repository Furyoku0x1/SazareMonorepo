// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "metric/MetricOmmPoolDeployer.sol";
import {IPriceProvider} from "metric/interfaces/IPriceProvider/IPriceProvider.sol";
import {IMetricOmmSwapCallback} from "metric/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {IMetricOmmModifyLiquidityCallback} from "metric/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {BinState} from "metric/types/PoolStorage.sol";
import {LiquidityDelta} from "metric/types/PoolOperation.sol";
import {MetricLendingVault} from "vault/MetricLendingVault.sol";
import {CurvePair, Ledger, OpenRequest, VaultParameters} from "vault/VaultTypes.sol";
import {Curve} from "vault/libraries/VaultMath.sol";

contract IntegrationToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name, uint8 decimals_) ERC20(name, name) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice An oracle-style provider: a settable reference with a symmetric spread, whole-token Q64.64.
contract SettableProvider is IPriceProvider {
    address public immutable token0;
    address public immutable token1;
    uint128 public referenceX64;
    /// @dev Half-spreads in tenths of a basis point: bid = ref / (1 + h), ask = ref · (1 + h_ask).
    uint256 public halfSpreadE5;
    uint256 public askHalfSpreadE5;
    bool public broken;

    constructor(address base, address quote) {
        token0 = base;
        token1 = quote;
    }

    function set(uint128 newReferenceX64, uint256 halfSpread) external {
        setBand(newReferenceX64, halfSpread, halfSpread);
    }

    /// @notice A lopsided band; Metric rejects it beyond the pool's bid/ask asymmetry bound.
    function setBand(uint128 newReferenceX64, uint256 bidHalfSpread, uint256 askHalfSpread) public {
        referenceX64 = newReferenceX64;
        halfSpreadE5 = bidHalfSpread;
        askHalfSpreadE5 = askHalfSpread;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function getQuote() external view returns (uint128 bid, uint128 ask, uint128 referencePrice) {
        require(!broken, "stale");
        referencePrice = referenceX64;
        bid = uint128(uint256(referencePrice) * 1e5 / (1e5 + halfSpreadE5));
        ask = uint128(uint256(referencePrice) * (1e5 + askHalfSpreadE5) / 1e5);
    }
}

/// @notice A plain LP and swapper against the pool, for outside depth and for moving the cursor.
contract Trader is IMetricOmmSwapCallback, IMetricOmmModifyLiquidityCallback {
    function addLiquidity(MetricOmmPool pool, LiquidityDelta memory deltas) external {
        pool.addLiquidity(address(this), 0, deltas, abi.encode(address(pool)), "");
    }

    function swap(MetricOmmPool pool, bool zeroForOne, int128 amount) external returns (int128, int128) {
        return pool.swap(address(this), zeroForOne, amount, zeroForOne ? 0 : type(uint128).max, "", "");
    }

    function metricOmmModifyLiquidityCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        MetricOmmPool pool = MetricOmmPool(msg.sender);
        ERC20(pool.getImmutables().token0).transfer(msg.sender, amount0);
        ERC20(pool.getImmutables().token1).transfer(msg.sender, amount1);
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        MetricOmmPool pool = MetricOmmPool(msg.sender);
        if (amount0 > 0) ERC20(pool.getImmutables().token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) ERC20(pool.getImmutables().token1).transfer(msg.sender, uint256(amount1));
    }
}

/// @notice A Metric pool for an 18-decimal base at 2,000 of a 6-decimal quote, with an outside LP, and a vault on it.
abstract contract MetricFixture is Test {
    uint256 internal constant Q64 = 1 << 64;
    uint256 internal constant BINS_PER_SIDE = 40;
    /// @dev 0.2% bins: the pool spans about ±8% around the reference.
    uint16 internal constant BIN_LENGTH_E6 = 2_000;
    /// @dev 5 bp each side.
    uint256 internal constant HALF_SPREAD_E5 = 50;

    IntegrationToken internal base;
    IntegrationToken internal quote;
    SettableProvider internal provider;
    MetricOmmPool internal pool;
    Trader internal outsider;
    MetricLendingVault internal vault;
    uint256 internal vaultId;

    /// @dev Pools this fixture deployed as their factory.
    mapping(address => bool) internal deployedPools;

    address internal owner = makeAddr("owner");
    address internal lender = makeAddr("lender");
    address internal trader = makeAddr("trader");
    address internal closer = makeAddr("closer");

    /// @dev The fixture deploys pools as their factory (`params.factory`), so it answers as Metric's factory does: a
    /// pool is one it deployed.
    function isPool(address someAddress) external view returns (bool) {
        return deployedPools[someAddress];
    }

    function setUp() public virtual {
        base = new IntegrationToken("BASE", 18);
        quote = new IntegrationToken("QUOTE", 6);
        provider = new SettableProvider(address(base), address(quote));
        provider.set(uint128(2_000 * Q64), HALF_SPREAD_E5);
        pool = _deployPool();
        outsider = new Trader();
        base.mint(address(outsider), 1e30);
        quote.mint(address(outsider), 1e30);
        outsider.addLiquidity(pool, _outsideLiquidity());
        vault = new MetricLendingVault(owner, makeAddr("treasury"), makeAddr("feeVault"), address(this));
        vm.prank(owner);
        vaultId = vault.createVault(defaultParameters(), defaultCurves());
        _fund(lender);
        _fund(trader);
    }

    function defaultParameters() internal view returns (VaultParameters memory parameters) {
        parameters.token0 = address(base);
        parameters.token1 = address(quote);
        parameters.pool = address(pool);
        parameters.vestSeconds = 1 days;
        parameters.graceSeconds = 1 days;
        // Zero here so tests can open delinquent positions at once; `test_open_requiresTheMinimumEscrow` covers it.
        parameters.minimumEscrowSeconds = 0;
        parameters.premiumProtocolBps = 1_000;
        parameters.profitShareBps = 200;
        parameters.profitTreasuryBps = 2_500;
        parameters.profitFeeVaultBps = 2_500;
        parameters.forceCloseRewardBps = 100;
        parameters.forceCloseSlippageBps = 100;
        parameters.utilizationCeilingBps = 9_000;
        parameters.minBorrowNotional = 100e6;
        parameters.binCount = 16;
        parameters.recenterDistance = 3;
        parameters.weightCapBps = 10_000;
    }

    function defaultCurves() internal pure returns (CurvePair memory curves) {
        Curve memory curve = Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0.04e18, slope2Wad: 3e18});
        curves.token0 = curve;
        curves.token1 = curve;
    }

    function deposit(address who, uint256 amount0, uint256 amount1) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(vaultId, amount0, amount1, 0, who);
    }

    /// @dev Every token the vault contract holds belongs to exactly one part of the ledger; Metric holds the rest.
    function assertLedger() internal view {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        (uint256 book0, uint256 book1, uint256 income0, uint256 income1) = vault.bookTotalsOf(vaultId);
        assertEq(uint256(ledger.held0), base.balanceOf(address(vault)), "held0 vs balance");
        assertEq(uint256(ledger.held1), quote.balanceOf(address(vault)), "held1 vs balance");
        assertEq(
            uint256(ledger.held0),
            uint256(ledger.buffer0) + ledger.reserve0 + ledger.treasury0 + ledger.feeVault0 + ledger.unclaimed0
                + vault.streamOf(vaultId).remaining0 + book0 + income0,
            "held0 parts"
        );
        assertEq(
            uint256(ledger.held1),
            uint256(ledger.buffer1) + ledger.reserve1 + ledger.escrow + ledger.treasury1 + ledger.feeVault1
                + ledger.unclaimed1 + vault.streamOf(vaultId).remaining1 + book1 + income1,
            "held1 parts"
        );
    }

    function _deployPool() private returns (MetricOmmPool) {
        MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(this));
        address deployed = deployer.deploy(poolParams());
        deployedPools[deployed] = true;
        return MetricOmmPool(deployed);
    }

    /// @dev The fixture pool's parameters, with this fixture as its factory.
    function poolParams() internal view returns (MetricOmmPoolDeployer.DeployParams memory params) {
        params.salt = keccak256("vault-integration");
        params.factory = address(this);
        params.token0 = address(base);
        params.token1 = address(quote);
        params.priceProvider = address(provider);
        params.immutablePriceProvider = true;
        // Metric scales both tokens to 18 decimals.
        params.token0ScaleMultiplier = 1;
        params.token1ScaleMultiplier = 1e12;
        params.initialScaledAmount0PerShareE18 = 1e18;
        params.initialScaledAmount1PerShareE18 = 2_000e18;
        params.minimalOperationalLiquidity = 1e6;
        params.spreadFeeE6 = 300_000;
        params.bidAskRefAsymmetryX8 = 512;
        params.nonNegativeBinStates = _bins();
        params.negativeBinStates = _bins();
    }

    function _bins() private pure returns (BinState[] memory bins) {
        bins = new BinState[](BINS_PER_SIDE);
        // BINS_PER_SIDE bins
        for (uint256 index = 0; index < BINS_PER_SIDE; ++index) {
            bins[index].lengthE6 = BIN_LENGTH_E6;
        }
    }

    /// @dev Ten base per bin at and above the cursor, 20,000 quote per bin below, across the middle 40 bins.
    function _outsideLiquidity() private pure returns (LiquidityDelta memory deltas) {
        deltas.binIdxs = new int256[](40);
        deltas.shares = new uint256[](40);
        // 40 bins
        for (uint256 index = 0; index < 40; ++index) {
            deltas.binIdxs[index] = int256(index) - 20;
            deltas.shares[index] = 10e18;
        }
    }

    function _fund(address who) private {
        base.mint(who, 1e30);
        quote.mint(who, 1e30);
        vm.startPrank(who);
        base.approve(address(vault), type(uint256).max);
        quote.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }
}
