// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeAgreementDisputeExitAndGasCaps.s.sol
//
// Carries three Agreement fixes to the people who will make deals after it:
//
//   1. a silent diamond no longer locks a disputed deal for ever
//             (triggerArbiterTimeout stood behind a bare
//              hasSubmittedVerdict() read on the diamond; an unanswered read
//              meant "a verdict exists", and the pot stayed in the clone with
//              no second door -- measured, not read: no rescue function exists
//              here and none on the diamond, because the money is not there)
//
//   2. a gas-eating facet can no longer stand between a party and
//             their money (try/catch turns a revert into a caught failure but
//             cannot give back gas the callee already burned; closing an
//             ordinary deal against such a facet cost 29_791_258 instead of
//             419_481 gas -- more than a block. Every tolerated diamond call
//             now carries a measured {gas: ...} cap.)
//
//   (this one) a deal can no longer be created with no terms at all
//             (initialize() reverts EmptyTerms on an empty `terms_`. The terms
//             are the subject of the agreement and the only thing an arbiter
//             has to judge a dispute by; they were stored, drawn into the NFT,
//             and read by no branch of the logic, so an empty string went the
//             whole way -- deal created, money escrowed, dispute claimed, no
//             subject. Emptiness is measured by byte
//             length, not by scanning for whitespace -- the reasoning is in
//             the comment at the guard itself; the interface trims.)
//
// Details and the measurements: the diamond-death-escrow audit of 22 August
// 2026 and test/DealTermsRequired.t.sol
//
// WHY A NEW IMPLEMENTATION AT ALL. Every deal is an EIP-1167 clone, and a
// clone is nailed to the implementation it was cloned from -- there is no
// upgrade path inside a clone. A fix in src/Agreement.sol reaches nobody
// until a new implementation is deployed and a new AgreementDeployer is
// pointed at it. NOT RETROACTIVE: clones that already exist keep the old
// code and keep behaving exactly as they did. Only deals created after this
// script runs carry the fixes.
//
// What it does, in order:
//   1. deploy the new Agreement implementation;
//   2. deploy AgreementDeployer(authorizedCaller = diamond, implementation =
//      the new one) -- its constructor refuses zero addresses and an
//      implementation without code;
//   3. call setAgreementDeployer(new) on the diamond (onlyOwner).
//
// The diamond address comes from the environment and is never hardcoded: the
// five previous versions of this script are pinned to diamonds that no longer
// exist, and running any of them today would "succeed" against a dead address.
//
// Usage (dry run -- always this one first, it makes no transaction):
//   forge script script/UpgradeAgreementDisputeExitAndGasCaps.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeAgreementDisputeExitAndGasCaps.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/AgreementDeployer.sol";
import "../src/FactoryFacet.sol";

