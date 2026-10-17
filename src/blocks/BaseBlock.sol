// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IFluxBlock} from "../core/IFluxBlock.sol";

/// @notice Settings storage shared by the starting blocks. Values are stored per calling core and
/// checked against settingBounds on every write, so a setting can never leave its bounds.
abstract contract BaseBlock is IFluxBlock {
    /// @dev Stored as value + 1 so an unset slot falls back to the default.
    mapping(address core => mapping(bytes32 setting => uint256)) internal _stored;

    event SettingSet(address indexed core, bytes32 indexed setting, uint256 value);

    error UnknownSetting(bytes32 setting);
    error OutOfBounds(bytes32 setting, uint256 value);

    /// @inheritdoc IFluxBlock
    function settingBounds(bytes32 setting) public view virtual returns (uint256 min, uint256 max, bool higherIsSafer);

    /// @dev The value a core gets before it sets one. Must lie within bounds.
    function _defaultOf(bytes32 setting) internal view virtual returns (uint256);

    /// @inheritdoc IFluxBlock
    function setSetting(bytes32 setting, uint256 value) external {
        (uint256 min, uint256 max,) = settingBounds(setting);
        if (value < min || value > max) revert OutOfBounds(setting, value);
        _stored[msg.sender][setting] = value + 1;
        emit SettingSet(msg.sender, setting, value);
    }

    /// @inheritdoc IFluxBlock
    function getSetting(address core, bytes32 setting) public view returns (uint256) {
        uint256 v = _stored[core][setting];
        return v == 0 ? _defaultOf(setting) : v - 1;
    }

    /// @inheritdoc IFluxBlock
    function onBeforeSwap(address, PoolKey calldata, SwapParams calldata) external virtual returns (uint24, bool) {
        return (0, true);
    }

    /// @inheritdoc IFluxBlock
    function onAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta) external virtual {}
}
