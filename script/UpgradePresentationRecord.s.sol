// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
// Five of this cut's readers (getDisputeClaimedAt, getNoResponseAt,
// getPresentationDigests/Count/Page) and six older ones later moved into the
// accountability facet. The cut is ALREADY EXECUTED and is not to be rewritten:
// the lists below are a record of what went on chain on 15 August, and the
// selector values did not change by a bit in the move. The import is here only so
// that `.selector` has somewhere to be read from.
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

/// The one selector this ALREADY EXECUTED cut reads through the diamond.
///
/// It is declared here as a local interface rather than taken from the facet, and
/// deliberately so: at the moment this script was written and run,
/// `getOpenClaimCount` lived in ArbiterRegistryFacet; the split later moved the
/// reader into ArbiterAccountabilityFacet. The script hits THE DIAMOND'S ADDRESS,
/// and the diamond does not care which facet holds the selector today — and tying
/// an executed cut to a facet that did not exist when it ran would be rewriting
/// history. The selector does not change in the move.
interface IOpenClaimCountProbe {
    function getOpenClaimCount(address arbiter) external view returns (uint256);
}

/// The same getNoResponseFloor(), but declared `view` rather than `pure`.
/// In the facet itself it is pure — there it really does nothing but return a
/// constant. THROUGH THE DIAMOND, however, that same call first looks the facet
/// up in the proxy's storage, that is, it reads state. The point of the smoke test
/// is precisely that lookup, so the type here is honest: `pure` would declare that
/// no routing takes place.
interface INoResponseFloorProbe {
    function getNoResponseFloor() external view returns (uint256);
}

/**
 * The record "asked, got no answer" and the presentation digest.
 *
 * ONE diamondCut of two actions:
 *   Replace — all 56 previous facet selectors onto the new address;
 *   Add     — eight new ones:
 *               getDisputeClaimedAt(address)
 *               recordNoResponse(address)
 *               getNoResponseAt(address)
 *               getNoResponseFloor()
 *               recordPresentationDigest(address,bytes32)
 *               getPresentationDigests(address)
 *               getPresentationDigestCount(address)
 *               getPresentationDigestsPage(address,uint256,uint256)
 *
 * There is NO Remove group: not one previous signature changed, so there is
 * nothing to delete. The number of mounted selectors in the diamond goes 169 →
 * 177. That number is checked by the post-flight below, not by eye.
 *
 * Why one cut rather than two calls: between the Replace and the Add the diamond
 * must not end up in a state of "new code, no entrances" — recordNoResponse and
 * recordPresentationDigest write into fields the new code already reads.
 *
 * Why the Replace is mandatory: without it the facet's 56 selectors would stay at
 * the old address and the diamond would run half on old code that knows nothing
 * about the three new storage fields.
 *
 * ── Pre/post-flight ──────────────────────────────────────────────────────
 * The form comes from the arbiter chat-key upgrade of 10 August 2026. A Replace
 * onto an address that does not have the required selector does NOT revert
 * (DiamondCutLib.replaceFunctions checks only "the address is different and has
 * code", not "does it implement this selector") — a silent drift of the "mounted
 * but does not work" kind, exactly the class that already broke fundDispute by
 * reading msg.sender instead of _msgSender(): deployed, never once fired, and
 * nobody noticed until a separate investigation. So before the broadcast it is
 * checked that the whole Replace group aims at one and the same really mounted old
 * address, and that Add aims at selectors not yet mounted; after the broadcast,
 * that Replace/Add landed on the new address, that the old address is empty, and in
 * addition a functional smoke test: getNoResponseFloor() THROUGH THE DIAMOND
 * returns EXACTLY one day rather than merely appearing in the loupe. The value is
 * compared, not the fact of a return, because the floor is declared in the contract
 * and only there — the client takes it from the chain, and a chain answering a
 * different number would draw a person the wrong expectation.
 *
 * ── Storage continuity ───────────────────────────────────────────────────
 * Everything above checks the ROUTING of selectors — not one of those checks reads
 * a single value that was already lying in the arbiter namespace BEFORE the cut.
 * That is exactly the class that broke JobBoard in July 2026: getOpenJobs() began
 * reverting Panic(0x22) on live storage after a layout change, and the static gates
 * (selectors, ABI) did not see it. This work appended THREE fields to the end of
 * ArbiterRegistryStorage.Data, that is, precisely the kind of edit that gives rise
 * to that class. So getArbiters().length, getVaultBalance() and getArbiterFloor()
 * are read here BEFORE vm.startBroadcast and again AFTER vm.stopBroadcast, with a
 * require on equality — a proof on real data rather than on the fact that the cut
 * went through.
 *
 * ── Disputes claimed BEFORE the cut ──────────────────────────────────────
 * There is no migration code at all (the owner's decision of 14 August): a dispute
 * claimed before this cut has no time anchor on chain, and recordNoResponse will
 * answer it with ClaimTimeUnknown. The cure is cheap — releaseDisputeClaim and
 * claim the dispute again. The pre-flight LISTS AND PRINTS such disputes but does
 * not revert: they were claimed lawfully, and failing here would be a lie.
 */
