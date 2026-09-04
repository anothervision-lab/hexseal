// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../script/archive/UpgradePaidArbitration.s.sol";
import "../script/DeployFull.s.sol";
import "../src/DiamondProxy.sol";

/// Anti-drift gate for script/UpgradePaidArbitration.s.sol — same design as
/// test/UpgradeFeeModelSelectors.t.sol, adapted for a two-facet, Replace+Add
/// (no Remove) upgrade.
///
/// Ground truth is read directly out of the compiled artifact
/// (`out/<Facet>.sol/<Facet>.json`'s `methodIdentifiers` map), not hand-typed
/// here. This test fails if:
///   - the two facets' Replace+Add builders together miss a selector the
///     facet really implements (undercut)
///   - the two facets' Replace+Add builders together claim a selector the
///     facet does not implement (phantom)
///   - the same selector appears in BOTH a facet's Replace list and its Add
///     list (would make one of the two FacetCut entries in
///     buildPaidArbitrationCuts() revert on chain: Replace of a
///     not-yet-mounted selector, or Add of an already-mounted one — see
///     DiamondCutLib.replaceFunctions / addFunctions in src/DiamondProxy.sol)
///   - buildPaidArbitrationCuts() wires a selector set to the wrong
///     facetAddress or the wrong FacetCutAction
///   - any of the 8 Add selectors collides with anything the OTHER nine
///     facets (DiamondCut/Loupe/Ownership/Factory/JobBoard/ServiceBoard/
///     Registry/DealMetadata/JobReceipt, via DeployFull's own
///     already-gated builders) implement today — this is the static
///     equivalent of the script's own runtime _checkAddGroup: if an Add
///     selector already existed anywhere on the live ABI, the collision
///     scan below would show a duplicate
///   - the grand total drifts from 55 Replace-eligible (this upgrade's two
///     facets, pre-upgrade) / 8 Add / 167 (post-upgrade, all eleven facets)
///
/// UPDATE (9 August 2026): the "not broadcast yet" claim above is stale — the
/// header comment in script/UpgradePaidArbitration.s.sol still calls this a
/// dry run, but broadcast/UpgradePaidArbitration.s.sol/84532/run-latest.json
/// holds three real transactions with status 0x1 at block 0x2acaff6/0x2acaff7
/// (31 July 2026), the same shape as the confirmed UpgradeFeeModel broadcast.
/// So this script IS live history now, same as UpgradeFeeModel — the direct
/// live-ABI comparison for ArbiterRegistryFacet was removed for exactly the
/// same reason it was removed from test/UpgradeFeeModelSelectors.t.sol on 31
/// July: this facet's ABI kept growing afterward (getArbiterChatKeys, 9
/// August 2026), and comparing a frozen historical Replace+Add list against a
/// live-growing ABI means demanding the past match the present. See
/// testArbiterRegistryFacetSelectors() below.
///
/// The nine untouched facets are still read LIVE from DeployFull.s.sol's own
/// already-gated builders (test/DeployFullSelectors.t.sol), not hardcoded:
/// a real diamond built from today's source really would mount today's ABI,
/// so the collision scan below tracks that source, not a snapshot of it. The
/// 167 grand total is this script's OWN historical delivery (54 + 9 across
/// the two touched facets, as computed from the upgrade contract's own
/// Replace+Add lists — not from live ABI), and is expected to no longer equal
/// a fresh DeployFull total once other facets grow (DeployFull is at 169
/// since 9 August 2026's arbiter chat keys plus same-day setArbiterChatKey;
/// this script's own math is unaffected and stays 167).
contract UpgradePaidArbitrationSelectorsTest is Test {
    UpgradePaidArbitration internal upgrade;
    DeployFull internal deploy;

    // Placeholder facet addresses — buildPaidArbitrationCuts is pure and only
    // threads the address through into the FacetCut struct, so any nonzero,
    // pairwise-distinct address works.
    address constant ARBITER_FACET = address(0x3001);
    address constant REPUTE_FACET  = address(0x3002);

    function setUp() public {
        upgrade = new UpgradePaidArbitration();
        deploy  = new DeployFull();
    }

    // ── Ground truth: read straight out of the compiled artifact ────────────
    function _abiSelectors(string memory sourceFile, string memory contractName) internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(string.concat("out/", sourceFile, ".sol/", contractName, ".json"));
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; i++) out[i] = bytes4(keccak256(bytes(sigs[i])));
    }

    function _abiSelectors(string memory contractName) internal view returns (bytes4[] memory) {
        return _abiSelectors(contractName, contractName);
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }

    // ── Set-equality helper (identical to DeployFullSelectorsTest / UpgradeFeeModelSelectorsTest) ──
    function _assertSameSelectorSet(bytes4[] memory actual, bytes4[] memory expected, string memory label) internal pure {
        assertEq(actual.length, expected.length, string.concat(label, ": selector count mismatch"));

        for (uint256 i = 0; i < actual.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < expected.length; j++) {
                if (actual[i] == expected[j]) { found = true; break; }
            }
            assertTrue(found, string.concat(label, ": script mounts a selector no facet implements (phantom)"));
        }

        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < actual.length; j++) {
                if (expected[i] == actual[j]) { found = true; break; }
            }
            assertTrue(found, string.concat(label, ": facet has a selector the script does not mount (undercut)"));
        }
    }

    /// Replace and Add for the same facet must never share a selector: one of
    /// the two FacetCut entries would revert on chain (Replace of an unmounted
    /// selector, or Add of an already-mounted one).
    function _assertDisjoint(bytes4[] memory replaceSels, bytes4[] memory addSels, string memory label) internal pure {
        for (uint256 i = 0; i < replaceSels.length; i++) {
            for (uint256 j = 0; j < addSels.length; j++) {
                assertTrue(
                    replaceSels[i] != addSels[j],
                    string.concat(label, ": the same selector appears in both Replace and Add")
                );
            }
        }
    }

    // ── Per-facet drift checks: Replace ∪ Add must equal the real ABI ───────

    function testArbiterRegistryFacetSelectors() public view {
        bytes4[] memory replace = upgrade.arbiterRegistryFacetReplaceSelectors();
        bytes4[] memory add     = upgrade.arbiterRegistryFacetAddSelectors();
        assertEq(replace.length, 47, "ArbiterRegistryFacet: expected 47 Replace selectors");
        assertEq(add.length, 7, "ArbiterRegistryFacet: expected 7 Add selectors");
        _assertDisjoint(replace, add, "ArbiterRegistryFacet");
        // The cross-check against the live ABI and against DeployFull was
        // dropped on 9 August 2026, the same way and for the same reason as
        // in UpgradeFeeModelSelectors' arbiter-registry case on 31 July: this
        // script really was broadcast (see the UPDATE in the file header), so
        // Replace+Add here is a record of what was mounted on 31 July. The
        // facet ABI keeps growing (getArbiterChatKeys, 9 August), and
        // demanding equality with the live ABI or with DeployFull would be
        // demanding that the past agree with the present. Drift in fresh
        // deployments is caught by DeployFullSelectors, and new cuts by their
        // own gates.
    }

    function testReputationFacetSelectors() public view {
        bytes4[] memory replace = upgrade.reputationFacetReplaceSelectors();
        bytes4[] memory add     = upgrade.reputationFacetAddSelectors();
        assertEq(replace.length, 8, "ReputationFacet: expected 8 Replace selectors");
        assertEq(add.length, 1, "ReputationFacet: expected 1 Add selector");
        _assertDisjoint(replace, add, "ReputationFacet");
        _assertSameSelectorSet(_concat(replace, add), _abiSelectors("ReputationFacet"), "ReputationFacet");
        _assertSameSelectorSet(_concat(replace, add), deploy.reputationFacetSelectors(), "ReputationFacet vs DeployFull");
    }

    // ── FacetCut[] builder checks ─────────────────────────────────────────
    // Exercises the exact function run() calls to build what it actually
    // broadcasts — catching a facetAddress/action/selector-set mixup (e.g.
    // ArbiterRegistry's Add selectors wired to Reputation's address, or a
    // Replace entry accidentally carrying the Add action) that the per-facet
    // selector tests above cannot see.

    function testBuildPaidArbitrationCutsWiring() public view {
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildPaidArbitrationCuts(ARBITER_FACET, REPUTE_FACET);
        assertEq(cuts.length, 4, "buildPaidArbitrationCuts: expected 4 FacetCut entries (2 facets, each Replace+Add)");

        assertEq(cuts[0].facetAddress, ARBITER_FACET);
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace, "cuts[0] must be Replace");
        _assertSameSelectorSet(cuts[0].functionSelectors, upgrade.arbiterRegistryFacetReplaceSelectors(), "cuts[0] ArbiterRegistryFacet Replace");

        assertEq(cuts[1].facetAddress, ARBITER_FACET);
        assertTrue(cuts[1].action == IDiamondCut.FacetCutAction.Add, "cuts[1] must be Add");
        _assertSameSelectorSet(cuts[1].functionSelectors, upgrade.arbiterRegistryFacetAddSelectors(), "cuts[1] ArbiterRegistryFacet Add");

        assertEq(cuts[2].facetAddress, REPUTE_FACET);
        assertTrue(cuts[2].action == IDiamondCut.FacetCutAction.Replace, "cuts[2] must be Replace");
        _assertSameSelectorSet(cuts[2].functionSelectors, upgrade.reputationFacetReplaceSelectors(), "cuts[2] ReputationFacet Replace");

        assertEq(cuts[3].facetAddress, REPUTE_FACET);
        assertTrue(cuts[3].action == IDiamondCut.FacetCutAction.Add, "cuts[3] must be Add");
        _assertSameSelectorSet(cuts[3].functionSelectors, upgrade.reputationFacetAddSelectors(), "cuts[3] ReputationFacet Add");
    }

    // ── Cross-cutting invariants ─────────────────────────────────────────

    function testReplaceCountMatchesCurrentLiveTotalForTouchedFacets() public view {
        uint256 replaceTotal =
            upgrade.arbiterRegistryFacetReplaceSelectors().length +
            upgrade.reputationFacetReplaceSelectors().length;
        // Live diamond today (after UpgradeFeeModel, before this cut) mounts
        // 47 ArbiterRegistryFacet + 8 ReputationFacet selectors — see the
        // script header for how 47 and 8 were derived from
        // broadcast/UpgradeFeeModel.s.sol/84532/run-latest.json + the live
        // ReputationFacet ABI, which this script's own Replace lists must
        // reproduce exactly (otherwise Replace reverts on an unmounted
        // selector, or misses one that's actually live).
        assertEq(replaceTotal, 55, "sum of both Replace groups should be 55 (47 ArbiterRegistry + 8 Reputation)");
    }

    function testAddCountIsExactlyEight() public view {
        uint256 addTotal =
            upgrade.arbiterRegistryFacetAddSelectors().length +
            upgrade.reputationFacetAddSelectors().length;
        assertEq(addTotal, 8, "this release must add exactly 8 selectors, no more, no less");
    }

    function testNoSelectorCollisionsAcrossAllElevenFacetsPostUpgrade() public view {
        bytes4[][11] memory groups = [
            // Untouched by this release (ground truth: DeployFull.s.sol,
            // itself gated against the artifacts by test/DeployFullSelectors.t.sol).
            // Deliberately LIVE, not frozen: a real diamond built from
            // today's DeployFull.s.sol really would mount today's ABI for
            // these nine facets, so the collision scan below must see the
            // same set a live deploy (or the live diamond, since none of
            // these nine changed since 25/30 July) would — freezing this
            // group could hide a real collision introduced by a later,
            // unrelated facet change.
            deploy.cutFacetSelectors(),
            deploy.loupeFacetSelectors(),
            deploy.ownershipFacetSelectors(),
            deploy.registryFacetSelectors(),
            deploy.factoryFacetSelectors(),
            deploy.jobBoardFacetSelectors(),
            deploy.serviceBoardFacetSelectors(),
            deploy.dealMetadataFacetSelectors(),
            deploy.jobReceiptFacetSelectors(),
            // Changed by this release
            _concat(upgrade.arbiterRegistryFacetReplaceSelectors(), upgrade.arbiterRegistryFacetAddSelectors()),
            _concat(upgrade.reputationFacetReplaceSelectors(), upgrade.reputationFacetAddSelectors())
        ];

        uint256 total;
        for (uint256 g = 0; g < groups.length; g++) total += groups[g].length;

        // 167 is this script's OWN historical delivery — the diamond really
        // did route exactly this many selectors right after this script's
        // 31 July 2026 broadcast (see the UPDATE note in the file header),
        // computed here as a cross-check between two independently written
        // selector lists at that point in time (this script's Replace+Add
        // builders vs. what DeployFull.s.sol's Add-only builders produced
        // for the nine untouched facets back then). It is frozen ON
        // PURPOSE and must NOT move in lockstep with
        // test/DeployFullSelectors.t.sol's own total: that total is a LIVE
        // read of today's source and has already grown past this number
        // (169 since 9 August 2026's arbiter chat keys) for reasons this
        // script's own history has nothing to do with — this facet's ABI
        // kept growing after 31 July, same as testArbiterRegistryFacetSelectors()
        // above explains. If a later, unrelated facet legitimately grows,
        // DeployFullSelectors.t.sol's total moves; this 167 does not.
        //
        // ⚠️ 167 -> 169 on 25 August 2026, and the word "frozen" above needs
        // the qualification this number never had: only TWO of the eleven
        // groups are frozen (this script's own Replace+Add builders). The
        // other NINE are read live from DeployFull, by deliberate design three
        // paragraphs up — so the total was only ever frozen for as long as
        // none of those nine grew. FactoryFacet just did: +2
        // (getUndeliveredFees, withdrawUndeliveredFees), because a fee the
        // recipient refuses now becomes a debt instead of blocking a person's
        // refund. The delivery this script made on 31 July is unchanged; what
        // moved is the live half of the sum, and it will move again.
        // 169 -> 170 on 31 August 2026: RegistryFacet gained
        // `notifyWorkHandedIn()`, and this total reads nine facets live from
        // DeployFull, so the registry's growth lands here even though this
        // archived script never touched it.
        // 170 -> 175 on 3 September 2026, in ONE cut carrying two deliveries.
        // Four are the emergency brake (decision 17) -- `pauseNewDeals`,
        // `resumeNewDeals`, `newDealsPausedUntil` and the
        // `NEW_DEALS_PAUSE_DURATION` getter. The fifth is `MAX_FEE_BPS()`
        // (item 138), the 20% fee ceiling that stood as a bare `2_000` in
        // `initFeeModel` and `setFeeBps` and could be read from nowhere. Same
        // mechanism as the two moves above: FactoryFacet is one of the nine read
        // LIVE from DeployFull, so its growth lands in this sum even though this
        // archived script never touched it. The 31 July delivery of 63 is
        // unchanged.
        assertEq(total, 175, "post-upgrade diamond should route exactly 175 selectors across all 11 facets (this script's 31 July 2026 delivery of 63, plus nine facets read live from DeployFull)");

        bytes4[] memory flat = new bytes4[](total);
        uint256 k = 0;
        for (uint256 g = 0; g < groups.length; g++) {
            for (uint256 i = 0; i < groups[g].length; i++) flat[k++] = groups[g][i];
        }

        for (uint256 i = 0; i < flat.length; i++) {
            for (uint256 j = i + 1; j < flat.length; j++) {
                assertTrue(flat[i] != flat[j], "duplicate selector across facets post-upgrade");
            }
        }
    }
}
