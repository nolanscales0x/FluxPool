// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FluxPlanScript} from "./FluxPlan.s.sol";
import {FluxLauncher} from "../src/launch/FluxLauncher.sol";
import {FluxGraphInitializer} from "../src/launch/FluxGraphInitializer.sol";
import {CreatorFee} from "../src/blocks/CreatorFee.sol";
import {AntiSnipe, IShellLaunchInfo} from "../src/blocks/AntiSnipe.sol";
import {AdaptiveFee} from "../src/blocks/AdaptiveFee.sol";
import {AgentRegistry} from "../src/agents/AgentRegistry.sol";
import {ChangeRegistry} from "../src/gates/ChangeRegistry.sol";
import {PlaybookRegistry} from "../src/playbooks/PlaybookRegistry.sol";
import {FluxCore} from "../src/core/FluxCore.sol";
import {IFluxShellGovernance} from "../src/interfaces/IFluxShellGovernance.sol";
import {IChangeQueue} from "../src/interfaces/IChangeQueue.sol";

/// @notice FluxPool's launch through Programmable's Ethereum Custom Launch API (V3), in two phases.
///
/// Phase 1, the 9 shared contracts, deployed from the controller at pinned nonces: CreatorFee, the
/// three registries, the core implementation, the launcher, the two blocks and the revenue router.
/// Their constructor arguments are exactly those of the 16-step plan, except that the shell, the token
/// and the normal fee vault are the addresses Programmable's graph factory will give them (V3_SHELL,
/// V3_TOKEN, V3_MODULE, V3_NORMAL_VAULT, V3_TAX_VAULT, from `programmable-launch pack`).
///
/// Phase 2, the V3 graph, one Router transaction: the token, the shell (the hook), the protection
/// module, both fee vaults (their constructors require the shell and token to exist already) and
/// FluxGraphInitializer, whose `launch` call is written here as `initializerCalldata`.
///
/// A CREATE address depends only on the controller and the nonce, never on constructor arguments, so
/// the shared contracts can name the graph's addresses and the graph can name theirs without a cycle.
///
/// It never signs or broadcasts.
///
///   PLAN_CONFIG=deploy/out/mainnet-config.json V3_SHELL=0x… V3_TOKEN=0x… \
///     forge script script/FluxPlanV3.s.sol --sig 'runV3()' --fork-url $RPC_URL
contract FluxPlanV3Script is FluxPlanScript {
    uint256 internal constant PHASE1_STEPS = 9;

    function runV3() external {
        Config memory c = _load(vm.readFile(vm.envOr("PLAN_CONFIG", string(CONFIG))));
        if (c.routerCodeHash == bytes32(0)) c.routerCodeHash = c.router.codehash;
        if (c.usdFeedCodeHash == bytes32(0)) c.usdFeedCodeHash = c.usdFeed.codehash;
        require(c.router.code.length != 0, "canonical router has no code: fork Ethereum mainnet");
        require(c.usdFeed.code.length != 0, "Chainlink feed has no code: fork Ethereum mainnet");
        _requireNoPlaceholders(c);

        Addresses memory a = _addressesV3(c);
        a.shell = vm.envAddress("V3_SHELL");
        a.token = vm.envAddress("V3_TOKEN");
        a.module = vm.envAddress("V3_MODULE");
        a.normalVault = vm.envAddress("V3_NORMAL_VAULT");
        a.taxVault = vm.envAddress("V3_TAX_VAULT");
        Step[] memory s = _phase1(c, a);
        _simulate(c, s);
        _writeV3(c, a, s);
    }

    function _addressesV3(Config memory c) internal pure returns (Addresses memory a) {
        a.creatorFee = _at(c, 0);
        a.agentRegistry = _at(c, 1);
        a.changeRegistry = _at(c, 2);
        a.playbookRegistry = _at(c, 3);
        a.coreImpl = _at(c, 4);
        a.launcher = _at(c, 5);
        a.antiSnipe = _at(c, 6);
        a.adaptiveFee = _at(c, 7);
        a.router = _at(c, 8);
    }

    function _phase1(Config memory c, Addresses memory a) internal pure returns (Step[] memory s) {
        s = new Step[](PHASE1_STEPS);
        s[0] = _create(c, 0, "CreatorFee", type(CreatorFee).creationCode, a.creatorFee);
        s[1] = _create(
            c,
            1,
            "AgentRegistry",
            abi.encodePacked(
                type(AgentRegistry).creationCode,
                abi.encode(IFluxShellGovernance(a.shell), IChangeQueue(a.changeRegistry), a.playbookRegistry)
            ),
            a.agentRegistry
        );
        s[2] = _create(
            c,
            2,
            "ChangeRegistry",
            abi.encodePacked(
                type(ChangeRegistry).creationCode,
                abi.encode(IFluxShellGovernance(a.shell), AgentRegistry(a.agentRegistry), c.attesterManager)
            ),
            a.changeRegistry
        );
        s[3] = _create(
            c,
            3,
            "PlaybookRegistry",
            abi.encodePacked(
                type(PlaybookRegistry).creationCode,
                abi.encode(IFluxShellGovernance(a.shell), AgentRegistry(a.agentRegistry))
            ),
            a.playbookRegistry
        );
        s[4] = _create(
            c,
            4,
            "FluxCore",
            abi.encodePacked(
                type(FluxCore).creationCode,
                abi.encode(IPoolManager(c.poolManager), a.shell, a.changeRegistry, a.playbookRegistry)
            ),
            a.coreImpl
        );
        s[5] = _create(c, 5, "FluxLauncher", _launcherInitcode(c, a), a.launcher);
        s[6] = _create(
            c,
            6,
            "AntiSnipe",
            abi.encodePacked(
                type(AntiSnipe).creationCode, abi.encode(IPoolManager(c.poolManager), IShellLaunchInfo(a.shell))
            ),
            a.antiSnipe
        );
        s[7] = _create(
            c,
            7,
            "AdaptiveFee",
            abi.encodePacked(
                type(AdaptiveFee).creationCode, abi.encode(IPoolManager(c.poolManager), IShellLaunchInfo(a.shell))
            ),
            a.adaptiveFee
        );
        s[8] = _create(c, 8, "FluxRevenueRouter", _routerInitcode(c, a), a.router);
    }

    function _writeV3(Config memory c, Addresses memory a, Step[] memory s) internal {
        string memory steps = "steps";
        string memory last;
        uint256 total;
        for (uint256 i; i < s.length; i++) {
            string memory k = string.concat("step", vm.toString(i));
            vm.serializeString(k, "id", s[i].id);
            vm.serializeUint(k, "nonce", s[i].nonce);
            vm.serializeAddress(k, "to", s[i].to);
            vm.serializeUint(k, "value", s[i].value);
            vm.serializeAddress(k, "expectedAddress", s[i].expected);
            vm.serializeUint(k, "gasUsed", s[i].gasUsed);
            vm.serializeUint(k, "gasLimit", _gasLimit(s[i]));
            string memory obj = vm.serializeBytes(k, "data", s[i].data);
            last = vm.serializeString(steps, vm.toString(i), obj);
            total += _gasLimit(s[i]);
        }

        string memory g = "graph";
        vm.serializeAddress(g, "shell", a.shell);
        vm.serializeAddress(g, "token", a.token);
        vm.serializeAddress(g, "launcher", a.launcher);
        vm.serializeAddress(g, "creatorFee", a.creatorFee);
        vm.serializeAddress(g, "agentRegistry", a.agentRegistry);
        vm.serializeAddress(g, "module", a.module);
        vm.serializeAddress(g, "normalFeeVault", a.normalVault);
        vm.serializeAddress(g, "openingTaxVault", a.taxVault);
        vm.serializeAddress(g, "revenueRouter", a.router);
        vm.serializeBytes32(g, "routerCodeHash", c.routerCodeHash);
        vm.serializeUint(g, "initialBuyWei", c.initialBuyEth);
        string memory graph = vm.serializeBytes(
            g, "initializerCalldata", abi.encodeCall(FluxGraphInitializer.launch, (_launchArgs(c, a)))
        );

        string memory root = "root";
        vm.serializeString(root, "phase1", last);
        vm.serializeString(root, "graph", graph);
        vm.serializeAddress(root, "controller", c.controller);
        vm.serializeUint(root, "startNonce", c.startNonce);
        vm.serializeUint(root, "chainId", block.chainid);
        string memory out = vm.serializeUint(root, "phase1GasLimit", total);
        vm.writeJson(out, vm.envOr("PLAN_OUT", string("deploy/out/plan-v3.json")));
    }
}
