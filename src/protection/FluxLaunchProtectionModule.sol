// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FluxProtectedToken} from "./FluxProtectedToken.sol";

/// @notice The canonical router's report of who is trading. Uniswap's Universal Router exposes the
/// address that called it, for the duration of its own execution, as `msgSender()`.
interface IProtectionRouter {
    function msgSender() external view returns (address);
}

/// @title FluxLaunchProtectionModule
/// @notice One protected pool's opening-fee schedule, its exemption list and the identity of its buyers,
/// held as immutables. Deployed once per protected pool by the launcher, next to the pool's token.
///
/// Programmable's policy requires the protection rules to hold "in every mode". That is why the rules
/// that a mode could otherwise weaken are constructor arguments here rather than settings anywhere: a
/// creator, an agent, a block, a vote or the change queue has no function to call and no storage to
/// write. The only thing this contract reads that it does not itself fix is the token's `startedAt`,
/// set once inside the initialize transaction.
///
/// The three rules the policy requires are split across three contracts, because each can only be
/// enforced where it is decided:
///   - the opening fee schedule and the exemption list live here, as immutables;
///   - the buyer budget lives in the shell, keyed to the buyer this contract authenticates;
///   - the recipient budget lives in the token, keyed to the actual recipient.
///
/// A buyer's identity is the part that cannot be assumed. The sender of a swap is not the person
/// trading: it is whichever contract called the PoolManager. So the sender must be the chain's canonical
/// Universal Router — the one Programmable's policy fixes, by address *and* by code hash — and the trader
/// is the router's own `msgSender()`. `hookData` is data a caller chose and is never read. This is the
/// policy's "supported canonical buyer path"; no other router is accepted during the window.
///
/// Everything here is a `view`. There is no swap callback because our shell is itself the hook: the
/// shell asks this contract one question per protected buy and enforces the answers on its own swap path.
contract FluxLaunchProtectionModule {
    /// @notice The revision of the protection this contract implements. Our own counter, not
    /// Programmable's: it moves whenever one of the enforced rules changes.
    uint256 public constant POLICY_REVISION = 1;

    /// @notice The total buy fee at the first second of trading, in ppm of the gross quote leg. The
    /// policy's opening fee for its first thirty seconds.
    uint256 public constant OPENING_TOTAL_PPM = 990_000;
    /// @notice How long the opening fee takes to fall to the normal fee, in whole seconds.
    uint256 public constant DECAY_SECONDS = 30;
    /// @notice The buyer budget per wallet, in bps of the launch supply. The policy's `buyerLimitBps`.
    uint256 public constant BUYER_LIMIT_BPS = 200;
    /// @notice How long both budgets last. The policy's `protectionSeconds`.
    uint256 public constant PROTECTION_SECONDS = 300;

    uint256 internal constant BPS = 10_000;
    /// @notice The canonical Universal Router on Ethereum mainnet, as Programmable's policy fixes it.
    address public constant CANONICAL_ROUTER_MAINNET = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    /// @notice The canonical Universal Router on Robinhood Chain, as Programmable's policy fixes it.
    address public constant CANONICAL_ROUTER_ROBINHOOD = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;
    /// @notice The platform's share of every trade, in bps of the gross quote leg. Part of the normal
    /// fee, so it is included in `normalBuyFeePpm` and the opening fee never falls below it.
    uint256 internal constant PLATFORM_FEE_BPS = 30;
    /// @notice Ceiling on the pool's own normal rate, in bps. The reference caps a creator fee at 1000 bps
    /// and this contract keeps the same ceiling, which is also what makes
    /// `OPENING_TOTAL_PPM - normalBuyFeePpm` impossible to underflow.
    uint256 internal constant MAX_CREATOR_FEE_BPS = 1_000;

    /// @notice The FluxShell that stages the pool this module belongs to, and the only caller of the
    /// swap-facing views. The shell passes a swap's sender in, so it is the shell's own report that is
    /// authenticated; only the shell can ask with it.
    address public immutable shell;
    /// @notice The pool's token. The clock the schedule runs on is the token's `startedAt`, so the module
    /// needs no timestamp of its own and cannot diverge from the contract that holds one.
    FluxProtectedToken public immutable token;
    /// @notice The launch's developer. Pays the normal fee but not the opening fee, and is capped like
    /// everyone else — the exemption list covers the opening fee only.
    address public immutable developer;
    /// @notice The canonical Universal Router for this chain — the only router a buyer may use during the
    /// protection window. Pinned by address (a constant per chain) and by the code hash below.
    address public immutable router;
    /// @notice The router's code hash at deploy. A pin on the address alone would be satisfied by
    /// different code at that address; a pin on the hash alone would be satisfied by a copy of the router
    /// deployed anywhere.
    bytes32 public immutable routerCodeHash;
    /// @notice The pool's normal buy fee in ppm of the gross quote leg: the pool's own rate plus the
    /// platform's 30 bps. The schedule runs from `OPENING_TOTAL_PPM` down to exactly this, so the fee is
    /// the ordinary one from the thirtieth second on.
    uint256 public immutable normalBuyFeePpm;
    /// @notice The buyer budget in tokens, read from the token at deploy so it is the same number as the
    /// recipient budget by construction rather than by two independent calculations that could drift.
    uint256 public immutable buyerTokenLimit;

    /// @dev The developer and up to six wallets that pay the normal fee but not the opening fee. Zero
    /// entries are unused slots; the list is fixed at deploy and has no setter.
    address[6] private _exemptWallets;

    error InvalidConfiguration();
    error OnlyShell();
    error UnsupportedRouter();
    error InvalidBuyer();

    /// @param shell_ The FluxShell that will stage the pool. Must be a contract.
    /// @param token_ The pool's `FluxProtectedToken`. Its `initializer` and `poolManager` are read here,
    /// so the module is bound to those addresses too.
    /// @param developer_ The launch's developer, who is exempt from the opening fee.
    /// @param router_ The chain's canonical Universal Router: `CANONICAL_ROUTER_MAINNET` on chain 1,
    /// `CANONICAL_ROUTER_ROBINHOOD` on chain 4663. Anything else is refused.
    /// @param routerCodeHash_ `router_.codehash`, supplied rather than computed so the value the launch
    /// plan committed to is the value the pool runs with.
    /// @param creatorBuyFeeBps_ The pool's own normal buy rate in bps. `normalBuyFeePpm` is
    /// `(30 + creatorBuyFeeBps_) * 100`.
    /// @param exemptWallets_ Up to six wallets exempt from the opening fee. Zeros are unused slots.
    constructor(
        address shell_,
        FluxProtectedToken token_,
        address developer_,
        address router_,
        bytes32 routerCodeHash_,
        uint16 creatorBuyFeeBps_,
        address[6] memory exemptWallets_
    ) {
        // The policy supports chains 1 and 4663 only. Refusing every other chain at construction is
        // what makes "this pool cannot be deployed where the policy does not apply" a property of the
        // module rather than a checklist item in a plan.
        if (block.chainid != 1 && block.chainid != 4663) revert InvalidConfiguration();
        if (shell_ == address(0) || shell_.code.length == 0) revert InvalidConfiguration();
        if (address(token_).code.length == 0) revert InvalidConfiguration();
        if (developer_ == address(0) || developer_ == shell_ || developer_ == address(token_)) {
            revert InvalidConfiguration();
        }
        // The pool manager is the only other address the token itself is bound to; the developer must not
        // be it, and neither must any exempt wallet below.
        if (developer_ == token_.poolManager()) revert InvalidConfiguration();
        if (routerCodeHash_ == bytes32(0) || router_.code.length == 0) revert InvalidConfiguration();
        if (router_ != (block.chainid == 1 ? CANONICAL_ROUTER_MAINNET : CANONICAL_ROUTER_ROBINHOOD)) {
            revert InvalidConfiguration();
        }
        if (router_.codehash != routerCodeHash_) revert InvalidConfiguration();
        if (creatorBuyFeeBps_ > MAX_CREATOR_FEE_BPS) revert InvalidConfiguration();

        for (uint256 i; i < exemptWallets_.length; ++i) {
            address wallet = exemptWallets_[i];
            if (wallet == address(0)) continue;
            // An exempt entry must not be one of the addresses the pool's own machinery sits at: a
            // wallet that is the router would exemption-flag the router, and the developer, the shell,
            // the token, the manager and the initializer are all contracts that must never be treated as
            // a person paying fees.
            if (
                wallet == developer_ || wallet == shell_ || wallet == address(token_) || wallet == token_.poolManager()
                    || wallet == router_ || wallet == token_.initializer()
            ) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (wallet == exemptWallets_[j]) revert InvalidConfiguration();
            }
        }

        shell = shell_;
        token = token_;
        developer = developer_;
        router = router_;
        routerCodeHash = routerCodeHash_;
        normalBuyFeePpm = (PLATFORM_FEE_BPS + uint256(creatorBuyFeeBps_)) * 100;
        // The policy's buyer budget and recipient budget are the same number, so this reads the token's
        // rather than computing it again.
        buyerTokenLimit = token_.walletTokenLimit();
        _exemptWallets = exemptWallets_;
    }

    /// @notice The exemption list as deployed, in the order it was supplied. Zero entries are unused.
    function exemptWallets() external view returns (address[6] memory) {
        return _exemptWallets;
    }

    /// @notice Whether a wallet pays the normal fee instead of the opening fee. True for the developer
    /// and for any nonzero entry of the exemption list. It affects the opening fee only: an exempt wallet
    /// is capped by the buyer budget and by the recipient budget exactly like a stranger.
    function isTaxExempt(address wallet) public view returns (bool) {
        if (wallet == address(0)) return false;
        if (wallet == developer) return true;
        for (uint256 i; i < _exemptWallets.length; ++i) {
            if (wallet == _exemptWallets[i]) return true;
        }
        return false;
    }

    /// @notice The opening fee a buyer owes on top of the pool's normal fee, in ppm of the gross quote
    /// leg. Zero once thirty seconds have passed, and zero for an exempt wallet.
    /// @dev Linear in whole seconds, rounded down: at `startedAt` exactly `OPENING_TOTAL_PPM` in total,
    /// and exactly the normal fee from `startedAt + 30` on. The rounding is the reference's, and it is
    /// what keeps the first second at 99% rather than a ppm over it.
    function additionalTaxPpmForBuyer(address buyer) public view returns (uint24) {
        uint256 start = token.startedAt();
        if (start == 0 || block.timestamp >= start + DECAY_SECONDS || isTaxExempt(buyer)) return 0;
        return uint24(
            Math.mulDiv(OPENING_TOTAL_PPM - normalBuyFeePpm, start + DECAY_SECONDS - block.timestamp, DECAY_SECONDS)
        );
    }

    /// @notice The authenticated buyer of a swap and the opening fee that buyer owes, for the shell.
    /// @dev One call, not two: the shell needs both answers on the same swap, and every read here is a
    /// read the swap pays for. Outside the protection window there is nothing to authenticate and nothing
    /// to charge, so the answer is `(0, 0)` rather than a revert — after five minutes any sender may buy,
    /// including through contracts this pool never pinned.
    /// @param sender The swap's sender as the shell saw it: the PoolManager's caller.
    function buyerAndTaxPpm(address sender) external view returns (address buyer, uint24 taxPpm) {
        if (msg.sender != shell) revert OnlyShell();
        uint256 start = token.startedAt();
        if (start == 0 || block.timestamp >= start + PROTECTION_SECONDS) return (address(0), 0);
        buyer = _buyer(sender);
        taxPpm = additionalTaxPpmForBuyer(buyer);
    }

    /// @dev Who is buying. The initializer's own swap is the developer's initial buy: it happens inside
    /// the launch transaction, before any router is involved, and it is attributed to the developer so
    /// that it is exempt from the opening fee and still counts against the developer's budget.
    ///
    /// Anyone else must be the canonical router, by address and by code hash, and then the buyer is the
    /// router's own `msgSender()` — the account that called the router, as the reference reads it.
    function _buyer(address sender) private view returns (address buyer) {
        if (sender == token.initializer()) {
            buyer = developer;
        } else {
            if (sender != router || sender.codehash != routerCodeHash) revert UnsupportedRouter();
            buyer = IProtectionRouter(sender).msgSender();
            if (buyer == address(0) || buyer == router || buyer == shell || buyer == token.poolManager()) {
                revert InvalidBuyer();
            }
        }
    }
}
