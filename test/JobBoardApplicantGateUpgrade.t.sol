// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeJobBoardApplicantGate.s.sol — the diamondCut that
// replaces JobBoardFacet.
//
// ⚠️ WHY A STAND AT ALL, WHEN THE SCRIPT HAS A DRY RUN. A dry run proves the
// script survives TODAY'S chain. It cannot prove the script survives the chain
// it will meet at the moment somebody signs, and it cannot be run in CI at all
// — it needs a network and an RPC key. Everything below runs offline, and the
// questions that decide whether the cut lands or reverts are answered from
// sources this file does not own:
//
//   * "does the Replace list cover the facet" — the expected side is solc's own
//     `methodIdentifiers`, read out of the build artifact, not the list in the
//     script;
//   * "is every one of them mounted, and is anything else on that facet" — the
//     expected side is a census read off Base Sepolia and committed as data
//     (test/fixtures/chain-2026-08-25-jobboard-selectors.json).
//
// Neither is derived from the thing being checked. That is the fourth way to be
// fooled by a measurement, and it cost a whole cut once: a
// stand that built "what is mounted on chain" out of the script's own
// `replaceSelectors()` agreed with itself no matter which group a selector was
// filed under.
//
// ⚠️ THE FAILURE THIS SHAPE OF CUT HAS AND THE LAST ONE DID NOT. `Replace`
// reverts "Diamond: selector not found" on a selector that is not mounted;
// `Add` reverts "Diamond: selector exists" on one that is. Either drops the
// WHOLE cut in one live transaction. The previous cut was Add-only by
// construction and could not meet the first half of that pair; this one is
// Replace-only and cannot meet the second — but only for as long as the facet
// gains no function, which is exactly what the census comparison below checks
// rather than assumes. Both reverts are demonstrated against a real diamond
// further down, so the pre-flight is known to be guarding something real.

import "./BoardsFixture.sol";
import {LegacyApplyWriter} from "./JobBoardApplicantGate.t.sol";
import "../src/RegistryFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/TreasuryLinkFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {UpgradeJobBoardApplicantGate} from "../script/UpgradeJobBoardApplicantGate.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

