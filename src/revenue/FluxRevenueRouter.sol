// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The shell functions the revenue router uses.
interface IFluxShellRevenue {
    struct Observation {
        uint32 blockNumber;
        uint32 timestamp;
        int24 tick;
    }

    function collect(PoolKey calldata key) external;
    function claim(Currency currency) external;
    function feeSplit(PoolId id) external view returns (uint256 creatorBps, uint256 agentBps, address agent);
    function observe(PoolId id, uint256 blocksAgo) external view returns (Observation memory);
}

interface IFeeVaultCreator {
    function claimCreator() external returns (uint256);
}

/// @title FluxRevenueRouter
/// @notice Receives the creator fee share of FluxPool's own token pool and splits the pool's fees
/// between the team Safe and buybacks:
///  - Buybacks get 5% of the pool's total fees at or below `mcLow` market cap, rising linearly to 20%
///    at or above `mcHigh`. While the market cap is in a significant drop, buybacks get 30%.
///  - Everything else goes to the Safe. The pool's protocol share already goes to the protocol
///    treasury (the Safe), so the Safe ends up with the rest of the pool's fees.
///  - Buyback shares paid in the token are burned at once. Quote (ETH) buyback shares wait here until the
///    Safe or the operator runs `buyback()`, which buys the token in the pool and burns it.
///  - Funds here stay accessible to the team: the Safe can withdraw at any time.
///
/// Market cap is the token's fixed supply at the shell's start-of-block price, in the quote (ETH), so trades
/// inside the current block can't move it. A drop is a fall of at least `dropTicks` (about 1 bp per
/// tick) from `dropWindowBlocks + dropHoldBlocks` ago that still holds `dropHoldBlocks` ago and now.
contract FluxRevenueRouter is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    struct Config {
        IPoolManager poolManager;
        IFluxShellRevenue shell;
        address token;
        Currency quote; // the pool's quote currency (native ETH on Ethereum, or WETH)
        int24 tickSpacing;
        address safe;
        address operator;
        uint256 mcLow; // in quote units (wei of ETH)
        uint256 mcHigh; // in quote units
        uint32 dropWindowBlocks;
        uint32 dropHoldBlocks;
        int24 dropTicks;
        /// The normal-fee vault of a protected pool (zero otherwise). A protected pool's LP fee is zero, so
        /// its income is the creator fee that vault custodies; this router is that vault's creator
        /// recipient, and everything it receives from the vault is the pool's creator income in full.
        address normalFeeVault;
    }

    uint256 public constant MIN_BUYBACK_BPS = 500;
    uint256 public constant MAX_BUYBACK_BPS = 2_000;
    uint256 public constant DROP_BUYBACK_BPS = 3_000;
    uint256 internal constant BPS = 10_000;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    IFluxShellRevenue public immutable shell;
    IERC20 public immutable token;
    Currency public immutable quote;
    /// @notice Whether the token sorts as currency0 (below the quote's address).
    bool public immutable tokenIsCurrency0;
    int24 public immutable tickSpacing;
    address public immutable safe;
    address public immutable operator;
    uint256 public immutable mcLow;
    uint256 public immutable mcHigh;
    uint32 public immutable dropWindowBlocks;
    uint32 public immutable dropHoldBlocks;
    int24 public immutable dropTicks;
    PoolId public immutable poolId;
    /// @notice The normal-fee vault of a protected pool, or zero.
    address public immutable normalFeeVault;

    event Distributed(
        uint256 ethIn,
        uint256 tokenIn,
        uint256 buybackBps,
        uint256 ethToBuyback,
        uint256 tokensBurned,
        uint256 ethToSafe,
        uint256 tokensToSafe
    );
    event BoughtBack(uint256 ethSpent, uint256 tokensBurned);
    event Withdrawn(address indexed to, address indexed asset, uint256 amount);

    error InvalidConfig();
    error NotSafe();
    error NotOperator();
    error NotPoolManager();
    error SlippageExceeded(uint256 out, uint256 minOut);
    error TransferFailed();

    constructor(Config memory c) {
        if (
            c.token == address(0) || c.token == Currency.unwrap(c.quote) || c.safe == address(0) || c.mcLow >= c.mcHigh
                || c.dropTicks <= 0 || c.dropWindowBlocks == 0 || c.dropHoldBlocks == 0
                || uint256(c.dropWindowBlocks) + c.dropHoldBlocks > 63
        ) revert InvalidConfig();
        poolManager = c.poolManager;
        shell = c.shell;
        token = IERC20(c.token);
        quote = c.quote;
        tokenIsCurrency0 = c.token < Currency.unwrap(c.quote);
        tickSpacing = c.tickSpacing;
        safe = c.safe;
        operator = c.operator == address(0) ? c.safe : c.operator;
        mcLow = c.mcLow;
        mcHigh = c.mcHigh;
        dropWindowBlocks = c.dropWindowBlocks;
        dropHoldBlocks = c.dropHoldBlocks;
        dropTicks = c.dropTicks;
        poolId = poolKey().toId();
        normalFeeVault = c.normalFeeVault;
    }

    // ---------------------------------------------------------------------
    // Splitting
    // ---------------------------------------------------------------------

    /// @notice Collects the pool's fees, then splits what this contract received. Anyone may call.
    function distribute() external {
        uint256 quoteBefore = quote.balanceOfSelf();
        uint256 tokBefore = token.balanceOf(address(this));
        uint256 creatorBps;
        if (normalFeeVault != address(0)) {
            // Protected pool: the creator fee arrives from its vault, which pays only this contract.
            try IFeeVaultCreator(normalFeeVault).claimCreator() {} catch {}
            creatorBps = BPS; // what arrives is the whole of the pool's creator income
        } else {
            shell.collect(poolKey());
            shell.claim(quote);
            shell.claim(Currency.wrap(address(token)));
            (creatorBps,,) = shell.feeSplit(poolId);
        }
        uint256 quoteIn = quote.balanceOfSelf() - quoteBefore;
        uint256 tokIn = token.balanceOf(address(this)) - tokBefore;

        uint256 bps = buybackBps();
        uint256 quoteBuyback = _share(quoteIn, bps, creatorBps);
        uint256 tokBurn = _share(tokIn, bps, creatorBps);

        if (quoteIn > quoteBuyback) quote.transfer(safe, quoteIn - quoteBuyback);
        if (tokIn > tokBurn) token.safeTransfer(safe, tokIn - tokBurn);
        if (tokBurn > 0) token.safeTransfer(BURN, tokBurn);
        emit Distributed(quoteIn, tokIn, bps, quoteBuyback, tokBurn, quoteIn - quoteBuyback, tokIn - tokBurn);
    }

    /// @notice The buyback share of the pool's total fees right now, in bps.
    function buybackBps() public view returns (uint256) {
        if (inDrop()) return DROP_BUYBACK_BPS;
        uint256 mc = marketCapEth();
        if (mc <= mcLow) return MIN_BUYBACK_BPS;
        if (mc >= mcHigh) return MAX_BUYBACK_BPS;
        return MIN_BUYBACK_BPS + (MAX_BUYBACK_BPS - MIN_BUYBACK_BPS) * (mc - mcLow) / (mcHigh - mcLow);
    }

    /// @notice Fixed supply at the latest start-of-block price, in quote units (wei of ETH).
    function marketCapEth() public view returns (uint256) {
        return _mcAtTick(shell.observe(poolId, 0).tick);
    }

    /// @notice Whether the market cap is in a significant drop (see contract notes).
    function inDrop() public view returns (bool) {
        try shell.observe(poolId, uint256(dropWindowBlocks) + dropHoldBlocks) returns (
            IFluxShellRevenue.Observation memory ref
        ) {
            IFluxShellRevenue.Observation memory held = shell.observe(poolId, dropHoldBlocks);
            IFluxShellRevenue.Observation memory latest = shell.observe(poolId, 0);
            if (held.blockNumber <= ref.blockNumber) return false;
            return _dropped(ref.tick, held.tick) >= dropTicks && _dropped(ref.tick, latest.tick) >= dropTicks;
        } catch {
            return false;
        }
    }

    // ---------------------------------------------------------------------
    // Buybacks and team access
    // ---------------------------------------------------------------------

    /// @notice Buys the token with `quoteAmount` of the buyback funds and burns everything bought.
    function buyback(uint256 quoteAmount, uint256 minTokensOut) external returns (uint256 burned) {
        if (msg.sender != operator && msg.sender != safe) revert NotOperator();
        burned = abi.decode(poolManager.unlock(abi.encode(quoteAmount, minTokensOut)), (uint256));
        emit BoughtBack(quoteAmount, burned);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 quoteAmount, uint256 minOut) = abi.decode(data, (uint256, uint256));
        bool zeroForOne = !tokenIsCurrency0; // pay the quote, receive the token
        BalanceDelta d = poolManager.swap(
            poolKey(),
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(quoteAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(address(this))
        );
        int128 quoteDelta = tokenIsCurrency0 ? d.amount1() : d.amount0();
        int128 tokenDelta = tokenIsCurrency0 ? d.amount0() : d.amount1();
        _settle(uint256(uint128(-quoteDelta)));
        uint256 out = uint256(uint128(tokenDelta));
        if (out < minOut) revert SlippageExceeded(out, minOut);
        poolManager.take(Currency.wrap(address(token)), BURN, out);
        return abi.encode(out);
    }

    /// @notice The team keeps access to everything held here. `asset` zero means native ETH.
    function withdraw(address asset, address to, uint256 amount) external {
        if (msg.sender != safe) revert NotSafe();
        if (asset == address(0)) _sendEth(to, amount);
        else IERC20(asset).safeTransfer(to, amount);
        emit Withdrawn(to, asset, amount);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function poolKey() public view returns (PoolKey memory) {
        Currency t = Currency.wrap(address(token));
        return PoolKey({
            currency0: tokenIsCurrency0 ? t : quote,
            currency1: tokenIsCurrency0 ? quote : t,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(shell))
        });
    }

    /// @dev This contract receives only the creator share (`creatorBps` of the pool's fees). The
    /// buyback target is `bps` of the pool's total fees, so it takes `bps / creatorBps` of what
    /// arrived, never more than all of it.
    function _share(uint256 received, uint256 bps, uint256 creatorBps) internal pure returns (uint256) {
        if (creatorBps == 0) return 0;
        uint256 amount = received * bps / creatorBps;
        return amount > received ? received : amount;
    }

    /// @dev Ticks price currency0 in units of currency1 (price = sqrtP^2 / 2^192).
    function _mcAtTick(int24 tick) internal view returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 supply = token.totalSupply();
        if (tokenIsCurrency0) {
            // quote per token = sqrtP^2 / 2^192
            return FullMath.mulDiv(FullMath.mulDiv(supply, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
        }
        // quote per token = 2^192 / sqrtP^2
        return FullMath.mulDiv(FullMath.mulDiv(supply, FixedPoint96.Q96, sqrtP), FixedPoint96.Q96, sqrtP);
    }

    /// @dev How far the token's price fell between two ticks. A cheaper token is a lower tick when the
    /// token is currency0, and a higher tick when it is currency1.
    function _dropped(int24 fromTick, int24 toTick) internal view returns (int24) {
        return tokenIsCurrency0 ? fromTick - toTick : toTick - fromTick;
    }

    /// @dev Pays the PoolManager in the quote currency.
    function _settle(uint256 amount) internal {
        if (quote.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(quote);
            IERC20(Currency.unwrap(quote)).safeTransfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
