// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FluxSwapRouter} from "../src/swap/FluxSwapRouter.sol";

/// @notice Deploys the router holders trade through, against the chain's PoolManager.
/// @dev `POOL_MANAGER` is that chain's v4 PoolManager, the same one the shell was built on. The router
/// takes no other constructor argument: it holds no funds, has no owner and reads nothing but the pool
/// key each call carries.
contract DeploySwapRouter is Script {
    function run() external returns (FluxSwapRouter router) {
        address manager = vm.envAddress("POOL_MANAGER");
        vm.startBroadcast();
        router = new FluxSwapRouter(IPoolManager(manager));
        vm.stopBroadcast();
        console.log("FluxSwapRouter", address(router));
        console.log("PoolManager", manager);
    }
}
