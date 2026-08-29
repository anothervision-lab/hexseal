// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeArbiterApplications.s.sol
//
// THE DOOR INTO THE CORPS, OPENED BEFORE THE DAO — one diamondCut, one
// element, ADD ONLY.
//
// WHAT IS WRONG TODAY. `ArbiterRegistryFacet.applyAsArbiter` reverts
// `DAONotActive` on its very first line, so before governance nobody can put
// himself forward at all; the only entrance is `addArbiter`, pressed by the
// owner against somebody he already knows. The gate on the automatic door
// measures a RECORD — 3 000 XP is roughly thirty deals with thirty different
// people — and on a marketplace nobody has used yet there is no record to
// measure. Lowering the threshold until it becomes reachable would leave the
// bond as the only filter, and a bond is bought.
//
// So admissions are decided by hand, and the measure ends BY EVENT rather than
// by anybody's promise: the same `isDaoActive()` ratchet that shuts
// `addArbiter` shuts this facet's approvals too.
//
// WHAT THIS CUT DOES: mounts ArbiterApplicationsFacet, the thirteenth facet,
// with eleven selectors. Nothing is replaced and nothing is removed.
//
//   Add 11 -> new ArbiterApplicationsFacet
//   12 facets -> 13, 203 routed selectors -> 214
//
// ⚠️ WHY THERE IS NO Replace GROUP AT ALL, AND WHY THAT IS THE POINT.
// A `Replace`/`Add` pair is the operation that drops a whole cut on one live
// transaction: `Add` reverts "Diamond: selector exists" on a selector already
// mounted, `Replace` reverts "Diamond: selector not found" on one that is not.
// This work was deliberately shaped so that no existing selector has to move:
// the storage the new facet uses is APPENDED to ArbiterRegistryStorage.Data,
// and no line of ArbiterRegistryFacet or ArbiterAccountabilityFacet is edited,
// so their deployed bytecode stands and their selectors keep pointing where
// they point.
//
// The claim "all eleven are new" is not taken on trust in either direction:
//
//   * the expected side comes from the BUILD ARTIFACT — solc's own
//     `methodIdentifiers` for ArbiterApplicationsFacet, read below out of
//     out/ArbiterApplicationsFacet.sol/ArbiterApplicationsFacet.json — not
//     from the hand-written list in this file. The two are compared, so a
//     selector this script forgets to mount stops the run;
//   * the actual side comes from the LIVE CHAIN, `facetAddress(sel)` through
//     the loupe, in the pre-flight below.
//
// Neither side is derived from the other. The offline twin of the same
// comparison lives in test/ArbiterApplicationsUpgrade.t.sol and is fed by
// test/fixtures/chain-2026-08-24-diamond-selectors.json, a census read off
// Base Sepolia at block 45 897 877 (12 facets, 203 routed selectors).
//
// The diamond address comes from the environment and is never hardcoded.
//
// Usage (dry run — always this one first, it sends no transaction):
//   forge script script/UpgradeArbiterApplications.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeArbiterApplications.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterApplicationsFacet} from "../src/facets/ArbiterApplicationsFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

/// `getApplicationWindow()` declared `view` rather than `pure`. In the facet it
/// really is pure — it returns a constant. THROUGH THE DIAMOND the same call
/// first has to find the facet in the proxy's storage, so it reads state, and
/// the whole point of the smoke test is that lookup. Declaring it `pure` here
/// would be claiming no routing happens.
interface IApplicationWindowProbe {
    function getApplicationWindow() external view returns (uint256);
}

