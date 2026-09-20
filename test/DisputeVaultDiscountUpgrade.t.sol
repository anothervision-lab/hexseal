// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeDisputeVaultDiscount.s.sol — the diamondCut that
// replaces both arbitration facets and adds three selectors, carrying decision
// 54 (the arbiter bank takes three dollars off a dispute top-up) into the chain.
//
// ⚠️ WHY A STAND AT ALL, WHEN THE SCRIPT HAS A DRY RUN. A dry run proves the
// script survives TODAY'S chain. It cannot prove the script survives the chain
// it will meet at the moment somebody signs, and it cannot be run in CI at all —
// it needs a network and an RPC key. Everything below runs offline, and the
// questions that decide whether the cut lands or reverts are answered from
// sources this file does not own:
//
//   * "do the lists cover the facets" — the expected side is solc's own
//     `methodIdentifiers`, read out of the build artifacts, not the lists in the
//     script;
//   * "is every Replace selector mounted, is anything else on those facets, and
//     are the three Add selectors mounted nowhere" — the expected side is a
//     census read off Base Sepolia and committed as data
//     (test/fixtures/chain-2026-08-29-arbiter-discount-selectors.json).
//
// Neither is derived from the thing being checked. That is the fourth way to be
// fooled by a measurement, and it cost a whole cut once: a
// stand that built "what is mounted on chain" out of the script's own
// `registryReplaceSelectors()` agreed with itself no matter which group a
// selector was filed under.
//
// ⚠️ THIS CUT MEETS BOTH HALVES OF THE PAIR. `Replace` reverts "Diamond:
// selector not found" on a selector that is not mounted; `Add` reverts "Diamond:
// selector exists" on one that is. Ninety-two selectors are filed under Replace
// and three under Add, across TWO facet addresses, so a selector in the wrong
// group drops the whole cut in a single live transaction after two facets have
// already been paid for. Both halves are demonstrated below against a real
// diamond, not asserted.
//
// ⚠️ AND A THIRD MISTAKE THIS CUT CAN MAKE THAT THE GOVERNANCE CUT COULD NOT:
// filing an Add selector under the WRONG FACET. `getDisputeSubsidy(address)`
// belongs to the accountability facet's Add group; moved to the registry's, the
// cut would LAND — both groups are unmounted, so nothing reverts — and the
// function would then revert on every call for ever, because the registry's code
// does not contain it. Only the artifact comparison catches that one, and it has
// its own test below.

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/Agreement.sol";
import "../src/AgreementDeployer.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/TreasuryLinkFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {MockUSDCB} from "./BoardsFixture.sol";
import {UpgradeDisputeVaultDiscount} from "../script/UpgradeDisputeVaultDiscount.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterSplitRig} from "./ArbiterSplitRig.sol";

/// A registry facet whose discount is a DIFFERENT number — the shape the diamond
/// would be in if the Add group landed on stale code. Nothing but a behavioural
/// read can tell: the selector is routed either way.
contract StaleDiscountFacet {
    function getDisputeDiscount() external pure returns (uint256) { return 1; }
}

