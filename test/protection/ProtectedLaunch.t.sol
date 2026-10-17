// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {FluxShell} from "../../src/shell/FluxShell.sol";
import {FluxCore} from "../../src/core/FluxCore.sol";
import {FluxLauncher, IUsdFeed} from "../../src/launch/FluxLauncher.sol";
import {FluxProtectedToken} from "../../src/protection/FluxProtectedToken.sol";
import {FluxLaunchProtectionModule} from "../../src/protection/FluxLaunchProtectionModule.sol";
import {FluxFeeVault} from "../../src/protection/FluxFeeVault.sol";

/// @dev Uniswap's Universal Router, as far as the policy cares: it swaps for its caller and reports
/// that caller as `msgSender()` while it does. Deployed normally, then its runtime code (with the
/// PoolManager immutable baked in) is placed at the canonical address.
contract MockUniversalRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    address public msgSender;

    constructor(IPoolManager m) {
        manager = m;
    }

    function buy(PoolKey calldata pkey, uint256 ethIn) external payable returns (uint256 out) {
        return buyFor(pkey, ethIn, msg.sender);
    }

    /// @dev Like the Universal Router's `recipient`: the buyer is the caller, the tokens go elsewhere.
    function buyFor(PoolKey calldata pkey, uint256 ethIn, address recipient) public payable returns (uint256 out) {
        msgSender = msg.sender;
        out = abi.decode(manager.unlock(abi.encode(pkey, ethIn, recipient)), (uint256));
        msgSender = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory pkey, uint256 ethIn, address to) = abi.decode(data, (PoolKey, uint256, address));
        BalanceDelta d = manager.swap(
            pkey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        manager.settle{value: uint256(uint128(-d.amount0()))}();
        uint256 out = uint256(uint128(d.amount1()));
        manager.take(pkey.currency1, to, out);
        return abi.encode(out);
    }
}

