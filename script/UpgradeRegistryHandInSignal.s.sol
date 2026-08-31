// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeRegistryHandInSignal.s.sol
//
// THE DIAMOND LEARNS THAT WORK WAS HANDED IN. One diamondCut, TWO elements:
//
//   Replace 13 -> new RegistryFacet
//   Add      1 -> the SAME new RegistryFacet   (notifyWorkHandedIn())
//
//   13 facets -> 13 facets, routed selectors + 1
//
// WHAT IS WRONG TODAY. `Agreement.markDone()` touches the diamond not at all:
// it stamps `_markedDoneAt` on the clone and emits `MarkedDone` THERE. The one
// standing chain observer the web client is allowed to keep is pinned to the
// DIAMOND, and the subgraph indexes neither `MarkedDone` nor the registry's
// status event. So the single transition that starts AUTO_APPROVE_WINDOW --
// after which `triggerAutoApprove()` hands the ENTIRE pot to the executor
// through a door open to anyone -- was invisible from the only address anybody
// watches. A client who was on another page when the work arrived found out by
// opening the deal, or did not find out, and silence costs him the escrow.
//
// WHAT SHIPS. One new function on RegistryFacet, `notifyWorkHandedIn()`, and
// one new event, `WorkHandedIn(agreement, client, executor)`. The caller IS the
// key -- there is no `agreement` argument to point at somebody else's deal --
// and the function WRITES NOTHING: the clone holds `_markedDoneAt` and stays
// the authority on it.
//
// ⚠️ WHY NOT `updateStatus(agreement, ACTIVE)`, WHICH WOULD HAVE NEEDED NO CUT
// AT ALL. That was the cheap design and it is a forgery. `syncRegistry()` on
// every Agreement is callable BY ANYONE, takes no arguments, and pushes exactly
// ACTIVE for any deal that is not disputed or finished. A stranger could
// therefore have rung the client's "your work has arrived" bell on demand, on a
// deal where nothing had happened. That is not a hypothesis about the future:
// the selector is mounted today. The scene is
// test/WorkHandInVisible.t.sol::testAStrangerPushingSyncRegistryCannotForgeAHandIn.
//
// ⚠️ THIS CUT MEETS BOTH HALVES OF THE PAIR THAT DROPS A CUT ON ONE LIVE
// TRANSACTION. `Replace` reverts "Diamond: selector not found" on a selector
// that is not mounted; `Add` reverts "Diamond: selector exists" on one that is.
// Thirteen selectors are filed under Replace and one under Add, on ONE facet
// address, so a selector in the wrong group reverts the whole thing AFTER the
// facet has already been paid for.
//
// So the composition is held against two sources, and NEITHER of them is this
// script:
//
//   * solc's own `methodIdentifiers`, read out of the build artifact, answers
//     "does the cut mount exactly what the facet implements";
//   * the live diamond's loupe, asked here at run time and asked offline in
//     test/WorkHandInVisibleUpgrade.t.sol against a census committed as data,
//     answers "is each Replace selector mounted today and the Add selector
//     mounted nowhere".
//
// A stand that built "what is mounted" out of this script's own
// `registryReplaceSelectors()` would agree with itself no matter which group a
// selector was filed under. That is the fourth way to be fooled by a
// measurement and it cost a whole cut once.
//
// STORAGE: NOTHING MOVES. `RegistryStorage.Layout` is untouched by this work --
// no field added, none reordered, none retyped. The new function reads three
// words of an existing record and emits a log. The snapshot below is taken
// across the cut anyway, because "nothing moved" is a claim, and a claim in
// front of a live registry is worth a read.
//
// ⚠️ AND THE HALF THIS CUT DOES NOT DELIVER. The clone has to CALL the new
// function, and only a clone born from the new Agreement implementation does.
// Every deal alive today is an EIP-1167 clone of the OLD implementation and
// will never call it -- clones are nailed to their implementation for life.
// So this cut makes hand-ins visible for deals created after
// script/UpgradeAgreementHandInSignal.s.sol runs, and for no deal created
// before it. Deals already alive are not harmed and not changed; they keep the
// behaviour they were born with.
//
// ⚠️ ORDER. THIS CUT GOES FIRST, the Agreement implementation second. The
// clone's call is wrapped in try/catch, so the reverse order is not a
// catastrophe -- a hand-in on a diamond without the selector simply announces
// nothing, which is exactly today's behaviour -- but it is a window in which
// new deals are silently no better off, and nothing anywhere would say so.
//
// RUN IT DRY FIRST (no --broadcast):
//   forge script script/UpgradeRegistryHandInSignal.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeRegistryHandInSignal.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {RegistryFacet, RegistryStorage} from "../src/RegistryFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