contract JobBoardApplicantGateUpgradeTest is BoardsFixture {
    UpgradeJobBoardApplicantGate upgrade;

    /// The census, and the things it is held to before it is believed.
    string constant CENSUS_PATH = "test/fixtures/chain-2026-08-25-jobboard-selectors.json";
    address constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;

    /// Read off the chain on 25 August 2026 and written down by a person, so
    /// that a facet which silently grows or loses a function stops here instead
    /// of at the signature.
    uint256 constant CHAIN_FACETS      = 13;

    /// ⚠️ ELEVEN CONSTANTS WERE DELETED HERE ON 14 SEPTEMBER 2026, and what
    /// they were for is the finding.
    ///
    /// Nine of them said "this cut has not landed yet" and two said "my census
    /// is older than the chain". Together they were the whole expected side of
    /// one test -- `test_AFreshDeployHasTheSameShapeAsTheLiveChain` -- which
    /// asked whether a diamond built from script/DeployFull.s.sol still looked
    /// like the live one. The test was GREEN on 14 September while a
    /// from-scratch deployment would have produced a diamond with no treasury
    /// link at all: no fee split, no arbiter vault, no payroll stream.
    ///
    /// It was green because it compared the script against THIS census, taken
    /// on 25 August, plus the eleven allowances. 214 + 17 came to exactly what
    /// the script built, and both sides were nine selectors behind the chain.
    /// Every cut had answered its red by writing one more line here instead of
    /// re-reading the census. That is a ratchet turned into a budget.
    ///
    /// The test is gone; the question belongs to
    /// test/DeployFullMatchesChain.t.sol, which asks it against a census read
    /// at the CURRENT block, and to test/CensusFreshness.t.sol, which asks
    /// forge's own receipts whether a cut has been signed since that census was
    /// read. Neither has a number anybody can raise.
    ///
    /// Removing them left NOTHING in this file undefined, which is the proof
    /// they were load-bearing for exactly one lock -- the one that could not
    /// have worked.

    uint256 constant CHAIN_ROUTED      = 214;
    uint256 constant JOBBOARD_SELECTORS = 13;

    /// `applicantGeneration` is field 8 of `JobBoardStorage.Layout` — see the
    /// same constant, and the same refusal to take it on trust, in
    /// test/JobBoardApplicantGate.t.sol.
    uint256 constant SLOT_APPLICANT_GENERATION = 8;

    function _upgrade() internal returns (UpgradeJobBoardApplicantGate) {
        if (address(upgrade) == address(0)) upgrade = new UpgradeJobBoardApplicantGate();
        return upgrade;
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE INDEPENDENT ORACLES
    // ══════════════════════════════════════════════════════════════════════

    /// The three the job board grew AFTER this cut (18 September 2026, "an
    /// arbiter is not a player in the market"): `getOpenMarketItems`,
    /// `pruneClosedApplications`, `getAppliedJobIds`. By SIGNATURE TEXT, never
    /// read off the later script's lists.
    ///
    /// ⚠️ WHY THIS FILE NEEDS AN ALLOWANCE AT ALL, when its whole point was
    /// that the facet gains nothing. This cut is a RECORD: it was broadcast on
    /// 25 August 2026, and its thirteen selectors are what was mounted that
    /// day. The facet has grown since, and demanding that a 25 August record
    /// equal today's ABI is demanding that the past match the present — the
    /// same argument test/BoardFeeDeliveryUpgrade.t.sol and
    /// test/UpgradeFeeModelSelectors.t.sol already carry for other facets. The
    /// SCRIPT's own `assertReplaceListCoversTheWholeFacet` stays strict and
    /// keeps refusing, which is right: re-running it today would deploy a job
    /// board with sixteen functions and mount thirteen, shipping three dead
    /// ones.
    function _grownAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](3);
        sels[0] = bytes4(keccak256("getOpenMarketItems(address)"));
        sels[1] = bytes4(keccak256("pruneClosedApplications(address,uint256)"));
        sels[2] = bytes4(keccak256("getAppliedJobIds(address)"));
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }

    function _isIn(bytes4[] memory set, bytes4 sel) internal pure returns (bool) {
        for (uint256 i = 0; i < set.length; i++) if (set[i] == sel) return true;
        return false;
    }

    /// The allowance held to its own two conditions, so that a failure names
    /// which one broke: every selector in it is implemented by the facet today,
    /// and none of them is one this cut mounted.
    function test_TheGrowthBeyondThisCutIsRealAndCoversNothingItMounted() public {
        UpgradeJobBoardApplicantGate u = _upgrade();
        bytes4[] memory grown = _grownAfterThisCut();
        bytes4[] memory abiSels = u.artifactSelectors();
        bytes4[] memory replaced = u.replaceSelectors();
        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(_isIn(abiSels, grown[i]), "the allowance is stale: JobBoardFacet no longer implements it");
            assertFalse(_isIn(replaced, grown[i]), "the allowance covers a selector this cut REPLACED");
        }
    }

    /// The script's hand-written Replace list against solc's output for the
    /// facet. A function the facet gains and nobody mounts would otherwise ship
    /// dead: present in the ABI, routed nowhere, discovered by the first person
    /// whose button did nothing.
    function test_ReplaceListCoversExactlyTheCompiledFacet() public {
        UpgradeJobBoardApplicantGate u = _upgrade();
        // The strict version lives on in the script and still refuses; here the
        // later growth is named and added, see `_grownAfterThisCut`.
        u.assertReplaceListCoversTheWholeFacet(_concat(u.replaceSelectors(), _grownAfterThisCut()));

        assertEq(u.replaceSelectors().length, JOBBOARD_SELECTORS, "the cut no longer replaces thirteen selectors");
        assertEq(
            u.artifactSelectors().length,
            JOBBOARD_SELECTORS + _grownAfterThisCut().length,
            "the facet no longer exposes thirteen functions plus the named later growth"
        );
    }

    /// THE PROOF OF THE Replace/Add SPLIT, and the reason there is no Add group.
    ///
    /// Set equality between the list this cut carries and the set Base Sepolia
    /// says is mounted on the JobBoard facet today. Equality in both directions
    /// is what makes both halves of the pair impossible:
    ///
    ///   * nothing in the cut is unmounted -> no element belongs in `Add`, so an
    ///     empty Add group is correct rather than merely convenient;
    ///   * nothing mounted is missing from the cut -> no selector is left
    ///     pointing at a facet that no longer implements it.
    function test_EveryReplacedSelectorIsMountedOnTheLiveChainAndNothingElseIs() public {
        bytes4[] memory mounted = _jobBoardCensus();
        assertEq(mounted.length, JOBBOARD_SELECTORS, "the census does not hold thirteen JobBoard selectors");

        bytes4[] memory sels = _upgrade().replaceSelectors();
        assertEq(sels.length, mounted.length, "the cut and the live facet disagree on how many selectors there are");

        for (uint256 i = 0; i < sels.length; i++) {
            bool found;
            for (uint256 j = 0; j < mounted.length; j++) {
                if (sels[i] == mounted[j]) { found = true; break; }
            }
            assertTrue(
                found,
                "a selector this cut REPLACES is not mounted on the live chain - it belongs in Add, and Replace would revert"
            );
        }
        for (uint256 i = 0; i < mounted.length; i++) {
            bool found;
            for (uint256 j = 0; j < sels.length; j++) {
                if (mounted[i] == sels[j]) { found = true; break; }
            }
            assertTrue(
                found,
                "a selector mounted on the live JobBoard facet is not in this cut - it would be left pointing at the old code"
            );
        }
    }

    /// And the same claim asked of the ARTIFACT rather than of the script, so
    /// that a function added to the facet without touching the script is caught
    /// by the chain rather than by the compiler alone.
    function test_TheCompiledFacetGainsNoSelector_SoTheAddGroupIsEmpty() public {
        bytes4[] memory fromArtifact = _upgrade().artifactSelectors();
        bytes4[] memory mounted = _jobBoardCensus();

        for (uint256 i = 0; i < fromArtifact.length; i++) {
            // The named later growth is exactly the set that is NOT on the chain
            // yet and does need an Add group — in its own cut, not in this one.
            if (_isIn(_grownAfterThisCut(), fromArtifact[i])) continue;
            bool found;
            for (uint256 j = 0; j < mounted.length; j++) {
                if (fromArtifact[i] == mounted[j]) { found = true; break; }
            }
            assertTrue(
                found,
                "the rebuilt facet exposes a function that is not mounted on chain - that one needs an Add group"
            );
        }
    }

    /// Each of the thirteen appears exactly once in the whole diamond census,
    /// not merely somewhere in the JobBoard group. A selector that answered from
    /// two places would make "replace the JobBoard facet" an ambiguous sentence.
    function test_NoReplacedSelectorIsMountedTwiceInTheDiamond() public {
        bytes4[] memory census = _census();
        assertEq(census.length, CHAIN_ROUTED, "the census does not hold the number of selectors it claims");

        bytes4[] memory sels = _upgrade().replaceSelectors();
        for (uint256 i = 0; i < sels.length; i++) {
            uint256 seen;
            for (uint256 j = 0; j < census.length; j++) {
                if (sels[i] == census[j]) seen++;
            }
            assertEq(seen, 1, "a replaced selector is routed a number of times other than once");
        }
    }

    /// The census is only worth anything if it is the right census. The trap
    /// that actually happens is not "it is stale" — that is visible — but "an
    /// old census was reused for a NEW cut", and that passes in silence.
    function test_CensusIsTheOneTakenForThisScript() public {
        string memory json = vm.readFile(CENSUS_PATH);
        assertEq(
            vm.parseJsonString(json, ".forScript"),
            _upgrade().scriptPath(),
            "this census was taken for a DIFFERENT cut - it does not describe what is being checked"
        );
        assertEq(vm.parseJsonAddress(json, ".diamond"), CENSUS_DIAMOND, "the census was read off a different diamond");
        assertEq(vm.parseJsonUint(json, ".facetCount"), CHAIN_FACETS, "the census disagrees on the facet count");
        assertGt(vm.parseJsonUint(json, ".block"), 0, "the census header has no block number");
        assertGt(bytes(vm.parseJsonString(json, ".takenAt")).length, 0, "the census header has no date");
    }

    /// A third source for the same list: the from-scratch deploy. If the cut and
    /// the fresh deploy ever disagree about what JobBoardFacet exposes, one of
    /// the two diamonds is wrong and nothing else would say which.
    function test_TheCutAndTheFreshDeployMountTheSameThirteen() public {
        DeployFull deploy = new DeployFull();
        bytes4[] memory fromDeploy = deploy.jobBoardFacetSelectors();
        bytes4[] memory sels = _concat(_upgrade().replaceSelectors(), _grownAfterThisCut());

        assertEq(fromDeploy.length, sels.length, "DeployFull and this cut disagree on how many JobBoard selectors exist");
        for (uint256 i = 0; i < fromDeploy.length; i++) {
            bool found;
            for (uint256 j = 0; j < sels.length; j++) {
                if (fromDeploy[i] == sels[j]) { found = true; break; }
            }
            assertTrue(found, "DeployFull mounts a JobBoard selector this cut does not replace");
        }
    }
    // ⚠️ A TEST WAS REMOVED HERE ON 14 SEPTEMBER 2026, AND WHERE IT WENT
    // MATTERS MORE THAN WHAT IT SAID.
    //
    // `test_AFreshDeployHasTheSameShapeAsTheLiveChain` asked whether a diamond built from
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

    // ══════════════════════════════════════════════════════════════════════
    // THE CUT ITSELF, APPLIED TO A DIAMOND HOLDING PRE-UPGRADE JOBS
    // ══════════════════════════════════════════════════════════════════════

    function test_CutIsOneReplaceElementAndNothingElse() public {
        address facetAddr = address(0xFACE7);
        IDiamondCut.FacetCut[] memory cuts = _upgrade().buildCuts(facetAddr);

        assertEq(cuts.length, 1, "the cut must be a single element - nothing is added and nothing removed");
        assertEq(cuts[0].facetAddress, facetAddr, "the element points at the facet it was handed");
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace, "the element must be Replace");
        assertEq(cuts[0].functionSelectors.length, JOBBOARD_SELECTORS, "the element carries all thirteen selectors");
    }

    function test_PreFlightPassesAndTheCutLandsWithoutLosingApplicants() public {
        UpgradeJobBoardApplicantGate u = _upgrade();
        _seedPreUpgradeBoard();

        bytes4[] memory sels = u.replaceSelectors();

        // Pre-flight, as run() calls it — with the growth this cut predates
        // named and added, see `_grownAfterThisCut`. The script's own version
        // stays strict and still refuses; this is the test admitting that the
        // facet has three functions more than a 25 August record can mount.
        u.assertReplaceListCoversTheWholeFacet(_concat(sels, _grownAfterThisCut()));
        address previousFacet = u.assertAllMountedOnOneFacet(sels, address(diamond));
        u.assertNothingIsLeftBehind(sels, previousFacet, address(diamond));

        uint256 routedBefore = _routed();
        uint256 facetsBefore = IDiamondLoupe(address(diamond)).facetAddresses().length;
        UpgradeJobBoardApplicantGate.StorageSnapshot memory before = u.snapshotBoard(address(diamond));

        // The scene is only worth running if there is something to lose.
        assertEq(before.totalJobs, 2, "the seeded board does not hold two jobs");
        assertEq(before.totalApplicants, 1, "the seeded board does not hold a pre-upgrade applicant");

        JobBoardFacet fresh = new JobBoardFacet();
        IDiamondCut(address(diamond)).diamondCut(u.buildCuts(address(fresh)), address(0), "");

        // Post-flight, exactly as run() calls it.
        u.assertRouted(sels, address(fresh), address(diamond));
        u.assertStorageContinuity(before, u.snapshotBoard(address(diamond)));
        u.assertUnpostedIdIsRefused(address(diamond));

        assertEq(_routed(), routedBefore, "a Replace moved the routed-selector count");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, facetsBefore,
            "a Replace changed the facet count"
        );
        assertEq(
            IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousFacet).length, 0,
            "the old facet still holds selectors after the Replace"
        );

        // And the applicant of the pre-upgrade job is still there by name, not
        // merely by count.
        address[] memory applicants = JobBoardFacet(address(diamond)).getApplicants(0);
        assertEq(applicants.length, 1, "the pre-upgrade job lost its applicant across the cut");
        assertEq(applicants[0], executor, "the pre-upgrade job's applicant changed across the cut");
    }

    /// The pre-flight has to REFUSE when the chain is not in the shape the cut
    /// assumes. A selector that is not mounted is the realistic way to get
    /// there: a facet that gained a function since the census was taken.
    function test_PreFlightRefusesWhenASelectorIsNotMounted() public {
        UpgradeJobBoardApplicantGate u = _upgrade();
        bytes4[] memory sels = u.replaceSelectors();

        // Unmount one of them, which is what "this one belongs in Add" looks
        // like from the loupe's side.
        bytes4[] memory one = new bytes4[](1);
        one[0] = JobBoardFacet.getJobFeeHeld.selector;
        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, one);
        IDiamondCut(address(diamond)).diamondCut(remove, address(0), "");

        vm.expectRevert(
            bytes("pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert")
        );
        u.assertAllMountedOnOneFacet(sels, address(diamond));
    }

    /// And the diamond itself refuses, with its own message — proof that the
    /// pre-flight guards a real failure rather than an imagined one. This is the
    /// half of the Replace/Add pair that this cut can actually meet.
    function test_ADiamondRejectsAReplaceOfAnUnmountedSelector() public {
        bytes4[] memory one = new bytes4[](1);
        one[0] = JobBoardFacet.getJobFeeHeld.selector;
        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, one);
        IDiamondCut(address(diamond)).diamondCut(remove, address(0), "");

        // ⚠️ Built BEFORE the expectation is armed: `vm.expectRevert` arms the
        // NEXT call, and `upgrade.buildCuts(...)` is itself an external call to
        // the script contract.
        IDiamondCut.FacetCut[] memory cuts = _upgrade().buildCuts(address(new JobBoardFacet()));
        vm.expectRevert(bytes("Diamond: selector not found"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    /// The other half of the pair, on the same diamond, so that the reason this
    /// cut files everything under Replace is demonstrated and not asserted: an
    /// Add of a mounted selector reverts too.
    function test_ADiamondRejectsAnAddOfAMountedSelector() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            address(new JobBoardFacet()),
            IDiamondCut.FacetCutAction.Add,
            _upgrade().replaceSelectors()
        );

        vm.expectRevert(bytes("Diamond: selector exists"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    /// The rollback path, proved rather than described: the thirteen selectors
    /// go back to the facet they came from and the board still reads.
    function test_RollbackPointsTheSelectorsBackAtTheOldFacet() public {
        UpgradeJobBoardApplicantGate u = _upgrade();
        _seedPreUpgradeBoard();

        bytes4[] memory sels = u.replaceSelectors();
        address previousFacet = u.assertAllMountedOnOneFacet(sels, address(diamond));

        JobBoardFacet fresh = new JobBoardFacet();
        IDiamondCut(address(diamond)).diamondCut(u.buildCuts(address(fresh)), address(0), "");

        IDiamondCut.FacetCut[] memory undo = new IDiamondCut.FacetCut[](1);
        undo[0] = IDiamondCut.FacetCut(previousFacet, IDiamondCut.FacetCutAction.Replace, sels);
        IDiamondCut(address(diamond)).diamondCut(undo, address(0), "");

        u.assertRouted(sels, previousFacet, address(diamond));
        assertEq(JobBoardFacet(address(diamond)).totalJobs(), 2, "the board did not survive the rollback");
    }

    // ══════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════

    function _routed() internal view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(diamond)).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    /// Puts the fixture's diamond into the shape Base Sepolia is in before the
    /// cut: two jobs, and one applicant recorded the way the OLD facet recorded
    /// it — in generation 0, the pre-upgrade namespace.
    ///
    /// The writer facet is mounted for the seeding and unmounted again, so the
    /// diamond the cut is applied to holds exactly the selectors it would hold
    /// on chain.
    function _seedPreUpgradeBoard() internal {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 first = JobBoardFacet(address(diamond)).mintJob("One", "d", AMOUNT, DEADLINE, TERMS, REGION);
        uint256 second = JobBoardFacet(address(diamond)).mintJob("Two", "d", AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
        assertEq(first, 0, "the first posting must be job 0");
        assertEq(second, 1, "the second posting must be job 1");

        LegacyApplyWriter writer = new LegacyApplyWriter();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = LegacyApplyWriter.legacyApply.selector;
        IDiamondCut.FacetCut[] memory mount = new IDiamondCut.FacetCut[](1);
        mount[0] = IDiamondCut.FacetCut(address(writer), IDiamondCut.FacetCutAction.Add, sels);
        IDiamondCut(address(diamond)).diamondCut(mount, address(0), "");

        // Job 0 becomes a job posted before this upgrade: generation 0, and an
        // applicant in the tables the old code wrote to.
        bytes32 slot = keccak256(
            abi.encode(uint256(0), bytes32(uint256(JobBoardStorage.POSITION) + SLOT_APPLICANT_GENERATION))
        );
        assertEq(
            uint256(vm.load(address(diamond), slot)), 1,
            "generation slot offset drifted - minting did not write 1 where this test looks"
        );
        vm.store(address(diamond), slot, bytes32(uint256(0)));
        LegacyApplyWriter(address(diamond)).legacyApply(0, executor);

        IDiamondCut.FacetCut[] memory unmount = new IDiamondCut.FacetCut[](1);
        unmount[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, sels);
        IDiamondCut(address(diamond)).diamondCut(unmount, address(0), "");
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

    function _census() internal view returns (bytes4[] memory out) {
        return _selectorsAt(".selectors", ".count");
    }

    function _jobBoardCensus() internal view returns (bytes4[] memory out) {
        return _selectorsAt(".jobBoardSelectors", ".jobBoardCount");
    }

    function _selectorsAt(string memory listKey, string memory countKey)
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
}
