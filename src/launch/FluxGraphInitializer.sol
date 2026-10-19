// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FluxLauncher} from "./FluxLauncher.sol";

/// @notice The initializer of FluxPool's Programmable launch graph on Ethereum.
///
/// Programmable's Router deploys the launch graph (the token, the shell and this contract) and calls
/// `launch` in the same transaction, with the initial buy as its value. `launch` hands everything to
/// `FluxLauncher.launchProtected`, which checks the opening valuation, initializes the pool, seeds the
/// whole supply as locked liquidity, starts protection and makes the initial buy for the developer
/// named in the protection module. The launcher returns any rounding dust and unspent value to its
/// caller, which is this contract; both are passed on to the developer, so nothing stays here.
///
/// It holds nothing between transactions and can launch once.
contract FluxGraphInitializer {
    using SafeERC20 for IERC20;

    FluxLauncher public immutable launcher;
    /// @notice Receives the launcher's dust and refunds. The plan sets it to the protection module's developer.
    address public immutable developer;

    bool public launched;

    error AlreadyLaunched();
    error InvalidSetup();
    error RefundFailed();

    constructor(FluxLauncher launcher_, address developer_) {
        if (address(launcher_) == address(0) || developer_ == address(0)) revert InvalidSetup();
        launcher = launcher_;
        developer = developer_;
    }

    /// @notice Launches the pool. `msg.value` is the initial buy.
    function launch(FluxLauncher.ProtectedLaunchParams calldata l) external payable {
        if (launched) revert AlreadyLaunched();
        launched = true;
        launcher.launchProtected{value: msg.value}(l);

        uint256 dust = IERC20(address(l.token)).balanceOf(address(this));
        if (dust > 0) IERC20(address(l.token)).safeTransfer(developer, dust);
        uint256 refund = address(this).balance;
        if (refund > 0) {
            (bool ok,) = developer.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @dev The launcher refunds unspent value to its caller.
    receive() external payable {}
}