contract UpgradePresentationRecord is Script {
    /// The script's own name — the chain snapshot taken FOR THIS cut compares
    /// itself against the script it validates by it. There must be no literal in
    /// the bench here: the next cut's bench is copied from this one, and a literal
    /// would travel along with the copy-paste in silence. A value taken from the
    /// script under test itself does not travel.
    ///
    /// ⚠️ The cut is EXECUTED, and this addition changes nothing in it: a `pure`
    /// getter, no state, not a line of `run()`. The record of what happened stayed
    /// a record.
    ///
    /// The string must match the `forScript` field in
    /// test/fixtures/chain-2026-08-14-arbiter-selectors.json.
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradePresentationRecord.s.sol";
    }

    /// The floor for a record of silence is one day (the owner's decision of
    /// 14 August 2026). Declared in the contract; here it is only checked.
    uint256 internal constant EXPECTED_NO_RESPONSE_FLOOR = 24 hours;

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        require(diamond != address(0), "DIAMOND_ADDRESS not set");

        bytes4[] memory replaceSels = replaceSelectors();
        bytes4[] memory addSels     = addSelectors();

        // ── Pre-flight ────────────────────────────────────────────────────
        console.log("=== UpgradePresentationRecord: pre-flight ===");
        address oldFacet = checkReplaceGroup(replaceSels, diamond);
        checkAddGroupUnmounted(addSels, diamond);
        console.log("Old ArbiterRegistryFacet currently mounted at:", oldFacet);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        console.log("Total routed selectors BEFORE cut:", selectorsBefore);

        // Values already lying in the arbiter namespace — read BEFORE the broadcast
        // and compared against the same reads AFTER.
        StorageSnapshot memory before = snapshotArbiterStorage(diamond);
        console.log("Arbiter storage BEFORE cut - arbiters:", before.arbiterCount);
        console.log("  vaultBalance:", before.vaultBalance);
        console.log("  arbiterFloor:", before.arbiterFloor);

        warnArbitersWithPreCutClaims(diamond);
        console.log("");

        // ── The upgrade ───────────────────────────────────────────────────
        vm.startBroadcast();
        ArbiterRegistryFacet facet = new ArbiterRegistryFacet();
        IDiamondCut(diamond).diamondCut(buildCuts(address(facet)), address(0), "");
        vm.stopBroadcast();

        console.log("ArbiterRegistryFacet:", address(facet));
        console.log("Replace", replaceSels.length, "/ Add", addSels.length);
        console.log("");

        // ── Post-flight ───────────────────────────────────────────────────
        console.log("=== Post-flight ===");
        assertRouted(replaceSels, address(facet), diamond);
        assertRouted(addSels,     address(facet), diamond);
        assertFacetHoldsNoSelectors(oldFacet, diamond);
        console.log("Replace/Add -> new facet, old facet emptied.");

        StorageSnapshot memory afterCut = snapshotArbiterStorage(diamond);
        assertStorageContinuity(before, afterCut);
        console.log("Arbiter storage AFTER cut  - arbiters:", afterCut.arbiterCount);
        console.log("  vaultBalance:", afterCut.vaultBalance);
        console.log("  arbiterFloor:", afterCut.arbiterFloor);
        console.log("Storage continuity OK: arbiters/vaultBalance/arbiterFloor unchanged by the cut.");

        assertNoResponseFloorAnswers(diamond);
        console.log("Smoke getNoResponseFloor() through diamond returned 24h.");

        uint256 selectorsAfter = totalRoutedSelectors(diamond);
        require(
            selectorsAfter == selectorsBefore + addSels.length,
            "post-flight: the count of mounted selectors did not move by exactly +Add"
        );
        console.log("Total routed selectors AFTER cut:", selectorsAfter);
    }

    // ════════════════════════════════════════════════════════════════════
    // Pre/post-flight helpers — public so that the PresentationRecordUpgrade
    // suite can call them directly against a locally deployed diamond and not only
    // against the live chain inside run().
    // ════════════════════════════════════════════════════════════════════

    /// Every selector in the group is mounted now, and they all point at ONE and the
    /// same address — otherwise the Replace list was derived wrongly (the facet has
    /// already split across several addresses, and a Replace onto a single new
    /// address would be the wrong operation). Returns that address.
    function checkReplaceGroup(bytes4[] memory sels, address diamond)
        public view returns (address facetAddr)
    {
        require(sels.length > 0, "UpgradePresentationRecord: the Replace group is empty");
        facetAddr = IDiamondLoupe(diamond).facetAddress(sels[0]);
        require(facetAddr != address(0), "UpgradePresentationRecord: the first Replace selector is not mounted");
        for (uint256 i = 0; i < sels.length; i++) {
            address a = IDiamondLoupe(diamond).facetAddress(sels[i]);
            require(a != address(0), "UpgradePresentationRecord: one of the Replace selectors is not mounted");
            require(
                a == facetAddr,
                "UpgradePresentationRecord: the Replace selectors are spread across more than one live facet address"
            );
        }
    }

    /// Not one selector in the group is mounted yet — otherwise Add reverts
    /// "selector exists" in DiamondCutLib.addFunctions and the whole rollout fails
    /// AFTER the new facet has been broadcast.
    function checkAddGroupUnmounted(bytes4[] memory sels, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == address(0),
                "UpgradePresentationRecord: an Add selector is already mounted somewhere, so Add will revert"
            );
        }
    }

    /// Every selector in the group leads to the expected (new) facet address.
    function assertRouted(bytes4[] memory sels, address expected, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                "UpgradePresentationRecord: a selector did not land on the new facet"
            );
        }
    }

    /// The old facet address has not one selector left — it was displaced entirely
    /// rather than half split.
    function assertFacetHoldsNoSelectors(address facetAddr, address diamond) public view {
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(facetAddr).length == 0,
            "UpgradePresentationRecord: the old facet address still holds selectors after the cut"
        );
    }

    /// A functional smoke test: getNoResponseFloor() THROUGH THE DIAMOND (not by a
    /// direct call to the facet) executes and returns EXACTLY one day.
    ///
    /// The value is compared rather than the fact of a return, and that is not
    /// pedantry: the floor is declared in the contract and only there, the client
    /// asks the chain for it and draws a person "this long to wait". A diamond
    /// answering a different number — because Replace/Add landed on somebody else's
    /// address with a similar signature, say — looks healthy in routing terms while
    /// promising an untruth.
    function assertNoResponseFloorAnswers(address diamond) public view {
        require(
            INoResponseFloorProbe(diamond).getNoResponseFloor() == EXPECTED_NO_RESPONSE_FLOOR,
            "post-flight: the floor for a record of silence does not answer through the diamond"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Storage continuity — reads values that were already lying in the arbiter
    // namespace BEFORE the cut, not only selector routing.
    // ════════════════════════════════════════════════════════════════════

    struct StorageSnapshot {
        uint256 arbiterCount;
        uint256 vaultBalance;
        uint256 arbiterFloor;
    }

    /// Three reads of existing arbiter-namespace fields THROUGH THE DIAMOND.
    /// getArbiterFloor() returns DEFAULT_ARBITER_FLOOR when the field is zero (see
    /// the facet itself) — that is still a read of an existing field and not an
    /// invention: if the layout shifts, the value jumps along with the rest rather
    /// than quietly staying at the default.
    function snapshotArbiterStorage(address diamond) public view returns (StorageSnapshot memory s) {
        ArbiterRegistryFacet f = ArbiterRegistryFacet(diamond);
        s.arbiterCount = f.getArbiters().length;
        s.vaultBalance = f.getVaultBalance();
        s.arbiterFloor = f.getArbiterFloor();
    }

    /// The three values taken BEFORE and AFTER the cut must match literally —
    /// diamondCut must write nothing into somebody else's namespace. A divergence
    /// here is the same class of signal as Panic(0x22) on getOpenJobs() after the
    /// JobBoard layout change in July 2026: the layout shifted, and old records are
    /// read from the wrong slots.
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

    // ════════════════════════════════════════════════════════════════════
    // Disputes claimed BEFORE the cut — a loud warning, not a require.
    // ════════════════════════════════════════════════════════════════════

    /// A dispute claimed BEFORE this cut keeps its arbiter in disputeClaims after
    /// the cut (their openClaimCount is > 0), while the time anchor for it does not
    /// and cannot exist on chain: the disputeClaimedAtBy field was appended by this
    /// same change, and before it there was nothing to write into. recordNoResponse
    /// refuses such disputes outright (ClaimTimeUnknown, the owner's decision of
    /// 14 August 2026 — there is no migration code at all). The cure is cheap: the
    /// arbiter calls releaseDisputeClaim and claims the dispute again, and then the
    /// time is recorded.
    /// NOT a require: those claims were taken lawfully, no anchor was required
    /// before the cut, and failing here would be a lie.
    ///
    /// It does NOT call getDisputeClaimedAt(): this function is called BEFORE the
    /// broadcast (pre-flight), and getDisputeClaimedAt is itself one of the eight
    /// Add selectors of THIS cut, that is, on the live diamond it is NOT yet mounted
    /// at that moment — the call would revert "Diamond: Function does not exist" and
    /// bring the whole script down instead of printing a warning. Nor is there any
    /// need to read it: before this cut an anchor could not appear in principle, so
    /// for any arbiter with openClaimCount > 0 it is guaranteed to be zero.
    /// openClaimCount alone (an existing selector, part of Replace) is enough.
    ///
    /// It enumerates over the current list of registered arbiters (getArbiters()) —
    /// an arbiter who has already lost their status but is still sitting in
    /// disputeClaims with an open counter will not be found by this walk; that is a
    /// separate and rarer case.
    function findArbitersWithPreCutClaims(address diamond) public view returns (address[] memory flagged) {
        ArbiterRegistryFacet f = ArbiterRegistryFacet(diamond);
        address[] memory arbiters = f.getArbiters();
        IOpenClaimCountProbe claims = IOpenClaimCountProbe(diamond);

        uint256 count;
        bool[] memory hit = new bool[](arbiters.length);
        for (uint256 i = 0; i < arbiters.length; i++) {
            if (claims.getOpenClaimCount(arbiters[i]) == 0) continue;
            hit[i] = true;
            count++;
        }

        flagged = new address[](count);
        uint256 k;
        for (uint256 i = 0; i < arbiters.length; i++) {
            if (hit[i]) flagged[k++] = arbiters[i];
        }
    }

    function warnArbitersWithPreCutClaims(address diamond) public view {
        address[] memory flagged = findArbitersWithPreCutClaims(diamond);
        console.log("=== Pre-flight: arbiters holding claims taken BEFORE this cut ===");
        if (flagged.length == 0) {
            console.log("  none.");
            return;
        }
        for (uint256 i = 0; i < flagged.length; i++) {
            console.log("  NO CLAIM ANCHOR - arbiter:", flagged[i]);
            console.log("    openClaimCount:", IOpenClaimCountProbe(diamond).getOpenClaimCount(flagged[i]));
            console.log("    -> recordNoResponse will revert ClaimTimeUnknown");
            console.log("    -> cure: releaseDisputeClaim(deal) and claim it again");
        }
        console.log("Total arbiters whose open claims predate this cut:", flagged.length);
    }

    function totalRoutedSelectors(address diamond) public view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(diamond).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    /// Extracted into a public pure function so a test can check the cut's composition without a rollout.
    function buildCuts(address facet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = _cut(facet, IDiamondCut.FacetCutAction.Replace, replaceSelectors());
        cuts[1] = _cut(facet, IDiamondCut.FacetCutAction.Add,     addSelectors());
    }

    /// The eight new entrances. Completeness and the absence of an intersection with
    /// Replace are checked by a test against the compiled ABI, not by eye: searching
    /// for `function ... external` lines misses functions whose signature spans two
    /// lines (which is exactly how getPresentationDigestsPage was lost on the first
    /// count).
    function addSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](8);

        // The moment a dispute was claimed
        sels[0] = ArbiterAccountabilityFacet.getDisputeClaimedAt.selector;

        // The record "asked, got no answer" plus the one-day floor
        sels[1] = ArbiterRegistryFacet.recordNoResponse.selector;
        sels[2] = ArbiterAccountabilityFacet.getNoResponseAt.selector;
        sels[3] = ArbiterRegistryFacet.getNoResponseFloor.selector;

        // The presentation digest plus reading the feed
        sels[4] = ArbiterRegistryFacet.recordPresentationDigest.selector;
        sels[5] = ArbiterAccountabilityFacet.getPresentationDigests.selector;
        sels[6] = ArbiterAccountabilityFacet.getPresentationDigestCount.selector;
        sels[7] = ArbiterAccountabilityFacet.getPresentationDigestsPage.selector;
    }

    /// Every selector mounted on the facet today — 56 of them, the same list
    /// script/DeployFull.s.sol::arbiterRegistryFacetSelectors() held before this
    /// work. Not one previous signature changed, so this is exactly "everything but
    /// the eight new ones". Completeness is checked by a test against the compiled
    /// ABI, not by eye.
    function replaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](56);

        // DAO mode
        sels[0]  = ArbiterRegistryFacet.activateDAO.selector;
        sels[1]  = ArbiterRegistryFacet.applyAsArbiter.selector;
        sels[2]  = ArbiterRegistryFacet.resignAsArbiter.selector;

        // Admin: managing arbiters
        sels[3]  = ArbiterRegistryFacet.setChiefArbiter.selector;
        sels[4]  = ArbiterRegistryFacet.addArbiter.selector;
        sels[5]  = bytes4(0x3487e08c) /* removeArbiter(address), removed 15 August 2026 */;

        // Claiming a dispute (commit-reveal)
        sels[6]  = ArbiterRegistryFacet.commitDisputeClaim.selector;
        sels[7]  = ArbiterRegistryFacet.claimDispute.selector;
        sels[8]  = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        sels[9]  = ArbiterRegistryFacet.clearDisputeClaim.selector;

        // The verdict
        sels[10] = ArbiterRegistryFacet.submitVerdict.selector;
        sels[11] = ArbiterRegistryFacet.finalizeVerdict.selector;
        sels[12] = ArbiterRegistryFacet.overturnVerdict.selector;
        sels[13] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        sels[14] = ArbiterRegistryFacet.freezeVerdict.selector;
        sels[15] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        sels[16] = ArbiterRegistryFacet.clearStuckVerdict.selector;

        // The appeal
        sels[17] = ArbiterRegistryFacet.raiseAppeal.selector;
        sels[18] = ArbiterRegistryFacet.voteOnAppeal.selector;
        sels[19] = ArbiterRegistryFacet.resolveAppeal.selector;

        // Rewards
        sels[20] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        sels[21] = ArbiterRegistryFacet.fundVault.selector;
        sels[22] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        sels[23] = ArbiterRegistryFacet.setDAOAddress.selector;

        // Views
        sels[24] = ArbiterRegistryFacet.isDaoActive.selector;
        sels[25] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        sels[26] = ArbiterRegistryFacet.getDaoThreshold.selector;
        sels[27] = ArbiterRegistryFacet.getChiefArbiter.selector;
        sels[28] = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        sels[29] = ArbiterRegistryFacet.getArbiters.selector;
        sels[30] = ArbiterRegistryFacet.getDisputeClaimer.selector;
        sels[31] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        sels[32] = ArbiterRegistryFacet.getClaimCommitment.selector;
        sels[33] = ArbiterRegistryFacet.getPendingVerdict.selector;
        sels[34] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        sels[35] = ArbiterRegistryFacet.getVaultBalance.selector;
        sels[36] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        sels[37] = ArbiterRegistryFacet.getDAOAddress.selector;
        sels[38] = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;
        sels[39] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        sels[40] = ArbiterRegistryFacet.getAppealVotes.selector;
        sels[41] = ArbiterRegistryFacet.hasVotedOnAppeal.selector;
        sels[42] = ArbiterAccountabilityFacet.getArbiterBond.selector;
        sels[43] = ArbiterAccountabilityFacet.getOpenClaimCount.selector;

        // The dispute fee (3% of the disputed amount) — split 80/20 arbiter/treasury
        sels[44] = ArbiterRegistryFacet.creditDisputeFee.selector;
        sels[45] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        sels[46] = ArbiterRegistryFacet.getTreasurySlice.selector;

        // The paid arbiter call: the floor and the quote for the top-up to it
        sels[47] = ArbiterRegistryFacet.setArbiterFloor.selector;
        sels[48] = ArbiterRegistryFacet.getArbiterFloor.selector;
        sels[49] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;

        // The paid arbiter call: payment and the soft refund of the top-up
        sels[50] = ArbiterRegistryFacet.fundDispute.selector;
        sels[51] = ArbiterRegistryFacet.getDisputeBounty.selector;
        sels[52] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        sels[53] = ArbiterRegistryFacet.getRefundableBounty.selector;

        // The arbiter's chat keys (9 August 2026)
        sels[54] = ArbiterAccountabilityFacet.getArbiterChatKeys.selector;
        sels[55] = ArbiterRegistryFacet.setArbiterChatKey.selector;

        // The eight new entrances go into Add, not here (see addSelectors()).
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
