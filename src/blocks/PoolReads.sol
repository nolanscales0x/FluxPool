// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Pool reads shared by blocks.
library PoolReads {
    using StateLibrary for IPoolManager;

    /// @notice The pool's virtual reserve of the launched token at the current price, from active
    /// liquidity. Exact for a full-range position, which is what FluxPool pools hold.
    function tokenReserve(IPoolManager manager, PoolId id, bool tokenIs0)
        internal
        view
        returns (uint256 reserve, uint160 sqrtPriceX96)
    {
        (sqrtPriceX96,,,) = manager.getSlot0(id);
        uint256 liquidity = manager.getLiquidity(id);
        reserve = tokenIs0
            ? FullMath.mulDiv(liquidity, FixedPoint96.Q96, sqrtPriceX96)
            : FullMath.mulDiv(liquidity, sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @notice Converts an amount of the pool's other currency into launched tokens at the current
    /// price, ignoring slippage. That overstates what a buy receives, so limits built on it err safe.
    function toTokens(uint256 otherAmount, uint160 sqrtPriceX96, bool tokenIs0) internal pure returns (uint256) {
        if (tokenIs0) {
            return FullMath.mulDiv(
                FullMath.mulDiv(otherAmount, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
            );
        }
        return
            FullMath.mulDiv(
                FullMath.mulDiv(otherAmount, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96
            );
    }
}
