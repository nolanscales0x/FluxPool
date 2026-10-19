// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FluxGraphInitializer} from "../../src/launch/FluxGraphInitializer.sol";
import {FluxLauncher} from "../../src/launch/FluxLauncher.sol";
import {ProtectedLaunchTest} from "../protection/ProtectedLaunch.t.sol";

/// @notice The V3 graph's initializer: it launches through FluxLauncher.launchProtected exactly once and
/// keeps nothing. Reuses the protected-launch fixture (real PoolManager, mocks at the canonical router and
/// Chainlink feed addresses on a simulated chain 1).
contract FluxGraphInitializerTest is ProtectedLaunchTest {
    function _init() internal returns (FluxGraphInitializer) {
        return new FluxGraphInitializer(launcher, dev);
    }

    function test_graph_launchesThroughTheLauncherForTheDeveloper() public {
        FluxGraphInitializer init = _init();
        init.launch{value: 0.01 ether}(_args(START_TICK));
        assertTrue(init.launched());
        assertGt(token.balanceOf(dev), 0, "the initial buy goes to the developer");
        assertEq(token.balanceOf(address(init)), 0, "no tokens stay in the initializer");
        assertEq(address(init).balance, 0, "no ETH stays in the initializer");
        assertGt(token.startedAt(), 0, "protection started");
    }

    function test_graph_launchesOnlyOnce() public {
        FluxGraphInitializer init = _init();
        init.launch{value: 0.01 ether}(_args(START_TICK));
        vm.expectRevert(FluxGraphInitializer.AlreadyLaunched.selector);
        init.launch{value: 0.01 ether}(_args(START_TICK));
    }

    function test_graph_aFailedLaunchRevertsEverything() public {
        FluxGraphInitializer init = _init();
        // An opening below the $15,000 floor fails inside the launcher; the initializer stays unlaunched.
        vm.expectRevert();
        init.launch{value: 0.01 ether}(_args(198_000));
        assertFalse(init.launched());
    }

    function test_graph_refusesAnIncompleteSetup() public {
        vm.expectRevert(FluxGraphInitializer.InvalidSetup.selector);
        new FluxGraphInitializer(FluxLauncher(payable(address(0))), dev);
        vm.expectRevert(FluxGraphInitializer.InvalidSetup.selector);
        new FluxGraphInitializer(launcher, address(0));
    }
}
