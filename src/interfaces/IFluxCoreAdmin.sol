// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The core functions the immutable layer calls. Lanes: 0 before swap, 1 after swap.
interface IFluxCoreAdmin {
    function setBlockSetting(address blockAddr, bytes32 setting, uint256 value) external;
    function setLane(uint8 lane, address[] calldata blocks) external;
    function blocksIn(uint8 lane) external view returns (address[] memory);
}
