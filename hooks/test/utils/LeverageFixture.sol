// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ExtensionFixture} from "./ExtensionFixture.sol";
import {Leverage, IFeeVault} from "../../src/leverage/Leverage.sol";
import {Curve} from "../../src/libraries/leverage/LeverageMath.sol";
import {Bin, Position} from "../../src/libraries/leverage/LeverageBins.sol";
import {LeverageEngine, OpenRequest} from "../../src/libraries/leverage/LeverageEngine.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {CallbackType, ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";

/// @dev Test-side mirror of a force close's first step, so tests can make exactly that swap fail and drive the strike
/// fallback without breaking the force close's other swap.
library LeverageTestLib {
    /// @dev The calldata of the deficit purchase a full force close of `positionId` makes now, or empty if the
    /// position's reserves already cover the return.
    function deficitSwapCall(Leverage leverage, IPoolManager manager, uint256 positionId)
        internal
        view
        returns (bytes memory)
    {
        Position memory held = leverage.positionOf(positionId);
        (uint256 needed0, uint256 needed1) = returnCost(leverage, manager, positionId, held);
        uint256 deficitIndex = held.reserve0 < needed0 ? 0 : 1;
        uint256 deficit =
            deficitIndex == 0 ? needed0 - held.reserve0 : needed1 > held.reserve1 ? needed1 - held.reserve1 : 0;
        if (deficit == 0) return "";
        bool zeroForOne = deficitIndex == 1;
        uint160 limitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        SwapParams memory params = SwapParams(zeroForOne, int256(deficit), limitX96);
        return abi.encodeCall(IPoolManager.swap, (leverage.poolKey(), params, ""));
    }

    /// @dev What v4 charges now to return every borrow of the position, rounded up as Pool.modifyLiquidity does.
    function returnCost(Leverage leverage, IPoolManager manager, uint256 positionId, Position memory held)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = StateLibrary.getSlot0(manager, leverage.POOL_ID());
        // held.binCount <= MAX_BINS
        for (uint256 offset; offset < held.binCount; ++offset) {
            uint128 liquidity = leverage.borrowOf(positionId, offset).liquidity;
            (int24 tickLower, int24 tickUpper) = leverage.binTicks(held.lowerBin + int24(int256(offset)));
            (uint256 cost0, uint256 cost1) = addCost(liquidity, tickLower, tickUpper, tick, sqrtPriceX96);
            amount0 += cost0;
            amount1 += cost1;
        }
    }

    function addCost(uint128 liquidity, int24 tickLower, int24 tickUpper, int24 tick, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (tick < tickLower) return (SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true), 0);
        if (tick >= tickUpper) return (0, SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true));
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
    }
}

