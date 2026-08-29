// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeAgreementPacking.s.sol
//
// THE WHOLE LIFE OF A DEAL IN ONE STORAGE SLOT. Five timestamps, five flags and
// the deadline used to occupy SEVEN slots, five of them carrying a number below
// 2^40 in a thirty-two byte word. They now occupy one word, thirty-two bytes
// exactly, at slot 10.
//
// ⚠️ THIS IS NOT A diamondCut, AND IT IS THE ONE STEP THAT CANNOT BE TAKEN
// BACK. Every deal is an EIP-1167 clone, and a clone is NAILED to the
// implementation it was cloned from — there is no upgrade path inside a clone.
// So:
//
//   * deals already alive keep reading the OLD implementation and notice
//     nothing whatsoever;
//   * the new shape reaches only clones created AFTER this script runs;
//   * a clone created after it can never be moved back, even though this
//     script's own `rollback` can point the factory at the old deployer again.
//     The pointer is reversible. The clones born while it pointed here are not.
//
// That is why the Agreement layout gate refuses this
// change by default and had to be told about it: changing the TYPE of an
// existing storage field is forbidden everywhere else in this codebase, and it
// is the bug that broke JobBoard in July 2026. It is safe here for one reason
// and one only — clones do not share storage with each other or with anything
// that already holds money. There is no live data underneath.
//
// WHAT IT DOES, IN ORDER:
//   1. deploy the new Agreement implementation;
//   2. deploy AgreementDeployer(authorizedCaller = diamond, implementation =
//      the new one) — its constructor refuses zero addresses and an
//      implementation without code;
//   3. call setAgreementDeployer(new) on the diamond (onlyOwner).
//
// WHY A NEW DEPLOYER AND NOT JUST A NEW IMPLEMENTATION. `AgreementDeployer`
// holds `implementation` as an `immutable`. There is no setter and there cannot
// be one without redeploying the deployer anyway, so a new implementation always
// costs two contracts, not one.
//
// ⚠️ WHERE THIS ONE CAN FAIL EXPENSIVELY. Two deploys stand in front of
// `setAgreementDeployer`. Tripping in the pre-flight is free; tripping on the
// third step means having paid for two contracts that nothing points at. So
// everything checkable is checked before the first `new`, including the two
// things that changed with the packing:
//
//   the ceiling  the implementation grew from 21 060 bytes to 23 314 against the
//                EIP-170 limit of 24 576 — packing trades storage slots for
//                shift-and-mask code. `new Agreement()` on a contract over the
//                limit reverts with no reason at all, so the size is asserted
//                here, where the failure has a sentence attached to it.
//
//   the identity the live implementation must NOT be byte-identical to what this
//                checkout compiles. If it is, the run would spend real gas to
//                change nothing — a stale checkout, or a second run by mistake.
//                The expected side of that comparison is the compiler's output
//                for the current source; the actual side is read off the live
//                chain. Two independent sources on purpose.
//
// The diamond address comes from the environment and is never hardcoded: older
// versions of this script are pinned to diamonds that no longer exist, and
// running any of them today would "succeed" against a dead address.
//
// Usage (dry run — always this one first, it sends no transaction):
//   forge script script/UpgradeAgreementPacking.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeAgreementPacking.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {Agreement} from "../src/Agreement.sol";
import {AgreementDeployer} from "../src/AgreementDeployer.sol";
import {FactoryFacet} from "../src/FactoryFacet.sol";

