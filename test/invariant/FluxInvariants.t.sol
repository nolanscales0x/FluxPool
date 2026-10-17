// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FluxCore} from "../../src/core/FluxCore.sol";
import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {PlaybookRegistry} from "../../src/playbooks/PlaybookRegistry.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";
import {FluxHandler} from "./FluxHandler.sol";

/// @notice The six protections from A6, checked after every call of long random sequences. One
/// suite per freedom mode. Run with FOUNDRY_PROFILE=ci for 10,000 sequences per mode.
abstract contract FluxInvariantBase is FluxTestBase {
    using StateLibrary for IPoolManager;

    FluxHandler handler;
    address agent = makeAddr("agent");
    address attester = makeAddr("attester");

    function _mode() internal pure virtual returns (uint8);
    function _agentLevel() internal pure virtual returns (AgentRegistry.Level);

    function _coreGate() internal view override returns (address) {
        return address(changeRegistry);
    }

    function setUp() public override {
        super.setUp();
        launchMode = _mode();
        address[] memory before = new address[](2);
        before[0] = address(antiSnipe);
        before[1] = address(adaptiveFee);
        _launch(before, _one(address(adaptiveFee)), _noSettings());
        _registerAgent(agent, _agentLevel()); // also moves past the launch window
        vm.prank(attesterManager);
        changeRegistry.setAttester(attester, true);

        uint256[] memory pbs = new uint256[](2);
        pbs[0] = _addPlaybook(address(adaptiveFee), adaptiveFee.MAX_FEE(), 50_000);
        pbs[1] = _addPlaybook(address(adaptiveFee), adaptiveFee.THRESHOLD(), 5_000);

        address[] memory traders = new address[](5);
        for (uint256 i; i < traders.length; i++) {
            traders[i] = makeAddr(string.concat("trader", vm.toString(i)));
            token.transfer(traders[i], 1_000 ether);
            vm.prank(traders[i]);
            token.approve(address(swapRouter), type(uint256).max);
            if (_usesWeth()) {
                vm.prank(traders[i]);
                weth.approve(address(swapRouter), type(uint256).max);
            }
        }

        handler = new FluxHandler(
            FluxHandler.System({
                manager: manager,
                swapRouter: swapRouter,
                shell: shell,
                core: core,
                antiSnipe: antiSnipe,
                adaptiveFee: adaptiveFee,
                creatorFee: creatorFee,
                agentRegistry: agentRegistry,
                changeRegistry: changeRegistry,
                playbookRegistry: playbookRegistry,
                token: token,
                weth: weth,
                key: poolKey,
                id: poolId,
                creator: creator,
                agent: agent,
                attester: attester,
                agentLevel: uint8(_agentLevel()),
                mode: _mode(),
                playbooks: pbs
            }),
            traders
        );
        targetContract(address(handler));
    }

    function _addPlaybook(address b, bytes32 setting, uint256 value) internal returns (uint256) {
        PlaybookRegistry.Action[] memory a = new PlaybookRegistry.Action[](1);
        a[0] = PlaybookRegistry.Action(b, setting, value);
        vm.prank(creator);
        return playbookRegistry.addPlaybook(poolId, a, 10 minutes, 24, PlaybookRegistry.Trigger(0, 0, 0));
    }

    // ------------------------------------------------------------------
    // The protections
    // ------------------------------------------------------------------

    function invariant_sellNeverReverts() public view {
        assertEq(handler.sellReverts(), 0, "a sell reverted");
    }

    function invariant_feeNeverExceedsActiveCap() public view {
        assertEq(handler.capViolations(), 0, "fee above cap");
    }

    function invariant_lockedLiquidityStaysLocked() public view {
        assertEq(handler.earlyWithdrawals(), 0, "liquidity withdrawn");
        (uint128 liq,,) = manager.getPositionInfo(poolId, address(shell), TICK_LOWER, TICK_UPPER, bytes32(0));
        assertEq(liq, SEED_LIQUIDITY, "position shrank");
    }

    function invariant_platformFeeAlwaysCollectedAndBacked() public view {
        assertEq(handler.platformShortfalls(), 0, "trade paid under 30 bps to the platform");
        assertGe(
            manager.balanceOf(address(shell), quote.toId()), shell.platformAccrued(), "platform fees not fully backed"
        );
    }

    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), TOKEN_SUPPLY, "supply changed");
    }

    function invariant_agentStaysWithinItsLevel() public view {
        assertEq(handler.agentOverreach(), 0, "agent acted beyond its level");
        (address account, AgentRegistry.Level level,) = agentRegistry.agentInfo(poolId);
        assertEq(account, agent);
        assertEq(uint8(level), uint8(_agentLevel()), "agent level changed");
    }

    function afterInvariant() external view {
        console.log("buys", handler.buys(), "sells", handler.sells());
        console.log("fires", handler.fires(), "executes", handler.executes());
        console.log("blocks activated", handler.blocksActivated(), "pending", handler.pendingCount());
    }
}

/// @dev In Guarded and Fast: every block in a lane was there at launch or passed every required check.
abstract contract CheckedModeInvariants is FluxInvariantBase {
    function invariant_noBlockActivatesWithoutChecks() public view {
        for (uint8 l; l < 2; l++) {
            address[] memory lane = core.blocksIn(FluxCore.Lane(l));
            for (uint256 i; i < lane.length; i++) {
                assertTrue(handler.approved(lane[i]), "block live without its checks");
            }
        }
    }
}

/// @dev Guarded pairs with WETH, the token sorting below it (currency0); Fast and Wild pair with native ETH.
contract GuardedInvariants is CheckedModeInvariants {
    function _tokenFirst() internal pure override returns (bool) {
        return true;
    }

    function _mode() internal pure override returns (uint8) {
        return 0;
    }

    function _agentLevel() internal pure override returns (AgentRegistry.Level) {
        return AgentRegistry.Level.ProposeCode;
    }
}

contract FastInvariants is CheckedModeInvariants {
    function _mode() internal pure override returns (uint8) {
        return 1;
    }

    function _agentLevel() internal pure override returns (AgentRegistry.Level) {
        return AgentRegistry.Level.ProposeSettings;
    }
}

contract WildInvariants is FluxInvariantBase {
    function _mode() internal pure override returns (uint8) {
        return 2;
    }

    function _agentLevel() internal pure override returns (AgentRegistry.Level) {
        return AgentRegistry.Level.Fire;
    }
}
