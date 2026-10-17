// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IFluxCore} from "../core/IFluxCore.sol";

/// @title FluxShell
/// @notice The single, immutable Uniswap v4 hook shared by every FluxPool pool. It forwards each
/// trade moment to the pool's core and enforces protections no core can override:
///   1. Fee cap: the core's fee is clamped to the pool's active cap.
///   2. Sells are never blocked: a core rejection is ignored when the swap sells the launched token.
///   3. Locked liquidity stays locked: all liquidity is shell-held and cannot leave before unlock.
///   4. No minting: the shell holds no minting rights (tokens are fixed-supply, enforced by the factory).
/// Every FluxPool pool pairs a launched token with one quote currency fixed at deploy: native ETH on
/// Ethereum (address(0), so the token is currency1), or an ERC-20 such as WETH, in which case the
/// token may sort on either side of the quote.
/// The shell also collects Programmable's platform fee: 0.30% of the gross quote leg of every buy and
/// sell, rounded up per trade, held as fully backed PoolManager claims in the quote currency and paid
/// only to Programmable's fixed recipient (same accounting as Programmable's EthereumNative30HookV3
/// reference). The shell is the only contract that uses swap return deltas; blocks never see them.
/// No proxy, no owner, no admin setters.
contract FluxShell is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Protocol limits (permanent)
    // ---------------------------------------------------------------------

    /// @notice Gas forwarded to the core on each call. The core cannot use more than this.
    uint256 public constant CORE_GAS_BEFORE_SWAP = 500_000;
    uint256 public constant CORE_GAS_AFTER_SWAP = 320_000;
    /// @dev Gas kept back so the shell can finish after a core burns its whole allowance.
    uint256 internal constant GAS_RESERVE = 10_000;
    /// @notice Highest normal-trading cap a pool may set (10%).
    uint24 public constant MAX_FEE_CAP = 100_000;
    /// @notice Highest launch-window cap a pool may set (99%).
    uint24 public constant MAX_LAUNCH_FEE_CAP = 990_000;
    /// @notice Longest launch window a pool may set.
    uint32 public constant MAX_LAUNCH_WINDOW = 1 hours;
    /// @notice Shortest timelock delay a pool may set.
    uint64 public constant MIN_TIMELOCK_DELAY = 24 hours;
    /// @notice Size of each pool's price-reference ring buffer (one entry per block with swaps).
    uint256 public constant OBSERVATIONS = 64;

    /// @notice Fee-split bounds the shell enforces whatever the CreatorFee block reports (bps of fees).
    uint256 public constant MIN_CREATOR_SHARE_BPS = 2_000;
    uint256 public constant MAX_CREATOR_SHARE_BPS = 8_000;
    uint256 public constant MAX_AGENT_SHARE_BPS = 2_000;
    /// @notice Split used when the CreatorFee block can't be read.
    uint256 public constant DEFAULT_CREATOR_SHARE_BPS = 5_000;
    /// @notice Setting names in the CreatorFee block.
    bytes32 public constant CREATOR_SHARE = "creatorShareBps";
    bytes32 public constant AGENT_SHARE = "agentShareBps";
    uint256 internal constant READ_GAS = 30_000;

    /// @notice Programmable's fixed platform-fee recipient.
    address public constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint256 public constant PLATFORM_FEE_BPS = 30;
    uint256 public constant FEE_DENOMINATOR = 10_000;
    bytes32 public constant FEE_PROFILE =
        keccak256("programmable.robinhood-quote-fee.gross-quote.ceil-per-trade.fluxpool-shell.v2");

    // Transient slots for the swap in progress.
    bytes32 internal constant SWAP_ACTIVE_SLOT = keccak256("fluxpool.shell.swapActive");
    bytes32 internal constant EXPECTED_QUOTE_SLOT = keccak256("fluxpool.shell.expectedQuote");

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum LockType {
        Locked, // never withdrawable
        TimeLocked, // withdrawable by the creator after unlockAt
        Unlocked // withdrawable by the creator at any time (flagged red on the trust card)
    }

    /// @notice What the launch adapter supplies when it stages a pool.
    struct PoolSetup {
        uint160 sqrtPriceX96; // the pool must be initialized at exactly this price
        address core;
        address token;
        address creator; // governs the pool (agents, playbooks, changes)
        address creatorFeeRecipient; // receives the creator's fee share; zero means the creator
        uint24 baseFee;
        uint24 feeCap;
        uint24 launchFeeCap;
        uint32 launchWindow;
        uint64 timelockDelay;
        LockType lockType;
        uint64 unlockAt;
        uint8 launchMode; // freedom mode at launch: 0 Guarded, 1 Fast, 2 Wild
    }

    struct PoolConfig {
        address core;
        address token;
        address creator; // governs the pool (agents, playbooks, changes)
        address creatorFeeRecipient; // receives the creator's fee share; zero means the creator
        uint24 baseFee;
        uint24 feeCap;
        uint24 launchFeeCap;
        uint32 launchWindow;
        uint64 launchStart;
        uint64 timelockDelay;
        LockType lockType;
        uint64 unlockAt;
        uint8 launchMode; // freedom mode at launch: 0 Guarded, 1 Fast, 2 Wild
        bool tokenIsCurrency0;
        uint160 initSqrtPriceX96;
        bool staged;
        bool initialized;
    }

    /// @notice The shell's single liquidity position in a pool.
    struct Position {
        int24 tickLower;
        int24 tickUpper;
        bool seeded;
    }

    /// @notice Start-of-block price, recorded before the first swap in each block. Playbook trigger
    /// checks read these, so a swap inside the current block can't fake a price move.
    struct Observation {
        uint32 blockNumber;
        uint32 timestamp;
        int24 tick;
    }

    enum Action {
        Seed,
        Withdraw, // liquidityDelta < 0
        Collect, // liquidityDelta == 0: realizes fees only
        ClaimPlatform // pays accrued platform fees to PLATFORM_RECIPIENT
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice The currency every FluxPool pool pairs its token with (native ETH on Ethereum, or WETH).
    Currency public immutable quote;

    /// @notice The only address that may stage pools and seed their liquidity. This is the launch
    /// adapter for whichever Programmable path is confirmed (Module Mode or Custom Launch).
    address public immutable launcher;
    /// @notice The CreatorFee block, where each pool's fee split is set (within the shell's bounds).
    address public immutable creatorFeeBlock;
    /// @notice The AgentRegistry, read to find who receives a pool's agent share.
    address public immutable agentRegistry;
    /// @notice Receives the protocol's share of fees.
    address public immutable protocolTreasury;

    /// @notice Fees credited to each recipient, per currency. Pulled with claim(), so a recipient
    /// that can't receive funds never blocks collect() for anyone else.
    mapping(address account => mapping(Currency currency => uint256)) public claimable;
    /// @notice Platform fees accrued and not yet claimed, in the quote currency. Backed 1:1 by ERC-6909
    /// claims the shell holds in the PoolManager.
    uint256 public platformAccrued;

    mapping(PoolId => PoolConfig) internal _configs;
    mapping(PoolId => Position) public positions;
    /// @notice Swap fees taken out of the position but not yet paid out, per pool and currency index.
    mapping(PoolId => uint256[2]) internal _pendingFees;
    mapping(PoolId => Observation[OBSERVATIONS]) internal _observations;
    /// @notice Total observations ever written per pool; the latest is at (count - 1) % OBSERVATIONS.
    mapping(PoolId => uint256) public observationCount;

    // ---------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------

    event PoolRegistered(PoolId indexed pool, address indexed token, address indexed creator, address core);
    event LiquiditySeeded(PoolId indexed pool, uint128 liquidity, LockType lockType, uint64 unlockAt);
    event LiquidityWithdrawn(PoolId indexed pool, uint128 liquidity, address to);
    event FeesCollected(
        PoolId indexed pool, Currency indexed currency, uint256 toCreator, uint256 toProtocol, uint256 toAgent
    );
    event FeesClaimed(address indexed account, Currency indexed currency, uint256 amount);
    event PlatformFeeAccrued(PoolId indexed pool, bool isBuy, uint256 grossQuote, uint256 platformFee);
    event PlatformFeesClaimed(uint256 amount);
    event CoreCallFailed(PoolId indexed pool, bytes4 selector);

    error NotLauncher();
    error NotCreator();
    error NotSelf();
    error InvalidSetup();
    error AlreadyStaged();
    error NotStaged();
    error WrongInitialPrice();
    error NoObservation();
    error AlreadySeeded();
    error PoolNotLive();
    error TradeRejected();
    error ExternalLiquidityNotAllowed();
    error LiquidityLocked();
    error InsufficientGasForCore();
    error ReentrantSwap();
    error InvalidSwapContext();
    error NoTrade();
    error PartialFillUnsupported(uint256 expected, uint256 actual);
    error NothingToClaim();

    constructor(
        IPoolManager _poolManager,
        address _launcher,
        address _creatorFeeBlock,
        address _agentRegistry,
        address _protocolTreasury,
        Currency _quote
    ) BaseHook(_poolManager) {
        if (_launcher == address(0) || _protocolTreasury == address(0)) revert InvalidSetup();
        quote = _quote;
        launcher = _launcher;
        creatorFeeBlock = _creatorFeeBlock;
        agentRegistry = _agentRegistry;
        protocolTreasury = _protocolTreasury;
    }

    // ---------------------------------------------------------------------
    // Permissions (fixed forever by the mined address)
    // ---------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // platform fee only
            afterSwapReturnDelta: true, // platform fee only
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Launch path (launcher only)
    // ---------------------------------------------------------------------

    /// @notice Records a pool's config before the launcher initializes it. Pools that were not
    /// staged cannot be initialized with this hook.
    function stagePool(PoolKey calldata key, PoolSetup calldata s) external {
        if (msg.sender != launcher) revert NotLauncher();
        PoolId id = key.toId();
        PoolConfig storage cfg = _configs[id];
        if (cfg.staged) revert AlreadyStaged();

        // The pool pairs the launched token with the shell's quote currency, in either order.
        bool tokenIs0 = Currency.unwrap(key.currency0) == s.token;
        Currency other = tokenIs0 ? key.currency1 : key.currency0;
        if (
            s.sqrtPriceX96 == 0 || address(key.hooks) != address(this) || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG
                || s.core == address(0) || s.creator == address(0) || s.token == address(0)
                || Currency.unwrap(quote) == s.token || Currency.unwrap(other) != Currency.unwrap(quote)
                || (!tokenIs0 && Currency.unwrap(key.currency1) != s.token) || s.baseFee > s.feeCap
                || s.feeCap > MAX_FEE_CAP || s.launchFeeCap < s.feeCap || s.launchFeeCap > MAX_LAUNCH_FEE_CAP
                || s.launchWindow > MAX_LAUNCH_WINDOW || s.timelockDelay < MIN_TIMELOCK_DELAY
                || (s.lockType == LockType.TimeLocked && s.unlockAt <= block.timestamp)
                || (s.lockType != LockType.TimeLocked && s.unlockAt != 0) || s.launchMode > 2
        ) revert InvalidSetup();

        cfg.initSqrtPriceX96 = s.sqrtPriceX96;
        cfg.core = s.core;
        cfg.token = s.token;
        cfg.creator = s.creator;
        cfg.creatorFeeRecipient = s.creatorFeeRecipient == address(0) ? s.creator : s.creatorFeeRecipient;
        cfg.baseFee = s.baseFee;
        cfg.feeCap = s.feeCap;
        cfg.launchFeeCap = s.launchFeeCap;
        cfg.launchWindow = s.launchWindow;
        cfg.timelockDelay = s.timelockDelay;
        cfg.lockType = s.lockType;
        cfg.unlockAt = s.unlockAt;
        cfg.launchMode = s.launchMode;
        cfg.tokenIsCurrency0 = tokenIs0;
        cfg.staged = true;
    }

    /// @notice Adds the pool's initial liquidity as a shell-held position. ERC-20 sides (WETH and the
    /// token) are pulled from the launcher; a native quote comes from msg.value (excess refunded).
    function seedLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external payable {
        if (msg.sender != launcher) revert NotLauncher();
        PoolId id = key.toId();
        if (!_configs[id].initialized) revert PoolNotLive();
        Position storage pos = positions[id];
        if (pos.seeded) revert AlreadySeeded();
        pos.tickLower = tickLower;
        pos.tickUpper = tickUpper;
        pos.seeded = true;

        uint256 balanceBefore = address(this).balance - msg.value;
        poolManager.unlock(abi.encode(Action.Seed, key, int256(uint256(liquidity)), msg.sender));

        uint256 leftover = address(this).balance - balanceBefore;
        if (leftover > 0) CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, leftover); // native quote only

        PoolConfig storage cfg = _configs[id];
        emit LiquiditySeeded(id, liquidity, cfg.lockType, cfg.unlockAt);
    }

    /// @notice Lets the creator withdraw liquidity from a TimeLocked pool after unlock, or from an
    /// Unlocked pool at any time. Fees earned by the position stay in the shell for the fee split.
    function withdrawLiquidity(PoolKey calldata key, uint128 liquidity) external {
        PoolId id = key.toId();
        PoolConfig storage cfg = _configs[id];
        if (msg.sender != cfg.creator) revert NotCreator();
        if (!_isUnlocked(cfg)) revert LiquidityLocked();

        poolManager.unlock(abi.encode(Action.Withdraw, key, -int256(uint256(liquidity)), msg.sender));
        emit LiquidityWithdrawn(id, liquidity, msg.sender);
    }

    /// @notice Realizes the shell position's swap fees and splits them between the creator, the
    /// protocol and the pool's agent. Anyone can call it, so payouts never depend on one key.
    function collect(PoolKey calldata key) external {
        PoolId id = key.toId();
        PoolConfig storage cfg = _configs[id];
        if (!cfg.initialized) revert PoolNotLive();
        Position memory pos = positions[id];
        if (pos.seeded) {
            (uint128 liq,,) = poolManager.getPositionInfo(id, address(this), pos.tickLower, pos.tickUpper, bytes32(0));
            if (liq > 0) poolManager.unlock(abi.encode(Action.Collect, key, int256(0), address(0)));
        }

        (uint256 creatorBps, uint256 agentBps, address agent) = feeSplit(id);
        _distribute(id, key.currency0, 0, cfg.creatorFeeRecipient, creatorBps, agent, agentBps);
        _distribute(id, key.currency1, 1, cfg.creatorFeeRecipient, creatorBps, agent, agentBps);
    }

    /// @notice Pays out everything credited to the caller in one currency.
    function claim(Currency currency) external {
        uint256 amount = claimable[msg.sender][currency];
        if (amount == 0) return;
        claimable[msg.sender][currency] = 0;
        currency.transfer(msg.sender, amount);
        emit FeesClaimed(msg.sender, currency, amount);
    }

    /// @notice Pays every accrued platform fee to Programmable's fixed recipient. Anyone may call.
    function claimPlatform() external returns (uint256 amount) {
        amount = platformAccrued;
        if (amount == 0) revert NothingToClaim();
        platformAccrued = 0;
        poolManager.unlock(abi.encode(Action.ClaimPlatform, amount));
        emit PlatformFeesClaimed(amount);
    }

    /// @notice Gross quote amount and platform fee for a quote leg. `amountIsNet` means the amount
    /// excludes the fee (fee added on top); otherwise the fee comes out of it. Rounds up.
    function quotePlatformFee(uint256 amount, bool amountIsNet) public pure returns (uint256 gross, uint256 fee) {
        if (amountIsNet) {
            gross = Math.mulDiv(amount, FEE_DENOMINATOR, FEE_DENOMINATOR - PLATFORM_FEE_BPS, Math.Rounding.Ceil);
            fee = gross - amount;
        } else {
            gross = amount;
            fee = Math.mulDiv(amount, PLATFORM_FEE_BPS, FEE_DENOMINATOR, Math.Rounding.Ceil);
        }
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (Action(uint8(uint256(bytes32(data[:32])))) == Action.ClaimPlatform) {
            (, uint256 amount) = abi.decode(data, (Action, uint256));
            poolManager.burn(address(this), quote.toId(), amount);
            poolManager.take(quote, PLATFORM_RECIPIENT, amount);
            return "";
        }
        (Action action, PoolKey memory key, int256 liquidityDelta, address party) =
            abi.decode(data, (Action, PoolKey, int256, address));
        PoolId id = key.toId();
        Position memory pos = positions[id];

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower, tickUpper: pos.tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );

        if (action == Action.Seed) {
            _pay(key.currency0, callerDelta.amount0(), party);
            _pay(key.currency1, callerDelta.amount1(), party);
        } else {
            // Principal goes to the creator; accrued fees are kept for the fee split.
            BalanceDelta principal = callerDelta - feesAccrued;
            _take(key.currency0, principal.amount0(), party);
            _take(key.currency1, principal.amount1(), party);
            _keepFees(id, key, feesAccrued);
        }
        return "";
    }

    // ---------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------

    /// @dev Doesn't check who initialized: under Custom Launch that's Programmable's router, not ours.
    /// Staging (launcher only) is the authorization, and the exact-price check stops anyone
    /// initializing a staged pool at a price of their choosing.
    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId id = key.toId();
        PoolConfig storage cfg = _configs[id];
        if (!cfg.staged) revert NotStaged();
        if (sqrtPriceX96 != cfg.initSqrtPriceX96) revert WrongInitialPrice();
        _record(id, tick);
        cfg.initialized = true;
        cfg.launchStart = uint64(block.timestamp);
        emit PoolRegistered(id, cfg.token, cfg.creator, cfg.core);
        return this.afterInitialize.selector;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != address(this)) revert ExternalLiquidityNotAllowed();
        return this.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (sender != address(this)) revert ExternalLiquidityNotAllowed();
        // liquidityDelta == 0 is a fee collection (v4 routes it through the remove path); always allowed.
        if (params.liquidityDelta < 0 && !_isUnlocked(_configs[key.toId()])) revert LiquidityLocked();
        return this.beforeRemoveLiquidity.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal pure override returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal pure override returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_tload(SWAP_ACTIVE_SLOT) != 0) revert ReentrantSwap();
        if (params.amountSpecified == 0) revert NoTrade();
        _tstore(SWAP_ACTIVE_SLOT, 1);
        _observeStartOfBlock(key.toId());
        (bool ok, uint256 rawFee, uint256 rawAllow) = _callCore(
            _configs[key.toId()].core,
            CORE_GAS_BEFORE_SWAP,
            abi.encodeCall(IFluxCore.onBeforeSwap, (sender, key, params, hookData))
        );
        uint24 fee = _resolveFee(key.toId(), params.zeroForOne, ok, rawFee, rawAllow);
        return (this.beforeSwap.selector, _platformFeeBefore(key, params), fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev When the swap specifies the quote amount (exact-in buy, exact-out sell), the platform fee
    /// is taken from the specified side now, and the pool's quote leg must then fill exactly.
    function _platformFeeBefore(PoolKey calldata key, SwapParams calldata params) internal returns (BeforeSwapDelta) {
        bool quoteIs0 = !_configs[key.toId()].tokenIsCurrency0;
        if (!_quoteIsSpecified(params, quoteIs0)) return BeforeSwapDeltaLibrary.ZERO_DELTA;
        uint256 quoteAmount = _abs(params.amountSpecified);
        (uint256 gross, uint256 platformFee) = quotePlatformFee(quoteAmount, params.amountSpecified > 0);
        uint256 expected = params.amountSpecified > 0 ? gross : quoteAmount - platformFee;
        if (expected == 0) revert NoTrade();
        _tstore(EXPECTED_QUOTE_SLOT, expected);
        _accruePlatform(key, params.zeroForOne == quoteIs0, gross, platformFee);
        return toBeforeSwapDelta(SafeCast.toInt128(SafeCast.toInt256(platformFee)), 0);
    }

    /// @dev When the quote amount is unspecified (exact-in sell, exact-out buy), the platform fee is
    /// taken from the quote leg after the swap. Returns the hook's delta in the unspecified currency.
    function _platformFeeAfter(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        returns (int128)
    {
        bool quoteIs0 = !_configs[key.toId()].tokenIsCurrency0;
        uint256 quoteAmount = _abs(int256(quoteIs0 ? delta.amount0() : delta.amount1()));
        if (quoteAmount == 0 || (quoteIs0 ? delta.amount1() : delta.amount0()) == 0) revert NoTrade();
        if (_quoteIsSpecified(params, quoteIs0)) {
            uint256 expected = _tload(EXPECTED_QUOTE_SLOT);
            if (quoteAmount != expected) revert PartialFillUnsupported(expected, quoteAmount);
            return 0;
        }
        (uint256 gross, uint256 platformFee) = quotePlatformFee(quoteAmount, params.amountSpecified > 0);
        if (params.amountSpecified < 0 && platformFee >= quoteAmount) revert NoTrade();
        _accruePlatform(key, params.zeroForOne == quoteIs0, gross, platformFee);
        return SafeCast.toInt128(SafeCast.toInt256(platformFee));
    }

    /// @dev The specified currency is the input on exact-in swaps and the output on exact-out swaps.
    function _quoteIsSpecified(SwapParams calldata params, bool quoteIs0) internal pure returns (bool) {
        bool specifiedIs0 = params.zeroForOne == (params.amountSpecified < 0);
        return specifiedIs0 == quoteIs0;
    }

    /// @dev Mints the fee as quote claims to the shell (backed by the swap's own delta) and records it.
    function _accruePlatform(PoolKey calldata key, bool isBuy, uint256 gross, uint256 platformFee) internal {
        poolManager.mint(address(this), quote.toId(), platformFee);
        platformAccrued += platformFee;
        emit PlatformFeeAccrued(key.toId(), isBuy, gross, platformFee);
    }

    /// @dev Turns the core's raw answer into the fee the pool charges, enforcing the cap and the
    /// never-block-a-sell rule.
    function _resolveFee(PoolId id, bool zeroForOne, bool ok, uint256 rawFee, uint256 rawAllow)
        internal
        returns (uint24 fee)
    {
        PoolConfig storage cfg = _configs[id];
        bool isSell = cfg.tokenIsCurrency0 == zeroForOne;
        bool inLaunchWindow = block.timestamp < uint256(cfg.launchStart) + cfg.launchWindow;
        uint24 cap = inLaunchWindow ? cfg.launchFeeCap : cfg.feeCap;

        if (ok && rawFee <= type(uint24).max && rawAllow <= 1) {
            if (rawAllow == 0 && !isSell) revert TradeRejected();
            fee = uint24(rawFee) > cap ? cap : uint24(rawFee);
        } else {
            // Core failed or answered out of range. Sells (and buys after launch) pay the base fee.
            // Buys inside the launch window pay the launch cap, so breaking the core can't be used
            // to skip anti-sniper protection.
            fee = (inLaunchWindow && !isSell) ? cap : cfg.baseFee;
            emit CoreCallFailed(id, IFluxCore.onBeforeSwap.selector);
        }
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (_tload(SWAP_ACTIVE_SLOT) == 0) revert InvalidSwapContext();
        int128 hookDelta = _platformFeeAfter(key, params, delta);
        PoolId id = key.toId();
        (bool ok,,) = _callCore(
            _configs[id].core,
            CORE_GAS_AFTER_SWAP,
            abi.encodeCall(IFluxCore.onAfterSwap, (sender, key, params, delta, hookData))
        );
        if (!ok) emit CoreCallFailed(id, IFluxCore.onAfterSwap.selector);
        _tstore(EXPECTED_QUOTE_SLOT, 0);
        _tstore(SWAP_ACTIVE_SLOT, 0);
        return (this.afterSwap.selector, hookDelta);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice The split collect() would use now: creator and agent shares in bps, and the agent
    /// (zero if none, in which case the agent share goes to the creator). The protocol gets the rest.
    function feeSplit(PoolId id) public view returns (uint256 creatorBps, uint256 agentBps, address agent) {
        address core = _configs[id].core;
        (bool ok, uint256 v) =
            _read(creatorFeeBlock, abi.encodeWithSignature("getSetting(address,bytes32)", core, CREATOR_SHARE));
        creatorBps = ok ? v : DEFAULT_CREATOR_SHARE_BPS;
        if (creatorBps < MIN_CREATOR_SHARE_BPS) creatorBps = MIN_CREATOR_SHARE_BPS;
        if (creatorBps > MAX_CREATOR_SHARE_BPS) creatorBps = MAX_CREATOR_SHARE_BPS;

        (ok, v) = _read(creatorFeeBlock, abi.encodeWithSignature("getSetting(address,bytes32)", core, AGENT_SHARE));
        agentBps = ok ? v : 0;
        if (agentBps > MAX_AGENT_SHARE_BPS) agentBps = MAX_AGENT_SHARE_BPS;

        (ok, v) = _read(agentRegistry, abi.encodeWithSignature("agentOf(bytes32)", PoolId.unwrap(id)));
        if (ok && v <= type(uint160).max) agent = address(uint160(v));
        if (agent == address(0)) {
            creatorBps += agentBps;
            agentBps = 0;
        }
    }

    /// @notice What the registries need about a pool: who governs it, how long changes wait, and
    /// which core to write to. `live` is false for pools that were never initialized.
    /// @notice The freedom mode the pool launched in. The ChangeRegistry tracks changes from here.
    function launchModeOf(PoolId id) external view returns (uint8) {
        return _configs[id].launchMode;
    }

    function governanceOf(PoolId id)
        external
        view
        returns (bool live, address creator, uint64 timelockDelay, address core)
    {
        PoolConfig storage cfg = _configs[id];
        return (cfg.initialized, cfg.creator, cfg.timelockDelay, cfg.core);
    }

    /// @notice What blocks need about a pool's launch, in one cheap call.
    function launchInfo(PoolId id)
        external
        view
        returns (bool tokenIsCurrency0, uint64 launchStart, uint32 launchWindow)
    {
        PoolConfig storage cfg = _configs[id];
        return (cfg.tokenIsCurrency0, cfg.launchStart, cfg.launchWindow);
    }

    function poolConfig(PoolId id) external view returns (PoolConfig memory) {
        return _configs[id];
    }

    function pendingFees(PoolId id) external view returns (uint256 amount0, uint256 amount1) {
        return (_pendingFees[id][0], _pendingFees[id][1]);
    }

    /// @notice The newest start-of-block price at least `blocksAgo` blocks old. Playbook trigger checks
    /// compare this against the current price. Reverts if the buffer doesn't reach back that far.
    function observe(PoolId id, uint256 blocksAgo) external view returns (Observation memory obs) {
        uint256 count = observationCount[id];
        if (count == 0) revert NoObservation();
        uint256 target = block.number >= blocksAgo ? block.number - blocksAgo : 0;
        uint256 n = count < OBSERVATIONS ? count : OBSERVATIONS;
        for (uint256 i; i < n; i++) {
            obs = _observations[id][(count - 1 - i) % OBSERVATIONS];
            if (obs.blockNumber <= target) return obs;
        }
        revert NoObservation();
    }

    function latestObservation(PoolId id) external view returns (Observation memory) {
        uint256 count = observationCount[id];
        if (count == 0) revert NoObservation();
        return _observations[id][(count - 1) % OBSERVATIONS];
    }

    /// @notice The fee cap in force right now (launch-window cap during the window, normal cap after).
    function activeFeeCap(PoolId id) external view returns (uint24) {
        PoolConfig storage cfg = _configs[id];
        return block.timestamp < uint256(cfg.launchStart) + cfg.launchWindow ? cfg.launchFeeCap : cfg.feeCap;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Calls the core with a hard gas limit and no trust in its return data:
    ///  - reverts up front if the caller didn't supply enough gas for the core to get its full
    ///    allowance, so a trader can't starve the core to force the fallback path;
    ///  - copies at most 64 bytes of return data, so a return bomb can't burn the shell's gas;
    ///  - treats short return data as failure instead of letting abi.decode revert.
    function _callCore(address core, uint256 gasLimit, bytes memory data)
        internal
        returns (bool ok, uint256 word0, uint256 word1)
    {
        if (gasleft() < gasLimit + gasLimit / 63 + GAS_RESERVE) revert InsufficientGasForCore();
        assembly ("memory-safe") {
            ok := call(gasLimit, core, 0, add(data, 0x20), mload(data), 0, 0)
            if and(ok, lt(returndatasize(), 0x40)) { ok := 0 }
            if ok {
                returndatacopy(0, 0, 0x40)
                word0 := mload(0)
                word1 := mload(0x20)
            }
        }
        // A call to an address with no code "succeeds" with empty return data; the length check
        // above turns that into a failure for onBeforeSwap. For onAfterSwap it is harmless.
    }

    /// @dev Records the pool's price before the first swap of each block, i.e. where the previous
    /// block closed. One storage write per pool per block with swaps.
    function _observeStartOfBlock(PoolId id) internal {
        uint256 count = observationCount[id];
        if (count != 0 && _observations[id][(count - 1) % OBSERVATIONS].blockNumber == uint32(block.number)) return;
        (, int24 tick,,) = poolManager.getSlot0(id);
        _record(id, tick);
    }

    function _record(PoolId id, int24 tick) internal {
        uint256 count = observationCount[id];
        _observations[id][count % OBSERVATIONS] =
            Observation({blockNumber: uint32(block.number), timestamp: uint32(block.timestamp), tick: tick});
        observationCount[id] = count + 1;
    }

    function _distribute(
        PoolId id,
        Currency currency,
        uint256 index,
        address creator,
        uint256 creatorBps,
        address agent,
        uint256 agentBps
    ) internal {
        uint256 amount = _pendingFees[id][index];
        if (amount == 0) return;
        _pendingFees[id][index] = 0;
        uint256 toCreator = amount * creatorBps / 10_000;
        uint256 toAgent = amount * agentBps / 10_000;
        uint256 toProtocol = amount - toCreator - toAgent;
        claimable[creator][currency] += toCreator;
        if (toAgent > 0) claimable[agent][currency] += toAgent;
        claimable[protocolTreasury][currency] += toProtocol;
        emit FeesCollected(id, currency, toCreator, toProtocol, toAgent);
    }

    /// @dev Gas-limited staticcall returning one word; any failure or short data reads as not ok.
    function _read(address target, bytes memory data) internal view returns (bool ok, uint256 value) {
        if (target == address(0)) return (false, 0);
        assembly ("memory-safe") {
            ok := staticcall(READ_GAS, target, add(data, 0x20), mload(data), 0, 0x20)
            if lt(returndatasize(), 0x20) { ok := 0 }
            value := mload(0)
        }
    }

    function _abs(int256 x) internal pure returns (uint256) {
        if (x == type(int256).min) revert NoTrade();
        return uint256(x < 0 ? -x : x);
    }

    function _tload(bytes32 slot) internal view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 v) internal {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    function _isUnlocked(PoolConfig storage cfg) internal view returns (bool) {
        if (cfg.lockType == LockType.Unlocked) return true;
        if (cfg.lockType == LockType.TimeLocked) return block.timestamp >= cfg.unlockAt;
        return false;
    }

    function _pay(Currency currency, int128 amount, address payer) internal {
        if (amount >= 0) return;
        uint256 owed = uint256(uint128(-amount));
        if (currency.isAddressZero()) {
            poolManager.settle{value: owed}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), owed);
            poolManager.settle();
        }
    }

    function _take(Currency currency, int128 amount, address to) internal {
        if (amount > 0) poolManager.take(currency, to, uint256(uint128(amount)));
    }

    function _keepFees(PoolId id, PoolKey memory key, BalanceDelta fees) internal {
        int128 f0 = fees.amount0();
        int128 f1 = fees.amount1();
        if (f0 > 0) {
            poolManager.take(key.currency0, address(this), uint256(uint128(f0)));
            _pendingFees[id][0] += uint256(uint128(f0));
        }
        if (f1 > 0) {
            poolManager.take(key.currency1, address(this), uint256(uint128(f1)));
            _pendingFees[id][1] += uint256(uint128(f1));
        }
    }

    /// @dev Receives native currency from PoolManager.take and from seedLiquidity.
    receive() external payable {}
}
