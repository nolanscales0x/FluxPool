// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {BaseBlock} from "../../src/blocks/BaseBlock.sol";
import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";
import {FeeBlock, CallLog} from "../mocks/TestBlocks.sol";

contract CreatorFeeTest is FluxTestBase {
    Currency eth; // the pool quote (native ETH by default)
    Currency tok;
    address agent = makeAddr("agent");

    function setUp() public override {
        super.setUp();
        eth = quote;
        // A 1% fee block so the position earns something measurable.
        FeeBlock fee = new FeeBlock(1, new CallLog(), 7_000);
        _launch(_one(address(fee)), _none(), _noSettings());
        _skipWindow();
        tok = poolKey.currency1;
    }

    function _trade() internal {
        _buy(5 ether);
        _sell(5 ether);
    }

    function _setShare(bytes32 setting, uint256 value) internal {
        core.setBlockSetting(address(creatorFee), setting, value);
    }

    function test_defaultSplitIsHalfCreatorHalfProtocol() public {
        _trade();
        shell.collect(poolKey);
        uint256 c = shell.claimable(creator, eth);
        uint256 p = shell.claimable(treasury, eth);
        assertGt(c, 0);
        assertApproxEqAbs(c, p, 1);
        assertGt(shell.claimable(creator, tok), 0);
    }

    function test_splitFollowsCreatorFeeBlock() public {
        _setShare(creatorFee.CREATOR_SHARE(), 8_000);
        _trade();
        shell.collect(poolKey);
        uint256 c = shell.claimable(creator, eth);
        uint256 p = shell.claimable(treasury, eth);
        assertApproxEqRel(c, p * 4, 1e15);
    }

    function test_agentShareGoesToRegisteredAgent() public {
        _setShare(creatorFee.AGENT_SHARE(), 2_000);
        _registerAgent(agent, AgentRegistry.Level.Fire);
        _trade();
        shell.collect(poolKey);
        uint256 total = shell.claimable(creator, eth) + shell.claimable(treasury, eth) + shell.claimable(agent, eth);
        assertApproxEqAbs(shell.claimable(agent, eth), total * 2_000 / 10_000, 2);
        assertApproxEqAbs(shell.claimable(creator, eth), total * 5_000 / 10_000, 2);
    }

    function test_agentShareGoesToCreatorWhenNoAgent() public {
        _setShare(creatorFee.AGENT_SHARE(), 2_000);
        _trade();
        shell.collect(poolKey);
        uint256 total = shell.claimable(creator, eth) + shell.claimable(treasury, eth);
        assertApproxEqAbs(shell.claimable(creator, eth), total * 7_000 / 10_000, 2);
    }

    function test_collectIsPermissionlessAndClaimPaysOut() public {
        _trade();
        vm.prank(makeAddr("anyone"));
        shell.collect(poolKey);

        uint256 owed = shell.claimable(creator, eth);
        uint256 before = _quoteBalance(creator);
        vm.prank(creator);
        shell.claim(eth);
        assertEq(_quoteBalance(creator) - before, owed);
        assertEq(shell.claimable(creator, eth), 0);

        uint256 owedTok = shell.claimable(creator, tok);
        vm.prank(creator);
        shell.claim(tok);
        assertEq(token.balanceOf(creator), owedTok);
    }

    function test_shellHoldsExactlyWhatIsOwed() public {
        _registerAgent(agent, AgentRegistry.Level.Fire);
        _setShare(creatorFee.AGENT_SHARE(), 1_500);
        for (uint256 i; i < 3; i++) {
            _trade();
            shell.collect(poolKey);
        }
        assertEq(
            _quoteBalance(address(shell)),
            shell.claimable(creator, eth) + shell.claimable(treasury, eth) + shell.claimable(agent, eth)
        );
        assertEq(
            token.balanceOf(address(shell)),
            shell.claimable(creator, tok) + shell.claimable(treasury, tok) + shell.claimable(agent, tok)
        );
    }

    function test_collectWithNothingAccruedIsANoOp() public {
        shell.collect(poolKey);
        assertEq(shell.claimable(creator, eth), 0);
    }

    function test_shareBounds() public {
        bytes32 creatorShare = creatorFee.CREATOR_SHARE();
        bytes32 agentShare = creatorFee.AGENT_SHARE();
        vm.expectRevert(abi.encodeWithSelector(BaseBlock.OutOfBounds.selector, creatorShare, 8_001));
        _setShare(creatorShare, 8_001);
        vm.expectRevert(abi.encodeWithSelector(BaseBlock.OutOfBounds.selector, creatorShare, 1_999));
        _setShare(creatorShare, 1_999);
        vm.expectRevert(abi.encodeWithSelector(BaseBlock.OutOfBounds.selector, agentShare, 2_001));
        _setShare(agentShare, 2_001);
    }

    function testFuzz_splitAlwaysAddsUp(uint256 creatorShare, uint256 agentShare, bool hasAgent) public {
        _setShare(creatorFee.CREATOR_SHARE(), bound(creatorShare, 2_000, 8_000));
        _setShare(creatorFee.AGENT_SHARE(), bound(agentShare, 0, 2_000));
        if (hasAgent) _registerAgent(agent, AgentRegistry.Level.Fire);
        _trade();
        shell.collect(poolKey);
        (uint256 c, uint256 a,) = shell.feeSplit(poolId);
        assertLe(c + a, 10_000);
        assertEq(
            _quoteBalance(address(shell)),
            shell.claimable(creator, eth) + shell.claimable(treasury, eth) + shell.claimable(agent, eth)
        );
    }
}
