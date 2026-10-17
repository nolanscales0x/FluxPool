// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FluxDeployer
/// @notice Minimal CREATE2 factory. A v4 hook's address must encode its permissions, so the shell is
/// deployed through this factory with a mined salt. Permissionless: the address depends only on the
/// salt and the exact initcode (constructor arguments included), so anyone deploying the same
/// salt and code just deploys the same contract.
contract FluxDeployer {
    event Deployed(address indexed addr, bytes32 indexed salt);

    error DeployFailed();

    function deploy(bytes32 salt, bytes calldata initcode) external payable returns (address addr) {
        bytes memory code = initcode;
        assembly ("memory-safe") {
            addr := create2(callvalue(), add(code, 0x20), mload(code), salt)
        }
        if (addr == address(0)) revert DeployFailed();
        emit Deployed(addr, salt);
    }

    function predict(bytes32 salt, bytes32 initcodeHash) external view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initcodeHash)))));
    }
}
