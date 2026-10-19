// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {FluxShell} from "../src/shell/FluxShell.sol";
import {FluxCore} from "../src/core/FluxCore.sol";
import {CreatorFee} from "../src/blocks/CreatorFee.sol";
import {AntiSnipe, IShellLaunchInfo} from "../src/blocks/AntiSnipe.sol";
import {AdaptiveFee} from "../src/blocks/AdaptiveFee.sol";
import {AgentRegistry} from "../src/agents/AgentRegistry.sol";
import {ChangeRegistry} from "../src/gates/ChangeRegistry.sol";
import {PlaybookRegistry} from "../src/playbooks/PlaybookRegistry.sol";
import {IFluxShellGovernance} from "../src/interfaces/IFluxShellGovernance.sol";
import {IChangeQueue} from "../src/interfaces/IChangeQueue.sol";
import {FluxRevenueRouter, IFluxShellRevenue} from "../src/revenue/FluxRevenueRouter.sol";
import {FluxDeployer} from "../src/launch/FluxDeployer.sol";
import {FluxLauncher, IUsdFeed} from "../src/launch/FluxLauncher.sol";
import {FluxProtectedToken} from "../src/protection/FluxProtectedToken.sol";
import {FluxLaunchProtectionModule} from "../src/protection/FluxLaunchProtectionModule.sol";
import {FluxFeeVault} from "../src/protection/FluxFeeVault.sol";

