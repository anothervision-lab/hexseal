// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AgreementPackingFixture.sol";

// ============================================================
// 2. BOUNDS
// ============================================================

contract AgreementPackingBoundsTest is PackingFixture {
    uint256 constant MAX_TS   = type(uint40).max;   // 1_099_511_627_775 -- year 36812
    uint256 constant MAX_DAYS = type(uint16).max;   // 65_535 days -- 179 years

    // -------- ZERO --------

    /// A clone nobody has touched reads zero out of every time field, and the
    /// status that follows from that.
    function testEveryTimeIsZeroOnAFreshClone() public {
        Agreement a = _clone(7);
        assertEq(a.fundedAt(),     0, "fundedAt");
        assertEq(a.activatedAt(),  0, "activatedAt");
        assertEq(a.markedDoneAt(), 0, "markedDoneAt");
        assertEq(a.disputedAt(),   0, "disputedAt");
        assertEq(a.resolvedAt(),   0, "resolvedAt");
        assertFalse(a.clientWonDispute(),  "clientWonDispute");
        assertFalse(a.clientResponded(),   "clientResponded");
        assertFalse(a.executorResponded(), "executorResponded");
        assertEq(uint256(a.status()), uint256(Agreement.Status.CREATED), "status");
    }

    // -------- THE TOP OF THE TIME FIELD --------

    /// A deal funded at the very last second the field can hold reads that
    /// second back. A width one bit short truncates here instead.
    function testFundingAtTheMaximumTimestampRoundTrips() public {
        vm.warp(MAX_TS);
        Agreement a = _fundedClone(7);
        assertEq(a.fundedAt(), MAX_TS, "fundedAt did not survive the maximum");
        assertEq(uint256(a.status()), uint256(Agreement.Status.FUNDED), "status");
    }

    function testFundingOneSecondBelowTheMaximumRoundTrips() public {
        vm.warp(MAX_TS - 1);
        Agreement a = _fundedClone(7);
        assertEq(a.fundedAt(), MAX_TS - 1, "fundedAt did not survive max-1");
    }

    /// One second past the top of the field the deal REFUSES rather than
    /// storing a truncated time. A truncated `fundedAt` would read as a deal
    /// that was never funded, and fund() would then be callable again.
    function testFundingPastTheMaximumTimestampIsRefusedByName() public {
        Agreement a = _clone(7);
        usdc.mint(CLIENT, AMOUNT);
        vm.startPrank(CLIENT);
        usdc.approve(address(a), AMOUNT);
        vm.warp(MAX_TS + 1);
        vm.expectRevert(Agreement.TimestampOverflow.selector);
        a.fund();
        vm.stopPrank();
    }

    // -------- THE TOP OF THE DEADLINE FIELD --------

    /// The ceiling the factory enforces is 365, but the FIELD has to survive
    /// a future raise of that ceiling and an operator mistake alike, so its
    /// own top is tested directly through the clone.
    function testTheDeadlineFieldHoldsItsMaximum() public {
        Agreement a = _clone(MAX_DAYS);
        assertEq(a.deadlineDays(), MAX_DAYS, "deadlineDays did not survive the maximum");
    }

    function testTheDeadlineFieldHoldsOneBelowItsMaximum() public {
        Agreement a = _clone(MAX_DAYS - 1);
        assertEq(a.deadlineDays(), MAX_DAYS - 1, "deadlineDays did not survive max-1");
    }

    /// One day past the top of the field, initialize REFUSES. It does not
    /// truncate: a truncated 65_536 would become a deal with a deadline of
    /// zero days, and a truncated type(uint256).max would become 65_535 -- a
    /// 179-year deal nobody asked for. Both are silent lies about a term
    /// somebody signed.
    function testADeadlinePastTheFieldIsRefusedByName() public {
        vm.expectRevert(Agreement.DeadlineDaysOverflow.selector);
        cloneDeployer.deploy(
            CLIENT, EXECUTOR, address(0),
            AMOUNT, MAX_DAYS + 1, "Standard work terms",
            DIAMOND, address(usdc), FORWARDER, address(this)
        );
    }

    /// The value form A of the audit built its trap out of. It is now refused
    /// at the clone, one level below the factory ceiling that also refuses it.
    function testAMaxUint256DeadlineIsRefusedAtTheClone() public {
        vm.expectRevert(Agreement.DeadlineDaysOverflow.selector);
        cloneDeployer.deploy(
            CLIENT, EXECUTOR, address(0),
            AMOUNT, type(uint256).max, "Standard work terms",
            DIAMOND, address(usdc), FORWARDER, address(this)
        );
    }

    /// The zero end keeps its own refusal. Narrowing the field must not have
    /// swallowed it.
    function testAZeroDeadlineIsStillRefused() public {
        vm.expectRevert(Agreement.ZeroAmount.selector);
        cloneDeployer.deploy(
            CLIENT, EXECUTOR, address(0),
            AMOUNT, 0, "Standard work terms",
            DIAMOND, address(usdc), FORWARDER, address(this)
        );
    }

    // -------- THE SUM, AT BOTH MAXIMA AT ONCE --------

    /// The one arithmetic this file has to survive: the deadline is computed
    /// as `activatedAt + deadlineDays * 1 days`, and every door out of an
    /// active deal touches it. With BOTH terms at the top of their fields the
    /// sum is 1_105_173_938_175 -- forty-one bits, nowhere near the uint256
    /// it is computed in.
    ///
    /// Form A of this audit measured what happens when that sum does
    /// overflow: markDone, triggerDeadlineTimeout, raiseDispute and status()
    /// all revert with Panic 0x11 while the four other doors refuse for
    /// reasons of their own, and the escrow has no rescuer. So this scene is
    /// not about a number being large; it is about seven doors staying open.
    function testTheDeadlineSumDoesNotOverflowAtBothMaxima() public {
        vm.warp(MAX_TS);
        Agreement a = _fundedClone(MAX_DAYS);
        vm.prank(EXECUTOR);
        a.activate();

        assertEq(a.activatedAt(),  MAX_TS,   "activatedAt");
        assertEq(a.deadlineDays(), MAX_DAYS, "deadlineDays");

        // Reads that touch the sum.
        assertEq(uint256(a.status()), uint256(Agreement.Status.ACTIVE), "status revert-free");
        assertEq(a.timeLeft(), MAX_DAYS * 1 days, "timeLeft");

        // Writes that touch the sum. markDone is inside the deadline, so it
        // succeeds; the timeout is before it, so it refuses BY NAME rather
        // than with an arithmetic panic.
        vm.prank(CLIENT);
        vm.expectRevert(Agreement.DeadlineNotPassed.selector);
        a.triggerDeadlineTimeout();

        vm.prank(EXECUTOR);
        a.markDone();
        assertEq(a.markedDoneAt(), MAX_TS, "markedDoneAt");
    }

    /// The same sum through the door that reads it without an activation:
    /// proposeExtra compares against `activatedAt + deadlineDays * 1 days`
    /// with no grace term, which is a different expression in the same shape.
    function testProposeExtraArithmeticSurvivesBothMaxima() public {
        vm.warp(MAX_TS);
        Agreement a = _fundedClone(MAX_DAYS);
        vm.prank(EXECUTOR);
        a.activate();

        usdc.mint(CLIENT, 10_000_000);
        vm.startPrank(CLIENT);
        usdc.approve(address(a), 10_000_000);
        // No diamond, so the fee model cannot be read: the refusal must be
        // that one, by name, and not an arithmetic panic on the deadline.
        vm.expectRevert(Agreement.FeeUnavailable.selector);
        a.proposeExtra(1_000_000, "extra");
        vm.stopPrank();
    }

    // -------- THE DISPUTE WINDOW, AT THE TOP OF THE TIME FIELD --------

    /// `disputedAt + DISPUTE_WINDOW` is the other sum a narrow time field
    /// feeds. At the top of the field it must still be computed in uint256.
    function testTheDisputeWindowSumDoesNotOverflowAtTheMaximum() public {
        vm.warp(MAX_TS);
        Agreement a = _fundedClone(365);
        vm.prank(EXECUTOR);
        a.activate();
        vm.prank(CLIENT);
        a.raiseDispute();

        assertEq(a.disputedAt(), MAX_TS, "disputedAt");
        assertEq(a.arbiterTimeLeft(), 4 days, "arbiterTimeLeft");

        vm.prank(CLIENT);
        vm.expectRevert(Agreement.WindowNotPassed.selector);
        a.triggerArbiterTimeout();
    }
}

