// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice What a FluxPool launch token looks like: the whole supply minted once at deploy, no mint
/// function, no owner.
contract FixedSupplyToken is ERC20 {
    constructor(string memory name, string memory symbol, uint256 supply, address to) ERC20(name, symbol, 18) {
        _mint(to, supply);
    }
}