contract UpgradeArbiterApplications is Script {

    /// The window this cut is shipping, as a literal fixed by a person. The
    /// smoke test below compares the diamond's answer with THIS, not with
    /// `ArbiterApplicationsFacet`'s own constant read back through the same
    /// deployment: a check whose expected side comes out of the thing being
    /// checked agrees with itself no matter what the number becomes.
    uint256 internal constant EXPECTED_APPLICATION_WINDOW = 7 days;

    /// The build artifact this script holds its own selector list against.
    /// Read through `vm.readFile`; `./out` is already in `fs_permissions`.
    string internal constant ARTIFACT_PATH =
        "out/ArbiterApplicationsFacet.sol/ArbiterApplicationsFacet.json";

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeArbiterApplications.s.sol";
    }

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);

        // ── Pre-flight: everything checkable before a wei is spent ─────────
        require(diamond != address(0), "upgrade: DIAMOND_ADDRESS is zero");
        require(diamond.code.length > 0, "upgrade: DIAMOND_ADDRESS has no code");

        // Code is not enough. TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT
        // live in the same .env and all three have code, so a typo would sail
        // through the check above. Probe a selector only this diamond answers.
        address currentOwner = _readAddress(diamond, "owner()");
        require(
            currentOwner == broadcaster,
            "upgrade: PRIVATE_KEY is not the diamond owner - diamondCut would revert after a paid deploy"
        );

        bytes4[] memory addSels = addSelectors();

        // The hand-written list against solc's own output. A selector the facet
        // implements and this script does not mount would otherwise ship as a
        // dead function: present in the ABI, routed nowhere, and discovered by
        // the first person whose button did nothing.
        assertAddListCoversTheWholeFacet(addSels);

        // Every one of them must be unmounted TODAY, or `Add` reverts and takes
        // the whole cut with it.
        assertAllUnmounted(addSels, diamond);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        uint256 facetsBefore    = IDiamondLoupe(diamond).facetAddresses().length;

        console.log("=== UpgradeArbiterApplications: pre-flight ===");
        console.log("Diamond:                     ", diamond);
        console.log("Owner:                       ", currentOwner);
        console.log("Facets BEFORE cut:           ", facetsBefore);
        console.log("Routed selectors BEFORE cut: ", selectorsBefore);
        console.log("Add (all new, no Replace, no Remove):", addSels.length);
        console.log("");

        // Three readings of the arbiter namespace, taken before and after. A
        // cut must not write into anybody's storage, and this namespace is the
        // one the new facet shares.
        StorageSnapshot memory before = snapshotArbiterStorage(diamond);
        console.log("Arbiter storage BEFORE cut - arbiters:", before.arbiterCount);
        console.log("  vaultBalance:", before.vaultBalance);
        console.log("  chiefArbiter:", before.chiefArbiter);
        console.log("");

        // ── The cut ────────────────────────────────────────────────────────
        vm.startBroadcast(pk);
        ArbiterApplicationsFacet applicationsFacet = new ArbiterApplicationsFacet();
        IDiamondCut(diamond).diamondCut(
            buildCuts(address(applicationsFacet)),
            address(0),
            ""
        );
        vm.stopBroadcast();

        console.log("New ArbiterApplicationsFacet:", address(applicationsFacet));
        console.log("");

        // ── Post-flight: read the result back, do not assume it ────────────
        console.log("=== Post-flight ===");
        assertRouted(addSels, address(applicationsFacet), diamond);
        console.log("All eleven selectors land on the new facet.");

        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(applicationsFacet)).length
                == addSels.length,
            "post-flight: the new facet holds a different number of selectors than were added"
        );

        assertApplicationWindowAnswers(diamond);
        console.log("Smoke getApplicationWindow() through the diamond returned 7 days.");

        StorageSnapshot memory afterCut = snapshotArbiterStorage(diamond);
        assertStorageContinuity(before, afterCut);
        console.log("Storage continuity OK: arbiters / vaultBalance / chiefArbiter unchanged.");

        uint256 selectorsAfter = totalRoutedSelectors(diamond);
        uint256 facetsAfter    = IDiamondLoupe(diamond).facetAddresses().length;
        require(
            selectorsAfter == selectorsBefore + addSels.length,
            "post-flight: the routed-selector count did not move by exactly +Add"
        );
        require(
            facetsAfter == facetsBefore + 1,
            "post-flight: the facet count did not grow by exactly one"
        );
        console.log("Facets AFTER cut:            ", facetsAfter);
        console.log("Routed selectors AFTER cut:  ", selectorsAfter);
        console.log("");

        console.log("The door into the corps is open until the DAO closes it.");
        console.log("");
        console.log("Rollback (removes the eleven selectors again; the facet is left on chain,");
        console.log("unreferenced and harmless - a diamond routes nothing to an unmounted address):");
        console.log("  forge script script/UpgradeArbiterApplications.s.sol \\");
        console.log("    --sig \"rollback()\" --rpc-url $BASE_SEPOLIA_RPC_URL \\");
        console.log("    --private-key $PRIVATE_KEY --broadcast");
        console.log("");
        console.log("  or, by hand, one diamondCut with a single Remove element:");
        console.log("  cast send <diamond> \\");
        console.log("    \"diamondCut((address,uint8,bytes4[])[],address,bytes)\" \\");
        console.log("    \"[(0x0000000000000000000000000000000000000000,2,[<the 11 selectors>])]\" \\");
        console.log("    0x0000000000000000000000000000000000000000 0x \\");
        console.log("    --private-key $PRIVATE_KEY --rpc-url $BASE_SEPOLIA_RPC_URL");
        console.log("  <diamond> =", diamond);
        _printSelectors(addSels);
    }

    /// Undo, as a command rather than as a paragraph somebody has to
    /// transcribe. Removes exactly the eleven selectors this script added, and
    /// refuses if the chain is not in the state that follows this cut — a
    /// rollback that runs against an unexpected diamond is how one mistake
    /// becomes two.
    function rollback() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        require(diamond != address(0), "rollback: DIAMOND_ADDRESS is zero");

        bytes4[] memory sels = addSelectors();
        address host = IDiamondLoupe(diamond).facetAddress(sels[0]);
        require(host != address(0), "rollback: nothing to remove - the cut was not applied here");
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == host,
                "rollback: the eleven selectors are not all on one facet - the chain is not in the post-cut state"
            );
        }

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, sels);

        vm.startBroadcast(pk);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == address(0),
                "rollback: a selector is still routed after the Remove"
            );
        }
        console.log("Rolled back: the eleven application selectors route nowhere.");
        console.log("The facet contract is still on chain at:", host);
    }

    // ════════════════════════════════════════════════════════════════════
    // CHECKS — public so test/ArbiterApplicationsUpgrade.t.sol can call them
    // against a locally built diamond, not only through run() on a live chain.
    // ════════════════════════════════════════════════════════════════════

    /// The hand-written Add list against solc's `methodIdentifiers`. Set
    /// equality, not a count: a count agrees on a swap.
    function assertAddListCoversTheWholeFacet(bytes4[] memory sels) public view {
        bytes4[] memory fromArtifact = artifactSelectors();
        require(
            sels.length == fromArtifact.length,
            "pre-flight: the Add list and the compiled facet disagree on how many functions it has"
        );
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            bool found;
            for (uint256 j = 0; j < sels.length; j++) {
                if (fromArtifact[i] == sels[j]) { found = true; break; }
            }
            require(found, "pre-flight: the facet implements a function this cut does not mount");
        }
        for (uint256 i = 0; i < sels.length; i++) {
            bool found;
            for (uint256 j = 0; j < fromArtifact.length; j++) {
                if (sels[i] == fromArtifact[j]) { found = true; break; }
            }
            require(found, "pre-flight: this cut mounts a selector the facet does not implement");
        }
    }

    /// solc's own answer to "what does this facet expose", straight out of the
    /// build artifact. `methodIdentifiers` maps the signature to the four-byte
    /// selector as text, so nothing has to be hashed here.
    function artifactSelectors() public view returns (bytes4[] memory out) {
        string memory json = vm.readFile(ARTIFACT_PATH);
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i = 0; i < sigs.length; i++) {
            out[i] = bytes4(keccak256(bytes(sigs[i])));
        }
    }

    /// Not one of them may be mounted anywhere in the diamond today.
    function assertAllUnmounted(bytes4[] memory sels, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == address(0),
                "pre-flight: a selector from Add is already mounted - Add would revert and drop the whole cut"
            );
        }
    }

    function assertRouted(bytes4[] memory sels, address expected, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                "post-flight: a selector did not land on the new facet"
            );
        }
    }

    /// Functional smoke: the call goes THROUGH the diamond, is routed, executes,
    /// and returns exactly seven days.
    ///
    /// The value is compared, not merely the fact of a return: the window is
    /// declared in the contract and nowhere else, the front reads it off the
    /// chain and shows a person "your application runs this long". A diamond
    /// answering a different number looks healthy from the loupe and promises
    /// something untrue.
    function assertApplicationWindowAnswers(address diamond) public view {
        require(
            IApplicationWindowProbe(diamond).getApplicationWindow() == EXPECTED_APPLICATION_WINDOW,
            "post-flight: the application window does not answer 7 days through the diamond"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Storage continuity
    // ════════════════════════════════════════════════════════════════════

    struct StorageSnapshot {
        uint256 arbiterCount;
        uint256 vaultBalance;
        address chiefArbiter;
    }

    /// Three reads of EXISTING fields of the arbiter namespace, through the
    /// diamond. This cut appends two fields to the end of the same struct, and
    /// appending is the only legal evolution — if anything above them moved,
    /// these three would move with it.
    function snapshotArbiterStorage(address diamond) public view returns (StorageSnapshot memory s) {
        ArbiterRegistryFacet f = ArbiterRegistryFacet(diamond);
        s.arbiterCount = f.getArbiters().length;
        s.vaultBalance = f.getVaultBalance();
        s.chiefArbiter = f.getChiefArbiter();
    }

    function assertStorageContinuity(StorageSnapshot memory beforeCut, StorageSnapshot memory afterCut)
        public pure
    {
        require(
            afterCut.arbiterCount == beforeCut.arbiterCount,
            "post-flight: getArbiters().length changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.vaultBalance == beforeCut.vaultBalance,
            "post-flight: getVaultBalance() changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.chiefArbiter == beforeCut.chiefArbiter,
            "post-flight: getChiefArbiter() changed across the cut - the layout may have shifted"
        );
    }

    function totalRoutedSelectors(address diamond) public view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(diamond).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    // ════════════════════════════════════════════════════════════════════
    // THE CUT
    // ════════════════════════════════════════════════════════════════════

    /// ONE element, and that is the whole design of this upgrade. Nothing is
    /// replaced, so there is no `Replace`/`Add` pair to get wrong; nothing is
    /// removed, so no live selector goes dark.
    function buildCuts(address applicationsFacet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            applicationsFacet,
            IDiamondCut.FacetCutAction.Add,
            addSelectors()
        );
    }

    /// Eleven selectors, taken from the type rather than typed as literals: a
    /// signature change is then picked up by the compiler instead of by whoever
    /// presses the button. Held against the build artifact in
    /// `assertAddListCoversTheWholeFacet` and against the live chain in
    /// `assertAllUnmounted`.
    function addSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](11);

        // The applicant's own doors — both gasless (ERC-2771). Whoever is worth
        // seating has a record of deals, not necessarily a balance of ETH.
        sels[0] = ArbiterApplicationsFacet.applyForArbiterSeat.selector;
        sels[1] = ArbiterApplicationsFacet.withdrawArbiterApplication.selector;

        // The decision doors — owner, or the chief until governance is live.
        // The bond is taken HERE, at approval, not at submission: the decision
        // is made by a person by hand, and an unanswered application would
        // otherwise leave somebody else's money standing with the protocol.
        sels[2] = ArbiterApplicationsFacet.approveArbiterApplication.selector;
        sels[3] = ArbiterApplicationsFacet.rejectArbiterApplication.selector;

        // Reads. `getArbiterApplication` folds expiry into its answer — expiry
        // has no event, deliberately, because no transaction exists that would
        // emit one, so a reader that did not compute it would show a dead
        // application as live for ever.
        sels[4]  = ArbiterApplicationsFacet.getArbiterApplication.selector;
        sels[5]  = ArbiterApplicationsFacet.getApplicationWindow.selector;
        sels[6]  = ArbiterApplicationsFacet.getApplicationRequirements.selector;
        sels[7]  = ArbiterApplicationsFacet.isManualAdmissionOpen.selector;
        sels[8]  = ArbiterApplicationsFacet.getApplicants.selector;
        sels[9]  = ArbiterApplicationsFacet.getApplicantCount.selector;
        sels[10] = ArbiterApplicationsFacet.getApplicantsPage.selector;
    }

    // ════════════════════════════════════════════════════════════════════

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

    function _printSelectors(bytes4[] memory sels) internal pure {
        console.log("  the 11 selectors:");
        for (uint256 i = 0; i < sels.length; i++) {
            console.logBytes4(sels[i]);
        }
    }
}
