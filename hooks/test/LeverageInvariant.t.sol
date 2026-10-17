// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {LeverageFixture} from "./utils/LeverageFixture.sol";
import {Leverage} from "../src/leverage/Leverage.sol";
import {LeverageMath} from "../src/libraries/leverage/LeverageMath.sol";
import {Bin, Position} from "../src/libraries/leverage/LeverageBins.sol";
import {LeverageEngine, OpenRequest} from "../src/libraries/leverage/LeverageEngine.sol";
import {Curve} from "../src/libraries/leverage/LeverageMath.sol";
import {LeverageTestLib} from "./utils/LeverageFixture.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {CallbackType, ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @dev Drives deposits, withdrawals, opens, closes, premium, force closes, outside swaps and time. Records ghosts for
/// the properties that need history: profit-share credit, withdrawals of borrowed liquidity, borrows above the
/// ceiling and value reaching traders outside a close.
contract LeverageHandler is CommonBase, StdCheats, StdUtils {
    uint256 internal constant Q128 = 1 << 128;
    bytes32 internal constant CLOSED_TOPIC = keccak256("Closed(uint256,address,uint256,uint256,uint256)");
    int24 public constant LOWEST_BIN = -8;
    int24 public constant HIGHEST_BIN = 7;

    Leverage public leverage;
    PoolSwapTest public swapRouter;
    PoolKey internal key;
    Currency internal currency0;
    Currency internal currency1;
    address[] public lenders;
    address[] public traders;
    address public swapper;
    address public closer;

    bool public withdrewBorrowed;
    bool public borrowedAboveCeiling;
    bool public valueLeftOutsideClose;
    uint256 public closes;
    uint256 public opens;

    constructor(
        Leverage leverage_,
        PoolSwapTest swapRouter_,
        PoolKey memory key_,
        address[] memory lenders_,
        address[] memory traders_,
        address swapper_,
        address closer_
    ) {
        leverage = leverage_;
        swapRouter = swapRouter_;
        key = key_;
        currency0 = key_.currency0;
        currency1 = key_.currency1;
        lenders = lenders_;
        traders = traders_;
        swapper = swapper_;
        closer = closer_;
    }

    function lenderCount() external view returns (uint256) {
        return lenders.length;
    }

    function traderCount() external view returns (uint256) {
        return traders.length;
    }

    // ---------------------------------------------------------------- lenders

    function deposit(uint256 actorSeed, int256 lowerSeed, uint256 countSeed, uint256 liquiditySeed) external {
        address actor = lenders[actorSeed % lenders.length];
        uint8 binCount = uint8(bound(countSeed, 1, 8));
        int24 lowerBin = int24(bound(lowerSeed, LOWEST_BIN, HIGHEST_BIN + 1 - int256(uint256(binCount))));
        uint128 liquidity = uint128(bound(liquiditySeed, 1e15, 2e21));
        _checkTraders();
        vm.prank(actor);
        leverage.deposit(lowerBin, binCount, liquidity, type(uint256).max, type(uint256).max);
        _requireTradersUnpaid();
    }

    function withdraw(uint256 actorSeed, int256 binSeed, uint256 amountSeed) external {
        address actor = lenders[actorSeed % lenders.length];
        int24 binIndex = int24(bound(binSeed, LOWEST_BIN, HIGHEST_BIN));
        uint128 owned = leverage.lenderOf(actor, binIndex).liquidity;
        if (owned == 0) return;
        uint128 amount = uint128(bound(amountSeed, 1, owned));
        Bin memory target = leverage.binOf(binIndex);
        uint128 idle = target.liquidity - target.borrowed;
        vm.prank(actor);
        try leverage.withdraw(binIndex, 1, amount, 0, 0, actor) {
            if (amount > idle) withdrewBorrowed = true;
        } catch {}
    }

    function collect(uint256 actorSeed) external {
        address actor = lenders[actorSeed % lenders.length];
        vm.prank(actor);
        leverage.collect(LOWEST_BIN, uint8(uint24(HIGHEST_BIN - LOWEST_BIN + 1)), actor);
    }

    // ---------------------------------------------------------------- traders

    function open(
        uint256 actorSeed,
        int256 lowerSeed,
        uint256 countSeed,
        uint256 shareSeed,
        uint256 premiumSeed,
        bool long
    ) external {
        address actor = traders[actorSeed % traders.length];
        uint256 binCount = bound(countSeed, 1, 4);
        int24 lowerBin = int24(bound(lowerSeed, LOWEST_BIN, HIGHEST_BIN + 1 - int256(binCount)));
        uint128[] memory amounts = new uint128[](binCount);
        uint256 total;
        // binCount <= 4
        for (uint256 offset; offset < binCount; ++offset) {
            Bin memory target = leverage.binOf(lowerBin + int24(int256(offset)));
            // Up to the 95% ceiling of the bin, from what is left.
            uint256 room = uint256(target.liquidity) * 9500 / 10_000;
            if (room <= target.borrowed) return;
            amounts[offset] = uint128(bound(shareSeed >> (offset * 8), 1, room - target.borrowed));
            total += amounts[offset];
        }
        OpenRequest memory request;
        request.lowerBin = lowerBin;
        request.liquidity = amounts;
        request.long = long;
        request.collateral = uint128(total / 4 + 1e15);
        request.premium = uint128(bound(premiumSeed, 1, 1e18));
        request.sqrtPriceLimitX96 = long ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        _checkTraders();
        vm.prank(actor);
        try leverage.open(request) {
            ++opens;
            _checkCeiling(lowerBin, binCount);
        } catch {}
        _requireTradersUnpaid();
    }

    function close(uint256 positionSeed, uint256 fractionSeed) external {
        uint256 id = _pickPosition(positionSeed);
        if (id == 0) return;
        address owner = leverage.positionOf(id).owner;
        uint256 fractionWad = fractionSeed % 2 == 0 ? 1e18 : bound(fractionSeed, 1e16, 1e18);
        vm.prank(owner);
        try leverage.close(id, fractionWad, 0, owner) {
            ++closes;
        } catch {}
    }

    function addPremium(uint256 positionSeed, uint256 amountSeed) external {
        uint256 id = _pickPosition(positionSeed);
        if (id == 0) return;
        address owner = leverage.positionOf(id).owner;
        _checkTraders();
        vm.prank(owner);
        leverage.addPremium(id, uint128(bound(amountSeed, 1, 1e18)));
        _requireTradersUnpaid();
    }

    function settle(uint256 positionSeed) external {
        uint256 id = _pickPosition(positionSeed);
        if (id == 0) return;
        _checkTraders();
        leverage.settlePremium(id);
        _requireTradersUnpaid();
    }

    function flag(uint256 positionSeed) external {
        uint256 id = _pickPosition(positionSeed);
        if (id == 0) return;
        if (!leverage.isDelinquent(id)) return;
        leverage.flagDelinquent(id);
    }

    function forceClose(uint256 positionSeed, bool atStrike) external {
        uint256 id = _pickPosition(positionSeed);
        if (id == 0) return;
        if (!leverage.isDelinquent(id)) return;
        uint256 flaggedAt = leverage.positionOf(id).delinquentSince;
        if (flaggedAt == 0) return;
        if (block.timestamp < flaggedAt + leverage.GRACE_SECONDS()) return;
        _checkTraders();
        // Half the force closes fail their deficit purchase, as a pool that cannot buy it would, to drive the strike.
        bytes memory deficitCall = LeverageTestLib.deficitSwapCall(leverage, swapRouter.manager(), id);
        if (atStrike) {
            if (deficitCall.length != 0) {
                vm.mockCallRevert(
                    address(swapRouter.manager()),
                    deficitCall,
                    abi.encodePacked(LeverageEngine.InsufficientProceeds.selector)
                );
            }
        }
        vm.prank(closer);
        try leverage.forceClose(id, type(uint256).max) {
            ++closes;
        } catch {}
        vm.clearMockedCalls();
        // A force close credits the owner; nothing is paid to traders directly.
        _requireTradersUnpaid();
    }

    /// @dev A curve change with positions open: a new version, pricing only the time after it.
    function configure(uint256 baseSeed, uint256 slopeSeed) external {
        Curve memory next = Curve({
            binWidth: 10,
            forceCloseRewardBps: 100,
            kinkWad: 0.8e18,
            baseRateWad: uint64(bound(baseSeed, 0, 0.05e18)),
            slope1Wad: uint64(bound(slopeSeed, 0, 0.1e18)),
            slope2Wad: 3e18
        });
        ExtensionSettings memory settings;
        settings.callbackMask = leverage.CALLBACK_MASK();
        settings.lifecycleGasLimit = 500_000;
        settings.callbackGasLimits[uint8(CallbackType.BeforeAddLiquidity)] = 50_000;
        settings.configuration = abi.encode(next);
        IKernelHook kernel = leverage.KERNEL();
        kernel.deactivateExtension(key, IHookExtension(address(leverage)));
        try kernel.configureExtension(key, IHookExtension(address(leverage)), settings) {} catch {}
        kernel.activateExtension(key, IHookExtension(address(leverage)));
    }

    // ---------------------------------------------------------------- market

    function swap(bool zeroForOne, uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1e12, 5e19);
        uint160 limitX96 = zeroForOne ? TickMath.getSqrtPriceAtTick(-4500) : TickMath.getSqrtPriceAtTick(4500);
        _checkTraders();
        vm.prank(swapper);
        try swapRouter.swap(
            key, SwapParams(zeroForOne, -int256(amount), limitX96), PoolSwapTest.TestSettings(false, false), ""
        ) {}
            catch {}
        _requireTradersUnpaid();
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 60 days));
    }

    // ---------------------------------------------------------------- ghosts

    uint256[2][] internal _traderBalances;

    function _checkTraders() internal {
        delete _traderBalances;
        // traders.length is fixed at construction
        for (uint256 i; i < traders.length; ++i) {
            _traderBalances.push([_balance(currency0, traders[i]), _balance(currency1, traders[i])]);
        }
    }

    function _requireTradersUnpaid() internal {
        // traders.length is fixed at construction
        for (uint256 i; i < traders.length; ++i) {
            if (_balance(currency0, traders[i]) > _traderBalances[i][0]) valueLeftOutsideClose = true;
            if (_balance(currency1, traders[i]) > _traderBalances[i][1]) valueLeftOutsideClose = true;
        }
    }

    function _checkCeiling(int24 lowerBin, uint256 binCount) internal {
        // binCount <= 4
        for (uint256 offset; offset < binCount; ++offset) {
            Bin memory target = leverage.binOf(lowerBin + int24(int256(offset)));
            if (uint256(target.borrowed) * 10_000 > uint256(target.liquidity) * 9500) borrowedAboveCeiling = true;
        }
    }

    function _pickPosition(uint256 seed) internal view returns (uint256) {
        uint256 last = leverage.lastPositionId();
        if (last == 0) return 0;
        // Try from a random start; at most `last` reads.
        for (uint256 step; step < last; ++step) {
            uint256 id = (seed + step) % last + 1;
            if (leverage.positionOf(id).owner != address(0)) return id;
        }
        return 0;
    }

    function _balance(Currency currency, address account) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(account);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
