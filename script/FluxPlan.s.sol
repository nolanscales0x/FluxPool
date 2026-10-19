// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FluxPlanner} from "./FluxPlanner.sol";
import {MockUniversalRouter, MockUsdFeed} from "../test/protection/ProtectedLaunch.t.sol";

/// @notice Builds FluxPool's protected launch plan from deploy/fluxpool-token.config.json, simulates
/// every step as the controller at its pinned nonce, and writes deploy/out/plan.json: each step's nonce,
/// target, value, calldata or initcode, expected address and gas limit, plus the total gas budget
/// including Programmable's stamp.
///
/// It never signs or broadcasts. Steps are signed one by one through Programmable's launch flow.
///
///   Real plan (needs an Ethereum mainnet RPC, every placeholder filled):
///     forge script script/FluxPlan.s.sol --fork-url $RPC_URL
///   Dry run (simulated chain 1, local PoolManager, mocks at the canonical router and feed addresses,
///   placeholders replaced with labelled dry-run values):
///     DRY_RUN=true forge script script/FluxPlan.s.sol
contract FluxPlanScript is Script, FluxPlanner {
    string internal constant CONFIG = "deploy/fluxpool-token.config.json";
    string internal constant OUT = "deploy/out/plan.json";

    function run() external {
        bool dryRun = vm.envOr("DRY_RUN", false);
        // PLAN_CONFIG / PLAN_OUT point a rehearsal at its own files (for example a local mainnet fork).
        Config memory c = _load(vm.readFile(vm.envOr("PLAN_CONFIG", string(CONFIG))));
        if (dryRun) _dryRunChain(c);
        // The canonical router and feed are fixed by the policy; their code hashes are read from the chain.
        if (c.routerCodeHash == bytes32(0)) c.routerCodeHash = c.router.codehash;
        if (c.usdFeedCodeHash == bytes32(0)) c.usdFeedCodeHash = c.usdFeed.codehash;
        require(c.router.code.length != 0, "canonical router has no code: fork Ethereum mainnet");
        require(c.usdFeed.code.length != 0, "Chainlink feed has no code: fork Ethereum mainnet");
        _requireNoPlaceholders(c);

        (Addresses memory a, Step[] memory s) = _plan(c);
        _simulate(c, s);
        _write(c, a, s, dryRun);
    }

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------

    function _load(string memory j) internal pure returns (Config memory c) {
        c.controller = vm.parseJsonAddress(j, ".controller");
        c.startNonce = uint64(vm.parseJsonUint(j, ".startNonce"));
        c.poolManager = vm.parseJsonAddress(j, ".poolManager");
        c.treasury = vm.parseJsonAddress(j, ".treasury");
        c.safe = vm.parseJsonAddress(j, ".safe");
        c.operator = vm.parseJsonAddress(j, ".operator");
        c.attesterManager = vm.parseJsonAddress(j, ".attesterManager");
        c.developer = vm.parseJsonAddress(j, ".developer");
        address[] memory ex = vm.parseJsonAddressArray(j, ".exemptWallets");
        require(ex.length <= 6, "at most six exempt wallets");
        for (uint256 i; i < ex.length; i++) {
            c.exemptWallets[i] = ex[i];
        }
        c.router = vm.parseJsonAddress(j, ".router");
        c.usdFeed = vm.parseJsonAddress(j, ".usdFeed");
        c.name = vm.parseJsonString(j, ".name");
        c.symbol = vm.parseJsonString(j, ".symbol");
        c.supply = vm.parseJsonUint(j, ".supply");
        c.startTick = int24(vm.parseJsonInt(j, ".startTick"));
        c.initialBuyEth = vm.parseJsonUint(j, ".initialBuyEth");
        c.minTokensOut = vm.parseJsonUint(j, ".minTokensOut");
        c.creatorBuyFeeBps = uint16(vm.parseJsonUint(j, ".creatorBuyFeeBps"));
        c.creatorSellFeeBps = uint16(vm.parseJsonUint(j, ".creatorSellFeeBps"));
        c.timelockDelay = uint64(vm.parseJsonUint(j, ".timelockDelay"));
        c.launchMode = uint8(vm.parseJsonUint(j, ".launchMode"));
        c.mcLow = vm.parseJsonUint(j, ".mcLow");
        c.mcHigh = vm.parseJsonUint(j, ".mcHigh");
        c.dropWindowBlocks = uint32(vm.parseJsonUint(j, ".dropWindowBlocks"));
        c.dropHoldBlocks = uint32(vm.parseJsonUint(j, ".dropHoldBlocks"));
        c.dropTicks = int24(vm.parseJsonInt(j, ".dropTicks"));
    }

    /// @dev A dry run simulates chain 1 locally: a fresh PoolManager, and mocks of the canonical Universal
    /// Router and the Chainlink feed placed at their real addresses, so the policy's checks run unchanged.
    function _dryRunChain(Config memory c) internal {
        vm.chainId(1);
        if (c.poolManager.code.length == 0) c.poolManager = address(new PoolManager(_label("dry-run pm owner")));
        vm.etch(c.router, address(new MockUniversalRouter(IPoolManager(c.poolManager))).code);
        vm.etch(c.usdFeed, address(new MockUsdFeed()).code);
        MockUsdFeed(c.usdFeed).set(3_000e8, block.timestamp);
        c.routerCodeHash = c.router.codehash;
        c.usdFeedCodeHash = c.usdFeed.codehash;
        if (c.controller == address(0)) c.controller = _label("dry-run controller");
        if (c.treasury == address(0)) c.treasury = _label("dry-run treasury");
        if (c.safe == address(0)) c.safe = _label("dry-run safe");
        if (c.operator == address(0)) c.operator = _label("dry-run operator");
        if (c.attesterManager == address(0)) c.attesterManager = _label("dry-run attester manager");
        if (c.developer == address(0)) c.developer = _label("dry-run developer");
        if (_isTbd(c.name)) c.name = "Dry Run Token";
        if (_isTbd(c.symbol)) c.symbol = "DRYRUN";
        if (c.supply == 0) c.supply = 1_000_000_000 ether;
        if (c.startTick == 0) c.startTick = 180_000;
        if (c.initialBuyEth == 0) c.initialBuyEth = 0.01 ether;
        if (c.mcLow == 0) c.mcLow = 10 ether;
        if (c.mcHigh == 0) c.mcHigh = 1_000 ether;
    }

    function _requireNoPlaceholders(Config memory c) internal pure {
        require(c.controller != address(0), "placeholder: controller");
        require(c.treasury != address(0), "placeholder: treasury");
        require(c.safe != address(0), "placeholder: safe");
        require(c.operator != address(0), "placeholder: operator");
        require(c.attesterManager != address(0), "placeholder: attesterManager");
        require(c.developer != address(0), "placeholder: developer");
        require(!_isTbd(c.name) && !_isTbd(c.symbol), "placeholder: name/symbol");
        require(c.supply != 0, "placeholder: supply");
        require(c.startTick != 0, "placeholder: startTick (opening price; $15k FDV floor)");
        require(c.initialBuyEth != 0, "placeholder: initialBuyEth (Programmable requires an initial buy)");
        require(c.mcLow != 0 && c.mcHigh > c.mcLow, "placeholder: mcLow/mcHigh");
    }

    function _isTbd(string memory s) internal pure returns (bool) {
        return keccak256(bytes(s)) == keccak256("TBD") || bytes(s).length == 0;
    }

    function _label(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }

    // ---------------------------------------------------------------------
    // Output
    // ---------------------------------------------------------------------

    function _write(Config memory c, Addresses memory a, Step[] memory s, bool dryRun) internal {
        string memory steps = "steps";
        string memory last;
        for (uint256 i; i < s.length; i++) {
            string memory k = string.concat("step", vm.toString(i));
            vm.serializeString(k, "id", s[i].id);
            vm.serializeUint(k, "nonce", s[i].nonce);
            vm.serializeAddress(k, "to", s[i].to);
            vm.serializeUint(k, "value", s[i].value);
            vm.serializeAddress(k, "expectedAddress", s[i].expected);
            vm.serializeUint(k, "gasUsed", s[i].gasUsed);
            vm.serializeUint(k, "gasNeeded", s[i].gasNeeded);
            vm.serializeUint(k, "gasLimit", _gasLimit(s[i]));
            string memory obj = vm.serializeBytes(k, "data", s[i].data);
            last = vm.serializeString(steps, vm.toString(i), obj);
        }
        string memory root = "plan";
        vm.serializeBool(root, "dryRun", dryRun);
        vm.serializeAddress(root, "controller", c.controller);
        vm.serializeUint(root, "startNonce", c.startNonce);
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "shell", a.shell);
        vm.serializeAddress(root, "token", a.token);
        vm.serializeAddress(root, "protectionModule", a.module);
        vm.serializeAddress(root, "normalFeeVault", a.normalVault);
        vm.serializeAddress(root, "openingTaxVault", a.taxVault);
        vm.serializeBytes32(root, "shellSalt", a.shellSalt);
        vm.serializeUint(root, "stampGas", STAMP_GAS);
        vm.serializeUint(root, "maxTotalGas", _totalGas(s));
        string memory json = vm.serializeString(root, "steps", last);
        vm.createDir("deploy/out", true);
        vm.writeJson(json, vm.envOr("PLAN_OUT", string(OUT)));
    }
}
