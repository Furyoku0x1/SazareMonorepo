// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IHookExtension} from "core/src/interfaces/IHookExtension.sol";
import {IHookCatalog} from "core/src/interfaces/IHookCatalog.sol";
import {KernelHookVault} from "core/src/KernelHookVault.sol";
import {
    CallbackResult,
    CallbackType,
    ExecutionContext,
    ExtensionSettings,
    Operation,
    RouteAction
} from "core/src/types/KernelHookTypes.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {IDepositVault} from "../src/libraries/BookOrders.sol";
import {OrderBookFixture, FeeOverrider, TwoSwaps} from "./utils/OrderBookFixture.sol";

/// @dev An extension that does nothing in its callbacks.
contract Noop is FeeOverrider {
    constructor() FeeOverrider(0) {}

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata)
        external
        pure
        override
        returns (CallbackResult memory result)
    {}
}

/// @dev An extension that fills part of a swap before the book, from its own vault balance: on the swap whose
/// amountSpecified equals the trigger, it returns the deltas set for it.
contract Prefill is FeeOverrider {
    int256 public trigger;
    int128 public delta0;
    int128 public delta1;

    constructor() FeeOverrider(0) {}

    function set(int256 trigger_, int128 delta0_, int128 delta1_) external {
        (trigger, delta0, delta1) = (trigger_, delta0_, delta1_);
    }

    function fund(address vault, PoolId pool, Currency currency, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).approve(vault, amount);
        IDepositVault(vault).deposit(pool, address(this), currency, amount);
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata, bytes calldata data)
        external
        view
        override
        returns (CallbackResult memory)
    {
        if (abi.decode(data, (SwapParams)).amountSpecified != trigger) return CallbackResult(0, 0, 0);
        return CallbackResult(delta0, delta1, 0);
    }
}

/// @dev An extension that, once armed, swaps in its own pool from afterSwap through a nested route, as an
/// arbitrage extension does.
contract NestedSwapper is FeeOverrider {
    IKernelHook public immutable KERNEL;
    SwapParams internal _params;
    bool public armed;

    constructor(IKernelHook kernel) FeeOverrider(0) {
        KERNEL = kernel;
    }

    function arm(SwapParams calldata params) external {
        (_params, armed) = (params, true);
    }

    function fund(address vault, PoolId pool, Currency currency, uint256 amount) external {
        MockERC20(Currency.unwrap(currency)).approve(vault, amount);
        IDepositVault(vault).deposit(pool, address(this), currency, amount);
    }

    function onCallback(ExecutionContext calldata, PoolKey calldata key, bytes calldata)
        external
        override
        returns (CallbackResult memory result)
    {
        if (!armed) return result;
        armed = false;
        RouteAction[] memory actions = new RouteAction[](1);
        actions[0] = RouteAction(key, Operation.Swap, abi.encode(_params), "");
        KERNEL.executeRoute(actions);
    }
}

