// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeArbiterApplications.s.sol — the diamondCut that
// mounts the thirteenth facet.
//
// ⚠️ WHY A STAND AT ALL, WHEN THE SCRIPT HAS A DRY RUN. A dry run proves the
// script survives TODAY'S chain. It cannot prove the script survives the chain
// it will meet at the moment somebody signs, and it cannot be run in CI at all
// — it needs a network and an RPC key. Everything below runs offline, and the
// two questions that decide whether the cut lands or reverts are answered from
// sources this file does not own:
//
//   * "does the Add list cover the facet" — the expected side is solc's own
//     `methodIdentifiers`, read out of the build artifact, not the list in the
//     script;
//   * "is any of them mounted already" — the expected side is a census read
//     off Base Sepolia and committed as data
//     (test/fixtures/chain-2026-08-24-diamond-selectors.json).
//
// Neither is derived from the thing being checked. That is the fourth way to
// be fooled by a measurement, and it cost a whole cut once:
// a stand that built "what is mounted on chain" out of the script's own
// `replaceSelectors()` agreed with itself no matter which group a selector was
// filed under.
//
// ⚠️ `Add` reverts "Diamond: selector exists" on a selector already mounted,
// and one such revert drops the WHOLE cut in one live transaction — after the
// facet has been paid for. This cut has no Replace group and no Remove group
// at all, which removes the other half of that failure class by construction;
// what remains is exactly the question above, and it is asked here.

import "forge-std/Test.sol";
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
import "../script/DeployFull.s.sol";
import {UpgradeArbiterApplications} from "../script/UpgradeArbiterApplications.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterSplitRig} from "./ArbiterSplitRig.sol";

