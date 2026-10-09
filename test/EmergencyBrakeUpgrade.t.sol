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
import "../src/facets/TreasuryLinkFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {UpgradeEmergencyBrake} from "../script/UpgradeEmergencyBrake.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterSplitRig} from "./ArbiterSplitRig.sol";

contract EmergencyBrakeUpgradeTest is BoardsFixture, ArbiterSplitRig {
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

    /// The three the job board grew AFTER this cut (18 September 2026, "an
    /// arbiter is not a player in the market"): getOpenMarketItems,
    /// pruneClosedApplications, getAppliedJobIds. By SIGNATURE TEXT, never read
    /// off the later script's lists.
    ///
    /// ⚠️ WHY THE SCRIPT'S OWN `assertListsCoverTheCompiledFacets` IS NOT USED
    /// BY THIS FILE ANY MORE, and why the script keeps its strict version
    /// untouched. That one asks "is the compiled facet exactly what I mount",
    /// and for this cut the honest answer is now NO — JobBoardFacet has grown
    /// three reads since 3 September. `run()` still asks it strictly, which is
    /// right: re-running this script today would deploy a job board carrying
    /// those three and mount only thirteen of its sixteen functions, shipping
    /// three dead ones. The refusal is the script telling the truth about
    /// itself, and it is not silenced. The same device, for the same reason, is
    /// in test/BoardFeeDeliveryUpgrade.t.sol.
    function _grownJobBoardAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](3);
        sels[0] = bytes4(keccak256("getOpenMarketItems(address)"));
        sels[1] = bytes4(keccak256("pruneClosedApplications(address,uint256)"));
        sels[2] = bytes4(keccak256("getAppliedJobIds(address)"));
    }

    /// The coverage claim with that growth named rather than folded in.
    function _assertListsCoverTheCompiledFacetsAllowingLaterGrowth() internal view {
        _assertSameSet(
            _concat(upgrade.factoryReplaceSelectors(), upgrade.factoryAddSelectors()),
            upgrade.artifactSelectors("out/FactoryFacet.sol/FactoryFacet.json"),
            "FactoryFacet"
        );
        _assertSameSet(
            _concat(upgrade.jobBoardReplaceSelectors(), _grownJobBoardAfterThisCut()),
            upgrade.artifactSelectors("out/JobBoardFacet.sol/JobBoardFacet.json"),
            "JobBoardFacet (this cut's group plus the named later growth)"
        );
        _assertSameSet(
            upgrade.serviceBoardReplaceSelectors(),
            upgrade.artifactSelectors("out/ServiceBoardFacet.sol/ServiceBoardFacet.json"),
            "ServiceBoardFacet"
        );
    }

    /// The allowance held to its own conditions: every selector in it is really
    /// implemented by the facet today, and none of them is one this cut mounted.
    function test_TheJobBoardGrowthBeyondThisCutIsRealAndCoversNothingItMounted() public view {
        bytes4[] memory grown = _grownJobBoardAfterThisCut();
        bytes4[] memory jobAbi = upgrade.artifactSelectors("out/JobBoardFacet.sol/JobBoardFacet.json");
        bytes4[] memory mounted = upgrade.jobBoardReplaceSelectors();
        for (uint256 i = 0; i < grown.length; i++) {
            bool inAbi;
            for (uint256 j = 0; j < jobAbi.length; j++) if (jobAbi[j] == grown[i]) inAbi = true;
            assertTrue(inAbi, "the allowance is stale: JobBoardFacet no longer implements it");
            for (uint256 j = 0; j < mounted.length; j++) {
                assertTrue(mounted[j] != grown[i], "the allowance covers a selector this cut REPLACED");
            }
        }
    }

    /// The script's hand-written lists against solc's output for each facet. A
    /// function a facet gains and nobody mounts would otherwise ship dead:
    /// present in the ABI, routed nowhere, discovered by the first person whose
    /// button did nothing.
    function test_ListsCoverExactlyTheCompiledFacets() public view {
        _assertListsCoverTheCompiledFacetsAllowingLaterGrowth();

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
        _assertSameSet(
            _concat(upgrade.jobBoardReplaceSelectors(), _grownJobBoardAfterThisCut()),
            deploy.jobBoardFacetSelectors(),
            "JobBoard vs DeployFull (plus the named later growth)"
        );
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

        _assertListsCoverTheCompiledFacetsAllowingLaterGrowth();
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
        _mountOfferRegistration();

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
        // The census this rig is measured against predates the unmount; see the
        // helper's own note for why the script cannot supply this any more.
        _mountHistoricalDealMetadata(d);

        bytes4[] memory onChain = _censusAt(".selectors", ".count");
        _conformToCensus(d, onChain);
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
    /// Every selector this checkout mounts that the census does not hold,
    /// filled in by _conformToCensus. COMPUTED, never declared: this is the
    /// surplus that used to be a hand-kept total.
    bytes4[] internal rigSurplusOverCensus;

    /// Cut the rig down to the census, and then prove it IS the census.
    ///
    /// ⚠️ THE SIZE OF THE DIFFERENCE IS COMPUTED, NEVER DECLARED. Whatever this
    /// checkout mounts that the census does not hold comes off, however many
    /// that is. The shape this helper replaced sized its array from a hand-kept
    /// total and refused when the count disagreed, so every cut landing in the
    /// tree reddened it and every red was answered by raising the total.
    ///
    /// The claim that takes the count's place is stronger, not weaker: after the
    /// removal the rig's selector set must EQUAL the census's, both directions
    /// checked. A count agrees with a swap; equality does not.
    ///
    /// The other direction deserves its own sentence. A selector the census
    /// holds and this checkout can no longer build is the case that arrives when
    /// a facet leaves the tree -- it reds HERE, naming the selector, instead of
    /// leaving the rig one door short of the diamond it claims to be.
    /// ⚠️ TWO SELECTORS MOUNTED ON TOP OF THE CENSUS, for the one scene that has
    /// to CREATE a deal (18 September 2026).
    ///
    /// This rig deploys THIS CHECKOUT's FactoryFacet on a diamond stripped back
    /// to the shape the chain had at the emergency-brake cut. Since the direct
    /// hire became an offer, that factory registers a deal through
    /// `registerOffer` and the clone announces the acceptance through
    /// `notifyOfferAccepted` — neither of which the chain routed at that
    /// census, so `deployAndFund` on the conformed rig dies with
    /// "function not found" for a reason that has nothing to do with the brake.
    ///
    /// Mounted HERE and not in `_deployPreCutDiamond`, so that every other
    /// scene keeps the exact-census claim this rig is built on, and so that the
    /// one scene that steps outside it says why in the trace.
    function _mountOfferRegistration() internal {
        address registryFacet = IDiamondLoupe(address(diamond)).facetAddress(RegistryFacet.register.selector);
        require(registryFacet != address(0), "the rig has no registry facet to extend");
        if (IDiamondLoupe(address(diamond)).facetAddress(RegistryFacet.registerOffer.selector) != address(0)) return;

        bytes4[] memory sels = new bytes4[](2);
        sels[0] = RegistryFacet.registerOffer.selector;
        sels[1] = RegistryFacet.notifyOfferAccepted.selector;
        IDiamondCut.FacetCut[] memory add = new IDiamondCut.FacetCut[](1);
        add[0] = IDiamondCut.FacetCut(registryFacet, IDiamondCut.FacetCutAction.Add, sels);
        IDiamondCut(address(diamond)).diamondCut(add, address(0), "");
    }

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

        // The three application doors this checkout stopped building on
        // 22 September 2026, put back where the census still has them. See
        // ArbiterSplitRig._mountRemovedApplicationDoors for why they go on the
        // applications facet that is already here rather than on a stub.
        _mountRemovedApplicationDoors(address(d), census);
        // And the three doors of the governance hand over a verdict, which left the
        // facet AND the chain on 9 October 2026. Same reason, same shape, one note:
        // see ArbiterSplitRig._mountRemovedVerdictHandDoors.
        _mountRemovedVerdictHandDoors(address(d), census);

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

    function _contains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) if (haystack[i] == needle) return true;
        return false;
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