/// @dev The book among other Kernel extensions: earlier fills in the same swap, nested routes, the order of
/// callbacks, and rollback.
contract OrderBookKernelTest is OrderBookFixture {
    using StateLibrary for IPoolManager;

    uint16 internal constant BEFORE_SWAP = uint16(1) << uint8(CallbackType.BeforeSwap);
    uint16 internal constant AFTER_SWAP = uint16(1) << uint8(CallbackType.AfterSwap);

    // ---------------------------------------------------------------- earlier fills

    /// @dev Sol's review: an extension before the book fills part of the swap (`context.prior`). The book and the AMM
    /// then trade exactly what a swap of the rest alone would: same book fill, same final price, same ledger, and the
    /// taker's totals differ by the earlier fill only. In each direction and mode.
    function test_priorFill_zeroForOneExactInput() public {
        _priorFill(true, true);
    }

    function test_priorFill_zeroForOneExactOutput() public {
        _priorFill(true, false);
    }

    function test_priorFill_oneForZeroExactInput() public {
        _priorFill(false, true);
    }

    function test_priorFill_oneForZeroExactOutput() public {
        _priorFill(false, false);
    }

    struct Outcome {
        BalanceDelta delta;
        uint160 price;
        uint256 bookSpecified;
        uint256 bookOther;
        bytes32 ledger;
    }

    function _priorFill(bool zeroForOne, bool exactIn) private {
        Prefill prefill = _prefillBeforeTheBook();
        int256 specified = exactIn ? -2e17 : int256(2e17);
        // The earlier fill: 5e16 of the specified currency, 4e16 of the other, each charged or paid as the mode says.
        int128 input = exactIn ? int128(5e16) : int128(4e16);
        int128 output = exactIn ? -int128(4e16) : -int128(5e16);
        (int128 d0, int128 d1) = zeroForOne ? (input, output) : (output, input);
        uint160 limit = zeroForOne ? MIN_LIMIT : MAX_LIMIT;

        uint256 snapshot = vm.snapshotState();
        prefill.set(specified, d0, d1);
        Outcome memory withPrefill = _outcome(SwapParams(zeroForOne, specified, limit));
        vm.revertToState(snapshot);
        prefill.set(0, 0, 0);
        Outcome memory alone = _outcome(SwapParams(zeroForOne, exactIn ? specified + 5e16 : specified - 5e16, limit));

        assertGt(alone.bookSpecified, 0, "the book filled");
        assertEq(withPrefill.bookSpecified, alone.bookSpecified, "book fill: specified");
        assertEq(withPrefill.bookOther, alone.bookOther, "book fill: other");
        assertEq(withPrefill.price, alone.price, "final price");
        assertEq(withPrefill.ledger, alone.ledger, "ledger");
        assertEq(withPrefill.delta.amount0(), alone.delta.amount0() - d0, "taker: currency0");
        assertEq(withPrefill.delta.amount1(), alone.delta.amount1() - d1, "taker: currency1");
    }

    /// @dev AMM liquidity, a funded Prefill before the book, and a range and a level on each side.
    function _prefillBeforeTheBook() private returns (Prefill prefill) {
        _lp(-6000, 6000, 1e18);
        prefill = new Prefill();
        _installExtension(address(prefill), BEFORE_SWAP, true, 200_000);
        _installInactive(_settings(), _policy());
        hook.activateExtension(key, IHookExtension(address(prefill)));
        hook.activateExtension(key, IHookExtension(address(book)));
        address vault = address(hook.VAULT());
        for (uint256 c; c < 2; ++c) {
            Currency currency = c == 0 ? currency0 : currency1;
            MockERC20(Currency.unwrap(currency)).mint(address(prefill), 1e18);
            prefill.fund(vault, pool, currency, 1e18);
        }
        _placeFixed(true, 100, 1e11);
        _placeRange(true, 50, 600, 1e18);
        _placeFixed(false, -100, 1e11);
        _placeRange(false, -600, -50, 1e18);
    }

    function _outcome(SwapParams memory params) private returns (Outcome memory o) {
        vm.recordLogs();
        o.delta = _swap(params);
        (o.bookSpecified, o.bookOther) = _bookFilled();
        (o.price,,,) = manager.getSlot0(pool);
        o.ledger = keccak256(abi.encode(book.ledger(pool)));
        _checkBacking();
    }

    // ---------------------------------------------------------------- nested routes

    /// @dev Sol's review: an extension's nested swap in the pool (as arbitrage makes) fills the book when the policy
    /// allows nested fills, and leaves it to the AMM when not. Either way the book's vault matches its ledger.
    function test_nestedSwapFillsTheBookWhenAllowed() public {
        assertGt(_nestedSwap(true), 0, "the nested swap filled the order");
    }

    function test_nestedSwapSkipsTheBookWhenNotAllowed() public {
        assertEq(_nestedSwap(false), 0, "the nested swap left the order");
    }

    /// @return filled The ask's lots filled by the nested swap.
    function _nestedSwap(bool nestedFills) private returns (uint64 filled) {
        _lp(-6000, 6000, 1e18);
        OrderBook.Policy memory p = _policy();
        p.nestedFills = nestedFills;
        // Small enough limits that the book's callbacks fit inside the swapper's.
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 800_000;
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 800_000;
        _installInactive(settings, p);
        NestedSwapper swapper = new NestedSwapper(IKernelHook(address(hook)));
        _installExtension(address(swapper), AFTER_SWAP, true, 3_000_000);
        hook.activateExtension(key, IHookExtension(address(book)));
        hook.activateExtension(key, IHookExtension(address(swapper)));
        MockERC20(Currency.unwrap(currency1)).mint(address(swapper), 1e18);
        swapper.fund(address(hook.VAULT()), pool, currency1, 1e18);
        uint256 id = _placeFixed(true, 100, 1e11);
        (uint160 before,,,) = manager.getSlot0(pool);
        // A small swap the other way, with no bids; the swapper's route then buys up through the ask.
        swapper.arm(SwapParams(false, -2e17, MAX_LIMIT));
        _swap(SwapParams(true, -1e6, MIN_LIMIT));
        assertFalse(swapper.armed(), "the route ran");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertGt(price, before, "the nested swap moved the price");
        (, filled) = book.fixedOrder(pool, id);
        _checkBacking();
    }

    // ---------------------------------------------------------------- callback order

    /// @dev The book activates only when every extension after it in afterSwap is optional: a required one would deny
    /// its donation and price-move routes.
    function test_activationRejectsARequiredTail() public {
        _installInactive(_settings(), _policy());
        Noop tail = new Noop();
        _installExtension(address(tail), AFTER_SWAP, false, 100_000);
        vm.expectRevert();
        hook.activateExtension(key, IHookExtension(address(book)));
        hook.configureExtension(key, IHookExtension(address(tail)), _extensionSettings(AFTER_SWAP, true, 100_000));
        hook.activateExtension(key, IHookExtension(address(book)));
    }

    /// @dev Sol's review: while the book is active, an optional extension after it cannot be made required.
    function test_tailCannotBecomeRequiredWhileTheBookIsActive() public {
        _installInactive(_settings(), _policy());
        Noop tail = new Noop();
        _installExtension(address(tail), AFTER_SWAP, true, 100_000);
        hook.activateExtension(key, IHookExtension(address(book)));
        vm.expectRevert(IKernelHook.SubscribersActive.selector);
        hook.configureExtension(key, IHookExtension(address(tail)), _extensionSettings(AFTER_SWAP, false, 100_000));
    }

    // ---------------------------------------------------------------- rollback

    /// @dev A bid fill credits the input (currency0) before the output's settlement (currency1) fails: the Kernel
    /// skips the book and the credit rolls back with its fills.
    function test_failureAfterTheInputCreditRollsBack() public {
        _lp(-6000, 6000, 1e18);
        _install(_policy());
        uint256 id = _placeFixed(false, -100, 1e11);
        OrderBook.Ledger memory before = book.ledger(pool);
        KernelHookVault vault = KernelHookVault(payable(address(hook.VAULT())));
        uint256 held0 = vault.balanceOf(pool, address(book), currency0);
        vm.mockCallRevert(
            address(vault), abi.encodeWithSelector(vault.settleDebtFor.selector, pool, address(book), currency1), ""
        );
        vm.recordLogs();
        _swap(SwapParams(true, -2e17, MIN_LIMIT));
        assertTrue(_skipped(), "the book was skipped");
        (, uint64 filled) = book.fixedOrder(pool, id);
        assertEq(filled, 0, "fills rolled back");
        assertEq(vault.balanceOf(pool, address(book), currency0), held0, "the input credit rolled back");
        assertEq(keccak256(abi.encode(book.ledger(pool))), keccak256(abi.encode(before)), "ledger rolled back");
        _checkBacking();
    }

    /// @dev Only the book itself can run its routes.
    function test_routeIsTheBooksOwn() public {
        _install(_policy());
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        book.route(key, 0, 0, 0);
    }

    /// @dev Sol's review: the stale frontier with the book's early return for a swap an earlier extension fills
    /// whole. In one transaction, a swap fills the book in an empty pool with too little gas for the book's afterSwap;
    /// then an extension fills a second swap entirely, so the book returns before walking. The second swap's
    /// afterSwap must not move the price to the first swap's frontier.
    function test_staleFrontierWithAWholeEarlierFill() public {
        Prefill prefill = new Prefill();
        _installExtension(address(prefill), BEFORE_SWAP, true, 200_000);
        ExtensionSettings memory settings = _settings();
        settings.callbackGasLimits[uint8(CallbackType.BeforeSwap)] = 1_000_000;
        settings.callbackGasLimits[uint8(CallbackType.AfterSwap)] = 3_000_000;
        _installInactive(settings, _policy());
        hook.activateExtension(key, IHookExtension(address(prefill)));
        hook.activateExtension(key, IHookExtension(address(book)));
        MockERC20(Currency.unwrap(currency1)).mint(address(prefill), 1e18);
        prefill.fund(address(hook.VAULT()), pool, currency1, 1e18);
        prefill.set(-1e6, 1e6, -9e5); // takes the whole second swap's input
        uint256 id = _placeFixed(true, 200, 1e11);
        TwoSwaps swaps = new TwoSwaps(swapRouter, currency0, currency1);
        MockERC20(Currency.unwrap(currency0)).mint(address(swaps), 1e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(swaps), 1e18);
        vm.recordLogs();
        swaps.run(key, SwapParams(false, -5e16, MAX_LIMIT), 2_500_000, SwapParams(true, -1e6, MIN_LIMIT));
        assertTrue(_skipped(), "the first afterSwap skipped");
        (, uint64 filled) = book.fixedOrder(pool, id);
        assertGt(filled, 0, "the first swap filled the book");
        (uint160 price,,,) = manager.getSlot0(pool);
        assertEq(price, PRICE_1, "no move to the first swap's frontier");
        _checkBacking();
    }

    // ---------------------------------------------------------------- helpers

    function _installExtension(address extension, uint16 mask, bool optional, uint32 gasLimit) private {
        catalog.admit(extension, IHookCatalog.Entry(extension.codehash, mask, true, true, false, true, true));
        hook.installExtension(key, IHookExtension(extension), _extensionSettings(mask, optional, gasLimit));
    }

    function _extensionSettings(uint16 mask, bool optional, uint32 gasLimit)
        private
        pure
        returns (ExtensionSettings memory settings)
    {
        settings.callbackMask = mask;
        settings.optionalCallbacks = optional;
        settings.allowNesting = true;
        settings.lifecycleGasLimit = 500_000;
        for (uint8 i; i < 16; ++i) {
            if (mask & (uint16(1) << i) != 0) settings.callbackGasLimits[i] = gasLimit;
        }
    }
}
