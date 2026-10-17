// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FluxToken
/// @notice A FluxPool launch token: the whole supply is minted once, at deploy, to `holder`. No mint
/// function, no burn function, no owner, no pause, no fee on transfer. Burns are transfers to 0x…dEaD.
contract FluxToken is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply, address holder) ERC20(name_, symbol_) {
        _mint(holder, supply);
    }
}
