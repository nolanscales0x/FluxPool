// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {FluxShell} from "../../src/shell/FluxShell.sol";
import {ConfigurableCore} from "../mocks/HostileCores.sol";

/// @dev Runs the shell directly with a native ETH quote and a configurable mock core; the suites built on
/// FluxTestBase run the real core and blocks on native ETH and on WETH.
contract FluxShellTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint160 constant FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint24 constant BASE_FEE = 3_000; // 0.3%
    uint24 constant FEE_CAP = 50_000; // 5%
    uint24 constant LAUNCH_CAP = 990_000; // 99%
    uint32 constant WINDOW = 5; // seconds
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;
    uint128 constant SEED_LIQUIDITY = 100 ether;

    FluxShell shell;
    MockERC20 token;
    ConfigurableCore core;
    PoolKey poolKey;
    PoolId poolId;
    address creator = makeAddr("creator");

    function setUp() public {
        deployFreshManagerAndRouters();
        address hookAddr = address(FLAGS ^ (0x4444 << 144));
        deployCodeTo(
            "FluxShell.sol:FluxShell",
            abi.encode(
                manager, address(this), address(0), address(0), makeAddr("treasury"), CurrencyLibrary.ADDRESS_ZERO
            ),
            hookAddr
        );
        shell = FluxShell(payable(hookAddr));

        token = new MockERC20("Flux Test", "FLX", 18);
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(shell), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        core = new ConfigurableCore();
        core.set(ConfigurableCore.Mode.Answer, BASE_FEE, 1);
        vm.deal(address(this), 1_000 ether);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(shell))
        });
    }

    function _setup(FluxShell.LockType lockType, uint64 unlockAt) internal view returns (FluxShell.PoolSetup memory) {
        return FluxShell.PoolSetup({
            sqrtPriceX96: SQRT_PRICE_1_1,
            core: address(core),
            token: address(token),
            creator: creator,
            creatorFeeRecipient: address(0),
            baseFee: BASE_FEE,
            feeCap: FEE_CAP,
            launchFeeCap: LAUNCH_CAP,
            launchWindow: WINDOW,
            timelockDelay: 48 hours,
            lockType: lockType,
            unlockAt: unlockAt,
            launchMode: 0
        });
    }

    function _launch(FluxShell.LockType lockType, uint64 unlockAt) internal {
        poolKey = _key();
        poolId = poolKey.toId();
        shell.stagePool(poolKey, _setup(lockType, unlockAt));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        shell.seedLiquidity{value: 200 ether}(poolKey, TICK_LOWER, TICK_UPPER, SEED_LIQUIDITY);
    }

    function _launchAndSkipWindow() internal {
        _launch(FluxShell.LockType.Locked, 0);
        vm.warp(block.timestamp + WINDOW);
    }

    function _buy(uint256 ethIn) internal {
        swapRouter.swap{value: ethIn}(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _sell(uint256 tokensIn) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Runs a swap and returns the LP fee the PoolManager actually charged.
    function _feeOf(bool isBuy, uint256 amount) internal returns (uint24) {
        vm.recordLogs();
        if (isBuy) _buy(amount);
        else _sell(amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event");
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------

    function test_registersPoolOnAfterInitialize() public {
        _launch(FluxShell.LockType.Locked, 0);
        FluxShell.PoolConfig memory cfg = shell.poolConfig(poolId);
        assertTrue(cfg.initialized);
        assertEq(cfg.core, address(core));
        assertEq(cfg.token, address(token));
        assertEq(cfg.creator, creator);
        assertEq(cfg.launchStart, block.timestamp);
        assertFalse(cfg.tokenIsCurrency0);
        (,, bool seeded) = shell.positions(poolId);
        assertTrue(seeded);
    }

    function test_hookAddressMatchesPermissions() public view {
        Hooks.validateHookPermissions(IHooks(address(shell)), shell.getHookPermissions());
    }

    function test_revertsInitializeOfUnstagedPool() public {
        vm.expectRevert();
        manager.initialize(_key(), SQRT_PRICE_1_1);
    }

    function test_anyoneCanInitializeAStagedPoolAtTheStagedPrice() public {
        // Under Custom Launch, Programmable's router initializes the pool, not the launch adapter.
        shell.stagePool(_key(), _setup(FluxShell.LockType.Locked, 0));
        vm.prank(makeAddr("programmable-router"));
        manager.initialize(_key(), SQRT_PRICE_1_1);
        assertTrue(shell.poolConfig(_key().toId()).initialized);
    }

    function test_revertsInitializeAtAnyOtherPrice() public {
        shell.stagePool(_key(), _setup(FluxShell.LockType.Locked, 0));
        vm.prank(makeAddr("front-runner"));
        vm.expectRevert();
        manager.initialize(_key(), SQRT_PRICE_1_2);
    }

    // ------------------------------------------------------------------
    // Price reference for playbook trigger checks
    // ------------------------------------------------------------------

    function test_recordsInitialPriceAtInitialize() public {
        _launch(FluxShell.LockType.Locked, 0);
        assertEq(shell.observationCount(poolId), 1);
        FluxShell.Observation memory o = shell.latestObservation(poolId);
        assertEq(o.blockNumber, block.number);
        assertEq(o.tick, 0);
    }

    function test_recordsStartOfBlockPriceOncePerBlock() public {
        _launchAndSkipWindow();
        vm.roll(block.number + 1);
        _buy(1 ether);
        _buy(1 ether); // same block: no new observation, and the recorded price ignores in-block moves
        assertEq(shell.observationCount(poolId), 2);
        assertEq(shell.latestObservation(poolId).tick, 0);

        vm.roll(block.number + 1);
        _sell(0.5 ether);
        assertEq(shell.observationCount(poolId), 3);
        assertLt(shell.latestObservation(poolId).tick, 0); // buys pushed currency1 per currency0 down
    }

    function test_observeReturnsPriceFromBlocksAgo() public {
        _launchAndSkipWindow();
        uint256 startBlock = block.number;
        for (uint256 i = 1; i <= 5; i++) {
            vm.roll(startBlock + i * 10);
            _buy(1 ether);
        }
        // Last observation is at startBlock + 50. 25 blocks ago -> the one at startBlock + 20.
        FluxShell.Observation memory o = shell.observe(poolId, 25);
        assertEq(o.blockNumber, startBlock + 20);
        assertLt(shell.latestObservation(poolId).tick, o.tick);
    }

    function test_observationBufferWraps() public {
        _launchAndSkipWindow();
        uint256 n = shell.OBSERVATIONS() + 10;
        for (uint256 i = 1; i <= n; i++) {
            vm.roll(block.number + 1);
            _buy(0.01 ether);
        }
        assertEq(shell.observationCount(poolId), n + 1);
        // Asking further back than the buffer holds reverts instead of returning a wrong price.
        vm.expectRevert(FluxShell.NoObservation.selector);
        shell.observe(poolId, n);
    }

    function test_revertsStageByNonLauncher() public {
        FluxShell.PoolSetup memory s = _setup(FluxShell.LockType.Locked, 0);
        PoolKey memory k = _key();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FluxShell.NotLauncher.selector);
        shell.stagePool(k, s);
    }

    function test_revertsStageTwice() public {
        shell.stagePool(_key(), _setup(FluxShell.LockType.Locked, 0));
        FluxShell.PoolSetup memory s = _setup(FluxShell.LockType.Locked, 0);
        PoolKey memory k = _key();
        vm.expectRevert(FluxShell.AlreadyStaged.selector);
        shell.stagePool(k, s);
    }

    function test_revertsInvalidSetups() public {
        PoolKey memory k = _key();
        FluxShell.PoolSetup memory s;

        k.fee = 3000; // static fee pool
        s = _setup(FluxShell.LockType.Locked, 0);
        vm.expectRevert(FluxShell.InvalidSetup.selector);
        shell.stagePool(k, s);
        k = _key();

        s.feeCap = shell.MAX_FEE_CAP() + 1;
        vm.expectRevert(FluxShell.InvalidSetup.selector);
        shell.stagePool(k, s);

        s = _setup(FluxShell.LockType.Locked, 0);
        s.launchFeeCap = shell.MAX_LAUNCH_FEE_CAP() + 1;
        vm.expectRevert(FluxShell.InvalidSetup.selector);
        shell.stagePool(k, s);

        s = _setup(FluxShell.LockType.Locked, 0);
        s.baseFee = FEE_CAP + 1;
        vm.expectRevert(FluxShell.InvalidSetup.selector);
        shell.stagePool(k, s);

        s = _setup(FluxShell.LockType.Locked, 0);
        s.timelockDelay = 1 hours;
        vm.expectRevert(FluxShell.InvalidSetup.selector);
        shell.stagePool(k, s);

        s = _setup(FluxShell.LockType.TimeLocked, uint64(block.timestamp)); // unlock not in future
        vm.expectRevert(FluxShell.InvalidSetup.selector);
        shell.stagePool(k, s);

        s = _setup(FluxShell.LockType.Locked, 0);
        s.token = makeAddr("not-in-pool");
        vm.expectRevert(FluxShell.InvalidSetup.selector);
        shell.stagePool(k, s);
    }

    // ------------------------------------------------------------------
    // Protection 1: fee cap
    // ------------------------------------------------------------------

    function test_wellBehavedCoreFeeIsCharged() public {
        _launchAndSkipWindow();
        core.set(ConfigurableCore.Mode.Answer, 10_000, 1);
        assertEq(_feeOf(true, 0.1 ether), 10_000);
        assertEq(_feeOf(false, 0.1 ether), 10_000);
    }

    function test_hugeFeeIsClampedToCap() public {
        _launchAndSkipWindow();
        core.set(ConfigurableCore.Mode.Answer, type(uint24).max, 1);
        assertEq(_feeOf(true, 0.1 ether), FEE_CAP);
        assertEq(_feeOf(false, 0.1 ether), FEE_CAP);
    }

    function test_launchWindowUsesLaunchCapThenNormalCap() public {
        _launch(FluxShell.LockType.Locked, 0);
        core.set(ConfigurableCore.Mode.Answer, type(uint24).max, 1);
        assertEq(shell.activeFeeCap(poolId), LAUNCH_CAP);
        assertEq(_feeOf(true, 0.1 ether), LAUNCH_CAP);

        vm.warp(block.timestamp + WINDOW);
        assertEq(shell.activeFeeCap(poolId), FEE_CAP);
        assertEq(_feeOf(true, 0.1 ether), FEE_CAP);
    }

    // ------------------------------------------------------------------
    // Protection 2: sells are never blocked; broken cores fall back safely
    // ------------------------------------------------------------------

    function test_rejectingCoreBlocksBuysButNotSells() public {
        _launchAndSkipWindow();
        core.set(ConfigurableCore.Mode.Answer, BASE_FEE, 0);
        vm.expectRevert();
        _buy(0.1 ether);
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
    }

    function test_revertingCoreFallsBackToBaseFee() public {
        _launchAndSkipWindow();
        core.set(ConfigurableCore.Mode.Revert, 0, 0);
        assertEq(_feeOf(true, 0.1 ether), BASE_FEE);
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
    }

    function test_gasBurningCoreFallsBackToBaseFee() public {
        _launchAndSkipWindow();
        core.set(ConfigurableCore.Mode.BurnGas, 0, 0);
        assertEq(_feeOf(true, 0.1 ether), BASE_FEE);
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
    }

    function test_shortReturnDataFallsBack() public {
        _launchAndSkipWindow();
        core.set(ConfigurableCore.Mode.ShortReturn, FEE_CAP, 0);
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
    }

    function test_outOfRangeWordsFallBack() public {
        _launchAndSkipWindow();
        // fee wider than uint24 and allow that isn't a bool: treated as a failed core
        core.set(ConfigurableCore.Mode.RawWords, uint256(1) << 200, 7);
        assertEq(_feeOf(true, 0.1 ether), BASE_FEE);
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
    }

    function test_returnBombFallsBackOrClamps() public {
        _launchAndSkipWindow();
        core.set(ConfigurableCore.Mode.ReturnBomb, type(uint24).max, 0);
        // Whether the bomb runs the core out of gas or returns, a sell must go through under the cap.
        assertLe(_feeOf(false, 0.1 ether), FEE_CAP);
    }

    function test_coreWithNoCodeFallsBack() public {
        poolKey = _key();
        poolId = poolKey.toId();
        FluxShell.PoolSetup memory s = _setup(FluxShell.LockType.Locked, 0);
        s.core = makeAddr("eoa-core");
        shell.stagePool(poolKey, s);
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        shell.seedLiquidity{value: 200 ether}(poolKey, TICK_LOWER, TICK_UPPER, SEED_LIQUIDITY);
        vm.warp(block.timestamp + WINDOW);
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
        assertEq(_feeOf(true, 0.1 ether), BASE_FEE);
    }

    function test_brokenCoreDuringLaunchWindowChargesBuysTheLaunchCap() public {
        _launch(FluxShell.LockType.Locked, 0);
        core.set(ConfigurableCore.Mode.Revert, 0, 0);
        assertEq(_feeOf(true, 0.1 ether), LAUNCH_CAP);
        assertEq(_feeOf(false, 0.01 ether), BASE_FEE);
    }

    function test_afterSwapFailureDoesNotBlockTrade() public {
        _launchAndSkipWindow();
        core.setRevertAfterSwap(true);
        _sell(0.1 ether);
        _buy(0.1 ether);
        core.setRevertAfterSwap(false);
        _sell(0.1 ether);
        assertEq(core.afterSwapCalls(), 1);
    }

    function test_starvingTheCoreOfGasRevertsInsteadOfSkippingIt() public {
        _launch(FluxShell.LockType.Locked, 0);
        core.set(ConfigurableCore.Mode.Answer, LAUNCH_CAP, 0); // anti-sniper: reject buys in window
        core.setWork(200_000); // a realistic lane of blocks, so a starved core can run out of gas
        SwapParams memory p =
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Sweep gas limits: no amount of gas lets a rejected buy succeed via the fallback path.
        // Note: the EVM's 63/64 rule already makes this hold (a starved core leaves the shell too
        // little gas to finish the swap); the shell's up-front gas check is defense in depth and
        // gives a clear InsufficientGasForCore error. Mutation-tested: this passes without it.
        for (uint256 g = 150_000; g < 900_000; g += 5_000) {
            try swapRouter.swap{value: 0.1 ether, gas: g}(poolKey, p, ts, ZERO_BYTES) {
                revert("buy got through");
            } catch {}
        }
    }

    // ------------------------------------------------------------------
    // Protection 3: liquidity lock
    // ------------------------------------------------------------------

    function test_externalLiquidityIsRejected() public {
        _launch(FluxShell.LockType.Locked, 0);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(
            poolKey, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0}), ZERO_BYTES
        );
    }

    function test_lockedLiquidityCanNeverBeWithdrawn() public {
        _launch(FluxShell.LockType.Locked, 0);
        vm.warp(block.timestamp + 100 * 365 days);
        vm.prank(creator);
        vm.expectRevert(FluxShell.LiquidityLocked.selector);
        shell.withdrawLiquidity(poolKey, 1 ether);
    }

    function test_timeLockedLiquidityUnlocksOnSchedule() public {
        uint64 unlockAt = uint64(block.timestamp + 30 days);
        _launch(FluxShell.LockType.TimeLocked, unlockAt);

        vm.prank(creator);
        vm.expectRevert(FluxShell.LiquidityLocked.selector);
        shell.withdrawLiquidity(poolKey, 1 ether);

        vm.warp(unlockAt);
        uint256 before = token.balanceOf(creator);
        vm.prank(creator);
        shell.withdrawLiquidity(poolKey, 1 ether);
        assertGt(token.balanceOf(creator), before);
        assertGt(creator.balance, 0);
    }

    function test_onlyCreatorCanWithdraw() public {
        _launch(FluxShell.LockType.Unlocked, 0);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FluxShell.NotCreator.selector);
        shell.withdrawLiquidity(poolKey, 1 ether);
    }

    function test_withdrawKeepsAccruedFeesInShell() public {
        _launchAndSkipWindow();
        _launchUnlockedTwin();
        core.set(ConfigurableCore.Mode.Answer, 10_000, 1);
        _buy(1 ether);
        _sell(1 ether);
        uint256 creatorEthBefore = creator.balance;
        vm.prank(creator);
        shell.withdrawLiquidity(poolKey, SEED_LIQUIDITY);
        (uint256 fee0, uint256 fee1) = shell.pendingFees(poolId);
        assertGt(fee0, 0);
        assertGt(fee1, 0);
        // shell holds exactly the pending native fees
        assertEq(address(shell).balance, fee0);
        assertEq(token.balanceOf(address(shell)), fee1);
        assertGt(creator.balance, creatorEthBefore);
    }

    /// @dev Replaces the current pool with an unlocked one using a fresh token.
    function _launchUnlockedTwin() internal {
        token = new MockERC20("Flux Twin", "FLX2", 18);
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(shell), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        _launch(FluxShell.LockType.Unlocked, 0);
        vm.warp(block.timestamp + WINDOW);
    }

    function test_seedRefundsOnlyExcessEth() public {
        _launchAndSkipWindow();
        uint256 balBefore = address(this).balance;
        uint256 shellBefore = address(shell).balance;
        token = new MockERC20("Flux Three", "FLX3", 18);
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(shell), type(uint256).max);
        poolKey = _key();
        shell.stagePool(poolKey, _setup(FluxShell.LockType.Locked, 0));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        shell.seedLiquidity{value: 500 ether}(poolKey, TICK_LOWER, TICK_UPPER, SEED_LIQUIDITY);
        assertEq(address(shell).balance, shellBefore);
        assertGt(address(this).balance, balBefore - 500 ether);
    }

    // ------------------------------------------------------------------
    // Fuzz: whatever the core answers, sells go through and fees stay under the cap
    // ------------------------------------------------------------------

    function testFuzz_anyCoreAnswerNeverBlocksSellOrExceedsCap(
        uint8 modeSeed,
        uint256 w0,
        uint256 w1,
        uint256 amount,
        bool inWindow
    ) public {
        _launch(FluxShell.LockType.Locked, 0);
        if (!inWindow) vm.warp(block.timestamp + WINDOW);
        ConfigurableCore.Mode mode = ConfigurableCore.Mode(modeSeed % 6);
        core.set(mode, w0, w1);
        amount = bound(amount, 1e9, 5 ether);

        uint24 cap = shell.activeFeeCap(poolId);
        uint24 sellFee = _feeOf(false, amount);
        assertLe(sellFee, cap);

        // Buys may be rejected, but if they go through they respect the cap.
        try this.feeOfExternal(true, amount) returns (uint24 buyFee) {
            assertLe(buyFee, cap);
        } catch {}
    }

    function feeOfExternal(bool isBuy, uint256 amount) external returns (uint24) {
        require(msg.sender == address(this));
        return _feeOf(isBuy, amount);
    }
}
