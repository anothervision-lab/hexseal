// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  Money path, part 4 — when a third party will not take the money
// ============================================================
//
// Decision 44 (25 August 2026): on every path where the diamond hands out
// money it holds, the fee push must not be able to cancel the transfer to the
// person. This part checks that claim on ALL paths rather than on the six it
// was written for, and then asks the same question of the transfers that are
// NOT the fee -- because a hard transfer to a party is the same class of
// hostage-taking, whoever the hostage is.
//
// The token refuses in both of the two ways a real one can: `blacklisted`
// reverts (Circle's USDC), `refusesSilently` returns false without reverting.

import "./MoneyPathBase.sol";

contract MoneyPathRefusalTest is MoneyPathBase {
    /// Local copy, because expectEmit needs a declaration it can name. A drift
    /// from Agreement's own declaration changes topic0 and the expectation
    /// stops matching, so the scene goes red rather than quietly passing.
    event DisputeFeeDeferred(uint256 amount);


    // ============================================================
    //  A. The fee recipient refuses — the deferred-fee rule's own ground
    // ============================================================

    function testCancelJobPaysTheClientWhileTheTreasuryRefuses() public {
        vm.prank(client);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, TERMS, 0);
        usdc.setBlacklisted(feeRecipient, true);

        uint256 c0 = usdc.balanceOf(client);
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        assertEq(usdc.balanceOf(client) - c0, AMOUNT + AMOUNT_FEE - FEE_FLOOR, "the person came first");
        assertEq(FactoryFacet(address(diamond)).getUndeliveredFees(), FEE_FLOOR, "the floor became a debt");
        _assertDiamondBalances("cancelJob with a refusing treasury");
    }

    function testAcceptApplicantStillHiresWhileTheTreasuryRefuses() public {
        vm.prank(client);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        usdc.setBlacklisted(feeRecipient, true);

        vm.prank(client);
        Agreement a = Agreement(JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor));

        assertEq(usdc.balanceOf(address(a)), AMOUNT, "the deal happened anyway");
        assertEq(FactoryFacet(address(diamond)).getUndeliveredFees(), AMOUNT_FEE, "the whole fee is a debt");
        _assertDiamondBalances("acceptApplicant with a refusing treasury");
    }

    function testEveryServiceBoardExitSurvivesARefusingTreasury() public {
        vm.prank(executor);
        uint256 svcId = ServiceBoardFacet(address(diamond)).mintService("t", "d", AMOUNT, DEADLINE, 0);

        // reject
        vm.prank(client);
        uint256 r1 = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);
        usdc.setBlacklisted(feeRecipient, true);
        uint256 c0 = usdc.balanceOf(client);
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(r1);
        assertEq(usdc.balanceOf(client) - c0, AMOUNT + AMOUNT_FEE - FEE_FLOOR, "reject paid the client");

        // cancel
        vm.prank(client);
        uint256 r2 = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);
        uint256 c1 = usdc.balanceOf(client);
        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(r2);
        assertEq(usdc.balanceOf(client) - c1, AMOUNT + AMOUNT_FEE - FEE_FLOOR, "cancel paid the client");

        // accept, with a sibling superseded in the same call
        vm.prank(client);
        uint256 r3 = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(client);
        uint256 r4 = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);
        uint256 c2 = usdc.balanceOf(client);
        vm.prank(executor);
        Agreement a = Agreement(ServiceBoardFacet(address(diamond)).acceptRequest(r3));
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "the hire went through");
        assertEq(usdc.balanceOf(client) - c2, AMOUNT + AMOUNT_FEE - FEE_FLOOR, "the sibling refunded");
        assertEq(uint8(ServiceBoardFacet(address(diamond)).getRequest(r4).status), 4, "SUPERSEDED");

        // Four floors + one whole deal fee, all owed.
        assertEq(
            FactoryFacet(address(diamond)).getUndeliveredFees(),
            FEE_FLOOR * 3 + AMOUNT_FEE,
            "every refused push was booked"
        );
        _assertDiamondBalances("service board with a refusing treasury");

        // And once the treasury relents, the whole debt goes home in one push.
        usdc.setBlacklisted(feeRecipient, false);
        uint256 f0 = usdc.balanceOf(feeRecipient);
        vm.prank(stranger); // deliberately open: anyone may push it
        FactoryFacet(address(diamond)).withdrawUndeliveredFees();
        assertEq(usdc.balanceOf(feeRecipient) - f0, FEE_FLOOR * 3 + AMOUNT_FEE, "paid in one lump");
        assertEq(FactoryFacet(address(diamond)).getUndeliveredFees(), 0);
        _assertDiamondBalances("after the debt was paid");
    }

    /// A token that says no by returning false, not by reverting, must book
    /// the same debt. Reading `false` as success would lose the dollar with no
    /// balance anywhere showing it.
    function testASilentRefusalIsBookedTheSameAsALoudOne() public {
        vm.prank(client);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, TERMS, 0);
        usdc.setRefusesSilently(feeRecipient, true);

        uint256 c0 = usdc.balanceOf(client);
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        assertEq(usdc.balanceOf(client) - c0, AMOUNT + AMOUNT_FEE - FEE_FLOOR, "person still paid");
        assertEq(FactoryFacet(address(diamond)).getUndeliveredFees(), FEE_FLOOR, "and the dollar is on the books");
        _assertDiamondBalances("silent refusal");
    }

    // ============================================================
    //  B. The paths that rule deliberately left out
    // ============================================================
    //
    // Direct hire and mintService pay the fee straight from the payer's wallet
    // to the recipient without ever passing through the diamond. That rule
    // ruled these out on the grounds that a refusal there "does not lock
    // anything -- the payer keeps their money". Measured here rather than
    // taken on trust, both halves: it reverts by name, and nothing is stuck.

    function testDeployAndFundRevertsOutrightOnARefusingTreasuryAndLocksNothing() public {
        usdc.setBlacklisted(feeRecipient, true);
        uint256 c0 = usdc.balanceOf(client);

        vm.prank(client);
        vm.expectRevert("Factory: fee transfer failed");
        FactoryFacet(address(diamond)).deployAndFund(client, executor, AMOUNT, DEADLINE, TERMS, 0);

        assertEq(usdc.balanceOf(client), c0, "the client keeps every cent");
        assertEq(FactoryFacet(address(diamond)).getUndeliveredFees(), 0, "nothing owed, nothing stuck");
        _assertDiamondBalances("deployAndFund refused");
    }

    // There was a third case here, `deployAgreement` on a refusing treasury.
    // It moved a fee straight from the client's wallet to the recipient and so
    // belonged in this section; it no longer moves anything, because the only
    // caller it accepts is the diamond and a board settles the fee itself a
    // few lines later. Section A above measures that path.

    function testMintServiceRevertsOutrightOnARefusingTreasury() public {
        usdc.setBlacklisted(feeRecipient, true);
        uint256 e0 = usdc.balanceOf(executor);

        vm.prank(executor);
        vm.expectRevert("ServiceBoard: transferFrom failed");
        ServiceBoardFacet(address(diamond)).mintService("t", "d", AMOUNT, DEADLINE, 0);

        assertEq(usdc.balanceOf(executor), e0, "the executor keeps every cent");
    }

    // ============================================================
    //  C. The transfers that are NOT the fee
    // ============================================================
    //
    // Decision 44 protects the person from the protocol. Since 26 August 2026
    // the same shape protects the person from the OTHER person's token status
    // inside the escrow: the push to the client is soft, what does not land is
    // booked in Agreement.undeliveredRefund, and withdrawUndeliveredRefund()
    // is the way to it. It matters more here than anywhere else, because a
    // clone has no rescue function -- what these scenes measure stays measured
    // forever.
    //
    // Since the same day, EVERY payment to the client is soft, not just the
    // ones where somebody else's money stood behind it. The argument that kept
    // four of them hard -- "the money is the client's own, so a refusal costs
    // nobody else" -- was true about who is hurt and wrong about what happens:
    // each of those four is the LAST door on its path, so a refusal did not
    // defer the refund, it cancelled it forever. Measured before the fix and
    // kept below as the scenes that used to end in TransferFailed.

    /// A hanging proposal used to be refunded with a HARD transfer at the top
    /// of every exit, so a client the token stopped serving took the
    /// executor's payout down with them: $110 in the clone, $100 of it the
    /// executor's, and no way through any of the five doors. The refund is
    /// soft now, and the $10 that cannot be delivered is a debt, not a wall.
    function testAHangingProposalPlusABlockedClientNoLongerLocksTheEscrow() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, 10_000_000);
        vm.prank(executor); a.markDone();

        assertEq(usdc.balanceOf(address(a)), AMOUNT + 10_500_000, "$110.50 in the clone: body, offer, held fee");

        usdc.setBlacklisted(client, true);

        // 1. release goes through, and the executor is paid in full
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(client); a.release();
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "$100 out to the executor");

        // 2. the $10 that could not be returned is booked, not lost
        assertEq(a.pendingExtrasTotal(), 0, "the proposal is settled");
        assertEq(a.undeliveredRefund(), 10_500_000, "and owed to the client, held fee with it");
        assertEq(usdc.balanceOf(address(a)), 10_500_000, "exactly the debt is left in the clone");

        // 3. and it leaves the moment they can receive again
        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        vm.prank(stranger); a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(client) - c0, 10_500_000, "$10.50 home");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// The deadline timeout used to be shut for the blocked client twice over
    /// -- the proposal refund and the body both go to them, and both were hard.
    /// Measured before the fix: TransferFailed, $110 still in the clone, and no
    /// other door (release and triggerAutoApprove want a markDone that never
    /// came, raiseDispute refuses past the deadline). Both are soft now, the
    /// deal closes, and the $110 is one debt rather than two.
    function testTheDeadlineTimeoutClosesForTheBlockedClientIntoOneDebt() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, 10_000_000);
        usdc.setBlacklisted(client, true);
        vm.warp(block.timestamp + DEADLINE * 1 days + DEADLINE_GRACE + 1);

        vm.prank(executor);
        a.triggerDeadlineTimeout();

        assertEq(uint8(a.status()), uint8(Agreement.Status.REFUNDED), "the deal is closed");
        assertEq(a.undeliveredRefund(), AMOUNT + 10_500_000, "$110.50 owed in one sum");
        assertEq(usdc.balanceOf(address(a)), AMOUNT + 10_500_000, "and waiting in the clone");

        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        vm.prank(stranger); a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(client) - c0, AMOUNT + 10_500_000, "$110.50 home");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// The activation timeout is the same shape one step earlier: the executor
    /// never confirmed, and this is the ONLY exit a funded, unactivated deal
    /// has. Before the fix: TransferFailed, $100 in the clone, nothing else to
    /// try -- activate() is past its window and both other timeouts refuse.
    function testTheActivationTimeoutClosesForTheBlockedClient() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        usdc.setBlacklisted(client, true);
        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);

        vm.prank(client);
        a.triggerActivationTimeout();

        assertEq(uint8(a.status()), uint8(Agreement.Status.REFUNDED), "the deal is closed");
        assertEq(a.undeliveredRefund(), AMOUNT, "$100 owed");

        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        vm.prank(stranger); a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(client) - c0, AMOUNT, "$100 home");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// A client who WON the dispute and cannot receive. This was the worst of
    /// the four: a verdict is the last thing that can happen to a disputed
    /// deal, so before the fix the win was final, the payout reverted, and
    /// triggerArbiterTimeout answered VerdictInFlight on the only other door.
    /// $100, won on the merits, locked forever.
    function testAClientWhoWonAndCannotReceiveIsOwedTheMoneyInstead() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);
        usdc.setBlacklisted(client, true);

        _submitAndFinalize(a, true); // client wins

        assertEq(uint8(a.status()), uint8(Agreement.Status.RESOLVED), "the verdict landed");
        assertEq(a.undeliveredRefund(), 97_000_000, "pot less the 3% fee, owed");
        assertEq(usdc.balanceOf(address(a)), 97_000_000, "and held in the clone");

        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        vm.prank(stranger); a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(client) - c0, 97_000_000, "the winner was paid, late");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// The same door, reached through the dispute. The executor won on the
    /// merits and still could not be paid, because the refund of the client's
    /// hanging proposal ran first in the same function. It no longer stops
    /// them: $97 out (pot $100 less the 3% fee), $10 booked.
    function testAWonDisputeIsNoLongerBlockedByAHangingProposal() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, 10_000_000);
        vm.prank(executor); a.raiseDispute();
        _claimByArbiter(a);

        usdc.setBlacklisted(client, true);

        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), false); // executor wins
        vm.warp(block.timestamp + FINALIZE_DELAY + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));

        assertEq(usdc.balanceOf(executor) - e0, 97_000_000, "the winner was paid");
        assertEq(a.undeliveredRefund(), 10_500_000, "the client's proposal is a debt, held fee included");
        assertEq(usdc.balanceOf(address(a)), 10_500_000, "and nothing else stayed behind");
    }

    /// With no proposal hanging, a blocked client used to freeze the
    /// executor's half of an unjudged split -- on the LAST door the deal has.
    /// The two halves are symmetric now: whichever side cannot receive, the
    /// other is still paid.
    function testABlockedClientNoLongerFreezesTheExecutorsHalfOfASplit() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(executor); a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        usdc.setBlacklisted(client, true);

        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(executor);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - e0, 50_000_000, "the executor's half went out");
        assertEq(a.undeliveredRefund(), 50_000_000, "the client's half is owed to them");
        assertEq(usdc.balanceOf(address(a)), 50_000_000, "and waits in the clone for them");
    }

    /// The mirror case, and the two are finally the same shape: a blocked
    /// EXECUTOR does not freeze the split either, and their half is BOOKED to
    /// them rather than handed to the client. Until 26 August it was handed
    /// over -- measured: the client walked away with the whole $100 of a pot
    /// nobody judged, because the token would not serve the other side.
    function testABlockedExecutorGetsTheirHalfBookedNotConfiscated() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(executor); a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        usdc.setBlacklisted(executor, true);

        uint256 c0 = usdc.balanceOf(client);
        vm.prank(executor); a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - c0, AMOUNT / 2, "the client got their half, no more");
        assertEq(a.undeliveredPayout(), AMOUNT / 2, "the executor's half is owed to them");
        assertEq(usdc.balanceOf(address(a)), AMOUNT / 2, "and waits in the clone");

        usdc.setBlacklisted(executor, false);
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(stranger); a.withdrawUndeliveredPayout();
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT / 2, "and reaches them later");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// rejectExtra paid the client with a HARD transfer while withdrawExtra --
    /// the same act on the same money, by the client instead of the executor --
    /// was soft. Before the fix the executor simply could not decline a top-up
    /// offered by a blacklisted client: TransferFailed, and the offer stood
    /// over them until the deal ended. Same money, same recipient, two
    /// functions, two answers.
    function testTheExecutorCanRejectAProposalFromABlockedClient() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 10_000_000);

        usdc.setBlacklisted(client, true);
        vm.prank(executor);
        a.rejectExtra(id);

        assertEq(uint8(a.getExtra(id).status), uint8(Agreement.ExtraStatus.REJECTED), "declined");
        assertEq(a.pendingExtrasTotal(), 0, "and off the pending books");
        assertEq(a.undeliveredRefund(), 10_500_000, "the $10.50 is a debt to the client");

        // and the deal carries on normally around it
        vm.prank(executor); a.markDone();
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(client); a.release();
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "the body still went to the executor");
        assertEq(usdc.balanceOf(address(a)), 10_500_000, "exactly the debt is left");
    }

    /// On the service board the superseded sibling's refund runs inside the
    /// hire. A blocked client with two pending requests to the same executor
    /// therefore cannot be hired at all -- the executor's accept reverts on
    /// somebody else's refund.
    function testABlockedClientWithTwoRequestsCannotBeHiredAtAll() public {
        vm.prank(executor);
        uint256 svcId = ServiceBoardFacet(address(diamond)).mintService("t", "d", AMOUNT, DEADLINE, 0);
        vm.prank(client);
        uint256 r1 = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(client);
        ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);

        usdc.setBlacklisted(client, true);

        vm.prank(executor);
        vm.expectRevert("ServiceBoard: transfer failed");
        ServiceBoardFacet(address(diamond)).acceptRequest(r1);

        // Two full requests' worth is stuck on the diamond, and the books still
        // account for every cent of it.
        assertEq(usdc.balanceOf(address(diamond)), (AMOUNT + AMOUNT_FEE) * 2);
        _assertDiamondBalances("blocked client, two requests");
    }

    /// With exactly one request the same client CAN be hired: nothing needs to
    /// be pushed back to them inside the call. The difference is the sibling
    /// refund, not the blacklist.
    function testTheSameBlockedClientWithOneRequestIsHiredFine() public {
        vm.prank(executor);
        uint256 svcId = ServiceBoardFacet(address(diamond)).mintService("t", "d", AMOUNT, DEADLINE, 0);
        vm.prank(client);
        uint256 r1 = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);

        usdc.setBlacklisted(client, true);

        vm.prank(executor);
        Agreement a = Agreement(ServiceBoardFacet(address(diamond)).acceptRequest(r1));
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "hired");
        _assertDiamondBalances("blocked client, one request");
    }

    /// A blocked client also cannot cancel their own posting: the refund is a
    /// hard transfer to them. Named because it is the benign end of the same
    /// class -- there is nobody else's money in that clone to hold hostage.
    function testABlockedClientCannotCancelTheirOwnPosting() public {
        vm.prank(client);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, TERMS, 0);
        usdc.setBlacklisted(client, true);

        vm.prank(client);
        vm.expectRevert("JobBoard: transfer failed");
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        _assertDiamondBalances("blocked client cannot cancel");
    }

    // ============================================================
    //  D. The third payee: the dispute fee, and the diamond itself
    // ============================================================
    //
    // Decision 44 rules that the protocol's own fee may not cancel a payment to
    // a person, and the boards were fixed for it on 25 August. Inside the escrow
    // the rule ran backwards: the fee transfer to the diamond stood BEFORE the
    // winner's payout and was hard, so a diamond the token refuses locked the
    // whole pot. Soft since 26 August, and what cannot be delivered is booked on
    // the clone -- the diamond's ledger has already been credited, so the money
    // is owed rather than lost.

    /// $3 of fee used to freeze $100 of somebody's won dispute. The revert is
    /// invisible to the try/catch around the credit, by language rule: a revert
    /// raised in the SUCCESS block of a try/catch escapes its own catch.
    function testAWonDisputeSurvivesADiamondTheTokenRefuses() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);

        usdc.setBlacklisted(address(diamond), true);

        uint256 c0 = usdc.balanceOf(client);
        // Armed around finalizeVerdict alone, not around _submitAndFinalize:
        // submitVerdict emits first, and an expectation armed before it would
        // match on that log instead.
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);
        vm.warp(block.timestamp + FINALIZE_DELAY + 1);
        vm.expectEmit(false, false, false, true, address(a));
        emit DisputeFeeDeferred(3_000_000);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a)); // client wins

        assertEq(uint8(a.status()), uint8(Agreement.Status.RESOLVED), "the dispute closed");
        assertEq(usdc.balanceOf(client) - c0, 97_000_000, "the winner was paid in full and on time");
        assertEq(a.undeliveredFee(), 3_000_000, "and the $3 is owed to the diamond");
        assertEq(usdc.balanceOf(address(a)), 3_000_000, "held on the clone until it can be sent");

        // The diamond's books already count the fee -- creditDisputeFee ran --
        // so its ledger stands exactly $3 above its balance until the pull.
        assertEq(
            _diamondLedger() - usdc.balanceOf(address(diamond)),
            3_000_000,
            "the gap is the deferred fee, to the cent"
        );

        usdc.setBlacklisted(address(diamond), false);
        uint256 d0 = usdc.balanceOf(address(diamond));
        vm.prank(stranger); a.withdrawUndeliveredFee();
        assertEq(usdc.balanceOf(address(diamond)) - d0, 3_000_000, "the fee arrived, late");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
        _assertDiamondBalances("after the deferred fee was pulled");

        // And the arbiter can be paid out of it, which is what the credit
        // promised in the first place.
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).withdrawArbiterReward();
        _assertDiamondBalances("after the arbiter took their share");
    }

    /// The same with the silent form of refusal, and with the EXECUTOR winning
    /// -- the fee line sits in front of both winners equally.
    function testASilentlyRefusingDiamondDoesNotStopTheExecutorsWin() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor); a.raiseDispute();
        _claimByArbiter(a);

        usdc.setRefusesSilently(address(diamond), true);

        uint256 e0 = usdc.balanceOf(executor);
        _submitAndFinalize(a, false); // executor wins

        assertEq(usdc.balanceOf(executor) - e0, 97_000_000, "the winner was paid");
        assertEq(a.undeliveredFee(), 3_000_000, "the silent refusal is booked like the loud one");
    }

    /// The control the scenes above need: with a healthy diamond nothing is
    /// deferred, the fee goes out on the spot and the clone still empties.
    /// Without it, "the fee is a debt" could be true of every dispute and none
    /// of the scenes would notice.
    function testAHealthyDiamondStillTakesTheFeeOnTheSpot() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);

        uint256 d0 = usdc.balanceOf(address(diamond));
        _submitAndFinalize(a, true);

        assertEq(usdc.balanceOf(address(diamond)) - d0, 3_000_000, "the fee arrived at once");
        assertEq(a.undeliveredFee(), 0, "nothing deferred on the healthy path");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
        _assertDiamondBalances("healthy diamond, fee taken");
    }

    /// The fee door pays the diamond, nobody else, and only once.
    function testTheFeeDoorPaysOnlyTheDiamondAndOnlyOnce() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);
        usdc.setBlacklisted(address(diamond), true);
        _submitAndFinalize(a, true);
        usdc.setBlacklisted(address(diamond), false);

        uint256 s0 = usdc.balanceOf(stranger);
        uint256 c0 = usdc.balanceOf(client);
        uint256 d0 = usdc.balanceOf(address(diamond));

        vm.prank(stranger); a.withdrawUndeliveredFee();

        assertEq(usdc.balanceOf(address(diamond)) - d0, 3_000_000, "to the diamond");
        assertEq(usdc.balanceOf(stranger), s0, "not to the caller");
        assertEq(usdc.balanceOf(client), c0, "not to the winner");

        vm.prank(stranger);
        vm.expectRevert(Agreement.ZeroAmount.selector);
        a.withdrawUndeliveredFee();
    }

    /// All three payees unservable on the same verdict. The clone keeps exactly
    /// the pot, split across three ledgers that add up to it, and each is pulled
    /// through its own door. This is the shape the whole day's work was for: no
    /// path where one address's token status decides another's money, and
    /// nothing left in a clone that nobody can reach.
    function testAllThreeDebtsAtOnceAddUpToThePot() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, 10_000_000);   // a hanging proposal, refundable
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);

        usdc.setBlacklisted(client, true);
        usdc.setBlacklisted(executor, true);
        usdc.setBlacklisted(address(diamond), true);

        _submitAndFinalize(a, false); // executor wins the $100 pot

        assertEq(a.undeliveredRefund(), 10_500_000, "the client's hanging proposal and its held fee");
        assertEq(a.undeliveredPayout(), 97_000_000, "the executor's winnings");
        assertEq(a.undeliveredFee(),     3_000_000, "the arbiter's fee");
        assertEq(
            a.undeliveredRefund() + a.undeliveredPayout() + a.undeliveredFee(),
            usdc.balanceOf(address(a)),
            "three ledgers, and they add up to what is actually held"
        );

        usdc.setBlacklisted(client, false);
        usdc.setBlacklisted(executor, false);
        usdc.setBlacklisted(address(diamond), false);
        vm.startPrank(stranger);
        a.withdrawUndeliveredRefund();
        a.withdrawUndeliveredPayout();
        a.withdrawUndeliveredFee();
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
        _assertDiamondBalances("after all three debts were pulled");
    }

    /// Asking for a fee that is not owed is refused by name, like the other two
    /// doors.
    function testWithdrawingNoFeeIsRefusedByName() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        vm.prank(stranger);
        vm.expectRevert(Agreement.ZeroAmount.selector);
        a.withdrawUndeliveredFee();
    }
}
