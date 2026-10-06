// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {KernelHookFixture} from "../utils/KernelHookFixture.sol";
import {MockExtension} from "../mocks/MockExtension.sol";
import {NoopExtension} from "../mocks/NoopExtension.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {CallbackType, ExtensionSettings, Operation, RouteAction} from "../../src/types/KernelHookTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice Gas baseline for KernelHook. Each test builds its scenario, then measures exactly one call.
/// @dev Run with `forge test --isolate --match-path test/gas/*` for numbers close to a chain: in isolate mode each
/// top-level call is its own transaction, so cold access costs and the refund limit apply. The results go to
/// snapshots/KernelHook.json. The NoopExtension keeps the extension's own cost close to zero.
contract KernelHookGasTest is KernelHookFixture {
    string internal constant GROUP = "KernelHook";
    uint256 internal constant SWAP_AMOUNT = 1e14;

    /// @dev Eight required extensions at this limit fit the default budget: 8 * 100,000 + 80,000 + 8 * 25,000.
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
