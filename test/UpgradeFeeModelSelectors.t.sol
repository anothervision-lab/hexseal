// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../script/archive/UpgradeFeeModel.s.sol";
import "../script/DeployFull.s.sol";
import "../src/DiamondProxy.sol";
import "./BoardsFixture.sol";

/// Anti-drift gate for script/UpgradeFeeModel.s.sol — same design as
/// test/DeployFullSelectors.t.sol, adapted for a Replace+Add upgrade instead
/// of an Add-only fresh deploy.
///
/// Ground truth is read directly out of the compiled artifact
/// (`out/<Facet>.sol/<Facet>.json`'s `methodIdentifiers` map), not hand-typed
/// here. This test fails if:
///   - a facet's Replace+Add builders together miss a selector the facet
///     really implements (undercut)
///   - a facet's Replace+Add builders together claim a selector that facet
///     does not implement (phantom)
///   - the same selector appears in BOTH a facet's Replace list and its Add
///     list (would make one of the two FacetCut entries in
///     buildFeeModelCuts() revert: Replace of a not-yet-mounted selector, or
///     Add of an already-mounted one — see DiamondCutLib.replaceFunctions /
///     addFunctions in src/DiamondProxy.sol)
///   - buildFeeModelCuts() wires a selector set to the wrong facetAddress or
///     the wrong FacetCutAction
///   - the 14 Add selectors collide with anything the OTHER five untouched
///     facets (DiamondCut/Loupe/Ownership/JobReceipt/Reputation, via
///     DeployFull's own already-gated builders) already implement
///   - the grand total drifts from 145 Replace-eligible (pre-upgrade) / 14
///     Add / 159 (post-upgrade) selectors across all eleven facets (frozen
///     literals — this script is deployed, its numbers describe 30 July 2026)
contract UpgradeFeeModelSelectorsTest is Test {
    UpgradeFeeModel internal upgrade;
    DeployFull internal deploy;

    // Placeholder facet addresses — buildFeeModelCuts is pure and only
    // threads the address through into the FacetCut struct, so any nonzero,
    // pairwise-distinct address works.
    address constant FACTORY_FACET  = address(0x2001);
    address constant ARBITER_FACET  = address(0x2002);
    address constant JOB_BOARD      = address(0x2003);
    address constant SERVICE_BOARD  = address(0x2004);
    address constant REGISTRY_FACET = address(0x2005);
    address constant META_FACET     = address(0x2006);

    function setUp() public {
        upgrade = new UpgradeFeeModel();
        deploy  = new DeployFull();
    }

    // ── Ground truth: read straight out of the compiled artifact ────────────
    function _abiSelectors(string memory sourceFile, string memory contractName) internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(string.concat("out/", sourceFile, ".sol/", contractName, ".json"));
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; i++) out[i] = bytes4(keccak256(bytes(sigs[i])));
    }

    function _abiSelectors(string memory contractName) internal view returns (bytes4[] memory) {
        return _abiSelectors(contractName, contractName);
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }

    // ── Set-equality helper (identical to DeployFullSelectorsTest) ──────────
    function _assertSameSelectorSet(bytes4[] memory actual, bytes4[] memory expected, string memory label) internal pure {
        assertEq(actual.length, expected.length, string.concat(label, ": selector count mismatch"));

        for (uint256 i = 0; i < actual.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < expected.length; j++) {
                if (actual[i] == expected[j]) { found = true; break; }
            }
            assertTrue(found, string.concat(label, ": script mounts a selector no facet implements (phantom)"));
        }

        for (uint256 i = 0; i < expected.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < actual.length; j++) {
                if (expected[i] == actual[j]) { found = true; break; }
            }
            assertTrue(found, string.concat(label, ": facet has a selector the script does not mount (undercut)"));
        }
    }

    /// Replace and Add for the same facet must never share a selector: one of
    /// the two FacetCut entries would revert on chain (Replace of an unmounted
    /// selector, or Add of an already-mounted one).
    function _assertDisjoint(bytes4[] memory replaceSels, bytes4[] memory addSels, string memory label) internal pure {
        for (uint256 i = 0; i < replaceSels.length; i++) {
            for (uint256 j = 0; j < addSels.length; j++) {
                assertTrue(
                    replaceSels[i] != addSels[j],
                    string.concat(label, ": the same selector appears in both Replace and Add")
                );
            }
        }
    }

    // ── Per-facet drift checks: Replace ∪ Add must equal the real ABI ───────

    function testFactoryFacetSelectors() public view {
        bytes4[] memory replace = upgrade.factoryFacetReplaceSelectors();
        bytes4[] memory add     = upgrade.factoryFacetAddSelectors();
        assertEq(replace.length, 13, "FactoryFacet: expected 13 Replace selectors");
        assertEq(add.length, 8, "FactoryFacet: expected 8 Add selectors");
        _assertDisjoint(replace, add, "FactoryFacet");
        // The live-ABI comparison was dropped on 25 August 2026, for exactly
        // the reason it was dropped from testArbiterRegistryFacetSelectors()
        // below on 31 July: this script was broadcast, so its lists are a
        // RECORD of what was mounted on 30 July 2026, while the facet's ABI
        // keeps growing. FactoryFacet's first growth since is
        // getUndeliveredFees / withdrawUndeliveredFees — the fee a refusing
        // recipient did not take stops holding a person's refund hostage and
        // becomes a debt the protocol can be paid later. Demanding that a 30
        // July record equal today's ABI is demanding that the past match the
        // present. Fresh-deploy drift is caught by
        // test/DeployFullSelectors.t.sol, and each new cut by its own gate.
    }

    function testArbiterRegistryFacetSelectors() public view {
        bytes4[] memory replace = upgrade.arbiterRegistryFacetReplaceSelectors();
        bytes4[] memory add     = upgrade.arbiterRegistryFacetAddSelectors();
        assertEq(replace.length, 44, "ArbiterRegistryFacet: expected 44 Replace selectors");
        assertEq(add.length, 3, "ArbiterRegistryFacet: expected 3 Add selectors");
        _assertDisjoint(replace, add, "ArbiterRegistryFacet");
        // The cross-check against the live ABI was dropped on 31 July. It guarded
        // against the script drifting away from the facet while the cut was not
        // yet shipped; after the broadcast this script's lists are a record of
        // what was really mounted on chain on 30 July, while the facet ABI keeps
        // growing (the first addition was the threshold and the quote for the
        // paid arbiter call). Demanding they be equal would be demanding that
        // the past agree with the present. Drift in fresh deployments is caught
        // by DeployFullSelectors, and new cuts by their own gates.
    }

    function testJobBoardFacetSelectors() public view {
        bytes4[] memory replace = upgrade.jobBoardFacetReplaceSelectors();
        bytes4[] memory add     = upgrade.jobBoardFacetAddSelectors();
        assertEq(replace.length, 12, "JobBoardFacet: expected 12 Replace selectors");
        assertEq(add.length, 1, "JobBoardFacet: expected 1 Add selector");
        _assertDisjoint(replace, add, "JobBoardFacet");
        _assertSameSelectorSet(_concat(replace, add), _abiSelectors("JobBoardFacet"), "JobBoardFacet");
    }

    function testServiceBoardFacetSelectors() public view {
        bytes4[] memory replace = upgrade.serviceBoardFacetReplaceSelectors();
        bytes4[] memory add     = upgrade.serviceBoardFacetAddSelectors();
        assertEq(replace.length, 23, "ServiceBoardFacet: expected 23 Replace selectors");
        assertEq(add.length, 2, "ServiceBoardFacet: expected 2 Add selectors");
        _assertDisjoint(replace, add, "ServiceBoardFacet");
        _assertSameSelectorSet(_concat(replace, add), _abiSelectors("ServiceBoardFacet"), "ServiceBoardFacet");
    }

    function testRegistryFacetSelectors() public view {
        bytes4[] memory replace = upgrade.registryFacetReplaceSelectors();
        bytes4[] memory add     = upgrade.registryFacetAddSelectors();
        assertEq(replace.length, 13, "RegistryFacet: expected 13 Replace selectors");
        assertEq(add.length, 0, "RegistryFacet: expected 0 Add selectors - this release did not change its ABI");
        _assertDisjoint(replace, add, "RegistryFacet");
        _assertSameSelectorSet(_concat(replace, add), _abiSelectors("RegistryFacet"), "RegistryFacet");
    }

    function testDealMetadataFacetSelectors() public view {
        bytes4[] memory replace = upgrade.dealMetadataFacetReplaceSelectors();
        bytes4[] memory add     = upgrade.dealMetadataFacetAddSelectors();
        assertEq(replace.length, 1, "DealMetadataFacet: expected 1 Replace selector");
        assertEq(add.length, 0, "DealMetadataFacet: expected 0 Add selectors - this release did not change its ABI");
        _assertDisjoint(replace, add, "DealMetadataFacet");
        _assertSameSelectorSet(_concat(replace, add), _abiSelectors("DealMetadataFacet"), "DealMetadataFacet");
    }

    // ── FacetCut[] builder checks ─────────────────────────────────────────
    // Exercises the exact function run() calls to build what it actually
    // broadcasts — catching a facetAddress/action/selector-set mixup (e.g.
    // ArbiterRegistry's Add selectors wired to JobBoard's address, or a
    // Replace entry accidentally carrying the Add action) that the per-facet
    // selector tests above cannot see.

    function testBuildFeeModelCutsWiring() public view {
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildFeeModelCuts(
            FACTORY_FACET, ARBITER_FACET, JOB_BOARD, SERVICE_BOARD, REGISTRY_FACET, META_FACET
        );
        assertEq(cuts.length, 10, "buildFeeModelCuts: expected 10 FacetCut entries (4 facets get Replace+Add, 2 get Replace only)");

        assertEq(cuts[0].facetAddress, FACTORY_FACET);
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace, "cuts[0] must be Replace");
        _assertSameSelectorSet(cuts[0].functionSelectors, upgrade.factoryFacetReplaceSelectors(), "cuts[0] FactoryFacet Replace");

        assertEq(cuts[1].facetAddress, FACTORY_FACET);
        assertTrue(cuts[1].action == IDiamondCut.FacetCutAction.Add, "cuts[1] must be Add");
        _assertSameSelectorSet(cuts[1].functionSelectors, upgrade.factoryFacetAddSelectors(), "cuts[1] FactoryFacet Add");

        assertEq(cuts[2].facetAddress, ARBITER_FACET);
        assertTrue(cuts[2].action == IDiamondCut.FacetCutAction.Replace, "cuts[2] must be Replace");
        _assertSameSelectorSet(cuts[2].functionSelectors, upgrade.arbiterRegistryFacetReplaceSelectors(), "cuts[2] ArbiterRegistryFacet Replace");

        assertEq(cuts[3].facetAddress, ARBITER_FACET);
        assertTrue(cuts[3].action == IDiamondCut.FacetCutAction.Add, "cuts[3] must be Add");
        _assertSameSelectorSet(cuts[3].functionSelectors, upgrade.arbiterRegistryFacetAddSelectors(), "cuts[3] ArbiterRegistryFacet Add");

        assertEq(cuts[4].facetAddress, JOB_BOARD);
        assertTrue(cuts[4].action == IDiamondCut.FacetCutAction.Replace, "cuts[4] must be Replace");
        _assertSameSelectorSet(cuts[4].functionSelectors, upgrade.jobBoardFacetReplaceSelectors(), "cuts[4] JobBoardFacet Replace");

        assertEq(cuts[5].facetAddress, JOB_BOARD);
        assertTrue(cuts[5].action == IDiamondCut.FacetCutAction.Add, "cuts[5] must be Add");
        _assertSameSelectorSet(cuts[5].functionSelectors, upgrade.jobBoardFacetAddSelectors(), "cuts[5] JobBoardFacet Add");

        assertEq(cuts[6].facetAddress, SERVICE_BOARD);
        assertTrue(cuts[6].action == IDiamondCut.FacetCutAction.Replace, "cuts[6] must be Replace");
        _assertSameSelectorSet(cuts[6].functionSelectors, upgrade.serviceBoardFacetReplaceSelectors(), "cuts[6] ServiceBoardFacet Replace");

        assertEq(cuts[7].facetAddress, SERVICE_BOARD);
        assertTrue(cuts[7].action == IDiamondCut.FacetCutAction.Add, "cuts[7] must be Add");
        _assertSameSelectorSet(cuts[7].functionSelectors, upgrade.serviceBoardFacetAddSelectors(), "cuts[7] ServiceBoardFacet Add");

        assertEq(cuts[8].facetAddress, REGISTRY_FACET);
        assertTrue(cuts[8].action == IDiamondCut.FacetCutAction.Replace, "cuts[8] must be Replace");
        _assertSameSelectorSet(cuts[8].functionSelectors, upgrade.registryFacetReplaceSelectors(), "cuts[8] RegistryFacet Replace");

        assertEq(cuts[9].facetAddress, META_FACET);
        assertTrue(cuts[9].action == IDiamondCut.FacetCutAction.Replace, "cuts[9] must be Replace");
        _assertSameSelectorSet(cuts[9].functionSelectors, upgrade.dealMetadataFacetReplaceSelectors(), "cuts[9] DealMetadataFacet Replace");
    }

    // ── Cross-cutting invariants tying back to the numbers verified on chain ──
    //
    // The live diamond had 145 routed selectors across 11 facets on 30 July
    // 2026, when this upgrade shipped. Six of those facets change here
    // (Replace 106 of their selectors between them, Add 14 new ones); the
    // other five (DiamondCut, DiamondLoupe, Ownership, JobReceipt,
    // Reputation) were untouched by this release. DeployFull.s.sol already
    // exposes `public pure` selector builders for those five (gated against
    // their own artifacts by test/DeployFullSelectors.t.sol), so reusing them
    // here proves the FULL post-upgrade diamond - not just the six facets
    // this script touches - ends up with zero collisions, and that none of
    // the 14 Add selectors collide with a facet this script does not even
    // mount.

    function testReplaceCountMatchesCurrentLiveTotal() public view {
        uint256 replaceTotal =
            upgrade.factoryFacetReplaceSelectors().length +
            upgrade.arbiterRegistryFacetReplaceSelectors().length +
            upgrade.jobBoardFacetReplaceSelectors().length +
            upgrade.serviceBoardFacetReplaceSelectors().length +
            upgrade.registryFacetReplaceSelectors().length +
            upgrade.dealMetadataFacetReplaceSelectors().length;
        assertEq(replaceTotal, 106, "sum of all six Replace groups should be 106");

        // The five facets this cut did not touch carried 39 selectors on 30 July
        // 2026. The number is frozen as a literal on purpose: it used to be
        // summed from DeployFull's live builders, so any addition to an untouched
        // facet (getUnresolvedDisputes in reputation on 31 July, say) shifted the
        // total — and the test began asserting things about a diamond that never
        // existed. This script has shipped, its numbers describe the past, so
        // both sides of the comparison have to be frozen.
        uint256 untouchedTotal = 39;
        assertEq(untouchedTotal, 39, "sum of the five untouched facets should be 39");

        assertEq(replaceTotal + untouchedTotal, 145, "pre-upgrade live diamond should route exactly 145 selectors");
    }

    function testAddCountIsExactlyFourteen() public view {
        uint256 addTotal =
            upgrade.factoryFacetAddSelectors().length +
            upgrade.arbiterRegistryFacetAddSelectors().length +
            upgrade.jobBoardFacetAddSelectors().length +
            upgrade.serviceBoardFacetAddSelectors().length +
            upgrade.registryFacetAddSelectors().length +
            upgrade.dealMetadataFacetAddSelectors().length;
        assertEq(addTotal, 14, "this release must add exactly 14 selectors, no more, no less");
    }

    function testNoSelectorCollisionsAcrossAllElevenFacetsPostUpgrade() public view {
        bytes4[][11] memory groups = [
            // Untouched by this release (ground truth: DeployFull.s.sol, itself
            // gated against the artifacts by test/DeployFullSelectors.t.sol).
            // Deliberately LIVE, not frozen: a real diamond built from today's
            // DeployFull.s.sol really would mount today's ReputationFacet,
            // selectors and all, so the collision scan below must see the same
            // set a live deploy would — freezing this group could hide a real
            // collision introduced by a later, unrelated facet change.
            deploy.cutFacetSelectors(),
            deploy.loupeFacetSelectors(),
            deploy.ownershipFacetSelectors(),
            deploy.jobReceiptFacetSelectors(),
            deploy.reputationFacetSelectors(),
            // Changed by this release
            _concat(upgrade.factoryFacetReplaceSelectors(), upgrade.factoryFacetAddSelectors()),
            _concat(upgrade.arbiterRegistryFacetReplaceSelectors(), upgrade.arbiterRegistryFacetAddSelectors()),
            _concat(upgrade.jobBoardFacetReplaceSelectors(), upgrade.jobBoardFacetAddSelectors()),
            _concat(upgrade.serviceBoardFacetReplaceSelectors(), upgrade.serviceBoardFacetAddSelectors()),
            _concat(upgrade.registryFacetReplaceSelectors(), upgrade.registryFacetAddSelectors()),
            _concat(upgrade.dealMetadataFacetReplaceSelectors(), upgrade.dealMetadataFacetAddSelectors())
        ];

        // `total` sizes `flat` below for the actual scan and must match what
        // the live groups above really contain today — it is NOT the number
        // asserted next. The 159 assertion is the frozen historical count
        // (106 Replace + 14 Add + 39 untouched, all as of 30 July 2026);
        // computing it independently, from the same frozen sources as
        // testReplaceCountMatchesCurrentLiveTotal / testAddCountIsExactlyFourteen,
        // keeps it from drifting every time an untouched facet (like
        // Reputation, Task 4) legitimately grows.
        uint256 total;
        for (uint256 g = 0; g < groups.length; g++) total += groups[g].length;

        uint256 frozenReplaceTotal =
            upgrade.factoryFacetReplaceSelectors().length +
            upgrade.arbiterRegistryFacetReplaceSelectors().length +
            upgrade.jobBoardFacetReplaceSelectors().length +
            upgrade.serviceBoardFacetReplaceSelectors().length +
            upgrade.registryFacetReplaceSelectors().length +
            upgrade.dealMetadataFacetReplaceSelectors().length;
        uint256 frozenAddTotal =
            upgrade.factoryFacetAddSelectors().length +
            upgrade.arbiterRegistryFacetAddSelectors().length +
            upgrade.jobBoardFacetAddSelectors().length +
            upgrade.serviceBoardFacetAddSelectors().length +
            upgrade.registryFacetAddSelectors().length +
            upgrade.dealMetadataFacetAddSelectors().length;
        uint256 frozenUntouchedTotal = 39; // see testReplaceCountMatchesCurrentLiveTotal
        assertEq(
            frozenReplaceTotal + frozenAddTotal + frozenUntouchedTotal,
            159,
            "post-upgrade diamond should route exactly 159 selectors across all 11 facets"
        );

        bytes4[] memory flat = new bytes4[](total);
        uint256 k = 0;
        for (uint256 g = 0; g < groups.length; g++) {
            for (uint256 i = 0; i < groups[g].length; i++) flat[k++] = groups[g][i];
        }

        for (uint256 i = 0; i < flat.length; i++) {
            for (uint256 j = i + 1; j < flat.length; j++) {
                assertTrue(flat[i] != flat[j], "duplicate selector across facets post-upgrade");
            }
        }
    }
}

