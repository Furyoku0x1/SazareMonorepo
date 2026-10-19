// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MetricLendingVault} from "../../../src/metric/vault/MetricLendingVault.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {
    CloseRequest,
    ExitSwap,
    IncreaseRequest,
    Ledger,
    OpenRequest,
    Position
} from "../../../src/metric/vault/VaultTypes.sol";
import {IMetricLendingVault} from "../../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {DebtTotals, VaultMath} from "../../../src/metric/vault/libraries/VaultMath.sol";
import {VenueSwap} from "../../../src/metric/vault/libraries/VenueSwap.sol";
import {RouteVenue, VenueRoutes} from "../utils/RouteVenue.sol";
import {MockPriceSource, TestToken, VaultFixture} from "../utils/VaultFixture.sol";

/// @notice The actions of the vault's invariant test, on two vaults of one singleton that share the quote token.
/// @dev The fuzzer calls the `act*` functions in random order with random inputs. Every vault call is wrapped in
/// try/catch, so no action reverts the run. A revert whose error the action does not expect, or an action on one vault
/// that changes the other vault's books, adds to `violations`; the invariant test requires none. Both vaults read the
/// fixture's single price source, so one random walk moves both.
contract VaultHandler is VaultFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant VAULT_COUNT = 2;
    uint256 internal constant LENDER_COUNT = 3;
    uint256 internal constant TRADER_COUNT = 2;
    /// @dev The walk stays within about 20% of the start, so every range below stays far inside the tick bounds.
    int256 internal constant MAX_PRICE_DRIFT_TICKS = 2_000;
    /// @dev About 3% a step.
    int256 internal constant MAX_PRICE_STEP_TICKS = 300;
    uint256 internal constant MAX_WARP_SECONDS = 10 days;
    /// @dev Just above the vault's 100e6 minimum, which `liquidityFor1` can round under.
    uint256 internal constant MIN_NOTIONAL = 101e6;
    uint256 internal constant MAX_NOTIONAL = 50_000e6;
    /// @dev `VaultLending`'s virtual shares and value, to price burned shares exactly as a withdrawal does.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_VALUE = 1;
    /// @dev A withdrawal's amounts and value each round down by a unit or two; a burn worth more than the delivered
    /// value by more than this overcharges the withdrawer.
    uint256 internal constant WITHDRAW_ROUNDING = 4;

    TestToken internal secondBase;
    RouteVenue internal venue;
    uint256[VAULT_COUNT] public vaultIds;
    address[LENDER_COUNT] public lenders;
    address[TRADER_COUNT] internal traders;
    /// @dev Every position ever opened; closed ones read back with no owner.
    uint256[] public positionIds;
    int24 public priceTick;
    int24 public spreadTicks;

    uint256 public violations;
    string public lastViolation;

    /// @dev Successful actions, to show the run reaches every path.
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public opens;
    uint256 public escrowTopUps;
    uint256 public collateralTopUps;
    uint256 public fullCloses;
    uint256 public partialCloses;
    uint256 public settlements;
    uint256 public flags;
    uint256 public forceCloses;
    uint256 public protocolPayments;
    uint256 public increases;
    uint256 public venueOpens;
    uint256 public venueCloses;

    constructor(
        MetricLendingVault sharedVault,
        TestToken firstBase,
        TestToken secondBase_,
        TestToken sharedQuote,
        MockPriceSource sharedSource,
        uint256 firstVaultId,
        uint256 secondVaultId
    ) {
        vault = sharedVault;
        base = firstBase;
        secondBase = secondBase_;
        quote = sharedQuote;
        source = sharedSource;
        vaultId = firstVaultId;
        vaultIds = [firstVaultId, secondVaultId];
        priceTick = PRICE_TICK;
        spreadTicks = 1;
        venue = new RouteVenue();
        firstBase.mint(address(venue), 1e30);
        secondBase_.mint(address(venue), 1e30);
        sharedQuote.mint(address(venue), 1e30);
        // LENDER_COUNT and TRADER_COUNT actors
        for (uint256 index = 0; index < LENDER_COUNT; ++index) {
            lenders[index] = makeAddr(string.concat("lender", vm.toString(index)));
            _fundActor(lenders[index]);
        }
        for (uint256 index = 0; index < TRADER_COUNT; ++index) {
            traders[index] = makeAddr(string.concat("trader", vm.toString(index)));
            _fundActor(traders[index]);
        }
    }

    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    // ---------------------------------------------------------------- lenders

    function actDeposit(uint256 actorChoice, uint256 amount0, uint256 amount1) external {
        uint256 someVaultId = vaultIds[actorChoice % VAULT_COUNT];
        address someLender = lenders[(actorChoice / VAULT_COUNT) % LENDER_COUNT];
        amount0 = bound(amount0, 0, 250e18);
        amount1 = bound(amount1, 0, 500_000e6);
        // A dust deposit mints no shares and reverts by design; keep every deposit worth at least one quote unit.
        if (amount1 < 1e6) amount1 = 1e6;
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(someLender);
        try vault.deposit(someVaultId, amount0, amount1, 0, someLender) {
            ++deposits;
        } catch (bytes memory reason) {
            _expect(reason, "deposit", 0, 0, 0);
        }
        _checkIsolation(before, someVaultId);
    }

    /// @dev Checks the burn against what the withdrawal delivers: never less than its value (the lenders who stay are
    /// not diluted), and never more than its value plus rounding (the withdrawer is not overcharged).
    function actWithdraw(uint256 actorChoice, uint256 fractionWad) external {
        uint256 someVaultId = vaultIds[actorChoice % VAULT_COUNT];
        address someLender = lenders[(actorChoice / VAULT_COUNT) % LENDER_COUNT];
        uint256 shares = vault.sharesOf(someVaultId, someLender) * bound(fractionWad, 0.01e18, WAD) / WAD;
        if (shares == 0) return;
        bytes32[VAULT_COUNT] memory before = _snapshot();
        // For a vault without a pool, recenter only checkpoints; the withdrawal then sees exactly the state priced here.
        vault.recenter(someVaultId);
        uint160 sqrtBidX96 = source.sqrtBidX96();
        uint256 sharePriceNumerator = _valueLow(someVaultId, sqrtBidX96) + VIRTUAL_VALUE;
        uint256 sharePriceDenominator = vault.totalSharesOf(someVaultId) + VIRTUAL_SHARES;
        vm.prank(someLender);
        try vault.withdraw(someVaultId, shares, 0, 0, someLender) returns (
            uint256 amount0, uint256 amount1, uint256 burned
        ) {
            ++withdrawals;
            uint256 burnedValue = FullMath.mulDiv(burned, sharePriceNumerator, sharePriceDenominator);
            uint256 deliveredValue = VaultMath.valueInToken1(amount0, amount1, sqrtBidX96, false);
            if (deliveredValue > burnedValue + 1) _violate("withdraw delivered more than the burned shares' value");
            if (burnedValue > deliveredValue + WITHDRAW_ROUNDING) _violate("withdraw burned more than it delivered");
        } catch (bytes memory reason) {
            // A fully lent vault has no idle to pay, and a sliver of shares can claim nothing.
            _expect(
                reason,
                "withdraw",
                IMetricLendingVault.InsufficientIdle.selector,
                IMetricLendingVault.ZeroAmount.selector,
                0
            );
        }
        _checkIsolation(before, someVaultId);
    }

    function actPayProtocol(uint256 vaultChoice) external {
        uint256 someVaultId = vaultIds[vaultChoice % VAULT_COUNT];
        bytes32[VAULT_COUNT] memory before = _snapshot();
        try vault.payProtocol(someVaultId) {
            ++protocolPayments;
        } catch (bytes memory reason) {
            _expect(reason, "payProtocol", 0, 0, 0);
        }
        _checkIsolation(before, someVaultId);
    }

    // ---------------------------------------------------------------- opening

    /// @dev A long borrows a range entirely below the bid, so its release is all token1.
    function actOpenLong(
        uint256 actorChoice,
        uint256 distanceTicks,
        uint256 widthTicks,
        uint256 notional,
        uint256 collateralChoice,
        uint256 escrowChoice
    ) external {
        int24 tickUpper = priceTick - spreadTicks - _ticks(distanceTicks, 0, 1_500);
        int24 tickLower = tickUpper - _ticks(widthTicks, 1, 2_000);
        _open(
            true,
            actorChoice,
            tickLower,
            tickUpper,
            bound(notional, MIN_NOTIONAL, MAX_NOTIONAL),
            collateralChoice,
            escrowChoice
        );
    }

    /// @dev A short borrows a range entirely above the ask, so its release is all token0.
    function actOpenShort(
        uint256 actorChoice,
        uint256 distanceTicks,
        uint256 widthTicks,
        uint256 notional,
        uint256 collateralChoice,
        uint256 escrowChoice
    ) external {
        int24 tickLower = priceTick + spreadTicks + _ticks(distanceTicks, 0, 1_500);
        int24 tickUpper = tickLower + _ticks(widthTicks, 1, 2_000);
        _open(
            false,
            actorChoice,
            tickLower,
            tickUpper,
            bound(notional, MIN_NOTIONAL, MAX_NOTIONAL),
            collateralChoice,
            escrowChoice
        );
    }

    /// @dev An open whose entry swap goes through a venue the trader names: part or all of what the open adds is
    /// sold, part or all of that spent, at a fair fill or a poor one. Any fill stands, and the basis must be the
    /// collateral and escrow less exactly what the fill lost against the band.
    function actOpenThroughVenue(
        uint256 actorChoice,
        bool isLong,
        uint256 distanceTicks,
        uint256 notional,
        uint256 collateralChoice,
        uint256 swapChoice
    ) external {
        (int24 tickLower, int24 tickUpper) = _venueRange(isLong, distanceTicks);
        notional = bound(notional, MIN_NOTIONAL, MAX_NOTIONAL);
        OpenRequest memory request =
            _openTerms(isLong, actorChoice, tickLower, tickUpper, notional, collateralChoice, 2 + 3 * 50e6);
        uint256 lost = _routeThroughVenue(request, swapChoice);
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(traders[(actorChoice / VAULT_COUNT) % TRADER_COUNT]);
        try vault.open(request) returns (uint256 positionId) {
            positionIds.push(positionId);
            ++venueOpens;
            uint256 paidIn = uint256(request.collateral) + request.escrow;
            if (vault.positionOf(positionId).basis + lost != paidIn) {
                _violate("a venue fill's loss not charged exactly");
            }
        } catch (bytes memory reason) {
            // The fill is at the band's edge or worse, not the strike, so it can leave the reserves under the chord.
            _expect(
                reason,
                "open through a venue",
                IMetricLendingVault.UtilizationCeiling.selector,
                IMetricLendingVault.InsufficientIdle.selector,
                IMetricLendingVault.Insolvent.selector
            );
        }
        _checkIsolation(before, request.vaultId);
    }

    // ---------------------------------------------------------------- open positions

    function actAddEscrow(uint256 positionChoice, uint256 amount) external {
        (bool found, uint256 positionId, Position memory position) = _pick(positionChoice);
        if (!found) return;
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(position.owner);
        try vault.addEscrow(positionId, bound(amount, 1, 50e6)) {
            ++escrowTopUps;
        } catch (bytes memory reason) {
            _expect(reason, "addEscrow", 0, 0, 0);
        }
        _checkIsolation(before, position.vaultId);
    }

    /// @dev Adds liquidity with the collateral an open of the added size alone would need; refused only for idle,
    /// the ceiling, or premium owed.
    function actIncrease(uint256 positionChoice, uint256 notional, uint256 collateralChoice, uint256 escrowChoice)
        external
    {
        (bool found, uint256 positionId, Position memory position) = _pick(positionChoice);
        if (!found) return;
        notional = bound(notional, MIN_NOTIONAL, MAX_NOTIONAL);
        IncreaseRequest memory request;
        request.positionId = positionId;
        request.liquidity = liquidityFor1(position.tickLower, position.tickUpper, notional);
        request.collateral =
            uint128(_collateral(position.tickLower, position.tickUpper, request.liquidity, notional, collateralChoice));
        request.escrow = uint128(_escrow(escrowChoice));
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(position.owner);
        try vault.increase(request) {
            ++increases;
        } catch (bytes memory reason) {
            _expect(
                reason,
                "increase",
                IMetricLendingVault.UtilizationCeiling.selector,
                IMetricLendingVault.InsufficientIdle.selector,
                IMetricLendingVault.PremiumUnpaid.selector
            );
        }
        _checkIsolation(before, position.vaultId);
    }

    function actAddCollateral(uint256 positionChoice, uint256 amount) external {
        (bool found, uint256 positionId, Position memory position) = _pick(positionChoice);
        if (!found) return;
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(position.owner);
        try vault.addCollateral(positionId, bound(amount, 1, 1_000e6)) {
            ++collateralTopUps;
        } catch (bytes memory reason) {
            _expect(reason, "addCollateral", 0, 0, 0);
        }
        _checkIsolation(before, position.vaultId);
    }

    /// @dev A full close by the owner, with a repayment the reserves can pay, never needs a price and must succeed.
    function actCloseFull(uint256 positionChoice) external {
        (bool found, uint256 positionId, Position memory position) = _pick(positionChoice);
        if (!found) return;
        (uint256 repay0, uint256 repay1) = repaymentFor(positionId, WAD);
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(position.owner);
        try vault.close(CloseRequest({positionId: positionId, fractionWad: WAD, repay0: repay0, repay1: repay1})) {
            ++fullCloses;
        } catch (bytes memory reason) {
            _expect(reason, "full close", 0, 0, 0);
        }
        _checkIsolation(before, position.vaultId);
    }

    /// @dev A full close that first sells part of its token0 through the venue, at a fair or a poor fill, then repays
    /// with everything the reserves hold after it. Refused only when a poor fill leaves too little to repay.
    function actCloseThroughVenue(uint256 positionChoice, uint256 swapChoice) external {
        (bool found, uint256 positionId, Position memory position) = _pick(positionChoice);
        if (!found) return;
        if (position.reserve0 == 0) return;
        VenueRoutes.Route memory chosen =
            VenueRoutes.route(false, position.reserve0, swapChoice, source.sqrtBidX96(), source.sqrtAskX96());
        ExitSwap memory exit = ExitSwap({
            zeroForOne: true, amountIn: chosen.amountIn, minimumOut: 0, venue: address(venue), route: chosen.data
        });
        CloseRequest memory request = CloseRequest({
            positionId: positionId,
            fractionWad: WAD,
            repay0: position.reserve0 - chosen.spend,
            repay1: position.reserve1 + chosen.amountOut
        });
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(position.owner);
        try vault.closeAfterSwap(request, exit) {
            ++venueCloses;
        } catch (bytes memory reason) {
            _expect(reason, "close through a venue", IMetricLendingVault.RepaymentShort.selector, 0, 0);
        }
        _checkIsolation(before, position.vaultId);
    }

    /// @dev A partial close may be refused when it cannot pay all arrears from the closed part, or would leave the
    /// rest below the minimum borrow or the chord; nothing else.
    function actClosePartial(uint256 positionChoice, uint256 fractionWad) external {
        (bool found, uint256 positionId, Position memory position) = _pick(positionChoice);
        if (!found) return;
        fractionWad = bound(fractionWad, 0.05e18, 0.95e18);
        (uint256 repay0, uint256 repay1) = repaymentFor(positionId, fractionWad);
        // The closed part of a barely solvent position can round below the rule; such a close cannot be made.
        if (repay1 > VaultMath.portionDown(position.reserve1, fractionWad)) return;
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(position.owner);
        try vault.close(
            CloseRequest({positionId: positionId, fractionWad: fractionWad, repay0: repay0, repay1: repay1})
        ) {
            ++partialCloses;
        } catch (bytes memory reason) {
            _expect(
                reason,
                "partial close",
                IMetricLendingVault.PremiumUnpaid.selector,
                IMetricLendingVault.BelowMinimumBorrow.selector,
                IMetricLendingVault.Insolvent.selector
            );
        }
        _checkIsolation(before, position.vaultId);
    }

    function actSettle(uint256 positionChoice) external {
        (bool found, uint256 positionId, Position memory position) = _pick(positionChoice);
        if (!found) return;
        bytes32[VAULT_COUNT] memory before = _snapshot();
        try vault.settle(positionId) returns (bool settled) {
            if (settled) ++settlements;
        } catch (bytes memory reason) {
            _expect(reason, "settle", 0, 0, 0);
        }
        _checkIsolation(before, position.vaultId);
    }

    function actFlag(uint256 positionChoice) external {
        _flagFirstDelinquent(positionChoice);
    }

    /// @dev Force closes the first flagged position at or after `choice` as a keeper would: flagging a delinquent one
    /// first if none is flagged, and waiting out the grace period if it is still running. The position may have
    /// recovered since the flag, and then it is not delinquent; nothing else may
    /// stop it.
    function actForceClose(uint256 positionChoice) external {
        (bool found, uint256 positionId, Position memory position) = _pickFlagged(positionChoice);
        if (!found) (found, positionId) = _flagFirstDelinquent(positionChoice);
        if (!found) return;
        position = vault.positionOf(positionId);
        uint256 graceEnd = uint256(position.delinquentSince) + vault.parametersOf(position.vaultId).graceSeconds;
        if (block.timestamp < graceEnd) vm.warp(graceEnd);
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(closer);
        try vault.forceClose(positionId) returns (uint256 reward0, uint256 reward1) {
            ++forceCloses;
            _checkReward(position, reward0, reward1);
        } catch (bytes memory reason) {
            _expect(reason, "force close", IMetricLendingVault.NotDelinquent.selector, 0, 0);
        }
        _checkIsolation(before, position.vaultId);
    }

    // ---------------------------------------------------------------- environment

    function actWarp(uint256 elapsedSeconds) external {
        vm.warp(block.timestamp + bound(elapsedSeconds, 1, MAX_WARP_SECONDS));
    }

    /// @dev A bounded random walk; the band stays one or two ticks each side of the price.
    function actMovePrice(int256 stepTicks, uint256 spreadChoice) external {
        int256 next = int256(priceTick) + bound(stepTicks, -MAX_PRICE_STEP_TICKS, MAX_PRICE_STEP_TICKS);
        int256 lowest = int256(PRICE_TICK) - MAX_PRICE_DRIFT_TICKS;
        int256 highest = int256(PRICE_TICK) + MAX_PRICE_DRIFT_TICKS;
        if (next < lowest) next = lowest;
        if (next > highest) next = highest;
        priceTick = int24(next);
        spreadTicks = int24(int256(1 + spreadChoice % 2));
        setPrice(priceTick, spreadTicks);
    }

    // ---------------------------------------------------------------- internal

    function _open(
        bool isLong,
        uint256 actorChoice,
        int24 tickLower,
        int24 tickUpper,
        uint256 notional,
        uint256 collateralChoice,
        uint256 escrowChoice
    ) private {
        OpenRequest memory request = _openTerms(
            isLong, actorChoice, tickLower, tickUpper, notional, collateralChoice, escrowChoice
        );
        bytes32[VAULT_COUNT] memory before = _snapshot();
        vm.prank(traders[(actorChoice / VAULT_COUNT) % TRADER_COUNT]);
        try vault.open(request) returns (uint256 positionId) {
            positionIds.push(positionId);
            ++opens;
        } catch (bytes memory reason) {
            // Lenders may not have the idle capital, or the open would pass the utilization ceiling. The collateral
            // always covers the chord, so Insolvent would be a bug.
            _expect(
                reason,
                "open",
                IMetricLendingVault.UtilizationCeiling.selector,
                IMetricLendingVault.InsufficientIdle.selector,
                0
            );
        }
        _checkIsolation(before, request.vaultId);
    }

    /// @dev A third of opens are barely solvent (at most three units over the chord), a third carry 0.1% to 2% of the
    /// notional over it, and a third 5% to 50%.
    function _collateral(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 notional, uint256 choice)
        private
        view
        returns (uint256)
    {
        uint256 minimum = minimumCollateral(tickLower, tickUpper, liquidity);
        uint256 mode = choice % 3;
        uint256 amountChoice = choice / 3;
        if (mode == 0) return minimum + amountChoice % 4;
        if (mode == 1) return minimum + notional * bound(amountChoice, 10, 200) / BPS;
        return minimum + notional * bound(amountChoice, 500, 5_000) / BPS;
    }

    /// @dev A long's range entirely below the bid, a short's entirely above the ask, as the other opens choose them.
    function _venueRange(bool isLong, uint256 distanceTicks) private view returns (int24 tickLower, int24 tickUpper) {
        int24 distance = _ticks(distanceTicks, 0, 1_500);
        int24 width = _ticks(distanceTicks / 1_501, 1, 2_000);
        if (isLong) {
            tickUpper = priceTick - spreadTicks - distance;
            return (tickUpper - width, tickUpper);
        }
        tickLower = priceTick + spreadTicks + distance;
        return (tickLower, tickLower + width);
    }

    function _openTerms(
        bool isLong,
        uint256 actorChoice,
        int24 tickLower,
        int24 tickUpper,
        uint256 notional,
        uint256 collateralChoice,
        uint256 escrowChoice
    ) private view returns (OpenRequest memory request) {
        uint128 liquidity = liquidityFor1(tickLower, tickUpper, notional);
        request = openRequest(isLong, tickLower, tickUpper, liquidity, 0);
        request.vaultId = vaultIds[actorChoice % VAULT_COUNT];
        request.collateral = uint128(_collateral(tickLower, tickUpper, liquidity, notional, collateralChoice));
        request.escrow = uint128(_escrow(escrowChoice));
    }

    /// @dev Routes the open's entry swap through the handler's venue (`VenueRoutes.route`), and returns what the fill
    /// loses against the band, as the vault measures it.
    function _routeThroughVenue(OpenRequest memory request, uint256 swapChoice) private view returns (uint256) {
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(request.tickLower, request.tickUpper);
        uint160 sqrtBidX96 = source.sqrtBidX96();
        uint160 sqrtAskX96 = source.sqrtAskX96();
        (uint256 release0, uint256 release1) =
            VaultMath.releaseAcrossBand(request.liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96, sqrtAskX96);
        uint256 sellable = request.isLong ? release1 + request.collateral : release0;
        VenueRoutes.Route memory chosen =
            VenueRoutes.route(request.isLong, sellable, swapChoice, sqrtBidX96, sqrtAskX96);
        request.entryAmountIn = chosen.amountIn;
        request.entryVenue = address(venue);
        request.entryRoute = chosen.data;
        VenueSwap.Trade memory trade;
        trade.zeroForOne = !request.isLong;
        trade.sqrtBidX96 = sqrtBidX96;
        trade.sqrtAskX96 = sqrtAskX96;
        return VenueSwap.shortfall(trade, chosen.spend, chosen.amountOut);
    }

    /// @dev No escrow, a dust escrow, or up to 100 quote: the first two go delinquent within a step or two.
    function _escrow(uint256 choice) private pure returns (uint256) {
        uint256 mode = choice % 3;
        uint256 amountChoice = choice / 3;
        if (mode == 0) return 0;
        if (mode == 1) return 1 + amountChoice % 1e6;
        return 1e6 + amountChoice % 100e6;
    }

    function _ticks(uint256 choice, uint256 minimum, uint256 maximum) private pure returns (int24) {
        return int24(int256(bound(choice, minimum, maximum)));
    }

    /// @dev The first open position at or after `choice` in the list.
    function _pick(uint256 choice) private view returns (bool found, uint256 positionId, Position memory position) {
        uint256 count = positionIds.length;
        if (count == 0) return (false, 0, position);
        uint256 start = choice % count;
        // count <= the run's depth
        for (uint256 step = 0; step < count; ++step) {
            positionId = positionIds[(start + step) % count];
            position = vault.positionOf(positionId);
            if (position.owner != address(0)) return (true, positionId, position);
        }
        return (false, 0, position);
    }

    /// @dev The first open position at or after `choice` that is flagged.
    function _pickFlagged(uint256 choice)
        private
        view
        returns (bool found, uint256 positionId, Position memory position)
    {
        uint256 count = positionIds.length;
        if (count == 0) return (false, 0, position);
        uint256 start = choice % count;
        // count <= the run's depth
        for (uint256 step = 0; step < count; ++step) {
            positionId = positionIds[(start + step) % count];
            position = vault.positionOf(positionId);
            if (position.owner != address(0) && position.delinquentSince != 0) return (true, positionId, position);
        }
        return (false, 0, position);
    }

    /// @dev Flags the first unflagged position at or after `choice` that is delinquent.
    function _flagFirstDelinquent(uint256 choice) private returns (bool flagged, uint256 positionId) {
        uint256 count = positionIds.length;
        if (count == 0) return (false, 0);
        uint256 start = choice % count;
        // count <= the run's depth
        for (uint256 step = 0; step < count; ++step) {
            positionId = positionIds[(start + step) % count];
            Position memory position = vault.positionOf(positionId);
            if (position.owner == address(0) || position.delinquentSince != 0) continue;
            bytes32[VAULT_COUNT] memory before = _snapshot();
            flagged = _tryFlag(positionId);
            _checkIsolation(before, position.vaultId);
            if (flagged) return (true, positionId);
        }
        return (false, 0);
    }

    function _tryFlag(uint256 positionId) private returns (bool) {
        try vault.flag(positionId) {
            ++flags;
            return true;
        } catch (bytes memory reason) {
            _expect(reason, "flag", IMetricLendingVault.NotDelinquent.selector, 0, 0);
            return false;
        }
    }

    /// @dev `VaultLending.valueLow` for a vault without a pool, whose idle capital is its buffer.
    function _valueLow(uint256 someVaultId, uint160 sqrtBidX96) private view returns (uint256) {
        Ledger memory ledger = vault.ledgerOf(someVaultId);
        (uint256 debtValue,) = vault.debtValuesAt(someVaultId, sqrtBidX96);
        return VaultMath.valueInToken1(ledger.buffer0, ledger.buffer1, sqrtBidX96, false) + debtValue;
    }

    /// @dev The closer's reward is a share of what is left after repayment, so it can never exceed that share of the
    /// reserves the position held before the close.
    function _checkReward(Position memory position, uint256 reward0, uint256 reward1) private {
        uint256 rewardBps = vault.parametersOf(position.vaultId).forceCloseRewardBps;
        if (reward0 * BPS > uint256(position.reserve0) * rewardBps) _violate("force close reward0 above its cap");
        if (reward1 * BPS > uint256(position.reserve1) * rewardBps) _violate("force close reward1 above its cap");
    }

    function _expect(bytes memory reason, string memory action, bytes4 allowedA, bytes4 allowedB, bytes4 allowedC)
        private
    {
        if (reason.length >= 4) {
            bytes4 selector = bytes4(reason);
            if (selector == allowedA || selector == allowedB || selector == allowedC) return;
        }
        _violate(string.concat(action, " reverted unexpectedly: ", vm.toString(reason)));
    }

    function _violate(string memory message) private {
        ++violations;
        lastViolation = message;
    }

    /// @dev A hash of everything one vault's books hold, to prove an action on one vault leaves the other untouched.
    function _snapshot() private view returns (bytes32[VAULT_COUNT] memory hashes) {
        // VAULT_COUNT vaults
        for (uint256 index = 0; index < VAULT_COUNT; ++index) {
            hashes[index] = _booksHash(vaultIds[index]);
        }
    }

    function _booksHash(uint256 someVaultId) private view returns (bytes32) {
        (DebtTotals memory longDebts, DebtTotals memory shortDebts) = vault.debtsOf(someVaultId);
        bytes memory books = abi.encode(
            vault.ledgerOf(someVaultId),
            vault.accrualOf(someVaultId),
            vault.streamOf(someVaultId),
            longDebts,
            shortDebts,
            vault.totalSharesOf(someVaultId)
        );
        return keccak256(books);
    }

    function _checkIsolation(bytes32[VAULT_COUNT] memory before, uint256 actedVaultId) private {
        // VAULT_COUNT vaults
        for (uint256 index = 0; index < VAULT_COUNT; ++index) {
            if (vaultIds[index] == actedVaultId) continue;
            if (_booksHash(vaultIds[index]) != before[index]) _violate("an action changed another vault's books");
        }
    }

    function _fundActor(address actor) private {
        fundWith(actor, base);
        fundWith(actor, secondBase);
        fundWith(actor, quote);
    }
}
