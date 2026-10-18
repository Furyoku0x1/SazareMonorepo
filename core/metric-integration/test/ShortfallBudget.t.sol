// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vault} from "vault/VaultTypes.sol";
import {VaultPricing} from "vault/libraries/VaultPricing.sol";
import {MetricFixture} from "./utils/MetricFixture.sol";

/// @notice Holds one vault's storage on the fixture's pool so the budget can be read directly.
contract BudgetReader {
    Vault internal vault;

    constructor(address pool, uint16 slippageBps) {
        vault.parameters.pool = pool;
        vault.parameters.forceCloseSlippageBps = slippageBps;
        vault.venue.scale0 = 1;
        vault.venue.scale1 = 1e12;
    }

    function budget(bool buyToken0, uint256 deficit, uint256 surplus) external returns (uint256) {
        return VaultPricing.shortfallBudget(vault, buyToken0, deficit, surplus, 0);
    }

    function budgetWithArrears(bool buyToken0, uint256 deficit, uint256 surplus, uint256 arrears)
        external
        returns (uint256)
    {
        return VaultPricing.shortfallBudget(vault, buyToken0, deficit, surplus, arrears);
    }

    /// @dev The cost at the band's far edge of buying `deficit` token1 with token0, as the budget computes it.
    function edgeCostOfToken1(uint256 deficit) external returns (uint256) {
        (, uint160 sqrtBidX96,) = VaultPricing.tryCloseBand(vault);
        return VaultPricing.token0At(sqrtBidX96, deficit);
    }
}

/// @notice When a force close may scale instead of swapping (audit finding Sol-2-1): a zero budget means scale, any
/// other means swap or wait for the pool.
contract ShortfallBudgetTest is MetricFixture {
    BudgetReader internal reader;

    function setUp() public override {
        super.setUp();
        reader = new BudgetReader(address(pool), 100);
    }

    /// @dev Buying 1,000 USD at a bid near 2,000 costs about 0.5 base at the edge: a surplus that can pay swaps, with
    /// at most 1% more; one that cannot pay even at the edge scales, since the trader holds nothing more at the band.
    /// A zero budget where the surplus can pay would scale away a gain the trader is owed.
    function test_budget_scalesOnlyWhereTheSurplusCannotPayAtTheEdge() public {
        uint256 fullBudget = reader.budget(false, 1_000e6, type(uint256).max);
        assertApproxEqRel(fullBudget, 0.505e18, 0.01e18, "half a base at the edge, plus 1%");
        assertEq(reader.budget(false, 1_000e6, 10e18), fullBudget, "a surplus that can pay swaps");
        assertEq(reader.budget(false, 1_000e6, fullBudget - 1), fullBudget - 1, "capped at the surplus");
        assertEq(reader.budget(false, 1_000e6, fullBudget / 2), 0, "cannot pay at the edge: scale");
    }

    /// @dev Sol's verification finding: Metric rounds a swap's input up twice, so a tiny deficit can cost a unit or
    /// two past the edge. The budget allows those units; a surplus that cannot cover them scales instead of waiting
    /// forever.
    function test_budget_allowsMetricsRoundingAndScalesBelowIt() public {
        uint256 costAtEdge = reader.edgeCostOfToken1(1);
        assertEq(reader.budget(false, 1, costAtEdge + 1), 0, "short of the rounding allowance: scale");
        // A thousandth of a base left over is worth keeping: the swap gets the allowance.
        uint256 allowedBudget = costAtEdge * 10_100 / 10_000 + 2;
        assertEq(reader.budget(false, 1, costAtEdge + 1e15), allowedBudget, "the edge, 1% and the allowance");
        assertGe(reader.budget(false, 1, type(uint256).max), costAtEdge + 2, "the allowance is in every budget");
    }

    /// @dev Audit finding W-3: a wait protects only what the trader would keep. Once the arrears the close collects,
    /// in the surplus token as the close takes them, reach what the surplus leaves after buying the deficit at the edge,
    /// scaling costs the trader nothing, so the budget is zero and the close scales rather than wait for the pool.
    function test_budget_scalesOnceArrearsTakeWhatTheTraderWouldKeep() public {
        uint256 atEdge = reader.edgeCostOfToken1(1_000e6);
        uint256 surplus = atEdge + 0.01e18;
        // The trader would keep 0.01 base.
        assertGt(reader.budgetWithArrears(false, 1_000e6, surplus, 0.009e18), 0, "keeps more than the arrears: swap");
        assertEq(reader.budgetWithArrears(false, 1_000e6, surplus, 0.01e18), 0, "arrears take it all: scale");
    }

    function test_budget_scalesADeficitMetricCannotSwap() public {
        uint256 deficitBeyondInt128 = uint256(uint128(type(int128).max)) + 1;
        uint256 budget = reader.budget(true, deficitBeyondInt128, type(uint256).max);
        assertEq(budget, 0, "beyond Metric's signed amount: scale");
    }

    /// @dev With the provider broken there is no band to budget against. This is the spec's exit without a price: the
    /// close scales rather than wait on a price that may never come back.
    function test_budget_scalesWithoutAPrice() public {
        provider.setBroken(true);
        assertEq(reader.budget(false, 1_000e6, 10e18), 0, "no price: scale");
    }
}
