// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {FluxShell} from "../../src/shell/FluxShell.sol";
import {FluxRevenueRouter} from "../../src/revenue/FluxRevenueRouter.sol";
import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {ChangeRegistry} from "../../src/gates/ChangeRegistry.sol";
import {FluxPlanner} from "../../script/FluxPlanner.sol";

/// @notice Rehearses the whole launch plan: every step sent by the controller at its pinned nonce,
/// every address checked against the prediction, then the launched pool used for real. The pool
/// pairs the token with native ETH (as on Ethereum) or with WETH; the concrete suites below cover
/// native ETH and both WETH sort orders.
abstract contract LaunchPlanTestBase is Deployers, FluxPlanner {
    using PoolIdLibrary for PoolKey;

    Config c;
    Addresses a;
    Step[] steps;
    PoolKey launchKey;
    address trader = makeAddr("trader");
    WETH weth; // unset for a native ETH quote
    address quote;

    /// @dev The pool's quote: address(0) for native ETH, otherwise where to put a WETH.
    function _quoteAddress() internal pure virtual returns (address);

    function setUp() public {
        deployFreshManagerAndRouters();
        quote = _quoteAddress();
        if (quote != address(0)) {
            deployCodeTo("WETH.sol:WETH", quote);
            weth = WETH(payable(quote));
        }
        c = Config({
            controller: makeAddr("controller"),
            startNonce: 0,
            poolManager: address(manager),
            quote: quote,
            treasury: makeAddr("treasury-placeholder"),
            safe: makeAddr("safe-placeholder"),
            operator: makeAddr("operator-placeholder"),
            attesterManager: makeAddr("attester-manager-placeholder"),
            buyRecipient: makeAddr("launch-wallet"),
            name: "FluxPool Test",
            symbol: "FLUXTEST",
            supply: 1_000_000_000 ether,
            liquidityQuote: 10 ether,
            liquidityTokens: 100_000_000 ether,
            initialBuyQuote: 0.01 ether,
            minTokensOut: 1,
            launchWindow: 300,
            baseFee: 32_000,
            feeCap: 40_000,
            launchFeeCap: 50_000,
            openingFee: 18_000,
            creatorShareBps: 8_000,
            timelockDelay: 48 hours,
            launchMode: 0,
            mcLow: 50 ether,
            mcHigh: 5_000 ether,
            dropWindowBlocks: 40,
            dropHoldBlocks: 10,
            dropTicks: 2_877
        });
        Step[] memory s;
        (a, s) = _plan(c);
        for (uint256 i; i < s.length; i++) {
            steps.push(s[i]);
        }
        bool tokenIs0 = a.token < quote;
        Currency t = Currency.wrap(a.token);
        Currency q = Currency.wrap(quote);
        launchKey = PoolKey(tokenIs0 ? t : q, tokenIs0 ? q : t, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(a.shell));
    }

    /// @dev zeroForOne for a buy: paying the quote for the token.
    function _buyDir() internal view returns (bool) {
        return Currency.unwrap(launchKey.currency0) == quote;
    }

    function _quoteBalance(address who) internal view returns (uint256) {
        return quote == address(0) ? who.balance : weth.balanceOf(who);
    }

    function _buyAsTrader(uint256 quoteIn) internal {
        bool dir = _buyDir();
        vm.prank(trader);
        swapRouter.swap{value: quote == address(0) ? quoteIn : 0}(
            launchKey,
            SwapParams({
                zeroForOne: dir,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: dir ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _run() internal {
        Step[] memory s = steps;
        _simulate(c, s);
        for (uint256 i; i < s.length; i++) {
            steps[i].gasUsed = s[i].gasUsed;
        }
    }

    // ------------------------------------------------------------------
    // The plan
    // ------------------------------------------------------------------

    function test_everyStepLandsWherePredicted() public {
        _run(); // reverts on any address drift
        Hooks.validateHookPermissions(IHooks(a.shell), FluxShell(payable(a.shell)).getHookPermissions());
        FluxShell shell = FluxShell(payable(a.shell));
        assertEq(shell.launcher(), a.launcher);
        assertEq(shell.creatorFeeBlock(), a.creatorFee);
        assertEq(shell.agentRegistry(), a.agentRegistry);
        assertEq(shell.protocolTreasury(), c.treasury);
        assertEq(address(AgentRegistry(a.agentRegistry).changeRegistry()), a.changeRegistry);
        assertEq(address(ChangeRegistry(a.changeRegistry).agentRegistry()), a.agentRegistry);
        assertEq(AgentRegistry(a.agentRegistry).playbookRegistry(), a.playbookRegistry);
    }

    function test_launchIsLiveAndChargedCorrectly() public {
        _run();
        FluxShell shell = FluxShell(payable(a.shell));
        PoolId id = launchKey.toId();
        FluxShell.PoolConfig memory cfg = shell.poolConfig(id);
        assertTrue(cfg.initialized);
        assertEq(cfg.creator, c.safe);
        assertEq(cfg.creatorFeeRecipient, a.router);
        assertEq(cfg.launchFeeCap, 50_000);

        // Initial buy went to the launch wallet and paid Programmable's 0.30%.
        assertGt(IERC20(a.token).balanceOf(c.buyRecipient), 0);
        assertEq(shell.platformAccrued(), 0.00003 ether);
        // The launcher holds nothing; the controller keeps the rest of the supply.
        assertEq(IERC20(a.token).balanceOf(a.launcher), 0);
        assertEq(a.launcher.balance, 0);
        assertEq(_quoteBalance(a.launcher), 0);
        assertEq(Currency.unwrap(shell.quote()), quote);
        assertGe(IERC20(a.token).balanceOf(c.controller), c.supply - c.liquidityTokens);
        (uint256 creatorBps,,) = shell.feeSplit(id);
        assertEq(creatorBps, 8_000);
    }

    function test_launchedPoolTradesAndBuysBack() public {
        _run();
        vm.deal(trader, 100 ether);
        if (quote != address(0)) {
            vm.startPrank(trader);
            weth.deposit{value: 10 ether}();
            weth.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
        _buyAsTrader(0.05 ether);

        vm.warp(block.timestamp + c.launchWindow);
        for (uint256 i; i < 5; i++) {
            vm.roll(block.number + 1);
            _buyAsTrader(0.05 ether);
        }

        FluxRevenueRouter router = FluxRevenueRouter(payable(a.router));
        assertGt(router.marketCapEth(), c.mcLow);
        router.distribute();
        uint256 funds = _quoteBalance(a.router);
        assertGt(funds, 0);
        assertGt(_quoteBalance(c.safe), 0);
        vm.prank(c.operator);
        router.buyback(funds, 1);
        assertGt(IERC20(a.token).balanceOf(router.BURN()), 0);
    }

    // ------------------------------------------------------------------
    // Programmable's rules
    // ------------------------------------------------------------------

    function test_aStrayControllerTransactionBreaksThePlan() public {
        // Golden rule 1: one extra controller transaction shifts every later nonce.
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

    function test_fitsProgrammableLimitsAndBudget() public {
        _run();
        address[11] memory components = [
            a.deployer,
            a.creatorFee,
            a.agentRegistry,
            a.changeRegistry,
            a.playbookRegistry,
            a.coreImpl,
            a.launcher,
            a.shell,
            a.antiSnipe,
            a.adaptiveFee,
            a.token
        ];
        for (uint256 i; i < components.length; i++) {
            assertLe(components[i].code.length, 24_576, "runtime over Programmable's limit");
        }
        assertLe(a.router.code.length, 24_576);
        assertLe(components.length + 1, 16, "too many components");
        assertLe(steps.length, 64, "too many actions");

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

/// @dev Native ETH, as we launch on Ethereum: the token is always currency1.
contract LaunchPlanNativeTest is LaunchPlanTestBase {
    function _quoteAddress() internal pure override returns (address) {
        return address(0);
    }
}

/// @dev WETH at a very low address: the token sorts as currency1.
contract LaunchPlanTest is LaunchPlanTestBase {
    function _quoteAddress() internal pure override returns (address) {
        return address(0x0000000000000000000000000000000000001111);
    }
}

/// @dev WETH at a very high address: the token sorts as currency0.
contract LaunchPlanTokenFirstTest is LaunchPlanTestBase {
    function _quoteAddress() internal pure override returns (address) {
        return address(uint160(type(uint160).max) - 0xFFFF);
    }
}