// ============================================================
// 3. INDEPENDENCE
// ============================================================

contract AgreementPackingIndependenceTest is PackingFixture {
    /// Every field in the shared slot, driven to a DIFFERENT value in one
    /// deal, then all of them read back.
    ///
    /// This is the test a packing bug actually trips. Writing one field with
    /// the wrong mask leaves its neighbours wrong, and a suite that sets one
    /// field and reads it straight back never notices.
    function testEveryPackedFieldKeepsItsOwnValue() public {
        uint256 t0 = 1_800_000_000;      // funded
        uint256 t1 = t0 + 1;             // activated
        uint256 t2 = t1 + 12 hours;      // marked done
        uint256 t3 = t2 + 3 hours;       // disputed
        uint256 t4 = t3 + 5 hours;       // resolved

        vm.warp(t0);
        Agreement a = _fundedClone(311);  // a deadline no other number equals

        vm.prank(DIAMOND);
        a.setArbiter(DIAMOND);

        vm.warp(t1);
        vm.prank(EXECUTOR);
        a.activate();

        vm.warp(t2);
        vm.prank(EXECUTOR);
        a.markDone();

        vm.warp(t3);
        vm.prank(CLIENT);
        a.raiseDispute();

        // Only the client has shown up so far -- the asymmetry is the point.
        assertTrue(a.clientResponded(),    "clientResponded after raiseDispute");
        assertFalse(a.executorResponded(), "executorResponded before responding");

        vm.prank(EXECUTOR);
        a.respondToDispute();

        vm.warp(t4);
        vm.prank(DIAMOND);
        a.resolveDispute(true);

        assertEq(a.fundedAt(),     t0,  "fundedAt");
        assertEq(a.activatedAt(),  t1,  "activatedAt");
        assertEq(a.markedDoneAt(), t2,  "markedDoneAt");
        assertEq(a.disputedAt(),   t3,  "disputedAt");
        assertEq(a.resolvedAt(),   t4,  "resolvedAt");
        assertEq(a.deadlineDays(), 311, "deadlineDays");
        assertTrue(a.clientWonDispute(),  "clientWonDispute");
        assertTrue(a.clientResponded(),   "clientResponded");
        assertTrue(a.executorResponded(), "executorResponded");
        assertEq(uint256(a.status()), uint256(Agreement.Status.RESOLVED), "final status");
    }

    /// The same slot, with the OTHER verdict and only one party present. A
    /// mask that happens to work when every flag ends up true says nothing.
    function testTheFalseVerdictAndTheSilentPartyAreAlsoKept() public {
        uint256 t0 = 1_800_000_000;
        vm.warp(t0);
        Agreement a = _fundedClone(1);

        vm.prank(DIAMOND);
        a.setArbiter(DIAMOND);

        vm.warp(t0 + 60);
        vm.prank(EXECUTOR);
        a.activate();

        vm.warp(t0 + 120);
        vm.prank(EXECUTOR);
        a.raiseDispute();

        vm.warp(t0 + 180);
        vm.prank(DIAMOND);
        a.resolveDispute(false);

        assertFalse(a.clientWonDispute(),  "clientWonDispute must stay false");
        assertFalse(a.clientResponded(),   "the client never showed up");
        assertTrue(a.executorResponded(),  "the executor raised it, so they showed up");
        assertEq(a.fundedAt(),     t0,       "fundedAt");
        assertEq(a.activatedAt(),  t0 + 60,  "activatedAt");
        assertEq(a.markedDoneAt(), 0,        "markedDoneAt was never set");
        assertEq(a.disputedAt(),   t0 + 120, "disputedAt");
        assertEq(a.resolvedAt(),   t0 + 180, "resolvedAt");
        assertEq(a.deadlineDays(), 1,        "deadlineDays");
    }

    /// getDetails() is a second reader of the same slot, and it has its own
    /// copy of the widening. It must agree with the single-field getters
    /// field for field.
    function testGetDetailsAgreesWithTheIndividualGetters() public {
        uint256 t0 = 1_800_000_000;
        vm.warp(t0);
        Agreement a = _fundedClone(42);
        vm.warp(t0 + 7);
        vm.prank(EXECUTOR);
        a.activate();
        vm.warp(t0 + 99);
        vm.prank(EXECUTOR);
        a.markDone();

        (
            , , , ,
            ,
            uint256 deadlineDays_,
            uint256 fundedAt_,
            uint256 activatedAt_,
            uint256 markedDoneAt_,
            uint256 disputedAt_,
            uint256 resolvedAt_,
            Agreement.Status status_
        ) = a.getDetails();

        assertEq(deadlineDays_, a.deadlineDays(), "deadlineDays");
        assertEq(fundedAt_,     a.fundedAt(),     "fundedAt");
        assertEq(activatedAt_,  a.activatedAt(),  "activatedAt");
        assertEq(markedDoneAt_, a.markedDoneAt(), "markedDoneAt");
        assertEq(disputedAt_,   a.disputedAt(),   "disputedAt");
        assertEq(resolvedAt_,   a.resolvedAt(),   "resolvedAt");
        assertEq(uint256(status_), uint256(a.status()), "status");

        assertEq(deadlineDays_, 42,     "deadlineDays value");
        assertEq(fundedAt_,     t0,     "fundedAt value");
        assertEq(activatedAt_,  t0 + 7, "activatedAt value");
        assertEq(markedDoneAt_, t0 + 99, "markedDoneAt value");
    }

    /// The finalisation pair lives in the same slot and has no getter of its
    /// own: it is observable only through status() sticking after the deal is
    /// over. A clobbered `_finalStatus` would show up here as the wrong final
    /// status, a clobbered `_finalized` as a status that keeps moving.
    function testTheFinalStatusSticksAfterTheDealIsOver() public {
        uint256 t0 = 1_800_000_000;
        vm.warp(t0);
        Agreement a = _fundedClone(3);
        vm.prank(EXECUTOR);
        a.activate();
        vm.prank(EXECUTOR);
        a.markDone();

        vm.warp(t0 + 3 days);
        a.triggerAutoApprove();

        assertEq(uint256(a.status()), uint256(Agreement.Status.COMPLETED), "final status");

        // Far past every window the live status() would have walked.
        vm.warp(t0 + 400 days);
        assertEq(uint256(a.status()), uint256(Agreement.Status.COMPLETED), "status moved after finalisation");

        vm.prank(CLIENT);
        vm.expectRevert(Agreement.AlreadyFinalized.selector);
        a.raiseDispute();
    }
}

