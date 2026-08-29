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

        uint256 pot = AMOUNT;
        uint256 fee = pot * 300 / 10_000;          // 3%
        uint256 toArbiter  = fee * 8_000 / 10_000; // 80%
        uint256 toTreasury = fee - toArbiter;      // by subtraction, never a second share
        assertEq(a.disputeFee(), fee, "3% of the pot");

        Snap memory b = _snap(a);
        _submitAndFinalize(a, true);
        Snap memory s = _snap(a);

        assertEq(s.c - b.c, pot - fee, "client got the pot less the fee");
        assertEq(s.e, b.e, "executor nothing");
        assertEq(s.clone_, 0, "clone empty");
        assertEq(s.dia - b.dia, fee, "the fee is on the diamond");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), toArbiter);
        assertEq(ArbiterRegistryFacet(address(diamond)).getTreasurySlice(), toTreasury);
        assertEq(toArbiter + toTreasury, fee, "the two shares are the whole fee");
        _assertDiamondBalances("after resolve for client");

        // And both halves can actually be taken out.
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).withdrawArbiterReward();
        ArbiterRegistryFacet(address(diamond)).withdrawTreasurySlice();
        assertEq(usdc.balanceOf(arbiterAddr) - b.arb, toArbiter, "arbiter paid out");
        assertEq(usdc.balanceOf(feeRecipient) - b.fee, toTreasury, "treasury paid out");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond back to nothing");
        _assertDiamondBalances("after both withdrawals");
    }

    function testDisputeResolvedForTheExecutorSplitsTheSameWay() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor); a.raiseDispute();
        _claimByArbiter(a);

        uint256 fee = AMOUNT * 300 / 10_000;
        Snap memory b = _snap(a);
        _submitAndFinalize(a, false);
        Snap memory s = _snap(a);

        assertEq(s.e - b.e, AMOUNT - fee, "executor got the pot less the fee");
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
        vm.prank(client); a.raiseDispute();
        vm.prank(executor); a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        Snap memory b = _snap(a);
        vm.prank(client); a.triggerArbiterTimeout();
        Snap memory s = _snap(a);

        assertEq(s.e - b.e, AMOUNT / 2, "half to the executor");
        assertEq(s.c - b.c, AMOUNT - AMOUNT / 2, "the rest to the client");
        assertEq(s.clone_, 0, "clone empty");
        assertEq(s.dia, b.dia, "no fee is taken when nobody judged");
        _assertDiamondBalances("after unclaimed timeout, both present");
    }

    function testUnclaimedTimeoutGivesTheSilentPartyAQuarter() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();   // executor never responds
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        Snap memory b = _snap(a);
        vm.prank(client); a.triggerArbiterTimeout();
        Snap memory s = _snap(a);

        assertEq(s.e - b.e, AMOUNT / 4, "a quarter to the silent executor");
        assertEq(s.c - b.c, AMOUNT - AMOUNT / 4, "the rest to the one who showed up");
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

        assertEq((s.c - b.c) + (s.e - b.e), odd, "every unit landed somewhere");
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
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        Snap memory b = _snap(a);
        vm.prank(client); a.triggerArbiterTimeout();
        Snap memory s = _snap(a);

        assertEq(s.c - b.c, AMOUNT, "the whole pot to the client");
        assertEq(s.e, b.e, "executor nothing, even though both showed up");
        assertEq(s.clone_, 0, "clone empty");
        assertEq(s.dia, b.dia, "no fee: nobody delivered a verdict");
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
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond keeps nothing");
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
        assertEq(usdc.balanceOf(address(diamond)), 0);
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
