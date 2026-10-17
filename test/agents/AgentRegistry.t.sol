// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {ChangeRegistry} from "../../src/gates/ChangeRegistry.sol";
import {IChangeQueue} from "../../src/interfaces/IChangeQueue.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";

contract AgentRegistryTest is FluxTestBase {
    address agent = makeAddr("agent");
    address agent2 = makeAddr("agent-2");
    uint64 constant DELAY = 48 hours;

    event AgentSet(PoolId indexed pool, address agent, uint8 level);
    event ChangeQueued(
        PoolId indexed pool,
        uint256 indexed changeId,
        address proposer,
        uint8 kind,
        address target,
        bytes32 setting,
        uint256 oldValue,
        uint256 newValue,
        uint64 executableAt
    );
    event ChangeApplied(PoolId indexed pool, uint256 indexed changeId, bool instant);
    event ChangeCancelled(PoolId indexed pool, uint256 indexed changeId);

    function setUp() public override {
        super.setUp();
        _launch(_none(), _none(), _noSettings());
    }

    function _set(address a, AgentRegistry.Level level) internal returns (uint256) {
        vm.prank(creator);
        return agentRegistry.setAgent(poolId, a, uint8(level));
    }

    function _levelOf() internal view returns (AgentRegistry.Level level) {
        (, level,) = agentRegistry.agentInfo(poolId);
    }

    /// Acts as the playbook registry checking an agent action.
    function _authorize(address caller, AgentRegistry.Level required) internal {
        vm.prank(playbooks);
        agentRegistry.authorize(poolId, caller, required);
    }

    function _authorizeExpectRevert(address caller, AgentRegistry.Level required, bytes4 err) internal {
        vm.prank(playbooks);
        vm.expectRevert(err);
        agentRegistry.authorize(poolId, caller, required);
    }

    // ------------------------------------------------------------------
    // Adding and raising are timelocked
    // ------------------------------------------------------------------

    function test_addingAnAgentWaitsOutTheTimelock() public {
        uint64 executableAt = uint64(block.timestamp) + DELAY;
        vm.expectEmit(true, true, false, true, address(changeRegistry));
        emit ChangeQueued(poolId, 1, creator, uint8(IChangeQueue.Kind.Agent), agent, bytes32(0), 0, 2, executableAt);
        uint256 id = _set(agent, AgentRegistry.Level.ProposeSettings);
        assertEq(id, 1);
        assertEq(agentRegistry.agentOf(poolId), address(0));

        vm.warp(executableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.TooEarly.selector, executableAt));
        changeRegistry.execute(id);

        vm.warp(executableAt);
        vm.expectEmit(true, false, false, true, address(agentRegistry));
        emit AgentSet(poolId, agent, 2);
        vm.expectEmit(true, true, false, true, address(changeRegistry));
        emit ChangeApplied(poolId, id, false);
        vm.prank(makeAddr("anyone")); // anyone can execute
        changeRegistry.execute(id);
        assertEq(agentRegistry.agentOf(poolId), agent);
        assertEq(uint8(_levelOf()), 2);

        vm.expectRevert(ChangeRegistry.NotQueued.selector);
        changeRegistry.execute(id);
    }

    function test_raisingALevelIsTimelocked() public {
        _registerAgent(agent, AgentRegistry.Level.Fire);
        uint256 id = _set(agent, AgentRegistry.Level.ProposeCode);
        assertGt(id, 0);
        assertEq(uint8(_levelOf()), uint8(AgentRegistry.Level.Fire));
        vm.warp(block.timestamp + DELAY);
        changeRegistry.execute(id);
        assertEq(uint8(_levelOf()), uint8(AgentRegistry.Level.ProposeCode));
    }

    function test_replacingTheAgentIsTimelocked() public {
        _registerAgent(agent, AgentRegistry.Level.ProposeCode);
        uint256 id = _set(agent2, AgentRegistry.Level.Fire); // lower level, but a new agent
        assertGt(id, 0);
        assertEq(agentRegistry.agentOf(poolId), agent);
    }

    // ------------------------------------------------------------------
    // Lowering and removing are instant
    // ------------------------------------------------------------------

    function test_loweringALevelIsInstant() public {
        _registerAgent(agent, AgentRegistry.Level.ProposeCode);
        vm.expectEmit(true, false, false, true, address(agentRegistry));
        emit AgentSet(poolId, agent, 1);
        assertEq(_set(agent, AgentRegistry.Level.Fire), 0);
        assertEq(uint8(_levelOf()), 1);
    }

    function test_removeAgentIsAnInstantOffSwitch() public {
        _registerAgent(agent, AgentRegistry.Level.ProposeCode);
        _authorize(agent, AgentRegistry.Level.ProposeCode);

        vm.prank(creator);
        agentRegistry.removeAgent(poolId);
        assertEq(agentRegistry.agentOf(poolId), address(0));
        vm.warp(block.timestamp + 1 hours);
        _authorizeExpectRevert(agent, AgentRegistry.Level.Fire, AgentRegistry.NotAgent.selector);
    }

    function test_settingLevelNoneRemoves() public {
        _registerAgent(agent, AgentRegistry.Level.Fire);
        assertEq(_set(agent, AgentRegistry.Level.None), 0);
        assertEq(agentRegistry.agentOf(poolId), address(0));
    }

    function test_removalVoidsQueuedRaise() public {
        _registerAgent(agent, AgentRegistry.Level.Fire);
        uint256 id = _set(agent, AgentRegistry.Level.ProposeCode);
        vm.prank(creator);
        agentRegistry.removeAgent(poolId);
        vm.warp(block.timestamp + DELAY);
        // A stolen key's pending raise can't bring the agent back after the off switch.
        vm.expectRevert(AgentRegistry.StaleChange.selector);
        changeRegistry.execute(id);
        assertEq(agentRegistry.agentOf(poolId), address(0));
    }

    function test_loweringVoidsQueuedRaise() public {
        _registerAgent(agent, AgentRegistry.Level.ProposeSettings);
        uint256 id = _set(agent, AgentRegistry.Level.ProposeCode);
        _set(agent, AgentRegistry.Level.Fire);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(AgentRegistry.StaleChange.selector);
        changeRegistry.execute(id);
        assertEq(uint8(_levelOf()), uint8(AgentRegistry.Level.Fire));
    }

    // ------------------------------------------------------------------
    // Cancel
    // ------------------------------------------------------------------

    function test_creatorCanCancelQueuedChange() public {
        uint256 id = _set(agent, AgentRegistry.Level.Fire);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ChangeRegistry.NotCreator.selector);
        changeRegistry.cancel(id);

        vm.expectEmit(true, true, false, true, address(changeRegistry));
        emit ChangeCancelled(poolId, id);
        vm.prank(creator);
        changeRegistry.cancel(id);

        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(ChangeRegistry.NotQueued.selector);
        changeRegistry.execute(id);
        assertEq(agentRegistry.agentOf(poolId), address(0));
    }

    // ------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------

    function test_onlyCreatorSetsAgents() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(AgentRegistry.NotCreator.selector);
        agentRegistry.setAgent(poolId, agent, 1);
        vm.expectRevert(AgentRegistry.NotCreator.selector);
        agentRegistry.removeAgent(poolId);
        vm.expectRevert(AgentRegistry.NotCreator.selector);
        agentRegistry.setRateLimits(poolId, 120, 10);
        vm.stopPrank();
    }

    function test_rejectsUnknownPoolsAndLevels() public {
        vm.prank(creator);
        vm.expectRevert(AgentRegistry.PoolNotLive.selector);
        agentRegistry.setAgent(PoolId.wrap(bytes32(uint256(1))), agent, 1);
        vm.prank(creator);
        vm.expectRevert(AgentRegistry.InvalidLevel.selector);
        agentRegistry.setAgent(poolId, agent, 4);
    }

    function test_onlyRegistriesCanAuthorizeOrApply() public {
        vm.expectRevert(AgentRegistry.NotRegistry.selector);
        agentRegistry.authorize(poolId, agent, AgentRegistry.Level.Fire);
        vm.expectRevert(AgentRegistry.NotChangeRegistry.selector);
        agentRegistry.applyQueued(poolId, IChangeQueue.Kind.Agent, abi.encode(agent, uint8(3), uint64(0)));
        vm.expectRevert(ChangeRegistry.NotAuthorizedQueuer.selector);
        changeRegistry.queue(poolId, address(this), IChangeQueue.Kind.Agent, agent, 0, 0, 3, "");
    }

    // ------------------------------------------------------------------
    // Permission levels
    // ------------------------------------------------------------------

    function test_fireAgentCannotPropose() public {
        _registerAgent(agent, AgentRegistry.Level.Fire);
        _authorize(agent, AgentRegistry.Level.Fire);
        vm.warp(block.timestamp + 60);
        _authorizeExpectRevert(agent, AgentRegistry.Level.ProposeSettings, AgentRegistry.LevelTooLow.selector);
        _authorizeExpectRevert(agent, AgentRegistry.Level.ProposeCode, AgentRegistry.LevelTooLow.selector);
    }

    function test_proposeSettingsAgentCannotSubmitBlocks() public {
        _registerAgent(agent, AgentRegistry.Level.ProposeSettings);
        _authorize(agent, AgentRegistry.Level.Fire);
        vm.warp(block.timestamp + 60);
        _authorize(agent, AgentRegistry.Level.ProposeSettings);
        vm.warp(block.timestamp + 60);
        _authorizeExpectRevert(agent, AgentRegistry.Level.ProposeCode, AgentRegistry.LevelTooLow.selector);
    }

    function test_proposeCodeAgentCanDoAllThree() public {
        _registerAgent(agent, AgentRegistry.Level.ProposeCode);
        for (uint8 l = 1; l <= 3; l++) {
            _authorize(agent, AgentRegistry.Level(l));
            vm.warp(block.timestamp + 60);
        }
    }

    function test_nonAgentIsRejected() public {
        _registerAgent(agent, AgentRegistry.Level.ProposeCode);
        _authorizeExpectRevert(agent2, AgentRegistry.Level.Fire, AgentRegistry.NotAgent.selector);
        _authorizeExpectRevert(creator, AgentRegistry.Level.Fire, AgentRegistry.NotAgent.selector);
    }

    // ------------------------------------------------------------------
    // Rate limits
    // ------------------------------------------------------------------

    function test_minimumGapBetweenActions() public {
        _registerAgent(agent, AgentRegistry.Level.Fire);
        _authorize(agent, AgentRegistry.Level.Fire);
        vm.warp(block.timestamp + 59);
        _authorizeExpectRevert(agent, AgentRegistry.Level.Fire, AgentRegistry.TooSoon.selector);
        vm.warp(block.timestamp + 1);
        _authorize(agent, AgentRegistry.Level.Fire);
    }

    function test_dailyMaximum() public {
        _registerAgent(agent, AgentRegistry.Level.Fire);
        vm.prank(creator);
        assertEq(agentRegistry.setRateLimits(poolId, 60, 3), 0); // tighter: instant
        vm.warp((block.timestamp / 1 days + 1) * 1 days); // start of a fresh day
        for (uint256 i; i < 3; i++) {
            _authorize(agent, AgentRegistry.Level.Fire);
            vm.warp(block.timestamp + 60);
        }
        _authorizeExpectRevert(agent, AgentRegistry.Level.Fire, AgentRegistry.DailyLimitReached.selector);
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        _authorize(agent, AgentRegistry.Level.Fire);
    }

    function test_stolenKeyFiringRepeatedlyIsCapped() public {
        _registerAgent(agent, AgentRegistry.Level.Fire);
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        uint256 ok;
        for (uint256 i; i < 200; i++) {
            vm.prank(playbooks);
            try agentRegistry.authorize(poolId, agent, AgentRegistry.Level.Fire) {
                ok++;
            } catch {}
            vm.warp(block.timestamp + 61);
        }
        // 200 attempts a minute apart, within one day: capped at the daily maximum.
        assertEq(ok, agentRegistry.DEFAULT_DAILY_MAX());
    }

    function test_looseningRateLimitsIsTimelocked() public {
        vm.prank(creator);
        uint256 id = agentRegistry.setRateLimits(poolId, 30, 100);
        assertGt(id, 0);
        assertEq(agentRegistry.rateLimitsOf(poolId).minGap, 60);
        vm.warp(block.timestamp + DELAY);
        changeRegistry.execute(id);
        assertEq(agentRegistry.rateLimitsOf(poolId).minGap, 30);
        assertEq(agentRegistry.rateLimitsOf(poolId).dailyMax, 100);
    }

    function test_rateLimitBounds() public {
        vm.startPrank(creator);
        vm.expectRevert(AgentRegistry.InvalidRateLimits.selector);
        agentRegistry.setRateLimits(poolId, 9, 10);
        vm.expectRevert(AgentRegistry.InvalidRateLimits.selector);
        agentRegistry.setRateLimits(poolId, 60, 0);
        vm.expectRevert(AgentRegistry.InvalidRateLimits.selector);
        agentRegistry.setRateLimits(poolId, 60, 201);
        vm.expectRevert(AgentRegistry.InvalidRateLimits.selector);
        agentRegistry.setRateLimits(poolId, 1 days + 1, 10);
        vm.stopPrank();
    }

    function test_newAgentStartsWithFreshUsage() public {
        _registerAgent(agent, AgentRegistry.Level.Fire);
        _authorize(agent, AgentRegistry.Level.Fire);
        _registerAgent(agent2, AgentRegistry.Level.Fire);
        _authorize(agent2, AgentRegistry.Level.Fire);
    }

    // ------------------------------------------------------------------
    // Fuzz: the level only ever goes up through the timelock
    // ------------------------------------------------------------------

    function testFuzz_levelRisesOnlyThroughTimelock(uint8 from, uint8 to, bool sameAgent) public {
        from = uint8(bound(from, 1, 3));
        to = uint8(bound(to, 0, 3));
        _registerAgent(agent, AgentRegistry.Level(from));
        address next = sameAgent ? agent : agent2;
        uint256 id = _set(next, AgentRegistry.Level(to));

        bool instant = to == 0 || (sameAgent && to <= from);
        assertEq(id == 0, instant);
        (address account, AgentRegistry.Level level,) = agentRegistry.agentInfo(poolId);
        if (instant) {
            assertEq(uint8(level), to);
            assertEq(account, to == 0 ? address(0) : agent);
        } else {
            assertEq(account, agent);
            assertEq(uint8(level), from);
        }
    }
}
