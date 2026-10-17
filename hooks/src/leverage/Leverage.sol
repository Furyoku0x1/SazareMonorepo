// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IKernelHook} from "core/src/interfaces/IKernelHook.sol";
import {IKernelHookExtension} from "core/src/interfaces/IKernelHookExtension.sol";
import {CallbackResult, CallbackType, ExecutionContext, ExtensionSettings} from "core/src/types/KernelHookTypes.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IERC20} from "oz/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "oz/contracts/utils/math/SafeCast.sol";
import {KernelExtension} from "../base/KernelExtension.sol";
import {Curve, LeverageMath} from "../libraries/leverage/LeverageMath.sol";
import {
    Bin,
    Borrow,
    CurveVersion,
    Lender,
    LeverageBins,
    LeverageContext,
    LeverageState,
    Owed,
    Position
} from "../libraries/leverage/LeverageBins.sol";
import {CloseRequest, CloseResult, LeverageEngine, OpenRequest} from "../libraries/leverage/LeverageEngine.sol";
import {BinRequest, LeverageLending} from "../libraries/leverage/LeverageLending.sol";

/// @notice The fee vault that funds the mining game's pot. Its full interface is designed separately.
interface IFeeVault {
    /// @notice Pulls `amount` of `currency` from the caller, which approved it first.
    function deposit(Currency currency, uint256 amount) external;
}

