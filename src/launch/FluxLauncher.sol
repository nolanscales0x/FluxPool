// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {FluxShell} from "../shell/FluxShell.sol";
import {FluxCore} from "../core/FluxCore.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FluxProtectedToken} from "../protection/FluxProtectedToken.sol";
import {FluxLaunchProtectionModule} from "../protection/FluxLaunchProtectionModule.sol";
import {FluxFeeVault} from "../protection/FluxFeeVault.sol";

/// @notice Chainlink aggregator, as the protected launch reads it.
interface IUsdFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IWETH9 {
    function deposit() external payable;
}

/// @title FluxLauncher
/// @notice The shell's launch adapter. One call launches a FluxPool pool atomically, so there is
/// never a half-created pool to snipe:
///   1. pulls the liquidity tokens from the caller,
///   2. clones a core and writes its lanes and settings,
///   3. stages the pool with the shell (the shell's only authorization for a new pool),
///   4. initializes the token / quote pool at the staged price (native ETH as sent, or wrapped to WETH),
///   5. adds the initial liquidity as a shell-held, locked position,
///   6. makes the initial buy (Programmable requires one) to the launch wallet,
///   7. returns any leftover ETH and tokens to the caller.
/// Permissionless: anyone can launch a pool for their own token. The shell's limits bound every
/// setting, whoever launches. Holds nothing between calls.
contract FluxLauncher is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    struct Launch {
        address token;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        FluxShell.PoolSetup setup; // `core`, `token` and `sqrtPriceX96` are filled in here
        address[] beforeSwap;
        address[] afterSwap;
        FluxCore.SettingInit[] settings;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokenAmount; // tokens pulled from the caller for liquidity
        uint256 liquidityQuote; // quote for liquidity, paid as ETH in msg.value (wrapped here if WETH)
        uint256 initialBuyQuote; // the rest of msg.value, spent on the initial buy
        uint256 minTokensOut;
        address buyRecipient;
    }

    IPoolManager public immutable poolManager;
    FluxShell public immutable shell;
    address public immutable coreImplementation;
    /// @notice The chain's canonical Chainlink native/USD feed (zero off chains 1 and 4663), its pinned
    /// code hash, decimals, and the maximum answer age (the feed's published heartbeat).
    IUsdFeed public immutable usdFeed;
    bytes32 public immutable usdFeedCodeHash;
    uint8 public immutable usdFeedDecimals;
    uint256 public immutable maxFeedAge;
    address public constant CANONICAL_FEED_MAINNET = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant CANONICAL_FEED_ROBINHOOD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    event Launched(
        PoolId indexed pool, address indexed token, address indexed creator, address core, address launchedBy
    );
    event InitialBuy(PoolId indexed pool, address indexed recipient, uint256 ethIn, uint256 tokensOut);

    error WrongValue();
    error NotPoolManager();
    error InitialBuyTooSmall(uint256 out, uint256 minOut);
    error RefundFailed();

    constructor(
        IPoolManager _poolManager,
        FluxShell _shell,
        address _coreImplementation,
        IUsdFeed _usdFeed,
        bytes32 _usdFeedCodeHash
    ) {
        poolManager = _poolManager;
        shell = _shell;
        coreImplementation = _coreImplementation;
        uint8 dec;
        if (address(_usdFeed) != address(0)) {
            address canonical = block.chainid == 1
                ? CANONICAL_FEED_MAINNET
                : block.chainid == 4663 ? CANONICAL_FEED_ROBINHOOD : address(0);
            if (address(_usdFeed) != canonical || address(_usdFeed).codehash != _usdFeedCodeHash) {
                revert InvalidProtectedLaunch();
            }
            dec = _usdFeed.decimals();
            if (dec > 18) revert InvalidProtectedLaunch();
        }
        usdFeed = _usdFeed;
        usdFeedCodeHash = _usdFeedCodeHash;
        usdFeedDecimals = dec;
        maxFeedAge = block.chainid == 1 ? 1 hours : 24 hours;
    }

    function launch(Launch calldata l) external payable returns (PoolId id, address core) {
        if (msg.value != l.liquidityQuote + l.initialBuyQuote) revert WrongValue();
        Currency quote = shell.quote();
        PoolKey memory key = _key(l.token, quote, l.tickSpacing);
        id = key.toId();

        IERC20(l.token).safeTransferFrom(msg.sender, address(this), l.tokenAmount);
        IERC20(l.token).forceApprove(address(shell), l.tokenAmount);
        if (!quote.isAddressZero()) {
            // The launch is funded in ETH; wrap it so the pool's quote side is WETH.
            IWETH9(Currency.unwrap(quote)).deposit{value: msg.value}();
            IERC20(Currency.unwrap(quote)).forceApprove(address(shell), l.liquidityQuote);
        }

        core = Clones.clone(coreImplementation);
        FluxCore(core).initialize(key, l.setup.baseFee, l.beforeSwap, l.afterSwap, l.settings);

        FluxShell.PoolSetup memory setup = l.setup;
        setup.core = core;
        setup.token = l.token;
        setup.sqrtPriceX96 = l.sqrtPriceX96;
        shell.stagePool(key, setup);
        poolManager.initialize(key, l.sqrtPriceX96);
        shell.seedLiquidity{value: quote.isAddressZero() ? l.liquidityQuote : 0}(
            key, l.tickLower, l.tickUpper, l.liquidity
        );

        if (l.initialBuyQuote > 0) {
            bytes memory out = poolManager.unlock(abi.encode(key, l.initialBuyQuote, l.minTokensOut, l.buyRecipient));
            emit InitialBuy(id, l.buyRecipient, l.initialBuyQuote, abi.decode(out, (uint256)));
        }

        _refund(l.token, quote);
        emit Launched(id, l.token, setup.creator, core, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Protected launch (Programmable launch-protection v1)
    // ---------------------------------------------------------------------

    /// @notice Everything a protected launch needs. The token, module and both vaults are deployed
    /// beforehand (each a plan step); this call checks they are wired to each other and to this launcher,
    /// then launches atomically.
    struct ProtectedLaunchParams {
        FluxProtectedToken token;
        FluxLaunchProtectionModule module;
        FluxFeeVault normalFeeVault;
        FluxFeeVault openingTaxVault;
        FluxShell.PoolSetup setup; // pool settings; core, token, price and protection wiring are filled in here
        address[] beforeSwap;
        address[] afterSwap;
        FluxCore.SettingInit[] settings;
        int24 startTick; // the opening price; the whole supply is seeded from the lowest usable tick up to it
        uint256 minTokensOut; // for the initial buy, which is msg.value
    }

    /// @notice The reference's opening-valuation floor, in whole US dollars.
    uint256 public constant MINIMUM_FDV_USD = 15_000;
    int24 internal constant TICK_SPACING = 60;

    event ProtectedLaunch(
        address indexed token,
        PoolId indexed pool,
        uint256 openingFdvUsd,
        uint128 lockedLiquidity,
        uint256 initialBuyNative,
        uint256 initialBuyTokens
    );

    error InvalidProtectedLaunch();
    error InvalidOraclePrice();
    error OpeningValuationTooLow(uint256 actual);
    error InvalidSettlement();

    /// @notice Launches a protected pool in one transaction, the way Programmable's
    /// ProtectedNativeInitializerV1 does: checks the opening valuation against the fixed Chainlink feed,
    /// stages the pool `Locked`, initializes it, seeds the entire supply as shell-held liquidity, starts
    /// protection and makes the initial buy for the developer. Any failure reverts all of it.
    function launchProtected(ProtectedLaunchParams calldata l) external payable returns (PoolId id, address core) {
        address developer = _checkProtectedArgs(l);
        FluxProtectedToken token = l.token;

        uint160 price = TickMath.getSqrtPriceAtTick(l.startTick);
        uint256 fdv = openingFdvUsd(token.launchSupply(), price);
        if (fdv < MINIMUM_FDV_USD) revert OpeningValuationTooLow(fdv);

        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(shell))
        });
        id = key.toId();
        core = _stageProtected(l, key, price);
        poolManager.initialize(key, price);
        uint128 liquidity = _seedAll(key, token, l.startTick);

        token.start();
        uint256 tokensOut =
            abi.decode(poolManager.unlock(abi.encode(key, msg.value, l.minTokensOut, developer)), (uint256));

        // Seeding rounds down, so a few base units of supply can be left here; they belong to the caller.
        uint256 left = token.balanceOf(address(this));
        if (left > 0) IERC20(address(token)).safeTransfer(msg.sender, left);
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            if (!ok) revert RefundFailed();
        }
        emit ProtectedLaunch(address(token), id, fdv, liquidity, msg.value, tokensOut);
        emit Launched(id, address(token), l.setup.creator, core, msg.sender);
    }

    function _checkProtectedArgs(ProtectedLaunchParams calldata l) internal view returns (address developer) {
        if (block.chainid != 1 && block.chainid != 4663) revert InvalidProtectedLaunch();
        if (!shell.quote().isAddressZero()) revert InvalidProtectedLaunch();
        FluxProtectedToken token = l.token;
        if (
            token.initializer() != address(this) || token.poolManager() != address(poolManager)
                || token.startedAt() != 0 || token.balanceOf(address(this)) != token.launchSupply()
                || l.module.shell() != address(shell) || address(l.module.token()) != address(token)
                || l.startTick % TICK_SPACING != 0 || l.startTick <= TickMath.minUsableTick(TICK_SPACING)
                || l.startTick >= TickMath.maxUsableTick(TICK_SPACING)
        ) revert InvalidProtectedLaunch();
        developer = l.module.developer();
        if (
            msg.value == 0 || msg.value > uint256(uint128(type(int128).max)) || l.minTokensOut == 0
                || developer == address(this) || developer == address(poolManager)
        ) revert InvalidProtectedLaunch();
    }

    /// @dev Clones and initializes the core, then stages the pool `Locked` with its protection wiring.
    function _stageProtected(ProtectedLaunchParams calldata l, PoolKey memory key, uint160 price)
        internal
        returns (address core)
    {
        core = Clones.clone(coreImplementation);
        FluxCore(core).initialize(key, l.setup.baseFee, l.beforeSwap, l.afterSwap, l.settings);
        FluxShell.PoolSetup memory setup = l.setup;
        setup.core = core;
        setup.token = address(l.token);
        setup.sqrtPriceX96 = price;
        setup.lockType = FluxShell.LockType.Locked;
        setup.unlockAt = 0;
        setup.protectedLaunch = true;
        setup.protectionModule = address(l.module);
        setup.normalFeeVault = address(l.normalFeeVault);
        setup.openingTaxVault = address(l.openingTaxVault);
        shell.stagePool(key, setup); // the shell checks the full protection wiring again
    }

    /// @dev The whole supply, single-sided below the opening price (as the reference seeds it), held by
    /// the shell and Locked forever.
    function _seedAll(PoolKey memory key, FluxProtectedToken token, int24 startTick) internal returns (uint128) {
        uint256 supply = token.launchSupply();
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        uint256 liquidity = FullMath.mulDiv(
            supply, uint256(1) << 96, TickMath.getSqrtPriceAtTick(startTick) - TickMath.getSqrtPriceAtTick(lower)
        );
        if (liquidity == 0 || liquidity > type(uint128).max) revert InvalidSettlement();
        IERC20(address(token)).forceApprove(address(shell), supply);
        shell.seedLiquidity(key, lower, startTick, uint128(liquidity));
        IERC20(address(token)).forceApprove(address(shell), 0);
        return uint128(liquidity);
    }

    /// @notice The opening valuation in whole US dollars: the full supply at `sqrtPriceX96` (native
    /// currency0, token currency1), priced by the fixed Chainlink native/USD feed. Rounds down, as the
    /// reference does, before the floor is enforced.
    function openingFdvUsd(uint256 supply, uint160 sqrtPriceX96) public view returns (uint256) {
        if (address(usdFeed) == address(0) || address(usdFeed).codehash != usdFeedCodeHash) {
            revert InvalidOraclePrice();
        }
        (uint80 round, int256 answer,, uint256 updated, uint80 answeredRound) = usdFeed.latestRoundData();
        if (
            answer <= 0 || updated == 0 || updated > block.timestamp || block.timestamp - updated > maxFeedAge
                || answeredRound < round || round == 0
        ) revert InvalidOraclePrice();
        uint256 nativeValue;
        if (sqrtPriceX96 <= type(uint128).max) {
            nativeValue = FullMath.mulDiv(uint256(1) << 192, supply, uint256(sqrtPriceX96) * sqrtPriceX96);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, uint256(1) << 64);
            nativeValue = FullMath.mulDiv(uint256(1) << 128, supply, ratioX128);
        }
        return FullMath.mulDiv(nativeValue, uint256(answer), 1 ether * 10 ** usdFeedDecimals);
    }

    /// @dev The initial buy: exact ETH in, every token out to the launch wallet.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 quoteIn, uint256 minOut, address recipient) =
            abi.decode(data, (PoolKey, uint256, uint256, address));
        Currency quote = shell.quote();
        bool quoteIs0 = Currency.unwrap(key.currency0) == Currency.unwrap(quote);
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: quoteIs0,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(recipient)
        );
        uint256 paid = uint256(uint128(-(quoteIs0 ? d.amount0() : d.amount1())));
        if (quote.isAddressZero()) {
            poolManager.settle{value: paid}();
        } else {
            poolManager.sync(quote);
            IERC20(Currency.unwrap(quote)).safeTransfer(address(poolManager), paid);
            poolManager.settle();
        }
        uint256 out = uint256(uint128(quoteIs0 ? d.amount1() : d.amount0()));
        if (out == 0 || out < minOut) revert InitialBuyTooSmall(out, minOut);
        poolManager.take(quoteIs0 ? key.currency1 : key.currency0, recipient, out);
        return abi.encode(out);
    }

    /// @dev The pool key for a token and the quote, sorted as v4 requires.
    function _key(address token, Currency quote, int24 tickSpacing) internal view returns (PoolKey memory) {
        Currency t = Currency.wrap(token);
        bool tokenIs0 = token < Currency.unwrap(quote);
        return PoolKey({
            currency0: tokenIs0 ? t : quote,
            currency1: tokenIs0 ? quote : t,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(shell))
        });
    }

    /// @dev Returns leftovers to the caller: ETH, unused WETH (for a WETH quote) and unused tokens.
    function _refund(address token, Currency quote) internal {
        uint256 eth = address(this).balance;
        if (eth > 0) {
            (bool ok,) = msg.sender.call{value: eth}("");
            if (!ok) revert RefundFailed();
        }
        if (!quote.isAddressZero()) {
            IERC20 q = IERC20(Currency.unwrap(quote));
            uint256 left = q.balanceOf(address(this));
            if (left > 0) q.safeTransfer(msg.sender, left);
            q.forceApprove(address(shell), 0);
        }
        uint256 tokens = IERC20(token).balanceOf(address(this));
        if (tokens > 0) IERC20(token).safeTransfer(msg.sender, tokens);
        IERC20(token).forceApprove(address(shell), 0);
    }

    /// @dev Receives the shell's refund of unused liquidity ETH.
    receive() external payable {}
}
