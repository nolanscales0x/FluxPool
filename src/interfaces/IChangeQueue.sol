// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice The ChangeRegistry's queue, as other immutable-layer contracts use it.
interface IChangeQueue {
    /// @notice Change kinds. The numeric values are the `kind` field of the shared ChangeQueued
    /// event, so they are part of the interface the backend reads: never renumber.
    enum Kind {
        Setting, // 0: block setting
        Lane, // 1: new block or lane change
        Agent, // 2: add, replace or raise an agent
        Mode, // 3: freedom mode
        AgentRateLimit // 4: loosen an agent's rate limits
    }

    /// @notice Queues a change behind the pool's timelock. Callable only by trusted registries.
    function queue(
        PoolId id,
        address proposer,
        Kind kind,
        address target,
        bytes32 setting,
        uint256 oldValue,
        uint256 newValue,
        bytes calldata payload
    ) external returns (uint256 changeId);
}

/// @notice Implemented by registries whose queued changes the ChangeRegistry executes.
interface IQueuedChangeTarget {
    function applyQueued(PoolId id, IChangeQueue.Kind kind, bytes calldata payload) external;
}