/// @notice Leveraged long and short positions on real LP liquidity of one Kernel pool, under a solvency chord.
/// @dev hooks/docs/leverage-spec.md. One deployment per pool. Every LP of the pool lends through this contract: its
/// required beforeAddLiquidity subscription refuses every other adder, so the pool installs and activates it before
/// its first liquidity (a catalog entry without late installation). Custody is this contract's own ERC20 balance;
/// every unlock settles its PoolManager deltas before it returns. Native currency, fee-on-transfer tokens and tokens
/// with transfer hooks are not supported. LeverageEngine, a linked library, runs opens and closes in this contract's storage.
contract Leverage is KernelExtension, IKernelHookExtension, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using TransientStateLibrary for IPoolManager;

    /// @notice Fixed at deployment, so a pool admin cannot redirect or reprice them.
    struct Deployment {
        PoolKey key;
        bool quoteIsCurrency0;
        address treasury;
        address feeVault;
        uint16 profitShareBps;
        uint16 treasuryShareBps;
        uint16 feeVaultShareBps;
        uint16 utilizationCeilingBps;
        uint8 maxBinsPerPosition;
        uint16 minRewardBps;
        uint16 maxRewardBps;
        uint24 maxBinWidth;
        uint64 maxRateWad;
        /// @dev How long a flagged position waits before anyone may force close it.
        uint32 graceSeconds;
        /// @dev How long premium and the lenders' part of a profit share take to vest to a bin's lenders.
        uint32 vestSeconds;
        /// @dev The smallest quote notional a position may borrow, or keep after a partial close.
        uint128 minBorrowNotional;
    }

    enum Action {
        Deposit,
        Withdraw,
        Collect,
        Open,
        Close
    }

    uint16 public constant CALLBACK_MASK = uint16(1) << uint8(CallbackType.BeforeAddLiquidity);
    /// @dev Bounds every per-call bin loop. MAX_BINS_PER_POSITION <= MAX_BINS, so a bin count fits uint8.
    uint256 public constant MAX_BINS = 32;
    /// @dev Bounds the grace period and the vesting period: longer, a delinquent position or a lender's earnings could be
    /// held for months.
    uint256 public constant MAX_GRACE_SECONDS = 30 days;
    uint256 public constant MAX_VEST_SECONDS = 30 days;
    uint256 internal constant WAD = LeverageMath.WAD;
    uint256 internal constant BPS = LeverageMath.BPS;

    PoolId public immutable POOL_ID;
    Currency public immutable CURRENCY0;
    Currency public immutable CURRENCY1;
    uint24 internal immutable FEE;
    int24 internal immutable TICK_SPACING;
    bool public immutable QUOTE_IS_CURRENCY0;
    address public immutable TREASURY;
    address public immutable FEE_VAULT;
    uint256 public immutable PROFIT_SHARE_BPS;
    uint256 public immutable TREASURY_SHARE_BPS;
    uint256 public immutable FEE_VAULT_SHARE_BPS;
    uint256 public immutable UTILIZATION_CEILING_BPS;
    uint256 public immutable MAX_BINS_PER_POSITION;
    uint256 public immutable MIN_REWARD_BPS;
    uint256 public immutable MAX_REWARD_BPS;
    uint256 public immutable MAX_BIN_WIDTH;
    uint256 public immutable MAX_RATE_WAD;
    uint256 public immutable GRACE_SECONDS;
    uint256 public immutable VEST_SECONDS;
    uint256 public immutable MIN_BORROW_NOTIONAL;

    LeverageState internal _state;

    error NotDelinquent();
    /// @dev Flag the position with flagDelinquent first.
    error NotFlagged();
    /// @dev The grace period since the flag has not passed.
    error GracePending();
    error InstallationInactive();

    event Deposited(
        address indexed lender, int24 lowerBin, uint8 binCount, uint128 liquidityPerBin, uint256 paid0, uint256 paid1
    );
    event Withdrawn(
        address indexed lender,
        int24 lowerBin,
        uint8 binCount,
        uint128 liquidityPerBin,
        uint256 amount0,
        uint256 amount1
    );
    event Collected(address indexed account, address recipient, uint256 amount0, uint256 amount1);
    event Opened(uint256 indexed positionId, address indexed owner, int24 lowerBin, uint8 binCount, uint128 collateral);
    event DelinquencyFlagged(uint256 indexed positionId, uint256 flaggedAt);

    constructor(IKernelHook kernel, Deployment memory deployment) KernelExtension(kernel) {
        _validateDeployment(deployment);
        POOL_ID = deployment.key.toId();
        CURRENCY0 = deployment.key.currency0;
        CURRENCY1 = deployment.key.currency1;
        FEE = deployment.key.fee;
        TICK_SPACING = deployment.key.tickSpacing;
        QUOTE_IS_CURRENCY0 = deployment.quoteIsCurrency0;
        TREASURY = deployment.treasury;
        FEE_VAULT = deployment.feeVault;
        PROFIT_SHARE_BPS = deployment.profitShareBps;
        TREASURY_SHARE_BPS = deployment.treasuryShareBps;
        FEE_VAULT_SHARE_BPS = deployment.feeVaultShareBps;
        UTILIZATION_CEILING_BPS = deployment.utilizationCeilingBps;
        MAX_BINS_PER_POSITION = deployment.maxBinsPerPosition;
        MIN_REWARD_BPS = deployment.minRewardBps;
        MAX_REWARD_BPS = deployment.maxRewardBps;
        MAX_BIN_WIDTH = deployment.maxBinWidth;
        MAX_RATE_WAD = deployment.maxRateWad;
        GRACE_SECONDS = deployment.graceSeconds;
        VEST_SECONDS = deployment.vestSeconds;
        MIN_BORROW_NOTIONAL = deployment.minBorrowNotional;
    }

    // ---------------------------------------------------------------- lenders

    /// @notice Lends `liquidityPerBin` in each of `binCount` bins from `lowerBin`, paying at most the given amounts.
    function deposit(int24 lowerBin, uint8 binCount, uint128 liquidityPerBin, uint256 maximum0, uint256 maximum1)
        external
        publicMutation
        returns (uint256 paid0, uint256 paid1)
    {
        _requireActive();
        _requireBinCount(binCount);
        if (liquidityPerBin == 0) revert InvalidAmount();
        BinRequest memory request = BinRequest(msg.sender, lowerBin, binCount, liquidityPerBin, maximum0, maximum1);
        (paid0, paid1) = abi.decode(_unlock(Action.Deposit, abi.encode(request)), (uint256, uint256));
        emit Deposited(msg.sender, lowerBin, binCount, liquidityPerBin, paid0, paid1);
    }

    /// @notice Withdraws idle liquidity. The borrowed part of a bin comes back only when its positions close.
    function withdraw(
        int24 lowerBin,
        uint8 binCount,
        uint128 liquidityPerBin,
        uint256 minimum0,
        uint256 minimum1,
        address recipient
    ) external publicMutation returns (uint256 amount0, uint256 amount1) {
        _requireBinCount(binCount);
        if (liquidityPerBin == 0) revert InvalidAmount();
        BinRequest memory request = BinRequest(msg.sender, lowerBin, binCount, liquidityPerBin, minimum0, minimum1);
        (amount0, amount1) = abi.decode(_unlock(Action.Withdraw, abi.encode(request)), (uint256, uint256));
        _push(CURRENCY0, recipient, amount0);
        _push(CURRENCY1, recipient, amount1);
        emit Withdrawn(msg.sender, lowerBin, binCount, liquidityPerBin, amount0, amount1);
    }

    /// @notice Pays everything the caller is owed. With `binCount` nonzero, first collects the swap fees of those bins
    /// and realizes the caller's lender earnings in them.
    function collect(int24 lowerBin, uint8 binCount, address recipient)
        external
        publicMutation
        returns (uint256 amount0, uint256 amount1)
    {
        if (binCount != 0) {
            _requireBinCount(binCount);
            _unlock(Action.Collect, abi.encode(BinRequest(msg.sender, lowerBin, binCount, 0, 0, 0)));
        }
        // Read after the unlock: safe under publicMutation's lock.
        Owed storage balance = _state.owed[msg.sender];
        amount0 = balance.amount0;
        amount1 = balance.amount1;
        delete _state.owed[msg.sender];
        _state.totalOwed0 -= amount0;
        _state.totalOwed1 -= amount1;
        _push(CURRENCY0, recipient, amount0);
        _push(CURRENCY1, recipient, amount1);
        emit Collected(msg.sender, recipient, amount0, amount1);
    }

    /// @notice Moves the fee vault's part of the profit shares into the fee vault.
    function flushFeeVault() external publicMutation returns (uint256 amount) {
        Owed storage balance = _state.owed[FEE_VAULT];
        amount = QUOTE_IS_CURRENCY0 ? balance.amount0 : balance.amount1;
        if (amount == 0) return 0;
        if (QUOTE_IS_CURRENCY0) {
            balance.amount0 = 0;
            _state.totalOwed0 -= amount;
        } else {
            balance.amount1 = 0;
            _state.totalOwed1 -= amount;
        }
        IERC20 quoteToken = IERC20(Currency.unwrap(_quote()));
        quoteToken.forceApprove(FEE_VAULT, amount);
        IFeeVault(FEE_VAULT).deposit(_quote(), amount);
        // Checked after the external call, safe under publicMutation's lock: the vault pulled exactly the amount.
        if (quoteToken.allowance(address(this), FEE_VAULT) != 0) revert LeverageBins.UnexpectedDelta();
    }

    // ---------------------------------------------------------------- traders

    /// @notice Opens a position: borrows the bins' liquidity, adds the collateral and runs the entry swap.
    function open(OpenRequest calldata request) external publicMutation returns (uint256 positionId) {
        _requireActive();
        _requireBinCount(request.liquidity.length);
        if (request.collateral == 0) revert InvalidAmount();
        positionId = ++_state.lastPositionId;
        _unlock(Action.Open, abi.encode(msg.sender, positionId, request));
        emit Opened(positionId, msg.sender, request.lowerBin, uint8(request.liquidity.length), request.collateral);
    }

    /// @notice Adds quote collateral to the reserves. It adds to the cost basis.
    function addCollateral(uint256 positionId, uint128 amount) external publicMutation {
        Position storage position = _ownedPosition(positionId);
        if (amount == 0) revert InvalidAmount();
        LeverageBins.pull(_quote(), msg.sender, amount);
        if (QUOTE_IS_CURRENCY0) position.reserve0 = (uint256(position.reserve0) + amount).toUint128();
        else position.reserve1 = (uint256(position.reserve1) + amount).toUint128();
        position.collateral += amount;
    }

    /// @notice Adds to the premium escrow, then settles accrued premium if the escrow now covers it.
    function addPremium(uint256 positionId, uint128 amount) external publicMutation {
        Position storage position = _ownedPosition(positionId);
        if (amount == 0) revert InvalidAmount();
        LeverageBins.pull(_quote(), msg.sender, amount);
        position.escrow += amount;
        LeverageEngine.settleEscrow(_state, _context(), positionId);
    }

    /// @notice Pays a position's accrued premium from its escrow to its bins' lenders. Pays nothing when the escrow
    /// cannot cover it: a delinquent position's premium is settled when it closes.
    function settlePremium(uint256 positionId) external publicMutation returns (uint256 paid) {
        if (_state.positions[positionId].owner == address(0)) revert InvalidAmount();
        return LeverageEngine.settleEscrow(_state, _context(), positionId);
    }

    /// @notice Closes `fractionWad` of a position through the pool and pays the proceeds and, on a full close, the
    /// escrow refund to `recipient`. `minimumProceeds` bounds the close's swap fees and slippage.
    function close(uint256 positionId, uint256 fractionWad, uint256 minimumProceeds, address recipient)
        external
        publicMutation
        returns (uint256 payout)
    {
        _ownedPosition(positionId);
        if (fractionWad == 0) revert InvalidAmount();
        if (fractionWad > WAD) revert InvalidAmount();
        CloseResult memory result =
            _unlockClose(CloseRequest(positionId, fractionWad, minimumProceeds, address(0), false, 0));
        _push(_quote(), recipient, result.payout);
        return result.payout;
    }

    /// @notice Starts a delinquent position's grace period. Anyone may flag; the clock does not restart while the
    /// flag stands, and it clears once the position's premium is fully paid again.
    function flagDelinquent(uint256 positionId) external publicMutation {
        if (!isDelinquent(positionId)) revert NotDelinquent();
        Position storage position = _state.positions[positionId];
        if (position.delinquentSince != 0) return;
        position.delinquentSince = uint40(block.timestamp);
        emit DelinquencyFlagged(positionId, block.timestamp);
    }

    /// @notice Closes a delinquent position, flagged at least GRACE_SECONDS ago, for the force-close reward. It buys
    /// only the deficit the liquidity's return leaves, and settles the rest in kind; only if the pool cannot buy it
    /// does the strike fallback run. The owner is credited both tokens to collect.
    /// @dev The grace period gives the owner time to add premium or close, so a delinquency someone caused, for
    /// example by withdrawing a bin's idle liquidity to spike its rate, is not an instant close (audit L3-1).
    /// @param maximumPaid The most the closer pays in each currency if the fallback runs.
    /// @return reward The quote part of the reward; the closer also receives its base part.
    function forceClose(uint256 positionId, uint256 maximumPaid) external publicMutation returns (uint256 reward) {
        if (!isDelinquent(positionId)) revert NotDelinquent();
        uint256 flaggedAt = _state.positions[positionId].delinquentSince;
        if (flaggedAt == 0) revert NotFlagged();
        if (block.timestamp < flaggedAt + GRACE_SECONDS) revert GracePending();
        CloseResult memory result = _unlockClose(CloseRequest(positionId, WAD, 0, msg.sender, false, maximumPaid));
        return _payCloser(result);
    }

    /// @notice Runs a force close through the pool. Only this contract calls it, inside its own unlock, so that a
    /// revert unwinds the attempt's pool deltas and state before the fallback.
    function attemptPoolClose(bytes calldata payload) external returns (bytes memory) {
        if (msg.sender != address(this)) revert Unauthorized();
        return abi.encode(LeverageEngine.close(_state, _context(), abi.decode(payload, (CloseRequest))));
    }

    // ---------------------------------------------------------------- views

    /// @notice The curve in force. Reverts before the first install, when there is none; so does binTicks.
    function curve() external view returns (Curve memory) {
        return LeverageBins.currentCurve(_state);
    }

    function curveVersion(uint256 version) external view returns (CurveVersion memory) {
        return _state.curves[version];
    }

    function curveVersionCount() external view returns (uint256) {
        return _state.curves.length;
    }

    function installed() external view returns (bool) {
        return _state.installed;
    }

    function totals()
        external
        view
        returns (uint256 totalLiquidity, uint256 openPositions, uint256 totalOwed0, uint256 totalOwed1)
    {
        return (_state.totalLiquidity, _state.openPositions, _state.totalOwed0, _state.totalOwed1);
    }

    function lastPositionId() external view returns (uint256) {
        return _state.lastPositionId;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey();
    }

    function binOf(int24 binIndex) external view returns (Bin memory) {
        return _state.bins[binIndex];
    }

    /// @notice The quote still streaming to a bin's lenders, and how much of it has vested since its last checkpoint.
    function streamOf(int24 binIndex) external view returns (uint256 remaining, uint256 vested) {
        Bin storage target = _state.bins[binIndex];
        remaining = target.streamRemaining;
        if (target.liquidity == 0) return (remaining, 0);
        vested = LeverageBins.releasable(target, block.timestamp - target.updatedAt);
    }

    function lenderOf(address account, int24 binIndex) external view returns (Lender memory) {
        return _state.lenders[account][binIndex];
    }

    function owedOf(address account) external view returns (uint256 amount0, uint256 amount1) {
        return (_state.owed[account].amount0, _state.owed[account].amount1);
    }

    function positionOf(uint256 positionId) external view returns (Position memory) {
        return _state.positions[positionId];
    }

    function borrowOf(uint256 positionId, uint256 offset) external view returns (Borrow memory) {
        return _state.borrows[positionId][offset];
    }

    function binTicks(int24 binIndex) external view returns (int24 tickLower, int24 tickUpper) {
        return LeverageBins.binTicks(_state, _context(), binIndex);
    }

    /// @notice Lender earnings in `binIndex` not yet credited to `account`'s owed balance, including what the bin's
    /// stream has vested by now. Excludes swap fees the pool holds until the bin's next modification or collection.
    function pendingEarnings(address account, int24 binIndex) external view returns (uint256 amount0, uint256 amount1) {
        Lender storage holder = _state.lenders[account][binIndex];
        Bin storage target = _state.bins[binIndex];
        (amount0, amount1) = LeverageBins.earnings(_context(), holder, target);
        if (target.liquidity == 0) return (amount0, amount1);
        uint256 vested = LeverageBins.releasable(target, block.timestamp - target.updatedAt);
        uint256 vestedShare = FullMath.mulDiv(vested, holder.liquidity, target.liquidity);
        if (QUOTE_IS_CURRENCY0) amount0 += vestedShare;
        else amount1 += vestedShare;
    }

    /// @notice Premium accrued since the position's last settlement, at the bins' current rate indices.
    function premiumOwed(uint256 positionId) public view returns (uint256) {
        return LeverageEngine.premiumOwed(_state, _context(), positionId);
    }

    /// @notice A position is delinquent once its accrued premium exceeds its escrow; anyone may then force close it.
    function isDelinquent(uint256 positionId) public view returns (bool) {
        if (_state.positions[positionId].owner == address(0)) return false;
        return premiumOwed(positionId) > _state.positions[positionId].escrow;
    }

    // ---------------------------------------------------------------- Kernel lifecycle

    function onInstall(PoolKey memory key, ExtensionSettings calldata settings) external lifecycle returns (bytes4) {
        _requireOwnPool(key);
        _checkSettings(settings);
        if (_state.installed) revert InvalidConfiguration();
        _pushCurve(_decodeCurve(settings.configuration));
        _state.installed = true;
        return this.onInstall.selector;
    }

    /// @dev A new curve takes effect from now as a new version, so open positions keep the curve that priced their
    /// past. The bin width maps bins to ticks, so it can change only while no bin has liquidity.
    function onConfigure(PoolKey memory key, ExtensionSettings calldata, ExtensionSettings calldata settings)
        external
        lifecycle
        returns (bytes4)
    {
        _requireOwnPool(key);
        _checkSettings(settings);
        if (!_state.installed) revert InvalidConfiguration();
        Curve memory next = _decodeCurve(settings.configuration);
        if (next.binWidth != LeverageBins.currentCurve(_state).binWidth) {
            if (_state.totalLiquidity != 0) revert OutstandingObligations();
        }
        _pushCurve(next);
        return this.onConfigure.selector;
    }

    function canActivate(PoolKey memory key, ExtensionSettings calldata settings)
        external
        view
        onlyKernel
        returns (bool)
    {
        _requireOwnPool(key);
        _checkSettings(settings);
        if (!_state.installed) return false;
        bytes32 configured = keccak256(abi.encode(LeverageBins.currentCurve(_state)));
        if (keccak256(abi.encode(_decodeCurve(settings.configuration))) != configured) return false;
        uint256 subscribers = KERNEL.callbackOrder(POOL_ID, CallbackType.BeforeAddLiquidity).length;
        uint32 limitGas = settings.callbackGasLimits[uint8(CallbackType.BeforeAddLiquidity)];
        return _callbackFits(POOL_ID, CallbackType.BeforeAddLiquidity, limitGas, subscribers, false);
    }

    /// @dev Lenders' liquidity, open positions and unpaid claims all stay with this contract; any of them blocks removal.
    function canUninstall(PoolKey memory key) external view onlyKernel returns (bool) {
        _requireOwnPool(key);
        if (_entered) return false;
        if (_state.openPositions != 0) return false;
        if (_state.totalLiquidity != 0) return false;
        if (_state.totalOwed0 != 0) return false;
        return _state.totalOwed1 == 0;
    }

    function onUninstall(PoolKey memory key, bytes calldata) external lifecycle returns (bytes4) {
        _requireOwnPool(key);
        if (!_state.installed) revert InvalidConfiguration();
        _state.installed = false;
        return this.onUninstall.selector;
    }

    /// @notice The add gate: liquidity enters this pool only through this contract.
    /// @dev Not _authenticate: this contract's own adds arrive mid-mutation, while _entered is set. Its adds are root
    /// operations of its own unlock, so context.sender is this contract; every other sender, the route executor
    /// included, is refused, and the subscription is required, so the refusal reverts the add.
    function onCallback(ExecutionContext calldata context, PoolKey memory key, bytes calldata)
        external
        view
        onlyKernel
        returns (CallbackResult memory result)
    {
        _authenticateContext(context, key);
        if (PoolId.unwrap(context.poolId) != PoolId.unwrap(POOL_ID)) revert InvalidPool();
        if (context.callback != CallbackType.BeforeAddLiquidity) revert Unauthorized();
        if (context.sender != address(this)) revert Unauthorized();
        return result;
    }

    /// @dev The PoolManager calls back only the contract that unlocked it, so this runs only inside this contract's
    /// own public mutations.
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != address(MANAGER)) revert Unauthorized();
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        result = _dispatch(action, payload);
        _settleCurrency(CURRENCY0);
        _settleCurrency(CURRENCY1);
    }

    // ---------------------------------------------------------------- unlocked actions

    function _dispatch(Action action, bytes memory payload) private returns (bytes memory) {
        if (action == Action.Deposit) {
            return LeverageLending.deposit(_state, _context(), abi.decode(payload, (BinRequest)));
        }
        if (action == Action.Withdraw) {
            return LeverageLending.withdraw(_state, _context(), abi.decode(payload, (BinRequest)));
        }
        if (action == Action.Collect) {
            return LeverageLending.collect(_state, _context(), abi.decode(payload, (BinRequest)));
        }
        if (action == Action.Open) {
            (address owner, uint256 positionId, OpenRequest memory request) =
                abi.decode(payload, (address, uint256, OpenRequest));
            LeverageEngine.open(_state, _context(), owner, positionId, request);
            return "";
        }
        CloseRequest memory closeRequest = abi.decode(payload, (CloseRequest));
        if (closeRequest.closer == address(0)) {
            return abi.encode(LeverageEngine.close(_state, _context(), closeRequest));
        }
        return _forceClose(payload, closeRequest);
    }

    /// @dev The strike is a fallback, not the closer's choice: at a strike below the market it hands the closer the
    /// owner's levered equity. It runs only for the pool path's own shortfalls, proceeds below the cost or a fill the
    /// pool cannot complete. Any other revert, a Kernel callback starved of gas or an out-of-gas included, bubbles up,
    /// so a closer cannot force the fallback by tuning gas.
    function _forceClose(bytes memory payload, CloseRequest memory request) private returns (bytes memory) {
        try this.attemptPoolClose(payload) returns (bytes memory result) {
            return result;
        } catch (bytes memory reason) {
            _requirePoolShortfall(reason);
        }
        request.atStrike = true;
        return abi.encode(LeverageEngine.close(_state, _context(), request));
    }

    /// @dev Passes the pool path's own shortfalls; rethrows anything else unchanged.
    function _requirePoolShortfall(bytes memory reason) private pure {
        if (_poolShortfall(reason)) return;
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    function _poolShortfall(bytes memory reason) private pure returns (bool) {
        if (reason.length != 4) return false;
        bytes4 selector = bytes4(reason);
        if (selector == LeverageEngine.InsufficientProceeds.selector) return true;
        return selector == LeverageBins.UnexpectedDelta.selector;
    }

    // ---------------------------------------------------------------- settlement and transfers

    function _unlock(Action action, bytes memory payload) private returns (bytes memory) {
        return MANAGER.unlock(abi.encode(action, payload));
    }

    function _unlockClose(CloseRequest memory request) private returns (CloseResult memory) {
        return abi.decode(_unlock(Action.Close, abi.encode(request)), (CloseResult));
    }

    function _payCloser(CloseResult memory result) private returns (uint256 reward) {
        _push(CURRENCY0, msg.sender, result.closerOut0);
        _push(CURRENCY1, msg.sender, result.closerOut1);
        return result.reward;
    }

    /// @dev Settles a currency's net PoolManager delta against this contract's balance.
    function _settleCurrency(Currency currency) private {
        int256 delta = MANAGER.currencyDelta(address(this), currency);
        if (delta > 0) MANAGER.take(currency, address(this), uint256(delta));
        if (delta >= 0) return;
        MANAGER.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(MANAGER), uint256(-delta));
        MANAGER.settle();
    }

    function _push(Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------- helpers

    function _context() private view returns (LeverageContext memory) {
        return LeverageContext({
            manager: MANAGER,
            key: _poolKey(),
            quoteIsCurrency0: QUOTE_IS_CURRENCY0,
            utilizationCeilingBps: UTILIZATION_CEILING_BPS,
            profitShareBps: PROFIT_SHARE_BPS,
            treasuryShareBps: TREASURY_SHARE_BPS,
            feeVaultShareBps: FEE_VAULT_SHARE_BPS,
            treasury: TREASURY,
            feeVault: FEE_VAULT,
            vestSeconds: VEST_SECONDS,
            minBorrowNotional: MIN_BORROW_NOTIONAL
        });
    }

    function _ownedPosition(uint256 positionId) private view returns (Position storage position) {
        position = _state.positions[positionId];
        if (position.owner != msg.sender) revert Unauthorized();
    }

    function _requireActive() private view {
        (, bool active,,) = KERNEL.installationFlags(POOL_ID, address(this));
        if (!active) revert InstallationInactive();
    }

    function _requireBinCount(uint256 binCount) private view {
        if (binCount == 0) revert InvalidAmount();
        if (binCount > MAX_BINS_PER_POSITION) revert InvalidAmount();
    }

    function _requireOwnPool(PoolKey memory key) private view {
        if (PoolId.unwrap(_validateKey(key)) != PoolId.unwrap(POOL_ID)) revert InvalidPool();
    }

    function _checkSettings(ExtensionSettings calldata settings) private pure {
        if (settings.callbackMask != CALLBACK_MASK) revert InvalidConfiguration();
        // Required, so a refusal reverts the add: the gate is worthless if Kernel may skip it.
        if (settings.optionalCallbacks) revert InvalidConfiguration();
        if (settings.allowNesting) revert InvalidConfiguration();
        if (settings.callbackGasLimits[uint8(CallbackType.BeforeAddLiquidity)] == 0) revert InvalidConfiguration();
    }

    function _decodeCurve(bytes calldata configuration) private view returns (Curve memory next) {
        next = abi.decode(configuration, (Curve));
        if (next.binWidth == 0) revert InvalidConfiguration();
        if (next.binWidth > MAX_BIN_WIDTH) revert InvalidConfiguration();
        if (next.forceCloseRewardBps < MIN_REWARD_BPS) revert InvalidConfiguration();
        if (next.forceCloseRewardBps > MAX_REWARD_BPS) revert InvalidConfiguration();
        if (next.kinkWad == 0) revert InvalidConfiguration();
        if (next.kinkWad >= WAD) revert InvalidConfiguration();
        uint256 maximumRateWad = uint256(next.baseRateWad) + next.slope1Wad + next.slope2Wad;
        if (maximumRateWad > MAX_RATE_WAD) revert InvalidConfiguration();
        // Bin zero must fit the tick range, or no bin does.
        LeverageMath.binTicks(0, next.binWidth, TICK_SPACING);
    }

    function _validateDeployment(Deployment memory deployment) private view {
        _validateKey(deployment.key);
        if (deployment.key.currency0.isAddressZero()) revert InvalidConfiguration();
        if (deployment.treasury == address(0)) revert InvalidConfiguration();
        if (deployment.feeVault.code.length == 0) revert InvalidConfiguration();
        if (deployment.profitShareBps > BPS) revert InvalidConfiguration();
        if (uint256(deployment.treasuryShareBps) + deployment.feeVaultShareBps > BPS) revert InvalidConfiguration();
        // Below 100%, so no bin is ever fully lent.
        if (deployment.utilizationCeilingBps == 0) revert InvalidConfiguration();
        if (deployment.utilizationCeilingBps >= BPS) revert InvalidConfiguration();
        if (deployment.maxBinsPerPosition == 0) revert InvalidConfiguration();
        if (deployment.maxBinsPerPosition > MAX_BINS) revert InvalidConfiguration();
        if (deployment.minRewardBps > deployment.maxRewardBps) revert InvalidConfiguration();
        if (deployment.maxRewardBps > BPS) revert InvalidConfiguration();
        if (deployment.maxBinWidth == 0) revert InvalidConfiguration();
        if (deployment.graceSeconds > MAX_GRACE_SECONDS) revert InvalidConfiguration();
        // A stream needs time to vest over; zero would credit premium to whoever is in the bin at that moment.
        if (deployment.vestSeconds == 0) revert InvalidConfiguration();
        if (deployment.vestSeconds > MAX_VEST_SECONDS) revert InvalidConfiguration();
    }

    /// @dev Bounded, so a bin untouched across every change still checkpoints within a known loop.
    function _pushCurve(Curve memory next) private {
        if (_state.curves.length >= LeverageBins.MAX_CURVE_VERSIONS) revert InvalidConfiguration();
        _state.curves.push(CurveVersion(next, uint40(block.timestamp)));
    }

    function _poolKey() private view returns (PoolKey memory) {
        return PoolKey(CURRENCY0, CURRENCY1, FEE, TICK_SPACING, IHooks(address(KERNEL)));
    }

    function _quote() private view returns (Currency) {
        return QUOTE_IS_CURRENCY0 ? CURRENCY0 : CURRENCY1;
    }
}
