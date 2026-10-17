// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MetricLendingVault} from "../../../src/metric/vault/MetricLendingVault.sol";
import {
    Bucket,
    Leg,
    LegRequest,
    MakerCloseRequest,
    MakerOpenRequest,
    MakerPosition
} from "../../../src/metric/vault/MakerTypes.sol";
import {Accrual, Ledger} from "../../../src/metric/vault/VaultTypes.sol";
import {IMakerBook} from "../../../src/metric/vault/interfaces/IMakerBook.sol";
import {IMetricLendingVault} from "../../../src/metric/vault/interfaces/IMetricLendingVault.sol";
import {MakerMath} from "../../../src/metric/vault/libraries/MakerMath.sol";
import {DebtTotals, VaultMath} from "../../../src/metric/vault/libraries/VaultMath.sol";
import {MockPriceSource, TestToken} from "../utils/VaultFixture.sol";
import {MakerFixture} from "../utils/MakerFixture.sol";

/// @notice The actions of the maker book's invariant test on a no-pool vault: makers deposit, withdraw and claim;
/// traders open one- to three-leg positions, top them up, settle and close them; keepers flag and force close; the
/// price walks and time passes.
/// @dev Every vault call is wrapped in try/catch. A revert whose error the action does not expect, or a maker action
/// that changes the passive vault's books, adds to `violations`; the invariant test requires none.
contract MakerHandler is MakerFixture {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAKER_COUNT = 2;
    uint256 internal constant LEVEL_COUNT = 6;
    int256 internal constant MAX_PRICE_DRIFT_TICKS = 1_500;
    int256 internal constant MAX_PRICE_STEP_TICKS = 250;
    uint256 internal constant MAX_WARP_SECONDS = 5 days;

    address[MAKER_COUNT] internal makers;
    /// @dev Buy levels below the starting price and sell levels above it.
    int24[LEVEL_COUNT] internal buyLevels;
    int24[LEVEL_COUNT] internal sellLevels;
    /// @dev Every bucket ever deposited into, and every position ever opened (closed ones read back with no owner).
    uint256[] public bucketIds;
    mapping(uint256 bucketId => bool) internal tracked;
    uint256[] public positionIds;
    int24 public priceTick;

    uint256 public violations;
    string public lastViolation;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public claims;
    uint256 public opens;
    uint256 public settlements;
    uint256 public fullCloses;
    uint256 public partialCloses;
    uint256 public forceCloses;

    constructor(
        MetricLendingVault sharedVault,
        TestToken base_,
        TestToken quote_,
        MockPriceSource source_,
        uint256 id
    ) {
        vault = sharedVault;
        base = base_;
        quote = quote_;
        source = source_;
        vaultId = id;
        priceTick = PRICE_TICK;
        buyLevels = [int24(-2_006), -2_010, -2_014, -2_024, -2_044, -2_073];
        sellLevels = [int24(-2_002), -1_998, -1_994, -1_984, -1_964, -1_935];
        // MAKER_COUNT makers
        for (uint256 index = 0; index < MAKER_COUNT; ++index) {
            makers[index] = makeAddr(string.concat("maker", vm.toString(index)));
            fundWith(makers[index], base);
            fundWith(makers[index], quote);
        }
        fundWith(trader, base);
        fundWith(trader, quote);
    }

    function makerAt(uint256 index) external view returns (address) {
        return makers[index];
    }

    function bucketCount() external view returns (uint256) {
        return bucketIds.length;
    }

    function positionCount() external view returns (uint256) {
        return positionIds.length;
    }

    // ---------------------------------------------------------------- makers

    function actDeposit(uint256 makerChoice, uint256 levelChoice, bool isBuy, uint256 amountSeed) external {
        address maker = makers[makerChoice % MAKER_COUNT];
        int24 level = isBuy ? buyLevels[levelChoice % LEVEL_COUNT] : sellLevels[levelChoice % LEVEL_COUNT];
        uint256 amount = isBuy ? bound(amountSeed, 100e6, 200_000e6) : bound(amountSeed, 0.06e18, 100e18);
        bytes32 before = _passiveBooks();
        vm.prank(maker);
        try vault.depositOrder(vaultId, level, isBuy, amount, 0, maker) returns (uint256 bucketId, uint256) {
            ++deposits;
            _track(bucketId);
        } catch (bytes memory reason) {
            _expect(reason, "deposit", IMakerBook.WrongSideOfPrice.selector, IMakerBook.BelowMinimumNotional.selector);
        }
        _checkIsolation(before);
    }

    function actWithdraw(uint256 makerChoice, uint256 bucketChoice, uint256 fractionSeed) external {
        if (bucketIds.length == 0) return;
        address maker = makers[makerChoice % MAKER_COUNT];
        uint256 bucketId = bucketIds[bucketChoice % bucketIds.length];
        uint256 held = vault.makerShareOf(vaultId, bucketId, maker).shares;
        uint256 shares = FullMath.mulDiv(held, bound(fractionSeed, 1, WAD), WAD);
        if (shares == 0) return;
        vm.prank(maker);
        try vault.withdrawOrder(vaultId, bucketId, shares, 0, 0, maker) returns (uint256, uint256, uint256 burned) {
            ++withdrawals;
            if (burned > shares) _violate("withdraw burned more shares than asked");
        } catch (bytes memory reason) {
            _expect(
                reason,
                "withdraw",
                IMetricLendingVault.InsufficientIdle.selector,
                IMetricLendingVault.ZeroAmount.selector
            );
        }
    }

    function actClaim(uint256 makerChoice, uint256 bucketChoice) external {
        if (bucketIds.length == 0) return;
        address maker = makers[makerChoice % MAKER_COUNT];
        vm.prank(maker);
        try vault.claimOrderIncome(vaultId, bucketIds[bucketChoice % bucketIds.length], maker) {
            ++claims;
        } catch (bytes memory reason) {
            _expect(reason, "claim", IMetricLendingVault.ZeroAmount.selector, bytes4(0));
        }
    }

    /// @dev Claims for every maker in every bucket that has income; the fixed walk's way to reach a claim.
    function actClaimAny() external {
        // MAKER_COUNT makers x the buckets tracked
        for (uint256 makerIndex = 0; makerIndex < MAKER_COUNT; ++makerIndex) {
            for (uint256 index = 0; index < bucketIds.length; ++index) {
                vm.prank(makers[makerIndex]);
                try vault.claimOrderIncome(vaultId, bucketIds[index], makers[makerIndex]) {
                    ++claims;
                } catch {}
            }
        }
    }

    // ---------------------------------------------------------------- traders

    function actOpen(bool isLong, uint256 legsSeed, uint256 levelSeed, uint256 sizeSeed, bool tight) external {
        uint256 legCount = bound(legsSeed, 1, 3);
        uint256[] memory ids = new uint256[](legCount);
        uint128[] memory liquidities = new uint128[](legCount);
        // legCount <= 3
        for (uint256 index = 0; index < legCount; ++index) {
            uint256 levelIndex = (levelSeed % LEVEL_COUNT + index * 2) % LEVEL_COUNT;
            int24 level = isLong ? buyLevels[levelIndex] : sellLevels[levelIndex];
            ids[index] = vault.currentBucketOf(vaultId, level, isLong);
            liquidities[index] =
                liquidityOn(level, bound(uint256(keccak256(abi.encode(sizeSeed, index))), 101e6, 20_000e6));
        }
        (ids, liquidities) = _sorted(ids, liquidities);
        if (_hasDuplicate(ids)) return;
        _open(_request(isLong, ids, liquidities, tight));
    }

    function actAddEscrow(uint256 positionChoice, uint256 amountSeed) external {
        (bool found, uint256 positionId) = _pick(positionChoice);
        if (!found) return;
        vm.prank(trader);
        vault.addMakerEscrow(positionId, bound(amountSeed, 1e6, 5_000e6));
    }

    function actSettle(uint256 positionChoice) external {
        (bool found, uint256 positionId) = _pick(positionChoice);
        if (!found) return;
        if (vault.settleMaker(positionId)) ++settlements;
    }

    function actClose(uint256 positionChoice, bool partialClose, uint256 fractionSeed) external {
        (bool found, uint256 positionId) = _pick(positionChoice);
        if (!found) return;
        uint256 fractionWad = partialClose ? _partialFraction(fractionSeed) : WAD;
        (uint256[] memory repay0, uint256[] memory repay1) = _repayments(positionId, fractionWad);
        bytes32 before = _passiveBooks();
        vm.prank(trader);
        try vault.closeMaker(
            MakerCloseRequest({positionId: positionId, fractionWad: fractionWad, repay0: repay0, repay1: repay1})
        ) {
            if (partialClose) ++partialCloses;
            else ++fullCloses;
        } catch (bytes memory reason) {
            if (!partialClose) _violate(string.concat("full close reverted: ", vm.toString(reason)));
            else _expectPartial(reason);
        }
        _checkIsolation(before);
    }

    function actForceClose(uint256 positionChoice) external {
        (bool found, uint256 positionId) = _pick(positionChoice);
        if (!found) return;
        try vault.flagMaker(positionId) {}
        catch (bytes memory reason) {
            _expect(reason, "flag", IMetricLendingVault.NotDelinquent.selector, bytes4(0));
            return;
        }
        vm.warp(block.timestamp + 1 hours);
        vm.prank(closer);
        try vault.forceCloseMaker(positionId) {
            ++forceCloses;
        } catch (bytes memory reason) {
            // Ten more days' premium was owed only if the warp kept it delinquent; a top-up race is not modeled.
            _expect(reason, "force close", IMetricLendingVault.NotDelinquent.selector, bytes4(0));
        }
    }

    // ---------------------------------------------------------------- the market

    function actWarp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, MAX_WARP_SECONDS));
    }

    function actMovePrice(int256 stepSeed) external {
        int256 step = bound(stepSeed, -MAX_PRICE_STEP_TICKS, MAX_PRICE_STEP_TICKS);
        int256 next = int256(priceTick) + step;
        int256 low = int256(PRICE_TICK) - MAX_PRICE_DRIFT_TICKS;
        int256 high = int256(PRICE_TICK) + MAX_PRICE_DRIFT_TICKS;
        if (next < low) next = low;
        if (next > high) next = high;
        priceTick = int24(next);
        setPrice(priceTick, 1);
    }

    // ---------------------------------------------------------------- helpers

    function _open(MakerOpenRequest memory request) private {
        bytes32 before = _passiveBooks();
        vm.prank(trader);
        try vault.openMaker(request) returns (uint256 positionId) {
            ++opens;
            positionIds.push(positionId);
        } catch (bytes memory reason) {
            _expectOpen(reason);
        }
        _checkIsolation(before);
    }

    /// @dev Collateral at the aggregate chord's edge plus one or two units (tight), or a margin of 1% of `ΣM1`.
    function _request(bool isLong, uint256[] memory ids, uint128[] memory liquidities, bool tight)
        private
        view
        returns (MakerOpenRequest memory request)
    {
        (uint256 maximum0, uint256 maximum1, uint256 release0, uint256 release1) = _terms(ids, liquidities);
        uint256 legCount = ids.length;
        uint256 kept0 = release0 > legCount ? release0 - legCount : 0;
        uint256 needed1 =
            kept0 >= maximum0 ? legCount : FullMath.mulDivRoundingUp(maximum1, maximum0 - kept0, maximum0) + legCount;
        uint256 collateral = needed1 > release1 ? needed1 - release1 : 0;
        collateral += tight ? 2 : maximum1 / 100;
        request = makerRequest(isLong, ids, liquidities, uint128(collateral));
        // Tight opens escrow about three days at the steepest floor: the two prepaid and about one more, so they soon
        // fall delinquent and get force closed.
        request.escrow = tight ? uint128(maximum1 * 3 / 100) : uint128(maximum1 / 10 + 10e6);
    }

    function _terms(uint256[] memory ids, uint128[] memory liquidities)
        private
        view
        returns (uint256 maximum0, uint256 maximum1, uint256 release0, uint256 release1)
    {
        // ids.length <= 3
        for (uint256 index = 0; index < ids.length; ++index) {
            (int24 level,,) = MakerMath.decode(ids[index]);
            (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(level);
            (uint256 legMaximum0, uint256 legMaximum1) =
                VaultMath.debtExtremes(liquidities[index], sqrtLowerX96, sqrtUpperX96);
            (uint256 legRelease0, uint256 legRelease1) = VaultMath.releaseAcrossBand(
                liquidities[index], sqrtLowerX96, sqrtUpperX96, source.sqrtBidX96(), source.sqrtAskX96()
            );
            maximum0 += legMaximum0;
            maximum1 += legMaximum1;
            release0 += legRelease0;
            release1 += legRelease1;
        }
    }

    /// @dev Each leg's holdings at the bid plus a unit of each held token when the closed reserves hold them;
    /// otherwise each leg's proportional share of the closed reserves, which the aggregate chord makes repay.
    function _repayments(uint256 positionId, uint256 fractionWad)
        private
        view
        returns (uint256[] memory repay0, uint256[] memory repay1)
    {
        (repay0, repay1) = repaymentsAtBid(positionId, fractionWad);
        MakerPosition memory position = vault.makerPositionOf(positionId);
        uint256 portion0 = VaultMath.portionDown(position.reserve0, fractionWad);
        uint256 portion1 = VaultMath.portionDown(position.reserve1, fractionWad);
        uint256 total0;
        uint256 total1;
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < repay0.length; ++index) {
            total0 += repay0[index];
            total1 += repay1[index];
        }
        if (total0 <= portion0) {
            if (total1 <= portion1) return (repay0, repay1);
        }
        // legCount <= MAX_LEGS
        for (uint256 index = 0; index < repay0.length; ++index) {
            Leg memory leg = vault.legOf(positionId, index);
            repay0[index] = MakerMath.allocation(
                portion0,
                repay0.length,
                VaultMath.portionDown(leg.maximum0, fractionWad),
                VaultMath.portionDown(position.maximum0, fractionWad)
            );
            repay1[index] = MakerMath.allocation(
                portion1,
                repay0.length,
                VaultMath.portionDown(leg.maximum1, fractionWad),
                VaultMath.portionDown(position.maximum1, fractionWad)
            );
        }
    }

    /// @dev A quarter of partial closes are tiny, so a leg's closed `M1` part can round to nothing while its liquidity
    /// part does not (Sol's finding); the rest close between 1% and 90%.
    function _partialFraction(uint256 seed) private pure returns (uint256) {
        if (seed % 4 == 0) return bound(seed, 1, 1e12);
        return bound(seed, 0.01e18, 0.9e18);
    }

    function _pick(uint256 choice) private view returns (bool, uint256) {
        uint256 count = positionIds.length;
        // count <= the run's opens
        for (uint256 step = 0; step < count; ++step) {
            uint256 positionId = positionIds[(choice % count + step) % count];
            if (vault.makerPositionOf(positionId).owner != address(0)) return (true, positionId);
        }
        return (false, 0);
    }

    function _track(uint256 bucketId) private {
        if (tracked[bucketId]) return;
        tracked[bucketId] = true;
        bucketIds.push(bucketId);
    }

    function _sorted(uint256[] memory ids, uint128[] memory liquidities)
        private
        pure
        returns (uint256[] memory, uint128[] memory)
    {
        // insertion sort over at most 3 legs
        for (uint256 index = 1; index < ids.length; ++index) {
            uint256 id = ids[index];
            uint128 liquidity = liquidities[index];
            uint256 cursor = index;
            while (cursor > 0 && ids[cursor - 1] > id) {
                ids[cursor] = ids[cursor - 1];
                liquidities[cursor] = liquidities[cursor - 1];
                cursor -= 1;
            }
            ids[cursor] = id;
            liquidities[cursor] = liquidity;
        }
        return (ids, liquidities);
    }

    function _hasDuplicate(uint256[] memory ids) private pure returns (bool) {
        // ids.length <= 3
        for (uint256 index = 1; index < ids.length; ++index) {
            if (ids[index] == ids[index - 1]) return true;
        }
        return false;
    }

    function _expectOpen(bytes memory reason) private {
        bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0);
        if (selector == IMakerBook.WrongSideOfPrice.selector) return;
        if (selector == IMakerBook.UnknownBucket.selector) return;
        if (selector == IMakerBook.BelowMinimumNotional.selector) return;
        if (selector == IMetricLendingVault.InsufficientIdle.selector) return;
        if (selector == IMetricLendingVault.UtilizationCeiling.selector) return;
        if (selector == IMetricLendingVault.EscrowTooSmall.selector) return;
        _violate(string.concat("open reverted unexpectedly: ", vm.toString(reason)));
    }

    function _expectPartial(bytes memory reason) private {
        bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0);
        if (selector == IMetricLendingVault.PremiumUnpaid.selector) return;
        if (selector == IMakerBook.BelowMinimumNotional.selector) return;
        if (selector == IMetricLendingVault.Insolvent.selector) return;
        if (selector == IMetricLendingVault.RepaymentShort.selector) return;
        if (selector == IMetricLendingVault.InvalidFraction.selector) return;
        _violate(string.concat("partial close reverted unexpectedly: ", vm.toString(reason)));
    }

    function _expect(bytes memory reason, string memory action, bytes4 allowedA, bytes4 allowedB) private {
        if (reason.length >= 4) {
            bytes4 selector = bytes4(reason);
            if (selector == allowedA) return;
            if (selector == allowedB) return;
        }
        _violate(string.concat(action, " reverted unexpectedly: ", vm.toString(reason)));
    }

    function _violate(string memory message) private {
        ++violations;
        lastViolation = message;
    }

    /// @dev The passive vault's books that maker activity must never touch.
    function _passiveBooks() private view returns (bytes32) {
        (DebtTotals memory longDebts, DebtTotals memory shortDebts) = vault.debtsOf(vaultId);
        Ledger memory ledger = vault.ledgerOf(vaultId);
        Accrual memory accrual = vault.accrualOf(vaultId);
        return keccak256(
            abi.encode(
                ledger.buffer0,
                ledger.buffer1,
                accrual,
                vault.streamOf(vaultId),
                longDebts,
                shortDebts,
                vault.totalSharesOf(vaultId)
            )
        );
    }

    function _checkIsolation(bytes32 before) private {
        if (_passiveBooks() != before) _violate("maker action changed the passive vault's books");
    }
}
