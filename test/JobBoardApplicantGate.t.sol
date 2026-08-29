// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// "AN APPLICANT BELONGS TO A JOB, NOT TO AN ID"
//
// Two halves of one fix, and each scene below names which half it is standing
// on, because they fail independently:
//
//   the door        — `applyForJob` refuses an id no client has posted.
//                     Before this, `JobStatus.OPEN` being zero meant every id
//                     that had never been written read back as an open job, so
//                     an entry could be left on any future number, free, and
//                     with the relayer paying the gas.
//   the inheritance — a job created on an id that was squatted BEFORE the door
//                     closed is born with an empty applicant list. Closing the
//                     door does not empty storage, and what is in storage is
//                     what the next client handed that id would have received:
//                     applicants he never invited, plus `editJob` refusing to
//                     touch the job for ever after (`JobHasApplicants`).
//
// ⚠️ HOW THE "BEFORE" STATE IS PUT ON THE TREE. Not with `vm.store` against a
// hand-computed slot for the list itself, and not by pretending: a test-only
// facet, `LegacyApplyWriter`, performs the two writes the OLD `applyForJob`
// body performed, through the same `JobBoardStorage` library, so the entries
// land in the same words of the same namespace they occupy on Base Sepolia
// today. The scenes then read that state back through the ordinary
// `getApplicants` — see `test_SquattedEntriesAreVisibleWhileTheIdIsStillFree`,
// which exists to prove the reproduction is real before anything is asserted
// about the cure.
//
// ⚠️ Job ids in these scenes are LITERALS (0, 1), never `totalJobs()` and never
// a re-derivation of `nextJobId++`. An expected value computed by the same rule
// as the value under test agrees with it no matter what that rule becomes.
// ============================================================

import "./BoardsFixture.sol";

/// The body of `applyForJob` exactly as it stood before this upgrade: set the
/// flag, push the address. Mounted on the test diamond so that a squatter can
/// still do what the shipped facet no longer lets anybody do.
///
/// It writes through `JobBoardStorage.store()`, i.e. into generation 0 — the
/// pre-upgrade namespace — which is the whole point: the cure has to work
/// against entries that are already there, not against entries the new code
/// put somewhere convenient.
contract LegacyApplyWriter {
    function legacyApply(uint256 jobId, address who) external {
        JobBoardStorage.Layout storage s = JobBoardStorage.store();
        s.hasApplied[jobId][who] = true;
        s.applicants[jobId].push(who);
    }
}

