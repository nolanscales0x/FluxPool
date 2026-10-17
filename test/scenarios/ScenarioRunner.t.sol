// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {FluxCore} from "../../src/core/FluxCore.sol";
import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {PlaybookRegistry} from "../../src/playbooks/PlaybookRegistry.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";
import {HostileBlock, LightFeeBlock} from "../mocks/TestBlocks.sol";

/// @notice Replays the shared attack scenarios in contracts/scenarios/ (format in its README). Runs
/// on a fresh local PoolManager, or on a fork when FORK_RPC_URL and POOL_MANAGER are set.
abstract contract ScenarioRunnerBase is FluxTestBase {
    /// @dev Fields in alphabetical order of the JSON keys, which is how Foundry decodes objects.
    struct Step {
        string actor;
        uint256 amount;
        uint256 blockOffset; // "block"
        string expect;
        string kind;
        uint256 seconds_; // "seconds"
        string target;
        uint256 value;
    }

    uint256 constant POOL_TOKENS = 100 ether; // starting token reserve, from SEED_LIQUIDITY at price 1

    address agent = makeAddr("agent");
    address attester = makeAddr("attester");
    address anyone = makeAddr("anyone");

    uint256 playbookId;
    uint256 lastChange;
    uint24 lastFee;
    bool sellFailed;
    bool capBroken;
    address[] snipers;
    mapping(address => bool) funded;
    mapping(bytes32 => address) named;

    function _coreGate() internal view override returns (address) {
        return address(changeRegistry);
    }

    // ------------------------------------------------------------------
    // One test per scenario file
    // ------------------------------------------------------------------

    function test_scenario_snipeAtLaunch() public {
        _run("snipe-at-launch");
    }

    function test_scenario_panicSell() public {
        _run("panic-sell");
    }

    function test_scenario_stolenKeyFireSpam() public {
        _run("stolen-key-fire-spam");
    }

    function test_scenario_stolenKeyLoosening() public {
        _run("stolen-key-loosening");
    }

    function test_scenario_fakeDump() public {
        _run("fake-dump");
    }

    function test_scenario_hostileBlock() public {
        _run("hostile-block");
    }

    function test_scenario_wildHostileBlock() public {
        _run("wild-hostile-block");
    }

    function test_scenario_quietSwitchToWild() public {
        _run("quiet-switch-to-wild");
    }

    function test_scenario_missingOrFailedCheck() public {
        _run("missing-or-failed-check");
    }

    function test_scenario_feeGriefing() public {
        _run("fee-griefing");
    }

    /// Every JSON file in the folder has a test above, so a new scenario can't be added silently.
    function test_everyScenarioFileIsCovered() public view {
        Vm.DirEntry[] memory entries = vm.readDir("scenarios");
        uint256 json;
        for (uint256 i; i < entries.length; i++) {
            if (_endsWith(entries[i].path, ".json")) json++;
        }
        assertEq(json, 10, "add a test_scenario_ function for the new scenario file");
    }

    // ------------------------------------------------------------------
    // Runner
    // ------------------------------------------------------------------

    function _run(string memory id) internal {
        string memory json = vm.readFile(string.concat("scenarios/", id, ".json"));
        assertEq(vm.parseJsonString(json, ".id"), id, "file id");
        _start(json);

        Step[] memory steps = abi.decode(vm.parseJson(json, ".steps"), (Step[]));
        uint256 b0 = block.number;
        uint256 t0 = block.timestamp;
        for (uint256 i; i < steps.length; i++) {
            Step memory s = steps[i];
            if (b0 + s.blockOffset > block.number) vm.roll(b0 + s.blockOffset);
            if (t0 + s.seconds_ > block.timestamp) vm.warp(t0 + s.seconds_);
            _fund(s.actor);

            bool ok;
            try this.doStep(s) {
                ok = true;
            } catch {}
            string memory where = string.concat(id, " step ", vm.toString(i), " (", s.kind, ")");
            if (_eq(s.kind, "sell") && !ok) sellFailed = true;
            if (_eq(s.expect, "ok")) assertTrue(ok, string.concat(where, " should succeed"));
            if (_eq(s.expect, "revert")) assertFalse(ok, string.concat(where, " should revert"));
            if (ok && _eq(s.kind, "sell") && s.value > 0) assertLe(lastFee, s.value, string.concat(where, " fee"));
        }
        _checkOutcome(json, id);
    }

    function _start(string memory json) internal {
        launchMode = uint8(vm.parseJsonUint(json, ".start.mode"));
        address[] memory before = _blocksByName(vm.parseJsonStringArray(json, ".start.beforeSwap"));
        address[] memory afterLane = _blocksByName(vm.parseJsonStringArray(json, ".start.afterSwap"));
        _launch(before, afterLane, _noSettings(), uint32(vm.parseJsonUint(json, ".start.launchWindow")));

        uint256 pb = vm.parseJsonUint(json, ".start.playbook");
        if (pb != 0) {
            PlaybookRegistry.Action[] memory a = new PlaybookRegistry.Action[](1);
            a[0] = PlaybookRegistry.Action(address(adaptiveFee), adaptiveFee.MAX_FEE(), 50_000);
            PlaybookRegistry.Trigger memory t =
                pb == 2 ? PlaybookRegistry.Trigger(5, 3, 200) : PlaybookRegistry.Trigger(0, 0, 0);
            vm.prank(creator);
            playbookId = playbookRegistry.addPlaybook(poolId, a, 10 minutes, 24, t);
        }
        uint256 level = vm.parseJsonUint(json, ".start.agentLevel");
        if (level != 0) _registerAgent(agent, AgentRegistry.Level(level));
        vm.prank(attesterManager);
        changeRegistry.setAttester(attester, true);
    }

    function _checkOutcome(string memory json, string memory id) internal view {
        if (vm.parseJsonBool(json, ".expect.allSellsSucceed")) {
            assertFalse(sellFailed, string.concat(id, ": a sell failed"));
        }
        if (vm.parseJsonBool(json, ".expect.feeNeverAboveCap")) {
            assertFalse(capBroken, string.concat(id, ": fee above cap"));
        }
        uint256 maxShare = vm.parseJsonUint(json, ".expect.maxSniperShareOfPoolBps");
        if (maxShare != 0) {
            uint256 held;
            for (uint256 i; i < snipers.length; i++) {
                held += token.balanceOf(snipers[i]) - 1_000 ether;
            }
            assertLe(held * 10_000 / POOL_TOKENS, maxShare, string.concat(id, ": snipers took too much"));
        }
        uint256 finalMode = vm.parseJsonUint(json, ".expect.finalMode");
        if (finalMode != 255) assertEq(uint256(changeRegistry.modeOf(poolId)), finalMode, string.concat(id, ": mode"));
        uint256 laneLen = vm.parseJsonUint(json, ".expect.finalLaneLength");
        if (laneLen != 255) {
            assertEq(core.blocksIn(FluxCore.Lane.BeforeSwap).length, laneLen, string.concat(id, ": lane length"));
        }
    }

    /// @dev Runs one step as its actor. External so the runner can catch its revert.
    function doStep(Step memory s) external {
        require(msg.sender == address(this));
        address actor = _actor(s.actor);
        bytes32 k = keccak256(bytes(s.kind));

        if (k == keccak256("buy") || k == keccak256("sell")) {
            _swap(actor, k == keccak256("buy"), s.amount * 1e15);
        } else if (k == keccak256("fire")) {
            vm.prank(actor);
            playbookRegistry.fire(playbookId);
        } else if (k == keccak256("expire")) {
            vm.prank(actor);
            playbookRegistry.expire(playbookId);
        } else if (k == keccak256("proposeSetting")) {
            (address b, bytes32 setting) = _setting(s.target);
            vm.prank(actor);
            lastChange = changeRegistry.proposeSetting(poolId, b, setting, s.value);
        } else if (k == keccak256("proposeBlock")) {
            address b = _newBlock(s.target);
            named[keccak256(bytes(s.target))] = b;
            vm.prank(actor);
            lastChange = changeRegistry.proposeBlock(poolId, 0, 0, b, new bytes32[](0));
        } else if (k == keccak256("removeBlock")) {
            address gone = named[keccak256(bytes(s.target))];
            address[] memory lane = core.blocksIn(FluxCore.Lane.BeforeSwap);
            address[] memory next = new address[](lane.length - 1);
            uint256 j;
            for (uint256 i; i < lane.length; i++) {
                if (lane[i] != gone) next[j++] = lane[i];
            }
            vm.prank(actor);
            lastChange = changeRegistry.proposeLaneChange(poolId, 0, next, new bytes32[](0));
        } else if (k == keccak256("setMode")) {
            vm.prank(actor);
            lastChange = changeRegistry.setMode(poolId, uint8(s.value));
        } else if (k == keccak256("execute")) {
            vm.prank(actor);
            changeRegistry.execute(lastChange);
        } else if (k == keccak256("cancel")) {
            vm.prank(actor);
            changeRegistry.cancel(lastChange);
        } else if (k == keccak256("recordCheck")) {
            vm.prank(actor);
            changeRegistry.recordCheck(lastChange, bytes32(bytes(s.target)), s.value == 1);
        } else if (k == keccak256("passChecks")) {
            bytes32[] memory req = changeRegistry.requiredChecksOf(lastChange);
            for (uint256 i; i < req.length; i++) {
                vm.prank(actor);
                changeRegistry.recordCheck(lastChange, req[i], true);
            }
        } else if (k == keccak256("removeAgent")) {
            vm.prank(actor);
            agentRegistry.removeAgent(poolId);
        } else {
            revert(string.concat("unknown step kind: ", s.kind));
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _swap(address actor, bool isBuy, uint256 amount) internal {
        vm.recordLogs();
        bool zeroForOne = isBuy ? _buyDir() : !_buyDir();
        uint256 value = _quoteValue(isBuy, -int256(amount), actor);
        vm.prank(actor);
        swapRouter.swap{value: value}(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(actor)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, lastFee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
        if (lastFee > shell.activeFeeCap(poolId)) capBroken = true;
    }

    function _actor(string memory name) internal view returns (address) {
        if (_eq(name, "creator")) return creator;
        if (_eq(name, "agent")) return agent;
        if (_eq(name, "attester")) return attester;
        if (_eq(name, "anyone")) return anyone;
        return vm.addr(uint256(keccak256(bytes(name))));
    }

    function _fund(string memory name) internal {
        address a = _actor(name);
        if (funded[a] || a == creator || a == agent || a == attester || a == anyone) return;
        funded[a] = true;
        _fundQuote(a, 1_000 ether);
        token.transfer(a, 1_000 ether);
        vm.prank(a);
        token.approve(address(swapRouter), type(uint256).max);
        if (_startsWith(name, "sniper")) snipers.push(a);
    }

    function _blocksByName(string[] memory names) internal returns (address[] memory out) {
        out = new address[](names.length);
        for (uint256 i; i < names.length; i++) {
            out[i] = _blockByName(names[i]);
        }
    }

    function _blockByName(string memory name) internal returns (address) {
        if (_eq(name, "AntiSnipe")) return address(antiSnipe);
        if (_eq(name, "AdaptiveFee")) return address(adaptiveFee);
        if (_eq(name, "Light")) return address(new LightFeeBlock(500));
        revert(string.concat("unknown block: ", name));
    }

    function _newBlock(string memory name) internal returns (address) {
        if (!_startsWith(name, "Hostile:")) return _blockByName(name);
        string[10] memory modes = [
            "RejectAll",
            "MaxFee",
            "Revert",
            "BurnGas",
            "ShortReturn",
            "ReturnBomb",
            "OutOfRange",
            "TakeFunds",
            "SyncCurrency",
            "ReenterCore"
        ];
        for (uint256 i; i < modes.length; i++) {
            if (_eq(name, string.concat("Hostile:", modes[i]))) {
                HostileBlock h = new HostileBlock(manager);
                h.set(HostileBlock.Mode(i), address(core));
                return address(h);
            }
        }
        revert(string.concat("unknown hostile mode: ", name));
    }

    function _setting(string memory target) internal view returns (address, bytes32) {
        bytes memory t = bytes(target);
        uint256 dot;
        while (dot < t.length && t[dot] != ".") dot++;
        require(dot < t.length, "setting must be Block.name");
        bytes memory blockName = new bytes(dot);
        bytes memory settingName = new bytes(t.length - dot - 1);
        for (uint256 i; i < dot; i++) {
            blockName[i] = t[i];
        }
        for (uint256 i; i < settingName.length; i++) {
            settingName[i] = t[dot + 1 + i];
        }
        address b;
        if (_eq(string(blockName), "AntiSnipe")) b = address(antiSnipe);
        else if (_eq(string(blockName), "AdaptiveFee")) b = address(adaptiveFee);
        else if (_eq(string(blockName), "CreatorFee")) b = address(creatorFee);
        else revert(string.concat("unknown block: ", string(blockName)));
        return (b, bytes32(settingName));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory p = bytes(prefix);
        if (a.length < p.length) return false;
        for (uint256 i; i < p.length; i++) {
            if (a[i] != p[i]) return false;
        }
        return true;
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory x = bytes(suffix);
        if (a.length < x.length) return false;
        for (uint256 i; i < x.length; i++) {
            if (a[a.length - x.length + i] != x[i]) return false;
        }
        return true;
    }
}

/// @dev Native ETH quote, as on Ethereum (token = currency1).
contract ScenarioRunner is ScenarioRunnerBase {}

/// @dev WETH quote, the token sorting below it (token = currency0).
contract ScenarioRunnerTokenFirst is ScenarioRunnerBase {
    function _tokenFirst() internal pure override returns (bool) {
        return true;
    }
}
