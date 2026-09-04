// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeEmergencyBrake.s.sol — the diamondCut that
// replaces FactoryFacet, JobBoardFacet and ServiceBoardFacet and adds five
// selectors: the four of the emergency brake (decision 17) and `MAX_FEE_BPS()`
// (item 138), the fee ceiling that used to be a bare literal written twice.
//
// The two deliveries are held apart everywhere in this file rather than being
// counted together. Four plus one is five either way; a single number cannot
// say WHICH five, and the discipline this cut inherited from 77a8f069 is that
// each delivery names its own constant so an allowance can never absorb a drift
// it was not written for.
//
// ⚠️ WHY A STAND AT ALL, WHEN THE SCRIPT HAS A DRY RUN. A dry run proves the
// script survives TODAY'S chain. It cannot prove the script survives the chain
// it will meet at the moment somebody signs, and it cannot be run in CI at all
// — it needs a network. Everything below runs offline, and the questions that
// decide whether the cut lands or reverts are answered from sources this file
// does not own:
//
//   * "do the lists cover the facets" — the expected side is solc's own
//     `methodIdentifiers`, read out of the build artifacts, not the lists in
//     the script;
//   * "is every Replace selector mounted, and are the five Add selectors
//     mounted nowhere" — the expected side is a census read off Base Sepolia at
//     block 46306403 and committed as data
//     (test/fixtures/chain-2026-09-03-emergency-brake-selectors.json).
//
// Neither is derived from the thing being checked. That is the fourth way to be
// fooled by a measurement, and on 16 August it cost a whole cut: the sabotage
// turned two neighbours red and left the APPOINTED lock green, because that
// lock built "what is mounted on chain" out of the script's own
// `replaceSelectors()` and therefore agreed with itself no matter which group a
// selector was filed under.
//
// ⚠️ WHAT THIS RIG CANNOT PROVE, SAID OUT LOUD SO NOBODY READS A GREEN HERE AS
// MORE THAN IT IS. The local diamond is built from TODAY'S source, so both
// boards already read the brake's clock before the cut is applied. That means
// the BEHAVIOURAL tests below ("press it and the doors shut") do NOT lock the
// two board Replace groups: drop either one from `buildCuts` and the rig's
// boards still behave, because they were never the old code. What locks those
// two groups is structural and lives in
// `test_EveryReplacedSelectorLandsOnItsNewFacetAndTheOldFacetsAreEmpty` and
// `test_CutIsThreeReplacesAndOneAdd`. The behavioural half locks something
// else, and something real: the brake cannot be PRESSED until the Add group
// lands, because `pauseNewDeals()` is routed nowhere before it.

import "./BoardsFixture.sol";
import "../src/RegistryFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {UpgradeEmergencyBrake} from "../script/UpgradeEmergencyBrake.s.sol";

