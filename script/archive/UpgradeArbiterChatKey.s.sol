// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ArbiterRegistryFacet} from "../../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../../src/facets/ArbiterAccountabilityFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../../src/DiamondProxy.sol";

/**
 * The arbiter's chat keys on chain.
 *
 * ONE diamondCut of three actions:
 *   Remove  — the old claim selector claimDispute(address,bytes32);
 *   Replace — every other facet selector onto the new address;
 *   Add     — the new claim, setArbiterChatKey, getArbiterChatKeys.
 *
 * Why one and not three calls: between the operations the diamond must not end up
 * in a state of "both claim entrances exist" — the second entrance takes a dispute
 * WITHOUT a key, that is, precisely the hole this change closes stays open.
 *
 * Why the Replace is mandatory: without it the facet's 53 selectors would stay at
 * the old address and the diamond would run half on old code.
 *
 * ── Pre/post-flight ──────────────────────────────────────────────────────
 * The form comes from the paid-arbitration upgrade and its helpers. A Replace onto
 * an address that does not have the required selector does NOT revert
 * (DiamondCutLib.replaceFunctions checks only "the address is different and has
 * code", not "does it implement this selector") — a silent drift of the "mounted
 * but does not work" kind, exactly the class that already broke fundDispute by
 * reading msg.sender instead of _msgSender(): deployed, never once fired, and
 * nobody noticed until a separate investigation. So before the broadcast it is
 * checked that Replace/Remove aim at one and the same really mounted old address,
 * and that Add aims at selectors not yet mounted; after the broadcast, that
 * Replace/Add landed on the new address, that the old address is empty, that the
 * Remove led nowhere, and in addition a functional smoke test: getArbiterChatKeys
 * THROUGH THE DIAMOND really executes (does not revert, returns zeroes) rather than
 * merely appearing in the loupe.
 *
 * ── Storage continuity (found in the final review of 9 August) ───────────
 * Everything above checks the ROUTING of selectors — not one of those checks reads
 * a single value that was already lying in the arbiter namespace BEFORE the cut.
 * That is exactly the class that broke JobBoard in July 2026: getOpenJobs() began
 * reverting Panic(0x22) on live storage after a layout change, and the static gates
 * (selectors, ABI) did not see it — only a read of the real state before and after
 * can. So getArbiters().length, getVaultBalance() and getArbiterFloor() are read
 * here BEFORE vm.startBroadcast and again AFTER vm.stopBroadcast, with a require on
 * equality — a proof on real data rather than on the fact that the cut went through.
 */
