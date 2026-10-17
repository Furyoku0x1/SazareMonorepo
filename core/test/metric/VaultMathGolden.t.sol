// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console2} from "forge-std/Test.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";

/// @notice Exact VaultMath outputs for fixed inputs, logged as `golden|...` lines. The Metric backtest
/// (hooks/research/metric-backtest) asserts its Python port reproduces every one of them to the unit.
/// Run: forge test --match-contract VaultMathGoldenTest -vv
contract VaultMathGoldenTest is Test {
    /// @dev About ETH at 2,000 USD with 18 and 6 decimals.
    int24 internal constant PRICE_TICK = -200_311;

    function test_logGoldenValues() public pure {
        int24[5] memory offsets = [int24(-2_000), -600, -150, 100, 900];
        int24[3] memory widths = [int24(10), int24(100), int24(1_000)];
        uint128[3] memory liquidities = [uint128(1e12), uint128(3e15), uint128(7e18)];
        int24[5] memory priceOffsets = [int24(-3_000), -620, 0, 75, 2_500];
        // offsets × widths × liquidities × price offsets = 225 cases
        for (uint256 rangeIndex = 0; rangeIndex < 5; ++rangeIndex) {
            for (uint256 widthIndex = 0; widthIndex < 3; ++widthIndex) {
                _logRange(PRICE_TICK + offsets[rangeIndex], widths[widthIndex], liquidities, priceOffsets);
            }
        }
    }

    function _logRange(int24 tickLower, int24 width, uint128[3] memory liquidities, int24[5] memory priceOffsets)
        internal
        pure
    {
        int24 tickUpper = tickLower + width;
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(tickLower, tickUpper);
        // liquidities × price offsets
        for (uint256 liquidityIndex = 0; liquidityIndex < 3; ++liquidityIndex) {
            for (uint256 priceIndex = 0; priceIndex < 5; ++priceIndex) {
                _logCase(
                    tickLower,
                    tickUpper,
                    liquidities[liquidityIndex],
                    sqrtLowerX96,
                    sqrtUpperX96,
                    PRICE_TICK + priceOffsets[priceIndex]
                );
            }
        }
    }

    /// @dev The outputs of one case; a struct keeps the stack shallow.
    struct Outputs {
        uint256 maximum0;
        uint256 maximum1;
        uint256 held0;
        uint256 held1;
        uint256 release0;
        uint256 release1;
        bool repaysHeld;
        bool repaysShort;
        uint256 heldValue0;
    }

    function _logCase(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint160 sqrtLowerX96,
        uint160 sqrtUpperX96,
        int24 priceTick
    ) internal pure {
        Outputs memory outputs = _compute(liquidity, sqrtLowerX96, sqrtUpperX96, priceTick);
        string memory head = string.concat(
            "golden|", vm.toString(tickLower), "|", vm.toString(tickUpper), "|", vm.toString(liquidity), "|"
        );
        string memory middle = string.concat(
            vm.toString(priceTick),
            "|",
            vm.toString(outputs.maximum0),
            "|",
            vm.toString(outputs.maximum1),
            "|",
            vm.toString(outputs.held0),
            "|"
        );
        string memory tail = string.concat(
            vm.toString(outputs.held1),
            "|",
            vm.toString(outputs.release0),
            "|",
            vm.toString(outputs.release1),
            "|",
            outputs.repaysHeld ? "1" : "0",
            "|",
            outputs.repaysShort ? "1" : "0",
            "|",
            vm.toString(outputs.heldValue0)
        );
        console2.log(string.concat(head, middle, tail));
    }

    function _compute(uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96, int24 priceTick)
        internal
        pure
        returns (Outputs memory outputs)
    {
        uint160 sqrtBidX96 = TickMath.getSqrtPriceAtTick(priceTick - 1);
        uint160 sqrtAskX96 = TickMath.getSqrtPriceAtTick(priceTick + 1);
        (outputs.maximum0, outputs.maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        (outputs.held0, outputs.held1) = VaultMath.holdingsAt(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96);
        (outputs.release0, outputs.release1) =
            VaultMath.releaseAcrossBand(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96, sqrtAskX96);
        outputs.repaysHeld =
            VaultMath.repays(outputs.held0 + 1, outputs.held1 + 1, liquidity, sqrtLowerX96, sqrtUpperX96);
        uint256 short0 = outputs.held0 == 0 ? 0 : outputs.held0 - 1;
        uint256 short1 = outputs.held1 == 0 ? 0 : outputs.held1 - 1;
        outputs.repaysShort = VaultMath.repays(short0, short1, liquidity, sqrtLowerX96, sqrtUpperX96);
        outputs.heldValue0 = VaultMath.priceTimes(outputs.held0, sqrtBidX96, false);
    }
}
