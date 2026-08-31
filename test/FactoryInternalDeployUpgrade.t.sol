// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeFactoryInternalDeploy.s.sol — the diamondCut that
// replaces FactoryFacet so that `deployAgreement` admits the diamond alone.
//
// ⚠️ WHY A STAND AT ALL, WHEN THE SCRIPT HAS A DRY RUN. A dry run proves the
// script survives TODAY'S chain. It cannot prove the script survives the chain
// it will meet at the moment somebody signs, and it cannot be run in CI at all —
// it needs a network and an RPC key. Everything below runs offline, and the
// questions that decide whether the cut lands or reverts are answered from
// sources this file does not own:
//
//   * "does the list cover the facet" — the expected side is solc's own
//     `methodIdentifiers`, read out of the build artifact, not the list in the
//     script;
//   * "is every selector mounted, and is anything else on that facet" — the
//     expected side is a census read off Base Sepolia and committed as data
//     (test/fixtures/chain-2026-08-29-factory-selectors.json).
//
// Neither is derived from the thing being checked. That is the fourth way to be
// fooled by a measurement, and it cost a whole cut once.
//
// ⚠️ THE SHAPE OF THIS ONE IS THE QUIET KIND. It is a pure Replace: twenty-three
// selectors in, twenty-three out, routed count unmoved, facet count unmoved.
// Every shape check in this file would pass just as happily on a cut that was
// signed against the wrong commit and shipped the code that is already running.
// So the claim that the cut DID something rests entirely on a behavioural pair,
// and that pair is exercised in both directions below:
//
//     before   deployAgreement(client=stranger) reverts NotClient()
//     after    the same call reverts NotDiamond()
//
// Both refusals are raised before the function writes anything, so a
// `staticcall` reaches them and the probe costs nothing and sends no
// transaction.

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
import {UpgradeFactoryInternalDeploy} from "../script/UpgradeFactoryInternalDeploy.s.sol";

/// The door as the LIVE chain answers it today: a stranger acting for somebody
/// else is turned away with `NotClient()`. The rig is built from today's source,
/// where that answer is already `NotDiamond()`, so the pre-cut behaviour has to
/// be staged — there is no way to compile the old facet from this checkout.
contract StaleDoorFacet {
    error NotClient();
    function deployAgreement(
        address, address, address, uint256, uint256, string calldata, uint8
    ) external pure returns (address) {
        revert NotClient();
    }
}

/// A door that refuses with something else entirely — the shape of a diamond
/// where the probe reaches a guard that is not the one being asked about.
contract WrongReasonDoorFacet {
    error SomethingElse();
    function deployAgreement(
        address, address, address, uint256, uint256, string calldata, uint8
    ) external pure returns (address) {
        revert SomethingElse();
    }
}

