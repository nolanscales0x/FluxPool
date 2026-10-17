// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {FluxFeeVault} from "../../src/protection/FluxFeeVault.sol";
import {FluxTestBase} from "../utils/FluxTestBase.sol";

/// @dev Mints ERC-6909 claims to an address through the only path the PoolManager allows: inside its own
/// unlock, and paid for in the same unlock so the currency settles to zero. It is the same call the shell
/// makes during a swap, where the swap's own delta pays for the claims it mints.
contract ClaimMinter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager internal immutable manager;
    address internal to;
    Currency internal currency;
    uint256 internal amount;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @dev The caller funds this contract first: ETH for a native quote, the token for WETH.
    function mint(address to_, Currency currency_, uint256 amount_) external {
        to = to_;
        currency = currency_;
        amount = amount_;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only the manager");
        manager.mint(to, currency.toId(), amount);
        manager.sync(currency);
        if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            IERC20(Currency.unwrap(currency)).transfer(address(manager), amount);
            manager.settle();
        }
        return "";
    }
}

/// @dev A recipient that tries, while it is being paid, to be paid again and to have new fees recorded.
/// Both attempts have to fail: the first because a claim is in flight, the second for the same reason.
contract ReentrantRecipient {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    FluxFeeVault internal vault;
    address internal kernel;
    bool public claimAttempted;
    bool public recordAttempted;

    function arm(FluxFeeVault vault_, address kernel_) external {
        vault = vault_;
        kernel = kernel_;
    }

    receive() external payable {
        if (!claimAttempted) {
            claimAttempted = true;
            try vault.claimCreator() {} catch {}
        }
        if (!recordAttempted) {
            recordAttempted = true;
            VM.prank(kernel);
            try vault.recordFees(1, 1) {} catch {}
        }
    }
}

