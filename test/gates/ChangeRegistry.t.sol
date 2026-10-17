// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ChangeRegistry} from "../../src/gates/ChangeRegistry.sol";
import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {PlaybookRegistry} from "../../src/playbooks/PlaybookRegistry.sol";
import {FluxCore} from "../../src/core/FluxCore.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";
import {HostileBlock, LightFeeBlock} from "../mocks/TestBlocks.sol";

contract ChangeRegistryTest is FluxTestBase {
    uint8 constant GUARDED = 0;
    uint8 constant FAST = 1;
    uint8 constant WILD = 2;
    uint64 constant DELAY = 48 hours;

    address agent = makeAddr("agent");
    address attester = makeAddr("attester");
    bytes32 THRESHOLD;
    bytes32 MAX_FEE;
    LightFeeBlock newBlock;

    event ChangeApplied(PoolId indexed pool, uint256 indexed changeId, bool instant);
    event CheckRecorded(PoolId indexed pool, uint256 indexed changeId, bytes32 check, address attester, bool passed);
    event ModeChanged(PoolId indexed pool, uint8 oldMode, uint8 newMode);
    event BlockAdded(PoolId indexed pool, uint8 lane, address blockAddr, address author);

    function _coreGate() internal view override returns (address) {
        return address(changeRegistry);
    }

    function setUp() public override {
        super.setUp();
        THRESHOLD = adaptiveFee.THRESHOLD(); // lower is safer; default 20_000
        MAX_FEE = adaptiveFee.MAX_FEE(); // higher is safer; default 30_000
        newBlock = new LightFeeBlock(500);
        vm.prank(attesterManager);
        changeRegistry.setAttester(attester, true);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _launchIn(uint8 mode) internal {
        launchMode = mode;
        address[] memory before = new address[](2);
        before[0] = address(antiSnipe);
        before[1] = address(adaptiveFee);
        _launch(before, _one(address(adaptiveFee)), _noSettings());
        _skipWindow();
    }

    function _get(bytes32 setting) internal view returns (uint256) {
        return adaptiveFee.getSetting(address(core), setting);
    }

    function _status(uint256 id) internal view returns (ChangeRegistry.Status status) {
        (,, status,,,,,) = changeRegistry.changeOf(id);
    }

    function _proposeSetting(bytes32 setting, uint256 value) internal returns (uint256) {
        vm.prank(creator);
        return changeRegistry.proposeSetting(poolId, address(adaptiveFee), setting, value);
    }

    function _proposeNewBlock() internal returns (uint256) {
        vm.prank(creator);
        return changeRegistry.proposeBlock(poolId, 0, 2, address(newBlock), new bytes32[](0));
    }

    function _passAllChecks(uint256 id) internal {
        bytes32[] memory req = changeRegistry.requiredChecksOf(id);
        for (uint256 i; i < req.length; i++) {
            vm.prank(attester);
            changeRegistry.recordCheck(id, req[i], true);
        }
    }

    function _beforeLane() internal view returns (address[] memory) {
        return core.blocksIn(FluxCore.Lane.BeforeSwap);
    }

    // ------------------------------------------------------------------
    // Row: safer setting — instant in every mode
    // ------------------------------------------------------------------

    function test_saferSettingIsInstantInEveryMode() public {
        for (uint8 m; m <= WILD; m++) {
            _launchIn(m);
            vm.expectEmit(true, false, false, true, address(changeRegistry));
            emit ChangeApplied(poolId, changeRegistry.nextChangeId(), true);
            _proposeSetting(THRESHOLD, 10_000);
            assertEq(_get(THRESHOLD), 10_000, "mode");
        }
    }

    function test_playbookFireIsInstantInEveryMode() public {
        PlaybookRegistry.Action[] memory a = new PlaybookRegistry.Action[](1);
        a[0] = PlaybookRegistry.Action(address(adaptiveFee), MAX_FEE, 50_000);
        for (uint8 m; m <= WILD; m++) {
            _launchIn(m);
            vm.startPrank(creator);
            uint256 pb = playbookRegistry.addPlaybook(poolId, a, 10 minutes, 4, PlaybookRegistry.Trigger(0, 0, 0));
            playbookRegistry.fire(pb);
            vm.stopPrank();
            assertEq(_get(MAX_FEE), 50_000);
        }
    }

    // ------------------------------------------------------------------
    // Row: riskier setting within bounds — timelock in Guarded, instant in Fast and Wild
    // ------------------------------------------------------------------

    function test_riskierSettingIsTimelockedInGuarded() public {
        _launchIn(GUARDED);
        uint256 id = _proposeSetting(THRESHOLD, 40_000);
        assertEq(_get(THRESHOLD), 20_000);
        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.TooEarly.selector, uint64(block.timestamp + DELAY)));
        changeRegistry.execute(id);
        vm.warp(block.timestamp + DELAY);
        changeRegistry.execute(id);
        assertEq(_get(THRESHOLD), 40_000);
    }

    function test_riskierSettingIsInstantInFastAndWild() public {
        for (uint8 m = FAST; m <= WILD; m++) {
            _launchIn(m);
            _proposeSetting(THRESHOLD, 40_000);
            assertEq(_get(THRESHOLD), 40_000);
        }
    }

    // ------------------------------------------------------------------
    // Row: out of bounds — rejected in every mode
    // ------------------------------------------------------------------

    function test_outOfBoundsIsRejectedInEveryMode() public {
        for (uint8 m; m <= WILD; m++) {
            _launchIn(m);
            vm.prank(creator);
            vm.expectRevert(ChangeRegistry.OutOfBounds.selector);
            changeRegistry.proposeSetting(poolId, address(adaptiveFee), THRESHOLD, 200_001);
            vm.prank(creator);
            vm.expectRevert(ChangeRegistry.OutOfBounds.selector);
            changeRegistry.proposeSetting(poolId, address(adaptiveFee), "nope", 1);
        }
    }

    // ------------------------------------------------------------------
    // Row: new block or lane change
    // ------------------------------------------------------------------

    function test_newBlockInGuardedNeedsChecksAndTimelock() public {
        _launchIn(GUARDED);
        uint256 id = _proposeNewBlock();
        assertEq(changeRegistry.requiredChecksOf(id).length, 4);

        vm.warp(block.timestamp + DELAY); // delay alone isn't enough
        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.ChecksMissing.selector, bytes32("compiled")));
        changeRegistry.execute(id);

        _passAllChecks(id);
        vm.expectEmit(true, false, false, true, address(changeRegistry));
        emit BlockAdded(poolId, 0, address(newBlock), creator);
        changeRegistry.execute(id);
        assertEq(_beforeLane()[2], address(newBlock));
    }

    function test_newBlockInGuardedWithChecksStillWaits() public {
        _launchIn(GUARDED);
        uint256 id = _proposeNewBlock();
        _passAllChecks(id);
        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.TooEarly.selector, uint64(block.timestamp + DELAY)));
        changeRegistry.execute(id);
    }

    function test_newBlockInFastNeedsChecksButNoTimelock() public {
        _launchIn(FAST);
        uint256 id = _proposeNewBlock();
        assertEq(_beforeLane().length, 2);
        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.ChecksMissing.selector, bytes32("compiled")));
        changeRegistry.execute(id);
        _passAllChecks(id);
        changeRegistry.execute(id); // same block: no timelock
        assertEq(_beforeLane().length, 3);
    }

    function test_newBlockInWildIsInstant() public {
        _launchIn(WILD);
        _proposeNewBlock();
        assertEq(_beforeLane()[2], address(newBlock));
    }

    function test_failedCheckMeansNeverActivates() public {
        _launchIn(FAST);
        // A passed check can still be downgraded to failed (e.g. a re-run finds a problem)...
        uint256 first = _proposeNewBlock();
        _passAllChecks(first);
        vm.prank(attester);
        changeRegistry.recordCheck(first, "simulated", false);
        vm.expectRevert(ChangeRegistry.CheckFailed.selector);
        changeRegistry.execute(first);

        // ...but a failure is final.
        uint256 id = _proposeNewBlock();
        vm.prank(attester);
        changeRegistry.recordCheck(id, "simulated", false);
        vm.prank(attester);
        vm.expectRevert(ChangeRegistry.CheckAlreadyFailed.selector);
        changeRegistry.recordCheck(id, "simulated", true);
        _passAllChecksExcept(id, "simulated");
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(ChangeRegistry.CheckFailed.selector);
        changeRegistry.execute(id);
    }

    /// Found by the Fast invariant suite: a failed check that the pool doesn't require must still
    /// stop activation.
    function test_failedOptionalCheckAlsoBlocks() public {
        _launchIn(FAST);
        uint256 id = _proposeNewBlock();
        vm.prank(attester);
        changeRegistry.recordCheck(id, "programmableVerified", false); // not required for this pool
        _passAllChecks(id);
        vm.expectRevert(ChangeRegistry.CheckFailed.selector);
        changeRegistry.execute(id);
    }

    function _passAllChecksExcept(uint256 id, bytes32 skip) internal {
        bytes32[] memory req = changeRegistry.requiredChecksOf(id);
        for (uint256 i; i < req.length; i++) {
            if (req[i] == skip) continue;
            vm.prank(attester);
            changeRegistry.recordCheck(id, req[i], true);
        }
    }

    function test_reorderingWithoutNewCodeNeedsNoChecks() public {
        address[] memory swapped = new address[](2);
        swapped[0] = address(adaptiveFee);
        swapped[1] = address(antiSnipe);

        _launchIn(GUARDED);
        vm.prank(creator);
        uint256 id = changeRegistry.proposeLaneChange(poolId, 0, swapped, new bytes32[](0));
        assertEq(changeRegistry.requiredChecksOf(id).length, 0);
        vm.warp(block.timestamp + DELAY);
        changeRegistry.execute(id);
        assertEq(_beforeLane()[0], address(adaptiveFee));

        for (uint8 m = FAST; m <= WILD; m++) {
            _launchIn(m);
            vm.prank(creator);
            changeRegistry.proposeLaneChange(poolId, 0, swapped, new bytes32[](0));
            assertEq(_beforeLane()[0], address(adaptiveFee)); // instant
        }
    }

    function test_programmableCheckWhenPoolRequiresIt() public {
        _launchIn(FAST);
        vm.prank(creator);
        changeRegistry.setRequireProgrammable(poolId);
        uint256 id = _proposeNewBlock();
        bytes32[] memory req = changeRegistry.requiredChecksOf(id);
        assertEq(req.length, 5);
        assertEq(req[4], bytes32("programmableVerified"));
    }

    function test_extraChecksAreAddedOnceAndValidated() public {
        _launchIn(FAST);
        bytes32[] memory extra = new bytes32[](2);
        extra[0] = "programmableVerified";
        extra[1] = "compiled"; // already required
        vm.prank(creator);
        uint256 id = changeRegistry.proposeBlock(poolId, 0, 0, address(newBlock), extra);
        assertEq(changeRegistry.requiredChecksOf(id).length, 5);

        extra[1] = "vibes";
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.UnknownCheck.selector, bytes32("vibes")));
        changeRegistry.proposeBlock(poolId, 0, 0, address(newBlock), extra);
    }

    function test_rejectsInvalidLanes() public {
        _launchIn(WILD);
        address[] memory dup = new address[](2);
        dup[0] = address(antiSnipe);
        dup[1] = address(antiSnipe);
        vm.startPrank(creator);
        vm.expectRevert(ChangeRegistry.InvalidLane.selector);
        changeRegistry.proposeLaneChange(poolId, 0, dup, new bytes32[](0));
        vm.expectRevert(ChangeRegistry.InvalidLane.selector);
        changeRegistry.proposeLaneChange(poolId, 2, new address[](0), new bytes32[](0));
        vm.expectRevert(ChangeRegistry.InvalidLane.selector);
        changeRegistry.proposeBlock(poolId, 0, 3, address(newBlock), new bytes32[](0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Row: raising an agent's level — timelocked in every mode
    // ------------------------------------------------------------------

    function test_raisingAgentLevelIsTimelockedInEveryMode() public {
        for (uint8 m; m <= WILD; m++) {
            _launchIn(m);
            vm.prank(creator);
            uint256 id = agentRegistry.setAgent(poolId, agent, uint8(AgentRegistry.Level.Fire));
            assertGt(id, 0);
            assertEq(agentRegistry.agentOf(poolId), address(0));
            vm.expectRevert();
            changeRegistry.execute(id);
            vm.warp(block.timestamp + DELAY);
            changeRegistry.execute(id);
            assertEq(agentRegistry.agentOf(poolId), agent);
        }
    }

    // ------------------------------------------------------------------
    // Rows: switching modes
    // ------------------------------------------------------------------

    function test_switchingToAFreerModeIsTimelocked() public {
        uint8[2][3] memory moves = [[GUARDED, FAST], [GUARDED, WILD], [FAST, WILD]];
        for (uint256 i; i < 3; i++) {
            _launchIn(moves[i][0]);
            vm.prank(creator);
            uint256 id = changeRegistry.setMode(poolId, moves[i][1]);
            assertGt(id, 0);
            assertEq(uint8(changeRegistry.modeOf(poolId)), moves[i][0]);
            vm.warp(block.timestamp + DELAY - 1);
            vm.expectRevert();
            changeRegistry.execute(id);
            vm.warp(block.timestamp + 1);
            vm.expectEmit(true, false, false, true, address(changeRegistry));
            emit ModeChanged(poolId, moves[i][0], moves[i][1]);
            changeRegistry.execute(id);
            assertEq(uint8(changeRegistry.modeOf(poolId)), moves[i][1]);
        }
    }

    function test_switchingToASaferModeIsInstant() public {
        uint8[2][3] memory moves = [[FAST, GUARDED], [WILD, GUARDED], [WILD, FAST]];
        for (uint256 i; i < 3; i++) {
            _launchIn(moves[i][0]);
            vm.prank(creator);
            assertEq(changeRegistry.setMode(poolId, moves[i][1]), 0);
            assertEq(uint8(changeRegistry.modeOf(poolId)), moves[i][1]);
        }
    }

    function test_quietSwitchToWildIsVisibleAndCancellable() public {
        _launchIn(GUARDED);
        vm.recordLogs();
        vm.prank(creator);
        uint256 id = changeRegistry.setMode(poolId, WILD);
        assertEq(vm.getRecordedLogs().length, 1); // ChangeQueued fires at once for the alerts worker
        vm.prank(creator);
        changeRegistry.cancel(id);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(ChangeRegistry.NotQueued.selector);
        changeRegistry.execute(id);
        assertEq(uint8(changeRegistry.modeOf(poolId)), GUARDED);
    }

    function test_saferModeSlowsDownWhatIsAlreadyQueued() public {
        _launchIn(FAST);
        uint256 id = _proposeNewBlock();
        vm.prank(creator);
        changeRegistry.setMode(poolId, GUARDED);
        _passAllChecks(id);
        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.TooEarly.selector, uint64(block.timestamp + DELAY)));
        changeRegistry.execute(id);
        vm.warp(block.timestamp + DELAY);
        changeRegistry.execute(id);
    }

    function test_cannotSwitchToSameOrUnknownMode() public {
        _launchIn(FAST);
        vm.startPrank(creator);
        vm.expectRevert(ChangeRegistry.SameMode.selector);
        changeRegistry.setMode(poolId, FAST);
        vm.expectRevert(ChangeRegistry.UnsupportedKind.selector);
        changeRegistry.setMode(poolId, 3);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Agents through the gates
    // ------------------------------------------------------------------

    function test_agentProposalsFollowItsLevel() public {
        _launchIn(FAST);
        _registerAgent(agent, AgentRegistry.Level.ProposeSettings);
        vm.prank(agent);
        changeRegistry.proposeSetting(poolId, address(adaptiveFee), THRESHOLD, 30_000);
        assertEq(_get(THRESHOLD), 30_000);

        vm.warp(block.timestamp + 60);
        vm.prank(agent);
        vm.expectRevert(AgentRegistry.LevelTooLow.selector);
        changeRegistry.proposeBlock(poolId, 0, 0, address(newBlock), new bytes32[](0));
    }

    function test_proposeCodeAgentCanSubmitBlocks() public {
        _launchIn(WILD);
        _registerAgent(agent, AgentRegistry.Level.ProposeCode);
        vm.expectEmit(true, false, false, true, address(changeRegistry));
        emit BlockAdded(poolId, 0, address(newBlock), agent);
        vm.prank(agent);
        changeRegistry.proposeBlock(poolId, 0, 0, address(newBlock), new bytes32[](0));
    }

    function test_agentCannotTouchTheFeeSplitOrTheMode() public {
        _launchIn(WILD);
        _registerAgent(agent, AgentRegistry.Level.ProposeCode);
        bytes32 agentShare = creatorFee.AGENT_SHARE();
        vm.prank(agent);
        vm.expectRevert(ChangeRegistry.CreatorOnly.selector);
        changeRegistry.proposeSetting(poolId, address(creatorFee), agentShare, 2_000);
        vm.prank(agent);
        vm.expectRevert(ChangeRegistry.NotCreator.selector);
        changeRegistry.setMode(poolId, GUARDED);
    }

    function test_stolenKeyLooseningInGuardedIsQueuedAndCancellable() public {
        _launchIn(GUARDED);
        _registerAgent(agent, AgentRegistry.Level.ProposeSettings);
        vm.prank(agent);
        uint256 id = changeRegistry.proposeSetting(poolId, address(adaptiveFee), MAX_FEE, 0);
        assertEq(_get(MAX_FEE), 30_000);
        vm.prank(creator);
        agentRegistry.removeAgent(poolId);
        vm.prank(creator);
        changeRegistry.cancel(id);
        assertEq(uint8(_status(id)), uint8(ChangeRegistry.Status.Cancelled));
    }

    function test_strangerCannotPropose() public {
        _launchIn(WILD);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AgentRegistry.NotAgent.selector);
        changeRegistry.proposeSetting(poolId, address(adaptiveFee), THRESHOLD, 10_000);
    }

    // ------------------------------------------------------------------
    // Attesters
    // ------------------------------------------------------------------

    function test_onlyAttestersRecordAndOnlyManagerSetsThem() public {
        _launchIn(FAST);
        uint256 id = _proposeNewBlock();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ChangeRegistry.NotAttester.selector);
        changeRegistry.recordCheck(id, "compiled", true);

        vm.prank(creator);
        vm.expectRevert(ChangeRegistry.NotAttesterManager.selector);
        changeRegistry.setAttester(creator, true);

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.UnknownCheck.selector, bytes32("vibes")));
        changeRegistry.recordCheck(id, "vibes", true);

        vm.expectEmit(true, true, false, true, address(changeRegistry));
        emit CheckRecorded(poolId, id, "compiled", attester, true);
        vm.prank(attester);
        changeRegistry.recordCheck(id, "compiled", true);
    }

    // ------------------------------------------------------------------
    // Wild pool with a hostile block: shell protections still hold
    // ------------------------------------------------------------------

    function test_wildPoolWithHostileBlockKeepsProtections() public {
        _launchIn(WILD);
        HostileBlock hostile = new HostileBlock(manager);
        hostile.set(HostileBlock.Mode.MaxFee, address(0));
        _registerAgent(agent, AgentRegistry.Level.ProposeCode);
        vm.prank(agent);
        changeRegistry.proposeBlock(poolId, 0, 0, address(hostile), new bytes32[](0));

        assertEq(_feeOf(false, 0.1 ether), FEE_CAP); // clamped, sell goes through
        hostile.set(HostileBlock.Mode.RejectAll, address(0));
        assertTrue(_buyReverts(0.1 ether));
        _sell(0.1 ether);
        hostile.set(HostileBlock.Mode.TakeFunds, address(0));
        _sell(0.1 ether);

        // Removable at once in Wild.
        address[] memory clean = new address[](2);
        clean[0] = address(antiSnipe);
        clean[1] = address(adaptiveFee);
        vm.prank(creator);
        changeRegistry.proposeLaneChange(poolId, 0, clean, new bytes32[](0));
        _buy(0.1 ether);
    }

    // ------------------------------------------------------------------
    // Fuzz: classification matches the table
    // ------------------------------------------------------------------

    function testFuzz_settingClassificationMatchesTable(uint8 mode, uint256 value) public {
        mode = uint8(bound(mode, 0, 2));
        value = bound(value, 5_000, 200_000);
        _launchIn(mode);
        uint256 id = _proposeSetting(THRESHOLD, value);
        bool safer = value <= 20_000;
        bool instant = safer || mode != GUARDED;
        assertEq(uint8(_status(id)), uint8(instant ? ChangeRegistry.Status.Applied : ChangeRegistry.Status.Queued));
        assertEq(_get(THRESHOLD), instant ? value : 20_000);
    }
}