contract JobBoardApplicantGateTest is BoardsFixture {
    /// `applicantGeneration` is field 8 of `JobBoardStorage.Layout`:
    /// nextJobId(0), jobs(1), clientJobs(2), applicants(3), hasApplied(4),
    /// _deprecated_receiptNFT(5), jobFunds(6), jobFeeHeld(7),
    /// applicantGeneration(8). The offset is never taken on trust — every use
    /// of it below first asserts that the word holds what minting just wrote.
    uint256 constant SLOT_APPLICANT_GENERATION = 8;

    address squatter = address(0xBAD);
    address secondExecutor = address(0xE2);

    // ══════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════

    function _mintJob() internal returns (uint256 jobId) {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    function _mintJobWithPermit() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = JobBoardFacet(address(diamond)).mintJobWithPermit(
            client,
            "Build a dApp",
            "Need a Solidity dev",
            AMOUNT,
            DEADLINE,
            TERMS,
            REGION,
            block.timestamp + 1 hours,
            0,
            bytes32(0),
            bytes32(0)
        );
    }

    /// Mounts the pre-upgrade writer as a fourteenth facet of the test diamond.
    /// The fixture leaves this contract as the diamond's owner, so the cut is
    /// the protocol's to make.
    function _mountLegacyWriter() internal {
        LegacyApplyWriter writer = new LegacyApplyWriter();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = LegacyApplyWriter.legacyApply.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(address(writer), IDiamondCut.FacetCutAction.Add, sels);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    function _squat(uint256 jobId, address who) internal {
        LegacyApplyWriter(address(diamond)).legacyApply(jobId, who);
    }

    function _generationSlot(uint256 jobId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(jobId, bytes32(uint256(JobBoardStorage.POSITION) + SLOT_APPLICANT_GENERATION))
        );
    }

    /// Puts an existing job back into the shape a job posted BEFORE this
    /// upgrade has on chain: created, and still on generation 0, so its
    /// applicants live in the pre-upgrade tables. Same technique, and same
    /// reason, as `_makeLegacyJob` in Boards.t.sol.
    function _demoteToPreUpgradeJob(uint256 jobId) internal {
        bytes32 slot = _generationSlot(jobId);
        assertEq(
            uint256(vm.load(address(diamond), slot)),
            1,
            "generation slot offset drifted - minting did not write 1 where this test looks"
        );
        vm.store(address(diamond), slot, bytes32(uint256(0)));
    }

    // ══════════════════════════════════════════════════════════════════
    // HALF ONE — THE DOOR
    // ══════════════════════════════════════════════════════════════════

    /// The finding itself: an empty board, and an application for a job that
    /// does not exist. Before the fix this returned successfully and wrote into
    /// the storage of a job nobody had posted.
    function test_ApplyForJob_RevertsOnAnIdNobodyPosted() public {
        assertEq(JobBoardFacet(address(diamond)).totalJobs(), 0, "the board must start empty");

        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.JobNotFound.selector);
        JobBoardFacet(address(diamond)).applyForJob(0);

        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.JobNotFound.selector);
        JobBoardFacet(address(diamond)).applyForJob(1000000);
    }

    /// The boundary, with both ids written as literals: id 0 exists, id 1 does
    /// not, and the difference between them is one posting.
    function test_ApplyForJob_RevertsOnTheVeryNextId() public {
        uint256 jobId = _mintJob();
        assertEq(jobId, 0, "the first posting must be job 0");

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(0);

        vm.prank(secondExecutor);
        vm.expectRevert(JobBoardFacet.JobNotFound.selector);
        JobBoardFacet(address(diamond)).applyForJob(1);
    }

    /// The ordinary path, which is the thing a gate like this most easily
    /// breaks: an open job still takes applications.
    function test_ApplyForJob_StillAcceptsAnOpenJob() public {
        uint256 jobId = _mintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        address[] memory applicants = JobBoardFacet(address(diamond)).getApplicants(jobId);
        assertEq(applicants.length, 1, "the application did not land");
        assertEq(applicants[0], executor, "the wrong address landed");
    }

    /// A job that EXISTS and is closed must still be refused by name, as
    /// before. Existence and status are two different questions, and the new
    /// check must not answer the second one.
    function test_ApplyForJob_ClosedJobStillSaysJobNotOpen() public {
        uint256 jobId = _mintJob();

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.JobNotOpen.selector);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
    }

    // ══════════════════════════════════════════════════════════════════
    // HALF TWO — THE INHERITANCE
    // ══════════════════════════════════════════════════════════════════

    /// Before anything is claimed about the cure: the reproduction is real.
    /// The entries a pre-upgrade squatter leaves on a free id are visible
    /// through the ordinary reader, exactly as they would be on the live chain.
    function test_SquattedEntriesAreVisibleWhileTheIdIsStillFree() public {
        _mountLegacyWriter();
        _squat(0, squatter);

        address[] memory ghosts = JobBoardFacet(address(diamond)).getApplicants(0);
        assertEq(ghosts.length, 1, "the squat did not land where the old code wrote");
        assertEq(ghosts[0], squatter, "the squat landed with the wrong address");
    }

    /// The cure, on the id a squatter took first.
    function test_MintJob_BornCleanOnAnIdSomebodySquatted() public {
        _mountLegacyWriter();
        _squat(0, squatter);

        uint256 jobId = _mintJob();
        assertEq(jobId, 0, "the posting did not land on the squatted id");

        assertEq(
            JobBoardFacet(address(diamond)).getApplicants(0).length,
            0,
            "the new job inherited applicants left on its id before it existed"
        );
    }

    /// The other writer of `nextJobId`. Both minters have to hand the job a
    /// namespace of its own; one of them forgetting is invisible from the other.
    function test_MintJobWithPermit_BornCleanOnAnIdSomebodySquatted() public {
        _mountLegacyWriter();
        _squat(0, squatter);

        uint256 jobId = _mintJobWithPermit();
        assertEq(jobId, 0, "the posting did not land on the squatted id");

        assertEq(
            JobBoardFacet(address(diamond)).getApplicants(0).length,
            0,
            "the new job inherited applicants left on its id before it existed"
        );
    }

    /// Squatting a NON-zero id, so that "clean" cannot be an accident of the
    /// first slot: post one job, squat the id the second posting will be given,
    /// then post it.
    function test_MintJob_BornCleanOnASquattedIdThatIsNotZero() public {
        _mountLegacyWriter();
        uint256 first = _mintJob();
        assertEq(first, 0, "the first posting must be job 0");

        _squat(1, squatter);
        assertEq(
            JobBoardFacet(address(diamond)).getApplicants(1).length, 1, "the squat did not land on id 1"
        );

        uint256 second = _mintJob();
        assertEq(second, 1, "the second posting did not land on the squatted id");
        assertEq(
            JobBoardFacet(address(diamond)).getApplicants(1).length,
            0,
            "the second job inherited applicants left on its id before it existed"
        );
    }

    /// The consequence the finding is actually about: a client who posts a job
    /// can correct it. `editJob` refuses a job with any applicants, so an
    /// inherited entry locks the text of a brand new posting for ever.
    function test_EditJob_WorksRightAfterCreationOnASquattedId() public {
        _mountLegacyWriter();
        _squat(0, squatter);

        uint256 jobId = _mintJob();

        vm.prank(client);
        JobBoardFacet(address(diamond)).editJob(jobId, "Corrected title", "Corrected description", 14, TERMS, REGION);

        JobBoardStorage.Job memory job = JobBoardFacet(address(diamond)).getJob(jobId);
        assertEq(job.title, "Corrected title", "the correction did not take");
        assertEq(job.deadlineDays, 14, "the correction did not take");
    }

    /// The flag table, not just the list. A stale `hasApplied` would answer
    /// `AlreadyApplied` to somebody applying for the first time.
    function test_SquatterCanStillApplyForRealAfterTheJobIsCreated() public {
        _mountLegacyWriter();
        _squat(0, squatter);

        uint256 jobId = _mintJob();

        vm.prank(squatter);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        address[] memory applicants = JobBoardFacet(address(diamond)).getApplicants(jobId);
        assertEq(applicants.length, 1, "the real application did not land");
        assertEq(applicants[0], squatter, "the real application landed with the wrong address");
    }

    /// And the other direction, which is the dangerous one: a stale flag would
    /// let a client hire somebody who never appeared on the board.
    function test_AcceptApplicant_IgnoresAFlagLeftBeforeTheJobExisted() public {
        _mountLegacyWriter();
        _squat(0, squatter);

        uint256 jobId = _mintJob();

        vm.prank(client);
        vm.expectRevert(JobBoardFacet.NotApplicant.selector);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, squatter);
    }

    // ══════════════════════════════════════════════════════════════════
    // WHAT THE CURE MUST NOT COST: THE JOBS ALREADY ON CHAIN
    // ══════════════════════════════════════════════════════════════════

    /// Base Sepolia holds jobs posted before this upgrade, two of them with a
    /// real applicant each. Their bookkeeping is in generation 0 and has to
    /// stay readable and usable — a namespace switch that quietly emptied them
    /// would look exactly like a clean board.
    function test_PreUpgradeJobKeepsItsApplicantsAndCanStillHire() public {
        _mountLegacyWriter();
        uint256 jobId = _mintJob();
        _demoteToPreUpgradeJob(jobId);

        // The application as the old facet recorded it.
        _squat(jobId, executor);

        address[] memory applicants = JobBoardFacet(address(diamond)).getApplicants(jobId);
        assertEq(applicants.length, 1, "a pre-upgrade job lost its applicants");
        assertEq(applicants[0], executor, "a pre-upgrade job lost its applicants");

        vm.prank(client);
        address agreementAddr = JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
        assertTrue(agreementAddr != address(0), "a pre-upgrade job could no longer hire its applicant");
    }

    /// And a pre-upgrade job still takes new applications into the same
    /// generation-0 tables its old ones live in, rather than splitting them
    /// across two namespaces.
    function test_PreUpgradeJobStillTakesNewApplications() public {
        _mountLegacyWriter();
        uint256 jobId = _mintJob();
        _demoteToPreUpgradeJob(jobId);
        _squat(jobId, executor);

        vm.prank(secondExecutor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        address[] memory applicants = JobBoardFacet(address(diamond)).getApplicants(jobId);
        assertEq(applicants.length, 2, "the new application did not join the old ones");
        assertEq(applicants[0], executor, "the old application went missing");
        assertEq(applicants[1], secondExecutor, "the new application went missing");

        vm.prank(secondExecutor);
        JobBoardFacet(address(diamond)).withdrawApplication(jobId);
        assertEq(
            JobBoardFacet(address(diamond)).getApplicants(jobId).length,
            1,
            "withdrawing from a pre-upgrade job did not remove the right entry"
        );
    }
}
