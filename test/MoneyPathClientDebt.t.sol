// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  Money path, part 7 — the refund that could not be delivered
// ============================================================
//
// The money-path audit of 26 August 2026 (findings 1, 2 and 6) named three holes in Agreement, all of them permanent: a clone is
// pinned to its implementation by EIP-1167 and has no rescue function, so
// whatever is locked in a live deal stays locked for the life of that deal.
//
//   * A HARD refund to the client stood on the first line of five exits. One
//     client the token stopped serving therefore froze the whole escrow --
//     $110 in the clone, and $100 of it the EXECUTOR's.
//   * The same hard transfer on the unjudged split froze the executor's half,
//     while the mirror case (a blocked executor) had been soft all along.
//   * acceptExtra looked at neither the dispute nor the clock, so the executor
//     could turn the client's refundable money into their own payout after the
//     client had lost every way to stop them.
//
// This file measures the state after the fix. Every number is a token balance
// or a stored counter read back, never a figure recomputed from the contract
// under measurement, and every expected refusal names its selector.
//
// The scenes that measured the holes are NOT deleted. They live where they were
// found -- MoneyPathRefusal.t.sol, MoneyPathDispute.t.sol, MoneyPathExtras.t.sol
// -- and now assert the new truth under renamed titles, so the diff shows what
// changed rather than hiding it.

import "./MoneyPathBase.sol";

