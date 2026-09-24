// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeBoardFeeDelivery.s.sol — the diamondCut that
// replaces JobBoardFacet, ServiceBoardFacet and FactoryFacet and adds two
// selectors.
//
// ⚠️ WHY A STAND AT ALL, WHEN THE SCRIPT HAS A DRY RUN. A dry run proves the
// script survives TODAY'S chain. It cannot prove the script survives the chain
// it will meet at the moment somebody signs, and it cannot be run in CI at all
// — it needs a network and an RPC key. Everything below runs offline, and the
// questions that decide whether the cut lands or reverts are answered from
// sources this file does not own:
//
//   * "do the lists cover the facets" — the expected side is solc's own
//     `methodIdentifiers`, read out of the build artifacts, not the lists in
//     the script;
//   * "is every Replace selector mounted, is anything else on those facets, and
//     are the two Add selectors mounted nowhere" — the expected side is a
//     census read off Base Sepolia and committed as data
//     (test/fixtures/chain-2026-08-25-boards-fee-selectors.json).
//
// Neither is derived from the thing being checked. That is the fourth way to be
// fooled by a measurement, and it cost a whole cut once: a
// stand that built "what is mounted on chain" out of the script's own
// `replaceSelectors()` agreed with itself no matter which group a selector was
// filed under.
//
// ⚠️ THIS CUT CAN MEET BOTH HALVES OF THE PAIR, AND THE PREVIOUS TWO COULD NOT.
// `Replace` reverts "Diamond: selector not found" on a selector that is not
// mounted; `Add` reverts "Diamond: selector exists" on one that is. The last cut
// was Replace-only and could only meet the first; the one before it was
// Add-only and could only meet the second. This one carries three Replace
// groups AND an Add group, so a selector filed under the wrong one drops the
// whole cut in a single live transaction after three facets have been paid for.
// Both reverts are demonstrated against a real diamond further down, so the
// pre-flight is known to be guarding something real.

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
import {UpgradeBoardFeeDelivery} from "../script/UpgradeBoardFeeDelivery.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterSplitRig} from "./ArbiterSplitRig.sol";

