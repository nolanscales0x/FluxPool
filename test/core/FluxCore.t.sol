// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FluxCore} from "../../src/core/FluxCore.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";
import {CallLog, FeeBlock, HostileBlock, TraderBlock} from "../mocks/TestBlocks.sol";

contract FluxCoreTest is FluxTestBase {
    CallLog callLog;
    FeeBlock a;
    FeeBlock b;
    FeeBlock c;
    HostileBlock hostile;

    function setUp() public override {
        super.setUp();
        callLog = new CallLog();
        a = new FeeBlock(1, callLog, 1_000);
        b = new FeeBlock(2, callLog, 2_000);
        c = new FeeBlock(3, callLog, 4_000);
        hostile = new HostileBlock(manager);
    }

    function _lane(address x, address y) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = x;
        l[1] = y;
    }

    function _lane(address x, address y, address z) internal pure returns (address[] memory l) {
        l = new address[](3);
        l[0] = x;
        l[1] = y;
        l[2] = z;
    }

    // ------------------------------------------------------------------
    // Combining rules
    // ------------------------------------------------------------------

    function test_runsBlocksInLaneOrderAndAddsFees() public {
        _launch(_lane(address(c), address(a), address(b)), _none(), _noSettings());
        _skipWindow();
        assertEq(_feeOf(true, 0.1 ether), BASE_FEE + 7_000);
        uint256[] memory order = callLog.all();
        assertEq(order.length, 3);
        assertEq(order[0], 3);
        assertEq(order[1], 1);
        assertEq(order[2], 2);
    }

    function test_firstRejectionStopsTheLaneForBuys() public {
        _launch(_lane(address(a), address(b), address(c)), _none(), _noSettings());
        _skipWindow();
        b.set(2_000, false);
        assertTrue(_buyReverts(0.1 ether));
        // The buy reverted, so its log entries rolled back; check the order on a sell instead below.
    }

    function test_sellsIgnoreRejectionsAndStillRunLaterBlocks() public {
        _launch(_lane(address(a), address(b), address(c)), _none(), _noSettings());
        _skipWindow();
        b.set(2_000, false);
        // All three blocks still add their fee on a sell: a rejecting block can't switch off later ones.
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE + 7_000);
        assertEq(callLog.all().length, 3);
    }

    function test_totalFeeIsClampedByShell() public {
        a.set(40_000, true);
        b.set(40_000, true);
        _launch(_lane(address(a), address(b)), _none(), _noSettings());
        _skipWindow();
        assertEq(_feeOf(true, 0.1 ether), FEE_CAP);
    }

    function test_afterSwapLaneRuns() public {
        _launch(_none(), _lane(address(a), address(b)), _noSettings());
        _skipWindow();
        _sell(0.1 ether);
        assertEq(a.afterCalls(), 1);
        assertEq(b.afterCalls(), 1);
    }

    // ------------------------------------------------------------------
    // Hostile blocks
    // ------------------------------------------------------------------

    function test_hostileRejectAllBlocksBuysButNotSells() public {
        hostile.set(HostileBlock.Mode.RejectAll, address(0));
        _launch(_lane(address(hostile), address(a)), _none(), _noSettings());
        _skipWindow();
        assertTrue(_buyReverts(0.1 ether));
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE + 1_000);
    }

    function test_hostileMaxFeeIsClamped() public {
        hostile.set(HostileBlock.Mode.MaxFee, address(0));
        _launch(_one(address(hostile)), _none(), _noSettings());
        _skipWindow();
        assertEq(_feeOf(true, 0.1 ether), FEE_CAP);
        assertEq(_feeOf(false, 0.1 ether), FEE_CAP);
    }

    /// Every failure mode is skipped: the other blocks keep working and sells go through.
    function test_failingBlocksAreSkipped() public {
        HostileBlock.Mode[6] memory modes = [
            HostileBlock.Mode.Revert,
            HostileBlock.Mode.BurnGas,
            HostileBlock.Mode.ShortReturn,
            HostileBlock.Mode.OutOfRange,
            HostileBlock.Mode.TakeFunds,
            HostileBlock.Mode.SyncCurrency
        ];
        for (uint256 i; i < modes.length; i++) {
            HostileBlock h = new HostileBlock(manager);
            h.set(modes[i], address(0));
            _launch(_lane(address(a), address(h), address(b)), _lane(address(h), address(a)), _noSettings());
            _skipWindow();
            assertEq(_feeOf(false, 0.1 ether), BASE_FEE + 3_000, "sell fee");
            assertEq(_feeOf(true, 0.1 ether), BASE_FEE + 3_000, "buy fee");
        }
    }

    /// A return bomb's leading zero words read as a valid "no fee, reject" answer: the same as a
    /// block that rejects buys, which any block may do. It must not cost the core its gas budget.
    function test_returnBombActsAsRejectionAndSellsPass() public {
        hostile.set(HostileBlock.Mode.ReturnBomb, address(0));
        _launch(_lane(address(hostile), address(a)), _none(), _noSettings());
        _skipWindow();
        assertTrue(_buyReverts(0.1 ether));
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE + 1_000);
    }

    function test_blockCannotTakeFundsFromPoolManager() public {
        hostile.set(HostileBlock.Mode.TakeFunds, address(0));
        _launch(_one(address(hostile)), _one(address(hostile)), _noSettings());
        _skipWindow();
        _sell(1 ether);
        _buy(1 ether);
        assertEq(token.balanceOf(address(hostile)), 0);
        assertEq(address(hostile).balance, 0);
    }

    function test_blockCannotRewriteLanes() public {
        hostile.set(HostileBlock.Mode.ReenterCore, address(0));
        _launch(_lane(address(hostile), address(a)), _none(), _noSettings());
        hostile.set(HostileBlock.Mode.ReenterCore, address(core));
        _skipWindow();
        _sell(0.1 ether);
        assertEq(core.blocksIn(FluxCore.Lane.BeforeSwap).length, 2);
    }

    function test_fourHostileGasBurnersStillLetSellsThrough() public {
        address[] memory lane = new address[](4);
        for (uint256 i; i < 4; i++) {
            HostileBlock h = new HostileBlock(manager);
            h.set(HostileBlock.Mode.BurnGas, address(0));
            lane[i] = address(h);
        }
        _launch(lane, lane, _noSettings());
        _skipWindow();
        // Each burns its full allowance; the lane still fits the shell's budget, so the core answers.
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
    }

    // ------------------------------------------------------------------
    // Access and setup
    // ------------------------------------------------------------------

    function test_onlyShellCanCallCore() public {
        _launch(_one(address(a)), _none(), _noSettings());
        vm.expectRevert(FluxCore.NotShell.selector);
        core.onBeforeSwap(address(this), poolKey, _dummyParams(), "");
    }

    function test_onlyGatesCanSetLanes() public {
        _launch(_one(address(a)), _none(), _noSettings());
        address[] memory l = _one(address(b));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FluxCore.NotGate.selector);
        core.setLane(FluxCore.Lane.BeforeSwap, l);

        core.setLane(FluxCore.Lane.BeforeSwap, l); // this test contract is the gate
        assertEq(core.blocksIn(FluxCore.Lane.BeforeSwap)[0], address(b));
        vm.prank(playbooks);
        core.setLane(FluxCore.Lane.BeforeSwap, _none());
        assertEq(core.blocksIn(FluxCore.Lane.BeforeSwap).length, 0);
    }

    function test_rejectsBadLanes() public {
        _launch(_none(), _none(), _noSettings());
        address[] memory five = new address[](5);
        for (uint256 i; i < 5; i++) {
            five[i] = address(new FeeBlock(i, callLog, 0));
        }
        vm.expectRevert(FluxCore.LaneTooLong.selector);
        core.setLane(FluxCore.Lane.BeforeSwap, five);

        vm.expectRevert(FluxCore.DuplicateBlock.selector);
        core.setLane(FluxCore.Lane.BeforeSwap, _lane(address(a), address(a)));

        vm.expectRevert(FluxCore.InvalidBlock.selector);
        core.setLane(FluxCore.Lane.BeforeSwap, _one(makeAddr("no-code")));
    }

    function test_cannotInitializeTwiceOrInitializeImplementation() public {
        _launch(_none(), _none(), _noSettings());
        vm.expectRevert(FluxCore.AlreadyInitialized.selector);
        core.initialize(poolKey, BASE_FEE, _none(), _none(), _noSettings());
        vm.expectRevert(FluxCore.AlreadyInitialized.selector);
        coreImpl.initialize(poolKey, BASE_FEE, _none(), _none(), _noSettings());
    }

    function test_sandboxIsSelfOnly() public {
        _launch(_none(), _none(), _noSettings());
        vm.expectRevert(FluxCore.NotSelf.selector);
        core.sandbox(address(a), 50_000, "", false, poolKey.currency0, poolKey.currency1);
    }

    function test_traderComesFromHookDataElseRouter() public {
        TraderBlock t = new TraderBlock();
        _launch(_one(address(t)), _none(), _noSettings());
        _skipWindow();
        address alice = makeAddr("alice");
        _swap(_buyDir(), -0.1 ether, abi.encode(alice));
        assertEq(t.lastTrader(), alice);
        _buy(0.1 ether); // no hookData
        assertEq(t.lastTrader(), address(swapRouter));
    }

    function _dummyParams() internal pure returns (SwapParams memory p) {}
}
