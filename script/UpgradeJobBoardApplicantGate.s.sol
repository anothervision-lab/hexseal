// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeJobBoardApplicantGate.s.sol
//
// AN APPLICANT BELONGS TO A JOB, NOT TO AN ID — one diamondCut, one element,
// REPLACE ONLY.
//
// WHAT IS WRONG TODAY. `JobStatus.OPEN` is the zero value of the enum, and zero
// in storage is also "nothing was ever written here". So on the live diamond
// every id that has never been posted reads back as an open job, and
// `applyForJob` accepts an application for it: the status gate passes (status is
// OPEN), the self-apply gate passes (the client of a job that does not exist is
// the zero address), and the duplicate gate passes. The entry lands in the
// storage of a job nobody has created yet, it costs the applicant nothing, and
// the relayer pays the gas. There is no ceiling on the id and none on the count.
//
// The damage arrives later, to somebody else. The client eventually handed that
// id gets a job that is born with applicants he never invited — and `editJob`
// refuses to touch a job that has any (`JobHasApplicants`), so his first
// posting can never be corrected, not once, not ever.
//
// Measured on Base Sepolia on 25 August 2026, block 45 924 636: totalJobs = 5,
// and `getApplicants` over ids 5, 6, 7, 8, 10, 42 and 1 000 000 all answered
// with an empty list. Nobody has done it yet. That is the reason this cut is
// worth making now rather than the reason to make only half of it.
//
// WHAT THIS CUT SHIPS. A rebuilt JobBoardFacet with two changes:
//
//   the door        `applyForJob` refuses an id at or beyond `nextJobId` with
//                   a named error, `JobNotFound()`. The counter is the witness
//                   of existence: it moves only in the two minters, one step
//                   per job created, and never goes back. It says nothing about
//                   status — a CANCELLED or ACCEPTED job is past that line and
//                   is still turned away by `JobNotOpen`, by name, as before.
//
//   the inheritance closing the door does not empty storage, and the window
//                   between this file being written in a PUBLIC repository and
//                   this cut being signed is exactly when somebody would use
//                   what it describes. So a job created from now on is handed
//                   an applicant namespace of its own: `applicantGeneration` is
//                   bumped at creation, and the applicant list and the
//                   `hasApplied` table are read out of that generation.
//                   Generation 0 is the pre-upgrade namespace and stays exactly
//                   where it is, which is what keeps the applicants of the five
//                   jobs already on chain readable and hireable.
//
//                   `delete s.applicants[jobId]` was the obvious alternative and
//                   is not affordable: it costs one store per entry, and the
//                   number of entries is chosen by whoever left them, so a
//                   client could be handed an id that costs more gas to post on
//                   than the relayer will spend — the griefing moved, not
//                   removed. Bumping a counter is one store no matter how much
//                   was left behind.
//
// ⚠️ THIS CUT REPLACES, AND THAT IS THE DANGEROUS SHAPE. `Replace` reverts
// "Diamond: selector not found" on a selector that is not mounted; `Add` reverts
// "Diamond: selector exists" on one that is. Either drops the WHOLE cut in one
// live transaction, after the facet has been paid for. A cut that puts a
// selector in the wrong group is therefore not a cosmetic mistake.
//
// The claim this script makes is "all thirteen go in Replace and the Add group
// is empty", and it is not taken on trust in either direction:
//
//   * the expected side comes from the BUILD ARTIFACT — solc's own
//     `methodIdentifiers` for JobBoardFacet, read out of
//     out/JobBoardFacet.sol/JobBoardFacet.json — not from the hand-written list
//     in this file. A function the facet gained and this cut does not mount
//     stops the run;
//   * the actual side comes from the LIVE CHAIN, `facetAddress(sel)` through the
//     loupe, in the pre-flight below.
//
// Neither side is derived from the other. The offline twin of the same
// comparison lives in test/JobBoardApplicantGateUpgrade.t.sol and is fed by
// test/fixtures/chain-2026-08-25-jobboard-selectors.json, a census read off Base
// Sepolia at block 45 924 636 (13 facets, 214 routed selectors, 13 of them on
// the JobBoard facet).
//
// The storage layout is APPENDED to, never reordered: three new mappings at the
// end of `JobBoardStorage.Layout`. The pre-flight and post-flight read the same
// three facts about the board across the cut and refuse if any of them moved.
//
// The diamond address comes from the environment and is never hardcoded.
//
// Usage (dry run — always this one first, it sends no transaction):
//   forge script script/UpgradeJobBoardApplicantGate.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeJobBoardApplicantGate.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {JobBoardFacet, JobBoardStorage} from "../src/facets/JobBoardFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

