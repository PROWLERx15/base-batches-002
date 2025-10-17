// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {console} from "forge-std/console.sol";
import {PhoneLock} from "src/PhoneLock.sol";

contract DeployPhoneLock is Script, Config {
    function run() public returns (PhoneLock) {

        // Load config and enable write-back for storing deployment addresses
        _loadConfig("./config/dev.toml", true);

        // Get the chain we're deploying to
        uint256 chainId = block.chainid;
        console.log("Deploying to chain:", chainId);

        _validateConfig();

        // Load configuration values
        address verifiedSigner = config.get("verifierSigner").toAddress();
        address priceFeed = config.get("priceFeed").toAddress();
        
        // Log Deployment Details 
        console.log("==============================================");
        console.log("Deploying PhoneLock Contract to chain ID:", block.chainid);
        console.log("Deployer address (msg.sender):", msg.sender);
        console.log("Verifier Signer address:", verifiedSigner);
        console.log("Price Feed address:", priceFeed);
        console.log("==============================================");

        // Deployment 
        vm.startBroadcast();
        PhoneLock phoneLock = new PhoneLock(verifiedSigner, priceFeed);
        console.log("PhoneLock Contract deployed at:", address(phoneLock));
        vm.stopBroadcast();

        // Save deployment addresses back to config
        config.set("phone_lock_contract", address(phoneLock));

        console.log("\nDeployment complete! Addresses saved to dev.toml");
        return phoneLock;
    }

    function _validateConfig() internal view {
        // Ensure critical addresses are set
        require(config.get("verifierSigner").toAddress() != address(0), "Verifier Signer address is not set in config");
        require(config.get("priceFeed").toAddress() != address(0), "Price Feed address is not set in config");
    }

}
