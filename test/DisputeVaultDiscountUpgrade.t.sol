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
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {MockUSDCB} from "./BoardsFixture.sol";
import {UpgradeDisputeVaultDiscount} from "../script/UpgradeDisputeVaultDiscount.s.sol";

/// A registry facet whose discount is a DIFFERENT number — the shape the diamond
/// would be in if the Add group landed on stale code. Nothing but a behavioural
/// read can tell: the selector is routed either way.
contract StaleDiscountFacet {
    function getDisputeDiscount() external pure returns (uint256) { return 1; }
}

contract DisputeVaultDiscountUpgradeTest is Test {
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

    /// Everything a fresh deploy carries that the live chain does not — and for
    /// THIS cut that is exactly its own two Add groups and nothing else. No
    /// third cut is queued behind it in the tree; the day one is, this constant
    /// grows and the growth has to be named by signature text, the way
    /// test/GovernanceHandoverUpgrade.t.sol names this cut's three.
    uint256 constant EXTRA_BEYOND_CHAIN = ADDED_REGISTRY + ADDED_ACCOUNTABILITY;

    /// A number from a recorded decision, copied here by a person and NOT
    /// read off the facet: the facet is the thing being checked.
    uint256 constant DISCOUNT_AFTER = 3_000_000;

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
        upgrade.assertListsCoverTheCompiledFacets(
            upgrade.registryReplaceSelectors(),
            upgrade.registryAddSelectors(),
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
        assertEq(added.length, EXTRA_BEYOND_CHAIN, "this cut adds a different number of selectors than the stand expects");
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
                upgrade.artifactSelectors("out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json"),
                _censusAt(".selectors", ".count")
            ),
            ADDED_REGISTRY,
            "the compiled ArbiterRegistryFacet gains a different number of functions than this cut adds"
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
        bytes4[] memory regAbi =
            upgrade.artifactSelectors("out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json");
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
        _assertSameSet(
            _concat(upgrade.registryReplaceSelectors(), upgrade.registryAddSelectors()),
            deploy.arbiterRegistryFacetSelectors(),
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

        // Pre-flight, exactly as run() calls it.
        upgrade.assertListsCoverTheCompiledFacets(regSels, regAdd, accSels, accAdd);
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

        // Post-flight, exactly as run() calls it.
        upgrade.assertRouted(regSels, IDiamondLoupe(address(diamond)).facetAddress(regSels[0]), address(diamond));
        upgrade.assertRouted(accSels, IDiamondLoupe(address(diamond)).facetAddress(accSels[0]), address(diamond));
        upgrade.assertStorageContinuity(before, upgrade.snapshotArbitration(address(diamond)));
        upgrade.assertTheDiscountAnswers(address(diamond), DISCOUNT_AFTER);
        upgrade.assertTheSubsidyDoorAnswersAndIsEmpty(address(diamond));

        assertEq(usdc.balanceOf(address(diamond)), heldBefore, "the diamond's USDC moved across a cut");
        assertEq(_routed(), routedBefore + EXTRA_BEYOND_CHAIN, "the routed count moved by something other than the Add groups");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, facetsBefore,
            "the facet count moved - the old facets should have been emptied, not unmounted"
        );
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousRegistry).length, 0);
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousAccountability).length, 0);

        // And the door the cut is FOR actually works afterwards, which no
        // selector count can say: the owner can move the number, and the read
        // follows it.
        ArbiterRegistryFacet(address(diamond)).setDisputeDiscount(1_500_000);
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getDisputeDiscount(), 1_500_000,
            "setDisputeDiscount did not move the number"
        );
        // Zero reads back as the default, which is the shape chosen for it
        // and the reason "no discount at all" has to be written as 1.
        ArbiterRegistryFacet(address(diamond)).setDisputeDiscount(0);
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getDisputeDiscount(), DISCOUNT_AFTER,
            "a zeroed discount does not read back as the default"
        );
    }

    /// The pre-flight has to REFUSE when the chain is not in the shape the cut
    /// assumes. A selector that is not mounted is the realistic way to get
    /// there: a facet that gained a function since the census was taken, or a
    /// selector filed in the wrong group.
    function test_PreFlightRefusesWhenAReplacedSelectorIsNotMounted() public {
        _unmount(ArbiterRegistryFacet.getVaultBalance.selector);

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
        _mountOne(ArbiterRegistryFacet.getDisputeDiscount.selector, address(new ArbiterRegistryFacet()));

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
            ArbiterRegistryFacet.getDisputeDiscount.selector,
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
        _unmount(ArbiterRegistryFacet.getVaultBalance.selector);

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

    /// The shape of a diamond built the way the live one was built, against the
    /// shape a person read off the live one. Neither number is computed from the
    /// other. A fresh deploy is exactly this cut's three selectors ahead of the
    /// chain, and they are checked by name so the allowance cannot absorb a
    /// different drift of the same size.
    function test_AFreshDeployIsExactlyThisCutAheadOfTheLiveChain() public {
        DiamondProxy d = _deployFullShapedDiamond();  // NOT the pre-cut rig
        assertEq(
            IDiamondLoupe(address(d)).facetAddresses().length, CHAIN_FACETS,
            "a from-scratch diamond has a different number of facets than the live one"
        );

        uint256 routed;
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(d)).facets();
        for (uint256 i = 0; i < all.length; i++) routed += all[i].functionSelectors.length;
        assertEq(
            routed, CHAIN_ROUTED + EXTRA_BEYOND_CHAIN,
            "a from-scratch diamond is not exactly this cut ahead of the live chain"
        );

        // Named by SIGNATURE TEXT, not taken from the script's lists.
        assertTrue(
            IDiamondLoupe(address(d)).facetAddress(bytes4(keccak256("setDisputeDiscount(uint256)"))) != address(0),
            "setDisputeDiscount is not mounted by a fresh deploy"
        );
        assertTrue(
            IDiamondLoupe(address(d)).facetAddress(bytes4(keccak256("getDisputeDiscount()"))) != address(0),
            "getDisputeDiscount is not mounted by a fresh deploy"
        );
        assertTrue(
            IDiamondLoupe(address(d)).facetAddress(bytes4(keccak256("getDisputeSubsidy(address)"))) != address(0),
            "getDisputeSubsidy is not mounted by a fresh deploy"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE BEHAVIOURAL GUARDS
    // ══════════════════════════════════════════════════════════════════════

    /// The discount does not exist before the cut and answers after it. Asked of
    /// the diamond rather than of the script's list.
    function test_TheDiscountAnswersOnlyAfterTheCut() public {
        (bool okBefore,) = address(diamond).staticcall(
            abi.encodeWithSelector(ArbiterRegistryFacet.getDisputeDiscount.selector)
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
        upgrade.assertTheDiscountAnswers(address(diamond), DISCOUNT_AFTER);

        // Now put a different number behind the same selector, and nothing else.
        // Shape unchanged, count unchanged, behaviour wrong.
        bytes4[] memory one = new bytes4[](1);
        one[0] = ArbiterRegistryFacet.getDisputeDiscount.selector;
        IDiamondCut.FacetCut[] memory stale = new IDiamondCut.FacetCut[](1);
        stale[0] = IDiamondCut.FacetCut(address(new StaleDiscountFacet()), IDiamondCut.FacetCutAction.Replace, one);
        IDiamondCut(address(diamond)).diamondCut(stale, address(0), "");

        assertEq(_routed(), CHAIN_ROUTED + EXTRA_BEYOND_CHAIN, "the sabotage changed the routed count - it is meant not to");

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
        // Unsabotaged, it passes.
        upgrade.assertStorageContinuity(before, upgrade.snapshotArbitration(address(diamond)));

        bytes4[] memory one = new bytes4[](1);
        one[0] = ArbiterRegistryFacet.getVaultBalance.selector;
        IDiamondCut.FacetCut[] memory moved = new IDiamondCut.FacetCut[](1);
        moved[0] = IDiamondCut.FacetCut(address(new MovedVaultFacet()), IDiamondCut.FacetCutAction.Replace, one);
        IDiamondCut(address(diamond)).diamondCut(moved, address(0), "");

        assertEq(_routed(), CHAIN_ROUTED + EXTRA_BEYOND_CHAIN, "the sabotage changed the routed count - it is meant not to");

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
        uint256 vaultBefore = ArbiterRegistryFacet(address(diamond)).getVaultBalance();

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
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore,
            "the vault did not survive the rollback"
        );
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getArbiters().length, 1,
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
        ArbiterRegistryFacet(address(diamond)).setArbiterFloor(7_000_000);

        usdc.mint(address(this), 11_000_000);
        usdc.approve(address(diamond), 11_000_000);
        ArbiterRegistryFacet(address(diamond)).fundVault(11_000_000);
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
                    require(n < EXTRA_BEYOND_CHAIN, "the local rig has more selectors than the chain by more than this cut adds");
                    extra[n++] = sel;
                }
            }
        }
        require(n == EXTRA_BEYOND_CHAIN, "the local rig does not differ from the chain by exactly this cut's additions");

        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, extra);
        IDiamondCut(address(d)).diamondCut(remove, address(0), "");

        uint256 routed;
        IDiamondLoupe.Facet[] memory after_ = IDiamondLoupe(address(d)).facets();
        for (uint256 i = 0; i < after_.length; i++) routed += after_[i].functionSelectors.length;
        require(routed == CHAIN_ROUTED, "the local pre-cut rig routes a different number of selectors than the live chain");
        require(after_.length == CHAIN_FACETS, "the local pre-cut rig has a different number of facets than the live chain");
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