contract BoardFeeDeliveryUpgradeTest is BoardsFixture, ArbiterSplitRig {
    UpgradeBoardFeeDelivery upgrade;

    /// The census, and the things it is held to before it is believed.
    string constant CENSUS_PATH = "test/fixtures/chain-2026-08-25-boards-fee-selectors.json";
    address constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;

    /// Read off the chain on 25 August 2026 and written down by a person, so
    /// that a facet which silently grows or loses a function stops here instead
    /// of at the signature.
    uint256 constant CHAIN_FACETS       = 13;

    uint256 constant CHAIN_ROUTED       = 214;
    uint256 constant JOBBOARD_SELECTORS = 13;
    uint256 constant SERVICE_SELECTORS  = 25;
    uint256 constant FACTORY_SELECTORS  = 21;
    uint256 constant ADDED_SELECTORS    = 2;

    /// The five, by SIGNATURE TEXT, never taken from the later script's lists.
    function _grownFactoryAfterThisCut() internal pure returns (bytes4[] memory sels) {
        // ⚠️ THE SIZE IS THE LENGTH OF THE LIST DIRECTLY BELOW IT, and it used
        // to be a sum of separately declared allowance constants. Those
        // constants are gone: a number kept apart from the list it sizes is one
        // more thing to keep in step, and keeping it in step by hand is the
        // habit this file was rewritten to break.
        sels = new bytes4[](5);
        sels[0] = bytes4(keccak256("pauseNewDeals()"));
        sels[1] = bytes4(keccak256("resumeNewDeals()"));
        sels[2] = bytes4(keccak256("newDealsPausedUntil()"));
        sels[3] = bytes4(keccak256("NEW_DEALS_PAUSE_DURATION()"));
        sels[4] = bytes4(keccak256("MAX_FEE_BPS()"));
    }

    /// The three the job board grew on 18 September 2026, by SIGNATURE TEXT and
    /// never taken from a later script's lists — same device as the factory's
    /// allowance above and for the same reason: this cut is a RECORD of what was
    /// mounted on 25 August, and "an arbiter is not a player in the market"
    /// added three reads to JobBoardFacet afterwards (getOpenMarketItems,
    /// pruneClosedApplications, getAppliedJobIds). Demanding this cut mount them
    /// would be demanding that the past match the present; leaving them out of
    /// the allowance would make the coverage lock below call a job board with
    /// three unmounted functions complete.
    function _grownJobBoardAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](3);
        sels[0] = bytes4(keccak256("getOpenMarketItems(address)"));
        sels[1] = bytes4(keccak256("pruneClosedApplications(address,uint256)"));
        sels[2] = bytes4(keccak256("getAppliedJobIds(address)"));
    }

    /// The allowance held to its own two conditions, in its own test so that a
    /// failure names which one broke.
    ///
    /// What disappears from behaviour if this is removed: the allowance becomes
    /// an unchecked hole — four FactoryFacet selectors could be dropped out of
    /// this cut's lists and parked here, and the coverage lock below would call
    /// the cut complete.
    function test_TheJobBoardGrowthBeyondThisCutIsRealAndCoversNothingItMounted() public {
        UpgradeBoardFeeDelivery u = _upgrade();
        bytes4[] memory grown = _grownJobBoardAfterThisCut();
        bytes4[] memory jobAbi = u.artifactSelectors("out/JobBoardFacet.sol/JobBoardFacet.json");
        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(
                _contains(jobAbi, grown[i]),
                "the allowance is stale: JobBoardFacet no longer implements it"
            );
            assertFalse(
                _contains(u.jobBoardReplaceSelectors(), grown[i]),
                "the allowance covers a selector this cut REPLACED"
            );
        }
    }

    function test_TheGrowthBeyondThisCutIsRealAndCoversNothingItMounted() public {
        UpgradeBoardFeeDelivery u = _upgrade();
        bytes4[] memory grown = _grownFactoryAfterThisCut();
        bytes4[] memory factoryAbi = u.artifactSelectors("out/FactoryFacet.sol/FactoryFacet.json");
        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(
                _contains(factoryAbi, grown[i]),
                "the allowance is stale: FactoryFacet no longer implements it"
            );
            assertFalse(
                _contains(u.factoryReplaceSelectors(), grown[i]),
                "the allowance covers a selector this cut REPLACED"
            );
            assertFalse(
                _contains(u.factoryAddSelectors(), grown[i]),
                "the allowance covers a selector this cut ADDED"
            );
        }
    }

    function _contains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) if (haystack[i] == needle) return true;
        return false;
    }

    /// The coverage claim, with the later growth named rather than folded in.
    ///
    /// ⚠️ NOT `u.assertListsCoverTheCompiledFacets(...)` ANY MORE, and the script
    /// keeps that strict version untouched on purpose. It asks "is the compiled
    /// facet exactly what I mount", and for this cut the honest answer is NO —
    /// FactoryFacet has grown four functions since 25 August. `run()` still asks
    /// it strictly, which is correct: re-running this script today would deploy a
    /// FactoryFacet carrying the brake and mount only 23 of its 27 functions,
    /// shipping four dead ones. The refusal is the script telling the truth about
    /// itself, and it is not silenced.
    function _assertListsCoverTheCompiledFacetsAllowingLaterGrowth(UpgradeBoardFeeDelivery u) internal view {
        _assertSameSet(
            _concat(u.jobBoardReplaceSelectors(), _grownJobBoardAfterThisCut()),
            u.artifactSelectors("out/JobBoardFacet.sol/JobBoardFacet.json"),
            "JobBoardFacet (this cut's group plus the named later growth)"
        );
        _assertSameSet(u.serviceBoardReplaceSelectors(), u.artifactSelectors("out/ServiceBoardFacet.sol/ServiceBoardFacet.json"), "ServiceBoardFacet");
        _assertSameSet(
            _concat(_concat(u.factoryReplaceSelectors(), u.factoryAddSelectors()), _grownFactoryAfterThisCut()),
            u.artifactSelectors("out/FactoryFacet.sol/FactoryFacet.json"),
            "FactoryFacet (this cut's two groups plus the named later growth)"
        );
    }

    function _upgrade() internal returns (UpgradeBoardFeeDelivery) {
        if (address(upgrade) == address(0)) upgrade = new UpgradeBoardFeeDelivery();
        return upgrade;
    }

    /// ⚠️ THE FIXTURE'S OWN DIAMOND IS NOT THE RIGHT STAND FOR THIS CUT.
    /// `BoardsFixture` mounts a FactoryFacet selector set of its own — it skips
    /// `initFeeModel` and carries three literals for functions that no longer
    /// exist. That is fine for board behaviour and useless for rehearsing a
    /// cut, which is a claim about the set the CHAIN routes. So the actors, the
    /// mock token and the balances stay, and the diamond is rebuilt in the live
    /// shape below.
    function setUp() public override {
        super.setUp();
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
    function test_ListsCoverExactlyTheCompiledFacets() public {
        UpgradeBoardFeeDelivery u = _upgrade();
        _assertListsCoverTheCompiledFacetsAllowingLaterGrowth(u);

        assertEq(u.jobBoardReplaceSelectors().length, JOBBOARD_SELECTORS);
        assertEq(u.serviceBoardReplaceSelectors().length, SERVICE_SELECTORS);
        assertEq(u.factoryReplaceSelectors().length, FACTORY_SELECTORS);
        assertEq(u.factoryAddSelectors().length, ADDED_SELECTORS);
    }

    /// THE PROOF OF THE Replace/Add SPLIT, half one: everything in a Replace
    /// group is mounted on the live chain today, and everything mounted on
    /// those three facets is in a Replace group. Set equality in both
    /// directions, per facet.
    ///
    ///   * nothing in a Replace group is unmounted -> no element belongs in Add;
    ///   * nothing mounted is missing -> no selector is left pointing at a facet
    ///     that no longer implements it.
    function test_EveryReplacedSelectorIsMountedOnTheLiveChainAndNothingElseIs() public {
        UpgradeBoardFeeDelivery u = _upgrade();
        _assertSameSet(u.jobBoardReplaceSelectors(), _censusAt(".jobBoardSelectors", ".jobBoardCount"), "JobBoard");
        _assertSameSet(u.serviceBoardReplaceSelectors(), _censusAt(".serviceBoardSelectors", ".serviceBoardCount"), "ServiceBoard");
        _assertSameSet(u.factoryReplaceSelectors(), _censusAt(".factorySelectors", ".factoryCount"), "Factory");
    }

    /// THE PROOF OF THE SPLIT, half two — and the half neither of the previous
    /// two cuts had to make. Both Add selectors must be mounted NOWHERE in the
    /// diamond, which is a question about the whole routed list, not about
    /// FactoryFacet: `Add` reverts on a selector routed anywhere at all.
    function test_BothAddedSelectorsAreMountedNowhereOnTheLiveChain() public {
        bytes4[] memory whole = _censusAt(".selectors", ".count");
        assertEq(whole.length, CHAIN_ROUTED, "the census does not hold the number of selectors it claims");

        bytes4[] memory added = _upgrade().factoryAddSelectors();
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
    /// compiled FactoryFacet must expose exactly two functions the chain does
    /// not have. A third one added later without touching the script would be
    /// caught here rather than by whoever presses the button.
    function test_TheCompiledFactoryGainsExactlyTheTwoSelectorsThisCutAdds() public {
        bytes4[] memory fromArtifact = _upgrade().artifactSelectors("out/FactoryFacet.sol/FactoryFacet.json");
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
            unmounted, ADDED_SELECTORS + _grownFactoryAfterThisCut().length,
            "the compiled FactoryFacet gains a different number of functions than this cut adds plus the named later growth"
        );

        // A count agrees on a swap, so the surplus is also asked BY NAME: every
        // one of the five beyond this cut's two must be a selector this file
        // has named -- the brake's four or item 138's MAX_FEE_BPS() -- and
        // every one of those five must be in the surplus.
        bytes4[] memory surplus = new bytes4[](unmounted);
        uint256 k;
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            bool found;
            for (uint256 j = 0; j < mounted.length; j++) {
                if (fromArtifact[i] == mounted[j]) { found = true; break; }
            }
            if (!found) surplus[k++] = fromArtifact[i];
        }
        _assertSameSet(
            surplus,
            _concat(_upgrade().factoryAddSelectors(), _grownFactoryAfterThisCut()),
            "the artifact's surplus over the census"
        );
    }

    /// The census header, before anything is read out of it. The trap worth
    /// catching is not "the census is stale" but "an old census was reused for
    /// a NEW script" — the numbers would look plausible and describe a
    /// different cut.
    function test_TheCensusDescribesThisScriptAndThisDiamond() public {
        string memory json = vm.readFile(CENSUS_PATH);
        assertEq(
            keccak256(bytes(vm.parseJsonString(json, ".forScript"))),
            keccak256(bytes(_upgrade().scriptPath())),
            "this census was taken for a DIFFERENT cut - it does not describe what is being checked"
        );
        assertEq(vm.parseJsonAddress(json, ".diamond"), CENSUS_DIAMOND, "the census was read off a different diamond");
        assertEq(vm.parseJsonUint(json, ".facetCount"), CHAIN_FACETS, "the census disagrees on the facet count");
        assertGt(vm.parseJsonUint(json, ".block"), 0, "the census header has no block number");
        assertGt(bytes(vm.parseJsonString(json, ".takenAt")).length, 0, "the census header has no date");
    }

    /// A third source for the same lists: the from-scratch deploy. If the cut
    /// and the fresh deploy ever disagree about what a facet exposes, one of
    /// the two diamonds is wrong and nothing else would say which.
    function test_TheCutAndTheFreshDeployMountTheSameSets() public {
        DeployFull deploy = new DeployFull();
        UpgradeBoardFeeDelivery u = _upgrade();

        _assertSameSet(
            _concat(u.jobBoardReplaceSelectors(), _grownJobBoardAfterThisCut()),
            deploy.jobBoardFacetSelectors(),
            "JobBoard vs DeployFull (plus the named later growth)"
        );
        _assertSameSet(u.serviceBoardReplaceSelectors(), deploy.serviceBoardFacetSelectors(), "ServiceBoard vs DeployFull");
        _assertSameSet(
            _concat(_concat(u.factoryReplaceSelectors(), u.factoryAddSelectors()), _grownFactoryAfterThisCut()),
            deploy.factoryFacetSelectors(),
            "Factory vs DeployFull"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE CUT ITSELF, APPLIED TO A DIAMOND HOLDING LIVE BOARD MONEY
    // ══════════════════════════════════════════════════════════════════════

    function test_CutIsThreeReplacesAndOneAdd() public {
        IDiamondCut.FacetCut[] memory cuts =
            _upgrade().buildCuts(address(0xF00D1), address(0xF00D2), address(0xF00D3));

        assertEq(cuts.length, 4, "the cut must be four elements");

        assertEq(cuts[0].facetAddress, address(0xF00D1));
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace);
        assertEq(cuts[0].functionSelectors.length, JOBBOARD_SELECTORS);

        assertEq(cuts[1].facetAddress, address(0xF00D2));
        assertTrue(cuts[1].action == IDiamondCut.FacetCutAction.Replace);
        assertEq(cuts[1].functionSelectors.length, SERVICE_SELECTORS);

        assertEq(cuts[2].facetAddress, address(0xF00D3));
        assertTrue(cuts[2].action == IDiamondCut.FacetCutAction.Replace);
        assertEq(cuts[2].functionSelectors.length, FACTORY_SELECTORS);

        // The Add group lands on the SAME address as the Factory Replace group
        // — one FacetCut carries one action, which is the only reason it is a
        // separate element at all.
        assertEq(cuts[3].facetAddress, address(0xF00D3), "the added selectors must land on the new FactoryFacet");
        assertTrue(cuts[3].action == IDiamondCut.FacetCutAction.Add);
        assertEq(cuts[3].functionSelectors.length, ADDED_SELECTORS);
    }

    function test_PreFlightPassesAndTheCutLandsWithoutLosingBoardMoney() public {
        UpgradeBoardFeeDelivery u = _upgrade();
        _seedLiveBoards();

        bytes4[] memory jobSels = u.jobBoardReplaceSelectors();
        bytes4[] memory svcSels = u.serviceBoardReplaceSelectors();
        bytes4[] memory facSels = u.factoryReplaceSelectors();
        bytes4[] memory addSels = u.factoryAddSelectors();

        // Pre-flight, as run() calls it — except for the coverage check, which
        // run() asks strictly and which now refuses, correctly: see
        // _assertListsCoverTheCompiledFacetsAllowingLaterGrowth.
        _assertListsCoverTheCompiledFacetsAllowingLaterGrowth(u);
        address previousJobBoard = u.assertAllMountedOnOneFacet(jobSels, address(diamond));
        address previousServiceBoard = u.assertAllMountedOnOneFacet(svcSels, address(diamond));
        address previousFactory = u.assertAllMountedOnOneFacet(facSels, address(diamond));
        u.assertNothingIsLeftBehind(jobSels, previousJobBoard, address(diamond));
        u.assertNothingIsLeftBehind(svcSels, previousServiceBoard, address(diamond));
        u.assertAddGroupIsUnmountedAnywhere(addSels, address(diamond));

        uint256 routedBefore = _routed();
        uint256 facetsBefore = IDiamondLoupe(address(diamond)).facetAddresses().length;
        UpgradeBoardFeeDelivery.StorageSnapshot memory before = u.snapshotBoards(address(diamond));

        // The scene is only worth running if there is money to lose.
        assertEq(before.totalJobs, 2, "the seeded board does not hold two jobs");
        assertEq(before.totalRequests, 1, "the seeded board does not hold a pending request");
        assertGt(before.jobFeeHeldSum, 0, "the seeded board holds no fee at all");
        uint256 heldBefore = usdc.balanceOf(address(diamond));

        IDiamondCut(address(diamond)).diamondCut(
            u.buildCuts(
                address(new JobBoardFacet()),
                address(new ServiceBoardFacet()),
                address(new FactoryFacet())
            ),
            address(0),
            ""
        );

        // Post-flight, exactly as run() calls it.
        u.assertStorageContinuity(before, u.snapshotBoards(address(diamond)));
        u.assertTheDebtLedgerAnswersAndIsEmpty(address(diamond));

        assertEq(usdc.balanceOf(address(diamond)), heldBefore, "the diamond's USDC moved across a cut");
        assertEq(_routed(), routedBefore + ADDED_SELECTORS, "the routed count moved by something other than the Add group");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, facetsBefore,
            "the facet count moved - the old facets should have been emptied, not unmounted"
        );
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousJobBoard).length, 0);
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousServiceBoard).length, 0);
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousFactory).length, 0);

        // And the money still comes out afterwards, which is the point of the
        // whole cut. The identity is checked, not just the client's balance.
        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(0);
        assertGt(usdc.balanceOf(client), clientBefore, "a job posted before the cut cannot be cancelled after it");
        _assertDiamondHoldsExactlyItsLedger("after cancelling a pre-cut job");
    }

    /// The pre-flight has to REFUSE when the chain is not in the shape the cut
    /// assumes. A selector that is not mounted is the realistic way to get
    /// there: a facet that gained a function since the census was taken.
    function test_PreFlightRefusesWhenAReplacedSelectorIsNotMounted() public {
        UpgradeBoardFeeDelivery u = _upgrade();
        _unmount(ServiceBoardFacet.getRequestFeeHeld.selector);

        // ⚠️ Fetched BEFORE the expectation is armed: `vm.expectRevert` arms the
        // NEXT call, and `u.serviceBoardReplaceSelectors()` is itself an
        // external call to the script contract.
        bytes4[] memory sels = u.serviceBoardReplaceSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert")
        );
        u.assertAllMountedOnOneFacet(sels, address(diamond));
    }

    /// The mirror refusal, and the one this cut needs that the last one did not:
    /// an Add selector that is already routed.
    function test_PreFlightRefusesWhenAnAddedSelectorIsAlreadyMounted() public {
        UpgradeBoardFeeDelivery u = _upgrade();

        bytes4[] memory one = new bytes4[](1);
        one[0] = FactoryFacet.getUndeliveredFees.selector;
        IDiamondCut.FacetCut[] memory mount = new IDiamondCut.FacetCut[](1);
        mount[0] = IDiamondCut.FacetCut(address(new FactoryFacet()), IDiamondCut.FacetCutAction.Add, one);
        IDiamondCut(address(diamond)).diamondCut(mount, address(0), "");

        bytes4[] memory added = u.factoryAddSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert")
        );
        u.assertAddGroupIsUnmountedAnywhere(added, address(diamond));
    }

    /// The diamond itself refuses, with its own message — proof that the
    /// pre-flight guards a real failure rather than an imagined one.
    function test_ADiamondRejectsAReplaceOfAnUnmountedSelector() public {
        _unmount(ServiceBoardFacet.getRequestFeeHeld.selector);

        // ⚠️ Built BEFORE the expectation is armed: `vm.expectRevert` arms the
        // NEXT call, and `buildCuts(...)` is itself an external call.
        IDiamondCut.FacetCut[] memory cuts = _upgrade().buildCuts(
            address(new JobBoardFacet()), address(new ServiceBoardFacet()), address(new FactoryFacet())
        );
        vm.expectRevert(bytes("Diamond: selector not found"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    /// The other half of the pair, on the same diamond, so that the reason the
    /// two new selectors are filed under Add is demonstrated and not asserted.
    function test_ADiamondRejectsAnAddOfAMountedSelector() public {
        bytes4[] memory one = new bytes4[](1);
        one[0] = FactoryFacet.getUndeliveredFees.selector;
        IDiamondCut.FacetCut[] memory mount = new IDiamondCut.FacetCut[](1);
        mount[0] = IDiamondCut.FacetCut(address(new FactoryFacet()), IDiamondCut.FacetCutAction.Add, one);
        IDiamondCut(address(diamond)).diamondCut(mount, address(0), "");

        IDiamondCut.FacetCut[] memory cuts = _upgrade().buildCuts(
            address(new JobBoardFacet()), address(new ServiceBoardFacet()), address(new FactoryFacet())
        );
        vm.expectRevert(bytes("Diamond: selector exists"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }
    // ⚠️ A TEST WAS REMOVED HERE ON 14 SEPTEMBER 2026, AND WHERE IT WENT
    // MATTERS MORE THAN WHAT IT SAID.
    //
    // `test_AFreshDeployIsExactlyThisCutAheadOfTheLiveChain` asked whether a diamond built from
    // script/DeployFull.s.sol still matches the live chain. That is a real
    // question and it now has exactly one owner:
    // test/DeployFullMatchesChain.t.sol, which asks it against the census read
    // at the CURRENT block.
    //
    // It could never be answered here. This stand's census is a BEFORE picture
    // of one past cut, so the only way to compare today's deploy script with it
    // was "old census, plus a hand-kept allowance for every cut that has landed
    // since". That sum is what turned the ratchet into a budget: on
    // 14 September the sibling of this test in
    // test/JobBoardApplicantGateUpgrade.t.sol was GREEN while a from-scratch
    // deployment would have produced a diamond with no treasury link at all,
    // because the stale census and the nine accumulated allowances added up to
    // exactly what the script built.
    //
    // A stand rehearsing a PAST cut is the wrong place to ask a question about
    // the PRESENT chain, and no amount of care with the allowance fixes that.

    /// The rollback path, proved rather than described: the fifty-nine go back
    /// to the facets they came from, the two added ones are removed, and the
    /// boards still read.
    function test_RollbackRestoresTheShapeAndTheBoardsStillRead() public {
        UpgradeBoardFeeDelivery u = _upgrade();
        _seedLiveBoards();

        bytes4[] memory jobSels = u.jobBoardReplaceSelectors();
        bytes4[] memory svcSels = u.serviceBoardReplaceSelectors();
        bytes4[] memory facSels = u.factoryReplaceSelectors();
        bytes4[] memory addSels = u.factoryAddSelectors();

        address previousJobBoard = u.assertAllMountedOnOneFacet(jobSels, address(diamond));
        address previousServiceBoard = u.assertAllMountedOnOneFacet(svcSels, address(diamond));
        address previousFactory = u.assertAllMountedOnOneFacet(facSels, address(diamond));
        uint256 routedBefore = _routed();

        IDiamondCut(address(diamond)).diamondCut(
            u.buildCuts(
                address(new JobBoardFacet()), address(new ServiceBoardFacet()), address(new FactoryFacet())
            ),
            address(0),
            ""
        );

        IDiamondCut.FacetCut[] memory undo = new IDiamondCut.FacetCut[](4);
        undo[0] = IDiamondCut.FacetCut(previousJobBoard, IDiamondCut.FacetCutAction.Replace, jobSels);
        undo[1] = IDiamondCut.FacetCut(previousServiceBoard, IDiamondCut.FacetCutAction.Replace, svcSels);
        undo[2] = IDiamondCut.FacetCut(previousFactory, IDiamondCut.FacetCutAction.Replace, facSels);
        undo[3] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, addSels);
        IDiamondCut(address(diamond)).diamondCut(undo, address(0), "");

        u.assertRouted(jobSels, previousJobBoard, address(diamond));
        u.assertRouted(svcSels, previousServiceBoard, address(diamond));
        u.assertRouted(facSels, previousFactory, address(diamond));
        assertEq(_routed(), routedBefore, "the rollback did not restore the pre-cut shape");
        assertEq(JobBoardFacet(address(diamond)).totalJobs(), 2, "the board did not survive the rollback");
        assertEq(ServiceBoardFacet(address(diamond)).totalRequests(), 1, "the requests did not survive the rollback");
    }

    // ══════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════

    function _routed() internal view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(diamond)).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    function _unmount(bytes4 sel) internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = sel;
        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, one);
        IDiamondCut(address(diamond)).diamondCut(remove, address(0), "");
    }

    /// Puts the fixture's diamond into the shape the live one is in: two open
    /// jobs holding budget and fee, a published service, and one pending
    /// request holding both as well. The cut is then applied on top of real
    /// board money rather than an empty diamond, which is the only way the
    /// storage-continuity claim means anything.
    function _seedLiveBoards() internal {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        JobBoardFacet(address(diamond)).mintJob("One", "d", AMOUNT, DEADLINE, TERMS, REGION);
        JobBoardFacet(address(diamond)).mintJob("Two", "d", AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();

        vm.startPrank(executor);
        usdc.approve(address(diamond), FEE);
        uint256 serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Solidity", "I write it", AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();

        vm.startPrank(client);
        ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    /// The diamond as Base Sepolia stands TODAY — before this cut.
    ///
    /// Built the honest way round: a full DeployFull-shaped diamond (which,
    /// since this work, already mounts the two new selectors) and then the
    /// difference against the CENSUS is removed. Which selectors to remove is
    /// therefore decided by what the chain answered, not by this cut's own
    /// `factoryAddSelectors()` — a rig built from the script's own list would
    /// agree with the script no matter which group anything was filed under,
    /// and that is the fourth way to be fooled by a measurement.
    ///
    /// The count is checked afterwards against the census header too, so a rig
    /// that has quietly drifted from the live diamond stops being a stand-in
    /// without anybody noticing.
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
    /// scenes below run on money rather than on an empty diamond.
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
