// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeAppealDepositSoftRefund.s.sol
//
// A DEPOSIT THAT CANNOT BE DELIVERED NO LONGER LOCKS THE ESCROW. One
// diamondCut, ONE element:
//
//   Replace 59 -> new ArbiterRegistryFacet
//   Add       0
//   Remove    0
//
//   13 facets -> 13 facets, routed selectors 221 -> 221, UNCHANGED
//
// WHAT IS WRONG TODAY (fixed in the tree by 8c9114ee). `resolveAppeal` ended a
// WON appeal with a hard push:
//
//     bool refundOk = IUSDCFull(usdc).transfer(v.appellant, _depositOf(v));
//     require(refundOk, "ArbiterRegistry: deposit refund failed");
//
// USDC can refuse, and a blacklist is the ordinary way. That refund stands
// AFTER `appealResolved = true; frozen = false;`, so its revert took those two
// writes down with it -- and every other door out is already shut:
// finalizeVerdict answers VerdictFrozenError, unfreezeVerdict and
// overturnVerdict answer AppealInProgress, raiseAppeal answers AlreadyAppealed,
// and the Agreement's own last exit, triggerArbiterTimeout, answers
// VerdictInFlight forever, because hasSubmittedVerdict is `submittedAt != 0`
// and never goes back to false. So a $20 deposit stranded the WHOLE escrow
// inside the clone, where no rescue function exists, and it stranded it for the
// man who WON.
//
// The push is now soft, into the claimable that already exists
// (refundableBounty / withdrawDisputeBounty).
//
// ⚠️ THIS IS THE ONE CUT OF THE THREE THAT REACHES DEALS THAT ALREADY EXIST.
// `resolveAppeal` lives on the FACET, not in the clone, so replacing the facet
// changes the behaviour for every deal on the diamond, including the eight
// alive today and the three currently disputed. That is the opposite of
// script/UpgradeAgreementHandInSignal.s.sol, whose delivery is nailed to clones
// not yet born. Read on 31 August 2026: eight deals on record, three DISPUTED,
// none of them with a verdict submitted yet -- so nobody is stuck in this bug
// at this moment, and all three of those disputes can still walk into it.
//
// ⚠️ NO NEW SELECTOR, AND THAT IS A CLAIM THIS SCRIPT HAS TO EARN. `Replace`
// reverts "Diamond: selector not found" on a selector that is not mounted;
// `Add` reverts "Diamond: selector exists" on one that is. A single selector in
// the wrong group drops the WHOLE cut in one transaction, after the facet has
// been paid for. The claim is therefore held against two sources, and NEITHER
// of them is this script's own list:
//
//   * solc's `methodIdentifiers`, read out of the build artifact, answers
//     "does the cut mount exactly what the facet implements";
//   * the live diamond's loupe, asked here at run time and asked offline in
//     test/AppealDepositSoftRefundUpgrade.t.sol against a census committed as
//     data, answers "is every one of the fifty-nine mounted TODAY".
//
// A stand that built "what is mounted" out of this script's own
// `replaceSelectors()` would agree with itself no matter which group a selector
// was filed under. That is the fourth way to be fooled by a measurement and it
// cost a whole cut once.
//
// ⚠️ WHAT A PURE REPLACE CANNOT PROVE ABOUT ITSELF. The selector count is
// IDENTICAL on both sides of this cut -- 221 before, 221 after -- so "the
// numbers match" is exactly as true of a cut that landed as of a cut that never
// ran. The one reading that tells them apart is the CODE behind the selectors:
// the mounted facet's `extcodehash` must differ from
// `keccak256` of the artifact's deployedBytecode before the cut and equal
// it after. Expected side is solc; actual side is the chain; neither is this
// file. That pair is `assertTheLiveFacetIsNotThisCheckout` /
// `assertTheLiveFacetIsThisCheckout`, and it is the reason this script can say
// the cut worked instead of saying the transaction did not revert.
//
// ⚠️ 209 BYTES OF HEADROOM. The facet compiles to 24,367 against the EIP-170
// ceiling of 24,576. It was 24,486 before this fix -- the fix made it SMALLER.
// `new ArbiterRegistryFacet()` over the ceiling reverts with no reason at all,
// and it would do so INSIDE the broadcast, after the gas is committed, so the
// ceiling is checked here where the failure has a sentence attached to it.
//
// STORAGE: NOTHING MOVES. The fix adds no field, reorders none and retypes
// none; the undelivered deposit goes into `refundableBounty`, a mapping that
// already exists and is already read by `getRefundableBounty` and drained by
// `withdrawDisputeBounty`. The snapshot below is taken across the cut anyway,
// because "nothing moved" is a claim, and a claim in front of a live arbiter
// vault holding real USDC is worth a read.
//
// ORDER: INDEPENDENT OF THE OTHER TWO. This cut touches ArbiterRegistryFacet;
// script/UpgradeRegistryHandInSignal.s.sol touches RegistryFacet, a different
// facet with a disjoint selector set. Neither disturbs the other's pre-flight,
// and this one may be run before, between or after them. It does not change the
// routed-selector count, so a census taken for either of the others stays true
// across it.
//
// RUN IT DRY FIRST (no --broadcast):
//   forge script script/UpgradeAppealDepositSoftRefund.s.sol \
//     --rpc-url https://sepolia.base.org
//
// Usage (live):
//   forge script script/UpgradeAppealDepositSoftRefund.s.sol \
//     --rpc-url https://sepolia.base.org --account deployer --sender $OWNER \
//     --broadcast --slow -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

