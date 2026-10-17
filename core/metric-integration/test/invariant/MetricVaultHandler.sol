// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MetricOmmPool} from "metric/MetricOmmPool.sol";
import {IMetricOmmPoolActions} from "metric/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {PoolStateLibrary} from "metric/libraries/PoolStateLibrary.sol";
import {MetricLendingVault} from "vault/MetricLendingVault.sol";
import {CloseRequest, Ledger, OpenRequest, Position, Venue} from "vault/VaultTypes.sol";
import {IMetricLendingVault} from "vault/interfaces/IMetricLendingVault.sol";
import {MetricPrice} from "vault/libraries/MetricPrice.sol";
import {DebtTotals, VaultMath} from "vault/libraries/VaultMath.sol";
import {IntegrationToken, SettableProvider, Trader} from "../utils/MetricFixture.sol";

/// @notice Reads of the vault's Metric position straight from the pool's storage, through Metric's own
/// `PoolStateLibrary` rather than the vault's `MetricState`, so they check the vault's reads independently.
library PoolReads {
    /// @notice The vault's position in its window, each bin's share of its balances rounded down and then converted
    /// to native units rounded down, as the vault defines its holdings.
    function holdings(
        address pool,
        address owner,
        uint256 vaultId,
        int256 lowestBin,
        uint256 binCount,
        uint256 scale0,
        uint256 scale1
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // binCount bins
        for (uint256 offset = 0; offset < binCount; ++offset) {
            int16 binIndex = int16(lowestBin + int256(offset));
            uint256 ours = PoolStateLibrary._positionBinShares(pool, owner, uint80(vaultId), binIndex);
            if (ours == 0) continue;
            (uint104 balance0, uint104 balance1,,,) = PoolStateLibrary._binState(pool, binIndex);
            uint256 totalShares = PoolStateLibrary._binTotalShares(pool, binIndex);
            amount0 += FullMath.mulDiv(ours, balance0, totalShares) / scale0;
            amount1 += FullMath.mulDiv(ours, balance1, totalShares) / scale1;
        }
    }
}

