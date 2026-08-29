// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradePaidArbitration.s.sol
//
// Moves the LIVE diamond 0x760F07367888C62f7c2Dfb619A5e534132855ce5 onto the paid
// arbiter call: a party to a dispute may top the pot up to the floor
// (`arbiterFloor`) so that an arbiter takes the dispute rather than waiting for a
// volunteer on a small pot; the top-up goes to the arbiter on a verdict and comes
// back to whoever paid it if the dispute ended without one (a timeout or a dispute
// split). Along with it, a count is kept of how many participants had a dispute
// close without a verdict (`getUnresolvedDisputes`).
//
// ── THE BASELINE IS THE CHAIN, NOT THE BRANCH. ───────────────────────────
// The live diamond was assembled by script/DeployFull.s.sol on 25.07.2026 and has
// been patched since (see the header of the fee-model upgrade for the full chain).
// The last real (non dry-run) patch at the time this file was written was the
// fee-model upgrade itself (30.07.2026): Replace 106 + Add 14 selectors across six
// facets, including ArbiterRegistryFacet (Replace 44 old + Add 3 new:
// creditDisputeFee, withdrawTreasurySlice, getTreasurySlice — the 3% fee on the
// disputed amount). The live ArbiterRegistryFacet is now
// 0xc60bf9da775555859df5c7180ad19dcbc181d342 (broadcast/UpgradeFeeModel.s.sol
// /84532/run-latest.json) and NOT the 0xf707aa69... from DeployFull. ReputationFacet
// has never received a patch — its live address is
// 0xce3bc88f78b1576576a3196bcaf09faba709701f, the one DeployFull deployed on 25.07.
//
// As in the fee-model upgrade: this script reads the CURRENT addresses and
// selectors FROM THE CHAIN through facetAddress()/facets() at the moment it runs,
// and substitutes nothing listed above as a constant — its correctness does not
// depend on whether the diamond was patched again in the meantime.
//
// ── WHAT CHANGES ─────────────────────────────────────────────────────────
// Two facets: ArbiterRegistryFacet and ReputationFacet.
//
// On chain right now (after the fee-model upgrade) ArbiterRegistryFacet carries 47
// selectors and ReputationFacet 8. In the current sources those same two facets
// have 54 and 9. Add is EXACTLY EIGHT:
//
//   ArbiterRegistryFacet (7): fundDispute, getArbiterFloor,
//                              getDisputeBounty, getRefundableBounty,
//                              quoteDisputeTopUp, setArbiterFloor,
//                              withdrawDisputeBounty
//   ReputationFacet      (1): getUnresolvedDisputes
//
// ── THERE ARE EXACTLY TWO ACTIONS, NOT THREE ─────────────────────────────
// An early design laid down a third action — a Remove of
// `setRewardPerDispute`/`getRewardPerDispute`, withdrawing the vault's flat payout
// per dispute (rejected by design on 28 July, see the header of
// ArbiterRegistryFacet.sol). That was CANCELLED BEFORE THIS SCRIPT and not in it:
// both functions are still in the sources and still mounted today (Replace, not
// Remove).
//
//   - setRewardPerDispute(uint256) is now `external pure` and reverts
//     unconditionally with a custom RewardPathRetired() error. The reason is not
//     removeFunctions but that eight historical scripts in script/ refer to its
//     selector in their mounting lists at compile time (DeployFull.s.sol,
//     PatchArbiterAutoCleanup.s.sol, PatchArbiterClearStuck.s.sol,
//     UpgradeArbiterRegistryFacetAppeal.s.sol,
//     UpgradeArbiterRegistryFacetBondAndGuard.s.sol,
//     UpgradeArbiterRegistryFacetDemotion.s.sol, UpgradeArbiterRegistryV3.s.sol,
//     UpgradeFeeModel.s.sol) — deleting the function from the source breaks the
//     build of the whole script/ folder, and broadcast/ is in .gitignore, so those
//     scripts are the only remaining record of the upgrades that happened.
//   - getRewardPerDispute() stayed as a legacy getter: nobody writes the field it
//     reads any more, and the value is always 0.
//
// Neither function's selector changed — so for diamondCut this is an ORDINARY
// Replace, like the other 45 functions of the facet whose signatures did not
// change. A Remove here would be not merely superfluous but WRONG: it would take a
// live, callable function (predictably reverting though it is) off the diamond,
// replacing a predictable custom revert with "Diamond: function not found".
//
// ── REPLACE AND ADD ARE SEPARATE FacetCut ENTRIES ────────────────────────
// Not one selector is in both: DiamondCutLib.replaceFunctions reverts on
// `oldFacetAddress == _facetAddress` (the same address — a Replace is meaningless
// — and on "the selector is not mounted"), while DiamondCutLib.addFunctions
// reverts on `oldFacetAddress != address(0)` (the selector already exists). Both
// lists for each facet are checked on chain BEFORE the broadcast (see run() —
// _checkReplaceGroup/_checkAddGroup).
//
// ── THE SELECTOR LISTS COME FROM THE SOURCES, NOT FROM A HAND ────────────
// As in the fee-model upgrade: each list is a `public pure` function of the form
// `<Facet>.<fn>.selector`, a single source of truth for
// buildPaidArbitrationCuts() below and for
// test/UpgradePaidArbitrationSelectors.t.sol, which compares them against
// `out/<Facet>.sol/<Facet>.json`.methodIdentifiers.
//
// ── NO `_init` IS NEEDED ─────────────────────────────────────────────────
// `arbiterFloor` is read through getArbiterFloor(), which substitutes the default
// of 10 USDC in the getter itself on a zero storage field
// (`f == 0 ? DEFAULT_ARBITER_FLOOR : f`). There is nothing to seed — unlike
// feeFloor in the fee-model upgrade (where a zero floor means "not configured" and
// quote() reverts), here a zero in storage is a VALID and expected starting state,
// interpreted as "the default floor".
//
// ── ⚠️  A WARNING ABOUT ROLLING BACK — A VERIFIED FACT, NOT A GUESS ──────
// The eight Add selectors of this cut CANNOT be rolled back with a Replace onto
// the old (pre-upgrade) facet address. DiamondCutLib.replaceFunctions checks only
// that the target facetAddress differs from the current one and has a non-zero
// code.length — whether it implements THE SELECTOR ITSELF is NEVER checked. Such a
// Replace succeeds, facets()/facetFunctionSelectors() will show the selector
// mounted on the old address, and every call will revert with EMPTY returndata
// (the address itself holds no code for that selector — it will fall into the old
// facet's fallback or simply into emptiness, depending on what is there). Invisible
// to facet-level monitoring: the loupe lies that everything is mounted normally.
//
// The only correct way to roll back the eight Add selectors is a Remove (action 2,
// where `facetAddress` MUST be address(0)). It is printed in plain text at the end
// of run() below.
//
// Usage (a dry run — always this one first):
//   forge script script/UpgradePaidArbitration.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (a real run):
//   forge script script/UpgradePaidArbitration.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../../src/DiamondProxy.sol";
import "../../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../../src/facets/ArbiterAccountabilityFacet.sol";
import "../../src/facets/ReputationFacet.sol";

