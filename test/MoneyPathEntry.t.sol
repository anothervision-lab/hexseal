// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  Money path, part 1 — the way in
// ============================================================
//
// Four ways money enters an escrow. For each one the question is the same and
// is answered in token balances, never in intent:
//   how much left the wallet, how much reached the clone, how much was kept
//   as fee, and does the diamond still hold exactly what it books.

import "./MoneyPathBase.sol";

contract MoneyPathEntryTest is MoneyPathBase {

    // ------------------------------------------------------------
    //  1. Job board: client posts, executor applies, client accepts
    // ------------------------------------------------------------

    function testJobBoardEntryAddsUpToTheCent() public {
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore    = usdc.balanceOf(feeRecipient);

        vm.prank(client);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob(
            "t", "d", AMOUNT, DEADLINE, TERMS, 0
        );

        // Posting takes amount + fee up front and holds both on the diamond.
        assertEq(clientBefore - usdc.balanceOf(client), AMOUNT + AMOUNT_FEE, "posting cost");
        assertEq(usdc.balanceOf(address(diamond)), AMOUNT + AMOUNT_FEE, "held on the diamond");
        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "nothing to the treasury yet");
        _assertJobFundsSlot(jobId, AMOUNT);
        assertEq(JobBoardFacet(address(diamond)).getJobFeeHeld(jobId), AMOUNT_FEE);
        _assertDiamondBalances("after mintJob");

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        vm.prank(client);
        Agreement a = Agreement(JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor));

        // Hiring moves the body to the clone and the fee to the treasury.
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "clone holds the deal body");
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, AMOUNT_FEE, "treasury got the fee");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond keeps nothing");
        assertEq(clientBefore - usdc.balanceOf(client), AMOUNT + AMOUNT_FEE, "client paid once");
        assertEq(uint8(a.status()), uint8(Agreement.Status.FUNDED));
        _assertDiamondBalances("after acceptApplicant");
    }

    // ------------------------------------------------------------
    //  2. Service board: executor posts, client requests, executor accepts
    // ------------------------------------------------------------

    function testServiceBoardEntryAddsUpToTheCent() public {
        uint256 execBefore   = usdc.balanceOf(executor);
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore    = usdc.balanceOf(feeRecipient);

        vm.prank(executor);
        uint256 svcId = ServiceBoardFacet(address(diamond)).mintService("t", "d", AMOUNT, DEADLINE, 0);

        // Listing costs the executor a flat floor, paid straight through.
        assertEq(execBefore - usdc.balanceOf(executor), FEE_FLOOR, "listing costs the floor");
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, FEE_FLOOR, "and goes straight out");
        assertEq(usdc.balanceOf(address(diamond)), 0, "listing money never sits on the diamond");
        _assertDiamondBalances("after mintService");

        vm.prank(client);
        uint256 reqId = ServiceBoardFacet(address(diamond)).requestService(
            svcId, AMOUNT, DEADLINE, TERMS, 0
        );

        assertEq(clientBefore - usdc.balanceOf(client), AMOUNT + AMOUNT_FEE, "request cost");
        assertEq(usdc.balanceOf(address(diamond)), AMOUNT + AMOUNT_FEE, "held pending the answer");
        assertEq(ServiceBoardFacet(address(diamond)).getRequestFunds(reqId), AMOUNT);
        assertEq(ServiceBoardFacet(address(diamond)).getRequestFeeHeld(reqId), AMOUNT_FEE);
        _assertDiamondBalances("after requestService");

        vm.prank(executor);
        Agreement a = Agreement(ServiceBoardFacet(address(diamond)).acceptRequest(reqId));

        assertEq(usdc.balanceOf(address(a)), AMOUNT, "clone holds the deal body");
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, FEE_FLOOR + AMOUNT_FEE, "listing + deal fee");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond keeps nothing");
        _assertDiamondBalances("after acceptRequest");
    }

    // ------------------------------------------------------------
    //  3. Direct hire, one transaction
    // ------------------------------------------------------------

    function testDirectHireInOneTransactionAddsUp() public {
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore    = usdc.balanceOf(feeRecipient);

        Agreement a = _hireDirectly(AMOUNT);

        assertEq(usdc.balanceOf(address(a)), AMOUNT, "clone funded");
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, AMOUNT_FEE, "fee delivered");
        assertEq(clientBefore - usdc.balanceOf(client), AMOUNT + AMOUNT_FEE, "client paid once");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond is a pass-through here");
        assertEq(uint8(a.status()), uint8(Agreement.Status.FUNDED));
        _assertDiamondBalances("after deployAndFund");
    }

    // ------------------------------------------------------------
    //  4. The fourth way in is shut, and that is the whole repair
    // ------------------------------------------------------------
    //
    // `deployAgreement` used to be a fourth entrance: it took the percentage
    // fee and left the clone unfunded. There was no way back out of that
    // state -- the activation timeout answers "not funded", the registry
    // counts the CREATED clone as a live pair so the same two people cannot be
    // matched through a board again, and the only key was to put the FULL
    // amount into a contract nobody would ever activate and wait two days.
    //
    // It takes the diamond alone now. The three entrances above all create and
    // fund in ONE transaction, so the state with no exit stopped being
    // reachable rather than being given a door.

    /// Measured in balances, like everything else here: the wallet is refused
    /// by name and nothing moves.
    function testTheUnfundedDirectHireIsRefusedAndNobodyIsCharged() public {
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore    = usdc.balanceOf(feeRecipient);

        vm.prank(client);
        vm.expectRevert(FactoryFacet.NotDiamond.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, DEADLINE, TERMS, 0
        );

        assertEq(usdc.balanceOf(client), clientBefore, "not a cent left the wallet");
        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "and nothing was earned");
        _assertDiamondBalances("after the refused deployAgreement");
    }

    /// The consequence that made it a trap rather than a nuisance: no unfunded
    /// clone means the pair is never locked, and the same two people can still
    /// be hired through a board -- which funds in the same transaction.
    function testARefusedDirectHireLeavesThePairFreeToHireThroughABoard() public {
        vm.prank(client);
        vm.expectRevert(FactoryFacet.NotDiamond.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, DEADLINE, TERMS, 0
        );

        assertFalse(
            RegistryFacet(address(diamond)).hasActivePair(client, executor),
            "no clone was created, so no pair was locked"
        );

        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        assertEq(uint8(a.status()), uint8(Agreement.Status.FUNDED), "the board still hires the pair");
        assertEq(usdc.balanceOf(address(a)), AMOUNT, "and funds the clone in the same transaction");
        _assertDiamondBalances("after the board hire");
    }

    // ------------------------------------------------------------
    //  5. The floor bites the small deal on every entrance
    // ------------------------------------------------------------

    function testSmallDealPaysTheFloorNotThePercentage() public {
        uint256 small = 10_000_000; // $10; 5% would be $0.50, floor is $1
        assertEq(FactoryFacet(address(diamond)).quoteFee(small), FEE_FLOOR, "floor wins under $20");

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        Agreement a = _hireDirectly(small);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, FEE_FLOOR, "the floor is what was taken");
        assertEq(usdc.balanceOf(address(a)), small, "and the body is untouched by it");
    }

    // ------------------------------------------------------------
    //  6. Same deal, three doors, same price
    // ------------------------------------------------------------

    /// The three entrances must not disagree about what a $100 deal costs.
    /// A divergence here would be invisible to anyone who only ever used one.
    function testAllThreeDoorsChargeTheSameForTheSameDeal() public {
        uint256 f0 = usdc.balanceOf(feeRecipient);
        _hireThroughJobBoard(AMOUNT);
        uint256 viaJobBoard = usdc.balanceOf(feeRecipient) - f0;

        // A fresh pair, because the registry allows one live deal per pair.
        address client2 = address(0x11);
        usdc.mint(client2, BAG);
        vm.prank(client2); usdc.approve(address(diamond), type(uint256).max);

        uint256 f1 = usdc.balanceOf(feeRecipient);
        vm.prank(executor);
        uint256 svcId = ServiceBoardFacet(address(diamond)).mintService("t", "d", AMOUNT, DEADLINE, 0);
        uint256 listing = usdc.balanceOf(feeRecipient) - f1;
        vm.prank(client2);
        uint256 reqId = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(reqId);
        uint256 viaServiceBoard = usdc.balanceOf(feeRecipient) - f1 - listing;

        address client3 = address(0x12);
        usdc.mint(client3, BAG);
        vm.prank(client3); usdc.approve(address(diamond), type(uint256).max);
        uint256 f2 = usdc.balanceOf(feeRecipient);
        vm.prank(client3);
        FactoryFacet(address(diamond)).deployAndFund(client3, executor, AMOUNT, DEADLINE, TERMS, 0);
        uint256 viaDirect = usdc.balanceOf(feeRecipient) - f2;

        assertEq(viaJobBoard, AMOUNT_FEE, "job board");
        assertEq(viaServiceBoard, AMOUNT_FEE, "service board");
        assertEq(viaDirect, AMOUNT_FEE, "direct hire");
        assertEq(listing, FEE_FLOOR, "the service board charges the executor a listing floor on top");
    }
}
