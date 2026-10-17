// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PlaybookRegistry} from "../../src/playbooks/PlaybookRegistry.sol";
import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";

abstract contract PlaybookRegistryTestBase is FluxTestBase {
    address agent = makeAddr("agent");
    bytes32 THRESHOLD;
    bytes32 MAX_FEE;

    event PlaybookAdded(PoolId indexed pool, uint256 indexed playbookId);
    event PlaybookFired(PoolId indexed pool, uint256 indexed playbookId, address firedBy);
    event PlaybookExpired(PoolId indexed pool, uint256 indexed playbookId);

    function setUp() public override {
        super.setUp();
        THRESHOLD = adaptiveFee.THRESHOLD(); // lower is safer; default 20_000
        MAX_FEE = adaptiveFee.MAX_FEE(); // higher is safer; default 30_000
        address[] memory before = new address[](2);
        before[0] = address(antiSnipe);
        before[1] = address(adaptiveFee);
        _launch(before, _one(address(adaptiveFee)), _noSettings());
        _skipWindow();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _actions(uint256 threshold, uint256 maxFee) internal view returns (PlaybookRegistry.Action[] memory a) {
        a = new PlaybookRegistry.Action[](2);
        a[0] = PlaybookRegistry.Action(address(adaptiveFee), THRESHOLD, threshold);
        a[1] = PlaybookRegistry.Action(address(adaptiveFee), MAX_FEE, maxFee);
    }

    function _noTrigger() internal pure returns (PlaybookRegistry.Trigger memory t) {}

    function _add(PlaybookRegistry.Action[] memory a, uint16 firesPerDay, PlaybookRegistry.Trigger memory t)
        internal
        returns (uint256)
    {
        vm.prank(creator);
        return playbookRegistry.addPlaybook(poolId, a, 10 minutes, firesPerDay, t);
    }

    function _addDefault() internal returns (uint256) {
        return _add(_actions(10_000, 50_000), 4, _noTrigger());
    }

    function _get(bytes32 setting) internal view returns (uint256) {
        return adaptiveFee.getSetting(address(core), setting);
    }

    function _fireAsCreator(uint256 id) internal {
        vm.prank(creator);
        playbookRegistry.fire(id);
    }

    // ------------------------------------------------------------------
    // Approval
    // ------------------------------------------------------------------

    function test_addEmitsAndStores() public {
        vm.expectEmit(true, true, false, false, address(playbookRegistry));
        emit PlaybookAdded(poolId, 1);
        uint256 id = _addDefault();
        assertEq(id, 1);
        (PoolId pool,, bool removed, uint32 cooldown, uint16 fires,, PlaybookRegistry.Action[] memory a) =
            playbookRegistry.playbookOf(id);
        assertEq(PoolId.unwrap(pool), PoolId.unwrap(poolId));
        assertFalse(removed);
        assertEq(cooldown, 10 minutes);
        assertEq(fires, 4);
        assertEq(a.length, 2);
    }

    function test_rejectsLooseningAction() public {
        PlaybookRegistry.Action[] memory a = _actions(30_000, 50_000); // raising the threshold loosens
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PlaybookRegistry.LooseningAction.selector, 0));
        playbookRegistry.addPlaybook(poolId, a, 10 minutes, 4, _noTrigger());

        a = _actions(10_000, 10_000); // lowering the max fee loosens
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PlaybookRegistry.LooseningAction.selector, 1));
        playbookRegistry.addPlaybook(poolId, a, 10 minutes, 4, _noTrigger());
    }

    function test_rejectsOutOfBoundsAndUnknownSettings() public {
        PlaybookRegistry.Action[] memory a = _actions(1_000, 50_000); // threshold min is 5_000
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PlaybookRegistry.OutOfBounds.selector, 0));
        playbookRegistry.addPlaybook(poolId, a, 10 minutes, 4, _noTrigger());

        a = _actions(10_000, 50_000);
        a[1].setting = "nope";
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PlaybookRegistry.OutOfBounds.selector, 1));
        playbookRegistry.addPlaybook(poolId, a, 10 minutes, 4, _noTrigger());
    }

    function test_rejectsInvalidParameters() public {
        PlaybookRegistry.Action[] memory a = _actions(10_000, 50_000);
        PlaybookRegistry.Trigger memory badTrigger = PlaybookRegistry.Trigger(60, 10, 100); // span > 63
        vm.startPrank(creator);
        vm.expectRevert(PlaybookRegistry.InvalidPlaybook.selector);
        playbookRegistry.addPlaybook(poolId, a, 1 minutes, 4, _noTrigger());
        vm.expectRevert(PlaybookRegistry.InvalidPlaybook.selector);
        playbookRegistry.addPlaybook(poolId, a, 10 minutes, 0, _noTrigger());
        vm.expectRevert(PlaybookRegistry.InvalidPlaybook.selector);
        playbookRegistry.addPlaybook(poolId, new PlaybookRegistry.Action[](0), 10 minutes, 4, _noTrigger());
        vm.expectRevert(PlaybookRegistry.InvalidPlaybook.selector);
        playbookRegistry.addPlaybook(poolId, a, 10 minutes, 4, badTrigger);
        vm.stopPrank();
    }

    function test_onlyCreatorAddsAndRemoves() public {
        PlaybookRegistry.Action[] memory a = _actions(10_000, 50_000);
        vm.prank(agent);
        vm.expectRevert(PlaybookRegistry.NotCreator.selector);
        playbookRegistry.addPlaybook(poolId, a, 10 minutes, 4, _noTrigger());

        uint256 id = _addDefault();
        vm.prank(agent);
        vm.expectRevert(PlaybookRegistry.NotCreator.selector);
        playbookRegistry.removePlaybook(id);
    }

    // ------------------------------------------------------------------
    // Firing
    // ------------------------------------------------------------------

    function test_firingIsInstant() public {
        uint256 id = _addDefault();
        vm.expectEmit(true, true, false, true, address(playbookRegistry));
        emit PlaybookFired(poolId, id, creator);
        _fireAsCreator(id);
        assertEq(_get(THRESHOLD), 10_000);
        assertEq(_get(MAX_FEE), 50_000);
    }

    function test_agentCanFireAndNonAgentCannot() public {
        uint256 id = _addDefault();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AgentRegistry.NotAgent.selector);
        playbookRegistry.fire(id);

        _registerAgent(agent, AgentRegistry.Level.Fire);
        vm.prank(agent);
        playbookRegistry.fire(id);
        assertEq(_get(MAX_FEE), 50_000);
    }

    function test_cannotFireWhileActive() public {
        uint256 id = _addDefault();
        _fireAsCreator(id);
        vm.prank(creator);
        vm.expectRevert(PlaybookRegistry.AlreadyActive.selector);
        playbookRegistry.fire(id);
    }

    function test_agentRateLimitsHold() public {
        uint256 a = _addDefault();
        PlaybookRegistry.Action[] memory other = new PlaybookRegistry.Action[](1);
        other[0] = PlaybookRegistry.Action(address(antiSnipe), antiSnipe.MAX_BUYS_PER_BLOCK(), 1);
        uint256 b = _add(other, 4, _noTrigger());
        _registerAgent(agent, AgentRegistry.Level.Fire);

        vm.prank(agent);
        playbookRegistry.fire(a);
        vm.prank(agent);
        vm.expectRevert(AgentRegistry.TooSoon.selector);
        playbookRegistry.fire(b);
        vm.warp(block.timestamp + 60);
        vm.prank(agent);
        playbookRegistry.fire(b);
    }

    function test_dailyFireLimit() public {
        uint256 id = _add(_actions(10_000, 50_000), 2, _noTrigger());
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        for (uint256 i; i < 2; i++) {
            _fireAsCreator(id);
            vm.warp(block.timestamp + 10 minutes);
            playbookRegistry.expire(id);
        }
        vm.prank(creator);
        vm.expectRevert(PlaybookRegistry.DailyFireLimit.selector);
        playbookRegistry.fire(id);
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        _fireAsCreator(id);
    }

    function test_fireSkipsActionsThatNoLongerTighten() public {
        uint256 id = _addDefault();
        core.setBlockSetting(address(adaptiveFee), THRESHOLD, 5_000); // already tighter than the playbook
        _fireAsCreator(id);
        assertEq(_get(THRESHOLD), 5_000);
        assertEq(_get(MAX_FEE), 50_000);

        vm.warp(block.timestamp + 10 minutes);
        playbookRegistry.expire(id);
        assertEq(_get(THRESHOLD), 5_000); // untouched: the playbook never changed it
        assertEq(_get(MAX_FEE), 30_000);
    }

    function test_fireWithNothingToTightenReverts() public {
        uint256 id = _addDefault();
        core.setBlockSetting(address(adaptiveFee), THRESHOLD, 5_000);
        core.setBlockSetting(address(adaptiveFee), MAX_FEE, 50_000);
        vm.prank(creator);
        vm.expectRevert(PlaybookRegistry.NothingToTighten.selector);
        playbookRegistry.fire(id);
    }

    // ------------------------------------------------------------------
    // Expire
    // ------------------------------------------------------------------

    function test_expireRestoresPreviousValues() public {
        uint256 id = _addDefault();
        _fireAsCreator(id);
        uint64 until = uint64(block.timestamp + 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(PlaybookRegistry.CooldownNotOver.selector, until));
        playbookRegistry.expire(id);

        vm.warp(until);
        vm.expectEmit(true, true, false, false, address(playbookRegistry));
        emit PlaybookExpired(poolId, id);
        vm.prank(makeAddr("anyone"));
        playbookRegistry.expire(id);
        assertEq(_get(THRESHOLD), 20_000);
        assertEq(_get(MAX_FEE), 30_000);

        vm.expectRevert(PlaybookRegistry.NotActive.selector);
        playbookRegistry.expire(id);
    }

    function test_expireLeavesSettingsOthersChanged() public {
        uint256 id = _addDefault();
        _fireAsCreator(id);
        core.setBlockSetting(address(adaptiveFee), THRESHOLD, 8_000); // changed elsewhere meanwhile
        vm.warp(block.timestamp + 10 minutes);
        playbookRegistry.expire(id);
        assertEq(_get(THRESHOLD), 8_000);
        assertEq(_get(MAX_FEE), 30_000);
    }

    function test_overlappingPlaybooksNeverEndLooser() public {
        uint256 a = _add(_actions(15_000, 40_000), 4, _noTrigger());
        uint256 b = _add(_actions(10_000, 50_000), 4, _noTrigger());
        _fireAsCreator(a);
        _fireAsCreator(b);
        vm.warp(block.timestamp + 10 minutes);
        playbookRegistry.expire(a); // b changed both since: left alone
        playbookRegistry.expire(b); // restores to a's values
        assertLe(_get(THRESHOLD), 20_000);
        assertGe(_get(MAX_FEE), 30_000);
    }

    function test_removeOnlyWhenNotActive() public {
        uint256 id = _addDefault();
        _fireAsCreator(id);
        vm.prank(creator);
        vm.expectRevert(PlaybookRegistry.AlreadyActive.selector);
        playbookRegistry.removePlaybook(id);

        vm.warp(block.timestamp + 10 minutes);
        playbookRegistry.expire(id);
        vm.prank(creator);
        playbookRegistry.removePlaybook(id);
        vm.prank(creator);
        vm.expectRevert(PlaybookRegistry.UnknownPlaybook.selector);
        playbookRegistry.fire(id);
    }

    // ------------------------------------------------------------------
    // On-chain trigger check
    // ------------------------------------------------------------------

    /// One swap per block so the shell records a start-of-block price for each.
    function _sellEachBlock(uint256 tokens, uint256 blocks) internal {
        for (uint256 i; i < blocks; i++) {
            vm.roll(block.number + 1);
            _sell(tokens);
        }
    }

    function _addTriggered() internal returns (uint256) {
        // ~2% drop (200 ticks) sustained: measured from 8 blocks back, still down 3 blocks back and now.
        return _add(_actions(10_000, 50_000), 4, PlaybookRegistry.Trigger(5, 3, 200));
    }

    function test_triggerBlocksFireWithoutADrop() public {
        uint256 id = _addTriggered();
        _sellEachBlock(0.001 ether, 12); // tiny sells: price barely moves
        assertFalse(playbookRegistry.triggerMet(id));
        vm.prank(creator);
        vm.expectRevert(PlaybookRegistry.TriggerNotMet.selector);
        playbookRegistry.fire(id);
    }

    function test_triggerAllowsFireOnSustainedDrop() public {
        uint256 id = _addTriggered();
        _sellEachBlock(0.001 ether, 4); // history before the dump
        _sellEachBlock(2 ether, 10); // sustained selling
        vm.roll(block.number + 1);
        _sell(0.001 ether); // record this block's start price
        assertTrue(playbookRegistry.triggerMet(id));
        _fireAsCreator(id);
    }

    function test_triggerResistsAFakeDump() public {
        uint256 id = _addTriggered();
        _sellEachBlock(0.001 ether, 10);
        // One big dump in a single block, bought back inside the same block: start-of-block prices
        // never see it.
        vm.roll(block.number + 1);
        _sell(10 ether);
        _buy(9 ether);
        vm.roll(block.number + 1);
        _sell(0.001 ether);
        assertFalse(playbookRegistry.triggerMet(id));

        // A dump that stays down for one block only still fails the hold requirement.
        vm.roll(block.number + 1);
        _sell(10 ether);
        vm.roll(block.number + 1);
        _sell(0.001 ether);
        assertFalse(playbookRegistry.triggerMet(id));
        vm.prank(creator);
        vm.expectRevert(PlaybookRegistry.TriggerNotMet.selector);
        playbookRegistry.fire(id);
    }

    function test_triggerFailsWithoutEnoughHistory() public {
        uint256 id = _addTriggered();
        assertFalse(playbookRegistry.triggerMet(id));
    }

    // ------------------------------------------------------------------
    // Fuzz: approval accepts exactly the tightening actions, and fire + expire round-trips
    // ------------------------------------------------------------------

    function testFuzz_onlyTighteningIsApprovedAndExpireRestores(uint256 threshold, uint256 maxFee) public {
        threshold = bound(threshold, 5_000, 200_000);
        maxFee = bound(maxFee, 0, 50_000);
        bool tightening = threshold <= 20_000 && maxFee >= 30_000;
        PlaybookRegistry.Action[] memory a = _actions(threshold, maxFee);
        vm.prank(creator);
        try playbookRegistry.addPlaybook(poolId, a, 10 minutes, 4, _noTrigger()) returns (uint256 id) {
            assertTrue(tightening);
            bool changes = threshold < 20_000 || maxFee > 30_000;
            vm.prank(creator);
            try playbookRegistry.fire(id) {
                assertTrue(changes);
                vm.warp(block.timestamp + 10 minutes);
                playbookRegistry.expire(id);
            } catch {
                assertFalse(changes);
            }
            assertEq(_get(THRESHOLD), 20_000);
            assertEq(_get(MAX_FEE), 30_000);
        } catch {
            assertFalse(tightening);
        }
    }
}

/// @dev Native ETH quote, as on Ethereum (token = currency1).
contract PlaybookRegistryTest is PlaybookRegistryTestBase {}

/// @dev WETH quote, the token sorting below it (token = currency0).
contract PlaybookRegistryTokenFirstTest is PlaybookRegistryTestBase {
    function _tokenFirst() internal pure override returns (bool) {
        return true;
    }
}