contract UpgradePaidArbitration is Script {

    function run() external {
        address diamond     = vm.envAddress("DIAMOND_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(deployerKey);

        // ── Pre-flight ────────────────────────────────────────────────────
        require(diamond != address(0), "UpgradePaidArbitration: DIAMOND_ADDRESS is zero");
        require(diamond.code.length > 0, "UpgradePaidArbitration: DIAMOND_ADDRESS has no code");

        address currentOwner = OwnershipFacet(diamond).owner();
        require(
            currentOwner == broadcaster,
            "UpgradePaidArbitration: PRIVATE_KEY is not the diamond owner - diamondCut would revert"
        );

        console.log("=== UpgradePaidArbitration: pre-flight ===");
        console.log("Diamond: ", diamond);
        console.log("Owner:   ", currentOwner);
        console.log("");

        bytes4[] memory arbiterReplace = arbiterRegistryFacetReplaceSelectors();
        bytes4[] memory arbiterAdd     = arbiterRegistryFacetAddSelectors();
        bytes4[] memory reputeReplace  = reputationFacetReplaceSelectors();
        bytes4[] memory reputeAdd      = reputationFacetAddSelectors();

        // Every Replace selector is mounted now, and all the selectors of one facet
        // point at ONE and the same live address (otherwise the Replace list for that
        // facet was derived wrongly).
        address oldArbiter = _checkReplaceGroup("ArbiterRegistryFacet", arbiterReplace, diamond);
        address oldRepute  = _checkReplaceGroup("ReputationFacet",      reputeReplace, diamond);

        // Not one of the eight Add selectors is mounted anywhere on the diamond.
        _checkAddGroup("ArbiterRegistryFacet", arbiterAdd, diamond);
        _checkAddGroup("ReputationFacet",      reputeAdd, diamond);

        uint256 selectorsBefore = _totalRoutedSelectors(diamond);
        console.log("");
        console.log("Total routed selectors BEFORE cut:", selectorsBefore);
        console.log("");

        // ── The upgrade ───────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        ArbiterRegistryFacet newArbiter = new ArbiterRegistryFacet();
        ReputationFacet      newRepute  = new ReputationFacet();

        console.log("=== New facet implementations ===");
        console.log("ArbiterRegistryFacet: ", address(newArbiter));
        console.log("ReputationFacet:      ", address(newRepute));
        console.log("");

        IDiamondCut.FacetCut[] memory cuts = buildPaidArbitrationCuts(
            address(newArbiter), address(newRepute)
        );

        // No _init: getArbiterFloor() substitutes the default itself, and there is
        // nothing to seed (see the file header).
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        vm.stopBroadcast();

        // ── Post-flight ───────────────────────────────────────────────────
        console.log("=== Post-flight ===");

        _assertRouted("ArbiterRegistryFacet Replace", arbiterReplace, address(newArbiter), diamond);
        _assertRouted("ArbiterRegistryFacet Add",     arbiterAdd,     address(newArbiter), diamond);
        _assertRouted("ReputationFacet Replace",      reputeReplace,  address(newRepute),  diamond);
        _assertRouted("ReputationFacet Add",           reputeAdd,      address(newRepute),  diamond);

        require(IDiamondLoupe(diamond).facetFunctionSelectors(oldArbiter).length == 0, "post: old ArbiterRegistryFacet still holds selectors");
        require(IDiamondLoupe(diamond).facetFunctionSelectors(oldRepute).length == 0,  "post: old ReputationFacet still holds selectors");
        console.log("Both old facet addresses hold zero selectors (fully displaced).");
        console.log("");

        uint256 selectorsAfter = _totalRoutedSelectors(diamond);
        require(selectorsAfter == selectorsBefore + 8, "post: expected exactly +8 routed selectors after the cut");
        console.log("Total routed selectors AFTER cut: ", selectorsAfter);
        console.log("");

        uint256 floor = ArbiterRegistryFacet(diamond).getArbiterFloor();
        console.log("getArbiterFloor():", floor, "(expect 10000000 - 10 USDC default, field unseeded)");
        require(floor == 10_000_000, "post: getArbiterFloor() did not return the unseeded default");

        // getUnresolvedDisputes() must be callable and must return 0 for an address
        // with no history of disputes without a verdict - which confirms that the
        // selector really leads into the new ReputationFacet rather than merely
        // counting as mounted.
        uint256 unresolved = ReputationFacet(diamond).getUnresolvedDisputes(broadcaster);
        console.log("getUnresolvedDisputes(broadcaster):", unresolved);
        console.log("");

        console.log("=== Paid arbitration live on chain ===");
        console.log("Any dispute party can call fundDispute(agreement) to top up the arbiter's");
        console.log("cut to the floor (default 10 USDC); withdrawDisputeBounty() pulls a soft");
        console.log("refund if the push-refund failed (e.g. blacklisted USDC recipient).");
        console.log("");

        console.log("=== Rollback ===");
        console.log("One diamondCut: Replace each of the two groups above back onto <old*>, PLUS");
        console.log("Remove (action 2, facetAddress MUST be address(0) - see DiamondCutLib.removeFunctions)");
        console.log("of the 8 Add selectors, in the SAME cut.");
        console.log("");
        console.log("NEVER Replace the 8 Add selectors onto an old facet. That cut does NOT");
        console.log("revert - replaceFunctions only checks the target facet is a DIFFERENT");
        console.log("address that has SOME code, never that it implements the selector. It");
        console.log("succeeds, loupe reports the selector mounted, and every call to it reverts");
        console.log("with empty returndata. Silent and invisible to facet-level monitoring.");
        console.log("Remove is the only correct action for them.");
        console.log("  <old ArbiterRegistryFacet> =", oldArbiter);
        console.log("  <old ReputationFacet>      =", oldRepute);
    }

    // ════════════════════════════════════════════════════════════════════
    // Pre/post-flight helpers (same shape as script/UpgradeFeeModel.s.sol)
    // ════════════════════════════════════════════════════════════════════

    /// Checks that every selector in the group is mounted (otherwise Replace reverts
    /// "selector not exist" in DiamondCutLib.replaceFunctions) and that they all
    /// point at ONE and the same current address — if they do not, the Replace list
    /// for that facet was derived wrongly (part of the functions has already moved to
    /// another facet, say). Returns that address.
    function _checkReplaceGroup(string memory label, bytes4[] memory sels, address diamond)
        internal view returns (address facetAddr)
    {
        require(sels.length > 0, string.concat(label, ": replace group is empty"));
        facetAddr = IDiamondLoupe(diamond).facetAddress(sels[0]);
        require(facetAddr != address(0), string.concat(label, ": selector[0] is not mounted at all"));
        for (uint256 i = 0; i < sels.length; i++) {
            address a = IDiamondLoupe(diamond).facetAddress(sels[i]);
            require(a != address(0), string.concat(label, ": a replace selector is not mounted"));
            require(a == facetAddr, string.concat(label, ": replace selectors are split across more than one live facet address"));
        }
        console.log(string.concat(label, " currently mounted at:"), facetAddr);
        console.log(string.concat(label, " selectors to Replace:"), sels.length);
    }

    /// Checks that not one selector in the group is mounted yet — otherwise Add
    /// reverts "selector exists" in DiamondCutLib.addFunctions.
    function _checkAddGroup(string memory label, bytes4[] memory sels, address diamond) internal view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == address(0),
                string.concat(label, ": an Add selector is already mounted somewhere - Add would revert")
            );
        }
        console.log(string.concat(label, " selectors to Add (currently unmounted):"), sels.length);
    }

    function _assertRouted(string memory label, bytes4[] memory sels, address expected, address diamond) internal view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                string.concat(label, ": a selector did not land on the new facet")
            );
        }
        console.log(string.concat(label, " -> "), expected);
    }

    function _totalRoutedSelectors(address diamond) internal view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(diamond).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    // ════════════════════════════════════════════════════════════════════
    // The FacetCut[] builder — extracted into a public pure function so that
    // test/UpgradePaidArbitrationSelectors.t.sol can compare its output against the
    // live ABIs without running the script again. run() above builds its cuts
    // through this very function and duplicates nothing by hand.
    // ════════════════════════════════════════════════════════════════════

    function buildPaidArbitrationCuts(address arbiterAddr, address reputeAddr)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = _cut(arbiterAddr, IDiamondCut.FacetCutAction.Replace, arbiterRegistryFacetReplaceSelectors());
        cuts[1] = _cut(arbiterAddr, IDiamondCut.FacetCutAction.Add,     arbiterRegistryFacetAddSelectors());
        cuts[2] = _cut(reputeAddr,  IDiamondCut.FacetCutAction.Replace, reputationFacetReplaceSelectors());
        cuts[3] = _cut(reputeAddr,  IDiamondCut.FacetCutAction.Add,     reputationFacetAddSelectors());
    }

    // ── Per-facet selector arrays (ground truth: `forge inspect <Facet> methodIdentifiers`) ──
    // Split Replace (already on chain today, after UpgradeFeeModel for
    // ArbiterRegistryFacet) vs. Add (the 8 new selectors from Tasks 1-4 of
    // the paid-arbitration plan).

    // ArbiterRegistryFacet — 47 Replace (unchanged signatures, incl. the
    // retired-but-mounted setRewardPerDispute/getRewardPerDispute pair —
    // see file header) + 7 Add (paid arbiter call: floor, quote, fund, refund)
    function arbiterRegistryFacetReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](47);
        sels[0]  = ArbiterRegistryFacet.activateDAO.selector;
        sels[1]  = ArbiterRegistryFacet.applyAsArbiter.selector;
        sels[2]  = ArbiterRegistryFacet.resignAsArbiter.selector;
        sels[3]  = ArbiterRegistryFacet.setChiefArbiter.selector;
        sels[4]  = ArbiterRegistryFacet.addArbiter.selector;
        sels[5]  = bytes4(0x3487e08c) /* removeArbiter(address), removed 15 August 2026 */;
        sels[6]  = ArbiterRegistryFacet.commitDisputeClaim.selector;
        sels[7]  = bytes4(keccak256("claimDispute(address,bytes32)")) /* frozen: old 2-arg selector, historical cut */;
        sels[8]  = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        sels[9]  = ArbiterRegistryFacet.clearDisputeClaim.selector;
        sels[10] = ArbiterRegistryFacet.submitVerdict.selector;
        sels[11] = ArbiterRegistryFacet.finalizeVerdict.selector;
        sels[12] = ArbiterRegistryFacet.overturnVerdict.selector;
        sels[13] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        sels[14] = ArbiterRegistryFacet.freezeVerdict.selector;
        sels[15] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        sels[16] = ArbiterRegistryFacet.clearStuckVerdict.selector;
        sels[17] = ArbiterRegistryFacet.raiseAppeal.selector;
        sels[18] = ArbiterRegistryFacet.voteOnAppeal.selector;
        sels[19] = ArbiterRegistryFacet.resolveAppeal.selector;
        sels[20] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        sels[21] = ArbiterRegistryFacet.fundVault.selector;
        sels[22] = ArbiterRegistryFacet.setRewardPerDispute.selector; // retired: reverts RewardPathRetired, still mounted (see file header)
        sels[23] = ArbiterRegistryFacet.setDAOAddress.selector;
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
        sels[36] = ArbiterRegistryFacet.getRewardPerDispute.selector; // retired: always reads 0, still mounted (see file header)
        sels[37] = ArbiterRegistryFacet.getDAOAddress.selector;
        sels[38] = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;
        sels[39] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        sels[40] = ArbiterRegistryFacet.getAppealVotes.selector;
        sels[41] = ArbiterRegistryFacet.hasVotedOnAppeal.selector;
        sels[42] = ArbiterAccountabilityFacet.getArbiterBond.selector;
        sels[43] = ArbiterAccountabilityFacet.getOpenClaimCount.selector;
        sels[44] = ArbiterRegistryFacet.creditDisputeFee.selector;
        sels[45] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        sels[46] = ArbiterRegistryFacet.getTreasurySlice.selector;
    }

    function arbiterRegistryFacetAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](7);
        sels[0] = ArbiterRegistryFacet.setArbiterFloor.selector;
        sels[1] = ArbiterRegistryFacet.fundDispute.selector;
        sels[2] = ArbiterRegistryFacet.getDisputeBounty.selector;
        sels[3] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        sels[4] = ArbiterRegistryFacet.getRefundableBounty.selector;
        sels[5] = ArbiterRegistryFacet.getArbiterFloor.selector;
        sels[6] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;
    }

    // ReputationFacet — 8 Replace (unchanged) + 1 Add (unresolved-dispute counter)
    function reputationFacetReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](8);
        sels[0] = ReputationFacet.autoAwardXP.selector;
        sels[1] = ReputationFacet.claimXP.selector;
        sels[2] = ReputationFacet.notifyExecutorFault.selector;
        sels[3] = ReputationFacet.getXP.selector;
        sels[4] = ReputationFacet.getUniqueActiveUsers.selector;
        sels[5] = ReputationFacet.hasClaimed.selector;
        sels[6] = ReputationFacet.isDealWin.selector;
        sels[7] = ReputationFacet.getCleanStreak.selector;
    }

    function reputationFacetAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = ReputationFacet.getUnresolvedDisputes.selector;
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory sels)
        internal pure returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({ facetAddress: facet, action: action, functionSelectors: sels });
    }
}
