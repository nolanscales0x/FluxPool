// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

interface IUsdFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Read-only pre-launch check: would `launchProtected` accept the config's opening price right now?
/// @dev Mirrors `FluxLauncher.openingFdvUsd` and its checks exactly: the full supply at the start tick, priced
/// by the canonical Chainlink ETH/USD feed, rounded down to whole dollars, against the $15,000 floor; and the
/// feed's answer no older than one hour on mainnet. Also prints the lowest ETH/USD at which the launch
/// still clears the floor. Sends nothing. Run against mainnet:
/// `forge script script/CheckOpening.s.sol --rpc-url <mainnet>`; `PLAN_CONFIG` picks the config file.
contract CheckOpening is Script {
    uint256 constant MINIMUM_FDV_USD = 15_000;
    uint256 constant MAX_FEED_AGE = 1 hours;

    function run() external view {
        string memory j = vm.readFile(vm.envOr("PLAN_CONFIG", string("deploy/fluxpool-token.config.json")));
        IUsdFeed feed = IUsdFeed(vm.parseJsonAddress(j, ".usdFeed"));
        uint256 supply = vm.parseJsonUint(j, ".supply");
        int24 tick = int24(vm.parseJsonInt(j, ".startTick"));
        require(supply != 0 && tick != 0, "config has placeholder supply or startTick");

        (uint80 round, int256 answer,, uint256 updated, uint80 answeredRound) = feed.latestRoundData();
        uint8 dec = feed.decimals();
        uint256 age = block.timestamp - updated;
        bool feedOk = answer > 0 && updated != 0 && age <= MAX_FEED_AGE && answeredRound >= round && round != 0;

        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 nativeValue; // the whole supply in wei of ETH, as the launcher computes it
        if (sqrtP <= type(uint128).max) {
            nativeValue = FullMath.mulDiv(uint256(1) << 192, supply, uint256(sqrtP) * sqrtP);
        } else {
            nativeValue = FullMath.mulDiv(uint256(1) << 128, supply, FullMath.mulDiv(sqrtP, sqrtP, uint256(1) << 64));
        }
        uint256 fdv = FullMath.mulDiv(nativeValue, uint256(answer), 1 ether * 10 ** dec);
        // The lowest feed answer that still values the supply at the floor (rounded up).
        uint256 floorAnswer = FullMath.mulDivRoundingUp(MINIMUM_FDV_USD, 1 ether * 10 ** dec, nativeValue);

        console.log("Start tick", vm.toString(tick));
        console.log("Opening market cap (milli-ETH)", nativeValue / 1e15);
        console.log("ETH/USD now (cents)", uint256(answer) / 10 ** (dec - 2));
        console.log("Feed answer age (s)", age);
        console.log("Opening FDV now ($)", fdv);
        console.log("Launch fails below ETH/USD (cents)", floorAnswer / 10 ** (dec - 2));
        console.log(
            "Margin over the floor (bps)",
            fdv >= MINIMUM_FDV_USD ? (fdv - MINIMUM_FDV_USD) * 10_000 / MINIMUM_FDV_USD : 0
        );
        if (!feedOk) console.log("FAIL: feed answer is stale or invalid; wait for the next Chainlink update");
        else if (fdv < MINIMUM_FDV_USD) console.log("FAIL: opening FDV is under $15,000 at this ETH price");
        else console.log("OK: launchProtected would accept this opening price right now");
    }
}
