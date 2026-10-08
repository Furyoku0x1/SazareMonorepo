// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {NoopExtension} from "../mocks/NoopExtension.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {TestUniswapV2Factory, TestUniswapV2Pair} from "../mocks/TestUniswapV2.sol";
import {UniswapV2Adapter, IUniswapV2FactoryMinimal} from "../../src/adapters/UniswapV2Adapter.sol";
import {
    CallbackType,
    ExtensionSettings,
    ExternalSwapParameters,
    Operation,
    RouteAction
} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice Gas baseline for KernelHook. Each test builds its scenario, then measures exactly one call.
/// @dev Run with `forge test --isolate --match-path test/gas/*` for numbers close to a chain: in isolate mode each
/// top-level call is its own transaction, so cold access costs and the refund limit apply. The results go to
/// snapshots/KernelHook.json. The NoopExtension keeps the extension's own cost close to zero.
contract KernelHookGasTest is KernelHookFixture {
    string internal constant GROUP = "KernelHook";
    uint256 internal constant SWAP_AMOUNT = 1e14;

    /// @dev Eight required extensions at this limit fit the default budget:
    /// 8 * (100,000 + 3,225 + 250,000) + 80,000 + 25,000 + 8 * (25,000 + 12,000) = 3,226,800.
    uint32 internal constant NOOP_GAS_LIMIT = 100_000;

    uint16 internal constant ADD_LIQUIDITY_CALLBACKS =
        uint16(1) << uint8(CallbackType.BeforeAddLiquidity) | uint16(1) << uint8(CallbackType.AfterAddLiquidity);
    uint16 internal constant REMOVE_LIQUIDITY_CALLBACKS =
        uint16(1) << uint8(CallbackType.BeforeRemoveLiquidity) | uint16(1) << uint8(CallbackType.AfterRemoveLiquidity);
    uint16 internal constant DONATE_CALLBACKS =
        uint16(1) << uint8(CallbackType.BeforeDonate) | uint16(1) << uint8(CallbackType.AfterDonate);

    // ---------------------------------------------------------------- swaps

    function test_gas_swap_noHook() public {
        PoolKey memory key = _plainPoolKey();
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key);
        _swapExactInput(key, true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, "swap_noHook");
    }

    function test_gas_swap_0Extensions() public {
        _measureSwapWithNoops(0, false, "swap_0Extensions");
    }

    function test_gas_swap_1Extension() public {
        _measureSwapWithNoops(1, false, "swap_1Extension");
    }

    function test_gas_swap_2Extensions() public {
        _measureSwapWithNoops(2, false, "swap_2Extensions");
    }

    function test_gas_swap_4Extensions() public {
        _measureSwapWithNoops(4, false, "swap_4Extensions");
    }

    function test_gas_swap_8Extensions() public {
        _measureSwapWithNoops(8, false, "swap_8Extensions");
    }

    function test_gas_swap_2OptionalExtensions() public {
        _measureSwapWithNoops(2, true, "swap_2OptionalExtensions");
    }

    /// @dev The extension charges a fee in beforeSwap, so KernelHook takes it from the PoolManager into the vault.
    /// The settlement uses KernelHook's own reserve, not the extension's gas limit.
    function test_gas_swap_1ExtensionWithFee() public {
        PoolKey memory key = _readyPool();
        NoopExtension extension = new NoopExtension(address(hook), CallbackType.BeforeSwap, 1e10, 0);
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, false, NOOP_GAS_LIMIT));
        _swapExactInput(key, true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, "swap_1ExtensionWithFee");
    }

    // ---------------------------------------------------------------- liquidity and donations

    function test_gas_addLiquidity_noHook() public {
        PoolKey memory key = _plainPoolKey();
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key);
        vm.snapshotGasLastFrame(GROUP, "addLiquidity_noHook");
    }

    function test_gas_addLiquidity_1Extension() public {
        PoolKey memory key = _poolKey();
        _createPool(key);
        _installNoop(key, ADD_LIQUIDITY_CALLBACKS);
        _addLiquidity(key);
        vm.snapshotGasLastFrame(GROUP, "addLiquidity_1Extension");
    }

    function test_gas_removeLiquidity_noHook() public {
        PoolKey memory key = _plainPoolKey();
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key);
        _removeLiquidity(key);
        vm.snapshotGasLastFrame(GROUP, "removeLiquidity_noHook");
    }

    function test_gas_removeLiquidity_1Extension() public {
        PoolKey memory key = _readyPool();
        _installNoop(key, REMOVE_LIQUIDITY_CALLBACKS);
        _removeLiquidity(key);
        vm.snapshotGasLastFrame(GROUP, "removeLiquidity_1Extension");
    }

    function test_gas_donate_noHook() public {
        PoolKey memory key = _plainPoolKey();
        manager.initialize(key, SQRT_PRICE_1_1);
        _addLiquidity(key);
        donateRouter.donate(key, 1e12, 1e12, "");
        vm.snapshotGasLastFrame(GROUP, "donate_noHook");
    }

    function test_gas_donate_1Extension() public {
        PoolKey memory key = _readyPool();
        _installNoop(key, DONATE_CALLBACKS);
        donateRouter.donate(key, 1e12, 1e12, "");
        vm.snapshotGasLastFrame(GROUP, "donate_1Extension");
    }

    // ---------------------------------------------------------------- nested route

    /// @dev Reference for the route test: the same MockExtension, without a route.
    function test_gas_swap_1MockExtension() public {
        PoolKey memory key = _readyPool();
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, true, 1_000_000));
        _swapExactInput(key, true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, "swap_1MockExtension");
    }

    /// @dev The extension takes part of the input in beforeSwap; the Kernel credits it to the vault as claims.
    function test_gas_swap_1MockExtensionCredit() public {
        MockExtension extension = _deltaExtension();
        extension.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(int128(1e10), 0, 0, false, 0));
        _swapExactInput(_poolKey(), true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, "swap_1MockExtensionCredit");
    }

    /// @dev After that credit, the extension pays part of the next input from it: a debt paid from claims.
    function test_gas_swap_1MockExtensionDebtFromCredit() public {
        MockExtension extension = _deltaExtension();
        extension.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(int128(1e10), 0, 0, false, 0));
        _swapExactInput(_poolKey(), true, SWAP_AMOUNT);
        extension.setBehavior(CallbackType.BeforeSwap, MockExtension.Behavior(-int128(1e10), 0, 0, false, 0));
        _swapExactInput(_poolKey(), true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, "swap_1MockExtensionDebtFromCredit");
    }

    /// @dev In afterSwap, the extension swaps on a second KernelHook pool. It pays from its vault balance.
    function test_gas_swap_1MockExtensionWithRouteOf1Swap() public {
        PoolKey memory key = _readyPool();
        PoolKey memory routeKey = PoolKey(currency0, currency1, 500, 10, key.hooks);
        _createPool(routeKey);
        _addLiquidity(routeKey);

        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, true, 1_000_000));
        IERC20(Currency.unwrap(currency0)).transfer(address(extension), 1e15);
        extension.deposit(key.toId(), currency0, 1e15);
        extension.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction({
                key: routeKey,
                operation: Operation.Swap,
                parameters: abi.encode(_exactInputParameters(true, 1e12)),
                hookData: ""
            })
        );

        _swapExactInput(key, true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, "swap_1MockExtensionWithRouteOf1Swap");
    }

    /// @dev The same route, with its swap on a Uniswap v2 pair through the admitted adapter (ExternalSwap): exact
    /// input.
    function test_gas_swap_1MockExtensionWithRouteOf1ExternalSwapExactInput() public {
        _externalSwapRoute(-1e12);
        _swapExactInput(_poolKey(), true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, "swap_1MockExtensionWithRouteOf1ExternalSwapExactInput");
    }

    /// @dev Exact output: the executor first reads the adapter's quote.
    function test_gas_swap_1MockExtensionWithRouteOf1ExternalSwapExactOutput() public {
        _externalSwapRoute(1e12);
        _swapExactInput(_poolKey(), true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, "swap_1MockExtensionWithRouteOf1ExternalSwapExactOutput");
    }

    /// @dev The same route, with its swap in a hookless pool (ForeignSwap): no nested Kernel operation.
    function test_gas_swap_1MockExtensionWithRouteOf1ForeignSwap() public {
        PoolKey memory key = _readyPool();
        PoolKey memory foreignKey = _plainPoolKey();
        manager.initialize(foreignKey, SQRT_PRICE_1_1);
        _addLiquidity(foreignKey);

        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, true, 1_000_000));
        IERC20(Currency.unwrap(currency0)).transfer(address(extension), 1e15);
        extension.deposit(key.toId(), currency0, 1e15);
        extension.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction({
                key: foreignKey,
                operation: Operation.ForeignSwap,
                parameters: abi.encode(_exactInputParameters(true, 1e12)),
                hookData: ""
            })
        );

        _swapExactInput(key, true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, "swap_1MockExtensionWithRouteOf1ForeignSwap");
    }

    // ---------------------------------------------------------------- management

    function test_gas_preparePool() public {
        hook.preparePool(_poolKey());
        vm.snapshotGasLastFrame(GROUP, "preparePool");
    }

    function test_gas_initialize_0Extensions() public {
        PoolKey memory key = _poolKey();
        hook.preparePool(key);
        manager.initialize(key, SQRT_PRICE_1_1);
        vm.snapshotGasLastFrame(GROUP, "initialize_0Extensions");
    }

    function test_gas_installExtension() public {
        PoolKey memory key = _poolKey();
        _createPool(key);
        NoopExtension extension = _newNoop();
        _admit(address(extension));
        hook.installExtension(key, IHookExtension(address(extension)), _noopSettings(SWAP_CALLBACKS, false));
        vm.snapshotGasLastFrame(GROUP, "installExtension");
    }

    function test_gas_activateExtension() public {
        PoolKey memory key = _poolKey();
        _createPool(key);
        NoopExtension extension = _newNoop();
        _admit(address(extension));
        hook.installExtension(key, IHookExtension(address(extension)), _noopSettings(SWAP_CALLBACKS, false));
        hook.activateExtension(key, IHookExtension(address(extension)));
        vm.snapshotGasLastFrame(GROUP, "activateExtension");
    }

    function test_gas_removeExtension() public {
        PoolKey memory key = _poolKey();
        _createPool(key);
        NoopExtension extension = _newNoop();
        _installAndActivate(key, address(extension), _noopSettings(SWAP_CALLBACKS, false));
        hook.deactivateExtension(key, IHookExtension(address(extension)));
        hook.removeExtension(key, IHookExtension(address(extension)));
        vm.snapshotGasLastFrame(GROUP, "removeExtension");
    }

    // ---------------------------------------------------------------- helpers

    function _measureSwapWithNoops(uint256 count, bool optionalCallbacks, string memory name) private {
        PoolKey memory key = _readyPool();
        address[] memory extensions = new address[](count);
        // count <= 8
        for (uint256 i; i < count; ++i) {
            extensions[i] = address(_newNoop());
        }
        _installAndActivateAll(key, extensions, _noopSettings(SWAP_CALLBACKS, optionalCallbacks));
        _swapExactInput(key, true, SWAP_AMOUNT);
        vm.snapshotGasLastFrame(GROUP, name);
    }

    /// @notice Creates the default KernelHook pool and adds liquidity to it.
    /// @dev A pool with a MockExtension whose AfterSwap route is one ExternalSwap on a fresh v2 pair (1e18 / 1e18).
    function _externalSwapRoute(int256 amountSpecified) private {
        PoolKey memory key = _readyPool();
        TestUniswapV2Factory factory = new TestUniswapV2Factory();
        address pair = factory.createPair(Currency.unwrap(currency0), Currency.unwrap(currency1));
        IERC20(Currency.unwrap(currency0)).transfer(pair, 1e18);
        IERC20(Currency.unwrap(currency1)).transfer(pair, 1e18);
        TestUniswapV2Pair(pair).sync();
        UniswapV2Adapter adapter =
            new UniswapV2Adapter(address(hook.ROUTE_EXECUTOR()), IUniswapV2FactoryMinimal(address(factory)), 30);
        catalog.admitAdapter(address(adapter), address(adapter).codehash);
        MockExtension extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, true, 1_000_000));
        IERC20(Currency.unwrap(currency0)).transfer(address(extension), 1e15);
        extension.deposit(key.toId(), currency0, 1e15);
        extension.addRouteAction(
            CallbackType.AfterSwap,
            RouteAction({
                key: PoolKey(currency0, currency1, 0, 0, IHooks(address(0))),
                operation: Operation.ExternalSwap,
                parameters: abi.encode(
                    // No minimum output for an exact input; no maximum input for an exact output.
                    ExternalSwapParameters(
                        address(adapter), pair, true, amountSpecified, amountSpecified < 0 ? 0 : type(uint256).max
                    )
                ),
                hookData: ""
            })
        );
    }

    function _deltaExtension() private returns (MockExtension extension) {
        PoolKey memory key = _readyPool();
        extension = new MockExtension(address(hook));
        _installAndActivate(key, address(extension), _settings(SWAP_CALLBACKS, false, false, 1_000_000));
    }

    function _readyPool() private returns (PoolKey memory key) {
        key = _poolKey();
        _createPool(key);
        _addLiquidity(key);
    }

    function _installNoop(PoolKey memory key, uint16 callbackMask) private {
        _installAndActivate(key, address(_newNoop()), _noopSettings(callbackMask, false));
    }

    /// @dev BeforeInitialize as the result callback: the extension never receives it, so all its deltas are zero.
    function _newNoop() private returns (NoopExtension) {
        return new NoopExtension(address(hook), CallbackType.BeforeInitialize, 0, 0);
    }

    function _noopSettings(uint16 callbackMask, bool optionalCallbacks)
        private
        pure
        returns (ExtensionSettings memory)
    {
        return _settings(callbackMask, optionalCallbacks, false, NOOP_GAS_LIMIT);
    }
}
