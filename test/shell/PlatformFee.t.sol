// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {FluxShell} from "../../src/shell/FluxShell.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";
import {FeeBlock, CallLog, HostileBlock} from "../mocks/TestBlocks.sol";
import {FixedSupplyToken} from "../mocks/FixedSupplyToken.sol";

/// @notice Programmable's 0.30% platform fee: gross quote leg, rounded up per trade, on every buy and
/// sell, held as backed quote claims and paid only to the fixed recipient. The concrete suites below
/// run every test with native ETH and with WETH on each side of the token.
abstract contract PlatformFeeTestBase is FluxTestBase {
    address trader = makeAddr("trader");
    address recipient;

    function setUp() public override {
        super.setUp();
        recipient = shell.PLATFORM_RECIPIENT();
        _launch(_none(), _none(), _noSettings());
        _skipWindow();
        _fundQuote(trader, 1_000 ether);
        _fundTrader();
    }

    /// @dev Every launch makes a new token, so the trader needs a balance of the current one.
    function _fundTrader() internal {
        token.transfer(trader, 1_000 ether);
        vm.prank(trader);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function _ceilFee(uint256 gross) internal pure returns (uint256) {
        return Math.mulDiv(gross, 30, 10_000, Math.Rounding.Ceil);
    }

    /// @dev amountSpecified < 0 is exact input, > 0 exact output (v4 convention).
    function _swapAs(bool isBuy, int256 amountSpecified) internal {
        bool zeroForOne = isBuy ? _buyDir() : !_buyDir();
        uint256 value = _quoteValue(isBuy, amountSpecified, trader);
        vm.prank(trader);
        swapRouter.swap{value: value}(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _onTop(uint256 net) internal view returns (uint256 fee) {
        (, fee) = shell.quotePlatformFee(net, true);
    }

    function _backed() internal view {
        assertEq(manager.balanceOf(address(shell), quote.toId()), shell.platformAccrued());
    }

    // ------------------------------------------------------------------
    // The four swap shapes
    // ------------------------------------------------------------------

    function test_exactInputBuyChargesThirtyBpsOfWethIn() public {
        uint256 quoteIn = 1 ether;
        uint256 before = _quoteBalance(trader);
        _swapAs(true, -int256(quoteIn));
        assertEq(before - _quoteBalance(trader), quoteIn);
        assertEq(shell.platformAccrued(), _ceilFee(quoteIn));
        assertEq(shell.platformAccrued(), 0.003 ether);
        _backed();
    }

    function test_exactInputSellChargesThirtyBpsOfGrossWethOut() public {
        uint256 before = _quoteBalance(trader);
        _swapAs(false, -1 ether);
        uint256 received = _quoteBalance(trader) - before;
        uint256 fee = shell.platformAccrued();
        assertGt(received, 0);
        assertEq(fee, _ceilFee(received + fee));
        _backed();
    }

    function test_exactOutputBuyAddsFeeOnTopOfWethIn() public {
        uint256 before = _quoteBalance(trader);
        _swapAs(true, 0.5 ether); // exactly 0.5 tokens out
        uint256 paid = before - _quoteBalance(trader);
        uint256 fee = shell.platformAccrued();
        assertEq(fee, _onTop(paid - fee));
        assertGe(fee * 10_000, paid * 30); // at least 30 bps of the gross quote paid
        _backed();
    }

    function test_exactOutputSellDeliversExactWethAndChargesOnTop() public {
        uint256 quoteOut = 0.5 ether;
        uint256 before = _quoteBalance(trader);
        _swapAs(false, int256(quoteOut));
        assertEq(_quoteBalance(trader) - before, quoteOut);
        assertEq(shell.platformAccrued(), _onTop(quoteOut));
        _backed();
    }

    // ------------------------------------------------------------------
    // Always charged, whatever the core or blocks do
    // ------------------------------------------------------------------

    function test_chargedOnTheFirstBuyInTheLaunchWindow() public {
        _launch(_none(), _none(), _noSettings()); // fresh pool, still in its window
        _swapAs(true, -1 ether);
        assertEq(shell.platformAccrued(), 0.003 ether);
    }

    function test_chargedOnTopOfAProjectFeeAtTheCap() public {
        FeeBlock big = new FeeBlock(1, new CallLog(), 900_000);
        _launch(_one(address(big)), _none(), _noSettings());
        _skipWindow();
        assertEq(_feeOf(true, 1 ether), FEE_CAP); // project fee clamped...
        assertEq(shell.platformAccrued(), 0.003 ether); // ...platform fee still exactly 30 bps
    }

    function test_chargedWhenTheCoreAndBlocksFail() public {
        HostileBlock h = new HostileBlock(manager);
        h.set(HostileBlock.Mode.TakeFunds, address(0));
        _launch(_one(address(h)), _one(address(h)), _noSettings());
        _skipWindow();
        _fundTrader();
        _swapAs(true, -1 ether);
        _swapAs(false, -1 ether);
        assertGt(shell.platformAccrued(), 0.003 ether);
        _backed();
    }

    function test_zeroAmountSwapReverts() public {
        vm.expectRevert();
        _swapAs(true, 0);
    }

    // ------------------------------------------------------------------
    // Claim
    // ------------------------------------------------------------------

    function test_claimPaysOnlyTheFixedRecipientInWeth() public {
        _swapAs(true, -1 ether);
        _swapAs(false, -1 ether);
        uint256 owed = shell.platformAccrued();
        uint256 before = _quoteBalance(recipient);
        vm.prank(makeAddr("anyone"));
        assertEq(shell.claimPlatform(), owed);
        assertEq(_quoteBalance(recipient) - before, owed);
        assertEq(shell.platformAccrued(), 0);
        _backed();
        vm.expectRevert(FluxShell.NothingToClaim.selector);
        shell.claimPlatform();
    }

    function test_platformFeesStaySeparateFromTheProjectSplit() public {
        FeeBlock fee = new FeeBlock(1, new CallLog(), 7_000);
        _launch(_one(address(fee)), _none(), _noSettings());
        _skipWindow();
        _fundTrader();
        _swapAs(true, -1 ether);
        _swapAs(false, -1 ether);
        uint256 platform = shell.platformAccrued();
        shell.collect(poolKey);
        shell.claimPlatform();
        // Project fees were split from LP fees only; the platform's claims weren't touched.
        assertEq(_quoteBalance(address(shell)), shell.claimable(creator, quote) + shell.claimable(treasury, quote));
        assertGt(platform, 0);
    }

    function test_rejectsPoolsNotPairedWithTheQuote() public {
        FixedSupplyToken other = new FixedSupplyToken("Other", "OTH", 1 ether, address(this));
        Currency t = Currency.wrap(address(token));
        Currency o = Currency.wrap(address(other));
        bool tokenIs0 = address(token) < address(other);
        PoolKey memory k = poolKey;
        k.currency0 = tokenIs0 ? t : o;
        k.currency1 = tokenIs0 ? o : t;
        FluxShell.PoolSetup memory s = FluxShell.PoolSetup({
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
            lockType: FluxShell.LockType.Locked,
            unlockAt: 0,
            launchMode: 0,
            protectedLaunch: false,
            protectionModule: address(0),
            normalFeeVault: address(0),
            openingTaxVault: address(0),
            normalBuyFeeBps: 0,
            normalSellFeeBps: 0
        });
        vm.expectRevert(FluxShell.InvalidSetup.selector);
        shell.stagePool(k, s);
    }

    // ------------------------------------------------------------------
    // Fuzz: every shape, every size: exactly the reference formula, always backed
    // ------------------------------------------------------------------

    function testFuzz_feeMatchesReferenceFormula(bool isBuy, bool exactIn, uint256 amount) public {
        amount = bound(amount, 1e9, 5 ether);
        uint256 before = _quoteBalance(trader);
        _swapAs(isBuy, exactIn ? -int256(amount) : int256(amount));
        uint256 fee = shell.platformAccrued();
        if (isBuy) {
            uint256 paid = before - _quoteBalance(trader);
            if (exactIn) assertEq(fee, _ceilFee(paid));
            else assertEq(fee, _onTop(paid - fee)); // fee on top of the net quote that reached the pool
            assertGe(fee * 10_000, paid * 30);
        } else {
            uint256 received = _quoteBalance(trader) - before;
            if (exactIn) assertEq(fee, _ceilFee(received + fee));
            else assertEq(received, amount);
            assertGe(fee * 10_000, (received + fee) * 30);
        }
        _backed();
    }
}

/// @dev Native ETH quote, as on Ethereum (token = currency1).
contract PlatformFeeTest is PlatformFeeTestBase {}

/// @dev WETH quote, the token sorting below it (token = currency0).
contract PlatformFeeTokenFirstTest is PlatformFeeTestBase {
    function _tokenFirst() internal pure override returns (bool) {
        return true;
    }
}

/// @dev WETH quote, the token sorting above it (token = currency1).
contract PlatformFeeWethTest is PlatformFeeTestBase {
    function _wethQuote() internal pure override returns (bool) {
        return true;
    }
}
