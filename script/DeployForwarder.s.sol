// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/MinimalForwarder.sol";

contract DeployForwarder is Script {
    function run() external {
        
        vm.startBroadcast();
        
        console.log("Deploying MinimalForwarder...");
        MinimalForwarder forwarder = new MinimalForwarder();
        
        console.log("MinimalForwarder deployed at:", address(forwarder));
        
        vm.stopBroadcast();
        
        console.log("\nAdd to .env:");
        console.log("TRUSTED_FORWARDER=", address(forwarder));
    }
}