contract DisputeVaultDiscountUpgradeTest is Test, ArbiterSplitRig {
    UpgradeDisputeVaultDiscount upgrade;
    DeployFull deploy;
    DiamondProxy diamond;
    MockUSDCB usdc;

    address constant ARBITER = address(0xA11CE);
    address constant CHIEF   = address(0xB0B);
    address constant FEE_RECIPIENT = address(0xFEE);

    /// The census, and the things it is held to before it is believed.
    string constant CENSUS_PATH = "test/fixtures/chain-2026-08-29-arbiter-discount-selectors.json";
    address constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;

    /// Read off the chain on 29 August 2026 and written down by a person, so
    /// that a facet which silently grows or loses a function stops here instead
    /// of at the signature.
    uint256 constant CHAIN_FACETS             = 13;

    uint256 constant CHAIN_ROUTED             = 218;
    uint256 constant REGISTRY_SELECTORS       = 57;
    uint256 constant ACCOUNTABILITY_SELECTORS = 35;
    uint256 constant ADDED_REGISTRY           = 2;
    uint256 constant ADDED_ACCOUNTABILITY     = 1;

    /// What THIS cut alone puts on a diamond, as opposed to what a fresh deploy
    /// carries beyond the chain. The two used to be the same number and stopped
    /// being the same number the moment a fourth cut queued up behind this one,
    /// which is exactly the confusion worth a separate name: the rig that
    /// `_deployPreCutDiamond` builds has had EVERY extra stripped, mine
    /// included, so applying this cut to it moves the count by three and not by
    /// four.
    uint256 constant ADDED_BY_THIS_CUT = ADDED_REGISTRY + ADDED_ACCOUNTABILITY;

    /// A number from a recorded decision, copied here by a person and NOT
    /// read off the facet: the facet is the thing being checked.
    uint256 constant DISCOUNT_AFTER = 3_000_000;

    /// ⚠️ WHAT THE PAIR GREW **AFTER** THIS CUT WAS SIGNED — written by hand, by
    /// SIGNATURE TEXT, never taken from the script's own lists. The same device
    /// as `_grownAfterThisCut` in test/GovernanceHandoverUpgrade.t.sol, and for
    /// the same reason: this script ran on 29 August 2026 and its lists are a
    /// record of that transaction, while the locks below compare them with
    /// TODAY'S compiled ABI.
    ///
    ///   • withdrawAppealShare(address), getAppealShareOwed(address,address),
    ///     getAppealLedger(address), quoteAppealDeposit(address) —
    ///     17 September 2026, the appeal economics: the panel's pull, its read,
    ///     a settled appeal's ledger and the price of an appeal — and, the same
    ///     day, settleAppealDebts(uint256) and getAppealDebts(). All six on
    ///     ArbiterVaultFacet.
    ///
    /// Held to "real, and covering nothing this cut mounted" by
    /// test_TheGrowthBeyondThisCutIsRealAndCoversNothingItMounted.
    function _grownAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](8);
        sels[0] = bytes4(keccak256("withdrawAppealShare(address)"));
        sels[1] = bytes4(keccak256("getAppealShareOwed(address,address)"));
        sels[2] = bytes4(keccak256("getAppealLedger(address)"));
        sels[3] = bytes4(keccak256("quoteAppealDeposit(address)"));
        sels[4] = bytes4(keccak256("settleAppealDebts(uint256)"));
        sels[5] = bytes4(keccak256("getAppealDebts()"));
        // And the two of 18 September 2026 on the arbiter registry: item D1's
        // public door for a dead dispute claim, and the read a screen needs now
        // that the appeal quorum moves with the corps.
        sels[6] = bytes4(keccak256("abandonClaim(address)"));
        sels[7] = bytes4(keccak256("getAppealPanel(address)"));
    }

    function test_TheGrowthBeyondThisCutIsRealAndCoversNothingItMounted() public view {
        bytes4[] memory grown = _grownAfterThisCut();
        bytes4[] memory regAbi = upgrade.registryFacetAbi(); // the pair
        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(_contains(regAbi, grown[i]), "the allowance is stale: no such function in the registry pair's ABI");
            assertFalse(_contains(upgrade.registryReplaceSelectors(), grown[i]), "the allowance covers a selector this cut REPLACED");
            assertFalse(_contains(upgrade.registryAddSelectors(), grown[i]), "the allowance covers a selector this cut ADDED");
        }
    }

    function setUp() public {
        upgrade = new UpgradeDisputeVaultDiscount();
        deploy  = new DeployFull();
        usdc    = new MockUSDCB();
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
        // The Add group carries the growth queued behind this cut: the
        // compiled pair has moved on and the script may not be edited, having run.
        upgrade.assertListsCoverTheCompiledFacets(
            upgrade.registryReplaceSelectors(),
            _concat(upgrade.registryAddSelectors(), _grownAfterThisCut()),
            upgrade.accountabilityReplaceSelectors(),
            upgrade.accountabilityAddSelectors()
        );

        assertEq(upgrade.registryReplaceSelectors().length, REGISTRY_SELECTORS);
        assertEq(upgrade.registryAddSelectors().length, ADDED_REGISTRY);
        assertEq(upgrade.accountabilityReplaceSelectors().length, ACCOUNTABILITY_SELECTORS);
        assertEq(upgrade.accountabilityAddSelectors().length, ADDED_ACCOUNTABILITY);
    }

    /// THE PROOF OF THE Replace/Add SPLIT, half one: everything in a Replace
    /// group is mounted on the live chain today, and everything mounted on those
    /// two facets is in a Replace group. Set equality in both directions, per
    /// facet.
    ///
    ///   * nothing in a Replace group is unmounted -> no element belongs in Add;
    ///   * nothing mounted is missing -> no selector is left pointing at a facet
    ///     that no longer implements it.
    ///
    /// ⚠️ THIS IS THE LOCK FOR "A SELECTOR MOVED BETWEEN GROUPS". Its expected
    /// side is the census — the chain's own answer — so moving a selector from
    /// Replace to Add takes it out of the script's list without taking it out of
    /// the chain's, and the two sets stop matching. A stand that built the
    /// chain's side out of `registryReplaceSelectors()` would follow the move
    /// and stay green.
    function test_EveryReplacedSelectorIsMountedOnTheLiveChainAndNothingElseIs() public view {
        _assertSameSet(
            upgrade.registryReplaceSelectors(),
            _censusAt(".arbiterRegistrySelectors", ".arbiterRegistryCount"),
            "ArbiterRegistry"
        );
        _assertSameSet(
            upgrade.accountabilityReplaceSelectors(),
            _censusAt(".arbiterAccountabilitySelectors", ".arbiterAccountabilityCount"),
            "ArbiterAccountability"
        );
    }

    /// THE PROOF OF THE SPLIT, half two. All three Add selectors must be mounted
    /// NOWHERE in the diamond, which is a question about the whole routed list,
    /// not about one facet: `Add` reverts on a selector routed anywhere at all.
    function test_AllThreeAddedSelectorsAreMountedNowhereOnTheLiveChain() public view {
        bytes4[] memory whole = _censusAt(".selectors", ".count");
        assertEq(whole.length, CHAIN_ROUTED, "the census does not hold the number of selectors it claims");

        bytes4[] memory added = _concat(upgrade.registryAddSelectors(), upgrade.accountabilityAddSelectors());
        assertEq(
            added.length,
            ADDED_REGISTRY + ADDED_ACCOUNTABILITY,
            "this cut adds a different number of selectors than the stand expects"
        );
        for (uint256 i = 0; i < added.length; i++) {
            for (uint256 j = 0; j < whole.length; j++) {
                assertTrue(
                    added[i] != whole[j],
                    "a selector this cut ADDS is already routed on the live chain - it belongs in Replace, and Add would revert"
                );
            }
        }
    }

    /// And the same claim asked of the ARTIFACTS rather than of the script: each
    /// compiled facet must expose exactly as many functions the chain does not
    /// have as this cut adds to it. A fourth one added later without touching
    /// the script would be caught here rather than by whoever presses the button.
    function test_TheCompiledFacetsGainExactlyWhatThisCutAdds() public view {
        assertEq(
            _unmountedCount(
                upgrade.registryFacetAbi(), // the pair, see the note on registryFacetAbi()
                _censusAt(".selectors", ".count")
            ),
            ADDED_REGISTRY + _grownAfterThisCut().length,
            "the compiled ArbiterRegistryFacet gains a different number of functions than this cut adds plus what is queued behind it"
        );
        assertEq(
            _unmountedCount(
                upgrade.artifactSelectors("out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json"),
                _censusAt(".selectors", ".count")
            ),
            ADDED_ACCOUNTABILITY,
            "the compiled ArbiterAccountabilityFacet gains a different number of functions than this cut adds"
        );
    }

    /// ⚠️ THE MISTAKE ONLY THE ARTIFACT CAN CATCH. `getDisputeSubsidy(address)`
    /// filed under the registry's Add group instead of the accountability
    /// facet's would LAND: both groups are unmounted, so no `Add` reverts and
    /// the cut goes through. The function would then revert on every call for
    /// ever, because the registry's runtime code does not contain it — a live
    /// read answering nothing, discovered by whoever first opened a funded
    /// dispute.
    ///
    /// What disappears from behaviour if this is removed: nothing else in this
    /// file asks WHICH FACET an added selector belongs to. The census answers
    /// "mounted nowhere", which is true of it either way.
    function test_EachAddedSelectorIsImplementedByTheFacetItIsMountedOn() public view {
        // ⚠️ THE PAIR, NOT ONE FILE (16 September 2026). The facet this signed
        // cut mounted was split into ArbiterRegistryFacet and ArbiterVaultFacet
        // with no signature touched, so "what the compiled registry exposes" is
        // the union of the two — the same set the single facet had. Taught
        // rather than frozen: this check exists to notice a function added
        // later, and a frozen list would stop noticing.
        bytes4[] memory regAbi = upgrade.registryFacetAbi();
        bytes4[] memory accAbi =
            upgrade.artifactSelectors("out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json");

        bytes4[] memory regAdd = upgrade.registryAddSelectors();
        for (uint256 i = 0; i < regAdd.length; i++) {
            assertTrue(_contains(regAbi, regAdd[i]), "the registry Add group carries a selector the registry does not implement");
            assertFalse(_contains(accAbi, regAdd[i]), "a registry Add selector is implemented by the OTHER facet");
        }

        bytes4[] memory accAdd = upgrade.accountabilityAddSelectors();
        for (uint256 i = 0; i < accAdd.length; i++) {
            assertTrue(_contains(accAbi, accAdd[i]), "the accountability Add group carries a selector that facet does not implement");
            assertFalse(_contains(regAbi, accAdd[i]), "an accountability Add selector is implemented by the OTHER facet");
        }

        // And the one that makes this concrete rather than abstract: the subsidy
        // read is named by SIGNATURE TEXT, not taken from the script's list.
        bytes4 subsidy = bytes4(keccak256("getDisputeSubsidy(address)"));
        assertTrue(_contains(accAdd, subsidy), "getDisputeSubsidy is not in the accountability Add group");
        assertFalse(_contains(regAdd, subsidy), "getDisputeSubsidy is in the REGISTRY Add group - it would be mounted on a facet that cannot answer it");
    }

    /// The census header, before anything is read out of it. The trap worth
    /// catching is not "the census is stale" but "an old census was reused for a
    /// NEW script" — the numbers would look plausible and describe a different
    /// cut.
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

        // The reading the storage-continuity claim leans on, recorded by the
        // same pass that produced the selector lists.
        assertGt(
            vm.parseJsonUint(json, ".vaultBalance"), 0,
            "the census records an empty vault - then the continuity check proves nothing on the live chain"
        );
    }

    /// A third source for the same lists: the from-scratch deploy. If the cut
    /// and the fresh deploy ever disagree about what a facet exposes, one of the
    /// two diamonds is wrong and nothing else would say which.
    function test_TheCutAndTheFreshDeployMountTheSameSets() public view {
        // The growth queued behind this cut is added to THIS cut's side, not
        // subtracted from DeployFull's: a fresh deploy mounts what the facets
        // have today, this cut mounted what they had in August.
        _assertSameSet(
            _concat(
                _concat(upgrade.registryReplaceSelectors(), upgrade.registryAddSelectors()),
                _grownAfterThisCut()
            ),
            _concat(deploy.arbiterRegistryFacetSelectors(), deploy.arbiterVaultFacetSelectors()),
            "ArbiterRegistry vs DeployFull"
        );
        _assertSameSet(
            _concat(upgrade.accountabilityReplaceSelectors(), upgrade.accountabilityAddSelectors()),
            deploy.arbiterAccountabilityFacetSelectors(),
            "ArbiterAccountability vs DeployFull"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE SHAPE OF THE CUT
    // ══════════════════════════════════════════════════════════════════════

    function test_CutIsTwoReplacesAndTwoAdds() public view {
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(0xF00D1), address(0xF00D2));

        assertEq(cuts.length, 4, "the cut must be four elements");

        assertEq(cuts[0].facetAddress, address(0xF00D1));
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace);
        assertEq(cuts[0].functionSelectors.length, REGISTRY_SELECTORS);

        // Each Add group lands on the SAME address as its Replace — one FacetCut
        // carries one action, which is the only reason it is a separate element.
        assertEq(cuts[1].facetAddress, address(0xF00D1), "the registry's added selectors must land on the new ArbiterRegistryFacet");
        assertTrue(cuts[1].action == IDiamondCut.FacetCutAction.Add);
        assertEq(cuts[1].functionSelectors.length, ADDED_REGISTRY);

        assertEq(cuts[2].facetAddress, address(0xF00D2));
        assertTrue(cuts[2].action == IDiamondCut.FacetCutAction.Replace);
        assertEq(cuts[2].functionSelectors.length, ACCOUNTABILITY_SELECTORS);

        assertEq(cuts[3].facetAddress, address(0xF00D2), "the subsidy read must land on the ACCOUNTABILITY facet, which implements it");
        assertTrue(cuts[3].action == IDiamondCut.FacetCutAction.Add);
        assertEq(cuts[3].functionSelectors.length, ADDED_ACCOUNTABILITY);
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE CUT ITSELF, APPLIED TO A DIAMOND HOLDING A LIVE CORPS AND A VAULT
    // ══════════════════════════════════════════════════════════════════════

    function test_PreFlightPassesAndTheCutLandsWithoutLosingTheVault() public {
        _seedArbitration();

        bytes4[] memory regSels = upgrade.registryReplaceSelectors();
        bytes4[] memory regAdd  = upgrade.registryAddSelectors();
        bytes4[] memory accSels = upgrade.accountabilityReplaceSelectors();
        bytes4[] memory accAdd  = upgrade.accountabilityAddSelectors();

        // Pre-flight, exactly as run() calls it — bar the growth queued behind
        // this cut, which rides with the Add group for the reason given in
        // test_ListsCoverExactlyTheCompiledFacets.
        upgrade.assertListsCoverTheCompiledFacets(regSels, _concat(regAdd, _grownAfterThisCut()), accSels, accAdd);
        address previousRegistry = upgrade.assertAllMountedOnOneFacet(regSels, address(diamond));
        address previousAccountability = upgrade.assertAllMountedOnOneFacet(accSels, address(diamond));
        assertTrue(previousRegistry != previousAccountability, "the two groups sit on the same facet");
        upgrade.assertNothingIsLeftBehind(regSels, previousRegistry, address(diamond));
        upgrade.assertNothingIsLeftBehind(accSels, previousAccountability, address(diamond));
        upgrade.assertAddGroupIsUnmountedAnywhere(regAdd, address(diamond));
        upgrade.assertAddGroupIsUnmountedAnywhere(accAdd, address(diamond));

        uint256 routedBefore = _routed();
        uint256 facetsBefore = IDiamondLoupe(address(diamond)).facetAddresses().length;
        UpgradeDisputeVaultDiscount.StorageSnapshot memory before =
            upgrade.snapshotArbitration(address(diamond));

        // The scene is only worth running if there is something to lose.
        assertEq(before.arbiterCount, 1, "the seeded corps holds no arbiter");
        assertEq(before.chiefArbiter, CHIEF, "the seeded diamond has no chief");
        assertGt(before.vaultBalance, 0, "the seeded vault is empty");
        uint256 heldBefore = usdc.balanceOf(address(diamond));

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()),
                address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        // ── Post-flight, part one: THE SHAPE, exactly as run() checks it, and
        // checked BEFORE the later split is played out below. This is the
        // diamond as Base Sepolia stood the day this cut was signed.
        upgrade.assertRouted(regSels, IDiamondLoupe(address(diamond)).facetAddress(regSels[0]), address(diamond));
        upgrade.assertRouted(accSels, IDiamondLoupe(address(diamond)).facetAddress(accSels[0]), address(diamond));

        assertEq(usdc.balanceOf(address(diamond)), heldBefore, "the diamond's USDC moved across a cut");
        assertEq(
            _routed(),
            routedBefore + ADDED_REGISTRY + ADDED_ACCOUNTABILITY,
            "the routed count moved by something other than the Add groups"
        );
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, facetsBefore,
            "the facet count moved - the old facets should have been emptied, not unmounted"
        );
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousRegistry).length, 0);
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousAccountability).length, 0);

        // ⚠️ AND THEN THE SEPTEMBER SPLIT IS PLAYED OUT (16 September 2026).
        // The cut above is the one that was SIGNED: it deploys one
        // `new ArbiterRegistryFacet()` and mounts its whole group on it. It
        // cannot know about a split made three weeks later, and it is not
        // rewritten — it is the record of what went on chain. But the doors read
        // below moved to ArbiterVaultFacet, so until the split lands they are
        // routed at code that does not implement them. That is the chain's real
        // state between the two cuts, and a test reading a moved door plays the
        // move out first — as ArbiterTwoFacetBench._applyTask45MoveAfterLegacyCut
        // does for the August split.
        _replayArbiterVaultSplit(address(diamond));

        // ── Post-flight, part two: THE ANSWERS.
        upgrade.assertStorageContinuity(before, upgrade.snapshotArbitration(address(diamond)));
        upgrade.assertTheDiscountAnswers(address(diamond), DISCOUNT_AFTER);
        upgrade.assertTheSubsidyDoorAnswersAndIsEmpty(address(diamond));

        // And the door the cut is FOR actually works afterwards, which no
        // selector count can say: the owner can move the number, and the read
        // follows it.
        ArbiterVaultFacet(address(diamond)).setDisputeDiscount(1_500_000);
        assertEq(
            ArbiterVaultFacet(address(diamond)).getDisputeDiscount(), 1_500_000,
            "setDisputeDiscount did not move the number"
        );
        // Zero reads back as the default, which is the shape chosen for it
        // and the reason "no discount at all" has to be written as 1.
        ArbiterVaultFacet(address(diamond)).setDisputeDiscount(0);
        assertEq(
            ArbiterVaultFacet(address(diamond)).getDisputeDiscount(), DISCOUNT_AFTER,
            "a zeroed discount does not read back as the default"
        );
    }

    /// The pre-flight has to REFUSE when the chain is not in the shape the cut
    /// assumes. A selector that is not mounted is the realistic way to get
    /// there: a facet that gained a function since the census was taken, or a
    /// selector filed in the wrong group.
    function test_PreFlightRefusesWhenAReplacedSelectorIsNotMounted() public {
        _unmount(ArbiterVaultFacet.getVaultBalance.selector);

        // ⚠️ Fetched BEFORE the expectation is armed: `vm.expectRevert` arms the
        // NEXT call, and `upgrade.registryReplaceSelectors()` is itself an
        // external call to the script contract.
        bytes4[] memory sels = upgrade.registryReplaceSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert")
        );
        upgrade.assertAllMountedOnOneFacet(sels, address(diamond));
    }

    /// The same refusal for the other facet, so a mistake filed against
    /// ArbiterAccountabilityFacet is not caught only by luck.
    function test_PreFlightRefusesWhenAnAccountabilitySelectorIsNotMounted() public {
        _unmount(ArbiterAccountabilityFacet.getArbiterStanding.selector);

        bytes4[] memory sels = upgrade.accountabilityReplaceSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert")
        );
        upgrade.assertAllMountedOnOneFacet(sels, address(diamond));
    }

    /// The mirror refusal: an Add selector that is already routed.
    function test_PreFlightRefusesWhenAnAddedSelectorIsAlreadyMounted() public {
        _mountOne(ArbiterVaultFacet.getDisputeDiscount.selector, address(new ArbiterRegistryFacet()));

        bytes4[] memory added = upgrade.registryAddSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert")
        );
        upgrade.assertAddGroupIsUnmountedAnywhere(added, address(diamond));
    }

    /// And the same for the accountability facet's one-element Add group, which
    /// is the easiest thing in this cut to forget about entirely.
    function test_PreFlightRefusesWhenTheSubsidyReadIsAlreadyMounted() public {
        _mountOne(ArbiterAccountabilityFacet.getDisputeSubsidy.selector, address(new ArbiterAccountabilityFacet()));

        bytes4[] memory added = upgrade.accountabilityAddSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert")
        );
        upgrade.assertAddGroupIsUnmountedAnywhere(added, address(diamond));
    }

    /// And the refusal that catches a facet which grew a function nobody
    /// mounted: the previous facet holds more selectors than the cut carries.
    function test_PreFlightRefusesWhenTheOldFacetHoldsSomethingTheCutDoesNotCarry() public {
        _mountOne(
            ArbiterVaultFacet.getDisputeDiscount.selector,
            _hostOf(ArbiterRegistryFacet.isDaoActive.selector)
        );

        bytes4[] memory sels = upgrade.registryReplaceSelectors();
        address host = _hostOf(ArbiterRegistryFacet.isDaoActive.selector);
        vm.expectRevert(
            bytes("pre-flight: a facet being replaced holds a different number of selectors than this cut carries")
        );
        upgrade.assertNothingIsLeftBehind(sels, host, address(diamond));
    }

    /// The diamond itself refuses, with its own message — proof that the
    /// pre-flight guards a real failure rather than an imagined one.
    function test_ADiamondRejectsAReplaceOfAnUnmountedSelector() public {
        _unmount(ArbiterVaultFacet.getVaultBalance.selector);

        // ⚠️ Built BEFORE the expectation is armed: `vm.expectRevert` arms the
        // NEXT call, and `buildCuts(...)` is itself an external call.
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(
            address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
        );
        vm.expectRevert(bytes("Diamond: selector not found"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    /// The other half of the pair, on the same diamond, so that the reason the
    /// three new selectors are filed under Add is demonstrated and not asserted.
    function test_ADiamondRejectsAnAddOfAMountedSelector() public {
        _mountOne(ArbiterAccountabilityFacet.getDisputeSubsidy.selector, address(new ArbiterAccountabilityFacet()));

        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(
            address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
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

    // ══════════════════════════════════════════════════════════════════════
    // THE BEHAVIOURAL GUARDS
    // ══════════════════════════════════════════════════════════════════════

    /// The discount does not exist before the cut and answers after it. Asked of
    /// the diamond rather than of the script's list.
    function test_TheDiscountAnswersOnlyAfterTheCut() public {
        (bool okBefore,) = address(diamond).staticcall(
            abi.encodeWithSelector(ArbiterVaultFacet.getDisputeDiscount.selector)
        );
        assertFalse(okBefore, "getDisputeDiscount already answers before the cut");

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()),
                address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        // ⚠️ AND THEN THE SEPTEMBER SPLIT IS PLAYED OUT (16 September 2026).
        // The cut above is the one that was SIGNED: it deploys one
        // `new ArbiterRegistryFacet()` and mounts its whole group on it. It
        // cannot know about a split made three weeks later, and it is not
        // rewritten — it is the record of what went on chain. But the doors read
        // below moved to ArbiterVaultFacet, so until the split lands they are
        // routed at code that does not implement them. That is the chain's real
        // state between the two cuts, and a test reading a moved door plays the
        // move out first — as ArbiterTwoFacetBench._applyTask45MoveAfterLegacyCut
        // does for the August split.
        _replayArbiterVaultSplit(address(diamond));

        upgrade.assertTheDiscountAnswers(address(diamond), DISCOUNT_AFTER);
        upgrade.assertTheSubsidyDoorAnswersAndIsEmpty(address(diamond));
    }

    /// ⚠️ THE THING A MOUNTED SELECTOR CANNOT SAY. `getDisputeDiscount()` being
    /// routed proves the Add landed; it does not prove the code behind it is the
    /// code this cut carried. This is the scene that catches stale code: the
    /// selector is routed, the shape is right, the number is wrong.
    function test_TheDiscountGuardCatchesStaleCodeBehindALandedSelector() public {
        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()),
                address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        // ⚠️ AND THEN THE SEPTEMBER SPLIT IS PLAYED OUT (16 September 2026).
        // The cut above is the one that was SIGNED: it deploys one
        // `new ArbiterRegistryFacet()` and mounts its whole group on it. It
        // cannot know about a split made three weeks later, and it is not
        // rewritten — it is the record of what went on chain. But the doors read
        // below moved to ArbiterVaultFacet, so until the split lands they are
        // routed at code that does not implement them. That is the chain's real
        // state between the two cuts, and a test reading a moved door plays the
        // move out first — as ArbiterTwoFacetBench._applyTask45MoveAfterLegacyCut
        // does for the August split.
        _replayArbiterVaultSplit(address(diamond));

        upgrade.assertTheDiscountAnswers(address(diamond), DISCOUNT_AFTER);

        // Now put a different number behind the same selector, and nothing else.
        // Shape unchanged, count unchanged, behaviour wrong.
        bytes4[] memory one = new bytes4[](1);
        one[0] = ArbiterVaultFacet.getDisputeDiscount.selector;
        IDiamondCut.FacetCut[] memory stale = new IDiamondCut.FacetCut[](1);
        stale[0] = IDiamondCut.FacetCut(address(new StaleDiscountFacet()), IDiamondCut.FacetCutAction.Replace, one);
        IDiamondCut(address(diamond)).diamondCut(stale, address(0), "");

        assertEq(_routed(), CHAIN_ROUTED + ADDED_BY_THIS_CUT, "the sabotage changed the routed count - it is meant not to");

        vm.expectRevert(bytes("post-flight: getDisputeDiscount() is not the number this cut carries"));
        upgrade.assertTheDiscountAnswers(address(diamond), DISCOUNT_AFTER);
    }

    /// ⚠️ THE CLAIM THE CONTINUITY CHECK IS ACTUALLY FOR, AND THE ONLY SCENE
    /// THAT MAKES IT MEAN ANYTHING. This work appended two fields to
    /// `ArbiterRegistryStorage.Data`. Appended in the wrong place, one of them
    /// lands on a live slot — and a corps that had silently lost its vault would
    /// look, from every other angle, exactly healthy: same facets, same selector
    /// count, same everything a loupe can see.
    ///
    /// Nothing on this rig can APPEND a field wrongly, so the reading is moved
    /// instead: a facet that answers a different vault balance stands in for a
    /// layout that shifted. The question under test is whether the guard says so.
    ///
    /// What disappears from behaviour if this is removed: `assertStorageContinuity`
    /// is only ever called on a diamond where nothing moved, so every one of its
    /// eleven requires would be unreachable and the whole check would be a
    /// paragraph rather than a lock.
    function test_TheContinuityCheckCatchesAVaultThatMovedAcrossTheCut() public {
        _seedArbitration();
        UpgradeDisputeVaultDiscount.StorageSnapshot memory before =
            upgrade.snapshotArbitration(address(diamond));
        assertGt(before.vaultBalance, 0, "the seeded vault is empty - the scene proves nothing");

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        // ⚠️ AND THEN THE SEPTEMBER SPLIT IS PLAYED OUT (16 September 2026).
        // The cut above is the one that was SIGNED: it deploys one
        // `new ArbiterRegistryFacet()` and mounts its whole group on it. It
        // cannot know about a split made three weeks later, and it is not
        // rewritten — it is the record of what went on chain. But the doors read
        // below moved to ArbiterVaultFacet, so until the split lands they are
        // routed at code that does not implement them. That is the chain's real
        // state between the two cuts, and a test reading a moved door plays the
        // move out first — as ArbiterTwoFacetBench._applyTask45MoveAfterLegacyCut
        // does for the August split.
        _replayArbiterVaultSplit(address(diamond));

        // Unsabotaged, it passes.
        upgrade.assertStorageContinuity(before, upgrade.snapshotArbitration(address(diamond)));

        bytes4[] memory one = new bytes4[](1);
        one[0] = ArbiterVaultFacet.getVaultBalance.selector;
        IDiamondCut.FacetCut[] memory moved = new IDiamondCut.FacetCut[](1);
        moved[0] = IDiamondCut.FacetCut(address(new MovedVaultFacet()), IDiamondCut.FacetCutAction.Replace, one);
        IDiamondCut(address(diamond)).diamondCut(moved, address(0), "");

        assertEq(_routed(), CHAIN_ROUTED + ADDED_BY_THIS_CUT, "the sabotage changed the routed count - it is meant not to");

        UpgradeDisputeVaultDiscount.StorageSnapshot memory afterCut =
            upgrade.snapshotArbitration(address(diamond));
        vm.expectRevert(
            bytes("post-flight: the arbiter vault moved across the cut - the two appended fields may have landed on a live slot")
        );
        upgrade.assertStorageContinuity(before, afterCut);
    }

    // ══════════════════════════════════════════════════════════════════════
    // ROLLBACK
    // ══════════════════════════════════════════════════════════════════════

    /// The rollback path, proved rather than described: the ninety-two go back
    /// to the facets they came from, the three added ones are removed, and the
    /// vault still reads.
    function test_RollbackRestoresTheShapeAndTheVaultStillReads() public {
        _seedArbitration();

        bytes4[] memory regSels = upgrade.registryReplaceSelectors();
        bytes4[] memory regAdd  = upgrade.registryAddSelectors();
        bytes4[] memory accSels = upgrade.accountabilityReplaceSelectors();
        bytes4[] memory accAdd  = upgrade.accountabilityAddSelectors();

        address previousRegistry = upgrade.assertAllMountedOnOneFacet(regSels, address(diamond));
        address previousAccountability = upgrade.assertAllMountedOnOneFacet(accSels, address(diamond));
        uint256 routedBefore = _routed();
        uint256 vaultBefore = ArbiterVaultFacet(address(diamond)).getVaultBalance();

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        // The rollback's own guard passes on a diamond where nothing was funded.
        address[] memory none = new address[](0);
        upgrade.assertNoBankShareIsStranded(address(diamond), none);

        IDiamondCut.FacetCut[] memory undo = new IDiamondCut.FacetCut[](3);
        undo[0] = IDiamondCut.FacetCut(previousRegistry, IDiamondCut.FacetCutAction.Replace, regSels);
        undo[1] = IDiamondCut.FacetCut(previousAccountability, IDiamondCut.FacetCutAction.Replace, accSels);
        undo[2] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, _concat(regAdd, accAdd));
        IDiamondCut(address(diamond)).diamondCut(undo, address(0), "");

        upgrade.assertRouted(regSels, previousRegistry, address(diamond));
        upgrade.assertRouted(accSels, previousAccountability, address(diamond));
        upgrade.assertAddGroupIsUnmountedAnywhere(regAdd, address(diamond));
        upgrade.assertAddGroupIsUnmountedAnywhere(accAdd, address(diamond));
        assertEq(_routed(), routedBefore, "the rollback did not restore the pre-cut shape");
        assertEq(
            ArbiterVaultFacet(address(diamond)).getVaultBalance(), vaultBefore,
            "the vault did not survive the rollback"
        );
        assertEq(
            ArbiterVaultFacet(address(diamond)).getArbiters().length, 1,
            "the corps did not survive the rollback"
        );
    }

    /// ⚠️ THE ONE STATE THE ROLLBACK CANNOT CARRY BACK, and the guard that
    /// refuses rather than stranding it. A dispute funded under the new code has
    /// its bank share booked in an appended field; the old code neither reads
    /// that field nor gives it back, so `vaultBalance` would stay short for ever.
    ///
    /// The scene is built by mounting a stub that CLAIMS a share, because
    /// reaching a real one needs a whole disputed deal — and the thing under
    /// test is the guard's reaction to a non-zero answer, not how the number got
    /// there.
    function test_RollbackRefusesWhenANamedAgreementStillHoldsABankShare() public {
        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        bytes4[] memory one = new bytes4[](1);
        one[0] = ArbiterAccountabilityFacet.getDisputeSubsidy.selector;
        IDiamondCut.FacetCut[] memory stub = new IDiamondCut.FacetCut[](1);
        stub[0] = IDiamondCut.FacetCut(address(new FundedSubsidyFacet()), IDiamondCut.FacetCutAction.Replace, one);
        IDiamondCut(address(diamond)).diamondCut(stub, address(0), "");

        address[] memory named = new address[](1);
        named[0] = address(0xDEA1);
        vm.expectRevert(
            bytes("rollback: a named agreement holds a booked bank share - undoing would strand it and leave the vault short")
        );
        upgrade.assertNoBankShareIsStranded(address(diamond), named);
    }

    // ══════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════

    function _routed() internal view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(diamond)).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    function _hostOf(bytes4 sel) internal view returns (address) {
        return IDiamondLoupe(address(diamond)).facetAddress(sel);
    }

    function _unmount(bytes4 sel) internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = sel;
        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, one);
        IDiamondCut(address(diamond)).diamondCut(remove, address(0), "");
    }

    function _mountOne(bytes4 sel, address facet) internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = sel;
        IDiamondCut.FacetCut[] memory add = new IDiamondCut.FacetCut[](1);
        add[0] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, one);
        IDiamondCut(address(diamond)).diamondCut(add, address(0), "");
    }

    function _contains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) if (haystack[i] == needle) return true;
        return false;
    }

    function _unmountedCount(bytes4[] memory candidates, bytes4[] memory mounted)
        internal pure returns (uint256 n)
    {
        for (uint256 i = 0; i < candidates.length; i++) {
            if (!_contains(mounted, candidates[i])) n++;
        }
    }

    /// Puts the rig into the shape the live diamond is in: a seated arbiter, a
    /// chief, a funded vault and a floor. The cut is then applied on top of a
    /// live arbitration namespace rather than an empty one, which is the only
    /// way the storage-continuity claim means anything — this work APPENDED two
    /// fields to `ArbiterRegistryStorage.Data`.
    function _seedArbitration() internal {
        ArbiterRegistryFacet(address(diamond)).addArbiter(ARBITER);
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(7_000_000);

        usdc.mint(address(this), 11_000_000);
        usdc.approve(address(diamond), 11_000_000);
        ArbiterVaultFacet(address(diamond)).fundVault(11_000_000);
    }

    /// The diamond as Base Sepolia stands TODAY — before this cut.
    ///
    /// Built the honest way round: a full DeployFull-shaped diamond (which,
    /// since this work, already mounts the three new selectors) and then the
    /// difference against the CENSUS is removed. Which selectors to remove is
    /// therefore decided by what the chain answered, not by this cut's own Add
    /// lists — a rig built from the script's own list would agree with the
    /// script no matter which group anything was filed under, and that is the
    /// fourth way to be fooled by a measurement.
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

    /// Registry and factory, seeded so `fundVault` has a token to move.
    function _initDiamond() internal {
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), FEE_RECIPIENT, address(0xDEAD), address(diamond), address(agDeployer)
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

/// Answers a vault balance that is not the one the diamond holds — the shape a
/// misplaced storage append would leave behind, without any way to actually
/// misplace one on a rig built from a single source.
contract MovedVaultFacet {
    function getVaultBalance() external pure returns (uint256) { return 1; }
}

/// Answers a non-zero bank share for any agreement — the shape the diamond is in
/// after somebody has funded a discounted dispute, without having to build a
/// whole disputed deal to get there.
contract FundedSubsidyFacet {
    function getDisputeSubsidy(address) external pure returns (uint256) { return 3_000_000; }
}
