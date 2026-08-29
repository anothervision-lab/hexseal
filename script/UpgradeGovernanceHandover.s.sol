// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeGovernanceHandover.s.sol
//
// GOVERNANCE IS HANDED OVER BY A PERSON, IN TWO STEPS, AND A MATTER ALREADY
// UNDER WAY KEEPS THE RULES IT STARTED UNDER — decisions 50, 51 and 52
// One diamondCut, THREE elements:
//
//   Replace 55 -> new ArbiterRegistryFacet
//   Add       2 -> the SAME new ArbiterRegistryFacet
//   Replace 35 -> new ArbiterAccountabilityFacet
//
//   13 facets -> 13 facets, 216 routed selectors -> 218
//
// WHAT SHIPS.
//
//   THE SWITCH    `isDaoActive()` stops being "manual flag OR threshold" and
//                 becomes the manual flag alone. The threshold survives as a
//                 CONDITION on the owner's own press, and drops from 100 000 to
//                 10 000 unique active users. Before this cut, strangers could
//                 latch the second half of the predicate with their own
//                 activity, with no successor named: DAO mode switches on, the
//                 three doors into the corps shut, the chief's authority dies,
//                 and there is nobody to hand anything to.
//
//   THE HANDOVER  `setDAOAddress` stops taking effect immediately. It PROPOSES;
//                 the named address takes office only by sending
//                 `acceptDAOAddress()` itself. The second step does not vet a
//                 candidate — `daoAddress` is a governance contract or multisig
//                 the owner deploys himself. It proves the door opens FROM THE
//                 INSIDE: a typo sends no transaction, and neither do lost keys.
//                 One wrong letter used to mean nobody could ever remove an
//                 arbiter again, with no way back.
//
//   THE RECORD    The appeal deposit and the accusation's TTL are written INTO
//                 the record when the record is created, instead of being read
//                 live from a constant on every touch. Today a cut that shortens
//                 `PROPOSAL_TTL` expires an eight-day-old accusation instantly,
//                 with no transaction at all, and the refund to a winning
//                 appellant pays today's `APPEAL_DEPOSIT` rather than what he
//                 actually put in.
//
// ⚠️ WHY THE ACCOUNTABILITY FACET IS IN THE CUT AT ALL, WITH THE SAME 35
// SELECTORS IT ALREADY HAS. The switch and the record changed its BODY, not its ABI:
// it carries the mirrored DAO threshold (`DAO_THRESHOLD_MIRROR`, 100 000 ->
// 10 000) and it is the facet that WRITES the TTL into a `RemovalProposal`. Its
// executable bytecode differs from what is deployed — measured, not assumed:
// the on-chain code at 0x04d69d8e83FD9c88850E85aa333Af078Fcd39836 and the local
// build disagree once the CBOR metadata tail is stripped. A facet's selectors
// cannot be split across two addresses, so all 35 move together or none do.
//
// Because the count does not change, the ONLY proof the new code is live after
// the cut is a behavioural read, and there is one:
// `getDaoThresholdMirror()` answers 100 000 today and must answer 10 000 after.
// The post-flight below refuses if it does not.
//
// ⚠️ THIS CUT CAN MEET BOTH HALVES OF THE PAIR THAT DROPS A CUT ON ONE LIVE
// TRANSACTION. `Replace` reverts "Diamond: selector not found" on a selector
// that is not mounted; `Add` reverts "Diamond: selector exists" on one that is.
// Filing `acceptDAOAddress` or `getPendingDAOAddress` under Replace, or any of
// the other 55 under Add, reverts the whole thing AFTER two facets have already
// been paid for.
//
// So the composition is held against two sources, and NEITHER of them is this
// script:
//
//   * solc's own `methodIdentifiers`, read out of the build artifacts, answers
//     "does the cut mount exactly what the facets implement";
//   * the live diamond's loupe, asked here at run time and asked offline in
//     test/GovernanceHandoverUpgrade.t.sol against a census committed as data
//     (test/fixtures/chain-2026-08-27-arbiter-governance-selectors.json),
//     answers "is each Replace selector mounted today and each Add selector
//     mounted nowhere".
//
// A stand that built "what is mounted" out of this script's own
// `registryReplaceSelectors()` would agree with itself no matter which group a
// selector was filed under. That is the fourth way to be fooled by a
// measurement, and it cost a whole cut once.
//
// ⚠️ WHAT THIS CUT DOES NOT DO. `Treasury.DAO_THRESHOLD` is a separate constant
// in a deployed, immutable contract and still says 100 000. Decision 50 says the
// two are meant to agree; making them agree means deploying another treasury,
// which is not this work. Until then it is a KNOWN disagreement, written down
// here and in the facet, not an oversight.
//
// RUN IT DRY FIRST (no --broadcast):
//   forge script script/UpgradeGovernanceHandover.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

