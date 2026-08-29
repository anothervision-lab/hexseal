// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BoardsFixture.sol";
import "../src/SVGRenderer.sol";

// ---------- TEST ----------

contract BoardsTest is BoardsFixture {
    // ============================================================
    //  HELPERS
    // ============================================================

    function _approveAndMintJob() internal returns (uint256 jobId) {
        vm.startPrank(client);
        // JobBoard now prices through quote() (a percentage) rather than by region
        // — approve the whole balance instead of the exact old FEE + AMOUNT.
        usdc.approve(address(diamond), type(uint256).max);
        jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp",
            "Need a Solidity dev",
            AMOUNT,
            DEADLINE,
            TERMS,
            REGION
        );
        vm.stopPrank();
    }

    // ============================================================
    //  JOB BOARD TESTS
    // ============================================================

    function testMintJob() public {
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        uint256 jobId = _approveAndMintJob();

        assertEq(jobId, 0);

        JobBoardStorage.Job memory job = JobBoardFacet(address(diamond)).getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.amount, AMOUNT);
        assertEq(uint256(job.status), uint256(JobBoardStorage.JobStatus.OPEN));

        // The fee is held in the Diamond — there is no deal yet, the recipient got nothing
        assertEq(usdc.balanceOf(client), clientBefore - JOB_FEE - AMOUNT);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore);
        assertEq(usdc.balanceOf(address(diamond)), AMOUNT + JOB_FEE);
    }

    function testMintJobInvalidTitle() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), FEE + AMOUNT);

        vm.expectRevert(JobBoardFacet.TitleInvalid.selector);
        JobBoardFacet(address(diamond)).mintJob("", "desc", AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    function testMintJobZeroAmount() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), FEE + AMOUNT);

        vm.expectRevert(JobBoardFacet.ZeroAmount.selector);
        JobBoardFacet(address(diamond)).mintJob("title", "desc", 0, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    function testApplyForJob() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        address[] memory applicants = JobBoardFacet(address(diamond)).getApplicants(jobId);
        assertEq(applicants.length, 1);
        assertEq(applicants[0], executor);
    }

    function testApplyForJobDuplicate() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.AlreadyApplied.selector);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
    }

    function testApplyForJobSelf() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(client);
        vm.expectRevert(JobBoardFacet.SelfApply.selector);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
    }

    function testAcceptApplicant() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(client);
        address agreementAddr = JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);

        // The job was updated
        JobBoardStorage.Job memory job = JobBoardFacet(address(diamond)).getJob(jobId);
        assertEq(uint256(job.status), uint256(JobBoardStorage.JobStatus.ACCEPTED));
        assertEq(job.chosenExecutor, executor);
        assertEq(job.agreement, agreementAddr);

        // The Diamond gave the amount to the Agreement and the held fee to feeRecipient
        assertEq(usdc.balanceOf(address(diamond)), 0);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore + JOB_FEE);

        // The Agreement is registered in the Registry
        assertTrue(RegistryFacet(address(diamond)).hasActivePair(client, executor));

        // The Agreement address is non-zero
        assertTrue(agreementAddr != address(0));
    }

    function testAcceptApplicantNotClient() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        vm.prank(executor); // not the client
        vm.expectRevert(JobBoardFacet.NotClient.selector);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
    }

    function testAcceptApplicantNotApplied() public {
        uint256 jobId = _approveAndMintJob();
        // The executor never applied

        vm.prank(client);
        vm.expectRevert(JobBoardFacet.NotApplicant.selector);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
    }

    function testCancelJob() public {
        uint256 jobId = _approveAndMintJob();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        // Refund: amount + the fee above the floor; the floor stays with the protocol
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT + (JOB_FEE - JOB_FLOOR));
        assertEq(usdc.balanceOf(feeRecipient), JOB_FLOOR);
        assertEq(usdc.balanceOf(address(diamond)), 0);

        // Status
        JobBoardStorage.Job memory job = JobBoardFacet(address(diamond)).getJob(jobId);
        assertEq(uint256(job.status), uint256(JobBoardStorage.JobStatus.CANCELLED));
    }

    function testCancelJobNotClient() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.NotClient.selector);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
    }

    function testCancelJobAlreadyCancelled() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        vm.prank(client);
        vm.expectRevert(JobBoardFacet.JobNotOpen.selector);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
    }

    function testCancelAfterAccept() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        vm.prank(client);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);

        vm.prank(client);
        vm.expectRevert(JobBoardFacet.JobNotOpen.selector);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
    }

    // ============================================================
    //  JOB BOARD FEE HOLDING
    // ============================================================

    function testMintJob_FeeHeldNotForwarded() public {
        uint256 amount = 200_000_000;      // $200
        uint256 fee = 10_000_000;          // 5%

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + fee);
        JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        // The fee is NOT with the recipient yet — there is no deal
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(usdc.balanceOf(address(diamond)), amount + fee);
    }

    function testAcceptApplicant_ForwardsHeldFee() public {
        uint256 amount = 200_000_000;
        uint256 fee = 10_000_000;

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + fee);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(client);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);

        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(address(diamond)), 0);
    }

    function testCancelJob_RefundsFeeAboveFloor() public {
        uint256 amount = 200_000_000;      // $200
        uint256 fee = 10_000_000;          // 5%
        uint256 floor_ = 1_000_000;        // $1
        uint256 before = usdc.balanceOf(client);

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + fee);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", amount, DEADLINE, TERMS, REGION
        );
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        vm.stopPrank();

        // The client lost exactly the floor, everything else came back
        assertEq(usdc.balanceOf(client), before - floor_);
        assertEq(usdc.balanceOf(feeRecipient), floor_);
        assertEq(usdc.balanceOf(address(diamond)), 0);
    }

    function testCancelJob_SmallDealBurnsWholeFee() public {
        uint256 amount = 20_000_000;       // $20 — the fee equals the floor
        uint256 fee = 1_000_000;
        uint256 before = usdc.balanceOf(client);

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + fee);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob(
            "Small task", "Tiny", amount, DEADLINE, TERMS, REGION
        );
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(client), before - fee);
        assertEq(usdc.balanceOf(feeRecipient), fee);
    }

    function testCancelJob_EmitsActualReturnedAmount() public {
        uint256 amount = 200_000_000;      // $200
        uint256 fee = 10_000_000;          // 5%
        uint256 floor_ = 1_000_000;        // $1

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + fee);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", amount, DEADLINE, TERMS, REGION
        );

        // JobCancelled must carry the amount that actually came back to the client
        // (amount + the fee above the floor), not merely the order amount — the
        // client prints this field verbatim in the notification.
        vm.expectEmit(true, true, false, true, address(diamond));
        emit JobBoardFacet.JobCancelled(jobId, client, amount + (fee - floor_));
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        vm.stopPrank();
    }

    function testCancelJob_FloorRaisedAfterMint_BurnsOnlyWhatWasHeld() public {
        uint256 amount = 20_000_000;       // $20 — held fee = $1 (floor at mint time)
        uint256 heldFee = 1_000_000;
        uint256 before = usdc.balanceOf(client);

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + heldFee);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob(
            "Small task", "Tiny", amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        // The owner raises the floor AFTER the mint — above the fee already held.
        // The same case exists in live storage: orders created before the upgrade,
        // whose feeFloor at mint time was different (or zero).
        FactoryFacet(address(diamond)).setFeeFloor(2_000_000);

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        // The floor (2_000_000) is now larger than the held fee (1_000_000) — what
        // burns is exactly what was held, the client gets nothing back beyond the
        // order amount, and the subtraction does not underflow.
        assertEq(usdc.balanceOf(client), before - heldFee);
        assertEq(usdc.balanceOf(feeRecipient), heldFee);
        assertEq(usdc.balanceOf(address(diamond)), 0);
    }

    // ============================================================
    //  JOB RECEIPT NFT TESTS
    // ============================================================

    function testJobReceiptMintedOnJobPost() public {
        assertEq(JobReceiptFacet(address(diamond)).getReceiptTotalSupply(), 0);

        _approveAndMintJob();

        assertEq(JobReceiptFacet(address(diamond)).getReceiptTotalSupply(), 1);
        assertEq(JobReceiptFacet(address(diamond)).balanceOf(client), 1);
        assertEq(JobReceiptFacet(address(diamond)).ownerOf(0), client);
        assertTrue(JobReceiptFacet(address(diamond)).isJobReceiptToken(0));
    }

    function testJobReceiptData() public {
        _approveAndMintJob();

        ReceiptStorage.JobReceiptData memory data = JobReceiptFacet(address(diamond)).getJobReceiptData(0);
        assertEq(data.client, client);
        assertEq(data.amount, AMOUNT);
        assertEq(data.deadlineDays, DEADLINE);
        assertEq(data.region, REGION);
        assertEq(data.title, "Build a dApp");
    }

    function testJobReceiptSoulbound() public {
        _approveAndMintJob();

        vm.prank(client);
        vm.expectRevert();
        JobReceiptFacet(address(diamond)).transferFrom(client, address(0x5), 0);
    }

    function testJobReceiptDirectMintReverts() public {
        vm.expectRevert("Only Diamond");
        JobReceiptFacet(address(diamond)).mintJobReceipt(client, 0, AMOUNT, DEADLINE, REGION, "title");
    }

    function testJobReceiptIdempotent() public {
        // Two jobs — each gets its own receipt
        _approveAndMintJob();

        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        JobBoardFacet(address(diamond)).mintJob(
            "Second Job",
            "Another task",
            AMOUNT,
            DEADLINE,
            TERMS,
            REGION
        );
        vm.stopPrank();

        assertEq(JobReceiptFacet(address(diamond)).getReceiptTotalSupply(), 2);
        assertEq(JobReceiptFacet(address(diamond)).balanceOf(client), 2);
    }

    function testJobReceiptNotReceiptToken() public view {
        assertFalse(JobReceiptFacet(address(diamond)).isJobReceiptToken(99));
    }

    function testJobReceiptSetSvgRenderer() public {
        address renderer = address(0xABC);
        JobReceiptFacet(address(diamond)).setSvgRenderer(renderer);
        assertEq(JobReceiptFacet(address(diamond)).getSvgRenderer(), renderer);
    }

    function testJobReceiptTokenURIRevertsWithoutRenderer() public {
        _approveAndMintJob();
        // Without an SVGRenderer, tokenURI reverts
        vm.expectRevert("SVGRenderer not set");
        JobReceiptFacet(address(diamond)).tokenURI(0);
    }

    function testCancelJobBurnsReceipt() public {
        uint256 jobId = _approveAndMintJob();

        // The receipt was minted when the order was created
        assertEq(JobReceiptFacet(address(diamond)).ownerOf(0), client);
        assertFalse(JobReceiptFacet(address(diamond)).isJobReceiptBurned(0));

        (uint256 tokenId, bool exists) = JobReceiptFacet(address(diamond)).getTokenIdByJobId(jobId);
        assertEq(tokenId, 0);
        assertTrue(exists);

        // Cancel the order
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        // The receipt must be burned
        assertTrue(JobReceiptFacet(address(diamond)).isJobReceiptBurned(0));
        assertEq(JobReceiptFacet(address(diamond)).balanceOf(client), 0);

        // ownerOf reverts for a burned token
        vm.expectRevert("ERC721: nonexistent token");
        JobReceiptFacet(address(diamond)).ownerOf(0);

        // getJobReceiptData still works — the data is kept for history
        ReceiptStorage.JobReceiptData memory data = JobReceiptFacet(address(diamond)).getJobReceiptData(0);
        assertEq(data.client, client);
        assertEq(data.amount, AMOUNT);
    }

    function testBurnJobReceiptDirectReverts() public {
        _approveAndMintJob();

        vm.prank(address(0x99));
        vm.expectRevert("Only Diamond");
        JobReceiptFacet(address(diamond)).burnJobReceipt(0);
    }

    function testGetTokenIdByJobIdBeforeMint() public view {
        (, bool exists) = JobReceiptFacet(address(diamond)).getTokenIdByJobId(99);
        assertFalse(exists);
    }

    function testJobReceiptFacetSupportsInterface() public view {
        // In this harness JobReceiptFacet really is wired up (unlike in the Diamond
        // suite) — so ERC-721/ERC721Metadata are checked here not only against the
        // mapping but against a working facet.
        assertTrue(DiamondLoupeFacet(address(diamond)).supportsInterface(type(IERC165).interfaceId));
        assertTrue(DiamondLoupeFacet(address(diamond)).supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(DiamondLoupeFacet(address(diamond)).supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(DiamondLoupeFacet(address(diamond)).supportsInterface(0x80ac58cd), "ERC721");
        assertTrue(DiamondLoupeFacet(address(diamond)).supportsInterface(0x5b5e139f), "ERC721Metadata");
        // An unknown interface — false
        assertFalse(DiamondLoupeFacet(address(diamond)).supportsInterface(0xdeadbeef));

        // It does not merely claim ERC-721 — it really answers its calls
        assertEq(JobReceiptFacet(address(diamond)).balanceOf(client), 0);
        assertEq(JobReceiptFacet(address(diamond)).name(), "Hexseal Receipt");
        assertEq(JobReceiptFacet(address(diamond)).symbol(), "HSEALR");
    }

    // ============================================================
    //  JOB BOARD EDIT + WITHDRAW TESTS
    // ============================================================

    function testWithdrawApplication() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        assertEq(JobBoardFacet(address(diamond)).getApplicants(jobId).length, 1);

        vm.prank(executor);
        JobBoardFacet(address(diamond)).withdrawApplication(jobId);

        assertEq(JobBoardFacet(address(diamond)).getApplicants(jobId).length, 0);
    }

    function testWithdrawApplicationRevertIfNotApplied() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.NotApplicant.selector);
        JobBoardFacet(address(diamond)).withdrawApplication(jobId);
    }

    function testWithdrawApplicationRevertIfJobClosed() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.JobNotOpen.selector);
        JobBoardFacet(address(diamond)).withdrawApplication(jobId);
    }

    function testEditJob() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(client);
        JobBoardFacet(address(diamond)).editJob(
            jobId,
            "Updated Title",
            "Updated description",
            14,
            TERMS,
            REGION
        );

        JobBoardStorage.Job memory job = JobBoardFacet(address(diamond)).getJob(jobId);
        assertEq(job.title, "Updated Title");
        assertEq(job.deadlineDays, 14);
    }

    function testEditJobRevertIfNotClient() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.NotClient.selector);
        JobBoardFacet(address(diamond)).editJob(jobId, "X", "X", 14, TERMS, REGION);
    }

    function testEditJobRevertIfHasApplicants() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        vm.prank(client);
        vm.expectRevert(JobBoardFacet.JobHasApplicants.selector);
        JobBoardFacet(address(diamond)).editJob(jobId, "X", "X", 14, TERMS, REGION);
    }

    function testTotalJobsAndGetOpenJobs() public {
        assertEq(JobBoardFacet(address(diamond)).totalJobs(), 0);

        _approveAndMintJob();
        assertEq(JobBoardFacet(address(diamond)).totalJobs(), 1);

        (uint256[] memory ids, JobBoardStorage.Job[] memory jobs) =
            JobBoardFacet(address(diamond)).getOpenJobs();
        assertEq(ids.length, 1);
        assertEq(jobs[0].client, client);
    }

    function testGetClientJobs() public {
        _approveAndMintJob();

        uint256[] memory clientJobs = JobBoardFacet(address(diamond)).getClientJobs(client);
        assertEq(clientJobs.length, 1);
        assertEq(clientJobs[0], 0);
    }

    // ============================================================
    //  FEE FORMULA
    // ============================================================

    function testQuoteFee_PercentageAboveFloor() public view {
        // 5% of $200 = $10, the floor does not kick in
        assertEq(FactoryFacet(address(diamond)).quoteFee(200_000_000), 10_000_000);
    }

    function testQuoteFee_FloorBelowCrossover() public view {
        // 5% of $5 = $0.25, the $1 floor kicks in
        assertEq(FactoryFacet(address(diamond)).quoteFee(5_000_000), 1_000_000);
    }

    function testQuoteFee_ExactCrossover() public view {
        // $20 — exactly the junction: 5% = $1 = the floor
        assertEq(FactoryFacet(address(diamond)).quoteFee(20_000_000), 1_000_000);
    }

    function testQuoteFee_LargeDeal() public view {
        // 5% of $1000 = $50
        assertEq(FactoryFacet(address(diamond)).quoteFee(1_000_000_000), 50_000_000);
    }

    function testQuoteFee_ZeroAmountReturnsFloor() public view {
        // amount=0 -> 5% of 0 = 0, the $1 floor kicks in. Unreachable in practice
        // (ZeroAmount higher up the stack gates a zero amount earlier), but the
        // behaviour of the formula is pinned explicitly — so that a future
        // refactor cannot overturn it silently.
        assertEq(FactoryFacet(address(diamond)).quoteFee(0), 1_000_000);
    }

    function testSetFeeBps_OnlyOwner() public {
        vm.prank(client);
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).setFeeBps(300);
    }

    function testSetFeeBps_ChangesQuote() public {
        FactoryFacet(address(diamond)).setFeeBps(300); // 3%
        assertEq(FactoryFacet(address(diamond)).quoteFee(1_000_000_000), 30_000_000);
    }

    function testSetFeeBps_RevertsAboveCap() public {
        vm.expectRevert(FactoryFacet.FeeBpsTooHigh.selector);
        FactoryFacet(address(diamond)).setFeeBps(2_001);
    }

    function testSetFeeBps_AllowsExactCap() public {
        FactoryFacet(address(diamond)).setFeeBps(2_000); // exactly 20% — the ceiling, must not revert
        assertEq(FactoryFacet(address(diamond)).quoteFee(100_000_000), 20_000_000);
    }

    function testSetFeeFloor_OnlyOwner() public {
        vm.prank(client);
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).setFeeFloor(2_000_000);
    }

    function testSetFeeFloor_RevertsOnZero() public {
        vm.expectRevert(FeeNotConfigured.selector);
        FactoryFacet(address(diamond)).setFeeFloor(0);
    }

    function testSetFeeFloor_ChangesQuote() public {
        FactoryFacet(address(diamond)).setFeeFloor(2_000_000); // a $2 floor
        // 5% of $5 = $0.25, below the new $2 floor — the floor wins
        assertEq(FactoryFacet(address(diamond)).quoteFee(5_000_000), 2_000_000);
    }

    function testGetMaxPendingRequests_DefaultIsFive() public view {
        assertEq(FactoryFacet(address(diamond)).getMaxPendingRequests(), 5);
    }

    function testSetMaxPendingRequests_OnlyOwner() public {
        vm.prank(client);
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).setMaxPendingRequests(3);
    }

    function testSetMaxPendingRequests_ZeroAllowed() public {
        // 0 = no limit — the setter must let a zero through rather than revert
        FactoryFacet(address(diamond)).setMaxPendingRequests(0);
        assertEq(FactoryFacet(address(diamond)).getMaxPendingRequests(), 0);
    }

    function testGetRegionFee_NowReverts() public {
        vm.expectRevert(FeeNotRegional.selector);
        FactoryFacet(address(diamond)).getRegionFee(0);
    }

    function testGetAllFees_NowReverts() public {
        vm.expectRevert(FeeNotRegional.selector);
        FactoryFacet(address(diamond)).getAllFees();
    }

    function testSetRegionFee_NowReverts() public {
        // Symmetrically to the getters: a working write next to a reverting read
        // would mean the admin screen "sets" fees that do nothing. It reverts for
        // the owner — that is, for everyone.
        vm.expectRevert(FeeNotRegional.selector);
        FactoryFacet(address(diamond)).setRegionFee(0, 5_000_000);
    }

    function testSetRegionFee_RevertsForNonOwnerToo() public {
        vm.prank(client);
        vm.expectRevert(FeeNotRegional.selector);
        FactoryFacet(address(diamond)).setRegionFee(0, 5_000_000);
    }

    /// The fee on a direct hire is taken by deployAndFund — the only door that
    /// creates a deal and pays for it in one transaction.
    function testDeployAndFund_ChargesPercentage() public {
        uint256 amount = 200_000_000;      // $200
        uint256 expectedFee = 10_000_000;  // 5%

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + expectedFee);
        FactoryFacet(address(diamond)).deployAndFund(
            client, executor, amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(feeRecipient), expectedFee);
    }

    /// And deployAgreement takes NOTHING: only the diamond itself may call it,
    /// that is, a board, and a board has been holding the client's fee since the
    /// posting and hands it over itself a few lines below. Taking it a second time
    /// here would charge the client twice for one deal.
    function testDeployAgreement_TakesNoFeeBecauseTheBoardHoldsIt() public {
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore    = usdc.balanceOf(feeRecipient);

        vm.prank(address(diamond));
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), 200_000_000, DEADLINE, TERMS, REGION
        );

        assertEq(usdc.balanceOf(client), clientBefore, "nothing left the client's wallet");
        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "and nothing reached the treasury");
    }

    // ============================================================
    //  FEE LEDGER READ PATH
    // ============================================================

    function testGetJobFeeHeld_ReportsWhatIsHeld() public {
        uint256 jobId = _approveAndMintJob();
        assertEq(JobBoardFacet(address(diamond)).getJobFeeHeld(jobId), JOB_FEE);
    }

    function testGetJobFeeHeld_ZeroBeforeAndAfterAccept() public {
        assertEq(JobBoardFacet(address(diamond)).getJobFeeHeld(0), 0);

        uint256 jobId = _approveAndMintJob();
        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(client);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);

        assertEq(JobBoardFacet(address(diamond)).getJobFeeHeld(jobId), 0);
    }

    function testGetJobFeeHeld_ClearedOnCancel() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        assertEq(JobBoardFacet(address(diamond)).getJobFeeHeld(jobId), 0);
    }

    // ============================================================
    //  FEE COLLECTED EVENT
    // ============================================================

    function testAcceptApplicant_EmitsFeeCollected() public {
        uint256 jobId = _approveAndMintJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        // _assertLedgerBalanced proves both that the right event fired AND
        // that nothing else moved into feeRecipient unannounced during this
        // call — vm.expectEmit alone only proves the former.
        (, Vm.Log[] memory logs) = _assertLedgerBalanced(
            client,
            abi.encodeWithSelector(JobBoardFacet.acceptApplicant.selector, jobId, executor)
        );
        _assertFeeCollected(logs, jobId, client, FEE_KIND_JOB_DEAL, JOB_FEE);
    }

    /// The floor left with the protocol on a cancellation is economically a
    /// different event from the fee on a deal that happened (the test above):
    /// forfeit, not deal. kind has to tell them apart, otherwise an indexer cannot
    /// separate one from the other by the log.
    function testCancelJob_EmitsFeeCollected() public {
        uint256 jobId = _approveAndMintJob();

        (, Vm.Log[] memory logs) = _assertLedgerBalanced(
            client,
            abi.encodeWithSelector(JobBoardFacet.cancelJob.selector, jobId)
        );
        _assertFeeCollected(logs, jobId, client, FEE_KIND_JOB_FORFEIT, JOB_FLOOR);
    }

    /// A direct hire bypassing both boards. It has one door — deployAndFund():
    /// it moves the amount into the Agreement in the same transaction, so the fee
    /// is taken for a deal that exists. There is no natural id — the Agreement is
    /// not deployed yet at the moment of transfer — so id = 0, and the deal is
    /// identified by the AgreementDeployed of the same transaction.
    function testDeployAndFund_EmitsFeeCollected() public {
        uint256 amount = 200_000_000;      // $200
        uint256 expectedFee = 10_000_000;  // 5%

        vm.prank(client);
        usdc.approve(address(diamond), amount + expectedFee);

        (, Vm.Log[] memory logs) = _assertLedgerBalanced(
            client,
            abi.encodeWithSelector(
                FactoryFacet.deployAndFund.selector,
                client, executor, amount, DEADLINE, TERMS, REGION
            )
        );
        _assertFeeCollected(logs, 0, client, FEE_KIND_DIRECT_DEAL, expectedFee);
    }

    /// AgreementDeployed.fee is recomputed as of the hire, while what is
    /// transferred is what was held at posting. The event signature is frozen for
    /// the sake of the indexer, so the discrepancy is not going away — this test
    /// PINS it executably (and therefore passes), so that the indexer is not read
    /// as the source of truth about the fee actually earned.
    function testAcceptApplicant_AgreementDeployedFeeDivergesFromWhatWasCollected() public {
        uint256 jobId = _approveAndMintJob();   // 5% of $100 = $5 held

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        // The rate changes between the posting and the hire.
        FactoryFacet(address(diamond)).setFeeBps(1_000); // 10%

        vm.recordLogs();
        vm.prank(client);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 announced;  // AgreementDeployed.fee — recomputed as of the hire
        uint256 collected;  // FeeCollected.amount   — actually transferred
        bool sawAnnounced;
        bool sawCollected;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FactoryFacet.AgreementDeployed.selector) {
                (, , announced) = abi.decode(logs[i].data, (uint256, uint8, uint256));
                sawAnnounced = true;
            } else if (logs[i].topics[0] == JobBoardFacet.FeeCollected.selector) {
                collected = abi.decode(logs[i].data, (uint256));
                sawCollected = true;
            }
        }
        assertTrue(sawAnnounced, "AgreementDeployed not emitted");
        assertTrue(sawCollected, "FeeCollected not emitted");

        assertEq(collected, JOB_FEE);         // $5 — held at posting
        assertEq(announced, 10_000_000);      // $10 — 10% as of the hire
        assertTrue(announced != collected, "AgreementDeployed.fee must be read as a quote, not a receipt");

        // Not taken on trust: what reached the treasury is exactly collected, not announced.
        assertEq(usdc.balanceOf(feeRecipient), JOB_FEE);
    }

    // ============================================================
    //  LEGACY JOBS (posted before the fee-holding upgrade)
    // ============================================================

    /// An OPEN order created by the old code is sitting on the live diamond:
    /// jobFunds is filled, jobFeeHeld is zero (the field did not exist then), and
    /// the fee went to the treasury back at posting time. Symmetrical to
    /// testLegacyPendingRequestDoesNotUnderflowOnResolve in the ServiceBoard suite.
    /// Accepting and cancelling such an order must work without a revert.
    function _makeLegacyJob() internal returns (uint256 jobId) {
        jobId = _approveAndMintJob();

        // jobFeeHeld — the field at index 7 in JobBoardStorage.Layout: nextJobId(0),
        // jobs(1), clientJobs(2), applicants(3), hasApplied(4),
        // _deprecated_receiptNFT(5), jobFunds(6), jobFeeHeld(7).
        bytes32 mappingSlot = bytes32(uint256(JobBoardStorage.POSITION) + 7);
        bytes32 feeSlot = keccak256(abi.encode(jobId, mappingSlot));

        // Sanity: mintJob has just written the held fee here.
        assertEq(uint256(vm.load(address(diamond), feeSlot)), JOB_FEE);

        vm.store(address(diamond), feeSlot, bytes32(uint256(0)));

        // The old code forwarded the fee to the treasury right at posting time, so
        // that money is not in the diamond. The tokens are moved too, not just the
        // ledger — otherwise the "legacy" state would be half invented.
        vm.prank(address(diamond));
        usdc.transfer(feeRecipient, JOB_FEE);
    }

    function testLegacyJobWithNoHeldFeeCanBeAccepted() public {
        uint256 jobId = _makeLegacyJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        vm.prank(client);
        address agreementAddr = JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);

        assertTrue(agreementAddr != address(0));
        assertEq(usdc.balanceOf(agreementAddr), AMOUNT);
        // The fee was already paid at posting — it is not taken a second time.
        assertEq(usdc.balanceOf(feeRecipient), JOB_FEE);
        assertEq(usdc.balanceOf(address(diamond)), 0);
    }

    function testLegacyJobWithNoHeldFeeCanBeCancelled() public {
        uint256 jobId = _makeLegacyJob();
        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        // Nothing to burn — zero was held, and subtracting the floor does not underflow.
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT);
        assertEq(usdc.balanceOf(feeRecipient), JOB_FEE);
        assertEq(usdc.balanceOf(address(diamond)), 0);

        JobBoardStorage.Job memory job = JobBoardFacet(address(diamond)).getJob(jobId);
        assertEq(uint256(job.status), uint256(JobBoardStorage.JobStatus.CANCELLED));
    }

    // ============================================================
    //  UPGRADE WINDOW: diamondCut landed, config transaction has not
    // ============================================================

    /// The design requires feeBps/feeFloor to be seeded in the SAME transaction as
    /// the diamondCut. The only mechanism available is `_init`/`_calldata`:
    /// DiamondCutLib.initializeDiamondCut() does `_init.delegatecall(_calldata)`
    /// while already in the diamond's context, so
    ///   _init      = the address of the facet IMPLEMENTATION (not of the diamond),
    ///   storage    = the diamond's (delegatecall),
    ///   msg.sender = the owner who called diamondCut (delegatecall preserves it),
    /// which means onlyOwner inside initFeeModel is a real gate.
    ///
    /// The diamond's own address in `_init` would work too (one extra hop through
    /// its fallback), but the implementation address does not depend on whether
    /// the selector is mounted yet — which is why the upgrade script uses that one.
    function testInitFeeModel_SeedsConfigInTheSameTransactionAsTheCut() public {
        (DiamondProxy fresh, address factoryImpl) = _deployUnconfiguredDiamond();

        // The window before seeding: there is nothing to take a fee from.
        vm.expectRevert(FeeNotConfigured.selector);
        FactoryFacet(address(fresh)).quoteFee(AMOUNT);

        bytes4[] memory added = new bytes4[](1);
        added[0] = FactoryFacet.initFeeModel.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(factoryImpl, IDiamondCut.FacetCutAction.Add, added);

        IDiamondCut(address(fresh)).diamondCut(
            cuts,
            factoryImpl,
            abi.encodeCall(FactoryFacet.initFeeModel, (500, 1_000_000, 5))
        );

        // One transaction — and the configuration is in place.
        assertEq(FactoryFacet(address(fresh)).getFeeBps(), 500);
        assertEq(FactoryFacet(address(fresh)).getFeeFloor(), 1_000_000);
        assertEq(FactoryFacet(address(fresh)).getMaxPendingRequests(), 5);
        assertEq(FactoryFacet(address(fresh)).quoteFee(AMOUNT), JOB_FEE);

        // And a deal gets created — no second transaction was needed.
        vm.startPrank(client);
        usdc.approve(address(fresh), type(uint256).max);
        uint256 jobId = JobBoardFacet(address(fresh)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
        assertEq(JobBoardFacet(address(fresh)).getJobFeeHeld(jobId), JOB_FEE);
    }

    function testInitFeeModel_RevertsOnAnAlreadyConfiguredDiamond() public {
        (DiamondProxy fresh, address factoryImpl) = _deployUnconfiguredDiamond();

        bytes4[] memory added = new bytes4[](1);
        added[0] = FactoryFacet.initFeeModel.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(factoryImpl, IDiamondCut.FacetCutAction.Add, added);

        IDiamondCut(address(fresh)).diamondCut(
            cuts,
            factoryImpl,
            abi.encodeCall(FactoryFacet.initFeeModel, (500, 1_000_000, 5))
        );

        // A second run against the same diamond — already configured.
        vm.expectRevert(FactoryFacet.AlreadyInitialized.selector);
        FactoryFacet(address(fresh)).initFeeModel(300, 2_000_000, 3);
    }

    function testInitFeeModel_RejectsZeroFloorAndTooHighBps() public {
        (DiamondProxy fresh, address factoryImpl) = _deployUnconfiguredDiamond();

        bytes4[] memory added = new bytes4[](1);
        added[0] = FactoryFacet.initFeeModel.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(factoryImpl, IDiamondCut.FacetCutAction.Add, added);
        IDiamondCut(address(fresh)).diamondCut(cuts, address(0), "");

        // The one-shot path is no weaker than the ordinary setters.
        vm.expectRevert(FeeNotConfigured.selector);
        FactoryFacet(address(fresh)).initFeeModel(500, 0, 5);

        vm.expectRevert(FactoryFacet.FeeBpsTooHigh.selector);
        FactoryFacet(address(fresh)).initFeeModel(2_001, 1_000_000, 5);

        // A zero is rejected too: otherwise a single typo atomically returns the
        // protocol to a flat fee, and that can only be fixed with a new cut.
        vm.expectRevert(FactoryFacet.FeeBpsTooHigh.selector);
        FactoryFacet(address(fresh)).initFeeModel(0, 1_000_000, 5);

        vm.prank(client);
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(fresh)).initFeeModel(500, 1_000_000, 5);
    }

    function testInitFeeModel_ZeroBpsCannotSlipThroughAndFlattenTheFee() public {
        (DiamondProxy fresh, address factoryImpl) = _deployUnconfiguredDiamond();

        bytes4[] memory added = new bytes4[](1);
        added[0] = FactoryFacet.initFeeModel.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(factoryImpl, IDiamondCut.FacetCutAction.Add, added);

        // A zero rate does not get through even by the atomic path — the whole cut
        // reverts rather than leaving the diamond with a quiet flat fee.
        vm.expectRevert(FactoryFacet.FeeBpsTooHigh.selector);
        IDiamondCut(address(fresh)).diamondCut(
            cuts,
            factoryImpl,
            abi.encodeCall(FactoryFacet.initFeeModel, (0, 1_000_000, 5))
        );
    }

    // ── Every money entrance of an unconfigured diamond reverts ────────────

    function testUnconfigured_MintJobReverts() public {
        (DiamondProxy fresh, ) = _deployUnconfiguredDiamond();

        vm.startPrank(client);
        usdc.approve(address(fresh), type(uint256).max);
        vm.expectRevert(FeeNotConfigured.selector);
        JobBoardFacet(address(fresh)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    function testUnconfigured_MintJobWithPermitReverts() public {
        (DiamondProxy fresh, ) = _deployUnconfiguredDiamond();

        // quote() comes BEFORE permit(), so the path fails on the fee rather than on
        // the signature — which is what has to be checked.
        vm.expectRevert(FeeNotConfigured.selector);
        JobBoardFacet(address(fresh)).mintJobWithPermit(
            client, "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION,
            block.timestamp + 1 days, 0, bytes32(0), bytes32(0)
        );
    }

    function testUnconfigured_DeployAgreementReverts() public {
        (DiamondProxy fresh, ) = _deployUnconfiguredDiamond();

        // Called by the diamond itself — otherwise the door would reject the caller
        // before the unconfigured fee ever came up, and the test would be checking
        // the wrong thing.
        vm.prank(address(fresh));
        vm.expectRevert(FeeNotConfigured.selector);
        FactoryFacet(address(fresh)).deployAgreement(
            client, executor, address(0), AMOUNT, DEADLINE, TERMS, REGION
        );
    }

    function testUnconfigured_DeployAndFundReverts() public {
        (DiamondProxy fresh, ) = _deployUnconfiguredDiamond();

        vm.startPrank(client);
        usdc.approve(address(fresh), type(uint256).max);
        vm.expectRevert(FeeNotConfigured.selector);
        FactoryFacet(address(fresh)).deployAndFund(
            client, executor, AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    function testUnconfigured_QuoteFeeReverts() public {
        (DiamondProxy fresh, ) = _deployUnconfiguredDiamond();

        vm.expectRevert(FeeNotConfigured.selector);
        FactoryFacet(address(fresh)).quoteFee(AMOUNT);
    }

    /// Money must come out even of an unconfigured protocol: the order was posted
    /// BEFORE the cut, the seeding window is not closed yet, and the client cancels.
    function testUnconfigured_CancelJobStillReturnsEverything() public {
        (DiamondProxy fresh, ) = _deployBoardsDiamond();

        vm.startPrank(client);
        usdc.approve(address(fresh), type(uint256).max);
        uint256 jobId = JobBoardFacet(address(fresh)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        _unconfigureFeeModel(address(fresh));

        vm.prank(client);
        JobBoardFacet(address(fresh)).cancelJob(jobId);

        // There is no floor — nothing to burn, everything comes back: amount and fee alike.
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT + JOB_FEE);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore);
        assertEq(usdc.balanceOf(address(fresh)), 0);
    }

    // ============================================================
    //  RECEIPT SVG RENDER
    // ============================================================

    function testRenderReceipt_StillRenders() public {
        SVGRenderer renderer = new SVGRenderer();

        string memory uri = renderer.renderReceipt(ISVGRenderer.ReceiptParams({
            tokenId:      1,
            client:       client,
            title:        "Build a dApp",
            amount:       200_000_000,
            deadlineDays: DEADLINE,
            region:       REGION,
            createdAt:    block.timestamp
        }));

        assertGt(bytes(uri).length, 100);

        // The data-URI prefix is in place — the render did not degenerate into an empty string
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory uriBytes = bytes(uri);
        for (uint256 i = 0; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i]);
        }
    }
}
