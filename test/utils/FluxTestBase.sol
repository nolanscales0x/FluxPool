// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {FixedSupplyToken} from "../mocks/FixedSupplyToken.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {FluxShell} from "../../src/shell/FluxShell.sol";
import {FluxCore} from "../../src/core/FluxCore.sol";
import {CreatorFee} from "../../src/blocks/CreatorFee.sol";
import {AntiSnipe, IShellLaunchInfo} from "../../src/blocks/AntiSnipe.sol";
import {AdaptiveFee} from "../../src/blocks/AdaptiveFee.sol";
import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {ChangeRegistry} from "../../src/gates/ChangeRegistry.sol";
import {PlaybookRegistry} from "../../src/playbooks/PlaybookRegistry.sol";
import {IFluxShellGovernance} from "../../src/interfaces/IFluxShellGovernance.sol";
import {IChangeQueue} from "../../src/interfaces/IChangeQueue.sol";

/// @notice Deploys the real shell, core implementation and starting blocks on a fresh PoolManager,
/// and launches pools the way the launch adapter will: clone and initialize a core, stage the pool,
/// initialize it, seed shell-held liquidity.
///
/// Pools pair the token with native ETH by default, as on Ethereum: ETH is address(0), so the token is
/// always currency1. WETH stays supported: `_wethQuote()` pairs with WETH at a very low address (token
/// is currency1), and `_tokenFirst()` pairs with WETH at a very high address (token is currency0).
abstract contract FluxTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 constant FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint24 constant BASE_FEE = 3_000;
    uint24 constant FEE_CAP = 50_000;
    uint24 constant LAUNCH_CAP = 990_000;
    uint32 constant WINDOW = 5;
    int24 constant TICK_LOWER = -887_220;
    int24 constant TICK_UPPER = 887_220;
    uint128 constant SEED_LIQUIDITY = 100 ether;

    FluxShell shell;
    FluxCore coreImpl;
    CreatorFee creatorFee;
    AntiSnipe antiSnipe;
    AdaptiveFee adaptiveFee;
    AgentRegistry agentRegistry;
    ChangeRegistry changeRegistry;
    PlaybookRegistry playbookRegistry;

    /// @dev The core's change-registry slot. Block tests use this contract so they can write settings
    /// directly; ChangeRegistry tests override _coreGate() to wire the real registry.
    address gate;
    uint8 launchMode; // 0 Guarded, 1 Fast, 2 Wild
    // Pool fee settings used by _launch; tests may change them before launching.
    uint24 poolBaseFee = BASE_FEE;
    uint24 poolFeeCap = FEE_CAP;
    uint24 poolLaunchCap = LAUNCH_CAP;
    address playbooks; // the PlaybookRegistry's address
    address treasury = makeAddr("treasury");
    address attesterManager = makeAddr("attester-manager");
    address creator = makeAddr("creator");

    FixedSupplyToken token;
    WETH weth;
    Currency quote;
    uint256 constant TOKEN_SUPPLY = 10_000_000 ether;
    PoolKey poolKey;
    PoolId poolId;
    FluxCore core;
    uint256 tokenNonce;

    function setUp() public virtual {
        _deployManagerAndRouters();
        address hookAddr = address(FLAGS ^ (0x4444 << 144));
        if (_usesWeth()) {
            address wethAddr = _tokenFirst()
                ? address(uint160(type(uint160).max) - 0xFFFF)  // above any token: token is currency0
                : address(0x0000000000000000000000000000000000001111); // below any token: token is currency1
            deployCodeTo("WETH.sol:WETH", wethAddr);
            weth = WETH(payable(wethAddr));
            quote = Currency.wrap(wethAddr);
        } else {
            quote = CurrencyLibrary.ADDRESS_ZERO;
        }

        // AgentRegistry and ChangeRegistry each need the other's address: predict it, as the
        // deploy script will.
        uint64 nonce = vm.getNonce(address(this));
        address predictedChange = vm.computeCreateAddress(address(this), nonce + 2);
        playbooks = vm.computeCreateAddress(address(this), nonce + 3);
        creatorFee = new CreatorFee();
        agentRegistry = new AgentRegistry(IFluxShellGovernance(hookAddr), IChangeQueue(predictedChange), playbooks);
        changeRegistry = new ChangeRegistry(IFluxShellGovernance(hookAddr), agentRegistry, attesterManager);
        assertEq(address(changeRegistry), predictedChange);
        playbookRegistry = new PlaybookRegistry(IFluxShellGovernance(hookAddr), agentRegistry);
        assertEq(address(playbookRegistry), playbooks);

        deployCodeTo(
            "FluxShell.sol:FluxShell",
            abi.encode(manager, address(this), address(creatorFee), address(agentRegistry), treasury, quote),
            hookAddr
        );
        shell = FluxShell(payable(hookAddr));
        gate = _coreGate();
        coreImpl = new FluxCore(manager, address(shell), gate, playbooks);
        antiSnipe = new AntiSnipe(manager, IShellLaunchInfo(address(shell)));
        adaptiveFee = new AdaptiveFee(manager, IShellLaunchInfo(address(shell)));
        vm.deal(address(this), 200_000 ether);
        if (_usesWeth()) {
            weth.deposit{value: 100_000 ether}();
            weth.approve(address(shell), type(uint256).max);
            weth.approve(address(swapRouter), type(uint256).max);
        }
    }

    /// @dev Override to put the token below WETH (token = currency0). Implies a WETH quote, since native
    /// ETH (address(0)) always sorts first.
    function _tokenFirst() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev Override to pair with WETH instead of native ETH, with the token as currency1.
    function _wethQuote() internal pure virtual returns (bool) {
        return false;
    }

    function _usesWeth() internal pure returns (bool) {
        return _wethQuote() || _tokenFirst();
    }

    function _nativeQuote() internal view returns (bool) {
        return quote.isAddressZero();
    }

    /// @dev ETH to send with a call that may pay the quote: the full amount for exact-in, and a
    /// generous buffer otherwise (the v4 test routers refund what isn't used).
    function _quoteValue(bool paysQuote, int256 amountSpecified, address payer) internal view returns (uint256) {
        if (!_nativeQuote() || !paysQuote) return 0;
        if (amountSpecified < 0) return uint256(-amountSpecified);
        return payer.balance;
    }

    function _tokenIs0() internal view returns (bool) {
        return Currency.unwrap(poolKey.currency0) == address(token);
    }

    /// @dev Gives `who` `amount` of the quote (ETH, or WETH approved to the swap router).
    function _fundQuote(address who, uint256 amount) internal {
        if (_nativeQuote()) {
            vm.deal(who, who.balance + amount);
            return;
        }
        weth.transfer(who, amount);
        vm.prank(who);
        weth.approve(address(swapRouter), type(uint256).max);
    }

    function _quoteBalance(address who) internal view returns (uint256) {
        return _nativeQuote() ? who.balance : weth.balanceOf(who);
    }

    /// @dev zeroForOne for a buy (paying the quote for the token).
    function _buyDir() internal view returns (bool) {
        return !_tokenIs0();
    }

    /// @dev A fresh local PoolManager by default. With FORK_RPC_URL set, forks that chain and uses the
    /// PoolManager at POOL_MANAGER (required then; verify it against Uniswap's deployment list).
    /// The RPC URL isn't a secret, so an empty default is fine here.
    function _deployManagerAndRouters() internal {
        string memory forkUrl = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            deployFreshManagerAndRouters();
            return;
        }
        vm.createSelectFork(forkUrl);
        manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        // On a live chain these addresses can already hold stray ETH, which the test routers would
        // refund to the trader after each swap and skew balance checks.
        vm.deal(address(swapRouter), 0);
        vm.deal(address(modifyLiquidityRouter), 0);
    }

    /// @dev Called during _launch once the token and pool key exist. Zero pays the creator.
    function _feeRecipient() internal virtual returns (address) {
        return address(0);
    }

    function _coreGate() internal view virtual returns (address) {
        return address(this);
    }

    function _launch(address[] memory beforeSwap, address[] memory afterSwap, FluxCore.SettingInit[] memory settings)
        internal
    {
        _launch(beforeSwap, afterSwap, settings, WINDOW);
    }

    function _launch(
        address[] memory beforeSwap,
        address[] memory afterSwap,
        FluxCore.SettingInit[] memory settings,
        uint32 window
    ) internal {
        token = new FixedSupplyToken(
            "Flux Test", string.concat("FLX", vm.toString(++tokenNonce)), TOKEN_SUPPLY, address(this)
        );
        token.approve(address(shell), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        Currency t = Currency.wrap(address(token));
        bool tokenIs0 = address(token) < Currency.unwrap(quote);
        require(tokenIs0 == _tokenFirst(), "token ordering");
        poolKey = PoolKey({
            currency0: tokenIs0 ? t : quote,
            currency1: tokenIs0 ? quote : t,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(shell))
        });
        poolId = poolKey.toId();

        core = FluxCore(Clones.clone(address(coreImpl)));
        core.initialize(poolKey, poolBaseFee, beforeSwap, afterSwap, settings);
        address feeRecipient = _feeRecipient();

        shell.stagePool(
            poolKey,
            FluxShell.PoolSetup({
                sqrtPriceX96: SQRT_PRICE_1_1,
                core: address(core),
                token: address(token),
                creator: creator,
                creatorFeeRecipient: feeRecipient,
                baseFee: poolBaseFee,
                feeCap: poolFeeCap,
                launchFeeCap: poolLaunchCap,
                launchWindow: window,
                timelockDelay: 48 hours,
                lockType: FluxShell.LockType.Locked,
                unlockAt: 0,
                launchMode: launchMode,
                protectedLaunch: false,
                protectionModule: address(0),
                normalFeeVault: address(0),
                openingTaxVault: address(0),
                normalBuyFeeBps: 0,
                normalSellFeeBps: 0
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        // A native quote is sent as value; the shell refunds what the position didn't need.
        shell.seedLiquidity{value: _nativeQuote() ? 2 * uint256(SEED_LIQUIDITY) : 0}(
            poolKey, TICK_LOWER, TICK_UPPER, SEED_LIQUIDITY
        );
        // The core and the shell must agree on which side the token is (a mismatch flips buys and sells).
        assertEq(core.tokenIsCurrency0(), shell.poolConfig(poolId).tokenIsCurrency0, "core/shell token side");
        assertEq(core.tokenIsCurrency0(), tokenIs0, "token side");
    }

    /// @dev Registers an agent as the creator would, waiting out the timelock when it applies.
    function _registerAgent(address agent, AgentRegistry.Level level) internal {
        vm.prank(creator);
        uint256 id = agentRegistry.setAgent(poolId, agent, uint8(level));
        if (id != 0) {
            vm.warp(block.timestamp + 48 hours);
            changeRegistry.execute(id);
        }
    }

    function _skipWindow() internal {
        vm.warp(block.timestamp + WINDOW);
    }

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _one(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _noSettings() internal pure returns (FluxCore.SettingInit[] memory) {
        return new FluxCore.SettingInit[](0);
    }

    /// @dev Exact-in buy: `quoteIn` of the quote for tokens.
    function _buy(uint256 quoteIn) internal {
        _swap(_buyDir(), -int256(quoteIn), ZERO_BYTES);
    }

    /// @dev Exact-in sell: `tokensIn` tokens for the quote.
    function _sell(uint256 tokensIn) internal {
        _swap(!_buyDir(), -int256(tokensIn), ZERO_BYTES);
    }

    /// @dev Swaps from this contract. With a native quote, a buy sends ETH as value.
    function _swap(bool zeroForOne, int256 amountSpecified, bytes memory hookData) internal returns (BalanceDelta) {
        return swapRouter.swap{value: _quoteValue(zeroForOne == _buyDir(), amountSpecified, address(this))}(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev Runs a swap and returns the LP fee the PoolManager charged.
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

    /// @dev External wrapper so tests can try/catch a swap.
    function feeOfExternal(bool isBuy, uint256 amount) external returns (uint24) {
        require(msg.sender == address(this));
        return _feeOf(isBuy, amount);
    }

    function _buyReverts(uint256 ethIn) internal returns (bool) {
        try this.feeOfExternal(true, ethIn) {
            return false;
        } catch {
            return true;
        }
    }
}