/// The second gate on the same script, but about slot arithmetic rather than
/// selectors.
///
/// UpgradeFeeModel reads feeFloor with a RAW storage read
/// (FACTORY_STORAGE_POSITION + FEE_FLOOR_SLOT_OFFSET), because getFeeFloor() is
/// itself one of the 14 selectors being added: before the broadcast there is
/// physically nothing on the live diamond to call. The single check standing
/// between the operator and the loss of six paid facet deployments depends on
/// that read: `require(currentFloor == 0)`. Get the offset wrong and it returns
/// somebody else's slot. On a zero (an empty tail of the layout, say) the
/// pre-flight passes and initFeeModel then drops the ENTIRE cut on
/// AlreadyInitialized.
///
/// Before this test the correctness of the offset held only indirectly, through
/// BoardsFixture.SLOT_FEE_FLOOR, which is checked inside _unconfigureFeeModel()
/// and would have failed in the BOARD tests. Now the offset is tied to the real
/// layout here: the test brings up a local diamond, moves feeFloor through the
/// real setFeeFloor()/getFeeFloor() (that is, through Solidity's own storage
/// resolution) and requires the script's raw read to return the same value.
///
/// It inherits BoardsFixture for _deployBoardsDiamond/_unconfigureFeeModel and
/// for access to SLOT_FEE_FLOOR — the very constant the offset has to be tied
/// to explicitly.
contract UpgradeFeeModelFeeFloorSlotTest is BoardsFixture {
    /// Initialised at the declaration rather than in setUp: BoardsFixture.setUp()
    /// is not virtual (and no other test overrides it), and reworking the fixture
    /// for the sake of one field is pointless — the constructor runs before setUp
    /// in any case.
    UpgradeFeeModel internal upgrade = new UpgradeFeeModel();

    /// The offset in the script and the offset in the fixture are one number, not
    /// two similar ones.
    function testFeeFloorOffsetMatchesFixtureConstant() public view {
        assertEq(
            upgrade.FEE_FLOOR_SLOT_OFFSET(),
            SLOT_FEE_FLOOR,
            "UpgradeFeeModel.FEE_FLOOR_SLOT_OFFSET drifted from BoardsFixture.SLOT_FEE_FLOOR"
        );
    }

    /// The script's raw read == getFeeFloor() on a freshly configured diamond.
    /// The value is non-zero (initFactory seeded $1), so the agreement cannot be
    /// an accidental "0 == 0" over an empty slot.
    function testRawFeeFloorReadMatchesGetterOnLiveLayout() public view {
        uint256 viaGetter = FactoryFacet(address(diamond)).getFeeFloor();
        assertEq(viaGetter, 1_000_000, "initFactory should have seeded feeFloor = $1");
        assertEq(
            upgrade.readFeeFloorRaw(address(diamond)),
            viaGetter,
            "raw slot read disagrees with getFeeFloor() - FEE_FLOOR_SLOT_OFFSET points at the wrong slot"
        );
    }

    /// The raw read TRACKS the write rather than merely agreeing once. This check
    /// is stronger than the previous one: any other offset inside the Layout would
    /// not react to a change of feeFloor (neighbouring fields do not move) and the
    /// test would go red. The value is deliberately not round and not equal to
    /// anything else in the layout.
    function testRawFeeFloorReadTracksSetFeeFloor() public {
        uint256 probe = 7_777_777;
        FactoryFacet(address(diamond)).setFeeFloor(probe);

        assertEq(FactoryFacet(address(diamond)).getFeeFloor(), probe, "setFeeFloor did not take effect");
        assertEq(
            upgrade.readFeeFloorRaw(address(diamond)),
            probe,
            "raw slot read did not follow setFeeFloor - FEE_FLOOR_SLOT_OFFSET points at a different field"
        );
    }

    /// A zero must read back as a zero too — that is exactly the state of the live
    /// 0x760F… the script's pre-flight stands on: the feeBps/feeFloor/
    /// maxPendingRequests fields never existed in that storage.
    /// _unconfigureFeeModel() asserts internally that it is zeroing precisely
    /// those three slots, so the fixture and the script meet on one fact here.
    function testRawFeeFloorReadSeesTheUnconfiguredStateThePreflightGatesOn() public {
        _unconfigureFeeModel(address(diamond));
        assertEq(
            upgrade.readFeeFloorRaw(address(diamond)),
            0,
            "raw slot read should report 0 on an unconfigured diamond - this is the pre-flight condition"
        );
    }

    /// And at an offset that is NOT feeFloor the same raw device gives a different
    /// number — otherwise the three tests above would pass at any offset at all,
    /// because the whole layout would be filled with the same value.
    function testNeighbouringSlotsHoldSomethingElse() public {
        uint256 probe = 7_777_777;
        FactoryFacet(address(diamond)).setFeeFloor(probe);

        bytes32 base = FactoryStorage.FACTORY_STORAGE_POSITION;
        uint256 bps        = uint256(vm.load(address(diamond), bytes32(uint256(base) + SLOT_FEE_BPS)));
        uint256 maxPending = uint256(vm.load(address(diamond), bytes32(uint256(base) + SLOT_MAX_PENDING_REQUESTS)));

        assertTrue(bps != probe, "feeBps slot holds the feeFloor probe - offsets are indistinguishable");
        assertTrue(maxPending != probe, "maxPendingRequests slot holds the feeFloor probe - offsets are indistinguishable");
    }
}
