// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  The gate for script/UpgradeRegistryHandInSignal.s.sol
// ============================================================
//
// The cut is Replace 13 + Add 1 on ONE facet address, which is both halves of
// the pair that drops a whole cut on one live transaction: `Replace` reverts
// "Diamond: selector not found" on a selector that is not mounted, `Add`
// reverts "Diamond: selector exists" on one that is. A selector filed under the
// wrong group takes the entire diamondCut with it, AFTER the facet has been
// paid for.
//
// ⚠️ WHERE THE EXPECTED SIDE COMES FROM, WHICH IS THE WHOLE DESIGN OF THIS FILE.
// Never from the script. Two independent oracles, and the script is neither:
//
//   * solc's `methodIdentifiers`, read out of the build artifact, answers "does
//     the cut mount exactly what the facet implements";
//   * a census of the LIVE CHAIN, committed as data in
//     test/fixtures/chain-2026-08-31-registry-handin-selectors.json, answers
//     "which group does each selector belong in".
//
// A stand that derived "what is mounted" from the script's own
// `registryReplaceSelectors()` would agree with itself no matter how the
// selectors were filed. That is the fourth way to be fooled by a measurement,
// and on 16 August 2026 it produced a green stand next to two red neighbours
// while the cut underneath was genuinely broken.

import "forge-std/Test.sol";
import "../script/UpgradeRegistryHandInSignal.s.sol";
import "../script/DeployFull.s.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/TreasuryLinkFacet.sol";
import "../src/facets/ReputationFacet.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterSplitRig} from "./ArbiterSplitRig.sol";

