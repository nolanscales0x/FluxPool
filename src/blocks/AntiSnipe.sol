// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BaseBlock} from "./BaseBlock.sol";
import {PoolReads} from "./PoolReads.sol";

interface IShellLaunchInfo {
    function launchInfo(PoolId id)
        external
        view
        returns (bool tokenIsCurrency0, uint64 launchStart, uint32 launchWindow);
}

/// @title AntiSnipe
/// @notice Active only during the shell's launch window, and only on buys:
///  - an opening fee that decays linearly to zero over the window;
///  - a maximum buy per swap, as a share of the pool's token reserve;
///  - a maximum number of buys per block, which splitting across wallets can't get around.
/// The limits are per swap and per block, never per wallet, because the trader address is unverified.
/// Bounds act as floors: settings can be tightened but never loosened past them.
contract AntiSnipe is BaseBlock {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant OPENING_FEE = "openingFee"; // hundredths of a bip
    bytes32 public constant MAX_BUY_BPS = "maxBuyBps"; // bps of token reserve per swap
    bytes32 public constant MAX_BUYS_PER_BLOCK = "maxBuysPerBlock";

    IPoolManager public immutable poolManager;
    IShellLaunchInfo public immutable shell;

    mapping(address core => mapping(uint256 blockNumber => uint256)) public buysInBlock;

    constructor(IPoolManager _poolManager, IShellLaunchInfo _shell) {
        poolManager = _poolManager;
        shell = _shell;
    }

    function settingBounds(bytes32 setting) public pure override returns (uint256, uint256, bool) {
        if (setting == OPENING_FEE) return (10_000, 990_000, true);
        if (setting == MAX_BUY_BPS) return (10, 500, false);
        if (setting == MAX_BUYS_PER_BLOCK) return (1, 20, false);
        revert UnknownSetting(setting);
    }

    function _defaultOf(bytes32 setting) internal pure override returns (uint256) {
        if (setting == OPENING_FEE) return 900_000;
        if (setting == MAX_BUY_BPS) return 100;
        if (setting == MAX_BUYS_PER_BLOCK) return 3;
        revert UnknownSetting(setting);
    }

    function onBeforeSwap(address, PoolKey calldata key, SwapParams calldata params)
        external
        override
        returns (uint24, bool)
    {
        PoolId id = key.toId();
        (bool tokenIs0, uint64 start, uint32 window) = shell.launchInfo(id);
        if (tokenIs0 == params.zeroForOne) return (0, true); // sell
        uint256 end = uint256(start) + window;
        if (block.timestamp >= end) return (0, true);

        address core = msg.sender;
        uint256 count = ++buysInBlock[core][block.number];
        if (count > getSetting(core, MAX_BUYS_PER_BLOCK)) return (0, false);

        (uint256 reserve, uint160 sqrtPriceX96) = PoolReads.tokenReserve(poolManager, id, tokenIs0);
        uint256 tokensOut = params.amountSpecified > 0
            ? uint256(params.amountSpecified)  // exact output: the token amount asked for
            : PoolReads.toTokens(uint256(-params.amountSpecified), sqrtPriceX96, tokenIs0);
        if (tokensOut * 10_000 > reserve * getSetting(core, MAX_BUY_BPS)) return (0, false);

        uint256 fee = getSetting(core, OPENING_FEE) * (end - block.timestamp) / window;
        return (uint24(fee), true);
    }
}
