// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FluxCore} from "../../src/core/FluxCore.sol";
import {FluxRevenueRouter, IFluxShellRevenue} from "../../src/revenue/FluxRevenueRouter.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";

/// @notice FluxPool's own token pool: 5% -> 3.2% launch fee, 80/20 creator/protocol split, and the
/// revenue router's market-cap-scaled buybacks.
abstract contract FluxRevenueRouterTestBase is FluxTestBase {
    uint32 constant TOKEN_WINDOW = 300; // 5 minutes
    address safe = makeAddr("team-safe");
    address bot = makeAddr("buyback-operator");
    FluxRevenueRouter router;
    uint256 mcLow = 1_000_000 ether;
    uint256 mcHigh = 20_000_000 ether;

    function setUp() public override {
        super.setUp();
        poolBaseFee = 32_000; // 3.2%
        poolFeeCap = 40_000; // 4%: room for adaptive sell fees under a dump
        poolLaunchCap = 50_000; // 5%
        _launchToken();
    }

    function _launchToken() internal {
        FluxCore.SettingInit[] memory s = new FluxCore.SettingInit[](1);
        s[0] = FluxCore.SettingInit(address(antiSnipe), antiSnipe.OPENING_FEE(), 18_000); // 3.2% + 1.8% = 5%
        address[] memory before = new address[](2);
        before[0] = address(antiSnipe);
        before[1] = address(adaptiveFee);
        // Creator share 80% so the protocol (the team Safe as treasury) gets 20%.
        _launch(before, _one(address(adaptiveFee)), s, TOKEN_WINDOW);
        bytes32 creatorShare = creatorFee.CREATOR_SHARE(); // read first: a call here would use up the prank
        vm.prank(address(core));
        creatorFee.setSetting(creatorShare, 8_000);
        (uint256 c,,) = shell.feeSplit(poolId);
        assertEq(c, 8_000);
    }

    function _feeRecipient() internal override returns (address) {
        router = new FluxRevenueRouter(
            FluxRevenueRouter.Config({
                poolManager: manager,
                shell: IFluxShellRevenue(address(shell)),
                token: address(token),
                quote: quote,
                tickSpacing: 60,
                safe: safe,
                operator: bot,
                mcLow: mcLow,
                mcHigh: mcHigh,
                dropWindowBlocks: 5,
                dropHoldBlocks: 3,
                dropTicks: 2_877 // ~25%
            })
        );
        return address(router);
    }

    function _trade(uint256 blocks) internal {
        for (uint256 i; i < blocks; i++) {
            vm.roll(block.number + 1);
            _buy(1 ether);
            _sell(1 ether);
        }
    }

    // ------------------------------------------------------------------
    // Launch fee schedule
    // ------------------------------------------------------------------

    function test_launchFeeFallsFromFivePercentToThreePointTwo() public {
        uint256 t0 = block.timestamp;
        assertEq(_feeOf(true, 0.1 ether), 50_000);
        vm.warp(t0 + TOKEN_WINDOW / 2);
        vm.roll(block.number + 1);
        assertEq(_feeOf(true, 0.1 ether), 41_000);
        vm.warp(t0 + TOKEN_WINDOW);
        vm.roll(block.number + 1);
        assertEq(_feeOf(true, 0.1 ether), 32_000);
        assertEq(_feeOf(false, 0.1 ether), 32_000);
    }

    function test_launchFeeNeverAboveFivePercent() public {
        core.setBlockSetting(address(antiSnipe), antiSnipe.OPENING_FEE(), 990_000);
        assertEq(_feeOf(true, 0.1 ether), 50_000);
    }

    // ------------------------------------------------------------------
    // Split
    // ------------------------------------------------------------------

    function test_splitFollowsMarketCap() public {
        vm.warp(block.timestamp + TOKEN_WINDOW);
        _trade(3);
        uint256 bps = router.buybackBps();
        uint256 mc = router.marketCapEth();
        assertGt(mc, mcLow);
        assertLt(mc, mcHigh);
        assertEq(bps, 500 + 1_500 * (mc - mcLow) / (mcHigh - mcLow));

        uint256 safeEth = _quoteBalance(safe);
        vm.prank(makeAddr("anyone")); // distribute is permissionless
        router.distribute();
        uint256 toSafe = _quoteBalance(safe) - safeEth;
        uint256 kept = _quoteBalance(address(router));
        uint256 received = toSafe + kept;
        assertGt(received, 0);
        assertEq(kept, received * bps / 8_000); // bps of total pool fees, from the 80% creator share
        assertEq(token.balanceOf(router.BURN()), (token.balanceOf(safe) + token.balanceOf(router.BURN())) * bps / 8_000);
    }

    function test_lowMarketCapGetsFivePercent() public {
        mcLow = 100_000_000 ether;
        mcHigh = 200_000_000 ether;
        _launchToken();
        vm.warp(block.timestamp + TOKEN_WINDOW);
        assertEq(router.buybackBps(), 500);
    }

    function test_highMarketCapGetsTwentyPercent() public {
        mcLow = 1 ether;
        mcHigh = 2 ether;
        _launchToken();
        vm.warp(block.timestamp + TOKEN_WINDOW);
        assertEq(router.buybackBps(), 2_000);
    }

    function test_significantDropSwitchesToThirtySeventy() public {
        vm.warp(block.timestamp + TOKEN_WINDOW);
        assertFalse(router.inDrop());
        for (uint256 i; i < 12; i++) {
            vm.roll(block.number + 1);
            _sell(i < 3 ? 0.001 ether : 8 ether); // history, then a sustained dump
        }
        vm.roll(block.number + 1);
        _sell(0.001 ether);
        assertTrue(router.inDrop());
        assertEq(router.buybackBps(), 3_000);

        uint256 safeEth = _quoteBalance(safe);
        router.distribute();
        uint256 toSafe = _quoteBalance(safe) - safeEth;
        uint256 kept = _quoteBalance(address(router));
        // Of the pool's total fees: 30% buyback, 70% Safe (20% via the protocol share + 50% here).
        assertEq(kept, (toSafe + kept) * 3_000 / 8_000);
    }

    function test_oneBlockDipIsNotADrop() public {
        vm.warp(block.timestamp + TOKEN_WINDOW);
        _trade(10);
        vm.roll(block.number + 1);
        _sell(20 ether);
        vm.roll(block.number + 1);
        _sell(0.001 ether);
        assertFalse(router.inDrop());
    }

    function test_protocolShareGoesToTreasury() public {
        vm.warp(block.timestamp + TOKEN_WINDOW);
        _trade(2);
        router.distribute();
        uint256 protocolEth = shell.claimable(treasury, quote);
        uint256 routerEth = _quoteBalance(safe) + _quoteBalance(address(router));
        assertApproxEqRel(protocolEth * 4, routerEth, 1e14); // 20% vs 80%
    }

    // ------------------------------------------------------------------
    // Buybacks and team access
    // ------------------------------------------------------------------

    function test_buybackBuysAndBurns() public {
        vm.warp(block.timestamp + TOKEN_WINDOW);
        _trade(3);
        router.distribute();
        uint256 eth = _quoteBalance(address(router));
        assertGt(eth, 0);
        uint256 burnedBefore = token.balanceOf(router.BURN());
        uint256 platformBefore = shell.platformAccrued();
        vm.prank(bot);
        uint256 burned = router.buyback(eth, 1);
        assertGt(burned, 0);
        assertEq(token.balanceOf(router.BURN()) - burnedBefore, burned);
        assertEq(_quoteBalance(address(router)), 0);
        assertGt(shell.platformAccrued(), platformBefore); // Programmable's fee applies to buybacks too
    }

    function test_buybackSlippageAndAccess() public {
        vm.warp(block.timestamp + TOKEN_WINDOW);
        _trade(3);
        router.distribute();
        uint256 eth = _quoteBalance(address(router));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FluxRevenueRouter.NotOperator.selector);
        router.buyback(eth, 0);
        vm.prank(bot);
        vm.expectRevert();
        router.buyback(eth, type(uint128).max);
    }

    function test_teamCanWithdrawEverything() public {
        vm.warp(block.timestamp + TOKEN_WINDOW);
        _trade(3);
        router.distribute();
        uint256 eth = _quoteBalance(address(router));
        vm.prank(bot);
        vm.expectRevert(FluxRevenueRouter.NotSafe.selector);
        router.withdraw(Currency.unwrap(quote), bot, eth);

        uint256 before = _quoteBalance(safe);
        vm.prank(safe);
        router.withdraw(Currency.unwrap(quote), safe, eth);
        assertEq(_quoteBalance(safe) - before, eth);
    }

    function test_rejectsBadConfig() public {
        FluxRevenueRouter.Config memory c = FluxRevenueRouter.Config({
            poolManager: manager,
            shell: IFluxShellRevenue(address(shell)),
            token: address(token),
            quote: quote,
            tickSpacing: 60,
            safe: safe,
            operator: bot,
            mcLow: 2 ether,
            mcHigh: 1 ether,
            dropWindowBlocks: 5,
            dropHoldBlocks: 3,
            dropTicks: 2_877
        });
        vm.expectRevert(FluxRevenueRouter.InvalidConfig.selector);
        new FluxRevenueRouter(c);
    }

    function testFuzz_splitNeverExceedsWhatArrived(uint256 trades) public {
        vm.warp(block.timestamp + TOKEN_WINDOW);
        _trade(bound(trades, 1, 8));
        uint256 safeEth = _quoteBalance(safe);
        router.distribute();
        uint256 received = _quoteBalance(safe) - safeEth + _quoteBalance(address(router));
        assertLe(_quoteBalance(address(router)), received * 3_000 / 8_000);
        assertEq(token.balanceOf(address(router)), 0); // token shares are always paid out or burned
        Currency c = quote;
        assertEq(shell.claimable(address(router), c), 0);
    }
}

/// @dev Native ETH quote, as on Ethereum (token = currency1).
contract FluxRevenueRouterTest is FluxRevenueRouterTestBase {}

/// @dev Same tests with a WETH quote, the token sorting below it (token = currency0).
contract FluxRevenueRouterTokenFirstTest is FluxRevenueRouterTestBase {
    function _tokenFirst() internal pure override returns (bool) {
        return true;
    }
}