contract UpgradeGovernanceHandover is Script {

    /// Build artifacts this script holds its own selector lists against.
    /// Read through `vm.readFile`; `./out` is already in `fs_permissions`.
    string internal constant REGISTRY_ARTIFACT =
        "out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json";
    string internal constant ACCOUNTABILITY_ARTIFACT =
        "out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json";

    /// The number from a recorded decision, written here by a person
    /// rather than read from the facet. That is the whole point: the facet is
    /// the thing being checked, so the expected side may not come from it.
    uint256 public constant DAO_THRESHOLD_AFTER = 10_000;

    /// And what the chain answers TODAY, so a cut that has already landed is
    /// refused with a sentence instead of a revert nobody can read.
    uint256 public constant DAO_THRESHOLD_BEFORE = 100_000;

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeGovernanceHandover.s.sol";
    }

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);

        // ── Pre-flight: everything checkable before a wei is spent ─────────
        require(diamond != address(0), "upgrade: DIAMOND_ADDRESS is zero");
        require(diamond.code.length > 0, "upgrade: DIAMOND_ADDRESS has no code");

        // Code is not enough. TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT
        // live in the same .env and all three have code, so a typo would sail
        // through the check above. Probe a selector only this diamond answers.
        address currentOwner = _readAddress(diamond, "owner()");
        require(
            currentOwner == broadcaster,
            "upgrade: PRIVATE_KEY is not the diamond owner - diamondCut would revert after a paid deploy"
        );

        bytes4[] memory regSels = registryReplaceSelectors();
        bytes4[] memory addSels = registryAddSelectors();
        bytes4[] memory accSels = accountabilityReplaceSelectors();

        // The hand-written lists against solc's own output, both ways.
        assertListsCoverTheCompiledFacets(regSels, addSels, accSels);

        // Replace groups: every one of them must be mounted TODAY, and each
        // group all on one facet, or `Replace` reverts and takes the cut.
        address previousRegistry = assertAllMountedOnOneFacet(regSels, diamond);
        address previousAccountability = assertAllMountedOnOneFacet(accSels, diamond);
        require(
            previousRegistry != previousAccountability,
            "pre-flight: both groups sit on the same facet - this cut assumes two"
        );

        // And each facet must expose nothing else, or the cut leaves a selector
        // pointing at an address that no longer implements it.
        assertNothingIsLeftBehind(regSels, previousRegistry, diamond);
        assertNothingIsLeftBehind(accSels, previousAccountability, diamond);

        // Add group: mounted NOWHERE in the whole diamond, not merely absent
        // from ArbiterRegistryFacet. `Add` reverts on a selector routed anywhere.
        assertAddGroupIsUnmountedAnywhere(addSels, diamond);

        // The chain must still be the one this cut was written for. Both
        // thresholds read the OLD number today; if either already reads the new
        // one, this cut has landed and running it again would revert on the Add
        // group with a message about selectors rather than about the situation.
        assertBothThresholdsRead(diamond, DAO_THRESHOLD_BEFORE, "pre-flight");

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        uint256 facetsBefore    = IDiamondLoupe(diamond).facetAddresses().length;
        StorageSnapshot memory beforeCut = snapshotArbitration(diamond);

        console.log("=== UpgradeGovernanceHandover: pre-flight ===");
        console.log("Diamond:                          ", diamond);
        console.log("Owner:                            ", currentOwner);
        console.log("Current ArbiterRegistryFacet:     ", previousRegistry);
        console.log("Current ArbiterAccountabilityFacet:", previousAccountability);
        console.log("Facets BEFORE cut:                ", facetsBefore);
        console.log("Routed selectors BEFORE cut:      ", selectorsBefore);
        console.log("Replace (ArbiterRegistry):        ", regSels.length);
        console.log("Add     (ArbiterRegistry, new):   ", addSels.length);
        console.log("Replace (ArbiterAccountability):  ", accSels.length);
        console.log("Routed selectors AFTER cut will be:", selectorsBefore + addSels.length);
        console.log("DAO threshold now (both copies):  ", beforeCut.daoThreshold);
        console.log("DAO threshold after the cut:      ", DAO_THRESHOLD_AFTER);
        console.log("Seated arbiters:                  ", beforeCut.arbiterCount);
        console.log("Chief arbiter:                    ", beforeCut.chiefArbiter);
        console.log("DAO address (in office):          ", beforeCut.daoAddress);
        console.log("DAO mode active:                  ", beforeCut.daoActive);
        console.log("Arbiter vault balance:            ", beforeCut.vaultBalance);
        console.log("Treasury slice held:              ", beforeCut.treasurySlice);
        console.log("Proposal TTL:                     ", beforeCut.proposalTtl);
        console.log("");

        // ── The cut ────────────────────────────────────────────────────────
        vm.startBroadcast(pk);
        ArbiterRegistryFacet registryFacet = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet accountabilityFacet = new ArbiterAccountabilityFacet();
        IDiamondCut(diamond).diamondCut(
            buildCuts(address(registryFacet), address(accountabilityFacet)),
            address(0),
            ""
        );
        vm.stopBroadcast();

        console.log("New ArbiterRegistryFacet:      ", address(registryFacet));
        console.log("New ArbiterAccountabilityFacet:", address(accountabilityFacet));
        console.log("");

        // ── Post-flight: read the result back, do not assume it ────────────
        console.log("=== Post-flight ===");
        assertRouted(regSels, address(registryFacet), diamond);
        assertRouted(addSels, address(registryFacet), diamond);
        assertRouted(accSels, address(accountabilityFacet), diamond);
        console.log("All ninety replaced selectors and both new ones land on the new facets.");

        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(registryFacet)).length
                == regSels.length + addSels.length,
            "post-flight: the new ArbiterRegistryFacet does not hold the replaced selectors plus the two new ones"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(accountabilityFacet)).length == accSels.length,
            "post-flight: the new ArbiterAccountabilityFacet holds a different number of selectors than were replaced"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousRegistry).length == 0
                && IDiamondLoupe(diamond).facetFunctionSelectors(previousAccountability).length == 0,
            "post-flight: an old facet still holds selectors - a Replace did not move all of them"
        );

        assertStorageContinuity(beforeCut, snapshotArbitration(diamond));
        console.log("Storage continuity OK: the corps, the chief, the DAO address, the vault and the slice are where they were.");

        // The two smokes that say the cut did what it was FOR, one per facet.
        assertBothThresholdsRead(diamond, DAO_THRESHOLD_AFTER, "post-flight");
        console.log("Decision 50 is live: both copies of the threshold now read 10 000.");
        console.log("  (the registry's copy proves the new ArbiterRegistryFacet is running,");
        console.log("   the mirror proves the new ArbiterAccountabilityFacet is - it has the");
        console.log("   same 35 selectors as before, so nothing else could tell.)");

        assertTheHandoverDoorAnswersAndIsEmpty(diamond);
        console.log("Decision 51 is live: getPendingDAOAddress() answers, and it answers nobody -");
        console.log("  no successor was ever proposed on a diamond that never ran this code.");

        uint256 selectorsAfter = totalRoutedSelectors(diamond);
        uint256 facetsAfter    = IDiamondLoupe(diamond).facetAddresses().length;
        require(
            selectorsAfter == selectorsBefore + addSels.length,
            "post-flight: the routed-selector count moved by something other than the Add group"
        );
        require(
            facetsAfter == facetsBefore,
            "post-flight: the facet count moved - the old facets should have been emptied, not unmounted"
        );
        console.log("Facets AFTER cut:            ", facetsAfter);
        console.log("Routed selectors AFTER cut:  ", selectorsAfter);
        console.log("");

        console.log("Governance now moves because a person moved it, and the named successor");
        console.log("has to open the door from the inside.");
        console.log("");
        // ⚠️ Still open: on 21 August this same
        // pair of facets shipped UNVERIFIED because the script fell over on a
        // receipt before it reached `--verify`, and nobody noticed until the
        // owner asked. Nothing in a post-flight can see Basescan, so the least
        // this cut can do is say the two addresses out loud at the end, where
        // they are not buried above the post-flight output.
        console.log("VERIFY THESE TWO ON BASESCAN before calling the cut done - `--verify` is");
        console.log("not reached if the run trips on a receipt, and that is how three contracts");
        console.log("shipped unverified on 21 August:");
        console.log("  ArbiterRegistryFacet:      ", address(registryFacet));
        console.log("  ArbiterAccountabilityFacet:", address(accountabilityFacet));
        console.log("");
        console.log("WARNING: Treasury.DAO_THRESHOLD still says 100 000 and this cut cannot change it -");
        console.log("   the treasury is deployed and immutable. Known and deliberate.");
        console.log("");
        console.log("Rollback (points the ninety replaced selectors back at the previous facets,");
        console.log("which are still on chain and still work - they are the code running today):");
        console.log("  forge script script/UpgradeGovernanceHandover.s.sol \\");
        console.log("    --sig \"rollback(address,address)\" <registry> <accountability> \\");
        console.log("    --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast");
        console.log("  <registry>       =", previousRegistry);
        console.log("  <accountability> =", previousAccountability);
        console.log("");
        console.log("WARNING: rolling back REMOVES the two new selectors as well. A successor");
        console.log("proposed while the new code was live stays in the appended storage field");
        console.log("with no function left to accept it, and setDAOAddress goes back to taking");
        console.log("effect on the spot. The rollback below refuses when a proposal is standing.");
    }

    /// Undo, as a command rather than as a paragraph somebody has to
    /// transcribe. Points the ninety replaced selectors back at the previous
    /// facets, removes the two added ones, and refuses if the chain is not in
    /// the state that follows this cut — a rollback that runs against an
    /// unexpected diamond is how one mistake becomes two.
    function rollback(address previousRegistry, address previousAccountability) external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        require(diamond != address(0), "rollback: DIAMOND_ADDRESS is zero");
        require(
            previousRegistry != address(0) && previousAccountability != address(0),
            "rollback: a previous facet is zero"
        );
        require(
            previousRegistry.code.length > 0 && previousAccountability.code.length > 0,
            "rollback: a previous facet has no code"
        );
        require(
            previousRegistry != previousAccountability,
            "rollback: the two previous facets are the same address"
        );

        bytes4[] memory regSels = registryReplaceSelectors();
        bytes4[] memory addSels = registryAddSelectors();
        bytes4[] memory accSels = accountabilityReplaceSelectors();

        // Only roll back a diamond this cut actually landed on.
        assertAllMountedOnOneFacet(regSels, diamond);
        assertAllMountedOnOneFacet(accSels, diamond);
        for (uint256 i = 0; i < addSels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(addSels[i]) != address(0),
                "rollback: an added selector is not mounted - this cut did not land here"
            );
        }

        // ⚠️ THE ONE STATE THE ROLLBACK CANNOT CARRY BACK. `acceptDAOAddress`
        // is about to be removed; a successor already proposed would sit in
        // storage with no door left to walk through, while `setDAOAddress`
        // returns to taking effect immediately. Refuse rather than strand him.
        (bool ok, bytes memory ret) = diamond.staticcall(
            abi.encodeWithSelector(ArbiterRegistryFacet.getPendingDAOAddress.selector)
        );
        require(ok && ret.length >= 32, "rollback: the diamond does not answer getPendingDAOAddress()");
        require(
            abi.decode(ret, (address)) == address(0),
            "rollback: a successor is proposed and not yet seated - removing acceptDAOAddress would strand him"
        );

        IDiamondCut.FacetCut[] memory undo = new IDiamondCut.FacetCut[](3);
        undo[0] = IDiamondCut.FacetCut(previousRegistry, IDiamondCut.FacetCutAction.Replace, regSels);
        undo[1] = IDiamondCut.FacetCut(previousAccountability, IDiamondCut.FacetCutAction.Replace, accSels);
        undo[2] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, addSels);

        vm.startBroadcast(pk);
        IDiamondCut(diamond).diamondCut(undo, address(0), "");
        vm.stopBroadcast();

        assertRouted(regSels, previousRegistry, diamond);
        assertRouted(accSels, previousAccountability, diamond);
        for (uint256 i = 0; i < addSels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(addSels[i]) == address(0),
                "rollback: an added selector is still routed"
            );
        }
        assertBothThresholdsRead(diamond, DAO_THRESHOLD_BEFORE, "rollback");
        console.log("Rolled back. Both thresholds read 100 000 again and the second step is gone.");
    }

    // ════════════════════════════════════════════════════════════════════
    // THE INDEPENDENT ORACLES
    // ════════════════════════════════════════════════════════════════════

    /// The hand-written lists against solc's own answer to "what does this
    /// facet expose". Set equality in both directions, per facet:
    ///
    ///   * a function the facet implements and this cut does not mount would
    ///     ship dead — present in the ABI, routed nowhere, discovered by the
    ///     first person whose button did nothing;
    ///   * a selector this cut mounts and the facet does not implement routes
    ///     calls into whatever byte offset happens to be there.
    ///
    /// ArbiterRegistryFacet is checked as Replace ∪ Add, which is the whole
    /// point of the split: a selector that drifts from one group to the other
    /// keeps the union identical and would still revert the cut on chain. That
    /// half is answered by `assertAllMountedOnOneFacet` and
    /// `assertAddGroupIsUnmountedAnywhere`, whose expected side is the chain.
    function assertListsCoverTheCompiledFacets(
        bytes4[] memory regSels,
        bytes4[] memory addSels,
        bytes4[] memory accSels
    ) public view {
        _assertSameSet(_concat(regSels, addSels), artifactSelectors(REGISTRY_ARTIFACT), "ArbiterRegistryFacet");
        _assertSameSet(accSels, artifactSelectors(ACCOUNTABILITY_ARTIFACT), "ArbiterAccountabilityFacet");

        // And the two registry groups must be disjoint, or one of the two
        // FacetCut entries reverts by construction.
        for (uint256 i = 0; i < regSels.length; i++) {
            for (uint256 j = 0; j < addSels.length; j++) {
                require(
                    regSels[i] != addSels[j],
                    "pre-flight: a selector is in both the registry Replace group and the Add group"
                );
            }
        }
    }

    /// solc's own answer to "what does this facet expose", straight out of the
    /// build artifact. `methodIdentifiers` maps the signature to the four-byte
    /// selector as text, so nothing has to be hashed here.
    function artifactSelectors(string memory artifactPath) public view returns (bytes4[] memory out) {
        string memory json = vm.readFile(artifactPath);
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i = 0; i < sigs.length; i++) {
            out[i] = bytes4(keccak256(bytes(sigs[i])));
        }
    }

    /// Every selector must be routed TODAY, and all of them to the same
    /// address. An unmounted one belongs in `Add`, not in `Replace`, and
    /// putting it in the wrong group reverts the whole cut. Returns the facet
    /// they are on.
    function assertAllMountedOnOneFacet(bytes4[] memory sels, address diamond)
        public view returns (address host)
    {
        host = IDiamondLoupe(diamond).facetAddress(sels[0]);
        require(
            host != address(0),
            "pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert"
        );
        for (uint256 i = 1; i < sels.length; i++) {
            address where = IDiamondLoupe(diamond).facetAddress(sels[i]);
            require(
                where != address(0),
                "pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert"
            );
            require(
                where == host,
                "pre-flight: a Replace group is spread over more than one facet - this cut assumes one facet per group"
            );
        }
    }

    /// The other direction of the same question: the facet being replaced must
    /// not hold a selector this cut does not carry. One left behind would keep
    /// pointing at an address whose code no longer implements it — a live
    /// button answering with whatever that old byte offset happens to be.
    function assertNothingIsLeftBehind(bytes4[] memory sels, address previousFacet, address diamond)
        public view
    {
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousFacet).length == sels.length,
            "pre-flight: a facet being replaced holds a different number of selectors than this cut carries"
        );
    }

    /// ⚠️ THE HALF THAT IS EASIEST TO GET WRONG. `Add` reverts on a selector
    /// already routed, so "not on ArbiterRegistryFacet" is the wrong question —
    /// the right one is "not routed ANYWHERE in this diamond".
    ///
    /// Asked of the loupe, over the whole diamond, and NOT of this script's own
    /// lists: a stand that built "what is mounted" out of
    /// `registryReplaceSelectors()` would agree with itself no matter which
    /// group a selector was filed under. That is the fourth way to be fooled by
    /// a measurement, and it cost a whole cut once.
    function assertAddGroupIsUnmountedAnywhere(bytes4[] memory addSels, address diamond) public view {
        for (uint256 i = 0; i < addSels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(addSels[i]) == address(0),
                "pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert"
            );
        }
    }

    function assertRouted(bytes4[] memory sels, address expected, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                "post-flight: a selector did not land on the new facet"
            );
        }
    }

    /// Decision 50, read back through the diamond — and the ONLY thing that can
    /// tell whether the accountability facet's new code is live, because its
    /// selector set did not change by one.
    ///
    /// Both copies are asked, and they must agree with each other as well as
    /// with the expected number: one lives in ArbiterRegistryFacet
    /// (`DAO_THRESHOLD`), the other in ArbiterAccountabilityFacet
    /// (`DAO_THRESHOLD_MIRROR`). A cut that landed one facet and not the other
    /// would leave them disagreeing, and nothing else in this script would say
    /// so.
    function assertBothThresholdsRead(address diamond, uint256 expected, string memory phase) public view {
        uint256 registry = _readUint(diamond, ArbiterRegistryFacet.getDaoThreshold.selector, "getDaoThreshold()");
        uint256 mirror = _readUint(
            diamond, ArbiterAccountabilityFacet.getDaoThresholdMirror.selector, "getDaoThresholdMirror()"
        );
        require(
            registry == expected,
            string.concat(phase, ": ArbiterRegistryFacet.getDaoThreshold() is not the number this phase expects")
        );
        require(
            mirror == expected,
            string.concat(
                phase,
                ": ArbiterAccountabilityFacet.getDaoThresholdMirror() is not the number this phase expects"
                " - the accountability facet's code did not move"
            )
        );
    }

    /// Decision 51's door, read back: it answers at all (so the Add group
    /// landed and routes), and it answers nobody. A non-zero successor on a
    /// diamond that has never run this code would mean the appended field reads
    /// somebody else's slot — the layout moved, and the cut has to be undone
    /// before anything touches the corps.
    function assertTheHandoverDoorAnswersAndIsEmpty(address diamond) public view {
        (bool ok, bytes memory ret) = diamond.staticcall(
            abi.encodeWithSelector(ArbiterRegistryFacet.getPendingDAOAddress.selector)
        );
        require(ok && ret.length >= 32, "post-flight: the diamond does not answer getPendingDAOAddress()");
        require(
            abi.decode(ret, (address)) == address(0),
            "post-flight: a successor is already proposed on a diamond that never ran this code - the layout may have shifted"
        );
    }

    function totalRoutedSelectors(address diamond) public view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(diamond).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    // ════════════════════════════════════════════════════════════════════
    // Storage continuity
    // ════════════════════════════════════════════════════════════════════

    struct StorageSnapshot {
        uint256 arbiterCount;
        address firstArbiter;
        address chiefArbiter;
        address daoAddress;
        bool    daoActive;
        uint256 vaultBalance;
        uint256 treasurySlice;
        uint256 rewardPerDispute;
        uint256 arbiterFloor;
        uint256 daoThreshold;
        uint256 proposalTtl;
    }

    /// The arbitration namespace read through the diamond, before and after.
    ///
    /// `ArbiterRegistryStorage.Data` is what BOTH facets in this cut share, and
    /// this work appended a field to it (`pendingDaoAddress`) and two fields to
    /// structs inside it (`PendingVerdict.appealDeposit`,
    /// `RemovalProposal.ttl`). Appended in the wrong place, any of the three
    /// would read a live one — and a corps that had silently lost its bond
    /// ledger would look, from every other angle, exactly healthy.
    function snapshotArbitration(address diamond) public view returns (StorageSnapshot memory s) {
        ArbiterRegistryFacet reg = ArbiterRegistryFacet(diamond);
        address[] memory arbiters = reg.getArbiters();
        s.arbiterCount = arbiters.length;
        if (arbiters.length > 0) s.firstArbiter = arbiters[0];
        s.chiefArbiter     = reg.getChiefArbiter();
        s.daoAddress       = reg.getDAOAddress();
        s.daoActive        = reg.isDaoActive();
        s.vaultBalance     = reg.getVaultBalance();
        s.treasurySlice    = reg.getTreasurySlice();
        s.rewardPerDispute = reg.getRewardPerDispute();
        s.arbiterFloor     = reg.getArbiterFloor();
        s.daoThreshold     = reg.getDaoThreshold();
        s.proposalTtl      = ArbiterAccountabilityFacet(diamond).getProposalTTL();
    }

    /// ⚠️ `daoThreshold` is DELIBERATELY not compared: it is the one reading
    /// this cut is meant to change, and `assertBothThresholdsRead` owns it.
    /// Everything else must stand still.
    function assertStorageContinuity(StorageSnapshot memory beforeCut, StorageSnapshot memory afterCut)
        public pure
    {
        require(
            afterCut.arbiterCount == beforeCut.arbiterCount,
            "post-flight: the number of seated arbiters changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.firstArbiter == beforeCut.firstArbiter,
            "post-flight: the first seated arbiter changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.chiefArbiter == beforeCut.chiefArbiter,
            "post-flight: the chief arbiter changed across the cut"
        );
        require(
            afterCut.daoAddress == beforeCut.daoAddress,
            "post-flight: the DAO address changed across the cut - setDAOAddress must now only PROPOSE"
        );
        require(
            afterCut.daoActive == beforeCut.daoActive,
            "post-flight: DAO mode flipped across the cut"
        );
        require(
            afterCut.vaultBalance == beforeCut.vaultBalance,
            "post-flight: the arbiter vault moved across the cut"
        );
        require(
            afterCut.treasurySlice == beforeCut.treasurySlice,
            "post-flight: the treasury slice moved across the cut"
        );
        require(
            afterCut.rewardPerDispute == beforeCut.rewardPerDispute,
            "post-flight: the reward per dispute changed across the cut"
        );
        require(
            afterCut.arbiterFloor == beforeCut.arbiterFloor,
            "post-flight: the arbiter floor changed across the cut"
        );
        require(
            afterCut.proposalTtl == beforeCut.proposalTtl,
            "post-flight: the proposal TTL changed across the cut - the record stores its own TTL, the cut does not shorten it"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // THE CUT
    // ════════════════════════════════════════════════════════════════════

    /// Three elements. Two whole facets move address, and ArbiterRegistryFacet
    /// additionally gains two functions — so the Add group is its own element
    /// on the same address, because one FacetCut carries one action.
    function buildCuts(address registryFacet, address accountabilityFacet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut(registryFacet, IDiamondCut.FacetCutAction.Replace, registryReplaceSelectors());
        cuts[1] = IDiamondCut.FacetCut(registryFacet, IDiamondCut.FacetCutAction.Add, registryAddSelectors());
        cuts[2] = IDiamondCut.FacetCut(
            accountabilityFacet, IDiamondCut.FacetCutAction.Replace, accountabilityReplaceSelectors()
        );
    }

    /// Fifty-five — everything ArbiterRegistryFacet routes on Base Sepolia
    /// today. Taken from the type rather than typed as literals: a signature
    /// change is then picked up by the compiler instead of by whoever presses
    /// the button. Held against the build artifact in
    /// `assertListsCoverTheCompiledFacets` and against the live chain in
    /// `assertAllMountedOnOneFacet`.
    ///
    /// One of them changed BEHAVIOUR in this work — `setDAOAddress`, which now
    /// only proposes — and two more read differently because
    /// `isDaoActive` lost its second half and `DAO_THRESHOLD` dropped
    /// (100 000 -> 10 000). The rest are here because a Replace must carry the
    /// facet's whole selector set or leave the remainder pointing at the old
    /// address.
    function registryReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](55);

        // DAO mode and the corps
        sels[0]  = ArbiterRegistryFacet.activateDAO.selector;
        sels[1]  = ArbiterRegistryFacet.applyAsArbiter.selector;
        sels[2]  = ArbiterRegistryFacet.resignAsArbiter.selector;
        sels[3]  = ArbiterRegistryFacet.setChiefArbiter.selector;
        sels[4]  = ArbiterRegistryFacet.addArbiter.selector;

        // Claiming a dispute (commit-reveal)
        sels[5]  = ArbiterRegistryFacet.commitDisputeClaim.selector;
        sels[6]  = ArbiterRegistryFacet.claimDispute.selector;
        sels[7]  = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        sels[8]  = ArbiterRegistryFacet.clearDisputeClaim.selector;

        // Verdict
        sels[9]  = ArbiterRegistryFacet.submitVerdict.selector;
        sels[10] = ArbiterRegistryFacet.finalizeVerdict.selector;
        sels[11] = ArbiterRegistryFacet.overturnVerdict.selector;
        sels[12] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        sels[13] = ArbiterRegistryFacet.freezeVerdict.selector;
        sels[14] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        sels[15] = ArbiterRegistryFacet.clearStuckVerdict.selector;

        // Appeal — `raiseAppeal` now writes APPEAL_DEPOSIT into the record and
        // `resolveAppeal` refunds what is written there, not today's constant.
        sels[16] = ArbiterRegistryFacet.raiseAppeal.selector;      // changed
        sels[17] = ArbiterRegistryFacet.voteOnAppeal.selector;
        sels[18] = ArbiterRegistryFacet.resolveAppeal.selector;    // changed

        // Rewards
        sels[19] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        sels[20] = ArbiterRegistryFacet.fundVault.selector;
        sels[21] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        sels[22] = ArbiterRegistryFacet.setDAOAddress.selector;    // changed: proposes only

        // Views
        sels[23] = ArbiterRegistryFacet.isDaoActive.selector;      // changed: manual flag alone
        sels[24] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        sels[25] = ArbiterRegistryFacet.getDaoThreshold.selector;  // changed: 100 000 -> 10 000
        sels[26] = ArbiterRegistryFacet.getChiefArbiter.selector;
        sels[27] = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        sels[28] = ArbiterRegistryFacet.getArbiters.selector;
        sels[29] = ArbiterRegistryFacet.getDisputeClaimer.selector;
        sels[30] = ArbiterRegistryFacet.getClaimCommitment.selector;
        sels[31] = ArbiterRegistryFacet.getPendingVerdict.selector;
        sels[32] = ArbiterRegistryFacet.getVaultBalance.selector;
        sels[33] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        sels[34] = ArbiterRegistryFacet.getDAOAddress.selector;
        sels[35] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        sels[36] = ArbiterRegistryFacet.getAppealVotes.selector;
        sels[37] = ArbiterRegistryFacet.hasVotedOnAppeal.selector;

        // Dispute settlement fee — 80/20 arbiter/treasury
        sels[38] = ArbiterRegistryFacet.creditDisputeFee.selector;
        sels[39] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        sels[40] = ArbiterRegistryFacet.getTreasurySlice.selector;

        // Paid call for an arbiter: floor and the quote to reach it
        sels[41] = ArbiterRegistryFacet.setArbiterFloor.selector;
        sels[42] = ArbiterRegistryFacet.getArbiterFloor.selector;
        sels[43] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;

        // Paid call for an arbiter: payment and the soft refund
        sels[44] = ArbiterRegistryFacet.fundDispute.selector;
        sels[45] = ArbiterRegistryFacet.getDisputeBounty.selector;
        sels[46] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        sels[47] = ArbiterRegistryFacet.getRefundableBounty.selector;

        // The arbiter's chat key
        sels[48] = ArbiterRegistryFacet.setArbiterChatKey.selector;

        // The chain as a witness: "asked, no answer" and the presentation digest
        sels[49] = ArbiterRegistryFacet.recordNoResponse.selector;
        sels[50] = ArbiterRegistryFacet.getNoResponseFloor.selector;
        sels[51] = ArbiterRegistryFacet.recordPresentationDigest.selector;

        // Ceilings read from this side
        sels[52] = ArbiterRegistryFacet.getChiefBloc.selector;
        sels[53] = ArbiterRegistryFacet.getMaxClaimsPerArbiter.selector;
        sels[54] = ArbiterRegistryFacet.getMaxArbiterMistakes.selector;
    }

    /// The two that do not exist on chain yet, and the only reason this cut has
    /// an Add group at all. Filed here and nowhere else: putting either of them
    /// in the Replace group reverts the whole cut with "Diamond: selector not
    /// found", after two facets have already been paid for.
    ///
    ///   acceptDAOAddress()     0x02950d24  — the successor opens the door himself
    ///   getPendingDAOAddress() 0xde73a6fa  — and anyone can see who was named
    ///
    /// Verified unmounted two ways on 27 August 2026: absent from the whole
    /// routed list in the census fixture, and answered by the live diamond with
    /// "Diamond: function not found".
    function registryAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](2);
        sels[0] = ArbiterRegistryFacet.acceptDAOAddress.selector;
        sels[1] = ArbiterRegistryFacet.getPendingDAOAddress.selector;
    }

    /// Thirty-five — the whole of today's ArbiterAccountabilityFacet, and
    /// exactly as many as it has on chain right now. NONE of them is new; the
    /// facet is in this cut because its BODY changed and a facet's selectors
    /// cannot be split across two addresses.
    ///
    /// What changed inside: `DAO_THRESHOLD_MIRROR` (100 000 -> 10 000) and the TTL
    /// written into a `RemovalProposal` when it is raised. Both
    /// are invisible to the loupe, which is why the post-flight reads
    /// `getDaoThresholdMirror()` instead of counting selectors and calling it
    /// proof.
    function accountabilityReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](35);

        // Suspension
        sels[0]  = ArbiterAccountabilityFacet.suspendArbiter.selector;
        sels[1]  = ArbiterAccountabilityFacet.liftSuspension.selector;
        sels[2]  = ArbiterAccountabilityFacet.isSuspended.selector;
        sels[3]  = ArbiterAccountabilityFacet.getSuspendedUntil.selector;
        sels[4]  = ArbiterAccountabilityFacet.getSuspensionWindow.selector;

        // Removal with a cause, and the chain's own accusation
        sels[5]  = ArbiterAccountabilityFacet.removeArbiterForCause.selector;
        sels[6]  = ArbiterAccountabilityFacet.executeChainRemoval.selector;

        // The chief's proposal, and the accused man's right of reply.
        // `proposeRemoval` now writes the TTL into the record.
        sels[7]  = ArbiterAccountabilityFacet.proposeRemoval.selector;   // changed
        sels[8]  = ArbiterAccountabilityFacet.withdrawProposal.selector;
        sels[9]  = ArbiterAccountabilityFacet.hasLiveProposal.selector;  // changed: reads the stored TTL
        sels[10] = ArbiterAccountabilityFacet.getRemovalProposal.selector;
        sels[11] = ArbiterAccountabilityFacet.getProposalTTL.selector;
        sels[12] = ArbiterAccountabilityFacet.getRemovalDelay.selector;
        sels[13] = ArbiterAccountabilityFacet.respondToRemoval.selector;
        sels[14] = ArbiterAccountabilityFacet.getRemovalReply.selector;
        sels[15] = ArbiterAccountabilityFacet.getMaxReasonBytes.selector;

        // Standing, and the counters it is made of
        sels[16] = ArbiterAccountabilityFacet.getArbiterStanding.selector;
        sels[17] = ArbiterAccountabilityFacet.getArbiterBond.selector;
        sels[18] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        sels[19] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        sels[20] = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;
        sels[21] = ArbiterAccountabilityFacet.getCleanVerdicts.selector;
        sels[22] = ArbiterAccountabilityFacet.getOverturnedVerdicts.selector;
        sels[23] = ArbiterAccountabilityFacet.getOpenClaimCount.selector;
        sels[24] = ArbiterAccountabilityFacet.getMistakeThreshold.selector;

        // Mirrored constants — `getDaoThresholdMirror` is the reading that
        // proves this facet's new code is live after the cut.
        sels[25] = ArbiterAccountabilityFacet.getMaxArbiterMistakesMirror.selector;
        sels[26] = ArbiterAccountabilityFacet.getDaoThresholdMirror.selector; // changed: 100 000 -> 10 000

        // Provenance of a seat
        sels[27] = ArbiterAccountabilityFacet.getSeatedBy.selector;
        sels[28] = ArbiterAccountabilityFacet.getSeatedCountBy.selector;

        // The reading half of "the chain as a witness"
        sels[29] = ArbiterAccountabilityFacet.getArbiterChatKeys.selector;
        sels[30] = ArbiterAccountabilityFacet.getDisputeClaimedAt.selector;
        sels[31] = ArbiterAccountabilityFacet.getNoResponseAt.selector;
        sels[32] = ArbiterAccountabilityFacet.getPresentationDigests.selector;
        sels[33] = ArbiterAccountabilityFacet.getPresentationDigestCount.selector;
        sels[34] = ArbiterAccountabilityFacet.getPresentationDigestsPage.selector;
    }

    // ════════════════════════════════════════════════════════════════════

    function _assertSameSet(bytes4[] memory mine, bytes4[] memory theirs, string memory label) internal pure {
        require(
            mine.length == theirs.length,
            string.concat("pre-flight: ", label, " - this cut and the compiled facet disagree on how many functions it has")
        );
        for (uint256 i = 0; i < theirs.length; i++) {
            bool found;
            for (uint256 j = 0; j < mine.length; j++) {
                if (theirs[i] == mine[j]) { found = true; break; }
            }
            require(found, string.concat("pre-flight: ", label, " implements a function this cut does not mount"));
        }
        for (uint256 i = 0; i < mine.length; i++) {
            bool found;
            for (uint256 j = 0; j < theirs.length; j++) {
                if (mine[i] == theirs[j]) { found = true; break; }
            }
            require(found, string.concat("pre-flight: this cut mounts a selector ", label, " does not implement"));
        }
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }

    function _readAddress(address target, string memory signature) internal view returns (address) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(
            ok && data.length >= 32,
            string.concat(
                "upgrade: ", signature, " is not answered by DIAMOND_ADDRESS -- wrong address? ",
                "(TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT sit in the same .env and also have code)"
            )
        );
        return abi.decode(data, (address));
    }

    function _readUint(address target, bytes4 selector, string memory label) internal view returns (uint256) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        require(ok && data.length >= 32, string.concat("upgrade: the diamond does not answer ", label));
        return abi.decode(data, (uint256));
    }
}