/// @dev Pulls the whole approved amount, as the fee vault's minimal interface promises.
contract MockFeeVault is IFeeVault {
    mapping(address token => uint256) public received;
    bool public pullNothing;

    function setPullNothing(bool value) external {
        pullNothing = value;
    }

    function deposit(Currency currency, uint256 amount) external {
        if (pullNothing) return;
        IERC20(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
        received[Currency.unwrap(currency)] += amount;
    }
}

/// @dev A Leverage pool with no outside liquidity: the extension is installed and active before initialize, so
/// every unit of the pool's liquidity enters through `deposit`. Quote is currency1, so a long holds currency0.
abstract contract LeverageFixture is ExtensionFixture {
    int24 internal constant LEVERAGE_TICK_SPACING = 60;
    uint24 internal constant BIN_WIDTH = 10;
    int24 internal constant BIN_TICKS = 600;
    /// @dev The middle of bin 0.
    int24 internal constant START_TICK = 300;
    uint128 internal constant LENDER_LIQUIDITY = 1e21;
    uint256 internal constant ACTOR_FUNDS = 1e30;
    uint32 internal constant GRACE_SECONDS = 1 days;
    uint32 internal constant VEST_SECONDS = 1 days;

    Leverage internal leverage;
    MockFeeVault internal feeVault;
    PoolKey internal leverageKey;
    PoolId internal leveragePool;
    address internal treasury = makeAddr("treasury");
    address internal lenderA = makeAddr("lenderA");
    address internal lenderB = makeAddr("lenderB");
    address internal trader = makeAddr("trader");
    address internal closer = makeAddr("closer");
    address internal swapper = makeAddr("swapper");

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1_000);
        feeVault = new MockFeeVault();
        leverageKey = PoolKey(currency0, currency1, 500, LEVERAGE_TICK_SPACING, IHooks(address(hook)));
        leveragePool = leverageKey.toId();
        leverage = new Leverage(IKernelHook(address(hook)), _deployment(leverageKey));
        catalog.admit(
            address(leverage),
            IHookCatalog.Entry(address(leverage).codehash, leverage.CALLBACK_MASK(), false, false, false, false, true)
        );
        hook.preparePool(leverageKey);
        hook.installExtension(leverageKey, IHookExtension(address(leverage)), _leverageSettings(_curve()));
        hook.activateExtension(leverageKey, IHookExtension(address(leverage)));
        manager.initialize(leverageKey, TickMath.getSqrtPriceAtTick(START_TICK));
        _fundActor(lenderA);
        _fundActor(lenderB);
        _fundActor(trader);
        _fundActor(closer);
        _fundActor(swapper);
        _fundActor(address(this));
    }

    function _deployment(PoolKey memory target) internal view returns (Leverage.Deployment memory) {
        return Leverage.Deployment({
            key: target,
            quoteIsCurrency0: _quoteIsCurrency0(),
            treasury: treasury,
            feeVault: address(feeVault),
            profitShareBps: 100,
            treasuryShareBps: 2500,
            feeVaultShareBps: 2500,
            utilizationCeilingBps: 9500,
            maxBinsPerPosition: 16,
            minRewardBps: 0,
            maxRewardBps: 1000,
            maxBinWidth: 1000,
            maxRateWad: 10e18,
            graceSeconds: GRACE_SECONDS,
            vestSeconds: VEST_SECONDS,
            minBorrowNotional: 1e3
        });
    }

    /// @dev The main suites quote in currency1; LeverageQuote0Test flips it.
    function _quoteIsCurrency0() internal pure virtual returns (bool) {
        return false;
    }

    function _curve() internal pure returns (Curve memory) {
        return Curve({
            binWidth: BIN_WIDTH,
            forceCloseRewardBps: 100,
            kinkWad: 0.8e18,
            baseRateWad: 0,
            slope1Wad: 0.04e18,
            slope2Wad: 3e18
        });
    }

    function _leverageSettings(Curve memory curve) internal pure returns (ExtensionSettings memory settings) {
        settings.callbackMask = uint16(1) << uint8(CallbackType.BeforeAddLiquidity);
        settings.lifecycleGasLimit = 500_000;
        settings.callbackGasLimits[uint8(CallbackType.BeforeAddLiquidity)] = 50_000;
        settings.configuration = abi.encode(curve);
    }

    function _fundActor(address actor) internal {
        MockERC20(Currency.unwrap(currency0)).mint(actor, ACTOR_FUNDS);
        MockERC20(Currency.unwrap(currency1)).mint(actor, ACTOR_FUNDS);
        vm.startPrank(actor);
        IERC20(Currency.unwrap(currency0)).approve(address(leverage), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(leverage), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- actions

    function _deposit(address actor, int24 lowerBin, uint8 binCount, uint128 liquidityPerBin)
        internal
        returns (uint256 paid0, uint256 paid1)
    {
        vm.prank(actor);
        return leverage.deposit(lowerBin, binCount, liquidityPerBin, type(uint256).max, type(uint256).max);
    }

    /// @dev Ten bins around the start price, from bin -5 to bin 4, from two lenders.
    function _seedLenders() internal {
        _deposit(lenderA, -5, 10, LENDER_LIQUIDITY);
        _deposit(lenderB, -5, 10, LENDER_LIQUIDITY);
    }

    function _uniform(uint256 binCount, uint128 liquidity) internal pure returns (uint128[] memory amounts) {
        amounts = new uint128[](binCount);
        // binCount <= MAX_BINS
        for (uint256 i; i < binCount; ++i) {
            amounts[i] = liquidity;
        }
    }

    function _openRequest(int24 lowerBin, uint128[] memory amounts, bool long, uint128 collateral, uint128 premium)
        internal
        pure
        returns (OpenRequest memory request)
    {
        request.lowerBin = lowerBin;
        request.liquidity = amounts;
        request.long = long;
        request.collateral = collateral;
        request.premium = premium;
        // A long sells the quote and a short sells the base; selling currency0 moves the price down.
        bool sellsCurrency0 = long == _quoteIsCurrency0();
        request.sqrtPriceLimitX96 = sellsCurrency0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
    }

    function _open(address actor, OpenRequest memory request) internal returns (uint256 positionId) {
        vm.prank(actor);
        return leverage.open(request);
    }

    /// @dev A long below the price: borrows bins -3 to -1, whose liquidity is all quote at the start price.
    function _openLong(uint128 perBin, uint128 collateral, uint128 premium) internal returns (uint256) {
        return _open(trader, _openRequest(-3, _uniform(3, perBin), true, collateral, premium));
    }

    /// @dev A short above the price: borrows bins 1 to 3, whose liquidity is all base at the start price.
    function _openShort(uint128 perBin, uint128 collateral, uint128 premium) internal returns (uint256) {
        return _open(trader, _openRequest(1, _uniform(3, perBin), false, collateral, premium));
    }

    /// @dev Flags a delinquent position and waits out the grace period, so it can be force closed.
    function _flagAndWaitGrace(uint256 positionId) internal {
        leverage.flagDelinquent(positionId);
        vm.warp(block.timestamp + GRACE_SECONDS);
    }

    /// @dev Makes the force close's deficit purchase fail as a pool too thin or costly to buy it would, so the strike
    /// fallback runs. Returns false if the position needs no purchase.
    function _failDeficitPurchase(uint256 positionId) internal returns (bool) {
        bytes memory call = LeverageTestLib.deficitSwapCall(leverage, manager, positionId);
        if (call.length == 0) return false;
        vm.mockCallRevert(address(manager), call, abi.encodePacked(LeverageEngine.InsufficientProceeds.selector));
        return true;
    }

    function _swapAs(address actor, bool zeroForOne, uint256 amountIn) internal {
        vm.prank(actor);
        _swapExactInput(leverageKey, zeroForOne, amountIn);
    }

    // ---------------------------------------------------------------- reads

    function _balance(Currency currency, address account) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(account);
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(manager, leveragePool);
    }

    function _binOfTick(int24 tick) internal pure returns (int24) {
        int24 binIndex = tick / BIN_TICKS;
        if (tick < 0 && tick % BIN_TICKS != 0) --binIndex;
        return binIndex;
    }

    function _idle(int24 binIndex) internal view returns (uint128) {
        Bin memory target = leverage.binOf(binIndex);
        return target.liquidity - target.borrowed;
    }

    function _v4PositionLiquidity(int24 binIndex) internal view returns (uint128 liquidity) {
        (int24 tickLower, int24 tickUpper) = leverage.binTicks(binIndex);
        (liquidity,,) = StateLibrary.getPositionInfo(
            manager, leveragePool, address(leverage), tickLower, tickUpper, bytes32(uint256(uint24(binIndex)))
        );
    }

    /// @dev The pool's active liquidity belongs to the bin under the tick, and equals its idle part.
    function _assertActiveLiquidityIsBins() internal view {
        int24 tick = _currentTick();
        int24 binIndex = _binOfTick(tick);
        assertEq(StateLibrary.getLiquidity(manager, leveragePool), _idle(binIndex), "active liquidity");
    }

    function _assertBinMatchesPool(int24 binIndex) internal view {
        Bin memory target = leverage.binOf(binIndex);
        assertLe(target.borrowed, target.liquidity, "borrowed above liquidity");
        assertEq(_v4PositionLiquidity(binIndex), target.liquidity - target.borrowed, "v4 position is the idle part");
    }

    function _positionValueAt(Position memory held, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX96 = uint256(sqrtPriceX96) * sqrtPriceX96 >> 96;
        return (uint256(held.reserve0) * priceX96 >> 96) + held.reserve1;
    }
}