contract UpgradeArbiterChatKey is Script {
    /// The script's own name — the chain snapshot taken FOR THIS cut compares itself
    /// against the script it validates by it. There must be no literal in the bench
    /// here: the next cut's bench is copied from this one, and a literal would travel
    /// along with the copy-paste in silence. A value taken from the script under test
    /// itself does not travel.
    ///
    /// ⚠️ The cut is EXECUTED, and this addition changes nothing in it: a `pure`
    /// getter, no state, not a line of `run()`. The record of what happened stayed a
    /// record.
    ///
    /// The string must match the `forScript` field in
    /// test/fixtures/chain-2026-08-10-arbiter-selectors.json.
    function scriptPath() public pure returns (string memory) {
        return "script/archive/UpgradeArbiterChatKey.s.sol";
    }

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        require(diamond != address(0), "DIAMOND_ADDRESS not set");

        bytes4[] memory removeSels  = removeSelectors();
        bytes4[] memory replaceSels = replaceSelectors();
        bytes4[] memory addSels     = addSelectors();

        // ── Pre-flight ────────────────────────────────────────────────────
        console.log("=== UpgradeArbiterChatKey: pre-flight ===");
        address oldFacet = checkReplaceGroup(replaceSels, diamond);
        checkRemoveSelectorMounted(removeSels, oldFacet, diamond);
        checkAddGroupUnmounted(addSels, diamond);
        console.log("Old ArbiterRegistryFacet currently mounted at:", oldFacet);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        console.log("Total routed selectors BEFORE cut:", selectorsBefore);

        // Values that already lie in the arbiter namespace — read BEFORE the
        // broadcast and compared against the same reads AFTER. The form is below,
        // snapshotArbiterStorage/assertStorageContinuity.
        StorageSnapshot memory before = snapshotArbiterStorage(diamond);
        console.log("Arbiter storage BEFORE cut - arbiters:", before.arbiterCount);
        console.log("  vaultBalance:", before.vaultBalance);
        console.log("  arbiterFloor:", before.arbiterFloor);

        warnArbitersWithOpenClaimsMissingKeys(diamond);
        console.log("");

        // ── The upgrade ───────────────────────────────────────────────────
        vm.startBroadcast(pk);
        address facet = _deployRegistryFacet();
        IDiamondCut(diamond).diamondCut(buildCuts(facet), address(0), "");
        vm.stopBroadcast();

        console.log("ArbiterRegistryFacet:", facet);
        console.log("Remove 1 / Replace", replaceSels.length, "/ Add", addSels.length);
        console.log("");

        // ── Post-flight ───────────────────────────────────────────────────
        console.log("=== Post-flight ===");
        assertRouted(replaceSels, address(facet), diamond);
        assertRouted(addSels,     address(facet), diamond);
        assertFacetHoldsNoSelectors(oldFacet, diamond);
        assertSelectorsUnrouted(removeSels, diamond);
        console.log("Replace/Add -> new facet, old facet emptied, Remove routes nowhere.");

        StorageSnapshot memory afterCut = snapshotArbiterStorage(diamond);
        assertStorageContinuity(before, afterCut);
        console.log("Arbiter storage AFTER cut  - arbiters:", afterCut.arbiterCount);
        console.log("  vaultBalance:", afterCut.vaultBalance);
        console.log("  arbiterFloor:", afterCut.arbiterFloor);
        console.log("Storage continuity OK: arbiters/vaultBalance/arbiterFloor unchanged by the cut.");

        (bytes32 boxKey, bytes32 signKey) = smokeGetArbiterChatKeys(diamond, address(0xDEAD));
        require(
            boxKey == bytes32(0) && signKey == bytes32(0),
            "post: smoke call to getArbiterChatKeys through the diamond did not return zeros"
        );
        console.log("Smoke getArbiterChatKeys(0x...DEAD) through diamond did not revert, returned (0, 0).");

        uint256 selectorsAfter = totalRoutedSelectors(diamond);
        require(
            selectorsAfter == selectorsBefore - removeSels.length + addSels.length,
            "post: routed selector count did not move by exactly -Remove +Add"
        );
        console.log("Total routed selectors AFTER cut:", selectorsAfter);
    }

    // ════════════════════════════════════════════════════════════════════
    // Pre/post-flight helpers — public so that the ArbiterChatKeyUpgrade suite can
    // call them directly against a locally deployed diamond and not only against the
    // live chain inside run(). The form comes from the paid-arbitration upgrade.
    // ════════════════════════════════════════════════════════════════════

    /// Every selector in the group is mounted now, and they all point at ONE and the
    /// same address — otherwise the Replace list was derived wrongly (the facet has
    /// already split across several addresses, and a Replace onto a single new
    /// address would be the wrong operation). Returns that address.
    function checkReplaceGroup(bytes4[] memory sels, address diamond)
        public view returns (address facetAddr)
    {
        require(sels.length > 0, "UpgradeArbiterChatKey: replace group is empty");
        facetAddr = IDiamondLoupe(diamond).facetAddress(sels[0]);
        require(facetAddr != address(0), "UpgradeArbiterChatKey: selector[0] of Replace is not mounted");
        for (uint256 i = 0; i < sels.length; i++) {
            address a = IDiamondLoupe(diamond).facetAddress(sels[i]);
            require(a != address(0), "UpgradeArbiterChatKey: a Replace selector is not mounted");
            require(a == facetAddr, "UpgradeArbiterChatKey: Replace selectors are split across more than one live facet address");
        }
    }

    /// The selector being removed is mounted now and lives on THE SAME address as the
    /// Replace group — otherwise the Remove aims at a facet other than the one being
    /// upgraded by this cut.
    function checkRemoveSelectorMounted(bytes4[] memory sels, address expectedFacet, address diamond) public view {
        require(sels.length == 1, "UpgradeArbiterChatKey: remove group must have exactly one selector");
        address a = IDiamondLoupe(diamond).facetAddress(sels[0]);
        require(a != address(0), "UpgradeArbiterChatKey: Remove selector is not mounted anywhere");
        require(a == expectedFacet, "UpgradeArbiterChatKey: Remove selector lives on a different facet address than the Replace group");
    }

    /// Not one selector in the group is mounted yet — otherwise Add reverts "selector
    /// exists" in DiamondCutLib.addFunctions and the whole rollout fails.
    function checkAddGroupUnmounted(bytes4[] memory sels, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == address(0),
                "UpgradeArbiterChatKey: an Add selector is already mounted somewhere - Add would revert"
            );
        }
    }

    /// Every selector in the group leads to the expected (new) facet address.
    function assertRouted(bytes4[] memory sels, address expected, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                "UpgradeArbiterChatKey: a selector did not land on the new facet"
            );
        }
    }

    /// The old facet address has not one selector left — it was displaced entirely
    /// rather than half split.
    function assertFacetHoldsNoSelectors(address facetAddr, address diamond) public view {
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(facetAddr).length == 0,
            "UpgradeArbiterChatKey: old facet address still holds selectors after the cut"
        );
    }

    /// The removed selector leads nowhere any more (facetAddress -> address(0)).
    function assertSelectorsUnrouted(bytes4[] memory sels, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == address(0),
                "UpgradeArbiterChatKey: a removed selector still routes somewhere"
            );
        }
    }

    /// Which contract is deployed under all of this cut's selectors.
    ///
    /// ⚠️ EXTRACTED INTO A SEPARATE `virtual` FUNCTION, and this is not a rewriting
    /// of an executed cut: in production the body returns exactly what stood here on
    /// the line before — `new ArbiterRegistryFacet()`. Not one selector, not one
    /// address and not one order of actions changed.
    ///
    /// It was needed for this. The cut was executed on 10 August 2026, when
    /// `getArbiterChatKeys` lived in ArbiterRegistryFacet. The later split moved that
    /// reader (and thirteen more) into ArbiterAccountabilityFacet. The post-flight
    /// below runs the smoke test for real — so on today's source the cut would mount
    /// the selector onto a facet that no longer implements it, and would fail on its
    /// own check.
    ///
    /// On chain that means nothing (the cut did its work a year ago, on its own
    /// code), but a test that repeats run() literally has to stay honest. It
    /// substitutes this function with the "facet from before the split" double and
    /// gets an exact reproduction of that day — instead of weakening the check.
    function _deployRegistryFacet() internal virtual returns (address) {
        return address(new ArbiterRegistryFacet());
    }

    /// A functional smoke test: getArbiterChatKeys THROUGH THE DIAMOND (not a direct
    /// call to the facet) does not revert and returns zeroes for an address with no
    /// keys recorded. It tells "the selector counts as mounted according to the
    /// loupe" apart from "the route really executes the new facet's code" — precisely
    /// the difference a Replace onto a non-implementing address catches in no other
    /// way.
    function smokeGetArbiterChatKeys(address diamond, address probe)
        public view returns (bytes32 boxKey, bytes32 signKey)
    {
        return ArbiterAccountabilityFacet(diamond).getArbiterChatKeys(probe);
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
    /// getArbiterFloor() returns DEFAULT_ARBITER_FLOOR when the storage field is zero
    /// (see the facet itself) — that is still a read of an existing field and not an
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
    function assertStorageContinuity(StorageSnapshot memory beforeCut, StorageSnapshot memory afterCut) public pure {
        require(
            afterCut.arbiterCount == beforeCut.arbiterCount,
            "post: getArbiters().length changed across the cut - storage layout may have shifted"
        );
        require(
            afterCut.vaultBalance == beforeCut.vaultBalance,
            "post: getVaultBalance() changed across the cut - storage layout may have shifted"
        );
        require(
            afterCut.arbiterFloor == beforeCut.arbiterFloor,
            "post: getArbiterFloor() changed across the cut - storage layout may have shifted"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Claims taken under the old signature — a loud warning, not a require.
    // ════════════════════════════════════════════════════════════════════

    /// A dispute claimed BEFORE the upgrade keeps its arbiter in disputeClaims after
    /// the cut (their openClaimCount is > 0), while getArbiterChatKeys returns zeroes
    /// for it — an old claim had no keys and could not have had any.
    /// getArbiterChatKeys teaches the reader to take zeroes as "there is nobody to
    /// present to", so a party would silently decide there is nothing to present —
    /// and there is a cure: the arbiter calls setArbiterChatKey() themselves at any
    /// moment, even in the middle of an open dispute (the gate there is isArbiter, not
    /// the absence of a key). NOT a require: those claims were taken lawfully, no key
    /// was required before the upgrade, and failing here would be a lie.
    ///
    /// It does NOT call getArbiterChatKeys(): this function is called BEFORE the
    /// broadcast (pre-flight), and getArbiterChatKeys is itself one of the three Add
    /// selectors of THIS cut, that is, on the live diamond it is NOT yet mounted at
    /// that moment — the call would revert "Diamond: Function does not exist". Nor is
    /// there any need to read it: before THIS upgrade setArbiterChatKey did not exist
    /// at all, so a key could not have appeared in principle — for any arbiter with
    /// openClaimCount > 0 it is guaranteed to be absent. openClaimCount alone (an
    /// existing selector, part of Replace) is enough.
    ///
    /// It enumerates over the current list of registered arbiters (getArbiters()) —
    /// an arbiter who has already lost their status but is still sitting in
    /// disputeClaims with an open counter will not be found by this walk; that is a
    /// separate and rarer case (see the warning in the setArbiterChatKey docstring
    /// about the exception to "the loop closes itself").
    function findArbitersWithOpenClaimsMissingKeys(address diamond) public view returns (address[] memory flagged) {
        ArbiterRegistryFacet f = ArbiterRegistryFacet(diamond);
        address[] memory arbiters = f.getArbiters();
        // getOpenClaimCount moved into the accountability facet on 16 August 2026.
        // The address is the same — it is the diamond; the cast only names the ABI.
        // The cut was executed on 10 August and is not rewritten.
        ArbiterAccountabilityFacet claims = ArbiterAccountabilityFacet(diamond);

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

    function warnArbitersWithOpenClaimsMissingKeys(address diamond) public view {
        address[] memory flagged = findArbitersWithOpenClaimsMissingKeys(diamond);
        console.log("=== Pre-flight: arbiters with open claims and no chat key ===");
        if (flagged.length == 0) {
            console.log("  none.");
            return;
        }
        for (uint256 i = 0; i < flagged.length; i++) {
            console.log("  MISSING KEY - arbiter:", flagged[i]);
            console.log("    openClaimCount:", ArbiterAccountabilityFacet(diamond).getOpenClaimCount(flagged[i]));
            console.log("    -> must call setArbiterChatKey(boxKey, signKey) after this upgrade");
        }
        console.log("Total arbiters needing setArbiterChatKey after upgrade:", flagged.length);
    }

    function totalRoutedSelectors(address diamond) public view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(diamond).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    /// Extracted into a public pure function so a test can check the cut's composition without a rollout.
    function buildCuts(address facet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = _cut(address(0), IDiamondCut.FacetCutAction.Remove,  removeSelectors());
        cuts[1] = _cut(facet,      IDiamondCut.FacetCutAction.Replace, replaceSelectors());
        cuts[2] = _cut(facet,      IDiamondCut.FacetCutAction.Add,     addSelectors());
    }

    function removeSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("claimDispute(address,bytes32)"));
    }

    function addSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](3);
        sels[0] = ArbiterRegistryFacet.claimDispute.selector;
        sels[1] = ArbiterRegistryFacet.setArbiterChatKey.selector;
        sels[2] = ArbiterAccountabilityFacet.getArbiterChatKeys.selector;
    }

    /// Every mounted facet selector EXCEPT the three new ones and the one being
    /// removed. The list comes from script/DeployFull.s.sol,
    /// arbiterRegistryFacetSelectors() (56 selectors), minus claimDispute (a new
    /// signature, going into Add) and setArbiterChatKey/getArbiterChatKeys (new, also
    /// in Add). Completeness is checked by a test against the compiled ABI, not by eye.
    function replaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](53);

        // DAO mode
        sels[0]  = ArbiterRegistryFacet.activateDAO.selector;
        sels[1]  = ArbiterRegistryFacet.applyAsArbiter.selector;
        sels[2]  = ArbiterRegistryFacet.resignAsArbiter.selector;

        // Admin: managing arbiters
        sels[3]  = ArbiterRegistryFacet.setChiefArbiter.selector;
        sels[4]  = ArbiterRegistryFacet.addArbiter.selector;
        sels[5]  = bytes4(0x3487e08c) /* removeArbiter(address), removed 15 August 2026 */;

        // Claiming a dispute (commit-reveal) — claimDispute itself is NOT here: its
        // signature changed, and the new selector goes into Add.
        sels[6]  = ArbiterRegistryFacet.commitDisputeClaim.selector;
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
        sels[30] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        sels[31] = ArbiterRegistryFacet.getClaimCommitment.selector;
        sels[32] = ArbiterRegistryFacet.getPendingVerdict.selector;
        sels[33] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        sels[34] = ArbiterRegistryFacet.getVaultBalance.selector;
        sels[35] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        sels[36] = ArbiterRegistryFacet.getDAOAddress.selector;
        sels[37] = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;
        sels[38] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        sels[39] = ArbiterRegistryFacet.getAppealVotes.selector;
        sels[40] = ArbiterRegistryFacet.hasVotedOnAppeal.selector;
        sels[41] = ArbiterAccountabilityFacet.getArbiterBond.selector;
        sels[42] = ArbiterAccountabilityFacet.getOpenClaimCount.selector;

        // The dispute fee (3% of the disputed amount) — split 80/20 arbiter/treasury
        sels[43] = ArbiterRegistryFacet.creditDisputeFee.selector;
        sels[44] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        sels[45] = ArbiterRegistryFacet.getTreasurySlice.selector;

        // The paid arbiter call: the floor and the quote for the top-up to it
        sels[46] = ArbiterRegistryFacet.setArbiterFloor.selector;
        sels[47] = ArbiterRegistryFacet.getArbiterFloor.selector;
        sels[48] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;

        // The paid arbiter call: payment and the soft refund of the top-up
        sels[49] = ArbiterRegistryFacet.fundDispute.selector;
        sels[50] = ArbiterRegistryFacet.getDisputeBounty.selector;
        sels[51] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        sels[52] = ArbiterRegistryFacet.getRefundableBounty.selector;

        // getArbiterChatKeys/setArbiterChatKey and the new claimDispute go into Add,
        // not here (see addSelectors()).
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