contract WorkHandInVisibleUpgradeTest is Test, ArbiterSplitRig {
    UpgradeRegistryHandInSignal internal upgrade;
    DeployFull internal deploy;
    DiamondProxy internal diamond;

    string constant CENSUS_PATH =
        "test/fixtures/chain-2026-08-31-registry-handin-selectors.json";

    /// Read off the chain on 31 August 2026 and written down by a person, so
    /// that a facet which silently grows or loses a function stops here instead
    /// of at the signature.
    uint256 constant CHAIN_FACETS     = 13;

    uint256 constant CHAIN_ROUTED     = 221;
    uint256 constant REGISTRY_SELECTORS = 13;
    uint256 constant ADDED_SELECTORS  = 1;

    /// ⚠️ NO "HOW FAR AHEAD OF ITS CENSUS IS THIS RIG" NUMBER LIVES HERE ANY
    /// MORE, AND REMOVING IT IS THE POINT OF THIS FILE'S REWRITE.
    ///
    /// Until 14 September 2026 this stand carried a running total --
    /// PENDING_BRAKE_ADDS, PENDING_FEE_CAP_ADDS, PENDING_ARBITER_BOND_ADDS,
    /// PENDING_UNPROVEN_SEAT_ADDS, PENDING_BOND_PERMIT_ADDS and
    /// TREASURY_LINK_LANDED_AFTER_THIS_CENSUS -- and every cut that landed in
    /// the tree wrote one more line into it. That is a ratchet turning into a
    /// budget, and it is how ten selectors of drift stayed invisible for ten
    /// days: an old census plus its accumulated allowances came to exactly what
    /// the tree built, while both were nine behind the chain.
    ///
    /// The numbers were never needed. A census is a COMPLETE list of what the
    /// chain routed at a named block, so the rig is conformed to it by SET
    /// DIFFERENCE: take out everything the census does not hold, then prove the
    /// two sets are equal. A cut landing in the tree changes the size of that
    /// difference and nothing else, so it needs no hand anywhere -- and a hand
    /// could not buy a green here even if one were offered, because the
    /// comparison at the end is equality, not a count.
    ///
    /// ⚠️ AND THE LABELS HAD ALREADY STARTED LYING. Measured 14 September 2026
    /// from forge's own receipts: script/UpgradeArbiterBondRequired.s.sol was
    /// signed in block 46645782 and
    /// script/UpgradeUnprovenSeatRevocationAndBondPermit.s.sol in block
    /// 46686454. Three of the deleted lines still said "pending, has not landed
    /// yet". Their numbers stayed right only because this census predates both
    /// cuts, which is the disease in one sentence: a number covering both "not
    /// landed yet" and "my census is stale" can no longer say which one moved.

    function setUp() public {
        upgrade = new UpgradeRegistryHandInSignal();
        deploy  = new DeployFull();
        diamond = _deployPreCutDiamond();
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE TWO INDEPENDENT ORACLES
    // ══════════════════════════════════════════════════════════════════════

    /// The script's hand-written lists against solc's output for the facet.
    /// A function the facet gains and nobody mounts would otherwise ship dead:
    /// present in the ABI, routed nowhere, discovered by the first person whose
    /// button did nothing.
    /// The one the registry grew AFTER this cut (18 September 2026, "an arbiter
    /// is not a player in the market"): `getOpenDealCount(address)`, the count
    /// of unfinished deals per party that the doors into the arbiter corps read.
    /// By SIGNATURE TEXT, never read off the later script's lists.
    ///
    /// ⚠️ THE SCRIPT'S OWN CHECK STAYS STRICT and still refuses — this cut is a
    /// RECORD of the fourteen selectors mounted on 31 August 2026, and
    /// re-running it today would deploy a registry with fifteen functions and
    /// mount fourteen, shipping one dead. Demanding that the record equal
    /// today's ABI is demanding that the past match the present; the same
    /// device, with the same argument, is in test/BoardFeeDeliveryUpgrade.t.sol
    /// and test/JobBoardApplicantGateUpgrade.t.sol.
    function _grownAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](5);
        sels[0] = bytes4(keccak256("getOpenDealCount(address)"));
        // The four of 18 September 2026, "a direct hire is an offer": the road
        // that registers a deal whose executor has only been named, the
        // clone's announcement that he accepted, anybody's repair for a lost
        // announcement, and the read.
        sels[1] = bytes4(keccak256("registerOffer(address,address,address,uint256)"));
        sels[2] = bytes4(keccak256("notifyOfferAccepted()"));
        sels[3] = bytes4(keccak256("syncOfferAcceptance(address)"));
        sels[4] = bytes4(keccak256("isOfferPending(address)"));
    }

    /// The allowance held to its own two conditions.
    function test_TheGrowthBeyondThisCutIsRealAndCoversNothingItMounted() public view {
        bytes4[] memory grown = _grownAfterThisCut();
        bytes4[] memory abiSels = upgrade.artifactSelectors("out/RegistryFacet.sol/RegistryFacet.json");
        bytes4[] memory replaced = upgrade.registryReplaceSelectors();
        bytes4[] memory added = upgrade.registryAddSelectors();
        for (uint256 i = 0; i < grown.length; i++) {
            bool inAbi;
            for (uint256 j = 0; j < abiSels.length; j++) if (abiSels[j] == grown[i]) inAbi = true;
            assertTrue(inAbi, "the allowance is stale: RegistryFacet no longer implements it");
            for (uint256 j = 0; j < replaced.length; j++) {
                assertTrue(replaced[j] != grown[i], "the allowance covers a selector this cut REPLACED");
            }
            for (uint256 j = 0; j < added.length; j++) {
                assertTrue(added[j] != grown[i], "the allowance covers a selector this cut ADDED");
            }
        }
    }

    function test_TheListsCoverExactlyTheCompiledFacet() public view {
        bytes4[] memory grown = _grownAfterThisCut();
        bytes4[] memory replaceWithGrowth = new bytes4[](upgrade.registryReplaceSelectors().length + grown.length);
        bytes4[] memory replaced = upgrade.registryReplaceSelectors();
        for (uint256 i = 0; i < replaced.length; i++) replaceWithGrowth[i] = replaced[i];
        for (uint256 i = 0; i < grown.length; i++) replaceWithGrowth[replaced.length + i] = grown[i];
        upgrade.assertListsCoverTheCompiledFacet(
            replaceWithGrowth,
            upgrade.registryAddSelectors()
        );

        assertEq(upgrade.registryReplaceSelectors().length, REGISTRY_SELECTORS, "the Replace group is no longer thirteen");
        assertEq(upgrade.registryAddSelectors().length, ADDED_SELECTORS, "the cut no longer adds exactly one selector");
        assertEq(
            upgrade.artifactSelectors("out/RegistryFacet.sol/RegistryFacet.json").length,
            REGISTRY_SELECTORS + ADDED_SELECTORS + _grownAfterThisCut().length,
            "the compiled RegistryFacet exposes a different number of functions than this cut mounts plus the named later growth"
        );
    }

    /// THE GROUPING QUESTION, ANSWERED BY THE CHAIN.
    ///
    /// This is the assertion the whole file exists for, and its expected side is
    /// the committed census -- not the script, and not the compiled facet. Every
    /// Replace selector must be mounted on the live diamond today; the Add
    /// selector must be mounted nowhere on it. Get either backwards and the cut
    /// reverts as a whole.
    function test_TheChainSaysEachSelectorIsInTheRightGroup() public view {
        bytes4[] memory onChain = _censusAt(".selectors", ".count");

        bytes4[] memory replaceSels = upgrade.registryReplaceSelectors();
        for (uint256 i = 0; i < replaceSels.length; i++) {
            assertTrue(
                _contains(onChain, replaceSels[i]),
                "a selector filed under Replace is NOT routed on the live chain - Replace would revert and take the cut"
            );
        }

        bytes4[] memory addSels = upgrade.registryAddSelectors();
        for (uint256 i = 0; i < addSels.length; i++) {
            assertFalse(
                _contains(onChain, addSels[i]),
                "a selector filed under Add IS already routed on the live chain - Add would revert and take the cut"
            );
        }
    }

    /// The Replace group against the census's own per-facet list, which is the
    /// stronger form of the same question: not merely "routed somewhere" but
    /// "routed on the facet this cut is replacing", and nothing else is.
    function test_TheReplaceGroupIsExactlyWhatTheRegistryFacetHoldsOnChain() public view {
        bytes4[] memory onFacet = _censusAt(".registrySelectors", ".registryCount");
        bytes4[] memory replaceSels = upgrade.registryReplaceSelectors();

        assertEq(onFacet.length, replaceSels.length, "the chain's RegistryFacet holds a different number of selectors than this cut replaces");
        for (uint256 i = 0; i < replaceSels.length; i++) {
            assertTrue(_contains(onFacet, replaceSels[i]), "this cut replaces a selector the chain's RegistryFacet does not hold");
        }
        for (uint256 i = 0; i < onFacet.length; i++) {
            assertTrue(
                _contains(replaceSels, onFacet[i]),
                "the chain's RegistryFacet holds a selector this cut leaves behind - it would keep pointing at code that no longer implements it"
            );
        }
    }

    /// The census header, before anything is read out of it. The trap worth
    /// catching is not "the census is stale" but "an old census was reused for a
    /// NEW script" -- the numbers would look plausible and describe a different
    /// cut.
    function test_TheCensusDescribesThisScriptAndThisDiamond() public view {
        string memory json = vm.readFile(CENSUS_PATH);
        assertEq(
            keccak256(bytes(vm.parseJsonString(json, ".forScript"))),
            keccak256(bytes(upgrade.scriptPath())),
            "the census was taken for a different script"
        );
        assertEq(vm.parseJsonUint(json, ".count"), CHAIN_ROUTED, "the census does not hold the number of selectors it claims");
        assertEq(vm.parseJsonUint(json, ".facetCount"), CHAIN_FACETS, "the census does not hold the number of facets it claims");
        assertEq(_censusAt(".selectors", ".count").length, CHAIN_ROUTED, "the census's selector list is a different length than its own count");

        // The selector the whole cut delivers, spelled out in the census as a
        // literal a person wrote down, checked against the one solc computes.
        bytes memory named = vm.parseBytes(vm.parseJsonString(json, ".handInSelector"));
        require(named.length == 4, "the census names something that is not a selector");
        assertEq(
            bytes4(named),
            RegistryFacet.notifyWorkHandedIn.selector,
            "the census names a different selector than the facet implements"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE CUT ITSELF, ON A DIAMOND SHAPED LIKE THE LIVE ONE
    // ══════════════════════════════════════════════════════════════════════

    /// The shape of a diamond built the way the live one was built, against the
    /// shape a person read off the live one. Neither number is computed from the
    /// other.
    function test_TheLocalRigHasTheSameShapeAsTheLiveChain() public view {
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, CHAIN_FACETS,
            "the local pre-cut rig has a different number of facets than the live one"
        );
        assertEq(
            _routed(), CHAIN_ROUTED,
            "the local pre-cut rig routes a different number of selectors than the live one"
        );
    }

    /// Pre-flight passes on a diamond in the live shape, the cut lands, and the
    /// routed count moves by EXACTLY the Add group -- not by more (a Replace
    /// group that behaved like an Add) and not by less.
    function test_ThePreFlightPassesAndTheCutLands() public {
        upgrade.assertAllMountedOnOneFacet(upgrade.registryReplaceSelectors(), address(diamond));
        upgrade.assertAddGroupIsUnmountedAnywhere(upgrade.registryAddSelectors(), address(diamond));

        uint256 routedBefore = _routed();
        uint256 facetsBefore = IDiamondLoupe(address(diamond)).facetAddresses().length;

        RegistryFacet fresh = new RegistryFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(fresh)), address(0), "");

        assertEq(_routed(), routedBefore + ADDED_SELECTORS, "the routed count moved by something other than the Add group");
        assertEq(IDiamondLoupe(address(diamond)).facetAddresses().length, facetsBefore, "the facet count moved");
        upgrade.assertRouted(upgrade.registryReplaceSelectors(), address(fresh), address(diamond));
        upgrade.assertRouted(upgrade.registryAddSelectors(), address(fresh), address(diamond));
        assertEq(
            IDiamondLoupe(address(diamond)).facetFunctionSelectors(address(fresh)).length,
            REGISTRY_SELECTORS + ADDED_SELECTORS,
            "the new facet does not hold the replaced selectors plus the new one"
        );
    }

    /// The registry must read the same on both sides of the cut. This work
    /// appends nothing to RegistryStorage.Layout, and that is a claim worth a
    /// read: a facet compiled from a source whose layout had quietly moved would
    /// replace the old one without complaint and read the wrong words out of the
    /// same slots.
    function test_TheRegistryReadsTheSameOnBothSidesOfTheCut() public {
        _seedADeal();
        UpgradeRegistryHandInSignal.StorageSnapshot memory before =
            upgrade.snapshotRegistry(address(diamond));
        assertGt(before.totalAgreements, 0, "the seeded registry is empty - the scene proves nothing");

        RegistryFacet fresh = new RegistryFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(fresh)), address(0), "");

        upgrade.assertRegistryUnmoved(before, upgrade.snapshotRegistry(address(diamond)));
    }

    /// ⚠️ WHAT A MOUNTED SELECTOR CANNOT SAY. `notifyWorkHandedIn()` being routed
    /// proves the Add landed; it does not prove the code behind it is this cut's
    /// code. The probe distinguishes the two: called by an address that is not a
    /// registered deal it must answer `AgreementNotRegistered`, where a diamond
    /// that never got the cut answers "Diamond: function not found".
    function test_TheLivenessProbeTellsAMountedDoorFromAnAbsentOne() public {
        // Before: the selector is not routed, and the probe must refuse to call
        // that a success.
        vm.expectRevert();
        upgrade.assertTheNewDoorIsAliveAndRefusesAStranger(address(diamond));

        RegistryFacet fresh = new RegistryFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(fresh)), address(0), "");

        // After: it answers, and it answers by refusing a caller that is not a deal.
        upgrade.assertTheNewDoorIsAliveAndRefusesAStranger(address(diamond));
    }

    /// A diamond that already carries the cut must be refused, not cut twice:
    /// the second Add would revert on chain, after the facet was paid for.
    function test_ThePreFlightRefusesADiamondThatAlreadyHasTheCut() public {
        RegistryFacet fresh = new RegistryFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(fresh)), address(0), "");

        // Hoisted out of the argument list on purpose: `vm.expectRevert` arms
        // the NEXT call, and an argument that is itself an external call would
        // consume the expectation and pass without the check ever running.
        bytes4[] memory addSels = upgrade.registryAddSelectors();
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert"
            )
        );
        upgrade.assertAddGroupIsUnmountedAnywhere(addSels, address(diamond));
    }

    /// The pre-flight must also refuse the OTHER way round: a Replace selector
    /// that is not mounted. Built by removing one, so the refusal is provoked
    /// rather than assumed.
    function test_ThePreFlightRefusesAReplaceSelectorThatIsNotMounted() public {
        bytes4[] memory one = new bytes4[](1);
        one[0] = RegistryFacet.getDisputed.selector;
        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, one);
        IDiamondCut(address(diamond)).diamondCut(remove, address(0), "");

        bytes4[] memory replaceSels = upgrade.registryReplaceSelectors();
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert"
            )
        );
        upgrade.assertAllMountedOnOneFacet(replaceSels, address(diamond));
    }

    /// The rollback puts the diamond back in the shape it was in, exactly.
    function test_TheRollbackRestoresThePreCutShape() public {
        address previous = IDiamondLoupe(address(diamond)).facetAddress(RegistryFacet.updateStatus.selector);
        uint256 routedBefore = _routed();

        RegistryFacet fresh = new RegistryFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(fresh)), address(0), "");
        assertEq(_routed(), routedBefore + ADDED_SELECTORS, "precondition: the cut did not land");

        IDiamondCut.FacetCut[] memory undo = new IDiamondCut.FacetCut[](2);
        undo[0] = IDiamondCut.FacetCut(previous, IDiamondCut.FacetCutAction.Replace, upgrade.registryReplaceSelectors());
        undo[1] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, upgrade.registryAddSelectors());
        IDiamondCut(address(diamond)).diamondCut(undo, address(0), "");

        assertEq(_routed(), routedBefore, "the rollback did not restore the routed count");
        upgrade.assertRouted(upgrade.registryReplaceSelectors(), previous, address(diamond));
        upgrade.assertAddGroupIsUnmountedAnywhere(upgrade.registryAddSelectors(), address(diamond));
    }

    // ══════════════════════════════════════════════════════════════════════
    // Rig and helpers
    // ══════════════════════════════════════════════════════════════════════

    /// The diamond as Base Sepolia stands TODAY -- before this cut.
    ///
    /// Built the honest way round: a full DeployFull-shaped diamond (which,
    /// since this work, already mounts the new selector) and then the difference
    /// against the CENSUS is removed. Which selectors to remove is therefore
    /// decided by what the chain answered, not by this cut's own Add list -- a
    /// rig built from the script's own list would agree with the script no
    /// matter which group anything was filed under.
    function _deployPreCutDiamond() internal returns (DiamondProxy d) {
        d = _deployFullShapedDiamond();
        // The census this rig is measured against predates the unmount; see the
        // helper's own note for why the script cannot supply this any more.
        _mountHistoricalDealMetadata(d);

        bytes4[] memory onChain = _censusAt(".selectors", ".count");
        _conformToCensus(d, onChain);
    }

    /// Every selector this checkout mounts that the census does not hold,
    /// filled in by _conformToCensus. COMPUTED, never declared: this is the
    /// surplus that used to be a hand-kept total.
    bytes4[] internal rigSurplusOverCensus;

    /// Cut the rig down to the census, and then prove it IS the census.
    ///
    /// ⚠️ THE SIZE OF THE DIFFERENCE IS COMPUTED, NEVER DECLARED. Whatever this
    /// checkout mounts that the census does not hold comes off, however many
    /// that is. The old shape of this helper sized the array from a hand-kept
    /// total and refused when the count disagreed, which meant every cut landing
    /// in the tree reddened it and every red was answered by raising the total.
    ///
    /// The claim that replaces the count is stronger, not weaker: after the
    /// removal the rig's selector set must EQUAL the census's, both directions
    /// checked. A count agrees with a swap; equality does not.
    ///
    /// The other direction deserves its own sentence. A selector the census has
    /// and this checkout can no longer build is the case that arrives when a
    /// facet leaves the tree -- it reds HERE, naming the selector, instead of
    /// silently leaving the rig one door short of the diamond it claims to be.
    function _conformToCensus(DiamondProxy d, bytes4[] memory census) internal {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(d)).facets();

        uint256 routed;
        for (uint256 i = 0; i < all.length; i++) routed += all[i].functionSelectors.length;

        bytes4[] memory scratch = new bytes4[](routed);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = 0; j < all[i].functionSelectors.length; j++) {
                bytes4 sel = all[i].functionSelectors[j];
                if (!_contains(census, sel)) scratch[n++] = sel;
            }
        }

        // Kept for the locks that ask what the surplus IS, now that nothing
        // declares what it should be. Recorded before it is removed, because
        // after the removal it is gone from the diamond.
        delete rigSurplusOverCensus;
        for (uint256 i = 0; i < n; i++) rigSurplusOverCensus.push(scratch[i]);

        if (n > 0) {
            bytes4[] memory extra = new bytes4[](n);
            for (uint256 i = 0; i < n; i++) extra[i] = scratch[i];
            IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
            remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, extra);
            IDiamondCut(address(d)).diamondCut(remove, address(0), "");
        }

        for (uint256 i = 0; i < census.length; i++) {
            require(
                IDiamondLoupe(address(d)).facetAddress(census[i]) != address(0),
                string.concat(
                    "the rig is MISSING a selector the chain routed at this census: ",
                    vm.toString(census[i]),
                    " - this checkout no longer builds it, and a stand rehearsing a past cut has to mount it itself"
                )
            );
        }

        IDiamondLoupe.Facet[] memory conformed = IDiamondLoupe(address(d)).facets();
        uint256 routedAfter;
        for (uint256 i = 0; i < conformed.length; i++) routedAfter += conformed[i].functionSelectors.length;
        require(routedAfter == census.length, "the conformed rig routes a different number of selectors than the census holds");
        // ⚠️ THE ARBITER FACET IS TWO CONTRACTS IN THIS CHECKOUT AND ONE ON THE
        // CHAIN (16 September 2026). The split moved twenty-eight selectors to
        // ArbiterVaultFacet without touching a signature, so the SET above is
        // right either way — but the rig would carry one facet more than the
        // chain, and the signed cut rehearsed here would then meet a Replace
        // group spread over two addresses, which its pre-flight refuses and
        // should go on refusing. So the rig is put back into the chain's shape
        // instead of the check being loosened: one host for all fifty-nine.
        //
        // ⚠️ THIS CALL STAYS, and the line that stood here saying it would come
        // out the day the split landed was wrong. The rig is conformed to THIS
        // STAND'S census, read before the split, when one host routed all
        // fifty-nine arbiter selectors; the split landing on Base Sepolia
        // (17 September 2026, block 46 946 562) does not change that past.
        // Measured 18 September 2026 on EmergencyBrakeUpgrade: without this
        // call setUp reverts "the conformed rig has a different number of
        // facets than the live chain had" and the suite does not run.
        _mountArbiterAsOneHost(address(d));

        IDiamondLoupe.Facet[] memory conformedNow = IDiamondLoupe(address(d)).facets();
        require(
            conformedNow.length == CHAIN_FACETS,
            "the conformed rig has a different number of facets than the live chain had"
        );
    }

    /// ⚠️ A FACET THE DEPLOY SCRIPT NO LONGER CARRIES, MOUNTED HERE ON PURPOSE.
    ///
    /// This rig has to look like the chain did at THIS STAND'S CENSUS, and at
    /// that census DealMetadataFacet was mounted and answering 0xb6a03ff7. On
    /// 14 September 2026 the owner signed the cut that unmounted it, and
    /// script/DeployFull.s.sol stopped mounting it the same day.
    ///
    /// So the rig can no longer get it by borrowing the script's list, and that
    /// is the lesson rather than an inconvenience: a stand that rehearses a PAST
    /// cut must own the past itself. Borrowing the shape of the chain from a
    /// script that tracks the PRESENT is what let this whole class of drift go
    /// unnoticed for ten days.
    function _mountHistoricalDealMetadata(DiamondProxy target) internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = DealMetadataFacet.getDealTokenURI.selector;
        // ⚠️ ASKED OF THE CENSUS, NOT DECIDED HERE. Mount it only if the chain
        // routed it at this census and this checkout no longer builds it. A
        // standing "always mount" would be one more hand-kept fact about which
        // cuts have landed -- the exact species this file just stopped keeping
        // -- and it would revert as a duplicate Add the day DeployFull carries
        // the facet again.
        if (!_contains(_censusAt(".selectors", ".count"), sels[0])) return;
        if (IDiamondLoupe(address(target)).facetAddress(sels[0]) != address(0)) return;
        IDiamondCut.FacetCut[] memory c = new IDiamondCut.FacetCut[](1);
        c[0] = IDiamondCut.FacetCut(
            address(new DealMetadataFacet()), IDiamondCut.FacetCutAction.Add, sels
        );
        IDiamondCut(address(target)).diamondCut(c, address(0), "");
    }

    function _deployFullShapedDiamond() internal returns (DiamondProxy d) {
        IDiamondCut.FacetCut[] memory initCuts = deploy.buildInitCuts(
            address(new DiamondCutFacet()),
            address(new DiamondLoupeFacet()),
            address(new OwnershipFacet()),
            address(new RegistryFacet()),
            address(new FactoryFacet())
        );
        d = new DiamondProxy(address(this), initCuts, address(0), "");

        IDiamondCut(address(d)).diamondCut(
            deploy.buildRemainingCuts(
                address(new JobBoardFacet()),
                address(new ServiceBoardFacet()),
                address(new ArbiterRegistryFacet()),
                address(new ArbiterVaultFacet()),
                address(new ArbiterAccountabilityFacet()),
                address(new ArbiterApplicationsFacet()),
                address(new TreasuryLinkFacet()),
                address(new JobReceiptFacet()),
                address(new ReputationFacet())
            ),
            address(0),
            ""
        );
    }

    /// One deal on the books, so the continuity snapshot has something to be
    /// about. `register` is the factory's door, so this test contract makes
    /// itself the authorized factory first -- which is also the shape a live
    /// diamond is in, where the factory is the diamond itself.
    function _seedADeal() internal {
        RegistryFacet(address(diamond)).initRegistry(address(this));
        RegistryFacet(address(diamond)).register(address(0xDEA1), address(0xC11), address(0xE8E), 1_000_000);
    }

    function _routed() internal view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(diamond)).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    /// A census array, read as text and turned into selectors here. Held to its
    /// own declared count so a truncated file cannot pass as a short chain.
    function _censusAt(string memory listKey, string memory countKey)
        internal view returns (bytes4[] memory out)
    {
        string memory json = vm.readFile(CENSUS_PATH);
        string[] memory raw = vm.parseJsonStringArray(json, listKey);
        require(
            raw.length == vm.parseJsonUint(json, countKey),
            "the census header promises a different number of selectors than it holds"
        );
        out = new bytes4[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            bytes memory b = vm.parseBytes(raw[i]);
            require(b.length == 4, "the census holds a string that is not a selector");
            out[i] = bytes4(b);
        }
    }

    function _contains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) if (haystack[i] == needle) return true;
        return false;
    }
}
