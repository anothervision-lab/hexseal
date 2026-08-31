// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// HEXSEAL — DeployTreasury.s.sol
// Deploys the protocol treasury. It does NOT make it the fee recipient — that is a
// separate human decision, in a separate transaction:
//   cast send $DIAMOND_ADDRESS "setFeeRecipient(address)" <treasury> \
//     --account deployer --sender $OWNER --rpc-url $BASE_SEPOLIA_RPC_URL
// The separation is deliberate: a deployment is reversible (simply do not put it
// in place), while putting it in place redirects the protocol's whole income.

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/Treasury.sol";

contract DeployTreasury is Script {
    function run() external {
        address usdc       = vm.envAddress("USDC_ADDRESS");
        address diamond    = vm.envAddress("DIAMOND_ADDRESS");
        address foundation = vm.envAddress("FOUNDATION_ADDRESS");

        require(usdc       != address(0), "DeployTreasury: USDC_ADDRESS is zero");
        require(diamond    != address(0), "DeployTreasury: DIAMOND_ADDRESS is zero");
        require(foundation != address(0), "DeployTreasury: FOUNDATION_ADDRESS is zero");
        require(usdc.code.length    > 0,  "DeployTreasury: USDC_ADDRESS has no code");
        require(diamond.code.length > 0,  "DeployTreasury: DIAMOND_ADDRESS has no code");

        // The presence of code is NOT ENOUGH. Two more contract addresses lie next
        // to it in .env — TRUSTED_FORWARDER and USDC_ADDRESS — and both have code. A
        // typo in DIAMOND_ADDRESS would pass the check above and give an IMMUTABLE
        // treasury whose every distribute() reverts (the treasury can neither correct
        // the address nor migrate: it has not one onlyOwner function), and all the
        // income sent to it would be lost forever. So what is checked is not "a
        // contract" but "THAT contract": exactly the FOUR reads the treasury uses in
        // its work are attempted.
        //
        // The fourth — getUniqueActiveUsers() — lives in a DIFFERENT facet
        // (ReputationFacet) from the first three (ArbiterRegistryFacet), and without
        // it the pre-flight was incomplete in earnest and not merely formally: a
        // diamond with ArbiterRegistryFacet but without ReputationFacet passed three
        // probes and gave an immutable treasury with a dead withdrawReserve() — that
        // is, the reserve would NEVER reach the DAO.
        _requireDiamondAnswers(diamond, "getVaultBalance()");
        _requireDiamondAnswers(diamond, "isDaoActive()");
        _requireDiamondAnswers(diamond, "getDAOAddress()");
        _requireDiamondAnswers(diamond, "getUniqueActiveUsers()");

        vm.startBroadcast();
        Treasury treasury = new Treasury(usdc, diamond, foundation);
        vm.stopBroadcast();

        console.log("Treasury:            ", address(treasury));
        console.log("  usdc:              ", usdc);
        console.log("  diamond:           ", diamond);
        console.log("  foundation:        ", foundation);
        console.log("");
        console.log("NOT wired in yet. To route protocol fees here, run:");
        console.log("  cast send <diamond> \"setFeeRecipient(address)\" <treasury>");
    }

    /// Tries to read a selector from the given address. It requires both success and
    /// an answer a whole word long: a diamond without the required facet reverts
    /// through its fallback, while an unrelated contract (the forwarder, USDC) on a
    /// foreign selector either reverts or answers with emptiness — both cases are
    /// caught here.
    function _requireDiamondAnswers(address diamond, string memory signature) internal view {
        (bool ok, bytes memory data) = diamond.staticcall(abi.encodeWithSignature(signature));
        require(
            ok && data.length >= 32,
            string.concat(
                "DeployTreasury: DIAMOND_ADDRESS does not answer ", signature,
                " -- wrong address? (TRUSTED_FORWARDER and USDC_ADDRESS live in the same .env and also have code). ",
                "A treasury deployed against a wrong diamond is IMMUTABLE and reverts on every distribute()."
            )
        );
    }
}
