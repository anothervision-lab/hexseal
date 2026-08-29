// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DiamondProxy.sol";

/**
 * @notice Check existing selectors in Diamond
 */
contract CheckDiamondSelectors is Script {
    address DIAMOND = vm.envAddress("DIAMOND_ADDRESS");
    
    function run() external view {
        console.log("=== DIAMOND SELECTORS CHECK ===");
        console.log("Diamond address:", DIAMOND);
        
        IDiamondLoupe diamondLoupe = IDiamondLoupe(DIAMOND);
        
        // Get all facets
        IDiamondLoupe.Facet[] memory facets = diamondLoupe.facets();
        
        console.log("\nTotal facets:", facets.length);
        for (uint256 i = 0; i < facets.length; i++) {
            console.log("\nFacet", i, ":", facets[i].facetAddress);
            console.log("  Selectors:", facets[i].functionSelectors.length);
            for (uint256 j = 0; j < facets[i].functionSelectors.length; j++) {
                console.log("   -", vm.toString(facets[i].functionSelectors[j]));
            }
        }
    }
}