contract UpgradeAgreementDisputeExitAndGasCaps is Script {
    function run() external {
        address diamond     = vm.envAddress("DIAMOND_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(deployerKey);

        // ── Pre-flight: everything checkable before a wei is spent ─────────
        // Two deploys stand in front of setAgreementDeployer. Tripping here
        // is free; tripping on the third step means paying for two contracts
        // that nothing points at.
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

        // Is there anything to ship? The deployer in the diamond names the
        // implementation every new deal is cloned from. If that live code is
        // byte-for-byte what this checkout compiles, the run would spend real
        // gas to change nothing -- a stale checkout, or a second run by
        // mistake. The expected side of this comparison is the compiler's
        // output for the current source; the actual side is read off the live
        // chain. Two independent sources on purpose.
        address oldImpl = _readAddressIfAnswered(oldDeployer, "implementation()");
        if (oldImpl != address(0)) {
            require(
                oldImpl.codehash != keccak256(type(Agreement).runtimeCode),
                "upgrade: the live implementation is byte-identical to what this checkout compiles - nothing to ship, wrong commit?"
            );
        }

        console.log("--- Before ---");
        console.log("Diamond:               ", diamond);
        console.log("Owner:                 ", currentOwner);
        console.log("Deployer in diamond:   ", oldDeployer);
        console.log("  its implementation:  ", oldImpl);
        console.log("");

        // ── The upgrade ────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        // Deployed once, cloned for every deal. Its own constructor sets
        // _initialized = true, so the implementation itself cannot be claimed
        // by a stranger calling initialize() on it; that is asserted below
        // against the freshly deployed bytecode rather than assumed.
        Agreement agreementImpl = new Agreement();
        console.log("New Agreement impl:    ", address(agreementImpl));

        // The deployer's constructor requires non-zero addresses and code at
        // the implementation: Clones.clone() checks neither, and a call to a
        // codeless address returns SUCCESS in the EVM, so a clone of nothing
        // would pass as a working deal.
        AgreementDeployer newDeployer = new AgreementDeployer(diamond, address(agreementImpl));
        console.log("New AgreementDeployer: ", address(newDeployer));

        FactoryFacet(diamond).setAgreementDeployer(address(newDeployer));

        vm.stopBroadcast();

        // ── Post-check: read the result back, do not assume it ─────────────
        address stored = FactoryFacet(diamond).getAgreementDeployer();
        require(stored == address(newDeployer), "upgrade: setAgreementDeployer did not take effect");
        require(
            newDeployer.authorizedCaller() == diamond,
            "upgrade: new deployer is wired to a different caller"
        );
        require(
            newDeployer.implementation() == address(agreementImpl),
            "upgrade: new deployer points at a different implementation"
        );
        require(
            address(agreementImpl).code.length > 0,
            "upgrade: new implementation has no code"
        );
        // This is what makes the "nothing to ship" pre-flight above mean
        // anything: it compares a codehash read off the chain with
        // keccak256(type(Agreement).runtimeCode), and those two are only
        // comparable while the compiler's runtimeCode is literally what lands
        // on chain. Should Agreement ever gain an immutable, that stops being
        // true, and this line says so instead of the pre-flight quietly
        // never matching again.
        require(
            address(agreementImpl).codehash == keccak256(type(Agreement).runtimeCode),
            "upgrade: deployed implementation differs from type(Agreement).runtimeCode - the pre-flight identity check is blind"
        );

        // The implementation is left standing on chain for ever, and clones
        // only delegatecall into it -- its own storage is nobody's escrow.
        // Still, an unlocked implementation is a contract any stranger can
        // name themselves the client of, under the project deployer address, verified
        // on Basescan. Asserted by behaviour, not by reading the source: a
        // staticcall cannot write and cannot be broadcast, so the only way it
        // comes back with AlreadyInitialized is that the guard is really there.
        _requireImplementationLocked(address(agreementImpl), diamond);

        console.log("");
        console.log("--- After ---");
        console.log("Deployer in diamond:   ", stored);
        console.log("  authorizedCaller:    ", newDeployer.authorizedCaller());
        console.log("  implementation:      ", newDeployer.implementation());
        console.log("");
        console.log("New deals get: a dispute that survives a silent diamond, gas caps on");
        console.log("every diamond call, and a refusal to be created with empty terms.");
        console.log("Existing clones are untouched and keep working.");
        console.log("");
        console.log("Rollback (restores the previous deployer in one transaction):");
        console.log("  cast send <diamond> \"setAgreementDeployer(address)\" <old> \\");
        console.log("    --private-key $PRIVATE_KEY --rpc-url $BASE_SEPOLIA_RPC_URL");
        console.log("  <diamond> =", diamond);
        console.log("  <old>     =", oldDeployer);
    }

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

    /// Same read, but a silent target is an answer too: deployers older than
    /// the EIP-1167 switch have no implementation() at all, and that is not a
    /// reason to refuse the upgrade.
    function _readAddressIfAnswered(address target, string memory signature) internal view returns (address) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    /// Proves the freshly deployed implementation refuses initialize().
    function _requireImplementationLocked(address impl, address diamond) internal view {
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
        require(!ok, "upgrade: implementation accepted initialize() - a stranger can claim it");
        require(
            ret.length >= 4 && bytes4(ret) == Agreement.AlreadyInitialized.selector,
            "upgrade: implementation did not refuse initialize() with AlreadyInitialized - the constructor lock is gone"
        );
    }
}
