// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

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
import {FluxToken} from "../src/launch/FluxToken.sol";
import {FluxDeployer} from "../src/launch/FluxDeployer.sol";
import {FluxLauncher} from "../src/launch/FluxLauncher.sol";

/// @notice Builds FluxPool's launch as an ordered list of controller transactions, each pinned to a
/// nonce, the way a Programmable Custom Launch Plan binds them. Every address is derived from the
/// controller and its starting nonce before anything is sent; the shell's address is mined through
/// FluxDeployer (CREATE2) so its low bits match its hook permissions.
///
/// Used by script/FluxPlan.s.sol (writes the plan) and test/launch/LaunchPlan.t.sol (rehearses it).
abstract contract FluxPlanner is CommonBase, StdUtils {
    uint160 internal constant SHELL_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    int24 internal constant TICK_SPACING = 60;
    /// @notice Programmable's stamp transaction, counted in the plan's gas budget.
    uint256 internal constant STAMP_GAS = 6_000_000;
    uint256 internal constant STEPS = 14;

    struct Config {
        address controller;
        uint64 startNonce;
        address poolManager;
        address quote; // the pool's quote currency: address(0) for native ETH (Ethereum), or WETH
        // Addresses still to be decided are placeholders until launch day.
        address treasury; // protocol share of every pool
        address safe; // team Safe: our pool's creator and the router's owner
        address operator; // runs buybacks
        address attesterManager;
        address buyRecipient; // receives the initial buy
        string name;
        string symbol;
        uint256 supply;
        uint256 liquidityQuote; // funded as ETH in the launch transaction (wrapped by the launcher if WETH)
        uint256 liquidityTokens;
        uint256 initialBuyQuote;
        uint256 minTokensOut;
        uint32 launchWindow;
        uint24 baseFee;
        uint24 feeCap;
        uint24 launchFeeCap;
        uint24 openingFee;
        uint16 creatorShareBps;
        uint64 timelockDelay;
        uint8 launchMode;
        uint256 mcLow;
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
        a.router = _at(c, 11);
        (a.shell, a.shellSalt) = _mineShell(a.deployer, _shellInitcode(c, a));
    }

    function _plan(Config memory c) internal pure returns (Addresses memory a, Step[] memory s) {
        a = _addresses(c);
        s = new Step[](STEPS);
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
        s[6] = _create(
            c,
            6,
            "FluxLauncher",
            abi.encodePacked(
                type(FluxLauncher).creationCode,
                abi.encode(IPoolManager(c.poolManager), FluxShell(payable(a.shell)), a.coreImpl)
            ),
            a.launcher
        );
        s[7] = Step({
            id: "FluxShell",
            nonce: c.startNonce + 7,
            to: a.deployer,
            value: 0,
            data: abi.encodeCall(FluxDeployer.deploy, (a.shellSalt, _shellInitcode(c, a))),
            expected: a.shell,
            gasUsed: 0
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
        s[10] = _create(
            c,
            10,
            "FluxToken",
            abi.encodePacked(type(FluxToken).creationCode, abi.encode(c.name, c.symbol, c.supply, c.controller)),
            a.token
        );
        s[11] = _create(c, 11, "FluxRevenueRouter", _routerInitcode(c, a), a.router);
        s[12] = Step({
            id: "ApproveLauncher",
            nonce: c.startNonce + 12,
            to: a.token,
            value: 0,
            data: abi.encodeWithSignature("approve(address,uint256)", a.launcher, c.liquidityTokens),
            expected: address(0),
            gasUsed: 0
        });
        s[13] = Step({
            id: "Launch",
            nonce: c.startNonce + 13,
            to: a.launcher,
            value: c.liquidityQuote + c.initialBuyQuote,
            data: abi.encodeCall(FluxLauncher.launch, (_launchArgs(c, a))),
            expected: address(0),
            gasUsed: 0
        });
    }

    /// @dev Starting price and full-range liquidity for the configured amounts, in the pool's sorted order.
    function _poolMath(Config memory c, Addresses memory a)
        internal
        pure
        returns (uint160 sqrtP, int24 lo, int24 hi, uint128 liq)
    {
        bool tokenIs0 = a.token < c.quote;
        (uint256 amount0, uint256 amount1) =
            tokenIs0 ? (c.liquidityTokens, c.liquidityQuote) : (c.liquidityQuote, c.liquidityTokens);
        sqrtP = _sqrtPrice(amount0, amount1);
        lo = TickMath.minUsableTick(TICK_SPACING);
        hi = TickMath.maxUsableTick(TICK_SPACING);
        liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), amount0, amount1
        );
        // A hair under the maximum, so rounding inside the PoolManager never needs more than we send.
        liq = uint128(uint256(liq) * 9_999 / 10_000);
    }

    function _launchArgs(Config memory c, Addresses memory a) internal pure returns (FluxLauncher.Launch memory l) {
        (uint160 sqrtP, int24 lo, int24 hi, uint128 liq) = _poolMath(c, a);

        address[] memory before = new address[](2);
        before[0] = a.antiSnipe;
        before[1] = a.adaptiveFee;
        address[] memory afterLane = new address[](1);
        afterLane[0] = a.adaptiveFee;
        FluxCore.SettingInit[] memory settings = new FluxCore.SettingInit[](2);
        settings[0] = FluxCore.SettingInit(a.antiSnipe, "openingFee", c.openingFee);
        settings[1] = FluxCore.SettingInit(a.creatorFee, "creatorShareBps", c.creatorShareBps);

        l = FluxLauncher.Launch({
            token: a.token,
            tickSpacing: TICK_SPACING,
            sqrtPriceX96: sqrtP,
            setup: FluxShell.PoolSetup({
                sqrtPriceX96: 0,
                core: address(0),
                token: address(0),
                creator: c.safe,
                creatorFeeRecipient: a.router,
                baseFee: c.baseFee,
                feeCap: c.feeCap,
                launchFeeCap: c.launchFeeCap,
                launchWindow: c.launchWindow,
                timelockDelay: c.timelockDelay,
                lockType: FluxShell.LockType.Locked,
                unlockAt: 0,
                launchMode: c.launchMode
            }),
            beforeSwap: before,
            afterSwap: afterLane,
            settings: settings,
            tickLower: lo,
            tickUpper: hi,
            liquidity: liq,
            tokenAmount: c.liquidityTokens,
            liquidityQuote: c.liquidityQuote,
            initialBuyQuote: c.initialBuyQuote,
            minTokensOut: c.minTokensOut,
            buyRecipient: c.buyRecipient
        });
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
                Currency.wrap(c.quote)
            )
        );
    }

    function _routerInitcode(Config memory c, Addresses memory a) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(FluxRevenueRouter).creationCode,
            abi.encode(
                FluxRevenueRouter.Config({
                    poolManager: IPoolManager(c.poolManager),
                    shell: IFluxShellRevenue(a.shell),
                    token: a.token,
                    quote: Currency.wrap(c.quote),
                    tickSpacing: TICK_SPACING,
                    safe: c.safe,
                    operator: c.operator,
                    mcLow: c.mcLow,
                    mcHigh: c.mcHigh,
                    dropWindowBlocks: c.dropWindowBlocks,
                    dropHoldBlocks: c.dropHoldBlocks,
                    dropTicks: c.dropTicks
                })
            )
        );
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

    /// @dev sqrtPriceX96 for a pool holding `amount0` of currency0 and `amount1` of currency1.
    function _sqrtPrice(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        return uint160(Math.sqrt(FullMath.mulDiv(amount1, 1 << 192, amount0)));
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
            gasUsed: 0
        });
    }

    function _at(Config memory c, uint64 offset) internal pure returns (address) {
        return vm.computeCreateAddress(c.controller, c.startNonce + offset);
    }

    // ---------------------------------------------------------------------
    // Simulate: run every step as the controller at its pinned nonce
    // ---------------------------------------------------------------------

    function _simulate(Config memory c, Step[] memory s) internal {
        vm.deal(c.controller, c.controller.balance + c.liquidityQuote + c.initialBuyQuote + 1 ether);
        for (uint256 i; i < s.length; i++) {
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
            if (s[i].expected != address(0)) require(made == s[i].expected, string.concat("address drift: ", s[i].id));
        }
    }

    /// @notice Per-step gas limit: execution measured in simulation plus intrinsic and calldata gas,
    /// with a 20% margin. Confirm each limit with eth_estimateGas on a mainnet fork before binding the plan.
    function _gasLimit(Step memory s) internal pure returns (uint256) {
        uint256 calldataGas;
        bytes memory d = s.data;
        for (uint256 i; i < d.length; i++) {
            calldataGas += d[i] == 0 ? 4 : 16;
        }
        uint256 intrinsic = 21_000 + calldataGas + (s.to == address(0) ? 32_000 + 2 * ((d.length + 31) / 32) : 0);
        return (s.gasUsed + intrinsic) * 12 / 10;
    }

    function _totalGas(Step[] memory s) internal pure returns (uint256 total) {
        for (uint256 i; i < s.length; i++) {
            total += _gasLimit(s[i]);
        }
        total += STAMP_GAS * 12 / 10;
    }
}
