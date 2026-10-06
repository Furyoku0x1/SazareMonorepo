// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookCatalog} from "../../src/HookCatalog.sol";
import {KernelHook} from "../../src/KernelHook.sol";
import {IHookCatalog} from "../../src/interfaces/IHookCatalog.sol";
import {IHookExtension} from "../../src/interfaces/IHookExtension.sol";
import {CallbackLibrary} from "../../src/libraries/CallbackLibrary.sol";
import {CALLBACK_COUNT, CallbackType, ExtensionSettings} from "../../src/types/KernelHookTypes.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Deploys a PoolManager, the v4 test routers, two tokens, a catalog and KernelHook, and gives
/// short helpers for pools, liquidity, swaps and extension installation.
/// @dev The PoolManager pins solc 0.8.26, so it is deployed from its artifact (test/utils/PoolManagerArtifact.sol).
/// A filtered `forge test --match-*` builds only imported files: run `forge build` once before it.
abstract contract KernelHookFixture is Test {
    using CallbackLibrary for CallbackType;

    /// @dev The low 14 bits of a hook address select its callbacks. KernelHook needs all 14.
    address internal constant HOOK_ADDRESS = address(uint160(0xC0FFEE) << 136 | uint160(Hooks.ALL_HOOK_MASK));

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    /// @dev Enough for MockExtension, which writes several storage slots on its first call. With the default
    /// callback gas budget of a pool (4,000,000), four required extensions fit on a callback that can return deltas:
    /// 4 * (500,000 + 16,129 + 250,000) + 80,000 + 25,000 + 4 * (25,000 + 12,000) = 3,317,516.
    /// Tests with more required extensions use _settings with a smaller gas limit.
    uint32 internal constant DEFAULT_CALLBACK_GAS_LIMIT = 500_000;
    uint32 internal constant DEFAULT_LIFECYCLE_GAS_LIMIT = 200_000;

    uint16 internal constant SWAP_CALLBACKS =
        uint16(1) << uint8(CallbackType.BeforeSwap) | uint16(1) << uint8(CallbackType.AfterSwap);

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolDonateTest internal donateRouter;
    Currency internal currency0;
    Currency internal currency1;
    HookCatalog internal catalog;
    KernelHook internal hook;

    function setUp() public virtual {
        manager = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        donateRouter = new PoolDonateTest(manager);
        (currency0, currency1) = _deployCurrencies();
        catalog = new HookCatalog();
        deployCodeTo("KernelHook.sol:KernelHook", abi.encode(manager, address(catalog)), HOOK_ADDRESS);
        hook = KernelHook(HOOK_ADDRESS);
    }

    /// @notice Returns a KernelHook pool key with the default fee and tick spacing.
    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(hook)));
    }

    /// @notice Returns a pool key for the same currencies with no hook, as a gas reference.
    function _plainPoolKey() internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, FEE, TICK_SPACING, IHooks(address(0)));
    }

    /// @notice Prepares the pool and then initializes it from this contract, the initializer.
    function _createPool(PoolKey memory key) internal {
        hook.preparePool(key);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    /// @notice Adds 1e18 liquidity between ticks -120 and 120 through the liquidity router.
    function _addLiquidity(PoolKey memory key) internal returns (BalanceDelta) {
        return modifyLiquidityRouter.modifyLiquidity(key, _liquidityParameters(1e18), "");
    }

    /// @notice Removes the liquidity that _addLiquidity added.
    function _removeLiquidity(PoolKey memory key) internal returns (BalanceDelta) {
        return modifyLiquidityRouter.modifyLiquidity(key, _liquidityParameters(-1e18), "");
    }

    function _liquidityParameters(int256 liquidityDelta) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: liquidityDelta, salt: 0});
    }

    /// @notice Swaps an exact input amount through the swap router, with no price limit in practice.
    function _swapExactInput(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return
            swapRouter.swap(
                key, _exactInputParameters(zeroForOne, amountIn), PoolSwapTest.TestSettings(false, false), ""
            );
    }

    function _exactInputParameters(bool zeroForOne, uint256 amountIn) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
    }

    /// @notice Returns the revert data that a caller sees when KernelHook reverts with hookError inside a hook
    /// callback: the PoolManager wraps it in CustomRevert.WrappedError.
    /// @param hookCallbackSelector The callback that reverted, for example IHooks.beforeSwap.selector
    /// @param hookError The revert data of KernelHook, for example abi.encodeWithSelector(IKernelHook.X.selector)
    function _hookRevert(bytes4 hookCallbackSelector, bytes memory hookError) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookCallbackSelector,
            hookError,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }

    /// @notice Admits an extension with all callbacks and all capabilities.
    function _admit(address extension) internal {
        catalog.admit(
            extension,
            IHookCatalog.Entry({
                codeHash: extension.codehash,
                callbackMask: CallbackLibrary.ALL_CALLBACKS_MASK,
                supportsOptionalCallbacks: true,
                supportsNesting: true,
                supportsReentrancy: true,
                supportsLateInstallation: true,
                admitted: true
            })
        );
    }

    /// @notice Returns settings with the default gas limit for every callback.
    function _settings(uint16 callbackMask, bool optionalCallbacks, bool allowNesting)
        internal
        pure
        returns (ExtensionSettings memory)
    {
        return _settings(callbackMask, optionalCallbacks, allowNesting, DEFAULT_CALLBACK_GAS_LIMIT);
    }

    /// @notice Returns settings with callbackGasLimit for every callback.
    function _settings(uint16 callbackMask, bool optionalCallbacks, bool allowNesting, uint32 callbackGasLimit)
        internal
        pure
        returns (ExtensionSettings memory settings)
    {
        settings.callbackMask = callbackMask;
        settings.optionalCallbacks = optionalCallbacks;
        settings.allowNesting = allowNesting;
        settings.lifecycleGasLimit = DEFAULT_LIFECYCLE_GAS_LIMIT;
        // i < CALLBACK_COUNT
        for (uint256 i; i < CALLBACK_COUNT; ++i) {
            settings.callbackGasLimits[i] = callbackGasLimit;
        }
    }

    /// @notice Admits the extension if the catalog does not know it, then installs and activates it.
    function _installAndActivate(PoolKey memory key, address extension, ExtensionSettings memory settings) internal {
        if (catalog.getEntry(extension).codeHash == bytes32(0)) _admit(extension);
        hook.installExtension(key, IHookExtension(extension), settings);
        hook.activateExtension(key, IHookExtension(extension));
    }

    /// @notice Installs all extensions first, then activates them.
    /// @dev installExtension requires the current subscribers of its callbacks to be inactive, so a second
    /// extension on the same callback cannot be installed after the first one is active.
    function _installAndActivateAll(PoolKey memory key, address[] memory extensions, ExtensionSettings memory settings)
        internal
    {
        // extensions.length <= MAX_EXTENSIONS
        for (uint256 i; i < extensions.length; ++i) {
            if (catalog.getEntry(extensions[i]).codeHash == bytes32(0)) _admit(extensions[i]);
            hook.installExtension(key, IHookExtension(extensions[i]), settings);
        }
        // extensions.length <= MAX_EXTENSIONS
        for (uint256 i; i < extensions.length; ++i) {
            hook.activateExtension(key, IHookExtension(extensions[i]));
        }
    }

    function _deployCurrencies() private returns (Currency, Currency) {
        MockERC20 tokenA = new MockERC20("Token A", "A", 18);
        MockERC20 tokenB = new MockERC20("Token B", "B", 18);
        (MockERC20 lower, MockERC20 higher) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        _fund(lower);
        _fund(higher);
        return (Currency.wrap(address(lower)), Currency.wrap(address(higher)));
    }

    function _fund(MockERC20 token) private {
        token.mint(address(this), type(uint128).max);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(donateRouter), type(uint256).max);
    }
}
