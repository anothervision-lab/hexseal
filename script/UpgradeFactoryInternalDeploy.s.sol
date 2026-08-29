// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeFactoryInternalDeploy.s.sol
//
// `deployAgreement` BECOMES THE DIAMOND'S OWN DOOR — one diamondCut, one
// element, REPLACE ONLY.
//
//   Replace 23 -> new FactoryFacet
//   13 facets -> 13 facets, 218 routed selectors -> 218
//
// WHAT IS WRONG TODAY. `deployAgreement` is an entrance without payment. Called
// straight off the chain by anybody, it creates a clone and leaves it UNFUNDED,
// and there is no way back out of that state: the fee has already been taken,
// the escrow is empty, the activation timeout answers "not funded", and the
// registry counts the CREATED clone as a live pair, so the same two people can
// no longer be matched through a board. The only key is to put the FULL deal
// amount into a contract nobody will ever activate and wait two days for the
// timeout. The clone stays in the registry for good.
//
// WHAT THIS CUT SHIPS. One line of guard: `msg.sender != address(this)` now
// reverts `NotDiamond()`, where before it was `msg.sender != client &&
// msg.sender != address(this)` reverting `NotClient()`. Both boards reach
// `deployAgreement` as `address(this).call(...)` from inside the same
// transaction and then fund the clone under a `require`, so a refused funding
// reverts everything and the clone never exists. An unfunded clone could
// therefore only ever be born of a direct call from outside; take that away and
// the state with no exit stops being reachable at all.
//
// `deployAndFund` is untouched and stays open — it creates and funds in one
// transaction, so it charges for a deal that exists, and `/deal/new` (the
// direct-hire screen) goes there.
//
// ⚠️ THIS CUT REPLACES, AND THAT IS THE DANGEROUS SHAPE. `Replace` reverts
// "Diamond: selector not found" on a selector that is not mounted; `Add` reverts
// "Diamond: selector exists" on one that is. Either drops the WHOLE cut in one
// live transaction, after the facet has already been paid for. This cut has no
// Add group at all — `deployAgreement` keeps its signature and therefore its
// selector, 0x7ba33dab — and the claim "all twenty-three go in Replace, nothing
// is added, nothing removed" is not taken on trust in either direction:
//
//   * the expected side comes from the BUILD ARTIFACT — solc's own
//     `methodIdentifiers` for FactoryFacet, read out of
//     out/FactoryFacet.sol/FactoryFacet.json — not from the hand-written list in
//     this file. A function the facet gained and this cut does not mount stops
//     the run;
//   * the actual side comes from the LIVE CHAIN, `facetAddress(sel)` through the
//     loupe, in the pre-flight below.
//
// Neither side is derived from the other. The offline twin of the same
// comparison lives in test/FactoryInternalDeployUpgrade.t.sol and is fed by
// test/fixtures/chain-2026-08-29-factory-selectors.json, a census read off Base
// Sepolia at block 46 094 401 (13 facets, 218 routed selectors, 23 of them on
// the factory facet).
//
// ⚠️ WHAT NO SELECTOR COUNT CAN SAY HERE. The facet ships 23 selectors before
// this cut and 23 after; only its body changed. A cut that was signed against
// the wrong commit, or one that silently did not land, would pass every shape
// check in this file. So the only proof the new code is running is a
// BEHAVIOURAL read, and there is one that costs nothing and writes nothing:
// `deployAgreement` called by a stranger on behalf of somebody else answers
// `NotClient()` today and must answer `NotDiamond()` afterwards. Both are clean
// four-byte refusals raised before the function touches any storage, so both can
// be read under `staticcall`. The pre-flight demands the first and refuses if it
// already gets the second; the post-flight demands the second.
//
// STORAGE. Nothing is appended and nothing moves: `FactoryStorage.Layout` is
// untouched by this work. The pre-flight and post-flight read the same four
// facts about the factory across the cut and refuse if any of them moved — a fee
// model that quietly reset would look, from every other angle, exactly healthy.
//
// The diamond address comes from the environment and is never hardcoded.
//
// Usage (dry run — always this one first, it sends no transaction):
//   forge script script/UpgradeFactoryInternalDeploy.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeFactoryInternalDeploy.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {FactoryFacet} from "../src/FactoryFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

