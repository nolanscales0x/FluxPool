// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {ChangeRegistry} from "../../src/gates/ChangeRegistry.sol";
import {PlaybookRegistry} from "../../src/playbooks/PlaybookRegistry.sol";
import {FluxProtectedToken} from "../../src/protection/FluxProtectedToken.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";

/// @title ReviewDemo
/// @notice One runnable answer to the three things a Programmable Custom Launch review asks to see,
/// plus the condition that a community-selected Wild mode cannot bypass the mandatory protections.
///
///   A. The actual fee and action limits, and that they are enforced on chain.
///   B. That Wild mode changes the wait, not the limits: the caps, the platform fee and the agent
///      timelock hold in every mode.
///   C. That a playbook can only ever tighten a setting.
///   D. The scope of an agent's session: one pool, one level, rate limited.
///   E. That revocation is instant and voids a queued raise.
///   F. That settings and mode changes are timelocked, and that execution is permissionless.
///   G. The recipient budget a protected launch token enforces: cumulative 2% per wallet for five
///      minutes, with sells exempt because a sell settles into the PoolManager.
///
/// Run it: `forge test --match-contract ReviewDemo -vv`
///
/// Everything below runs against the real shell, core, blocks and registries, deployed fresh by the
/// shared test base exactly as the launch script deploys them. No mocks stand in for any of the
/// contracts under review, and nothing here is a re-implementation of a rule: each assertion calls
/// the same code path a live pool calls.
contract ReviewDemo is FluxTestBase {
    address agent = makeAddr("agent");
    address trader = makeAddr("trader");

    function setUp() public override {
        super.setUp();
        vm.deal(trader, 1_000 ether);
    }

    /// @dev Settings are written through the real change registry, so the core's gate is the
    /// registry, not this test contract.
    function _coreGate() internal view override returns (address) {
        return address(changeRegistry);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Launches a fresh pool with both starting blocks in the before lane, the adaptive fee block
    /// also in the after lane, and the given freedom mode (0 Guarded, 1 Fast, 2 Wild).
    function _launchAs(uint8 mode) internal {
        launchMode = mode;
        address[] memory before = new address[](2);
        before[0] = address(antiSnipe);
        before[1] = address(adaptiveFee);
        _launch(before, _one(address(adaptiveFee)), _noSettings());
    }

    function _setting(address blockAddr, bytes32 setting) internal view returns (uint256) {
        return IFluxBlockLike(blockAddr).getSetting(address(core), setting);
    }

    function _propose(address blockAddr, bytes32 setting, uint256 value) internal returns (uint256) {
        vm.prank(creator);
        return changeRegistry.proposeSetting(poolId, blockAddr, setting, value);
    }

    function _expectOutOfBounds(address blockAddr, bytes32 setting, uint256 value) internal {
        vm.prank(creator);
        vm.expectRevert(ChangeRegistry.OutOfBounds.selector);
        changeRegistry.proposeSetting(poolId, blockAddr, setting, value);
    }

    function _noTrigger() internal pure returns (PlaybookRegistry.Trigger memory t) {}

    function _tighten(address blockAddr, bytes32 setting, uint256 value)
        internal
        pure
        returns (PlaybookRegistry.Action[] memory a)
    {
        a = new PlaybookRegistry.Action[](1);
        a[0] = PlaybookRegistry.Action(blockAddr, setting, value);
    }

    function _add(PlaybookRegistry.Action[] memory a) internal returns (uint256) {
        vm.prank(creator);
        return playbookRegistry.addPlaybook(poolId, a, 10 minutes, 4, _noTrigger());
    }

    function _buyAsTrader(uint256 ethIn) internal {
        vm.prank(trader);
        swapRouter.swap{value: ethIn}(
            poolKey,
            SwapParams({zeroForOne: _buyDir(), amountSpecified: -int256(ethIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    // ------------------------------------------------------------------
    // A. The actual fee and action limits
    // ------------------------------------------------------------------

    /// @notice Every setting a block exposes has a hard range, and a proposal outside it is rejected
    /// before anything is queued. These are the numbers a reviewer can hold us to.
    function test_A_feeAndActionLimits_areEnforcedOnChain() public {
        _launchAs(0);

        emit log_string("AntiSnipe: openingFee 10_000-990_000, maxBuyBps 10-500, maxBuysPerBlock 1-20");
        _expectOutOfBounds(address(antiSnipe), antiSnipe.OPENING_FEE(), 9_999);
        _expectOutOfBounds(address(antiSnipe), antiSnipe.OPENING_FEE(), 990_001);
        _expectOutOfBounds(address(antiSnipe), antiSnipe.MAX_BUY_BPS(), 9);
        _expectOutOfBounds(address(antiSnipe), antiSnipe.MAX_BUY_BPS(), 501);
        _expectOutOfBounds(address(antiSnipe), antiSnipe.MAX_BUYS_PER_BLOCK(), 0);
        _expectOutOfBounds(address(antiSnipe), antiSnipe.MAX_BUYS_PER_BLOCK(), 21);

        emit log_string("AdaptiveFee: threshold 5_000-200_000, maxFee 0-50_000, windowBlocks 5-200");
        _expectOutOfBounds(address(adaptiveFee), adaptiveFee.THRESHOLD(), 4_999);
        _expectOutOfBounds(address(adaptiveFee), adaptiveFee.THRESHOLD(), 200_001);
        _expectOutOfBounds(address(adaptiveFee), adaptiveFee.MAX_FEE(), 50_001);
        _expectOutOfBounds(address(adaptiveFee), adaptiveFee.WINDOW_BLOCKS(), 4);
        _expectOutOfBounds(address(adaptiveFee), adaptiveFee.WINDOW_BLOCKS(), 201);

        emit log_string("CreatorFee: creatorShareBps 2_000-8_000, agentShareBps 0-2_000");
        _expectOutOfBounds(address(creatorFee), creatorFee.CREATOR_SHARE(), 1_999);
        _expectOutOfBounds(address(creatorFee), creatorFee.CREATOR_SHARE(), 8_001);
        _expectOutOfBounds(address(creatorFee), creatorFee.AGENT_SHARE(), 2_001);

        emit log_string("A setting the block does not expose is rejected as well");
        _expectOutOfBounds(address(antiSnipe), "notASetting", 1);

        emit log_string("An in-range value is accepted (lower buys per block is the safer direction)");
        _propose(address(antiSnipe), antiSnipe.MAX_BUYS_PER_BLOCK(), 2);
        emit log_named_uint(
            "maxBuysPerBlock after a safer change", _setting(address(antiSnipe), antiSnipe.MAX_BUYS_PER_BLOCK())
        );
        assertEq(_setting(address(antiSnipe), antiSnipe.MAX_BUYS_PER_BLOCK()), 2); // applied at once
    }

    // ------------------------------------------------------------------
    // B. Wild mode changes the wait, not the limits
    // ------------------------------------------------------------------

    /// @notice A community-selected Wild mode cannot bypass the mandatory launch protections, the
    /// platform fee, or the agent timelock. It only removes the delay on a riskier in-range setting.
    function test_B_wildMode_changesTheWait_notTheLimits() public {
        // Guarded: a riskier change, still well inside its bounds, waits out the timelock.
        _launchAs(0);
        uint256 guardedId = _propose(address(antiSnipe), antiSnipe.MAX_BUY_BPS(), 200);
        emit log_named_uint("Guarded: change id (queued)", guardedId);
        assertEq(_setting(address(antiSnipe), antiSnipe.MAX_BUY_BPS()), 100);

        // Wild: the same change applies at once.
        _launchAs(2);
        assertEq(shell.launchModeOf(poolId), 2);
        _propose(address(antiSnipe), antiSnipe.MAX_BUY_BPS(), 200);
        emit log_named_uint("Wild: maxBuyBps applied at once", _setting(address(antiSnipe), antiSnipe.MAX_BUY_BPS()));
        assertEq(_setting(address(antiSnipe), antiSnipe.MAX_BUY_BPS()), 200);

        // The bound itself is unchanged: 500 bps is still the ceiling in Wild.
        emit log_string("Wild: the 500 bps ceiling still holds");
        _expectOutOfBounds(address(antiSnipe), antiSnipe.MAX_BUY_BPS(), 501);
        _expectOutOfBounds(address(antiSnipe), antiSnipe.OPENING_FEE(), 990_001);
        _expectOutOfBounds(address(adaptiveFee), adaptiveFee.MAX_FEE(), 50_001);
        _expectOutOfBounds(address(creatorFee), creatorFee.CREATOR_SHARE(), 8_001);

        // Adding an agent is timelocked in Wild too. Mode never touches who may act.
        vm.prank(creator);
        uint256 id = agentRegistry.setAgent(poolId, agent, uint8(AgentRegistry.Level.ProposeCode));
        assertGt(id, 0, "wild: adding an agent still waits");
        assertEq(agentRegistry.agentOf(poolId), address(0));
        vm.warp(block.timestamp + 48 hours);
        changeRegistry.execute(id);
        assertEq(agentRegistry.agentOf(poolId), agent);

        // The platform fee is charged on an ordinary buy in a Wild pool, at the same fixed 30 bps.
        _skipWindow();
        _buyAsTrader(1 ether);
        emit log_named_uint("Wild: platform fee on a 1 ETH buy", shell.platformAccrued());
        assertEq(shell.platformAccrued(), 0.003 ether);
    }

    // ------------------------------------------------------------------
    // C. A playbook can only tighten
    // ------------------------------------------------------------------

    /// @notice Responses are approved in advance, and approval rejects anything that would move a
    /// setting in its riskier direction or outside its bounds. A playbook that tightens fires at
    /// once in every mode, because the only direction it can move is the safe one.
    function test_C_playbooks_canOnlyTighten() public {
        _launchAs(0);

        // Raising the threshold (looser) is rejected at approval, action by action.
        PlaybookRegistry.Action[] memory looser = _tighten(address(adaptiveFee), adaptiveFee.THRESHOLD(), 30_000);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PlaybookRegistry.LooseningAction.selector, 0));
        playbookRegistry.addPlaybook(poolId, looser, 10 minutes, 4, _noTrigger());

        // So is a value outside the block's bounds.
        PlaybookRegistry.Action[] memory belowMin = _tighten(address(adaptiveFee), adaptiveFee.THRESHOLD(), 4_000);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(PlaybookRegistry.OutOfBounds.selector, 0));
        playbookRegistry.addPlaybook(poolId, belowMin, 10 minutes, 4, _noTrigger());

        // A tightening playbook is approved and fires at once: no timelock, on purpose.
        uint256 id = _add(_tighten(address(adaptiveFee), adaptiveFee.THRESHOLD(), 10_000));
        vm.prank(creator);
        playbookRegistry.fire(id);
        emit log_named_uint("Fired: threshold", _setting(address(adaptiveFee), adaptiveFee.THRESHOLD()));
        assertEq(_setting(address(adaptiveFee), adaptiveFee.THRESHOLD()), 10_000);

        // It cannot fire again while active, and expiring restores the value it replaced.
        vm.prank(creator);
        vm.expectRevert(PlaybookRegistry.AlreadyActive.selector);
        playbookRegistry.fire(id);

        vm.warp(block.timestamp + 10 minutes);
        playbookRegistry.expire(id);
        emit log_named_uint("Expired: threshold", _setting(address(adaptiveFee), adaptiveFee.THRESHOLD()));
        assertEq(_setting(address(adaptiveFee), adaptiveFee.THRESHOLD()), 20_000);
    }

    // ------------------------------------------------------------------
    // D. The scope of a session: one pool, one level, rate limited
    // ------------------------------------------------------------------

    /// @notice An agent is one address on one pool at one level, checked on chain by the registries on
    /// every action, and bounded by a minimum gap and a daily maximum.
    function test_D_sessionScope_isOnePoolOneLevel_withRateLimits() public {
        _launchAs(0);
        PoolId poolA = poolId;

        // The check is registry-only: an outside caller cannot authorize anything.
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(AgentRegistry.NotRegistry.selector);
        agentRegistry.authorize(poolA, agent, AgentRegistry.Level.Fire);

        _registerAgent(agent, AgentRegistry.Level.Fire);

        // At its level it passes.
        vm.prank(playbooks);
        agentRegistry.authorize(poolA, agent, AgentRegistry.Level.Fire);

        // One level down is not enough: a Fire agent cannot propose a setting. The real call path.
        bytes32 maxFee = adaptiveFee.MAX_FEE();
        vm.prank(agent);
        vm.expectRevert(AgentRegistry.LevelTooLow.selector);
        changeRegistry.proposeSetting(poolA, address(adaptiveFee), maxFee, 40_000);

        // Anyone who isn't the agent is refused.
        vm.prank(playbooks);
        vm.expectRevert(AgentRegistry.NotAgent.selector);
        agentRegistry.authorize(poolA, makeAddr("stranger"), AgentRegistry.Level.Fire);

        // One pool only: the same address is not an agent on another pool.
        _launchAs(0);
        PoolId poolB = poolId;
        vm.prank(playbooks);
        vm.expectRevert(AgentRegistry.NotAgent.selector);
        agentRegistry.authorize(poolB, agent, AgentRegistry.Level.Fire);

        // Rate limits: two playbooks, and the agent cannot fire the second inside the minimum gap.
        _launchAs(0);
        _registerAgent(agent, AgentRegistry.Level.Fire);
        uint256 first = _add(_tighten(address(adaptiveFee), adaptiveFee.MAX_FEE(), 50_000));
        uint256 second = _add(_tighten(address(antiSnipe), antiSnipe.MAX_BUYS_PER_BLOCK(), 1));
        vm.prank(agent);
        playbookRegistry.fire(first);
        vm.prank(agent);
        vm.expectRevert(AgentRegistry.TooSoon.selector);
        playbookRegistry.fire(second);
        vm.warp(block.timestamp + agentRegistry.DEFAULT_MIN_GAP());
        vm.prank(agent);
        playbookRegistry.fire(second);
        emit log_named_uint("Agent actions a day, by default", agentRegistry.DEFAULT_DAILY_MAX());
        assertEq(agentRegistry.DEFAULT_MIN_GAP(), 60);
    }

    // ------------------------------------------------------------------
    // E. Revocation is instant, and voids anything still queued
    // ------------------------------------------------------------------

    /// @notice The off switch doesn't wait for anything. It applies in the transaction it is sent in,
    /// and any raise still queued from before cannot bring the agent back.
    function test_E_revocation_isInstant_andVoidsAQueuedRaise() public {
        _launchAs(0);
        _registerAgent(agent, AgentRegistry.Level.Fire);

        // A raise sits behind the timelock.
        vm.prank(creator);
        uint256 id = agentRegistry.setAgent(poolId, agent, uint8(AgentRegistry.Level.ProposeCode));
        assertGt(id, 0);

        // Revoking is instant: no queue, no delay, no checks.
        vm.prank(creator);
        agentRegistry.removeAgent(poolId);
        emit log_string("Removed instantly; the queued raise is now stale");
        assertEq(agentRegistry.agentOf(poolId), address(0));

        // The queued raise cannot resurrect it, even after the delay has passed.
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(AgentRegistry.StaleChange.selector);
        changeRegistry.execute(id);
        assertEq(agentRegistry.agentOf(poolId), address(0));

        // And a removed agent can no longer act.
        vm.prank(playbooks);
        vm.expectRevert(AgentRegistry.NotAgent.selector);
        agentRegistry.authorize(poolId, agent, AgentRegistry.Level.Fire);

        // Only the pool's creator can revoke.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(AgentRegistry.NotCreator.selector);
        agentRegistry.removeAgent(poolId);
    }

    // ------------------------------------------------------------------
    // F. Timelocks, and permissionless execution
    // ------------------------------------------------------------------

    /// @notice A queued change cannot execute early, anyone may execute it once the delay has passed,
    /// and the creator can cancel it at any time.
    function test_F_settingsAndModes_areTimelocked_andAnyoneMayExecute() public {
        _launchAs(0);

        uint64 queuedAt = uint64(block.timestamp);
        uint256 id = _propose(address(antiSnipe), antiSnipe.MAX_BUY_BPS(), 200);
        uint64 earliest = queuedAt + 48 hours;
        assertEq(_setting(address(antiSnipe), antiSnipe.MAX_BUY_BPS()), 100);

        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.TooEarly.selector, earliest));
        changeRegistry.execute(id);

        // A stranger can execute: the delay is the permission, not a role.
        vm.warp(earliest);
        vm.prank(makeAddr("stranger"));
        changeRegistry.execute(id);
        assertEq(_setting(address(antiSnipe), antiSnipe.MAX_BUY_BPS()), 200);

        // Cancel is instant and final.
        uint256 id2 = _propose(address(antiSnipe), antiSnipe.MAX_BUY_BPS(), 300);
        vm.prank(creator);
        changeRegistry.cancel(id2);
        vm.warp(uint64(block.timestamp) + 48 hours);
        vm.expectRevert(ChangeRegistry.NotQueued.selector);
        changeRegistry.execute(id2);

        // Moving to a freer mode is timelocked, and a mode change never skips the agent timelock.
        vm.prank(creator);
        uint256 modeId = changeRegistry.setMode(poolId, 1);
        uint64 modeEarliest = uint64(block.timestamp) + 48 hours;
        assertGt(modeId, 0);
        vm.expectRevert(abi.encodeWithSelector(ChangeRegistry.TooEarly.selector, modeEarliest));
        changeRegistry.execute(modeId);
        vm.warp(modeEarliest);
        changeRegistry.execute(modeId);
        assertEq(uint8(changeRegistry.modeOf(poolId)), 1);
    }

    // ------------------------------------------------------------------
    // G. The recipient budget of a protected launch token
    // ------------------------------------------------------------------

    /// @notice One of the three things the review asks for is the cumulative 2% recipient limit, and it
    /// can only be enforced in the token rather than in the hook — so this runs the token itself,
    /// against the real PoolManager this suite already deploys. Exactly 2% may reach a wallet, one unit
    /// more reverts, a wallet at its limit can still sell, and nothing is capped at five minutes.
    function test_G_protectedToken_capsEachRecipientAtTwoPercentForFiveMinutes() public {
        address initializer = makeAddr("protectedInitializer");
        uint256 supply = 1_000_000_000e18;
        FluxProtectedToken token = new FluxProtectedToken("Protected", "PROT", supply, initializer, address(manager));
        uint256 limit = token.walletTokenLimit();

        emit log_string("the whole supply is minted once, and 2% of it is the limit per recipient");
        assertEq(token.balanceOf(initializer), supply);
        assertEq(limit, supply * 200 / 10_000);

        emit log_string("before trading opens, the seed is the only movement allowed");
        vm.prank(initializer);
        vm.expectRevert(FluxProtectedToken.TradingNotStarted.selector);
        token.transfer(trader, 1);
        vm.prank(initializer);
        token.transfer(address(manager), limit); // the seed, into the pool

        vm.prank(initializer);
        token.start();
        assertEq(token.protectionEndsAt(), block.timestamp + 300);

        emit log_string("exactly 2% reaches a recipient; one unit more reverts");
        vm.prank(initializer);
        token.transfer(trader, limit);
        assertEq(token.receivedDuringProtection(trader), limit);
        vm.prank(initializer);
        vm.expectRevert(
            abi.encodeWithSelector(FluxProtectedToken.WalletLimitExceeded.selector, trader, limit + 1, limit)
        );
        token.transfer(trader, 1);

        emit log_string("selling everything is allowed, and does not give the budget back");
        vm.prank(trader);
        token.transfer(address(manager), limit);
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.receivedDuringProtection(trader), limit);
        vm.prank(initializer);
        vm.expectRevert(
            abi.encodeWithSelector(FluxProtectedToken.WalletLimitExceeded.selector, trader, limit + 1, limit)
        );
        token.transfer(trader, 1);

        emit log_string("at five minutes the cap is gone and nothing further is recorded");
        vm.warp(block.timestamp + 300);
        vm.prank(initializer);
        token.transfer(trader, limit);
        assertEq(token.balanceOf(trader), limit);
        assertEq(token.receivedDuringProtection(trader), limit);
    }
}

interface IFluxBlockLike {
    function getSetting(address core, bytes32 setting) external view returns (uint256);
}
