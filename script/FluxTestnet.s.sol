// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FluxPlanner} from "./FluxPlanner.sol";
import {FluxShell} from "../src/shell/FluxShell.sol";

/// @notice Deploys FluxPool to a testnet with the same launch plan as mainnet, sent from our own
/// deployer instead of Programmable's controller, then trades the launched pool.
///
///   Deploy (Sepolia; the key comes from DEPLOYER_PRIVATE_KEY in the repo's .env):
///     forge script script/FluxTestnet.s.sol --rpc-url $RPC_URL --broadcast --slow \
///       --gas-estimate-multiplier 800
///   Trade the launched pool (buy, sell, collect fees); re-run any time:
///     forge script script/FluxTestnet.s.sol --sig "trade()" --rpc-url $RPC_URL --broadcast \
///       --gas-estimate-multiplier 800
///   Rehearse deploy + trade in one simulation, no key and nothing sent (a throwaway key, funded only
///   in simulation; writes nothing):
///     DRY_RUN=true forge script script/FluxTestnet.s.sol --sig "rehearse()" --rpc-url $RPC_URL
///
/// @dev `--gas-estimate-multiplier 800` (i.e. 8x, the flag is a percentage) is required against live
/// networks. Sepolia is on Osaka (Fusaka), whose gas schedule prices code deposit and account
/// creation several times higher than cancun. Foundry clamps `evm_version` to what the compiler
/// supports, and solc 0.8.26 tops out at cancun, so forge's simulator under-estimates every
/// transaction here by roughly 6-7x: without the multiplier the first create runs out of gas. 8x
/// covers the widest step we measured (ChangeRegistry 7.08x) with margin. Mainnet is on the same
/// schedule, so Programmable's controller will need the same treatment.
///
/// The pool pairs the token with native ETH. Addresses go to deploy/out/testnet-<chainId>.json.
/// Refuses to run on Ethereum mainnet.
contract FluxTestnetScript is Script, FluxPlanner {
    using PoolIdLibrary for PoolKey;

    string internal constant CONFIG = "deploy/fluxpool-token.config.json";
    address internal constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    /// @dev A rehearsal impersonates the deployer instead of broadcasting, so nothing is ever sendable.
    bool internal rehearsing;

    function run() external {
        (uint256 key, address deployer, bool dryRun) = _deployer();
        require(!dryRun, "use rehearse() for a dry run");
        (Config memory c, Addresses memory a, PoolKey memory pk) = _deploy(key, deployer);
        _write(c, a, pk);
    }

    /// @notice Buys with ETH, sells half of it back, then collects the pool's fees.
    function trade() external {
        (uint256 key, address trader, bool dryRun) = _deployer();
        require(!dryRun, "use rehearse() for a dry run");
        string memory j = vm.readFile(_outPath());
        _trade(
            key,
            trader,
            vm.parseJsonAddress(j, ".shell"),
            vm.parseJsonAddress(j, ".token"),
            IPoolManager(vm.parseJsonAddress(j, ".poolManager"))
        );
    }

    /// @notice Deploy and trade in one simulation, with a throwaway key. Never broadcasts or writes.
    function rehearse() external {
        (uint256 key, address deployer, bool dryRun) = _deployer();
        require(dryRun, "rehearse() needs DRY_RUN=true");
        rehearsing = true;
        vm.deal(deployer, 10 ether);
        (Config memory c, Addresses memory a,) = _deploy(key, deployer);
        vm.warp(block.timestamp + c.launchWindow);
        vm.roll(block.number + 1);
        _trade(key, deployer, a.shell, a.token, IPoolManager(c.poolManager));
    }

    function _deploy(uint256 key, address deployer)
        internal
        returns (Config memory c, Addresses memory a, PoolKey memory pk)
    {
        c = _config(deployer);
        require(deployer.balance > c.liquidityQuote + c.initialBuyQuote, "deployer needs testnet ETH");
        Step[] memory s;

        (a, s) = _plan(c);
        for (uint256 i; i < s.length; i++) {
            address made;
            if (rehearsing) {
                vm.setNonce(deployer, s[i].nonce);
                vm.prank(deployer);
            } else {
                require(vm.getNonce(deployer) == s[i].nonce, string.concat("nonce drift before ", s[i].id));
                vm.broadcast(key);
            }
            if (s[i].to == address(0)) {
                bytes memory code = s[i].data;
                assembly ("memory-safe") {
                    made := create(0, add(code, 0x20), mload(code))
                }
                require(made != address(0), string.concat("create failed: ", s[i].id));
            } else {
                (bool ok, bytes memory ret) = s[i].to.call{value: s[i].value}(s[i].data);
                require(ok, string.concat("call failed: ", s[i].id));
                if (s[i].expected != address(0)) made = abi.decode(ret, (address));
            }
            if (s[i].expected != address(0)) require(made == s[i].expected, string.concat("address drift: ", s[i].id));
            console.log(s[i].id, made);
        }

        pk = _poolKey(a.token, a.shell);
        require(FluxShell(payable(a.shell)).poolConfig(pk.toId()).initialized, "pool not live");
        console.log("shell", a.shell);
        console.log("token", a.token);
    }

    function _trade(uint256 key, address trader, address shell, address token, IPoolManager manager) internal {
        PoolKey memory pk = _poolKey(token, shell);

        uint256 buyEth = vm.envOr("TRADE_BUY_WEI", uint256(0.00005 ether)); // under AntiSnipe's 1% cap
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 ethBefore = trader.balance;
        uint256 tokBefore = IERC20(token).balanceOf(trader);

        if (rehearsing) vm.startPrank(trader);
        else vm.startBroadcast(key);
        PoolSwapTest router = new PoolSwapTest(manager);
        IERC20(token).approve(address(router), type(uint256).max);
        // Buy: pay ETH (currency0) for the token (currency1).
        router.swap{value: buyEth}(
            pk,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(buyEth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ""
        );
        uint256 bought = IERC20(token).balanceOf(trader) - tokBefore;
        require(bought > 0, "buy returned no tokens");
        uint256 sellTokens = bought / 2;
        // Sell: half of what was just bought, back for ETH.
        router.swap(
            pk,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(sellTokens), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );
        FluxShell(payable(shell)).collect(pk);
        if (rehearsing) vm.stopPrank();
        else vm.stopBroadcast();

        console.log("bought tokens", bought);
        console.log("sold tokens", sellTokens);
        console.log("eth spent net (wei, before gas)", ethBefore - trader.balance);
        console.log("platform fee accrued (wei)", FluxShell(payable(shell)).platformAccrued());
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _deployer() internal returns (uint256 key, address who, bool dryRun) {
        require(block.chainid != 1, "Ethereum mainnet needs Anu's explicit approval; this script is testnet only");
        dryRun = vm.envOr("DRY_RUN", false);
        key = dryRun ? uint256(keccak256("fluxpool testnet dry run")) : _envKey("DEPLOYER_PRIVATE_KEY");
        who = vm.addr(key);
        vm.label(who, "deployer");
    }

    /// @dev Reads a private key from the environment, accepting it with or without the 0x prefix.
    function _envKey(string memory name) internal view returns (uint256) {
        string memory raw = vm.envString(name);
        bytes memory b = bytes(raw);
        if (b.length != 66 || b[0] != 0x30 || b[1] != 0x78) raw = string.concat("0x", raw);
        return vm.parseUint(raw);
    }

    /// @dev The mainnet launch config, with testnet roles all held by the deployer and small amounts.
    function _config(address deployer) internal view returns (Config memory c) {
        string memory j = vm.readFile(CONFIG);
        c.controller = deployer;
        c.startNonce = vm.getNonce(deployer);
        c.poolManager = vm.envOr("POOL_MANAGER", block.chainid == 11155111 ? SEPOLIA_POOL_MANAGER : address(0));
        require(c.poolManager.code.length > 0, "no PoolManager on this chain: set POOL_MANAGER");
        c.quote = address(0); // native ETH
        c.treasury = vm.envOr("TESTNET_TREASURY", deployer);
        c.safe = vm.envOr("TESTNET_SAFE", deployer);
        c.operator = vm.envOr("TESTNET_OPERATOR", deployer);
        c.attesterManager = vm.envOr("TESTNET_ATTESTER_MANAGER", deployer);
        c.buyRecipient = deployer;
        c.name = "FluxPool Testnet";
        c.symbol = "FLUXTEST";
        c.supply = 1_000_000_000 ether;
        c.liquidityQuote = vm.envOr("TESTNET_LIQUIDITY_WEI", uint256(0.01 ether));
        c.liquidityTokens = 100_000_000 ether;
        // AntiSnipe caps any buy in the launch window at 1% of the pool's tokens: keep buys well under it.
        c.initialBuyQuote = vm.envOr("TESTNET_INITIAL_BUY_WEI", uint256(0.00005 ether));
        c.minTokensOut = 1;
        c.launchWindow = uint32(vm.parseJsonUint(j, ".launchWindow"));
        c.baseFee = uint24(vm.parseJsonUint(j, ".baseFee"));
        c.feeCap = uint24(vm.parseJsonUint(j, ".feeCap"));
        c.launchFeeCap = uint24(vm.parseJsonUint(j, ".launchFeeCap"));
        c.openingFee = uint24(vm.parseJsonUint(j, ".openingFee"));
        c.creatorShareBps = uint16(vm.parseJsonUint(j, ".creatorShareBps"));
        c.timelockDelay = uint64(vm.parseJsonUint(j, ".timelockDelay"));
        c.launchMode = uint8(vm.parseJsonUint(j, ".launchMode"));
        // Market-cap bounds around the testnet pool's size (0.01 ETH against 10% of supply ~ 0.1 ETH cap).
        c.mcLow = 0.05 ether;
        c.mcHigh = 5 ether;
        c.dropWindowBlocks = uint32(vm.parseJsonUint(j, ".dropWindowBlocks"));
        c.dropHoldBlocks = uint32(vm.parseJsonUint(j, ".dropHoldBlocks"));
        c.dropTicks = int24(vm.parseJsonInt(j, ".dropTicks"));
    }

    function _poolKey(address token, address shell) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(shell)
        });
    }

    function _outPath() internal view returns (string memory) {
        return string.concat("deploy/out/testnet-", vm.toString(block.chainid), ".json");
    }

    function _write(Config memory c, Addresses memory a, PoolKey memory pk) internal {
        string memory o = "testnet";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "poolManager", c.poolManager);
        vm.serializeAddress(o, "deployer", c.controller);
        vm.serializeAddress(o, "fluxDeployer", a.deployer);
        vm.serializeAddress(o, "creatorFee", a.creatorFee);
        vm.serializeAddress(o, "agentRegistry", a.agentRegistry);
        vm.serializeAddress(o, "changeRegistry", a.changeRegistry);
        vm.serializeAddress(o, "playbookRegistry", a.playbookRegistry);
        vm.serializeAddress(o, "fluxCoreImpl", a.coreImpl);
        vm.serializeAddress(o, "fluxLauncher", a.launcher);
        vm.serializeAddress(o, "antiSnipe", a.antiSnipe);
        vm.serializeAddress(o, "adaptiveFee", a.adaptiveFee);
        vm.serializeAddress(o, "fluxRevenueRouter", a.router);
        vm.serializeAddress(o, "token", a.token);
        vm.serializeBytes32(o, "poolId", PoolId.unwrap(pk.toId()));
        string memory json = vm.serializeAddress(o, "shell", a.shell);
        vm.createDir("deploy/out", true);
        vm.writeJson(json, _outPath());
    }
}
