// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MetricLendingVault} from "../../src/metric/vault/MetricLendingVault.sol";
import {LegRequest, MakerIncreaseRequest, MakerOpenRequest, MakerPosition} from "../../src/metric/vault/MakerTypes.sol";
import {IncreaseRequest, OpenRequest, Position} from "../../src/metric/vault/VaultTypes.sol";
import {IMetricLendingVault} from "../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {ISwapVenue} from "../../src/metric/vault/interfaces/ISwapVenue.sol";
import {VaultMath} from "../../src/metric/vault/libraries/VaultMath.sol";
import {VenueSwap} from "../../src/metric/vault/libraries/VenueSwap.sol";
import {MakerFixture} from "./utils/MakerFixture.sol";
import {RouteVenue} from "./utils/RouteVenue.sol";

/// @notice Tries to enter the vault again from inside the swap.
contract ReentrantVenue is ISwapVenue {
    MetricLendingVault internal immutable vault;
    uint256 internal immutable vaultId;

    constructor(MetricLendingVault vault_, uint256 vaultId_) {
        vault = vault_;
        vaultId = vaultId_;
    }

    function swapForVault(address, address, uint256, bytes calldata) external {
        vault.recenter(vaultId);
    }
}

/// @notice Tries to take more of the vault's tokens than it was sent.
contract PullingVenue is ISwapVenue {
    function swapForVault(address tokenIn, address, uint256, bytes calldata) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), 1);
    }
}

/// @notice Sends back one more unit of the input than it was sent, and nothing else.
contract OverpayingVenue is ISwapVenue {
    function swapForVault(address tokenIn, address, uint256 amountIn, bytes calldata) external {
        IERC20(tokenIn).transfer(msg.sender, amountIn + 1);
    }
}

