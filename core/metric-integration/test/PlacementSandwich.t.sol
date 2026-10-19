// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {IMetricOmmSwapCallback} from "metric/interfaces/callbacks/IMetricOmmSwapCallback.sol";
import {MetricState} from "vault/libraries/MetricState.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice A swapper that trades up or down to a price limit.
contract LimitSwapper is IMetricOmmSwapCallback {
    function swapToLimit(MetricOmmPool pool, bool zeroForOne, int128 amount, uint128 limitX64) external {
        pool.swap(address(this), zeroForOne, amount, limitX64, "", "");
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        MetricOmmPool pool = MetricOmmPool(msg.sender);
        if (amount0 > 0) ERC20(pool.getImmutables().token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) ERC20(pool.getImmutables().token1).transfer(msg.sender, uint256(amount1));
    }
}

/// @notice Audit finding X-1: anyone could push Metric's cursor off the oracle reference, trigger a vault placement
/// (a deposit or a close), and trade back, buying the vault's newly placed base below the reference (or its quote
/// above). On a 400,000 USD vault a 5% push took 3.8% of lender value. The vault now places only while the cursor's bin
/// holds the reference.
contract PlacementSandwichTest is MetricFixture {
    /// @dev The fixture's reference price, in whole quote per whole base.
    uint256 internal constant REFERENCE_PRICE = 2_000;
    /// @dev Inside the outsider's ±4% of depth, and ten bins of 0.2% off the reference.
    uint256 internal constant PUSH_BPS = 200;

    LimitSwapper internal swapper;
    address internal secondLender = makeAddr("lender2");

    function setUp() public override {
        super.setUp();
        swapper = new LimitSwapper();
        base.mint(address(swapper), 1e24);
        quote.mint(address(swapper), 1e14);
        base.mint(secondLender, 1e24);
        quote.mint(secondLender, 1e14);
        vm.startPrank(secondLender);
        base.approve(address(vault), type(uint256).max);
        quote.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        deposit(lender, 100e18, 200_000e6);
    }

    /// @dev Pushed down, a lender's base deposit waits in the buffer, so it puts no more base below the reference than
    /// the push itself sold into the vault's quote bins (bought cheaply, which is harmless); the round trip only costs
    /// the swapper the pool's fees. A deposit placed around the pushed cursor would put base below the reference for
    /// the swapper to buy back cheaply, the X-1 sandwich.
    function test_pushDownThenDeposit_placesNoBaseBelowTheReference() public {
        uint256 walletBefore = _walletValue();
        _push(true);
        uint256 belowAfterPush = _baseBelowReference();
        uint256 buffer0Before = vault.ledgerOf(vaultId).buffer0;
        vm.prank(secondLender);
        vault.deposit(vaultId, 1e18, 0, 0, secondLender);
        assertEq(vault.ledgerOf(vaultId).buffer0, buffer0Before + 1e18, "the deposit waits in the buffer");
        assertEq(_baseBelowReference(), belowAfterPush, "no base moved below the reference");
        _reverse(true);
        assertLe(_walletValue(), walletBefore, "the sandwich does not pay");
        assertLedger();
    }

    /// @dev Pushed up, an honest lender's deposit waits in the buffer rather than put quote above the reference, and
    /// is placed once the price is back. A deposit placed around the pushed cursor would put quote above the
    /// reference for the swapper to sell into dearly, the X-1 sandwich run through a deposit.
    function test_pushUpThenDeposit_placesNoQuoteAboveTheReference() public {
        uint256 walletBefore = _walletValue();
        _push(false);
        uint256 aboveAfterPush = _quoteAboveReference();
        uint256 buffer1Before = vault.ledgerOf(vaultId).buffer1;
        vm.prank(secondLender);
        vault.deposit(vaultId, 0, 1_000e6, 0, secondLender);
        assertEq(vault.ledgerOf(vaultId).buffer1, buffer1Before + 1_000e6, "the deposit waits in the buffer");
        assertEq(_quoteAboveReference(), aboveAfterPush, "no quote moved above the reference");
        _reverse(false);
        assertLe(_walletValue(), walletBefore, "the sandwich does not pay");
        // Back at the reference, the next placement puts the waiting quote to work.
        vm.prank(secondLender);
        vault.deposit(vaultId, 0, 1_000e6, 0, secondLender);
        assertLt(vault.ledgerOf(vaultId).buffer1, buffer1Before + 2_000e6, "placed once back at the reference");
        assertLedger();
    }

    function _push(bool down) internal {
        if (down) {
            swapper.swapToLimit(pool, true, int128(int256(10_000e18)), _limitX64(10_000 - PUSH_BPS));
            return;
        }
        swapper.swapToLimit(pool, false, int128(int256(100_000_000e6)), _limitX64(10_000 + PUSH_BPS));
    }

    function _reverse(bool down) internal {
        if (down) {
            swapper.swapToLimit(pool, false, int128(int256(100_000_000e6)), _limitX64(10_000));
            return;
        }
        swapper.swapToLimit(pool, true, int128(int256(10_000e18)), _limitX64(10_000));
    }

    /// @dev A swap price limit at `fractionBps` of the reference, as a Q64.64 price.
    function _limitX64(uint256 fractionBps) internal pure returns (uint128) {
        return uint128(REFERENCE_PRICE * Q64 * fractionBps / 10_000);
    }

    /// @dev The swapper's tokens valued at the reference, in quote units.
    function _walletValue() internal view returns (uint256) {
        return quote.balanceOf(address(swapper)) + base.balanceOf(address(swapper)) * REFERENCE_PRICE / 1e12;
    }

    /// @dev The vault's base in bins whose upper edge is at or below the reference: Metric's bins below zero.
    function _baseBelowReference() internal view returns (uint256 amount0) {
        // the fixture's 40 bins below the reference
        for (int256 binIndex = -40; binIndex < 0; ++binIndex) {
            amount0 += _vaultPart(int16(binIndex), true);
        }
    }

    /// @dev The vault's quote in bins whose lower edge is at or above the reference: bins from zero up.
    function _quoteAboveReference() internal view returns (uint256 amount1) {
        // the fixture's 40 bins from the reference up
        for (int256 binIndex = 0; binIndex < 40; ++binIndex) {
            amount1 += _vaultPart(int16(binIndex), false);
        }
    }

    /// @dev The vault's share of one bin's token0 or token1, in Metric's scaled units.
    function _vaultPart(int16 binIndex, bool isToken0) internal view returns (uint256) {
        uint256 ours = MetricState.positionShares(address(pool), address(vault), uint80(vaultId), binIndex);
        if (ours == 0) return 0;
        MetricState.Bin memory state = MetricState.bin(address(pool), binIndex);
        uint256 balance = isToken0 ? state.balance0Scaled : state.balance1Scaled;
        return ours * balance / state.totalShares;
    }
}