/// @notice Drives one vault on a real Metric pool: lenders, traders, a force closer, an outside trader, the price
/// provider and time. Every vault call is try/caught; a revert whose selector is not on the action's list of
/// legitimate reasons is recorded, and the invariant suite requires none.
contract MetricVaultHandler is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q64 = 1 << 64;
    uint256 internal constant Q96 = 1 << 96;
    /// @dev The vault's virtual shares (`VaultLending.VIRTUAL_SHARES`).
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    /// @dev Metric rounding per lender flow: under a unit per bin and token on each add and removal, in quote units.
    uint256 internal constant DILUTION_DUST = 100;
    bytes4 internal constant NONE = 0xffffffff;

    MetricLendingVault internal immutable vault;
    uint256 internal immutable vaultId;
    MetricOmmPool internal immutable pool;
    SettableProvider internal immutable provider;
    IntegrationToken internal immutable base;
    IntegrationToken internal immutable quote;
    Trader internal immutable outsider;
    /// @dev The pool's factory, the only account that may pause it.
    address internal immutable factory;

    address[3] internal lenders;
    address[2] internal traders;
    address internal closer = makeAddr("handler.closer");

    uint256[] internal openIds;

    // ---------------------------------------------------------------- ghosts

    uint256 public unexpectedReverts;
    string public lastUnexpectedAction;
    bytes public lastUnexpectedReason;
    /// @dev Vault actions after which the bin active at their start had no shares left, though it had some before.
    uint256 public activeBinEmptied;
    /// @dev Repayments at the bid's holdings rounded up that failed the repayment rule, so took one more unit.
    uint256 public holdingsAtBidShort;
    /// @dev Deposits and withdrawals after which the lenders' value per share at the bid fell, beyond dust.
    uint256 public stayersDiluted;
    uint256 public dilutionChecks;
    /// @dev Withdrawals with a claim worth at least one quote refused for want of idle capital while at least one
    /// quote's worth of it sat in the buffer and the vault's Metric bins.
    uint256 public withdrawalsRefusedWithIdle;
    /// @dev Legitimate refusals, by selector.
    mapping(bytes4 => uint256) public refusals;

    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public opens;
    uint256 public opensRefused;
    uint256 public fullCloses;
    uint256 public partialCloses;
    uint256 public closesRefused;
    uint256 public closesAtBid;
    uint256 public closesWhole;
    uint256 public settles;
    uint256 public flags;
    uint256[3] public forceCloses;
    uint256 public outsideSwaps;
    uint256 public recenters;

    constructor(
        MetricLendingVault vault_,
        uint256 vaultId_,
        MetricOmmPool pool_,
        SettableProvider provider_,
        IntegrationToken base_,
        IntegrationToken quote_,
        Trader outsider_,
        address factory_
    ) {
        vault = vault_;
        vaultId = vaultId_;
        pool = pool_;
        provider = provider_;
        base = base_;
        quote = quote_;
        outsider = outsider_;
        factory = factory_;
        lenders = [makeAddr("handler.lender0"), makeAddr("handler.lender1"), makeAddr("handler.lender2")];
        traders = [makeAddr("handler.trader0"), makeAddr("handler.trader1")];
        // three lenders and two traders
        for (uint256 index = 0; index < 3; ++index) {
            _fund(lenders[index]);
        }
        for (uint256 index = 0; index < 2; ++index) {
            _fund(traders[index]);
        }
    }

    // ---------------------------------------------------------------- views for the invariants

    function openCount() external view returns (uint256) {
        return openIds.length;
    }

    function forceClosesByMode() external view returns (uint256, uint256, uint256) {
        return (forceCloses[0], forceCloses[1], forceCloses[2]);
    }

    // ---------------------------------------------------------------- lenders

    function deposit(uint256 who, uint256 amount0, uint256 amount1) external watchActiveBin {
        address lender = lenders[who % 3];
        amount0 = amount0 % 4 == 0 ? 0 : bound(amount0, 1e12, 50e18);
        amount1 = bound(amount1, 0, 100_000e6);
        if (amount0 == 0 && amount1 < 1e6) amount1 = 1e6;
        (bool checked, uint256 valueBefore, uint256 sharesBefore) = _valuePerShare();
        vm.prank(lender);
        try vault.deposit(vaultId, amount0, amount1, 0, lender) {
            deposits += 1;
            if (checked) _checkNoDilution(valueBefore, sharesBefore);
        } catch (bytes memory reason) {
            _allow(reason, "deposit", [IMetricLendingVault.ZeroAmount.selector, NONE, NONE, NONE, NONE, NONE]);
        }
    }

    function withdraw(uint256 who, uint256 fractionBps) external watchActiveBin {
        address lender = lenders[who % 3];
        uint256 held = vault.sharesOf(vaultId, lender);
        uint256 shares = held * bound(fractionBps, 1, 10_000) / 10_000;
        if (shares == 0) return;
        (bool checked, uint256 valueBefore, uint256 sharesBefore) = _valuePerShare();
        vm.prank(lender);
        try vault.withdraw(vaultId, shares, 0, 0, lender) {
            withdrawals += 1;
            if (checked) _checkNoDilution(valueBefore, sharesBefore);
        } catch (bytes memory reason) {
            if (bytes4(reason) == IMetricLendingVault.InsufficientIdle.selector) {
                (, uint256 idleValue,) = _idleValue();
                (uint256 value, uint256 totalShares) = _lowValue();
                uint256 claim = FullMath.mulDiv(shares, value + 1, totalShares + VIRTUAL_SHARES);
                if (idleValue >= 1e6 && claim >= 1e6) withdrawalsRefusedWithIdle += 1;
            }
            _allow(
                reason,
                "withdraw",
                [
                    IMetricLendingVault.InsufficientIdle.selector,
                    IMetricLendingVault.ZeroAmount.selector,
                    NONE,
                    NONE,
                    NONE,
                    NONE
                ]
            );
        }
    }

    function recenter() external watchActiveBin {
        try vault.recenter(vaultId) returns (bool moved) {
            if (moved) recenters += 1;
        } catch (bytes memory reason) {
            _allow(reason, "recenter", [NONE, NONE, NONE, NONE, NONE, NONE]);
        }
    }

    // ---------------------------------------------------------------- traders

    /// @dev A range within about −8%..+4% of the bid, 0.1% to 6% wide, `M1` of 150 to 25,000 quote. Collateral is
    /// the chord's gap at open, either plus one unit (tight) or plus up to a fifth of `M1`; an entry swap sells up to
    /// all of the reserves' input token.
    function open(
        uint256 who,
        bool isLong,
        uint256 offsetSeed,
        uint256 widthSeed,
        uint256 notionalSeed,
        uint256 collateralSeed,
        uint256 entrySeed,
        uint256 escrowSeed
    ) external watchActiveBin {
        (uint160 sqrtBidX96, uint160 sqrtAskX96) = _band();
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtBidX96);
        int24 lower = tick - 800 + int24(int256(bound(offsetSeed, 0, 1_200)));
        int24 upper = lower + int24(int256(bound(widthSeed, 10, 600)));
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upper);
        uint128 liquidity =
            uint128(FullMath.mulDiv(bound(notionalSeed, 150e6, 25_000e6), Q96, sqrtUpperX96 - sqrtLowerX96));
        (uint256 maximum0, uint256 maximum1) = VaultMath.debtExtremes(liquidity, sqrtLowerX96, sqrtUpperX96);
        (uint256 release0, uint256 release1) =
            VaultMath.releaseAcrossBand(liquidity, sqrtLowerX96, sqrtUpperX96, sqrtBidX96, sqrtAskX96);
        // The chord r1 + K·r0 ≥ M1 with K = M1 / M0.
        uint256 covered = release1 + FullMath.mulDiv(release0, maximum1, maximum0);
        uint256 gap = covered >= maximum1 ? 0 : maximum1 - covered;
        uint256 collateral = collateralSeed % 4 == 0 ? gap + 1 : gap + bound(collateralSeed, 0, maximum1 / 5);
        uint256 available = isLong ? release1 + collateral : release0;
        OpenRequest memory request;
        request.vaultId = vaultId;
        request.isLong = isLong;
        request.tickLower = lower;
        request.tickUpper = upper;
        request.liquidity = liquidity;
        request.collateral = uint128(collateral);
        request.escrow = uint128(bound(escrowSeed, 0, 30e6));
        request.entryAmountIn = entrySeed % 3 == 0 ? 0 : available * bound(entrySeed, 1, 100) / 100;
        vm.prank(traders[who % 2]);
        try vault.open(request) returns (uint256 positionId) {
            openIds.push(positionId);
            opens += 1;
        } catch (bytes memory reason) {
            opensRefused += 1;
            _allow(
                reason,
                "open",
                [
                    IMetricLendingVault.Insolvent.selector,
                    IMetricLendingVault.InsufficientIdle.selector,
                    IMetricLendingVault.UtilizationCeiling.selector,
                    IMetricLendingVault.BelowMinimumBorrow.selector,
                    // A dust entry swap can round to no output.
                    IMetricOmmPoolActions.FinalAmountIsZero.selector,
                    NONE
                ]
            );
        }
    }

    /// @dev Closes all or part, repaying the cheapest passing repayment at the band's bid (the range's holdings there,
    /// rounded up) when the closed part of the reserves holds it, otherwise the whole closed part.
    function close(uint256 pick, uint256 fractionSeed) external watchActiveBin {
        if (openIds.length == 0) return;
        uint256 index = pick % openIds.length;
        uint256 positionId = openIds[index];
        Position memory position = vault.positionOf(positionId);
        uint256 fractionWad = fractionSeed % 3 == 0 ? bound(fractionSeed, 0.1e18, 0.9e18) : WAD;
        (uint256 repay0, uint256 repay1, bool atBid) = _repayment(position, fractionWad);
        vm.prank(position.owner);
        try vault.close(
            CloseRequest({positionId: positionId, fractionWad: fractionWad, repay0: repay0, repay1: repay1})
        ) {
            if (atBid) {
                closesAtBid += 1;
            } else {
                closesWhole += 1;
            }
            if (fractionWad == WAD) {
                fullCloses += 1;
                _forget(index);
            } else {
                partialCloses += 1;
            }
        } catch (bytes memory reason) {
            closesRefused += 1;
            if (fractionWad == WAD) {
                // A full close repaying a passing amount from the reserves has no reason to fail.
                _allow(reason, "close full", [NONE, NONE, NONE, NONE, NONE, NONE]);
                return;
            }
            _allow(
                reason,
                "close partial",
                [
                    IMetricLendingVault.PremiumUnpaid.selector,
                    IMetricLendingVault.Insolvent.selector,
                    IMetricLendingVault.BelowMinimumBorrow.selector,
                    // The rounded-down closed part of chord-solvent reserves can miss the rule by a unit.
                    IMetricLendingVault.RepaymentShort.selector,
                    NONE,
                    NONE
                ]
            );
        }
    }

    function settle(uint256 pick) external {
        if (openIds.length == 0) return;
        try vault.settle(openIds[pick % openIds.length]) returns (bool settled) {
            if (settled) settles += 1;
        } catch (bytes memory reason) {
            _allow(reason, "settle", [NONE, NONE, NONE, NONE, NONE, NONE]);
        }
    }

    function flag(uint256 pick) external {
        if (openIds.length == 0) return;
        try vault.flag(openIds[pick % openIds.length]) {
            flags += 1;
        } catch (bytes memory reason) {
            _allow(reason, "flag", [IMetricLendingVault.NotDelinquent.selector, NONE, NONE, NONE, NONE, NONE]);
        }
    }

    /// @dev Lets up to 60 days pass, flags the position if it is then delinquent, waits out the grace period, and force
    /// closes it: with the pool live (mode 0), paused (1), or with the price provider failing (2).
    function forceClose(uint256 pick, uint256 mode, uint256 waitSeed) external watchActiveBin {
        if (openIds.length == 0) return;
        uint256 index = pick % openIds.length;
        uint256 positionId = openIds[index];
        if (vault.positionOf(positionId).delinquentSince == 0) {
            vm.warp(block.timestamp + bound(waitSeed, 0, 60 days));
            vm.roll(block.number + 1);
            try vault.flag(positionId) {}
            catch (bytes memory reason) {
                _allow(reason, "flag", [IMetricLendingVault.NotDelinquent.selector, NONE, NONE, NONE, NONE, NONE]);
                return;
            }
        }
        uint256 ready = uint256(vault.positionOf(positionId).delinquentSince) + vault.parametersOf(vaultId).graceSeconds;
        if (block.timestamp < ready) vm.warp(ready);
        mode %= 3;
        if (mode == 1) {
            vm.prank(factory);
            pool.setPause(1);
        }
        if (mode == 2) provider.setBroken(true);
        vm.prank(closer);
        try vault.forceClose(positionId) {
            forceCloses[mode] += 1;
            _forget(index);
        } catch (bytes memory reason) {
            // An escrow top-up since the flag can cover what was owed.
            _allow(reason, "forceClose", [IMetricLendingVault.NotDelinquent.selector, NONE, NONE, NONE, NONE, NONE]);
        }
        if (mode == 1) {
            vm.prank(factory);
            pool.setPause(0);
        }
        if (mode == 2) provider.setBroken(false);
    }

    // ---------------------------------------------------------------- the market

    /// @dev Outside trades of 0.001 to 60 base, or 1 to 120,000 quote: they move the cursor up to several bins and pay
    /// spread into the bins, the vault's included. Their failures are Metric's business, not the vault's.
    function swapOutside(bool zeroForOne, uint256 size) external {
        uint256 amount = zeroForOne ? bound(size, 1e15, 60e18) : bound(size, 1e6, 120_000e6);
        try outsider.swap(pool, zeroForOne, int128(int256(amount))) {
            outsideSwaps += 1;
        } catch {}
    }

    /// @dev A random walk of the reference, ±0.3% a step within 1,600..2,500, with half-spreads of 0.5 to 15 bp no
    /// more than 2:1 apart, inside the pool's 3:1 asymmetry bound.
    function moveReference(uint256 stepSeed, uint256 bidSeed, uint256 askSeed) external {
        uint256 referenceX64 = uint256(provider.referenceX64()) * (997_000 + bound(stepSeed, 0, 6_000)) / 1e6;
        referenceX64 = bound(referenceX64, 1_600 * Q64, 2_500 * Q64);
        uint256 bidHalf = bound(bidSeed, 5, 150);
        provider.setBand(uint128(referenceX64), bidHalf, bound(askSeed, (bidHalf + 1) / 2, bidHalf * 2));
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1 hours, 10 days));
        vm.roll(block.number + 1);
    }

    // ---------------------------------------------------------------- helpers

    /// @dev The bin active when a vault action starts must keep some shares: emptying it would reset Metric's cursor
    /// position (`MetricOmmPool.sol:229`). Only removals change a bin's total shares, and the vault removes from the
    /// active bin only above its last shares (`MetricVenue._sharesFor`).
    modifier watchActiveBin() {
        (, int16 active,,,,,) = PoolStateLibrary._slot0(address(pool));
        uint256 sharesBefore = PoolStateLibrary._binTotalShares(address(pool), active);
        _;
        if (sharesBefore != 0 && PoolStateLibrary._binTotalShares(address(pool), active) == 0) activeBinEmptied += 1;
    }

    /// @dev Lenders' idle capital, the buffer plus the vault's Metric bins read from pool storage, valued at the bid.
    function _idleValue() internal returns (uint160 sqrtBidX96, uint256 value, uint256 placedValue) {
        (sqrtBidX96,) = _band();
        Venue memory venue = vault.venueOf(vaultId);
        Ledger memory ledger = vault.ledgerOf(vaultId);
        (uint256 placed0, uint256 placed1) = PoolReads.holdings(
            address(pool),
            address(vault),
            vaultId,
            venue.lowestBin,
            vault.parametersOf(vaultId).binCount,
            venue.scale0,
            venue.scale1
        );
        placedValue = VaultMath.valueInToken1(placed0, placed1, sqrtBidX96, false);
        value = VaultMath.valueInToken1(ledger.buffer0, ledger.buffer1, sqrtBidX96, false) + placedValue;
    }

    /// @dev The lenders' value for withdrawals (`VaultLending.valueLow`), rebuilt from pool storage, and the total
    /// shares. Only when the vault checkpointed in this block: a checkpoint vests income into the buffer, which would
    /// mask a small dilution.
    function _valuePerShare() internal returns (bool checked, uint256 value, uint256 shares) {
        if (vault.accrualOf(vaultId).updatedAt != block.timestamp) return (false, 0, 0);
        (value, shares) = _lowValue();
        checked = true;
    }

    function _lowValue() internal returns (uint256 value, uint256 shares) {
        (uint160 sqrtBidX96, uint256 idle,) = _idleValue();
        (DebtTotals memory longDebts, DebtTotals memory shortDebts) = vault.debtsOf(vaultId);
        value =
            idle + VaultMath.debtValueLower(longDebts, sqrtBidX96) + VaultMath.debtValueLower(shortDebts, sqrtBidX96);
        shares = vault.totalSharesOf(vaultId);
    }

    /// @dev Deposits are priced at the ask and withdrawals at the bid, both against the lenders' value, so neither
    /// lowers the value per share of the lenders who stay: `(V' + 1)/(S' + v) ≥ (V + 1)/(S + v)`, less dust.
    function _checkNoDilution(uint256 valueBefore, uint256 sharesBefore) internal {
        (uint256 valueAfter, uint256 sharesAfter) = _lowValue();
        dilutionChecks += 1;
        uint256 left = (valueAfter + 1 + DILUTION_DUST) * (sharesBefore + VIRTUAL_SHARES);
        if (left < (valueBefore + 1) * (sharesAfter + VIRTUAL_SHARES)) stayersDiluted += 1;
    }

    function _repayment(Position memory position, uint256 fractionWad)
        internal
        returns (uint256 repay0, uint256 repay1, bool atBid)
    {
        uint128 liquidity = uint128(VaultMath.portionDown(position.liquidity, fractionWad));
        uint256 portion0 = VaultMath.portionDown(position.reserve0, fractionWad);
        uint256 portion1 = VaultMath.portionDown(position.reserve1, fractionWad);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = VaultMath.rangeSqrtPrices(position.tickLower, position.tickUpper);
        (uint160 sqrtBidX96,) = _band();
        uint160 inside = sqrtBidX96 < sqrtLowerX96 ? sqrtLowerX96 : sqrtBidX96;
        inside = inside > sqrtUpperX96 ? sqrtUpperX96 : inside;
        repay0 = SqrtPriceMath.getAmount0Delta(inside, sqrtUpperX96, liquidity, true);
        repay1 = SqrtPriceMath.getAmount1Delta(sqrtLowerX96, inside, liquidity, true);
        if (!VaultMath.repays(repay0, repay1, liquidity, sqrtLowerX96, sqrtUpperX96)) {
            holdingsAtBidShort += 1;
            repay0 += 1;
            repay1 += 1;
        }
        if (repay0 <= portion0 && repay1 <= portion1) return (repay0, repay1, true);
        return (portion0, portion1, false);
    }

    function _band() internal returns (uint160, uint160) {
        return MetricPrice.band(address(pool), 1, 1e12);
    }

    function _forget(uint256 index) internal {
        openIds[index] = openIds[openIds.length - 1];
        openIds.pop();
    }

    /// @dev Records `reason` unless its selector is one of `allowed`; NONE pads the list.
    function _allow(bytes memory reason, string memory action, bytes4[6] memory allowed) internal {
        bytes4 selector = bytes4(reason);
        // six allowed selectors
        for (uint256 index = 0; index < 6; ++index) {
            if (allowed[index] != NONE && allowed[index] == selector) {
                refusals[selector] += 1;
                return;
            }
        }
        unexpectedReverts += 1;
        lastUnexpectedAction = action;
        lastUnexpectedReason = reason;
    }

    function _fund(address who) internal {
        base.mint(who, 1e30);
        quote.mint(who, 1e30);
        vm.startPrank(who);
        base.approve(address(vault), type(uint256).max);
        quote.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }
}