// ============================================================
// 4. THE SLOT ITSELF
// ============================================================

contract AgreementPackedSlotTest is PackingFixture {
    /// The slot number is a LITERAL fixed by a person, not read back out of
    /// the layout under test. That is the whole value of this file: a check
    /// that derived "where the fields are" from the same artifact it is
    /// checking would agree with itself no matter where they moved to.
    ///
    /// Its independent source is script/agreement-layout.snapshot, which a
    /// human reviews and updates on purpose.
    uint256 constant PACKED_SLOT = 10;

    /// One word holds all eleven values, and the two words either side of it
    /// hold what they are supposed to hold.
    ///
    /// This exists because of a real mistake made while writing this change.
    /// The packed group was first declared after `factory`, an address with
    /// twelve spare bytes, and solc quietly split it across TWO slots -- two
    /// of the timestamps riding along with the factory address and the other
    /// nine in the next word. Everything still worked, every other test in
    /// this file passed, and `forge inspect` was the only thing that said so.
    /// A design whose whole claim is "one slot" needs a test that fails when
    /// it is two.
    function testAllElevenValuesLiveInOneWord() public {
        uint256 t0 = 1_800_000_000;
        uint256 t1 = t0 + 1;
        uint256 t2 = t1 + 12 hours;
        uint256 t3 = t2 + 3 hours;
        uint256 t4 = t3 + 5 hours;

        vm.warp(t0);
        Agreement a = _fundedClone(311);

        vm.prank(DIAMOND);
        a.setArbiter(DIAMOND);

        vm.warp(t1);
        vm.prank(EXECUTOR);
        a.activate();
        vm.warp(t2);
        vm.prank(EXECUTOR);
        a.markDone();
        vm.warp(t3);
        vm.prank(CLIENT);
        a.raiseDispute();
        vm.prank(EXECUTOR);
        a.respondToDispute();
        vm.warp(t4);
        vm.prank(DIAMOND);
        a.resolveDispute(true);

        uint256 w = uint256(vm.load(address(a), bytes32(PACKED_SLOT)));

        assertEq(uint256(uint40(w)),          t0,  "fundedAt at byte 0");
        assertEq(uint256(uint40(w >> 40)),    t1,  "activatedAt at byte 5");
        assertEq(uint256(uint40(w >> 80)),    t2,  "markedDoneAt at byte 10");
        assertEq(uint256(uint40(w >> 120)),   t3,  "disputedAt at byte 15");
        assertEq(uint256(uint40(w >> 160)),   t4,  "resolvedAt at byte 20");
        assertEq(uint256(uint8(w >> 200)),    1,   "clientWonDispute at byte 25");
        assertEq(uint256(uint8(w >> 208)),    1,   "_finalized at byte 26");
        assertEq(uint256(uint8(w >> 216)),
                 uint256(Agreement.Status.RESOLVED),  "_finalStatus at byte 27");
        assertEq(uint256(uint8(w >> 224)),    1,   "clientResponded at byte 28");
        assertEq(uint256(uint8(w >> 232)),    1,   "executorResponded at byte 29");
        assertEq(uint256(uint16(w >> 240)),   311, "deadlineDays at byte 30");

        // Thirty-two bytes accounted for, and nothing has spilled either way.
        // The word before is `amount`; the word after is the header of the
        // `terms` string, which for a 19-byte literal is 2*length+... -- read
        // as "not one of the contract's own" rather than decoded.
        assertEq(uint256(vm.load(address(a), bytes32(uint256(PACKED_SLOT - 1)))), AMOUNT,
                 "the word before the packed slot is no longer `amount`");
        assertTrue(uint256(vm.load(address(a), bytes32(uint256(PACKED_SLOT + 1)))) != 0,
                   "the word after the packed slot is no longer `terms`");
    }
}