contract UpgradeAppealDepositSoftRefund is Script {

    /// Build artifact this script holds its own selector list against.
    /// Read through `vm.readFile`; `./out` is already in `fs_permissions`.
    string internal constant ARTIFACT_PATH =
        "out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json";

    /// EIP-170. Written here as a literal by a person rather than derived from
    /// anything in the tree: it is the chain's rule and not this project's, and
    /// a constant read out of the thing being measured would be the fourth way
    /// to be fooled by a measurement.
    uint256 public constant CONTRACT_SIZE_LIMIT = 24_576;

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeAppealDepositSoftRefund.s.sol";
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

        bytes4[] memory sels = replaceSelectors();

        // ⚠️ ONE read of the 1.75 MB artifact for the whole run. See
        // `artifactJson()` for what four of them did to a dry run on 31 August.
        bytes4[] memory compiled;
        bytes32 expectedCodehash;
        uint256 compiledSize;
        {
            string memory artifact = artifactJson();
            compiled = selectorsIn(artifact);
            bytes memory deployedCode = deployedCodeIn(artifact);
            expectedCodehash = keccak256(deployedCode);
            compiledSize     = deployedCode.length;
        }

        // The hand-written list against solc's own output, both ways.
        assertReplaceListCovers(sels, compiled);

        // Every one of them must be mounted TODAY, and all on one facet, or
        // `Replace` reverts and takes the whole cut with it.
        address previousFacet = assertAllMountedOnOneFacet(sels, diamond);

        // And that facet must expose nothing else, or the cut leaves a selector
        // pointing at an address that no longer implements it.
        assertNothingIsLeftBehind(sels, previousFacet, diamond);

        // "No Add group" is a claim about the CHAIN, so the chain is asked.
        assertNoAddGroupNeeded(diamond, compiled);

        // The ceiling, before anything is paid for.
        require(
            compiledSize <= CONTRACT_SIZE_LIMIT,
            "pre-flight: the compiled ArbiterRegistryFacet is over the EIP-170 ceiling - `new ArbiterRegistryFacet()` would revert with no reason inside the broadcast"
        );

        // The chain must still be the one this cut was written for. If the
        // mounted code is already byte-for-byte this checkout, the cut has
        // landed and a second run would spend real gas to change nothing.
        assertLiveFacetIsNot(diamond, expectedCodehash);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        uint256 facetsBefore    = IDiamondLoupe(diamond).facetAddresses().length;
        StorageSnapshot memory beforeCut = snapshotArbiterStorage(diamond);

        console.log("=== UpgradeAppealDepositSoftRefund: pre-flight ===");
        console.log("Diamond:                       ", diamond);
        console.log("Owner:                         ", currentOwner);
        console.log("Current ArbiterRegistryFacet:  ", previousFacet);
        console.log("  its code size:               ", previousFacet.code.length);
        console.log("New facet code size:           ", compiledSize);
        console.log("EIP-170 ceiling:               ", CONTRACT_SIZE_LIMIT);
        console.log("Headroom left:                 ", CONTRACT_SIZE_LIMIT - compiledSize);
        console.log("Facets BEFORE cut:             ", facetsBefore);
        console.log("Routed selectors BEFORE cut:   ", selectorsBefore);
        console.log("Replace (all mounted, no Add, no Remove):", sels.length);
        console.log("Routed selectors AFTER cut will be:", selectorsBefore);
        console.log("Seated arbiters:               ", beforeCut.arbiterCount);
        console.log("Vault balance:                 ", beforeCut.vaultBalance);
        console.log("Arbiter floor:                 ", beforeCut.arbiterFloor);
        console.log("DAO threshold:                 ", beforeCut.daoThreshold);
        console.log("Dispute discount:              ", beforeCut.disputeDiscount);
        console.log("The mounted code is NOT this checkout - this cut has not landed yet.");
        console.log("");

        console.log("NOTE: unlike the Agreement half of the hand-in work, this cut reaches deals");
        console.log("that ALREADY EXIST. resolveAppeal lives on the facet, not in the clone, so");
        console.log("every deal on this diamond gets the soft refund the moment the cut lands.");
        console.log("");

        // ── The cut ────────────────────────────────────────────────────────
        vm.startBroadcast();
        ArbiterRegistryFacet arbiterRegistryFacet = new ArbiterRegistryFacet();
        IDiamondCut(diamond).diamondCut(
            buildCuts(address(arbiterRegistryFacet)),
            address(0),
            ""
        );
        vm.stopBroadcast();

        console.log("New ArbiterRegistryFacet:", address(arbiterRegistryFacet));
        console.log("");

        // ── Post-flight: read the result back, do not assume it ────────────
        console.log("=== Post-flight ===");
        assertRouted(sels, address(arbiterRegistryFacet), diamond);
        console.log("All fifty-nine selectors land on the new facet.");

        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(arbiterRegistryFacet)).length == sels.length,
            "post-flight: the new facet holds a different number of selectors than were replaced"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousFacet).length == 0,
            "post-flight: the old facet still holds selectors - the Replace did not move all of them"
        );

        uint256 selectorsAfter = totalRoutedSelectors(diamond);
        uint256 facetsAfter    = IDiamondLoupe(diamond).facetAddresses().length;
        require(
            selectorsAfter == selectorsBefore,
            "post-flight: the routed-selector count moved - a Replace must not change it, so an element of this cut behaved like an Add or a Remove"
        );
        require(
            facetsAfter == facetsBefore,
            "post-flight: the facet count moved - the old facet should have been emptied, not unmounted"
        );

        assertStorageContinuity(beforeCut, snapshotArbiterStorage(diamond));
        console.log("Storage continuity OK: the vault, the floor, the threshold and the seats are where they were.");

        // The one reading that says the cut did what it was FOR. Nothing else
        // can: the selector count is identical on both sides of it.
        assertLiveFacetIs(diamond, expectedCodehash);
        console.log("Smoke: the code behind the fifty-nine selectors is byte-for-byte this checkout,");
        console.log("so resolveAppeal now files an undeliverable deposit instead of reverting on it.");

        console.log("");
        console.log("Facets AFTER cut:            ", facetsAfter);
        console.log("Routed selectors AFTER cut:  ", selectorsAfter);
        console.log("");
        // ⚠️ Still open: on 21 August a cut shipped three contracts UNVERIFIED
        // because the script fell over on a receipt before it reached
        // `--verify`, and nobody noticed until the owner asked. Nothing in a
        // post-flight can see Basescan, so the least this cut can do is say the
        // address out loud at the end, where it is not buried above the
        // post-flight output.
        console.log("VERIFY THIS ON BASESCAN before calling the cut done - `--verify` is not reached");
        console.log("if the run trips on a receipt, and that is how three contracts shipped");
        console.log("unverified on 21 August:");
        console.log("  ArbiterRegistryFacet:", address(arbiterRegistryFacet));
        console.log("");
        console.log("Rollback (points the same fifty-nine selectors back at the previous facet,");
        console.log("which is still on chain and still works - it is the code running today):");
        console.log("  forge script script/UpgradeAppealDepositSoftRefund.s.sol \\");
        console.log("    --sig \"rollback(address)\" <previous facet> \\");
        console.log("    --rpc-url https://sepolia.base.org --account deployer --sender $OWNER --broadcast --slow");
        console.log("  <previous facet> =", previousFacet);
        console.log("");
        console.log("WARNING: rolling back re-opens the lock. A won appeal whose deposit the token");
        console.log("refuses would strand the whole escrow again, and the money already filed under");
        console.log("refundableBounty by the new code stays claimable either way - the old code");
        console.log("reads the same mapping through the same getter.");
    }

    // ════════════════════════════════════════════════════════════════════
    // rollback
    // ════════════════════════════════════════════════════════════════════

    /// Undo, as a command rather than as a paragraph somebody has to
    /// transcribe. Points the fifty-nine selectors back at the previous facet
    /// and refuses to do it blind.
    ///
    /// ⚠️ SAFE ON STORAGE, NOT SAFE ON BEHAVIOUR. This cut appends no storage
    /// and books no money, so there is no state written under the new code that
    /// the old code cannot read: an undelivered deposit filed into
    /// `refundableBounty` stays readable by `getRefundableBounty` and drainable
    /// by `withdrawDisputeBounty`, both of which are unchanged and both of
    /// which exist in the old facet too. What rolling back restores is the
    /// BUG -- the hard refund, and with it the chance of a locked escrow.
    function rollback(address previousFacet) external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");

        require(diamond != address(0), "rollback: DIAMOND_ADDRESS is zero");
        require(previousFacet != address(0), "rollback: previous facet is zero");
        require(previousFacet.code.length > 0, "rollback: previous facet has no code");
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

        bytes4[] memory sels = replaceSelectors();
        address host = assertAllMountedOnOneFacet(sels, diamond);
        require(
            host != previousFacet,
            "rollback: the fifty-nine selectors already point at the facet asked for - nothing to undo"
        );

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            previousFacet,
            IDiamondCut.FacetCutAction.Replace,
            sels
        );

        vm.startBroadcast();
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        assertRouted(sels, previousFacet, diamond);
        console.log("Rolled back: the fifty-nine selectors point at", previousFacet);
        console.log("The hard refund is back, and with it the locked-escrow case this cut removed.");
    }

    // ════════════════════════════════════════════════════════════════════
    // CHECKS — public so test/AppealDepositSoftRefundUpgrade.t.sol can call
    // them against a locally built diamond, not only through run() on a live
    // chain.
    // ════════════════════════════════════════════════════════════════════

    /// The hand-written Replace list against solc's `methodIdentifiers`. Set
    /// equality in both directions, not a count: a count agrees on a swap.
    ///
    ///   * a function the facet implements and this cut does not mount would
    ///     ship dead -- present in the ABI, routed at the OLD code, discovered
    ///     by the first person whose button did the old thing;
    ///   * a selector this cut mounts and the facet does not implement routes
    ///     calls into whatever byte offset happens to be there.
    function assertReplaceListCoversTheWholeFacet(bytes4[] memory sels) public view {
        assertReplaceListCovers(sels, artifactSelectors());
    }

    /// The same check with the compiled side handed in, so `run()` can reuse the
    /// one artifact read it already paid for.
    function assertReplaceListCovers(bytes4[] memory sels, bytes4[] memory fromArtifact) public pure {
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
        return selectorsIn(artifactJson());
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
                "pre-flight: the fifty-nine selectors are not all on one facet - this cut assumes one ArbiterRegistryFacet"
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

    /// ⚠️ THIS CUT HAS NO Add GROUP, AND THAT IS A CLAIM, NOT A GIVEN.
    ///
    /// Asked of the loupe over the WHOLE diamond and not of this script's own
    /// list: the question is "does the compiled facet expose anything that is
    /// routed nowhere", and a function newly added to the source since the last
    /// cut would answer yes. Such a selector needs an `Add` element, and this
    /// cut has none, so `Replace` would revert on it with "Diamond: selector
    /// not found" and take the whole transaction with it after the facet had
    /// been paid for.
    ///
    /// This is the live-chain half of the pair whose offline half is the
    /// committed census. Neither side comes from `replaceSelectors()`.
    function assertTheCompiledFacetNeedsNoAddGroup(address diamond) public view {
        assertNoAddGroupNeeded(diamond, artifactSelectors());
    }

    /// The same check with the compiled side handed in, for the same reason.
    function assertNoAddGroupNeeded(address diamond, bytes4[] memory fromArtifact) public view {
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(fromArtifact[i]) != address(0),
                "pre-flight: the compiled facet exposes a function that is mounted nowhere - this cut needs an Add group and has none"
            );
        }
    }

    /// EIP-170, asserted where the failure has a sentence attached to it.
    /// `new ArbiterRegistryFacet()` on a contract over the limit reverts with
    /// no reason at all, and it would do so INSIDE the broadcast -- after the
    /// gas is committed. The margin here is 209 bytes, which is thin enough
    /// that this is a live risk and not a formality.
    function assertTheImplementationFitsOnChain() public view {
        require(
            compiledFacetSize() <= CONTRACT_SIZE_LIMIT,
            "pre-flight: the compiled ArbiterRegistryFacet is over the EIP-170 ceiling - `new ArbiterRegistryFacet()` would revert with no reason inside the broadcast"
        );
    }

    /// Headroom, so the number can be printed and watched rather than
    /// rediscovered by a failing deploy.
    function facetHeadroom() public view returns (uint256) {
        uint256 size = compiledFacetSize();
        return size >= CONTRACT_SIZE_LIMIT ? 0 : CONTRACT_SIZE_LIMIT - size;
    }

    /// ⚠️ READ OUT OF THE BUILD ARTIFACT, NOT OUT OF THIS CONTRACT'S OWN CODE,
    /// AND THAT IS A CORRECTNESS FIX RATHER THAN A MATTER OF TASTE.
    ///
    /// The obvious spelling is `type(ArbiterRegistryFacet).runtimeCode`, and it
    /// is what stood here first. It embeds the facet's whole 24 KB runtime into
    /// THIS script, on top of the creation code that `new ArbiterRegistryFacet()`
    /// already embeds. That took the compiled script to 69,447 bytes -- the
    /// largest in script/ -- and past the point where the constants in this file
    /// still resolved.
    ///
    /// Measured on 31 August 2026, and it is worth writing down because it fails
    /// SILENTLY in the sense that matters: `vm.readFile` inside
    /// `artifactSelectors()` was dispatched to
    /// 0x2041677265656D656e742068616c66208B820152, an address whose bytes spell
    /// " Agreement half " -- a fragment of a console.log string literal from this
    /// very file. Eight tests reverted with no reason attached, and the live run
    /// would have done exactly the same thing at exactly the same place.
    ///
    /// The artifact is the same oracle -- solc's own output either way -- and it
    /// costs this script nothing to carry.
    function compiledFacetSize() public view returns (uint256) {
        return artifactDeployedCode().length;
    }

    /// ⚠️ THE ARTIFACT IS READ ONCE PER RUN, AND THAT IS NOT A TIDINESS
    /// CONCERN EITHER.
    ///
    /// out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json is 1.75 MB -- the
    /// profile emits `ast` and `storageLayout` into every artifact on purpose,
    /// and this facet is the largest source in the tree. The public helpers
    /// below each read it for themselves, which is right for the offline stand,
    /// where every call is its own frame.
    ///
    /// Inside `run()` it is not: the reads are internal calls sharing one
    /// frame, so four of them expand that frame past forge's memory limit.
    /// Measured on 31 August 2026 in a dry run against the live chain -- the cut
    /// LANDED, the post-flight counts passed, and the run then died with
    /// `MemoryOOG` on the last check. Broadcast for real, that is a signed and
    /// mined diamondCut followed by a script that reports failure, which is the
    /// 21-August shape: the transaction is in and nothing verifies it.
    ///
    /// So `run()` reads the file once, into the two things it actually needs.
    function artifactJson() public view returns (string memory) {
        return vm.readFile(ARTIFACT_PATH);
    }

    function selectorsIn(string memory json) public pure returns (bytes4[] memory out) {
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i = 0; i < sigs.length; i++) {
            out[i] = bytes4(keccak256(bytes(sigs[i])));
        }
    }

    function deployedCodeIn(string memory json) public pure returns (bytes memory) {
        return vm.parseJsonBytes(json, ".deployedBytecode.object");
    }

    /// solc's own compiled runtime for this facet, straight out of the build
    /// artifact. Comparable with an on-chain `extcodehash` only while the
    /// compiler's deployed bytecode is literally what lands on chain;
    /// `ArbiterRegistryFacet` has no constructor and no immutables, so it is.
    /// That is held to a real deployment by
    /// test_TheFreshlyDeployedFacetHashesToTheArtifact rather than left as a
    /// sentence.
    function artifactDeployedCode() public view returns (bytes memory) {
        return deployedCodeIn(artifactJson());
    }

    /// ⚠️ THE ONLY THING THAT TELLS THIS CUT APART FROM NO CUT AT ALL.
    ///
    /// A pure Replace leaves the loupe reading EXACTLY the same before and
    /// after: same thirteen facets, same 221 routed selectors, same set on the
    /// arbiter facet. Every count in the post-flight would therefore be just as
    /// green on a diamond this cut never touched. What changes is the CODE, and
    /// the code is what is read here.
    ///
    /// Expected side is solc (the build artifact's `deployedBytecode`), actual
    /// side is the chain (`extcodehash` of whatever the loupe says is mounted).
    /// Neither is this file, and neither is the other.
    ///
    /// The comparison is only sound while the compiler's deployed bytecode is
    /// literally what lands on chain. `ArbiterRegistryFacet` has no constructor
    /// and no immutables today, so it is; should it ever gain one, this
    /// function starts failing loudly instead of quietly measuring nothing.
    function liveFacetCodehash(address diamond) public view returns (bytes32) {
        address mounted = IDiamondLoupe(diamond).facetAddress(
            ArbiterRegistryFacet.resolveAppeal.selector
        );
        require(
            mounted != address(0),
            "resolveAppeal() is not mounted on this diamond at all - wrong address, or a diamond this cut was not written for"
        );
        return mounted.codehash;
    }

    function thisCheckoutCodehash() public view returns (bytes32) {
        return keccak256(artifactDeployedCode());
    }

    /// Pre-flight half: refuse a diamond that already runs this code. Two runs
    /// of this script would otherwise pay for a second identical facet and cut
    /// it in to change nothing -- which reads afterwards exactly like a
    /// success.
    function assertTheLiveFacetIsNotThisCheckout(address diamond) public view {
        assertLiveFacetIsNot(diamond, thisCheckoutCodehash());
    }

    function assertLiveFacetIsNot(address diamond, bytes32 expected) public view {
        require(
            liveFacetCodehash(diamond) != expected,
            "pre-flight: the mounted ArbiterRegistryFacet is ALREADY byte-for-byte this checkout - this cut has landed, or this is the wrong commit. Running would pay for a facet that changes nothing"
        );
    }

    /// Post-flight half: the code behind the fifty-nine selectors is this
    /// checkout's code. This is what "the soft refund is live" actually means,
    /// and it is the only post-flight reading that a no-op cut could not also
    /// produce.
    function assertTheLiveFacetIsThisCheckout(address diamond) public view {
        assertLiveFacetIs(diamond, thisCheckoutCodehash());
    }

    function assertLiveFacetIs(address diamond, bytes32 expected) public view {
        require(
            liveFacetCodehash(diamond) == expected,
            "post-flight: the code behind resolveAppeal is NOT this checkout - the cut mounted something else, and the counts cannot see it"
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
        uint256 arbiterFloor;
        uint256 daoThreshold;
        uint256 disputeDiscount;
        uint256 rewardPerDispute;
        uint256 treasurySlice;
    }

    /// The arbiter namespace read through the diamond, before and after.
    ///
    /// This cut appends NOTHING to `ArbiterRegistryStorage.Data`, so this
    /// snapshot is not guarding an append -- it is guarding the CLAIM that
    /// nothing was appended. A facet compiled from a source whose layout had
    /// quietly moved would replace the old one without complaint and read the
    /// wrong words from the same slots. The vault balance is the witness that
    /// matters most: it is real USDC, and a shifted layout would show it
    /// somewhere else or as something else.
    function snapshotArbiterStorage(address diamond) public view returns (StorageSnapshot memory s) {
        ArbiterRegistryFacet f = ArbiterRegistryFacet(diamond);
        address[] memory arbiters = f.getArbiters();
        s.arbiterCount     = arbiters.length;
        s.firstArbiter     = arbiters.length > 0 ? arbiters[0] : address(0);
        s.chiefArbiter     = f.getChiefArbiter();
        s.daoAddress       = f.getDAOAddress();
        s.daoActive        = f.isDaoActive();
        s.vaultBalance     = f.getVaultBalance();
        s.arbiterFloor     = f.getArbiterFloor();
        s.daoThreshold     = f.getDaoThreshold();
        s.disputeDiscount  = f.getDisputeDiscount();
        s.rewardPerDispute = f.getRewardPerDispute();
        s.treasurySlice    = f.getTreasurySlice();
    }

    function assertStorageContinuity(
        StorageSnapshot memory beforeCut,
        StorageSnapshot memory afterCut
    ) public pure {
        require(
            beforeCut.arbiterCount == afterCut.arbiterCount,
            "post-flight: getArbiters().length changed across the cut, so the layout may have shifted"
        );
        require(
            beforeCut.firstArbiter == afterCut.firstArbiter,
            "post-flight: the first seated arbiter changed across the cut, so the layout may have shifted"
        );
        require(
            beforeCut.chiefArbiter == afterCut.chiefArbiter,
            "post-flight: the chief arbiter changed across the cut, so the layout may have shifted"
        );
        require(
            beforeCut.daoAddress == afterCut.daoAddress,
            "post-flight: the DAO address changed across the cut, so the layout may have shifted"
        );
        require(
            beforeCut.daoActive == afterCut.daoActive,
            "post-flight: the DAO active flag changed across the cut, so the layout may have shifted"
        );
        require(
            beforeCut.vaultBalance == afterCut.vaultBalance,
            "post-flight: the arbiter vault balance changed across the cut - this cut moves no money, so the layout may have shifted"
        );
        require(
            beforeCut.arbiterFloor == afterCut.arbiterFloor,
            "post-flight: the arbiter floor changed across the cut, so the layout may have shifted"
        );
        require(
            beforeCut.daoThreshold == afterCut.daoThreshold,
            "post-flight: the DAO threshold changed across the cut, so the layout may have shifted"
        );
        require(
            beforeCut.disputeDiscount == afterCut.disputeDiscount,
            "post-flight: the dispute discount changed across the cut, so the layout may have shifted"
        );
        require(
            beforeCut.rewardPerDispute == afterCut.rewardPerDispute,
            "post-flight: the reward per dispute changed across the cut, so the layout may have shifted"
        );
        require(
            beforeCut.treasurySlice == afterCut.treasurySlice,
            "post-flight: the treasury slice changed across the cut, so the layout may have shifted"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // The cut
    // ════════════════════════════════════════════════════════════════════

    function buildCuts(address arbiterRegistryFacet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            arbiterRegistryFacet,
            IDiamondCut.FacetCutAction.Replace,
            replaceSelectors()
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // The one group, written out by hand
    // ════════════════════════════════════════════════════════════════════
    //
    // Hand-written, and NOT derived from the artifact, even though
    // `artifactSelectors()` above can read the artifact. The artifact answers
    // "what does the facet implement"; this list answers "which group does each
    // one go in", and that second question is the one the chain punishes.
    // Deriving the list from the artifact would make the two answers the same
    // answer, and `assertReplaceListCoversTheWholeFacet` would then be
    // comparing a thing with itself.

    /// Mounted today, all fifty-nine of them, and moving to the new facet
    /// address. Nothing is added and nothing is removed.
    function replaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](59);
        uint256 i;

        // ── seats and the register ──
        sels[i++] = ArbiterRegistryFacet.addArbiter.selector;
        sels[i++] = ArbiterRegistryFacet.applyAsArbiter.selector;
        sels[i++] = ArbiterRegistryFacet.resignAsArbiter.selector;
        sels[i++] = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        sels[i++] = ArbiterRegistryFacet.getArbiters.selector;
        sels[i++] = ArbiterRegistryFacet.getArbiterFloor.selector;
        sels[i++] = ArbiterRegistryFacet.setArbiterFloor.selector;
        sels[i++] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        sels[i++] = ArbiterRegistryFacet.getNoResponseFloor.selector;
        sels[i++] = ArbiterRegistryFacet.recordNoResponse.selector;

        // ── the chief ──
        sels[i++] = ArbiterRegistryFacet.getChiefArbiter.selector;
        sels[i++] = ArbiterRegistryFacet.setChiefArbiter.selector;
        sels[i++] = ArbiterRegistryFacet.getChiefBloc.selector;

        // ── governance ──
        sels[i++] = ArbiterRegistryFacet.getDAOAddress.selector;
        sels[i++] = ArbiterRegistryFacet.setDAOAddress.selector;
        sels[i++] = ArbiterRegistryFacet.acceptDAOAddress.selector;
        sels[i++] = ArbiterRegistryFacet.getPendingDAOAddress.selector;
        sels[i++] = ArbiterRegistryFacet.activateDAO.selector;
        sels[i++] = ArbiterRegistryFacet.isDaoActive.selector;
        sels[i++] = ArbiterRegistryFacet.getDaoThreshold.selector;
        sels[i++] = ArbiterRegistryFacet.getMaxArbiterMistakes.selector;

        // ── claims ──
        sels[i++] = ArbiterRegistryFacet.claimDispute.selector;
        sels[i++] = ArbiterRegistryFacet.commitDisputeClaim.selector;
        sels[i++] = ArbiterRegistryFacet.getClaimCommitment.selector;
        sels[i++] = ArbiterRegistryFacet.clearDisputeClaim.selector;
        sels[i++] = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        sels[i++] = ArbiterRegistryFacet.getDisputeClaimer.selector;
        sels[i++] = ArbiterRegistryFacet.getMaxClaimsPerArbiter.selector;

        // ── verdicts ──
        sels[i++] = ArbiterRegistryFacet.submitVerdict.selector;
        sels[i++] = ArbiterRegistryFacet.finalizeVerdict.selector;
        sels[i++] = ArbiterRegistryFacet.getPendingVerdict.selector;
        sels[i++] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        sels[i++] = ArbiterRegistryFacet.freezeVerdict.selector;
        sels[i++] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        sels[i++] = ArbiterRegistryFacet.overturnVerdict.selector;
        sels[i++] = ArbiterRegistryFacet.clearStuckVerdict.selector;
        sels[i++] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        sels[i++] = ArbiterRegistryFacet.recordPresentationDigest.selector;

        // ── appeals - the reason this cut exists ──
        sels[i++] = ArbiterRegistryFacet.raiseAppeal.selector;
        sels[i++] = ArbiterRegistryFacet.voteOnAppeal.selector;
        sels[i++] = ArbiterRegistryFacet.hasVotedOnAppeal.selector;
        sels[i++] = ArbiterRegistryFacet.getAppealVotes.selector;
        sels[i++] = ArbiterRegistryFacet.resolveAppeal.selector;

        // ── the dispute bounty, where the undelivered deposit now lands ──
        sels[i++] = ArbiterRegistryFacet.getDisputeBounty.selector;
        sels[i++] = ArbiterRegistryFacet.getRefundableBounty.selector;
        sels[i++] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        sels[i++] = ArbiterRegistryFacet.fundDispute.selector;
        sels[i++] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;
        sels[i++] = ArbiterRegistryFacet.creditDisputeFee.selector;

        // ── the vault and its economics ──
        sels[i++] = ArbiterRegistryFacet.getVaultBalance.selector;
        sels[i++] = ArbiterRegistryFacet.fundVault.selector;
        sels[i++] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        sels[i++] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        sels[i++] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        sels[i++] = ArbiterRegistryFacet.getTreasurySlice.selector;
        sels[i++] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        sels[i++] = ArbiterRegistryFacet.setDisputeDiscount.selector;
        sels[i++] = ArbiterRegistryFacet.getDisputeDiscount.selector;

        // ── the chat key ──
        sels[i++] = ArbiterRegistryFacet.setArbiterChatKey.selector;

        require(i == 59, "replaceSelectors: the list is not fifty-nine long");
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
