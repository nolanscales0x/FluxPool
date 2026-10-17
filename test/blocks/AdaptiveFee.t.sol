// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseBlock} from "../../src/blocks/BaseBlock.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";

abstract contract AdaptiveFeeTestBase is FluxTestBase {
    function setUp() public override {
        super.setUp();
        _launch(_one(address(adaptiveFee)), _one(address(adaptiveFee)), _noSettings());
        _skipWindow();
    }

    function _set(bytes32 setting, uint256 value) internal {
        core.setBlockSetting(address(adaptiveFee), setting, value);
    }

    function _sellEachBlock(uint256 tokens, uint256 blocks) internal {
        for (uint256 i; i < blocks; i++) {
            vm.roll(block.number + 1);
            _sell(tokens);
        }
    }

    function test_noPressureNoFee() public {
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
        (uint256 ema, uint256 fee) = adaptiveFee.pressureOf(address(core));
        assertEq(ema, 0);
        assertEq(fee, 0);
    }

    // Selling grows the token reserve, so 3 tokens a block settles near 1.5% of reserve per block.

    function test_sustainedSellingAddsSellFeeOnly() public {
        _set(adaptiveFee.THRESHOLD(), 10_000);
        _sellEachBlock(3 ether, 40);
        vm.roll(block.number + 1);
        (uint256 ema, uint256 expected) = adaptiveFee.pressureOf(address(core));
        assertGt(ema, 10_000);
        assertGt(expected, 0);
        assertLe(expected, 30_000);
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE + expected);
        assertEq(_feeOf(true, 0.1 ether), BASE_FEE); // buys never pay it
    }

    function test_feeNeverExceedsMaxFee() public {
        _set(adaptiveFee.THRESHOLD(), 5_000);
        _sellEachBlock(10 ether, 40);
        vm.roll(block.number + 1);
        (, uint256 fee) = adaptiveFee.pressureOf(address(core));
        assertEq(fee, 30_000);
    }

    function test_oneBlockSpikeDoesNotTriggerFee() public {
        vm.roll(block.number + 1);
        _sell(5 ether); // 5% of reserve in one block
        // Same block: the spike isn't in the average yet.
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
        vm.roll(block.number + 1);
        // Next block: folded in at weight 2/21, still under the threshold.
        (uint256 ema,) = adaptiveFee.pressureOf(address(core));
        assertLt(ema, 20_000);
        assertEq(_feeOf(false, 0.1 ether), BASE_FEE);
    }

    function test_feeEasesBackWhenPressureFalls() public {
        _set(adaptiveFee.THRESHOLD(), 10_000);
        _sellEachBlock(3 ether, 40);
        vm.roll(block.number + 1);
        (, uint256 high) = adaptiveFee.pressureOf(address(core));
        assertGt(high, 0);
        vm.roll(block.number + 30); // quiet blocks
        (, uint256 low) = adaptiveFee.pressureOf(address(core));
        assertEq(low, 0);
    }

    function test_buysOffsetSells() public {
        for (uint256 i; i < 40; i++) {
            vm.roll(block.number + 1);
            _sell(3 ether);
            _buy(3 ether);
        }
        vm.roll(block.number + 1);
        (, uint256 fee) = adaptiveFee.pressureOf(address(core));
        assertEq(fee, 0);
    }

    function test_settingsAtBoundsAndOutside() public {
        bytes32[3] memory names = [adaptiveFee.THRESHOLD(), adaptiveFee.MAX_FEE(), adaptiveFee.WINDOW_BLOCKS()];
        for (uint256 i; i < 3; i++) {
            (uint256 min, uint256 max,) = adaptiveFee.settingBounds(names[i]);
            _set(names[i], min);
            _set(names[i], max);
            vm.expectRevert(abi.encodeWithSelector(BaseBlock.OutOfBounds.selector, names[i], max + 1));
            _set(names[i], max + 1);
            if (min > 0) {
                vm.expectRevert(abi.encodeWithSelector(BaseBlock.OutOfBounds.selector, names[i], min - 1));
                _set(names[i], min - 1);
            }
        }
    }

    function testFuzz_anySettingsNeverBlockSellsOrExceedBounds(
        uint256 threshold,
        uint256 maxFee,
        uint256 window,
        uint256 sellSize,
        uint8 blocks
    ) public {
        _set(adaptiveFee.THRESHOLD(), bound(threshold, 5_000, 200_000));
        uint256 m = bound(maxFee, 0, 50_000);
        _set(adaptiveFee.MAX_FEE(), m);
        _set(adaptiveFee.WINDOW_BLOCKS(), bound(window, 5, 200));
        _sellEachBlock(bound(sellSize, 1e12, 5 ether), bound(blocks, 1, 30));
        vm.roll(block.number + 1);
        uint24 fee = _feeOf(false, 0.1 ether);
        assertLe(fee, BASE_FEE + m);
        assertLe(fee, FEE_CAP);
    }
}

/// @dev Native ETH quote, as on Ethereum (token = currency1).
contract AdaptiveFeeTest is AdaptiveFeeTestBase {}

/// @dev WETH quote, the token sorting below it (token = currency0).
contract AdaptiveFeeTokenFirstTest is AdaptiveFeeTestBase {
    function _tokenFirst() internal pure override returns (bool) {
        return true;
    }
}
