// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IFluxCore} from "./IFluxCore.sol";
import {IFluxBlock} from "./IFluxBlock.sol";

interface IShellQuote {
    function quote() external view returns (Currency);
}

/// @title FluxCore
/// @notice One clone per pool. Holds the pool's ordered block lanes and combines the blocks'
/// answers into one result for the shell. Every block is an untrusted external contract: it is
/// called with its own gas limit, its return data is checked by hand, and a failing block is
/// skipped rather than failing the swap.
///
/// The core is never replaced. New behavior arrives as a new block plus a lane change, and only
/// the immutable layer (change registry and playbook registry) can make either.
contract FluxCore is IFluxCore {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    enum Lane {
        BeforeSwap,
        AfterSwap
    }

    struct SettingInit {
        address blockAddr;
        bytes32 setting;
        uint256 value;
    }

    /// @notice Most blocks a lane may hold. Sized so a full lane of blocks that each burn their whole
    /// allowance still fits inside the shell's gas limit for the core.
    uint256 public constant MAX_BLOCKS_PER_LANE = 4;
    /// @notice Gas each block gets per call. 4 x (85k + sandbox) fits the shell's 500k for onBeforeSwap.
    uint256 public constant BLOCK_GAS_BEFORE_SWAP = 85_000;
    /// @notice 4 x (50k + sandbox) fits the shell's 320k for onAfterSwap.
    uint256 public constant BLOCK_GAS_AFTER_SWAP = 50_000;
    /// @dev Gas for the sandbox frame around each block: the delta checks and return handling.
    uint256 internal constant SANDBOX_OVERHEAD = 20_000;
    uint256 internal constant GAS_RESERVE = 5_000;

    IPoolManager public immutable poolManager;
    address public immutable shell;
    address public immutable changeRegistry;
    address public immutable playbookRegistry;

    bool public initialized;
    PoolId public poolId;
    uint24 public baseFee;
    bool public tokenIsCurrency0;
    address[] internal _beforeSwapLane;
    address[] internal _afterSwapLane;

    event BlockSkipped(address indexed blockAddr, bytes4 selector);

    error AlreadyInitialized();
    error NotShell();
    error NotGate();
    error WrongPool();
    error LaneTooLong();
    error InvalidBlock();
    error DuplicateBlock();
    error InsufficientGasForBlock();
    error NotSelf();
    error BlockCallFailed();
    error BlockTouchedPoolManager();

    constructor(IPoolManager _poolManager, address _shell, address _changeRegistry, address _playbookRegistry) {
        poolManager = _poolManager;
        shell = _shell;
        changeRegistry = _changeRegistry;
        playbookRegistry = _playbookRegistry;
        initialized = true; // the implementation itself can never be initialized
    }

    /// @notice Sets up a fresh clone. The launch adapter clones and initializes in one transaction,
    /// so nobody can initialize a clone before it does.
    function initialize(
        PoolKey calldata key,
        uint24 _baseFee,
        address[] calldata beforeSwapBlocks,
        address[] calldata afterSwapBlocks,
        SettingInit[] calldata settings
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        poolId = key.toId();
        baseFee = _baseFee;
        // Which side is the launched token comes from the shell's quote currency, so the core and the
        // shell can never disagree about what is a buy and what is a sell.
        tokenIsCurrency0 = Currency.unwrap(key.currency1) == Currency.unwrap(IShellQuote(shell).quote());
        _writeLane(Lane.BeforeSwap, beforeSwapBlocks);
        _writeLane(Lane.AfterSwap, afterSwapBlocks);
        for (uint256 i; i < settings.length; i++) {
            IFluxBlock(settings[i].blockAddr).setSetting(settings[i].setting, settings[i].value);
        }
    }

    // ---------------------------------------------------------------------
    // Setters (immutable layer only)
    // ---------------------------------------------------------------------

    modifier onlyGate() {
        if (msg.sender != changeRegistry && msg.sender != playbookRegistry) revert NotGate();
        _;
    }

    function setLane(Lane lane, address[] calldata blocks) external onlyGate {
        _writeLane(lane, blocks);
    }

    /// @notice Writes a block setting for this pool. The block enforces its own bounds; gates
    /// classify the change (tightening or loosening) before calling.
    function setBlockSetting(address blockAddr, bytes32 setting, uint256 value) external onlyGate {
        IFluxBlock(blockAddr).setSetting(setting, value);
    }

    // ---------------------------------------------------------------------
    // Shell callbacks
    // ---------------------------------------------------------------------

    /// @inheritdoc IFluxCore
    function onBeforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (uint24, bool)
    {
        _checkCaller(key);
        address trader = _trader(sender, hookData);
        bool isSell = tokenIsCurrency0 == params.zeroForOne;
        bytes memory data = abi.encodeCall(IFluxBlock.onBeforeSwap, (trader, key, params));
        Currency c0 = key.currency0;
        Currency c1 = key.currency1;

        uint256 total = baseFee;
        address[] storage lane = _beforeSwapLane;
        uint256 n = lane.length;
        for (uint256 i; i < n; i++) {
            address b = lane[i];
            (bool ok, uint256 feeAdd, uint256 allow) = _callBlock(b, BLOCK_GAS_BEFORE_SWAP, data, true, c0, c1);
            if (!ok || feeAdd > type(uint24).max || allow > 1) {
                emit BlockSkipped(b, IFluxBlock.onBeforeSwap.selector);
                continue;
            }
            total += feeAdd;
            // First rejection stops the lane for a buy. For a sell the rejection is ignored and the
            // remaining blocks still run, so a hostile block can't switch off later sell fees.
            if (allow == 0 && !isSell) return (_toFee(total), false);
        }
        return (_toFee(total), true);
    }

    /// @inheritdoc IFluxCore
    function onAfterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external {
        _checkCaller(key);
        bytes memory data = abi.encodeCall(IFluxBlock.onAfterSwap, (_trader(sender, hookData), key, params, delta));
        address[] storage lane = _afterSwapLane;
        uint256 n = lane.length;
        for (uint256 i; i < n; i++) {
            (bool ok,,) = _callBlock(lane[i], BLOCK_GAS_AFTER_SWAP, data, false, key.currency0, key.currency1);
            if (!ok) emit BlockSkipped(lane[i], IFluxBlock.onAfterSwap.selector);
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function blocksIn(Lane which) external view returns (address[] memory) {
        return which == Lane.BeforeSwap ? _beforeSwapLane : _afterSwapLane;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _checkCaller(PoolKey calldata key) internal view {
        if (msg.sender != shell) revert NotShell();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    /// @dev FluxPool's router puts abi.encode(trader) in hookData. Anything else falls back to the
    /// router address. Unverified either way.
    function _trader(address sender, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length < 32) return sender;
        return address(uint160(uint256(bytes32(hookData[:32]))));
    }

    function _toFee(uint256 total) internal pure returns (uint24) {
        return total > type(uint24).max ? type(uint24).max : uint24(total);
    }

    function _writeLane(Lane which, address[] calldata blocks) internal {
        if (blocks.length > MAX_BLOCKS_PER_LANE) revert LaneTooLong();
        for (uint256 i; i < blocks.length; i++) {
            if (blocks[i].code.length == 0) revert InvalidBlock();
            for (uint256 j; j < i; j++) {
                if (blocks[i] == blocks[j]) revert DuplicateBlock();
            }
        }
        if (which == Lane.BeforeSwap) _beforeSwapLane = blocks;
        else _afterSwapLane = blocks;
    }

    /// @dev Calls a block through the sandbox frame below. Same untrusted-call pattern as the shell:
    /// fixed gas, at most 64 bytes copied back, short return data treated as failure (so the block
    /// is skipped). Reverts the whole core, sending the shell to its fallback, rather than give a
    /// block less than its full allowance.
    function _callBlock(address b, uint256 gasLimit, bytes memory data, bool needsReturn, Currency c0, Currency c1)
        internal
        returns (bool ok, uint256 word0, uint256 word1)
    {
        uint256 frameGas = gasLimit + SANDBOX_OVERHEAD;
        if (gasleft() < frameGas + frameGas / 63 + GAS_RESERVE) revert InsufficientGasForBlock();
        return
            _rawCall(
                address(this), frameGas, abi.encodeCall(this.sandbox, (b, gasLimit, data, needsReturn, c0, c1)), true
            );
    }

    /// @notice Runs one block and undoes everything it did if it touched the PoolManager's
    /// accounting. Blocks run while the PoolManager is unlocked, so a hostile block could call
    /// take() or sync(): it couldn't keep the tokens, but the unsettled debt would revert the whole
    /// swap, letting a block block sells. Reverting this frame rolls the block's calls back, and
    /// the core skips it. Callable only by the core itself.
    function sandbox(address b, uint256 gasLimit, bytes calldata data, bool needsReturn, Currency c0, Currency c1)
        external
        returns (uint256 word0, uint256 word1)
    {
        if (msg.sender != address(this)) revert NotSelf();
        bytes32 before = _ledger(b, c0, c1);
        bool ok;
        (ok, word0, word1) = _rawCall(b, gasLimit, data, needsReturn);
        if (!ok) revert BlockCallFailed();
        if (_ledger(b, c0, c1) != before) revert BlockTouchedPoolManager();
    }

    /// @dev Call with a fixed gas limit that copies back at most 64 bytes. When a return value is
    /// expected, anything shorter than two words counts as failure.
    function _rawCall(address target, uint256 gasLimit, bytes memory data, bool needsReturn)
        internal
        returns (bool ok, uint256 word0, uint256 word1)
    {
        assembly ("memory-safe") {
            ok := call(gasLimit, target, 0, add(data, 0x20), mload(data), 0, 0)
            if and(ok, needsReturn) {
                switch lt(returndatasize(), 0x40)
                case 1 { ok := 0 }
                default {
                    returndatacopy(0, 0, 0x40)
                    word0 := mload(0)
                    word1 := mload(0x20)
                }
            }
        }
    }

    /// @dev Fingerprint of the PoolManager accounting a block could disturb: open debts, the synced
    /// currency and reserves, and the block's own deltas in this pool's currencies.
    function _ledger(address b, Currency c0, Currency c1) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                poolManager.getNonzeroDeltaCount(),
                poolManager.getSyncedCurrency(),
                poolManager.getSyncedReserves(),
                poolManager.currencyDelta(b, c0),
                poolManager.currencyDelta(b, c1)
            )
        );
    }
}
