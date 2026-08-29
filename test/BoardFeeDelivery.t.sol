// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BoardsFixture.sol";

// The stand for "a person's money does not wait on a third party".
//
// WHAT WAS WRONG. Six board paths moved custodied USDC out of the diamond and
// pushed the protocol's fee to `feeRecipient` in the same transaction, under a
// hard `require`. Four of them are the paths a person uses to GET THEIR MONEY
// BACK — `cancelJob`, `rejectRequest`, `cancelRequest` and the supersede loop
// inside `acceptRequest` — and two are the paths that start a deal with money
// already locked in the diamond. USDC keeps a blacklist and its `transfer`
// reverts on a blacklisted receiver, so a fee push is a call that can fail
// forever through no fault of the person making it. On live job #3 that was
// 36.19 USDC of somebody's budget standing behind a 1.00 USDC transfer to an
// address that person had never chosen and could not change.
//
// `Treasury` made its OUTGOING payments pull-based for exactly this reason and
// says so in its own header. The inflow never got the same protection.
//
// ⚠️ WITHOUT A RECIPIENT THAT REFUSES, NONE OF THIS IS TESTED. Every assertion
// below that matters runs against `MockUSDCB.setBlacklisted` /
// `setRefusesSilently` — the two ways a token says no. A suite that only ever
// paid a willing recipient would measure the happy path twice and call it
// coverage.
//
// WHAT MUST NOT HAPPEN INSTEAD. Swallowing the refusal. The fee is protocol
// revenue; "it did not go through, never mind" is a leak no balance would show.
// So the amount becomes a debt in `FactoryStorage.undeliveredFee`, and every
// test here closes with the same balance identity: the diamond's USDC equals
// the sum of what it books, to the microdollar — the same check the boards
// audit ran by hand against Base Sepolia, with `undeliveredFee` as a term of
// the sum. Expected side is storage, actual side is the token. Neither is
// computed from the other.
contract BoardFeeDeliveryTest is BoardsFixture {

    // ══════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════

    function _postJob() internal returns (uint256 jobId) {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    function _postService() internal returns (uint256 serviceId) {
        vm.startPrank(executor);
        usdc.approve(address(diamond), FEE);
        serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();
    }

    function _request(uint256 serviceId) internal returns (uint256 requestId) {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    /// The recipient says no by reverting — what real USDC does to a
    /// blacklisted address.
    function _feeRecipientRefuses() internal {
        usdc.setBlacklisted(feeRecipient, true);
    }

    /// The recipient says no by answering `false` — what a token with the older
    /// non-reverting habit does. A settlement that only handled the reverting
    /// flavour would read this as success and lose the dollar off the books.
    function _feeRecipientRefusesSilently() internal {
        usdc.setRefusesSilently(feeRecipient, true);
    }

    function _owed() internal view returns (uint256) {
        return FactoryFacet(address(diamond)).getUndeliveredFees();
    }

    function _countLogs(Vm.Log[] memory logs, bytes32 topic0) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(diamond)
                && logs[i].topics.length > 0
                && logs[i].topics[0] == topic0) n++;
        }
    }

    function _findLog(Vm.Log[] memory logs, bytes32 topic0, uint256 id)
        internal view returns (bool found, address payer, uint8 kind, uint256 amount)
    {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(diamond)
                && logs[i].topics.length == 4
                && logs[i].topics[0] == topic0
                && uint256(logs[i].topics[1]) == id) {
                found  = true;
                payer  = address(uint160(uint256(logs[i].topics[2])));
                kind   = uint8(uint256(logs[i].topics[3]));
                amount = abi.decode(logs[i].data, (uint256));
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    // 1. THE RECIPIENT REFUSES — THE PERSON IS PAID ANYWAY
    // ══════════════════════════════════════════════════════════════════════

    function testCancelJobPaysTheClientInFullWhileTheFeeRecipientRefuses() public {
        uint256 jobId = _postJob();
        _assertJobFundsSlotIsWhereWeThink(jobId, AMOUNT);

        _feeRecipientRefuses();

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        // Every cent the cancellation owes the client, unchanged by the refusal.
        assertEq(
            usdc.balanceOf(client),
            clientBefore + AMOUNT + (JOB_FEE - JOB_FLOOR),
            "the client must be paid in full even though the fee recipient refused"
        );
        assertEq(usdc.balanceOf(feeRecipient), 0, "a refusing recipient must not have been paid");
        assertEq(_owed(), JOB_FLOOR, "the floor must be booked as owed, not lost");
        _assertDiamondHoldsExactlyItsLedger("cancelJob with a refusing recipient");
    }

    function testCancelJobPaysTheClientInFullWhenTheRecipientRefusesSilently() public {
        uint256 jobId = _postJob();
        _feeRecipientRefusesSilently();

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT + (JOB_FEE - JOB_FLOOR));
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(
            _owed(), JOB_FLOOR,
            "a token that answers false is still a refusal - the dollar must be on the books"
        );
        _assertDiamondHoldsExactlyItsLedger("cancelJob with a silently refusing recipient");
    }

    function testAcceptApplicantStillHiresWhileTheFeeRecipientRefuses() public {
        uint256 jobId = _postJob();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        _feeRecipientRefuses();

        vm.prank(client);
        address agreementAddr = JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);

        assertTrue(agreementAddr != address(0), "the hire must go through");
        assertEq(usdc.balanceOf(agreementAddr), AMOUNT, "the budget must reach the escrow");
        assertEq(_owed(), JOB_FEE, "the whole earned fee is owed, not lost");
        _assertDiamondHoldsExactlyItsLedger("acceptApplicant with a refusing recipient");
    }

    function testRejectRequestRefundsTheClientWhileTheFeeRecipientRefuses() public {
        uint256 serviceId = _postService();
        uint256 requestId = _request(serviceId);

        _feeRecipientRefuses();

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId);

        assertEq(
            usdc.balanceOf(client),
            clientBefore + AMOUNT + (JOB_FEE - JOB_FLOOR),
            "a rejected client must be refunded even though the fee recipient refused"
        );
        assertEq(_owed(), JOB_FLOOR);
        _assertDiamondHoldsExactlyItsLedger("rejectRequest with a refusing recipient");
    }

    function testCancelRequestRefundsTheClientWhileTheFeeRecipientRefuses() public {
        uint256 serviceId = _postService();
        uint256 requestId = _request(serviceId);

        _feeRecipientRefuses();

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId);

        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT + (JOB_FEE - JOB_FLOOR));
        assertEq(_owed(), JOB_FLOOR);
        _assertDiamondHoldsExactlyItsLedger("cancelRequest with a refusing recipient");
    }

    function testAcceptRequestHiresAndSupersedesTheSiblingWhileTheRecipientRefuses() public {
        uint256 serviceId = _postService();
        uint256 first  = _request(serviceId);
        uint256 second = _request(serviceId);

        _feeRecipientRefuses();

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(executor);
        address agreementAddr = ServiceBoardFacet(address(diamond)).acceptRequest(first);

        assertTrue(agreementAddr != address(0), "the hire must go through");
        assertEq(usdc.balanceOf(agreementAddr), AMOUNT, "the budget must reach the escrow");

        // The sibling was refunded in the same transaction, minus the floor.
        assertEq(
            usdc.balanceOf(client),
            clientBefore + AMOUNT + (JOB_FEE - JOB_FLOOR),
            "the superseded sibling must be refunded even though the fee recipient refused"
        );
        assertEq(
            uint256(ServiceBoardFacet(address(diamond)).getRequest(second).status),
            uint256(ServiceBoardStorage.RequestStatus.SUPERSEDED)
        );

        // Two refusals in one call: the accepted request's whole fee and the
        // sibling's floor.
        assertEq(_owed(), JOB_FEE + JOB_FLOOR, "both refused fees are owed, and they add up");
        _assertDiamondHoldsExactlyItsLedger("acceptRequest + supersede with a refusing recipient");
    }

    // ══════════════════════════════════════════════════════════════════════
    // 2. THE RECIPIENT ACCEPTS — NOTHING CHANGED
    // ══════════════════════════════════════════════════════════════════════

    function testWillingRecipientIsStillPaidInTheSameTransaction() public {
        uint256 jobId = _postJob();

        vm.recordLogs();
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(usdc.balanceOf(feeRecipient), JOB_FLOOR, "the fee must still arrive immediately");
        assertEq(_owed(), 0, "nothing may be owed when the recipient took the money");

        (bool collected,, uint8 kind, uint256 amount) =
            _findLog(logs, JobBoardFacet.FeeCollected.selector, jobId);
        assertTrue(collected, "FeeCollected must still be emitted on the happy path");
        assertEq(kind, FEE_KIND_JOB_FORFEIT);
        assertEq(amount, JOB_FLOOR);

        assertEq(
            _countLogs(logs, JobBoardFacet.FeeDeferred.selector), 0,
            "nothing was deferred, so nothing may claim it was"
        );
        _assertDiamondHoldsExactlyItsLedger("cancelJob with a willing recipient");
    }

    function testWillingRecipientIsPaidOnEveryServicePathToo() public {
        uint256 serviceId = _postService();
        uint256 requestId = _request(serviceId);

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId);

        // The listing floor plus the rejected request's floor.
        assertEq(usdc.balanceOf(feeRecipient), JOB_FLOOR * 2);
        assertEq(_owed(), 0);
        _assertDiamondHoldsExactlyItsLedger("rejectRequest with a willing recipient");
    }

    // ══════════════════════════════════════════════════════════════════════
    // 3. WHAT DID NOT ARRIVE IS NOT LOST — IT IS SEEN, AND IT CAN BE TAKEN
    // ══════════════════════════════════════════════════════════════════════

    function testDeferredFeeIsAnnouncedByNameAndNotCountedAsRevenue() public {
        uint256 jobId = _postJob();
        _feeRecipientRefuses();

        vm.recordLogs();
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool deferred, address payer, uint8 kind, uint256 amount) =
            _findLog(logs, JobBoardFacet.FeeDeferred.selector, jobId);
        assertTrue(deferred, "a refused fee must announce itself");
        assertEq(payer, client, "and say whose dollar it was");
        assertEq(kind, FEE_KIND_JOB_FORFEIT, "and which kind of fee");
        assertEq(amount, JOB_FLOOR);

        // The half that protects the revenue figure: FeeCollected is what the
        // subgraph turns into protocol income, and this dollar never reached
        // the treasury.
        assertEq(
            _countLogs(logs, JobBoardFacet.FeeCollected.selector), 0,
            "money that did not move must not be reported as collected"
        );
    }

    function testWhatCouldNotBeDeliveredCanBeTakenOnceTheRecipientRelents() public {
        uint256 jobId = _postJob();
        _feeRecipientRefuses();

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        assertEq(_owed(), JOB_FLOOR);

        usdc.setBlacklisted(feeRecipient, false);

        vm.recordLogs();
        FactoryFacet(address(diamond)).withdrawUndeliveredFees();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(usdc.balanceOf(feeRecipient), JOB_FLOOR, "the debt must reach the recipient in full");
        assertEq(_owed(), 0, "and stop being owed");
        assertEq(
            _countLogs(logs, FactoryFacet.UndeliveredFeesPushed.selector), 1,
            "the payout must announce itself"
        );
        assertEq(
            _countLogs(logs, JobBoardFacet.FeeCollected.selector), 0,
            "and must NOT re-announce as revenue what was already counted as earned"
        );
        _assertDiamondHoldsExactlyItsLedger("after the debt was pushed");
    }

    function testDebtAddsUpAcrossEveryRefusedPath() public {
        uint256 serviceId = _postService();      // paid while the recipient still accepts
        uint256 jobId     = _postJob();
        uint256 requestA  = _request(serviceId);
        uint256 requestB  = _request(serviceId);

        _feeRecipientRefuses();

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);                 // + floor
        _assertDiamondHoldsExactlyItsLedger("after cancelJob");

        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestA);      // + floor
        _assertDiamondHoldsExactlyItsLedger("after cancelRequest");

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestB);      // + floor
        _assertDiamondHoldsExactlyItsLedger("after rejectRequest");

        assertEq(_owed(), JOB_FLOOR * 3, "three refusals, three floors, nothing rounded away");

        usdc.setBlacklisted(feeRecipient, false);
        uint256 recipientBefore = usdc.balanceOf(feeRecipient);
        FactoryFacet(address(diamond)).withdrawUndeliveredFees();

        assertEq(usdc.balanceOf(feeRecipient) - recipientBefore, JOB_FLOOR * 3);
        assertEq(usdc.balanceOf(address(diamond)), 0, "and the diamond keeps nothing of its own");
        _assertDiamondHoldsExactlyItsLedger("after the whole debt was pushed");
    }

    function testWithdrawFailsLoudlyWhileTheRecipientStillRefuses() public {
        uint256 jobId = _postJob();
        _feeRecipientRefuses();

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        // A pull that answers "done" while the money is still stuck would be
        // the one reply this function must never give.
        vm.expectRevert(bytes("Factory: transfer failed"));
        FactoryFacet(address(diamond)).withdrawUndeliveredFees();

        assertEq(_owed(), JOB_FLOOR, "a failed pull must leave the debt intact, not zeroed");
        _assertDiamondHoldsExactlyItsLedger("after a failed pull");
    }

    function testWithdrawWithNothingOwedRefusesByName() public {
        vm.expectRevert(FactoryFacet.NothingUndelivered.selector);
        FactoryFacet(address(diamond)).withdrawUndeliveredFees();
    }

    function testTheDebtFollowsAReplacementFeeRecipient() public {
        uint256 jobId = _postJob();
        _feeRecipientRefuses();

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        assertEq(_owed(), JOB_FLOOR);

        // This is the real recovery path: a treasury blacklisted for good is
        // replaced, and what piled up behind it follows the replacement. No new
        // power — `setFeeRecipient` already redirects every dollar of income.
        address replacement = address(0xBEEF);
        FactoryFacet(address(diamond)).setFeeRecipient(replacement);

        FactoryFacet(address(diamond)).withdrawUndeliveredFees();

        assertEq(usdc.balanceOf(replacement), JOB_FLOOR);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(_owed(), 0);
        _assertDiamondHoldsExactlyItsLedger("after the debt followed a new recipient");
    }

    // ══════════════════════════════════════════════════════════════════════
    // 4. THE IDENTITY ITSELF, ON EVERY PATH, IN ONE RUN
    // ══════════════════════════════════════════════════════════════════════

    /// The audit's convergence check, run over all six fee paths at once and
    /// with the recipient refusing throughout — the state in which the boards'
    /// bookkeeping is most likely to drift, because that is the only state in
    /// which the diamond keeps money that belongs to nobody on the board.
    function testTheDiamondAddsUpAcrossAllSixFeePathsWithARefusingRecipient() public {
        uint256 serviceId = _postService();
        _feeRecipientRefuses();

        uint256 jobA = _postJob();
        uint256 jobB = _postJob();
        _assertDiamondHoldsExactlyItsLedger("two jobs posted");

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobA);

        vm.prank(client);
        JobBoardFacet(address(diamond)).acceptApplicant(jobA, executor);   // JOB_DEAL
        _assertDiamondHoldsExactlyItsLedger("job hired");

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobB);                   // JOB_FORFEIT
        _assertDiamondHoldsExactlyItsLedger("job cancelled");

        // A second client, because this one now has an active pair with the
        // executor and cannot be hired twice.
        address client2 = address(0xC2);
        usdc.mint(client2, 1_000_000_000);
        vm.startPrank(client2);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 r1 = ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
        uint256 r2 = ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
        uint256 r3 = ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
        _assertDiamondHoldsExactlyItsLedger("three requests pending");

        vm.prank(client2);
        ServiceBoardFacet(address(diamond)).cancelRequest(r3);             // REQUEST_FORFEIT
        _assertDiamondHoldsExactlyItsLedger("request cancelled");

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(r1);             // REQUEST_DEAL + supersede of r2
        _assertDiamondHoldsExactlyItsLedger("request accepted, sibling superseded");

        assertEq(
            uint256(ServiceBoardFacet(address(diamond)).getRequest(r2).status),
            uint256(ServiceBoardStorage.RequestStatus.SUPERSEDED)
        );

        // Five refusals: job deal fee, job forfeit floor, request forfeit floor,
        // request deal fee, sibling forfeit floor.
        assertEq(_owed(), JOB_FEE * 2 + JOB_FLOOR * 3);

        usdc.setBlacklisted(feeRecipient, false);
        FactoryFacet(address(diamond)).withdrawUndeliveredFees();
        _assertDiamondHoldsExactlyItsLedger("everything settled");

        // And the last word: with every board object closed out, the diamond
        // holds nothing at all.
        assertEq(usdc.balanceOf(address(diamond)), 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    // 5. THE THINGS THIS WORK DELIBERATELY DID NOT CHANGE
    // ══════════════════════════════════════════════════════════════════════

    /// `mintService` pays the anti-spam floor straight from the executor's
    /// wallet to `feeRecipient` — the diamond never holds it. A refusal there
    /// drops the whole posting, and that is the right answer: the executor
    /// keeps his money, there is nothing locked, and nothing to release. Pinned
    /// as a decision so that a later reader does not "fix" it into a debt the
    /// protocol books for a service that was never published.
    function testPostingAServiceStillFailsOutrightIfTheFeeCannotBePaid() public {
        _feeRecipientRefuses();

        uint256 executorBefore = usdc.balanceOf(executor);

        vm.startPrank(executor);
        usdc.approve(address(diamond), FEE);
        vm.expectRevert(bytes("ServiceBoard: transferFrom failed"));
        ServiceBoardFacet(address(diamond)).mintService(
            "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(executor), executorBefore, "the executor keeps his money");
        assertEq(_owed(), 0, "and the protocol books no debt for a listing that does not exist");
        assertEq(ServiceBoardFacet(address(diamond)).totalServices(), 0);
    }
}
