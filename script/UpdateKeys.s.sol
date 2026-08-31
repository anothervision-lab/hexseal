// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/FactoryFacet.sol";

/// @notice Updates feeRecipient in the Diamond (and optionally trustedForwarder).
/// Run with:
///   forge script script/UpdateKeys.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --account deployer --sender $OWNER \
///     --broadcast
contract UpdateKeys is Script {
    function run() external {
        address diamond       = vm.envAddress("DIAMOND_ADDRESS");
        address newFeeRecipient = vm.envAddress("FEE_RECIPIENT");

        console.log("Diamond:          ", diamond);
        console.log("New feeRecipient: ", newFeeRecipient);

        // The current values, for checking
        address currentFeeRecipient = FactoryFacet(diamond).getFeeRecipient();
        address currentForwarder    = FactoryFacet(diamond).getTrustedForwarder();
        console.log("Current feeRecipient: ", currentFeeRecipient);
        console.log("Current forwarder:    ", currentForwarder);

        vm.startBroadcast();

        // Update feeRecipient
        if (currentFeeRecipient != newFeeRecipient) {
            FactoryFacet(diamond).setFeeRecipient(newFeeRecipient);
            console.log("feeRecipient updated to:", newFeeRecipient);
        } else {
            console.log("feeRecipient already up to date, skipping");
        }

        vm.stopBroadcast();

        // The final check
        address finalFeeRecipient = FactoryFacet(diamond).getFeeRecipient();
        console.log("Final feeRecipient:", finalFeeRecipient);
        require(finalFeeRecipient == newFeeRecipient, "feeRecipient not updated!");
    }
}