contract UpgradeFactoryInternalDeploy is Script {

    /// The build artifact this script holds its own selector list against.
    /// Read through `vm.readFile`; `./out` is already in `fs_permissions`.
    string internal constant ARTIFACT_PATH = "out/FactoryFacet.sol/FactoryFacet.json";

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeFactoryInternalDeploy.s.sol";
    }

    // ── The probe the behavioural check is made of ──────────────────────
    //
    // Deliberately a pair of addresses that are neither the diamond nor the
    // caller: the whole question is "what does the door say to a stranger acting
    // for somebody else", and the answer changes across this cut.
    address internal constant PROBE_CLIENT   = address(0xC11E17);
    address internal constant PROBE_EXECUTOR = address(0xE8EC0);

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

        bytes4[] memory sels = replaceSelectors();

        // The hand-written list against solc's own output, both ways.
        assertReplaceListCoversTheWholeFacet(sels);

        // Every one of them must be mounted TODAY, and all on one facet, or
        // `Replace` reverts and takes the whole cut with it.
        address previousFacet = assertAllMountedOnOneFacet(sels, diamond);

        // And that facet must expose nothing else, or the cut leaves a selector
        // pointing at an address that no longer implements it.
        assertNothingIsLeftBehind(sels, previousFacet, diamond);

        // The chain must still be the one this cut was written for. If the door
        // already refuses with `NotDiamond()`, this cut has landed and a second
        // run would spend real gas to change nothing.
        assertTheDoorIsStillOpenToStrangers(diamond);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        uint256 facetsBefore    = IDiamondLoupe(diamond).facetAddresses().length;
        StorageSnapshot memory beforeCut = snapshotFactory(diamond);

        console.log("=== UpgradeFactoryInternalDeploy: pre-flight ===");
        console.log("Diamond:                     ", diamond);
        console.log("Owner:                       ", currentOwner);
        console.log("Current FactoryFacet:        ", previousFacet);
        console.log("Facets BEFORE cut:           ", facetsBefore);
        console.log("Routed selectors BEFORE cut: ", selectorsBefore);
        console.log("Replace (all mounted, no Add, no Remove):", sels.length);
        console.log("Fee bps:                     ", beforeCut.feeBps);
        console.log("Fee floor:                   ", beforeCut.feeFloor);
        console.log("Fee recipient:               ", beforeCut.feeRecipient);
        console.log("Agreement deployer:          ", beforeCut.agreementDeployer);
        console.log("The door answers a stranger with NotClient() - this cut has not landed yet.");
        console.log("");

        // ── The cut ────────────────────────────────────────────────────────
        vm.startBroadcast(pk);
        FactoryFacet factoryFacet = new FactoryFacet();
        IDiamondCut(diamond).diamondCut(
            buildCuts(address(factoryFacet)),
            address(0),
            ""
        );
        vm.stopBroadcast();

        console.log("New FactoryFacet:", address(factoryFacet));
        console.log("");

        // ── Post-flight: read the result back, do not assume it ────────────
        console.log("=== Post-flight ===");
        assertRouted(sels, address(factoryFacet), diamond);
        console.log("All twenty-three selectors land on the new facet.");

        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(factoryFacet)).length == sels.length,
            "post-flight: the new facet holds a different number of selectors than were replaced"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousFacet).length == 0,
            "post-flight: the old facet still holds selectors - the Replace did not move all of them"
        );

        assertStorageContinuity(beforeCut, snapshotFactory(diamond));
        console.log("Storage continuity OK: the fee model, the recipient and the deployer are where they were.");

        // The one reading that says the cut did what it was FOR. Nothing else
        // can: the selector count is identical on both sides of it.
        assertTheDoorIsShutToStrangers(diamond);
        console.log("Smoke: deployAgreement now refuses a caller who is not the diamond, by name (NotDiamond()).");

        uint256 selectorsAfter = totalRoutedSelectors(diamond);
        uint256 facetsAfter    = IDiamondLoupe(diamond).facetAddresses().length;
        require(
            selectorsAfter == selectorsBefore,
            "post-flight: the routed-selector count moved - a Replace must not change it"
        );
        require(
            facetsAfter == facetsBefore,
            "post-flight: the facet count moved - the old facet should have been emptied, not unmounted"
        );
        console.log("Facets AFTER cut:            ", facetsAfter);
        console.log("Routed selectors AFTER cut:  ", selectorsAfter);
        console.log("");

        console.log("An unfunded clone can no longer be born. The direct-hire road is deployAndFund,");
        console.log("which creates and funds in one transaction and is untouched by this cut.");
        console.log("");
        // ⚠️ Still open: on 21 August a cut shipped
        // three contracts UNVERIFIED because the script fell over on a receipt
        // before it reached `--verify`, and nobody noticed until the owner
        // asked. Nothing in a post-flight can see Basescan, so the least this
        // cut can do is say the address out loud at the end, where it is not
        // buried above the post-flight output.
        console.log("VERIFY THIS ON BASESCAN before calling the cut done - `--verify` is not reached");
        console.log("if the run trips on a receipt, and that is how three contracts shipped");
        console.log("unverified on 21 August:");
        console.log("  FactoryFacet:", address(factoryFacet));
        console.log("");
        console.log("Rollback (points the same twenty-three selectors back at the previous facet,");
        console.log("which is still on chain and still works - it is the code running today):");
        console.log("  forge script script/UpgradeFactoryInternalDeploy.s.sol \\");
        console.log("    --sig \"rollback(address)\" <previous facet> \\");
        console.log("    --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast");
        console.log("  <previous facet> =", previousFacet);
        console.log("");
        console.log("WARNING: rolling back reopens the entrance without payment. Any clone created");
        console.log("through it stays in the registry as a live pair for ever.");
    }

    /// Undo, as a command rather than as a paragraph somebody has to
    /// transcribe. Points the twenty-three selectors back at `previousFacet` and
    /// refuses if the chain is not in the state that follows this cut — a
    /// rollback that runs against an unexpected diamond is how one mistake
    /// becomes two.
    function rollback(address previousFacet) external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        uint256 pk      = vm.envUint("PRIVATE_KEY");
        require(diamond != address(0), "rollback: DIAMOND_ADDRESS is zero");
        require(previousFacet != address(0), "rollback: previous facet is zero");
        require(previousFacet.code.length > 0, "rollback: previous facet has no code");

        bytes4[] memory sels = replaceSelectors();
        address host = assertAllMountedOnOneFacet(sels, diamond);
        require(
            host != previousFacet,
            "rollback: the twenty-three selectors already point at the facet asked for - nothing to undo"
        );

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(previousFacet, IDiamondCut.FacetCutAction.Replace, sels);

        vm.startBroadcast(pk);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        assertRouted(sels, previousFacet, diamond);
        assertTheDoorIsStillOpenToStrangers(diamond);
        console.log("Rolled back: the twenty-three selectors point at", previousFacet);
        console.log("The entrance without payment is open again.");
    }

    // ════════════════════════════════════════════════════════════════════
    // CHECKS — public so test/FactoryInternalDeployUpgrade.t.sol can call them
    // against a locally built diamond, not only through run() on a live chain.
    // ════════════════════════════════════════════════════════════════════

    /// The hand-written Replace list against solc's `methodIdentifiers`. Set
    /// equality, not a count: a count agrees on a swap.
    function assertReplaceListCoversTheWholeFacet(bytes4[] memory sels) public view {
        bytes4[] memory fromArtifact = artifactSelectors();
        require(
            sels.length == fromArtifact.length,
            "pre-flight: the Replace list and the compiled facet disagree on how many functions it has"
        );
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            bool found;
            for (uint256 j = 0; j < sels.length; j++) {
                if (fromArtifact[i] == sels[j]) { found = true; break; }
            }
            require(found, "pre-flight: the facet implements a function this cut does not mount");
        }
        for (uint256 i = 0; i < sels.length; i++) {
            bool found;
            for (uint256 j = 0; j < fromArtifact.length; j++) {
                if (sels[i] == fromArtifact[j]) { found = true; break; }
            }
            require(found, "pre-flight: this cut mounts a selector the facet does not implement");
        }
    }

    /// solc's own answer to "what does this facet expose", straight out of the
    /// build artifact. `methodIdentifiers` maps the signature to the four-byte
    /// selector as text, so nothing has to be hashed here.
    function artifactSelectors() public view returns (bytes4[] memory out) {
        string memory json = vm.readFile(ARTIFACT_PATH);
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i = 0; i < sigs.length; i++) {
            out[i] = bytes4(keccak256(bytes(sigs[i])));
        }
    }

    /// Every selector must be routed TODAY, and all of them to the same address.
    /// An unmounted one belongs in `Add`, not in `Replace`, and putting it in
    /// the wrong group reverts the whole cut. Returns the facet they are on.
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
                "pre-flight: the twenty-three selectors are not all on one facet - this cut assumes one FactoryFacet"
            );
        }
    }

    /// ⚠️ THIS CUT HAS NO Add GROUP, AND THAT IS A CLAIM, NOT A GIVEN. Asked of
    /// the loupe over the whole diamond and not of this script's own list: a
    /// stand that built "what is mounted" out of `replaceSelectors()` would agree
    /// with itself no matter which group a selector was filed under. That is the
    /// fourth way to be fooled by a measurement, and it cost a whole cut once.
    ///
    /// Every function the compiled facet exposes must already be routed
    /// somewhere. One that is not needs an Add group this cut does not have, and
    /// would ship dead: present in the ABI, routed nowhere, discovered by the
    /// first person whose button did nothing.
    function assertTheCompiledFacetNeedsNoAddGroup(address diamond) public view {
        bytes4[] memory fromArtifact = artifactSelectors();
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(fromArtifact[i]) != address(0),
                "pre-flight: the compiled facet exposes a function that is mounted nowhere - this cut needs an Add group and has none"
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
            "pre-flight: the facet being replaced holds a different number of selectors than this cut carries"
        );
    }

    function assertRouted(bytes4[] memory sels, address expected, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                "post-flight: a selector did not land on the new facet"
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // THE BEHAVIOURAL PAIR — the only thing that can tell whether the new
    // code is running, because the selector count is identical either side.
    // ════════════════════════════════════════════════════════════════════

    /// What the door says to a stranger acting for somebody else. Both answers
    /// are raised before the function writes anything, so a `staticcall` reaches
    /// them: this probe sends no transaction and costs nothing.
    ///
    /// Returns the four-byte reason, or `0x00000000` when the call did not
    /// revert at all — which is itself an answer, and a bad one.
    function probeTheDoor(address diamond) public view returns (bytes4 reason) {
        (bool ok, bytes memory ret) = diamond.staticcall(
            abi.encodeWithSelector(
                FactoryFacet.deployAgreement.selector,
                PROBE_CLIENT,
                PROBE_EXECUTOR,
                address(0),          // arbiter, ignored by the facet
                uint256(1),          // amount, non-zero so the guard is reached
                uint256(1),          // deadlineDays, inside MAX_DEADLINE_DAYS
                "door probe",        // terms, non-empty
                uint8(0)             // region, inside range
            )
        );
        require(!ok, "probe: deployAgreement did NOT refuse a stranger - neither the old nor the new facet does that");
        require(ret.length >= 4, "probe: deployAgreement refused with no reason at all");
        assembly { reason := mload(add(ret, 0x20)) }
    }

    /// Pre-flight half: the chain must still be the one this cut was written
    /// for. `NotClient()` is what today's code answers. `NotDiamond()` would
    /// mean this cut has already landed, and running it again would pay for a
    /// facet to change nothing.
    function assertTheDoorIsStillOpenToStrangers(address diamond) public view {
        bytes4 reason = probeTheDoor(diamond);
        require(
            reason != FactoryFacet.NotDiamond.selector,
            "pre-flight: the door already answers NotDiamond() - this cut has already landed on this diamond"
        );
        require(
            reason == FactoryFacet.NotClient.selector,
            "pre-flight: the door answers neither NotClient() nor NotDiamond() - this is not the FactoryFacet this cut was written against"
        );
    }

    /// Post-flight half, and the whole point of the cut: the door is shut, and
    /// shut BY NAME. A refusal with some other reason would mean the run tripped
    /// somewhere else and the guard is not the thing doing the refusing.
    function assertTheDoorIsShutToStrangers(address diamond) public view {
        require(
            probeTheDoor(diamond) == FactoryFacet.NotDiamond.selector,
            "post-flight: deployAgreement does not refuse a stranger with NotDiamond() - the new facet's code is not running"
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
        uint256 feeBps;
        uint256 feeFloor;
        address feeRecipient;
        address agreementDeployer;
    }

    /// Four readings of the factory taken through the diamond, before and after.
    /// This cut appends nothing to `FactoryStorage.Layout`, so all four must
    /// stand still — a fee model that quietly reset would look, from every other
    /// angle, exactly like a healthy factory, and the next deal would be charged
    /// zero or the wrong recipient would be paid.
    function snapshotFactory(address diamond) public view returns (StorageSnapshot memory s) {
        FactoryFacet f = FactoryFacet(diamond);
        s.feeBps            = f.getFeeBps();
        s.feeFloor          = f.getFeeFloor();
        s.feeRecipient      = f.getFeeRecipient();
        s.agreementDeployer = f.getAgreementDeployer();
    }

    function assertStorageContinuity(StorageSnapshot memory beforeCut, StorageSnapshot memory afterCut)
        public pure
    {
        require(
            afterCut.feeBps == beforeCut.feeBps,
            "post-flight: the fee rate changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.feeFloor == beforeCut.feeFloor,
            "post-flight: the fee floor changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.feeRecipient == beforeCut.feeRecipient,
            "post-flight: the fee recipient changed across the cut - the protocol's income would go elsewhere"
        );
        require(
            afterCut.agreementDeployer == beforeCut.agreementDeployer,
            "post-flight: the agreement deployer changed across the cut - this cut does not touch it"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // THE CUT
    // ════════════════════════════════════════════════════════════════════

    /// ONE element, and one action. The facet gains no function and loses none —
    /// `deployAgreement` keeps its signature, so it keeps selector 0x7ba33dab —
    /// so there is no `Add` group and no `Remove` group to get wrong, and the
    /// routed count does not budge. That claim is checked against the build
    /// artifact and against the live chain in the pre-flight, not asserted here.
    function buildCuts(address factoryFacet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            factoryFacet,
            IDiamondCut.FacetCutAction.Replace,
            replaceSelectors()
        );
    }

    /// Twenty-three selectors, taken from the type rather than typed as
    /// literals: a signature change is then picked up by the compiler instead of
    /// by whoever presses the button. Held against the build artifact in
    /// `assertReplaceListCoversTheWholeFacet` and against the live chain in
    /// `assertAllMountedOnOneFacet`.
    ///
    /// Exactly one of them changed BEHAVIOUR in this work — `deployAgreement`,
    /// whose guard now admits the diamond alone. The other twenty-two are here
    /// because a Replace must carry the facet's whole selector set or leave the
    /// remainder pointing at the old address.
    function replaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](23);

        // Set-up, once, at deploy time.
        sels[0] = FactoryFacet.initFactory.selector;
        sels[1] = FactoryFacet.initFeeModel.selector;

        // The two roads into a deal. The first is the one this cut closes to
        // everybody but the diamond; the second is untouched and stays open.
        sels[2] = FactoryFacet.deployAgreement.selector;   // changed: NotDiamond()
        sels[3] = FactoryFacet.deployAndFund.selector;

        // The fee model, written.
        sels[4] = FactoryFacet.setRegionFee.selector;
        sels[5] = FactoryFacet.setFeeBps.selector;
        sels[6] = FactoryFacet.setFeeFloor.selector;
        sels[7] = FactoryFacet.setFeeRecipient.selector;
        sels[8] = FactoryFacet.setMaxPendingRequests.selector;

        // The wiring, written.
        sels[9]  = FactoryFacet.setTrustedForwarder.selector;
        sels[10] = FactoryFacet.setAgreementDeployer.selector;

        // The fee model, read.
        sels[11] = FactoryFacet.getRegionFee.selector;
        sels[12] = FactoryFacet.getAllFees.selector;
        sels[13] = FactoryFacet.getFeeBps.selector;
        sels[14] = FactoryFacet.getFeeFloor.selector;
        sels[15] = FactoryFacet.getFeeRecipient.selector;
        sels[16] = FactoryFacet.quoteFee.selector;
        sels[17] = FactoryFacet.getMaxPendingRequests.selector;

        // The wiring, read.
        sels[18] = FactoryFacet.getTrustedForwarder.selector;
        sels[19] = FactoryFacet.getUsdc.selector;
        sels[20] = FactoryFacet.getAgreementDeployer.selector;

        // Fee the recipient would not take: it can be seen and it can be
        // collected. Without both, a board would push a debt into a field
        // nobody reads.
        sels[21] = FactoryFacet.getUndeliveredFees.selector;
        sels[22] = FactoryFacet.withdrawUndeliveredFees.selector;
    }

    // ════════════════════════════════════════════════════════════════════

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