contract EmergencyBrakeUpgradeTest is BoardsFixture {
    UpgradeEmergencyBrake upgrade;

    /// The census, and the things it is held to before it is believed.
    string constant CENSUS_PATH = "test/fixtures/chain-2026-09-03-emergency-brake-selectors.json";
    address constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;

    /// Read off the chain on 3 September 2026 at block 46306403 and written
    /// down by a person, so that a facet which silently grows or loses a
    /// function stops here instead of at the signature.
    uint256 constant CHAIN_FACETS       = 13;
    uint256 constant CHAIN_ROUTED       = 222;
    uint256 constant FACTORY_SELECTORS  = 23;
    uint256 constant JOBBOARD_SELECTORS = 13;
    uint256 constant SERVICE_SELECTORS  = 25;
    /// The Add group, split by delivery. `ADDED_BRAKE` is decision 17;
    /// `ADDED_FEE_CAP` is item 138's `MAX_FEE_BPS()`. Kept as two names for the
    /// reason 77a8f069 gave: a single widened allowance stops being able to say
    /// which growth it was written for, and a drift then hides inside it.
    uint256 constant ADDED_BRAKE        = 4;
    uint256 constant ADDED_FEE_CAP      = 1;
    uint256 constant ADDED_SELECTORS    = ADDED_BRAKE + ADDED_FEE_CAP;

    /// Everything a fresh deploy carries that the live chain does not. Today
    /// that is exactly this cut's own five and nothing else — measured, not
    /// assumed: `_deployPreCutDiamond` counts the difference and refuses if it
    /// is not this number. A cut queued after this one adds its own named
    /// constant here rather than widening this one, so that an allowance can
    /// never absorb a drift it was not written for.
    uint256 constant EXTRA_BEYOND_CHAIN = ADDED_SELECTORS;

    /// The brake's own number, as a literal in a third place: the facet has it,
    /// the script has it, and this stand has it. Two of the three could drift
    /// together; three is harder.
    uint256 constant PAUSE_DURATION = 72 hours;

    /// A realistic wall clock. The brake compares against `block.timestamp`,
    /// and forge starts at 1 — a duration of 72 hours would then be a number
    /// larger than any timestamp the test ever reaches, which would make the
    /// "it lets go by itself" test pass for the wrong reason.
    uint256 constant T0 = 1_756_900_000;

    /// ⚠️ THE FIXTURE'S OWN DIAMOND IS NOT THE RIGHT STAND FOR THIS CUT.
    /// `BoardsFixture` mounts a FactoryFacet selector set of its own — it skips
    /// `initFeeModel`, which the live chain DOES route. That is fine for board
    /// behaviour and useless for rehearsing a cut, which is a claim about the
    /// set the CHAIN routes. So the actors, the mock token and the balances
    /// stay, and the diamond is rebuilt in the live shape below.
    function setUp() public override {
        super.setUp();
        vm.warp(T0);
        upgrade = new UpgradeEmergencyBrake();
        diamond = _deployPreCutDiamond();
        _initDiamond();
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE INDEPENDENT ORACLES
    // ══════════════════════════════════════════════════════════════════════

    /// The script's hand-written lists against solc's output for each facet. A
    /// function a facet gains and nobody mounts would otherwise ship dead:
    /// present in the ABI, routed nowhere, discovered by the first person whose
    /// button did nothing.
    function test_ListsCoverExactlyTheCompiledFacets() public view {
        upgrade.assertListsCoverTheCompiledFacets(
            upgrade.factoryReplaceSelectors(),
            upgrade.factoryAddSelectors(),
            upgrade.jobBoardReplaceSelectors(),
            upgrade.serviceBoardReplaceSelectors()
        );

        assertEq(upgrade.factoryReplaceSelectors().length, FACTORY_SELECTORS);
        assertEq(upgrade.factoryAddSelectors().length, ADDED_SELECTORS);
        assertEq(upgrade.jobBoardReplaceSelectors().length, JOBBOARD_SELECTORS);
        assertEq(upgrade.serviceBoardReplaceSelectors().length, SERVICE_SELECTORS);
    }

    /// THE PROOF OF THE Replace/Add SPLIT, half one: everything in a Replace
    /// group is mounted on the live chain today, and everything mounted on
    /// those three facets is in a Replace group. Set equality in both
    /// directions, per facet.
    ///
    ///   * nothing in a Replace group is unmounted -> no element belongs in Add;
    ///   * nothing mounted is missing -> no selector is left pointing at a facet
    ///     that no longer implements it.
    function test_EveryReplacedSelectorIsMountedOnTheLiveChainAndNothingElseIs() public view {
        _assertSameSet(upgrade.factoryReplaceSelectors(), _censusAt(".factorySelectors", ".factoryCount"), "Factory");
        _assertSameSet(upgrade.jobBoardReplaceSelectors(), _censusAt(".jobBoardSelectors", ".jobBoardCount"), "JobBoard");
        _assertSameSet(upgrade.serviceBoardReplaceSelectors(), _censusAt(".serviceBoardSelectors", ".serviceBoardCount"), "ServiceBoard");
    }

    /// THE PROOF OF THE SPLIT, half two. All five Add selectors must be mounted
    /// NOWHERE in the diamond, which is a question about the whole routed list,
    /// not about FactoryFacet: `Add` reverts on a selector routed anywhere at
    /// all, including on some other facet by collision.
    function test_AllFiveAddedSelectorsAreMountedNowhereOnTheLiveChain() public view {
        bytes4[] memory whole = _censusAt(".selectors", ".count");
        assertEq(whole.length, CHAIN_ROUTED, "the census does not hold the number of selectors it claims");

        bytes4[] memory added = upgrade.factoryAddSelectors();
        assertEq(added.length, ADDED_SELECTORS, "the Add group is not the size this stand was written for");
        for (uint256 i = 0; i < added.length; i++) {
            for (uint256 j = 0; j < whole.length; j++) {
                assertTrue(
                    added[i] != whole[j],
                    "a selector this cut ADDS is already routed on the live chain - it belongs in Replace, and Add would revert"
                );
            }
        }
    }

    /// And the same claim asked of the ARTIFACT rather than of the script: the
    /// compiled FactoryFacet must expose exactly five functions the chain does
    /// not have. A sixth one added later without touching the script would be
    /// caught here rather than by whoever presses the button — it would ship
    /// dead, present in the ABI and routed nowhere. That is not hypothetical:
    /// this is one of the three tests that went red the moment `MAX_FEE_BPS`
    /// appeared in FactoryFacet and nothing else had been touched.
    ///
    /// Both sides come from outside the script: solc's artifact on one, the
    /// chain census on the other. The script's own list is not consulted, which
    /// is why this test survives a script that files a selector in the wrong
    /// group.
    function test_TheCompiledFactoryGainsExactlyTheFiveSelectorsThisCutAdds() public view {
        bytes4[] memory fromArtifact = upgrade.artifactSelectors("out/FactoryFacet.sol/FactoryFacet.json");
        bytes4[] memory mounted = _censusAt(".factorySelectors", ".factoryCount");

        uint256 unmounted;
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            bool found;
            for (uint256 j = 0; j < mounted.length; j++) {
                if (fromArtifact[i] == mounted[j]) { found = true; break; }
            }
            if (!found) unmounted++;
        }
        assertEq(
            unmounted, ADDED_SELECTORS,
            "the compiled FactoryFacet gains a different number of functions than this cut adds"
        );
    }

    /// The five, named one by one rather than counted, and grouped by the
    /// delivery each belongs to. A count agrees on a swap: drop
    /// `resumeNewDeals` and add something else and the arithmetic above is
    /// still five. The signature TEXT is the expected side here, so a renamed
    /// function shows up in this file instead of in a live transaction.
    ///
    /// ⚠️ THIS IS THE APPOINTED LOCK FOR ITEM 138's HALF OF THE CUT. Remove
    /// `MAX_FEE_BPS()` from `factoryAddSelectors()` and this test names it.
    function test_TheFiveAddedSelectorsAreNamedOneByOne() public view {
        bytes4[] memory added = upgrade.factoryAddSelectors();
        assertEq(added.length, ADDED_SELECTORS);

        // Delivery one: the emergency brake, decision 17.
        _assertContains(added, bytes4(keccak256("pauseNewDeals()")), "pauseNewDeals()");
        _assertContains(added, bytes4(keccak256("resumeNewDeals()")), "resumeNewDeals()");
        _assertContains(added, bytes4(keccak256("newDealsPausedUntil()")), "newDealsPausedUntil()");
        _assertContains(added, bytes4(keccak256("NEW_DEALS_PAUSE_DURATION()")), "NEW_DEALS_PAUSE_DURATION()");

        // Delivery two: the fee ceiling, item 138.
        _assertContains(added, bytes4(keccak256("MAX_FEE_BPS()")), "MAX_FEE_BPS()");

        // And the census agrees the chain routes none of them, read from the
        // two header fields rather than recomputed from the lists. Two fields,
        // because the census records the two deliveries separately.
        string memory json = vm.readFile(CENSUS_PATH);
        assertEq(
            vm.parseJsonAddress(json, ".brakeSelectorsRoutedTo"),
            address(0),
            "the census says the brake selectors are already routed somewhere"
        );
        assertEq(
            vm.parseJsonAddress(json, ".feeCapSelectorsRoutedTo"),
            address(0),
            "the census says MAX_FEE_BPS() is already routed somewhere"
        );

        // The census's two lists are the Add group and nothing else. Read from
        // the census — a source this cut does not own — rather than from the
        // script, so a selector quietly dropped from either side is named here.
        _assertSameSet(
            _concat(_censusList(".brakeSelectors"), _censusList(".feeCapSelectors")),
            added,
            "the census's two Add lists vs this cut's Add group"
        );
    }

    /// ⚠️ THE APPOINTED LOCK FOR "MAX_FEE_BPS IS AN Add, NOT A Replace". The
    /// census is the whole routed list of the live chain, read off Base Sepolia
    /// and committed as data. If `MAX_FEE_BPS()` ever appears in it, the
    /// selector is mounted and `Add` would revert on it — the cut would drop in
    /// one transaction after three facets had been paid for. Asked of the
    /// census and of the script's own Replace list, both, and in the direction
    /// that matters for each: absent from what the chain routes, present in the
    /// Add group, absent from the Replace group.
    function test_TheFeeCapSelectorIsUnmountedOnChainAndTravelsOnlyInTheAddGroup() public view {
        bytes4 feeCap = bytes4(keccak256("MAX_FEE_BPS()"));
        assertEq(feeCap, bytes4(0xd55be8c6), "MAX_FEE_BPS() is not the selector this cut was measured for");

        bytes4[] memory whole = _censusAt(".selectors", ".count");
        for (uint256 i = 0; i < whole.length; i++) {
            assertTrue(
                whole[i] != feeCap,
                "MAX_FEE_BPS() is already routed on the live chain - it belongs in Replace, and Add would revert"
            );
        }

        bytes4[] memory replaced = upgrade.factoryReplaceSelectors();
        for (uint256 i = 0; i < replaced.length; i++) {
            assertTrue(
                replaced[i] != feeCap,
                "MAX_FEE_BPS() was filed in the Replace group - Replace reverts on an unmounted selector"
            );
        }

        _assertContains(upgrade.factoryAddSelectors(), feeCap, "MAX_FEE_BPS()");
    }

    /// The fee ceiling behind the new getter must be the number the two writers
    /// enforce, and it is asked of the FACET rather than reasoned about. The
    /// expected side is a literal written here by a person: 2000 basis points,
    /// 20%. A getter that agreed with the facet's own constant no matter what
    /// the constant was would prove nothing.
    function test_TheFacetStatesTheSameTwentyPercentCeilingItEnforces() public {
        // The rig is the PRE-cut diamond, and `MAX_FEE_BPS()` is exactly what
        // this cut mounts — so it is routed nowhere until the cut lands. Asking
        // before would be asking the old shape.
        vm.expectRevert(bytes("Diamond: function not found"));
        FactoryFacet(address(diamond)).MAX_FEE_BPS();

        _applyTheCut();

        assertEq(FactoryFacet(address(diamond)).MAX_FEE_BPS(), 2_000, "the fee ceiling is not 20%");

        // And the writer honours it at the boundary, in both directions. This
        // is the half a getter alone cannot prove: a constant nothing compares
        // against is decoration.
        FactoryFacet(address(diamond)).setFeeBps(2_000);
        assertEq(FactoryFacet(address(diamond)).getFeeBps(), 2_000, "the ceiling itself was refused");

        vm.expectRevert(FactoryFacet.FeeBpsTooHigh.selector);
        FactoryFacet(address(diamond)).setFeeBps(2_001);
    }

    /// The census header, before anything is read out of it. The trap worth
    /// catching is not "the census is stale" but "an old census was reused for
    /// a NEW script" — the numbers would look plausible and describe a
    /// different cut.
    function test_TheCensusDescribesThisScriptAndThisDiamond() public view {
        string memory json = vm.readFile(CENSUS_PATH);
        assertEq(
            keccak256(bytes(vm.parseJsonString(json, ".forScript"))),
            keccak256(bytes(upgrade.scriptPath())),
            "this census was taken for a DIFFERENT cut - it does not describe what is being checked"
        );
        assertEq(vm.parseJsonAddress(json, ".diamond"), CENSUS_DIAMOND, "the census was read off a different diamond");
        assertEq(vm.parseJsonUint(json, ".facetCount"), CHAIN_FACETS, "the census disagrees on the facet count");
        assertGt(vm.parseJsonUint(json, ".block"), 0, "the census header has no block number");
        assertGt(bytes(vm.parseJsonString(json, ".takenAt")).length, 0, "the census header has no date");

        // The readings the storage-continuity claim leans on, recorded by the
        // same pass that produced the selector lists. A census with a zero fee
        // rate would let continuity prove nothing.
        assertGt(vm.parseJsonUint(json, ".feeBps"), 0, "the census records a zero fee rate");
        assertGt(vm.parseJsonUint(json, ".feeFloor"), 0, "the census records a zero fee floor");
        assertTrue(vm.parseJsonAddress(json, ".agreementDeployer") != address(0), "the census records no deployer");
    }

    /// A third source for the same lists: the from-scratch deploy. If the cut
    /// and the fresh deploy ever disagree about what a facet exposes, one of the
    /// two diamonds is wrong and nothing else would say which.
    function test_TheCutAndTheFreshDeployMountTheSameSets() public {
        DeployFull deploy = new DeployFull();
        _assertSameSet(
            _concat(upgrade.factoryReplaceSelectors(), upgrade.factoryAddSelectors()),
            deploy.factoryFacetSelectors(),
            "Factory vs DeployFull"
        );
        _assertSameSet(upgrade.jobBoardReplaceSelectors(), deploy.jobBoardFacetSelectors(), "JobBoard vs DeployFull");
        _assertSameSet(upgrade.serviceBoardReplaceSelectors(), deploy.serviceBoardFacetSelectors(), "ServiceBoard vs DeployFull");
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE SHAPE OF THE CUT — decision 55 lives here
    // ══════════════════════════════════════════════════════════════════════

    function test_CutIsThreeReplacesAndOneAdd() public view {
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(0xF00D1), address(0xF00D2), address(0xF00D3));
        assertEq(cuts.length, 4, "the cut must be four elements");

        uint256 replaces;
        uint256 adds;
        for (uint256 i = 0; i < cuts.length; i++) {
            if (cuts[i].action == IDiamondCut.FacetCutAction.Replace) replaces++;
            else if (cuts[i].action == IDiamondCut.FacetCutAction.Add) adds++;
            else revert("the cut carries an action that is neither Replace nor Add");
        }
        assertEq(replaces, 3, "three facets are being replaced");
        assertEq(adds, 1, "the additions travel in exactly one element of their own");

        // Each group on the address it belongs to. The Factory's two elements
        // share one address; the boards have their own.
        assertEq(cuts[0].facetAddress, address(0xF00D1));
        assertEq(cuts[1].facetAddress, address(0xF00D1));
        assertEq(cuts[2].facetAddress, address(0xF00D2));
        assertEq(cuts[3].facetAddress, address(0xF00D3));
        assertEq(cuts[0].functionSelectors.length, FACTORY_SELECTORS);
        assertEq(cuts[1].functionSelectors.length, ADDED_SELECTORS);
        assertEq(cuts[2].functionSelectors.length, JOBBOARD_SELECTORS);
        assertEq(cuts[3].functionSelectors.length, SERVICE_SELECTORS);
    }

    /// ⚠️ DECISION 55, AS A LOCK RATHER THAN AS A PARAGRAPH. The five new
    /// selectors must travel in an element whose action is `Add`, and must
    /// appear in NO `Replace` element. Folding them into the factory's Replace
    /// is the shortcut that was proposed on 31 August and refused: `Replace`
    /// reverts on a selector that is not mounted, so the cut would drop in one
    /// live transaction after three facets had been paid for.
    ///
    /// Asked of `buildCuts` — the thing that actually goes on chain — rather
    /// than of `factoryAddSelectors()`, because a cut can name a correct Add
    /// list and then not use it.
    function test_TheFiveNewSelectorsTravelInTheirOwnAddElementAndInNoReplace() public view {
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(0xF00D1), address(0xF00D2), address(0xF00D3));
        bytes4[] memory added = upgrade.factoryAddSelectors();

        for (uint256 s = 0; s < added.length; s++) {
            uint256 timesInAdd;
            for (uint256 i = 0; i < cuts.length; i++) {
                for (uint256 j = 0; j < cuts[i].functionSelectors.length; j++) {
                    if (cuts[i].functionSelectors[j] != added[s]) continue;
                    assertTrue(
                        cuts[i].action == IDiamondCut.FacetCutAction.Add,
                        "a new selector was folded into a Replace group - decision 55, and Replace would revert on it"
                    );
                    timesInAdd++;
                }
            }
            assertEq(timesInAdd, 1, "a new selector is not carried exactly once by an Add element");
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE CUT ITSELF, APPLIED TO A DIAMOND SHAPED LIKE THE LIVE ONE
    // ══════════════════════════════════════════════════════════════════════

    /// The whole pre-flight against a rig that routes what the chain routes,
    /// then the cut, then the post-flight — the same calls `run()` makes, in
    /// the same order, without a network.
    function test_PreFlightPassesAndTheCutLands() public {
        bytes4[] memory facSels = upgrade.factoryReplaceSelectors();
        bytes4[] memory addSels = upgrade.factoryAddSelectors();
        bytes4[] memory jobSels = upgrade.jobBoardReplaceSelectors();
        bytes4[] memory svcSels = upgrade.serviceBoardReplaceSelectors();

        upgrade.assertListsCoverTheCompiledFacets(facSels, addSels, jobSels, svcSels);
        address previousFactory      = upgrade.assertAllMountedOnOneFacet(facSels, address(diamond));
        address previousJobBoard     = upgrade.assertAllMountedOnOneFacet(jobSels, address(diamond));
        address previousServiceBoard = upgrade.assertAllMountedOnOneFacet(svcSels, address(diamond));
        assertTrue(previousFactory != previousJobBoard && previousFactory != previousServiceBoard);
        upgrade.assertNothingIsLeftBehind(facSels, previousFactory, address(diamond));
        upgrade.assertNothingIsLeftBehind(jobSels, previousJobBoard, address(diamond));
        upgrade.assertNothingIsLeftBehind(svcSels, previousServiceBoard, address(diamond));
        upgrade.assertAddGroupIsUnmountedAnywhere(addSels, address(diamond));
        upgrade.assertTheBrakeIsNotThereYet(address(diamond));

        UpgradeEmergencyBrake.StorageSnapshot memory beforeCut =
            upgrade.snapshotFactoryAndBoards(address(diamond));
        uint256 routedBefore = upgrade.totalRoutedSelectors(address(diamond));
        assertEq(routedBefore, CHAIN_ROUTED, "the rig does not route what the chain routes");

        (address newFactory, address newJobBoard, address newServiceBoard) = _applyTheCut();

        upgrade.assertRouted(facSels, newFactory, address(diamond));
        upgrade.assertRouted(addSels, newFactory, address(diamond));
        upgrade.assertRouted(jobSels, newJobBoard, address(diamond));
        upgrade.assertRouted(svcSels, newServiceBoard, address(diamond));
        upgrade.assertTheBrakeIsUpAndRefusesAStranger(address(diamond));
        upgrade.assertStorageUnmoved(beforeCut, upgrade.snapshotFactoryAndBoards(address(diamond)));

        assertEq(
            upgrade.totalRoutedSelectors(address(diamond)),
            CHAIN_ROUTED + ADDED_SELECTORS,
            "the routed count moved by something other than the Add group"
        );
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length,
            CHAIN_FACETS,
            "the facet count moved - the old facets should have been emptied, not unmounted"
        );
    }

    /// ⚠️ THE LOCK ON THE TWO BOARD Replace GROUPS, and the only one there is.
    /// The behavioural tests further down cannot do this job: this rig's boards
    /// are built from today's source and already read the brake's clock, so
    /// dropping either board from the cut changes nothing they can see. What
    /// changes is the ROUTING — the selectors would keep pointing at the facet
    /// deployed by the rig instead of the one this cut deploys — and that is
    /// what is asked here.
    function test_EveryReplacedSelectorLandsOnItsNewFacetAndTheOldFacetsAreEmpty() public {
        address oldFactory      = IDiamondLoupe(address(diamond)).facetAddress(upgrade.factoryReplaceSelectors()[0]);
        address oldJobBoard     = IDiamondLoupe(address(diamond)).facetAddress(upgrade.jobBoardReplaceSelectors()[0]);
        address oldServiceBoard = IDiamondLoupe(address(diamond)).facetAddress(upgrade.serviceBoardReplaceSelectors()[0]);

        (address newFactory, address newJobBoard, address newServiceBoard) = _applyTheCut();

        assertTrue(newFactory != oldFactory, "the factory did not move");
        assertTrue(newJobBoard != oldJobBoard, "the job board did not move");
        assertTrue(newServiceBoard != oldServiceBoard, "the service board did not move");

        _assertAllRoutedTo(upgrade.factoryReplaceSelectors(), newFactory, "FactoryFacet");
        _assertAllRoutedTo(upgrade.factoryAddSelectors(), newFactory, "FactoryFacet (added)");
        _assertAllRoutedTo(upgrade.jobBoardReplaceSelectors(), newJobBoard, "JobBoardFacet");
        _assertAllRoutedTo(upgrade.serviceBoardReplaceSelectors(), newServiceBoard, "ServiceBoardFacet");

        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(oldFactory).length, 0, "the old FactoryFacet kept a selector");
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(oldJobBoard).length, 0, "the old JobBoardFacet kept a selector");
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(oldServiceBoard).length, 0, "the old ServiceBoardFacet kept a selector");
    }

    // ══════════════════════════════════════════════════════════════════════
    // WHAT THE CUT DELIVERS: A BRAKE THAT LETS GO BY ITSELF
    // ══════════════════════════════════════════════════════════════════════

    /// Press it — the doors shut. Wait 72 hours — they open by themselves, with
    /// nobody having come back to clear anything. That round trip is the whole
    /// of decision 17, and it cannot be run at all until the Add group lands:
    /// `pauseNewDeals()` is routed nowhere before this cut.
    function test_PressedTheDoorsShutAndSeventyTwoHoursLaterTheyOpenByThemselves() public {
        _applyTheCut();

        // Before: the board takes a job. Asked of the COUNTER, not of the id --
        // `mintJob` hands out `nextJobId++`, so the first job on a fresh board
        // is id ZERO and `assertGt(id, 0)` would fail on a board that worked.
        uint256 firstJob = _postAJob();
        assertEq(JobBoardFacet(address(diamond)).totalJobs(), firstJob + 1, "the board would not take a job before the brake was pressed");

        FactoryFacet(address(diamond)).pauseNewDeals();
        assertEq(
            FactoryFacet(address(diamond)).newDealsPausedUntil(),
            block.timestamp + PAUSE_DURATION,
            "one press must hold for exactly NEW_DEALS_PAUSE_DURATION from now"
        );

        // Both boards refuse, and so does the factory's own door.
        vm.startPrank(client);
        vm.expectRevert(JobBoardFacet.FactoryPaused.selector);
        JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, "terms", 0);
        vm.stopPrank();

        vm.startPrank(executor);
        vm.expectRevert(ServiceBoardFacet.FactoryPaused.selector);
        ServiceBoardFacet(address(diamond)).mintService("t", "d", AMOUNT, DEADLINE, 0);
        vm.stopPrank();

        vm.startPrank(client);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        FactoryFacet(address(diamond)).deployAndFund(client, executor, AMOUNT, DEADLINE, "terms", 0);
        vm.stopPrank();

        // One second before it lets go: still down.
        vm.warp(FactoryFacet(address(diamond)).newDealsPausedUntil() - 1);
        vm.startPrank(client);
        vm.expectRevert(JobBoardFacet.FactoryPaused.selector);
        JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, "terms", 0);
        vm.stopPrank();

        // On the second it lets go: open, and NOBODY had to clear anything.
        vm.warp(FactoryFacet(address(diamond)).newDealsPausedUntil());
        uint256 laterJob = _postAJob();
        assertEq(laterJob, firstJob + 1, "the brake did not let go by itself");
        assertGt(
            FactoryFacet(address(diamond)).newDealsPausedUntil(), 0,
            "the timestamp was cleared by something - expiry must be the absence of a write, not a write"
        );
    }

    /// The early release, which is the other half of decision 17: an upgrade
    /// takes twenty minutes, not three days.
    function test_ResumeLetsTheBrakeGoEarlyAndWritesZero() public {
        _applyTheCut();
        FactoryFacet(address(diamond)).pauseNewDeals();

        vm.startPrank(client);
        vm.expectRevert(JobBoardFacet.FactoryPaused.selector);
        JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, "terms", 0);
        vm.stopPrank();

        FactoryFacet(address(diamond)).resumeNewDeals();
        assertEq(
            FactoryFacet(address(diamond)).newDealsPausedUntil(), 0,
            "an early release must write zero - the state after it is the state before the first press"
        );
        uint256 reopened = _postAJob();
        assertEq(
            JobBoardFacet(address(diamond)).totalJobs(), reopened + 1,
            "the board did not reopen after an early release"
        );
    }

    /// Who may press. Decision 17 names the diamond's owner and nobody else —
    /// not the arbiter chief, who runs the arbiter corps and not the
    /// marketplace.
    function test_OnlyTheOwnerMayPressOrRelease() public {
        _applyTheCut();

        vm.prank(client);
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).pauseNewDeals();

        vm.prank(executor);
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).resumeNewDeals();

        // And the owner may, which is what makes the two refusals above mean
        // something other than "the selector is broken".
        FactoryFacet(address(diamond)).pauseNewDeals();
        assertGt(FactoryFacet(address(diamond)).newDealsPausedUntil(), block.timestamp);
    }

    /// The facet states its own duration, and it is the one this cut was
    /// written for. Compared against this stand's literal — a third copy, after
    /// the facet's and the script's.
    function test_TheFacetStatesTheSameSeventyTwoHoursTheScriptExpects() public {
        _applyTheCut();
        (bool ok, bytes memory ret) = address(diamond).staticcall(
            abi.encodeWithSignature("NEW_DEALS_PAUSE_DURATION()")
        );
        assertTrue(ok, "NEW_DEALS_PAUSE_DURATION() does not answer");
        assertEq(abi.decode(ret, (uint256)), PAUSE_DURATION, "the facet's duration is not 72 hours");
        assertEq(upgrade.EXPECTED_PAUSE_DURATION(), PAUSE_DURATION, "the script expects a different duration");
    }

    /// ⚠️ THE APPEND, CHECKED WHERE IT WOULD ACTUALLY GO WRONG. A new field at
    /// the tail of `FactoryStorage.Layout` must come down on an UNTOUCHED slot.
    /// One that quietly landed on an occupied one would answer with whatever
    /// lives there — the fee floor is 1 000 000, which as a unix timestamp is
    /// January 1970, so the brake would read "up" and nothing would look wrong;
    /// the max pending requests is 5, same story. So the reading being ZERO on
    /// a diamond that has never been braked is the claim, and the neighbours
    /// being unmoved is the corroboration.
    function test_TheAppendedFieldLandsOnAnUntouchedSlotAndMovesNoNeighbour() public {
        UpgradeEmergencyBrake.StorageSnapshot memory beforeCut =
            upgrade.snapshotFactoryAndBoards(address(diamond));
        _applyTheCut();

        assertEq(
            FactoryFacet(address(diamond)).newDealsPausedUntil(), 0,
            "the appended field is not zero on a diamond that has never been braked - it is aliasing an occupied slot"
        );
        upgrade.assertStorageUnmoved(beforeCut, upgrade.snapshotFactoryAndBoards(address(diamond)));
    }

    /// The half of decision 17 that is a promise about what the brake does NOT
    /// do: a deal that already exists keeps running while the brake is down. It
    /// cannot be otherwise — a deal is an EIP-1167 clone nailed to its
    /// implementation — but "it cannot be otherwise" is exactly the kind of
    /// claim that is worth one measurement.
    function test_ADealBornBeforeThePressKeepsRunningWhileTheBrakeIsDown() public {
        _applyTheCut();

        vm.prank(client);
        usdc.approve(address(diamond), type(uint256).max);
        vm.prank(client);
        address deal = FactoryFacet(address(diamond)).deployAndFund(client, executor, AMOUNT, DEADLINE, "terms", 0);
        assertTrue(deal != address(0));
        uint256 fundedBefore = usdc.balanceOf(deal);
        assertEq(fundedBefore, AMOUNT, "the deal did not get funded");

        FactoryFacet(address(diamond)).pauseNewDeals();

        // The clone is untouched by the brake: it still holds its money and the
        // registry still knows it.
        assertEq(usdc.balanceOf(deal), fundedBefore, "the brake moved money out of a live deal");
        assertTrue(
            RegistryFacet(address(diamond)).hasActivePair(client, executor),
            "the brake unregistered a live deal"
        );

        // And a SECOND deal between the same two cannot be born, which is the
        // brake and not the active-pair guard: the message says so.
        vm.prank(client);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        FactoryFacet(address(diamond)).deployAndFund(client, address(0x77), AMOUNT, DEADLINE, "terms", 0);
    }

    /// The exits stay open while the brake is down, and that is not decoration:
    /// a brake that also traps the money it stopped is the accident, not the
    /// remedy. `cancelJob` carries no gate and must never grow one.
    function test_TheExitsStayOpenWhileTheBrakeIsDown() public {
        _applyTheCut();
        uint256 jobId = _postAJob();
        uint256 before = usdc.balanceOf(client);

        FactoryFacet(address(diamond)).pauseNewDeals();

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        assertGt(usdc.balanceOf(client), before, "money could not leave while the brake was down");
    }

    // ══════════════════════════════════════════════════════════════════════
    // SABOTAGE: the pre-flight is shown to be guarding something real
    // ══════════════════════════════════════════════════════════════════════

    /// `Add` reverts on a selector already routed. Mount one of the five
    /// somewhere first, and the pre-flight must refuse BEFORE three facets are
    /// paid for.
    function test_PreflightRefusesWhenAnAddSelectorIsAlreadyMounted() public {
        bytes4[] memory one = new bytes4[](1);
        one[0] = upgrade.factoryAddSelectors()[0];
        IDiamondCut.FacetCut[] memory sneak = new IDiamondCut.FacetCut[](1);
        sneak[0] = IDiamondCut.FacetCut(address(new FactoryFacet()), IDiamondCut.FacetCutAction.Add, one);
        IDiamondCut(address(diamond)).diamondCut(sneak, address(0), "");

        // ⚠️ The list goes into a local BEFORE expectRevert: `expectRevert`
        // applies to the NEXT external call, and `upgrade.factoryAddSelectors()`
        // is one. Left inline, the cheat matches that call, which does not
        // revert, and the test fails for a reason unrelated to what it asks.
        bytes4[] memory addSels = upgrade.factoryAddSelectors();
        vm.expectRevert(bytes("pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert"));
        upgrade.assertAddGroupIsUnmountedAnywhere(addSels, address(diamond));
    }

    /// `Replace` reverts on a selector that is not mounted. Unmount one and the
    /// pre-flight must say which group it belongs in.
    function test_PreflightRefusesWhenAReplaceSelectorIsNotMounted() public {
        bytes4[] memory one = new bytes4[](1);
        one[0] = upgrade.jobBoardReplaceSelectors()[0];
        IDiamondCut.FacetCut[] memory strip = new IDiamondCut.FacetCut[](1);
        strip[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, one);
        IDiamondCut(address(diamond)).diamondCut(strip, address(0), "");

        bytes4[] memory jobSels = upgrade.jobBoardReplaceSelectors();
        vm.expectRevert(bytes("pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert"));
        upgrade.assertAllMountedOnOneFacet(jobSels, address(diamond));
    }

    /// A facet holding a selector this cut does not carry would be left
    /// pointing at code that no longer implements it.
    function test_PreflightRefusesWhenTheOldFacetHoldsSomethingThisCutDoesNotCarry() public {
        address oldFactory = IDiamondLoupe(address(diamond)).facetAddress(upgrade.factoryReplaceSelectors()[0]);
        bytes4[] memory stray = new bytes4[](1);
        stray[0] = bytes4(keccak256("aFunctionNobodyHasEverWritten()"));
        IDiamondCut.FacetCut[] memory add = new IDiamondCut.FacetCut[](1);
        add[0] = IDiamondCut.FacetCut(oldFactory, IDiamondCut.FacetCutAction.Add, stray);
        IDiamondCut(address(diamond)).diamondCut(add, address(0), "");

        bytes4[] memory facSels = upgrade.factoryReplaceSelectors();
        vm.expectRevert(bytes("pre-flight: a facet being replaced holds a different number of selectors than this cut carries"));
        upgrade.assertNothingIsLeftBehind(facSels, oldFactory, address(diamond));
    }

    /// Running the cut twice. The second run must be refused by the pre-flight
    /// rather than by `Add`, which would revert only after the facets are paid
    /// for and would blame a selector instead of the operator.
    function test_PreflightRefusesToRunTheCutTwice() public {
        _applyTheCut();
        vm.expectRevert(bytes("pre-flight: the diamond already answers newDealsPausedUntil() - this cut has already landed"));
        upgrade.assertTheBrakeIsNotThereYet(address(diamond));
    }

    /// The post-flight is shown to be guarding something too: point the
    /// replaced selectors at a facet that is not the one this cut deployed and
    /// it must refuse.
    function test_PostflightRefusesWhenASelectorDidNotLandOnTheNewFacet() public {
        (address newFactory, , ) = _applyTheCut();
        bytes4[] memory facSels = upgrade.factoryReplaceSelectors();
        vm.expectRevert(bytes("post-flight: a selector did not land on the new facet"));
        upgrade.assertRouted(facSels, address(uint160(newFactory) + 1), address(diamond));
    }

    /// And the storage-continuity claim: move one witness and it must say so
    /// rather than reading past it.
    function test_StorageContinuityRefusesWhenAWitnessMoves() public {
        UpgradeEmergencyBrake.StorageSnapshot memory a = upgrade.snapshotFactoryAndBoards(address(diamond));
        // ⚠️ Copied FIELD BY FIELD, not `b = a`. Two memory structs assigned to
        // each other share one reference, so `b.feeFloor = ...` would move the
        // witness on both sides and the comparison would agree with itself --
        // the sabotage would sabotage nothing and this lock would be green
        // forever.
        UpgradeEmergencyBrake.StorageSnapshot memory b = UpgradeEmergencyBrake.StorageSnapshot({
            totalJobs: a.totalJobs,
            totalServices: a.totalServices,
            totalRequests: a.totalRequests,
            feeBps: a.feeBps,
            feeFloor: a.feeFloor + 1,
            maxPendingRequests: a.maxPendingRequests,
            feeRecipient: a.feeRecipient,
            agreementDeployer: a.agreementDeployer
        });
        vm.expectRevert(bytes("post-flight: the fee floor moved across the cut"));
        upgrade.assertStorageUnmoved(a, b);
    }

    // ══════════════════════════════════════════════════════════════════════
    // RIG
    // ══════════════════════════════════════════════════════════════════════

    function _applyTheCut() internal returns (address fac, address job, address svc) {
        fac = address(new FactoryFacet());
        job = address(new JobBoardFacet());
        svc = address(new ServiceBoardFacet());
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(fac, job, svc), address(0), "");
    }

    function _postAJob() internal returns (uint256 jobId) {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, "terms", 0);
        vm.stopPrank();
    }

    /// A diamond that routes exactly what Base Sepolia routes today: built from
    /// DeployFull's own lists — the same lists a fresh deployment uses — and
    /// then stripped back to the census by removing everything the tree has and
    /// the chain does not.
    ///
    /// The strip is the load-bearing part. It counts the difference and refuses
    /// unless it is EXACTLY this cut's five: a rig quietly ahead of the chain by
    /// something else would rehearse a cut against a diamond that does not
    /// exist.
    function _deployPreCutDiamond() internal returns (DiamondProxy d) {
        d = _deployFullShapedDiamond();

        bytes4[] memory onChain = _censusAt(".selectors", ".count");
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(d)).facets();

        bytes4[] memory extra = new bytes4[](EXTRA_BEYOND_CHAIN);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = 0; j < all[i].functionSelectors.length; j++) {
                bytes4 sel = all[i].functionSelectors[j];
                bool onLiveChain;
                for (uint256 k = 0; k < onChain.length; k++) {
                    if (sel == onChain[k]) { onLiveChain = true; break; }
                }
                if (!onLiveChain) {
                    require(n < EXTRA_BEYOND_CHAIN, "the local rig is ahead of the chain by more than this cut adds");
                    extra[n++] = sel;
                }
            }
        }
        require(n == EXTRA_BEYOND_CHAIN, "the local rig does not differ from the chain by exactly this cut's additions");

        // And the difference must be THIS cut's five, not merely five. A count
        // agrees on a swap.
        //
        // ⚠️ THE EXPECTED SIDE IS THE CENSUS, NOT `upgrade.factoryAddSelectors()`.
        // It used to be the script's own list, and that was wrong in a way that
        // only showed up under mutation: dropping a selector from the Add group
        // made THIS line fail, in setUp, which aborts the whole suite before the
        // by-name locks below ever run. One red, in a helper, and the tests
        // actually appointed to catch that mistake reported nothing at all --
        // the reading "one test went red" would have been true and useless.
        //
        // Reading it from the census fixes both halves at once: the rig is now
        // measured against data read off Base Sepolia plus a literal a person
        // wrote down, the script's own list is not consulted here, and a wrong
        // Add group reddens the tests that name the selectors instead of
        // silencing them.
        _assertSameSet(
            extra,
            _concat(_censusList(".brakeSelectors"), _censusList(".feeCapSelectors")),
            "the rig's surplus over the chain"
        );

        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, extra);
        IDiamondCut(address(d)).diamondCut(remove, address(0), "");

        uint256 routed;
        IDiamondLoupe.Facet[] memory after_ = IDiamondLoupe(address(d)).facets();
        for (uint256 i = 0; i < after_.length; i++) routed += after_[i].functionSelectors.length;
        require(routed == CHAIN_ROUTED, "the local pre-cut rig routes a different number of selectors than the live chain");
        require(after_.length == CHAIN_FACETS, "the local pre-cut rig has a different number of facets than the live chain");
    }

    /// Registry and factory, seeded the way `BoardsFixture` seeds its own — the
    /// same mock token, the same fee recipient, the same fee model — so the
    /// scenes above run on money rather than on an empty diamond.
    function _initDiamond() internal {
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );
    }

    /// A diamond built out of DeployFull's own selector lists — the same lists
    /// run() builds the live one from. A private hand-written set would drift
    /// from the live layout in silence, and then the shape claim would be about
    /// a diamond that does not exist.
    function _deployFullShapedDiamond() internal returns (DiamondProxy d) {
        DeployFull deploy = new DeployFull();
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
                address(new ArbiterAccountabilityFacet()),
                address(new ArbiterApplicationsFacet()),
                address(new DealMetadataFacet()),
                address(new JobReceiptFacet()),
                address(new ReputationFacet())
            ),
            address(0),
            ""
        );
    }

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

    /// A census list that carries no count field of its own — the two Add
    /// lists. `_censusAt` is for the lists the census also states a length for.
    function _censusList(string memory listKey) internal view returns (bytes4[] memory out) {
        string[] memory raw = vm.parseJsonStringArray(vm.readFile(CENSUS_PATH), listKey);
        out = new bytes4[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            bytes memory b = vm.parseBytes(raw[i]);
            require(b.length == 4, "the census holds a string that is not a selector");
            out[i] = bytes4(b);
        }
    }

    function _assertAllRoutedTo(bytes4[] memory sels, address expected, string memory label) internal view {
        for (uint256 i = 0; i < sels.length; i++) {
            assertEq(
                IDiamondLoupe(address(diamond)).facetAddress(sels[i]),
                expected,
                string.concat(label, ": a selector did not land on the facet this cut deployed")
            );
        }
    }

    function _assertContains(bytes4[] memory haystack, bytes4 needle, string memory what) internal pure {
        for (uint256 i = 0; i < haystack.length; i++) if (haystack[i] == needle) return;
        revert(string.concat("the Add group does not carry ", what));
    }

    function _assertSameSet(bytes4[] memory mine, bytes4[] memory theirs, string memory label) internal pure {
        assertEq(mine.length, theirs.length, string.concat(label, ": the two sides disagree on how many selectors there are"));
        for (uint256 i = 0; i < mine.length; i++) {
            bool found;
            for (uint256 j = 0; j < theirs.length; j++) {
                if (mine[i] == theirs[j]) { found = true; break; }
            }
            assertTrue(found, string.concat(label, ": this cut carries a selector the other side does not have"));
        }
        for (uint256 i = 0; i < theirs.length; i++) {
            bool found;
            for (uint256 j = 0; j < mine.length; j++) {
                if (theirs[i] == mine[j]) { found = true; break; }
            }
            assertTrue(found, string.concat(label, ": the other side has a selector this cut does not carry"));
        }
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }
}