contract MoneyPathClientDebtTest is MoneyPathBase {
    // Local copies, because expectEmit needs a declaration it can name. A
    // drift from Agreement's own declarations is NOT a compile error -- it
    // changes topic0 and the expectation stops matching, so the scenes below
    // go red rather than quietly passing on the wrong event.
    event RefundDeferred(address indexed client, uint256 amount);
    event RefundWithdrawn(address indexed client, uint256 amount);
    event ExtraWithdrawn(uint256 indexed extraId, address indexed client, uint256 amount);
    event DisputeSplitNoVerdict(uint256 toClient, uint256 toExecutor);
    event ArbiterTimedOut(address indexed client, uint256 amount);
    event PayoutDeferred(address indexed executor, uint256 amount);
    event PayoutWithdrawn(address indexed executor, uint256 amount);

    uint256 constant EXTRA = 10_000_000;  // $10
    /// The protocol fee the clone HOLDS on that proposal until somebody
    /// accepts it -- the same 5% the deal pays, with no floor. Nobody accepts
    /// it in any scene below, so it goes home with the proposal and every
    /// debt here is the two together.
    uint256 constant EXTRA_FEE  =    500_000;  // 5% of $10
    uint256 constant EXTRA_BACK = EXTRA + EXTRA_FEE;  // $10.50

    // ============================================================
    //  A. The escrow no longer hangs on the client's token status
    // ============================================================

    /// release: $100 reaches the executor, the $10 proposal that could not be
    /// returned is booked as a debt, and the client pulls it once the token
    /// serves them again. Before the fix this call reverted TransferFailed and
    /// $110 stayed in the clone forever.
    function testReleasePaysTheExecutorAndBooksTheUndeliverableRefund() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, EXTRA);
        vm.prank(executor); a.markDone();

        usdc.setBlacklisted(client, true);

        uint256 e0 = usdc.balanceOf(executor);
        vm.expectEmit(true, false, false, true, address(a));
        emit RefundDeferred(client, EXTRA_BACK);
        vm.prank(client); a.release();

        assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "the executor got the whole body");
        assertEq(a.undeliveredRefund(), EXTRA_BACK, "$10.50 is owed to the client");
        assertEq(a.pendingExtrasTotal(), 0, "and it is no longer a live proposal");
        assertEq(usdc.balanceOf(address(a)), EXTRA_BACK, "exactly the debt is left in the clone");
        assertEq(uint8(a.status()), uint8(Agreement.Status.COMPLETED), "the deal really closed");

        // The blacklist comes off. This is the half a soft push cannot do on
        // its own: without a door, the $10 would never reach them.
        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        vm.expectEmit(true, false, false, true, address(a));
        emit RefundWithdrawn(client, EXTRA_BACK);
        vm.prank(stranger); a.withdrawUndeliveredRefund();

        assertEq(usdc.balanceOf(client) - c0, EXTRA_BACK, "the client took their $10.50");
        assertEq(a.undeliveredRefund(), 0, "the debt is settled");
        assertEq(usdc.balanceOf(address(a)), 0, "and the clone is empty after all");
    }

    /// Auto-approve is the case that hurt most: it is the EXECUTOR's money and
    /// anyone at all may push it, yet a stranger's call died on a refund to a
    /// third party.
    function testAutoApproveGoesThroughForABlockedClientToo() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, EXTRA);
        vm.prank(executor); a.markDone();
        usdc.setBlacklisted(client, true);
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);

        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(stranger); a.triggerAutoApprove();

        assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "$100 to the executor");
        assertEq(a.undeliveredRefund(), EXTRA_BACK, "$10.50 booked");
        assertEq(usdc.balanceOf(address(a)), EXTRA_BACK);
    }

    /// A dispute the executor WON now finalizes. Pot $100, fee 3% = $3, so the
    /// executor takes $97 and the $10 proposal becomes the client's debt.
    function testAWonDisputeFinalizesWhileTheClientIsBlocked() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, EXTRA);
        vm.prank(executor); a.raiseDispute();
        _claimByArbiter(a);

        usdc.setBlacklisted(client, true);

        uint256 e0 = usdc.balanceOf(executor);
        uint256 d0 = usdc.balanceOf(address(diamond));
        _submitAndFinalize(a, false); // executor wins

        assertEq(usdc.balanceOf(executor) - e0, 97_000_000, "$97 = $100 pot less the 3% fee");
        assertEq(usdc.balanceOf(address(diamond)) - d0, 3_000_000, "the fee reached the diamond");
        assertEq(a.undeliveredRefund(), EXTRA_BACK, "$10.50 booked to the client");
        assertEq(usdc.balanceOf(address(a)), EXTRA_BACK, "and only that is left behind");
        assertEq(uint8(a.status()), uint8(Agreement.Status.RESOLVED));
    }

    /// The unjudged split: both showed up, nobody claimed it, the client is
    /// blocked. Their half is booked, the executor's half is paid, and the
    /// event carries the amount that actually moved -- zero -- rather than the
    /// amount that was intended.
    function testTheUnjudgedSplitPaysTheExecutorWhileTheClientIsBlocked() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client);   a.raiseDispute();
        vm.prank(executor); a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        usdc.setBlacklisted(client, true);

        uint256 e0 = usdc.balanceOf(executor);
        vm.expectEmit(false, false, false, true, address(a));
        emit DisputeSplitNoVerdict(0, 50_000_000);
        vm.prank(executor); a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - e0, 50_000_000, "the executor's half is out");
        assertEq(a.undeliveredRefund(), 50_000_000, "the client's half is owed");
        assertEq(usdc.balanceOf(address(a)), 50_000_000);

        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(client) - c0, 50_000_000, "and collected later");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// Both sides unservable at once. Each half is booked to its own side --
    /// the split is a split whether or not the token will carry it. Until
    /// 26 August the executor's half was redirected to the CLIENT, so this
    /// scene ended with the whole $100 owed to one party.
    function testBothSidesBlockedLeavesEachHalfOwedToItsOwnSide() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client);   a.raiseDispute();
        vm.prank(executor); a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        usdc.setBlacklisted(client, true);
        usdc.setBlacklisted(executor, true);

        vm.expectEmit(false, false, false, true, address(a));
        emit DisputeSplitNoVerdict(0, 0);
        vm.prank(executor); a.triggerArbiterTimeout();

        assertEq(a.undeliveredRefund(), AMOUNT / 2, "half owed to the client");
        assertEq(a.undeliveredPayout(), AMOUNT / 2, "half owed to the executor");
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "both halves waiting in the clone");
        assertEq(uint8(a.status()), uint8(Agreement.Status.REFUNDED), "and the deal is closed");

        // Two debts, two doors, neither able to take the other's money.
        usdc.setBlacklisted(client, false);
        usdc.setBlacklisted(executor, false);
        uint256 c0 = usdc.balanceOf(client);
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(stranger); a.withdrawUndeliveredRefund();
        vm.prank(stranger); a.withdrawUndeliveredPayout();
        assertEq(usdc.balanceOf(client) - c0, AMOUNT / 2, "client took their half");
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT / 2, "executor took theirs");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// The other branch of the same last door: an arbiter took the dispute and
    /// never ruled, so everything goes back to the client -- who cannot
    /// receive it. Before the fix this branch reverted and the deal had no exit
    /// left at all.
    function testTheArbiterFaultTimeoutClosesTheDealIntoADebt() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        usdc.setBlacklisted(client, true);

        vm.expectEmit(true, false, false, true, address(a));
        emit ArbiterTimedOut(client, 0);
        vm.prank(client); a.triggerArbiterTimeout();

        assertEq(a.undeliveredRefund(), AMOUNT, "$100 owed");
        assertEq(uint8(a.status()), uint8(Agreement.Status.REFUNDED));

        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(client) - c0, AMOUNT);
    }

    /// A token that refuses SILENTLY -- returns false without reverting -- is
    /// booked exactly the same way. Reading only the loud form would count this
    /// as delivered and lose the $10 off the books entirely.
    function testASilentRefusalIsBookedAsADebtToo() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, EXTRA);
        vm.prank(executor); a.markDone();

        usdc.setRefusesSilently(client, true);

        uint256 c0 = usdc.balanceOf(client);
        vm.prank(client); a.release();

        assertEq(usdc.balanceOf(client) - c0, 0, "nothing actually reached them");
        assertEq(a.undeliveredRefund(), EXTRA_BACK, "and the books say so");
        assertEq(usdc.balanceOf(address(a)), EXTRA_BACK);
    }

    // ============================================================
    //  B. The door the debt is pulled through
    // ============================================================

    /// Nothing owed is refused by name, not silently accepted.
    function testWithdrawingNothingIsRefusedByName() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        vm.expectRevert(Agreement.ZeroAmount.selector);
        a.withdrawUndeliveredRefund();
    }

    /// It cannot be drained twice, and it only ever pays the client no matter
    /// who pushes it -- which is why it is open to everyone.
    function testTheDebtPaysOnlyTheClientAndOnlyOnce() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, EXTRA);
        vm.prank(executor); a.markDone();
        usdc.setBlacklisted(client, true);
        vm.prank(client); a.release();
        usdc.setBlacklisted(client, false);

        uint256 s0 = usdc.balanceOf(stranger);
        uint256 c0 = usdc.balanceOf(client);
        vm.prank(stranger); a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(stranger) - s0, 0, "the caller gets nothing");
        assertEq(usdc.balanceOf(client) - c0, EXTRA_BACK, "the client gets it all");

        vm.expectRevert(Agreement.ZeroAmount.selector);
        vm.prank(stranger); a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(address(a)), 0);
    }

    // ============================================================
    //  C. Accepting a top-up now has the windows proposing has
    // ============================================================

    /// The two refusals themselves are measured where the hole was found,
    /// in MoneyPathExtras.t.sol. What belongs here is the other edge: they are
    /// boundaries, not a padlock. The ordinary case is untouched, and so is
    /// the last second before the window shuts.
    function testAcceptingStillWorksRightUpToTheEdgeOfTheWindow() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 60_000_000);
        vm.prank(executor); a.markDone();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW - 1);

        vm.prank(executor); a.acceptExtra(id);
        assertEq(a.totalPayout(), AMOUNT + 60_000_000, "accepted with a second to spare");

        vm.warp(block.timestamp + 2);
        uint256 e0 = usdc.balanceOf(executor);
        a.triggerAutoApprove();
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT + 60_000_000);
    }

    // ============================================================
    //  D. The client can take their own proposal back
    // ============================================================

    /// The other half of a promise that was one-way: proposing was possible,
    /// unproposing was not.
    function testTheClientCanTakeTheirOwnProposalBack() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 60_000_000);

        uint256 c0 = usdc.balanceOf(client);
        vm.expectEmit(true, true, false, true, address(a));
        emit ExtraWithdrawn(id, client, 63_000_000); // $60 proposal + $3 held fee
        vm.prank(client); a.withdrawExtra(id);

        assertEq(usdc.balanceOf(client) - c0, 63_000_000, "the money came straight back, held fee with it");
        assertEq(a.pendingExtrasTotal(), 0, "nothing hangs any more");
        assertEq(a.extrasTotal(), 0, "and it did not become pot");
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "only the body is left");

        // And the deal finishes normally on the smaller number.
        vm.prank(executor); a.markDone();
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(client); a.release();
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "$100, the body alone");
        assertEq(usdc.balanceOf(address(a)), 0);
    }

    /// It is the client's door and nobody else's, and it closes behind itself.
    function testTakingBackIsTheClientsAloneAndHappensOnce() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 60_000_000);

        vm.prank(executor);
        vm.expectRevert(Agreement.NotClient.selector);
        a.withdrawExtra(id);

        vm.prank(client); a.withdrawExtra(id);

        vm.prank(client);
        vm.expectRevert(Agreement.ExtraNotPending.selector);
        a.withdrawExtra(id);

        // And the executor can no longer accept what is no longer there.
        vm.prank(executor);
        vm.expectRevert(Agreement.ExtraNotPending.selector);
        a.acceptExtra(id);
    }

    /// Taking it back after the deal is over is refused by name: by then the
    /// exit has already returned it (or booked it).
    function testTakingBackIsRefusedOnceTheDealIsFinalized() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 60_000_000);
        vm.warp(block.timestamp + DEADLINE * 1 days + DEADLINE_GRACE + 1);
        vm.prank(client); a.triggerDeadlineTimeout();

        vm.prank(client);
        vm.expectRevert(Agreement.AlreadyFinalized.selector);
        a.withdrawExtra(id);
    }

    /// A client the token refuses can still clear their own proposal: the
    /// money becomes a debt instead of reverting the call.
    function testABlockedClientTakingBackTheirProposalGetsADebt() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 60_000_000);

        usdc.setBlacklisted(client, true);
        vm.prank(client); a.withdrawExtra(id);

        assertEq(a.pendingExtrasTotal(), 0, "cleared anyway");
        assertEq(a.undeliveredRefund(), 63_000_000, "and owed, held fee included");

        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(client) - c0, 63_000_000);
    }

    // ============================================================
    //  E. The executor's half of the same door
    // ============================================================
    //
    // The client got a debt and a door on 26 August; the executor got neither,
    // and the three payments that go TO the executor stayed hard. Half a door
    // is worse than no door -- the mechanism is visibly there and does not work
    // for you. The scenes below are the mirror of section A, one for each of
    // those three payments, and they all measured a permanent lock before the
    // fix.

    /// release with a blocked executor. Before the fix: TransferFailed, and
    /// once the auto-approve window ran out every other door refused by name
    /// (WindowAlreadyPassed x2, AlreadyMarkedDone, AlreadyActive, NotDisputed)
    /// -- six refusals, $100 in the clone forever.
    function testReleaseToABlockedExecutorClosesTheDealIntoADebt() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor); a.markDone();

        usdc.setBlacklisted(executor, true);

        vm.expectEmit(true, false, false, true, address(a));
        emit PayoutDeferred(executor, AMOUNT);
        vm.prank(client); a.release();

        assertEq(uint8(a.status()), uint8(Agreement.Status.COMPLETED), "the deal closed");
        assertEq(a.undeliveredPayout(), AMOUNT, "$100 owed to the executor");
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "and held in the clone");

        usdc.setBlacklisted(executor, false);
        uint256 e0 = usdc.balanceOf(executor);
        vm.expectEmit(true, false, false, true, address(a));
        emit PayoutWithdrawn(executor, AMOUNT);
        vm.prank(stranger); a.withdrawUndeliveredPayout();
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "$100 home");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// The same on the auto-approve path, which ANYONE may push. A stranger
    /// closing a deal used to be answered TransferFailed about a wallet that
    /// is none of their business.
    function testAutoApproveClosesForABlockedExecutorToo() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor); a.markDone();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);

        usdc.setBlacklisted(executor, true);
        vm.prank(stranger); a.triggerAutoApprove();

        assertEq(uint8(a.status()), uint8(Agreement.Status.COMPLETED));
        assertEq(a.undeliveredPayout(), AMOUNT, "owed, not lost");
    }

    /// An executor who WON the dispute and cannot receive -- the mirror of
    /// testAClientWhoWonAndCannotReceiveIsOwedTheMoneyInstead, and locked in
    /// exactly the same way before the fix: the verdict is final, the payout
    /// reverted, and triggerArbiterTimeout answers VerdictInFlight.
    function testAnExecutorWhoWonAndCannotReceiveIsOwedTheMoneyInstead() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);

        usdc.setBlacklisted(executor, true);
        _submitAndFinalize(a, false); // executor wins

        assertEq(uint8(a.status()), uint8(Agreement.Status.RESOLVED), "the verdict landed");
        assertEq(a.undeliveredPayout(), 97_000_000, "pot less the 3% fee, owed");

        usdc.setBlacklisted(executor, false);
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(stranger); a.withdrawUndeliveredPayout();
        assertEq(usdc.balanceOf(executor) - e0, 97_000_000, "the winner was paid, late");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// The undeliverable half of an unjudged split is BOOKED to the executor,
    /// not handed to the client. Measured before the fix: a blocked executor's
    /// $50 arrived in the client's wallet and the client walked away with the
    /// whole $100 of a pot nobody judged. A blacklist is not a verdict.
    function testTheSplitBooksTheExecutorsHalfInsteadOfGivingItAway() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(executor); a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        usdc.setBlacklisted(executor, true);

        uint256 c0 = usdc.balanceOf(client);
        vm.expectEmit(false, false, false, true, address(a));
        emit DisputeSplitNoVerdict(AMOUNT / 2, 0);
        vm.prank(executor); a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - c0, AMOUNT / 2, "the client got their half and no more");
        assertEq(a.undeliveredPayout(), AMOUNT / 2, "the executor's half is owed to the executor");
        assertEq(a.undeliveredRefund(), 0, "and nothing to the client");
    }

    /// The door pays the executor, only the executor, and only once.
    function testThePayoutDoorPaysOnlyTheExecutorAndOnlyOnce() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor); a.markDone();
        usdc.setBlacklisted(executor, true);
        vm.prank(client); a.release();
        usdc.setBlacklisted(executor, false);

        uint256 c0 = usdc.balanceOf(client);
        uint256 s0 = usdc.balanceOf(stranger);
        uint256 e0 = usdc.balanceOf(executor);

        vm.prank(client); a.withdrawUndeliveredPayout(); // the client may push it
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "it went to the executor");
        assertEq(usdc.balanceOf(client), c0, "not to the caller");
        assertEq(usdc.balanceOf(stranger), s0, "and not to anybody else");
        assertEq(a.undeliveredPayout(), 0, "the debt is cleared");

        vm.prank(stranger);
        vm.expectRevert(Agreement.ZeroAmount.selector);
        a.withdrawUndeliveredPayout();
    }

    /// Asking for a payout that is not owed is refused by name, the same way
    /// the refund door refuses.
    function testWithdrawingNoPayoutIsRefusedByName() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        vm.prank(stranger);
        vm.expectRevert(Agreement.ZeroAmount.selector);
        a.withdrawUndeliveredPayout();
    }

    /// Both debts live at once and do not touch each other: a blocked client's
    /// hanging proposal and a blocked executor's body, on one release.
    function testTheTwoDebtsAreSeparateBalancesWithSeparateDoors() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, EXTRA);
        vm.prank(executor); a.markDone();

        usdc.setBlacklisted(client, true);
        usdc.setBlacklisted(executor, true);
        vm.prank(client); a.release();

        assertEq(a.undeliveredRefund(), EXTRA_BACK, "$10.50 owed to the client");
        assertEq(a.undeliveredPayout(), AMOUNT, "$100 owed to the executor");
        assertEq(usdc.balanceOf(address(a)), AMOUNT + EXTRA_BACK, "$110.50 held");

        // The executor gets served again first; the client's debt is untouched.
        usdc.setBlacklisted(executor, false);
        uint256 e0 = usdc.balanceOf(executor);
        a.withdrawUndeliveredPayout();
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT);
        assertEq(a.undeliveredRefund(), EXTRA_BACK, "the client's debt did not move");
        assertEq(usdc.balanceOf(address(a)), EXTRA_BACK);

        // And the refund door will not pay out of the payout ledger.
        vm.expectRevert(SafeUSDC.TransferFailed.selector);
        a.withdrawUndeliveredRefund();

        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        a.withdrawUndeliveredRefund();
        assertEq(usdc.balanceOf(client) - c0, EXTRA_BACK);
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }
}
