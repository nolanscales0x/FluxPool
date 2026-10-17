// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IFluxShellGovernance} from "../interfaces/IFluxShellGovernance.sol";
import {IChangeQueue} from "../interfaces/IChangeQueue.sol";

/// @title AgentRegistry
/// @notice Who may act on each pool as its agent, at what permission level, and how often. Part of
/// the immutable layer: no block or core change can remove it.
///
///  - The creator sets the agent. Adding an agent, replacing it or raising its level always waits
///    out the pool's timelock (queued in the ChangeRegistry), whatever the pool's freedom mode.
///  - Lowering the level or removing the agent is instant: that's the off switch. It also voids any
///    agent change still queued, so a pending raise can't bring a removed agent back.
///  - Every agent action is checked here by the playbook or change registry: right caller, high
///    enough level, within rate limits. No level can move funds, change caps, approve playbooks,
///    change the freedom mode or touch the shell; those calls don't exist for agents.
///  - The agent is whatever address the creator registers, so a scoped smart account with session
///    keys works as-is.
contract AgentRegistry {
    enum Level {
        None,
        Fire, // fire(playbookId)
        ProposeSettings, // + proposeSetting
        ProposeCode // + proposeBlock, proposeLaneChange
    }

    struct Agent {
        address account;
        Level level;
        uint64 epoch; // bumped on every instant change; queued changes from an older epoch are void
    }

    struct RateLimit {
        uint32 minGap; // seconds between actions
        uint32 dailyMax; // actions per UTC day
    }

    struct Usage {
        uint64 lastAction;
        uint64 day;
        uint32 countToday;
    }

    uint32 public constant DEFAULT_MIN_GAP = 60;
    uint32 public constant DEFAULT_DAILY_MAX = 48;
    uint32 public constant MIN_GAP_FLOOR = 10;
    uint32 public constant MIN_GAP_CEILING = 1 days;
    uint32 public constant DAILY_MAX_CEILING = 200;

    IFluxShellGovernance public immutable shell;
    IChangeQueue public immutable changeRegistry;
    address public immutable playbookRegistry;

    mapping(PoolId => Agent) internal _agents;
    mapping(PoolId => RateLimit) internal _limits;
    mapping(PoolId => Usage) public usage;

    /// @notice Shared journal event: emitted whenever the active agent or its level changes.
    event AgentSet(PoolId indexed pool, address agent, uint8 level);
    event RateLimitsSet(PoolId indexed pool, uint32 minGap, uint32 dailyMax);

    error NotCreator();
    error NotChangeRegistry();
    error NotRegistry();
    error PoolNotLive();
    error InvalidLevel();
    error InvalidRateLimits();
    error StaleChange();
    error NotAgent();
    error LevelTooLow();
    error TooSoon();
    error DailyLimitReached();

    constructor(IFluxShellGovernance _shell, IChangeQueue _changeRegistry, address _playbookRegistry) {
        shell = _shell;
        changeRegistry = _changeRegistry;
        playbookRegistry = _playbookRegistry;
    }

    // ---------------------------------------------------------------------
    // Creator
    // ---------------------------------------------------------------------

    /// @notice Sets the pool's agent. Instant when it removes the agent or lowers its level;
    /// otherwise queued behind the pool's timelock. Returns the queued change id, or 0 if instant.
    function setAgent(PoolId id, address agent, uint8 level) external returns (uint256 changeId) {
        _requireCreator(id);
        if (level > uint8(Level.ProposeCode)) revert InvalidLevel();
        Agent storage cur = _agents[id];

        if (agent == address(0) || level == uint8(Level.None)) {
            _applyInstant(id, address(0), Level.None);
            return 0;
        }
        if (agent == cur.account && level <= uint8(cur.level)) {
            _applyInstant(id, agent, Level(level));
            return 0;
        }
        return changeRegistry.queue(
            id,
            msg.sender,
            IChangeQueue.Kind.Agent,
            agent,
            bytes32(0),
            uint256(cur.level),
            level,
            abi.encode(agent, level, cur.epoch)
        );
    }

    /// @notice The off switch: removes the agent at once and voids its queued changes.
    function removeAgent(PoolId id) external {
        _requireCreator(id);
        _applyInstant(id, address(0), Level.None);
    }

    /// @notice Sets the agent's rate limits. Tightening (longer gap and lower daily max) is instant;
    /// anything else waits out the timelock. Returns the queued change id, or 0 if instant.
    function setRateLimits(PoolId id, uint32 minGap, uint32 dailyMax) external returns (uint256 changeId) {
        _requireCreator(id);
        if (minGap < MIN_GAP_FLOOR || minGap > MIN_GAP_CEILING || dailyMax == 0 || dailyMax > DAILY_MAX_CEILING) {
            revert InvalidRateLimits();
        }
        RateLimit memory cur = rateLimitsOf(id);
        if (minGap >= cur.minGap && dailyMax <= cur.dailyMax) {
            _setLimits(id, minGap, dailyMax);
            return 0;
        }
        return changeRegistry.queue(
            id,
            msg.sender,
            IChangeQueue.Kind.AgentRateLimit,
            address(0),
            bytes32(0),
            (uint256(cur.minGap) << 32) | cur.dailyMax,
            (uint256(minGap) << 32) | dailyMax,
            abi.encode(minGap, dailyMax)
        );
    }

    // ---------------------------------------------------------------------
    // Change registry (executes queued changes)
    // ---------------------------------------------------------------------

    function applyQueued(PoolId id, IChangeQueue.Kind kind, bytes calldata payload) external {
        if (msg.sender != address(changeRegistry)) revert NotChangeRegistry();
        if (kind == IChangeQueue.Kind.Agent) {
            (address agent, uint8 level, uint64 epoch) = abi.decode(payload, (address, uint8, uint64));
            Agent storage cur = _agents[id];
            if (epoch != cur.epoch) revert StaleChange();
            if (agent != cur.account) delete usage[id];
            cur.account = agent;
            cur.level = Level(level);
            emit AgentSet(id, agent, level);
        } else {
            (uint32 minGap, uint32 dailyMax) = abi.decode(payload, (uint32, uint32));
            _setLimits(id, minGap, dailyMax);
        }
    }

    // ---------------------------------------------------------------------
    // Registries (check an agent action)
    // ---------------------------------------------------------------------

    /// @notice Checks that `caller` is the pool's agent at `required` level or above and within its
    /// rate limits, and records the action. Callable only by the playbook and change registries.
    function authorize(PoolId id, address caller, Level required) external {
        if (msg.sender != playbookRegistry && msg.sender != address(changeRegistry)) revert NotRegistry();
        Agent storage a = _agents[id];
        if (a.account == address(0) || caller != a.account) revert NotAgent();
        if (uint8(a.level) < uint8(required)) revert LevelTooLow();

        RateLimit memory lim = rateLimitsOf(id);
        Usage storage u = usage[id];
        if (u.lastAction != 0 && block.timestamp < uint256(u.lastAction) + lim.minGap) revert TooSoon();
        uint64 day = uint64(block.timestamp / 1 days);
        if (u.day != day) {
            u.day = day;
            u.countToday = 0;
        }
        if (u.countToday >= lim.dailyMax) revert DailyLimitReached();
        u.countToday += 1;
        u.lastAction = uint64(block.timestamp);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice The pool's active agent, or zero. The shell reads this for the agent fee share.
    function agentOf(PoolId id) external view returns (address) {
        return _agents[id].account;
    }

    function agentInfo(PoolId id) external view returns (address account, Level level, uint64 epoch) {
        Agent storage a = _agents[id];
        return (a.account, a.level, a.epoch);
    }

    function rateLimitsOf(PoolId id) public view returns (RateLimit memory lim) {
        lim = _limits[id];
        if (lim.minGap == 0) lim = RateLimit({minGap: DEFAULT_MIN_GAP, dailyMax: DEFAULT_DAILY_MAX});
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _requireCreator(PoolId id) internal view {
        (bool live, address creator,,) = shell.governanceOf(id);
        if (!live) revert PoolNotLive();
        if (msg.sender != creator) revert NotCreator();
    }

    function _applyInstant(PoolId id, address agent, Level level) internal {
        Agent storage cur = _agents[id];
        if (agent != cur.account) delete usage[id];
        cur.account = agent;
        cur.level = level;
        cur.epoch += 1;
        emit AgentSet(id, agent, uint8(level));
    }

    function _setLimits(PoolId id, uint32 minGap, uint32 dailyMax) internal {
        _limits[id] = RateLimit({minGap: minGap, dailyMax: dailyMax});
        emit RateLimitsSet(id, minGap, dailyMax);
    }
}
