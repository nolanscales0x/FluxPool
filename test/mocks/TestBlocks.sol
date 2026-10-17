// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Records the order blocks ran in.
contract CallLog {
    uint256[] public ids;

    function push(uint256 id) external {
        ids.push(id);
    }

    function all() external view returns (uint256[] memory) {
        return ids;
    }

    function clear() external {
        delete ids;
    }
}

/// @notice A well-behaved block with a fixed answer.
contract FeeBlock {
    uint256 public immutable id;
    CallLog public immutable log;
    uint24 public feeAdd;
    bool public allow = true;
    uint256 public afterCalls;

    constructor(uint256 _id, CallLog _log, uint24 _feeAdd) {
        id = _id;
        log = _log;
        feeAdd = _feeAdd;
    }

    function set(uint24 _feeAdd, bool _allow) external {
        feeAdd = _feeAdd;
        allow = _allow;
    }

    function onBeforeSwap(address, PoolKey calldata, SwapParams calldata) external returns (uint24, bool) {
        log.push(id);
        return (feeAdd, allow);
    }

    function onAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta) external {
        afterCalls++;
    }
}

/// @notice A block written to do damage. Each mode is one attack.
contract HostileBlock {
    enum Mode {
        RejectAll, // reject every trade, buys and sells
        MaxFee, // return the largest fee it can
        Revert,
        BurnGas,
        ShortReturn,
        ReturnBomb,
        OutOfRange,
        TakeFunds, // pull tokens out of the PoolManager mid-swap
        SyncCurrency, // disturb the PoolManager's synced currency
        ReenterCore // try to rewrite the core's lanes
    }

    IPoolManager public immutable manager;
    Mode public mode;
    address public target;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function set(Mode m, address _target) external {
        mode = m;
        target = _target;
    }

    function onBeforeSwap(address, PoolKey calldata key, SwapParams calldata) external returns (uint24, bool) {
        _attack(key);
        if (mode == Mode.MaxFee) return (type(uint24).max, true);
        return (0, false);
    }

    function onAfterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta) external {
        _attack(key);
    }

    function _attack(PoolKey calldata key) internal {
        Mode m = mode;
        if (m == Mode.Revert) revert("hostile");
        if (m == Mode.BurnGas) {
            while (true) {}
        }
        if (m == Mode.ShortReturn) {
            assembly {
                mstore(0, 1)
                return(0, 0x20)
            }
        }
        if (m == Mode.ReturnBomb) {
            assembly {
                return(0, 50000)
            }
        }
        if (m == Mode.OutOfRange) {
            assembly {
                mstore(0, shl(200, 1))
                mstore(0x20, 9)
                return(0, 0x40)
            }
        }
        if (m == Mode.TakeFunds) manager.take(key.currency1, address(this), 1 ether);
        if (m == Mode.SyncCurrency) manager.sync(key.currency1);
        if (m == Mode.ReenterCore) {
            (bool ok,) = target.call(abi.encodeWithSignature("setLane(uint8,address[])", uint8(0), new address[](0)));
            ok; // ignored: the attempt is the attack
        }
    }

    receive() external payable {}
}

/// @notice Records the trader the core passes in.
contract TraderBlock {
    address public lastTrader;

    function onBeforeSwap(address trader, PoolKey calldata, SwapParams calldata) external returns (uint24, bool) {
        lastTrader = trader;
        return (0, true);
    }

    function onAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta) external {}
}

/// @notice A stateless block with a fixed fee: stands in for an extra (e.g. agent-written) block in gas runs.
contract LightFeeBlock {
    uint24 public immutable feeAdd;

    constructor(uint24 _feeAdd) {
        feeAdd = _feeAdd;
    }

    function onBeforeSwap(address, PoolKey calldata, SwapParams calldata) external view returns (uint24, bool) {
        return (feeAdd, true);
    }

    function onAfterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta) external {}
}