/// @notice Entry swaps through a venue the trader names, on a vault without a pool, where the vault's own venue
/// cannot swap at all: the reserves move by what actually moved, any fill stands with its loss against the band
/// charged to the basis, and the venue can take nothing beyond its input.
contract EntryVenueTest is MakerFixture {
    uint256 internal constant NOTIONAL = 20_000e6;
    int24 internal constant LEVEL_BUY = -2_014;

    RouteVenue internal venue;

    function setUp() public override {
        super.setUp();
        venue = new RouteVenue();
        base.mint(address(venue), 1e30);
        quote.mint(address(venue), 1e30);
        deposit(lender, 200e18, 400_000e6);
    }

    // ---------------------------------------------------------------- prices

    /// @dev Token0 for `amount1` at the ask, rounded down: an honest buyer's fill at the band's edge.
    function _atAsk(uint256 amount1) internal view returns (uint256) {
        uint160 sqrtAskX96 = source.sqrtAskX96();
        return FullMath.mulDiv(FullMath.mulDiv(amount1, 1 << 96, sqrtAskX96), 1 << 96, sqrtAskX96);
    }

    /// @dev Token1 for `amount0` at the bid, rounded down: an honest seller's fill at the band's edge.
    function _atBid(uint256 amount0) internal view returns (uint256) {
        return VaultMath.priceTimes(amount0, source.sqrtBidX96(), false);
    }

    /// @dev What the vault charges to the basis for a fill, at the source's band now.
    function _lost(bool isLong, uint256 paid, uint256 received) internal view returns (uint256) {
        VenueSwap.Trade memory trade;
        trade.zeroForOne = !isLong;
        trade.sqrtBidX96 = source.sqrtBidX96();
        trade.sqrtAskX96 = source.sqrtAskX96();
        return VenueSwap.shortfall(trade, paid, received);
    }

    // ---------------------------------------------------------------- requests

    /// @dev A long one to two percent below the price: its release is all token1.
    function _longRequest(uint128 collateral) internal view returns (OpenRequest memory request) {
        int24 lower = PRICE_TICK - 200;
        int24 upper = PRICE_TICK - 100;
        request = openRequest(true, lower, upper, liquidityFor1(lower, upper, NOTIONAL), collateral);
    }

    /// @dev A short one to two percent above the price: its release is all token0.
    function _shortRequest(uint128 collateral) internal view returns (OpenRequest memory request) {
        int24 lower = PRICE_TICK + 100;
        int24 upper = PRICE_TICK + 200;
        request = openRequest(false, lower, upper, liquidityFor1(lower, upper, NOTIONAL), collateral);
    }

    function _release(OpenRequest memory request) internal view returns (uint256 release0, uint256 release1) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(request.tickLower, request.tickUpper);
        (release0, release1) = VaultMath.releaseAcrossBand(
            request.liquidity, sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96(), source.sqrtAskX96()
        );
    }

    function _route(OpenRequest memory request, address named, uint256 amountIn, uint256 spend, uint256 amountOut)
        internal
        pure
        returns (OpenRequest memory)
    {
        request.entryAmountIn = amountIn;
        request.entryVenue = named;
        request.entryRoute = abi.encode(spend, amountOut);
        return request;
    }

    function _expectRefused(OpenRequest memory request, bytes memory reason) internal {
        vm.prank(trader);
        vm.expectRevert(reason);
        vault.open(request);
    }

    // ---------------------------------------------------------------- passive opens

    /// @dev A vault without a pool could not swap at entry at all; through a named venue a long buys base with its
    /// release and collateral at the ask, and the reserves hold exactly what arrived.
    function test_open_longBuysBaseThroughANamedVenue() public {
        OpenRequest memory request = _longRequest(2_000e6);
        (, uint256 release1) = _release(request);
        uint256 amountIn = release1 + 2_000e6;
        uint256 amountOut = _atAsk(amountIn);
        _expectRefused(
            _route(_longRequest(2_000e6), address(0), amountIn, 0, 0),
            abi.encodeWithSelector(IMetricLendingVault.InvalidParameters.selector)
        );
        uint256 positionId = open(_route(request, address(venue), amountIn, amountIn, amountOut));
        Position memory position = vault.positionOf(positionId);
        assertEq(position.reserve0, amountOut, "the base the venue sent");
        assertEq(position.reserve1, 0, "every unit of token1 sold");
        assertEq(quote.balanceOf(address(venue)), 1e30 + amountIn, "the venue got exactly its input");
        assertLedger();
    }

    /// @dev A short sells its released base at the bid.
    function test_open_shortSellsBaseThroughANamedVenue() public {
        OpenRequest memory request = _shortRequest(2_000e6);
        (uint256 release0,) = _release(request);
        uint256 amountOut = _atBid(release0);
        uint256 positionId = open(_route(request, address(venue), release0, release0, amountOut));
        Position memory position = vault.positionOf(positionId);
        assertEq(position.reserve0, 0, "the release sold");
        assertEq(position.reserve1, 2_000e6 + amountOut, "collateral plus the token1 that arrived");
        assertLedger();
    }

    /// @dev A venue that spends only part of the input sends the rest back; the reserves pay only what it spent.
    function test_open_unspentInputComesBack() public {
        OpenRequest memory request = _longRequest(2_000e6);
        (, uint256 release1) = _release(request);
        uint256 amountIn = release1 + 2_000e6;
        uint256 spend = amountIn / 2;
        uint256 positionId = open(_route(request, address(venue), amountIn, spend, _atAsk(spend)));
        Position memory position = vault.positionOf(positionId);
        assertEq(position.reserve1, amountIn - spend, "the unspent half stays in the reserves");
        assertEq(position.reserve0, _atAsk(spend), "base for the spent half");
        assertLedger();
    }

    /// @dev Any fill stands. A fair one at the ask costs the basis only rounding; one returning half the base costs it
    /// exactly what the fill lost against the band, as if that much had been withdrawn: the profit share is then
    /// measured as if the swap had filled at the band.
    function test_open_poorFillIsChargedToTheBasis() public {
        OpenRequest memory request = _longRequest(30_000e6);
        (, uint256 release1) = _release(request);
        uint256 fair = _atAsk(release1);
        uint256 snapshot = vm.snapshotState();
        uint256 fairId = open(_route(request, address(venue), release1, release1, fair));
        assertLe(_lost(true, release1, fair), 2, "a fair fill loses only rounding");
        assertEq(vault.positionOf(fairId).basis, 30_000e6 + 100e6 - _lost(true, release1, fair));
        vm.revertToState(snapshot);
        uint256 poorId = open(_route(request, address(venue), release1, release1, fair / 2));
        uint256 lost = _lost(true, release1, fair / 2);
        assertApproxEqAbs(lost, release1 / 2, 2, "half the fill lost");
        assertEq(vault.positionOf(poorId).basis, 30_000e6 + 100e6 - lost, "charged to the basis");
        assertEq(vault.positionOf(poorId).reserve0, fair / 2, "the poor fill stands");
        assertLedger();
    }

    /// @dev The same for a short, whose base is valued at the bid.
    function test_open_poorShortFillIsChargedToTheBasis() public {
        OpenRequest memory request = _shortRequest(15_000e6);
        (uint256 release0,) = _release(request);
        uint256 poorOut = _atBid(release0) * 8 / 10;
        uint256 positionId = open(_route(request, address(venue), release0, release0, poorOut));
        uint256 lost = _lost(false, release0, poorOut);
        assertApproxEqAbs(lost, _atBid(release0) / 5, 2, "a fifth of the fill lost");
        assertEq(vault.positionOf(positionId).basis, 15_000e6 + 100e6 - lost);
        assertLedger();
    }

    /// @dev With a wide band (about ±1%), fills at the edge they cross cost the basis nothing beyond rounding: a long's
    /// base counts at the ask, a short's base at the bid, never the far edge, which would charge a fair fill the spread.
    function test_open_fairFillsAtAWideBandsEdgeCostNothing() public {
        setPrice(PRICE_TICK, 100);
        OpenRequest memory request = _longRequest(2_000e6);
        (, uint256 release1) = _release(request);
        uint256 amountIn = release1 + 2_000e6;
        uint256 longId = open(_route(request, address(venue), amountIn, amountIn, _atAsk(amountIn)));
        assertEq(vault.positionOf(longId).reserve0, _atAsk(amountIn), "a long filled at the ask");
        assertApproxEqAbs(vault.positionOf(longId).basis, 2_000e6 + 100e6, 2, "nothing charged");
        request = _shortRequest(2_000e6);
        (uint256 release0,) = _release(request);
        uint256 shortId = open(_route(request, address(venue), release0, release0, _atBid(release0)));
        assertEq(vault.positionOf(shortId).reserve1, 2_000e6 + _atBid(release0), "a short filled at the bid");
        assertApproxEqAbs(vault.positionOf(shortId).basis, 2_000e6 + 100e6, 2, "nothing charged");
        assertLedger();
    }

    /// @dev The trader's own minimum still applies to a named venue.
    function test_open_traderMinimumApplies() public {
        OpenRequest memory request = _longRequest(2_000e6);
        (, uint256 release1) = _release(request);
        uint256 amountIn = release1 + 2_000e6;
        uint256 amountOut = _atAsk(amountIn);
        request = _route(request, address(venue), amountIn, amountIn, amountOut);
        request.entryMinimumOut = amountOut + 1;
        _expectRefused(request, abi.encodeWithSelector(IMetricLendingVault.SlippageExceeded.selector));
    }

    /// @dev A venue may sell no more than the call brings in, as with the vault's own venue.
    function test_open_sellsNoMoreThanTheCallBringsIn() public {
        OpenRequest memory request = _longRequest(2_000e6);
        (, uint256 release1) = _release(request);
        uint256 amountIn = release1 + 2_000e6 + 1;
        _expectRefused(
            _route(request, address(venue), amountIn, amountIn, _atAsk(amountIn)),
            abi.encodeWithSelector(IMetricLendingVault.InvalidParameters.selector)
        );
    }

    // ---------------------------------------------------------------- what a venue cannot do

    function test_open_venueCannotReenterTheVault() public {
        ReentrantVenue reentrant = new ReentrantVenue(vault, vaultId);
        _expectRefused(
            _route(_longRequest(2_000e6), address(reentrant), 1_000e6, 0, 0),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
    }

    /// @dev The vault grants no allowance, so a venue can move only what it was sent.
    function test_open_venueHasNoAllowance() public {
        PullingVenue pulling = new PullingVenue();
        _expectRefused(
            _route(_longRequest(2_000e6), address(pulling), 1_000e6, 0, 0),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pulling), 0, 1)
        );
    }

    /// @dev Sending back more input than it was given would credit tokens to no one: refused.
    function test_open_venueSendingBackMoreThanItsInputIsRefused() public {
        OverpayingVenue overpaying = new OverpayingVenue();
        quote.mint(address(overpaying), 1);
        _expectRefused(_route(_longRequest(2_000e6), address(overpaying), 1_000e6, 0, 0), stdError.arithmeticError);
    }

    /// @dev The vault never calls its own tokens or itself on a trader's word.
    function test_open_venueMayNotBeTheVaultsTokensOrTheVault() public {
        address[3] memory forbidden = [address(base), address(quote), address(vault)];
        // three forbidden venues
        for (uint256 index = 0; index < 3; ++index) {
            _expectRefused(
                _route(_longRequest(2_000e6), forbidden[index], 1_000e6, 0, 0),
                abi.encodeWithSelector(IMetricLendingVault.InvalidParameters.selector)
            );
        }
    }

    // ---------------------------------------------------------------- increases

    /// @dev Why the charge exists. A long with 30,000 of spare token1 has chord room for another 20,000 borrow. An
    /// increase that sends its whole release to a venue of the trader's own, which returns one unit, leaves the combined
    /// position solvent: it takes collateral, and with it any profit, out of the reserves. It goes through, but the
    /// basis falls by what left, so a later close measures the share as if the release had filled at the band.
    function test_increase_drainCountsAsAWithdrawal() public {
        OpenRequest memory request = _longRequest(30_000e6);
        uint256 amountIn = 20_000e6;
        uint256 positionId = open(_route(request, address(venue), amountIn, amountIn, _atAsk(amountIn)));
        setPrice(PRICE_TICK + 1_823, 1);
        IncreaseRequest memory increase = _increaseRequest(positionId);
        (, uint256 release1) = _release(request);
        increase.entryAmountIn = release1;
        increase.entryVenue = address(venue);
        increase.entryRoute = abi.encode(release1, uint256(1));
        Position memory before = vault.positionOf(positionId);
        vm.prank(trader);
        vault.increase(increase);
        Position memory drained = vault.positionOf(positionId);
        uint256 lost = _lost(true, release1, 1);
        assertApproxEqAbs(lost, release1, 1, "the whole release left");
        assertEq(drained.reserve0, before.reserve0 + 1, "one unit came back");
        assertEq(drained.basis, before.basis + 100e6 - lost, "the basis lost what left");
        assertLedger();
    }

    function _increaseRequest(uint256 positionId) internal view returns (IncreaseRequest memory increase) {
        Position memory position = vault.positionOf(positionId);
        increase.positionId = positionId;
        increase.liquidity = position.liquidity;
        increase.escrow = 100e6;
    }

    // ---------------------------------------------------------------- maker book

    function _makerLong(uint256 bucketId, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (MakerOpenRequest memory request)
    {
        request = makerRequest(true, single(bucketId), single128(liquidityOn(LEVEL_BUY, 10_000e6)), 1_000e6);
        request.entryAmountIn = amountIn;
        request.entryVenue = address(venue);
        request.entryRoute = abi.encode(amountIn, amountOut);
    }

    /// @dev A maker long buys base through a named venue, and a later increase's poor fill is charged to its basis.
    function test_maker_openAndIncreaseThroughANamedVenue() public {
        (uint256 bucketId,) = depositBuy(makerA, LEVEL_BUY, 100_000e6);
        uint256 positionId = openMaker(_makerLong(bucketId, 5_000e6, _atAsk(5_000e6)));
        MakerPosition memory position = vault.makerPositionOf(positionId);
        assertEq(position.reserve0, _atAsk(5_000e6), "the base the venue sent");
        MakerIncreaseRequest memory increase;
        increase.positionId = positionId;
        increase.legs = new LegRequest[](1);
        increase.legs[0] = LegRequest({bucketId: bucketId, liquidity: liquidityOn(LEVEL_BUY, 10_000e6)});
        increase.collateral = 1_000e6;
        increase.escrow = 2_000e6;
        increase.maximumRateBps = type(uint256).max;
        increase.entryAmountIn = 5_000e6;
        increase.entryVenue = address(venue);
        uint256 poorOut = _atAsk(5_000e6) * 9_800 / 10_000;
        increase.entryRoute = abi.encode(uint256(5_000e6), poorOut);
        uint256 basisBefore = position.basis;
        vm.prank(trader);
        vault.increaseMaker(increase);
        MakerPosition memory increased = vault.makerPositionOf(positionId);
        assertEq(increased.reserve0, _atAsk(5_000e6) + poorOut, "both fills arrived");
        uint256 lost = _lost(true, 5_000e6, poorOut);
        assertApproxEqAbs(lost, 100e6, 2, "2% of 5,000 lost");
        assertEq(increased.basis, basisBefore + 1_000e6 + 2_000e6 - lost, "charged to the basis");
        assertLedger();
    }
}
