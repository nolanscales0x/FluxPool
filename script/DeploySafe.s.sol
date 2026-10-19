// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function proxyCreationCode() external pure returns (bytes memory);
}

interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function VERSION() external view returns (string memory);
}

/// @notice Deploys the FluxPool Safe: canonical Safe v1.4.1 on the chain, through the canonical proxy
/// factory, with the canonical fallback handler, so Safe{Wallet} recognises and operates it as its own.
/// @dev Owners, threshold and salt come from the environment (`SAFE_OWNERS` comma-separated,
/// `SAFE_THRESHOLD`, `SAFE_SALT_NONCE`). The address depends only on those and the singleton, not on who
/// sends the transaction, so the fork rehearsal predicts the mainnet address exactly. A Safe that already
/// exists at the predicted address is checked and reused, never redeployed. `DEPLOYER_WALLET_PRIVATE_KEY`
/// pays the gas and gains no rights over the Safe.
contract DeploySafe is Script {
    ISafeProxyFactory constant FACTORY = ISafeProxyFactory(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67);
    address constant SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a; // Safe (L1) 1.4.1
    address constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    function run() external returns (address safe) {
        address[] memory owners = vm.envAddress("SAFE_OWNERS", ",");
        uint256 threshold = vm.envUint("SAFE_THRESHOLD");
        uint256 saltNonce = vm.envUint("SAFE_SALT_NONCE");
        require(threshold > 0 && threshold <= owners.length, "bad threshold");
        require(SINGLETON.code.length > 0 && address(FACTORY).code.length > 0, "Safe 1.4.1 not on this chain");

        bytes memory initializer = abi.encodeCall(
            ISafe.setup, (owners, threshold, address(0), "", FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        safe = predict(initializer, saltNonce);
        console.log("Predicted Safe", safe);

        if (safe.code.length == 0) {
            uint256 key = deployerKey();
            console.log("Gas payer", vm.addr(key), vm.addr(key).balance);
            vm.startBroadcast(key);
            address deployed = FACTORY.createProxyWithNonce(SINGLETON, initializer, saltNonce);
            vm.stopBroadcast();
            require(deployed == safe, "address mismatch");
        } else {
            console.log("Safe already deployed; checking it");
        }

        address[] memory got = ISafe(safe).getOwners();
        require(got.length == owners.length, "owner count");
        for (uint256 i; i < owners.length; i++) {
            require(got[i] == owners[i], "owner mismatch");
            console.log("Owner", got[i]);
        }
        require(ISafe(safe).getThreshold() == threshold, "threshold mismatch");
        console.log("Threshold", threshold);
        console.log("Version", ISafe(safe).VERSION());
    }

    /// @dev The key is accepted with or without its `0x` prefix.
    function deployerKey() internal view returns (uint256) {
        string memory k = vm.envString("DEPLOYER_WALLET_PRIVATE_KEY");
        bytes memory b = bytes(k);
        bool prefixed = b.length > 1 && b[0] == "0" && (b[1] == "x" || b[1] == "X");
        return vm.parseUint(prefixed ? k : string.concat("0x", k));
    }

    function predict(bytes memory initializer, uint256 saltNonce) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        bytes memory code = abi.encodePacked(FACTORY.proxyCreationCode(), uint256(uint160(SINGLETON)));
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(FACTORY), salt, keccak256(code)))))
            );
    }
}
