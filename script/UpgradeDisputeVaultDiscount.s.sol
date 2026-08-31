// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeDisputeVaultDiscount.s.sol
//
// THE ARBITER BANK TAKES THREE DOLLARS OFF A DISPUTE TOP-UP — a recorded
// decision. One diamondCut, FOUR elements:
//
//   Replace 57 -> new ArbiterRegistryFacet
//   Add       2 -> the SAME new ArbiterRegistryFacet
//   Replace 35 -> new ArbiterAccountabilityFacet
//   Add       1 -> the SAME new ArbiterAccountabilityFacet
//
//   13 facets -> 13 facets, 218 routed selectors -> 221
//
// WHAT IS WRONG TODAY. A dispute on a five-dollar pot costs the party ten
// dollars. The arbiter floor is $10, the levy on that pot yields the arbiter
// twelve cents, and the party makes up the remaining $9.88 out of pocket. Live
// people found it in twenty minutes.
//
// WHAT SHIPS. The floor stays at $10 and the party still pays, but the arbiter
// vault now takes a fixed amount off that top-up — a DISCOUNT, not cover: full
// cover would make an empty dispute free, and free is what gets opened for no
// reason.
//
//   the reservation   The vault's share is subtracted from `vaultBalance` at
//                     `fundDispute` and booked under the agreement, not promised
//                     and settled days later at `finalizeVerdict`. Two disputes
//                     therefore cannot be promised the same three dollars, and
//                     there is no branch anywhere in which an arbiter is paid
//                     under the floor because the arithmetic ran out of somebody
//                     else's money.
//
//   the ways back     On every exit that does not pay the arbiter — an unclaimed
//                     dispute timing out, an overturned verdict — the vault's
//                     share goes back to the vault and the payer is refunded
//                     only what the payer paid.
//
//   the number        Stored, not constant: the protocol has seen ZERO disputes,
//                     so three dollars is a starting point the first hundred
//                     real deals will move, and moving it must cost one
//                     transaction rather than a facet replacement. Zero reads
//                     back as the $3 default, mirroring
//                     `arbiterFloor`/`getArbiterFloor` two functions away.
//
// ⚠️ WHY THE ACCOUNTABILITY FACET IS IN THIS CUT. It gains exactly one function,
// `getDisputeSubsidy(address)` — a bare storage read of a field the REGISTRY
// owns and writes. It sits on the other facet for bytes and not for meaning: the
// registry stands 90 bytes under the EIP-170 ceiling (24 486 of 24 576) and
// could not hold one more function. Same storage, same POSITION, same diamond
// address; from outside nothing about it is different.
//
// ⚠️ THIS CUT MEETS BOTH HALVES OF THE PAIR THAT DROPS A CUT ON ONE LIVE
// TRANSACTION. `Replace` reverts "Diamond: selector not found" on a selector
// that is not mounted; `Add` reverts "Diamond: selector exists" on one that is.
// Ninety-two selectors are filed under Replace and three under Add, on TWO facet
// addresses, so a selector in the wrong group reverts the whole thing AFTER both
// facets have already been paid for.
//
// So the composition is held against two sources, and NEITHER of them is this
// script:
//
//   * solc's own `methodIdentifiers`, read out of the build artifacts, answers
//     "does the cut mount exactly what the facets implement";
//   * the live diamond's loupe, asked here at run time and asked offline in
//     test/DisputeVaultDiscountUpgrade.t.sol against a census committed as data
//     (test/fixtures/chain-2026-08-29-arbiter-discount-selectors.json), answers
//     "is each Replace selector mounted today and each Add selector mounted
//     nowhere".
//
// A stand that built "what is mounted" out of this script's own
// `registryReplaceSelectors()` would agree with itself no matter which group a
// selector was filed under. That is the fourth way to be fooled by a measurement
// and it cost a whole cut once.
//
// STORAGE. Two fields appended to the END of `ArbiterRegistryStorage.Data`
// (`disputeVaultDiscount`, `disputeVaultSubsidy`). Appended in the wrong place,
// either would read a live one — and a corps that had silently lost its vault
// would look, from every other angle, exactly healthy. The pre-flight and
// post-flight read eleven facts about the arbitration namespace across the cut
// and refuse if any of them moved.
//
// ⚠️ THE ONE THING THIS CUT CHANGES FOR CODE THAT IS ALREADY ON CHAIN. Every
// live deal is an EIP-1167 clone that calls `clearDisputeClaim` on the diamond
// under a hard gas cap (`Agreement.CLAIM_CLEAR_GAS`, 200 000) inside an EMPTY
// catch. This work adds two storage operations to the branch of that function
// which returns a funded bounty. Replacing the facet changes what that call
// costs; a clone's cap cannot be changed at all, and a cap that has become too
// tight is swallowed in silence — the refund never happens, the claim is never
// cleared, and nobody is told.
//
// MEASURED, and not by the check that looks like it already covers this.
// test/DiamondDeathGasCaps.t.sol::testClaimClearCostSitsUnderItsCap runs on a
// 1000-dollar deal, where the levy already pays the arbiter more than the floor
// and `fundDispute` refuses with `TopUpNotNeeded` — so the refund branch, the
// only one this cut made more expensive, is never entered there. The
// measurement that does enter it is test/DisputeVaultDiscountGasCap.t.sol:
// 93 418 gas of the 200 000 cap, on a five-dollar deal with a funded bounty, a
// claim to drop and a stuck verdict to clear, every slot cold.
//
// RUN IT DRY FIRST (no --broadcast):
//   forge script script/UpgradeDisputeVaultDiscount.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeDisputeVaultDiscount.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

