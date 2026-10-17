// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IFluxCore} from "../../src/core/IFluxCore.sol";

/// @notice A core whose behavior the test picks, covering every way a core can misbehave.
contract ConfigurableCore {
    enum Mode {
        Answer, // return (fee, allow)
        Revert,
        BurnGas,
        ShortReturn, // return 32 bytes instead of 64
        RawWords, // return two arbitrary words (out-of-range values)
        ReturnBomb // return a huge buffer
    }

    Mode public mode;
    uint256 public word0;
    uint256 public word1;
    bool public revertAfterSwap;
    uint256 public afterSwapCalls;
    /// @notice Gas the core spends before answering, standing in for a lane of real blocks.
    uint256 public work;

    function set(Mode m, uint256 w0, uint256 w1) external {
        mode = m;
        word0 = w0;
        word1 = w1;
    }

    function setWork(uint256 w) external {
        work = w;
    }

    function setRevertAfterSwap(bool v) external {
        revertAfterSwap = v;
    }

    fallback() external {
        if (msg.sig == IFluxCore.onAfterSwap.selector) {
            if (revertAfterSwap) revert("after");
            afterSwapCalls++;
            return;
        }
        Mode m = mode;
        if (m == Mode.Revert) revert("core says no");
        if (m == Mode.BurnGas) {
            while (true) {}
        }
        uint256 start = gasleft();
        uint256 w = work;
        while (start - gasleft() < w) {}
        uint256 w0 = word0;
        uint256 w1 = word1;
        if (m == Mode.ShortReturn) {
            assembly {
                mstore(0, w0)
                return(0, 0x20)
            }
        }
        if (m == Mode.ReturnBomb) {
            assembly {
                mstore(0, w0)
                mstore(0x20, w1)
                return(0, 60000)
            }
        }
        // Answer and RawWords both return two words; Answer is the well-formed case.
        assembly {
            mstore(0, w0)
            mstore(0x20, w1)
            return(0, 0x40)
        }
    }
}
