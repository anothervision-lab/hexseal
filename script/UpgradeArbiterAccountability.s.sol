// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {IDiamondCut, IDiamondLoupe, OwnershipFacet} from "../src/DiamondProxy.sol";
// The provenance-migration init contract lives in a file of its own rather than
// beside this one: `forge script <path>` refuses to choose between two contracts
// in one file ("Multiple contracts in the target path") and would demand an extra
// --tc flag from a human at the moment of signing. The rollout command has to be
// the very one written down in the report, with no variants.
import {ArbiterProvenanceInit} from "./ArbiterProvenanceInit.sol";

/// The same getSuspensionWindow(), but declared `view` rather than `pure`. In the
/// facet itself it is pure — there it really does nothing but return a constant.
/// THROUGH THE DIAMOND, however, that same call first looks the facet up in the
/// proxy's storage, that is, it reads state. The point of the smoke test is
/// precisely that lookup, so the type here is honest: `pure` would declare that no
/// routing takes place.
interface ISuspensionWindowProbe {
    function getSuspensionWindow() external view returns (uint256);
}

/**
 * ACCOUNTABILITY OF HAND-PICKED ARBITERS — a diamond cut.
 *
 * ONE diamondCut of FIVE actions:
 *   Replace 52 → the new ArbiterRegistryFacet       (everything routed today that
 *                                                    stays in the registry)
 *   Replace 11 → the new ArbiterAccountabilityFacet (the readers that moved there
 *                                                    in the split — they ARE
 *                                                    MOUNTED today, hence Replace)
 *   Add      3 → the same new ArbiterRegistryFacet  (new entrances that stayed in
 *                                                    the registry)
 *   Add     24 → ArbiterAccountabilityFacet         (the whole facet: 21 of its own
 *                                                    plus 3 relocated ones that are
 *                                                    not on chain yet)
 *   Remove   1 → address(0): removeArbiter(address), 0x3487e08c
 *
 * ⚠️ WHY FIVE ELEMENTS. Both Replace and Add travel to TWO DIFFERENT addresses,
 * and one FacetCut element carries exactly one address — so neither group can be a
 * single entry. Remove is the fifth reason for an element of its own: it requires
 * `facetAddress == address(0)` (DiamondCutLib.removeFunctions, "Diamond: remove
 * needs zero address"), so it cannot be mixed with anything in principle.
 *
 * ⚠️ UNLOADING THE REGISTRY. ArbiterRegistryFacet had run into the EIP-170
 * ceiling (24 516 of 24 576, 60 free), and the next piece of work physically did
 * not fit into it. Fourteen READERS moved into the accountability facet: the
 * registry 24 516 → 23 238 (1 338 to spare), accountability 4 500 → 6 327. The
 * registry's selectors went 69 → 55 and accountability's 17 → 31; THE DIAMOND'S
 * TOTAL SET OF SELECTORS DID NOT CHANGE — 86 before and 86 after, the same set
 * byte for byte. From outside the move is invisible: the same proxy address, the
 * same selector, the same answer.
 *
 * Eleven of the fourteen are mounted on chain today → Replace onto the new
 * address. Three (getSeatedBy, getSeatedCountBy, getCleanVerdicts) are not mounted
 * → they stay Add, merely in a different list. The total FOR THE SPLIT ITSELF did
 * not move: Add was 6+17=23 and became 3+20=23.
 *
 * ⚠️ That is a snapshot from 16 August, and Add has grown since — not from the
 * split but from four later pieces of work (see the paragraphs below). Today's
 * number is not here but in the five-line summary above: Add 3 + 24 = 27.
 *
 * ⚠️ THE CAUSE IN WORDS (17 August 2026). The accountability Add group went 20 →
 * 21: getMaxReasonBytes arrived, the ceiling on words in BYTES. (It grew three
 * more times after that, and all three additions are further down this header:
 * getRemovalDelay, 21 → 22; executeChainRemoval, 22 → 23; getOverturnedVerdicts,
 * 23 → 24. The total is 24, and that is what the summary above says.) The same
 * work changed the SIGNATURES of three entrances in this group
 * (removeArbiterForCause and proposeRemoval gained a `string reason`,
 * respondToRemoval a `string reply`), and that does NOT move them into Replace:
 * none of the three is mounted on chain, the cut has not been made. Only the VALUE
 * of the selector inside the Add group changed, and the compiler picked that up —
 * the lists below take `.selector` from the type. The literal signatures in the
 * ArbiterAccountabilityUpgrade suite are rewritten by hand: that is where the lock
 * stands that notices a change of signature (the chain says nothing about it,
 * because it does not have these selectors either before or after).
 *
 * ⚠️ THE MAIN RULE OF THE Replace/Add SPLIT, over which the cut is rejected AS A
 * WHOLE. `Replace` requires the selector to be mounted ALREADY
 * (DiamondCutLib.replaceFunctions → removeFunction → "Diamond: selector not
 * found"); `Add` requires THE OPPOSITE — that the selector not yet exist
 * ("Diamond: selector exists"). So the boundary between the lists is determined
 * NOT by what lies in the compiled ABI but by WHAT THE LIVE DIAMOND ROUTES RIGHT
 * NOW. The previous cut, UpgradePresentationRecord.s.sol, is built the same way —
 * 56 Replace and 8 Add on one and the same facet.
 *
 * The lists are declared by hand (otherwise a test could not check them) but are
 * NOT taken on trust: the pre-flight compares each of the three against the live
 * chain through the loupe, and the ArbiterAccountabilityUpgrade suite compares
 * them against the compiled ABI of both facets. An error in a list has to come out
 * BEFORE the broadcast, not in a production transaction.
 *
 * The chain's state on 15 August 2026 (checked by reading, not from memory):
 *   mounted in total                 177 selectors, 11 facets
 *   ArbiterRegistryFacet             0x1CF4c7DaA27f2241eafd8E818329719418403013, 64 selectors
 *   arbiters                         1 (0x42dCd14e…), vault 6 000 000, floor 10 000 000
 * After the cut: 177 + 27 − 1 = 203 selectors, 12 facets — where 27 is Add 3 +
 * Add 24 and 1 is the Remove. The split did NOT move that number: it shifted
 * selectors between facets without adding or removing any.
 *
 * ⚠️ "177 + 24 − 1 = 200" used to stand here, from an Add group of 21 selectors,
 * and then "177 + 26 − 1 = 202", from a group of 23. The number goes stale in
 * silence every time a piece of work appends a selector to the LIST (the lines
 * below and the test on them) and leaves the summary above alone: that happened
 * twice already and nearly happened a third time. The post-flight does not suffer
 * from it — it COUNTS rather than comparing against a literal — but a human
 * reading the header before signing and checking "and now it is this many"
 * afterwards would be wrong on a production transaction. The summary has to be
 * recomputed AS A WHOLE together with the list, not only on the line its author is
 * editing.
 * The old address is still emptied exactly: 63 Replace (52 + 11) plus 1 Remove —
 * the very 64 that sit on it today, and a cut of this kind does not move that
 * number: Add travels to NEW addresses.
 *
 * ── What exactly arrives ─────────────────────────────────────────────────
 * seating provenance           getSeatedBy / getSeatedCountBy
 * the chief's bloc ceiling     getChiefBloc
 * the per-arbiter dispute cap  getMaxClaimsPerArbiter
 * judging service              getCleanVerdicts, getMaxArbiterMistakes
 * the other half of the ratio  getOverturnedVerdicts
 * and the whole ArbiterAccountabilityFacet: suspension, removal for cause, the
 *             chief's proposal, the right of reply of THE ACCUSED (since
 *             19 August 2026 a reply is accepted during the 48-hour pause as well,
 *             not only after a removal), and an arbiter's standing.
 * the bare removeArbiter was withdrawn   ← the single Remove of this cut
 *
 * ── Why one cut and not four calls ───────────────────────────────────────
 * Between the actions the diamond must not end up in a state of "new code, no
 * entrances" or, worse, "the bare removeArbiter is still alive while removal for
 * cause is already advertised by the client". One transaction — one state before
 * and one after.
 *
 * ── Pre/post-flight ──────────────────────────────────────────────────────
 * The form comes from UpgradePresentationRecord.s.sol (15 August 2026). A Replace
 * onto an address that does not have the required selector does NOT revert:
 * DiamondCutLib checks only "the address is different and has code", not "does it
 * implement this selector". That is a silent drift of the "mounted but does not
 * work" kind — exactly the class that already broke fundDispute by reading
 * msg.sender instead of _msgSender(): deployed, never once fired, noticed a month
 * later. So:
 *   BEFORE the broadcast — the whole Replace group aims at ONE really mounted
 *                   address; not one Add selector is mounted; removeArbiter IS
 *                   mounted (otherwise there is nothing to remove and the cut is
 *                   no longer the one that was written);
 *   AFTER           — Replace/Add landed on their new addresses, the old address
 *                   is empty, the selector count moved by exactly +Add−Remove,
 *                   THE BARE removeArbiter IS DEAD (a low-level call through the
 *                   diamond must not get through), and the suspension answers
 *                   through the diamond with EXACTLY 72 hours — the value is
 *                   compared, not the fact of a return: the window is declared in
 *                   the contract and only there, the client takes it from the
 *                   chain and draws a person "this long it holds".
 *
 * ── Storage continuity ───────────────────────────────────────────────────
 * Everything listed checks ROUTING and reads not one value already lying in the
 * arbiter namespace. That is the very class that broke JobBoard in July 2026:
 * getOpenJobs() began reverting Panic(0x22) on live storage after a layout change,
 * and the static gates did not see it. This branch appended TWELVE fields to the
 * end of ArbiterRegistryStorage.Data — precisely the kind of edit that gives rise
 * to that class. Count them like this (the number will go stale with the next
 * piece of work, the method will not): everything declared AFTER
 * `presentationDigests`, the last field that has lived on chain since the cut of
 * 15 August. Today that is seatedBy, seatedCountBy, suspendedUntil, cleanVerdicts,
 * removalProposals, removalReply, removedAt, removalCount, lastRemovalAt,
 * lastRemovalCause, chainProposalPath, overturnedVerdicts.
 *
 * ⚠️ "Tasks 1, 4, 5, 7 and 8 appended SIX fields" used to stand here — a snapshot
 * from 16 August that outlived four more pieces of work. A list of task names in
 * such a sentence goes stale faster than the number, so it is no longer here. Hence
 * getArbiters().length, getVaultBalance() and getArbiterFloor() are read BEFORE
 * vm.startBroadcast and again AFTER, with a require on equality.
 *
 * ── Provenance migration — A SEPARATE TRANSACTION AFTER THE CUT ──────────
 * There is one arbiter on chain, seated by the owner's hand, but their "who seated
 * them" field is empty: the field did not exist at the moment of the seating. An
 * empty seatedBy reads as "they enrolled themselves through applyAsArbiter" (see
 * the getter in ArbiterRegistryFacet) — that is, the chain tells an untruth about
 * a person, and on top of that the chief's bloc ceiling (_chiefBloc) counts them
 * wrongly. The backfill goes in a SECOND transaction rather than inside the cut,
 * for one reason: the cut must be reversible on its own. Reverting the cut is a
 * diamondCut back onto the old addresses; if the backfill travelled as the init
 * calldata of that same cut, reverting the routes would not revert the written
 * data, and "put it back as it was" would stop being one action.
 *
 * The list of arbiters is read FROM THE CHAIN (getArbiters()) rather than wired
 * into the script: a wired address is a claim about the composition of the corps,
 * made at the moment the script was written and re-checked by nobody at the moment
 * it runs.
 */
