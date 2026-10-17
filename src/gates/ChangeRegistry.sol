// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IFluxBlock} from "../core/IFluxBlock.sol";
import {IFluxShellGovernance} from "../interfaces/IFluxShellGovernance.sol";
import {IFluxCoreAdmin} from "../interfaces/IFluxCoreAdmin.sol";
import {IChangeQueue} from "../interfaces/IChangeQueue.sol";
import {AgentRegistry} from "../agents/AgentRegistry.sol";

/// @title ChangeRegistry
/// @notice Every change that isn't a playbook goes through here, under the pool's freedom mode.
/// The shell's protections sit underneath in every mode. Part of the immutable layer.
///
/// | Change                          | Guarded           | Fast                | Wild    |
/// | ------------------------------- | ----------------- | ------------------- | ------- |
/// | Safer setting                   | Instant           | Instant             | Instant |
/// | Riskier setting, within bounds  | Timelock          | Instant             | Instant |
/// | New block or lane change        | Checks + timelock | Checks, no timelock | Instant |
/// | Raising an agent's level        | Timelock          | Timelock            | Timelock|
/// | Switching to a freer mode       | Timelock          | Timelock            | n/a     |
/// | Switching to a safer mode       | n/a               | Instant             | Instant |
/// | Outside a setting's bounds      | Rejected          | Rejected            | Rejected|
///
///  - A lane change only needs checks when it brings in a block that isn't already in the pool's
///    lanes. Removing or reordering blocks follows the same timing without checks.
///  - Execution applies the stricter of the rules the change was queued under and the pool's
///    current mode, so switching a pool to a safer mode also slows down what's already queued.
///  - Agents can't change the CreatorFee block's settings (the fee split), in any mode.
///  - Attesters are protocol-wide and managed by `attesterManager` (a protocol multisig). Attesters
///    can only record check results: they gate activation and can't push a change through.
contract ChangeRegistry is IChangeQueue {
    enum Mode {
        Guarded,
        Fast,
        Wild
    }

    enum Status {
        None,
        Queued,
        Applied,
        Cancelled
    }

    enum CheckResult {
        None,
        Passed,
        Failed
    }

    struct Change {
        PoolId pool;
        Kind kind;
        Status status;
        bool needsChecks;
        uint64 queuedAt;
        uint64 executableAt;
        address proposer;
        bytes payload;
    }

    /// @dev Bundles queue arguments to keep the stack shallow.
    struct Entry {
        PoolId pool;
        Kind kind;
        address proposer;
        address target;
        bytes32 setting;
        uint256 oldValue;
        uint256 newValue;
        uint64 delay;
        bool needsChecks;
    }

    // Shared check names.
    bytes32 public constant COMPILED = "compiled";
    bytes32 public constant INTERFACE = "interface";
    bytes32 public constant SIMULATED = "simulated";
    bytes32 public constant SOURCE_VERIFIED = "sourceVerified";
    bytes32 public constant PROGRAMMABLE_VERIFIED = "programmableVerified";

    uint256 internal constant MAX_BLOCKS_PER_LANE = 4;
    uint256 internal constant READ_GAS = 50_000;

    IFluxShellGovernance public immutable shell;
    AgentRegistry public immutable agentRegistry;
    address public immutable attesterManager;

    /// @notice Change ids are global, so (pool, changeId) never collides across pools.
    uint256 public nextChangeId = 1;
    mapping(uint256 => Change) internal _changes;
    mapping(uint256 => bytes32[]) internal _requiredChecks;
    mapping(uint256 changeId => mapping(bytes32 check => CheckResult)) public checkResult;
    /// @notice True once any check on the change has been recorded as failed, required or not.
    mapping(uint256 changeId => bool) public anyCheckFailed;

    mapping(address => bool) public isAttester;
    mapping(PoolId => bool) internal _modeSet;
    mapping(PoolId => Mode) internal _mode;
    /// @notice Pools that also require `programmableVerified` on new blocks. One-way: once on, stays on.
    mapping(PoolId => bool) public requireProgrammable;

    // Shared journal events (names and fields fixed by the shared interfaces).
    event ChangeQueued(
        PoolId indexed pool,
        uint256 indexed changeId,
        address proposer,
        uint8 kind,
        address target,
        bytes32 setting,
        uint256 oldValue,
        uint256 newValue,
        uint64 executableAt
    );
    event CheckRecorded(PoolId indexed pool, uint256 indexed changeId, bytes32 check, address attester, bool passed);
    event ChangeApplied(PoolId indexed pool, uint256 indexed changeId, bool instant);
    event ChangeCancelled(PoolId indexed pool, uint256 indexed changeId);
    event ModeChanged(PoolId indexed pool, uint8 oldMode, uint8 newMode);
    event BlockAdded(PoolId indexed pool, uint8 lane, address blockAddr, address author);
    // Not in the shared list (needs review).
    event AttesterSet(address indexed attester, bool allowed);
    event RequireProgrammableSet(PoolId indexed pool);

    error NotAuthorizedQueuer();
    error PoolNotLive();
    error NotCreator();
    error NotAttesterManager();
    error NotAttester();
    error NotQueued();
    error TooEarly(uint64 earliest);
    error UnsupportedKind();
    error OutOfBounds();
    error CreatorOnly();
    error InvalidLane();
    error UnknownCheck(bytes32 check);
    error CheckAlreadyFailed();
    error ChecksMissing(bytes32 check);
    error CheckFailed();
    error SameMode();

    constructor(IFluxShellGovernance _shell, AgentRegistry _agentRegistry, address _attesterManager) {
        shell = _shell;
        agentRegistry = _agentRegistry;
        attesterManager = _attesterManager;
    }

    // ---------------------------------------------------------------------
    // Proposals (creator, or the agent at its level)
    // ---------------------------------------------------------------------

    /// @notice Proposes a new value for a block setting. Safer changes apply at once in every mode;
    /// riskier ones wait out the timelock in Guarded and apply at once in Fast and Wild.
    function proposeSetting(PoolId id, address blockAddr, bytes32 setting, uint256 value)
        external
        returns (uint256 changeId)
    {
        (address creator, uint64 delay, address core) = _live(id);
        if (msg.sender != creator) {
            if (blockAddr == shell.creatorFeeBlock()) revert CreatorOnly();
            agentRegistry.authorize(id, msg.sender, AgentRegistry.Level.ProposeSettings);
        }
        (uint256 current, bool instant) = _classifySetting(id, core, blockAddr, setting, value);

        changeId = _queue(
            Entry({
                pool: id,
                kind: Kind.Setting,
                proposer: msg.sender,
                target: blockAddr,
                setting: setting,
                oldValue: current,
                newValue: value,
                delay: instant ? 0 : delay,
                needsChecks: false
            }),
            abi.encode(blockAddr, setting, value)
        );
        if (instant) _applyNow(changeId);
    }

    /// @notice Proposes a whole new block list for a lane (0 before swap, 1 after swap).
    /// @param extraChecks Checks to require on top of the protocol minimum.
    function proposeLaneChange(PoolId id, uint8 lane, address[] calldata blocks, bytes32[] calldata extraChecks)
        external
        returns (uint256)
    {
        _authorizeCode(id);
        return _proposeLane(id, lane, blocks, extraChecks, address(0));
    }

    /// @notice Proposes inserting one block into a lane at `position` (0 = first to run).
    function proposeBlock(PoolId id, uint8 lane, uint256 position, address blockAddr, bytes32[] calldata checks)
        external
        returns (uint256)
    {
        address core = _authorizeCode(id);
        if (lane > 1) revert InvalidLane();
        address[] memory cur = IFluxCoreAdmin(core).blocksIn(lane);
        if (position > cur.length) revert InvalidLane();
        address[] memory next = new address[](cur.length + 1);
        for (uint256 i; i < next.length; i++) {
            next[i] = i < position ? cur[i] : i == position ? blockAddr : cur[i - 1];
        }
        return _proposeLane(id, lane, next, checks, blockAddr);
    }

    /// @notice Switches the pool's freedom mode. Creator only: no agent level can change the mode.
    /// A safer mode applies at once; a freer one always waits out the timelock.
    function setMode(PoolId id, uint8 newMode) external returns (uint256 changeId) {
        (address creator, uint64 delay,) = _live(id);
        if (msg.sender != creator) revert NotCreator();
        if (newMode > uint8(Mode.Wild)) revert UnsupportedKind();
        Mode cur = modeOf(id);
        if (Mode(newMode) == cur) revert SameMode();
        if (newMode < uint8(cur)) {
            _setMode(id, Mode(newMode));
            return 0;
        }
        return _queue(
            Entry({
                pool: id,
                kind: Kind.Mode,
                proposer: msg.sender,
                target: address(0),
                setting: bytes32(0),
                oldValue: uint256(cur),
                newValue: newMode,
                delay: delay,
                needsChecks: false
            }),
            abi.encode(newMode)
        );
    }

    /// @notice Makes `programmableVerified` a required check on this pool's new blocks. One-way.
    function setRequireProgrammable(PoolId id) external {
        (address creator,,) = _live(id);
        if (msg.sender != creator) revert NotCreator();
        requireProgrammable[id] = true;
        emit RequireProgrammableSet(id);
    }

    /// @inheritdoc IChangeQueue
    function queue(
        PoolId id,
        address proposer,
        Kind kind,
        address target,
        bytes32 setting,
        uint256 oldValue,
        uint256 newValue,
        bytes calldata payload
    ) external returns (uint256) {
        if (msg.sender != address(agentRegistry)) revert NotAuthorizedQueuer();
        if (kind != Kind.Agent && kind != Kind.AgentRateLimit) revert UnsupportedKind();
        (, uint64 delay,) = _live(id);
        return _queue(
            Entry({
                pool: id,
                kind: kind,
                proposer: proposer,
                target: target,
                setting: setting,
                oldValue: oldValue,
                newValue: newValue,
                delay: delay,
                needsChecks: false
            }),
            payload
        );
    }

    // ---------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------

    function setAttester(address attester, bool allowed) external {
        if (msg.sender != attesterManager) revert NotAttesterManager();
        isAttester[attester] = allowed;
        emit AttesterSet(attester, allowed);
    }

    /// @notice Records a check result for a queued change. A failure is final, and any failed check,
    /// required or not, stops the change from ever executing.
    function recordCheck(uint256 changeId, bytes32 check, bool passed) external {
        if (!isAttester[msg.sender]) revert NotAttester();
        Change storage c = _changes[changeId];
        if (c.status != Status.Queued) revert NotQueued();
        if (!_isKnownCheck(check)) revert UnknownCheck(check);
        if (checkResult[changeId][check] == CheckResult.Failed) revert CheckAlreadyFailed();
        checkResult[changeId][check] = passed ? CheckResult.Passed : CheckResult.Failed;
        if (!passed) anyCheckFailed[changeId] = true;
        emit CheckRecorded(c.pool, changeId, check, msg.sender, passed);
    }

    // ---------------------------------------------------------------------
    // Execute and cancel
    // ---------------------------------------------------------------------

    /// @notice Applies a queued change once its delay has passed and its checks are in. Anyone may call.
    function execute(uint256 changeId) external {
        Change storage c = _changes[changeId];
        if (c.status != Status.Queued) revert NotQueued();

        uint64 earliest = c.executableAt;
        if (_needsDelay(c.kind, modeOf(c.pool))) {
            (,, uint64 delay,) = shell.governanceOf(c.pool);
            uint64 byMode = c.queuedAt + delay;
            if (byMode > earliest) earliest = byMode;
        }
        if (block.timestamp < earliest) revert TooEarly(earliest);
        if (anyCheckFailed[changeId]) revert CheckFailed();

        if (c.needsChecks) {
            bytes32[] storage req = _requiredChecks[changeId];
            for (uint256 i; i < req.length; i++) {
                if (checkResult[changeId][req[i]] != CheckResult.Passed) revert ChecksMissing(req[i]);
            }
        }

        c.status = Status.Applied;
        _apply(changeId);
        emit ChangeApplied(c.pool, changeId, false);
    }

    /// @notice The pool's creator can cancel any queued change at any time.
    function cancel(uint256 changeId) external {
        Change storage c = _changes[changeId];
        if (c.status != Status.Queued) revert NotQueued();
        (, address creator,,) = shell.governanceOf(c.pool);
        if (msg.sender != creator) revert NotCreator();
        c.status = Status.Cancelled;
        emit ChangeCancelled(c.pool, changeId);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function modeOf(PoolId id) public view returns (Mode) {
        return _modeSet[id] ? _mode[id] : Mode(shell.launchModeOf(id));
    }

    function changeOf(uint256 changeId)
        external
        view
        returns (
            PoolId pool,
            Kind kind,
            Status status,
            bool needsChecks,
            uint64 queuedAt,
            uint64 executableAt,
            address proposer,
            bytes memory payload
        )
    {
        Change storage c = _changes[changeId];
        return (c.pool, c.kind, c.status, c.needsChecks, c.queuedAt, c.executableAt, c.proposer, c.payload);
    }

    function requiredChecksOf(uint256 changeId) external view returns (bytes32[] memory) {
        return _requiredChecks[changeId];
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _live(PoolId id) internal view returns (address creator, uint64 delay, address core) {
        bool live;
        (live, creator, delay, core) = shell.governanceOf(id);
        if (!live) revert PoolNotLive();
    }

    /// @dev Rejects out-of-bounds values; a change is instant if it's safer, or the pool isn't Guarded.
    function _classifySetting(PoolId id, address core, address blockAddr, bytes32 setting, uint256 value)
        internal
        view
        returns (uint256 current, bool instant)
    {
        (bool ok, uint256 min, uint256 max, bool higherIsSafer) = _bounds(blockAddr, setting);
        if (!ok || value < min || value > max) revert OutOfBounds();
        current = IFluxBlock(blockAddr).getSetting(core, setting);
        bool safer = value == current || (higherIsSafer ? value > current : value < current);
        instant = safer || modeOf(id) != Mode.Guarded;
    }

    function _authorizeCode(PoolId id) internal returns (address core) {
        address creator;
        (creator,, core) = _live(id);
        if (msg.sender != creator) agentRegistry.authorize(id, msg.sender, AgentRegistry.Level.ProposeCode);
    }

    function _proposeLane(
        PoolId id,
        uint8 lane,
        address[] memory blocks,
        bytes32[] calldata extraChecks,
        address addedBlock
    ) internal returns (uint256 changeId) {
        (, uint64 delay, address core) = _live(id);
        if (lane > 1 || blocks.length > MAX_BLOCKS_PER_LANE) revert InvalidLane();
        for (uint256 i; i < blocks.length; i++) {
            if (blocks[i].code.length == 0) revert InvalidLane();
            for (uint256 j; j < i; j++) {
                if (blocks[i] == blocks[j]) revert InvalidLane();
            }
        }
        for (uint256 i; i < extraChecks.length; i++) {
            if (!_isKnownCheck(extraChecks[i])) revert UnknownCheck(extraChecks[i]);
        }

        Mode mode = modeOf(id);
        bool needsChecks = mode != Mode.Wild && _hasNewCode(core, blocks);
        bool instant = mode == Mode.Wild || (mode == Mode.Fast && !needsChecks);
        uint256 oldLength = IFluxCoreAdmin(core).blocksIn(lane).length;

        changeId = _queue(
            Entry({
                pool: id,
                kind: Kind.Lane,
                proposer: msg.sender,
                target: addedBlock,
                setting: bytes32(uint256(lane)),
                oldValue: oldLength,
                newValue: blocks.length,
                delay: mode == Mode.Guarded ? delay : 0,
                needsChecks: needsChecks
            }),
            abi.encode(lane, blocks)
        );
        if (needsChecks) _storeRequiredChecks(changeId, id, extraChecks);
        if (instant) _applyNow(changeId);
    }

    function _storeRequiredChecks(uint256 changeId, PoolId id, bytes32[] calldata extra) internal {
        bytes32[] storage req = _requiredChecks[changeId];
        req.push(COMPILED);
        req.push(INTERFACE);
        req.push(SIMULATED);
        req.push(SOURCE_VERIFIED);
        if (requireProgrammable[id]) req.push(PROGRAMMABLE_VERIFIED);
        for (uint256 i; i < extra.length; i++) {
            bool dup;
            for (uint256 j; j < req.length; j++) {
                if (req[j] == extra[i]) dup = true;
            }
            if (!dup) req.push(extra[i]);
        }
    }

    function _queue(Entry memory e, bytes memory payload) internal returns (uint256 changeId) {
        changeId = nextChangeId++;
        uint64 executableAt = uint64(block.timestamp) + e.delay;
        _changes[changeId] = Change({
            pool: e.pool,
            kind: e.kind,
            status: Status.Queued,
            needsChecks: e.needsChecks,
            queuedAt: uint64(block.timestamp),
            executableAt: executableAt,
            proposer: e.proposer,
            payload: payload
        });
        emit ChangeQueued(
            e.pool, changeId, e.proposer, uint8(e.kind), e.target, e.setting, e.oldValue, e.newValue, executableAt
        );
    }

    function _applyNow(uint256 changeId) internal {
        Change storage c = _changes[changeId];
        c.status = Status.Applied;
        _apply(changeId);
        emit ChangeApplied(c.pool, changeId, true);
    }

    function _apply(uint256 changeId) internal {
        Change storage c = _changes[changeId];
        PoolId id = c.pool;
        if (c.kind == Kind.Setting) {
            (address blockAddr, bytes32 setting, uint256 value) = abi.decode(c.payload, (address, bytes32, uint256));
            (,,, address core) = shell.governanceOf(id);
            IFluxCoreAdmin(core).setBlockSetting(blockAddr, setting, value);
        } else if (c.kind == Kind.Lane) {
            (uint8 lane, address[] memory blocks) = abi.decode(c.payload, (uint8, address[]));
            (,,, address core) = shell.governanceOf(id);
            address[] memory old = IFluxCoreAdmin(core).blocksIn(lane);
            IFluxCoreAdmin(core).setLane(lane, blocks);
            for (uint256 i; i < blocks.length; i++) {
                if (!_contains(old, blocks[i])) emit BlockAdded(id, lane, blocks[i], c.proposer);
            }
        } else if (c.kind == Kind.Mode) {
            _setMode(id, Mode(abi.decode(c.payload, (uint8))));
        } else {
            agentRegistry.applyQueued(id, c.kind, c.payload);
        }
    }

    function _setMode(PoolId id, Mode newMode) internal {
        Mode old = modeOf(id);
        _modeSet[id] = true;
        _mode[id] = newMode;
        emit ModeChanged(id, uint8(old), uint8(newMode));
    }

    /// @dev Whether `kind` must wait out the timelock under `mode`.
    function _needsDelay(Kind kind, Mode mode) internal pure returns (bool) {
        if (kind == Kind.Setting || kind == Kind.Lane) return mode == Mode.Guarded;
        return true; // agent changes and freer modes are always timelocked
    }

    /// @dev True if `blocks` contains a block that isn't in either of the pool's current lanes.
    function _hasNewCode(address core, address[] memory blocks) internal view returns (bool) {
        address[] memory a = IFluxCoreAdmin(core).blocksIn(0);
        address[] memory b = IFluxCoreAdmin(core).blocksIn(1);
        for (uint256 i; i < blocks.length; i++) {
            if (!_contains(a, blocks[i]) && !_contains(b, blocks[i])) return true;
        }
        return false;
    }

    function _contains(address[] memory list, address x) internal pure returns (bool) {
        for (uint256 i; i < list.length; i++) {
            if (list[i] == x) return true;
        }
        return false;
    }

    function _isKnownCheck(bytes32 check) internal pure returns (bool) {
        return check == COMPILED || check == INTERFACE || check == SIMULATED || check == SOURCE_VERIFIED
            || check == PROGRAMMABLE_VERIFIED;
    }

    /// @dev Gas-limited read of a block's bounds; blocks are untrusted.
    function _bounds(address blockAddr, bytes32 setting)
        internal
        view
        returns (bool ok, uint256 min, uint256 max, bool higherIsSafer)
    {
        try IFluxBlock(blockAddr).settingBounds{gas: READ_GAS}(setting) returns (uint256 a, uint256 b, bool c) {
            return (a <= b, a, b, c);
        } catch {
            return (false, 0, 0, false);
        }
    }
}
