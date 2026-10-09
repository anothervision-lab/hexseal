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
import "../src/facets/TreasuryLinkFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {MockUSDCB} from "./BoardsFixture.sol";
import {UpgradeFactoryInternalDeploy} from "../script/UpgradeFactoryInternalDeploy.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterSplitRig} from "./ArbiterSplitRig.sol";

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

contract FactoryInternalDeployUpgradeTest is Test, ArbiterSplitRig {
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
        // ⚠️ THE SIZE IS THE LENGTH OF THE LIST DIRECTLY BELOW IT, and it used
        // to be a sum of separately declared allowance constants. Those
        // constants are gone: a number kept apart from the list it sizes is one
        // more thing to keep in step, and keeping it in step by hand is the
        // habit this file was rewritten to break.
        sels = new bytes4[](4);
        sels[0] = bytes4(keccak256("setDisputeDiscount(uint256)"));
        sels[1] = bytes4(keccak256("getDisputeDiscount()"));
        sels[2] = bytes4(keccak256("getDisputeSubsidy(address)"));
        // 31 August 2026: RegistryFacet gains the door the diamond needs to see
        // a hand-in at all. Ships with
        // script/UpgradeRegistryHandInSignal.s.sol; this cut touches neither
        // that facet nor that function.
        sels[3] = bytes4(keccak256("notifyWorkHandedIn()"));
    }

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

    /// The coverage claim, with the later growth named rather than folded in.
    ///
    /// ⚠️ NOT `upgrade.assertReplaceListCoversTheWholeFacet(...)` ANY MORE, and
    /// the script keeps that strict version untouched on purpose. It asks "is
    /// the compiled facet exactly what I mount", and for this cut the honest
    /// answer is now NO. `run()` still asks it strictly, which is correct:
    /// re-running this script today would deploy a FactoryFacet carrying the
    /// brake and mount only 23 of its 27 functions, shipping four dead ones.
    /// The refusal is the script telling the truth about itself, and it is not
    /// silenced.
    function _assertReplaceListCoversTheFacetAllowingLaterGrowth() internal view {
        _assertSameSet(
            _concat(upgrade.replaceSelectors(), _grownFactoryAfterThisCut()),
            upgrade.artifactSelectors(),
            "FactoryFacet (this cut's Replace list plus the named later growth)"
        );
    }

    /// The same for "does the compiled facet need an Add group": every function
    /// it exposes must be routed on the rig, UNLESS it is one of the five named
    /// above -- the brake's four and item 138's MAX_FEE_BPS(). Same refusal text as the script's, so the sabotage test below
    /// still reddens on the sabotage and not on the allowance.
    function _assertNoAddGroupNeededBeyondTheNamedGrowth() internal view {
        bytes4[] memory fromArtifact = upgrade.artifactSelectors();
        bytes4[] memory grown = _grownFactoryAfterThisCut();
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            if (_contains(grown, fromArtifact[i])) continue;
            require(
                IDiamondLoupe(address(diamond)).facetAddress(fromArtifact[i]) != address(0),
                "pre-flight: the compiled facet exposes a function that is mounted nowhere - this cut needs an Add group and has none"
            );
        }
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
        _assertReplaceListCoversTheFacetAllowingLaterGrowth();
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
    /// ⚠️ RENAMED AND REWRITTEN ON 3 SEPTEMBER 2026. It used to be called
    /// `...GainsNothingAndSoNeedsNoAddGroup`, and the premise stopped being
    /// true: the compiled facet now exposes four functions the chain routes
    /// nowhere. Keeping the old name and widening the number would have left a
    /// test whose name asserts one thing and whose body checks another.
    function test_TheCompiledFactoryFacetGainsOnlyTheNamedLaterGrowth() public view {
        bytes4[] memory fromArtifact = upgrade.artifactSelectors();
        bytes4[] memory whole = _censusAt(".selectors", ".count");
        bytes4[] memory grown = _grownFactoryAfterThisCut();
        assertEq(whole.length, CHAIN_ROUTED, "the census does not hold the number of selectors it claims");

        for (uint256 i = 0; i < fromArtifact.length; i++) {
            assertTrue(
                _contains(whole, fromArtifact[i]) || _contains(grown, fromArtifact[i]),
                "the compiled FactoryFacet exposes a function the live chain routes nowhere and nothing named claims - this cut needs an Add group and has none"
            );
        }
        // And the growth is not merely allowed, it is REQUIRED to be there: an
        // allowance for a function that has been deleted would otherwise sit
        // here forever, covering the next thing of the same size.
        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(_contains(fromArtifact, grown[i]), "the allowance is stale: FactoryFacet no longer implements it");
            assertFalse(_contains(whole, grown[i]), "the allowance names a selector the live chain already routes");
            assertFalse(_contains(upgrade.replaceSelectors(), grown[i]), "the allowance covers a selector this cut REPLACED");
        }
        assertEq(
            fromArtifact.length, FACTORY_SELECTORS + _grownFactoryAfterThisCut().length,
            "the compiled facet has a different number of functions than the chain mounts plus the named later growth"
        );
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
        // ⚠️ THE REGISTRY IS A PAIR SINCE 16 SEPTEMBER 2026, and this check is a
        // LIVE one — it has to keep being true about this checkout, not describe
        // the day of the cut — so it is taught the pair rather than frozen. The
        // split moved twenty-eight selectors to ArbiterVaultFacet without
        // touching a signature, so "is this selector implemented by the arbiter
        // registry" is now a question about two files. Naming the second one
        // keeps the check exactly as strict: the selector must be implemented by
        // one of the named facets, never merely "somewhere".
        bytes4[] memory vaultAbi = _abiOf("out/ArbiterVaultFacet.sol/ArbiterVaultFacet.json");
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
                    || _contains(vaultAbi, grown[i])
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
        _assertSameSet(
            _concat(upgrade.replaceSelectors(), _grownFactoryAfterThisCut()),
            deploy.factoryFacetSelectors(),
            "FactoryFacet vs DeployFull"
        );
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
        _assertReplaceListCoversTheFacetAllowingLaterGrowth();
        _assertNoAddGroupNeededBeyondTheNamedGrowth();
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
        this.exposed_assertNoAddGroupNeededBeyondTheNamedGrowth();
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
    // ⚠️ A TEST WAS REMOVED HERE ON 14 SEPTEMBER 2026, AND WHERE IT WENT
    // MATTERS MORE THAN WHAT IT SAID.
    //
    // `test_AFreshDeployIsAheadOfTheChainOnlyByAnotherCut` asked whether a diamond built from
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

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }

    /// `vm.expectRevert` needs an external call to watch, and the check it is
    /// pointed at is internal to this contract.
    function exposed_assertNoAddGroupNeededBeyondTheNamedGrowth() external view {
        _assertNoAddGroupNeededBeyondTheNamedGrowth();
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
        // The census this rig is measured against predates the unmount; see the
        // helper's own note for why the script cannot supply this any more.
        _mountHistoricalDealMetadata(d);

        bytes4[] memory onChain = _censusAt(".selectors", ".count");
        _conformToCensus(d, onChain);
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
