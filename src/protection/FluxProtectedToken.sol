// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FluxProtectedToken
/// @notice The launch token for a protected FluxPool pool. Fixed supply minted once, 18 decimals, no
/// owner, no pause, no upgrade path, and no mint after construction.
/// It enforces one of the three protections Programmable's `launch-protection.v1` requires, and it is
/// the only place that protection can be enforced: a cumulative 2% recipient-inflow budget for the
/// first 300 seconds of trading, counted against the recipient of every transfer rather than against
/// the sender. The buyer budget lives in the shell (against the token leg the swapper receives) and
/// the opening fee lives in the pool's protection module; this contract is the recipient half.
/// What counts, and what does not (mirroring the reference `ProtectedLaunchTokenV1`):
///   - every transfer with a nonzero sender, nonzero recipient and nonzero amount counts;
///   - minting and burning do not, so `burn` is how a holder leaves and it is not budgeted;
///   - self-transfers do not count and are not blocked;
///   - transfers to the PoolManager do not count, because that is a sell, a settle, or liquidity;
///   - before `start()` the only transfer allowed is the seed: this contract to the PoolManager.
/// The budget only ever increases. Selling, transferring out and burning never restore it, so a
/// wallet's 2% is a total for the window and not a balance it can refill.
/// There are no exemptions here. The exemption list in the policy covers the opening fee only, and it
/// lives in the module; a developer and their six wallets are capped by this contract like anyone.
contract FluxProtectedToken is ERC20 {
    /// @notice The revision of the protection this contract implements. Our own counter, not
    /// Programmable's: it moves whenever one of the enforced rules changes.
    uint256 public constant POLICY_REVISION = 1;

    /// @notice Recipient budget per wallet, in bps of the launch supply. The policy's
    /// `walletLimitBps`.
    uint256 internal constant WALLET_LIMIT_BPS = 200;
    uint256 internal constant BPS = 10_000;
    /// @notice How long the recipient budget lasts. The policy's `protectionSeconds`.
    uint256 internal constant PROTECTION_SECONDS = 300;
    /// @notice Supply ceiling. A supply above this would not survive the signed accounting a swap uses.
    uint256 internal constant MAX_SUPPLY = uint256(int256(type(int128).max));

    /// @notice The launch adapter. It holds the whole supply at deploy, is the only address that can
    /// send before `start()`, and is the only caller of `start()`.
    address public immutable initializer;
    /// @notice The PoolManager this token expects to be traded against. Transfers to it are uncounted,
    /// which is what lets a sell settle without eating anyone's budget.
    address public immutable poolManager;
    /// @notice The whole supply, fixed at deploy. The budget is a share of this, not of any later
    /// balance, so a burn cannot lower the limit.
    uint256 public immutable launchSupply;
    /// @notice The recipient budget in tokens: 2% of the launch supply, rounded down.
    uint256 public immutable walletTokenLimit;

    /// @notice When trading opened, set once by the initializer. Zero means it has not.
    uint64 public startedAt;
    /// @notice Cumulative inflow per recipient during the window. Never decremented.
    mapping(address recipient => uint256) public receivedDuringProtection;

    event ProtectionStarted(uint64 startedAt, uint64 protectionEndsAt);

    error InvalidConfiguration();
    error NotInitializer();
    error AlreadyStarted();
    error TradingNotStarted();
    error WalletLimitExceeded(address recipient, uint256 attempted, uint256 limit);

    constructor(string memory name_, string memory symbol_, uint256 supply_, address initializer_, address manager_)
        ERC20(name_, symbol_)
    {
        // The supply floor and ceiling are the reference contract's: a supply below 50 would round the
        // 2% budget to zero and make the token untradeable, and a supply above int128 max would not
        // survive the signed accounting a swap uses.
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert InvalidConfiguration();
        if (supply_ < 50 || supply_ > MAX_SUPPLY) revert InvalidConfiguration();
        if (initializer_ == address(0) || initializer_ == manager_) revert InvalidConfiguration();
        if (manager_.code.length == 0) revert InvalidConfiguration();

        initializer = initializer_;
        poolManager = manager_;
        launchSupply = supply_;
        walletTokenLimit = supply_ * WALLET_LIMIT_BPS / BPS;

        _mint(initializer_, supply_);
    }

    /// @notice Opens trading and starts both protection windows. Callable once, by the initializer,
    /// inside the launch transaction, after the liquidity is seeded and before the initial buy, so
    /// the initial buy is itself subject to the budgets.
    function start() external {
        if (msg.sender != initializer) revert NotInitializer();
        if (startedAt != 0) revert AlreadyStarted();
        startedAt = uint64(block.timestamp);
        emit ProtectionStarted(startedAt, uint64(uint256(startedAt) + PROTECTION_SECONDS));
    }

    /// @notice Burns the caller's own tokens. Excluded from the recipient budget, so leaving the pool
    /// this way never counts against anyone, and burning cannot lower anyone's limit because the limit
    /// is a share of the launch supply.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice When the recipient window closes. Zero while trading has not started.
    function protectionEndsAt() external view returns (uint64) {
        return startedAt == 0 ? 0 : uint64(uint256(startedAt) + PROTECTION_SECONDS);
    }

    /// @dev The whole protection, in one place, on the path every ERC-20 movement takes.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0) {
            uint64 started = startedAt;
            if (started == 0) {
                // Before trading opens the seed is the only movement: the initializer paying tokens
                // into the pool. Anything else is refused rather than capped.
                if (from != initializer || to != poolManager) revert TradingNotStarted();
            } else if (block.timestamp < uint256(started) + PROTECTION_SECONDS && to != poolManager && from != to) {
                uint256 received = receivedDuringProtection[to] + value;
                if (received > walletTokenLimit) revert WalletLimitExceeded(to, received, walletTokenLimit);
                receivedDuringProtection[to] = received;
            }
        }
        super._update(from, to, value);
    }
}
