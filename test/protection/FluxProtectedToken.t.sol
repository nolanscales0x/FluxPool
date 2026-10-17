// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FluxProtectedToken} from "../../src/protection/FluxProtectedToken.sol";

/// @dev Something with runtime code, so the token's "the manager must be a contract" check passes.
contract Manager {
    uint256 public pools;
}

contract FluxProtectedTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant MAX_SUPPLY = uint256(int256(type(int128).max));

    address internal initializer = makeAddr("initializer");
    address internal manager;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    FluxProtectedToken internal token;

    function setUp() public {
        manager = address(new Manager());
        token = new FluxProtectedToken("Flux", "FLUX", SUPPLY, initializer, manager);
    }

    function _start() internal {
        vm.prank(initializer);
        token.start();
    }

    /// @dev The seed: before trading opens this is the only movement the token permits.
    function _seed() internal {
        vm.prank(initializer);
        token.transfer(manager, token.walletTokenLimit());
    }

    function _give(address to, uint256 amount) internal {
        _start();
        vm.prank(initializer);
        token.transfer(to, amount);
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    function test_mintsTheWholeSupplyToTheInitializer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(initializer), SUPPLY);
        assertEq(token.launchSupply(), SUPPLY);
    }

    function test_isAnEighteenDecimalTokenWithNoOtherSupplyPath() public view {
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Flux");
        assertEq(token.symbol(), "FLUX");
        assertEq(token.initializer(), initializer);
        assertEq(token.poolManager(), manager);
    }

    function test_walletLimitIsTwoPercentRoundedDown() public view {
        assertEq(token.walletTokenLimit(), SUPPLY * 200 / 10_000);
    }

    function test_revertsOnEmptyNameOrSymbol() public {
        vm.expectRevert(FluxProtectedToken.InvalidConfiguration.selector);
        new FluxProtectedToken("", "FLUX", SUPPLY, initializer, manager);
        vm.expectRevert(FluxProtectedToken.InvalidConfiguration.selector);
        new FluxProtectedToken("Flux", "", SUPPLY, initializer, manager);
    }

    function test_revertsOnASupplyOutsideTheBounds() public {
        // Below the floor the 2% budget would round to zero and the token could never move.
        vm.expectRevert(FluxProtectedToken.InvalidConfiguration.selector);
        new FluxProtectedToken("Flux", "FLUX", 49, initializer, manager);
        vm.expectRevert(FluxProtectedToken.InvalidConfiguration.selector);
        new FluxProtectedToken("Flux", "FLUX", MAX_SUPPLY + 1, initializer, manager);
    }

    function test_revertsOnAConfigurationTheBudgetCannotRelyOn() public {
        vm.expectRevert(FluxProtectedToken.InvalidConfiguration.selector);
        new FluxProtectedToken("Flux", "FLUX", SUPPLY, address(0), manager);

        // A manager that is not a contract cannot be the pool the seed settles against.
        vm.expectRevert(FluxProtectedToken.InvalidConfiguration.selector);
        new FluxProtectedToken("Flux", "FLUX", SUPPLY, initializer, makeAddr("notAContract"));

        // The initializer paying itself would make the seed and the pool indistinguishable.
        vm.expectRevert(FluxProtectedToken.InvalidConfiguration.selector);
        new FluxProtectedToken("Flux", "FLUX", SUPPLY, manager, manager);
    }

    function testFuzz_limitIsAlwaysTwoPercentAndNeverZero(uint256 supply) public {
        supply = bound(supply, 50, MAX_SUPPLY);
        FluxProtectedToken t = new FluxProtectedToken("Flux", "FLUX", supply, initializer, manager);
        assertEq(t.walletTokenLimit(), supply * 200 / 10_000);
        assertGt(t.walletTokenLimit(), 0);
        assertLe(t.walletTokenLimit(), supply);
    }

    // ---------------------------------------------------------------------
    // Before trading opens
    // ---------------------------------------------------------------------

    function test_beforeStartTheOnlyMovementIsTheSeed() public {
        vm.prank(initializer);
        token.transfer(manager, 1_000e18); // the seed: allowed

        // Any other destination, and any other sender, is refused rather than capped.
        vm.prank(initializer);
        vm.expectRevert(FluxProtectedToken.TradingNotStarted.selector);
        token.transfer(alice, 1);

        vm.prank(alice);
        vm.expectRevert(FluxProtectedToken.TradingNotStarted.selector);
        token.transfer(manager, 1);
    }

    function test_beforeStartNothingIsCounted() public view {
        assertEq(token.receivedDuringProtection(alice), 0);
        assertEq(token.startedAt(), 0);
        assertEq(token.protectionEndsAt(), 0);
    }

    function test_startIsTheInitializersAndHappensOnce() public {
        vm.prank(alice);
        vm.expectRevert(FluxProtectedToken.NotInitializer.selector);
        token.start();

        vm.expectEmit(false, false, false, true);
        emit FluxProtectedToken.ProtectionStarted(uint64(block.timestamp), uint64(block.timestamp + 300));
        _start();

        assertEq(token.startedAt(), block.timestamp);
        assertEq(token.protectionEndsAt(), block.timestamp + 300);

        vm.prank(initializer);
        vm.expectRevert(FluxProtectedToken.AlreadyStarted.selector);
        token.start();
    }

    // ---------------------------------------------------------------------
    // The recipient budget
    // ---------------------------------------------------------------------

    function test_aRecipientMayTakeExactlyTheLimit() public {
        _give(alice, token.walletTokenLimit());
        assertEq(token.balanceOf(alice), token.walletTokenLimit());
        assertEq(token.receivedDuringProtection(alice), token.walletTokenLimit());
    }

    function test_oneUnitOverTheLimitReverts() public {
        uint256 limit = token.walletTokenLimit();
        _give(alice, limit);
        vm.prank(initializer);
        vm.expectRevert(
            abi.encodeWithSelector(FluxProtectedToken.WalletLimitExceeded.selector, alice, limit + 1, limit)
        );
        token.transfer(alice, 1);
    }

    function test_theBudgetIsCumulativeAcrossTransfers() public {
        uint256 limit = token.walletTokenLimit();
        _give(alice, limit / 3);
        vm.prank(initializer);
        token.transfer(alice, limit / 3);
        vm.prank(initializer);
        token.transfer(alice, limit - 2 * (limit / 3)); // tops it up to exactly the limit
        assertEq(token.receivedDuringProtection(alice), limit);

        vm.prank(initializer);
        vm.expectRevert(
            abi.encodeWithSelector(FluxProtectedToken.WalletLimitExceeded.selector, alice, limit + 1, limit)
        );
        token.transfer(alice, 1);
    }

    function test_theBudgetIsPerRecipientNotPerSender() public {
        uint256 limit = token.walletTokenLimit();
        _give(alice, limit);
        vm.prank(initializer);
        token.transfer(bob, limit);
        assertEq(token.receivedDuringProtection(alice), limit);
        assertEq(token.receivedDuringProtection(bob), limit);
    }

    function test_aSelfTransferIsNeitherCountedNorBlocked() public {
        uint256 limit = token.walletTokenLimit();
        _give(alice, limit);
        vm.prank(alice);
        token.transfer(alice, limit);
        assertEq(token.receivedDuringProtection(alice), limit);
    }

    /// A sell is a transfer to the PoolManager, and sells are never blocked by any cap.
    function test_transfersToThePoolManagerAreUncounted() public {
        uint256 limit = token.walletTokenLimit();
        _give(alice, limit);

        vm.prank(alice);
        token.transfer(manager, limit);
        assertEq(token.balanceOf(manager), limit);
        assertEq(token.receivedDuringProtection(manager), 0);

        // And a wallet already at its limit can still sell.
        vm.prank(initializer);
        token.transfer(bob, limit);
        vm.prank(bob);
        token.transfer(manager, limit);
        assertEq(token.receivedDuringProtection(manager), 0);
    }

    function test_transferringOutDoesNotRestoreTheBudget() public {
        uint256 limit = token.walletTokenLimit();
        _give(alice, limit);
        vm.prank(alice);
        token.transfer(manager, limit);

        // Empty again, but the window's total is what counts, not the balance.
        vm.prank(initializer);
        vm.expectRevert(
            abi.encodeWithSelector(FluxProtectedToken.WalletLimitExceeded.selector, alice, limit + 1, limit)
        );
        token.transfer(alice, 1);
    }

    function test_burningIsNotBudgeted() public {
        uint256 limit = token.walletTokenLimit();
        _give(alice, limit);
        vm.prank(alice);
        token.burn(limit);
        assertEq(token.balanceOf(alice), 0);
        // The limit itself is a share of the launch supply, so burning cannot lower it.
        assertEq(token.walletTokenLimit(), SUPPLY * 200 / 10_000);

        vm.prank(initializer);
        vm.expectRevert(
            abi.encodeWithSelector(FluxProtectedToken.WalletLimitExceeded.selector, alice, limit + 1, limit)
        );
        token.transfer(alice, 1);
    }

    function test_theBudgetLastsExactlyThreeHundredSeconds() public {
        _start();
        uint256 limit = token.walletTokenLimit();
        uint64 started = token.startedAt();

        // One second before the window closes the cap still bites.
        vm.warp(uint256(started) + 299);
        vm.prank(initializer);
        token.transfer(alice, limit);
        vm.prank(initializer);
        vm.expectRevert(
            abi.encodeWithSelector(FluxProtectedToken.WalletLimitExceeded.selector, alice, limit + 1, limit)
        );
        token.transfer(alice, 1);

        // At startedAt + 300 it is gone entirely.
        vm.warp(uint256(started) + 300);
        vm.prank(initializer);
        token.transfer(alice, SUPPLY - limit); // no cap at all, any amount
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.receivedDuringProtection(alice), limit); // and nothing further was recorded
    }

    function testFuzz_theCapIsEnforcedForAnyAmount(uint256 amount) public {
        uint256 limit = token.walletTokenLimit();
        _start();
        amount = bound(amount, 1, SUPPLY);

        if (amount > limit) {
            vm.prank(initializer);
            vm.expectRevert(
                abi.encodeWithSelector(FluxProtectedToken.WalletLimitExceeded.selector, alice, amount, limit)
            );
            token.transfer(alice, amount);
        } else {
            vm.prank(initializer);
            token.transfer(alice, amount);
            assertEq(token.receivedDuringProtection(alice), amount);
            assertLe(token.receivedDuringProtection(alice), limit);
        }
    }

    function testFuzz_onlyBurnsAndMintsBypassTheBudget(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != manager && to != initializer);
        uint256 limit = token.walletTokenLimit();
        amount = bound(amount, 1, SUPPLY);
        _start();

        vm.prank(initializer);
        if (amount > limit) {
            vm.expectRevert(abi.encodeWithSelector(FluxProtectedToken.WalletLimitExceeded.selector, to, amount, limit));
        }
        token.transfer(to, amount);
        assertLe(token.receivedDuringProtection(to), limit);
    }
}
