// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  Money path, part 3 — the way out
// ============================================================
//
// Eight terminal states. For each: who got how much, and is the clone empty
// afterwards. The clone has no rescue function and is nailed to its
// implementation for life, so anything left in it is left forever.

import "./MoneyPathBase.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

contract MoneyPathExitsTest is MoneyPathBase {

    struct Snap { uint256 c; uint256 e; uint256 arb; uint256 fee; uint256 clone_; uint256 dia; }

    function _snap(Agreement a) internal view returns (Snap memory s) {
        s.c      = usdc.balanceOf(client);
        s.e      = usdc.balanceOf(executor);
        s.arb    = usdc.balanceOf(arbiterAddr);
        s.fee    = usdc.balanceOf(feeRecipient);
        s.clone_ = usdc.balanceOf(address(a));
        s.dia    = usdc.balanceOf(address(diamond));
    }

    // ------------------------------------------------------------
    //  1. release
    // ------------------------------------------------------------

    function testReleaseEmptiesTheCloneIntoTheExecutor() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor); a.markDone();

        Snap memory b = _snap(a);
        vm.prank(client); a.release();
        Snap memory s = _snap(a);

        assertEq(s.e - b.e, AMOUNT, "executor took the whole body");
        assertEq(s.c, b.c, "client got nothing back");
        assertEq(s.clone_, 0, "clone empty");
        assertEq(s.fee, b.fee, "no second fee at the exit");
        _assertDiamondBalances("after release");
    }

    // ------------------------------------------------------------
    //  2. auto-approve
    // ------------------------------------------------------------

    function testAutoApproveEmptiesTheCloneIntoTheExecutor() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor); a.markDone();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);

        Snap memory b = _snap(a);
        vm.prank(stranger); a.triggerAutoApprove(); // anyone may push it
        Snap memory s = _snap(a);

        assertEq(s.e - b.e, AMOUNT, "executor paid");
        assertEq(s.clone_, 0, "clone empty");
        _assertDiamondBalances("after auto-approve");
    }

    // ------------------------------------------------------------
    //  3. activation timeout
    // ------------------------------------------------------------

    function testActivationTimeoutReturnsEverythingToTheClient() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);

        Snap memory b = _snap(a);
        vm.prank(client); a.triggerActivationTimeout();
        Snap memory s = _snap(a);

        assertEq(s.c - b.c, AMOUNT, "body back");
        assertEq(s.e, b.e, "executor got nothing");
        assertEq(s.clone_, 0, "clone empty");
        // The fee is NOT returned: it was earned when the deal was created.
        assertEq(s.fee, b.fee, "the fee stays where it went");
        _assertDiamondBalances("after activation timeout");
    }

    // ------------------------------------------------------------
    //  4. deadline timeout
    // ------------------------------------------------------------

    function testDeadlineTimeoutReturnsBodyAndHangingProposal() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _proposeExtra(a, 25_000_000);
        vm.warp(block.timestamp + DEADLINE * 1 days + DEADLINE_GRACE + 1);

        Snap memory b = _snap(a);
        vm.prank(executor); a.triggerDeadlineTimeout(); // either party may
        Snap memory s = _snap(a);

        assertEq(s.c - b.c, AMOUNT + 25_000_000 + _extraFee(25_000_000), "body, proposal and its held fee back");
        assertEq(s.clone_, 0, "clone empty");
        _assertDiamondBalances("after deadline timeout");
    }

    // ------------------------------------------------------------
    //  5-6. resolved dispute, both ways
    // ------------------------------------------------------------

    function testDisputeResolvedForTheClientSplitsPotAndFeeExactly() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);

        // ⚠️ THE THREE FIGURES BELOW ARE HAND LITERALS SINCE 20 OCTOBER 2026
        // AND USED TO BE RECOMPUTED FROM THE RATES. On a $100 pot 3% is $3,
        // under the fee's new ten dollar FLOOR, so the floor decides; and the
        // judge takes the WHOLE fee, because the treasury takes nothing out of
        // arbitration (`ARBITER_SHARE_BPS` = 10 000). Recomputing `pot * 300 /
        // 10_000` here would now be a second copy of a formula that no longer
        // decides the answer.
        uint256 pot = AMOUNT;
        uint256 fee        = 10_000_000;   // max($10 floor, 3% of $100)
        uint256 toArbiter  = 10_000_000;   // the whole fee
        uint256 toTreasury =          0;   // fee - toArbiter
        assertEq(a.disputeFee(), fee, "the floor decides on a $100 pot, so the fee is ten dollars");

        // ⚠️ THE BOND THIS CASE CARRIES IS PART OF THE ARITHMETIC NOW
        // (22 September 2026). The snapshot below is taken AFTER the claim, so
        // the arbiter's bond is already on the diamond; finalization sends it
        // home. Without naming it, "the fee is on the diamond" subtracts a
        // larger before from a smaller after and panics on the underflow, which
        // is exactly how this scene failed when the per-case bond landed.
        (uint256 caseBond, ) = ArbiterVaultFacet(address(diamond)).getCaseBond(address(a));
        assertGt(caseBond, 0, "the claim really did cost the arbiter a bond");

        Snap memory b = _snap(a);
        _submitAndFinalize(a, true);
        Snap memory s = _snap(a);

        // ⚠️ THE WHOLE POT, NOT THE POT LESS THE FEE (20 October 2026): the fee
        // left the opener's wallet at the dispute door and never touched the
        // escrow.
        assertEq(s.c - b.c, pot, "client got the whole pot");
        assertEq(s.e, b.e, "executor nothing");
        assertEq(s.clone_, 0, "clone empty");
        // ⚠️ AND THE DIAMOND IS UNCHANGED ACROSS THE SETTLEMENT, because the
        // fee was already there: the snapshot `b` was taken after the dispute
        // was opened. What moves is the bond, going home.
        assertEq(s.dia + caseBond - b.dia, 0, "money arrived at the diamond at the verdict -- the fee was supposed to be there already");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), toArbiter);
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), toTreasury);
        assertEq(toArbiter + toTreasury, fee, "the two shares are the whole fee");
        _assertDiamondBalances("after resolve for client");

        // And the one half there is can actually be taken out.
        vm.prank(arbiterAddr);
        ArbiterVaultFacet(address(diamond)).withdrawArbiterReward();

        // ⚠️ AND THE TREASURY'S DOOR REFUSES, 21 OCTOBER 2026. The line here
        // was a bare `withdrawTreasurySlice()` and it reverted `NothingToPush`,
        // which is the whole of what this scene failed on. The door is written
        // `if (slice == 0) revert NothingToPush()`, and the treasury's share of
        // an arbitration fee has been a named NOUGHT since the owner gave the
        // whole fee to the judge, so on this road there is nothing to push and
        // the refusal is the correct behaviour rather than a fault.
        //
        // Worked out by hand, the retired figures first so the method can be
        // checked. The three literals above were recomputed from the rates
        // until 20 October, and the retired treasury share was a TENTH of the
        // fee (`ARBITER_SHARE_BPS` = 9 000):
        //     the retired fee    100_000_000 x 300 / 10_000 = 3_000_000
        //     to the judge         3_000_000 x 9_000 / 10_000 = 2_700_000
        //     to the treasury      3_000_000 - 2_700_000      =   300_000
        // -- a non-zero slice, which is exactly why a bare call stood here and
        // passed for as long as it did. The same two steps at the live rates,
        // where the floor decides the fee and the share is the whole of it:
        //     the fee            max( 10_000_000, 3_000_000 ) = 10_000_000
        //     to the judge        10_000_000 x 10_000 / 10_000 = 10_000_000
        //     to the treasury     10_000_000 - 10_000_000      =          0
        //
        // ⚠️ THE REFUSAL IS ASSERTED RATHER THAN THE CALL DELETED, because a
        // deleted call is a scene that stops measuring the treasury's door at
        // all: the day a slice reappears on this road, `expectRevert` reds and
        // names it, while an absent call would stay green through it.
        vm.expectRevert(ArbiterRegistryFacet.NothingToPush.selector);
        ArbiterVaultFacet(address(diamond)).withdrawTreasurySlice();
        assertEq(
            usdc.balanceOf(arbiterAddr) - b.arb, toArbiter + caseBond,
            "arbiter paid out, and his bond for this case came back with it"
        );
        assertEq(usdc.balanceOf(feeRecipient) - b.fee, toTreasury, "the treasury was paid out of an arbitration fee");
        assertEq(usdc.balanceOf(address(diamond)), seatBondHeld, "diamond back to nothing");
        _assertDiamondBalances("after both withdrawals");
    }

    function testDisputeResolvedForTheExecutorSplitsTheSameWay() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor); a.raiseDispute();
        _claimByArbiter(a);

        // ⚠️ THE POT IS NOT TOUCHED BY THE FEE SINCE 20 OCTOBER 2026: the
        // opener paid it at the door out of his own wallet. The line below read
        // `AMOUNT - fee`, with `fee` recomputed as 3% of the pot.
        Snap memory b = _snap(a);
        _submitAndFinalize(a, false);
        Snap memory s = _snap(a);

        assertEq(s.e - b.e, AMOUNT, "executor got the whole pot");
        assertEq(s.c, b.c, "client nothing");
        assertEq(s.clone_, 0, "clone empty");
        _assertDiamondBalances("after resolve for executor");
    }

    // ------------------------------------------------------------
    //  7. arbiter timeout with nobody on the case
    // ------------------------------------------------------------

    function testUnclaimedTimeoutSplitsWhenBothShowedUpAndTakesNoFee() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _handIn(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(executor); a.respondToDispute();

        // ⚠️ THE QUOTE IS READ WHILE THE POT IS STILL THERE, and that is not a
        // tidiness point. `Agreement.disputeFee()` is `max( 3% of _pot(), the
        // floor )`, so once the timeout has emptied the clone it answers the
        // FLOOR on every deal that ever existed -- it would agree with ten
        // dollars here whatever the pot had been, and the claim "the floor
        // decides ON A $100 POT" would be green without being measured. Read
        // before the exit, the same line fails the day 3% of this pot rises
        // above the floor.
        uint256 doorCharge = 10_000_000;        // max( $10 floor, 3% of $100 = $3 )
        assertEq(a.disputeFee(), doorCharge, "the floor decides on a $100 pot, so the door charge is ten dollars");
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        Snap memory b = _snap(a);
        vm.prank(client); a.triggerArbiterTimeout();
        Snap memory s = _snap(a);

        // ⚠️ THE CLIENT'S HALF IS HIS HALF PLUS HIS OWN TEN DOLLARS BACK,
        // 21 OCTOBER 2026, and the line here read `AMOUNT - AMOUNT / 2`. The
        // dispute fee is taken at the DISPUTE'S DOOR since 20 October and it is
        // returned when no verdict was delivered (the owner's decision), and
        // the client is the one who opened this dispute. The snapshot `b` is
        // taken AFTER the door charged him, so the charge coming home shows up
        // as a gain here -- the same reason the odd-pot scene below carries
        // `odd + 10_000_000`, where the rule is written out in full.
        //
        // Worked out by hand, retired figure first so the method can be
        // checked. Under the rule that stood until 20 October the fee was taken
        // out of the POT at the settlement and no settlement happens on a
        // timeout, so nothing was charged and nothing came back:
        //     the client's half   100_000_000 - 100_000_000 / 2 = 50_000_000
        // -- the literal that stood here, reproduced from the retired rule. The
        // same half plus the charge the door took and the timeout returns,
        // where the charge is `max( 3% of the pot, $10 )` and the floor decides
        // because 3% of $100 is 3_000_000:
        //     the door charge     max( 10_000_000, 3_000_000 ) = 10_000_000
        //     the client's half   100_000_000 - 50_000_000     = 50_000_000
        //     what he receives     50_000_000 + 10_000_000     = 60_000_000
        //
        // ⚠️ AND THE CHARGE IS NAMED AS ITS OWN TERM RATHER THAN FOLDED INTO
        // ONE LITERAL OF 60_000_000, because the two halves answer to different
        // rules: the half is the pot's split and the ten dollars is the door's
        // refund, and a single figure would stay green if one grew while the
        // other shrank by as much.
        assertEq(s.e - b.e, AMOUNT / 2, "half to the executor");
        assertEq(s.c - b.c, (AMOUNT - AMOUNT / 2) + doorCharge, "the rest to the client, and his own door charge home with it");
        assertEq(s.clone_, 0, "clone empty");
        // ⚠️ AND THE DIAMOND IS LIGHTER BY EXACTLY THE CHARGE IT GAVE BACK, not
        // unchanged: the line here read `assertEq(s.dia, b.dia, "no fee is
        // taken when nobody judged")`, which was true while the fee was taken
        // at the settlement and the diamond never held it before one. It holds
        // the charge from the door now, so "no fee is taken" is measured as the
        // charge LEAVING rather than as the diamond standing still.
        assertEq(b.dia - s.dia, doorCharge, "the door charge did not leave the diamond on a road with no verdict -- a fee was kept where nobody judged");
        _assertDiamondBalances("after unclaimed timeout, both present");
    }

    function testUnclaimedTimeoutGivesTheSilentPartyAQuarter() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _handIn(a);
        vm.prank(client); a.raiseDispute();   // executor never responds
        // Read while the pot still stands -- see the note in the scene above on
        // why an emptied clone quotes the floor for any deal.
        uint256 doorCharge = 10_000_000;        // max( $10 floor, 3% of $100 = $3 )
        assertEq(a.disputeFee(), doorCharge, "the floor decides on a $100 pot, so the door charge is ten dollars");
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        Snap memory b = _snap(a);
        vm.prank(client); a.triggerArbiterTimeout();
        Snap memory s = _snap(a);

        // ⚠️ THE SAME CORRECTION AS THE SCENE ABOVE, 21 OCTOBER 2026: the line
        // read `AMOUNT - AMOUNT / 4`, and the client who opened the dispute
        // gets his own door charge back on a road with no verdict.
        //
        // Worked out by hand, retired figure first:
        //     the client's share  100_000_000 - 100_000_000 / 4 = 75_000_000
        // -- the literal that stood here. And with the charge coming home:
        //     the door charge     max( 10_000_000, 3_000_000 )  = 10_000_000
        //     what he receives     75_000_000 + 10_000_000      = 85_000_000
        //
        // ⚠️ AND NOTE WHICH PARTY IS WHICH HERE, because it is the one thing
        // this scene and the one above do not share: the SILENT party is the
        // executor and the man who showed up is the client, who is also the
        // opener. If the opener were ever the silent one, the charge would come
        // home to the other column and this line would be the wrong line --
        // which is why the refund is asserted against the opener by name
        // rather than against "the larger share".
        assertEq(s.e - b.e, AMOUNT / 4, "a quarter to the silent executor");
        assertEq(s.c - b.c, (AMOUNT - AMOUNT / 4) + doorCharge, "the rest to the one who showed up, and his own door charge home with it");
        assertEq(s.clone_, 0, "clone empty");
    }

    /// Odd pot: subtraction, not a second percentage, so no unit is lost.
    function testTheSplitLosesNoUnitOnAnOddPot() public {
        uint256 odd = 100_000_003;
        (Agreement a, ) = _hireThroughJobBoard(odd);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(executor); a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        Snap memory b = _snap(a);
        vm.prank(client); a.triggerArbiterTimeout();
        Snap memory s = _snap(a);

        // ⚠️ THE SNAPSHOT IS TAKEN AFTER THE DISPUTE WAS OPENED, so the door
        // charge is already out of the client's purse; the timeout gives it
        // back, which is why this sum is the pot PLUS the charge. The identity
        // the scene is for -- that no base unit of an odd pot is lost -- is
        // unchanged: the charge is a round ten dollars and cannot hide a unit.
        assertEq(
            (s.c - b.c) + (s.e - b.e), odd + 10_000_000,
            "every unit landed somewhere -- the odd pot and the ten dollar door charge coming home"
        );
        assertEq(s.clone_, 0, "clone empty");
    }

    // ------------------------------------------------------------
    //  8. arbiter timeout after someone took the case
    // ------------------------------------------------------------

    function testTimeoutAfterAClaimReturnsTheWholePotToTheClient() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(executor); a.respondToDispute();
        _claimByArbiter(a);

        // ⚠️ BOTH FIGURES ARE READ BEFORE THE EXIT, and for two different
        // reasons that would each have produced a green line that measures
        // nothing. `disputeFee()` answers the FLOOR once the clone is empty, on
        // any deal, so after the timeout it agrees with ten dollars whatever
        // the pot was. And `getCaseBond` is ZERO after the timeout, because the
        // bond is precisely what the timeout sends home -- so an `assertGt`
        // taken afterwards would red, and a `caseBond` taken afterwards would
        // silently make the diamond's two-term line a one-term line.
        uint256 doorCharge = 10_000_000;        // max( $10 floor, 3% of $100 = $3 )
        assertEq(a.disputeFee(), doorCharge, "the floor decides on a $100 pot, so the door charge is ten dollars");
        (uint256 caseBond, ) = ArbiterVaultFacet(address(diamond)).getCaseBond(address(a));
        assertGt(caseBond, 0, "the claim really did cost the arbiter a bond, so the diamond's line below has two terms and not one");

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        Snap memory b = _snap(a);
        vm.prank(client); a.triggerArbiterTimeout();
        Snap memory s = _snap(a);

        // ⚠️ THE WHOLE POT PLUS THE DOOR CHARGE, 21 OCTOBER 2026, and the line
        // read a bare `AMOUNT`. A case was CLAIMED on this road and still no
        // verdict was delivered, so the charge comes home exactly as it does
        // where nobody claimed -- the refund answers to the absence of a
        // VERDICT, not to the absence of a judge.
        //
        // Worked out by hand, retired figure first:
        //     the whole pot                      = 100_000_000
        // -- the literal that stood here, and it reproduces because the retired
        // fee came out of the pot only at a settlement. With the charge:
        //     the door charge  max( 10_000_000, 3_000_000 ) =  10_000_000
        //     what he receives 100_000_000 + 10_000_000     = 110_000_000
        //
        // ⚠️ AND THE BOND IS THE TERM THAT MAKES THIS ROAD DIFFER FROM THE TWO
        // ABOVE -- BUT NOT IN THE DIAMOND'S BALANCE, which is the thing I got
        // wrong on the first pass and the run corrected. The bond is NOT pushed
        // out by the timeout: `withdrawCaseBond` is a door the arbiter comes to
        // himself, gated on "nobody is judging this deal", and all the timeout
        // does is clear the claim so that door opens. So the bond stays on the
        // diamond as USDC, still booked to him, and the diamond is lighter by
        // the door charge ALONE -- the same figure as on the two roads above.
        //
        // The first version of this line expected `doorCharge + caseBond` and
        // red at 10000000 != 30000000, which is how the bond's size was
        // measured rather than assumed: 30_000_000 - 10_000_000 = 20_000_000,
        // and that agrees with the hand figure for a bond of `min( the flat
        // $20, the pot )` on a $100 pot. It is asserted below rather than left
        // as a subtraction, so the two claims -- what left and what stayed --
        // are separate lines and a bond that started being pushed would red on
        // the second rather than be absorbed by the first.
        assertEq(s.c - b.c, AMOUNT + doorCharge, "the whole pot to the client, and his own door charge home with it");
        assertEq(s.e, b.e, "executor nothing, even though both showed up");
        assertEq(s.clone_, 0, "clone empty");
        // ⚠️ THE LINE HERE WAS `assertEq(s.dia, b.dia, "no fee: nobody
        // delivered a verdict")`. "No fee" is still the claim; it is measured
        // as the charge and the bond LEAVING now, because the diamond held both
        // before the snapshot rather than neither.
        assertEq(caseBond, 20_000_000, "arithmetic: the bond this case took is not min( the flat $20, the $100 pot )");
        assertEq(b.dia - s.dia, doorCharge, "the diamond did not give back exactly the door charge -- either a fee was kept where nobody judged, or the bond was pushed out as well");
        // And the bond is still there, still his, and now collectable: the
        // claim is gone, which is the only thing `withdrawCaseBond` asks.
        (uint256 bondAfter, address bondOwner) = ArbiterVaultFacet(address(diamond)).getCaseBond(address(a));
        assertEq(bondAfter, caseBond,   "the timeout spent or moved the bond instead of leaving it for its owner to collect");
        assertEq(bondOwner, arbiterAddr, "the bond stopped being booked against the arbiter who posted it");
        _assertDiamondBalances("after claimed timeout");
    }

    // ------------------------------------------------------------
    //  9. board exits: cancel, reject, supersede
    // ------------------------------------------------------------

    function testCancellingAPostingReturnsEverythingButTheFloor() public {
        uint256 c0 = usdc.balanceOf(client);
        uint256 f0 = usdc.balanceOf(feeRecipient);

        vm.prank(client);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        assertEq(c0 - usdc.balanceOf(client), FEE_FLOOR, "the client is out exactly the floor");
        assertEq(usdc.balanceOf(feeRecipient) - f0, FEE_FLOOR, "and the floor is what the protocol kept");
        assertEq(usdc.balanceOf(address(diamond)), seatBondHeld, "diamond keeps nothing beyond the arbiter's bond");
        _assertDiamondBalances("after cancelJob");
    }

    function testRejectingARequestReturnsEverythingButTheFloor() public {
        vm.prank(executor);
        uint256 svcId = ServiceBoardFacet(address(diamond)).mintService("t", "d", AMOUNT, DEADLINE, 0);

        uint256 c0 = usdc.balanceOf(client);
        uint256 f0 = usdc.balanceOf(feeRecipient);
        vm.prank(client);
        uint256 reqId = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(reqId);

        assertEq(c0 - usdc.balanceOf(client), FEE_FLOOR, "client out exactly the floor");
        assertEq(usdc.balanceOf(feeRecipient) - f0, FEE_FLOOR, "protocol kept the floor");
        assertEq(usdc.balanceOf(address(diamond)), seatBondHeld);
        _assertDiamondBalances("after rejectRequest");
    }

    /// A deal smaller than the floor loses the whole fee it paid, and no more.
    function testASmallCancelledPostingBurnsItsWholeFeeAndNoMore() public {
        uint256 small = 5_000_000; // $5; fee is the $1 floor
        uint256 c0 = usdc.balanceOf(client);

        vm.prank(client);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", small, DEADLINE, TERMS, 0);
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        assertEq(c0 - usdc.balanceOf(client), FEE_FLOOR, "burnt the floor, not the body");
        _assertDiamondBalances("after small cancel");
    }
}
