// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice What the shell calls on a pool's core. The shell treats every answer as untrusted:
/// it calls with a fixed gas limit, decodes return data by hand, and clamps the result.
interface IFluxCore {
    /// @param sender The address that called PoolManager.swap (usually a router, not the trader).
    /// @param hookData Router-supplied data; FluxPool's router puts the trader address here (unverified).
    /// @return fee Total LP fee for this swap in hundredths of a bip (base fee plus every block's add).
    /// @return allow False rejects the swap. The shell ignores a rejection when the swap sells the launched token.
    function onBeforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (uint24 fee, bool allow);

    /// @notice State update after a swap, e.g. sell-pressure windows. Failures are ignored by the shell.
    function onAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external;
}
