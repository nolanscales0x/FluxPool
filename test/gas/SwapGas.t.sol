// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {FixedSupplyToken} from "../mocks/FixedSupplyToken.sol";

import {FluxTestBase} from "../utils/FluxTestBase.sol";
import {LightFeeBlock} from "../mocks/TestBlocks.sol";

/// @notice Gas per swap: plain v4 pool vs FluxPool with zero, two and four blocks, once with a
/// native ETH quote (snapshots/swap_native.json) and once with WETH (snapshots/swap.json).
/// Each figure is a sell measured as the first swap of a new block (includes the shell's price
/// observation) and as a later swap in the same block.
abstract contract SwapGasBase is FluxTestBase {
    function _group() internal pure virtual returns (string memory);

    function _measure(string memory name) internal {
        _sell(0.1 ether); // warm up
        vm.roll(block.number + 1);
        _sell(0.1 ether);
        uint256 first = vm.snapshotGasLastCall(_group(), string.concat(name, "_firstInBlock"));
        _sell(0.1 ether);
        uint256 later = vm.snapshotGasLastCall(_group(), string.concat(name, "_sameBlock"));
        console.log(_group(), name, first, later);
    }

    function test_gas_plainV4() public {
        token = new FixedSupplyToken("Plain", "PLN", 1_000_000 ether, address(this));
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        if (_usesWeth()) weth.approve(address(modifyLiquidityRouter), type(uint256).max);
        Currency t = Currency.wrap(address(token));
        poolKey = PoolKey(quote, t, 3000, 60, IHooks(address(0))); // ETH and this WETH sort below any token
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: _nativeQuote() ? 200 ether : 0}(
            poolKey,
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 100e18, salt: 0}),
            ZERO_BYTES
        );
        _measure("plainV4");
    }

    function test_gas_flux0Blocks() public {
        _launch(_none(), _none(), _noSettings());
        _skipWindow();
        _measure("flux_0_blocks");
    }

    function test_gas_flux2Blocks() public {
        address[] memory before = new address[](2);
        before[0] = address(antiSnipe);
        before[1] = address(adaptiveFee);
        _launch(before, _one(address(adaptiveFee)), _noSettings());
        _skipWindow();
        _measure("flux_2_blocks");
    }

    function test_gas_flux4Blocks() public {
        address[] memory before = new address[](4);
        before[0] = address(antiSnipe);
        before[1] = address(adaptiveFee);
        before[2] = address(new LightFeeBlock(500));
        before[3] = address(new LightFeeBlock(500));
        _launch(before, _one(address(adaptiveFee)), _noSettings());
        _skipWindow();
        _measure("flux_4_blocks");
    }

    function test_gas_flux2BlocksInLaunchWindow() public {
        address[] memory before = new address[](2);
        before[0] = address(antiSnipe);
        before[1] = address(adaptiveFee);
        _launch(before, _one(address(adaptiveFee)), _noSettings(), 3600);
        _buy(0.1 ether);
        vm.roll(block.number + 1);
        _buy(0.1 ether);
        uint256 g = vm.snapshotGasLastCall(_group(), "flux_2_blocks_launchWindowBuy");
        console.log(_group(), "flux_2_blocks_launchWindowBuy", g);
    }
}

/// @dev Native ETH quote, as on Ethereum.
contract SwapGasNativeTest is SwapGasBase {
    function _group() internal pure override returns (string memory) {
        return "swap_native";
    }
}

/// @dev WETH quote (still supported), token as currency1.
contract SwapGasWethTest is SwapGasBase {
    function _wethQuote() internal pure override returns (bool) {
        return true;
    }

    function _group() internal pure override returns (string memory) {
        return "swap";
    }
}