/// @notice Fee custody for a protected pool: a ledger that only the shell can add to, a payout that only
/// ever reaches the two fixed recipients, and a backing check that ties the ledger to the claims the
/// PoolManager actually holds.
///
/// The concrete suites run this with native ETH (as on Ethereum) and with WETH on each side of the
/// token: the vault treats the quote as an immutable, so the same contract serves both.
abstract contract FeeVaultTestBase is FluxTestBase {
    address internal anyone = makeAddr("anyone");
    address internal platform;

    /// @dev The normal-fee vault: the creator is its creator recipient.
    FluxFeeVault internal vault;
    /// @dev The opening-tax vault: everything it holds is platform money.
    FluxFeeVault internal taxVault;
    ClaimMinter internal minter;

    function setUp() public virtual override {
        super.setUp();
        platform = shell.PLATFORM_RECIPIENT();
        vault = new FluxFeeVault(manager, address(shell), quote, creator);
        taxVault = new FluxFeeVault(manager, address(shell), quote, platform);
        minter = new ClaimMinter(manager);
    }

    /// @dev The shell records fees. The shell's own swap path does this; here it is called as the shell.
    function _record(uint256 platformAmount, uint256 creatorAmount) internal {
        vm.prank(address(shell));
        vault.recordFees(platformAmount, creatorAmount);
    }

    /// @dev Gives the vault claims, paid for out of the minter's balance, so a claim is a real transfer
    /// out of the real PoolManager against real reserves.
    function _back(uint256 amount) internal {
        _backTo(address(vault), amount);
    }

    /// @dev `_back` for an arbitrary vault, so the reentrancy test can back its own.
    function _backTo(address vaultAddress, uint256 amount) internal {
        if (_nativeQuote()) vm.deal(address(minter), address(minter).balance + amount);
        else weth.transfer(address(minter), amount);
        minter.mint(vaultAddress, quote, amount);
    }

    function _sum() internal view returns (uint256) {
        return vault.platformAccrued() + vault.creatorAccrued();
    }

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    function test_constructor_refusesAnUnusableVault() public {
        vm.expectRevert(FluxFeeVault.InvalidConfiguration.selector);
        new FluxFeeVault(IPoolManager(address(0)), address(shell), quote, creator);

        vm.expectRevert(FluxFeeVault.InvalidConfiguration.selector);
        new FluxFeeVault(IPoolManager(anyone), address(shell), quote, creator);

        vm.expectRevert(FluxFeeVault.InvalidConfiguration.selector);
        new FluxFeeVault(manager, address(0), quote, creator);

        vm.expectRevert(FluxFeeVault.InvalidConfiguration.selector);
        new FluxFeeVault(manager, anyone, quote, creator);

        vm.expectRevert(FluxFeeVault.InvalidConfiguration.selector);
        new FluxFeeVault(manager, address(shell), quote, address(0));
    }

    function test_thePlatformRecipientIsTheShellsOwn() public view {
        // The treasury address is not a parameter anywhere: both contracts carry the same constant, and
        // this is the check that says so.
        assertEq(vault.PLATFORM_RECIPIENT(), platform, "the vault and the shell agree");
        assertEq(taxVault.creatorRecipient(), platform, "the opening tax is platform money");
        assertEq(vault.creatorRecipient(), creator, "the normal-fee vault pays the creator");
        assertEq(vault.kernel(), address(shell), "the shell records");
        assertEq(address(vault.poolManager()), address(manager), "the manager backs");
        assertEq(Currency.unwrap(vault.quote()), Currency.unwrap(quote), "the quote is the pool's");
    }

    // ------------------------------------------------------------------
    // The ledger
    // ------------------------------------------------------------------

    function test_onlyTheShellRecords() public {
        _back(1 ether);
        vm.expectRevert(FluxFeeVault.UnauthorizedKernel.selector);
        vault.recordFees(1, 1);
    }

    function test_theLedgerIsBackedByTheClaimsHeld() public {
        _back(1 ether);
        _record(0.003 ether, 0.002 ether);
        assertEq(vault.platformAccrued(), 0.003 ether, "platform ledger");
        assertEq(vault.creatorAccrued(), 0.002 ether, "creator ledger");
        assertEq(manager.balanceOf(address(vault), quote.toId()), 1 ether, "claims are the quote's claims");
        assertGe(vault.backing(), _sum(), "the ledger is covered");
    }

    function test_recordWithoutBackingReverts() public {
        // Nothing has been minted to the vault, so there is nothing that could pay the ledger out.
        vm.prank(address(shell));
        vm.expectRevert(FluxFeeVault.InsufficientFeeBacking.selector);
        vault.recordFees(1 ether, 0);
        assertEq(vault.platformAccrued(), 0, "the failed record left no ledger behind");
    }

    function test_theTwoLedgersAreIndependent() public {
        _back(1 ether);
        _record(0.003 ether, 0.002 ether);
        vm.prank(anyone);
        uint256 paid = vault.claimPlatform();
        assertEq(paid, 0.003 ether, "the platform ledger was paid");
        assertEq(vault.platformAccrued(), 0, "and cleared");
        assertEq(vault.creatorAccrued(), 0.002 ether, "the creator ledger was not touched");
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    function test_anyoneCanClaimAndOnlyTheCreatorIsPaid() public {
        _back(1 ether);
        _record(0.003 ether, 0.002 ether);
        uint256 before = _quoteBalance(creator);

        vm.prank(anyone);
        uint256 paid = vault.claimCreator();

        assertEq(paid, 0.002 ether, "the creator ledger");
        assertEq(_quoteBalance(creator) - before, 0.002 ether, "and it arrived");
        assertEq(vault.creatorAccrued(), 0, "the ledger cleared before the payout");
        vm.expectRevert(FluxFeeVault.NothingToClaim.selector);
        vault.claimCreator();
    }

    function test_anyoneCanClaimAndOnlyThePlatformIsPaid() public {
        _back(1 ether);
        _record(0.003 ether, 0.002 ether);
        uint256 before = _quoteBalance(platform);

        vm.prank(anyone);
        uint256 paid = vault.claimPlatform();

        assertEq(paid, 0.003 ether, "the platform ledger");
        assertEq(_quoteBalance(platform) - before, 0.003 ether, "and it arrived");
        assertEq(vault.platformAccrued(), 0, "cleared");
    }

    function test_theOpeningTaxVaultPaysThePlatformFromBothPaths() public {
        // "Booked entirely as platform money": whichever claim is called, the money reaches the same
        // fixed address, and the creator is not a party to it.
        _backTo(address(taxVault), 1 ether);
        vm.prank(address(shell));
        taxVault.recordFees(0.5 ether, 0.25 ether);
        assertEq(taxVault.creatorRecipient(), platform, "the creator recipient is the platform");

        uint256 before = _quoteBalance(platform);
        vm.prank(anyone);
        taxVault.claimPlatform();
        vm.prank(anyone);
        taxVault.claimCreator();
        assertEq(_quoteBalance(platform) - before, 0.75 ether, "all of it reached the platform");
        assertEq(_quoteBalance(creator), 0, "the creator is not paid by this vault");
    }

    function test_aDonationAboveTheLedgerIsUnclaimable() public {
        _back(2 ether);
        _record(0.003 ether, 0.002 ether);
        vm.prank(anyone);
        vault.claimPlatform();
        vm.prank(anyone);
        vault.claimCreator();
        // 2 ether of claims were sent to the vault; 0.005 ether was ever recorded against them. The rest
        // sits there and cannot be claimed, because claims pay ledger amounts and nothing else.
        assertEq(vault.backing(), 2 ether - 0.005 ether, "the excess is still held");
        assertEq(_sum(), 0, "with nothing owed");
        vm.expectRevert(FluxFeeVault.NothingToClaim.selector);
        vault.claimCreator();
        vm.expectRevert(FluxFeeVault.NothingToClaim.selector);
        vault.claimPlatform();
    }

    function test_nothingToClaimOnAnEmptyVault() public {
        vm.expectRevert(FluxFeeVault.NothingToClaim.selector);
        vault.claimCreator();
        vm.expectRevert(FluxFeeVault.NothingToClaim.selector);
        vault.claimPlatform();
    }

    // ------------------------------------------------------------------
    // The callback cannot be driven from outside
    // ------------------------------------------------------------------

    function test_theCallbackOnlyAnswersTheManager() public {
        vm.expectRevert(FluxFeeVault.InvalidClaim.selector);
        vault.unlockCallback(abi.encode(creator, 1));

        // Even from the manager, without a claim in flight, there is nothing to answer.
        vm.prank(address(manager));
        vm.expectRevert(FluxFeeVault.InvalidClaim.selector);
        vault.unlockCallback(abi.encode(creator, 1));
    }

    function test_aClaimCannotBeReenteredAndNoFeeCanBeRecordedMidClaim() public {
        // Reentrancy has to come through the recipient, and only a native payout calls it: an ERC-20
        // payout is a transfer with nobody on the other end. So this is a native-quote test, and the
        // WETH runs of the suite are covered by every other test here.
        if (!_nativeQuote()) return;

        ReentrantRecipient greedy = new ReentrantRecipient();
        FluxFeeVault reentrantSafe = new FluxFeeVault(manager, address(shell), quote, address(greedy));
        greedy.arm(reentrantSafe, address(shell));

        // Back it and give it a ledger to pay.
        _backTo(address(reentrantSafe), 1 ether);
        vm.prank(address(shell));
        reentrantSafe.recordFees(0, 0.25 ether);

        assertEq(greedy.claimAttempted(), false, "not yet armed");
        reentrantSafe.claimCreator();
        assertTrue(greedy.claimAttempted(), "the recipient tried to be paid again");
        assertTrue(greedy.recordAttempted(), "and tried to have fees recorded while being paid");
        assertEq(address(greedy).balance, 0.25 ether, "paid exactly once");
        assertEq(reentrantSafe.creatorAccrued(), 0, "and the ledger is clear");
    }
}

/// @dev Native ETH quote, as on Ethereum (token = currency1).
contract FeeVaultTest is FeeVaultTestBase {}

/// @dev WETH quote, the token sorting below it (token = currency0).
contract FeeVaultTokenFirstTest is FeeVaultTestBase {
    function _tokenFirst() internal pure override returns (bool) {
        return true;
    }
}

/// @dev WETH quote, the token sorting above it (token = currency1).
contract FeeVaultWethTest is FeeVaultTestBase {
    function _wethQuote() internal pure override returns (bool) {
        return true;
    }
}
