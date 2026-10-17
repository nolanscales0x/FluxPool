// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {FluxCore} from "../../src/core/FluxCore.sol";
import {BaseBlock} from "../../src/blocks/BaseBlock.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";

abstract contract AntiSnipeTestBase is FluxTestBase {
    uint32 constant LONG_WINDOW = 60;

    function _launchWithAntiSnipe() internal {
        _launch(_one(address(antiSnipe)), _none(), _noSettings(), LONG_WINDOW);
    }

    function _set(bytes32 setting, uint256 value) internal {
        core.setBlockSetting(address(antiSnipe), setting, value);
    }

    // ------------------------------------------------------------------
    // Opening fee
    // ------------------------------------------------------------------

    function test_openingFeeDecaysLinearlyToZero() public {
        _launchWithAntiSnipe();
        uint256 start = block.timestamp;
        assertEq(_feeOf(true, 0.1 ether), BASE_FEE + 900_000);

        vm.warp(start + LONG_WINDOW / 2);
        vm.roll(block.number + 1);
        assertEq(_feeOf(true, 0.1 ether), BASE_FEE + 450_000);

        vm.warp(start + LONG_WINDOW);
        vm.roll(block.number + 1);
        assertEq(_feeOf(true, 0.1 ether), BASE_FEE);
    }

    function test_sellsPayNoOpeningFee() public {
        _launchWithAntiSnipe();
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
    }

    function test_openingFeeIsClampedToLaunchCap() public {
        _launchWithAntiSnipe();
        _set(antiSnipe.OPENING_FEE(), 990_000);
        assertEq(_feeOf(true, 0.1 ether), LAUNCH_CAP);
    }

    // ------------------------------------------------------------------
    // Max buy per swap
    // ------------------------------------------------------------------

    function test_rejectsBuysOverMaxSizeDuringWindow() public {
        _launchWithAntiSnipe();
        // Reserve is ~100 tokens; the default limit is 1% per swap.
        assertTrue(_buyReverts(2 ether));
        _buy(0.5 ether);
    }

    function test_rejectsExactOutputBuysOverMaxSize() public {
        _launchWithAntiSnipe();
        _set(antiSnipe.OPENING_FEE(), 100_000); // keep the fee small so only size decides
        try this.exactOutBuy(2 ether) {
            revert("oversized exact-output buy went through");
        } catch {}
        this.exactOutBuy(0.5 ether);
    }

    function exactOutBuy(uint256 tokensOut) external {
        require(msg.sender == address(this));
        _swap(_buyDir(), int256(tokensOut), ZERO_BYTES); // exact output: tokensOut tokens
    }

    function test_sizeLimitLiftsAfterWindow() public {
        _launchWithAntiSnipe();
        vm.warp(block.timestamp + LONG_WINDOW);
        _buy(5 ether);
    }

    function test_sellsAreNeverSizeLimited() public {
        _launchWithAntiSnipe();
        _sell(5 ether);
    }

    // ------------------------------------------------------------------
    // Max buys per block (wallet splitting)
    // ------------------------------------------------------------------

    function test_capsBuysPerBlockAcrossWallets() public {
        _launchWithAntiSnipe();
        for (uint256 i; i < 3; i++) {
            _buyAs(address(uint160(0xB0700 + i)), 0.1 ether);
        }
        // Fourth buy in the block fails whichever wallet it claims to be from.
        try this.buyAs(address(0xB07FF), 0.1 ether) {
            revert("fourth buy went through");
        } catch {}

        vm.roll(block.number + 1);
        _buyAs(address(0xB07FF), 0.1 ether);
    }

    function buyAs(address trader, uint256 ethIn) external {
        require(msg.sender == address(this));
        _buyAs(trader, ethIn);
    }

    function _buyAs(address trader, uint256 ethIn) internal {
        _swap(_buyDir(), -int256(ethIn), abi.encode(trader));
    }

    function test_sellsDontCountTowardBlockCap() public {
        _launchWithAntiSnipe();
        for (uint256 i; i < 5; i++) {
            _sell(0.1 ether);
        }
        for (uint256 i; i < 3; i++) {
            _buy(0.1 ether);
        }
    }

    // ------------------------------------------------------------------
    // Bounds (floors)
    // ------------------------------------------------------------------

    function test_settingsAtBoundsAndOutside() public {
        _launchWithAntiSnipe();
        bytes32[3] memory names = [antiSnipe.OPENING_FEE(), antiSnipe.MAX_BUY_BPS(), antiSnipe.MAX_BUYS_PER_BLOCK()];
        for (uint256 i; i < 3; i++) {
            (uint256 min, uint256 max,) = antiSnipe.settingBounds(names[i]);
            _set(names[i], min);
            assertEq(antiSnipe.getSetting(address(core), names[i]), min);
            _set(names[i], max);
            assertEq(antiSnipe.getSetting(address(core), names[i]), max);
            vm.expectRevert(abi.encodeWithSelector(BaseBlock.OutOfBounds.selector, names[i], max + 1));
            _set(names[i], max + 1);
            if (min > 0) {
                vm.expectRevert(abi.encodeWithSelector(BaseBlock.OutOfBounds.selector, names[i], min - 1));
                _set(names[i], min - 1);
            }
        }
        vm.expectRevert(abi.encodeWithSelector(BaseBlock.UnknownSetting.selector, bytes32("nope")));
        _set("nope", 1);
    }

    function test_settingsAreScopedToTheCallingCore() public {
        _launchWithAntiSnipe();
        address otherCore = makeAddr("other-core");
        vm.prank(otherCore);
        antiSnipe.setSetting(antiSnipe.MAX_BUYS_PER_BLOCK(), 20);
        assertEq(antiSnipe.getSetting(address(core), antiSnipe.MAX_BUYS_PER_BLOCK()), 3);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_anySettingsNeverBlockSellsOrExceedCap(
        uint256 fee,
        uint256 maxBuy,
        uint256 maxBuys,
        uint256 amount,
        uint256 elapsed
    ) public {
        _launchWithAntiSnipe();
        _set(antiSnipe.OPENING_FEE(), bound(fee, 100_000, 990_000));
        _set(antiSnipe.MAX_BUY_BPS(), bound(maxBuy, 10, 500));
        _set(antiSnipe.MAX_BUYS_PER_BLOCK(), bound(maxBuys, 1, 20));
        vm.warp(block.timestamp + bound(elapsed, 0, LONG_WINDOW * 2));
        amount = bound(amount, 1e12, 10 ether);

        uint24 cap = shell.activeFeeCap(poolId);
        assertLe(_feeOf(false, amount), cap);
        try this.feeOfExternal(true, amount) returns (uint24 buyFee) {
            assertLe(buyFee, cap);
        } catch {}
    }
}

/// @dev Native ETH quote, as on Ethereum (token = currency1).
contract AntiSnipeTest is AntiSnipeTestBase {}

/// @dev WETH quote, the token sorting below it (token = currency0).
contract AntiSnipeTokenFirstTest is AntiSnipeTestBase {
    function _tokenFirst() internal pure override returns (bool) {
        return true;
    }
}
