// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeGovernanceHandover.s.sol — the diamondCut that
// replaces both arbitration facets and adds two selectors, carrying decisions
// 50, 51 and 52 into the chain.
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
//     (test/fixtures/chain-2026-08-27-arbiter-governance-selectors.json).
//
// Neither is derived from the thing being checked. That is the fourth way to be
// fooled by a measurement, and it cost a whole cut once: a
// stand that built "what is mounted on chain" out of the script's own
// `registryReplaceSelectors()` agreed with itself no matter which group a
// selector was filed under.
//
// ⚠️ THIS CUT CAN MEET BOTH HALVES OF THE PAIR. `Replace` reverts "Diamond:
// selector not found" on a selector that is not mounted; `Add` reverts
// "Diamond: selector exists" on one that is. Fifty-five selectors are filed
// under Replace and two under Add on the SAME facet address, so a selector in
// the wrong group drops the whole cut in a single live transaction after two
// facets have already been paid for. Both halves are demonstrated below against
// a real diamond, not asserted.
//
// ⚠️ WHAT THE OFFLINE RIG CANNOT REHEARSE, AND WHY IT IS SAID OUT LOUD. The rig
// is built from TODAY'S source, so its facets already carry the new
// threshold. The script's pre-flight demands that the chain still read the OLD
// number (100 000) before the cut, and on this rig it therefore REFUSES — which
// is itself the check firing, and is tested as such below. The post-cut side of
// the same guard, and its ability to catch "one facet moved and the other did
// not", are tested on the rig directly.

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
import {UpgradeGovernanceHandover} from "../script/UpgradeGovernanceHandover.s.sol";

/// An accountability facet whose mirrored threshold is still the OLD number —
/// the shape the diamond would be in if the registry half of the cut landed and
/// the accountability half did not. Nothing but a behavioural read can tell:
/// the selector count is identical either way.
contract StaleMirrorFacet {
    function getDaoThresholdMirror() external pure returns (uint256) { return 100_000; }
}