contract UpgradeAgreementPacking is Script {

    /// EIP-170. Written here as a literal by a person rather than derived from
    /// anything in the tree: it is the chain's rule and not this project's, and a constant
    /// read out of the thing being measured would be the fourth way to be fooled
    /// by a measurement.
    uint256 public constant CONTRACT_SIZE_LIMIT = 24_576;

    /// Named for the same reason as in the cut scripts: so an offline stand can
    /// say which script it is standing for.
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeAgreementPacking.s.sol";
    }

    function run() external {
        address diamond     = vm.envAddress("DIAMOND_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(deployerKey);

        // ── Pre-flight: everything checkable before a wei is spent ─────────
        require(diamond != address(0), "upgrade: DIAMOND_ADDRESS is zero");
        require(diamond.code.length > 0, "upgrade: DIAMOND_ADDRESS has no code");

        // Code is not enough. TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT
        // live in the same .env and all three have code, so a typo would pass
        // the check above. Probe the two selectors this script actually uses.
        address currentOwner = _readAddress(diamond, "owner()");
        address oldDeployer  = _readAddress(diamond, "getAgreementDeployer()");

        require(
            currentOwner == broadcaster,
            "upgrade: PRIVATE_KEY is not the diamond owner - setAgreementDeployer would revert after two paid deploys"
        );
        require(
            oldDeployer != address(0),
            "upgrade: factory has no deployer set - this is a fresh diamond, use DeployFull"
        );

        // The ceiling, before anything is paid for.
        assertTheImplementationFitsOnChain();

        // Is there anything to ship?
        address oldImpl = _readAddressIfAnswered(oldDeployer, "implementation()");
        assertThereIsSomethingToShip(oldImpl);

        console.log("--- Before ---");
        console.log("Diamond:               ", diamond);
        console.log("Owner:                 ", currentOwner);
        console.log("Deployer in diamond:   ", oldDeployer);
        console.log("  its implementation:  ", oldImpl);
        console.log("  its code size:       ", oldImpl.code.length);
        console.log("New implementation size:", type(Agreement).runtimeCode.length);
        console.log("EIP-170 ceiling:       ", CONTRACT_SIZE_LIMIT);
        console.log("");
        console.log("!! IRREVERSIBLE FOR EVERY DEAL CREATED AFTER THIS RUNS. A clone carries the");
        console.log("   layout of the implementation it was cloned from and is nailed to it for");
        console.log("   life. Pointing the factory back at the old deployer does NOT move a clone");
        console.log("   that was already born. Deals alive today are untouched and stay on:");
        console.log("  ", oldImpl);
        console.log("");

        // ── The upgrade ────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

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
        console.log("--- After ---");
        console.log("Deployer in diamond:   ", FactoryFacet(diamond).getAgreementDeployer());
        console.log("  authorizedCaller:    ", newDeployer.authorizedCaller());
        console.log("  implementation:      ", newDeployer.implementation());
        console.log("  implementation size: ", address(agreementImpl).code.length);
        console.log("");
        console.log("New deals put their whole life - five timestamps, five flags and the deadline -");
        console.log("in one storage word. Existing clones are untouched and keep working.");
        console.log("");
        // ⚠️ Still open: on 21 August a cut shipped
        // three contracts UNVERIFIED because the script fell over on a receipt
        // before it reached `--verify`, and nobody noticed until the owner asked.
        // Nothing here can see Basescan, so the least this script can do is say
        // both addresses out loud at the end.
        console.log("VERIFY THESE TWO ON BASESCAN before calling this done - `--verify` is not");
        console.log("reached if the run trips on a receipt, and that is how three contracts shipped");
        console.log("unverified on 21 August:");
        console.log("  Agreement (implementation):", address(agreementImpl));
        console.log("  AgreementDeployer:         ", address(newDeployer));
        console.log("");
        console.log("Rollback of the POINTER ONLY (one transaction):");
        console.log("  forge script script/UpgradeAgreementPacking.s.sol \\");
        console.log("    --sig \"rollback(address)\" <old deployer> \\");
        console.log("    --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast");
        console.log("  <old deployer> =", oldDeployer);
        console.log("");
        console.log("WARNING: that rollback moves the POINTER, not the clones. Every deal created");
        console.log("while the new deployer was in place keeps the packed layout for ever, and its");
        console.log("money keeps working - the two implementations are not compatible and are not");
        console.log("meant to be. Roll back only to stop NEW deals from using the new shape.");
    }

    /// Points the factory back at a previous deployer, and refuses to do it
    /// blind. It cannot undo the clones — see the warning it prints.
    function rollback(address previousDeployer) external {
        address diamond     = vm.envAddress("DIAMOND_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

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

        vm.startBroadcast(deployerKey);
        FactoryFacet(diamond).setAgreementDeployer(previousDeployer);
        vm.stopBroadcast();

        require(
            FactoryFacet(diamond).getAgreementDeployer() == previousDeployer,
            "rollback: setAgreementDeployer did not take effect"
        );
        console.log("Rolled back: new deals are cloned from", impl);
        console.log("Clones already created keep the layout they were born with. That cannot change.");
    }

    // ════════════════════════════════════════════════════════════════════
    // CHECKS — public so test/AgreementPackingUpgrade.t.sol can call them
    // against a locally built diamond, not only through run() on a live chain.
    // ════════════════════════════════════════════════════════════════════

    /// EIP-170, asserted where the failure has a sentence attached to it.
    /// `new Agreement()` on a contract over the limit reverts with no reason at
    /// all, and it would do so INSIDE the broadcast — after the gas is committed.
    /// The packing traded seven storage slots for shift-and-mask code and moved
    /// this contract materially closer to the ceiling, so the headroom is worth
    /// a line rather than a hope.
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
    /// delegatecall into it — its own storage is nobody's escrow. Still, an
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
            "post-flight: the implementation did not refuse initialize() with AlreadyInitialized - the constructor lock is gone"
        );
    }

    // ════════════════════════════════════════════════════════════════════

    /// Reads one address-returning selector and insists on a real answer.
    /// A diamond without the facet reverts through its fallback; an unrelated
    /// contract either reverts or answers with nothing. Both land here.
    function _readAddress(address target, string memory signature) internal view returns (address) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(
            ok && data.length >= 32,
            string.concat(
                "upgrade: ", signature, " is not answered by DIAMOND_ADDRESS -- wrong address? ",
                "(TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT sit in the same .env and also have code)"
            )
        );
        return abi.decode(data, (address));
    }

    /// Same read, but a silent target is an answer too: deployers older than the
    /// EIP-1167 switch have no `implementation()` at all.
    function _readAddressIfAnswered(address target, string memory signature) internal view returns (address) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }
}