/// @dev Chainlink's ETH/USD aggregator interface, with a settable answer.
contract MockUsdFeed {
    int256 public answer = 3_000e8;
    uint256 public updatedAt;

    function set(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Evidence for Programmable's launch-protection v1 review, end to end on (simulated) chain 1:
/// the atomic protected launch, the exact 99% opening total and its decay, the platform's 0.3% on both
/// sides, zero LP fee, separate custody, the canonical buyer path, both 2% budgets and the lock.
contract ProtectedLaunchTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    address constant CANONICAL_ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    address constant CANONICAL_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint160 constant FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint16 constant CREATOR_BUY_BPS = 100;
    uint16 constant CREATOR_SELL_BPS = 100;
    uint256 constant NORMAL_PPM = (30 + 100) * 100; // 13_000
    int24 constant START_TICK = 180_000; // ~6.56e7 tokens per ETH: FDV ~15.2 ETH, ~$45.7k at $3,000

    FluxShell shell;
    FluxLauncher launcher;
    FluxCore coreImpl;
    MockUsdFeed feed;
    FluxProtectedToken token;
    FluxLaunchProtectionModule module;
    FluxFeeVault normalVault;
    FluxFeeVault taxVault;
    PoolKey pkey;
    PoolId id;

    address safe = makeAddr("team-safe");
    address dev = makeAddr("developer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address exempt = makeAddr("exempt-wallet");
    address creatorRecipient = makeAddr("creator-recipient");

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        deployFreshManagerAndRouters();

        // The canonical router and the canonical feed, at their real addresses.
        vm.etch(CANONICAL_ROUTER, address(new MockUniversalRouter(manager)).code);
        vm.etch(CANONICAL_FEED, address(new MockUsdFeed()).code);
        feed = MockUsdFeed(CANONICAL_FEED);
        feed.set(3_000e8, block.timestamp);

        // The shell needs the launcher's address and the launcher needs the shell's: predict it.
        address hookAddr = address(FLAGS ^ (0x4444 << 144));
        uint64 n = vm.getNonce(address(this));
        address predictedLauncher = vm.computeCreateAddress(address(this), n + 3); // deployCodeTo uses n + 1
        address creatorFee = deployCode("CreatorFee.sol:CreatorFee"); // n
        coreImpl = FluxCore(vm.computeCreateAddress(address(this), n + 2));
        deployCodeTo(
            "FluxShell.sol:FluxShell",
            abi.encode(
                manager, predictedLauncher, creatorFee, address(0), makeAddr("treasury"), CurrencyLibrary.ADDRESS_ZERO
            ),
            hookAddr
        );
        shell = FluxShell(payable(hookAddr));
        address made =
            deployCode("FluxCore.sol:FluxCore", abi.encode(manager, address(shell), address(this), address(this))); // n+1
        assertEq(made, address(coreImpl));
        launcher = FluxLauncher(
            payable(deployCode(
                    "FluxLauncher.sol:FluxLauncher",
                    abi.encode(manager, shell, address(coreImpl), CANONICAL_FEED, CANONICAL_FEED.codehash)
                ))
        ); // n+2
        assertEq(address(launcher), predictedLauncher);

        _deployProtection(START_TICK);
    }

    function _deployProtection(int24) internal {
        token = FluxProtectedToken(
            deployCode(
                "FluxProtectedToken.sol:FluxProtectedToken",
                abi.encode("Flux Test", "FLUXT", SUPPLY, address(launcher), address(manager))
            )
        );
        address[6] memory ex;
        ex[0] = exempt;
        module = FluxLaunchProtectionModule(
            deployCode(
                "FluxLaunchProtectionModule.sol:FluxLaunchProtectionModule",
                abi.encode(address(shell), token, dev, CANONICAL_ROUTER, CANONICAL_ROUTER.codehash, CREATOR_BUY_BPS, ex)
            )
        );
        normalVault = FluxFeeVault(
            deployCode(
                "FluxFeeVault.sol:FluxFeeVault",
                abi.encode(manager, address(shell), CurrencyLibrary.ADDRESS_ZERO, creatorRecipient)
            )
        );
        taxVault = FluxFeeVault(
            deployCode(
                "FluxFeeVault.sol:FluxFeeVault",
                abi.encode(manager, address(shell), CurrencyLibrary.ADDRESS_ZERO, PLATFORM)
            )
        );
        pkey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(shell))
        });
        id = pkey.toId();
    }

    function _args(int24 tick) internal view returns (FluxLauncher.ProtectedLaunchParams memory l) {
        l.token = token;
        l.module = module;
        l.normalFeeVault = normalVault;
        l.openingTaxVault = taxVault;
        l.setup.creator = safe;
        l.setup.creatorFeeRecipient = creatorRecipient;
        l.setup.baseFee = 0;
        l.setup.feeCap = 50_000;
        l.setup.launchFeeCap = 50_000;
        l.setup.launchWindow = 0;
        l.setup.timelockDelay = 48 hours;
        l.setup.normalBuyFeeBps = CREATOR_BUY_BPS;
        l.setup.normalSellFeeBps = CREATOR_SELL_BPS;
        l.beforeSwap = new address[](0);
        l.afterSwap = new address[](0);
        l.settings = new FluxCore.SettingInit[](0);
        l.startTick = tick;
        l.minTokensOut = 1;
    }

    function _launch() internal returns (uint256 t0) {
        launcher.launchProtected{value: 0.01 ether}(_args(START_TICK));
        t0 = block.timestamp;
    }

    /// @dev A buy through the canonical router, as `who`. Returns the gross ETH in and the fees taken.
    function _routerBuy(address who, uint256 ethIn) internal returns (uint256 tokensOut) {
        vm.deal(who, who.balance + ethIn);
        vm.prank(who);
        tokensOut = MockUniversalRouter(CANONICAL_ROUTER).buy{value: ethIn}(pkey, ethIn);
    }

    function _lpFeeOfLastSwap(Vm.Log[] memory logs) internal view returns (uint24 fee) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    function _taken() internal view returns (uint256 platform, uint256 creator, uint256 tax) {
        platform = normalVault.platformAccrued();
        creator = normalVault.creatorAccrued();
        tax = taxVault.platformAccrued();
    }

    // ------------------------------------------------------------------
    // The launch
    // ------------------------------------------------------------------

    function test_launchIsAtomicLockedStartedAndBuysForTheDeveloper() public {
        _launch();
        FluxShell.PoolConfig memory cfg = shell.poolConfig(id);
        assertTrue(cfg.initialized && cfg.protectedLaunch, "protected and live");
        assertEq(uint8(cfg.lockType), uint8(FluxShell.LockType.Locked), "locked");
        assertEq(token.startedAt(), block.timestamp, "protection started");
        assertGt(token.balanceOf(dev), 0, "initial buy to the developer");
        assertLe(token.balanceOf(dev), token.walletTokenLimit(), "initial buy within 2%");
        assertEq(token.balanceOf(address(launcher)), 0, "launcher holds nothing");
        // The developer's initial buy pays the normal fee only (exempt from the opening tax).
        (uint256 p, uint256 c, uint256 t) = _taken();
        assertEq(t, 0, "no opening tax on the developer");
        assertEq(p + c, Math.mulDiv(0.01 ether, NORMAL_PPM, 1e6, Math.Rounding.Ceil), "normal fee on the initial buy");
    }

    function test_launchRefusesAValuationUnderFifteenThousandDollars() public {
        // At tick 198,000 the supply is worth ~2.5 ETH, about $7.5k at $3,000 per ETH: under the floor.
        vm.expectPartialRevert(FluxLauncher.OpeningValuationTooLow.selector);
        launcher.launchProtected{value: 0.01 ether}(_args(198_000));
    }

    function test_launchRefusesAStaleOrBadOracle() public {
        feed.set(3_000e8, block.timestamp - 2 hours);
        vm.expectRevert(FluxLauncher.InvalidOraclePrice.selector);
        launcher.launchProtected{value: 0.01 ether}(_args(START_TICK));
        feed.set(0, block.timestamp);
        vm.expectRevert(FluxLauncher.InvalidOraclePrice.selector);
        launcher.launchProtected{value: 0.01 ether}(_args(START_TICK));
    }

    function test_launchRefusesAnInitialBuyOverTwoPercent() public {
        vm.expectRevert();
        launcher.launchProtected{value: 1 ether}(_args(START_TICK)); // ~6.5% of supply
    }

    function test_liquidityCanNeverBeWithdrawn() public {
        _launch();
        vm.warp(block.timestamp + 3650 days);
        vm.prank(safe);
        vm.expectRevert(FluxShell.LiquidityLocked.selector);
        shell.withdrawLiquidity(pkey, 1);
    }

    // ------------------------------------------------------------------
    // Exact fee evidence
    // ------------------------------------------------------------------

    function test_firstSecondBuyPaysExactlyNinetyNinePercentWithZeroLpFee() public {
        _launch();
        (uint256 p0, uint256 c0, uint256 t0) = _taken();
        uint256 g = 0.2 ether;
        vm.recordLogs();
        _routerBuy(alice, g);
        assertEq(_lpFeeOfLastSwap(vm.getRecordedLogs()), 0, "LP fee is zero");
        (uint256 p, uint256 c, uint256 t) = _taken();
        p -= p0;
        c -= c0;
        t -= t0;
        assertEq(p + c + t, Math.mulDiv(g, 990_000, 1e6, Math.Rounding.Ceil), "total is exactly 99%");
        assertEq(p, Math.mulDiv(g, 30, 10_000, Math.Rounding.Ceil), "platform 0.3%");
        assertEq(p + c, Math.mulDiv(g, NORMAL_PPM, 1e6, Math.Rounding.Ceil), "normal fee");
    }

    function test_openingFeeDecaysLinearlyToNormalOverThirtySeconds() public {
        uint256 t0 = _launch();
        uint256[4] memory at = [uint256(1), 15, 29, 30];
        for (uint256 i; i < at.length; i++) {
            vm.warp(t0 + at[i]);
            (uint256 p0, uint256 c0, uint256 x0) = _taken();
            uint256 g = 0.05 ether;
            _routerBuy(bob, g);
            (uint256 p, uint256 c, uint256 x) = _taken();
            uint256 extra = at[i] >= 30 ? 0 : (990_000 - NORMAL_PPM) * (30 - at[i]) / 30;
            assertEq(
                (p - p0) + (c - c0) + (x - x0),
                Math.mulDiv(g, NORMAL_PPM + extra, 1e6, Math.Rounding.Ceil),
                "total at second"
            );
        }
    }

    function test_platformTakesThirtyBpsOnSellsToo() public {
        _launch();
        vm.warp(block.timestamp + 60);
        uint256 got = _routerBuy(alice, 0.1 ether);
        (uint256 p0, uint256 c0, uint256 t0) = _taken();
        // A sell through any router (here v4's test router): never authenticated, never taxed.
        vm.startPrank(alice);
        token.approve(address(swapRouter), got);
        uint256 before = alice.balance;
        vm.recordLogs();
        swapRouter.swap(
            pkey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(got), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        assertEq(_lpFeeOfLastSwap(vm.getRecordedLogs()), 0, "LP fee is zero on sells");
        uint256 received = alice.balance - before;
        (uint256 p, uint256 c, uint256 t) = _taken();
        uint256 gross = received + (p - p0) + (c - c0);
        assertEq(t - t0, 0, "sells never pay the opening tax");
        assertEq(p - p0, Math.mulDiv(gross, 30, 10_000, Math.Rounding.Ceil), "platform 0.3% of the gross ETH out");
        assertEq((p - p0) + (c - c0), Math.mulDiv(gross, NORMAL_PPM, 1e6, Math.Rounding.Ceil), "normal sell fee");
    }

    function test_custodyIsSeparateAndPaysOnlyFixedRecipients() public {
        _launch();
        _routerBuy(alice, 0.2 ether);
        (uint256 p, uint256 c, uint256 t) = _taken();
        assertGt(t, 0);
        // Each vault holds exactly its ledger in PoolManager claims; the shell holds none of it.
        assertEq(manager.balanceOf(address(normalVault), 0), p + c, "normal vault backing");
        assertEq(manager.balanceOf(address(taxVault), 0), t, "tax vault backing");
        assertEq(manager.balanceOf(address(shell), 0), 0, "shell custodies nothing");
        uint256 platformBefore = PLATFORM.balance;
        vm.prank(makeAddr("anyone"));
        normalVault.claimPlatform();
        vm.prank(makeAddr("anyone"));
        taxVault.claimPlatform();
        assertEq(PLATFORM.balance - platformBefore, p + t, "platform paid 0.3% plus the whole tax");
        normalVault.claimCreator();
        assertEq(creatorRecipient.balance, c, "creator paid the creator fee");
    }

    // ------------------------------------------------------------------
    // The canonical buyer path and the budgets
    // ------------------------------------------------------------------

    function test_buysOutsideTheCanonicalRouterAreRefusedDuringTheWindow() public {
        _launch();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        swapRouter.swap{value: 0.01 ether}(
            pkey,
            SwapParams({zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice) // the payload claims to be alice; it is never read
        );
        // After five minutes any router may buy.
        vm.warp(block.timestamp + 300);
        vm.prank(alice);
        swapRouter.swap{value: 0.01 ether}(
            pkey,
            SwapParams({zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_buyerBudgetIsCumulativeTwoPercent() public {
        _launch();
        vm.warp(block.timestamp + 30); // past the decay, so the tax doesn't shrink the buys
        _routerBuy(alice, 0.15 ether); // ~1% of supply
        _routerBuy(alice, 0.1 ether);
        vm.expectRevert();
        _routerBuy(alice, 0.15 ether); // over 2% in total
        // A different wallet has its own budget.
        _routerBuy(bob, 0.15 ether);
        // After the window there is no budget.
        vm.warp(block.timestamp + 300);
        _routerBuy(alice, 0.15 ether);
    }

    /// The shell's buyer budget on its own: one buyer, tokens sent to different recipients so no
    /// recipient comes near its own 2%. The buyer's cumulative purchases are still capped.
    function test_buyerBudgetHoldsEvenWhenTokensGoToOtherRecipients() public {
        _launch();
        vm.warp(block.timestamp + 30);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        MockUniversalRouter(CANONICAL_ROUTER).buyFor{value: 0.15 ether}(pkey, 0.15 ether, makeAddr("r1"));
        MockUniversalRouter(CANONICAL_ROUTER).buyFor{value: 0.1 ether}(pkey, 0.1 ether, makeAddr("r2"));
        vm.expectRevert();
        MockUniversalRouter(CANONICAL_ROUTER).buyFor{value: 0.15 ether}(pkey, 0.15 ether, makeAddr("r3"));
        vm.stopPrank();
        assertLt(token.balanceOf(makeAddr("r2")), token.walletTokenLimit(), "no recipient near its own cap");
    }

    function test_exemptWalletPaysNormalFeeOnlyButIsStillCapped() public {
        _launch();
        (uint256 p0, uint256 c0, uint256 t0) = _taken();
        _routerBuy(exempt, 0.1 ether);
        (uint256 p, uint256 c, uint256 t) = _taken();
        assertEq(t - t0, 0, "no opening tax");
        assertEq((p - p0) + (c - c0), Math.mulDiv(0.1 ether, NORMAL_PPM, 1e6, Math.Rounding.Ceil), "normal fee");
        vm.expectRevert();
        _routerBuy(exempt, 0.3 ether); // over 2% in total: capped like anyone
    }
}
