// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ExitSwap, OpenRequest, Position} from "../../src/metric/vault/VaultTypes.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {RouterVenue} from "../../src/metric/vault/venues/RouterVenue.sol";
import {TestToken, VaultFixture} from "./utils/VaultFixture.sol";

/// @notice An aggregator-shaped router: pulls the input from its caller on an approval and pays the output to the
/// recipient its calldata names, from its own inventory.
contract MockAggregator {
    error Refused();

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(recipient, amountOut);
    }

    function refuse() external pure {
        revert Refused();
    }
}

/// @notice Pulls on an aggregator's behalf, as 0x's allowance holder or ParaSwap's transfer proxy does.
contract MockTransferProxy {
    function pull(address token, address from, address to, uint256 amount) external {
        IERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice An aggregator whose approval is taken by a separate proxy.
contract MockProxiedAggregator {
    MockTransferProxy public immutable proxy = new MockTransferProxy();

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        proxy.pull(tokenIn, msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(recipient, amountOut);
    }
}

/// @notice The production venue for aggregators and routers, used as a trader and a lender would: the route is a script
/// of approvals and calls (one aggregator call, a multi-hop route, a split), the swap lands in the vault, and the venue
/// keeps nothing and no allowance.
contract RouterVenueTest is VaultFixture {
    uint256 internal constant NOTIONAL = 20_000e6;

    RouterVenue internal routerVenue;
    MockAggregator internal aggregator;

    function setUp() public override {
        super.setUp();
        routerVenue = new RouterVenue();
        aggregator = new MockAggregator();
        base.mint(address(aggregator), 1e30);
        quote.mint(address(aggregator), 1e30);
        deposit(lender, 200e18, 400_000e6);
    }

    // ---------------------------------------------------------------- helpers

    function _atAsk(uint256 amount1) internal view returns (uint256) {
        uint160 sqrtAskX96 = source.sqrtAskX96();
        return FullMath.mulDiv(FullMath.mulDiv(amount1, 1 << 96, sqrtAskX96), 1 << 96, sqrtAskX96);
    }

    function _swapCall(
        address target,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to
    ) internal pure returns (RouterVenue.Call memory) {
        return RouterVenue.Call({
            target: target, data: abi.encodeCall(MockAggregator.swap, (tokenIn, tokenOut, amountIn, amountOut, to))
        });
    }

    /// @dev One approval and one call, as an aggregator's API returns: token1 `amountIn` → base `amountOut`.
    function _route(address spender, address target, uint256 amountIn, uint256 amountOut, address recipient)
        internal
        view
        returns (bytes memory)
    {
        RouterVenue.Route memory script;
        script.approvals = new RouterVenue.Approval[](1);
        script.approvals[0] = RouterVenue.Approval({token: address(quote), spender: spender, amount: amountIn});
        script.calls = new RouterVenue.Call[](1);
        script.calls[0] = _swapCall(target, address(quote), address(base), amountIn, amountOut, recipient);
        return abi.encode(script);
    }

    /// @dev A long below the price, selling `amountIn` of its release and collateral through the router venue.
    function _openLong(uint256 amountIn, bytes memory route) internal returns (uint256 positionId) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, NOTIONAL), 2_000e6);
        request.entryAmountIn = amountIn;
        request.entryVenue = address(routerVenue);
        request.entryRoute = route;
        positionId = open(request);
    }

    function _assertVenueEmpty() internal view {
        assertEq(base.balanceOf(address(routerVenue)), 0, "keeps no base");
        assertEq(quote.balanceOf(address(routerVenue)), 0, "keeps no token1");
        assertEq(quote.allowance(address(routerVenue), address(aggregator)), 0, "no allowance left");
    }

    // ---------------------------------------------------------------- one aggregator call

    function test_routerVenue_opensThroughAnAggregator() public {
        uint256 amountIn = 15_000e6;
        uint256 amountOut = _atAsk(amountIn);
        bytes memory route = _route(address(aggregator), address(aggregator), amountIn, amountOut, address(routerVenue));
        uint256 positionId = _openLong(amountIn, route);
        assertEq(vault.positionOf(positionId).reserve0, amountOut, "the aggregator's base");
        _assertVenueEmpty();
        assertLedger();
    }

    /// @dev An aggregator that spends less than it is given: the rest comes back to the reserves.
    function test_routerVenue_unspentInputComesBack() public {
        uint256 spent = 7_500e6;
        bytes memory route =
            _route(address(aggregator), address(aggregator), spent, _atAsk(spent), address(routerVenue));
        uint256 positionId = _openLong(15_000e6, route);
        Position memory position = vault.positionOf(positionId);
        assertEq(position.reserve0, _atAsk(spent));
        assertGt(position.reserve1, 0, "the unspent token1 stays in the reserves");
        _assertVenueEmpty();
        assertLedger();
    }

    /// @dev An aggregator may pay the vault directly; the vault counts what reaches it either way.
    function test_routerVenue_aggregatorPaysTheVaultDirectly() public {
        uint256 amountIn = 15_000e6;
        uint256 amountOut = _atAsk(amountIn);
        bytes memory route = _route(address(aggregator), address(aggregator), amountIn, amountOut, address(vault));
        uint256 positionId = _openLong(amountIn, route);
        assertEq(vault.positionOf(positionId).reserve0, amountOut);
        _assertVenueEmpty();
        assertLedger();
    }

    /// @dev An aggregator whose approval is taken by a separate proxy.
    function test_routerVenue_separateSpender() public {
        MockProxiedAggregator proxied = new MockProxiedAggregator();
        base.mint(address(proxied), 1e30);
        uint256 amountIn = 15_000e6;
        uint256 amountOut = _atAsk(amountIn);
        bytes memory route =
            _route(address(proxied.proxy()), address(proxied), amountIn, amountOut, address(routerVenue));
        uint256 positionId = _openLong(amountIn, route);
        assertEq(vault.positionOf(positionId).reserve0, amountOut);
        assertEq(quote.allowance(address(routerVenue), address(proxied.proxy())), 0, "no allowance left");
        assertLedger();
    }

    /// @dev A router's revert reaches the caller, and nothing moves.
    function test_routerVenue_routerRevertBubbles() public {
        RouterVenue.Route memory script;
        script.calls = new RouterVenue.Call[](1);
        script.calls[0] =
            RouterVenue.Call({target: address(aggregator), data: abi.encodeCall(MockAggregator.refuse, ())});
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        OpenRequest memory request = openRequest(true, lower, upper, liquidityFor1(lower, upper, NOTIONAL), 2_000e6);
        request.entryAmountIn = 15_000e6;
        request.entryVenue = address(routerVenue);
        request.entryRoute = abi.encode(script);
        vm.prank(trader);
        vm.expectRevert(MockAggregator.Refused.selector);
        vault.open(request);
    }

    /// @dev A lender leaves with only token1, selling the payout's base through the aggregator.
    function test_routerVenue_withdrawalPayout() public {
        uint256 shares = vault.sharesOf(vaultId, lender) / 2;
        uint256 snapshot = vm.snapshotState();
        vm.prank(lender);
        (uint256 payout0,,) = vault.withdraw(vaultId, shares, 0, 0, lender);
        vm.revertToState(snapshot);
        uint256 amountOut = VaultMath.priceTimes(payout0, source.sqrtBidX96(), false);
        RouterVenue.Route memory script;
        script.approvals = new RouterVenue.Approval[](1);
        script.approvals[0] =
            RouterVenue.Approval({token: address(base), spender: address(aggregator), amount: payout0});
        script.calls = new RouterVenue.Call[](1);
        script.calls[0] =
            _swapCall(address(aggregator), address(base), address(quote), payout0, amountOut, address(routerVenue));
        ExitSwap memory swap = ExitSwap({
            zeroForOne: true,
            amountIn: payout0,
            minimumOut: amountOut,
            venue: address(routerVenue),
            route: abi.encode(script)
        });
        vm.prank(lender);
        (uint256 amount0,,) = vault.withdrawAfterSwap(vaultId, shares, 0, 0, lender, swap);
        assertEq(amount0, 0, "no base out");
        assertEq(base.allowance(address(routerVenue), address(aggregator)), 0, "no allowance left");
        assertLedger();
    }

    /// @dev Anyone may use the venue directly; they get back exactly what their own swap produced.
    function test_routerVenue_strangerGetsOnlyTheirOwnSwap() public {
        address stranger = makeAddr("stranger");
        quote.mint(stranger, 1_000e6);
        uint256 amountOut = _atAsk(1_000e6);
        bytes memory route = _route(address(aggregator), address(aggregator), 1_000e6, amountOut, address(routerVenue));
        vm.startPrank(stranger);
        quote.transfer(address(routerVenue), 1_000e6);
        routerVenue.swapForVault(address(quote), address(base), 1_000e6, route);
        vm.stopPrank();
        assertEq(base.balanceOf(stranger), amountOut);
        _assertVenueEmpty();
    }

    // ---------------------------------------------------------------- scripted routes

    /// @dev A two-hop route through a third token on two aggregators: token1 → MID on the first, MID → base on the
    /// second, the second approved for MID without knowing the amount in advance. The MID the second hop leaves is
    /// refunded to the trader, not stranded in the vault.
    function test_routerVenue_multiHopThroughAnotherToken() public {
        TestToken mid = new TestToken("MID", 18);
        MockAggregator second = new MockAggregator();
        mid.mint(address(aggregator), 1e30);
        base.mint(address(second), 1e30);
        uint256 amountIn = 15_000e6;
        uint256 midOut = 15_000e18;
        uint256 dust = 3;
        uint256 amountOut = _atAsk(amountIn);
        RouterVenue.Route memory script;
        script.approvals = new RouterVenue.Approval[](2);
        script.approvals[0] =
            RouterVenue.Approval({token: address(quote), spender: address(aggregator), amount: amountIn});
        script.approvals[1] =
            RouterVenue.Approval({token: address(mid), spender: address(second), amount: type(uint256).max});
        script.calls = new RouterVenue.Call[](2);
        script.calls[0] =
            _swapCall(address(aggregator), address(quote), address(mid), amountIn, midOut, address(routerVenue));
        script.calls[1] =
            _swapCall(address(second), address(mid), address(base), midOut - dust, amountOut, address(routerVenue));
        script.sweep = new address[](1);
        script.sweep[0] = address(mid);
        script.refund = trader;
        uint256 positionId = _openLong(amountIn, abi.encode(script));
        assertEq(vault.positionOf(positionId).reserve0, amountOut, "base at the end of two hops");
        assertEq(mid.balanceOf(trader), dust, "the hop's dust refunded to the trader");
        assertEq(mid.balanceOf(address(vault)), 0, "nothing stranded in the vault");
        assertEq(mid.allowance(address(routerVenue), address(second)), 0, "the open-ended approval revoked");
        _assertVenueEmpty();
        assertLedger();
    }

    /// @dev A split: two thirds through one aggregator, the rest through another, both paying the vault.
    function test_routerVenue_splitAcrossTwoAggregators() public {
        MockAggregator second = new MockAggregator();
        base.mint(address(second), 1e30);
        uint256 firstIn = 10_000e6;
        uint256 secondIn = 5_000e6;
        RouterVenue.Route memory script;
        script.approvals = new RouterVenue.Approval[](2);
        script.approvals[0] =
            RouterVenue.Approval({token: address(quote), spender: address(aggregator), amount: firstIn});
        script.approvals[1] = RouterVenue.Approval({token: address(quote), spender: address(second), amount: secondIn});
        script.calls = new RouterVenue.Call[](2);
        script.calls[0] =
            _swapCall(address(aggregator), address(quote), address(base), firstIn, _atAsk(firstIn), address(vault));
        script.calls[1] =
            _swapCall(address(second), address(quote), address(base), secondIn, _atAsk(secondIn), address(vault));
        uint256 positionId = _openLong(firstIn + secondIn, abi.encode(script));
        assertEq(vault.positionOf(positionId).reserve0, _atAsk(firstIn) + _atAsk(secondIn), "both legs arrived");
        assertEq(quote.allowance(address(routerVenue), address(second)), 0, "no allowance left");
        _assertVenueEmpty();
        assertLedger();
    }

    /// @dev Every loop over a route is bounded.
    function test_routerVenue_boundsTheScript() public {
        RouterVenue.Route memory script;
        script.calls = new RouterVenue.Call[](routerVenue.MAX_STEPS() + 1);
        vm.expectRevert(RouterVenue.TooManySteps.selector);
        routerVenue.swapForVault(address(quote), address(base), 0, abi.encode(script));
    }
}
