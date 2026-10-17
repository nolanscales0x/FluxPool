// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IFluxBlock} from "../core/IFluxBlock.sol";
import {IFluxShellGovernance} from "../interfaces/IFluxShellGovernance.sol";
import {IFluxCoreAdmin} from "../interfaces/IFluxCoreAdmin.sol";
import {AgentRegistry} from "../agents/AgentRegistry.sol";

/// @title PlaybookRegistry
/// @notice Responses the community approves in advance. A playbook can only tighten settings, so
/// firing it is instant in every freedom mode. Part of the immutable layer.
///
///  - Approval: the creator adds a playbook. Any action that would move a setting in its riskier
///    direction (per the block's settingBounds) is rejected.
///  - Firing: the pool's agent (Fire level, within its rate limits) or the creator calls fire().
///    Each action is re-checked against the current value; one that would no longer tighten is
///    skipped. A playbook that is already active can't fire again until it expires.
///  - Returning to normal: after the cooldown anyone calls expire(), which restores each setting the
///    playbook changed, but only if it still holds the value the playbook set. A setting someone
///    else changed since (another playbook or a timelocked change) is left alone. With overlapping
///    playbooks on one setting this can leave it tighter than before, never looser.
///  - Optional on-chain trigger: a sustained price drop, measured only between start-of-block prices
///    the shell recorded, so trades inside a block can't fake it and the drop must hold for
///    `holdBlocks`.
///
/// Scheduled windows (phase C) will be a second playbook kind: a pre-approved, time-limited
/// loosening approved through the timelock. `Kind` is reserved for it.
contract PlaybookRegistry {
    enum Kind {
        Response // tighten-only response; ScheduledWindow comes in phase C
    }

    struct Action {
        address blockAddr;
        bytes32 setting;
        uint256 value;
    }

    /// @notice Fire only if the launched token's price fell by at least `minDropTicks` (about 1 bp per
    /// tick) from `windowBlocks + holdBlocks` ago, and is still down that much `holdBlocks` ago and now.
    struct Trigger {
        uint32 windowBlocks;
        uint32 holdBlocks;
        int24 minDropTicks; // 0 means no trigger check
    }

    struct Playbook {
        PoolId pool;
        Kind kind;
        bool removed;
        uint32 cooldown;
        uint16 maxFiresPerDay;
        Trigger trigger;
        Action[] actions;
    }

    struct FireState {
        uint64 activeUntil; // 0 when not active
        uint64 day;
        uint16 firesToday;
        bool expired; // true once the last fire has been expired
    }

    uint256 public constant MAX_ACTIONS = 8;
    uint32 public constant MIN_COOLDOWN = 5 minutes;
    uint32 public constant MAX_COOLDOWN = 7 days;
    uint16 public constant MAX_FIRES_PER_DAY = 24;
    /// @notice The shell keeps 64 observations; a trigger must fit inside them.
    uint32 public constant MAX_TRIGGER_SPAN = 63;
    uint256 internal constant READ_GAS = 50_000;

    IFluxShellGovernance public immutable shell;
    AgentRegistry public immutable agentRegistry;

    uint256 public nextPlaybookId = 1;
    mapping(uint256 => Playbook) internal _playbooks;
    mapping(uint256 => FireState) public fireState;
    /// @notice Per fire: the value each action replaced (only for actions that were applied).
    mapping(uint256 playbookId => mapping(uint256 actionIndex => uint256)) internal _previous;
    mapping(uint256 playbookId => mapping(uint256 actionIndex => bool)) internal _applied;

    // Shared journal events.
    event PlaybookAdded(PoolId indexed pool, uint256 indexed playbookId);
    event PlaybookFired(PoolId indexed pool, uint256 indexed playbookId, address firedBy);
    event PlaybookExpired(PoolId indexed pool, uint256 indexed playbookId);
    event PlaybookRemoved(PoolId indexed pool, uint256 indexed playbookId);

    error PoolNotLive();
    error NotCreator();
    error InvalidPlaybook();
    error LooseningAction(uint256 index);
    error OutOfBounds(uint256 index);
    error UnknownPlaybook();
    error AlreadyActive();
    error NotActive();
    error CooldownNotOver(uint64 activeUntil);
    error DailyFireLimit();
    error TriggerNotMet();
    error NothingToTighten();

    constructor(IFluxShellGovernance _shell, AgentRegistry _agentRegistry) {
        shell = _shell;
        agentRegistry = _agentRegistry;
    }

    // ---------------------------------------------------------------------
    // Creator
    // ---------------------------------------------------------------------

    function addPlaybook(
        PoolId id,
        Action[] calldata actions,
        uint32 cooldown,
        uint16 maxFiresPerDay,
        Trigger calldata trigger
    ) external returns (uint256 playbookId) {
        (, address core) = _requireCreator(id);
        if (
            actions.length == 0 || actions.length > MAX_ACTIONS || cooldown < MIN_COOLDOWN || cooldown > MAX_COOLDOWN
                || maxFiresPerDay == 0 || maxFiresPerDay > MAX_FIRES_PER_DAY
        ) revert InvalidPlaybook();
        if (trigger.minDropTicks < 0) revert InvalidPlaybook();
        if (
            trigger.minDropTicks > 0
                && (trigger.windowBlocks == 0
                    || trigger.holdBlocks == 0
                    || uint256(trigger.windowBlocks) + trigger.holdBlocks > MAX_TRIGGER_SPAN)
        ) revert InvalidPlaybook();

        for (uint256 i; i < actions.length; i++) {
            (bool ok, uint256 min, uint256 max, bool higherIsSafer) = _bounds(actions[i].blockAddr, actions[i].setting);
            if (!ok || actions[i].value < min || actions[i].value > max) revert OutOfBounds(i);
            uint256 current = IFluxBlock(actions[i].blockAddr).getSetting(core, actions[i].setting);
            if (!_isTighter(actions[i].value, current, higherIsSafer, true)) revert LooseningAction(i);
        }

        playbookId = nextPlaybookId++;
        Playbook storage p = _playbooks[playbookId];
        p.pool = id;
        p.kind = Kind.Response;
        p.cooldown = cooldown;
        p.maxFiresPerDay = maxFiresPerDay;
        p.trigger = trigger;
        for (uint256 i; i < actions.length; i++) {
            p.actions.push(actions[i]);
        }
        fireState[playbookId].expired = true;
        emit PlaybookAdded(id, playbookId);
    }

    /// @notice Removes a playbook that isn't active. An active one must expire first, so its
    /// settings always have a way back.
    function removePlaybook(uint256 playbookId) external {
        Playbook storage p = _playbook(playbookId);
        _requireCreator(p.pool);
        if (!fireState[playbookId].expired) revert AlreadyActive();
        p.removed = true;
        emit PlaybookRemoved(p.pool, playbookId);
    }

    // ---------------------------------------------------------------------
    // Fire and expire
    // ---------------------------------------------------------------------

    /// @notice Applies the playbook's actions at once. Callable by the pool's agent (Fire level and
    /// within its rate limits) or the creator.
    function fire(uint256 playbookId) external {
        Playbook storage p = _playbook(playbookId);
        PoolId id = p.pool;
        (bool live, address creator,, address core) = shell.governanceOf(id);
        if (!live) revert PoolNotLive();
        if (msg.sender != creator) agentRegistry.authorize(id, msg.sender, AgentRegistry.Level.Fire);

        FireState storage st = fireState[playbookId];
        if (!st.expired) revert AlreadyActive();
        uint64 day = uint64(block.timestamp / 1 days);
        if (st.day != day) {
            st.day = day;
            st.firesToday = 0;
        }
        if (st.firesToday >= p.maxFiresPerDay) revert DailyFireLimit();
        if (p.trigger.minDropTicks > 0 && !triggerMet(playbookId)) revert TriggerNotMet();

        if (!_applyActions(playbookId, p, core)) revert NothingToTighten();

        st.firesToday += 1;
        st.expired = false;
        st.activeUntil = uint64(block.timestamp) + p.cooldown;
        emit PlaybookFired(id, playbookId, msg.sender);
    }

    /// @notice After the cooldown, restores every setting the last fire changed that still holds the
    /// playbook's value. Anyone may call; it was approved with the playbook, so no timelock.
    function expire(uint256 playbookId) external {
        Playbook storage p = _playbook(playbookId);
        FireState storage st = fireState[playbookId];
        if (st.expired) revert NotActive();
        if (block.timestamp < st.activeUntil) revert CooldownNotOver(st.activeUntil);
        st.expired = true;
        st.activeUntil = 0;

        (,,, address core) = shell.governanceOf(p.pool);
        for (uint256 i; i < p.actions.length; i++) {
            if (!_applied[playbookId][i]) continue;
            _applied[playbookId][i] = false;
            Action storage a = p.actions[i];
            if (IFluxBlock(a.blockAddr).getSetting(core, a.setting) != a.value) continue;
            IFluxCoreAdmin(core).setBlockSetting(a.blockAddr, a.setting, _previous[playbookId][i]);
        }
        emit PlaybookExpired(p.pool, playbookId);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Whether the playbook's on-chain trigger holds right now (true if it has none).
    function triggerMet(uint256 playbookId) public view returns (bool) {
        Playbook storage p = _playbooks[playbookId];
        Trigger memory t = p.trigger;
        if (t.minDropTicks == 0) return true;
        (bool tokenIs0,,) = shell.launchInfo(p.pool);
        try shell.observe(p.pool, uint256(t.windowBlocks) + t.holdBlocks) returns (
            IFluxShellGovernance.Observation memory ref
        ) {
            IFluxShellGovernance.Observation memory held = shell.observe(p.pool, t.holdBlocks);
            IFluxShellGovernance.Observation memory latest = shell.observe(p.pool, 0);
            if (held.blockNumber <= ref.blockNumber) return false;
            return _dropped(ref.tick, held.tick, tokenIs0) >= t.minDropTicks
                && _dropped(ref.tick, latest.tick, tokenIs0) >= t.minDropTicks;
        } catch {
            return false; // not enough price history yet
        }
    }

    function playbookOf(uint256 playbookId)
        external
        view
        returns (
            PoolId pool,
            Kind kind,
            bool removed,
            uint32 cooldown,
            uint16 maxFiresPerDay,
            Trigger memory trigger,
            Action[] memory actions
        )
    {
        Playbook storage p = _playbooks[playbookId];
        return (p.pool, p.kind, p.removed, p.cooldown, p.maxFiresPerDay, p.trigger, p.actions);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Applies each action that still tightens its setting, recording the value it replaced.
    function _applyActions(uint256 playbookId, Playbook storage p, address core) internal returns (bool any) {
        for (uint256 i; i < p.actions.length; i++) {
            Action storage a = p.actions[i];
            uint256 current = IFluxBlock(a.blockAddr).getSetting(core, a.setting);
            (bool ok,,, bool higherIsSafer) = _bounds(a.blockAddr, a.setting);
            if (!ok || !_isTighter(a.value, current, higherIsSafer, false)) {
                _applied[playbookId][i] = false;
                continue;
            }
            _previous[playbookId][i] = current;
            _applied[playbookId][i] = true;
            IFluxCoreAdmin(core).setBlockSetting(a.blockAddr, a.setting, a.value);
            any = true;
        }
    }

    function _playbook(uint256 playbookId) internal view returns (Playbook storage p) {
        p = _playbooks[playbookId];
        if (p.actions.length == 0 || p.removed) revert UnknownPlaybook();
    }

    function _requireCreator(PoolId id) internal view returns (address creator, address core) {
        bool live;
        (live, creator,, core) = shell.governanceOf(id);
        if (!live) revert PoolNotLive();
        if (msg.sender != creator) revert NotCreator();
    }

    /// @dev True if moving from `current` to `next` goes in the safer direction (or stays put when
    /// `allowEqual`).
    function _isTighter(uint256 next, uint256 current, bool higherIsSafer, bool allowEqual)
        internal
        pure
        returns (bool)
    {
        if (next == current) return allowEqual;
        return higherIsSafer ? next > current : next < current;
    }

    /// @dev How far the launched token's price fell from `fromTick` to `toTick`, in ticks. Ticks price
    /// currency0 in currency1, so a cheaper token is a higher tick when the token is currency1.
    function _dropped(int24 fromTick, int24 toTick, bool tokenIs0) internal pure returns (int24) {
        return tokenIs0 ? fromTick - toTick : toTick - fromTick;
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
