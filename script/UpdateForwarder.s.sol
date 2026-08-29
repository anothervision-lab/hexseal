// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/FactoryFacet.sol";

contract UpdateForwarder is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address newForwarder = vm.envAddress("TRUSTED_FORWARDER");
        
        vm.startBroadcast(deployerKey);
        
        console.log("Updating trusted forwarder...");
        console.log("Diamond:", diamond);
        console.log("New Forwarder:", newForwarder);
        
        FactoryFacet(diamond).setTrustedForwarder(newForwarder);
        
        console.log("Forwarder updated!");
        console.log("Current forwarder:", FactoryFacet(diamond).getTrustedForwarder());
        
        vm.stopBroadcast();
    }
}