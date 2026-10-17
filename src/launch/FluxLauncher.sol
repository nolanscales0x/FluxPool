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

    event Launched(
        PoolId indexed pool, address indexed token, address indexed creator, address core, address launchedBy
    );
    event InitialBuy(PoolId indexed pool, address indexed recipient, uint256 ethIn, uint256 tokensOut);

    error WrongValue();
    error NotPoolManager();
    error InitialBuyTooSmall(uint256 out, uint256 minOut);
    error RefundFailed();

    constructor(IPoolManager _poolManager, FluxShell _shell, address _coreImplementation) {
        poolManager = _poolManager;
        shell = _shell;
        coreImplementation = _coreImplementation;
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