/// @notice Builds FluxPool's protected launch (Programmable launch-protection v1) as an ordered list of
/// controller transactions, each pinned to a nonce, the way a Programmable Custom Launch Plan binds them.
/// Every address is derived from the controller and its starting nonce before anything is sent; the
/// shell's address is mined through FluxDeployer (CREATE2) so its low bits match its hook permissions.
///
/// The pool pairs native ETH with a FluxProtectedToken. Its protection module, normal-fee vault and
/// opening-tax vault are separate contracts; the launcher seeds the whole supply as locked, shell-held
/// liquidity, checks the $15,000 opening valuation against the fixed Chainlink feed and makes the
/// initial buy for the developer, all in the final step.
///
/// Used by script/FluxPlan.s.sol (writes the plan) and test/launch/LaunchPlan.t.sol (rehearses it).
abstract contract FluxPlanner is CommonBase, StdUtils {
    uint160 internal constant SHELL_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    int24 internal constant TICK_SPACING = 60;
    address internal constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    /// @notice Programmable's stamp transaction, counted in the plan's gas budget.
    uint256 internal constant STAMP_GAS = 6_000_000;
    uint256 internal constant STEPS = 16;

    struct Config {
        address controller;
        uint64 startNonce;
        address poolManager;
        // Addresses still to be decided are placeholders until launch day.
        address treasury; // protocol share of every ordinary pool
        address safe; // team Safe: our pool's creator (governance) and the revenue router's owner
        address operator; // runs buybacks
        address attesterManager;
        address developer; // receives the initial buy; exempt from the opening tax, capped like anyone
        address[6] exemptWallets; // up to six more opening-tax exemptions; zeros are unused slots
        address router; // the chain's canonical Universal Router (fixed by the policy)
        bytes32 routerCodeHash;
        address usdFeed; // the chain's canonical Chainlink native/USD feed (fixed by the policy)
        bytes32 usdFeedCodeHash;
        string name;
        string symbol;
        uint256 supply; // all of it is seeded as locked liquidity
        int24 startTick; // the opening price; must value the supply at $15,000 or more
        uint256 initialBuyEth; // msg.value of the launch step; at most 2% of supply after fees
        uint256 minTokensOut;
        uint16 creatorBuyFeeBps; // creator's normal buy fee, on the gross ETH leg (max 1000)
        uint16 creatorSellFeeBps; // creator's normal sell fee (max 1000)
        uint64 timelockDelay;
        uint8 launchMode;
        uint256 mcLow; // revenue router market-cap thresholds, in wei of ETH
        uint256 mcHigh;
        uint32 dropWindowBlocks;
        uint32 dropHoldBlocks;
        int24 dropTicks;
    }

    struct Addresses {
        address deployer;
        address creatorFee;
        address agentRegistry;
        address changeRegistry;
        address playbookRegistry;
        address coreImpl;
        address launcher;
        address shell;
        address antiSnipe;
        address adaptiveFee;
        address token;
        address module;
        address normalVault;
        address taxVault;
        address router;
        bytes32 shellSalt;
    }

    struct Step {
        string id;
        uint64 nonce;
        address to; // zero for a contract creation
        uint256 value;
        bytes data; // initcode for a creation, calldata otherwise
        address expected; // the contract a creation (or the CREATE2 call) must produce
        uint256 gasUsed; // filled by _simulate
        // The least execution gas the step succeeds with, found by search in _simulate. It can exceed
        // gasUsed: the shell refuses a swap unless enough gas is left to give the core its full allowance
        // (`InsufficientGasForCore`), gas a successful swap reserves but never spends.
        uint256 gasNeeded;
    }

    // ---------------------------------------------------------------------
    // Build
    // ---------------------------------------------------------------------

    function _addresses(Config memory c) internal pure returns (Addresses memory a) {
        a.deployer = _at(c, 0);
        a.creatorFee = _at(c, 1);
        a.agentRegistry = _at(c, 2);
        a.changeRegistry = _at(c, 3);
        a.playbookRegistry = _at(c, 4);
        a.coreImpl = _at(c, 5);
        a.launcher = _at(c, 6);
        // nonce 7 is the CREATE2 call that deploys the shell
        a.antiSnipe = _at(c, 8);
        a.adaptiveFee = _at(c, 9);
        a.token = _at(c, 10);
        a.module = _at(c, 11);
        a.normalVault = _at(c, 12);
        a.taxVault = _at(c, 13);
        a.router = _at(c, 14);
        (a.shell, a.shellSalt) = _mineShell(a.deployer, _shellInitcode(c, a));
    }

    function _plan(Config memory c) internal pure returns (Addresses memory a, Step[] memory s) {
        a = _addresses(c);
        s = new Step[](STEPS);
        _registrySteps(c, a, s);
        _platformSteps(c, a, s);
        _poolSteps(c, a, s);
    }

    /// @dev Steps 0-4: the CREATE2 deployer, CreatorFee and the three registries.
    function _registrySteps(Config memory c, Addresses memory a, Step[] memory s) internal pure {
        s[0] = _create(c, 0, "FluxDeployer", type(FluxDeployer).creationCode, a.deployer);
        s[1] = _create(c, 1, "CreatorFee", type(CreatorFee).creationCode, a.creatorFee);
        s[2] = _create(
            c,
            2,
            "AgentRegistry",
            abi.encodePacked(
                type(AgentRegistry).creationCode,
                abi.encode(IFluxShellGovernance(a.shell), IChangeQueue(a.changeRegistry), a.playbookRegistry)
            ),
            a.agentRegistry
        );
        s[3] = _create(
            c,
            3,
            "ChangeRegistry",
            abi.encodePacked(
                type(ChangeRegistry).creationCode,
                abi.encode(IFluxShellGovernance(a.shell), AgentRegistry(a.agentRegistry), c.attesterManager)
            ),
            a.changeRegistry
        );
        s[4] = _create(
            c,
            4,
            "PlaybookRegistry",
            abi.encodePacked(
                type(PlaybookRegistry).creationCode,
                abi.encode(IFluxShellGovernance(a.shell), AgentRegistry(a.agentRegistry))
            ),
            a.playbookRegistry
        );
    }

    /// @dev Steps 5-9: the core implementation, the launcher, the shell and the two blocks.
    function _platformSteps(Config memory c, Addresses memory a, Step[] memory s) internal pure {
        s[5] = _create(
            c,
            5,
            "FluxCore",
            abi.encodePacked(
                type(FluxCore).creationCode,
                abi.encode(IPoolManager(c.poolManager), a.shell, a.changeRegistry, a.playbookRegistry)
            ),
            a.coreImpl
        );
        s[6] = _create(c, 6, "FluxLauncher", _launcherInitcode(c, a), a.launcher);
        s[7] = Step({
            id: "FluxShell",
            nonce: c.startNonce + 7,
            to: a.deployer,
            value: 0,
            data: abi.encodeCall(FluxDeployer.deploy, (a.shellSalt, _shellInitcode(c, a))),
            expected: a.shell,
            gasUsed: 0,
            gasNeeded: 0
        });
        s[8] = _create(
            c,
            8,
            "AntiSnipe",
            abi.encodePacked(
                type(AntiSnipe).creationCode, abi.encode(IPoolManager(c.poolManager), IShellLaunchInfo(a.shell))
            ),
            a.antiSnipe
        );
        s[9] = _create(
            c,
            9,
            "AdaptiveFee",
            abi.encodePacked(
                type(AdaptiveFee).creationCode, abi.encode(IPoolManager(c.poolManager), IShellLaunchInfo(a.shell))
            ),
            a.adaptiveFee
        );
    }

    /// @dev Steps 10-15: our protected pool: the token, its protection module, its two vaults, the
    /// revenue router, and the atomic launch.
    function _poolSteps(Config memory c, Addresses memory a, Step[] memory s) internal pure {
        s[10] = _create(
            c,
            10,
            "FluxProtectedToken",
            abi.encodePacked(
                type(FluxProtectedToken).creationCode, abi.encode(c.name, c.symbol, c.supply, a.launcher, c.poolManager)
            ),
            a.token
        );
        s[11] = _create(c, 11, "FluxLaunchProtectionModule", _moduleInitcode(c, a), a.module);
        // The normal-fee vault pays the creator fee to the revenue router and the platform's 30 bps to the
        // platform; the opening-tax vault pays only the platform.
        s[12] = _create(c, 12, "NormalFeeVault", _vaultInitcode(c, a, a.router), a.normalVault);
        s[13] = _create(c, 13, "OpeningTaxVault", _vaultInitcode(c, a, PLATFORM_RECIPIENT), a.taxVault);
        s[14] = _create(c, 14, "FluxRevenueRouter", _routerInitcode(c, a), a.router);
        s[15] = Step({
            id: "LaunchProtected",
            nonce: c.startNonce + 15,
            to: a.launcher,
            value: c.initialBuyEth,
            data: abi.encodeCall(FluxLauncher.launchProtected, (_launchArgs(c, a))),
            expected: address(0),
            gasUsed: 0,
            gasNeeded: 0
        });
    }

    function _launchArgs(Config memory c, Addresses memory a)
        internal
        pure
        returns (FluxLauncher.ProtectedLaunchParams memory l)
    {
        l.token = FluxProtectedToken(a.token);
        l.module = FluxLaunchProtectionModule(a.module);
        l.normalFeeVault = FluxFeeVault(a.normalVault);
        l.openingTaxVault = FluxFeeVault(a.taxVault);
        l.setup.creator = c.safe;
        l.setup.creatorFeeRecipient = a.router;
        // A protected pool's LP fee is always zero: every fee is taken on the gross ETH leg.
        l.setup.timelockDelay = c.timelockDelay;
        l.setup.launchMode = c.launchMode;
        l.setup.normalBuyFeeBps = c.creatorBuyFeeBps;
        l.setup.normalSellFeeBps = c.creatorSellFeeBps;
        // Lanes start empty: a protected pool's fees are fixed by the policy, so fee blocks have nothing to
        // change. Blocks that only refuse buys can still be added later through the gates.
        l.beforeSwap = new address[](0);
        l.afterSwap = new address[](0);
        l.settings = new FluxCore.SettingInit[](0);
        l.startTick = c.startTick;
        l.minTokensOut = c.minTokensOut;
    }

    function _shellInitcode(Config memory c, Addresses memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(FluxShell).creationCode,
            abi.encode(
                IPoolManager(c.poolManager),
                a.launcher,
                a.creatorFee,
                a.agentRegistry,
                c.treasury,
                CurrencyLibrary.ADDRESS_ZERO // native ETH: the policy protects native-quoted pools only
            )
        );
    }

    function _launcherInitcode(Config memory c, Addresses memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(FluxLauncher).creationCode,
            abi.encode(
                IPoolManager(c.poolManager),
                FluxShell(payable(a.shell)),
                a.coreImpl,
                IUsdFeed(c.usdFeed),
                c.usdFeedCodeHash
            )
        );
    }

    function _moduleInitcode(Config memory c, Addresses memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(FluxLaunchProtectionModule).creationCode,
            abi.encode(
                a.shell,
                FluxProtectedToken(a.token),
                c.developer,
                c.router,
                c.routerCodeHash,
                c.creatorBuyFeeBps,
                c.exemptWallets
            )
        );
    }

    function _vaultInitcode(Config memory c, Addresses memory a, address creatorRecipient)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            type(FluxFeeVault).creationCode,
            abi.encode(IPoolManager(c.poolManager), a.shell, CurrencyLibrary.ADDRESS_ZERO, creatorRecipient)
        );
    }

    function _routerInitcode(Config memory c, Addresses memory a) internal pure returns (bytes memory) {
        FluxRevenueRouter.Config memory r;
        r.poolManager = IPoolManager(c.poolManager);
        r.shell = IFluxShellRevenue(a.shell);
        r.token = a.token;
        r.quote = CurrencyLibrary.ADDRESS_ZERO;
        r.tickSpacing = TICK_SPACING;
        r.safe = c.safe;
        r.operator = c.operator;
        r.mcLow = c.mcLow;
        r.mcHigh = c.mcHigh;
        r.dropWindowBlocks = c.dropWindowBlocks;
        r.dropHoldBlocks = c.dropHoldBlocks;
        r.dropTicks = c.dropTicks;
        r.normalFeeVault = a.normalVault;
        return abi.encodePacked(type(FluxRevenueRouter).creationCode, abi.encode(r));
    }

    /// @dev Hashes the initcode once and searches salts against the hash.
    function _mineShell(address deployer, bytes memory initcode) internal pure returns (address shell, bytes32 salt) {
        bytes32 codeHash = keccak256(initcode);
        for (uint256 i; i < 2_000_000; i++) {
            shell = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), codeHash)))));
            if (uint160(shell) & Hooks.ALL_HOOK_MASK == SHELL_FLAGS) return (shell, bytes32(i));
        }
        revert("no shell salt found");
    }

    function _create(Config memory c, uint64 offset, string memory id, bytes memory initcode, address expected)
        internal
        pure
        returns (Step memory)
    {
        return Step({
            id: id,
            nonce: c.startNonce + offset,
            to: address(0),
            value: 0,
            data: initcode,
            expected: expected,
            gasUsed: 0,
            gasNeeded: 0
        });
    }

    function _at(Config memory c, uint64 offset) internal pure returns (address) {
        return vm.computeCreateAddress(c.controller, c.startNonce + offset);
    }

    // ---------------------------------------------------------------------
    // Simulate: run every step as the controller at its pinned nonce
    // ---------------------------------------------------------------------

    function _simulate(Config memory c, Step[] memory s) internal {
        vm.deal(c.controller, c.controller.balance + c.initialBuyEth + 1 ether);
        for (uint256 i; i < s.length; i++) {
            if (s[i].to != address(0)) s[i].gasNeeded = _leastGas(c, s[i]);
            vm.setNonce(c.controller, s[i].nonce);
            uint256 g = gasleft();
            address made;
            if (s[i].to == address(0)) {
                bytes memory code = s[i].data;
                vm.prank(c.controller);
                assembly ("memory-safe") {
                    made := create(0, add(code, 0x20), mload(code))
                }
                require(made != address(0), string.concat("create failed: ", s[i].id));
            } else {
                vm.prank(c.controller);
                (bool ok, bytes memory ret) = s[i].to.call{value: s[i].value}(s[i].data);
                require(ok, string.concat("call failed: ", s[i].id));
                if (s[i].expected != address(0)) made = abi.decode(ret, (address));
            }
            s[i].gasUsed = g - gasleft();
            if (s[i].to == address(0)) s[i].gasNeeded = s[i].gasUsed;
            if (s[i].expected != address(0)) require(made == s[i].expected, string.concat("address drift: ", s[i].id));
        }
    }

    /// @dev The least gas a call step succeeds with, by binary search on a snapshot that is rolled back
    /// after every try, so the plan's state is untouched.
    function _leastGas(Config memory c, Step memory s) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        uint256 lo = 21_000;
        uint256 hi = 30_000_000;
        require(_tryCall(c, s, hi, snap), string.concat("call failed: ", s.id));
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_tryCall(c, s, mid, snap)) hi = mid;
            else lo = mid + 1;
        }
        vm.revertToStateAndDelete(snap);
        return hi;
    }

    function _tryCall(Config memory c, Step memory s, uint256 gas, uint256 snap) internal returns (bool ok) {
        vm.setNonce(c.controller, s.nonce);
        vm.prank(c.controller);
        (ok,) = s.to.call{value: s.value, gas: gas}(s.data);
        vm.revertToState(snap);
    }

    /// @notice Per-step gas limit: the least execution gas the step succeeds with in simulation (never less
    /// than what it used) plus intrinsic and calldata gas, with a 20% margin. Confirm each limit on a
    /// mainnet fork before binding the plan.
    function _gasLimit(Step memory s) internal pure returns (uint256) {
        uint256 calldataGas;
        bytes memory d = s.data;
        for (uint256 i; i < d.length; i++) {
            calldataGas += d[i] == 0 ? 4 : 16;
        }
        uint256 intrinsic = 21_000 + calldataGas + (s.to == address(0) ? 32_000 + 2 * ((d.length + 31) / 32) : 0);
        uint256 exec = s.gasNeeded > s.gasUsed ? s.gasNeeded : s.gasUsed;
        return (exec + intrinsic) * 12 / 10;
    }

    function _totalGas(Step[] memory s) internal pure returns (uint256 total) {
        for (uint256 i; i < s.length; i++) {
            total += _gasLimit(s[i]);
        }
        total += STAMP_GAS * 12 / 10;
    }
}
