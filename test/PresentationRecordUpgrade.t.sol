// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {LegacyPreSplitArbiterFacet, ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {UpgradePresentationRecord} from "../script/UpgradePresentationRecord.s.sol";
import {ArbiterChainCensus} from "./ArbiterChainCensus.sol";
import "../src/DiamondProxy.sol";

/// A double that answers getNoResponseFloor() with THE WRONG number. It exists for
/// exactly one purpose: to prove by measurement that the script's post-flight
/// check on the floor really compares the VALUE and not merely "the call did not
/// revert". Without it the require about the floor would be a tautology — a
/// freshly built facet returns its own constant by definition.
contract WrongFloorStub {
    function getNoResponseFloor() external pure returns (uint256) {
        return 12 hours;
    }
}

contract PresentationRecordUpgradeTest is Test, ArbiterTwoFacetBench, ArbiterChainCensus {
    UpgradePresentationRecord internal upgrade;

    function setUp() public {
        upgrade = new UpgradePresentationRecord();
    }

    // ── Ground truth: read straight out of the compiled artifact — the same
    //    device as _abiSelectors in the DeployFullSelectors suite ───────────
    function _abiSelectors(string memory contractName) internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(string.concat("out/", contractName, ".sol/", contractName, ".json"));
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; i++) out[i] = bytes4(keccak256(bytes(sigs[i])));
    }

    // ════════════════════════════════════════════════════════════════════
    // The cut's composition against the compiled ABI
    // ════════════════════════════════════════════════════════════════════

    /// ── REMOVED on 15 August 2026 ──────────────────────────────────────────
    ///
    /// test_ReplaceAndAddCoverWholeFacet used to stand here: it compared the union
    /// of THIS script's replaceSelectors()+addSelectors() against a fresh
    /// ArbiterRegistryFacet ABI. The cut this file describes ("the chain as a
    /// witness to presentation") was executed on Base Sepolia on 15 August and
    /// checked against the chain — it will never be repeated, and its selector
    /// lists describe the facet of THAT day forever (64 methods: 56 Replace + 8
    /// Add). Later work added two more to the facet — getSeatedBy/getSeatedCountBy,
    /// 64 → 66 — and this test went red while saying nothing about anything:
    /// comparing an executed cut against today's code is meaningless (the same
    /// diagnosis and the same treatment already applied here on 14 August to the
    /// ArbiterChatKeyUpgrade suite — see the comment there). The live role
    /// (spotting an under-mounted or phantom selector BEFORE the broadcast) is
    /// taken over by exactly the same test against a cut not yet executed, one that
    /// will physically mount getSeatedBy/getSeatedCountBy. The lock did not weaken:
    /// it simply moved again to a script that has yet to run. The other tests in
    /// this file are alive and there is nothing to touch about them: they check the
    /// pre- and post-flight helpers and storage continuity, that is, logic that does
    /// not depend on the facet's growth (after the fix to _oldFacetSelectors, see
    /// its comment above — on 15 August the same diagnosis touched the bench too).

    /// The eight Add selectors are exactly those eight, and they are named BY
    /// SIGNATURE rather than by `.selector` from the same facet. Comparing
    /// `.selector` against `.selector` would be a tautology: rename the function and
    /// both change together. Here the facet is on the left and a literal signature
    /// on the right — one the client and the relayer already depend on — so a
    /// divergence must go red.
    ///
    /// What disappears if this is removed: a changed signature (an extra argument,
    /// uint256 instead of bytes32) would go through in silence — the chain would
    /// mount the new selector while the client went on calling the old one and got
    /// "the function does not exist".
    function test_AddSelectorsAreTheEightNewSignatures() public view {
        bytes4[] memory addSels = upgrade.addSelectors();
        assertEq(addSels.length, 8, "Add: there are exactly eight new selectors");

        bytes4[8] memory expected = [
            bytes4(keccak256("getDisputeClaimedAt(address)")),
            bytes4(keccak256("recordNoResponse(address)")),
            bytes4(keccak256("getNoResponseAt(address)")),
            bytes4(keccak256("getNoResponseFloor()")),
            bytes4(keccak256("recordPresentationDigest(address,bytes32)")),
            bytes4(keccak256("getPresentationDigests(address)")),
            bytes4(keccak256("getPresentationDigestCount(address)")),
            bytes4(keccak256("getPresentationDigestsPage(address,uint256,uint256)"))
        ];

        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < addSels.length; j++) {
                if (expected[i] == addSels[j]) { found = true; break; }
            }
            assertTrue(found, "Add: one of the eight signatures is not mounted by this cut");
        }

        // And the other side of it: not one of the eight also sits in Replace —
        // diamondCut would reject the whole cut with "Diamond: selector exists".
        bytes4[] memory replaceSels = upgrade.replaceSelectors();
        for (uint256 i = 0; i < expected.length; i++) {
            for (uint256 j = 0; j < replaceSels.length; j++) {
                assertTrue(
                    expected[i] != replaceSels[j],
                    "a new selector also landed in Replace, so the whole cut will revert on a live diamond"
                );
            }
        }
    }

    /// No selector is named twice across the two lists.
    ///
    /// What disappears if this is removed: a silent typo instead of a comprehensible
    /// refusal at build time — the diamond on chain would revert the whole cut, but
    /// that would be discovered at the real rollout rather than in advance.
    function test_NoSelectorNamedTwiceAcrossLists() public view {
        bytes4[] memory replaceSels = upgrade.replaceSelectors();
        bytes4[] memory addSels = upgrade.addSelectors();

        bytes4[] memory all = new bytes4[](replaceSels.length + addSels.length);
        uint256 k = 0;
        for (uint256 i = 0; i < replaceSels.length; i++) all[k++] = replaceSels[i];
        for (uint256 i = 0; i < addSels.length; i++) all[k++] = addSels[i];

        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = i + 1; j < all.length; j++) {
                assertTrue(all[i] != all[j], "a selector is named more than once across Replace/Add");
            }
        }
    }

    /// The composition of buildCuts(): two actions, the expected lengths and the
    /// addresses. There is no Remove group at all — no previous signature changed.
    function test_BuildCutsShapeAndAddresses() public view {
        address facet = address(0xBEEF);
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(facet);

        assertEq(cuts.length, 2, "buildCuts: exactly two FacetCut entries were expected");

        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace, "cuts[0] must be a Replace");
        assertEq(cuts[0].facetAddress, facet, "Replace: the address must be the new facet");
        assertEq(cuts[0].functionSelectors.length, 56, "Replace: 56 previous selectors were expected");

        assertTrue(cuts[1].action == IDiamondCut.FacetCutAction.Add, "cuts[1] must be an Add");
        assertEq(cuts[1].facetAddress, facet, "Add: the address must be the new facet");
        assertEq(cuts[1].functionSelectors.length, 8, "Add: 8 new selectors were expected");
    }

    // ════════════════════════════════════════════════════════════════════
    // Pre/post-flight — proved on a locally deployed diamond and not only on the
    // source lists. A Replace onto an address that does not have the required
    // selector does NOT revert (DiamondCutLib.replaceFunctions checks only "the
    // address is different and has code"), so the script's own checks have to be
    // proved by measurement rather than taken on trust.
    // ════════════════════════════════════════════════════════════════════

    /// A minimal diamond: Cut+Loupe+Ownership. The device comes from the Diamond suite's setUp().
    function _deployMinimalDiamond() internal returns (DiamondProxy) {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownFacet = new OwnershipFacet();

        bytes4[] memory cutSels = new bytes4[](1);
        cutSels[0] = IDiamondCut.diamondCut.selector;

        bytes4[] memory loupeSels = new bytes4[](5);
        loupeSels[0] = IDiamondLoupe.facets.selector;
        loupeSels[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSels[2] = IDiamondLoupe.facetAddresses.selector;
        loupeSels[3] = IDiamondLoupe.facetAddress.selector;
        loupeSels[4] = IERC165.supportsInterface.selector;

        bytes4[] memory ownSels = new bytes4[](4);
        ownSels[0] = OwnershipFacet.transferOwnership.selector;
        ownSels[1] = OwnershipFacet.owner.selector;
        ownSels[2] = OwnershipFacet.acceptOwnership.selector;
        ownSels[3] = OwnershipFacet.pendingOwner.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut(address(cutFacet), IDiamondCut.FacetCutAction.Add, cutSels);
        cuts[1] = IDiamondCut.FacetCut(address(loupeFacet), IDiamondCut.FacetCutAction.Add, loupeSels);
        cuts[2] = IDiamondCut.FacetCut(address(ownFacet), IDiamondCut.FacetCutAction.Add, ownSels);

        return new DiamondProxy(address(this), cuts, address(0), "");
    }

    /// The selectors of the "old" (pre-cut) facet — they USED to be the compiled ABI
    /// MINUS the eight new ones; now they come straight from
    /// upgrade.replaceSelectors().
    ///
    /// ⚠️ REWORKED on 15 August 2026. The "chain as a witness to presentation" cut
    /// this script describes was executed on Base Sepolia the same day and checked
    /// against the chain — which means the risk the bench was once built for
    /// INDEPENDENTLY of replaceSelectors() (catching a selector forgotten in the
    /// script's list BEFORE the broadcast) is closed: the list is confirmed by the
    /// live chain, and backfilling makes no further sense. That same
    /// ABI-minus-addSelectors formula over a live (growing) facet ABI became a
    /// different risk in place of the old one: later work appended
    /// getSeatedBy/getSeatedCountBy to the facet (64 → 66 selectors), and "the ABI
    /// minus eight" began quietly including those two functions — which did not
    /// exist on 15 August — in the composition of the "old" facet: 7 reds caused by
    /// growth that has nothing to do with this cut (see the retirement note above).
    /// This script has no upgrade.removeSelectors() (Replace 56 / Add 8, with no
    /// deletions).
    ///
    /// ⚠️ THE "NO INDEPENDENT ORACLE" CAVEAT IS LIFTED. `return
    /// upgrade.replaceSelectors();` used to stand here — the bench derived the
    /// chain's layout from the very list it checks, and both of its pre-flights
    /// (`checkReplaceGroup`, `checkAddGroupUnmounted`) agreed with themselves. An
    /// oracle was found for an executed cut too: this cut ended in precisely what
    /// lies on chain TODAY — the census of 15 August found it there. So the layout
    /// BEFORE it rewinds exactly:
    ///   the census (64) − what it added (8) = 56.
    ///
    /// The rewind takes nothing from the script but `addSelectors()`, and those
    /// eight are locked down by LITERAL SIGNATURES in a neighbouring test
    /// (test_AddSelectorsAreTheEightNewSignatures) — that is, as text and not as
    /// `.selector` from the same facet. `replaceSelectors()`, the very thing the
    /// bench is built for, takes no part in the computation at all.
    ///
    /// ⚠️ THE REWIND WAS REPLACED BY AN OBSERVATION. `_rewindCut(_chainCensus(),
    /// upgrade.addSelectors(), ...)` used to stand here — that is, the layout was
    /// COMPUTED from the census of 16 August. The computation is correct, but it
    /// lives exactly until the first error in the lists it is made from. The layout
    /// is now READ from a chain snapshot at block 45476892 (14 August): 56 selectors
    /// on 0xEDE8B010…, 169 routes in total.
    /// The rewind is not thrown away — it is compared against the snapshot in
    /// test_RewindOfTheCensusMatchesTheChainSnapshot below. One number now has two
    /// independent sources instead of one.
    function _oldFacetSelectors() internal view returns (bytes4[] memory out) {
        out = _chainCensusAfter10Aug(upgrade.scriptPath());
        require(out.length == 56, "the layout before the 15 August cut must be 56 selectors");
    }

    /// Observation against computation: the chain snapshot of 14 August must agree
    /// with the census of 16 August rewound one step back.
    ///
    /// What disappears if this is removed: two sources become one again. While they
    /// are compared, an error in `addSelectors()` (which the rewind is made from)
    /// goes red HERE rather than showing up as a rejected production transaction;
    /// and a corrupted snapshot goes red against the rewind.
    function test_RewindOfTheCensusMatchesTheChainSnapshot() public view {
        _assertSameSelectorSet(
            _chainCensusAfter10Aug(upgrade.scriptPath()),
            _rewindCut(
                _censusFromFile(CENSUS_PATH, CENSUS_FACET, 64, "script/UpgradeArbiterAccountability.s.sol"),
                upgrade.addSelectors(),
                new bytes4[](0)
            ),
            "the chain snapshot of 14 August",
            "the census of 16 August rewound"
        );
    }

    /// The list in `ArbiterChainCensus._presentationCutAddSelectors()` is a second,
    /// textual copy of this cut's eight Add selectors. The bench of the 10 August cut
    /// needs it to rewind the census by two steps without deploying a second script
    /// for the purpose (the analysis and the measurement are in that function's
    /// header). There are two copies, so they must be compared against each other,
    /// or they will drift apart in silence.
    ///
    /// What disappears if this is removed: a signature changed in one place and
    /// forgotten in the other would take the 10 August cut's bench onto a layout that
    /// never existed on chain — and its pre-flight would start "checking" an invented
    /// world while staying green.
    function test_CensusRewindListMatchesTheCutsOwnAdd() public view {
        bytes4[] memory literal = _presentationCutAddSelectors();
        bytes4[] memory declared = upgrade.addSelectors();

        assertEq(literal.length, declared.length, "the two copies of the Add list differ in count");
        for (uint256 i = 0; i < literal.length; i++) {
            assertTrue(_censusContains(declared, literal[i]), "a signature from the rewind is missing from the cut's own Add");
        }
        for (uint256 i = 0; i < declared.length; i++) {
            assertTrue(_censusContains(literal, declared[i]), "the cut's own Add carries a selector that is missing from the rewind");
        }
    }

    /// The `LegacyPreSplitArbiterFacet` double must REALLY answer everything the
    /// benches of the historical cuts mount on it. It is checked not against lists
    /// written here but against the chain census: EVERY selector of the census must
    /// be in the double's ABI — all 64, including the bare removeArbiter.
    ///
    /// ⚠️ REWRITTEN, and there are now TWO claims instead of one. The earlier version
    /// demanded 63 selectors from the double and the ABSENCE of the bare
    /// removeArbiter "because it was deleted". That was a lock aimed at the wrong
    /// subject: the deletion is a property of TODAY'S facet, and it was being checked
    /// on the double, and passed only because the double inherited today's facet.
    /// The inheritance was the very thing being fixed: the double is declared to be
    /// the layout of THE CHAIN, and the chain routes removeArbiter and — with the
    /// facet of 15 August — really executes it.
    ///
    /// So two DIFFERENT subjects are now checked:
    ///   1. the double (= the chain) implements all 64 census selectors;
    ///   2. today's ArbiterRegistryFacet does NOT implement the bare removeArbiter —
    ///      exactly what was established when it was removed, and exactly what the
    ///      cut carries that selector away in a Remove group for.
    ///
    /// What disappears if the first is removed: a double that has lost one reader
    /// would mount as if nothing were wrong (diamondCut requires only that the
    /// address have code), and the pre-flight of a historical cut would start
    /// reverting `EvmError: Revert` without a word about the cause — measured: a
    /// removed `getOpenClaimCount` gave 11 such reds.
    ///
    /// What disappears if the second is removed: a bare button resurrected in the
    /// production facet would outlive its Remove — the selector would leave the
    /// routes while the code stayed in the repository and came back with the very
    /// next cut.
    function test_LegacyTwinAnswersEverythingTheChainRoutes() public view {
        // The double lives in another file, so the artifact path is not derived from
        // the contract name as it is in _abiSelectors.
        string memory json = vm.readFile("out/LegacyPreSplitArbiterFacet.sol/LegacyPreSplitArbiterFacet.json");
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        bytes4[] memory twin = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; i++) twin[i] = bytes4(keccak256(bytes(sigs[i])));

        bytes4[] memory census = _censusFromFile(
            CENSUS_PATH, CENSUS_FACET, 64, "script/UpgradeArbiterAccountability.s.sol"
        );
        bytes4 naked = bytes4(keccak256("removeArbiter(address)"));

        uint256 checked;
        for (uint256 i = 0; i < census.length; i++) {
            assertTrue(
                _censusContains(twin, census[i]),
                "the double does not implement a selector the chain routes"
            );
            checked++;
        }
        assertEq(checked, 64, "the chain census must be 64 selectors");
        assertTrue(
            _censusContains(twin, naked),
            "the double must carry the bare removeArbiter: the chain routes it, "
            "and the facet of 15 August answers it"
        );

        // The second subject: TODAY'S facet no longer implements it.
        assertFalse(
            _censusContains(_abiSelectors("ArbiterRegistryFacet"), naked),
            "the bare removeArbiter has come back in the production facet, and it was deleted"
        );
    }

    /// A LOCK ON THE SNAPSHOT'S FROZENNESS — ON ITS CODE, NOT ON ITS TEXT.
    ///
    /// `test/legacy/LegacyPreSplitArbiterFacet.sol` carries the CODE of
    /// `src/facets/ArbiterRegistryFacet.sol` as it stood in the source the facet
    /// standing on Base Sepolia since 15 August was built from. The fidelity of the
    /// copy was proved by a diff once, by hand. After that it was held only by a
    /// request in the file's header: editing the double's BODY (not its selectors)
    /// gave ZERO reds as long as the 64 selectors stayed in place. A snapshot that can
    /// be corrupted in silence is not a snapshot.
    ///
    /// ⚠️ WHAT CHANGED ON 30 AUGUST 2026. This lock used to pin the keccak256 of the
    /// file's WHOLE TEXT, taken from the artifact's `metadata.sources[…]` — the
    /// compiler's own number, with no second implementation of it here. That was the
    /// better arrangement while the whole text was frozen. It stopped being one: the
    /// snapshot's comments were translated into English for publication, so a lock on
    /// the whole text would have gone on guarding a claim — "this text is what was
    /// shipped" — that had ceased to be true, and would have gone red on the next
    /// wording fix exactly as loudly as on a change to the logic. A lock that cannot
    /// tell those two apart teaches the reader to update the literal without looking.
    ///
    /// So the lock was moved onto what the file actually promises: THE CODE. What is
    /// hashed is this file with comments removed (string literals respected) and runs
    /// of whitespace collapsed to a single space — the same reduction used for
    /// comparing deployed bytecode. The consequences are the whole point:
    ///   - an edit to the CODE of the double is RED;
    ///   - an edit to a COMMENT in the double is GREEN.
    ///
    /// ⚠️ The price of the move, stated plainly. The reduction is implemented HERE,
    /// in `_codeOnly` below, and a bug in it could leave this lock vacuous without
    /// making it red: an empty result hashes to a constant just as happily as the real
    /// one does. Two things hold against that. The LENGTH of the reduction is asserted
    /// beside the hash, so a stripper that returns nothing — or half — says so in
    /// words instead of quietly agreeing. And the move was accepted on a pair of
    /// mutations rather than on the argument above: a changed constant in the double's
    /// code turns this test red, a changed word in the double's comments does not.
    ///
    /// ⚠️ THIS LOCK GUARDS IMMUTABILITY, NOT FIDELITY. It says "the code is the code
    /// it was", and says nothing about that code matching the source it was taken
    /// from — that was proved separately, once, by hand, against the shipped source
    /// with the four renames listed in the snapshot's own header undone. That check
    /// needs the history and so cannot run here; this lock is what holds the file
    /// between such checks.
    ///
    /// What disappears if this is removed: the snapshot's body can be edited in
    /// silence again, and the benches of the two executed cuts will start reproducing
    /// a layout other than the one that lay on chain — while staying green.
    ///
    /// If an edit to the CODE is deliberate (a second snapshot is being created and
    /// this one renamed, say) — update both literals below along with it. That is
    /// exactly what is wanted: not a prohibition but deliberateness.
    function test_LegacyTwinSourceIsFrozen() public view {
        bytes memory code = _codeOnly(vm.readFile("test/legacy/LegacyPreSplitArbiterFacet.sol"));

        assertEq(
            code.length,
            38_368,
            "the CODE of the snapshot changed in size (or the stripper below is broken); "
            "if the edit is deliberate, update both literals and re-read the file header"
        );
        assertEq(
            keccak256(code),
            bytes32(0xe8e7781cf0a8083df78bac02e3392193028e5b589596c98a30406742d5b43802),
            "the CODE of the shipped facet's snapshot has changed, and it must be immutable; "
            "if the edit is deliberate, update both literals and re-read the file header"
        );
    }

    /// The reduction the lock above stands on: comments out, runs of whitespace
    /// collapsed to one space. String literals are copied through untouched — without
    /// that a `//` inside a string would swallow the rest of the line, and the lock
    /// would stop seeing a part of the very code it exists to guard.
    ///
    /// A single space is left where a comment or a run of whitespace stood, never
    /// nothing: `uint256/*x*/a` and `uint256 a` must not reduce to what `uint256a`
    /// reduces to.
    function _codeOnly(string memory sourceText) internal pure returns (bytes memory) {
        bytes1 constant_slash = 0x2f;
        bytes1 constant_star = 0x2a;
        bytes1 constant_space = 0x20;

        bytes memory src = bytes(sourceText);
        uint256 n = src.length;
        bytes memory out = new bytes(n);
        uint256 o = 0;
        uint256 i = 0;
        // 0 = code, 1 = line comment, 2 = block comment, 3 = string literal
        uint8 state = 0;
        bytes1 quote;
        bool escaped;

        while (i < n) {
            bytes1 c = src[i];

            if (state == 0) {
                if (c == constant_slash && i + 1 < n && src[i + 1] == constant_slash) {
                    state = 1;
                    i += 2;
                    continue;
                }
                if (c == constant_slash && i + 1 < n && src[i + 1] == constant_star) {
                    state = 2;
                    i += 2;
                    continue;
                }
                if (c == 0x22 || c == 0x27) {
                    state = 3;
                    quote = c;
                    escaped = false;
                    out[o] = c;
                    o++;
                    i++;
                    continue;
                }
                if (c == constant_space || c == 0x09 || c == 0x0a || c == 0x0d) {
                    if (o > 0 && out[o - 1] != constant_space) {
                        out[o] = constant_space;
                        o++;
                    }
                    i++;
                    continue;
                }
                out[o] = c;
                o++;
                i++;
                continue;
            }

            if (state == 1) {
                if (c == 0x0a) {
                    state = 0;
                    if (o > 0 && out[o - 1] != constant_space) {
                        out[o] = constant_space;
                        o++;
                    }
                }
                i++;
                continue;
            }

            if (state == 2) {
                if (c == constant_star && i + 1 < n && src[i + 1] == constant_slash) {
                    state = 0;
                    if (o > 0 && out[o - 1] != constant_space) {
                        out[o] = constant_space;
                        o++;
                    }
                    i += 2;
                    continue;
                }
                i++;
                continue;
            }

            // state == 3: inside a string literal, everything is copied verbatim
            out[o] = c;
            o++;
            if (escaped) escaped = false;
            else if (c == 0x5c) escaped = true;
            else if (c == quote) state = 0;
            i++;
        }

        // A leading space cannot appear (the first space is only written after
        // something else already has been), so only the tail needs trimming.
        while (o > 0 && out[o - 1] == constant_space) o--;
        assembly {
            mstore(out, o)
        }
        return out;
    }

    /// Mounts the "old" (pre-cut) layout: 56 selectors on ONE facet address —
    /// precisely the state standing on Base Sepolia today (169 selectors in total, 56
    /// of them arbiter ones). The eight new ones are NOT mounted: they are what this
    /// cut brings.
    function _mountOldFacet(DiamondProxy diamond) internal returns (address oldFacetAddr) {
        // ⚠️ The "facet from before the split" double rather than the production
        // ArbiterRegistryFacet: this bench reproduces the chain's layout AT THE
        // MOMENT of that cut — every selector on ONE address — and since then
        // fourteen readers have moved into ArbiterAccountabilityFacet, so no
        // production contract implements them all at once any more. A bare facet
        // would mount (diamondCut requires only the presence of code), but the
        // pre-flight really calls getOpenClaimCount and would revert.
        LegacyPreSplitArbiterFacet oldFacet = new LegacyPreSplitArbiterFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(oldFacet), IDiamondCut.FacetCutAction.Add, _oldFacetSelectors());
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        oldFacetAddr = address(oldFacet);
    }

    bytes32 constant ARB_POS = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    /// A direct write into vaultBalance (a plain uint256 field of
    /// ArbiterRegistryStorage.Data, slot POSITION+9). There is no setter without a
    /// USDC transfer, and fundVault() is unreachable here — this diamond does not
    /// mount Factory, and FactoryStorage.usdc is zero. The offset is confirmed by
    /// reading it back through the getter right after the write, not on trust.
    function _setVaultBalance(DiamondProxy diamond, uint256 amount) internal {
        vm.store(address(diamond), bytes32(uint256(ARB_POS) + 9), bytes32(amount));
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(), amount,
            "the vaultBalance offset in ArbiterRegistryStorage.Data has drifted"
        );
    }

    /// A direct write into openClaimCount[arbiter] (a mapping, slot base POSITION+13).
    /// Giving an arbiter an "open dispute" with a real claimDispute is impossible
    /// here — that needs an Agreement answering
    /// status()/disputedAt()/client()/executor(), and a registry record, neither of
    /// which the minimal diamond has.
    function _setOpenClaimCount(DiamondProxy diamond, address arbiter, uint256 n) internal {
        vm.store(address(diamond), keccak256(abi.encode(arbiter, uint256(ARB_POS) + 13)), bytes32(n));
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(arbiter), n,
            "the openClaimCount offset in ArbiterRegistryStorage.Data has drifted"
        );
    }

    /// A direct write into disputeClaims[agreement] (a mapping, slot base
    /// POSITION+2). The offset is confirmed through getDisputeClaimer() — an existing
    /// selector, mounted even BEFORE the cut.
    function _setDisputeClaimer(DiamondProxy diamond, address agreement, address arbiter) internal {
        vm.store(
            address(diamond),
            keccak256(abi.encode(agreement, uint256(ARB_POS) + 2)),
            bytes32(uint256(uint160(arbiter)))
        );
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getDisputeClaimer(agreement), arbiter,
            "the disputeClaims offset in ArbiterRegistryStorage.Data has drifted"
        );
    }

    /// A direct write into disputeClaimedAtBy[agreement][arbiter] (a nested mapping,
    /// slot base POSITION+22) and into presentationDigests[agreement] (a dynamic
    /// array in a mapping, slot base POSITION+24).
    ///
    /// NOT through recordNoResponse/recordPresentationDigest: both selectors are
    /// mounted by this very cut, so before it they are not on the diamond. The point
    /// of the raw write is different — to prove that the layout of the THREE NEW
    /// fields (append-only, added by this work) survives the replacement of the facet
    /// address, that is, a replacement of code and not of slots. They can only be read
    /// back AFTER the cut, through getDisputeClaimedAt/getPresentationDigests.
    function _seedNewFieldsRaw(
        DiamondProxy diamond,
        address agreement,
        address arbiter,
        uint256 claimedAt,
        bytes32 digest
    ) internal {
        bytes32 claimedSlot = keccak256(
            abi.encode(arbiter, keccak256(abi.encode(agreement, uint256(ARB_POS) + 22)))
        );
        vm.store(address(diamond), claimedSlot, bytes32(claimedAt));

        bytes32 lenSlot = keccak256(abi.encode(agreement, uint256(ARB_POS) + 24));
        vm.store(address(diamond), lenSlot, bytes32(uint256(1)));
        vm.store(address(diamond), keccak256(abi.encode(lenSlot)), digest);
    }

    address constant SEED_AGREEMENT = address(0xA9DEEA1);
    uint256 constant SEED_CLAIMED_AT = 1_723_600_000;
    bytes32 constant SEED_DIGEST = bytes32(uint256(0xD16E57));

    /// Seeds a NON-EMPTY state BEFORE the cut: a registered arbiter, a non-zero
    /// vault, a claimed dispute with a time anchor and one digest. Without this the
    /// storage-continuity comparison would compare zeroes with zeroes and would pass
    /// even if it were completely broken.
    ///
    /// To be called BEFORE ownership of the diamond is handed over: addArbiter is
    /// onlyOwnerOrChief.
    function _seedPreCutState(DiamondProxy diamond, address arbiter) internal {
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
        _setVaultBalance(diamond, 777_000_000); // 777 USDC — deliberately neither zero nor a "round" default
        _setDisputeClaimer(diamond, SEED_AGREEMENT, arbiter);
        _setOpenClaimCount(diamond, arbiter, 1);
        _seedNewFieldsRaw(diamond, SEED_AGREEMENT, arbiter, SEED_CLAIMED_AT, SEED_DIGEST);
    }

    /// An honest state: the pre-flight checks pass and return the correct old address.
    /// Without this test the reds from the next two would prove nothing — showing that
    /// a lock reverts on bad input is not enough, one has to show that it does NOT
    /// revert on good input.
    function test_PreflightPassesOnHonestState() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        address found = upgrade.checkReplaceGroup(upgrade.replaceSelectors(), address(diamond));
        assertEq(found, oldFacetAddr, "checkReplaceGroup did not find the mounted old facet address");

        upgrade.checkAddGroupUnmounted(upgrade.addSelectors(), address(diamond));
        // Nothing reverted — the point of the test.
    }

    /// What disappears if the fix is removed: the script runs against a diamond where
    /// one of the "remaining" selectors has already moved to another address (the
    /// facet was PARTIALLY upgraded by somebody else between runs) — a Replace onto a
    /// single new address would take part of the routes to the wrong place, and run()
    /// would learn of it only by outside observation after the rollout.
    function test_PreflightRevertsWhenReplaceSelectorLivesElsewhere() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        ArbiterRegistryFacet strayFacet = new ArbiterRegistryFacet();
        bytes4[] memory strayMount = new bytes4[](1);
        strayMount[0] = ArbiterRegistryFacet.getRefundableBounty.selector;
        IDiamondCut.FacetCut[] memory strayCut = new IDiamondCut.FacetCut[](1);
        strayCut[0] = IDiamondCut.FacetCut(address(strayFacet), IDiamondCut.FacetCutAction.Replace, strayMount);
        IDiamondCut(address(diamond)).diamondCut(strayCut, address(0), "");

        // The list goes into a local variable BEFORE expectRevert: expectRevert
        // catches exactly the next external call, and replaceSelectors() as an inline
        // argument would itself be that "next call", not checkReplaceGroup.
        bytes4[] memory sels = upgrade.replaceSelectors();
        vm.expectRevert(bytes("UpgradePresentationRecord: the Replace selectors are spread across more than one live facet address"));
        upgrade.checkReplaceGroup(sels, address(diamond));
    }

    /// What disappears if the fix is removed: the script runs against a diamond where
    /// an Add selector is already mounted by somebody (a repeated run of the same
    /// script, somebody else's parallel cut) — the diamond would revert the whole
    /// diamondCut with "Diamond: selector exists" AFTER the new facet was broadcast
    /// (the deployment happens, the cut does not), instead of a comprehensible refusal
    /// before a single unit of gas is spent.
    function test_PreflightRevertsWhenAddSelectorAlreadyMounted() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        ArbiterRegistryFacet stray = new ArbiterRegistryFacet();
        bytes4[] memory strayAdd = new bytes4[](1);
        strayAdd[0] = ArbiterRegistryFacet.recordNoResponse.selector;
        IDiamondCut.FacetCut[] memory strayCut = new IDiamondCut.FacetCut[](1);
        strayCut[0] = IDiamondCut.FacetCut(address(stray), IDiamondCut.FacetCutAction.Add, strayAdd);
        IDiamondCut(address(diamond)).diamondCut(strayCut, address(0), "");

        bytes4[] memory sels = upgrade.addSelectors();
        vm.expectRevert(bytes("UpgradePresentationRecord: an Add selector is already mounted somewhere, so Add will revert"));
        upgrade.checkAddGroupUnmounted(sels, address(diamond));
    }

    /// The post-flight check "the old address is empty" catches an under-mounted
    /// Replace: had buildCuts() forgotten one of the 56 selectors (the same class as
    /// test_ReplaceAndAddCoverWholeFacet, but here by the fact of routing on a live
    /// diamond rather than by the lists), the old facet would still hold at least one
    /// selector.
    function test_PostflightRevertsWhenOldFacetStillHoldsASelector() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        bytes4[] memory full = upgrade.replaceSelectors();
        bytes4[] memory incomplete = new bytes4[](full.length - 1);
        for (uint256 i = 0; i < incomplete.length; i++) incomplete[i] = full[i];

        ArbiterRegistryFacet newFacet = new ArbiterRegistryFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(newFacet), IDiamondCut.FacetCutAction.Replace, incomplete);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        vm.expectRevert(bytes("UpgradePresentationRecord: the old facet address still holds selectors after the cut"));
        upgrade.assertFacetHoldsNoSelectors(oldFacetAddr, address(diamond));
    }

    /// What disappears if the fix is removed: the post-flight check can be called with
    /// an address nothing actually landed on (run() swapped the old and new facet
    /// variables), and it would quietly agree. In the neighbouring file this same
    /// class was found by mutation: removing the require in assertRouted gave 0 red
    /// while the check was called only on an HONEST state.
    function test_PostflightRevertsWhenSelectorNotRoutedToExpectedFacet() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        ArbiterRegistryFacet newFacet = new ArbiterRegistryFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(newFacet)), address(0), "");

        bytes4[] memory sels = upgrade.replaceSelectors();
        vm.expectRevert(bytes("UpgradePresentationRecord: a selector did not land on the new facet"));
        upgrade.assertRouted(sels, oldFacetAddr, address(diamond));
    }

    // ════════════════════════════════════════════════════════════════════
    // The floor for a record of silence — the VALUE is compared, not "the call did not fail"
    // ════════════════════════════════════════════════════════════════════

    /// An honest state: the floor through the diamond equals a day, and the check stays silent.
    function test_FloorCheckPassesOnHonestDiamond() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);
        ArbiterRegistryFacet newFacet = new ArbiterRegistryFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(newFacet)), address(0), "");

        upgrade.assertNoResponseFloorAnswers(address(diamond)); // did not revert — the point of the test
    }

    /// What disappears if the fix is removed: the post-flight check stops telling "the
    /// floor answers" from "the floor answers CORRECTLY". The measurement is real: the
    /// getNoResponseFloor selector is mounted on a double that returns 12 hours
    /// instead of a day — the route is alive, the loupe is content, and the value is a
    /// lie. That is exactly the case the check compares a number for rather than the
    /// fact of a return: the client takes the floor from the chain and would have drawn
    /// a person "wait 12 hours", after which the chain would refuse them for another
    /// twelve.
    function test_FloorCheckRevertsWhenDiamondAnswersWrongNumber() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        WrongFloorStub stub = new WrongFloorStub();
        bytes4[] memory stubSel = new bytes4[](1);
        stubSel[0] = ArbiterRegistryFacet.getNoResponseFloor.selector;
        IDiamondCut.FacetCut[] memory stubCut = new IDiamondCut.FacetCut[](1);
        stubCut[0] = IDiamondCut.FacetCut(address(stub), IDiamondCut.FacetCutAction.Add, stubSel);
        IDiamondCut(address(diamond)).diamondCut(stubCut, address(0), "");

        vm.expectRevert(bytes("post-flight: the floor for a record of silence does not answer through the diamond"));
        upgrade.assertNoResponseFloorAnswers(address(diamond));
    }

    // ════════════════════════════════════════════════════════════════════
    // Continuity of the arbiter storage across the cut
    // ════════════════════════════════════════════════════════════════════

    /// An honest state: an identical before/after snapshot does not revert.
    function test_StorageContinuity_PassesOnUnchangedSnapshot() public view {
        UpgradePresentationRecord.StorageSnapshot memory s =
            UpgradePresentationRecord.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 5});
        upgrade.assertStorageContinuity(s, s); // nothing reverted — the point of the test
    }

    /// What disappears if the fix is removed: the script drives silently past a shift
    /// in the arbiter namespace's layout — exactly the class that in July 2026 brought
    /// getOpenJobs() down with Panic(0x22) on live JobBoard storage, AFTER the rollout
    /// rather than before.
    function test_StorageContinuity_RevertsWhenArbiterCountChanged() public {
        UpgradePresentationRecord.StorageSnapshot memory b =
            UpgradePresentationRecord.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 5});
        UpgradePresentationRecord.StorageSnapshot memory a =
            UpgradePresentationRecord.StorageSnapshot({arbiterCount: 4, vaultBalance: 100, arbiterFloor: 5});
        vm.expectRevert(bytes("post-flight: getArbiters().length changed across the cut, so the layout may have shifted"));
        upgrade.assertStorageContinuity(b, a);
    }

    function test_StorageContinuity_RevertsWhenVaultBalanceChanged() public {
        UpgradePresentationRecord.StorageSnapshot memory b =
            UpgradePresentationRecord.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 5});
        UpgradePresentationRecord.StorageSnapshot memory a =
            UpgradePresentationRecord.StorageSnapshot({arbiterCount: 3, vaultBalance: 101, arbiterFloor: 5});
        vm.expectRevert(bytes("post-flight: getVaultBalance() changed across the cut, so the layout may have shifted"));
        upgrade.assertStorageContinuity(b, a);
    }

    function test_StorageContinuity_RevertsWhenArbiterFloorChanged() public {
        UpgradePresentationRecord.StorageSnapshot memory b =
            UpgradePresentationRecord.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 5});
        UpgradePresentationRecord.StorageSnapshot memory a =
            UpgradePresentationRecord.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 6});
        vm.expectRevert(bytes("post-flight: getArbiterFloor() changed across the cut, so the layout may have shifted"));
        upgrade.assertStorageContinuity(b, a);
    }

    // ════════════════════════════════════════════════════════════════════
    // The warning about disputes claimed BEFORE the cut
    // ════════════════════════════════════════════════════════════════════

    /// An arbiter with an open dispute must land in the list: their dispute was claimed
    /// BEFORE the cut, they have no time anchor, and recordNoResponse will answer them
    /// with ClaimTimeUnknown. The cure is releaseDisputeClaim and claiming again.
    function test_FindArbitersWithPreCutClaims_FlagsArbiterWithOpenClaim() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);
        ArbiterRegistryFacet f = ArbiterRegistryFacet(address(diamond));

        address arb = address(0xAB1);
        f.addArbiter(arb);
        _setOpenClaimCount(diamond, arb, 1);

        address[] memory flagged = upgrade.findArbitersWithPreCutClaims(address(diamond));
        assertEq(flagged.length, 1, "an arbiter with an open dispute must land in the warning");
        assertEq(flagged[0], arb);
    }

    /// What disappears if the fix is removed: the pre-flight stops warning about
    /// arbiters whose disputes, claimed before the cut, will silently be refused a
    /// record of silence after the rollout — the arbiter will decide "the button is
    /// broken" instead of re-claiming the dispute.
    function test_FindArbitersWithPreCutClaims_SkipsArbiterWithoutOpenClaim() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);
        ArbiterRegistryFacet f = ArbiterRegistryFacet(address(diamond));

        f.addArbiter(address(0xAB2)); // registered, but openClaimCount == 0

        address[] memory flagged = upgrade.findArbitersWithPreCutClaims(address(diamond));
        assertEq(flagged.length, 0, "with no open dispute there is nothing to warn about");
    }

    /// Filters per arbiter rather than by "is there anybody at all".
    function test_FindArbitersWithPreCutClaims_MixOfFlaggedAndNot() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);
        ArbiterRegistryFacet f = ArbiterRegistryFacet(address(diamond));

        address quiet = address(0xAB3);
        address busy  = address(0xAB4);
        f.addArbiter(quiet);
        f.addArbiter(busy);
        _setOpenClaimCount(diamond, busy, 2);

        address[] memory flagged = upgrade.findArbitersWithPreCutClaims(address(diamond));
        assertEq(flagged.length, 1);
        assertEq(flagged[0], busy);
    }

    /// The warning is called BEFORE the broadcast — that is, BEFORE
    /// getDisputeClaimedAt is mounted (it is one of the eight Add selectors of THIS
    /// cut). A lock against the regression: had the function read the anchor directly,
    /// it would have reverted "Diamond: Function does not exist" on EVERY pre-flight
    /// on the live chain — the warning would have brought the whole script down
    /// instead of merely printing.
    function test_FindArbitersWithPreCutClaims_WorksBeforeAddSelectorsAreMounted() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond); // ONLY the old layout — getDisputeClaimedAt is NOT mounted
        ArbiterRegistryFacet f = ArbiterRegistryFacet(address(diamond));

        address arb = address(0xAB5);
        f.addArbiter(arb);
        _setOpenClaimCount(diamond, arb, 1);

        // First the premise is proved: the anchor really is not mounted before the cut.
        vm.expectRevert();
        ArbiterAccountabilityFacet(address(diamond)).getDisputeClaimedAt(address(0xDEAD));

        // And the warning meanwhile runs without a single revert.
        address[] memory flagged = upgrade.findArbitersWithPreCutClaims(address(diamond));
        assertEq(flagged.length, 1);
        assertEq(flagged[0], arb);
    }

    // ════════════════════════════════════════════════════════════════════
    // The full cycle
    // ════════════════════════════════════════════════════════════════════

    /// Deploy → mount the "old" layout → pre-flight checks → the cut itself through
    /// buildCuts() (the same function run() calls) → post-flight checks → a functional
    /// smoke test of ALL EIGHT new entrances THROUGH THE DIAMOND. Through the diamond
    /// specifically, and not by a direct call to the facet: a Replace/Add onto an
    /// address that does not implement the selector does NOT revert during the cut —
    /// "counts as mounted" and "the route executes the code" are different things (the
    /// class of bug that was deployed, never once fired, and noticed a month later).
    function test_FullUpgradeCycleOnLocalDiamond() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        address foundOld = upgrade.checkReplaceGroup(upgrade.replaceSelectors(), address(diamond));
        assertEq(foundOld, oldFacetAddr);
        upgrade.checkAddGroupUnmounted(upgrade.addSelectors(), address(diamond));

        uint256 before = upgrade.totalRoutedSelectors(address(diamond));

        // The "facet from before the split" double: this cut was executed on 15 August,
        // when five of its readers still lived in ArbiterRegistryFacet, and the smoke
        // test below calls them for real. That day is reproduced exactly.
        LegacyPreSplitArbiterFacet newFacet = new LegacyPreSplitArbiterFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(newFacet)), address(0), "");

        upgrade.assertRouted(upgrade.replaceSelectors(), address(newFacet), address(diamond));
        upgrade.assertRouted(upgrade.addSelectors(), address(newFacet), address(diamond));
        upgrade.assertFacetHoldsNoSelectors(oldFacetAddr, address(diamond));

        uint256 afterTotal = upgrade.totalRoutedSelectors(address(diamond));
        assertEq(
            afterTotal, before + upgrade.addSelectors().length,
            "the count of mounted selectors did not move by exactly +Add"
        );

        // ── A smoke test of all eight THROUGH THE DIAMOND ────────────────
        ArbiterRegistryFacet d = ArbiterRegistryFacet(address(diamond));
        address probe = address(0xDEAD);

        assertEq(d.getNoResponseFloor(), 24 hours, "the floor for a record of silence through the diamond is not a day");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getDisputeClaimedAt(probe), 0, "the claim anchor on a clean deal must be zero");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getNoResponseAt(probe), 0, "the record of silence on a clean deal must be zero");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getPresentationDigestCount(probe), 0, "the digest counter on a clean deal must be zero");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getPresentationDigests(probe).length, 0, "the digest feed on a clean deal must be empty");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getPresentationDigestsPage(probe, 0, 10).length, 0, "the digest window on a clean deal must be empty");

        // The two writing functions go through the diamond too. A refusal is expected
        // and is itself the proof that the route executes THE FACET'S code: the diamond's empty
        // fallback would have reverted "Diamond: Function does not exist" rather than
        // with an application error from the facet.
        vm.expectRevert(abi.encodeWithSignature("NotClaimingArbiter()"));
        d.recordNoResponse(probe);

        vm.expectRevert(abi.encodeWithSignature("ZeroDigest()"));
        d.recordPresentationDigest(probe, bytes32(0));
    }

    /// Literally run() — not a retelling of its steps but the method itself, with real
    /// vm.envAddress/vm.envUint/vm.startBroadcast, on a locally deployed diamond. The
    /// owner is the address derived from PRIVATE_KEY (a two-step handover), exactly as
    /// diamondCut requires on the live chain.
    ///
    /// The diamond is seeded NON-empty before the cut: an arbiter, a non-zero vault, a
    /// claimed dispute with a time anchor and one digest — written raw into the slots,
    /// because those entrances are mounted only by this very cut. Without the seed the
    /// storage-continuity check INSIDE run() would compare zeroes with zeroes and would
    /// pass even if it were completely broken.
    function test_RunEndToEndOnLocalDiamond() public {
        uint256 pk = 0xA11CE;
        address ownerAddr = vm.addr(pk);
        address seededArbiter = address(0xA12BE12);

        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);
        _seedPreCutState(diamond, seededArbiter);

        UpgradePresentationRecord.StorageSnapshot memory before =
            upgrade.snapshotArbiterStorage(address(diamond));
        assertEq(before.arbiterCount, 1, "the seed did not add an arbiter, so the comparison below would be zeroes against zeroes");
        assertEq(before.vaultBalance, 777_000_000, "the seed did not raise vaultBalance");

        OwnershipFacet(address(diamond)).transferOwnership(ownerAddr);
        vm.prank(ownerAddr);
        OwnershipFacet(address(diamond)).acceptOwnership();
        assertEq(OwnershipFacet(address(diamond)).owner(), ownerAddr, "ownership did not move");

        vm.setEnv("DIAMOND_ADDRESS", vm.toString(address(diamond)));
        vm.setEnv("PRIVATE_KEY", vm.toString(pk));

        uint256 routedBefore = upgrade.totalRoutedSelectors(address(diamond));

        upgrade.run(); // ← the method itself, not a retelling of it

        upgrade.assertFacetHoldsNoSelectors(oldFacetAddr, address(diamond));
        assertEq(
            upgrade.totalRoutedSelectors(address(diamond)),
            routedBefore + upgrade.addSelectors().length,
            "after run() the selector count did not move by exactly +Add"
        );

        UpgradePresentationRecord.StorageSnapshot memory afterCut =
            upgrade.snapshotArbiterStorage(address(diamond));
        assertEq(afterCut.arbiterCount, before.arbiterCount, "arbiterCount did not survive the cut");
        assertEq(afterCut.vaultBalance, before.vaultBalance, "vaultBalance did not survive the cut");

        // ⚠️ The move of the readers is played out here as in the neighbouring cycle
        // test. Ownership of the diamond is already with ownerAddr, so the cut goes in
        // its name: diamondCut admits only the owner.
        // startPrank rather than prank: the helper makes several external calls (a
        // facet deployment, loupe reads and the diamondCut itself), and prank holds
        // for exactly one.
        vm.startPrank(ownerAddr);
        _applyTask45MoveAfterLegacyCut(diamond);
        vm.stopPrank();

        // The raw bytes of the three NEW fields, written BEFORE their getters existed
        // on this diamond at all, are read back THROUGH THEM now that they are
        // mounted: the append-only layout survived the replacement of the facet
        // address.
        ArbiterRegistryFacet d = ArbiterRegistryFacet(address(diamond));
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getDisputeClaimedAt(SEED_AGREEMENT), SEED_CLAIMED_AT,
            "the claim anchor written BEFORE the cut did not survive the facet replacement"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getPresentationDigestCount(SEED_AGREEMENT), 1,
            "the digest counter written BEFORE the cut did not survive the facet replacement"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getPresentationDigests(SEED_AGREEMENT)[0], SEED_DIGEST,
            "the digest written BEFORE the cut did not survive the facet replacement"
        );
    }

    /// The only test that proves by measurement that the floor check stands INSIDE
    /// run() and not only in the extracted helper. The diamond's answer to
    /// getNoResponseFloor() is substituted — the route and the cut are entirely honest
    /// — and run() must fail on the post-flight. Remove the call to
    /// assertNoResponseFloorAnswers from run() while leaving the function itself, and
    /// this test goes red while the others do not.
    function test_RunRevertsWhenFloorAnswersWrong() public {
        uint256 pk = 0xA11CE;
        address ownerAddr = vm.addr(pk);

        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        OwnershipFacet(address(diamond)).transferOwnership(ownerAddr);
        vm.prank(ownerAddr);
        OwnershipFacet(address(diamond)).acceptOwnership();

        vm.setEnv("DIAMOND_ADDRESS", vm.toString(address(diamond)));
        vm.setEnv("PRIVATE_KEY", vm.toString(pk));

        vm.mockCall(
            address(diamond),
            abi.encodeWithSelector(ArbiterRegistryFacet.getNoResponseFloor.selector),
            abi.encode(uint256(12 hours))
        );

        vm.expectRevert(bytes("post-flight: the floor for a record of silence does not answer through the diamond"));
        upgrade.run();
    }

    /// A second measurement of the same kind, but for the storage-continuity check: it
    /// proves that assertStorageContinuity really IS CALLED from run() rather than
    /// merely existing beside it. Without this test, removing the line
    /// `assertStorageContinuity(before, afterCut);` from run() gave 0 red out of 661 —
    /// three tests below checked the CONDITION and not one checked that anybody asks
    /// it. Exactly the class locks are created for: the code is there and nobody uses
    /// it.
    ///
    /// How the divergence is made: getVaultBalance() is substituted on the OLD facet
    /// address. The pre-flight snapshot is read through it (the diamond delegates there
    /// before the cut) and sees 999; the post-flight one goes to the new facet and sees
    /// the real value. It is a literal imitation of what the comparison exists for: one
    /// and the same field, read by different code before and after the cut, has
    /// diverged.
    function test_RunRevertsWhenStorageDriftsAcrossTheCut() public {
        uint256 pk = 0xA11CE;
        address ownerAddr = vm.addr(pk);

        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        OwnershipFacet(address(diamond)).transferOwnership(ownerAddr);
        vm.prank(ownerAddr);
        OwnershipFacet(address(diamond)).acceptOwnership();

        vm.setEnv("DIAMOND_ADDRESS", vm.toString(address(diamond)));
        vm.setEnv("PRIVATE_KEY", vm.toString(pk));

        vm.mockCall(
            oldFacetAddr,
            abi.encodeWithSelector(ArbiterRegistryFacet.getVaultBalance.selector),
            abi.encode(uint256(999))
        );

        vm.expectRevert(bytes("post-flight: getVaultBalance() changed across the cut, so the layout may have shifted"));
        upgrade.run();
    }

    // ════════════════════════════════════════════════════════════════════
    // EVERY lock in run() is broken through run() itself
    //
    // A review found a common flaw in all the tests below in this file: they measured
    // a helper's CONDITION (call it separately on a lying state and see a revert) but
    // did not measure that run() CALLS it. The measurement: remove from run() the call
    // to checkReplaceGroup / checkAddGroupUnmounted / assertRouted (either) /
    // assertFacetHoldsNoSelectors / the selector count — 0 red out of 662 for each.
    // The cause was in the end-to-end test: it called the post-flight checks again
    // ITSELF after run(), that is, it checked the world after the cut rather than what
    // the script guards.
    //
    // The form below is one for all: break the world so that run() ITSELF is bound to
    // fail, and demand precisely that message from it. The model is the two tests
    // above (the floor and storage continuity), which did not suffer from this flaw.
    // ════════════════════════════════════════════════════════════════════

    /// The shared preparation of the negative tests on run(): a diamond with the "old"
    /// layout, ownership with the PRIVATE_KEY address, and the environment set.
    function _armRun(DiamondProxy diamond) internal returns (uint256 pk) {
        pk = 0xA11CE;
        address ownerAddr = vm.addr(pk);
        OwnershipFacet(address(diamond)).transferOwnership(ownerAddr);
        vm.prank(ownerAddr);
        OwnershipFacet(address(diamond)).acceptOwnership();
        // ⚠️ A RACE THROUGH THE PROCESS-GLOBAL vm.setEnv. `vm.setEnv` writes into the
        // PROCESS environment, while forge's suites run in parallel. Three cut benches
        // (ArbiterAccountabilityUpgrade, PresentationRecordUpgrade,
        // ArbiterChatKeyUpgrade) put DIAMOND_ADDRESS here and read it back inside
        // run(). It is harmless precisely because all three put THE SAME address
        // there: their sequence of `new`s before creating the diamond coincides, and
        // so therefore does the nonce.
        //
        // One extra `new` added to any of the three shifts the nonce — the address
        // moves, somebody else's run() goes with the loupe into an unrelated contract,
        // and the full run starts failing with a "random EvmError: Revert" about once
        // in twenty runs, saying nothing about the cause (measured: 2 failures out of
        // 40, against a green single run of 25 out of 25).
        //
        // The race itself is NOT fixed by this line — the real cure is not to pass the
        // address through the environment at all, and that is recorded separately as an
        // open item. This line turns a future flake into a DETERMINISTIC red with a
        // named cause.
        //
        // The address was obtained BY MEASUREMENT (an assertEq probe across all three
        // benches at once) rather than derived from the code: a derived one would move
        // along with the race and stay silent.
        assertEq(
            address(diamond),
            0xc7183455a4C133Ae270771860664b6B7ec320bB1,
            "the diamond's address moved: the bench's nonce shifted, and DIAMOND_ADDRESS "
            "now differs between the three suites in the process; see the comment above"
        );
        vm.setEnv("DIAMOND_ADDRESS", vm.toString(address(diamond)));
        vm.setEnv("PRIVATE_KEY", vm.toString(pk));
    }

    /// Remove `checkReplaceGroup(...)` from run() and this test goes red.
    ///
    /// The world is really broken: one of the 56 "remaining" selectors is moved onto an
    /// unrelated facet, as if somebody else's upgrade had passed between runs. In that
    /// state a Replace onto a single new address would take part of the routes to the
    /// wrong place, and without the pre-flight the script would learn of it only after
    /// the broadcast.
    function test_RunRevertsWhenReplaceGroupIsSplitAcrossFacets() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        ArbiterRegistryFacet strayFacet = new ArbiterRegistryFacet();
        bytes4[] memory stray = new bytes4[](1);
        stray[0] = ArbiterRegistryFacet.getRefundableBounty.selector;
        IDiamondCut.FacetCut[] memory strayCut = new IDiamondCut.FacetCut[](1);
        strayCut[0] = IDiamondCut.FacetCut(address(strayFacet), IDiamondCut.FacetCutAction.Replace, stray);
        IDiamondCut(address(diamond)).diamondCut(strayCut, address(0), "");

        _armRun(diamond);

        vm.expectRevert(bytes("UpgradePresentationRecord: the Replace selectors are spread across more than one live facet address"));
        upgrade.run();
    }

    /// Remove `checkAddGroupUnmounted(...)` from run() and this test goes red.
    ///
    /// The world is really broken: one of the eight new selectors is already mounted (a
    /// repeated run of the script, somebody else's parallel cut). Without the
    /// pre-flight the diamond would revert the whole diamondCut with "Diamond: selector
    /// exists" AFTER the new facet was broadcast — the deployment happened, the cut did
    /// not, and the gas is spent.
    function test_RunRevertsWhenAnAddSelectorIsAlreadyMounted() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        ArbiterRegistryFacet stray = new ArbiterRegistryFacet();
        bytes4[] memory strayAdd = new bytes4[](1);
        strayAdd[0] = ArbiterRegistryFacet.recordNoResponse.selector;
        IDiamondCut.FacetCut[] memory strayCut = new IDiamondCut.FacetCut[](1);
        strayCut[0] = IDiamondCut.FacetCut(address(stray), IDiamondCut.FacetCutAction.Add, strayAdd);
        IDiamondCut(address(diamond)).diamondCut(strayCut, address(0), "");

        _armRun(diamond);

        vm.expectRevert(bytes("UpgradePresentationRecord: an Add selector is already mounted somewhere, so Add will revert"));
        upgrade.run();
    }

    /// Remove the FIRST `assertRouted(replaceSels, ...)` from run() and this test goes
    /// red.
    ///
    /// A real diamondCut cannot be made to take one Replace selector past the new
    /// facet: buildCuts() assembles the routes itself. So it is THE DIRECTORY that
    /// lies — the loupe's answer for one selector is substituted with the OLD facet
    /// address. The substitution is chosen precisely so that the pre-flight stays
    /// content (before the cut the old address is what should be there) and exactly the
    /// thing under test fails. That is the nature of the bug the check was written for:
    /// "counts as mounted" and "stands where it is thought to" are different things.
    function test_RunRevertsWhenAReplaceSelectorDidNotLandOnTheNewFacet() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);
        _armRun(diamond);

        vm.mockCall(
            address(diamond),
            abi.encodeWithSelector(
                IDiamondLoupe.facetAddress.selector,
                ArbiterRegistryFacet.setArbiterChatKey.selector
            ),
            abi.encode(oldFacetAddr)
        );

        vm.expectRevert(bytes("UpgradePresentationRecord: a selector did not land on the new facet"));
        upgrade.run();
    }

    /// Remove the SECOND `assertRouted(addSels, ...)` from run() and this test goes
    /// red. The same device, but the substituted answer is zero: the pre-flight demands
    /// exactly zero from the Add selectors and stays content, while the post-flight is
    /// bound to see the new facet and does not. A separate test, because this is a
    /// separate line in run(): either of the two can be removed.
    function test_RunRevertsWhenAnAddSelectorDidNotLandOnTheNewFacet() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);
        _armRun(diamond);

        vm.mockCall(
            address(diamond),
            abi.encodeWithSelector(
                IDiamondLoupe.facetAddress.selector,
                ArbiterAccountabilityFacet.getPresentationDigestsPage.selector
            ),
            abi.encode(address(0))
        );

        vm.expectRevert(bytes("UpgradePresentationRecord: a selector did not land on the new facet"));
        upgrade.run();
    }

    /// Remove `assertFacetHoldsNoSelectors(oldFacet, ...)` from run() and this test
    /// goes red.
    ///
    /// The world is really broken, and without a single substitution: an EXTRA selector
    /// hangs on the old facet's address, one that is in neither Replace nor Add — a
    /// trace of some earlier cut. The Replace will displace the 56 familiar ones, this
    /// one will stay, and the old address will go on serving a live route on top of
    /// "already replaced" code. The pre-flight does not see that and should not: it
    /// looks only at the cut's groups.
    function test_RunRevertsWhenOldFacetKeepsALeftoverSelector() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        // addFunctions requires only that the address have code, not that it implement
        // the selector — which is why the "trace of an earlier cut" is hung right here.
        bytes4[] memory leftover = new bytes4[](1);
        leftover[0] = bytes4(keccak256("leftoverFromAnOlderCut()"));
        IDiamondCut.FacetCut[] memory leftoverCut = new IDiamondCut.FacetCut[](1);
        leftoverCut[0] = IDiamondCut.FacetCut(oldFacetAddr, IDiamondCut.FacetCutAction.Add, leftover);
        IDiamondCut(address(diamond)).diamondCut(leftoverCut, address(0), "");

        _armRun(diamond);

        vm.expectRevert(bytes("UpgradePresentationRecord: the old facet address still holds selectors after the cut"));
        upgrade.run();
    }

    /// Remove the final `require(selectorsAfter == selectorsBefore + addSels.length)`
    /// from run() and this test goes red.
    ///
    /// What is broken is the census: facets() answers both reads identically, before
    /// and after the cut. The count was bound to move by exactly +8 and did not move at
    /// all — that is, the cut did something other than what it declared. No other check
    /// in run() catches this: the routes are honest one by one, the old address is
    /// empty, the storage is in place, the floor answers. That is precisely why the
    /// final count stands on a line of its own.
    function test_RunRevertsWhenRoutedSelectorCountDoesNotMoveByAdd() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);
        _armRun(diamond);

        IDiamondLoupe.Facet[] memory frozen = new IDiamondLoupe.Facet[](0);
        vm.mockCall(
            address(diamond),
            abi.encodeWithSelector(IDiamondLoupe.facets.selector),
            abi.encode(frozen)
        );

        vm.expectRevert(bytes("post-flight: the count of mounted selectors did not move by exactly +Add"));
        upgrade.run();
    }

    /// Remove `warnArbitersWithPreCutClaims(diamond)` from run() and this test goes
    /// red.
    ///
    /// This is a warning, not a lock: it prints and does NOT revert, so "break the
    /// world so that run() fails" is inapplicable to it in principle. Leaving it as a
    /// silent exception is not allowed (that is worse than a missing check), so it is
    /// measured differently — by the TRACE it is bound to leave: getOpenClaimCount() is
    /// called in the whole of run() from this walk and from nowhere else (the storage
    /// snapshot reads getArbiters, getVaultBalance and getArbiterFloor). vm.expectCall
    /// demands that call by the name of a specific arbiter — remove the walk and the
    /// call is gone and the test is red.
    ///
    /// The value of the warning itself: a dispute claimed BEFORE the cut will be left
    /// without a time anchor, and recordNoResponse will refuse it with
    /// ClaimTimeUnknown. Without the printout the arbiter will decide the button is
    /// broken instead of re-claiming the dispute. As of 14 August there are no such
    /// disputes on chain (getOpenClaimCount = 0), so an arbiter with an open dispute is
    /// seated here by hand — otherwise the walk would go over an empty list and the
    /// trace would be indistinguishable from its absence.
    function test_RunCallsThePreCutClaimsWarning() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        address arb = address(0xAB7);
        ArbiterRegistryFacet(address(diamond)).addArbiter(arb);
        _setOpenClaimCount(diamond, arb, 1);

        _armRun(diamond);

        vm.expectCall(
            address(diamond),
            abi.encodeWithSelector(ArbiterAccountabilityFacet.getOpenClaimCount.selector, arb)
        );
        upgrade.run();
    }
}