contract UpgradeJobBoardApplicantGate is Script {

    /// The build artifact this script holds its own selector list against.
    /// Read through `vm.readFile`; `./out` is already in `fs_permissions`.
    string internal constant ARTIFACT_PATH = "out/JobBoardFacet.sol/JobBoardFacet.json";

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeJobBoardApplicantGate.s.sol";
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

        bytes4[] memory sels = replaceSelectors();

        // The hand-written list against solc's own output, both ways.
        assertReplaceListCoversTheWholeFacet(sels);

        // Every one of them must be mounted TODAY, and all on one facet, or
        // `Replace` reverts and takes the whole cut with it.
        address previousFacet = assertAllMountedOnOneFacet(sels, diamond);

        // And that facet must expose nothing else, or the cut leaves a selector
        // pointing at an address that no longer implements it.
        assertNothingIsLeftBehind(sels, previousFacet, diamond);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        uint256 facetsBefore    = IDiamondLoupe(diamond).facetAddresses().length;
        StorageSnapshot memory beforeCut = snapshotBoard(diamond);

        console.log("=== UpgradeJobBoardApplicantGate: pre-flight ===");
        console.log("Diamond:                     ", diamond);
        console.log("Owner:                       ", currentOwner);
        console.log("Current JobBoardFacet:       ", previousFacet);
        console.log("Facets BEFORE cut:           ", facetsBefore);
        console.log("Routed selectors BEFORE cut: ", selectorsBefore);
        console.log("Replace (all mounted, no Add, no Remove):", sels.length);
        console.log("Jobs on the board:           ", beforeCut.totalJobs);
        console.log("Applicants across all of them:", beforeCut.totalApplicants);
        console.log("");

        // ── The cut ────────────────────────────────────────────────────────
        vm.startBroadcast(pk);
        JobBoardFacet jobBoardFacet = new JobBoardFacet();
        IDiamondCut(diamond).diamondCut(
            buildCuts(address(jobBoardFacet)),
            address(0),
            ""
        );
        vm.stopBroadcast();

        console.log("New JobBoardFacet:", address(jobBoardFacet));
        console.log("");

        // ── Post-flight: read the result back, do not assume it ────────────
        console.log("=== Post-flight ===");
        assertRouted(sels, address(jobBoardFacet), diamond);
        console.log("All thirteen selectors land on the new facet.");

        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(jobBoardFacet)).length == sels.length,
            "post-flight: the new facet holds a different number of selectors than were replaced"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousFacet).length == 0,
            "post-flight: the old facet still holds selectors - the Replace did not move all of them"
        );

        assertStorageContinuity(beforeCut, snapshotBoard(diamond));
        console.log("Storage continuity OK: jobs, applicants and the first client are where they were.");

        assertUnpostedIdIsRefused(diamond);
        console.log("Smoke: applying for the id one past the last job is refused with JobNotFound().");

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

        console.log("An application now needs a job to apply to.");
        console.log("");
        console.log("Rollback (points the same thirteen selectors back at the previous facet,");
        console.log("which is still on chain and still works - it is the code running today):");
        console.log("  forge script script/UpgradeJobBoardApplicantGate.s.sol \\");
        console.log("    --sig \"rollback(address)\" <previous facet> \\");
        console.log("    --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast");
        console.log("  <previous facet> =", previousFacet);
        console.log("");
        console.log("WARNING: rolling back reopens the door AND leaves every job created in between on");
        console.log("generation 1, where the old code cannot see its applicants at all.");
    }

    /// Undo, as a command rather than as a paragraph somebody has to
    /// transcribe. Points the thirteen selectors back at `previousFacet` and
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
            "rollback: the thirteen selectors already point at the facet asked for - nothing to undo"
        );

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(previousFacet, IDiamondCut.FacetCutAction.Replace, sels);

        vm.startBroadcast(pk);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        assertRouted(sels, previousFacet, diamond);
        console.log("Rolled back: the thirteen selectors point at", previousFacet);
        console.log("The door is open again.");
    }

    // ════════════════════════════════════════════════════════════════════
    // CHECKS — public so test/JobBoardApplicantGateUpgrade.t.sol can call them
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
                "pre-flight: the thirteen selectors are not all on one facet - this cut assumes one JobBoardFacet"
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

    /// Functional smoke, and the only one that says the cut did what it was for:
    /// the id one past the last job is refused, and refused BY NAME.
    ///
    /// ⚠️ A plain `call`, not a `staticcall`. Under `staticcall` the old,
    /// broken facet would also "fail" — it writes storage — and this check would
    /// pass against the very code it is supposed to catch. Outside
    /// startBroadcast/stopBroadcast nothing here is sent to the chain; on a dry
    /// run it executes against the simulated post-cut state, which is the state
    /// being asked about.
    function assertUnpostedIdIsRefused(address diamond) public {
        (bool okRead, bytes memory total) = diamond.staticcall(
            abi.encodeWithSelector(JobBoardFacet.totalJobs.selector)
        );
        require(okRead && total.length >= 32, "post-flight: the diamond does not answer totalJobs()");
        uint256 unposted = abi.decode(total, (uint256));

        (bool ok, bytes memory ret) = diamond.call(
            abi.encodeWithSelector(JobBoardFacet.applyForJob.selector, unposted)
        );
        require(!ok, "post-flight: an application for a job nobody posted still succeeds");
        require(ret.length >= 4, "post-flight: refused with no reason at all");
        bytes4 reason;
        assembly { reason := mload(add(ret, 0x20)) }
        require(
            reason == JobBoardFacet.JobNotFound.selector,
            "post-flight: refused, but not by name - JobNotFound() was expected"
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
        uint256 totalJobs;
        uint256 totalApplicants;
        address firstJobClient;
    }

    /// Three readings of the board taken through the diamond, before and after.
    ///
    /// `totalApplicants` is the one this particular cut has to earn: the new
    /// facet reads applicants out of a per-job generation, and generation 0 —
    /// where every job already on chain keeps its applicants — has to keep
    /// answering. A namespace switch that lost them would look, from every
    /// other angle, exactly like a healthy board.
    function snapshotBoard(address diamond) public view returns (StorageSnapshot memory s) {
        JobBoardFacet board = JobBoardFacet(diamond);
        s.totalJobs = board.totalJobs();
        for (uint256 i = 0; i < s.totalJobs; i++) {
            s.totalApplicants += board.getApplicants(i).length;
        }
        if (s.totalJobs > 0) s.firstJobClient = board.getJob(0).client;
    }

    function assertStorageContinuity(StorageSnapshot memory beforeCut, StorageSnapshot memory afterCut)
        public pure
    {
        require(
            afterCut.totalJobs == beforeCut.totalJobs,
            "post-flight: totalJobs changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.totalApplicants == beforeCut.totalApplicants,
            "post-flight: the jobs on chain lost or gained applicants across the cut"
        );
        require(
            afterCut.firstJobClient == beforeCut.firstJobClient,
            "post-flight: job 0 has a different client across the cut - the layout may have shifted"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // THE CUT
    // ════════════════════════════════════════════════════════════════════

    /// ONE element, and one action. The facet gains no function and loses none,
    /// so there is no `Add` group and no `Remove` group to get wrong — the whole
    /// selector set moves from one address to another and the routed count does
    /// not budge. That claim is checked against the build artifact and against
    /// the live chain in the pre-flight, not asserted here.
    function buildCuts(address jobBoardFacet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            jobBoardFacet,
            IDiamondCut.FacetCutAction.Replace,
            replaceSelectors()
        );
    }

    /// Thirteen selectors, taken from the type rather than typed as literals: a
    /// signature change is then picked up by the compiler instead of by whoever
    /// presses the button. Held against the build artifact in
    /// `assertReplaceListCoversTheWholeFacet` and against the live chain in
    /// `assertAllMountedOnOneFacet`.
    function replaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](13);

        // Posting. Both minters now hand the new job an applicant generation of
        // its own — this is the half of the fix that cannot be done by refusing
        // calls, because the entries it defends against are already in storage.
        sels[0] = JobBoardFacet.mintJobWithPermit.selector;
        sels[1] = JobBoardFacet.mintJob.selector;

        // The door itself, and its neighbour: both read the applicant tables
        // through the job's generation now.
        sels[2] = JobBoardFacet.applyForJob.selector;
        sels[3] = JobBoardFacet.withdrawApplication.selector;

        // Hiring reads `hasApplied`, and editing reads the list length — a
        // stale entry in either is what made a fresh posting uneditable.
        sels[4] = JobBoardFacet.acceptApplicant.selector;
        sels[5] = JobBoardFacet.cancelJob.selector;
        sels[6] = JobBoardFacet.editJob.selector;

        // Reads. `getApplicants` moved with the rest; the other four are
        // untouched by this work and are here because a Replace must carry the
        // facet's whole selector set or leave the remainder pointing at the old
        // address.
        sels[7]  = JobBoardFacet.getJob.selector;
        sels[8]  = JobBoardFacet.getClientJobs.selector;
        sels[9]  = JobBoardFacet.getApplicants.selector;
        sels[10] = JobBoardFacet.totalJobs.selector;
        sels[11] = JobBoardFacet.getOpenJobs.selector;
        sels[12] = JobBoardFacet.getJobFeeHeld.selector;
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
