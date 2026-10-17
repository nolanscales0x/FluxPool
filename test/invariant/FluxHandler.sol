// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {FluxShell} from "../../src/shell/FluxShell.sol";
import {FluxCore} from "../../src/core/FluxCore.sol";
import {AntiSnipe} from "../../src/blocks/AntiSnipe.sol";
import {AdaptiveFee} from "../../src/blocks/AdaptiveFee.sol";
import {CreatorFee} from "../../src/blocks/CreatorFee.sol";
import {AgentRegistry} from "../../src/agents/AgentRegistry.sol";
import {ChangeRegistry} from "../../src/gates/ChangeRegistry.sol";
import {PlaybookRegistry} from "../../src/playbooks/PlaybookRegistry.sol";
import {FixedSupplyToken} from "../mocks/FixedSupplyToken.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {HostileBlock, LightFeeBlock} from "../mocks/TestBlocks.sol";

/// @notice Drives random sequences against one live pool and keeps ghost counters the invariant
/// suites assert on. Everything an attacker could do is in here: trades from many wallets, an
/// agent trying every action whatever its level, hostile blocks proposed into lanes, random check
/// results, playbook fires, early executes and early liquidity pulls.
contract FluxHandler is Test {
    struct System {
        IPoolManager manager;
        PoolSwapTest swapRouter;
        FluxShell shell;
        FluxCore core;
        AntiSnipe antiSnipe;
        AdaptiveFee adaptiveFee;
        CreatorFee creatorFee;
        AgentRegistry agentRegistry;
        ChangeRegistry changeRegistry;
        PlaybookRegistry playbookRegistry;
        FixedSupplyToken token;
        WETH weth; // the pool's quote when it is WETH; address(0) means native ETH
        PoolKey key;
        PoolId id;
        address creator;
        address agent;
        address attester;
        uint8 agentLevel;
        uint8 mode;
        uint256[] playbooks;
    }

    struct Pending {
        uint256 changeId;
        address newBlock; // zero unless the change brings in new code
        uint8 passedMask; // which of the four mandatory checks this handler recorded as passed
        bool anyFailed;
    }

    uint256 internal constant ALL_FOUR = 0xF;

    System internal s;
    address[] public traders;
    Pending[] internal _pending;
    mapping(address => bool) public approved;

    // Ghost counters: every one must stay zero.
    uint256 public sellReverts;
    uint256 public capViolations;
    uint256 public earlyWithdrawals;
    uint256 public agentOverreach;
    uint256 public platformShortfalls; // a trade that paid less than 30 bps of its gross ETH leg

    // Coverage counters, to show the sequences actually exercise things.
    uint256 public buys;
    uint256 public sells;
    uint256 public fires;
    uint256 public executes;
    uint256 public blocksActivated;

    constructor(System memory sys, address[] memory _traders) {
        s = sys;
        for (uint256 i; i < sys.playbooks.length; i++) {
            s.playbooks.push(sys.playbooks[i]);
        }
        traders = _traders;
        address[] memory lane0 = sys.core.blocksIn(FluxCore.Lane.BeforeSwap);
        address[] memory lane1 = sys.core.blocksIn(FluxCore.Lane.AfterSwap);
        for (uint256 i; i < lane0.length; i++) {
            approved[lane0[i]] = true;
        }
        for (uint256 i; i < lane1.length; i++) {
            approved[lane1[i]] = true;
        }
    }

    // ------------------------------------------------------------------
    // Trading
    // ------------------------------------------------------------------

    function buy(uint256 traderSeed, uint256 amount) external {
        address t = traders[traderSeed % traders.length];
        amount = bound(amount, 1e12, 3 ether);
        if (_native()) {
            vm.deal(t, t.balance + amount);
        } else {
            vm.deal(t, amount);
            vm.prank(t);
            s.weth.deposit{value: amount}();
        }
        (bool ok, uint24 fee) = _swap(t, true, amount);
        if (ok) {
            buys++;
            _checkCap(fee);
        }
    }

    function sell(uint256 traderSeed, uint256 amount) external {
        address t = traders[traderSeed % traders.length];
        uint256 bal = s.token.balanceOf(t);
        if (bal < 1e12) return;
        amount = bound(amount, 1e12, bal < 3 ether ? bal : 3 ether);
        (bool ok, uint24 fee) = _swap(t, false, amount);
        if (!ok) {
            sellReverts++;
            return;
        }
        sells++;
        _checkCap(fee);
    }

    function _swap(address t, bool isBuy, uint256 amount) internal returns (bool ok, uint24 fee) {
        uint256 accruedBefore = s.shell.platformAccrued();
        uint256 quoteBefore = _quoteBalance(t);
        bool zeroForOne = isBuy == (Currency.unwrap(s.key.currency0) == address(s.weth));
        uint256 value = isBuy && _native() ? amount : 0;
        vm.recordLogs();
        vm.prank(t);
        try s.swapRouter.swap{value: value}(
            s.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(t)
        ) {
            ok = true;
        } catch {
            return (false, 0);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(s.manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
        // Independent check of Programmable's fee from the trader's own ETH balance.
        uint256 platform = s.shell.platformAccrued() - accruedBefore;
        uint256 quoteAfter = _quoteBalance(t);
        uint256 gross = isBuy ? quoteBefore - quoteAfter : quoteAfter - quoteBefore + platform;
        if (platform * 10_000 < gross * 30) platformShortfalls++;
    }

    function _native() internal view returns (bool) {
        return address(s.weth) == address(0);
    }

    function _quoteBalance(address who) internal view returns (uint256) {
        return _native() ? who.balance : s.weth.balanceOf(who);
    }

    function _checkCap(uint24 fee) internal {
        if (fee > s.shell.activeFeeCap(s.id)) capViolations++;
    }

    // ------------------------------------------------------------------
    // Time
    // ------------------------------------------------------------------

    function passTime(uint256 secs, uint256 blocks) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 hours));
        vm.roll(block.number + bound(blocks, 1, 5));
    }

    // ------------------------------------------------------------------
    // Agent: tries everything, whatever its level
    // ------------------------------------------------------------------

    function agentProposeSetting(uint256 which, uint256 value) external {
        (address blockAddr, bytes32 setting) = _pickSetting(which);
        value = bound(value, 0, 1_000_000);
        vm.prank(s.agent);
        try s.changeRegistry.proposeSetting(s.id, blockAddr, setting, value) returns (uint256 changeId) {
            if (s.agentLevel < uint8(AgentRegistry.Level.ProposeSettings) || blockAddr == address(s.creatorFee)) {
                agentOverreach++;
            }
            _track(changeId, address(0));
        } catch {}
    }

    function agentProposeBlock(uint256 hostileMode, uint256 position) external {
        address b = _newBlock(hostileMode);
        vm.prank(s.agent);
        try s.changeRegistry.proposeBlock(s.id, 0, position % 3, b, new bytes32[](0)) returns (uint256 changeId) {
            if (s.agentLevel < uint8(AgentRegistry.Level.ProposeCode)) agentOverreach++;
            _track(changeId, b);
        } catch {}
    }

    function agentSwitchMode(uint8 newMode) external {
        vm.prank(s.agent);
        try s.changeRegistry.setMode(s.id, newMode % 3) {
            agentOverreach++; // no level may change the mode
        } catch {}
    }

    function agentFire(uint256 pbSeed) external {
        if (s.playbooks.length == 0) return;
        vm.prank(s.agent);
        try s.playbookRegistry.fire(s.playbooks[pbSeed % s.playbooks.length]) {
            if (s.agentLevel < uint8(AgentRegistry.Level.Fire)) agentOverreach++;
            fires++;
        } catch {}
    }

    // ------------------------------------------------------------------
    // Creator and everyone else
    // ------------------------------------------------------------------

    function creatorProposeBlock(uint256 hostileMode, uint256 position) external {
        address b = _newBlock(hostileMode);
        vm.prank(s.creator);
        try s.changeRegistry.proposeBlock(s.id, 0, position % 3, b, new bytes32[](0)) returns (uint256 changeId) {
            _track(changeId, b);
        } catch {}
    }

    function creatorRemoveFirstBlock() external {
        address[] memory lane = s.core.blocksIn(FluxCore.Lane.BeforeSwap);
        if (lane.length == 0) return;
        address[] memory next = new address[](lane.length - 1);
        for (uint256 i = 1; i < lane.length; i++) {
            next[i - 1] = lane[i];
        }
        vm.prank(s.creator);
        try s.changeRegistry.proposeLaneChange(s.id, 0, next, new bytes32[](0)) returns (uint256 changeId) {
            _track(changeId, address(0));
        } catch {}
    }

    function creatorTryWithdraw(uint128 liquidity) external {
        vm.prank(s.creator);
        try s.shell.withdrawLiquidity(s.key, uint128(bound(liquidity, 1, 1 ether))) {
            earlyWithdrawals++; // pools here are Locked: any success is a violation
        } catch {}
    }

    function recordCheck(uint256 pendingSeed, uint256 checkSeed, bool passed) external {
        if (_pending.length == 0) return;
        Pending storage p = _pending[pendingSeed % _pending.length];
        uint256 idx = checkSeed % 5;
        bytes32[5] memory names =
            [bytes32("compiled"), "interface", "simulated", "sourceVerified", "programmableVerified"];
        vm.prank(s.attester);
        try s.changeRegistry.recordCheck(p.changeId, names[idx], passed) {
            if (idx < 4) {
                if (passed) p.passedMask |= uint8(1 << idx);
                else p.passedMask &= ~uint8(1 << idx);
            }
            if (!passed) p.anyFailed = true;
        } catch {}
    }

    function passAllChecks(uint256 pendingSeed) external {
        if (_pending.length == 0) return;
        Pending storage p = _pending[pendingSeed % _pending.length];
        bytes32[4] memory names = [bytes32("compiled"), "interface", "simulated", "sourceVerified"];
        for (uint256 i; i < 4; i++) {
            vm.prank(s.attester);
            try s.changeRegistry.recordCheck(p.changeId, names[i], true) {
                p.passedMask |= uint8(1 << i);
            } catch {}
        }
    }

    function execute(uint256 pendingSeed) external {
        if (_pending.length == 0) return;
        uint256 i = pendingSeed % _pending.length;
        Pending memory p = _pending[i];
        try s.changeRegistry.execute(p.changeId) {
            executes++;
            _onApplied(p);
            _drop(i);
        } catch {}
    }

    function expire(uint256 pbSeed) external {
        if (s.playbooks.length == 0) return;
        try s.playbookRegistry.expire(s.playbooks[pbSeed % s.playbooks.length]) {} catch {}
    }

    function collect() external {
        s.shell.collect(s.key);
    }

    function claimPlatform() external {
        try s.shell.claimPlatform() {} catch {}
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _pickSetting(uint256 which) internal view returns (address, bytes32) {
        uint256 w = which % 7;
        if (w == 0) return (address(s.adaptiveFee), s.adaptiveFee.THRESHOLD());
        if (w == 1) return (address(s.adaptiveFee), s.adaptiveFee.MAX_FEE());
        if (w == 2) return (address(s.adaptiveFee), s.adaptiveFee.WINDOW_BLOCKS());
        if (w == 3) return (address(s.antiSnipe), s.antiSnipe.OPENING_FEE());
        if (w == 4) return (address(s.antiSnipe), s.antiSnipe.MAX_BUY_BPS());
        if (w == 5) return (address(s.antiSnipe), s.antiSnipe.MAX_BUYS_PER_BLOCK());
        return (address(s.creatorFee), s.creatorFee.AGENT_SHARE());
    }

    /// @dev A fresh block each time: hostile in one of its modes, or a plain fee block.
    function _newBlock(uint256 seed) internal returns (address) {
        uint256 m = seed % 10;
        if (m == 9) return address(new LightFeeBlock(uint24(seed % 20_000)));
        HostileBlock h = new HostileBlock(s.manager);
        h.set(HostileBlock.Mode(m), address(0));
        return address(h);
    }

    function _track(uint256 changeId, address newBlock) internal {
        (,, ChangeRegistry.Status status,,,,,) = s.changeRegistry.changeOf(changeId);
        Pending memory p = Pending({changeId: changeId, newBlock: newBlock, passedMask: 0, anyFailed: false});
        if (status == ChangeRegistry.Status.Applied) _onApplied(p);
        else _pending.push(p);
    }

    /// @dev Independent of the contract's own bookkeeping: a new block counts as approved only if
    /// this handler itself recorded all four mandatory checks as passed, or the pool is Wild.
    function _onApplied(Pending memory p) internal {
        if (p.newBlock == address(0)) return;
        blocksActivated++;
        bool ok = s.mode == 2 || (p.passedMask == ALL_FOUR && !p.anyFailed);
        if (ok) approved[p.newBlock] = true;
    }

    function _drop(uint256 i) internal {
        _pending[i] = _pending[_pending.length - 1];
        _pending.pop();
    }

    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }
}