contract GovernanceHandoverUpgradeTest is Test {
    UpgradeGovernanceHandover upgrade;
    DeployFull deploy;
    DiamondProxy diamond;
    MockUSDCB usdc;

    address constant ARBITER = address(0xA11CE);
    address constant CHIEF   = address(0xB0B);
    address constant FEE_RECIPIENT = address(0xFEE);

    /// The census, and the things it is held to before it is believed.
    string constant CENSUS_PATH = "test/fixtures/chain-2026-08-27-arbiter-governance-selectors.json";
    address constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;

    /// Read off the chain on 27 August 2026 and written down by a person, so
    /// that a facet which silently grows or loses a function stops here instead
    /// of at the signature.
    uint256 constant CHAIN_FACETS             = 13;
    uint256 constant CHAIN_ROUTED             = 216;
    uint256 constant REGISTRY_SELECTORS       = 55;
    uint256 constant ACCOUNTABILITY_SELECTORS = 35;
    uint256 constant ADDED_SELECTORS          = 2;

    /// Everything a fresh deploy carries that the live chain does not.
    ///
    /// ⚠️ THIS STOPPED BEING "JUST THIS CUT'S ADD GROUP" ON 29 AUGUST 2026. The
    /// line above used to read "no second pending cut is sitting in the tree",
    /// and one is: the arbiter vault's discount adds two selectors to the registry and
    /// one to the accountability facet, none of them cut into the chain. Every
    /// one of the three is named BY SIGNATURE TEXT below, so this allowance
    /// cannot absorb a different drift of the same size.
    uint256 constant EXTRA_BEYOND_CHAIN =
        ADDED_SELECTORS + GROWN_REGISTRY + GROWN_ACCOUNTABILITY;

    uint256 constant GROWN_REGISTRY       = 2;
    uint256 constant GROWN_ACCOUNTABILITY = 1;

    /// ⚠️ WHAT THE FACETS GREW **AFTER** THIS CUT WAS SIGNED — written by hand,
    /// by SIGNATURE TEXT, never taken from the script's own lists.
    ///
    /// This cut was broadcast on 27 August 2026 (three receipts, all
    /// `status: 0x1`, block 46 033 263, in
    /// broadcast/UpgradeGovernanceHandover.s.sol/84532/run-latest.json). Its
    /// lists are a record of a transaction that has already happened and must
    /// never be edited — editing them would make the script lie about it. But
    /// the facets keep growing, and the locks below compare those frozen lists
    /// against TODAY'S compiled ABI. Without naming the growth, they redden on
    /// every later addition and say nothing useful.
    ///
    /// Each entry is held to two things by
    /// test_TheGrowthBeyondThisCutIsRealAndCoversNothingItMounted: it must be in
    /// the facet's ABI today (a stale exemption dies), and it must be in NEITHER
    /// group of this cut (an exemption cannot quietly cover something the cut
    /// did mount).
    ///
    ///   • setDisputeDiscount(uint256) / getDisputeDiscount() —
    ///     29 August 2026: the arbiter vault takes a fixed amount off a dispute
    ///     top-up, and its size is a stored number rather than a constant.
    function _grownAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](GROWN_REGISTRY);
        sels[0] = bytes4(keccak256("setDisputeDiscount(uint256)"));
        sels[1] = bytes4(keccak256("getDisputeDiscount()"));
    }

    ///   • getDisputeSubsidy(address) — a bare read of how much of
    ///     a funded top-up came out of the vault. The field belongs to
    ///     ArbiterRegistryFacet, which writes it; the READ sits on the other
    ///     facet because the registry stands 90 bytes under the EIP-170 ceiling.
    function _grownAccountabilityAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](GROWN_ACCOUNTABILITY);
        sels[0] = bytes4(keccak256("getDisputeSubsidy(address)"));
    }

    /// Two numbers from a recorded decision, copied here by a person.
    uint256 constant THRESHOLD_BEFORE = 100_000;
    uint256 constant THRESHOLD_AFTER  = 10_000;

    function setUp() public {
        upgrade = new UpgradeGovernanceHandover();
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
    ///
    /// ⚠️ The growth beyond this cut is handed to the script's own check as if
    /// it were part of the Add groups, and that is the only honest way round:
    /// the check asks "do these lists cover the compiled facet", the compiled
    /// facet has moved on, and the script may not be edited because it has
    /// already run. What keeps the allowance from being a hole is that the three
    /// names are pinned by text and held to two conditions of their own.
    function test_ListsCoverExactlyTheCompiledFacets() public view {
        upgrade.assertListsCoverTheCompiledFacets(
            upgrade.registryReplaceSelectors(),
            _concat(upgrade.registryAddSelectors(), _grownAfterThisCut()),
            _concat(upgrade.accountabilityReplaceSelectors(), _grownAccountabilityAfterThisCut())
        );

        assertEq(upgrade.registryReplaceSelectors().length, REGISTRY_SELECTORS);
        assertEq(upgrade.registryAddSelectors().length, ADDED_SELECTORS);
        assertEq(upgrade.accountabilityReplaceSelectors().length, ACCOUNTABILITY_SELECTORS);
    }

    /// THE PROOF OF THE Replace/Add SPLIT, half one: everything in a Replace
    /// group is mounted on the live chain today, and everything mounted on those
    /// two facets is in a Replace group. Set equality in both directions, per
    /// facet.
    ///
    ///   * nothing in a Replace group is unmounted -> no element belongs in Add;
    ///   * nothing mounted is missing -> no selector is left pointing at a facet
    ///     that no longer implements it.
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

    /// THE PROOF OF THE SPLIT, half two. Both Add selectors must be mounted
    /// NOWHERE in the diamond, which is a question about the whole routed list,
    /// not about ArbiterRegistryFacet: `Add` reverts on a selector routed
    /// anywhere at all.
    function test_BothAddedSelectorsAreMountedNowhereOnTheLiveChain() public view {
        bytes4[] memory whole = _censusAt(".selectors", ".count");
        assertEq(whole.length, CHAIN_ROUTED, "the census does not hold the number of selectors it claims");

        bytes4[] memory added = upgrade.registryAddSelectors();
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
    /// compiled ArbiterRegistryFacet must expose exactly two functions the chain
    /// does not have. A third one added later without touching the script would
    /// be caught here rather than by whoever presses the button.
    function test_TheCompiledRegistryGainsExactlyTheTwoSelectorsThisCutAdds() public view {
        bytes4[] memory fromArtifact =
            upgrade.artifactSelectors("out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json");
        bytes4[] memory mounted = _censusAt(".arbiterRegistrySelectors", ".arbiterRegistryCount");

        uint256 unmounted;
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            bool found;
            for (uint256 j = 0; j < mounted.length; j++) {
                if (fromArtifact[i] == mounted[j]) { found = true; break; }
            }
            if (!found) unmounted++;
        }
        assertEq(
            unmounted, ADDED_SELECTORS + GROWN_REGISTRY,
            "the compiled ArbiterRegistryFacet gains a different number of functions than this cut adds plus what is queued behind it"
        );
    }

    /// The allowance is held to its own two conditions, in its own test so that
    /// a failure names which one broke.
    ///
    /// What disappears from behaviour if this is removed: the allowance above
    /// becomes an unchecked hole — a selector could be dropped out of the cut's
    /// lists and parked here, and the coverage locks would call the cut complete.
    function test_TheGrowthBeyondThisCutIsRealAndCoversNothingItMounted() public view {
        bytes4[] memory grown = _grownAfterThisCut();
        bytes4[] memory regAbi =
            upgrade.artifactSelectors("out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json");
        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(_contains(regAbi, grown[i]), "the allowance is stale: no such function in the registry ABI");
            assertFalse(_contains(upgrade.registryReplaceSelectors(), grown[i]), "the allowance covers a selector this cut REPLACED");
            assertFalse(_contains(upgrade.registryAddSelectors(), grown[i]), "the allowance covers a selector this cut ADDED");
        }

        bytes4[] memory grownAcc = _grownAccountabilityAfterThisCut();
        bytes4[] memory accAbi =
            upgrade.artifactSelectors("out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json");
        for (uint256 i = 0; i < grownAcc.length; i++) {
            assertTrue(_contains(accAbi, grownAcc[i]), "the allowance is stale: no such function in the accountability ABI");
            assertFalse(_contains(upgrade.accountabilityReplaceSelectors(), grownAcc[i]), "the allowance covers a selector this cut REPLACED");
        }
    }

    function _contains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) if (haystack[i] == needle) return true;
        return false;
    }

    /// The accountability facet's whole reason for being in this cut, stated as
    /// a claim about its ABI rather than about its behaviour: it gains nothing
    /// and loses nothing. If that ever stops being true, the cut needs an Add or
    /// a Remove group and this file has to change with it.
    /// ⚠️ Held with the growth added to the chain's side rather than by
    /// weakening the comparison: since 29 August 2026 the facet DOES gain one
    /// function beyond this cut, and it is named.
    function test_TheCompiledAccountabilityFacetGainsAndLosesNothing() public view {
        _assertSameSet(
            upgrade.artifactSelectors("out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json"),
            _concat(
                _censusAt(".arbiterAccountabilitySelectors", ".arbiterAccountabilityCount"),
                _grownAccountabilityAfterThisCut()
            ),
            "ArbiterAccountability artifact vs chain"
        );
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

        // The two numbers the cut is measured against are the CHAIN's, recorded
        // by the same reading that produced the selector lists — not the
        // script's constants restated.
        assertEq(
            vm.parseJsonUint(json, ".arbiterRegistryDaoThreshold"), THRESHOLD_BEFORE,
            "the census does not record the threshold the live registry answers"
        );
        assertEq(
            vm.parseJsonUint(json, ".arbiterAccountabilityDaoThresholdMirror"), THRESHOLD_BEFORE,
            "the census does not record the threshold the live mirror answers"
        );
    }

    /// A third source for the same lists: the from-scratch deploy. If the cut
    /// and the fresh deploy ever disagree about what a facet exposes, one of the
    /// two diamonds is wrong and nothing else would say which.
    /// ⚠️ The growth queued behind this cut is added to THIS cut's side, not
    /// subtracted from DeployFull's: a fresh deploy must mount everything the
    /// facet has today, and this cut mounted everything the facet had in
    /// August. The three names are pinned by text.
    function test_TheCutAndTheFreshDeployMountTheSameSets() public view {
        _assertSameSet(
            _concat(
                _concat(upgrade.registryReplaceSelectors(), upgrade.registryAddSelectors()),
                _grownAfterThisCut()
            ),
            deploy.arbiterRegistryFacetSelectors(),
            "ArbiterRegistry vs DeployFull"
        );
        _assertSameSet(
            _concat(upgrade.accountabilityReplaceSelectors(), _grownAccountabilityAfterThisCut()),
            deploy.arbiterAccountabilityFacetSelectors(),
            "ArbiterAccountability vs DeployFull"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE SHAPE OF THE CUT
    // ══════════════════════════════════════════════════════════════════════

    function test_CutIsTwoReplacesAndOneAdd() public view {
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(0xF00D1), address(0xF00D2));

        assertEq(cuts.length, 3, "the cut must be three elements");

        assertEq(cuts[0].facetAddress, address(0xF00D1));
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace);
        assertEq(cuts[0].functionSelectors.length, REGISTRY_SELECTORS);

        // The Add group lands on the SAME address as the registry Replace group
        // — one FacetCut carries one action, which is the only reason it is a
        // separate element at all.
        assertEq(cuts[1].facetAddress, address(0xF00D1), "the added selectors must land on the new ArbiterRegistryFacet");
        assertTrue(cuts[1].action == IDiamondCut.FacetCutAction.Add);
        assertEq(cuts[1].functionSelectors.length, ADDED_SELECTORS);

        assertEq(cuts[2].facetAddress, address(0xF00D2));
        assertTrue(cuts[2].action == IDiamondCut.FacetCutAction.Replace);
        assertEq(cuts[2].functionSelectors.length, ACCOUNTABILITY_SELECTORS);
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE CUT ITSELF, APPLIED TO A DIAMOND HOLDING A LIVE CORPS AND A VAULT
    // ══════════════════════════════════════════════════════════════════════

    function test_PreFlightPassesAndTheCutLandsWithoutLosingTheCorps() public {
        _seedArbitration();

        bytes4[] memory regSels = upgrade.registryReplaceSelectors();
        bytes4[] memory addSels = upgrade.registryAddSelectors();
        bytes4[] memory accSels = upgrade.accountabilityReplaceSelectors();

        // Pre-flight, exactly as run() calls it — bar the threshold guard, which
        // wants the chain's OLD number and this rig is built from new source.
        // Its refusal here is a test of its own, below.
        // The Add groups carry the growth queued behind this cut for the same
        // reason as in test_ListsCoverExactlyTheCompiledFacets: the compiled
        // facet has moved on and the script may not be edited, having run.
        upgrade.assertListsCoverTheCompiledFacets(
            regSels,
            _concat(addSels, _grownAfterThisCut()),
            _concat(accSels, _grownAccountabilityAfterThisCut())
        );
        address previousRegistry = upgrade.assertAllMountedOnOneFacet(regSels, address(diamond));
        address previousAccountability = upgrade.assertAllMountedOnOneFacet(accSels, address(diamond));
        assertTrue(previousRegistry != previousAccountability, "the two groups sit on the same facet");
        upgrade.assertNothingIsLeftBehind(regSels, previousRegistry, address(diamond));
        upgrade.assertNothingIsLeftBehind(accSels, previousAccountability, address(diamond));
        upgrade.assertAddGroupIsUnmountedAnywhere(addSels, address(diamond));

        uint256 routedBefore = _routed();
        uint256 facetsBefore = IDiamondLoupe(address(diamond)).facetAddresses().length;
        UpgradeGovernanceHandover.StorageSnapshot memory before = upgrade.snapshotArbitration(address(diamond));

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
        upgrade.assertStorageContinuity(before, upgrade.snapshotArbitration(address(diamond)));
        upgrade.assertBothThresholdsRead(address(diamond), THRESHOLD_AFTER, "post-flight");
        upgrade.assertTheHandoverDoorAnswersAndIsEmpty(address(diamond));

        assertEq(usdc.balanceOf(address(diamond)), heldBefore, "the diamond's USDC moved across a cut");
        assertEq(_routed(), routedBefore + ADDED_SELECTORS, "the routed count moved by something other than the Add group");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, facetsBefore,
            "the facet count moved - the old facets should have been emptied, not unmounted"
        );
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousRegistry).length, 0);
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousAccountability).length, 0);

        // And the doors the cut is FOR actually work afterwards, which no
        // selector count can say. `setDAOAddress` must only propose.
        ArbiterRegistryFacet(address(diamond)).setDAOAddress(address(0xDA0));
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getPendingDAOAddress(), address(0xDA0),
            "setDAOAddress did not propose"
        );
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getDAOAddress(), address(0),
            "setDAOAddress took effect on the spot - it must only propose"
        );
        vm.prank(address(0xDA0));
        ArbiterRegistryFacet(address(diamond)).acceptDAOAddress();
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getDAOAddress(), address(0xDA0),
            "the named successor could not take office from the inside"
        );
    }

    /// The pre-flight has to REFUSE when the chain is not in the shape the cut
    /// assumes. A selector that is not mounted is the realistic way to get
    /// there: a facet that gained a function since the census was taken.
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
        _mountOne(ArbiterRegistryFacet.acceptDAOAddress.selector, address(new ArbiterRegistryFacet()));

        bytes4[] memory added = upgrade.registryAddSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert")
        );
        upgrade.assertAddGroupIsUnmountedAnywhere(added, address(diamond));
    }

    /// And the refusal that catches a facet which grew a function nobody mounted:
    /// the previous facet holds more selectors than the cut carries.
    function test_PreFlightRefusesWhenTheOldFacetHoldsSomethingTheCutDoesNotCarry() public {
        _mountOne(ArbiterRegistryFacet.acceptDAOAddress.selector, _hostOf(ArbiterRegistryFacet.isDaoActive.selector));

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
    /// two new selectors are filed under Add is demonstrated and not asserted.
    function test_ADiamondRejectsAnAddOfAMountedSelector() public {
        _mountOne(ArbiterRegistryFacet.acceptDAOAddress.selector, address(new ArbiterRegistryFacet()));

        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(
            address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
        );
        vm.expectRevert(bytes("Diamond: selector exists"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    /// The shape of a diamond built the way the live one was built, against the
    /// shape a person read off the live one. Neither number is computed from the
    /// other. A fresh deploy is exactly this cut's two selectors ahead of the
    /// chain, and they are checked by name so the allowance cannot absorb a
    /// different pair.
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

        bytes4[] memory added = upgrade.registryAddSelectors();
        for (uint256 i = 0; i < added.length; i++) {
            assertTrue(
                IDiamondLoupe(address(d)).facetAddress(added[i]) != address(0),
                "a selector this cut adds is not mounted by a fresh deploy"
            );
        }
        assertTrue(
            IDiamondLoupe(address(d)).facetAddress(ArbiterRegistryFacet.acceptDAOAddress.selector) != address(0),
            "acceptDAOAddress is not mounted by a fresh deploy"
        );
        assertTrue(
            IDiamondLoupe(address(d)).facetAddress(ArbiterRegistryFacet.getPendingDAOAddress.selector) != address(0),
            "getPendingDAOAddress is not mounted by a fresh deploy"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE GUARD THAT WATCHES THE FACET WHOSE SELECTOR COUNT DOES NOT MOVE
    // ══════════════════════════════════════════════════════════════════════

    /// ⚠️ THE ONE THING NO SELECTOR COUNT CAN SAY. ArbiterAccountabilityFacet
    /// ships 35 selectors before this cut and 35 after; only its body changed.
    /// A cut that landed the registry and silently missed the accountability
    /// facet would pass every shape check in this file. This is the scene that
    /// catches it: the registry answers the new threshold, the mirror answers
    /// the old one, and the guard has to say so.
    function test_TheThresholdGuardCatchesAFacetThatDidNotMove() public {
        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()),
                address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );
        // Both agree at this point.
        upgrade.assertBothThresholdsRead(address(diamond), THRESHOLD_AFTER, "post-flight");

        // Now put the mirror back where it was before the cut, and nothing
        // else. Shape unchanged, count unchanged, behaviour wrong.
        bytes4[] memory one = new bytes4[](1);
        one[0] = ArbiterAccountabilityFacet.getDaoThresholdMirror.selector;
        IDiamondCut.FacetCut[] memory stale = new IDiamondCut.FacetCut[](1);
        stale[0] = IDiamondCut.FacetCut(address(new StaleMirrorFacet()), IDiamondCut.FacetCutAction.Replace, one);
        IDiamondCut(address(diamond)).diamondCut(stale, address(0), "");

        assertEq(_routed(), CHAIN_ROUTED + ADDED_SELECTORS, "the sabotage changed the routed count - it is meant not to");

        vm.expectRevert(
            bytes(
                "post-flight: ArbiterAccountabilityFacet.getDaoThresholdMirror() is not the number this phase expects"
                " - the accountability facet's code did not move"
            )
        );
        upgrade.assertBothThresholdsRead(address(diamond), THRESHOLD_AFTER, "post-flight");
    }

    /// The pre-cut half of the same guard, fired on the rig for the reason
    /// stated in this file's header: the rig runs today's source, so it already
    /// answers the NEW number, and the guard that demands the OLD one refuses.
    /// On the live chain the reading is 100 000 and it passes; the value of the
    /// guard is exactly this refusal, on a diamond this cut has already landed
    /// on.
    function test_ThePreFlightThresholdGuardRefusesAChainThisCutAlreadyLandedOn() public {
        vm.expectRevert(
            bytes("pre-flight: ArbiterRegistryFacet.getDaoThreshold() is not the number this phase expects")
        );
        upgrade.assertBothThresholdsRead(address(diamond), THRESHOLD_BEFORE, "pre-flight");
    }

    /// Decision 51's door does not exist before the cut, and answers after it.
    /// Asked of the diamond rather than of the script's list.
    function test_TheHandoverDoorAnswersOnlyAfterTheCut() public {
        (bool okBefore,) = address(diamond).staticcall(
            abi.encodeWithSelector(ArbiterRegistryFacet.getPendingDAOAddress.selector)
        );
        assertFalse(okBefore, "getPendingDAOAddress already answers before the cut");

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()),
                address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        upgrade.assertTheHandoverDoorAnswersAndIsEmpty(address(diamond));
    }

    /// The rollback path, proved rather than described: the ninety go back to
    /// the facets they came from, the two added ones are removed, and the corps
    /// still reads.
    function test_RollbackRestoresTheShapeAndTheCorpsStillReads() public {
        _seedArbitration();

        bytes4[] memory regSels = upgrade.registryReplaceSelectors();
        bytes4[] memory addSels = upgrade.registryAddSelectors();
        bytes4[] memory accSels = upgrade.accountabilityReplaceSelectors();

        address previousRegistry = upgrade.assertAllMountedOnOneFacet(regSels, address(diamond));
        address previousAccountability = upgrade.assertAllMountedOnOneFacet(accSels, address(diamond));
        uint256 routedBefore = _routed();

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        IDiamondCut.FacetCut[] memory undo = new IDiamondCut.FacetCut[](3);
        undo[0] = IDiamondCut.FacetCut(previousRegistry, IDiamondCut.FacetCutAction.Replace, regSels);
        undo[1] = IDiamondCut.FacetCut(previousAccountability, IDiamondCut.FacetCutAction.Replace, accSels);
        undo[2] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, addSels);
        IDiamondCut(address(diamond)).diamondCut(undo, address(0), "");

        upgrade.assertRouted(regSels, previousRegistry, address(diamond));
        upgrade.assertRouted(accSels, previousAccountability, address(diamond));
        assertEq(_routed(), routedBefore, "the rollback did not restore the pre-cut shape");
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getArbiters().length, 1,
            "the corps did not survive the rollback"
        );
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getChiefArbiter(), CHIEF,
            "the chief did not survive the rollback"
        );
        assertGt(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(), 0,
            "the vault did not survive the rollback"
        );
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

    /// Puts the rig into the shape the live diamond is in: a seated arbiter, a
    /// chief, a funded vault and a floor. The cut is then applied on top of a
    /// live arbitration namespace rather than an empty one, which is the only
    /// way the storage-continuity claim means anything — this work APPENDED a
    /// field to `ArbiterRegistryStorage.Data` and two fields to structs inside
    /// it.
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
    /// since this work, already mounts the two new selectors) and then the
    /// difference against the CENSUS is removed. Which selectors to remove is
    /// therefore decided by what the chain answered, not by this cut's own
    /// `registryAddSelectors()` — a rig built from the script's own list would
    /// agree with the script no matter which group anything was filed under,
    /// and that is the fourth way to be fooled by a measurement.
    ///
    /// The count is checked afterwards against the census header too, so a rig
    /// that has quietly drifted from the live diamond stops being a stand-in
    /// without anybody noticing.
    ///
    /// ⚠️ WHAT THIS RIG IS NOT. Its facets carry TODAY'S code, so its behaviour
    /// is already post-cut even while its SHAPE is pre-cut. Every claim made
    /// against it here is a claim about routing. The one behavioural pre-cut
    /// claim the script makes — "both thresholds still read 100 000" — is
    /// therefore tested by its refusal, not by its success.
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
