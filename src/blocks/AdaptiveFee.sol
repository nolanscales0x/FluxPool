// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {BaseBlock} from "./BaseBlock.sol";
import {PoolReads} from "./PoolReads.sol";
import {IShellLaunchInfo} from "./AntiSnipe.sol";

/// @title AdaptiveFee
/// @notice Adds a fee to sells (never a rejection) when sustained sell pressure crosses a threshold,
/// easing back as pressure falls.
///
/// Pressure is an exponential moving average, over a window of blocks, of each block's net tokens
/// sold as parts per million of the token reserve. A block's trades only enter the average once the
/// block is over, so trades inside the current block (one attacker's included) can't move the fee
/// they pay or anyone else pays this block. Spiking it takes net selling sustained across many blocks.
contract AdaptiveFee is BaseBlock {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant THRESHOLD = "threshold"; // ppm of token reserve, net sold per block
    bytes32 public constant MAX_FEE = "maxFee"; // hundredths of a bip
    bytes32 public constant WINDOW_BLOCKS = "windowBlocks";

    uint256 internal constant PPM = 1_000_000;

    struct Pressure {
        int128 bucket; // net sold this block, ppm of reserve (negative when buys dominate)
        uint64 bucketBlock;
        uint64 ema; // ppm, never negative
    }

    IPoolManager public immutable poolManager;
    IShellLaunchInfo public immutable shell;

    mapping(address core => Pressure) internal _pressure;

    constructor(IPoolManager _poolManager, IShellLaunchInfo _shell) {
        poolManager = _poolManager;
        shell = _shell;
    }

    function settingBounds(bytes32 setting) public pure override returns (uint256, uint256, bool) {
        if (setting == THRESHOLD) return (5_000, 200_000, false); // lower kicks in sooner
        if (setting == MAX_FEE) return (0, 50_000, true);
        if (setting == WINDOW_BLOCKS) return (5, 200, true); // longer is harder to grief
        revert UnknownSetting(setting);
    }

    function _defaultOf(bytes32 setting) internal pure override returns (uint256) {
        if (setting == THRESHOLD) return 20_000;
        if (setting == MAX_FEE) return 30_000;
        if (setting == WINDOW_BLOCKS) return 20;
        revert UnknownSetting(setting);
    }

    function onBeforeSwap(address, PoolKey calldata key, SwapParams calldata params)
        external
        view
        override
        returns (uint24, bool)
    {
        (bool tokenIs0,,) = shell.launchInfo(key.toId());
        if (tokenIs0 != params.zeroForOne) return (0, true); // buy
        return (uint24(_feeFor(msg.sender, _rolled(msg.sender).ema)), true);
    }

    function onAfterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta delta) external override {
        PoolId id = key.toId();
        (bool tokenIs0,,) = shell.launchInfo(id);
        // delta is from the swapper's side: a negative token amount is tokens paid into the pool.
        int256 netSold = -int256(tokenIs0 ? delta.amount0() : delta.amount1());
        (uint256 reserve,) = PoolReads.tokenReserve(poolManager, id, tokenIs0);
        if (reserve == 0) return;

        Pressure memory p = _rolled(msg.sender);
        int256 bucket = int256(p.bucket) + netSold * int256(PPM) / int256(reserve);
        if (bucket > type(int128).max) bucket = type(int128).max;
        if (bucket < type(int128).min) bucket = type(int128).min;
        p.bucket = int128(bucket);
        _pressure[msg.sender] = p;
    }

    /// @notice Current pressure (ppm) and the sell fee it implies for a core.
    function pressureOf(address core) external view returns (uint256 ema, uint256 sellFee) {
        ema = _rolled(core).ema;
        sellFee = _feeFor(core, ema);
    }

    function _feeFor(address core, uint256 ema) internal view returns (uint256) {
        uint256 threshold = getSetting(core, THRESHOLD);
        if (ema <= threshold) return 0;
        uint256 maxFee = getSetting(core, MAX_FEE);
        uint256 fee = maxFee * (ema - threshold) / threshold;
        return fee > maxFee ? maxFee : fee;
    }

    /// @dev Pressure brought forward to the current block: folds the finished block's bucket into the
    /// average, then decays it across any blocks with no trades.
    function _rolled(address core) internal view returns (Pressure memory p) {
        p = _pressure[core];
        if (p.bucketBlock == block.number) return p;
        uint256 alpha = 2 * PPM / (getSetting(core, WINDOW_BLOCKS) + 1);
        int256 ema = (int256(uint256(p.ema)) * int256(PPM - alpha) + int256(p.bucket) * int256(alpha)) / int256(PPM);
        uint256 e = ema > 0 ? uint256(ema) : 0;
        if (p.bucketBlock != 0 && block.number > p.bucketBlock + 1) {
            e = e * _powPpm(PPM - alpha, block.number - p.bucketBlock - 1) / PPM;
        } else if (p.bucketBlock == 0) {
            e = 0;
        }
        p.ema = uint64(e > type(uint64).max ? type(uint64).max : e);
        p.bucket = 0;
        p.bucketBlock = uint64(block.number);
    }

    function _powPpm(uint256 base, uint256 exp) internal pure returns (uint256 result) {
        result = PPM;
        while (exp != 0 && result != 0) {
            if (exp & 1 == 1) result = result * base / PPM;
            base = base * base / PPM;
            exp >>= 1;
        }
    }
}
