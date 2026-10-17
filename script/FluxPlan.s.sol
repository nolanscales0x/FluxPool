// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {FluxPlanner} from "./FluxPlanner.sol";

/// @notice Builds FluxPool's launch plan from deploy/fluxpool-token.config.json, simulates every step
/// as the controller at its pinned nonce, and writes deploy/out/plan.json: each step's nonce, target,
/// value, calldata or initcode, expected address and gas limit, plus the total gas budget including
/// Programmable's stamp.
///
/// It never signs or broadcasts. Steps are signed one by one through Programmable's launch flow.
///
///   Real plan (needs an Ethereum mainnet RPC, every placeholder filled):
///     forge script script/FluxPlan.s.sol --fork-url $RPC_URL
///   Dry run (local PoolManager, placeholders replaced with labelled dry-run values):
///     DRY_RUN=true forge script script/FluxPlan.s.sol
contract FluxPlanScript is Script, FluxPlanner {
    string internal constant CONFIG = "deploy/fluxpool-token.config.json";
    string internal constant OUT = "deploy/out/plan.json";

    function run() external {
        bool dryRun = vm.envOr("DRY_RUN", false);
        Config memory c = _load(vm.readFile(CONFIG));
        if (dryRun) _fillDryRun(c);
        if (c.poolManager.code.length == 0) {
            require(dryRun, "PoolManager has no code: run with --fork-url pointing at Ethereum mainnet");
            PoolManager pm = new PoolManager(_label("dry-run pool manager owner"));
            c.poolManager = address(pm);
        }
        // quote = address(0) is native ETH (the default). Any other quote is an ERC-20 such as WETH.
        if (c.quote != address(0) && c.quote.code.length == 0) {
            require(dryRun, "quote has no code: use address(0) for native ETH, or a deployed WETH address");
            c.quote = address(new WETH());
        }

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
        c.quote = vm.parseJsonAddress(j, ".quote");
        c.treasury = vm.parseJsonAddress(j, ".treasury");
        c.safe = vm.parseJsonAddress(j, ".safe");
        c.operator = vm.parseJsonAddress(j, ".operator");
        c.attesterManager = vm.parseJsonAddress(j, ".attesterManager");
        c.buyRecipient = vm.parseJsonAddress(j, ".buyRecipient");
        c.name = vm.parseJsonString(j, ".name");
        c.symbol = vm.parseJsonString(j, ".symbol");
        c.supply = vm.parseJsonUint(j, ".supply");
        c.liquidityQuote = vm.parseJsonUint(j, ".liquidityQuote");
        c.liquidityTokens = vm.parseJsonUint(j, ".liquidityTokens");
        c.initialBuyQuote = vm.parseJsonUint(j, ".initialBuyQuote");
        c.minTokensOut = vm.parseJsonUint(j, ".minTokensOut");
        c.launchWindow = uint32(vm.parseJsonUint(j, ".launchWindow"));
        c.baseFee = uint24(vm.parseJsonUint(j, ".baseFee"));
        c.feeCap = uint24(vm.parseJsonUint(j, ".feeCap"));
        c.launchFeeCap = uint24(vm.parseJsonUint(j, ".launchFeeCap"));
        c.openingFee = uint24(vm.parseJsonUint(j, ".openingFee"));
        c.creatorShareBps = uint16(vm.parseJsonUint(j, ".creatorShareBps"));
        c.timelockDelay = uint64(vm.parseJsonUint(j, ".timelockDelay"));
        c.launchMode = uint8(vm.parseJsonUint(j, ".launchMode"));
        c.mcLow = vm.parseJsonUint(j, ".mcLow");
        c.mcHigh = vm.parseJsonUint(j, ".mcHigh");
        c.dropWindowBlocks = uint32(vm.parseJsonUint(j, ".dropWindowBlocks"));
        c.dropHoldBlocks = uint32(vm.parseJsonUint(j, ".dropHoldBlocks"));
        c.dropTicks = int24(vm.parseJsonInt(j, ".dropTicks"));
    }

    function _fillDryRun(Config memory c) internal pure {
        if (c.controller == address(0)) c.controller = _label("dry-run controller");
        if (c.treasury == address(0)) c.treasury = _label("dry-run treasury");
        if (c.safe == address(0)) c.safe = _label("dry-run safe");
        if (c.operator == address(0)) c.operator = _label("dry-run operator");
        if (c.attesterManager == address(0)) c.attesterManager = _label("dry-run attester manager");
        if (c.buyRecipient == address(0)) c.buyRecipient = _label("dry-run launch wallet");
        if (_isTbd(c.name)) c.name = "Dry Run Token";
        if (_isTbd(c.symbol)) c.symbol = "DRYRUN";
        if (c.supply == 0) c.supply = 1_000_000_000 ether;
        if (c.liquidityQuote == 0) c.liquidityQuote = 10 ether;
        if (c.liquidityTokens == 0) c.liquidityTokens = 100_000_000 ether;
        if (c.initialBuyQuote == 0) c.initialBuyQuote = 0.01 ether;
        if (c.mcLow == 0) c.mcLow = 50 ether;
        if (c.mcHigh == 0) c.mcHigh = 5_000 ether;
    }

    function _requireNoPlaceholders(Config memory c) internal pure {
        require(c.controller != address(0), "placeholder: controller");
        require(c.treasury != address(0), "placeholder: treasury");
        require(c.safe != address(0), "placeholder: safe");
        require(c.operator != address(0), "placeholder: operator");
        require(c.attesterManager != address(0), "placeholder: attesterManager");
        require(c.buyRecipient != address(0), "placeholder: buyRecipient");
        require(!_isTbd(c.name) && !_isTbd(c.symbol), "placeholder: name/symbol");
        require(c.supply != 0 && c.liquidityQuote != 0 && c.liquidityTokens != 0, "placeholder: supply/liquidity");
        require(c.initialBuyQuote != 0, "placeholder: initialBuyQuote (Programmable requires an initial buy)");
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
        vm.serializeBytes32(root, "shellSalt", a.shellSalt);
        vm.serializeUint(root, "stampGas", STAMP_GAS);
        vm.serializeUint(root, "maxTotalGas", _totalGas(s));
        string memory json = vm.serializeString(root, "steps", last);
        vm.createDir("deploy/out", true);
        vm.writeJson(json, OUT);
    }
}