/// forge-config: default.invariant.fail-on-revert = false
contract LeverageInvariantTest is LeverageFixture {
    uint256 internal constant Q128 = 1 << 128;
    LeverageHandler internal handler;
    address internal traderB = makeAddr("traderB");
    address internal lenderC = makeAddr("lenderC");

    function setUp() public override {
        super.setUp();
        _fundActor(traderB);
        _fundActor(lenderC);
        _deposit(lenderA, -8, 16, 1e21);
        address[] memory lenders = new address[](3);
        lenders[0] = lenderA;
        lenders[1] = lenderB;
        lenders[2] = lenderC;
        address[] memory traders = new address[](2);
        traders[0] = trader;
        traders[1] = traderB;
        handler = new LeverageHandler(leverage, swapRouter, leverageKey, lenders, traders, swapper, closer);
        hook.grantPoolRole(leverageKey, hook.CONFIGURER_ROLE(), address(handler));
        targetContract(address(handler));
    }

    /// @dev Each bin: borrowed within its liquidity, its v4 position is exactly the idle part, and its borrowed
    /// liquidity is the sum of the open positions' borrows from it. Every unit of liquidity belongs to a lender.
    function invariant_binsMatchPositionsAndPool() public view {
        uint256 lenderSum;
        uint256 binSum;
        // binIndex in [LOWEST_BIN, HIGHEST_BIN]
        for (int24 binIndex = handler.LOWEST_BIN(); binIndex <= handler.HIGHEST_BIN(); ++binIndex) {
            Bin memory target = leverage.binOf(binIndex);
            _assertBinMatchesPool(binIndex);
            assertEq(target.borrowed, _borrowedByPositions(binIndex), "borrowed is the positions' borrows");
            binSum += target.liquidity;
            lenderSum += _lendersLiquidity(binIndex);
        }
        (uint256 totalLiquidity,,,) = leverage.totals();
        assertEq(binSum, totalLiquidity, "bins sum to the total");
        assertEq(lenderSum, totalLiquidity, "lenders own every unit");
    }

    /// @dev The pool's active liquidity is the idle part of the bin under the price: no liquidity outside the bins.
    function invariant_poolLiquidityBelongsToBins() public view {
        int24 binIndex = _binOfTick(_currentTick());
        _assertActiveLiquidityIsBins();
        if (binIndex < handler.LOWEST_BIN()) return;
        if (binIndex > handler.HIGHEST_BIN()) return;
        assertEq(_v4PositionLiquidity(binIndex), _idle(binIndex));
    }

    function invariant_openPositionsAreSolvent() public view {
        uint256 last = leverage.lastPositionId();
        uint256 open;
        // id <= lastPositionId
        for (uint256 id = 1; id <= last; ++id) {
            Position memory held = leverage.positionOf(id);
            if (held.owner == address(0)) continue;
            ++open;
            assertTrue(LeverageMath.chordHolds(held.reserve0, held.reserve1, held.maximum0, held.maximum1), "chord");
        }
        (, uint256 openPositions,,) = leverage.totals();
        assertEq(open, openPositions, "open position count");
    }

    /// @dev The contract's balances cover every liability: position reserves, escrows, owed balances, and lender
    /// earnings credited to the bins but not yet to an owed balance.
    function invariant_custodyCoversLiabilities() public view {
        (uint256 liability0, uint256 liability1) = _positionLiabilities();
        (,, uint256 totalOwed0, uint256 totalOwed1) = leverage.totals();
        liability0 += totalOwed0;
        liability1 += totalOwed1;
        (uint256 pending0, uint256 pending1) = _pendingEarnings();
        // Quote still streaming: pendingEarnings already counts what has vested since each bin's last checkpoint, so
        // only the unvested rest is added.
        liability1 += _unvestedStreams();
        assertGe(_balance(currency0, address(leverage)), liability0 + pending0, "currency0 custody");
        assertGe(_balance(currency1, address(leverage)), liability1 + pending1, "currency1 custody");
    }

    function invariant_noWithdrawalTookBorrowedLiquidity() public view {
        assertFalse(handler.withdrewBorrowed());
    }

    function invariant_noBorrowAboveTheCeiling() public view {
        assertFalse(handler.borrowedAboveCeiling());
    }

    function invariant_valueLeavesOnlyThroughClose() public view {
        assertFalse(handler.valueLeftOutsideClose());
    }

    /// @dev The handler's actions are not vacuous: its opens, closes and force closes go through.
    function test_handlerOpensClosesAndForceCloses() public {
        // Position 1 escrows a single wei of premium, so it turns delinquent; position 2 stays funded.
        handler.open(1, -4, 3, 1e20, 1, false);
        handler.open(0, 0, 2, 1e20, 1e17, true);
        assertEq(handler.opens(), 2, "opens");
        handler.swap(false, 4e19);
        // Seed 1 picks position 2.
        handler.close(1, 0);
        assertEq(handler.closes(), 1, "close");
        handler.warp(60 days);
        assertTrue(leverage.isDelinquent(1));
        handler.flag(0);
        handler.warp(1 days);
        // Seed 0 picks position 1.
        handler.forceClose(0, true);
        assertEq(handler.closes(), 2, "force close");
        (, uint256 openPositions,,) = leverage.totals();
        assertEq(openPositions, 0);
    }

    // ---------------------------------------------------------------- sums

    function _borrowedByPositions(int24 binIndex) internal view returns (uint256 sum) {
        uint256 last = leverage.lastPositionId();
        // id <= lastPositionId
        for (uint256 id = 1; id <= last; ++id) {
            Position memory held = leverage.positionOf(id);
            if (held.owner == address(0)) continue;
            int256 offset = int256(binIndex) - held.lowerBin;
            if (offset < 0) continue;
            if (offset >= int256(uint256(held.binCount))) continue;
            sum += leverage.borrowOf(id, uint256(offset)).liquidity;
        }
    }

    function _lendersLiquidity(int24 binIndex) internal view returns (uint256 sum) {
        // lenders.length == 3
        for (uint256 i; i < handler.lenderCount(); ++i) {
            sum += leverage.lenderOf(handler.lenders(i), binIndex).liquidity;
        }
    }

    function _positionLiabilities() internal view returns (uint256 liability0, uint256 liability1) {
        uint256 last = leverage.lastPositionId();
        // id <= lastPositionId
        for (uint256 id = 1; id <= last; ++id) {
            Position memory held = leverage.positionOf(id);
            liability0 += held.reserve0;
            liability1 += held.reserve1 + held.escrow;
        }
    }

    function _unvestedStreams() internal view returns (uint256 unvested) {
        // binIndex in [LOWEST_BIN, HIGHEST_BIN]
        for (int24 binIndex = handler.LOWEST_BIN(); binIndex <= handler.HIGHEST_BIN(); ++binIndex) {
            (uint256 remaining, uint256 vested) = leverage.streamOf(binIndex);
            unvested += remaining - vested;
        }
    }

    function _pendingEarnings() internal view returns (uint256 pending0, uint256 pending1) {
        // lenders.length == 3
        for (uint256 i; i < handler.lenderCount(); ++i) {
            // binIndex in [LOWEST_BIN, HIGHEST_BIN]
            for (int24 binIndex = handler.LOWEST_BIN(); binIndex <= handler.HIGHEST_BIN(); ++binIndex) {
                (uint256 amount0, uint256 amount1) = leverage.pendingEarnings(handler.lenders(i), binIndex);
                pending0 += amount0;
                pending1 += amount1;
            }
        }
    }
}
