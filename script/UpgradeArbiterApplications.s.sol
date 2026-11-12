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
//     --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterApplicationsFacet} from "../src/facets/ArbiterApplicationsFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

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

    // ════════════════════════════════════════════════════════════════════
    //  THE FIVE DOORS THE FACET GAINED AFTER THIS ADD LIST WAS SIGNED
    //
    //  Not doors this cut mounts -- those come from the type, in
    //  `addSelectors()`, so a renamed signature is caught by the compiler.
    //  These five are the growth ALLOWANCE used by
    //  `assertAddListCoversTheWholeFacet`: the compiled facet implements them,
    //  this landed cut's Add list does not, and the Add list is the record of
    //  what went on chain and is not rewritten. Why each one is here is
    //  written out at the allowance itself.
    //
    //  ⚠️ BY THEIR BYTES AND NOT THROUGH `.selector`, for the reason spelt out
    //  at the allowance: a `.selector` follows a rename and would keep this
    //  exception green through a signature change.
    //
    //  ⚠️ AND EACH IS SPELT TWICE -- the four bytes, and the signature text
    //  they must be the keccak of. The two are compared in Solidity by
    //  `assertTheGrowthAllowanceIsSpeltTheSameTwice()` and again, with no
    //  compiler at all, by script/check-cut-selector-literals.sh over the text
    //  of this file. Neither side is derived from the other: both are things a
    //  person wrote. Taken from `cast sig` on 10 November 2026 and each
    //  signature read back against its declaration in
    //  src/facets/ArbiterApplicationsFacet.sol.
    // ════════════════════════════════════════════════════════════════════

    bytes4 internal constant GAINED_SINCE_SIGNED_ACCEPT = 0x592cb55c;
    string internal constant GAINED_SINCE_SIGNED_ACCEPT_TEXT =
        "acceptArbiterInvitation()";

    bytes4 internal constant GAINED_SINCE_SIGNED_ACCEPT_PERMIT = 0x237d29f6;
    string internal constant GAINED_SINCE_SIGNED_ACCEPT_PERMIT_TEXT =
        "acceptArbiterInvitationWithPermit(uint256,uint8,bytes32,bytes32)";

    bytes4 internal constant GAINED_SINCE_SIGNED_READ_INVITATION = 0x49fe0690;
    string internal constant GAINED_SINCE_SIGNED_READ_INVITATION_TEXT =
        "getArbiterInvitation(address)";

    bytes4 internal constant GAINED_SINCE_SIGNED_APPLY_PERMIT = 0x205d501d;
    string internal constant GAINED_SINCE_SIGNED_APPLY_PERMIT_TEXT =
        "applyAsArbiterWithPermit(uint256,uint8,bytes32,bytes32)";

    bytes4 internal constant GAINED_SINCE_SIGNED_REVOKE_INVITATION = 0x2693a9d5;
    string internal constant GAINED_SINCE_SIGNED_REVOKE_INVITATION_TEXT =
        "revokeArbiterInvitation(address)";

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeArbiterApplications.s.sol";
    }

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        // The signer comes from the command line (--account / --private-key), never
        // from the environment. Foundry fills msg.sender from --sender and derives it
        // from --private-key; with no wallet named at all it stays forge-std's
        // DEFAULT_SENDER, which is how a dry run identifies itself below.
        address broadcaster = msg.sender;

        // ── Pre-flight: everything checkable before a wei is spent ─────────
        require(diamond != address(0), "upgrade: DIAMOND_ADDRESS is zero");
        require(diamond.code.length > 0, "upgrade: DIAMOND_ADDRESS has no code");

        // Code is not enough. TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT
        // live in the same .env and all three have code, so a typo would sail
        // through the check above. Probe a selector only this diamond answers.
        address currentOwner = _readAddress(diamond, "owner()");
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
                "upgrade: the signer is not the diamond owner - diamondCut would revert after a paid deploy"
            );
        }

        // The five handwritten literals of the growth allowance against each
        // other, before anything downstream believes them. Costs no chain read
        // and no environment, so it stands here rather than after the loupe.
        assertTheGrowthAllowanceIsSpeltTheSameTwice();

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
        vm.startBroadcast();
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
        console.log("    --account deployer --sender $OWNER --broadcast");
        console.log("");
        console.log("  or, by hand, one diamondCut with a single Remove element:");
        console.log("  cast send <diamond> \\");
        console.log("    \"diamondCut((address,uint8,bytes4[])[],address,bytes)\" \\");
        console.log("    \"[(0x0000000000000000000000000000000000000000,2,[<the 11 selectors>])]\" \\");
        console.log("    0x0000000000000000000000000000000000000000 0x \\");
        console.log("    --account deployer --sender $OWNER --rpc-url $BASE_SEPOLIA_RPC_URL");
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

        vm.startBroadcast();
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

    /// ⚠️ EVERY HANDWRITTEN FOUR BYTES OF THE GROWTH ALLOWANCE AGAINST THE
    /// SIGNATURE IT CLAIMS TO BE.
    ///
    /// The one check in this file whose expected value comes from neither the
    /// chain nor the build artifact: keccak of a text a person wrote, against
    /// four bytes the same person wrote somewhere else. What it catches is a
    /// copy-paste, and a copy-paste here is the failure that looks most like a
    /// measurement -- wrong four bytes write off as "gained" a door the facet
    /// never gained, which both hides a door the cut forgot to mount and lets
    /// the allowance cover a hole in this very cut.
    ///
    /// Public and `pure` so a stand can drive it with no chain and no
    /// environment. The same comparison over the TEXT of this file, with no
    /// compiler at all, is script/check-cut-selector-literals.sh.
    function assertTheGrowthAllowanceIsSpeltTheSameTwice() public pure {
        require(
            bytes4(keccak256(bytes(GAINED_SINCE_SIGNED_ACCEPT_TEXT))) == GAINED_SINCE_SIGNED_ACCEPT,
            "upgrade: GAINED_SINCE_SIGNED_ACCEPT is not the keccak of its text"
        );
        require(
            bytes4(keccak256(bytes(GAINED_SINCE_SIGNED_ACCEPT_PERMIT_TEXT))) == GAINED_SINCE_SIGNED_ACCEPT_PERMIT,
            "upgrade: GAINED_SINCE_SIGNED_ACCEPT_PERMIT is not the keccak of its text"
        );
        require(
            bytes4(keccak256(bytes(GAINED_SINCE_SIGNED_READ_INVITATION_TEXT))) == GAINED_SINCE_SIGNED_READ_INVITATION,
            "upgrade: GAINED_SINCE_SIGNED_READ_INVITATION is not the keccak of its text"
        );
        require(
            bytes4(keccak256(bytes(GAINED_SINCE_SIGNED_APPLY_PERMIT_TEXT))) == GAINED_SINCE_SIGNED_APPLY_PERMIT,
            "upgrade: GAINED_SINCE_SIGNED_APPLY_PERMIT is not the keccak of its text"
        );
        require(
            bytes4(keccak256(bytes(GAINED_SINCE_SIGNED_REVOKE_INVITATION_TEXT))) == GAINED_SINCE_SIGNED_REVOKE_INVITATION,
            "upgrade: GAINED_SINCE_SIGNED_REVOKE_INVITATION is not the keccak of its text"
        );
    }

    /// The hand-written Add list against solc's `methodIdentifiers`. Set
    /// equality, not a count: a count agrees on a swap.
    ///
    /// ⚠️ WITH ONE EXCEPTION SINCE 22 SEPTEMBER 2026, AND IT IS NAMED RATHER
    /// THAN COUNTED. Three doors this cut mounted — `applyForArbiterSeat`,
    /// `approveArbiterApplication`, `rejectArbiterApplication` — were removed
    /// from the facet by the owner's decision, and this script is the RECORD of a
    /// cut that put them on the chain. It is not rewritten: the list says what
    /// went on chain that day, and it still does.
    ///
    /// So the equality becomes: the compiled facet is a SUBSET of the Add list,
    /// and what the list has over it is EXACTLY those three, by selector. A
    /// fourth would go red, and so would one of the three coming back into the
    /// facet without leaving this exception.
    function assertAddListCoversTheWholeFacet(bytes4[] memory sels) public view {
        bytes4[] memory fromArtifact = artifactSelectors();
        bytes4[3] memory sinceRemoved = [
            bytes4(0x6fb78a56), // applyForArbiterSeat()
            bytes4(0xbcd90be1), // approveArbiterApplication(address)
            bytes4(0x8e7e21be)  // rejectArbiterApplication(address,string)
        ];

        // ⚠️ AND THE MIRROR OF THAT EXCEPTION SINCE 8 NOVEMBER 2026: FIVE
        // DOORS THE FACET HAS GAINED. Three of them come from the owner's
        // entry-bond decision that morning.
        // `addArbiter` stopped seating anybody, so the seat is taken by the man
        // who was invited, through his own call:
        //
        //   · acceptArbiterInvitation()                                     and
        //   · acceptArbiterInvitationWithPermit(uint256,uint8,bytes32,bytes32)
        //     -- the two doors an invited man answers through, the second
        //     carrying the bond's allowance in on a signature because an
        //     `approve` is a transaction sent TO USDC, which has never heard of
        //     our forwarder;
        //   · getArbiterInvitation(address) -- everything about one standing
        //     invitation, which a form needs the moment the press stopped being
        //     the seating.
        //
        // ⚠️ AND TWO MORE THE SAME EVENING, FOR ROOM AND NOT FOR MEANING.
        // `applyAsArbiterWithPermit(uint256,uint8,bytes32,bytes32)` and
        // `revokeArbiterInvitation(address)` were compiled on
        // ArbiterRegistryFacet that morning and moved here that evening: the
        // registry stood 3 716 bytes under EIP-170 where the appeal split of
        // 15 October had bought it 4 937, and
        // test/AppealFacetSplitCut.t.sol::test_BothFacetsFitUnderEip170 said so
        // by name. The move cost nothing on chain, because the cut that mounts
        // the five is not signed yet. Their SELECTORS did not change -- a
        // selector is the signature, not the facet -- so what this allowance
        // records is that the compiled facet implements two more functions than
        // the Add list this script signed, exactly like the three above.
        //
        // `script/DeployFull.s.sol` fills `sels[13..17]` with the five, and the
        // compiled facet reads eighteen methodIdentifiers against the thirteen
        // of 22 September. This script is the RECORD of a cut that went on
        // chain and its Add list is not rewritten; what moved is the compiled
        // facet, so the difference is carried here.
        //
        // ⚠️ BY THEIR BYTES AND NOT BY `.selector`, although all five exist in
        // this checkout. A `.selector` follows a rename and would keep this
        // allowance green through a signature change; four bytes out of
        // `cast sig`, written by a person, do not move. Held honest in both
        // directions below: each must really be in the compiled facet, and none
        // may be in this cut's Add list.
        //
        // ⚠️ AND THE TERM IS ADDED TO THE CUT'S SIDE HERE, WHILE THE SIBLING
        // SCRIPTS NEED NO SUCH TERM AT ALL. It depends on who hands the lists
        // in. This check has exactly one shape of caller -- `run()` and
        // test/ArbiterApplicationsUpgrade.t.sol both pass `addSelectors()`,
        // the signed record, with nothing concated onto it -- so the term
        // belongs on the cut's side. `UpgradeAppealDepositSoftRefund`,
        // `UpgradeDisputeVaultDiscount` and `UpgradeGovernanceHandover` were
        // given the same allowance on 8 November and it was taken back out
        // again: every one of THEIR callers hands in a side the stand has
        // already filtered, so the term was a no-op there and their stands'
        // own growth lists are the whole fix. Measured both ways rather than
        // reasoned: with the allowance removed, this file's two pre-flight
        // tests red and theirs do not.
        //
        // ⚠️ AND EACH OF THE FIVE IS SPELT TWICE, at the top of this file: the
        // four bytes, and the signature text they must be the keccak of. Until
        // 10 November 2026 they were anonymous array slots whose only signature
        // was a trailing comment -- and two trailing comments in THIS file are
        // known to disagree with the literal beside them, so a comment is not a
        // second spelling of anything. The pair is compared in Solidity by
        // `assertTheGrowthAllowanceIsSpeltTheSameTwice()`, called from `run()`
        // before this allowance is believed, and over the text of this file by
        // script/check-cut-selector-literals.sh, which needs no compiler and so
        // can run before a rehearsal rather than during one.
        bytes4[5] memory sinceAdded = [
            GAINED_SINCE_SIGNED_ACCEPT,
            GAINED_SINCE_SIGNED_ACCEPT_PERMIT,
            GAINED_SINCE_SIGNED_READ_INVITATION,
            GAINED_SINCE_SIGNED_APPLY_PERMIT,      // moved from the registry 8 Nov 2026
            GAINED_SINCE_SIGNED_REVOKE_INVITATION  // moved from the registry 8 Nov 2026
        ];

        require(
            sels.length + sinceAdded.length == fromArtifact.length + sinceRemoved.length,
            "pre-flight: the Add list and the compiled facet disagree on how many functions it has"
        );
        // Each door written off as gained really is in the compiled facet, and
        // none of them is in this cut's own list -- so the allowance can
        // neither go stale nor cover a hole in this very cut.
        for (uint256 i = 0; i < sinceAdded.length; i++) {
            bool present;
            for (uint256 j = 0; j < fromArtifact.length; j++) {
                if (sinceAdded[i] == fromArtifact[j]) { present = true; break; }
            }
            require(
                present,
                "pre-flight: a door written off as gained since this cut is not in the compiled facet - delete the exception"
            );
            for (uint256 j = 0; j < sels.length; j++) {
                require(
                    sinceAdded[i] != sels[j],
                    "pre-flight: the growth allowance covers a selector this cut MOUNTS - it would hide a hole in this very cut"
                );
            }
        }
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            bool isGrowth;
            for (uint256 j = 0; j < sinceAdded.length; j++) {
                if (fromArtifact[i] == sinceAdded[j]) { isGrowth = true; break; }
            }
            if (isGrowth) continue;
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
            if (!found) {
                for (uint256 j = 0; j < sinceRemoved.length; j++) {
                    if (sels[i] == sinceRemoved[j]) { found = true; break; }
                }
                require(
                    found,
                    "pre-flight: this cut mounts a selector the facet does not implement and that is not one of the three doors removed on 22 September 2026"
                );
            }
        }
        // And each of the three really is gone from the facet, so the exception
        // cannot outlive what it excuses.
        for (uint256 i = 0; i < sinceRemoved.length; i++) {
            for (uint256 j = 0; j < fromArtifact.length; j++) {
                require(
                    fromArtifact[j] != sinceRemoved[i],
                    "pre-flight: a door written off as removed is implemented again - delete the exception"
                );
            }
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
        ArbiterVaultFacet f_v = ArbiterVaultFacet(diamond);
        s.arbiterCount = f_v.getArbiters().length;
        s.vaultBalance = f_v.getVaultBalance();
        s.chiefArbiter = f_v.getChiefArbiter();
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

    /// ⚠️ ELEVEN WHEN THIS SCRIPT RAN, FIFTEEN NOW (8 and 11 September 2026).
    /// The four added are `postArbiterBond`, `isArbiterActive`,
    /// `revokeUnprovenSeat` and `postArbiterBondWithPermit`. This list is grown
    /// rather than frozen at what the live chain received because the property
    /// it guards is "deploy a facet, mount ALL of it" — a fresh diamond must not
    /// get a facet with two dead functions. Re-running this against the live
    /// diamond is refused by `assertAllUnmounted` before any money is spent, so
    /// growing the list cannot turn into an `Add` on a mounted selector.
    /// The live diamond took the first two through UpgradeArbiterBondRequired,
    /// which is SIGNED AND LANDED — measured on Base Sepolia at block
    /// 46 673 445: the applications facet at 0xF0E6E994 routes thirteen
    /// selectors and `postArbiterBond()` is one of them. The last two are still
    /// pending and reach the chain through
    /// UpgradeUnprovenSeatRevocationAndBondPermit, which carries both of the
    /// 11 September decisions in one transaction.
    ///
    /// Selectors taken from the type rather than typed as literals: a
    /// signature change is then picked up by the compiler instead of by whoever
    /// presses the button. Held against the build artifact in
    /// `assertAddListCoversTheWholeFacet` and against the live chain in
    /// `assertAllUnmounted`.
    function addSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](16);

        // The applicant's own doors — both gasless (ERC-2771). Whoever is worth
        // seating has a record of deals, not necessarily a balance of ETH.
        sels[0] = bytes4(0x6fb78a56) /* applyForArbiterSeat(), removed from the facet 22 Sep 2026; this script is the record of a cut that mounted it */;
        sels[1] = ArbiterApplicationsFacet.withdrawArbiterApplication.selector;

        // The decision doors — owner, or the chief until governance is live.
        // The bond is taken HERE, at approval, not at submission: the decision
        // is made by a person by hand, and an unanswered application would
        // otherwise leave somebody else's money standing with the protocol.
        sels[2] = bytes4(0xbcd90be1) /* approveArbiterApplication(), removed from the facet 22 Sep 2026; this script is the record of a cut that mounted it */;
        sels[3] = bytes4(0x8e7e21be) /* rejectArbiterApplication(), removed from the facet 22 Sep 2026; this script is the record of a cut that mounted it */;

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

        // The bond a hand-seated arbiter posts for himself, and the read that
        // lets a form tell "you owe a bond" from "you are not an arbiter"
        // (8 September 2026). Unlike every other door here, `postArbiterBond`
        // is NOT retired by the DAO ratchet: a man seated by hand before the
        // handover must still be able to pay after it.
        sels[11] = ArbiterApplicationsFacet.postArbiterBond.selector;
        sels[12] = ArbiterApplicationsFacet.isArbiterActive.selector;

        // Taking back a granted seat that nothing has been earned in
        // (11 September 2026). Administrative, and retired by the same DAO
        // ratchet as the two decision doors: after the handover arbiters seat
        // themselves and removal belongs to the successor.
        sels[13] = ArbiterApplicationsFacet.revokeUnprovenSeat.selector;

        // The second bond door (11 September 2026): the same 50 USDC, carried
        // in on a signed EIP-2612 paper rather than on an allowance granted in
        // a transaction of its own. `approve` is sent to USDC, which does not
        // trust our forwarder, so the allowance step could never be relayed —
        // and the arbiter it is asked of has earned nothing in the protocol yet
        // to pay that gas with. Not retired by the DAO ratchet, for the same
        // reason `postArbiterBond` is not.
        sels[14] = ArbiterApplicationsFacet.postArbiterBondWithPermit.selector;

        // Where a seat's bond stands — unposted, sagging after a lost appeal, or
        // whole — and what a top-up would take (17 September 2026, the appeal
        // economics). The live diamond gets it through the appeal-economics
        // cut, not through this script.
        sels[15] = ArbiterApplicationsFacet.getBondState.selector;
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
        console.log("  the selectors:", sels.length);
        for (uint256 i = 0; i < sels.length; i++) {
            console.logBytes4(sels[i]);
        }
    }
}