contract UpgradeDisputeVaultDiscount is Script {

    /// Build artifacts this script holds its own selector lists against.
    /// Read through `vm.readFile`; `./out` is already in `fs_permissions`.
    string internal constant REGISTRY_ARTIFACT =
        "out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json";
    string internal constant ACCOUNTABILITY_ARTIFACT =
        "out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json";

    /// The number from a recorded decision, written here by a person rather than
    /// read from the facet. That is the whole point: the facet is
    /// the thing being checked, so the expected side may not come from it.
    /// Six decimals, like every other USDC amount in this protocol.
    uint256 public constant DISCOUNT_AFTER = 3_000_000; // $3

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeDisputeVaultDiscount.s.sol";
    }

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        // The signer comes from the command line (--account / --private-key), never
        // from the environment. Foundry fills msg.sender from --sender and derives it
        // from --private-key; with no wallet named at all it stays forge-std's
        // DEFAULT_SENDER, which is how a dry run identifies itself below.
        address broadcaster = msg.sender;

        // ── Pre-flight: everything checkable before a wei is spent ─────────
        require(diamond != address(0), "upgrade: DIAMOND_ADDRESS is zero");
        require(diamond.code.length > 0, "upgrade: DIAMOND_ADDRESS has no code");

        // Code is not enough. TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT
        // live in the same .env and all three have code, so a typo would sail
        // through the check above. Probe a selector only this diamond answers.
        address currentOwner = _readAddress(diamond, "owner()");
        if (broadcaster == DEFAULT_SENDER) {
            // A dry run with nobody named as the signer. Every chain read above still
            // ran; the only thing not checkable is WHO signs, because nothing said.
            // Foundry itself refuses to broadcast from DEFAULT_SENDER ("You seem to be
            // using Foundry's default sender"), so no live run can reach the cut
            // through this branch -- the check is skipped only when there is nothing
            // left to protect.
            console.log("NOTE: no signer named (--account/--sender absent).");
            console.log("      Ownership is NOT checked in this run. The live run needs:");
            console.log("      --account deployer --sender", currentOwner);
        } else {
            require(
                currentOwner == broadcaster,
                "upgrade: the signer is not the diamond owner - diamondCut would revert after a paid deploy"
            );
        }

        bytes4[] memory regSels    = registryReplaceSelectors();
        bytes4[] memory regAdd     = registryAddSelectors();
        bytes4[] memory accSels    = accountabilityReplaceSelectors();
        bytes4[] memory accAdd     = accountabilityAddSelectors();

        // The hand-written lists against solc's own output, both ways.
        assertListsCoverTheCompiledFacets(regSels, regAdd, accSels, accAdd);

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

        // Add groups: mounted NOWHERE in the whole diamond, not merely absent
        // from their own facet. `Add` reverts on a selector routed anywhere.
        assertAddGroupIsUnmountedAnywhere(regAdd, diamond);
        assertAddGroupIsUnmountedAnywhere(accAdd, diamond);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        uint256 facetsBefore    = IDiamondLoupe(diamond).facetAddresses().length;
        StorageSnapshot memory beforeCut = snapshotArbitration(diamond);

        console.log("=== UpgradeDisputeVaultDiscount: pre-flight ===");
        console.log("Diamond:                          ", diamond);
        console.log("Owner:                            ", currentOwner);
        console.log("Current ArbiterRegistryFacet:     ", previousRegistry);
        console.log("Current ArbiterAccountabilityFacet:", previousAccountability);
        console.log("Facets BEFORE cut:                ", facetsBefore);
        console.log("Routed selectors BEFORE cut:      ", selectorsBefore);
        console.log("Replace (ArbiterRegistry):        ", regSels.length);
        console.log("Add     (ArbiterRegistry, new):   ", regAdd.length);
        console.log("Replace (ArbiterAccountability):  ", accSels.length);
        console.log("Add     (ArbiterAccountability):  ", accAdd.length);
        console.log("Routed selectors AFTER cut will be:", selectorsBefore + regAdd.length + accAdd.length);
        console.log("Arbiter floor:                    ", beforeCut.arbiterFloor);
        console.log("Arbiter vault balance:            ", beforeCut.vaultBalance);
        console.log("Discount after the cut will be:   ", DISCOUNT_AFTER);
        console.log("Seated arbiters:                  ", beforeCut.arbiterCount);
        console.log("Chief arbiter:                    ", beforeCut.chiefArbiter);
        console.log("DAO address (in office):          ", beforeCut.daoAddress);
        console.log("DAO mode active:                  ", beforeCut.daoActive);
        console.log("Treasury slice held:              ", beforeCut.treasurySlice);
        console.log("");

        // ⚠️ SAID OUT LOUD BECAUSE NOTHING HERE CAN REFUSE IT. The vault pays the
        // discount out of `vaultBalance`. An empty vault does not refuse a
        // dispute — it simply gives nothing, and the party pays the whole
        // top-up, exactly as today. Shipping this on an empty bank is legal and
        // silent, so the number is printed above rather than assumed.
        if (beforeCut.vaultBalance < DISCOUNT_AFTER) {
            console.log("WARNING: the arbiter vault holds less than one discount. The cut is still");
            console.log("correct - an empty bank gives nothing and refuses nobody - but nobody will");
            console.log("see three dollars come off until the vault is funded.");
            console.log("");
        }

        // ── The cut ────────────────────────────────────────────────────────
        vm.startBroadcast();
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
        assertRouted(regAdd,  address(registryFacet), diamond);
        assertRouted(accSels, address(accountabilityFacet), diamond);
        assertRouted(accAdd,  address(accountabilityFacet), diamond);
        console.log("All ninety-two replaced selectors and all three new ones land on the new facets.");

        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(registryFacet)).length
                == regSels.length + regAdd.length,
            "post-flight: the new ArbiterRegistryFacet does not hold the replaced selectors plus the two new ones"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(accountabilityFacet)).length
                == accSels.length + accAdd.length,
            "post-flight: the new ArbiterAccountabilityFacet does not hold the replaced selectors plus the new one"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousRegistry).length == 0
                && IDiamondLoupe(diamond).facetFunctionSelectors(previousAccountability).length == 0,
            "post-flight: an old facet still holds selectors - a Replace did not move all of them"
        );

        assertStorageContinuity(beforeCut, snapshotArbitration(diamond));
        console.log("Storage continuity OK: the corps, the chief, the DAO address, the vault, the");
        console.log("slice and the floor are where they were - the two appended fields landed at the end.");

        // The two readings that say the cut did what it was FOR, one per facet.
        assertTheDiscountAnswers(diamond, DISCOUNT_AFTER);
        console.log("Decision 54 is live: getDisputeDiscount() answers three dollars, which is the");
        console.log("  default a never-written field reads back as.");
        assertTheSubsidyDoorAnswersAndIsEmpty(diamond);
        console.log("  And getDisputeSubsidy() answers on the accountability facet - nobody has been");
        console.log("  charged a discounted top-up yet, so it answers nothing, which is right.");

        uint256 selectorsAfter = totalRoutedSelectors(diamond);
        uint256 facetsAfter    = IDiamondLoupe(diamond).facetAddresses().length;
        require(
            selectorsAfter == selectorsBefore + regAdd.length + accAdd.length,
            "post-flight: the routed-selector count moved by something other than the two Add groups"
        );
        require(
            facetsAfter == facetsBefore,
            "post-flight: the facet count moved - the old facets should have been emptied, not unmounted"
        );
        console.log("Facets AFTER cut:            ", facetsAfter);
        console.log("Routed selectors AFTER cut:  ", selectorsAfter);
        console.log("");

        console.log("A dispute on a small pot now costs the party three dollars less, and the");
        console.log("arbiter still receives the whole floor.");
        console.log("");
        // ⚠️ Still open: on 21 August this same pair
        // of facets shipped UNVERIFIED because the script fell over on a receipt
        // before it reached `--verify`, and nobody noticed until the owner asked.
        // Nothing in a post-flight can see Basescan, so the least this cut can do
        // is say the two addresses out loud at the end, where they are not buried
        // above the post-flight output.
        console.log("VERIFY THESE TWO ON BASESCAN before calling the cut done - `--verify` is");
        console.log("not reached if the run trips on a receipt, and that is how three contracts");
        console.log("shipped unverified on 21 August:");
        console.log("  ArbiterRegistryFacet:      ", address(registryFacet));
        console.log("  ArbiterAccountabilityFacet:", address(accountabilityFacet));
        console.log("");
        console.log("Rollback (points the ninety-two replaced selectors back at the previous facets,");
        console.log("which are still on chain and still work - they are the code running today):");
        console.log("  forge script script/UpgradeDisputeVaultDiscount.s.sol \\");
        console.log("    --sig \"rollback(address,address,address[])\" <registry> <accountability> \"[]\" \\");
        console.log("    --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER --broadcast");
        console.log("  <registry>       =", previousRegistry);
        console.log("  <accountability> =", previousAccountability);
        console.log("");
        console.log("WARNING: rolling back REMOVES the three new selectors as well, and the old code");
        console.log("cannot see the reservation. A dispute funded while the new code was live keeps");
        console.log("its bank share in the appended field with no function left to give it back, and");
        console.log("`vaultBalance` stays short by that amount. The rollback below refuses while any");
        console.log("dispute is standing funded.");
    }

    /// Undo, as a command rather than as a paragraph somebody has to
    /// transcribe. Points the ninety-two replaced selectors back at the previous
    /// facets, removes the three added ones, and refuses if the chain is not in
    /// the state that follows this cut — a rollback that runs against an
    /// unexpected diamond is how one mistake becomes two.
    ///
    /// ⚠️ `agreementsToCheck` is not decoration. The one state this rollback
    /// cannot carry back is a dispute that was funded under the new code: its
    /// bank share sits in `disputeVaultSubsidy`, and the old code neither reads
    /// that field nor gives it back, so `vaultBalance` would stay short for
    /// ever. There is no on-chain list of live disputes to walk, so the caller
    /// names the agreements to check. Passing an empty array is allowed and is
    /// the honest shape for "there were none" — it is not a check that passed.
    function rollback(
        address previousRegistry,
        address previousAccountability,
        address[] calldata agreementsToCheck
    ) external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
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
        bytes4[] memory regAdd  = registryAddSelectors();
        bytes4[] memory accSels = accountabilityReplaceSelectors();
        bytes4[] memory accAdd  = accountabilityAddSelectors();

        // Only roll back a diamond this cut actually landed on.
        assertAllMountedOnOneFacet(regSels, diamond);
        assertAllMountedOnOneFacet(accSels, diamond);
        assertAddGroupIsMountedEverywhere(regAdd, diamond);
        assertAddGroupIsMountedEverywhere(accAdd, diamond);

        assertNoBankShareIsStranded(diamond, agreementsToCheck);

        bytes4[] memory removeAll = _concat(regAdd, accAdd);
        IDiamondCut.FacetCut[] memory undo = new IDiamondCut.FacetCut[](3);
        undo[0] = IDiamondCut.FacetCut(previousRegistry, IDiamondCut.FacetCutAction.Replace, regSels);
        undo[1] = IDiamondCut.FacetCut(previousAccountability, IDiamondCut.FacetCutAction.Replace, accSels);
        undo[2] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, removeAll);

        vm.startBroadcast();
        IDiamondCut(diamond).diamondCut(undo, address(0), "");
        vm.stopBroadcast();

        assertRouted(regSels, previousRegistry, diamond);
        assertRouted(accSels, previousAccountability, diamond);
        assertAddGroupIsUnmountedAnywhere(regAdd, diamond);
        assertAddGroupIsUnmountedAnywhere(accAdd, diamond);
        console.log("Rolled back. The discount is gone and a top-up costs the party the whole floor again.");
    }

    // ════════════════════════════════════════════════════════════════════
    // THE INDEPENDENT ORACLES
    // ════════════════════════════════════════════════════════════════════

    /// The hand-written lists against solc's own answer to "what does this facet
    /// expose". Set equality in both directions, per facet:
    ///
    ///   * a function the facet implements and this cut does not mount would
    ///     ship dead — present in the ABI, routed nowhere, discovered by the
    ///     first person whose button did nothing;
    ///   * a selector this cut mounts and the facet does not implement routes
    ///     calls into whatever byte offset happens to be there.
    ///
    /// Each facet is checked as Replace ∪ Add, which is the whole point of the
    /// split: a selector that drifts from one group to the other keeps the union
    /// identical and would still revert the cut on chain. That half is answered
    /// by `assertAllMountedOnOneFacet` and `assertAddGroupIsUnmountedAnywhere`,
    /// whose expected side is the chain.
    function assertListsCoverTheCompiledFacets(
        bytes4[] memory regSels,
        bytes4[] memory regAdd,
        bytes4[] memory accSels,
        bytes4[] memory accAdd
    ) public view {
        _assertSameSet(_concat(regSels, regAdd), artifactSelectors(REGISTRY_ARTIFACT), "ArbiterRegistryFacet");
        _assertSameSet(_concat(accSels, accAdd), artifactSelectors(ACCOUNTABILITY_ARTIFACT), "ArbiterAccountabilityFacet");

        // And each facet's two groups must be disjoint, or one of the two
        // FacetCut entries reverts by construction.
        _assertDisjoint(regSels, regAdd, "registry");
        _assertDisjoint(accSels, accAdd, "accountability");
    }

    function _assertDisjoint(bytes4[] memory a, bytes4[] memory b, string memory label) internal pure {
        for (uint256 i = 0; i < a.length; i++) {
            for (uint256 j = 0; j < b.length; j++) {
                require(
                    a[i] != b[j],
                    string.concat("pre-flight: a selector is in both the ", label, " Replace group and its Add group")
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
    /// already routed, so "not on this facet" is the wrong question — the right
    /// one is "not routed ANYWHERE in this diamond".
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

    /// The rollback's mirror of the above: a diamond this cut never landed on
    /// has nothing to undo, and the `Remove` element would revert on it.
    function assertAddGroupIsMountedEverywhere(bytes4[] memory addSels, address diamond) public view {
        for (uint256 i = 0; i < addSels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(addSels[i]) != address(0),
                "rollback: an added selector is not mounted - this cut did not land here"
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

    /// Decision 54, read back through the diamond. This is what proves the new
    /// ArbiterRegistryFacet is RUNNING and not merely mounted: the selector
    /// existing says the Add landed, and the number says the code behind it is
    /// the code this cut carried.
    function assertTheDiscountAnswers(address diamond, uint256 expected) public view {
        (bool ok, bytes memory ret) = diamond.staticcall(
            abi.encodeWithSelector(ArbiterRegistryFacet.getDisputeDiscount.selector)
        );
        require(ok && ret.length >= 32, "post-flight: the diamond does not answer getDisputeDiscount()");
        require(
            abi.decode(ret, (uint256)) == expected,
            "post-flight: getDisputeDiscount() is not the number this cut carries"
        );
    }

    /// The same for the OTHER facet, which nothing else could tell apart: it
    /// answers at all (so its Add group landed and routes), and it answers zero.
    /// A non-zero reservation on a diamond that has never run this code would
    /// mean the appended field reads somebody else's slot — the layout moved,
    /// and the cut has to be undone before anything touches the vault.
    function assertTheSubsidyDoorAnswersAndIsEmpty(address diamond) public view {
        (bool ok, bytes memory ret) = diamond.staticcall(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.getDisputeSubsidy.selector, address(0xD15C0))
        );
        require(ok && ret.length >= 32, "post-flight: the diamond does not answer getDisputeSubsidy()");
        require(
            abi.decode(ret, (uint256)) == 0,
            "post-flight: a dispute nobody funded already has a bank share - the appended field reads a live slot"
        );
    }

    /// The rollback's own refusal. Named agreements are asked for their booked
    /// bank share; any non-zero one would be stranded by the undo.
    function assertNoBankShareIsStranded(address diamond, address[] memory agreements) public view {
        for (uint256 i = 0; i < agreements.length; i++) {
            (bool ok, bytes memory ret) = diamond.staticcall(
                abi.encodeWithSelector(ArbiterAccountabilityFacet.getDisputeSubsidy.selector, agreements[i])
            );
            require(ok && ret.length >= 32, "rollback: the diamond does not answer getDisputeSubsidy()");
            require(
                abi.decode(ret, (uint256)) == 0,
                "rollback: a named agreement holds a booked bank share - undoing would strand it and leave the vault short"
            );
        }
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
    /// this work appended two fields to it (`disputeVaultDiscount`,
    /// `disputeVaultSubsidy`). Appended in the wrong place, either would read a
    /// live one — and a corps that had silently lost its vault would look, from
    /// every other angle, exactly healthy.
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

    /// Everything must stand still. Unlike the governance cut, this one changes
    /// no existing reading at all: the discount is a NEW field with a NEW
    /// reader, so a moved number here means the append landed in the wrong
    /// place, full stop.
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
            "post-flight: the DAO address changed across the cut"
        );
        require(
            afterCut.daoActive == beforeCut.daoActive,
            "post-flight: DAO mode flipped across the cut"
        );
        require(
            afterCut.vaultBalance == beforeCut.vaultBalance,
            "post-flight: the arbiter vault moved across the cut - the two appended fields may have landed on a live slot"
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
            "post-flight: the arbiter floor changed across the cut - the discount comes off the top-up, not off the floor"
        );
        require(
            afterCut.daoThreshold == beforeCut.daoThreshold,
            "post-flight: the DAO threshold changed across the cut"
        );
        require(
            afterCut.proposalTtl == beforeCut.proposalTtl,
            "post-flight: the proposal TTL changed across the cut"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // THE CUT
    // ════════════════════════════════════════════════════════════════════

    /// Four elements. Two whole facets move address, and each of them
    /// additionally gains functions — so each Add group is its own element on
    /// the same address as its Replace, because one FacetCut carries one action.
    function buildCuts(address registryFacet, address accountabilityFacet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut(registryFacet, IDiamondCut.FacetCutAction.Replace, registryReplaceSelectors());
        cuts[1] = IDiamondCut.FacetCut(registryFacet, IDiamondCut.FacetCutAction.Add, registryAddSelectors());
        cuts[2] = IDiamondCut.FacetCut(
            accountabilityFacet, IDiamondCut.FacetCutAction.Replace, accountabilityReplaceSelectors()
        );
        cuts[3] = IDiamondCut.FacetCut(
            accountabilityFacet, IDiamondCut.FacetCutAction.Add, accountabilityAddSelectors()
        );
    }

    /// Fifty-seven — everything ArbiterRegistryFacet routes on Base Sepolia
    /// today. Taken from the type rather than typed as literals: a signature
    /// change is then picked up by the compiler instead of by whoever presses
    /// the button. Held against the build artifact in
    /// `assertListsCoverTheCompiledFacets` and against the live chain in
    /// `assertAllMountedOnOneFacet`.
    ///
    /// Four of them changed BEHAVIOUR in this work — `fundDispute` (reserves the
    /// bank's share and books it), `quoteDisputeTopUp` (returns what the wallet
    /// actually pays), `finalizeVerdict` and `clearDisputeClaim` (both give the
    /// bank's share back to the bank on an exit that pays no arbiter). The rest
    /// are here because a Replace must carry the facet's whole selector set or
    /// leave the remainder pointing at the old address.
    function registryReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](57);

        // DAO mode and the corps
        sels[0]  = ArbiterRegistryFacet.activateDAO.selector;
        sels[1]  = ArbiterRegistryFacet.applyAsArbiter.selector;
        sels[2]  = ArbiterRegistryFacet.resignAsArbiter.selector;
        sels[3]  = ArbiterRegistryFacet.setChiefArbiter.selector;
        sels[4]  = ArbiterRegistryFacet.addArbiter.selector;

        // Claiming a dispute (commit-reveal). `clearDisputeClaim` now returns
        // the bank's share to the bank when an unclaimed dispute times out.
        sels[5]  = ArbiterRegistryFacet.commitDisputeClaim.selector;
        sels[6]  = ArbiterRegistryFacet.claimDispute.selector;
        sels[7]  = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        sels[8]  = ArbiterRegistryFacet.clearDisputeClaim.selector;   // changed

        // Verdict. `finalizeVerdict` gives the bank its share back on an
        // overturned verdict and refunds the payer only what the payer paid.
        sels[9]  = ArbiterRegistryFacet.submitVerdict.selector;
        sels[10] = ArbiterRegistryFacet.finalizeVerdict.selector;     // changed
        sels[11] = ArbiterRegistryFacet.overturnVerdict.selector;
        sels[12] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        sels[13] = ArbiterRegistryFacet.freezeVerdict.selector;
        sels[14] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        sels[15] = ArbiterRegistryFacet.clearStuckVerdict.selector;

        // Appeal
        sels[16] = ArbiterRegistryFacet.raiseAppeal.selector;
        sels[17] = ArbiterRegistryFacet.voteOnAppeal.selector;
        sels[18] = ArbiterRegistryFacet.resolveAppeal.selector;

        // Rewards
        sels[19] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        sels[20] = ArbiterRegistryFacet.fundVault.selector;
        sels[21] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        sels[22] = ArbiterRegistryFacet.setDAOAddress.selector;

        // Views
        sels[23] = ArbiterRegistryFacet.isDaoActive.selector;
        sels[24] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        sels[25] = ArbiterRegistryFacet.getDaoThreshold.selector;
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

        // Paid call for an arbiter: floor and the quote to reach it.
        // `quoteDisputeTopUp` now returns the DISCOUNTED number — what the
        // wallet pays — so the screen and the transfer are the same subtraction.
        sels[41] = ArbiterRegistryFacet.setArbiterFloor.selector;
        sels[42] = ArbiterRegistryFacet.getArbiterFloor.selector;
        sels[43] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;   // changed

        // Paid call for an arbiter: payment and the soft refund. `fundDispute`
        // reserves the bank's share out of `vaultBalance` in the same
        // transaction and books it under the agreement.
        sels[44] = ArbiterRegistryFacet.fundDispute.selector;         // changed
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

        // Governance handover (mounted 27 August 2026)
        sels[55] = ArbiterRegistryFacet.acceptDAOAddress.selector;
        sels[56] = ArbiterRegistryFacet.getPendingDAOAddress.selector;
    }

    /// The two that do not exist on chain yet on the registry side, and half the
    /// reason this cut has Add groups at all. Filed here and nowhere else:
    /// putting either of them in the Replace group reverts the whole cut with
    /// "Diamond: selector not found", after two facets have already been paid
    /// for.
    ///
    ///   setDisputeDiscount(uint256)  0x98d798ce — owner moves the number
    ///   getDisputeDiscount()         0xd9b75b80 — and anyone can read it
    ///
    /// Verified unmounted two ways on 29 August 2026: absent from the whole
    /// routed list in the census fixture, and answered by the live diamond's
    /// `facetAddress` with the zero address.
    function registryAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](2);
        sels[0] = ArbiterRegistryFacet.setDisputeDiscount.selector;
        sels[1] = ArbiterRegistryFacet.getDisputeDiscount.selector;
    }

    /// Thirty-five — the whole of today's ArbiterAccountabilityFacet, and
    /// exactly as many as it has on chain right now. NONE of them changed
    /// behaviour; the facet is in this cut because it GAINS one function, and a
    /// facet's selectors cannot be split across two addresses, so all thirty-six
    /// move together or none do.
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

        // The chief's proposal, and the accused man's right of reply
        sels[7]  = ArbiterAccountabilityFacet.proposeRemoval.selector;
        sels[8]  = ArbiterAccountabilityFacet.withdrawProposal.selector;
        sels[9]  = ArbiterAccountabilityFacet.hasLiveProposal.selector;
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

        // Mirrored constants
        sels[25] = ArbiterAccountabilityFacet.getMaxArbiterMistakesMirror.selector;
        sels[26] = ArbiterAccountabilityFacet.getDaoThresholdMirror.selector;

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

    /// The one that does not exist on chain yet on the accountability side.
    ///
    ///   getDisputeSubsidy(address)   0x4c02060d — how much of a funded top-up
    ///                                came out of the bank
    ///
    /// ⚠️ IT LIVES ON THIS FACET FOR BYTES, NOT FOR MEANING. The rule that
    /// decides the number is in ArbiterRegistryFacet, and so is the writer; this
    /// is a bare storage read of a field that facet owns, mounted here because
    /// the registry stands 90 bytes under the EIP-170 ceiling. Filing it under
    /// the registry's Add group would put it on the wrong ADDRESS — the cut
    /// would land and the function would revert on every call, because the
    /// registry's code does not contain it.
    function accountabilityAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = ArbiterAccountabilityFacet.getDisputeSubsidy.selector;
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
}