contract UpgradeArbiterAccountability is Script {
    /// The suspension window is 72 hours (approved by the owner on 15 August 2026).
    /// Declared in ArbiterAccountabilityFacet; here it is only checked.
    uint256 internal constant EXPECTED_SUSPENSION_WINDOW = 72 hours;

    /// removeArbiter(address) was deleted from the facet on 15 August 2026, so there
    /// is no longer a `.selector` symbol for it and the selector is written as a
    /// literal. The same value in the same words stands in fourteen archived
    /// scripts: `cast sig "removeArbiter(address)"` = 0x3487e08c. The test computes
    /// it independently, from the keccak of the signature — comparing a literal
    /// against a literal would be a tautology.
    bytes4 internal constant REMOVE_ARBITER_SELECTOR = bytes4(0x3487e08c);

    /// The target address of the post-flight check "the bare button is dead". Any
    /// non-zero one: before the cut the call would reach the facet and fail on an
    /// application check; after the cut it must find no route at all.
    address internal constant DEAD_BUTTON_PROBE = address(0xA1);

    /// The script's own name. It is needed NOT for the logs but so that the chain
    /// census can say WHO it was taken for.
    ///
    /// The trap this exists for is not "the census will go stale" but "somebody will
    /// take an OLD census for a NEW cut script". Such a person will write a second
    /// script and copy this one's bench; a literal string in the bench would be
    /// copied along with the rest and they would notice nothing. A value taken from
    /// THE SCRIPT UNDER TEST does not travel by copying: the new script has its own,
    /// while `forScript` in the census is the previous one, and the bench goes red
    /// deterministically and WITHOUT touching the network.
    ///
    /// The string must match the `forScript` field in
    /// test/fixtures/chain-2026-08-16-arbiter-selectors.json.
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeArbiterAccountability.s.sol";
    }

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        require(diamond != address(0), "DIAMOND_ADDRESS not set");

        bytes4[] memory replaceSels = replaceSelectors();
        bytes4[] memory addSels     = addSelectors();
        bytes4[] memory removeSels  = removeSelectors();

        // ── Pre-flight ────────────────────────────────────────────────────
        console.log("=== UpgradeArbiterAccountability: pre-flight ===");
        address oldFacet = checkReplaceGroup(replaceSels, diamond);
        checkAddGroupUnmounted(addSels, diamond);
        address removeHost = checkRemoveGroupMounted(removeSels, diamond);
        // The selector being removed must sit on THE SAME facet as the whole Replace
        // group. Otherwise Remove would quietly pull somebody else's selector off
        // SOMEBODY ELSE'S facet, and nothing would notice: the bare button is
        // honestly dead, the +Add-Remove count adds up, and
        // assertFacetHoldsNoSelectors asks only about the Replace group's host. The
        // cut would go through green and tear a piece off another facet along the
        // way. Found in review: before this line the invariant was PRINTED, that is,
        // it rested on a human comparing a string by eye.
        require(
            removeHost == oldFacet,
            "pre-flight: removeArbiter sits on a different facet from the Replace group"
        );
        console.log("Old ArbiterRegistryFacet currently mounted at:", oldFacet);
        console.log("Naked removeArbiter currently routed to the same facet:", removeHost);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        console.log("Total routed selectors BEFORE cut:", selectorsBefore);
        console.log("Replace / Add / Remove:", replaceSels.length, addSels.length, removeSels.length);

        StorageSnapshot memory before = snapshotArbiterStorage(diamond);
        console.log("Arbiter storage BEFORE cut - arbiters:", before.arbiterCount);
        console.log("  vaultBalance:", before.vaultBalance);
        console.log("  arbiterFloor:", before.arbiterFloor);
        console.log("");

        // ── The upgrade ───────────────────────────────────────────────────
        vm.startBroadcast();
        ArbiterRegistryFacet registryFacet = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet accountabilityFacet = new ArbiterAccountabilityFacet();
        IDiamondCut(diamond).diamondCut(
            buildCuts(address(registryFacet), address(accountabilityFacet)),
            address(0),
            ""
        );
        vm.stopBroadcast();

        console.log("New ArbiterRegistryFacet:", address(registryFacet));
        console.log("New ArbiterAccountabilityFacet:", address(accountabilityFacet));
        console.log("");

        // ── Post-flight: routes ───────────────────────────────────────────
        console.log("=== Post-flight ===");
        assertRouted(replaceRegistrySelectors(), address(registryFacet), diamond);
        assertRouted(replaceAccountabilitySelectors(), address(accountabilityFacet), diamond);
        assertRouted(addRegistrySelectors(), address(registryFacet), diamond);
        assertRouted(addAccountabilitySelectors(), address(accountabilityFacet), diamond);
        assertFacetHoldsNoSelectors(oldFacet, diamond);
        console.log("Replace/Add landed on the new facets, old facet emptied.");

        assertNakedRemoveArbiterIsDead(diamond);
        console.log("Naked removeArbiter(address) no longer routes anywhere.");

        assertSuspensionWindowAnswers(diamond);
        console.log("Smoke getSuspensionWindow() through diamond returned 72h.");

        // ── Post-flight: storage ──────────────────────────────────────────
        StorageSnapshot memory afterCut = snapshotArbiterStorage(diamond);
        assertStorageContinuity(before, afterCut);
        console.log("Arbiter storage AFTER cut  - arbiters:", afterCut.arbiterCount);
        console.log("  vaultBalance:", afterCut.vaultBalance);
        console.log("  arbiterFloor:", afterCut.arbiterFloor);
        console.log("Storage continuity OK: arbiters/vaultBalance/arbiterFloor unchanged by the cut.");

        uint256 selectorsAfter = totalRoutedSelectors(diamond);
        require(
            selectorsAfter == selectorsBefore + addSels.length - removeSels.length,
            "post-flight: the count of mounted selectors did not move by exactly +Add-Remove"
        );
        console.log("Total routed selectors AFTER cut:", selectorsAfter);
        console.log("");

        // ── Provenance migration — a SECOND transaction ───────────────────
        migrateProvenance(diamond);
    }

    // ════════════════════════════════════════════════════════════════════
    // PROVENANCE MIGRATION
    // ════════════════════════════════════════════════════════════════════

    /// An emergency entrance: the cut has landed but the second transaction did not
    /// arrive — it failed, ran out of gas, the session dropped. A repeated run() in
    /// that state will refuse at the pre-flight, and rightly so: the Add selectors
    /// are already mounted, and there is nothing and no reason to repeat the cut.
    /// This entrance does ONLY the migration:
    ///   forge script script/UpgradeArbiterAccountability.s.sol \
    ///     --sig "migrateProvenanceOnly()" --rpc-url $BASE_SEPOLIA_RPC_URL
    /// It is idempotent: if the provenance is already filled in, it prints "nothing
    /// to migrate" and sends not one transaction.
    function migrateProvenanceOnly() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        require(diamond != address(0), "DIAMOND_ADDRESS not set");
        migrateProvenance(diamond);
    }

    /// Fills in "who seated them" for the arbiters whose field is empty because the
    /// field did not exist at the moment they were seated.
    ///
    /// It is called AFTER the cut and cannot be called earlier: getSeatedBy is one of
    /// the Add selectors of this same cut, and before it the diamond answers such a
    /// call with "Diamond: function not found".
    ///
    /// A second broadcast, that is a SECOND transaction on chain, and deliberately so
    /// (see the file header: the cut must be reversible on its own).
    ///
    /// Whoever signs the backfill is who it is recorded as: the diamond's owner is
    /// the very hand that did the seating. The address is read from the chain
    /// (OwnershipFacet.owner()) rather than from whoever signs: the signer may turn
    /// out to be the wrong account, in which case diamondCut would refuse anyway —
    /// but somebody else's name must not be written on chain even in the attempt.
    function migrateProvenance(address diamond) public {
        console.log("=== Provenance migration (separate transaction) ===");

        address[] memory all = ArbiterRegistryFacet(diamond).getArbiters();
        console.log("Arbiters on chain:", all.length);

        address[] memory pending = arbitersMissingProvenance(diamond);
        console.log("Arbiters missing provenance:", pending.length);
        for (uint256 i = 0; i < pending.length; i++) {
            console.log("  no seatedBy:", pending[i]);
        }
        if (pending.length == 0) {
            console.log("Nothing to migrate - skipping the second transaction entirely.");
            return;
        }

        address seater = OwnershipFacet(diamond).owner();
        console.log("Backfilling seatedBy with the diamond owner:", seater);

        // ⚠️ A cast to ArbiterAccountabilityFacet rather than ArbiterRegistryFacet:
        // the provenance is now READ from there. The address is the same — it is the
        // diamond; the cast here only names the ABI the call is encoded by. The
        // provenance is still WRITTEN by the registry (addArbiter/clearSeat) and by
        // the migration init contract.
        uint256 seatedCountBefore = ArbiterAccountabilityFacet(diamond).getSeatedCountBy(seater);

        vm.startBroadcast();
        ArbiterProvenanceInit init = new ArbiterProvenanceInit();
        IDiamondCut(diamond).diamondCut(
            new IDiamondCut.FacetCut[](0), // not one route is touched
            address(init),
            abi.encodeCall(ArbiterProvenanceInit.backfillSeatedBy, (pending, seater))
        );
        vm.stopBroadcast();

        console.log("ArbiterProvenanceInit:", address(init));
        assertProvenanceMigrated(diamond, pending, seater, seatedCountBefore);
        console.log("Provenance migrated for", pending.length, "arbiter(s).");
    }

    /// The arbiters whose seatedBy is empty. An empty field means EITHER
    /// self-enrolment through applyAsArbiter OR a seating from before the field
    /// existed — the chain cannot tell them apart, and that is the whole problem.
    /// Today it applies to one arbiter, seated by hand (self-enrolment is locked
    /// until the DAO is switched on and has never once fired).
    ///
    /// ⚠️ It reads getSeatedBy — a selector mounted by this very cut. It must not be
    /// called before the cut.
    function arbitersMissingProvenance(address diamond) public view returns (address[] memory pending) {
        // The composition of the corps is read from the registry, the provenance from
        // the accountability facet. The address is one and the same — the diamond.
        address[] memory all = ArbiterRegistryFacet(diamond).getArbiters();
        ArbiterAccountabilityFacet f = ArbiterAccountabilityFacet(diamond);

        uint256 count;
        bool[] memory hit = new bool[](all.length);
        for (uint256 i = 0; i < all.length; i++) {
            if (f.getSeatedBy(all[i]) != address(0)) continue;
            hit[i] = true;
            count++;
        }

        pending = new address[](count);
        uint256 k;
        for (uint256 i = 0; i < all.length; i++) {
            if (hit[i]) pending[k++] = all[i];
        }
    }

    /// Checks the RESULT of the migration rather than the fact that the transaction
    /// went through: each migrated arbiter has precisely this address written for
    /// them, and the seating counter grew by exactly the number migrated. The second
    /// is not decorative — the chief's bloc ceiling rests on seatedCountBy, and a
    /// backfill that forgot to raise it would leave the chief an extra seat forever.
    function assertProvenanceMigrated(
        address diamond,
        address[] memory migrated,
        address seater,
        uint256 seatedCountBefore
    ) public view {
        ArbiterAccountabilityFacet f = ArbiterAccountabilityFacet(diamond);
        for (uint256 i = 0; i < migrated.length; i++) {
            require(
                f.getSeatedBy(migrated[i]) == seater,
                "post-migration: an arbiter's provenance was not recorded"
            );
        }
        require(
            f.getSeatedCountBy(seater) == seatedCountBefore + migrated.length,
            "post-migration: the seating counter did not grow by exactly the number migrated"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Pre/post-flight helpers — public so that the ArbiterAccountabilityUpgrade
    // suite can call them directly against a locally deployed diamond and not only
    // through run() on the live chain.
    // ════════════════════════════════════════════════════════════════════

    /// Every selector in the group is mounted now, and they all point at ONE and the
    /// same address — otherwise the Replace list was derived wrongly (the facet has
    /// already split across several addresses, and a Replace onto a single new
    /// address would be the wrong operation). Returns that address.
    function checkReplaceGroup(bytes4[] memory sels, address diamond)
        public view returns (address facetAddr)
    {
        require(sels.length > 0, "UpgradeArbiterAccountability: the Replace group is empty");
        facetAddr = IDiamondLoupe(diamond).facetAddress(sels[0]);
        require(facetAddr != address(0), "UpgradeArbiterAccountability: the first Replace selector is not mounted");
        for (uint256 i = 0; i < sels.length; i++) {
            address a = IDiamondLoupe(diamond).facetAddress(sels[i]);
            require(a != address(0), "UpgradeArbiterAccountability: one of the Replace selectors is not mounted");
            require(
                a == facetAddr,
                "UpgradeArbiterAccountability: the Replace selectors are spread across more than one live facet address"
            );
        }
    }

    /// Not one selector in the group is mounted yet — otherwise Add reverts "Diamond:
    /// selector exists" in DiamondCutLib.addFunctions and the whole rollout fails
    /// AFTER two new facets have been broadcast.
    function checkAddGroupUnmounted(bytes4[] memory sels, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == address(0),
                "UpgradeArbiterAccountability: an Add selector is already mounted somewhere, so Add will revert"
            );
        }
    }

    /// The selector being removed must be mounted — otherwise Remove reverts
    /// "Diamond: selector not found" (DiamondCutLib.removeFunction) and the whole cut
    /// is cancelled. A separate reason not to stay silent: if removeArbiter has
    /// already been taken off by somebody, the chain is not in the state this script
    /// was written for, and its other assumptions are worth re-checking by hand.
    /// Returns the address it sits on.
    function checkRemoveGroupMounted(bytes4[] memory sels, address diamond)
        public view returns (address facetAddr)
    {
        require(sels.length > 0, "UpgradeArbiterAccountability: the Remove group is empty");
        facetAddr = IDiamondLoupe(diamond).facetAddress(sels[0]);
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) != address(0),
                "UpgradeArbiterAccountability: the selector to be removed is not mounted, so there is nothing to remove"
            );
        }
    }

    /// Every selector in the group leads to the expected (new) facet address.
    function assertRouted(bytes4[] memory sels, address expected, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                "UpgradeArbiterAccountability: a selector did not land on the new facet"
            );
        }
    }

    /// The old facet address has not one selector left — it was displaced entirely
    /// rather than half split. Here it is also the only check that would notice a
    /// selector forgotten in Replace: 63 replaced plus one removed is exactly the 64
    /// that sit on it today.
    function assertFacetHoldsNoSelectors(address facetAddr, address diamond) public view {
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(facetAddr).length == 0,
            "UpgradeArbiterAccountability: the old facet address still holds selectors after the cut"
        );
    }

    /// The bare button must be dead. A low-level call THROUGH THE DIAMOND rather than
    /// a loupe read: the loupe answers from its own table, while what is checked here
    /// is what a person sees from the client or from a wallet — whether the call
    /// reaches any code at all. A refusal is expected and is the goal: the diamond's
    /// fallback reverts "Diamond: function not found".
    ///
    /// Why this is a separate check and not a consequence of the Remove: the Remove
    /// element could have been assembled with the wrong selector (a typo in the
    /// literal), and diamondCut would then have successfully deleted SOMEBODY ELSE'S
    /// selector while the bare button stayed alive — a removal with no cause, no
    /// record of who pressed it and a refund of the bond, which is exactly what this
    /// whole piece of work was done to eliminate.
    function assertNakedRemoveArbiterIsDead(address diamond) public {
        (bool ok, ) = diamond.call(
            abi.encodeWithSignature("removeArbiter(address)", DEAD_BUTTON_PROBE)
        );
        require(!ok, "post-flight: the bare removeArbiter is still routed after the cut");
    }

    /// A functional smoke test: getSuspensionWindow() THROUGH THE DIAMOND (not by a
    /// direct call to the facet) executes and returns EXACTLY 72 hours.
    ///
    /// The value is compared rather than the fact of a return: the window is declared
    /// in the contract and only there, the client asks the chain for it and draws a
    /// person "this long the suspension holds". A diamond answering a different number
    /// — because an Add landed on somebody else's address with a similar signature,
    /// say — looks healthy in routing terms while promising an untruth.
    function assertSuspensionWindowAnswers(address diamond) public view {
        require(
            ISuspensionWindowProbe(diamond).getSuspensionWindow() == EXPECTED_SUSPENSION_WINDOW,
            "post-flight: the suspension window does not answer through the diamond"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Storage continuity
    // ════════════════════════════════════════════════════════════════════

    struct StorageSnapshot {
        uint256 arbiterCount;
        uint256 vaultBalance;
        uint256 arbiterFloor;
    }

    /// Three reads of existing arbiter-namespace fields THROUGH THE DIAMOND.
    /// getArbiterFloor() returns DEFAULT_ARBITER_FLOOR when the field is zero (see
    /// the facet itself) — that is still a read of an existing field: if the layout
    /// shifts, the value jumps along with the rest.
    function snapshotArbiterStorage(address diamond) public view returns (StorageSnapshot memory s) {
        ArbiterRegistryFacet f = ArbiterRegistryFacet(diamond);
        s.arbiterCount = f.getArbiters().length;
        s.vaultBalance = f.getVaultBalance();
        s.arbiterFloor = f.getArbiterFloor();
    }

    /// The three values taken BEFORE and AFTER the cut must match literally —
    /// diamondCut must write nothing into somebody else's namespace. A divergence
    /// here is the same class of signal as Panic(0x22) on getOpenJobs() after the
    /// JobBoard layout change in July 2026.
    function assertStorageContinuity(StorageSnapshot memory beforeCut, StorageSnapshot memory afterCut)
        public pure
    {
        require(
            afterCut.arbiterCount == beforeCut.arbiterCount,
            "post-flight: getArbiters().length changed across the cut, so the layout may have shifted"
        );
        require(
            afterCut.vaultBalance == beforeCut.vaultBalance,
            "post-flight: getVaultBalance() changed across the cut, so the layout may have shifted"
        );
        require(
            afterCut.arbiterFloor == beforeCut.arbiterFloor,
            "post-flight: getArbiterFloor() changed across the cut, so the layout may have shifted"
        );
    }

    function totalRoutedSelectors(address diamond) public view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(diamond).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    // ════════════════════════════════════════════════════════════════════
    // THE COMPOSITION OF THE CUT
    // ════════════════════════════════════════════════════════════════════

    /// FIVE elements: Replace onto the registry, Replace onto accountability, Add onto
    /// the registry, Add onto accountability, and Remove last. Remove goes last so
    /// that no later action can bring the deleted selector back: diamondCut applies
    /// the elements in order.
    ///
    /// ⚠️ THE FIFTH ELEMENT APPEARED WITH THE SPLIT. Eleven readers moved from the
    /// registry into the accountability facet, and they ARE MOUNTED ON CHAIN TODAY —
    /// so the operation on them is still `Replace` (the selector exists in the
    /// diamond, only the address changes), but it aims at a DIFFERENT address from
    /// the other 52. One FacetCut element carries exactly one address, so Replace
    /// physically cannot stay a single entry — the very same reason Add had already
    /// been split in two.
    ///
    /// The price of an error in the split: `Add` reverts "Diamond: selector exists"
    /// on an already mounted one, `Replace` reverts "Diamond: selector not found" on
    /// an unmounted one. Either of the two takes the WHOLE cut down in a single
    /// production transaction. Each selector's kind is derived from this file's lists
    /// and checked by the pre-flight against the live chain.
    function buildCuts(address registryFacet, address accountabilityFacet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = _cut(registryFacet,       IDiamondCut.FacetCutAction.Replace, replaceRegistrySelectors());
        cuts[1] = _cut(accountabilityFacet, IDiamondCut.FacetCutAction.Replace, replaceAccountabilitySelectors());
        cuts[2] = _cut(registryFacet,       IDiamondCut.FacetCutAction.Add,     addRegistrySelectors());
        cuts[3] = _cut(accountabilityFacet, IDiamondCut.FacetCutAction.Add,     addAccountabilitySelectors());
        cuts[4] = _cut(address(0),          IDiamondCut.FacetCutAction.Remove,  removeSelectors());
    }

    /// EVERYTHING the live diamond routes TODAY except removeArbiter: 56 selectors
    /// from the deployment of 25 July plus 8 that arrived with the "chain as a witness
    /// to presentation" cut on 15 August, minus the bare removeArbiter (which goes
    /// into Remove). Completeness is checked by a test against the compiled ABI and by
    /// the pre-flight against the chain, not by eye.
    ///
    /// ⚠️ SPLIT INTO TWO HALVES, because they travel to DIFFERENT ADDRESSES. Eleven
    /// readers about an arbiter's behaviour moved into ArbiterAccountabilityFacet;
    /// they ARE MOUNTED ON CHAIN TODAY, so they stay `Replace` — only the facet
    /// address changes, not the presence of the selector. The temptation to move them
    /// into Add is lethal: `Add` reverts "Diamond: selector exists" on an already
    /// mounted one, and the WHOLE cut fails in a single production transaction.
    ///
    /// This common list stays, and stays SINGLE: the checkReplaceGroup pre-flight
    /// requires all its selectors to sit on ONE address, and today that is true of the
    /// union — both halves lie on the old ArbiterRegistryFacet. It is split only in
    /// buildCuts().
    function replaceSelectors() public pure returns (bytes4[] memory sels) {
        bytes4[] memory reg = replaceRegistrySelectors();
        bytes4[] memory acc = replaceAccountabilitySelectors();
        sels = new bytes4[](reg.length + acc.length);
        uint256 k;
        for (uint256 i = 0; i < reg.length; i++) sels[k++] = reg[i];
        for (uint256 i = 0; i < acc.length; i++) sels[k++] = acc[i];
    }

    /// The half of Replace that stays on the registry: the composition of the corps,
    /// disputes, verdicts, appeals, money.
    function replaceRegistrySelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](52);

        // DAO mode
        sels[0]  = ArbiterRegistryFacet.activateDAO.selector;
        sels[1]  = ArbiterRegistryFacet.applyAsArbiter.selector;
        sels[2]  = ArbiterRegistryFacet.resignAsArbiter.selector;

        // Admin: managing arbiters (removeArbiter is in removeSelectors(), not here)
        sels[3]  = ArbiterRegistryFacet.setChiefArbiter.selector;
        sels[4]  = ArbiterRegistryFacet.addArbiter.selector;

        // Claiming a dispute (commit-reveal)
        sels[5]  = ArbiterRegistryFacet.commitDisputeClaim.selector;
        sels[6]  = ArbiterRegistryFacet.claimDispute.selector;
        sels[7]  = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        sels[8]  = ArbiterRegistryFacet.clearDisputeClaim.selector;

        // The verdict
        sels[9]  = ArbiterRegistryFacet.submitVerdict.selector;
        sels[10] = ArbiterRegistryFacet.finalizeVerdict.selector;
        sels[11] = ArbiterRegistryFacet.overturnVerdict.selector;
        sels[12] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        sels[13] = ArbiterRegistryFacet.freezeVerdict.selector;
        sels[14] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        sels[15] = ArbiterRegistryFacet.clearStuckVerdict.selector;

        // The appeal
        sels[16] = ArbiterRegistryFacet.raiseAppeal.selector;
        sels[17] = ArbiterRegistryFacet.voteOnAppeal.selector;
        sels[18] = ArbiterRegistryFacet.resolveAppeal.selector;

        // Rewards
        sels[19] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        sels[20] = ArbiterRegistryFacet.fundVault.selector;
        sels[21] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        sels[22] = ArbiterRegistryFacet.setDAOAddress.selector;

        // Views
        sels[23] = ArbiterRegistryFacet.isDaoActive.selector;
        sels[24] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        sels[25] = ArbiterRegistryFacet.getDaoThreshold.selector;
        sels[26] = ArbiterRegistryFacet.getChiefArbiter.selector;
        sels[27] = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        sels[28] = ArbiterRegistryFacet.getArbiters.selector;
        sels[29] = ArbiterRegistryFacet.getDisputeClaimer.selector;
        sels[30] = ArbiterRegistryFacet.getClaimCommitment.selector;
        sels[31] = ArbiterRegistryFacet.getPendingVerdict.selector;
        sels[32] = ArbiterRegistryFacet.getVaultBalance.selector;
        sels[33] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        sels[34] = ArbiterRegistryFacet.getDAOAddress.selector;
        sels[35] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        sels[36] = ArbiterRegistryFacet.getAppealVotes.selector;
        sels[37] = ArbiterRegistryFacet.hasVotedOnAppeal.selector;

        // The dispute fee (3% of the disputed amount) — split 80/20 arbiter/treasury
        sels[38] = ArbiterRegistryFacet.creditDisputeFee.selector;
        sels[39] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        sels[40] = ArbiterRegistryFacet.getTreasurySlice.selector;

        // The paid arbiter call: the floor and the quote for the top-up to it
        sels[41] = ArbiterRegistryFacet.setArbiterFloor.selector;
        sels[42] = ArbiterRegistryFacet.getArbiterFloor.selector;
        sels[43] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;

        // The paid arbiter call: payment and the soft refund of the top-up
        sels[44] = ArbiterRegistryFacet.fundDispute.selector;
        sels[45] = ArbiterRegistryFacet.getDisputeBounty.selector;
        sels[46] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        sels[47] = ArbiterRegistryFacet.getRefundableBounty.selector;

        // The arbiter's chat keys (9 August 2026) — the WRITE stayed here, the read
        // (getArbiterChatKeys) moved away, see the half below.
        sels[48] = ArbiterRegistryFacet.setArbiterChatKey.selector;

        // The chain as a witness to presentation (the cut of 15 August 2026) — the
        // WRITES stayed here, along with the getter for the NO_RESPONSE_FLOOR constant
        // (recordNoResponse in this same file applies it, and moving the getter would
        // require a second declaration of the number).
        sels[49] = ArbiterRegistryFacet.recordNoResponse.selector;
        sels[50] = ArbiterRegistryFacet.getNoResponseFloor.selector;
        sels[51] = ArbiterRegistryFacet.recordPresentationDigest.selector;
    }

    /// The half of Replace that MOVES to ArbiterAccountabilityFacet. All eleven are
    /// mounted on chain today on the old ArbiterRegistryFacet — hence Replace, not
    /// Add.
    ///
    /// What these functions are: readers about an arbiter's BEHAVIOUR, their STANDING
    /// and the EVIDENCE. The bodies were moved without a single edit — from outside
    /// the diamond the move is not visible at all, the same proxy address answers with
    /// the same answer.
    function replaceAccountabilitySelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](11);

        // An arbiter's behaviour and standing
        sels[0]  = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;
        sels[1]  = ArbiterAccountabilityFacet.getArbiterBond.selector;
        sels[2]  = ArbiterAccountabilityFacet.getOpenClaimCount.selector;
        sels[3]  = ArbiterAccountabilityFacet.getArbiterReward.selector;
        sels[4]  = ArbiterAccountabilityFacet.getArbiterDeals.selector;

        // Evidence: chat keys, the presentation anchor, the record of silence, and the
        // digests
        sels[5]  = ArbiterAccountabilityFacet.getArbiterChatKeys.selector;
        sels[6]  = ArbiterAccountabilityFacet.getDisputeClaimedAt.selector;
        sels[7]  = ArbiterAccountabilityFacet.getNoResponseAt.selector;
        sels[8]  = ArbiterAccountabilityFacet.getPresentationDigests.selector;
        sels[9]  = ArbiterAccountabilityFacet.getPresentationDigestCount.selector;
        sels[10] = ArbiterAccountabilityFacet.getPresentationDigestsPage.selector;
    }

    /// EVERYTHING mounted for the first time: six new entrances of the old facet plus
    /// the whole new facet. One list for the pre-flight (not one of them must be
    /// mounted) and for the final count; it is split across two addresses only in
    /// buildCuts().
    function addSelectors() public pure returns (bytes4[] memory sels) {
        bytes4[] memory reg = addRegistrySelectors();
        bytes4[] memory acc = addAccountabilitySelectors();
        sels = new bytes4[](reg.length + acc.length);
        uint256 k;
        for (uint256 i = 0; i < reg.length; i++) sels[k++] = reg[i];
        for (uint256 i = 0; i < acc.length; i++) sels[k++] = acc[i];
    }

    /// The new entrances that STAYED in the registry. They are not in the diamond
    /// today, so Add rather than Replace — see the file header.
    ///
    /// ⚠️ There were six and there are now three: getSeatedBy, getSeatedCountBy and
    /// getCleanVerdicts moved into the accountability facet. They are NOT mounted on
    /// chain, so the move does not change the operation — Add stays Add, merely in a
    /// different list and onto a different address.
    ///
    /// getChiefBloc stayed because it calls the private _chiefBloc that addArbiter
    /// holds — moving it would have cost a second copy of the body.
    /// getMaxClaimsPerArbiter and getMaxArbiterMistakes stayed because they read
    /// PRIVATE CONSTANTS of the registry that are applied by code staying there:
    /// moving the getter would introduce a second declaration of the number, and the
    /// outside world would be answered by a mirror while the rule was applied from the
    /// original. For getMaxArbiterMistakes it would in addition degenerate
    /// test_MistakeThresholdMatchesRegistry into comparing a mirror with itself.
    function addRegistrySelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](3);

        // The chief's bloc — how many seats they control
        sels[0] = ArbiterRegistryFacet.getChiefBloc.selector;

        // The ceiling on simultaneous disputes per arbiter
        sels[1] = ArbiterRegistryFacet.getMaxClaimsPerArbiter.selector;

        // The automatic threshold (now the threshold of an ACCUSATION, not of a removal)
        sels[2] = ArbiterRegistryFacet.getMaxArbiterMistakes.selector;
    }

    /// The whole ArbiterAccountabilityFacet — the diamond's twelfth facet.
    /// Completeness is checked by a test against the compiled ABI: a forgotten Add
    /// means a function that is not in the diamond, that is, a dead button on the
    /// client.
    function addAccountabilitySelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](24);

        // Suspension — quick, reversible, expiring by itself
        sels[0]  = ArbiterAccountabilityFacet.suspendArbiter.selector;
        sels[1]  = ArbiterAccountabilityFacet.liftSuspension.selector;
        sels[2]  = ArbiterAccountabilityFacet.isSuspended.selector;
        sels[3]  = ArbiterAccountabilityFacet.getSuspendedUntil.selector;
        sels[4]  = ArbiterAccountabilityFacet.getSuspensionWindow.selector;

        // Removal only with a cause (the replacement for the bare removeArbiter)
        sels[5]  = ArbiterAccountabilityFacet.removeArbiterForCause.selector;
        sels[6]  = ArbiterAccountabilityFacet.getMistakeThreshold.selector;
        sels[7]  = ArbiterAccountabilityFacet.getMaxArbiterMistakesMirror.selector;
        sels[8]  = ArbiterAccountabilityFacet.getDaoThresholdMirror.selector;

        // The chief proposes a removal, does not execute one
        sels[9]  = ArbiterAccountabilityFacet.proposeRemoval.selector;
        sels[10] = ArbiterAccountabilityFacet.withdrawProposal.selector;
        sels[11] = ArbiterAccountabilityFacet.getRemovalProposal.selector;
        sels[12] = ArbiterAccountabilityFacet.hasLiveProposal.selector;
        sels[13] = ArbiterAccountabilityFacet.getProposalTTL.selector;

        // The accused's right of reply (since 19 August 2026 during the pause as well,
        // not only after a removal)
        sels[14] = ArbiterAccountabilityFacet.respondToRemoval.selector;
        sels[15] = ArbiterAccountabilityFacet.getRemovalReply.selector;

        // An arbiter's standing in one read
        sels[16] = ArbiterAccountabilityFacet.getArbiterStanding.selector;

        // The three readers that moved out of the registry and are NOT YET MOUNTED on
        // chain — hence Add, not Replace. The other eleven that moved are mounted and
        // travel in the replaceAccountabilitySelectors() group. Each one's kind is
        // determined from this file's lists and by the pre-flight against the chain,
        // not by intuition.
        sels[17] = ArbiterAccountabilityFacet.getSeatedBy.selector;
        sels[18] = ArbiterAccountabilityFacet.getSeatedCountBy.selector;
        sels[19] = ArbiterAccountabilityFacet.getCleanVerdicts.selector;

        // The cause in words: the ceiling is in BYTES and is asked of the chain rather
        // than kept as a copy on the client.
        sels[20] = ArbiterAccountabilityFacet.getMaxReasonBytes.selector;

        // The 48-hour pause (design of 17 August 2026): removal
        // runs only through a proposal that has sat. The reading is mounted so
        // the form asks the chain for the number instead of keeping a copy that
        // drifts and shows the button as live an hour before it works.
        sels[21] = ArbiterAccountabilityFacet.getRemovalDelay.selector;

        // ⚠️ ADD, NOT REPLACE (18 August 2026). The quiet door — three
        // judicial mistakes unseating on the spot — now leads into the common
        // one: the third mistake suspends and lays an accusation in the chain's
        // own name, and after the 48 hours anyone may press this. The selector
        // is NEW: it has never been mounted in the diamond, so it belongs in
        // this group and nowhere else. A Replace on an unmounted selector
        // reverts and takes the WHOLE cut down with it, in one live
        // transaction.
        sels[22] = ArbiterAccountabilityFacet.executeChainRemoval.selector;

        // ⚠️ ADD, NOT REPLACE (21 August 2026), and for the plainest
        // possible reason: the function did not exist until today. The other
        // half of the fraction — how many of this arbiter's verdicts were
        // overturned, over his whole service. `cleanVerdicts` alone made a
        // patient bad arbiter read BETTER than an honest newcomer, because the
        // mistake counter is a streak and a clean verdict clears it. Nothing
        // counted the overturns at all.
        sels[23] = ArbiterAccountabilityFacet.getOverturnedVerdicts.selector;
    }

    /// Exactly one: the bare removeArbiter(address). Simply taking it out of the
    /// source is not enough — without a Remove the selector stays mounted on the OLD
    /// address, and the button goes on working after the cut, on the old code.
    function removeSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = REMOVE_ARBITER_SELECTOR;
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory sels)
        internal pure returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({
            facetAddress: facet,
            action: action,
            functionSelectors: sels
        });
    }
}
