// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../script/DeployFull.s.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";

/// Anti-drift gate for script/DeployFull.s.sol.
///
/// DeployFull.s.sol was broadcast exactly once (3 June 2026) and then went ~40
/// upgrades stale while the live diamond kept moving — nothing caught it because
/// nothing compared the script's mounted selectors against the facets' real ABIs.
/// This test is that comparison, made permanent.
///
/// Design: DeployFull exposes its selector arrays and FacetCut[] builders as
/// `public pure` functions (single source of truth — run() calls the very same
/// functions to build the cuts it broadcasts). Ground truth is read directly out
/// of the compiled artifact (`out/<Facet>.sol/<Facet>.json`'s `methodIdentifiers`
/// map) rather than hand-typed here.
///
/// A note on an earlier version of this file: it hand-typed each facet's
/// `expected` selector array via `<Facet>.<fn>.selector` and additionally asserted
/// a hardcoded total of 145. That was proven NOT to discriminate against the
/// specific failure mode that caused the original drift (a facet gaining a
/// function that nobody wires anywhere): adding one real function to a facet
/// changes nothing about either the hand-typed array or the hardcoded total, so
/// both sides silently agree on the same incomplete set and every test still
/// passes. Reading the artifact's `methodIdentifiers` instead means the expected
/// set updates itself the moment the facet is recompiled — there is nothing left
/// to remember to update by hand. The concrete before/after proof was recorded
/// when this file was regenerated on 25 July 2026.
///
/// This test fails if:
///   - the script is missing a selector a facet implements (undercut)
///   - the script mounts a selector no facet implements (phantom)
///   - a facet gains or loses a function between now and the next `forge build`
///     (ground truth is re-derived from the artifact every run, not pinned)
///   - a selector array's declared length disagrees with its real assignment
///     count (length mismatch surfaces immediately as a set-equality failure)
///   - `buildInitCuts`/`buildRemainingCuts` wire a correct selector set to the
///     wrong `FacetCut.facetAddress`
///   - the actual `DiamondProxy` this script would produce does not end up with
///     exactly 13 facets, exactly 221 routed selectors, and consistent
///     `facetAddress(sel)` <-> `facets()` routing in both directions
///     (177 -> 179, 15 Aug 2026: the arbiter-accountability branch added
///     getSeatedBy/getSeatedCountBy to ArbiterRegistryFacet; 179 -> 180,
///     same day: the same branch added getChiefBloc to cap
///     the chief's bloc below the appeal quorum; 180 -> 181, same day:
///     the same branch added getMaxClaimsPerArbiter to cap
///     how many disputes an arbiter can hold open at once; 181 -> 187, same
///     day: the same branch again — ArbiterRegistryFacet sat at 86.4%
///     of the EIP-170 deployed-bytecode limit, so arbiter suspension shipped
///     as a twelfth facet, ArbiterAccountabilityFacet, sharing the same
///     ArbiterRegistryStorage namespace — 11 facets -> 12, six new selectors;
///     187 -> 186, same day: the same branch removed
///     ArbiterAccountabilityFacet.getChiefArbiterAddress — it duplicated
///     ArbiterRegistryFacet.getChiefArbiter (both selectors route to the same
///     diamond address; the "so the frontend doesn't need to hit a second
///     facet" justification in that brief was the plan author's own
///     mistake, its real origin was the standalone-facet test rig); 186 -> 187,
///     same commit: the same step added ArbiterRegistryFacet.getCleanVerdicts, a
///     count of non-overturned finalized verdicts per arbiter, laid down for
///     a future "bond plus tenure" conversion when DAO mode activates — net
///     selector count unchanged, composition did; 187 -> 192, same day: the next step
///     removed the bare `removeArbiter` (no cause recorded, full bond refund —
///     a for-cause slash and a quiet purge looked identical on chain) and added
///     `getMaxArbiterMistakes` to ArbiterRegistryFacet (net 0 there), while
///     ArbiterAccountabilityFacet gained `removeArbiterForCause`,
///     `getMistakeThreshold`, and three standalone-test-rig getters (+5) —
///     `addArbiter`/`setChiefArbiter` also started reverting once DAO mode is
///     active (owner's literal instruction: "no more manual seating"), with no
///     selector-count effect; 192 -> 191, same day, on review of that step:
///     three of those standalone-test-rig getters
///     (isRegisteredArbiterHere/getMistakeStreakOf/getNoResponseAtHere) turned
///     out to be exactly the getChiefArbiterAddress mistake described above —
///     duplicates of live state already exposed by ArbiterRegistryFacet's own
///     getters through the diamond — and were removed; two getters over
///     ArbiterAccountabilityFacet's own local constants
///     (getMaxArbiterMistakesMirror, getDaoThresholdMirror) were added in
///     their place, needed for cross-checking against ArbiterRegistryFacet's
///     real numbers and not reachable any other way — net −1; 191 -> 196,
///     same day, the next step of that branch: the chief can now PROPOSE a
///     removal without being able to EXECUTE it — removal stays the owner's
///     (or, post-handover, daoAddress's) call, the chief only lays down a
///     signal record under his own address. ArbiterAccountabilityFacet
///     gained `proposeRemoval`, `withdrawProposal`, `hasLiveProposal`,
///     `getRemovalProposal`, `getProposalTTL` (+5); ArbiterRegistryFacet
///     unchanged (the new `removalProposals` field is storage layout only,
///     not a selector); 196 -> 198, same day, the step after that: a
///     removed arbiter's right to reply — an accusation against a real
///     address sits on chain forever, `respondToRemoval` lets the removed
///     arbiter lay down their own digest next to it, undoing nothing and
///     refunding nothing. ArbiterAccountabilityFacet gained
///     `respondToRemoval` and `getRemovalReply` (+2) — the facet's first
///     gasless function, so it also grew its own `_msgSender()`, which the
///     gasless-sender gate accounts for; the new `removalReply`/`removedAt`
///     fields are storage layout only, not selectors; 198 -> 199, same day,
///     the step after that: `getArbiterStanding` — the arbiter's whole
///     standing in one read (xp, cleanStreak, mistakeStreak, bond, seatedBy,
///     suspendedUntil, openClaims, cleanVerdicts, removedAt,
///     hasLiveRemovalProposal) instead of seven-plus separate calls that
///     could straddle a block boundary — bond read before a removal, status
///     read after. ArbiterAccountabilityFacet gained one selector (+1, 16 ->
///     17); the field set is wider than that step's brief, which predates
///     `cleanVerdicts` and `removedAt` landing in storage — both are read
///     into the return tuple, plus `hasLiveRemovalProposal` via a call to
///     the facet's own `hasLiveProposal`, not a copy of its formula. No new
///     storage fields, ArbiterRegistryFacet unchanged; 199 -> 200, 17 Aug 2026,
///     the removal-due-process branch opens: the accusation got WORDS.
///     `Cause` is a numeric code, so the public record of a removal carried no
///     words at all — "removal for cause" promised an explanation that existed
///     nowhere. ArbiterAccountabilityFacet gained `getMaxReasonBytes` (+1, 31
///     -> 32): the cap on those words, in BYTES, asked of the chain so the form
///     does not keep a copy that can drift. Three already-listed entries
///     changed SIGNATURE without adding selectors here
///     (`removeArbiterForCause`/`proposeRemoval` gained `string reason`,
///     `respondToRemoval` gained `string reply`) — still an Add on chain, not
///     a Replace: this plan's cut has not been made, so none of the three old
///     selectors is mounted on the diamond and only the selector VALUE inside
///     the Add group changed, see script/UpgradeArbiterAccountability.s.sol.
///     No new storage fields: the words live in events
///     (RemovalReasonGiven/RemovalReplyGiven), read by the feed and the card;
///     200 -> 201, 17 Aug 2026, the next step of that branch: 48 HOURS NOW STAND
///     BETWEEN THE ACCUSATION AND THE REMOVAL. The proposal existed but was
///     optional and changed nothing — removal went through in one transaction
///     and the person learned of it afterwards, sentence first and word after.
///     It is now the only way in: the execution window is [48 hours, 14 days)
///     from the proposal, and the cause at execution must match the one
///     proposed. ArbiterAccountabilityFacet gained `getRemovalDelay` (+1, 32 ->
///     33) — the pause itself is a rule rather than a selector, but the form
///     must ask the chain for the number instead of keeping a copy that drifts.
///     Four new errors (NoLiveProposal, RemovalTooEarly, ProposalStale,
///     CauseDiffersFromProposal) add no selectors here and no storage fields:
///     `removalProposals` has been in storage since the chief got the right to propose;
///     201 -> 202, 18 Aug 2026, a later step of that branch: THE QUIET DOOR NOW
///     LEADS INTO THE COMMON ONE. Three judicial mistakes used to unseat an
///     arbiter on the spot — no proposal, no pause, no words, no cause to
///     match — and that door survived the handover the whole branch exists to
///     build, since overturnVerdict sits under a modifier that lets the owner
///     through always. The third mistake now suspends at once and lays an
///     accusation in the CHAIN'S OWN name, and ArbiterAccountabilityFacet
///     gained `executeChainRemoval` (+1, 33 -> 34): once the 48 hours have
///     passed anyone may press it, because the chain proved the cause itself
///     and pressing carries no discretion. One new storage field
///     (`chainProposalPath`, appended at the end of ArbiterRegistryStorage.Data)
///     because the demotion path is known at the mistake and recorded at the
///     removal, two days apart;
///     202 -> 203, 21 Aug 2026: THE OTHER HALF OF THE FRACTION. The
///     mistake counter is a STREAK — a clean verdict clears it — so "mistake,
///     mistake, clean" round and round never reached the threshold, the
///     automatic path never fired, and `cleanVerdicts` kept growing, which made
///     an arbiter with thirteen overturns read from outside as BETTER than an
///     honest newcomer with none. Nothing counted the overturns at all.
///     ArbiterAccountabilityFacet gained `getOverturnedVerdicts` (+1, 34 -> 35)
///     and `getArbiterStanding` now hands the pair out together, the reader
///     dividing. One new storage field (`overturnedVerdicts`, appended at the
///     end of ArbiterRegistryStorage.Data). It gates nothing on purpose: the
///     rungs stop at "visible -> counted";
///     203 -> 214, 24 Aug 2026: THE DOOR INTO THE CORPS BEFORE THE DAO. Until
///     this cut `applyAsArbiter` reverted `DAONotActive` on its first line and
///     `addArbiter` was the only entrance, so nobody could put himself forward
///     at all. The self-service gate measures a RECORD (3 000 XP is roughly
///     thirty deals with thirty people) and at the start of a marketplace there
///     is none to measure; lowering the threshold would leave the bond as the
///     only filter, which sells the seat. So admissions are decided by hand and
///     the measure ends BY EVENT: the same `isDaoActive()` ratchet that shuts
///     `addArbiter` shuts this door too. 12 facets -> 13, +11 selectors: it
///     could not go in either existing arbiter facet — the registry had 1 207
///     bytes of margin left at the time (674 after decisions 50-52), and the
///     accountability facet has room but is
///     already named after something other than what it holds;
///     214 -> 216, 25 Aug 2026: THE REFUND STOPS WAITING ON THE FEE. Four board
///     paths pushed the fee floor to `feeRecipient` in the same transaction
///     that handed a person their money back, under a hard `require` — so one
///     dollar owed to a third party decided whether tens of dollars belonging
///     to the person came out at all (36.19 USDC behind a 1.00 USDC transfer on
///     live job #3). USDC blacklists addresses and `Treasury` already made its
///     OUTGOING payments pull-based for exactly that reason; the inflow had no
///     such protection. The fee is now booked as a debt when the recipient
///     refuses it, which needs two new selectors on FactoryFacet:
///     `getUndeliveredFees` so it is visible and `withdrawUndeliveredFees` so
///     it can be taken. Both are ADD; every other selector in that cut is
///     REPLACE;
///     216 -> 218, 26 Aug 2026, decisions 50 and 51: GOVERNANCE IS TURNED ON BY
///     A PERSON, AND THE SUCCESSOR PROVES HE EXISTS. `isDaoActive()` used to be
///     "the owner's flag OR uniqueActiveUsers >= DAO_THRESHOLD", and the second
///     half was pressed by STRANGERS closing their own deals: the instant it
///     flipped, three doors into the corps shut, the chief's office was
///     abolished, the money split moved 70% -> 20% in an immutable treasury —
///     with `daoAddress` possibly still zero and nobody to hand any of it to.
///     The earned half is gone from the predicate and became a CONDITION on
///     `activateDAO()` instead, which also drops from 100 000 to 10 000
///     (`Treasury.DAO_THRESHOLD` is a separate constant in a deployed immutable
///     contract and still says 100 000 — a known, deliberate disagreement, see
///     testDaoThresholdMatchesArbiterRegistryFacet). And `setDAOAddress` stops
///     taking effect on the spot: it PROPOSES, and the named address takes
///     office by sending `acceptDAOAddress()` itself, because before that one
///     wrong letter meant nobody could ever remove an arbiter again.
///     ArbiterRegistryFacet gained `acceptDAOAddress` and
///     `getPendingDAOAddress` (+2, 55 -> 57). One new storage field
///     (`pendingDaoAddress`, appended at the end of ArbiterRegistryStorage.Data)
///     plus two appended INSIDE existing structs — `RemovalProposal.ttl` and
///     `PendingVerdict.appealDeposit` — the deposit and the TTL now written
///     into the record itself, neither a selector);
///     218 -> 221, 29 Aug 2026: A DISPUTE ON A SMALL POT COST THE
///     PARTY TEN DOLLARS. The arbiter floor is $10 and the levy on a $5 pot
///     yields the arbiter twelve cents, so the party made up $9.88 — found by
///     live people in twenty minutes. The floor stays and the party still pays,
///     but the arbiter vault now takes a fixed amount off that top-up: a
///     DISCOUNT, not cover, because a dispute that costs the opener nothing is
///     one that gets opened for nothing. The size of it is a stored number and
///     not a constant — the protocol has seen zero disputes in its life, so
///     three dollars is a starting point that the first hundred real deals will
///     move, and moving it must not cost a facet replacement.
///     ArbiterRegistryFacet gained `setDisputeDiscount` and
///     `getDisputeDiscount` (+2, 57 -> 59); ArbiterAccountabilityFacet gained
///     `getDisputeSubsidy` (+1, 35 -> 36), which is a bare read of a registry
///     field mounted there for bytes — the registry stands 90 under the
///     EIP-170 ceiling. Two new storage fields, both appended at the end of
///     ArbiterRegistryStorage.Data (`disputeVaultDiscount`,
///     `disputeVaultSubsidy`)
contract DeployFullSelectorsTest is Test {
    DeployFull internal deploy;

    // Placeholder facet addresses for buildInitCuts/buildRemainingCuts — these
    // functions are pure and only thread the address through into the FacetCut
    // struct, so any nonzero address works; no real facet needs to be deployed
    // for THESE tests specifically (the real-facet integration test further down
    // deploys actual bytecode instead).
    address constant CUT_FACET      = address(0x1001);
    address constant LOUPE_FACET    = address(0x1002);
    address constant OWN_FACET      = address(0x1003);
    address constant REG_FACET      = address(0x1004);
    address constant FAC_FACET      = address(0x1005);
    address constant JOB_BOARD      = address(0x1006);
    address constant SERVICE_BOARD  = address(0x1007);
    address constant ARBITER_FACET  = address(0x1008);
    address constant ACCOUNTABILITY_FACET = address(0x100C);
    address constant META_FACET     = address(0x1009);
    address constant RECEIPT_FACET  = address(0x100A);
    address constant REPUTATION_FACET = address(0x100B);
    address constant APPLICATIONS_FACET   = address(0x100D);

    function setUp() public {
        deploy = new DeployFull();
    }

    // ── Ground truth: read straight out of the compiled artifact ────────────
    // `forge inspect <Facet> methodIdentifiers` is itself just a formatted dump
    // of this same `methodIdentifiers` map from the artifact JSON — reading it
    // directly means the expected set is regenerated by every `forge build`,
    // with nothing left for a human to keep in sync by hand.
    function _abiSelectors(string memory sourceFile, string memory contractName) internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(string.concat("out/", sourceFile, ".sol/", contractName, ".json"));
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; i++) out[i] = bytes4(keccak256(bytes(sigs[i])));
    }

    // Convenience overload for the common case where the contract's source file
    // shares its name (true for every facet except the three defined inside
    // DiamondProxy.sol).
    function _abiSelectors(string memory contractName) internal view returns (bytes4[] memory) {
        return _abiSelectors(contractName, contractName);
    }

    // ── Set-equality helper ──────────────────────────────────────────────────
    // Order-independent. Requires equal lengths (catches declared-length vs.
    // assignment-count drift immediately), then requires every element of
    // `actual` to appear in `expected` (phantom check) and every element of
    // `expected` to appear in `actual` (missing-selector check). Combined with
    // the length check this rejects duplicates masking a missing entry too.
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

    // ── Per-facet drift checks — expected sets come from the compiled ABI, not
    //    from hand-typed literals in this file ──────────────────────────────

    function testDiamondCutFacetSelectors() public view {
        _assertSameSelectorSet(deploy.cutFacetSelectors(), _abiSelectors("DiamondProxy", "DiamondCutFacet"), "DiamondCutFacet");
    }

    function testDiamondLoupeFacetSelectors() public view {
        _assertSameSelectorSet(deploy.loupeFacetSelectors(), _abiSelectors("DiamondProxy", "DiamondLoupeFacet"), "DiamondLoupeFacet");
    }

    function testOwnershipFacetSelectors() public view {
        _assertSameSelectorSet(deploy.ownershipFacetSelectors(), _abiSelectors("DiamondProxy", "OwnershipFacet"), "OwnershipFacet");
    }

    function testRegistryFacetSelectors() public view {
        _assertSameSelectorSet(deploy.registryFacetSelectors(), _abiSelectors("RegistryFacet"), "RegistryFacet");
    }

    function testFactoryFacetSelectors() public view {
        _assertSameSelectorSet(deploy.factoryFacetSelectors(), _abiSelectors("FactoryFacet"), "FactoryFacet");
    }

    function testJobBoardFacetSelectors() public view {
        _assertSameSelectorSet(deploy.jobBoardFacetSelectors(), _abiSelectors("JobBoardFacet"), "JobBoardFacet");
    }

    function testServiceBoardFacetSelectors() public view {
        _assertSameSelectorSet(deploy.serviceBoardFacetSelectors(), _abiSelectors("ServiceBoardFacet"), "ServiceBoardFacet");
    }

    function testArbiterRegistryFacetSelectors() public view {
        _assertSameSelectorSet(deploy.arbiterRegistryFacetSelectors(), _abiSelectors("ArbiterRegistryFacet"), "ArbiterRegistryFacet");
    }

    function testArbiterAccountabilityFacetSelectors() public view {
        _assertSameSelectorSet(deploy.arbiterAccountabilityFacetSelectors(), _abiSelectors("ArbiterAccountabilityFacet"), "ArbiterAccountabilityFacet");
    }

    function testArbiterApplicationsFacetSelectors() public view {
        _assertSameSelectorSet(deploy.arbiterApplicationsFacetSelectors(), _abiSelectors("ArbiterApplicationsFacet"), "ArbiterApplicationsFacet");
    }

    function testDealMetadataFacetSelectors() public view {
        _assertSameSelectorSet(deploy.dealMetadataFacetSelectors(), _abiSelectors("DealMetadataFacet"), "DealMetadataFacet");
    }

    function testJobReceiptFacetSelectors() public view {
        _assertSameSelectorSet(deploy.jobReceiptFacetSelectors(), _abiSelectors("JobReceiptFacet"), "JobReceiptFacet");
    }

    function testReputationFacetSelectors() public view {
        _assertSameSelectorSet(deploy.reputationFacetSelectors(), _abiSelectors("ReputationFacet"), "ReputationFacet");
    }

    // ── Cross-cutting invariant ──────────────────────────────────────────────

    /// No selector value appears under two different facets. A Diamond can only
    /// route a given 4-byte selector to one facet address — if two facets in
    /// this script ever claimed the same selector, one silently shadows the
    /// other during buildInitCuts/buildRemainingCuts (whichever cut wins,
    /// diamondCut itself would revert with `Diamond: selector exists` on the
    /// duplicate), so proving there is zero overlap here is a real check, not
    /// decoration. The total selector count is summed from the script's own
    /// output here (not hardcoded) — per-facet tests above are what pin each
    /// count against ground truth; this test only cares about cross-facet
    /// uniqueness.
    function testNoSelectorCollisionsAcrossFacets() public view {
        bytes4[][12] memory groups = [
            deploy.cutFacetSelectors(),
            deploy.loupeFacetSelectors(),
            deploy.ownershipFacetSelectors(),
            deploy.registryFacetSelectors(),
            deploy.factoryFacetSelectors(),
            deploy.jobBoardFacetSelectors(),
            deploy.serviceBoardFacetSelectors(),
            deploy.arbiterRegistryFacetSelectors(),
            deploy.arbiterAccountabilityFacetSelectors(),
            deploy.dealMetadataFacetSelectors(),
            deploy.jobReceiptFacetSelectors(),
            deploy.reputationFacetSelectors()
        ];

        uint256 total;
        for (uint256 g = 0; g < groups.length; g++) total += groups[g].length;

        bytes4[] memory flat = new bytes4[](total);
        uint256 k = 0;
        for (uint256 g = 0; g < groups.length; g++) {
            for (uint256 i = 0; i < groups[g].length; i++) {
                flat[k++] = groups[g][i];
            }
        }

        for (uint256 i = 0; i < flat.length; i++) {
            for (uint256 j = i + 1; j < flat.length; j++) {
                assertTrue(flat[i] != flat[j], "duplicate selector across facets");
            }
        }
    }

    // ── FacetCut[] builder checks ────────────────────────────────────────────
    // These exercise the exact functions run() calls to build what it actually
    // broadcasts to diamondCut() — catching a facetAddress/selector-set mixup
    // (e.g. ArbiterRegistry's selectors wired to JobBoard's address) that the
    // per-facet selector tests above cannot see, since they never look at which
    // address a selector set is paired with.

    function testBuildInitCutsMatchesIndividualSelectors() public view {
        IDiamondCut.FacetCut[] memory cuts = deploy.buildInitCuts(
            CUT_FACET, LOUPE_FACET, OWN_FACET, REG_FACET, FAC_FACET
        );
        assertEq(cuts.length, 5, "buildInitCuts: expected 5 FacetCut entries");

        assertEq(cuts[0].facetAddress, CUT_FACET);
        _assertSameSelectorSet(cuts[0].functionSelectors, deploy.cutFacetSelectors(), "initCuts[0] DiamondCutFacet");

        assertEq(cuts[1].facetAddress, LOUPE_FACET);
        _assertSameSelectorSet(cuts[1].functionSelectors, deploy.loupeFacetSelectors(), "initCuts[1] DiamondLoupeFacet");

        assertEq(cuts[2].facetAddress, OWN_FACET);
        _assertSameSelectorSet(cuts[2].functionSelectors, deploy.ownershipFacetSelectors(), "initCuts[2] OwnershipFacet");

        assertEq(cuts[3].facetAddress, REG_FACET);
        _assertSameSelectorSet(cuts[3].functionSelectors, deploy.registryFacetSelectors(), "initCuts[3] RegistryFacet");

        assertEq(cuts[4].facetAddress, FAC_FACET);
        _assertSameSelectorSet(cuts[4].functionSelectors, deploy.factoryFacetSelectors(), "initCuts[4] FactoryFacet");

        for (uint256 i = 0; i < cuts.length; i++) {
            assertTrue(cuts[i].action == IDiamondCut.FacetCutAction.Add, "initCuts: all entries must be Add");
        }
    }

    function testBuildRemainingCutsMatchesIndividualSelectors() public view {
        IDiamondCut.FacetCut[] memory cuts = deploy.buildRemainingCuts(
            JOB_BOARD, SERVICE_BOARD, ARBITER_FACET, ACCOUNTABILITY_FACET, APPLICATIONS_FACET,
            META_FACET, RECEIPT_FACET, REPUTATION_FACET
        );
        assertEq(cuts.length, 8, "buildRemainingCuts: expected 8 FacetCut entries");

        assertEq(cuts[0].facetAddress, JOB_BOARD);
        _assertSameSelectorSet(cuts[0].functionSelectors, deploy.jobBoardFacetSelectors(), "cuts2[0] JobBoardFacet");

        assertEq(cuts[1].facetAddress, SERVICE_BOARD);
        _assertSameSelectorSet(cuts[1].functionSelectors, deploy.serviceBoardFacetSelectors(), "cuts2[1] ServiceBoardFacet");

        assertEq(cuts[2].facetAddress, ARBITER_FACET);
        _assertSameSelectorSet(cuts[2].functionSelectors, deploy.arbiterRegistryFacetSelectors(), "cuts2[2] ArbiterRegistryFacet");

        assertEq(cuts[3].facetAddress, ACCOUNTABILITY_FACET);
        _assertSameSelectorSet(cuts[3].functionSelectors, deploy.arbiterAccountabilityFacetSelectors(), "cuts2[3] ArbiterAccountabilityFacet");

        assertEq(cuts[4].facetAddress, APPLICATIONS_FACET);
        _assertSameSelectorSet(cuts[4].functionSelectors, deploy.arbiterApplicationsFacetSelectors(), "cuts2[4] ArbiterApplicationsFacet");

        assertEq(cuts[5].facetAddress, META_FACET);
        _assertSameSelectorSet(cuts[5].functionSelectors, deploy.dealMetadataFacetSelectors(), "cuts2[5] DealMetadataFacet");

        assertEq(cuts[6].facetAddress, RECEIPT_FACET);
        _assertSameSelectorSet(cuts[6].functionSelectors, deploy.jobReceiptFacetSelectors(), "cuts2[6] JobReceiptFacet");

        assertEq(cuts[7].facetAddress, REPUTATION_FACET);
        _assertSameSelectorSet(cuts[7].functionSelectors, deploy.reputationFacetSelectors(), "cuts2[7] ReputationFacet");

        for (uint256 i = 0; i < cuts.length; i++) {
            assertTrue(cuts[i].action == IDiamondCut.FacetCutAction.Add, "cuts2: all entries must be Add");
        }
    }

    // ── Full-diamond integration check ───────────────────────────────────────
    // Every other test above works on the selector level. None of them ever
    // constructs the actual DiamondProxy this script produces — which is
    // exactly why the 40-upgrade drift this whole file exists to prevent was
    // possible in the first place: CriticalInvariant.t.sol / Extras.t.sol /
    // AdversarialAccess.t.sol each hand-build their own PARTIAL cuts for
    // feature testing (e.g. 33 of 47 ArbiterRegistry selectors, 20 of 23
    // ServiceBoard selectors) and none of them exercises DeployFull's actual
    // buildInitCuts/buildRemainingCuts output end to end.
    //
    // This deploys all thirteen real facets, builds the diamond exactly the way
    // run() does, and asserts the diamond that comes out the other end has
    // exactly 13 facets, exactly 218 routed selectors, and that
    // facetAddress(sel) and facets() agree with each other in both directions.
    // This is the only check in the suite that would catch a selector set
    // wired to the wrong facet address — diamondCut() itself does not validate
    // that a facet actually implements what it's handed.
    function testDeployFullBuildsCompleteDiamondWithConsistentRouting() public {
        DiamondCutFacet        cutFacet     = new DiamondCutFacet();
        DiamondLoupeFacet      loupeFacet   = new DiamondLoupeFacet();
        OwnershipFacet         ownFacet     = new OwnershipFacet();
        RegistryFacet          regFacet     = new RegistryFacet();
        FactoryFacet           facFacet     = new FactoryFacet();
        JobBoardFacet          jobBoard     = new JobBoardFacet();
        ServiceBoardFacet      serviceBoard = new ServiceBoardFacet();
        ArbiterRegistryFacet   arbiterFacet = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet accFacet = new ArbiterAccountabilityFacet();
        ArbiterApplicationsFacet appFacet   = new ArbiterApplicationsFacet();
        DealMetadataFacet      metaFacet    = new DealMetadataFacet();
        JobReceiptFacet        receiptFacet = new JobReceiptFacet();
        ReputationFacet        repFacet     = new ReputationFacet();

        IDiamondCut.FacetCut[] memory initCuts = deploy.buildInitCuts(
            address(cutFacet), address(loupeFacet), address(ownFacet), address(regFacet), address(facFacet)
        );
        DiamondProxy diamond = new DiamondProxy(address(this), initCuts, address(0), "");

        IDiamondCut.FacetCut[] memory cuts2 = deploy.buildRemainingCuts(
            address(jobBoard), address(serviceBoard), address(arbiterFacet), address(accFacet),
            address(appFacet), address(metaFacet), address(receiptFacet), address(repFacet)
        );
        IDiamondCut(address(diamond)).diamondCut(cuts2, address(0), "");

        IDiamondLoupe.Facet[] memory facetsList = IDiamondLoupe(address(diamond)).facets();
        assertEq(facetsList.length, 13, "diamond should end up with exactly 13 distinct facet addresses");

        uint256 totalRouted;
        for (uint256 i = 0; i < facetsList.length; i++) {
            bytes4[] memory sels = facetsList[i].functionSelectors;
            totalRouted += sels.length;
            for (uint256 j = 0; j < sels.length; j++) {
                assertEq(
                    IDiamondLoupe(address(diamond)).facetAddress(sels[j]),
                    facetsList[i].facetAddress,
                    "facetAddress(sel) disagrees with facets() for a routed selector"
                );
            }
        }
        // ⚠️ 221 IS A FROM-SCRATCH DEPLOY. The live chain is BEHIND it, and by
        // how much depends on a cut this work did not make.
        //
        // The census stands in this repository were taken against a chain of
        // 216. Two of those 216 became 218 on 27 August 2026, when
        // UpgradeGovernanceHandover was broadcast — three receipts, all
        // `status: 0x1`, block 46 033 263, in
        // broadcast/UpgradeGovernanceHandover.s.sol/84532/run-latest.json. That
        // is a reading of the broadcast record, not of the chain.
        //
        // The remaining three are the arbiter vault's discount on a dispute
        // top-up, added on 29 August
        // 2026 and NOT CUT INTO THE CHAIN by that work either — writing to the
        // chain was out of its scope, and the cut is a separate signature:
        // `setDisputeDiscount` and `getDisputeDiscount` on the registry,
        // `getDisputeSubsidy` on the accountability facet. The number here pins
        // what DeployFull builds; the stands that compare a local rig against
        // the chain census carry the same three as a named pending cut.
        //
        // 221 -> 222 on 31 August 2026: RegistryFacet gained
        // `notifyWorkHandedIn()`. `Agreement.markDone()` used to touch the
        // diamond not at all -- it stamped the clone and emitted `MarkedDone`
        // THERE -- so the transition that starts the two-day auto-approve
        // window, after which silence hands the executor the whole pot, was
        // invisible from the one address anything watches. Ships with
        // script/UpgradeRegistryHandInSignal.s.sol.
        //
        // ⚠️ MEASURED AGAINST THE CHAIN ON 31 AUGUST 2026, and the answer moved
        // the story above: the live diamond routes 221 across 13 facets, not
        // 218. The dispute-vault discount and the DAO handover have BOTH landed
        // since those censuses were taken (the discount at block 46 119 029,
        // three receipts `status: 0x1`). So the only thing this tree now
        // carries that the chain does not is the one selector named here, and
        // the older "three pending" allowances in the upgrade stands are
        // counting cuts that have already shipped.
        //
        // 222 -> 227 on 3 September 2026, in ONE cut carrying two deliveries.
        // Four of the five are the emergency brake (decision 17) —
        // `pauseNewDeals`, `resumeNewDeals`, `newDealsPausedUntil` and the
        // `NEW_DEALS_PAUSE_DURATION` getter. The fifth is `MAX_FEE_BPS()`
        // (item 138), the 20% fee ceiling that until now was a bare `2_000`
        // written twice inside FactoryFacet and readable from nowhere.
        //
        // The live chain routes 222 today, measured at block 46 306 403; these
        // five are the entire delta, and they ship together in
        // script/UpgradeEmergencyBrake.s.sol, whose stand carries them as the
        // one named allowance between the local rig and that census.
        assertEq(totalRouted, 227, "diamond should route exactly 227 selectors total");

        // Reverse direction: facetAddresses() must report exactly the same set
        // of addresses facets() reported them under.
        address[] memory addrs = IDiamondLoupe(address(diamond)).facetAddresses();
        assertEq(addrs.length, 13, "facetAddresses() should also report exactly 13 facets");
        for (uint256 i = 0; i < addrs.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < facetsList.length; j++) {
                if (facetsList[j].facetAddress == addrs[i]) { found = true; break; }
            }
            assertTrue(found, "facetAddresses() reported an address facets() does not know about");
        }
    }
}
