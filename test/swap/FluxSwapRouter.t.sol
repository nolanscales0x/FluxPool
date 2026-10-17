// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FluxTestBase} from "../utils/FluxTestBase.sol";
import {FluxSwapRouter} from "../../src/swap/FluxSwapRouter.sol";
import {FluxCore} from "../../src/core/FluxCore.sol";
import {TraderBlock} from "../mocks/TestBlocks.sol";

/// @dev The router against the real shell, core, blocks and PoolManager. Everything here holds for
/// either quote: a native-ETH pool (the way pools launch on Ethereum) and a WETH pool (still supported).
/// The assertions that depend on which currency is the quote live in the two concrete suites below.
abstract contract FluxSwapRouterTestBase is FluxTestBase {
    FluxSwapRouter router;
    address trader = makeAddr("holder");
    address other = makeAddr("other-holder");

    uint128 constant ETH_IN = 1 ether;
    uint128 constant TOKENS_IN = 1 ether;

    function setUp() public virtual override {
        super.setUp();
        router = new FluxSwapRouter(manager);
        _launch(_none(), _none(), new FluxCore.SettingInit[](0));

        vm.deal(trader, 100 ether);
        vm.deal(other, 100 ether);
        token.transfer(trader, 10 ether);
        _approveRouter();
    }

    /// @dev What a holder does once, before selling: approve the token to the router.
    function _approveRouter() internal virtual {
        vm.prank(trader);
        token.approve(address(router), type(uint256).max);
    }

    /// @dev Builds the call a holder makes. `buy` means paying the quote for the token.
    function _plan(bool buy, uint128 amountIn, uint128 minOut, address recipient)
        internal
        view
        returns (FluxSwapRouter.ExactIn memory p)
    {
        p = FluxSwapRouter.ExactIn({
            key: poolKey,
            zeroForOne: buy ? _buyDir() : !_buyDir(),
            amountIn: amountIn,
            minOut: minOut,
            recipient: recipient,
            deadline: block.timestamp + 60
        });
    }

    /// @dev Sends the swap as the trader, paying `msg.value` when the input is native ETH.
    function _swap(FluxSwapRouter.ExactIn memory p) internal returns (uint256 out) {
        bool nativeIn = _nativeQuote() && p.zeroForOne == _buyDir();
        vm.prank(trader);
        out = router.swapExactIn{value: nativeIn ? p.amountIn : 0}(p);
    }

    function _buy(uint128 amountIn, uint128 minOut, address recipient) internal returns (uint256) {
        return _swap(_plan(true, amountIn, minOut, recipient));
    }

    function _sell(uint128 amountIn, uint128 minOut, address recipient) internal returns (uint256) {
        return _swap(_plan(false, amountIn, minOut, recipient));
    }

    function test_a_buy_pays_the_quote_and_delivers_the_token() public {
        uint256 tokensBefore = token.balanceOf(trader);

        uint256 out = _buy(ETH_IN, 0, trader);

        assertGt(out, 0, "the buy produced nothing");
        assertEq(token.balanceOf(trader), tokensBefore + out, "the tokens out did not reach the trader");
    }

    function test_a_sell_pays_the_token_and_delivers_the_quote() public {
        uint256 tokensBefore = token.balanceOf(trader);

        uint256 out = _sell(TOKENS_IN, 0, trader);

        assertGt(out, 0, "the sell produced nothing");
        assertEq(token.balanceOf(trader), tokensBefore - TOKENS_IN, "the trader did not pay the tokens");
    }

    function test_the_output_goes_to_the_recipient_not_the_payer() public {
        uint256 otherBefore = token.balanceOf(other);
        uint256 traderBefore = token.balanceOf(trader);

        uint256 out = _buy(ETH_IN, 0, other);

        assertEq(token.balanceOf(other), otherBefore + out, "the recipient did not receive the output");
        assertEq(token.balanceOf(trader), traderBefore, "the payer received an output addressed to someone else");
    }

    function test_the_router_holds_nothing_after_a_round_trip() public {
        _buy(ETH_IN, 0, trader);
        _sell(TOKENS_IN, 0, trader);

        assertEq(address(router).balance, 0, "the router kept ETH");
        assertEq(token.balanceOf(address(router)), 0, "the router kept tokens");
    }

    function test_reverts_past_the_deadline() public {
        FluxSwapRouter.ExactIn memory p = _plan(true, ETH_IN, 0, trader);
        p.deadline = block.timestamp - 1;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(FluxSwapRouter.DeadlinePassed.selector, p.deadline, block.timestamp));
        router.swapExactIn{value: _nativeQuote() ? p.amountIn : 0}(p);
    }

    function test_reverts_when_the_output_is_below_the_floor() public {
        FluxSwapRouter.ExactIn memory p = _plan(true, ETH_IN, type(uint128).max, trader);
        vm.prank(trader);
        vm.expectPartialRevert(FluxSwapRouter.SlippageExceeded.selector);
        router.swapExactIn{value: _nativeQuote() ? p.amountIn : 0}(p);
    }

    function test_reverts_without_a_recipient() public {
        FluxSwapRouter.ExactIn memory p = _plan(true, ETH_IN, 0, address(0));
        vm.prank(trader);
        vm.expectRevert(FluxSwapRouter.NoRecipient.selector);
        router.swapExactIn{value: _nativeQuote() ? p.amountIn : 0}(p);
    }

    function test_reverts_on_a_zero_trade() public {
        FluxSwapRouter.ExactIn memory p = _plan(true, 0, 0, trader);
        vm.prank(trader);
        vm.expectRevert(FluxSwapRouter.NoTrade.selector);
        router.swapExactIn{value: 0}(p);
    }

    function test_reverts_when_a_token_swap_carries_eth() public {
        FluxSwapRouter.ExactIn memory p = _plan(false, TOKENS_IN, 0, trader);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(FluxSwapRouter.WrongValue.selector, 1, 0));
        router.swapExactIn{value: 1}(p);
    }

    /// @dev The core reads the trader out of hookData, which is what per-block buy caps and the
    /// launch-window rules act on. A router that reported itself would make every holder look like
    /// one wallet, so this is the assertion that keeps the router honest about who is trading.
    function test_reports_the_holder_to_blocks() public {
        TraderBlock recorder = new TraderBlock();
        address[] memory before = new address[](1);
        before[0] = address(recorder);
        _launch(before, _none(), new FluxCore.SettingInit[](0));

        _buy(ETH_IN, 0, trader);

        assertEq(recorder.lastTrader(), trader, "the block saw the router instead of the holder");
    }
}