contract UpgradeRegistryHandInSignal is Script {

    /// Build artifact this script holds its own selector lists against.
    /// Read through `vm.readFile`; `./out` is already in `fs_permissions`.
    string internal constant REGISTRY_ARTIFACT =
        "out/RegistryFacet.sol/RegistryFacet.json";

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeRegistryHandInSignal.s.sol";
    }

    // ════════════════════════════════════════════════════════════════════
    // The two groups, written out by hand
    // ════════════════════════════════════════════════════════════════════
    //
    // Hand-written, and NOT derived from the artifact, even though a helper
    // below can read the artifact. The artifact answers "what does the facet
    // implement"; these lists answer "which group does each one go in", and
    // that second question is the one the chain punishes. Deriving the lists
    // from the artifact would make the two answers the same answer.

    /// Mounted today, and moving to the new facet address.
    function registryReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](13);
        sels[0]  = RegistryFacet.initRegistry.selector;
        sels[1]  = RegistryFacet.register.selector;
        sels[2]  = RegistryFacet.updateStatus.selector;
        sels[3]  = RegistryFacet.setAuthorizedFactory.selector;
        sels[4]  = RegistryFacet.hasActivePair.selector;
        sels[5]  = RegistryFacet.getActivePair.selector;
        sels[6]  = RegistryFacet.getRecord.selector;
        sels[7]  = RegistryFacet.getByClient.selector;
        sels[8]  = RegistryFacet.getByExecutor.selector;
        sels[9]  = RegistryFacet.getActive.selector;
        sels[10] = RegistryFacet.getDisputed.selector;
        sels[11] = RegistryFacet.totalAgreements.selector;
        sels[12] = RegistryFacet.authorizedFactory.selector;
    }

    /// Mounted nowhere today. The whole delivery of this cut.
    function registryAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = RegistryFacet.notifyWorkHandedIn.selector;
    }

    function buildCuts(address registryFacet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress:      registryFacet,
            action:            IDiamondCut.FacetCutAction.Replace,
            functionSelectors: registryReplaceSelectors()
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress:      registryFacet,
            action:            IDiamondCut.FacetCutAction.Add,
            functionSelectors: registryAddSelectors()
        });
    }

    // ════════════════════════════════════════════════════════════════════
    // run
    // ════════════════════════════════════════════════════════════════════

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

        bytes4[] memory replaceSels = registryReplaceSelectors();
        bytes4[] memory addSels     = registryAddSelectors();

        // The hand-written lists against solc's own output, both ways.
        assertListsCoverTheCompiledFacet(replaceSels, addSels);
        _assertDisjoint(replaceSels, addSels);

        // Replace group: every one of them mounted TODAY, and all on one facet,
        // or `Replace` reverts and takes the cut with it.
        address previousRegistry = assertAllMountedOnOneFacet(replaceSels, diamond);

        // And that facet must expose nothing else, or the cut leaves a selector
        // pointing at an address that no longer implements it.
        assertNothingIsLeftBehind(replaceSels, previousRegistry, diamond);

        // Add group: mounted NOWHERE in the whole diamond, not merely absent
        // from its own facet. `Add` reverts on a selector routed anywhere.
        assertAddGroupIsUnmountedAnywhere(addSels, diamond);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        uint256 facetsBefore    = IDiamondLoupe(diamond).facetAddresses().length;
        StorageSnapshot memory beforeCut = snapshotRegistry(diamond);

        console.log("=== UpgradeRegistryHandInSignal: pre-flight ===");
        console.log("Diamond:                           ", diamond);
        console.log("Owner:                             ", currentOwner);
        console.log("Current RegistryFacet:             ", previousRegistry);
        console.log("Facets BEFORE cut:                 ", facetsBefore);
        console.log("Routed selectors BEFORE cut:       ", selectorsBefore);
        console.log("Replace (RegistryFacet):           ", replaceSels.length);
        console.log("Add     (RegistryFacet, new):      ", addSels.length);
        console.log("Routed selectors AFTER cut will be:", selectorsBefore + addSels.length);
        console.log("Deals on record:                   ", beforeCut.totalAgreements);
        console.log("Authorized factory:                ", beforeCut.authorizedFactory);
        console.log("Deals reading ACTIVE:              ", beforeCut.activeCount);
        console.log("Deals reading DISPUTED:            ", beforeCut.disputedCount);
        console.log("");

        // ⚠️ SAID OUT LOUD BECAUSE NOTHING HERE CAN REFUSE IT. This cut alone
        // changes NOTHING a person can see. The diamond gains a door that only
        // an Agreement clone can open, and no clone alive today opens it. The
        // signal begins the day the new Agreement implementation ships, and
        // only for deals created after that.
        console.log("NOTE: this cut on its own changes nothing observable. The door it mounts");
        console.log("is opened by Agreement.markDone(), and only clones born from the NEW");
        console.log("implementation call it. Run script/UpgradeAgreementHandInSignal.s.sol");
        console.log("AFTER this one; deals alive today keep the behaviour they were born with.");
        console.log("");

        // ── The cut ────────────────────────────────────────────────────────
        vm.startBroadcast();
        RegistryFacet registryFacet = new RegistryFacet();
        IDiamondCut(diamond).diamondCut(buildCuts(address(registryFacet)), address(0), "");
        vm.stopBroadcast();

        console.log("New RegistryFacet:", address(registryFacet));
        console.log("");

        // ── Post-flight: read the result back, do not assume it ────────────
        console.log("=== Post-flight ===");
        assertRouted(replaceSels, address(registryFacet), diamond);
        assertRouted(addSels,     address(registryFacet), diamond);
        console.log("All thirteen replaced selectors and the new one land on the new facet.");

        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(registryFacet)).length
                == replaceSels.length + addSels.length,
            "post-flight: the new RegistryFacet does not hold the replaced selectors plus the new one"
        );
        require(
            IDiamondLoupe(diamond).facetAddresses().length == facetsBefore,
            "post-flight: the facet count moved - a Replace group behaved like an Add"
        );
        require(
            totalRoutedSelectors(diamond) == selectorsBefore + addSels.length,
            "post-flight: the routed selector count moved by something other than the Add group"
        );

        assertTheNewDoorIsAliveAndRefusesAStranger(diamond);
        console.log("notifyWorkHandedIn() answers, and refuses a caller that is not a deal.");

        assertRegistryUnmoved(beforeCut, snapshotRegistry(diamond));
        console.log("The registry reads the same on both sides of the cut.");

        console.log("");
        console.log("Facets AFTER cut:            ", IDiamondLoupe(diamond).facetAddresses().length);
        console.log("Routed selectors AFTER cut:  ", totalRoutedSelectors(diamond));
        console.log("");
        console.log("NEXT: script/UpgradeAgreementHandInSignal.s.sol, which is what makes");
        console.log("new clones actually call this door.");
    }

    // ════════════════════════════════════════════════════════════════════
    // rollback
    // ════════════════════════════════════════════════════════════════════

    /// Undo, as a command rather than as a paragraph somebody has to
    /// transcribe. Points the thirteen replaced selectors back at the previous
    /// facet, removes the added one, and refuses if the chain is not in the
    /// state that follows this cut -- a rollback that runs against an
    /// unexpected diamond is how one mistake becomes two.
    ///
    /// ⚠️ SAFE TO RUN AT ANY TIME, WHICH IS NOT TRUE OF EVERY ROLLBACK IN THIS
    /// FOLDER. This cut appended no storage and booked no money, so there is no
    /// state written under the new code that the old code cannot read. The one
    /// consequence of undoing it is that clones born from the new Agreement
    /// implementation go back to announcing nothing -- their `markDone()` call
    /// is wrapped in try/catch and swallows the missing selector, so they keep
    /// working and simply stop being visible.
    function rollback(address previousRegistryFacet) external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");

        require(diamond.code.length > 0, "rollback: DIAMOND_ADDRESS has no code");
        require(
            previousRegistryFacet.code.length > 0,
            "rollback: the facet to go back to has no code"
        );
        // Same rule as run(): the signer arrives on the command line.
        address broadcaster  = msg.sender;
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
                "rollback: the signer is not the diamond owner"
            );
        }

        bytes4[] memory replaceSels = registryReplaceSelectors();
        bytes4[] memory addSels     = registryAddSelectors();

        // A diamond this cut never landed on has nothing to undo, and the
        // `Remove` element would revert on it.
        assertAddGroupIsMountedEverywhere(addSels, diamond);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress:      previousRegistryFacet,
            action:            IDiamondCut.FacetCutAction.Replace,
            functionSelectors: replaceSels
        });
        cuts[1] = IDiamondCut.FacetCut({
            // Remove takes address(0) by the standard.
            facetAddress:      address(0),
            action:            IDiamondCut.FacetCutAction.Remove,
            functionSelectors: addSels
        });

        vm.startBroadcast();
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        assertRouted(replaceSels, previousRegistryFacet, diamond);
        assertAddGroupIsUnmountedAnywhere(addSels, diamond);
        console.log("Rolled back to RegistryFacet:", previousRegistryFacet);
    }

    // ════════════════════════════════════════════════════════════════════
    // The checks, each with its expected side from somewhere that is not
    // this script
    // ════════════════════════════════════════════════════════════════════

    /// The hand-written lists against solc's own answer to "what does this
    /// facet expose". Set equality in both directions:
    ///
    ///   * a function the facet implements and this cut does not mount would
    ///     ship dead -- present in the ABI, routed nowhere, discovered by the
    ///     first person whose button did nothing;
    ///   * a selector this cut mounts and the facet does not implement routes
    ///     calls into whatever byte offset happens to be there.
    ///
    /// Checked as Replace ∪ Add, which is the whole point of the split: a
    /// selector that drifts from one group to the other keeps the union
    /// identical and would still revert the cut on chain. That half is answered
    /// by `assertAllMountedOnOneFacet` and `assertAddGroupIsUnmountedAnywhere`,
    /// whose expected side is the chain.
    function assertListsCoverTheCompiledFacet(
        bytes4[] memory replaceSels,
        bytes4[] memory addSels
    ) public view {
        bytes4[] memory compiled = artifactSelectors(REGISTRY_ARTIFACT);
        require(
            compiled.length == replaceSels.length + addSels.length,
            "pre-flight: RegistryFacet implements a different number of functions than this cut mounts"
        );
        for (uint256 i = 0; i < compiled.length; i++) {
            bool found;
            for (uint256 j = 0; j < replaceSels.length; j++) {
                if (compiled[i] == replaceSels[j]) { found = true; break; }
            }
            for (uint256 j = 0; !found && j < addSels.length; j++) {
                if (compiled[i] == addSels[j]) { found = true; break; }
            }
            require(found, "pre-flight: RegistryFacet implements a function this cut does not mount");
        }
    }

    function _assertDisjoint(bytes4[] memory a, bytes4[] memory b) internal pure {
        for (uint256 i = 0; i < a.length; i++) {
            for (uint256 j = 0; j < b.length; j++) {
                require(
                    a[i] != b[j],
                    "pre-flight: the same selector is in both Replace and Add - one of the two would revert"
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
                "pre-flight: the Replace group is spread over more than one facet - this cut assumes one"
            );
        }
    }

    /// The other direction of the same question: the facet being replaced must
    /// not hold a selector this cut does not carry. One left behind would keep
    /// pointing at an address whose code no longer implements it -- a live
    /// button answering with whatever that old byte offset happens to be.
    function assertNothingIsLeftBehind(bytes4[] memory sels, address previousFacet, address diamond)
        public view
    {
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousFacet).length == sels.length,
            "pre-flight: the facet being replaced holds a different number of selectors than this cut carries"
        );
    }

    /// ⚠️ THE HALF THAT IS EASIEST TO GET WRONG. `Add` reverts on a selector
    /// already routed, so "not on this facet" is the wrong question -- the right
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
                "rollback: the added selector is not mounted - this cut did not land here"
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

    /// What proves the new facet is RUNNING and not merely mounted.
    ///
    /// The selector answering at all says the `Add` landed. What it ANSWERS
    /// says the code behind it is this cut's code: called by an address that is
    /// not a registered deal -- which the broadcaster is not -- it must refuse
    /// with `AgreementNotRegistered`. A diamond that never got this cut refuses
    /// with "Diamond: function not found" instead, and the two are told apart
    /// here rather than being read as one "it reverted".
    ///
    /// A staticcall, so the probe cannot change anything even if the facet
    /// behind the selector is not the one this script deployed.
    function assertTheNewDoorIsAliveAndRefusesAStranger(address diamond) public view {
        (bool ok, bytes memory ret) = diamond.staticcall(
            abi.encodeWithSelector(RegistryFacet.notifyWorkHandedIn.selector)
        );
        require(!ok, "post-flight: notifyWorkHandedIn accepted a caller that is not a deal");
        require(
            ret.length >= 4 && bytes4(ret) == RegistryFacet.AgreementNotRegistered.selector,
            "post-flight: notifyWorkHandedIn did not refuse with AgreementNotRegistered - the selector may be unrouted, or behind other code"
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
        uint256 totalAgreements;
        address authorizedFactory;
        uint256 activeCount;
        uint256 disputedCount;
    }

    /// The registry namespace read through the diamond, before and after.
    ///
    /// This cut appends NOTHING to `RegistryStorage.Layout`, so this snapshot
    /// is not guarding an append -- it is guarding the claim that nothing was
    /// appended. A facet compiled from a source whose layout had quietly moved
    /// would replace the old one without complaint and read the wrong words
    /// from the same slots; the deal count and the factory address are the two
    /// cheapest witnesses that it did not.
    function snapshotRegistry(address diamond) public view returns (StorageSnapshot memory s) {
        RegistryFacet reg = RegistryFacet(diamond);
        s.totalAgreements   = reg.totalAgreements();
        s.authorizedFactory = reg.authorizedFactory();
        s.activeCount       = reg.getActive().length;
        s.disputedCount     = reg.getDisputed().length;
    }

    function assertRegistryUnmoved(
        StorageSnapshot memory beforeCut,
        StorageSnapshot memory afterCut
    ) public pure {
        require(
            beforeCut.totalAgreements == afterCut.totalAgreements,
            "post-flight: the number of deals on record moved across the cut"
        );
        require(
            beforeCut.authorizedFactory == afterCut.authorizedFactory,
            "post-flight: the authorized factory moved across the cut"
        );
        require(
            beforeCut.activeCount == afterCut.activeCount,
            "post-flight: the number of ACTIVE deals moved across the cut"
        );
        require(
            beforeCut.disputedCount == afterCut.disputedCount,
            "post-flight: the number of DISPUTED deals moved across the cut"
        );
    }

    function _readAddress(address target, string memory sig) internal view returns (address out) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && ret.length == 32, string.concat("upgrade: the diamond did not answer ", sig));
        out = abi.decode(ret, (address));
    }
}
