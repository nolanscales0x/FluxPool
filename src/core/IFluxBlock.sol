// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice The sandbox every block runs in, whoever wrote it. The core calls blocks as separate
/// contracts with a gas limit and reads back only a fee to add and whether to allow a buy.
/// Blocks never receive funds or liquidity rights, so the worst a hostile block can do is reject
/// buys or push fees to the shell's cap.
///
/// A block is deployed once and shared by every pool. It keys its per-pool state by the calling
/// core (msg.sender), so a caller can only ever touch its own namespace.
interface IFluxBlock {
    /// @notice Called in lane order before a swap.
    /// @param trader The trader as reported by the router in hookData, or the router itself.
    /// Unverified: never rely on it for protection.
    /// @return feeAdd Fee to add, in hundredths of a bip. The shell clamps the total.
    /// @return allow False rejects a buy. Rejections of sells are ignored.
    function onBeforeSwap(address trader, PoolKey calldata key, SwapParams calldata params)
        external
        returns (uint24 feeAdd, bool allow);

    /// @notice Called in lane order after a swap, to update state such as sell-pressure windows.
    function onAfterSwap(address trader, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta) external;

    /// @notice Bounds for a setting. Gates and playbooks use higherIsSafer to classify a change as
    /// tightening (instant) or loosening (mode rules apply).
    function settingBounds(bytes32 setting) external view returns (uint256 min, uint256 max, bool higherIsSafer);

    /// @notice Sets a setting for the calling core. Reverts outside settingBounds.
    function setSetting(bytes32 setting, uint256 value) external;

    /// @notice A core's current value for a setting (the block's default if never set).
    function getSetting(address core, bytes32 setting) external view returns (uint256);
}
