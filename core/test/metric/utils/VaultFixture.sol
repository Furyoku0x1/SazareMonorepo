// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MetricLendingVault} from "../../../src/metric/vault/MetricLendingVault.sol";
import {
    CloseRequest,
    CurvePair,
    Ledger,
    OpenRequest,
    Position,
    Stream,
    VaultParameters
} from "../../../src/metric/vault/VaultTypes.sol";
import {IVaultPriceSource} from "../../../src/metric/vault/interfaces/IVaultPriceSource.sol";
import {Curve, VaultMath} from "../../../src/metric/vault/libraries/VaultMath.sol";

contract TestToken is ERC20 {
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

/// @notice A settable band; `broken` makes it revert, as a stale oracle would.
contract MockPriceSource is IVaultPriceSource {
    uint160 public sqrtBidX96;
    uint160 public sqrtAskX96;
    bool public broken;

    function set(uint160 bid, uint160 ask) external {
        sqrtBidX96 = bid;
        sqrtAskX96 = ask;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function sqrtBandX96() external view returns (uint160, uint160) {
        require(!broken, "stale");
        return (sqrtBidX96, sqrtAskX96);
    }
}

/// @notice A vault without a Metric pool: idle capital stays in the contract, and prices come from a mock source.
/// Base is an 18-decimal token0 at about 2,000 of a 6-decimal token1.
abstract contract VaultFixture is Test {
    /// @dev Raw price 2e-9 (2,000e6 per 1e18) is about tick -200,311.
    int24 internal constant PRICE_TICK = -200_311;

    MetricLendingVault internal vault;
    TestToken internal base;
    TestToken internal quote;
    MockPriceSource internal source;
    uint256 internal vaultId;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal feeVault = makeAddr("feeVault");
    address internal lender = makeAddr("lender");
    address internal trader = makeAddr("trader");
    address internal closer = makeAddr("closer");

    function setUp() public virtual {
        base = new TestToken("BASE", 18);
        quote = new TestToken("QUOTE", 6);
        source = new MockPriceSource();
        vault = new MetricLendingVault(owner, treasury, feeVault, address(0));
        setPrice(PRICE_TICK, 1);
        vm.prank(owner);
        vaultId = vault.createVault(defaultParameters(), defaultCurves());
        _fund(lender);
        _fund(trader);
    }

    function defaultParameters() internal view returns (VaultParameters memory parameters) {
        parameters.token0 = address(base);
        parameters.token1 = address(quote);
        parameters.priceSource = address(source);
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
    }

    function defaultCurves() internal pure returns (CurvePair memory curves) {
        Curve memory curve = Curve({kinkWad: 0.8e18, baseRateWad: 0, slope1Wad: 0.04e18, slope2Wad: 3e18});
        curves.token0 = curve;
        curves.token1 = curve;
    }

    /// @dev Sets the band to `tick ± spreadTicks`.
    function setPrice(int24 tick, int24 spreadTicks) internal {
        source.set(TickMath.getSqrtPriceAtTick(tick - spreadTicks), TickMath.getSqrtPriceAtTick(tick + spreadTicks));
    }

    function deposit(address who, uint256 amount0, uint256 amount1) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(vaultId, amount0, amount1, 0, who);
    }

    /// @dev Liquidity whose all-token1 amount on `[tickLower, tickUpper)` is `amount1`.
    function liquidityFor1(int24 tickLower, int24 tickUpper, uint256 amount1) internal pure returns (uint128) {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        return uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtUpperX96 - sqrtLowerX96));
    }

    function openRequest(bool isLong, int24 tickLower, int24 tickUpper, uint128 liquidity, uint128 collateral)
        internal
        view
        returns (OpenRequest memory request)
    {
        request.vaultId = vaultId;
        request.isLong = isLong;
        request.tickLower = tickLower;
        request.tickUpper = tickUpper;
        request.liquidity = liquidity;
        request.collateral = collateral;
        request.escrow = 100e6;
    }

    function open(OpenRequest memory request) internal returns (uint256 positionId) {
        vm.prank(trader);
        positionId = vault.open(request);
    }

    /// @dev A long one to two percent below the price, borrowing `notional` of token1.
    function openLong(uint256 notional, uint128 collateral) internal returns (uint256) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        return open(openRequest(true, lower, upper, liquidityFor1(lower, upper, notional), collateral));
    }

    /// @dev Repays a position in full with the cheapest amounts at the band's bid.
    function cheapestRepayment(uint256 positionId) internal view returns (uint256 repay0, uint256 repay1) {
        Position memory position = vault.positionOf(positionId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        (repay0, repay1) = VaultMath.holdingsAt(position.liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96());
        // Holdings round down; two units of each held token covers the repayment rule's rounding.
        if (repay0 != 0) repay0 += 2;
        if (repay1 != 0) repay1 += 2;
    }

    /// @dev A repayment for `fractionWad` of a position, payable from the closed part of its reserves. The cheapest
    /// amounts at the bid, as `cheapestRepayment` rounds them, when the reserves hold them; otherwise all of the closed
    /// token0 plus the least token1 the repayment rule then needs. The second can exceed the closed token1 only when
    /// the closed reserves cannot repay at all.
    function repaymentFor(uint256 positionId, uint256 fractionWad)
        internal
        view
        returns (uint256 repay0, uint256 repay1)
    {
        Position memory position = vault.positionOf(positionId);
        uint128 closingLiquidity = uint128(VaultMath.portionDown(position.liquidity, fractionWad));
        uint256 portion0 = VaultMath.portionDown(position.reserve0, fractionWad);
        uint256 portion1 = VaultMath.portionDown(position.reserve1, fractionWad);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        (repay0, repay1) = VaultMath.holdingsAt(closingLiquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96());
        if (repay0 != 0) repay0 += 2;
        if (repay1 != 0) repay1 += 2;
        bool fits = repay0 <= portion0 && repay1 <= portion1;
        if (fits && VaultMath.repays(repay0, repay1, closingLiquidity, sqrtLowerX96, sqrtUpperX96)) {
            return (repay0, repay1);
        }
        repay0 = portion0;
        repay1 = minimumRepay1(portion0, closingLiquidity, sqrtLowerX96, sqrtUpperX96);
    }

    /// @dev The least token1 that, with `amount0`, passes `VaultMath.repays`: its virtual token1 must reach
    /// `ceil(T² / virtual0)` with `T = L·2^64`, the exact form of the rule's `floor(v0·v1 / T) >= T`.
    function minimumRepay1(uint256 amount0, uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (uint256)
    {
        uint256 thresholdX64 = uint256(liquidity) << 64;
        uint256 virtual0X64 = (amount0 << 64) + FullMath.mulDiv(liquidity, 1 << 160, sqrtUpperX96);
        uint256 neededX64 = FullMath.mulDivRoundingUp(thresholdX64, thresholdX64, virtual0X64);
        uint256 offset1X64 = FullMath.mulDiv(liquidity, sqrtLowerX96, 1 << 32);
        if (neededX64 <= offset1X64) return 0;
        return (neededX64 - offset1X64 + (1 << 64) - 1) >> 64;
    }

    /// @dev The least token1 collateral that makes an open of `liquidity` on the range pass the chord at the current
    /// band: the release is `(x(ask), y(bid))`, and the chord `r1·M0 + M1·r0 >= M1·M0` needs
    /// `r1 >= ceil(M1·(M0 − r0) / M0)`.
    function minimumCollateral(int24 tickLower, int24 tickUpper, uint128 liquidity) internal view returns (uint256) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(tickLower, tickUpper);
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        (uint256 release0, uint256 release1) =
            VaultMath.releaseAcrossBand(liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96(), source.sqrtAskX96());
        if (release0 >= maximum0) return 0;
        uint256 needed1 = FullMath.mulDivRoundingUp(maximum1, maximum0 - release0, maximum0);
        return needed1 > release1 ? needed1 - release1 : 0;
    }

    function closeFull(uint256 positionId, uint256 repay0, uint256 repay1) internal returns (uint256, uint256) {
        vm.prank(trader);
        return vault.close(CloseRequest({positionId: positionId, fractionWad: 1e18, repay0: repay0, repay1: repay1}));
    }

    /// @dev Every token the contract holds belongs to exactly one part of the ledger.
    function assertLedger() internal view {
        Ledger memory ledger = vault.ledgerOf(vaultId);
        assertEq(uint256(ledger.held0), base.balanceOf(address(vault)), "held0 vs balance");
        assertEq(uint256(ledger.held1), quote.balanceOf(address(vault)), "held1 vs balance");
        assertLedgerParts(vaultId);
    }

    /// @dev A vault's `held` balances are exactly the sum of their parts.
    function assertLedgerParts(uint256 someVaultId) internal view {
        Ledger memory ledger = vault.ledgerOf(someVaultId);
        Stream memory stream = vault.streamOf(someVaultId);
        assertEq(
            uint256(ledger.held0),
            uint256(ledger.buffer0) + ledger.reserve0 + ledger.treasury0 + ledger.feeVault0 + ledger.unclaimed0
                + stream.remaining0 + _bookPart(someVaultId, 0),
            "held0 parts"
        );
        assertEq(
            uint256(ledger.held1),
            uint256(ledger.buffer1) + ledger.reserve1 + ledger.escrow + ledger.treasury1 + ledger.feeVault1
                + ledger.unclaimed1 + stream.remaining1 + _bookPart(someVaultId, 1),
            "held1 parts"
        );
    }

    /// @dev The maker book's balances plus its makers' unclaimed income, in one token.
    function _bookPart(uint256 someVaultId, uint256 tokenIndex) internal view returns (uint256) {
        (uint256 book0, uint256 book1, uint256 income0, uint256 income1) = vault.bookTotalsOf(someVaultId);
        return tokenIndex == 0 ? book0 + income0 : book1 + income1;
    }

    function _fund(address who) private {
        fundWith(who, base);
        fundWith(who, quote);
    }

    /// @dev Mints `who` an unlimited supply of `token` for the vault's tests and approves the vault for it.
    function fundWith(address who, TestToken token) internal {
        token.mint(who, 1e30);
        vm.prank(who);
        token.approve(address(vault), type(uint256).max);
    }
}
