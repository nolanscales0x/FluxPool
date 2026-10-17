// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice The part of the shell the registries read.
interface IFluxShellGovernance {
    /// @dev Same layout as FluxShell.Observation.
    struct Observation {
        uint32 blockNumber;
        uint32 timestamp;
        int24 tick;
    }

    function governanceOf(PoolId id)
        external
        view
        returns (bool live, address creator, uint64 timelockDelay, address core);

    function launchModeOf(PoolId id) external view returns (uint8);

    function creatorFeeBlock() external view returns (address);

    function launchInfo(PoolId id)
        external
        view
        returns (bool tokenIsCurrency0, uint64 launchStart, uint32 launchWindow);

    function observe(PoolId id, uint256 blocksAgo) external view returns (Observation memory);
}
