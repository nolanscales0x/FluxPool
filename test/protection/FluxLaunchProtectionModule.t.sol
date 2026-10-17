// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FluxLaunchProtectionModule} from "../../src/protection/FluxLaunchProtectionModule.sol";
import {FluxProtectedToken} from "../../src/protection/FluxProtectedToken.sol";

/// @dev Something with runtime code. The shell, the PoolManager and the router all have to be contracts,
/// and the router's code hash is part of the configuration.
contract Widget {
    uint256 public value;
}

/// @dev Stands in for Uniswap's Universal Router: reports the account that called it as `msgSender()`.
contract MockUniversalRouter {
    address public msgSender;

    function setMsgSender(address who) external {
        msgSender = who;
    }
}

contract FluxLaunchProtectionModuleTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint16 internal constant CREATOR_FEE_BPS = 250;
    /// @dev (30 + 250) * 100.
    uint256 internal constant NORMAL_PPM = 28_000;
    /// @dev A fixed, non-zero timestamp so `startedAt` is never 0 by accident.
    uint256 internal constant T0 = 1_700_000_000;

    address internal shell;
    address internal manager;
    address internal router;
    bytes32 internal mockRouterHash;
    address internal initializer;
    FluxProtectedToken internal token;
    FluxLaunchProtectionModule internal module;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal exempt1 = makeAddr("exempt1");
    address internal exempt2 = makeAddr("exempt2");

    function setUp() public {
        // The policy supports chains 1 and 4663, and the constructor refuses anything else, so a test
        // that does not say which chain it is on cannot even deploy the module.
        vm.chainId(1);
        vm.warp(T0);
        shell = address(new Widget());
        manager = address(new Widget());
        // The policy fixes the router: the canonical Universal Router for the chain. A mock that reports
        // `msgSender()` is placed at that exact address.
        router = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
        vm.etch(router, address(new MockUniversalRouter()).code);
        mockRouterHash = router.codehash;
        initializer = makeAddr("initializer");
        token = new FluxProtectedToken("Flux", "FLUX", SUPPLY, initializer, manager);
        module = _deploy(
            address(token),
            initializer,
            router,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _six(address a, address b, address c, address d, address e, address f)
        internal
        pure
        returns (address[6] memory list)
    {
        list[0] = a;
        list[1] = b;
        list[2] = c;
        list[3] = d;
        list[4] = e;
        list[5] = f;
    }

    function _deploy(address token_, address developer_, address router_, uint16 feeBps_, address[6] memory exempts_)
        internal
        returns (FluxLaunchProtectionModule)
    {
        return new FluxLaunchProtectionModule(
            shell, FluxProtectedToken(token_), developer_, router_, router_.codehash, feeBps_, exempts_
        );
    }

    /// @dev Opens trading. The token's clock is the schedule's clock.
    function _start() internal returns (uint256 start) {
        start = block.timestamp;
        vm.prank(initializer);
        token.start();
    }

    /// @dev The shell asks the module a question. `who` is the account the router reports as its caller
    /// (`msgSender()`); it is set on the router before the shell asks.
    function _ask(address sender, bytes memory who) internal returns (address buyer, uint24 taxPpm) {
        if (sender == router && router.codehash == mockRouterHash && who.length == 32) {
            MockUniversalRouter(router).setMsgSender(abi.decode(who, (address)));
        }
        vm.prank(shell);
        return module.buyerAndTaxPpm(sender);
    }

    /// @dev The formula the schedule is supposed to be, written independently of the contract's code.
    function _expectedExtra(uint256 start, uint256 at, uint256 normalPpm) internal pure returns (uint256) {
        if (start == 0 || at >= start + 30) return 0;
        return (990_000 - normalPpm) * (start + 30 - at) / 30;
    }

    // ---------------------------------------------------------------------------------------------
    // The policy's numbers
    // ---------------------------------------------------------------------------------------------

    function test_policyNumbersAreThePolicy() public view {
        assertEq(module.OPENING_TOTAL_PPM(), 990_000, "opening total");
        assertEq(module.DECAY_SECONDS(), 30, "decay");
        assertEq(module.BUYER_LIMIT_BPS(), 200, "buyer limit");
        assertEq(module.PROTECTION_SECONDS(), 300, "protection window");
        assertEq(module.POLICY_REVISION(), 1, "revision");
    }

    function test_normalBuyFeeIncludesThePlatformShare() public view {
        assertEq(module.normalBuyFeePpm(), NORMAL_PPM, "normal = (30 + 250) * 100");
        assertEq(module.developer(), initializer, "developer round-trips");
        assertEq(address(module.token()), address(token), "token round-trips");
        assertEq(module.router(), router, "router round-trips");
        assertEq(module.routerCodeHash(), router.codehash, "code hash round-trips");
        assertEq(module.shell(), shell, "shell round-trips");
    }

    function test_buyerLimitIsTheTokensOwnRecipientLimit() public view {
        // The policy's two budgets are the same number. Reading the token's makes that a construction,
        // not two calculations that happen to agree today.
        assertEq(module.buyerTokenLimit(), token.walletTokenLimit(), "buyer limit = recipient limit");
        assertEq(module.buyerTokenLimit(), SUPPLY * 200 / 10_000, "2% of the launch supply");
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    function test_constructor_refusesAnyChainButOneAnd4663() public {
        vm.chainId(31337);
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        _deploy(
            address(token),
            initializer,
            router,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );

        vm.chainId(4663);
        FluxLaunchProtectionModule other = _deploy(
            address(token),
            initializer,
            router,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );
        assertEq(other.developer(), initializer, "chain 4663 is supported");
    }

    function test_constructor_refusesBadAddresses() public {
        // A shell with no code is not a shell.
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        new FluxLaunchProtectionModule(
            stranger,
            token,
            initializer,
            router,
            router.codehash,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );

        // A token with no code is not a token.
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        new FluxLaunchProtectionModule(
            shell,
            FluxProtectedToken(stranger),
            initializer,
            router,
            router.codehash,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );

        // No developer.
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        _deploy(
            address(token),
            address(0),
            router,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );

        // The developer cannot be the shell, the token or the manager.
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        _deploy(
            address(token),
            shell,
            router,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );

        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        _deploy(
            address(token),
            address(token),
            router,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );

        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        _deploy(
            address(token),
            manager,
            router,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );
    }

    function test_constructor_refusesUnpinnedRouter() public {
        // No code hash is not a pin.
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        new FluxLaunchProtectionModule(
            shell,
            token,
            initializer,
            router,
            bytes32(0),
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );

        // A router that is not a contract.
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        new FluxLaunchProtectionModule(
            shell,
            token,
            initializer,
            stranger,
            stranger.codehash,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );

        // A code hash that does not belong to the address.
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        new FluxLaunchProtectionModule(
            shell,
            token,
            initializer,
            router,
            keccak256("not the router"),
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );
    }

    function test_constructor_capsTheCreatorFee() public {
        // 1000 bps is the ceiling and is accepted; it is also what keeps the opening subtraction from
        // underflowing.
        FluxLaunchProtectionModule atCeiling = _deploy(
            address(token),
            initializer,
            router,
            1_000,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );
        assertEq(atCeiling.normalBuyFeePpm(), 103_000, "1000 bps + 30 bps platform");

        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        _deploy(
            address(token),
            initializer,
            router,
            1_001,
            _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
        );
    }

    function test_constructor_refusesAnExemptEntryThatIsPoolMachinery() public {
        address[6] memory cases = [initializer, shell, address(token), manager, router, address(0)];
        for (uint256 i; i < 5; ++i) {
            address[6] memory list;
            list[0] = cases[i];
            vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
            _deploy(address(token), alice, router, CREATOR_FEE_BPS, list);
        }
    }

    function test_constructor_refusesDuplicateExemptEntries() public {
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        _deploy(
            address(token),
            alice,
            router,
            CREATOR_FEE_BPS,
            _six(exempt1, exempt2, exempt1, address(0), address(0), address(0))
        );
    }

    function test_constructor_acceptsSixExemptWalletsAndZeroSlots() public {
        address[6] memory six =
            _six(makeAddr("e0"), makeAddr("e1"), makeAddr("e2"), makeAddr("e3"), makeAddr("e4"), makeAddr("e5"));
        FluxLaunchProtectionModule full = _deploy(address(token), alice, router, CREATOR_FEE_BPS, six);
        address[6] memory read = full.exemptWallets();
        for (uint256 i; i < 6; ++i) {
            assertEq(read[i], six[i], "exempt list round-trips");
            assertTrue(full.isTaxExempt(read[i]), "every entry is exempt");
        }

        // Zero slots are unused, not "address zero is exempt".
        FluxLaunchProtectionModule someSlots = _deploy(
            address(token),
            alice,
            router,
            CREATOR_FEE_BPS,
            _six(exempt1, address(0), address(0), address(0), address(0), address(0))
        );
        assertTrue(someSlots.isTaxExempt(exempt1), "the one entry is exempt");
        assertFalse(someSlots.isTaxExempt(address(0)), "zero is not a wallet");
    }

    // ---------------------------------------------------------------------------------------------
    // The schedule
    // ---------------------------------------------------------------------------------------------

    function test_schedule_isZeroBeforeTradingStarts() public view {
        assertEq(token.startedAt(), 0, "not started");
        assertEq(module.additionalTaxPpmForBuyer(stranger), 0, "no clock, no opening fee");
    }

    function test_schedule_runsFromNinetyNinePercentDownToNormal() public {
        uint16[3] memory rates = [uint16(0), uint16(250), uint16(1_000)];
        for (uint256 r; r < rates.length; ++r) {
            vm.warp(T0);
            FluxProtectedToken fresh = new FluxProtectedToken("Flux", "FLUX", SUPPLY, initializer, manager);
            FluxLaunchProtectionModule m = _deploy(
                address(fresh),
                initializer,
                router,
                rates[r],
                _six(exempt1, exempt2, address(0), address(0), address(0), address(0))
            );
            vm.prank(initializer);
            fresh.start();
            uint256 start = block.timestamp;
            uint256 normal = (30 + uint256(rates[r])) * 100;

            uint256 previous = type(uint256).max;
            for (uint256 t; t <= 30; ++t) {
                vm.warp(start + t);
                uint256 got = m.additionalTaxPpmForBuyer(stranger);
                assertEq(got, _expectedExtra(start, start + t, normal), "every second matches the schedule");
                assertLe(got + normal, 990_000, "the total never exceeds the opening total");
                if (t == 0) {
                    assertEq(got + normal, 990_000, "the first second is exactly 99% in total");
                }
                if (t == 30) {
                    assertEq(got, 0, "the thirtieth second is the normal fee alone");
                }
                assertLt(got, previous, "the opening fee only ever falls");
                previous = got;
            }
        }
    }

    function test_schedule_isFlatAfterThirtySeconds() public {
        uint256 start = _start();
        vm.warp(start + 30);
        assertEq(module.additionalTaxPpmForBuyer(stranger), 0, "at 30 s");
        vm.warp(start + 31);
        assertEq(module.additionalTaxPpmForBuyer(stranger), 0, "at 31 s");
        vm.warp(start + 300);
        assertEq(module.additionalTaxPpmForBuyer(stranger), 0, "at the end of the protection");
        vm.warp(start + 10_000);
        assertEq(module.additionalTaxPpmForBuyer(stranger), 0, "long after");
    }

    function test_schedule_roundsDownBetweenTheEndpoints() public {
        uint256 start = _start();
        // One second in, the extra is 29/30 of the opening premium and not a ppm more.
        vm.warp(start + 1);
        uint256 premium = 990_000 - NORMAL_PPM;
        assertEq(module.additionalTaxPpmForBuyer(stranger), premium * 29 / 30, "rounded down");
        assertEq(
            module.additionalTaxPpmForBuyer(stranger) + NORMAL_PPM,
            premium * 29 / 30 + NORMAL_PPM,
            "the total is the extra plus the normal fee"
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Exemptions
    // ---------------------------------------------------------------------------------------------

    function test_exemptions_payTheNormalFeeOnly() public {
        uint256 start = _start();
        vm.warp(start); // the first second, where the opening fee is at its highest

        assertGt(module.additionalTaxPpmForBuyer(stranger), 0, "a stranger pays the opening fee");
        assertEq(module.additionalTaxPpmForBuyer(initializer), 0, "the developer is exempt");
        assertEq(module.additionalTaxPpmForBuyer(exempt1), 0, "the first exempt wallet");
        assertEq(module.additionalTaxPpmForBuyer(exempt2), 0, "the second exempt wallet");

        assertTrue(module.isTaxExempt(initializer), "developer exempt");
        assertTrue(module.isTaxExempt(exempt1), "wallet exempt");
        assertFalse(module.isTaxExempt(stranger), "stranger not exempt");
        assertFalse(module.isTaxExempt(alice), "another wallet not exempt");
        assertFalse(module.isTaxExempt(address(0)), "zero is not exempt");
    }

    function test_exemptionDoesNotMoveTheBuyerBudget() public view {
        // The exemption list is about the opening fee. The budgets do not consult it anywhere — the token
        // has no exemptions at all, and the shell's buyer budget has none either — so the only thing to
        // assert here is that the module does not pretend otherwise.
        assertEq(module.buyerTokenLimit(), token.walletTokenLimit(), "one limit for everyone");
        assertTrue(module.isTaxExempt(initializer), "exempt from the fee");
    }

    // ---------------------------------------------------------------------------------------------
    // Buyer authentication
    // ---------------------------------------------------------------------------------------------

    function test_buyer_onlyTheShellMayAsk() public {
        uint256 start = _start();
        vm.warp(start);
        vm.expectRevert(FluxLaunchProtectionModule.OnlyShell.selector);
        module.buyerAndTaxPpm(router);
    }

    function test_buyer_thePinnedRouterIdentifiesTheTrader() public {
        uint256 start = _start();
        vm.warp(start);

        (address buyer, uint24 taxPpm) = _ask(router, abi.encode(alice));
        assertEq(buyer, alice, "the trader from the router's own report");
        assertEq(taxPpm, module.additionalTaxPpmForBuyer(alice), "with the tax that buyer owes");
        assertGt(taxPpm, 0, "a stranger pays the opening fee");
    }

    function test_buyer_theDeveloperIsExemptThroughTheRouterToo() public {
        uint256 start = _start();
        vm.warp(start);
        (address buyer, uint24 taxPpm) = _ask(router, abi.encode(initializer));
        assertEq(buyer, initializer, "the developer is still the buyer");
        assertEq(taxPpm, 0, "and pays no opening fee");
    }

    function test_buyer_aSenderThatIsNotTheRouterIsRefused() public {
        uint256 start = _start();
        vm.warp(start);

        vm.expectRevert(FluxLaunchProtectionModule.UnsupportedRouter.selector);
        _ask(stranger, abi.encode(alice));

        // Even the shell's own address, or a contract that looks like a router, is not the pinned one.
        // (The look-alike is deployed before the expectation, or its CREATE would consume it.)
        address lookAlike = address(new MockUniversalRouter());
        assertEq(lookAlike.codehash, router.codehash, "identical code");
        vm.expectRevert(FluxLaunchProtectionModule.UnsupportedRouter.selector);
        _ask(lookAlike, abi.encode(alice));

        vm.expectRevert(FluxLaunchProtectionModule.UnsupportedRouter.selector);
        _ask(shell, abi.encode(alice));
    }

    function test_buyer_sameAddressDifferentCodeIsRefused() public {
        uint256 start = _start();
        vm.warp(start);
        // The pin is a pair. Changing the code at the pinned address changes the hash, and the swap is
        // refused rather than authenticated against whatever now lives there.
        vm.etch(router, hex"60006000");
        assertTrue(router.codehash != module.routerCodeHash(), "the code changed");
        vm.expectRevert(FluxLaunchProtectionModule.UnsupportedRouter.selector);
        _ask(router, abi.encode(alice));
    }

    function test_buyer_isTheRoutersOwnMsgSender() public {
        uint256 start = _start();
        vm.warp(start);
        // Whatever the swap's hookData says, the buyer is the router's own report.
        MockUniversalRouter(router).setMsgSender(bob);
        vm.prank(shell);
        (address buyer,) = module.buyerAndTaxPpm(router);
        assertEq(buyer, bob, "buyer from msgSender()");
    }

    function test_constructor_refusesANonCanonicalRouter() public {
        address other = address(new MockUniversalRouter());
        vm.expectRevert(FluxLaunchProtectionModule.InvalidConfiguration.selector);
        _deploy(
            address(token),
            initializer,
            other,
            CREATOR_FEE_BPS,
            _six(address(0), address(0), address(0), address(0), address(0), address(0))
        );
    }

    function test_buyer_machineryIsNotAPerson() public {
        uint256 start = _start();
        vm.warp(start);

        address[4] memory bad = [address(0), router, shell, manager];
        for (uint256 i; i < bad.length; ++i) {
            MockUniversalRouter(router).setMsgSender(bad[i]); // the router reports machinery as its caller
            vm.prank(shell);
            vm.expectRevert(FluxLaunchProtectionModule.InvalidBuyer.selector);
            module.buyerAndTaxPpm(router);
        }
    }

    function test_buyer_theInitialBuyIsTheDevelopers() public {
        uint256 start = _start();
        vm.warp(start);
        // The initializer swaps before any router exists, with no payload at all: the launch's own buy,
        // attributed to the developer so it is exempt and still budgeted.
        (address buyer, uint24 taxPpm) = _ask(initializer, "");
        assertEq(buyer, initializer, "the developer");
        assertEq(taxPpm, 0, "exempt from the opening fee");
    }

    function test_buyer_nothingIsAuthenticatedOutsideTheWindow() public {
        // Before trading opens.
        (address buyer, uint24 taxPpm) = _ask(stranger, "");
        assertEq(buyer, address(0), "no buyer to name");
        assertEq(taxPpm, 0, "no fee to charge");

        // And after five minutes, any sender may buy through anything: a sell is never authenticated, and
        // neither is a trade whose window has closed. The payload is not even read.
        uint256 start = _start();
        vm.warp(start + 300);
        (buyer, taxPpm) = _ask(stranger, "");
        assertEq(buyer, address(0), "the window has closed");
        assertEq(taxPpm, 0, "and the fee is flat");
        (buyer, taxPpm) = _ask(stranger, hex"deadbeef");
        assertEq(buyer, address(0), "a payload of any shape is not read after the window");
        assertEq(taxPpm, 0, "and the fee is flat");

        // One second earlier, the same stranger is still refused: the window ends at 300 seconds, not
        // somewhere around it.
        vm.warp(start + 299);
        vm.expectRevert(FluxLaunchProtectionModule.UnsupportedRouter.selector);
        _ask(stranger, "");
    }

    function test_buyer_isAuthenticatedForTheWholeWindowNotJustTheDecay() public {
        uint256 start = _start();
        // Between the thirtieth second and the three hundredth, the opening fee is gone but the buyer
        // budget is not: the buyer must still be identified, and a sender the pool did not pin must still
        // be refused.
        vm.warp(start + 100);
        (address buyer, uint24 taxPpm) = _ask(router, abi.encode(bob));
        assertEq(buyer, bob, "named after the decay");
        assertEq(taxPpm, 0, "with no opening fee");

        vm.expectRevert(FluxLaunchProtectionModule.UnsupportedRouter.selector);
        _ask(stranger, "");
    }

    function test_buyer_theLastSecondOfTheWindowStillCounts() public {
        uint256 start = _start();
        vm.warp(start + 299);
        (address buyer, uint24 taxPpm) = _ask(router, abi.encode(alice));
        assertEq(buyer, alice, "named at 299 s");
        assertEq(taxPpm, 0, "no opening fee left");

        vm.warp(start + 300);
        (buyer, taxPpm) = _ask(router, abi.encode(alice));
        assertEq(buyer, address(0), "and not named at 300 s");
        assertEq(taxPpm, 0, "no opening fee");
    }
}
