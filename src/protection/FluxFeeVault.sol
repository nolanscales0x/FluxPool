// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title FluxFeeVault
/// @notice Custody for one protected pool's fees, as a ledger and a pull payment. One contract deployed
/// twice per protected pool: once for the normal fee (the platform's 30 bps and the creator's share) and
/// once for the opening tax, whose only recipient is the platform.
///
/// The point of a separate contract is that the fees a protected launch charges are not reachable by the
/// hook's own fee machinery: the shell can add to a ledger and nothing else, and the only ways out pay the
/// two fixed recipients. There is no owner, no setter, no pause, no operator and no arbitrary call. In
/// particular there is no destination override: `creatorRecipient` is fixed at deploy, so a later
/// "change the recipient" is not a function that exists to be called.
///
/// The ledger is backed, and the contract checks that it is. The shell mints the quotes as ERC-6909
/// claims **to this contract** and only then records them, so `recordFees` can require the PoolManager's
/// balance to cover the whole ledger and revert if it does not (`InsufficientFeeBacking`). Anything sent
/// here outside that path — a donation of claims, a stray transfer — sits above the ledger and is
/// unclaimable by design, because the claims pay out ledger amounts and no more.
///
/// Claims are permissionless. The gas is paid by whoever calls; the money always goes to the fixed
/// recipient. That is deliberate: a claim that only the creator could trigger would be a fee nobody can
/// collect if the creator disappears.
///
/// The quote currency is an immutable rather than assumed to be native: FluxPool pairs with native ETH,
/// and a WETH pool uses the same vault with `quote` set to the WETH currency. Nothing else changes.
contract FluxFeeVault is IUnlockCallback {
    /// @notice Programmable's fee recipient, the same address the shell uses. Fixed in code because a
    /// recipient that anyone could change is the thing this contract exists not to have.
    address public constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;

    /// @notice The PoolManager whose ERC-6909 claims back the ledger and whose `take` pays it out.
    IPoolManager public immutable poolManager;
    /// @notice The FluxShell allowed to record fees: one shell serves every pool, so this is the shell
    /// rather than the pool.
    address public immutable kernel;
    /// @notice The currency the ledger is denominated in: the pool's quote currency.
    Currency public immutable quote;
    /// @notice Who `claimCreator()` pays. The creator for the normal-fee vault, Programmable's recipient
    /// for the opening-tax vault.
    address public immutable creatorRecipient;

    /// @notice Platform money accrued and not yet claimed.
    uint256 public platformAccrued;
    /// @notice Creator money accrued and not yet claimed.
    uint256 public creatorAccrued;

    /// @dev Set for the duration of a claim, so a claim cannot be re-entered through the shell's or the
    /// PoolManager's callback path, and so `recordFees` cannot be used to re-credit a ledger mid-claim.
    bool private _claimActive;
    /// @dev The claim in flight, as a hash of its destination and amount. The callback only proceeds for
    /// the exact claim this contract opened.
    bytes32 private _activeClaim;

    error InvalidConfiguration();
    error UnauthorizedKernel();
    error ReentrantClaim();
    error NothingToClaim();
    error InvalidClaim();
    error InsufficientFeeBacking();

    event FeesRecorded(uint256 platformAmount, uint256 creatorAmount);
    event FeesClaimed(address indexed recipient, uint256 amount, bool platform);

    /// @param manager The PoolManager. Must be a contract.
    /// @param kernel_ The shell allowed to record. Must be a contract.
    /// @param quote_ The quote currency the ledger is denominated in.
    /// @param creatorRecipient_ Who `claimCreator()` pays. Must not be zero.
    constructor(IPoolManager manager, address kernel_, Currency quote_, address creatorRecipient_) {
        if (address(manager) == address(0) || address(manager).code.length == 0) revert InvalidConfiguration();
        if (kernel_ == address(0) || kernel_.code.length == 0) revert InvalidConfiguration();
        if (creatorRecipient_ == address(0)) revert InvalidConfiguration();
        poolManager = manager;
        kernel = kernel_;
        quote = quote_;
        creatorRecipient = creatorRecipient_;
    }

    /// @notice Records accrued fees against the two ledgers. Callable only by the shell, and only when no
    /// claim is in flight.
    /// @dev The backing check is the whole reason this is a contract and not two counters in the shell:
    /// the ledger can never exceed what the PoolManager actually holds for this contract, so a claim can
    /// never fail for want of backing and a fee can never be recorded that does not exist.
    function recordFees(uint256 platformAmount, uint256 creatorAmount) external {
        if (msg.sender != kernel) revert UnauthorizedKernel();
        if (_claimActive) revert ReentrantClaim();
        platformAccrued += platformAmount;
        creatorAccrued += creatorAmount;
        if (backing() < platformAccrued + creatorAccrued) revert InsufficientFeeBacking();
        emit FeesRecorded(platformAmount, creatorAmount);
    }

    /// @notice Pays the platform ledger to Programmable's fixed recipient. Anyone may call.
    function claimPlatform() external returns (uint256 amount) {
        amount = platformAccrued;
        _claim(PLATFORM_RECIPIENT, amount, true);
    }

    /// @notice Pays the creator ledger to this vault's fixed creator recipient. Anyone may call.
    function claimCreator() external returns (uint256 amount) {
        amount = creatorAccrued;
        _claim(creatorRecipient, amount, false);
    }

    /// @notice The ERC-6909 claims this contract holds in the quote currency: what actually backs the
    /// two ledgers. Equal to their sum in ordinary operation, and greater only if someone donated claims.
    function backing() public view returns (uint256) {
        return poolManager.balanceOf(address(this), quote.toId());
    }

    /// @dev The ledger is cleared before the payout and restored by nothing: a failed payout reverts the
    /// whole claim, so the ledger and the backing move together.
    function _claim(address recipient, uint256 amount, bool platform) private {
        if (_claimActive) revert ReentrantClaim();
        if (amount == 0) revert NothingToClaim();
        _claimActive = true;
        _activeClaim = keccak256(abi.encode(recipient, amount));
        if (platform) platformAccrued = 0;
        else creatorAccrued = 0;
        bytes memory result = poolManager.unlock(abi.encode(recipient, amount));
        if (result.length != 0 || _activeClaim != bytes32(0)) revert InvalidClaim();
        _claimActive = false;
        emit FeesClaimed(recipient, amount, platform);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (
            msg.sender != address(poolManager) || !_claimActive || _activeClaim == bytes32(0)
                || keccak256(data) != _activeClaim
        ) revert InvalidClaim();
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        _activeClaim = bytes32(0);
        poolManager.burn(address(this), quote.toId(), amount);
        poolManager.take(quote, recipient, amount);
        return "";
    }
}
