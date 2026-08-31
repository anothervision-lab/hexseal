// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeAgreementHandInSignal.s.sol
//
// THE SECOND HALF OF THE HAND-IN SIGNAL, and the half that cannot be taken
// back. `script/UpgradeRegistryHandInSignal.s.sol` mounts the door on the
// diamond; this one makes new deals walk through it.
//
// WHAT CHANGES. `Agreement.markDone()` now calls
// `RegistryFacet.notifyWorkHandedIn()` on the diamond, under a measured gas cap
// (`HANDOFF_NOTIFY_GAS`, 100 000 against 11 446 measured) and inside a
// try/catch. Before this, markDone touched the diamond not at all: it stamped
// the clone and emitted `MarkedDone` THERE, while the one standing chain
// observer is pinned to the diamond. So the transition that starts
// AUTO_APPROVE_WINDOW -- after which `triggerAutoApprove()` hands the ENTIRE pot
// to the executor through a door open to anyone -- was invisible from the only
// address anybody watches, and a client on another page found out by opening
// the deal, or did not find out.
//
// ⚠️ THIS IS NOT A diamondCut, AND IT IS THE STEP THAT CANNOT BE TAKEN BACK.
// Every deal is an EIP-1167 clone, and a clone is NAILED to the implementation
// it was cloned from -- there is no upgrade path inside a clone. So:
//
//   * deals already alive keep reading the OLD implementation and notice
//     nothing whatsoever. Measured on 31 August 2026: the live registry holds
//     EIGHT deals, all clones of 0x28bCCc48bd2Cb39f338d0bAB796Da23768C4e053,
//     and none of them will ever announce a hand-in;
//   * the signal reaches only clones created AFTER this script runs;
//   * this script's own `rollback` can point the factory at the old deployer
//     again. The POINTER is reversible. The clones born while it pointed here
//     are not.
//
// ⚠️ ORDER, AND IT IS ENFORCED HERE RATHER THAN REMEMBERED. The registry cut
// goes FIRST. This script REFUSES to run against a diamond that does not route
// `notifyWorkHandedIn()`, because the reverse order is a silent failure and not
// a loud one: the clone's call is wrapped in try/catch, so new deals would hand
// in exactly as before, announce nothing, and nothing anywhere would say so.
// The pre-flight below turns that silence into a refusal.
//
// WHAT IT DOES, IN ORDER:
//   1. refuse unless the diamond already routes notifyWorkHandedIn();
//   2. deploy the new Agreement implementation;
//   3. deploy AgreementDeployer(authorizedCaller = diamond, implementation =
//      the new one) -- its constructor refuses zero addresses and an
//      implementation without code;
//   4. call setAgreementDeployer(new) on the diamond (onlyOwner).
//
// WHY A NEW DEPLOYER AND NOT JUST A NEW IMPLEMENTATION. `AgreementDeployer`
// holds `implementation` as an `immutable`. There is no setter and there cannot
// be one without redeploying the deployer anyway, so a new implementation always
// costs two contracts, not one.
//
// ⚠️ WHERE THIS ONE CAN FAIL EXPENSIVELY. Two deploys stand in front of
// `setAgreementDeployer`. Tripping in the pre-flight is free; tripping on the
// third step means having paid for two contracts that nothing points at. So
// everything checkable is checked before the first `new`.
//
// Usage (dry run -- always this one first, it sends no transaction):
//   forge script script/UpgradeAgreementHandInSignal.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeAgreementHandInSignal.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Agreement} from "../src/Agreement.sol";
import {AgreementDeployer} from "../src/AgreementDeployer.sol";
import {FactoryFacet} from "../src/FactoryFacet.sol";
import {RegistryFacet} from "../src/RegistryFacet.sol";
import {IDiamondLoupe} from "../src/DiamondProxy.sol";

