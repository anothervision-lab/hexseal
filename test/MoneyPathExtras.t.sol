// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  Money path, part 2 — the top-up
// ============================================================
//
// Extras are the only way to add money to a live deal. Four questions, each
// answered by a balance rather than by reading the code:
//   * is a fee taken on a top-up, and at what rate;
//   * does the top-up reach totalPayout;
//   * what happens to a proposal still hanging when the deal ends;
//   * who can move a proposal, and when.

import "./MoneyPathBase.sol";

contract MoneyPathExtrasTest is MoneyPathBase {

    // ------------------------------------------------------------
    //  1. The protocol takes the same 5% on a top-up
    // ------------------------------------------------------------
    //
    // Until 26 August 2026 it took nothing at all. The fee is a function of
    // `amount`, and `amount` is frozen at hire time, so every dollar that
    // arrived as a top-up arrived free. Every number below is a literal or a
    // figure read off the token; none is recomputed from the contract under
    // measurement.

    /// A $1000 top-up on a $100 deal pays $50 -- the same 5% the deal paid --
    /// and pays it at the moment the executor accepts.
    function testTopUpPaysTheSameFivePercent() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 big = 1_000_000_000; // $1000, ten times the deal

        uint256 id = _proposeExtra(a, big);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 0, "nothing is owed until it is accepted");
        assertEq(usdc.balanceOf(address(a)), AMOUNT + big + 50_000_000, "the clone holds the body, the offer and its fee");
        assertEq(a.pendingExtraFeeTotal(), 50_000_000, "and says so");

        vm.prank(executor);
        a.acceptExtra(id);

        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 50_000_000, "$50 on a $1000 top-up");
        assertEq(a.pendingExtraFeeTotal(), 0, "nothing held any more");
        assertEq(usdc.balanceOf(address(a)), AMOUNT + big, "the clone holds exactly the pot");
        assertEq(a.totalPayout(), AMOUNT + big, "and it is all payable to the executor");
    }

    /// THE MEASUREMENT THIS CHANGE EXISTS FOR. Declaring $1100 of work up front
    /// costs $55. Declaring $100 and topping up $1000 now costs $55 too. It
    /// used to cost $5.
    function testTheSameMoneyCostsTheSameWhicheverWayItArrives() public {
        uint256 declared = 1_100_000_000; // $1100 in one deal
        uint256 feeIfDeclared = FactoryFacet(address(diamond)).quoteFee(declared);
        assertEq(feeIfDeclared, 55_000_000, "5% of $1100");

        uint256 f0 = usdc.balanceOf(feeRecipient);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 1_000_000_000);
        vm.prank(executor);
        a.acceptExtra(id);
        uint256 feeActuallyPaid = usdc.balanceOf(feeRecipient) - f0;

        assertEq(feeActuallyPaid, 55_000_000, "$55 on the same $1100 of work");
        assertEq(a.totalPayout(), declared, "and the work really is $1100");
        assertEq(feeIfDeclared, feeActuallyPaid, "the two ways cost the same");
    }

    /// The headline scheme, at the size that made it worth doing: a deal of
    /// $1000 with a $10 000 top-up against $11 000 declared in one go. $550
    /// either way; it used to be $50 against $550.
    function testTenThousandArrivingAsATopUpCostsWhatItWouldHaveCostDeclared() public {
        uint256 declared = 11_000_000_000; // $11 000
        assertEq(FactoryFacet(address(diamond)).quoteFee(declared), 550_000_000, "5% of $11 000");

        uint256 f0 = usdc.balanceOf(feeRecipient);
        Agreement a = _hireDirectly(1_000_000_000);            // $1000 deal
        assertEq(usdc.balanceOf(feeRecipient) - f0, 50_000_000, "$50 at the hire");

        _activate(a);
        uint256 id = _proposeExtra(a, 10_000_000_000);         // $10 000 top-up
        vm.prank(executor);
        a.acceptExtra(id);

        assertEq(usdc.balanceOf(feeRecipient) - f0, 550_000_000, "$550 split in two, $550 in one");
        assertEq(a.totalPayout(), declared, "on the same $11 000 of work");
    }

    /// The smallest case, and the one place the two ways do NOT cost the same
    /// -- which is the floor doing its job, not the hole reopening. A $1 deal
    /// pays the $1 floor because creating a deal has a fixed cost; the $10 000
    /// that follows pays a clean 5%. Splitting therefore costs 95 cents MORE
    /// than declaring $10 001 at once, never less, so there is nothing to
    /// exploit. It used to cost $1 against $500.05.
    function testTheFloorMakesTheSplitDearerThanTheWholeNeverCheaper() public {
        uint256 whole = 10_001_000_000; // $10 001 in one deal
        assertEq(FactoryFacet(address(diamond)).quoteFee(whole), 500_050_000, "5% of $10 001");

        uint256 f0 = usdc.balanceOf(feeRecipient);
        Agreement a = _hireDirectly(1_000_000); // $1
        assertEq(usdc.balanceOf(feeRecipient) - f0, FEE_FLOOR, "the floor, because a deal was created");

        _activate(a);
        uint256 id = _proposeExtra(a, 10_000_000_000); // $10 000
        vm.prank(executor);
        a.acceptExtra(id);

        uint256 split = usdc.balanceOf(feeRecipient) - f0;
        assertEq(split, 501_000_000, "$1 floor + $500 of top-up");
        assertEq(a.totalPayout(), whole, "on a pot of $10 001");
        assertGt(split, uint256(500_050_000), "splitting costs more, so it buys nothing");
    }

    /// The floor is NOT applied to a top-up, and that is a decision. A $5
    /// top-up pays 25 cents. The floor pays for CREATING a deal; a top-up
    /// creates nothing, and a dollar on five would be twenty percent.
    function testTheFloorIsNotAppliedToATopUp() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        assertEq(a.quoteExtraFee(5_000_000), 250_000, "25 cents, not the $1 floor");
        assertEq(
            FactoryFacet(address(diamond)).quoteFee(5_000_000),
            FEE_FLOOR,
            "the same $5 as a DEAL would pay the floor -- the asymmetry is deliberate"
        );

        uint256 f0 = usdc.balanceOf(feeRecipient);
        uint256 id = _proposeExtra(a, 5_000_000);
        vm.prank(executor);
        a.acceptExtra(id);
        assertEq(usdc.balanceOf(feeRecipient) - f0, 250_000, "25 cents collected");
    }

    /// A top-up small enough to round the fee to zero is charged nothing and
    /// still works. 19 units of USDC at 5% is 0.95 of a unit, and there is no
    /// smaller coin.
    function testADustTopUpIsChargedNothingAndStillGoesThrough() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        assertEq(a.quoteExtraFee(19), 0, "5% of 19 units rounds to nothing");
        uint256 f0 = usdc.balanceOf(feeRecipient);
        uint256 id = _proposeExtra(a, 19);
        vm.prank(executor);
        a.acceptExtra(id);

        assertEq(usdc.balanceOf(feeRecipient), f0, "nothing was taken");
        assertEq(a.totalPayout(), AMOUNT + 19, "and the 19 units are pot");
    }

    // ------------------------------------------------------------
    //  1b. An undone proposal costs nothing
    // ------------------------------------------------------------
    //
    // The fee is HELD, not paid, until the executor accepts. Paying it
    // straight through would have handed the executor a way to burn the
    // client's money: rejectExtra is theirs, and refusing a $10 000 proposal
    // would have cost the client $500 for nothing. No base path lets a
    // counterparty do that.

    /// The executor refuses. Everything comes back, fee included, and the
    /// protocol is paid nothing.
    function testTheExecutorRefusingATopUpCostsTheClientNothing() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        uint256 f0 = usdc.balanceOf(feeRecipient);
        uint256 c0 = usdc.balanceOf(client);
        uint256 id = _proposeExtra(a, 1_000_000_000);
        assertEq(c0 - usdc.balanceOf(client), 1_050_000_000, "$1000 offered, $50 of fee alongside it");

        vm.prank(executor);
        a.rejectExtra(id);

        assertEq(usdc.balanceOf(client), c0, "every cent back");
        assertEq(usdc.balanceOf(feeRecipient), f0, "and the protocol took nothing");
        assertEq(a.pendingExtraFeeTotal(), 0);
        assertEq(a.extraFee(id), 0);
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "only the body is left in the clone");
    }

    /// The client takes their own proposal back. Same answer -- taking back an
    /// offer nobody accepted is free.
    function testTakingYourOwnProposalBackIsFree() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        uint256 f0 = usdc.balanceOf(feeRecipient);
        uint256 c0 = usdc.balanceOf(client);
        uint256 id = _proposeExtra(a, 200_000_000); // $200, fee $10

        vm.prank(client);
        a.withdrawExtra(id);

        assertEq(usdc.balanceOf(client), c0, "$210 out, $210 back");
        assertEq(usdc.balanceOf(feeRecipient), f0, "nothing taken");
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "clone holds the body alone");
    }

    /// A deal that ends with a proposal still hanging sends the held fee home
    /// with it. This is the term that would otherwise be left in a clone that
    /// has no rescue function and is nailed to its implementation for life.
    function testAHangingProposalTakesItsHeldFeeHomeWithIt() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        uint256 f0 = usdc.balanceOf(feeRecipient);
        uint256 c0 = usdc.balanceOf(client);
        _proposeExtra(a, 400_000_000); // $400, fee $20
        assertEq(usdc.balanceOf(address(a)), AMOUNT + 420_000_000, "body + offer + held fee");

        vm.prank(executor); a.markDone();
        vm.prank(client);   a.release();

        assertEq(usdc.balanceOf(client), c0, "$420 out, $420 back");
        assertEq(usdc.balanceOf(feeRecipient), f0, "the protocol was never paid for it");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
        assertEq(a.pendingExtraFeeTotal(), 0);
    }

    // ------------------------------------------------------------
    //  1c. A diamond that will not name the rate stops the top-up
    // ------------------------------------------------------------

    /// The rate is read off the diamond every time. If the read fails the
    /// top-up REFUSES -- it does not quietly charge zero, which is the hole
    /// this whole change closes and would otherwise be openable by anyone who
    /// could silence the diamond for one block.
    ///
    /// A codeless address answers a staticcall with success and no returndata,
    /// so "carry on with what was read" would have read as "the rate is 0".
    function testATopUpRefusesWhenTheRateCannotBeRead() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        uint256 c0  = usdc.balanceOf(client);
        uint256 cl0 = usdc.balanceOf(address(a));
        vm.etch(address(diamond), hex""); // the diamond stops existing

        vm.startPrank(client);
        usdc.approve(address(a), 1_050_000_000);
        vm.expectRevert(Agreement.FeeUnavailable.selector);
        a.proposeExtra(1_000_000_000, "x");
        vm.stopPrank();

        assertEq(usdc.balanceOf(client), c0, "not a cent moved");
        assertEq(usdc.balanceOf(address(a)), cl0, "and the clone is untouched");
        assertEq(a.nextExtraId(), 0, "no proposal was recorded either");
    }

    /// The same refusal from the reading side, so the interface finds out
    /// before it asks anyone to sign.
    function testQuoteExtraFeeRefusesRatherThanAnsweringZero() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.etch(address(diamond), hex"");

        vm.expectRevert(Agreement.FeeUnavailable.selector);
        a.quoteExtraFee(1_000_000_000);
    }

    // ------------------------------------------------------------
    //  2. A hanging proposal, and what ends it
    // ------------------------------------------------------------

    /// The client has a door of their own since 26 August 2026. Before that
    /// rejectExtra was the only cancel there is and it belongs to the
    /// executor, so a proposal could be made and not unmade: the money sat in
    /// the clone until the other side chose to move it, or until the deal
    /// ended. Both halves measured here -- rejectExtra is still theirs alone,
    /// withdrawExtra is now the client's.
    function testTheClientCanTakeBackTheirOwnProposal() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 50_000_000);

        assertEq(a.pendingExtrasTotal(), 50_000_000);

        // rejectExtra did not change hands.
        vm.prank(client);
        vm.expectRevert(Agreement.NotExecutor.selector);
        a.rejectExtra(id);

        uint256 c0 = usdc.balanceOf(client);
        vm.prank(client);
        a.withdrawExtra(id);

        assertEq(usdc.balanceOf(client) - c0, 50_000_000 + _extraFee(50_000_000), "the money came back on their own say-so");
        assertEq(a.pendingExtrasTotal(), 0);
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "only the body is left in the clone");
    }

    /// Every exit that can be reached with a proposal outstanding returns it
    /// whole to the client, and leaves the clone empty.
    function testEveryExitReturnsAHangingProposalWhole() public {
        // release
        {
            (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
            _activate(a);
            _proposeExtra(a, 40_000_000);
            vm.prank(executor); a.markDone();
            uint256 c0 = usdc.balanceOf(client);
            uint256 e0 = usdc.balanceOf(executor);
            vm.prank(client); a.release();
            assertEq(usdc.balanceOf(client) - c0, 40_000_000 + _extraFee(40_000_000), "release: proposal and held fee back whole");
            assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "release: body to the executor");
            assertEq(usdc.balanceOf(address(a)), 0, "release: clone empty");
        }
        // auto-approve
        {
            address c2 = address(0x21); usdc.mint(c2, BAG);
            vm.prank(c2); usdc.approve(address(diamond), type(uint256).max);
            vm.prank(c2);
            Agreement a = Agreement(FactoryFacet(address(diamond)).deployAndFund(c2, executor, AMOUNT, DEADLINE, TERMS, 0));
            _activate(a);
            vm.startPrank(c2); usdc.approve(address(a), 40_000_000 + a.quoteExtraFee(40_000_000)); a.proposeExtra(40_000_000, "x"); vm.stopPrank();
            vm.prank(executor); a.markDone();
            vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);
            uint256 c0 = usdc.balanceOf(c2);
            a.triggerAutoApprove();
            assertEq(usdc.balanceOf(c2) - c0, 40_000_000 + _extraFee(40_000_000), "auto-approve: proposal and held fee back whole");
            assertEq(usdc.balanceOf(address(a)), 0, "auto-approve: clone empty");
        }
        // deadline timeout
        {
            address c3 = address(0x22); usdc.mint(c3, BAG);
            vm.prank(c3); usdc.approve(address(diamond), type(uint256).max);
            vm.prank(c3);
            Agreement a = Agreement(FactoryFacet(address(diamond)).deployAndFund(c3, executor, AMOUNT, DEADLINE, TERMS, 0));
            _activate(a);
            vm.startPrank(c3); usdc.approve(address(a), 40_000_000 + a.quoteExtraFee(40_000_000)); a.proposeExtra(40_000_000, "x"); vm.stopPrank();
            vm.warp(block.timestamp + DEADLINE * 1 days + DEADLINE_GRACE + 1);
            uint256 c0 = usdc.balanceOf(c3);
            vm.prank(c3); a.triggerDeadlineTimeout();
            assertEq(usdc.balanceOf(c3) - c0, AMOUNT + 40_000_000 + _extraFee(40_000_000), "deadline: body, proposal and held fee back");
            assertEq(usdc.balanceOf(address(a)), 0, "deadline: clone empty");
        }
    }

    /// Activation timeout is the one exit that never calls the refund of
    /// hanging proposals -- and it does not need to, because a proposal cannot
    /// exist before activation. Measured both halves.
    function testNoProposalCanExistBeforeActivationSoTheTimeoutNeedsNoRefund() public {
        Agreement a = _hireDirectly(AMOUNT);

        vm.startPrank(client);
        usdc.approve(address(a), 10_000_000);
        vm.expectRevert(Agreement.NotActive.selector);
        a.proposeExtra(10_000_000, "x");
        vm.stopPrank();

        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);
        uint256 c0 = usdc.balanceOf(client);
        vm.prank(client); a.triggerActivationTimeout();
        assertEq(usdc.balanceOf(client) - c0, AMOUNT, "exactly the body comes back");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
        assertEq(a.pendingExtrasTotal(), 0);
    }

    // ------------------------------------------------------------
    //  3. Accepting a proposal has the same windows as proposing one
    // ------------------------------------------------------------

    /// acceptExtra used to check the sender and the proposal's state and
    /// nothing else, so the executor could accept a hanging proposal AFTER the
    /// dispute was raised -- converting money that would have gone back to the
    /// client into pot a verdict could award to the executor. The verdict paid
    /// $155.20 instead of $97. It now refuses with the same name proposeExtra
    /// uses, and the $60 goes home.
    function testTheExecutorCannotAcceptAProposalOnceTheDisputeIsRaised() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 60_000_000);

        vm.prank(client);
        a.raiseDispute();
        assertEq(uint8(a.status()), uint8(Agreement.Status.DISPUTED));

        // The window that stops proposeExtra does not stop acceptExtra.
        vm.startPrank(client);
        usdc.approve(address(a), 10_000_000);
        vm.expectRevert(Agreement.AlreadyDisputed.selector);
        a.proposeExtra(10_000_000, "y");
        vm.stopPrank();

        vm.prank(executor);
        vm.expectRevert(Agreement.AlreadyDisputed.selector);
        a.acceptExtra(id);

        assertEq(a.pendingExtrasTotal(), 60_000_000, "still refundable");
        assertEq(a.totalPayout(), AMOUNT, "and still not pot");

        // The verdict is now decided on the body alone.
        _claimByArbiter(a);
        uint256 e0 = usdc.balanceOf(executor);
        uint256 c0 = usdc.balanceOf(client);
        _submitAndFinalize(a, false); // executor wins
        uint256 disputeFee = AMOUNT * 300 / 10_000;
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT - disputeFee, "$97, where it used to be $155.20");
        assertEq(usdc.balanceOf(client) - c0, 60_000_000 + _extraFee(60_000_000), "the proposal went home instead, unearned fee with it");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    /// The same door used to stay open after the auto-approve window had
    /// already run out: the deal reads COMPLETED, nobody has pushed the button
    /// yet, and the executor could still enlarge their own payout -- $160
    /// instead of $100. Shut by the window release() already uses.
    function testTheExecutorCannotAcceptAProposalOnceTheAutoApproveWindowRanOut() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 60_000_000);
        vm.prank(executor); a.markDone();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);
        assertEq(uint8(a.status()), uint8(Agreement.Status.COMPLETED), "already reads as done");

        vm.prank(executor);
        vm.expectRevert(Agreement.WindowAlreadyPassed.selector);
        a.acceptExtra(id);

        uint256 e0 = usdc.balanceOf(executor);
        uint256 c0 = usdc.balanceOf(client);
        a.triggerAutoApprove();
        assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "$100, where it used to be $160");
        assertEq(usdc.balanceOf(client) - c0, 60_000_000 + _extraFee(60_000_000), "and the proposal came back, unearned fee with it");
    }

    // ------------------------------------------------------------
    //  4. The clone's books
    // ------------------------------------------------------------

    /// Accepted and pending are two separate ledgers and they must not leak
    /// into each other. Three proposals: one accepted, one rejected, one left
    /// hanging.
    function testAcceptedRejectedAndHangingStaySeparate() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        uint256 a1 = _proposeExtra(a, 10_000_000);
        uint256 a2 = _proposeExtra(a, 20_000_000);
        uint256 a3 = _proposeExtra(a, 30_000_000);
        assertEq(usdc.balanceOf(address(a)), AMOUNT + 60_000_000 + _extraFee(60_000_000), "all three are in the clone, with their held fees");

        vm.prank(executor); a.acceptExtra(a1);
        uint256 c0 = usdc.balanceOf(client);
        vm.prank(executor); a.rejectExtra(a2);
        assertEq(usdc.balanceOf(client) - c0, 20_000_000 + _extraFee(20_000_000), "rejected comes straight back, held fee with it");

        assertEq(a.extrasTotal(), 10_000_000);
        assertEq(a.pendingExtrasTotal(), 30_000_000);
        assertEq(
            usdc.balanceOf(address(a)),
            AMOUNT + 40_000_000 + _extraFee(30_000_000),
            "clone holds accepted + hanging + the hanging one's held fee"
        );
        assertEq(a3, 2);

        vm.prank(executor); a.markDone();
        uint256 c1 = usdc.balanceOf(client);
        uint256 e1 = usdc.balanceOf(executor);
        vm.prank(client); a.release();

        assertEq(usdc.balanceOf(executor) - e1, AMOUNT + 10_000_000, "body + accepted");
        assertEq(usdc.balanceOf(client) - c1, 30_000_000 + _extraFee(30_000_000), "hanging back, held fee with it");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }
}
