// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {KernelHook} from "../../src/KernelHook.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {IKernelHook} from "../../src/interfaces/IKernelHook.sol";
import {CallbackType, ExtensionSettings, Operation, RouteAction} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice The actions of the invariant test. The fuzzer calls these functions in random order with random inputs.
/// @dev Each function is one transaction. If it reverts, the fuzzer discards it, so a function can try an action
/// that is not valid now (for example a route swap that the router's vault balance cannot pay for) without a guard.
/// The handler keeps a model (ghost state) of the route liquidity and of each installation's vault balances. It
/// updates the model only from the requested amounts and from the results that each successful action reports.
contract KernelHookHandler is Test {
    /// @dev Extension 0 starts routes (required). Extension 1 is optional and can fail. Extension 2 charges a fee.
    uint256 internal constant ROUTER = 0;
    uint256 internal constant OPTIONAL = 1;
    uint256 internal constant FEE_TAKER = 2;

    int24 internal constant ROUTE_TICK_LOWER = -60;
    int24 internal constant ROUTE_TICK_UPPER = 60;

    KernelHook public immutable hook;
    PoolSwapTest internal immutable swapRouter;
    /// @dev The router without balance assertions: v4's checked router assumes that an addition always costs
    /// the caller and a removal always pays it, which fees and very small amounts can break.
    PoolModifyLiquidityTestNoChecks internal immutable liquidityRouter;
    PoolDonateTest internal immutable donateRouter;
    /// @dev An optional extension of the route pool, so that routes run nested extension calls.
    MockExtension public immutable observer;

    PoolKey[2] internal _keys;
    Currency[2] internal _currencies;
    MockExtension[3] internal _extensions;
    uint256[2] internal _handlerLiquidity;
    int128 internal _fee;

    /// @notice The route liquidity that the requested additions and removals add up to.
    uint256 public ghostRouteLiquidity;
    /// @notice The vault balance of each installation of pool 0 in each currency, from the model.
    int256[2][3] public ghostBalance;

    mapping(string => uint256) public successfulCalls;

    constructor(
        KernelHook kernelHook,
        PoolSwapTest swapRouter_,
        PoolModifyLiquidityTestNoChecks liquidityRouter_,
        PoolDonateTest donateRouter_,
        PoolKey[2] memory keys,
        MockExtension[3] memory extensions,
        MockExtension observer_
    ) {
        hook = kernelHook;
        swapRouter = swapRouter_;
        liquidityRouter = liquidityRouter_;
        donateRouter = donateRouter_;
        observer = observer_;
        // The legacy compiler cannot copy a memory array of structs to storage at once.
        _keys[0] = keys[0];
        _keys[1] = keys[1];
        _extensions = extensions;
        _currencies[0] = keys[0].currency0;
        _currencies[1] = keys[0].currency1;
        // currencyIndex < 2
        for (uint256 i; i < 2; ++i) {
            IERC20 token = IERC20(Currency.unwrap(_currencies[i]));
            token.approve(address(swapRouter_), type(uint256).max);
            token.approve(address(liquidityRouter_), type(uint256).max);
            token.approve(address(donateRouter_), type(uint256).max);
        }
    }

    function swap(uint256 poolSeed, bool zeroForOne, uint256 amount, bool exactOutput) external {
        amount = bound(amount, 1e6, exactOutput ? 1e12 : 1e14);
        SwapParams memory parameters = _exactInput(zeroForOne, amount);
        if (exactOutput) parameters.amountSpecified = int256(amount);
        _swap(_keys[poolSeed % 2], parameters);
        ++successfulCalls["swap"];
    }

    function addLiquidity(uint256 poolSeed, uint256 liquidity) external {
        uint256 index = poolSeed % 2;
        liquidity = bound(liquidity, 1e9, 1e17);
        liquidityRouter.modifyLiquidity(_keys[index], _handlerRange(int256(liquidity)), "");
        _handlerLiquidity[index] += liquidity;
        ++successfulCalls["addLiquidity"];
    }

    function removeLiquidity(uint256 poolSeed, uint256 liquidity) external {
        uint256 index = poolSeed % 2;
        if (_handlerLiquidity[index] == 0) return;
        liquidity = bound(liquidity, 1, _handlerLiquidity[index]);
        liquidityRouter.modifyLiquidity(_keys[index], _handlerRange(-int256(liquidity)), "");
        _handlerLiquidity[index] -= liquidity;
        ++successfulCalls["removeLiquidity"];
    }

    function donate(uint256 poolSeed, uint256 amount) external {
        amount = bound(amount, 1, 1e12);
        donateRouter.donate(_keys[poolSeed % 2], amount, amount, "");
        ++successfulCalls["donate"];
    }

    /// @notice Sets the amount of currency0 that the fee taker charges (positive) or pays (negative) in beforeSwap.
    function setFee(int256 fee) external {
        _fee = int128(bound(fee, -1e6, 1e6));
        _extensions[FEE_TAKER].setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(_fee, 0, 0, false, 0));
    }

    /// @notice Makes an optional extension (of pool 0 or of the route pool) fail, or stop failing, in one callback.
    function setOptionalFailure(bool routePool, uint256 callbackSeed, bool shouldRevert) external {
        MockExtension target = routePool ? observer : _extensions[OPTIONAL];
        CallbackType callback = CallbackType(2 + callbackSeed % 8);
        target.setBehavior(callback, MockExtension.Behavior(0, 0, 0, shouldRevert, 0));
    }

    function deposit(uint256 extensionSeed, uint256 currencySeed, uint256 amount) external {
        uint256 index = extensionSeed % 3;
        uint256 currencyIndex = currencySeed % 2;
        amount = bound(amount, 1, 1e16);
        IERC20(Currency.unwrap(_currencies[currencyIndex])).transfer(address(_extensions[index]), amount);
        _extensions[index].deposit(_keys[0].toId(), _currencies[currencyIndex], amount);
        ghostBalance[index][currencyIndex] += int256(amount);
        ++successfulCalls["deposit"];
    }

    function withdraw(uint256 extensionSeed, uint256 currencySeed, uint256 amount) external {
        uint256 index = extensionSeed % 3;
        uint256 currencyIndex = currencySeed % 2;
        int256 balance = ghostBalance[index][currencyIndex];
        if (balance <= 0) return;
        amount = bound(amount, 1, uint256(balance));
        _extensions[index].withdraw(_keys[0].toId(), _currencies[currencyIndex], amount, address(this));
        ghostBalance[index][currencyIndex] -= int256(amount);
        ++successfulCalls["withdraw"];
    }

    /// @notice In afterSwap of the main pool, the router swaps on the route pool.
    function routeSwap(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 1e6, 1e12);
        RouteAction memory action = RouteAction({
            key: _keys[1],
            operation: Operation.Swap,
            parameters: abi.encode(_exactInput(zeroForOne, amount)),
            hookData: ""
        });
        _swapWithRoute(action);
        ++successfulCalls["routeSwap"];
    }

    /// @notice In afterSwap of the main pool, the router changes its liquidity in the route pool.
    function routeLiquidity(int256 liquidityDelta) external {
        liquidityDelta = bound(liquidityDelta, -int256(ghostRouteLiquidity), 1e15);
        _swapWithRoute(_routeLiquidityAction(liquidityDelta));
        ghostRouteLiquidity = uint256(int256(ghostRouteLiquidity) + liquidityDelta);
        ++successfulCalls["routeLiquidity"];
    }

    /// @notice The router closes part of its route position through unwindPositions, which needs an inactive
    /// installation. The router is deactivated for the call and then activated again, if it was active.
    function unwind(uint256 liquidity) external {
        if (ghostRouteLiquidity == 0) return;
        liquidity = bound(liquidity, 1, ghostRouteLiquidity);
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = _routeLiquidityAction(-int256(liquidity));
        bool active = _isActive(ROUTER);
        if (active) hook.deactivateExtension(_keys[0], _extension(ROUTER));
        BalanceDelta[] memory results = _extensions[ROUTER].unwindPositions(_keys[0], actions);
        if (active) hook.activateExtension(_keys[0], _extension(ROUTER));
        _addRouterResults(results);
        ghostRouteLiquidity -= liquidity;
        ++successfulCalls["unwind"];
    }

    /// @notice Deactivates an active extension, or activates an inactive one.
    function toggleActive(uint256 extensionSeed) external {
        uint256 index = extensionSeed % 3;
        if (_isActive(index)) hook.deactivateExtension(_keys[0], _extension(index));
        else hook.activateExtension(_keys[0], _extension(index));
        ++successfulCalls["toggleActive"];
    }

    /// @notice Sets a new order of the three swap subscribers in one multicall: deactivate the active ones, set the
    /// order of both swap callbacks, and activate the same ones again.
    function reorder(uint256 permutationSeed) external {
        address[] memory order = _permutation(permutationSeed % 6);
        bool[3] memory active = [_isActive(0), _isActive(1), _isActive(2)];
        bytes[] memory calls = new bytes[](8);
        uint256 count;
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            if (active[j]) calls[count++] = abi.encodeCall(IKernelHook.deactivateExtension, (_keys[0], _extension(j)));
        }
        calls[count++] = abi.encodeCall(IKernelHook.setCallbackOrder, (_keys[0], CallbackType.BeforeSwap, order));
        calls[count++] = abi.encodeCall(IKernelHook.setCallbackOrder, (_keys[0], CallbackType.AfterSwap, order));
        // extensionIndex < 3
        for (uint256 j; j < 3; ++j) {
            if (active[j]) calls[count++] = abi.encodeCall(IKernelHook.activateExtension, (_keys[0], _extension(j)));
        }
        hook.multicall(_shorten(calls, count));
        ++successfulCalls["reorder"];
    }

    /// @notice Gives the optional extension a new callback gas limit and a new configuration size, in one multicall.
    /// The configuration size changes KernelHook's gas reserve for each call of the extension.
    function reconfigure(uint256 gasLimit, uint256 configurationBytes) external {
        (, ExtensionSettings memory settings,) =
            hook.extensionConfiguration(_keys[0].toId(), address(_extensions[OPTIONAL]));
        uint32 limit = uint32(bound(gasLimit, 200_000, 600_000));
        // i < CALLBACK_COUNT
        for (uint256 i; i < settings.callbackGasLimits.length; ++i) {
            settings.callbackGasLimits[i] = limit;
        }
        settings.configuration = new bytes(bound(configurationBytes, 0, 1024));
        bool active = _isActive(OPTIONAL);
        bytes[] memory calls = new bytes[](3);
        uint256 count;
        if (active) calls[count++] = abi.encodeCall(IKernelHook.deactivateExtension, (_keys[0], _extension(OPTIONAL)));
        calls[count++] = abi.encodeCall(IKernelHook.configureExtension, (_keys[0], _extension(OPTIONAL), settings));
        if (active) calls[count++] = abi.encodeCall(IKernelHook.activateExtension, (_keys[0], _extension(OPTIONAL)));
        hook.multicall(_shorten(calls, count));
        ++successfulCalls["reconfigure"];
    }

    /// @notice The router's liquidity in its one route position, as the route executor records it.
    function trackedRouteLiquidity() public view returns (uint256) {
        return hook.ROUTE_EXECUTOR()
            .positionLiquidity(
                _keys[0].toId(),
                address(_extensions[ROUTER]),
                _keys[1].toId(),
                ROUTE_TICK_LOWER,
                ROUTE_TICK_UPPER,
                bytes32(0)
            );
    }

    function _swapWithRoute(RouteAction memory action) private {
        MockExtension router = _extensions[ROUTER];
        uint256 calls = router.callCount(CallbackType.AfterSwap);
        router.addRouteAction(CallbackType.AfterSwap, action);
        _swap(_keys[0], _exactInput(true, 1e10));
        router.clearRoute(CallbackType.AfterSwap);
        // KernelHook skips an inactive router, so the swap succeeds without the route. That call must not count.
        require(router.callCount(CallbackType.AfterSwap) > calls, "route did not run");
        _addRouterResults(router.lastRouteResults());
    }

    /// @dev Every swap of pool 0 in which the fee taker runs moves its fee in currency0.
    function _swap(PoolKey memory key, SwapParams memory parameters) private {
        MockExtension feeTaker = _extensions[FEE_TAKER];
        uint256 feeCalls = feeTaker.callCount(CallbackType.BeforeSwap);
        swapRouter.swap(key, parameters, PoolSwapTest.TestSettings(false, false), "");
        uint256 charged = feeTaker.callCount(CallbackType.BeforeSwap) - feeCalls;
        ghostBalance[FEE_TAKER][0] += int256(charged) * _fee;
    }

    /// @dev A route result is the PoolManager delta that the vault settles for the router: a negative amount is paid
    /// from the router's balance, and a positive amount is credited to it.
    function _addRouterResults(BalanceDelta[] memory results) private {
        // results.length <= MAX_ACTIONS
        for (uint256 i; i < results.length; ++i) {
            ghostBalance[ROUTER][0] += results[i].amount0();
            ghostBalance[ROUTER][1] += results[i].amount1();
        }
    }

    function _isActive(uint256 index) private view returns (bool active) {
        (active,,) = hook.extensionConfiguration(_keys[0].toId(), address(_extensions[index]));
    }

    function _extension(uint256 index) private view returns (IHookExtension) {
        return IHookExtension(address(_extensions[index]));
    }

    function _permutation(uint256 index) private view returns (address[] memory order) {
        uint8[3][6] memory permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
        order = new address[](3);
        // position < 3
        for (uint256 i; i < 3; ++i) {
            order[i] = address(_extensions[permutations[index][i]]);
        }
    }

    function _shorten(bytes[] memory calls, uint256 count) private pure returns (bytes[] memory result) {
        result = new bytes[](count);
        // i < count <= calls.length
        for (uint256 i; i < count; ++i) {
            result[i] = calls[i];
        }
    }

    function _exactInput(bool zeroForOne, uint256 amount) private pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _handlerRange(int256 liquidityDelta) private pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: liquidityDelta, salt: 0});
    }

    function _routeLiquidityAction(int256 liquidityDelta) private view returns (RouteAction memory) {
        ModifyLiquidityParams memory parameters = ModifyLiquidityParams({
            tickLower: ROUTE_TICK_LOWER, tickUpper: ROUTE_TICK_UPPER, liquidityDelta: liquidityDelta, salt: bytes32(0)
        });
        return RouteAction({
            key: _keys[1], operation: Operation.ModifyLiquidity, parameters: abi.encode(parameters), hookData: ""
        });
    }
}
