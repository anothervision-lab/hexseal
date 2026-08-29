// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  Money path, part 5 — the dispute, and the whole diamond at once
// ============================================================
//
// The dispute is where three pots of money meet: the escrow, the 3% levy on
// it, and the top-up a party pays to make the case worth an arbiter's time.
// Every number below is a balance or a stored counter, and the last scene
// checks the identity the whole audit rests on -- the diamond holds exactly
// the sum of what it books, with a real dispute, a real top-up and a treasury
// that refuses, all live at the same time.

import "./MoneyPathBase.sol";

contract MoneyPathDisputeTest is MoneyPathBase {

    uint256 constant ARBITER_FLOOR = 10_000_000; // $10, ArbiterRegistryFacet's default

    // ------------------------------------------------------------
    //  1. The levy: 3%, capped, split 80/20 with nothing lost
    // ------------------------------------------------------------

    function testTheLevyIsThreePercentOfTheWholePotIncludingExtras() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 200_000_000);
        vm.prank(executor); a.acceptExtra(id);

        assertEq(a.totalPayout(), 300_000_000, "pot is body plus accepted extras");
        assertEq(a.disputeFee(), 9_000_000, "3% of $300, not of $100");
    }

    function testTheLevyIsCappedAtFiveHundredDollars() public {
        uint256 huge = 50_000_000_000; // $50 000; 3% would be $1500
        Agreement a = _hireDirectly(huge);
        assertEq(a.disputeFee(), 500_000_000, "capped at $500");
    }

    function testTheArbiterFloorNeedsNoTopUpOnceThePotIsBigEnough() public {
        // 80% of 3% reaches $10 when the pot reaches $416.67.
        Agreement small = _hireDirectly(100_000_000); // $100 -> arbiter would get $2.40
        _activate(small);
        vm.prank(client); small.raiseDispute();
        assertEq(
            ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(small)),
            7_600_000,
            "$10 floor less the $2.40 the levy already yields"
        );

        address c2 = address(0x31); usdc.mint(c2, BAG);
        vm.prank(c2); usdc.approve(address(diamond), type(uint256).max);
        vm.prank(c2);
        Agreement big = Agreement(FactoryFacet(address(diamond)).deployAndFund(
            c2, executor, 1_000_000_000, DEADLINE, TERMS, 0)); // $1000 -> arbiter gets $24
        vm.prank(executor); big.activate();
        vm.prank(c2); big.raiseDispute();
        assertEq(
            ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(big)),
            0,
            "big pot needs no top-up at all"
        );
    }

    // ------------------------------------------------------------
    //  2. The paid call, counted end to end
    // ------------------------------------------------------------

    /// Every cent of a $100 dispute with a paid arbiter, from four wallets.
    /// The number worth looking at is the last one: the client WINS and is
    /// still $10.60 down on the deal.
    function testAPaidDisputeCountedFromEveryWallet() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        uint256 topUp = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertEq(topUp, 7_600_000, "$7.60 to reach the $10 floor");

        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));
        assertEq(clientBefore - usdc.balanceOf(client), topUp, "the client paid the top-up");
        assertEq(usdc.balanceOf(address(diamond)), topUp, "and it sits on the diamond");
        _assertDiamondBalances("after fundDispute");

        _claimByArbiter(a);
        _submitAndFinalize(a, true); // the client wins on the merits

        uint256 levy = AMOUNT * 300 / 10_000;        // $3.00
        uint256 arbiterShare = levy * 8_000 / 10_000; // $2.40
        uint256 treasuryShare = levy - arbiterShare;  // $0.60

        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            arbiterShare + topUp,
            "the arbiter is owed exactly the floor"
        );
        assertEq(arbiterShare + topUp, ARBITER_FLOOR, "which is $10 on the nose");
        assertEq(ArbiterRegistryFacet(address(diamond)).getTreasurySlice(), treasuryShare);
        _assertDiamondBalances("after the verdict was executed");

        // The winner's own arithmetic: $100 in, $97 back, $7.60 spent to be heard.
        assertEq(
            usdc.balanceOf(client),
            clientBefore - topUp + (AMOUNT - levy),
            "the client is out the top-up and the levy despite winning"
        );
        assertEq(topUp + levy, 10_600_000, "$10.60 to win a $100 argument");

        // Both owed halves really come out.
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).withdrawArbiterReward();
        ArbiterRegistryFacet(address(diamond)).withdrawTreasurySlice();
        assertEq(usdc.balanceOf(arbiterAddr), ARBITER_FLOOR, "arbiter paid the floor");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond empty");
        _assertDiamondBalances("after withdrawals");
    }

    /// If nobody takes the case, the top-up comes back -- but through a claim,
    /// not a push, so a payer who cannot receive it does not freeze the exit.
    function testAnUnclaimedTopUpComesBackAndABlockedClientDoesNotFreezeTheExit() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        uint256 topUp = 7_600_000;
        usdc.setBlacklisted(client, true);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        // The client cannot receive, and since 26 August 2026 that stops
        // nothing: the exit completes, the silent executor takes their quarter,
        // and both refunds owed to the client become claims. Before that this
        // same call reverted TransferFailed and the deal had no exit left.
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(executor); a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - e0, AMOUNT / 4, "the silent side's quarter went out");
        assertEq(a.undeliveredRefund(), AMOUNT - AMOUNT / 4, "the client's share is a debt on the clone");
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0);
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getRefundableBounty(client),
            topUp,
            "and the top-up is a claim on the diamond"
        );
        _assertDiamondBalances("after an unclaimed, funded dispute timed out");

        // Both are pulled once the token serves them again -- two doors,
        // because the two sums sit in two different contracts.
        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        a.withdrawUndeliveredRefund();
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).withdrawDisputeBounty();

        assertEq(usdc.balanceOf(client) - c0, AMOUNT - AMOUNT / 4 + topUp, "pot share plus the top-up back");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
        _assertDiamondBalances("after both claims were pulled");
    }

    /// Same again with the payer permanently unable to receive: the refund
    /// becomes claimable instead of blocking, and the escrow still empties.
    function testAPermanentlyBlockedPayerGetsAClaimNotADeadlock() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor); a.raiseDispute();
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        usdc.setBlacklisted(executor, true);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        uint256 c0 = usdc.balanceOf(client);
        vm.prank(client); a.triggerArbiterTimeout(); // completes

        // The client showed up nowhere -- the executor raised it -- so the
        // client's quarter is theirs and the executor's three quarters are
        // booked, not handed over. Before 26 August the executor's share was
        // redirected here and the client received the whole $100.
        assertEq(usdc.balanceOf(client) - c0, AMOUNT / 4, "the silent client's quarter, and only that");
        assertEq(a.undeliveredPayout(), AMOUNT - AMOUNT / 4, "the rest is owed to the blocked executor");
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getRefundableBounty(executor),
            7_600_000,
            "the top-up became a claim"
        );
        _assertDiamondBalances("blocked payer, claimable top-up");

        usdc.setBlacklisted(executor, false);
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).withdrawDisputeBounty();
        assertEq(usdc.balanceOf(executor) - e0, 7_600_000, "and it was collectable later");
        _assertDiamondBalances("after the claim was taken");

        // Three doors in this scene, not two: the top-up on the diamond, and
        // the pot share on the clone.
        uint256 e1 = usdc.balanceOf(executor);
        a.withdrawUndeliveredPayout();
        assertEq(usdc.balanceOf(executor) - e1, AMOUNT - AMOUNT / 4, "pot share too");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
    }

    // ------------------------------------------------------------
    //  3. The whole diamond at once
    // ------------------------------------------------------------

    /// Everything that can hold a cent, live at the same time: two postings
    /// (one hired, one cancelled), two service requests (one hired, one
    /// superseded), a funded dispute, a treasury that refuses the whole way
    /// through, and a vault top-up. The identity is checked after every step.
    ///
    /// The two sides come from different places on purpose -- expected from the
    /// diamond's own storage, actual from the token's balanceOf -- so a term
    /// nobody booked cannot agree with itself.
    function testTheDiamondAddsUpWithEverySortOfMoneyLiveAtOnce() public {
        // The service is listed first: mintService pays the fee straight from
        // the executor's wallet to the recipient and is one of the three paths
        // the deferred-fee rule deliberately left unprotected, so it cannot be posted
        // while the recipient refuses (measured in MoneyPathRefusal).
        vm.prank(executor);
        uint256 svcId = ServiceBoardFacet(address(diamond)).mintService("s", "d", AMOUNT, DEADLINE, 0);

        usdc.setBlacklisted(feeRecipient, true);

        // A posting that gets hired.
        vm.prank(client);
        uint256 job1 = JobBoardFacet(address(diamond)).mintJob("a", "d", AMOUNT, DEADLINE, TERMS, 0);
        _assertDiamondBalances("job posted");
        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(job1);
        vm.prank(client);
        Agreement a1 = Agreement(JobBoardFacet(address(diamond)).acceptApplicant(job1, executor));
        _assertDiamondBalances("job hired, fee deferred");

        // A posting that gets cancelled.
        vm.prank(client);
        uint256 job2 = JobBoardFacet(address(diamond)).mintJob("b", "d", 40_000_000, DEADLINE, TERMS, 0);
        _assertDiamondBalances("second job posted");
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(job2);
        _assertDiamondBalances("second job cancelled, floor deferred");

        // A service with two requests from a second client; one hired, one superseded.
        address c2 = address(0x41); usdc.mint(c2, BAG);
        vm.prank(c2); usdc.approve(address(diamond), type(uint256).max);
        vm.prank(c2);
        uint256 r1 = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(c2);
        ServiceBoardFacet(address(diamond)).requestService(svcId, 30_000_000, DEADLINE, TERMS, 0);
        _assertDiamondBalances("two requests pending");
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(r1);
        _assertDiamondBalances("one hired, one superseded");

        // The vault gets a donation from the owner.
        usdc.mint(owner, 50_000_000);
        usdc.approve(address(diamond), type(uint256).max);
        ArbiterRegistryFacet(address(diamond)).fundVault(50_000_000);
        _assertDiamondBalances("vault funded");

        // The first deal goes to a funded dispute and a verdict.
        _activate(a1);
        vm.prank(client); a1.raiseDispute();
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a1));
        _trackBounty(address(a1));
        _assertDiamondBalances("dispute funded");
        _claimByArbiter(a1);
        _submitAndFinalize(a1, false);
        _assertDiamondBalances("verdict executed, levy credited");

        // Now let the treasury take everything it is owed, three separate ways.
        usdc.setBlacklisted(feeRecipient, false);
        FactoryFacet(address(diamond)).withdrawUndeliveredFees();
        _assertDiamondBalances("board debt paid");
        ArbiterRegistryFacet(address(diamond)).withdrawTreasurySlice();
        _assertDiamondBalances("levy slice paid");
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).withdrawArbiterReward();
        _assertDiamondBalances("arbiter paid");

        // What is left is exactly the vault and the still-pending request --
        // and the vault is three dollars lighter than it was donated, because
        // this dispute was funded while the bank had money and the bank took
        // its discount off the top-up. Those three dollars are
        // not lost: they went to the arbiter as part of the floor, which the
        // withdrawal three lines up already moved out of the diamond.
        assertEq(
            usdc.balanceOf(address(diamond)),
            47_000_000 + 0,
            "only the vault remains, less the discount it gave"
        );
        assertEq(ArbiterRegistryFacet(address(diamond)).getVaultBalance(), 47_000_000);
        assertEq(
            usdc.balanceOf(arbiterAddr),
            ARBITER_FLOOR,
            "and the arbiter got the whole floor anyway"
        );
    }

    /// The vault has exactly ONE way out, and this is not it: a dispute that
    /// nobody paid a top-up for never touches the bank. Until 29 August 2026
    /// the vault had no way out at all; the discount on a funded top-up
    /// is the only one, and it is measured in
    /// test/DisputeVaultDiscount.t.sol. Stated here because the vault is a term
    /// of the identity above, and "it only ever grows" stopped being true.
    function testTheVaultIsUntouchedByADisputeNobodyPaidFor() public {
        usdc.mint(owner, 10_000_000);
        usdc.approve(address(diamond), type(uint256).max);
        ArbiterRegistryFacet(address(diamond)).fundVault(10_000_000);
        assertEq(ArbiterRegistryFacet(address(diamond)).getVaultBalance(), 10_000_000);

        // A dispute runs its whole course; the vault is untouched by it.
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);
        _submitAndFinalize(a, true);

        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(),
            10_000_000,
            "paying an arbiter out of the levy alone does not touch the vault"
        );
        _assertDiamondBalances("vault untouched by a dispute");
    }
}
