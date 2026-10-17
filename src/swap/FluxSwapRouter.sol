// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FluxSwapRouter
/// @notice The way in and out of a FluxPool pool for a holder: an exact-input buy or sell against the
/// pool's own hook, with the trader's own slippage floor and deadline.
///
/// The pool decides everything that matters. The fee is the shell's, resolved per swap from the pool's
/// blocks and capped by the shell; a rejected buy reverts inside the hook, and a sell is never blocked.
/// This contract only moves the two currencies: it pays what the swap owes, and sends what the swap
/// produced straight to `recipient`. It holds no funds between calls and has no owner, no pause and no
/// state to administer, so there is nothing here to protect.
///
/// The trader travels in `hookData`, which is what the core reports to blocks (`_trader`), so a block
/// that counts buys per block or holds a launch-window rule sees the holder rather than this contract.
///
/// Native ETH is currency0 in a FluxPool pool, so a buy sends `msg.value == amountIn`; a sell receives
/// ETH directly from the PoolManager. WETH pools work the same way through the ERC-20 path.
contract FluxSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    /// @param key The pool to trade against. It must be the pool's real key, hook included: the shell
    /// is the hook, and a key without it would address a pool nobody launched.
    /// @param zeroForOne True to pay currency0 and receive currency1 (a buy when the quote is currency0).
    /// @param amountIn How much of the input currency the caller pays.
    /// @param minOut The least the caller accepts from the swap. Checked after it, inside the unlock.
    /// @param recipient Where the output goes.
    /// @param deadline The last timestamp the swap may land in.
    struct ExactIn {
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint128 minOut;
        address recipient;
        uint256 deadline;
    }

    error NotPoolManager();
    error DeadlinePassed(uint256 deadline, uint256 at);
    error WrongValue(uint256 sent, uint256 needed);
    error NoTrade();
    error NoRecipient();
    error SlippageExceeded(uint256 out, uint256 minOut);
    error NothingReceived();
    error UnexpectedSettlement(uint256 settled, uint256 owed);

    event Swapped(
        address indexed trader,
        PoolId indexed pool,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @notice Pays `amountIn` of one side and sends the other side to `recipient`.
    /// @dev Native input must arrive as `msg.value`; token input must be approved to this contract.
    function swapExactIn(ExactIn calldata p) external payable returns (uint256 amountOut) {
        if (block.timestamp > p.deadline) revert DeadlinePassed(p.deadline, block.timestamp);
        if (p.amountIn == 0) revert NoTrade();
        if (p.recipient == address(0)) revert NoRecipient();

        Currency input = p.zeroForOne ? p.key.currency0 : p.key.currency1;
        if (input.isAddressZero()) {
            if (msg.value != p.amountIn) revert WrongValue(msg.value, p.amountIn);
        } else if (msg.value != 0) {
            revert WrongValue(msg.value, 0);
        }

        amountOut = abi.decode(poolManager.unlock(abi.encode(p, msg.sender, msg.value)), (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (ExactIn memory p, address trader, uint256 sent) = abi.decode(raw, (ExactIn, address, uint256));

        Currency input = p.zeroForOne ? p.key.currency0 : p.key.currency1;
        Currency output = p.zeroForOne ? p.key.currency1 : p.key.currency0;

        BalanceDelta delta = poolManager.swap(
            p.key,
            SwapParams({
                zeroForOne: p.zeroForOne,
                amountSpecified: -int256(uint256(p.amountIn)),
                sqrtPriceLimitX96: p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(trader)
        );

        int128 owedDelta = p.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = p.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 owed = owedDelta < 0 ? uint256(uint128(-owedDelta)) : 0;
        uint256 out = outDelta > 0 ? uint256(uint128(outDelta)) : 0;

        if (owed > 0) _settle(input, trader, owed, sent);
        if (out < p.minOut) revert SlippageExceeded(out, p.minOut);
        if (out == 0) revert NothingReceived();
        poolManager.take(output, p.recipient, out);

        emit Swapped(trader, p.key.toId(), p.zeroForOne, owed, out, p.recipient);
        return abi.encode(out);
    }

    /// @dev Pays the PoolManager what the swap owes, from the trader, without holding anything here.
    /// Native ETH is already here as the value the caller sent, which is read out of the payload rather
    /// than from `msg.value`: inside this callback the caller is the PoolManager, so `msg.value` is
    /// zero and checking it there would refuse every buy. A token is pulled straight into the
    /// PoolManager and the settled amount is checked, which is what makes a fee-on-transfer token fail
    /// loudly instead of leaving a debt behind.
    function _settle(Currency currency, address trader, uint256 owed, uint256 sent) internal {
        if (currency.isAddressZero()) {
            if (sent != owed) revert UnexpectedSettlement(sent, owed);
            poolManager.settle{value: owed}();
            return;
        }
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(trader, address(poolManager), owed);
        uint256 settled = poolManager.settle();
        if (settled != owed) revert UnexpectedSettlement(settled, owed);
    }
}