contract FactoryInternalDeployUpgradeTest is Test {
    UpgradeFactoryInternalDeploy upgrade;
    DeployFull deploy;
    DiamondProxy diamond;
    MockUSDCB usdc;

    address constant FEE_RECIPIENT = address(0xFEE);

    /// The census, and the things it is held to before it is believed.
    string constant CENSUS_PATH = "test/fixtures/chain-2026-08-29-factory-selectors.json";
    address constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;

    /// Read off the chain on 29 August 2026 and written down by a person, so
    /// that a facet which silently grows or loses a function stops here instead
    /// of at the signature.
    uint256 constant CHAIN_FACETS    = 13;
    uint256 constant CHAIN_ROUTED    = 218;
    uint256 constant FACTORY_SELECTORS = 23;

    /// Everything a fresh deploy carries that the live chain does not.
    ///
    /// ⚠️ THIS CUT ADDS NOTHING, so every one of these belongs to a DIFFERENT
    /// cut waiting in the same tree, and each is named BY SIGNATURE TEXT below
    /// so the allowance cannot absorb a different drift of the same size.
    uint256 constant GROWN_ELSEWHERE = 4;
    uint256 constant EXTRA_BEYOND_CHAIN = GROWN_ELSEWHERE;

    /// ⚠️ WHAT THE TREE CARRIES THAT THE CHAIN DOES NOT, AND WHY IT IS NOT THIS
    /// CUT'S BUSINESS — written by hand, by SIGNATURE TEXT, never taken from any
    /// script's lists.
    ///
    /// Decision 54, 29 August 2026: the arbiter vault takes a fixed amount off a
    /// dispute top-up. Two selectors on ArbiterRegistryFacet and one on
    /// ArbiterAccountabilityFacet, none of them cut into the chain yet; they ship
    /// with script/UpgradeDisputeVaultDiscount.s.sol, and this cut touches
    /// neither facet.
    ///
    /// Each entry is held to two things by
    /// test_TheGrowthBeyondThisCutIsRealAndBelongsToAnotherFacet: it must exist
    /// in some facet's ABI today (a stale exemption dies), and it must NOT be a
    /// FactoryFacet selector (an exemption cannot quietly cover something this
    /// cut is responsible for).
    function _grownElsewhere() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](GROWN_ELSEWHERE);
        sels[0] = bytes4(keccak256("setDisputeDiscount(uint256)"));
        sels[1] = bytes4(keccak256("getDisputeDiscount()"));
        sels[2] = bytes4(keccak256("getDisputeSubsidy(address)"));
        // 31 August 2026: RegistryFacet gains the door the diamond needs to see
        // a hand-in at all. Ships with
        // script/UpgradeRegistryHandInSignal.s.sol; this cut touches neither
        // that facet nor that function.
        sels[3] = bytes4(keccak256("notifyWorkHandedIn()"));
    }

    function setUp() public {
        upgrade = new UpgradeFactoryInternalDeploy();
        deploy  = new DeployFull();
        usdc    = new MockUSDCB();
        diamond = _deployPreCutDiamond();
        _initDiamond();
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE INDEPENDENT ORACLES
    // ══════════════════════════════════════════════════════════════════════

    /// The script's hand-written list against solc's output. A function the facet
    /// gains and nobody mounts would otherwise ship dead: present in the ABI,
    /// routed nowhere, discovered by the first person whose button did nothing.
    function test_TheReplaceListCoversExactlyTheCompiledFacet() public view {
        upgrade.assertReplaceListCoversTheWholeFacet(upgrade.replaceSelectors());
        assertEq(upgrade.replaceSelectors().length, FACTORY_SELECTORS);
    }

    /// THE PROOF THERE IS NOTHING TO SPLIT: everything in the Replace group is
    /// mounted on the live chain today, and everything mounted on that facet is
    /// in the Replace group. Set equality in both directions.
    ///
    ///   * nothing in the group is unmounted -> nothing belongs in an Add group
    ///     this cut does not have, and `Replace` will not revert;
    ///   * nothing mounted is missing -> no selector is left pointing at a facet
    ///     that no longer implements it.
    ///
    /// ⚠️ THIS IS THE LOCK FOR "A SELECTOR LEFT THE GROUP". Its expected side is
    /// the census — the chain's own answer — so dropping a selector from the
    /// script's list takes it out of one side without taking it out of the
    /// other. A stand that built the chain's side out of `replaceSelectors()`
    /// would follow the drop and stay green.
    function test_EveryReplacedSelectorIsMountedAndNothingElseIsOnThatFacet() public view {
        _assertSameSet(
            upgrade.replaceSelectors(),
            _censusAt(".factorySelectors", ".factoryCount"),
            "FactoryFacet"
        );
    }

    /// And the same claim asked of the ARTIFACT rather than of the script: the
    /// compiled FactoryFacet must expose NOTHING the chain does not already
    /// route. One more function, added later without touching the script, would
    /// need an Add group this cut does not have — caught here rather than by
    /// whoever presses the button.
    function test_TheCompiledFactoryFacetGainsNothingAndSoNeedsNoAddGroup() public view {
        bytes4[] memory fromArtifact = upgrade.artifactSelectors();
        bytes4[] memory whole = _censusAt(".selectors", ".count");
        assertEq(whole.length, CHAIN_ROUTED, "the census does not hold the number of selectors it claims");

        for (uint256 i = 0; i < fromArtifact.length; i++) {
            assertTrue(
                _contains(whole, fromArtifact[i]),
                "the compiled FactoryFacet exposes a function the live chain routes nowhere - this cut needs an Add group and has none"
            );
        }
        assertEq(fromArtifact.length, FACTORY_SELECTORS, "the compiled facet has a different number of functions than the chain mounts");
    }

    /// The allowance is held to its own two conditions, in its own test so that
    /// a failure names which one broke.
    ///
    /// What disappears from behaviour if this is removed: the allowance in
    /// `_deployPreCutDiamond` becomes an unchecked hole — three FactoryFacet
    /// selectors could be dropped out of the cut and parked here, and the rig
    /// would still claim to match the live chain.
    function test_TheGrowthBeyondThisCutIsRealAndBelongsToAnotherFacet() public view {
        bytes4[] memory grown = _grownElsewhere();
        bytes4[] memory regAbi = _abiOf("out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json");
        bytes4[] memory accAbi = _abiOf("out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json");
        // Widened on 31 August 2026, when the fourth queued cut turned out not
        // to be an arbitration one: the deal registry gained
        // `notifyWorkHandedIn()`. The condition that carries the weight is the
        // NEGATIVE one below -- an allowance may not cover anything FactoryFacet
        // implements, because that is the facet this cut is responsible for.
        // The positive condition only says the exemption is not stale, and it
        // stays exactly as strict per facet: the selector must be implemented by
        // one of the three named facets, never merely "somewhere".
        bytes4[] memory dealRegistryAbi = _abiOf("out/RegistryFacet.sol/RegistryFacet.json");
        bytes4[] memory factoryAbi = upgrade.artifactSelectors();

        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(
                _contains(regAbi, grown[i])
                    || _contains(accAbi, grown[i])
                    || _contains(dealRegistryAbi, grown[i]),
                "the allowance is stale: no named facet implements it any more"
            );
            assertFalse(
                _contains(factoryAbi, grown[i]),
                "the allowance covers a FactoryFacet selector - it would hide a hole in THIS cut"
            );
            assertFalse(
                _contains(upgrade.replaceSelectors(), grown[i]),
                "the allowance covers a selector this cut REPLACES"
            );
        }
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

        // The readings the storage-continuity claim leans on, recorded by the
        // same pass that produced the selector lists.
        assertGt(vm.parseJsonUint(json, ".factoryFeeBps"), 0, "the census records a zero fee rate - continuity would prove nothing");
        assertTrue(vm.parseJsonAddress(json, ".agreementDeployer") != address(0), "the census records no deployer");
    }

    /// A third source for the same list: the from-scratch deploy. If the cut and
    /// the fresh deploy ever disagree about what the facet exposes, one of the
    /// two diamonds is wrong and nothing else would say which.
    function test_TheCutAndTheFreshDeployMountTheSameSet() public view {
        _assertSameSet(upgrade.replaceSelectors(), deploy.factoryFacetSelectors(), "FactoryFacet vs DeployFull");
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE SHAPE OF THE CUT
    // ══════════════════════════════════════════════════════════════════════

    function test_CutIsOneReplaceAndNothingElse() public view {
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(0xF00D));
        assertEq(cuts.length, 1, "the cut must be a single element");
        assertEq(cuts[0].facetAddress, address(0xF00D));
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace, "the only action must be Replace");
        assertEq(cuts[0].functionSelectors.length, FACTORY_SELECTORS);
    }

    /// `deployAgreement` keeps its signature across this cut, which is the whole
    /// reason there is no Add group. Named by SIGNATURE TEXT rather than taken
    /// from the facet, so a signature change would show up here instead of in a
    /// reverted live transaction.
    function test_TheDoorKeepsItsSelector() public view {
        bytes4 door = bytes4(keccak256("deployAgreement(address,address,address,uint256,uint256,string,uint8)"));
        assertEq(door, bytes4(0x7ba33dab), "deployAgreement's selector is not the one on chain");
        assertTrue(_contains(upgrade.replaceSelectors(), door), "the cut does not carry deployAgreement");
        assertTrue(_contains(_censusAt(".factorySelectors", ".factoryCount"), door), "the live chain does not route deployAgreement on the factory facet");
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE CUT ITSELF, APPLIED TO A DIAMOND WITH A LIVE FEE MODEL
    // ══════════════════════════════════════════════════════════════════════

    function test_PreFlightPassesAndTheCutLandsWithoutLosingTheFeeModel() public {
        // Stage the door as the live chain answers it today. Everything else on
        // the rig is today's code; only this one selector has to be put back the
        // way the chain has it, because the old facet cannot be compiled here.
        address stale = address(new StaleDoorFacet());
        _replaceOne(FactoryFacet.deployAgreement.selector, stale);

        bytes4[] memory sels = upgrade.replaceSelectors();

        // Pre-flight, exactly as run() calls it — bar the two checks that assume
        // all twenty-three sit on ONE facet, which the staging above breaks on
        // purpose. Their own refusals are tested separately below.
        upgrade.assertReplaceListCoversTheWholeFacet(sels);
        upgrade.assertTheCompiledFacetNeedsNoAddGroup(address(diamond));
        upgrade.assertTheDoorIsStillOpenToStrangers(address(diamond));

        uint256 routedBefore = _routed();
        uint256 facetsBefore = IDiamondLoupe(address(diamond)).facetAddresses().length;
        UpgradeFactoryInternalDeploy.StorageSnapshot memory before =
            upgrade.snapshotFactory(address(diamond));

        // The scene is only worth running if there is something to lose.
        assertGt(before.feeBps, 0, "the seeded factory charges nothing");
        assertEq(before.feeRecipient, FEE_RECIPIENT, "the seeded factory has no recipient");
        assertTrue(before.agreementDeployer != address(0), "the seeded factory has no deployer");

        address newFacet = address(new FactoryFacet());
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(newFacet), address(0), "");

        // Post-flight, exactly as run() calls it.
        upgrade.assertRouted(sels, newFacet, address(diamond));
        upgrade.assertStorageContinuity(before, upgrade.snapshotFactory(address(diamond)));
        upgrade.assertTheDoorIsShutToStrangers(address(diamond));

        assertEq(_routed(), routedBefore, "a Replace moved the routed count");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, facetsBefore - 1,
            "the staged door facet should have been emptied and unmounted by the cut"
        );
        assertEq(
            IDiamondLoupe(address(diamond)).facetFunctionSelectors(newFacet).length, FACTORY_SELECTORS,
            "the new facet does not hold all twenty-three"
        );
        assertEq(
            IDiamondLoupe(address(diamond)).facetFunctionSelectors(stale).length, 0,
            "the staged door facet still holds a selector"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE BEHAVIOURAL PAIR — the only thing that can tell this cut apart from
    // no cut at all.
    // ══════════════════════════════════════════════════════════════════════

    /// The rig runs today's source, so the door is ALREADY shut on it. The
    /// pre-flight guard therefore refuses — and that refusal IS the guard
    /// working, and is the only way to test it without the old facet's bytecode.
    /// On the live chain the same guard passes, because the chain answers
    /// `NotClient()` today.
    function test_ThePreFlightDoorGuardRefusesAChainThisCutAlreadyLandedOn() public {
        vm.expectRevert(
            bytes("pre-flight: the door already answers NotDiamond() - this cut has already landed on this diamond")
        );
        upgrade.assertTheDoorIsStillOpenToStrangers(address(diamond));
    }

    /// And the post-flight half, on the diamond as built: the door is shut and
    /// shut BY NAME.
    function test_ThePostFlightDoorGuardPassesOnTheNewFacet() public view {
        upgrade.assertTheDoorIsShutToStrangers(address(diamond));
        assertEq(
            upgrade.probeTheDoor(address(diamond)), FactoryFacet.NotDiamond.selector,
            "the probe does not read NotDiamond() off a diamond running the new facet"
        );
    }

    /// ⚠️ THE SCENE THAT CATCHES A CUT WHICH DID NOT LAND. Stage the door the
    /// way the live chain answers it today, then ask the post-flight guard. It
    /// has to say so — nothing else in this file could, because the shape is
    /// identical either way.
    function test_ThePostFlightDoorGuardCatchesAFacetThatDidNotMove() public {
        _replaceOne(FactoryFacet.deployAgreement.selector, address(new StaleDoorFacet()));

        assertEq(_routed(), CHAIN_ROUTED, "the sabotage changed the routed count - it is meant not to");
        assertEq(
            upgrade.probeTheDoor(address(diamond)), StaleDoorFacet.NotClient.selector,
            "the staged door does not answer NotClient()"
        );

        vm.expectRevert(
            bytes("post-flight: deployAgreement does not refuse a stranger with NotDiamond() - the new facet's code is not running")
        );
        upgrade.assertTheDoorIsShutToStrangers(address(diamond));
    }

    /// And the pre-flight guard's OTHER refusal: a door that turns the stranger
    /// away for some third reason is not the facet this cut was written against,
    /// and running the cut on it would be running it blind.
    function test_ThePreFlightDoorGuardRefusesAThirdAnswer() public {
        _replaceOne(FactoryFacet.deployAgreement.selector, address(new WrongReasonDoorFacet()));

        vm.expectRevert(
            bytes("pre-flight: the door answers neither NotClient() nor NotDiamond() - this is not the FactoryFacet this cut was written against")
        );
        upgrade.assertTheDoorIsStillOpenToStrangers(address(diamond));
    }

    /// The probe insists on a refusal. A door that lets a stranger through is
    /// neither the old facet nor the new one, and reading its silence as
    /// "refused" would make both guards meaningless.
    function test_TheProbeRefusesADoorThatDoesNotRefuse() public {
        _replaceOne(FactoryFacet.deployAgreement.selector, address(new OpenDoorFacet()));

        vm.expectRevert(
            bytes("probe: deployAgreement did NOT refuse a stranger - neither the old nor the new facet does that")
        );
        upgrade.probeTheDoor(address(diamond));
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE PRE-FLIGHT REFUSALS
    // ══════════════════════════════════════════════════════════════════════

    /// The pre-flight has to REFUSE when the chain is not in the shape the cut
    /// assumes. A selector that is not mounted is the realistic way to get
    /// there: a facet that gained a function since the census was taken.
    function test_PreFlightRefusesWhenAReplacedSelectorIsNotMounted() public {
        _unmount(FactoryFacet.getUndeliveredFees.selector);

        // ⚠️ Fetched BEFORE the expectation is armed: `vm.expectRevert` arms the
        // NEXT call, and `upgrade.replaceSelectors()` is itself an external call.
        bytes4[] memory sels = upgrade.replaceSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert")
        );
        upgrade.assertAllMountedOnOneFacet(sels, address(diamond));
    }

    /// The same fact seen from the other side, and the one that would catch a
    /// FactoryFacet which grew a function nobody mounted: the compiled facet
    /// exposes something the diamond routes nowhere, and this cut has no Add
    /// group to put it in.
    function test_PreFlightRefusesWhenTheCompiledFacetNeedsAnAddGroup() public {
        _unmount(FactoryFacet.getUndeliveredFees.selector);

        vm.expectRevert(
            bytes("pre-flight: the compiled facet exposes a function that is mounted nowhere - this cut needs an Add group and has none")
        );
        upgrade.assertTheCompiledFacetNeedsNoAddGroup(address(diamond));
    }

    /// The group must be on ONE facet. Two addresses answering the same group is
    /// how a half-applied earlier cut looks, and a Replace over it would leave
    /// one of them holding nothing while the other kept a live selector.
    function test_PreFlightRefusesWhenTheGroupIsSpreadOverTwoFacets() public {
        _replaceOne(FactoryFacet.deployAgreement.selector, address(new StaleDoorFacet()));

        bytes4[] memory sels = upgrade.replaceSelectors();
        vm.expectRevert(
            bytes("pre-flight: the twenty-three selectors are not all on one facet - this cut assumes one FactoryFacet")
        );
        upgrade.assertAllMountedOnOneFacet(sels, address(diamond));
    }

    /// And the refusal that catches a facet holding a selector the cut does not
    /// carry — one left behind would keep pointing at code that no longer
    /// implements it.
    function test_PreFlightRefusesWhenTheOldFacetHoldsSomethingTheCutDoesNotCarry() public {
        address host = _hostOf(FactoryFacet.getFeeBps.selector);
        // A selector from ANOTHER facet, parked on the factory's address.
        _unmount(ArbiterRegistryFacet.getMinXPToRegister.selector);
        _mountOne(ArbiterRegistryFacet.getMinXPToRegister.selector, host);

        bytes4[] memory sels = upgrade.replaceSelectors();
        vm.expectRevert(
            bytes("pre-flight: the facet being replaced holds a different number of selectors than this cut carries")
        );
        upgrade.assertNothingIsLeftBehind(sels, host, address(diamond));
    }

    /// The diamond itself refuses, with its own message — proof that the
    /// pre-flight guards a real failure rather than an imagined one.
    function test_ADiamondRejectsAReplaceOfAnUnmountedSelector() public {
        _unmount(FactoryFacet.getUndeliveredFees.selector);

        // ⚠️ Built BEFORE the expectation is armed.
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(new FactoryFacet()));
        vm.expectRevert(bytes("Diamond: selector not found"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    /// The shape of a diamond built the way the live one was built, against the
    /// shape a person read off the live one. Neither number is computed from the
    /// other. A fresh deploy is ahead of the chain by three selectors that belong
    /// to ANOTHER cut, and they are checked by name.
    function test_AFreshDeployIsAheadOfTheChainOnlyByAnotherCut() public {
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
            "a from-scratch diamond is not ahead of the live chain by exactly the cut queued behind this one"
        );

        bytes4[] memory grown = _grownElsewhere();
        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(
                IDiamondLoupe(address(d)).facetAddress(grown[i]) != address(0),
                "a selector the allowance names is not mounted by a fresh deploy - the allowance is stale"
            );
        }
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

    function _replaceOne(bytes4 sel, address facet) internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = sel;
        IDiamondCut.FacetCut[] memory rep = new IDiamondCut.FacetCut[](1);
        rep[0] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Replace, one);
        IDiamondCut(address(diamond)).diamondCut(rep, address(0), "");
    }

    function _contains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) if (haystack[i] == needle) return true;
        return false;
    }

    /// solc's own answer to "what does this facet expose", for a facet this cut
    /// does not touch. Read here rather than through the script, which has no
    /// business knowing about the arbitration facets at all.
    function _abiOf(string memory artifactPath) internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(artifactPath);
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i = 0; i < sigs.length; i++) out[i] = bytes4(keccak256(bytes(sigs[i])));
    }

    /// The diamond as Base Sepolia stands TODAY — before this cut.
    ///
    /// Built the honest way round: a full DeployFull-shaped diamond and then the
    /// difference against the CENSUS is removed. Which selectors to remove is
    /// therefore decided by what the chain answered, not by any script's list.
    function _deployPreCutDiamond() internal returns (DiamondProxy d) {
        d = _deployFullShapedDiamond();

        bytes4[] memory onChain = _censusAt(".selectors", ".count");
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(d)).facets();

        bytes4[] memory extra = new bytes4[](EXTRA_BEYOND_CHAIN);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = 0; j < all[i].functionSelectors.length; j++) {
                bytes4 sel = all[i].functionSelectors[j];
                if (!_contains(onChain, sel)) {
                    require(n < EXTRA_BEYOND_CHAIN, "the local rig has more selectors than the chain by more than the cut queued behind this one");
                    extra[n++] = sel;
                }
            }
        }
        require(n == EXTRA_BEYOND_CHAIN, "the local rig does not differ from the chain by exactly the cut queued behind this one");

        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, extra);
        IDiamondCut(address(d)).diamondCut(remove, address(0), "");

        uint256 routed;
        IDiamondLoupe.Facet[] memory after_ = IDiamondLoupe(address(d)).facets();
        for (uint256 i = 0; i < after_.length; i++) routed += after_[i].functionSelectors.length;
        require(routed == CHAIN_ROUTED, "the local pre-cut rig routes a different number of selectors than the live chain");
        require(after_.length == CHAIN_FACETS, "the local pre-cut rig has a different number of facets than the live chain");
    }

    /// Registry and factory, seeded so the fee model is a live thing to lose.
    function _initDiamond() internal {
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), FEE_RECIPIENT, address(0xDEAD), address(diamond), address(agDeployer)
        );
    }

    /// A diamond built out of DeployFull's own selector lists — the same lists
    /// run() builds the live one from.
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
}

/// A door that lets a stranger straight through — neither the old facet nor the
/// new one behaves like this, and the probe has to say so rather than reading
/// silence as a refusal.
contract OpenDoorFacet {
    function deployAgreement(
        address, address, address, uint256, uint256, string calldata, uint8
    ) external pure returns (address) {
        return address(0xBEEF);
    }
}
