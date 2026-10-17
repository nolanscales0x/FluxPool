// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {FluxShell} from "../../src/shell/FluxShell.sol";
import {FluxRevenueRouter} from "../../src/revenue/FluxRevenueRouter.sol";
import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {ChangeRegistry} from "../../src/gates/ChangeRegistry.sol";
import {FluxProtectedToken} from "../../src/protection/FluxProtectedToken.sol";
import {FluxFeeVault} from "../../src/protection/FluxFeeVault.sol";
import {FluxPlanner} from "../../script/FluxPlanner.sol";
import {MockUniversalRouter, MockUsdFeed} from "../protection/ProtectedLaunch.t.sol";

/// @notice Rehearses the protected launch plan end to end on (simulated) chain 1: every step sent by the
/// controller at its pinned nonce, every address checked against the prediction, then the launched pool
/// traded through the canonical router, its fees custodied by the vaults and swept by the revenue router.
contract LaunchPlanTest is Deployers, FluxPlanner {
    using PoolIdLibrary for PoolKey;

    address constant CANONICAL_ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    address constant CANONICAL_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;

    Config c;
    Addresses a;
    Step[] steps;
    PoolKey launchKey;
    address trader = makeAddr("trader");

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        deployFreshManagerAndRouters();
        vm.etch(CANONICAL_ROUTER, address(new MockUniversalRouter(manager)).code);
        vm.etch(CANONICAL_FEED, address(new MockUsdFeed()).code);
        MockUsdFeed(CANONICAL_FEED).set(3_000e8, block.timestamp);

        c.controller = makeAddr("controller");
        c.startNonce = 0;
        c.poolManager = address(manager);
        c.treasury = makeAddr("treasury-placeholder");
        c.safe = makeAddr("safe-placeholder");
        c.operator = makeAddr("operator-placeholder");
        c.attesterManager = makeAddr("attester-manager-placeholder");
        c.developer = makeAddr("developer-placeholder");
        c.router = CANONICAL_ROUTER;
        c.routerCodeHash = CANONICAL_ROUTER.codehash;
        c.usdFeed = CANONICAL_FEED;
        c.usdFeedCodeHash = CANONICAL_FEED.codehash;
        c.name = "FluxPool Test";
        c.symbol = "FLUXTEST";
        c.supply = 1_000_000_000 ether;
        c.startTick = 180_000; // ~15.2 ETH FDV, ~$45.7k at $3,000
        c.initialBuyEth = 0.01 ether;
        c.minTokensOut = 1;
        c.creatorBuyFeeBps = 100;
        c.creatorSellFeeBps = 100;
        c.timelockDelay = 48 hours;
        c.launchMode = 0;
        c.mcLow = 10 ether;
        c.mcHigh = 1_000 ether;
        c.dropWindowBlocks = 40;
        c.dropHoldBlocks = 10;
        c.dropTicks = 2_877;

        Step[] memory s;
        (a, s) = _plan(c);
        for (uint256 i; i < s.length; i++) {
            steps.push(s[i]);
        }
        launchKey = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(a.token), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(a.shell)
        );
    }

    function _run() internal {
        Step[] memory s = steps;
        _simulate(c, s);
        for (uint256 i; i < s.length; i++) {
            steps[i].gasUsed = s[i].gasUsed;
        }
    }

    function test_everyStepLandsWherePredicted() public {
        _run(); // reverts on any address drift
        FluxShell shell = FluxShell(payable(a.shell));
        Hooks.validateHookPermissions(IHooks(a.shell), shell.getHookPermissions());
        assertEq(shell.launcher(), a.launcher);
        assertEq(shell.creatorFeeBlock(), a.creatorFee);
        assertEq(shell.agentRegistry(), a.agentRegistry);
        assertEq(shell.protocolTreasury(), c.treasury);
        assertEq(Currency.unwrap(shell.quote()), address(0), "native quote");
        assertEq(address(AgentRegistry(a.agentRegistry).changeRegistry()), a.changeRegistry);
        assertEq(address(ChangeRegistry(a.changeRegistry).agentRegistry()), a.agentRegistry);
        assertEq(FluxProtectedToken(a.token).initializer(), a.launcher, "launcher is the token's initializer");
    }

    function test_launchIsProtectedLockedAndLive() public {
        _run();
        FluxShell shell = FluxShell(payable(a.shell));
        FluxShell.PoolConfig memory cfg = shell.poolConfig(launchKey.toId());
        assertTrue(cfg.initialized && cfg.protectedLaunch, "protected and live");
        assertEq(uint8(cfg.lockType), uint8(FluxShell.LockType.Locked), "locked");
        assertEq(cfg.creator, c.safe);
        assertEq(cfg.protectionModule, a.module);
        assertEq(cfg.normalFeeVault, a.normalVault);
        assertEq(cfg.openingTaxVault, a.taxVault);
        FluxProtectedToken token = FluxProtectedToken(a.token);
        assertEq(token.startedAt(), block.timestamp, "protection started");
        assertGt(token.balanceOf(c.developer), 0, "initial buy to the developer");
        assertEq(token.balanceOf(a.launcher), 0, "launcher holds nothing");
        // The developer's initial buy paid the normal fee (0.3% platform + 1% creator) into the vault.
        FluxFeeVault normal = FluxFeeVault(a.normalVault);
        assertEq(
            normal.platformAccrued() + normal.creatorAccrued(),
            Math.mulDiv(c.initialBuyEth, 13_000, 1e6, Math.Rounding.Ceil)
        );
    }

    function test_launchedPoolTradesThroughTheCanonicalRouterAndPaysOut() public {
        _run();
        vm.warp(block.timestamp + 300);
        vm.deal(trader, 10 ether);
        for (uint256 i; i < 3; i++) {
            vm.roll(block.number + 1);
            vm.prank(trader);
            MockUniversalRouter(CANONICAL_ROUTER).buy{value: 0.1 ether}(launchKey, 0.1 ether);
        }
        FluxRevenueRouter router = FluxRevenueRouter(payable(a.router));
        uint256 safeBefore = c.safe.balance;
        router.distribute(); // pulls the creator fee from the vault, then splits Safe / buyback
        assertGt(c.safe.balance, safeBefore, "safe paid");
        assertGt(a.router.balance, 0, "buyback funds held");
        uint256 platformBefore = PLATFORM.balance;
        FluxFeeVault(a.normalVault).claimPlatform();
        assertGt(PLATFORM.balance, platformBefore, "platform paid its 0.3%");
    }

    function test_aStrayControllerTransactionBreaksThePlan() public {
        Step[] memory s = steps;
        for (uint256 i; i < s.length; i++) {
            s[i].nonce += 1;
        }
        try this.simulateExternal(s) {
            revert("plan should have drifted");
        } catch Error(string memory reason) {
            assertEq(reason, "address drift: FluxDeployer");
        }
    }

    function simulateExternal(Step[] memory s) external {
        require(msg.sender == address(this));
        _simulate(c, s);
    }

    /// @dev Programmable's plan limits. Runtime sizes come from the via-IR build: `forge build --sizes`.
    function test_fitsProgrammableLimitsAndBudget() public {
        _run();
        assertLe(steps.length, 64, "too many actions");
        assertLe(steps.length - 1, 16, "too many components"); // every step but the launch deploys one
        uint256 total;
        for (uint256 i; i < steps.length; i++) {
            if (steps[i].to == address(0)) assertLe(steps[i].data.length, 49_152, "initcode over limit");
            uint256 limit = _gasLimit(steps[i]);
            total += limit;
            console.log(steps[i].id, steps[i].gasUsed, limit);
        }
        assertEq(_totalGas(steps), total + 7_200_000); // stamp 6M + 20%
        console.log("maxTotalGas (steps + stamp, 20% margin)", _totalGas(steps));
    }

    function test_addressesDependOnlyOnControllerAndNonce() public view {
        Config memory c2 = c;
        Addresses memory same = _addresses(c2);
        assertEq(same.shell, a.shell);
        c2.startNonce = 5;
        Addresses memory shifted = _addresses(c2);
        assertTrue(shifted.token != a.token);
        assertTrue(shifted.shell != a.shell);
        assertEq(uint160(shifted.shell) & Hooks.ALL_HOOK_MASK, SHELL_FLAGS);
    }
}
