// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/DiamondProxy.sol";

contract RemoveOldFacets is Script {
    address DIAMOND = vm.envAddress("DIAMOND_ADDRESS");
    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

    function run() external {
        require(DIAMOND != address(0), "DIAMOND_ADDRESS not set");

        console.log("=== REMOVE JobNFTFacet + OfferNFTFacet ===");
        console.log("Diamond:", DIAMOND);

        bytes4[] memory jobSelectors = new bytes4[](15);
        jobSelectors[0]  = 0x8129fc1c;
        jobSelectors[1]  = 0xcc63abf7;
        jobSelectors[2]  = 0x1dffa3dc;
        jobSelectors[3]  = 0xe0c94ae5;
        jobSelectors[4]  = 0x0a3ff40d;
        jobSelectors[5]  = 0xe1255294;
        jobSelectors[6]  = 0xa1c0d32f;
        jobSelectors[7]  = 0xd93d9beb;
        jobSelectors[8]  = 0x34b25ee2;
        jobSelectors[9]  = 0xbf22c457;
        jobSelectors[10] = 0xcf2646c2;
        jobSelectors[11] = 0x45f4649f;
        jobSelectors[12] = 0x04f801a0;
        jobSelectors[13] = 0x5b7c278e;
        jobSelectors[14] = 0xc4e41b22;

        bytes4[] memory offerSelectors = new bytes4[](10);
        offerSelectors[0] = 0xc4d66de8;
        offerSelectors[1] = 0x0b569cb4;
        offerSelectors[2] = 0xfd7926cb;
        offerSelectors[3] = 0x5a113042;
        offerSelectors[4] = 0x7dcf9d81;
        offerSelectors[5] = 0x0b5e1f3f;
        offerSelectors[6] = 0x4579268a;
        offerSelectors[7] = 0xea2991c2;
        offerSelectors[8] = 0x18955c6d;
        offerSelectors[9] = 0x87003901;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: jobSelectors
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: offerSelectors
        });

        console.log("JobNFTFacet before:", IDiamondLoupe(DIAMOND).facetAddress(0xcc63abf7));
        console.log("OfferNFTFacet before:", IDiamondLoupe(DIAMOND).facetAddress(0x0b569cb4));

        vm.startBroadcast(deployerPrivateKey);
        IDiamondCut(DIAMOND).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        address jobCheck   = IDiamondLoupe(DIAMOND).facetAddress(0xcc63abf7);
        address offerCheck = IDiamondLoupe(DIAMOND).facetAddress(0x0b569cb4);
        console.log("JobNFTFacet after:",   jobCheck);
        console.log("OfferNFTFacet after:", offerCheck);

        require(jobCheck   == address(0), "JobNFTFacet not removed");
        require(offerCheck == address(0), "OfferNFTFacet not removed");

        console.log("=== DONE: Diamond clean ===");
    }
}