/// @dev Native ETH as the quote, which is how pools launch on Ethereum: the buy pays `msg.value`, and
/// the sell is paid out in ETH straight from the PoolManager.
contract FluxSwapRouterNativeTest is FluxSwapRouterTestBase {
    function test_a_buy_pays_exactly_the_eth_it_was_sent() public {
        uint256 ethBefore = trader.balance;

        _buy(ETH_IN, 0, trader);

        assertEq(trader.balance, ethBefore - ETH_IN, "the trader did not pay exactly what they said");
    }

    function test_a_sell_is_paid_out_in_eth() public {
        uint256 ethBefore = trader.balance;

        uint256 out = _sell(TOKENS_IN, 0, trader);

        assertEq(trader.balance, ethBefore + out, "the ETH out did not reach the trader");
    }

    function test_reverts_when_the_eth_sent_is_not_the_amount_in() public {
        FluxSwapRouter.ExactIn memory p = _plan(true, ETH_IN, 0, trader);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(FluxSwapRouter.WrongValue.selector, ETH_IN + 1, ETH_IN));
        router.swapExactIn{value: ETH_IN + 1}(p);
    }
}

/// @dev WETH as the quote, where both sides are ERC-20s: the input is pulled with `transferFrom` and
/// settled through `sync`, and the output is taken as WETH.
contract FluxSwapRouterWethTest is FluxSwapRouterTestBase {
    function _wethQuote() internal pure override returns (bool) {
        return true;
    }

    function _approveRouter() internal override {
        super._approveRouter();
        vm.startPrank(trader);
        weth.deposit{value: 10 ether}();
        weth.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_a_buy_pays_exactly_the_weth_it_was_sent() public {
        uint256 wethBefore = weth.balanceOf(trader);

        _buy(ETH_IN, 0, trader);

        assertEq(weth.balanceOf(trader), wethBefore - ETH_IN, "the trader did not pay exactly what they said");
    }

    function test_a_sell_is_paid_out_in_weth() public {
        uint256 wethBefore = weth.balanceOf(trader);

        uint256 out = _sell(TOKENS_IN, 0, trader);

        assertEq(weth.balanceOf(trader), wethBefore + out, "the WETH out did not reach the trader");
    }

    function test_the_router_holds_no_weth() public {
        _buy(ETH_IN, 0, trader);
        _sell(TOKENS_IN, 0, trader);

        assertEq(weth.balanceOf(address(router)), 0, "the router kept WETH");
    }
}
