// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseBlock} from "./BaseBlock.sol";

/// @title CreatorFee
/// @notice Holds each pool's fee split. Swap fees accrue to the shell's liquidity position, and the
/// shell's permissionless collect() reads these settings (clamping them to its own bounds) to divide
/// fees between the creator, the protocol and the pool's agent. The block needs no lane: it never
/// touches swaps, and the shell, not this block, moves the money.
contract CreatorFee is BaseBlock {
    bytes32 public constant CREATOR_SHARE = "creatorShareBps";
    bytes32 public constant AGENT_SHARE = "agentShareBps";

    function settingBounds(bytes32 setting) public pure override returns (uint256, uint256, bool) {
        // Neither direction protects holders; treating "higher" as riskier sends every increase in
        // what insiders take through the pool's mode rules.
        if (setting == CREATOR_SHARE) return (2_000, 8_000, false);
        if (setting == AGENT_SHARE) return (0, 2_000, false);
        revert UnknownSetting(setting);
    }

    function _defaultOf(bytes32 setting) internal pure override returns (uint256) {
        if (setting == CREATOR_SHARE) return 5_000;
        if (setting == AGENT_SHARE) return 0;
        revert UnknownSetting(setting);
    }
}