contract UpgradeAgreementHandInSignal is Script {

    /// EIP-170. Written here as a literal by a person rather than derived from
    /// anything in the tree: it is the chain's rule and not this project's, and
    /// a constant read out of the thing being measured would be the fourth way
    /// to be fooled by a measurement.
    uint256 public constant CONTRACT_SIZE_LIMIT = 24_576;

    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeAgreementHandInSignal.s.sol";
    }

    function run() external {
        address diamond     = vm.envAddress("DIAMOND_ADDRESS");
        // The signer comes from the command line (--account / --private-key), never
        // from the environment. Foundry fills msg.sender from --sender and derives it
        // from --private-key; with no wallet named at all it stays forge-std's
        // DEFAULT_SENDER, which is how a dry run identifies itself below.
        address broadcaster = msg.sender;

        // ── Pre-flight: everything checkable before a wei is spent ─────────
        require(diamond != address(0), "upgrade: DIAMOND_ADDRESS is zero");
        require(diamond.code.length > 0, "upgrade: DIAMOND_ADDRESS has no code");

        // Code is not enough. TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT
        // live in the same .env and all three have code, so a typo would pass
        // the check above. Probe the two selectors this script actually uses.
        address currentOwner = _readAddress(diamond, "owner()");
        address oldDeployer  = _readAddress(diamond, "getAgreementDeployer()");

        if (broadcaster == DEFAULT_SENDER) {
            // A dry run with nobody named as the signer. Every chain read above still
            // ran; the only thing not checkable is WHO signs, because nothing said.
            // Foundry itself refuses to broadcast from DEFAULT_SENDER ("You seem to be
            // using Foundry's default sender"), so no live run can reach the cut
            // through this branch -- the check is skipped only when there is nothing
            // left to protect.
            console.log("NOTE: no signer named (--account/--sender absent).");
            console.log("      Ownership is NOT checked in this run. The live run needs:");
            console.log("      --account deployer --sender", currentOwner);
        } else {
            require(
                currentOwner == broadcaster,
                "upgrade: the signer is not the diamond owner - setAgreementDeployer would revert after two paid deploys"
            );
        }
        require(
            oldDeployer != address(0),
            "upgrade: factory has no deployer set - this is a fresh diamond, use DeployFull"
        );

        // THE ORDER CHECK. See the header.
        assertTheDiamondCanHearAHandIn(diamond);

        // The ceiling, before anything is paid for.
        assertTheImplementationFitsOnChain();

        // Is there anything to ship?
        address oldImpl = _readAddressIfAnswered(oldDeployer, "implementation()");
        assertThereIsSomethingToShip(oldImpl);

        console.log("=== UpgradeAgreementHandInSignal: pre-flight ===");
        console.log("Diamond:                ", diamond);
        console.log("Owner:                  ", currentOwner);
        console.log("Deployer in diamond:    ", oldDeployer);
        console.log("  its implementation:   ", oldImpl);
        console.log("  its code size:        ", oldImpl.code.length);
        console.log("New implementation size:", type(Agreement).runtimeCode.length);
        console.log("EIP-170 ceiling:        ", CONTRACT_SIZE_LIMIT);
        console.log("Headroom left:          ", implementationHeadroom());
        console.log("Deals on record today:  ", RegistryFacet(diamond).totalAgreements());
        console.log("");
        console.log("!! IRREVERSIBLE FOR EVERY DEAL CREATED AFTER THIS RUNS. A clone carries the");
        console.log("   implementation it was cloned from and is nailed to it for life. Pointing");
        console.log("   the factory back at the old deployer does NOT move a clone that was");
        console.log("   already born. Every deal alive today is untouched, keeps working, and");
        console.log("   will NEVER announce a hand-in. They stay on:");
        console.log("  ", oldImpl);
        console.log("");

        // ── The upgrade ────────────────────────────────────────────────────
        vm.startBroadcast();

        // Deployed once, cloned for every deal. Its own constructor sets
        // _initialized = true, so the implementation itself cannot be claimed by
        // a stranger calling initialize() on it; that is asserted below against
        // the freshly deployed bytecode rather than assumed.
        Agreement agreementImpl = new Agreement();
        console.log("New Agreement impl:    ", address(agreementImpl));

        // The deployer's constructor requires non-zero addresses and code at the
        // implementation: Clones.clone() checks neither, and a call to a codeless
        // address returns SUCCESS in the EVM, so a clone of nothing would pass as
        // a working deal.
        AgreementDeployer newDeployer = new AgreementDeployer(diamond, address(agreementImpl));
        console.log("New AgreementDeployer: ", address(newDeployer));

        FactoryFacet(diamond).setAgreementDeployer(address(newDeployer));

        vm.stopBroadcast();

        // ── Post-check: read the result back, do not assume it ─────────────
        assertWiring(diamond, address(newDeployer), address(agreementImpl));
        assertDeployedCodeIsWhatThisCheckoutCompiles(address(agreementImpl));
        assertImplementationIsLocked(address(agreementImpl), diamond);

        console.log("");
        console.log("=== After ===");
        console.log("Deployer in diamond:   ", FactoryFacet(diamond).getAgreementDeployer());
        console.log("  authorizedCaller:    ", newDeployer.authorizedCaller());
        console.log("  implementation:      ", newDeployer.implementation());
        console.log("  implementation size: ", address(agreementImpl).code.length);
        console.log("");
        console.log("Deals created from now on announce their hand-in on the diamond, where the");
        console.log("bell can see it. Deals created before this keep the behaviour they were born");
        console.log("with, and nothing about them changed.");
        console.log("");
        // ⚠️ Still open: on 21 August a cut shipped three contracts UNVERIFIED
        // because the script fell over on a receipt before it reached
        // `--verify`, and nobody noticed until the owner asked. Nothing here can
        // see Basescan, so the least this script can do is say both addresses
        // out loud at the end.
        console.log("VERIFY THESE TWO ON BASESCAN before calling this done - `--verify` is not");
        console.log("reached if the run trips on a receipt, and that is how three contracts shipped");
        console.log("unverified on 21 August:");
        console.log("  Agreement (implementation):", address(agreementImpl));
        console.log("  AgreementDeployer:         ", address(newDeployer));
        console.log("");
        console.log("Rollback of the POINTER ONLY (one transaction):");
        console.log("  forge script script/UpgradeAgreementHandInSignal.s.sol \\");
        console.log("    --sig \"rollback(address)\" <old deployer> \\");
        console.log("    --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER --broadcast");
        console.log("  <old deployer> =", oldDeployer);
    }

    /// Points the factory back at a previous deployer, and refuses to do it
    /// blind. It cannot undo the clones.
    function rollback(address previousDeployer) external {
        address diamond     = vm.envAddress("DIAMOND_ADDRESS");

        require(diamond != address(0), "rollback: DIAMOND_ADDRESS is zero");
        require(previousDeployer != address(0), "rollback: previous deployer is zero");
        require(previousDeployer.code.length > 0, "rollback: previous deployer has no code");

        address current = _readAddress(diamond, "getAgreementDeployer()");
        require(
            current != previousDeployer,
            "rollback: the factory already points at the deployer asked for - nothing to undo"
        );

        // A deployer whose authorizedCaller is somebody else would be accepted
        // by the factory and would then refuse every single deal, which reads
        // from the outside as "the site is broken" and not as "the rollback was
        // wrong".
        address caller = _readAddressIfAnswered(previousDeployer, "authorizedCaller()");
        require(
            caller == diamond,
            "rollback: that deployer is wired to a different caller - every deal through it would revert"
        );
        address impl = _readAddressIfAnswered(previousDeployer, "implementation()");
        require(
            impl != address(0) && impl.code.length > 0,
            "rollback: that deployer's implementation has no code - clones of it would be empty shells"
        );

        vm.startBroadcast();
        FactoryFacet(diamond).setAgreementDeployer(previousDeployer);
        vm.stopBroadcast();

        require(
            FactoryFacet(diamond).getAgreementDeployer() == previousDeployer,
            "rollback: setAgreementDeployer did not take effect"
        );
        console.log("Rolled back: new deals are cloned from", impl);
        console.log("Clones already created keep what they were born with. That cannot change.");
    }

    // ════════════════════════════════════════════════════════════════════
    // CHECKS — public so test/AgreementHandInSignalUpgrade.t.sol can call them
    // against a locally built diamond, not only through run() on a live chain.
    // ════════════════════════════════════════════════════════════════════

    /// THE ORDER CHECK, and the reason this script exists as its own file rather
    /// than as a paragraph in a runbook.
    ///
    /// The clone's announcement is wrapped in try/catch, so shipping this
    /// implementation onto a diamond that cannot hear it is not an error -- it
    /// is SILENCE. New deals would behave exactly as old ones, the bell would
    /// stay as blind as it is today, and the only way to find out would be to
    /// notice that nothing improved.
    ///
    /// Asked of the LOUPE, over the whole diamond, so the answer comes from the
    /// chain and not from this repository's opinion of what has been cut.
    function assertTheDiamondCanHearAHandIn(address diamond) public view {
        require(
            IDiamondLoupe(diamond).facetAddress(RegistryFacet.notifyWorkHandedIn.selector) != address(0),
            "pre-flight: the diamond does not route notifyWorkHandedIn() - run script/UpgradeRegistryHandInSignal.s.sol FIRST, or every new deal ships announcing nothing, in silence"
        );
    }

    /// EIP-170, asserted where the failure has a sentence attached to it.
    /// `new Agreement()` on a contract over the limit reverts with no reason at
    /// all, and it would do so INSIDE the broadcast -- after the gas is
    /// committed.
    function assertTheImplementationFitsOnChain() public pure {
        require(
            type(Agreement).runtimeCode.length <= CONTRACT_SIZE_LIMIT,
            "pre-flight: the compiled Agreement is over the EIP-170 ceiling - `new Agreement()` would revert with no reason inside the broadcast"
        );
    }

    /// Headroom, so the number can be printed and watched rather than
    /// rediscovered by a failing deploy.
    function implementationHeadroom() public pure returns (uint256) {
        uint256 size = type(Agreement).runtimeCode.length;
        return size >= CONTRACT_SIZE_LIMIT ? 0 : CONTRACT_SIZE_LIMIT - size;
    }

    /// The live implementation must not be byte-identical to what this checkout
    /// compiles, or the run pays for two contracts to change nothing.
    ///
    /// A zero address is not a failure: deployers older than the EIP-1167 switch
    /// have no `implementation()` at all, and that is not a reason to refuse.
    function assertThereIsSomethingToShip(address liveImplementation) public view {
        if (liveImplementation == address(0)) return;
        require(
            liveImplementation.codehash != keccak256(type(Agreement).runtimeCode),
            "pre-flight: the live implementation is byte-identical to what this checkout compiles - nothing to ship, wrong commit?"
        );
    }

    /// The three facts the factory now depends on, read back off the chain
    /// rather than assumed from the fact that three transactions succeeded.
    function assertWiring(address diamond, address newDeployer, address newImplementation) public view {
        require(
            FactoryFacet(diamond).getAgreementDeployer() == newDeployer,
            "post-flight: setAgreementDeployer did not take effect"
        );
        require(
            AgreementDeployer(newDeployer).authorizedCaller() == diamond,
            "post-flight: the new deployer is wired to a different caller - every deal through it would revert"
        );
        require(
            AgreementDeployer(newDeployer).implementation() == newImplementation,
            "post-flight: the new deployer points at a different implementation"
        );
        require(
            newImplementation.code.length > 0,
            "post-flight: the new implementation has no code"
        );
    }

    /// This is what makes the "nothing to ship" pre-flight mean anything: it
    /// compares a codehash read off the chain with
    /// `keccak256(type(Agreement).runtimeCode)`, and those two are only
    /// comparable while the compiler's runtimeCode is literally what lands on
    /// chain. Should Agreement ever gain an immutable, that stops being true,
    /// and this line says so instead of the pre-flight quietly never matching
    /// again.
    function assertDeployedCodeIsWhatThisCheckoutCompiles(address implementation) public view {
        require(
            implementation.codehash == keccak256(type(Agreement).runtimeCode),
            "post-flight: deployed implementation differs from type(Agreement).runtimeCode - the pre-flight identity check is blind"
        );
    }

    /// The implementation is left standing on chain for ever, and clones only
    /// delegatecall into it -- its own storage is nobody's escrow. Still, an
    /// unlocked implementation is a contract any stranger can name themselves
    /// the client of, under the project deployer address, verified on Basescan.
    ///
    /// Asserted by BEHAVIOUR, not by reading the source: a staticcall cannot
    /// write and cannot be broadcast, so the only way it comes back with
    /// `AlreadyInitialized` is that the guard is really there.
    function assertImplementationIsLocked(address impl, address diamond) public view {
        (bool ok, bytes memory ret) = impl.staticcall(
            abi.encodeWithSignature(
                "initialize(address,address,address,uint256,uint256,string,address,address,address,address)",
                address(0xC1),        // client
                address(0xE2),        // executor
                address(0xA3),        // arbiter
                uint256(1),           // amount
                uint256(1),           // deadlineDays
                "implementation lock probe",
                diamond,
                diamond,              // usdc: any non-zero address, the guard fires first
                address(0),           // trustedForwarder
                diamond               // factory
            )
        );
        require(!ok, "post-flight: the implementation accepted initialize() - a stranger can claim it");
        require(
            ret.length >= 4 && bytes4(ret) == Agreement.AlreadyInitialized.selector,
            "post-flight: the implementation refused initialize() for some reason other than AlreadyInitialized"
        );
    }

    function _readAddress(address target, string memory sig) internal view returns (address out) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && ret.length == 32, string.concat("upgrade: the diamond did not answer ", sig));
        out = abi.decode(ret, (address));
    }

    /// The same, but a contract that does not implement the selector answers
    /// `address(0)` instead of stopping the run. Deployers older than the
    /// EIP-1167 switch have no `implementation()`.
    function _readAddressIfAnswered(address target, string memory sig) internal view returns (address out) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        if (!ok || ret.length != 32) return address(0);
        out = abi.decode(ret, (address));
    }
}
