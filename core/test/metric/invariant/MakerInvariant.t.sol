// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Bucket, Leg, MakerPosition} from "../../../src/metric/vault/MakerTypes.sol";
import {MakerMath} from "../../../src/metric/vault/libraries/MakerMath.sol";
import {MakerFixture} from "../utils/MakerFixture.sol";
import {MakerHandler} from "./MakerHandler.sol";

/// @notice Random sequences of maker, trader, keeper and market actions on a no-pool vault's maker book, with the
/// book checked after every call.
/// @dev All checks live in one invariant function, as in `VaultInvariantTest`: one campaign, each property asserting
/// on its own line.
contract MakerInvariantTest is MakerFixture {
    MakerHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new MakerHandler(vault, base, quote, source, vaultId);
        // Both makers start with orders on every level, so opens are possible from the first call.
        // 2 makers x 6 levels x 2 sides
        for (uint256 choice = 0; choice < 12; ++choice) {
            handler.actDeposit(choice % 2, choice / 2, true, 100_000e6);
            handler.actDeposit(choice % 2, choice / 2, false, 50e18);
        }
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_makerBook() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
        assertLedger();
        _assertBuckets();
        _assertPositions();
        _assertOwnerLists();
    }

    /// @dev A fixed walk through every action, so a handler whose actions all fail cannot pass the campaign quietly.
    function test_handlerReachesEveryAction() public {
        handler.actOpen(true, 3, 0, 1, false);
        handler.actOpen(false, 2, 1, 2, true);
        handler.actIncrease(0, 2, 1_000e6, false);
        handler.actWarp(3 days);
        handler.actSettle(0);
        // Income vests over a day before it can be claimed.
        handler.actWarp(2 days);
        handler.actClaimAny();
        handler.actClose(0, true, 1);
        handler.actWithdraw(0, 0, 0.5e18);
        handler.actMovePrice(200);
        handler.actWarp(5 days);
        handler.actWarp(5 days);
        handler.actWarp(5 days);
        handler.actForceClose(1);
        handler.actClose(0, false, 0);
        assertEq(handler.violations(), 0, handler.lastViolation());
        assertGt(handler.opens(), 0, "opens");
        assertGt(handler.increases(), 0, "increases");
        assertGt(handler.settlements(), 0, "settlements");
        assertGt(handler.claims(), 0, "claims");
        assertGt(handler.partialCloses() + handler.fullCloses(), 0, "closes");
        assertGt(handler.withdrawals(), 0, "withdrawals");
        assertGt(handler.forceCloses(), 0, "force closes");
        invariant_makerBook();
    }

    // ---------------------------------------------------------------- properties

    /// @dev The book's totals are the sums of its buckets, every bucket's shares are its makers', every bucket's loans
    /// are exactly what open legs borrowed from it, and every active bucket's loans are within the ceiling.
    function _assertBuckets() private view {
        (uint256 book0, uint256 book1,,) = vault.bookTotalsOf(vaultId);
        uint256 sum0;
        uint256 sum1;
        uint256 count = handler.bucketCount();
        // count <= 24 buckets: no fills without a pool, so generations never advance
        for (uint256 index = 0; index < count; ++index) {
            uint256 bucketId = handler.bucketIds(index);
            Bucket memory bucket = vault.bucketOf(vaultId, bucketId);
            sum0 += bucket.balance0;
            sum1 += bucket.balance1;
            uint256 shares = vault.makerShareOf(vaultId, bucketId, handler.makerAt(0)).shares
                + vault.makerShareOf(vaultId, bucketId, handler.makerAt(1)).shares;
            assertEq(bucket.totalShares, shares, "bucket shares are its makers'");
            assertEq(bucket.lent, _lentFrom(bucketId), "bucket loans are its open legs'");
            if (!bucket.retired) _assertWithinCeiling(bucketId, bucket);
            _assertOwned(bucket);
        }
        assertEq(book0, sum0, "book token0 is its buckets'");
        assertEq(book1, sum1, "book token1 is its buckets'");
    }

    /// @dev Every open position holds the aggregate chord with its per-leg rounding reserve, so every leg can repay.
    function _assertPositions() private view {
        uint256 count = handler.positionCount();
        // count <= the run's opens
        for (uint256 index = 0; index < count; ++index) {
            MakerPosition memory position = vault.makerPositionOf(handler.positionIds(index));
            if (position.owner == address(0)) continue;
            assertTrue(
                MakerMath.aggregateChordHolds(
                    position.reserve0, position.reserve1, position.maximum0, position.maximum1, position.legCount
                ),
                "open position on its aggregate chord"
            );
        }
    }

    /// @dev A bucket with loans out keeps a share, and a bucket with no shares has nothing vesting.
    function _assertOwned(Bucket memory bucket) private pure {
        if (bucket.lent != 0) assertGt(bucket.totalShares, 0, "a bucket with loans keeps an owner");
        if (bucket.totalShares != 0) return;
        assertEq(bucket.stream0Remaining, 0, "no shares, nothing vesting in token0");
        assertEq(bucket.stream1Remaining, 0, "no shares, nothing vesting in token1");
    }

    function _assertWithinCeiling(uint256 bucketId, Bucket memory bucket) private pure {
        (int24 level, bool isBuy,) = MakerMath.decode(bucketId);
        (uint160 sqrtLowerX96, uint160 sqrtUpperX96) = levelSqrtPrices(level);
        uint256 waiting = isBuy ? bucket.balance1 : bucket.balance0;
        uint256 capacity = MakerMath.liquidityFor(isBuy, waiting, sqrtLowerX96, sqrtUpperX96);
        uint256 lent = bucket.lent;
        assertLe(lent * 10_000, (lent + capacity) * 9_000, "active bucket within the ceiling");
    }

    function _lentFrom(uint256 bucketId) private view returns (uint256 lent) {
        uint256 count = handler.positionCount();
        // count <= the run's opens
        for (uint256 index = 0; index < count; ++index) {
            uint256 positionId = handler.positionIds(index);
            MakerPosition memory position = vault.makerPositionOf(positionId);
            if (position.owner == address(0)) continue;
            // legCount <= MAX_LEGS
            for (uint256 legIndex = 0; legIndex < position.legCount; ++legIndex) {
                Leg memory leg = vault.legOf(positionId, legIndex);
                if (leg.bucketId == bucketId) lent += leg.liquidity;
            }
        }
    }

    function _actions() private view returns (bytes4[] memory selectors) {
        selectors = new bytes4[](12);
        selectors[0] = handler.actDeposit.selector;
        selectors[1] = handler.actWithdraw.selector;
        selectors[2] = handler.actClaim.selector;
        selectors[3] = handler.actOpen.selector;
        selectors[4] = handler.actAddEscrow.selector;
        selectors[5] = handler.actSettle.selector;
        selectors[6] = handler.actClose.selector;
        selectors[7] = handler.actForceClose.selector;
        selectors[8] = handler.actWarp.selector;
        selectors[9] = handler.actMovePrice.selector;
        selectors[10] = handler.actOpen.selector;
        selectors[11] = handler.actIncrease.selector;
    }

    /// @dev Each owner's listed maker positions are exactly their open ones (`positionsOf`): opens list them, increases
    /// keep them, and full and forced closes take them out however the list is reordered.
    function _assertOwnerLists() private view {
        uint256 count = handler.positionCount();
        address[] memory owners = new address[](count);
        uint256 ownerCount;
        uint256 open;
        // count <= the run's opens
        for (uint256 index = 0; index < count; ++index) {
            uint256 positionId = handler.positionIds(index);
            address owner = vault.makerPositionOf(positionId).owner;
            if (owner == address(0)) continue;
            open += 1;
            assertTrue(_contains(_listed(owner), positionId), "an open position is in its owner's list");
            ownerCount = _addOwner(owners, ownerCount, owner);
        }
        uint256 listedTotal;
        // ownerCount <= count
        for (uint256 index = 0; index < ownerCount; ++index) {
            listedTotal += _listed(owners[index]).length;
        }
        assertEq(listedTotal, open, "the lists hold only open positions");
    }

    function _listed(address owner) private view returns (uint256[] memory listed) {
        (, listed) = vault.positionsOf(owner);
    }

    function _contains(uint256[] memory positionIds, uint256 positionId) private pure returns (bool) {
        // positionIds.length <= the owner's open positions
        for (uint256 index = 0; index < positionIds.length; ++index) {
            if (positionIds[index] == positionId) return true;
        }
        return false;
    }

    /// @dev Appends `owner` to the first `ownerCount` owners if it is not there yet; returns the new count.
    function _addOwner(address[] memory owners, uint256 ownerCount, address owner) private pure returns (uint256) {
        // ownerCount <= owners.length
        for (uint256 index = 0; index < ownerCount; ++index) {
            if (owners[index] == owner) return ownerCount;
        }
        owners[ownerCount] = owner;
        return ownerCount + 1;
    }
}