contract ArbiterApplicationsUpgradeTest is Test, ArbiterSplitRig {
    UpgradeArbiterApplications upgrade;
    DeployFull  deploy;
    DiamondProxy diamond;

    /// The census, and the two things it is held to before it is believed.
    string constant CENSUS_PATH = "test/fixtures/chain-2026-08-24-diamond-selectors.json";
    address constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;

    /// Read off the chain on 24 August 2026 and written down by a person. The
    /// local rig below is built to the SAME shape and its own count is compared
    /// with this, so a local diamond that has drifted from the live one stops
    /// being a stand-in without anybody noticing.
    uint256 constant CHAIN_FACETS_BEFORE   = 12;
    uint256 constant CHAIN_ROUTED_BEFORE   = 203;
    // ⚠️ ELEVEN WHEN THIS CUT SHIPPED, FIFTEEN IN THE TREE (8 and
    // 11 September 2026). The facet gained `postArbiterBond()` and
    // `isArbiterActive(address)`, then `revokeUnprovenSeat(address,string)` and
    // `postArbiterBondWithPermit(uint256,uint8,bytes32,bytes32)`.
    // This stand drives the script over a LOCAL rig, and the script's job is
    // "mount the whole facet" — so the number follows the compiled facet, not
    // what the live chain received. The live diamond gets the first two through
    // script/UpgradeArbiterBondRequired.s.sol and the last two through
    // script/UpgradeUnprovenSeatRevocationAndBondPermit.s.sol, which carries both of the
    // 11 September decisions in one transaction; re-running the applications
    // cut against it is refused by its own assertAllUnmounted before any money
    // moves.
    //
    // SIXTEEN since 17 September 2026: `getBondState(address)`, the read that
    // tells a sagging seat from one that never paid. It reaches the live
    // diamond through the appeal-economics cut, not through this script.
    uint256 constant ADDED_SELECTORS = 16;

    /// The one selector DealMetadataFacet ever answered, written out here
    /// rather than borrowed from DeployFull.
    ///
    /// ⚠️ 14 SEPTEMBER 2026: the owner signed the cut that unmounted this facet
    /// from the live diamond, and DeployFull stopped mounting it in the same
    /// commit. This rig is NOT wrong to keep it — it rehearses a cut against a
    /// diamond shaped the way the chain was AT THAT TIME, and at that time the
    /// facet was mounted. What it may no longer do is ask DeployFull what that
    /// shape was: DeployFull describes the chain of today, this rig describes
    /// the chain of its own moment, and the two have parted company.
    function _dealMetadataFacetSelectors() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = DealMetadataFacet.getDealTokenURI.selector;
    }

    function setUp() public {
        upgrade = new UpgradeArbiterApplications();
        deploy  = new DeployFull();
        diamond = _deployPreCutDiamond();
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE TWO INDEPENDENT ORACLES
    // ══════════════════════════════════════════════════════════════════════

    /// The script's hand-written Add list against solc's output for the facet.
    /// A function the facet gains and nobody mounts would otherwise ship dead:
    /// present in the ABI, routed nowhere, discovered by the first person whose
    /// button did nothing.
    function test_AddListCoversExactlyTheCompiledFacet() public view {
        upgrade.assertAddListCoversTheWholeFacet(upgrade.addSelectors());

        // And said out loud as a number a person fixed, so a facet that
        // silently grows a twelfth function stops here too.
        assertEq(upgrade.addSelectors().length, ADDED_SELECTORS, "the cut no longer adds the whole facet");
        assertEq(upgrade.artifactSelectors().length, ADDED_SELECTORS, "the facet exposes a different number of functions");
    }

    /// Every added selector against the LIVE CHAIN as it was read on 24 August
    /// 2026. This is the whole justification for "all of them go in Add".
    function test_NoAddedSelectorIsMountedOnTheLiveChain() public view {
        bytes4[] memory census = _chainCensus();
        assertEq(census.length, CHAIN_ROUTED_BEFORE, "the census does not hold the number of selectors it claims");

        bytes4[] memory added = upgrade.addSelectors();
        for (uint256 i = 0; i < added.length; i++) {
            for (uint256 j = 0; j < census.length; j++) {
                assertTrue(
                    added[i] != census[j],
                    "a selector this cut ADDS is already mounted on the live chain - Add would revert and drop the whole cut"
                );
            }
        }
    }

    /// The census is only worth anything if it is the right census. The trap
    /// that actually happens is not "it is stale" — that is visible — but "an
    /// old census was reused for a NEW cut", and that passes in silence.
    ///
    /// `forScript` is compared against the value the SCRIPT UNDER TEST reports,
    /// never against a literal here: the next author copies this stand whole,
    /// and his script names itself differently, so the census goes red for him
    /// without anybody remembering to make it.
    function test_CensusIsTheOneTakenForThisScript() public view {
        string memory json = vm.readFile(CENSUS_PATH);
        assertEq(
            vm.parseJsonString(json, ".forScript"),
            upgrade.scriptPath(),
            "this census was taken for a DIFFERENT cut - it does not describe what is being checked"
        );
        assertEq(vm.parseJsonAddress(json, ".diamond"), CENSUS_DIAMOND, "the census was read off a different diamond");
        assertEq(vm.parseJsonUint(json, ".facetCount"), CHAIN_FACETS_BEFORE, "the census disagrees on the facet count");
        assertGt(vm.parseJsonUint(json, ".block"), 0, "the census header has no block number");
        assertGt(bytes(vm.parseJsonString(json, ".takenAt")).length, 0, "the census header has no date");
    }

    /// The local rig against the live chain. Neither of the two numbers below
    /// is computed from the other: the left comes from a diamond this test
    /// builds out of DeployFull's own selector lists, the right from a person
    /// writing down what Base Sepolia answered.
    function test_LocalRigHasTheSameShapeAsTheLiveChain() public view {
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, CHAIN_FACETS_BEFORE,
            "the local pre-cut diamond has a different number of facets than the live one"
        );
        assertEq(
            _routed(), CHAIN_ROUTED_BEFORE,
            "the local pre-cut diamond routes a different number of selectors than the live one"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE CUT ITSELF, APPLIED TO A LOCAL DIAMOND IN THE PRE-CUT SHAPE
    // ══════════════════════════════════════════════════════════════════════

    function test_CutIsOneAddElementAndNothingElse() public view {
        address facetAddr = address(0xFACE7);
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(facetAddr);

        assertEq(cuts.length, 1, "the cut must be a single element - there is nothing to replace or remove");
        assertEq(cuts[0].facetAddress, facetAddr, "the element points at the facet it was handed");
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Add, "the element must be Add");
        assertEq(cuts[0].functionSelectors.length, ADDED_SELECTORS, "the element carries the whole facet");
    }

    function test_PreFlightPassesOnAPreCutDiamondAndTheCutLands() public {
        bytes4[] memory sels = upgrade.addSelectors();

        // Pre-flight, exactly as run() calls it.
        upgrade.assertAddListCoversTheWholeFacet(sels);
        upgrade.assertAllUnmounted(sels, address(diamond));

        uint256 routedBefore = _routed();
        uint256 facetsBefore = IDiamondLoupe(address(diamond)).facetAddresses().length;
        UpgradeArbiterApplications.StorageSnapshot memory before =
            upgrade.snapshotArbiterStorage(address(diamond));

        ArbiterApplicationsFacet facet = new ArbiterApplicationsFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(facet)), address(0), "");

        // Post-flight, exactly as run() calls it.
        upgrade.assertRouted(sels, address(facet), address(diamond));
        upgrade.assertApplicationWindowAnswers(address(diamond));
        upgrade.assertStorageContinuity(before, upgrade.snapshotArbiterStorage(address(diamond)));

        assertEq(_routed(), routedBefore + ADDED_SELECTORS, "the routed count did not move by exactly +Add");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, facetsBefore + 1,
            "the facet count did not grow by exactly one"
        );
        assertEq(
            IDiamondLoupe(address(diamond)).facetFunctionSelectors(address(facet)).length, ADDED_SELECTORS,
            "the new facet holds a different number of selectors than were added"
        );

        // And the shape the live chain will be in afterwards, in the same two
        // numbers the deployment record will carry.
        assertEq(IDiamondLoupe(address(diamond)).facetAddresses().length, 13, "13 facets after the cut");
        assertEq(
            // ⚠️ The cut now carries fifteen, not eleven: the facet gained
            // `postArbiterBond()` and `isArbiterActive(address)` on 8 September
            // 2026, then `revokeUnprovenSeat(address,string)` and
            // `postArbiterBondWithPermit(uint256,uint8,bytes32,bytes32)` on the
            // 11th. ADDED_SELECTORS is the one number that moved on the cut's
            // side; the three trailing literals are the same growth seen from
            // the census side, and they stay THREE — the bond pair, the seat
            // door and the permit door are three decisions, and a single 4
            // could no longer say which of them drifted.
            _routed(), CHAIN_ROUTED_BEFORE + ADDED_SELECTORS,
            "the cut did not move the routed count by exactly its own Add group"
        );
    }

    /// The pre-flight has to REFUSE when the chain is not in the shape the cut
    /// assumes. Applying the cut twice is the realistic way to get there: a run
    /// that landed, a session that dropped before the operator saw it, a second
    /// press.
    function test_PreFlightRefusesASecondApplication() public {
        bytes4[] memory sels = upgrade.addSelectors();
        ArbiterApplicationsFacet facet = new ArbiterApplicationsFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(facet)), address(0), "");

        vm.expectRevert(
            bytes("pre-flight: a selector from Add is already mounted - Add would revert and drop the whole cut")
        );
        upgrade.assertAllUnmounted(sels, address(diamond));
    }

    /// And the diamond itself refuses too, with its own message — proof that
    /// the pre-flight guards a real failure rather than an imagined one.
    function test_ASecondCutIsRejectedByTheDiamond() public {
        ArbiterApplicationsFacet facet = new ArbiterApplicationsFacet();
        // ⚠️ The cut is built BEFORE the expectation is armed. `vm.expectRevert`
        // arms the NEXT call, and `upgrade.buildCuts(...)` is itself an
        // external call to the script contract: written inline as an argument
        // it would swallow the expectation and the test would report "did not
        // revert" about the wrong call entirely (measured, 24 August 2026).
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(facet));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        vm.expectRevert(bytes("Diamond: selector exists"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    /// The rollback path, proved rather than described: every added selector goes
    /// dark and the rest of the diamond is untouched.
    function test_RollbackRemovesExactlyTheElevenSelectors() public {
        bytes4[] memory sels = upgrade.addSelectors();
        ArbiterApplicationsFacet facet = new ArbiterApplicationsFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(facet)), address(0), "");
        uint256 routedAfterCut = _routed();

        IDiamondCut.FacetCut[] memory undo = new IDiamondCut.FacetCut[](1);
        undo[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, sels);
        IDiamondCut(address(diamond)).diamondCut(undo, address(0), "");

        for (uint256 i = 0; i < sels.length; i++) {
            assertEq(
                IDiamondLoupe(address(diamond)).facetAddress(sels[i]), address(0),
                "a selector is still routed after the rollback"
            );
        }
        assertEq(_routed(), routedAfterCut - ADDED_SELECTORS, "the rollback removed a different number of selectors");
        assertEq(
            _routed(), CHAIN_ROUTED_BEFORE,
            "the rollback did not restore the pre-cut shape"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════

    function _routed() internal view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(diamond)).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    /// The diamond as Base Sepolia stands TODAY: twelve facets, the
    /// applications facet not among them. Built out of DeployFull's own
    /// selector lists rather than a second hand-written set — a private list
    /// would drift from the live layout in silence, and then every scene here
    /// would be about a diamond that does not exist.
    ///
    /// `buildRemainingCuts` cannot be used: since this work it MOUNTS the
    /// applications facet, which is precisely what the pre-cut shape does not
    /// have. The per-facet selector getters it is built from are the same ones.
    function _deployPreCutDiamond() internal returns (DiamondProxy d) {
        IDiamondCut.FacetCut[] memory initCuts = deploy.buildInitCuts(
            address(new DiamondCutFacet()),
            address(new DiamondLoupeFacet()),
            address(new OwnershipFacet()),
            address(new RegistryFacet()),
            address(new FactoryFacet())
        );
        d = new DiamondProxy(address(this), initCuts, address(0), "");

        IDiamondCut.FacetCut[] memory rest = new IDiamondCut.FacetCut[](8);
        rest[0] = IDiamondCut.FacetCut(
            address(new JobBoardFacet()), IDiamondCut.FacetCutAction.Add, deploy.jobBoardFacetSelectors()
        );
        rest[1] = IDiamondCut.FacetCut(
            address(new ServiceBoardFacet()), IDiamondCut.FacetCutAction.Add, deploy.serviceBoardFacetSelectors()
        );
        rest[2] = IDiamondCut.FacetCut(
            address(new ArbiterRegistryFacet()), IDiamondCut.FacetCutAction.Add, deploy.arbiterRegistryFacetSelectors()
        );
        rest[3] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()),
            IDiamondCut.FacetCutAction.Add,
            deploy.arbiterAccountabilityFacetSelectors()
        );
        rest[4] = IDiamondCut.FacetCut(
            address(new DealMetadataFacet()), IDiamondCut.FacetCutAction.Add, _dealMetadataFacetSelectors()
        );
        rest[5] = IDiamondCut.FacetCut(
            address(new JobReceiptFacet()), IDiamondCut.FacetCutAction.Add, deploy.jobReceiptFacetSelectors()
        );
        rest[6] = IDiamondCut.FacetCut(
            address(new ReputationFacet()), IDiamondCut.FacetCutAction.Add, deploy.reputationFacetSelectors()
        );
        // The money and the plain reads (16 September 2026 split). They were in
        // the registry's list until that day and are in the census as ordinary
        // arbiter selectors; without this entry the rig would simply be missing
        // twenty-eight selectors the chain routes, which is what it said.
        rest[7] = IDiamondCut.FacetCut(
            address(new ArbiterVaultFacet()), IDiamondCut.FacetCutAction.Add, deploy.arbiterVaultFacetSelectors()
        );
        IDiamondCut(address(d)).diamondCut(rest, address(0), "");

        // ⚠️ AND THEN CONFORMED TO THE CENSUS, BY SET DIFFERENCE AND WITHOUT A
        // NUMBER.
        //
        // The facets above are today's, and today's facets have grown since
        // 24 August. Until 14 September that growth was carried as two
        // allowance constants -- PENDING_LOCAL_ADDS, which had been raised from
        // 2 to 4 to 7 to 8 to 12 by five separate cuts, and PENDING_FEE_CAP_ADDS
        // -- and every assertion about this rig's size was written as "the
        // census, plus those". That is the arithmetic that let ten selectors of
        // drift pass unnoticed elsewhere in this repository: a sum that is
        // raised whenever it disagrees can no longer disagree.
        //
        // The census is the complete list of what the chain routed at block
        // 45897877. Whatever this checkout mounts that the census does not hold
        // comes off, however much that is; then the two sets are proved equal.
        // A cut landing in the tree changes the size of the difference and
        // nothing else.
        bytes4[] memory census = _chainCensus();
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(d)).facets();
        uint256 routed;
        for (uint256 i = 0; i < all.length; i++) routed += all[i].functionSelectors.length;

        bytes4[] memory scratch = new bytes4[](routed);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = 0; j < all[i].functionSelectors.length; j++) {
                bytes4 sel = all[i].functionSelectors[j];
                if (!_censusHolds(census, sel)) scratch[n++] = sel;
            }
        }
        if (n > 0) {
            bytes4[] memory extra = new bytes4[](n);
            for (uint256 i = 0; i < n; i++) extra[i] = scratch[i];
            IDiamondCut.FacetCut[] memory strip = new IDiamondCut.FacetCut[](1);
            strip[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, extra);
            IDiamondCut(address(d)).diamondCut(strip, address(0), "");
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

        // ⚠️ AND FINALLY BACK INTO THE CHAIN'S SHAPE (16 September 2026). The
        // split put twenty-eight of the arbiter selectors on a second contract
        // without touching a signature, so the SET proved equal just above is
        // right either way — but the chain still answers all fifty-nine from one
        // address, and the cut rehearsed here refuses a Replace group spread
        // over two. The rig is put back into that shape rather than the refusal
        // being loosened.
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
    }

    function _censusHolds(bytes4[] memory census, bytes4 sel) internal pure returns (bool) {
        for (uint256 i = 0; i < census.length; i++) if (census[i] == sel) return true;
        return false;
    }

    function _chainCensus() internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(CENSUS_PATH);
        string[] memory raw = vm.parseJsonStringArray(json, ".selectors");
        require(
            raw.length == vm.parseJsonUint(json, ".count"),
            "the census header promises a different number of selectors than it holds"
        );
        out = new bytes4[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            bytes memory b = vm.parseBytes(raw[i]);
            require(b.length == 4, "the census holds a string that is not a selector");
            out[i] = bytes4(b);
        }
    }
}
