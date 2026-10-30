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
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

contract MoneyPathDisputeTest is MoneyPathBase {

    uint256 constant ARBITER_FLOOR = 10_000_000; // $10, ArbiterRegistryFacet's default

    /// ⚠️ THE FLOOR THE TOP-UP SCENES RAISE IT TO, AND WHY THEY HAVE TO
    /// (20 October 2026). The dispute fee gained a flat ten dollar floor of its
    /// own, and the whole fee goes to the judge -- so on EVERY pot the judge
    /// already receives the default ten and `quoteDisputeTopUp` answers nought.
    /// That is the correct answer and it makes the top-up door's machinery
    /// unreachable on a deal cut from this implementation.
    ///
    /// Raising the floor to $20 by the owner's own door restores a real
    /// difference of $10 and leaves each scene about what it was written for.
    /// Nothing but the top-up quote reads this number.
    ///
    /// ⚠️ THE DOOR IS NOT DEAD: the sixteen clones already on Base Sepolia take
    /// 3% with no floor under it, and on those the difference is real at the
    /// default.
    uint256 constant RAISED_FLOOR = 20_000_000;
    /// The fee on this file's $100 pot: the floor, because 3% is $3.
    uint256 constant FEE_ON_HUNDRED = 10_000_000;
    /// What is left to find against the raised floor: $20 - $10.
    uint256 constant TOP_UP_ON_HUNDRED = 10_000_000;

    // ------------------------------------------------------------
    //  1. The levy: 3%, capped, split 80/20 with nothing lost
    // ------------------------------------------------------------

    function testTheLevyIsThreePercentOfTheWholePotIncludingExtras() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        uint256 id = _proposeExtra(a, 200_000_000);
        vm.prank(executor); a.acceptExtra(id);

        assertEq(a.totalPayout(), 300_000_000, "pot is body plus accepted extras");
        // ⚠️ THE FLOOR DECIDES ON THIS POT SINCE 20 OCTOBER 2026, so the scene
        // can no longer show the percentage here: 3% of $300 is $9, under the
        // $10 floor. The claim it was written for -- that the levy reads the
        // WHOLE pot including extras and not the body alone -- is kept by the
        // second assertion, on a pot where the percentage does decide.
        assertEq(a.disputeFee(), 10_000_000, "the $10 floor decides on a $300 pot: 3% of it is only $9");

        uint256 id2 = _proposeExtra(a, 100_000_000);
        vm.prank(executor); a.acceptExtra(id2);
        assertEq(a.totalPayout(), 400_000_000, "pot is body plus both accepted extras");
        assertEq(a.disputeFee(), 12_000_000, "3% of $400, not of $100 -- the percentage decides over the floor");
    }

    function testTheLevyIsCappedAtFiveHundredDollars() public {
        uint256 huge = 50_000_000_000; // $50 000; 3% would be $1500
        Agreement a = _hireDirectly(huge);
        assertEq(a.disputeFee(), 500_000_000, "capped at $500");
    }

    function testTheArbiterFloorNeedsNoTopUpOnceThePotIsBigEnough() public {
        // ⚠️ RE-DERIVED 20 OCTOBER 2026 AGAINST A RAISED FLOOR. The old note
        // read "90% of 3% reaches $10 when the pot reaches $370.37"; the whole
        // fee is the judge's now and it has a $10 floor, so the default floor
        // is reached on every pot and this scene would compare nought with
        // nought. Against a $20 floor the claim is real again: 3% reaches $20
        // at a pot of $666.666667.
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(RAISED_FLOOR);
        Agreement small = _hireDirectly(100_000_000); // $100 -> the fee is the $10 floor
        _activate(small);
        vm.prank(client); small.raiseDispute();
        assertEq(
            ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(small)),
            TOP_UP_ON_HUNDRED,
            "the raised $20 floor less the $10 the fee already yields"
        );

        address c2 = address(0x31); usdc.mint(c2, BAG);
        vm.prank(c2); usdc.approve(address(diamond), type(uint256).max);
        vm.prank(c2);
        Agreement big = Agreement(FactoryFacet(address(diamond)).deployAndFund(
            c2, executor, 1_000_000_000, DEADLINE, TERMS, 0)); // $1000 -> the fee is 3% = $30
        vm.prank(executor); big.activate();
        vm.prank(c2); big.raiseDispute();
        assertEq(big.disputeFee(), 30_000_000, "setup: 3% of a $1000 pot is $30, well over the raised floor");
        assertEq(
            ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(big)),
            0,
            "big pot needs no top-up at all"
        );
    }

    // ------------------------------------------------------------
    //  2. The paid call, counted end to end
    // ------------------------------------------------------------

    /// Every cent of a $100 dispute with a paid arbiter, from four wallets.
    /// The number worth looking at is the last one: what the client is down
    /// after WINNING.
    ///
    /// ⚠️ RE-DERIVED 20 OCTOBER 2026. The old column was: levy $3 (3% of the
    /// pot, cut out of the escrow), the judge's 90% of it $2.70, a top-up of
    /// $7.30 to reach the $10 floor, so $10.30 to win a $100 argument. All
    /// three inputs moved. The fee is a flat $10 paid AT THE DOOR out of the
    /// client's own wallet, the judge takes all of it, and the escrow is not
    /// touched -- so against the default floor there is no top-up at all. The
    /// scene raises the floor to $20 (see RAISED_FLOOR) so that there is a
    /// top-up to count, and the client's outlay is then $10 at the door plus
    /// $10 of top-up.
    function testAPaidDisputeCountedFromEveryWallet() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        assertEq(
            ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a)), 0,
            "against the default floor a modern deal needs no top-up -- its fee already reaches it"
        );
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(RAISED_FLOOR);

        uint256 topUp = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertEq(topUp, TOP_UP_ON_HUNDRED, "$10 to reach the raised $20 floor from a $10 fee");

        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));
        assertEq(clientBefore - usdc.balanceOf(client), topUp, "the client paid the top-up");
        // ⚠️ THE DOOR CHARGE IS A TERM OF THIS SUM, 21 OCTOBER 2026. The line
        // read `topUp + seatBondHeld` and the diamond holds the dispute fee as
        // well, because the fee is taken when the DISPUTE is opened now and
        // `a.raiseDispute()` is three lines above. Nothing about the top-up
        // changed; a term was missing.
        //
        // Worked out by hand. The retired rule took the fee out of the POT at
        // the settlement, so at this point in the scene the diamond held the
        // top-up and the seat bond and nothing else -- which is the expression
        // that stood here, and it reproduces as a STRUCTURE rather than as a
        // figure, because what moved is the number of terms. The figures inside
        // it moved as well, which is worth writing out so neither era has to be
        // remembered: the retired scene ran against the DEFAULT $10 floor with
        // a 3% fee, so its top-up was
        //     10_000_000 - 3_000_000 = 7_000_000
        // and the raised floor this scene now sets did not exist before
        // 20 October at all. What ships:
        //     the door charge  max( 10_000_000, 3_000_000 )  = 10_000_000
        //     the top-up       20_000_000 - 10_000_000       = 10_000_000
        //     on the diamond   10_000_000 + 10_000_000       = 20_000_000
        //                                                     + seatBondHeld
        //
        // ⚠️ AND THE TWO TENS ARE NAMED SEPARATELY RATHER THAN SUMMED TO
        // 20_000_000, because they are the same figure for different reasons --
        // one is the fee's own floor, the other is the gap from that fee to a
        // raised arbiter floor -- and a single literal would stay green if the
        // fee rose by what the top-up fell.
        uint256 doorCharge = FEE_ON_HUNDRED;
        assertEq(doorCharge, 10_000_000, "arithmetic: the door charge on a $100 pot is not max( the $10 floor, 3% = $3 )");
        assertEq(topUp + doorCharge, RAISED_FLOOR, "arithmetic: the door charge and the top-up do not add to the raised floor");
        assertEq(usdc.balanceOf(address(diamond)), doorCharge + topUp + seatBondHeld, "the door charge and the top-up do not both sit on the diamond");
        _assertDiamondBalances("after fundDispute");

        _claimByArbiter(a);
        _submitAndFinalize(a, true); // the client wins on the merits

        uint256 levy = FEE_ON_HUNDRED;                // $10, the floor
        uint256 arbiterShare = FEE_ON_HUNDRED;        // the whole fee
        uint256 treasuryShare = 0;                    // levy - arbiterShare

        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            arbiterShare + topUp,
            "the arbiter is owed exactly the floor"
        );
        assertEq(arbiterShare + topUp, RAISED_FLOOR, "which is the raised $20 on the nose");
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), treasuryShare);
        _assertDiamondBalances("after the verdict was executed");

        // ⚠️ THE WINNER'S OWN ARITHMETIC, AND THE FEE IS NO LONGER INSIDE THE
        // POT. $100 in, $100 back, and the $10 door charge plus the $10 top-up
        // spent to be heard. `clientBefore` is read AFTER the door charge was
        // taken, so the charge is not in this subtraction -- the pot comes home
        // whole and only the top-up comes off.
        assertEq(
            usdc.balanceOf(client),
            clientBefore - topUp + AMOUNT,
            "the client is out the top-up despite winning, and the pot came back whole"
        );
        assertEq(topUp + levy, 20_000_000, "$20 to win a $100 argument");

        // The one owed half really comes out.
        vm.prank(arbiterAddr);
        ArbiterVaultFacet(address(diamond)).withdrawArbiterReward();
        // ⚠️ AND THE TREASURY'S DOOR REFUSES, 21 OCTOBER 2026, where a bare
        // call stood: `withdrawTreasurySlice` is written `if (slice == 0) revert
        // NothingToPush()`, and `treasuryShare` three blocks above is a named
        // nought because the whole fee is the judge's. The retired share was a
        // tenth of a 3_000_000 fee, 300_000, which is why the bare call passed
        // for as long as it did. Asserted rather than deleted, so a slice
        // reappearing on this road reds here by name.
        vm.expectRevert(ArbiterRegistryFacet.NothingToPush.selector);
        ArbiterVaultFacet(address(diamond)).withdrawTreasurySlice();
        // His purse is in this number since 22 September 2026: the rig funds him
        // so he can post the bond each CASE asks for, and this deal's bond came
        // home at finalization.
        assertEq(usdc.balanceOf(arbiterAddr) - CASE_BOND_PURSE, RAISED_FLOOR, "arbiter paid the raised floor");
        assertEq(usdc.balanceOf(address(diamond)), seatBondHeld, "diamond empty but for the arbiter's bond");
        _assertDiamondBalances("after withdrawals");
    }

    /// If nobody takes the case, the top-up comes back -- but through a claim,
    /// not a push, so a payer who cannot receive it does not freeze the exit.
    function testAnUnclaimedTopUpComesBackAndABlockedClientDoesNotFreezeTheExit() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _handIn(a);
        vm.prank(client); a.raiseDispute();
        // ⚠️ THE FLOOR IS RAISED FIRST, 21 OCTOBER 2026, OR THERE IS NO TOP-UP
        // TO TIME OUT. `fundDispute` ends in `if (gross == 0) revert
        // TopUpNotNeeded()`, and against the DEFAULT $10 floor a modern deal's
        // own door charge already reaches it -- the fee's floor and the arbiter
        // floor are the same ten dollars since 20 October -- so the gross
        // top-up is nought and this scene reverted at its second line. The
        // scene is about what happens to a top-up that nobody earns, so the
        // cure is to put a top-up back on the road rather than to drop it, the
        // same way the paid-dispute scene above does.
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(RAISED_FLOOR);
        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));

        // ⚠️ THE TOP-UP WAS 7_300_000 AND IS TEN DOLLARS NOW. Worked out by
        // hand, retired figure first so the method can be checked. The retired
        // top-up was the gap from what the JUDGE kept of a 3% fee to the
        // default floor, and he kept nine tenths of it:
        //     the retired fee     100_000_000 x 300 / 10_000 = 3_000_000
        //     his share of it       3_000_000 x 9_000 / 10_000 = 2_700_000
        //     the gap to the floor 10_000_000 - 2_700_000      = 7_300_000
        // -- the literal that stood here, reproduced exactly, so the
        // subtraction is the right subtraction. The same gap today, where the
        // fee's floor decides it and the judge keeps the WHOLE fee:
        //     the fee             max( 10_000_000, 3_000_000 ) = 10_000_000
        //     his share of it     the whole of it              = 10_000_000
        //     the gap to the floor 20_000_000 - 10_000_000     = 10_000_000
        uint256 topUp = 10_000_000;
        // The control is on what the funding RECORDED, not on the quote.
        // `quoteDisputeTopUp` is the gap from the fee to the floor and it keeps
        // answering that gap after the money is in -- measured here: it still
        // returned 10_000_000 once funded, which is correct for what it means
        // and useless as a sign that the funding landed. `getDisputeBounty` is
        // the term that moves, and it is the one the timeout below spends.
        assertEq(
            ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), topUp,
            "the funding did not book the hand-derived top-up -- this scene's figures are then the wrong figures"
        );
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
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), 0);
        // ⚠️ TWO SUMS COME BACK TO HIM HERE AND NOT ONE, 21 OCTOBER 2026: the
        // top-up he funded AND the door charge he paid to open the dispute,
        // because no verdict was delivered. He cannot receive either, so both
        // land in the same claim.
        //
        // Worked out by hand:
        //     the door charge  max( 10_000_000, 3_000_000 ) = 10_000_000
        //     the top-up       20_000_000 - 10_000_000      = 10_000_000
        //     his claim        10_000_000 + 10_000_000      = 20_000_000
        // The two are named separately rather than as one twenty, because they
        // come home for different reasons -- one because nobody judged, the
        // other because nobody claimed -- and one literal would hide the day
        // only one of them arrives.
        uint256 doorCharge = FEE_ON_HUNDRED;
        assertEq(doorCharge, 10_000_000, "arithmetic: the door charge on a $100 pot is not max( the $10 floor, 3% = $3 )");
        assertEq(
            ArbiterVaultFacet(address(diamond)).getRefundableBounty(client),
            topUp + doorCharge,
            "the top-up and the door charge are not both a claim on the diamond"
        );
        _assertDiamondBalances("after an unclaimed, funded dispute timed out");

        // Both are pulled once the token serves them again -- two doors,
        // because the two sums sit in two different contracts.
        usdc.setBlacklisted(client, false);
        uint256 c0 = usdc.balanceOf(client);
        a.withdrawUndeliveredRefund();
        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).withdrawDisputeBounty();

        assertEq(usdc.balanceOf(client) - c0, AMOUNT - AMOUNT / 4 + topUp + doorCharge, "pot share, the top-up and the door charge back");
        assertEq(usdc.balanceOf(address(a)), 0, "clone empty");
        _assertDiamondBalances("after both claims were pulled");
    }

    /// Same again with the payer permanently unable to receive: the refund
    /// becomes claimable instead of blocking, and the escrow still empties.
    function testAPermanentlyBlockedPayerGetsAClaimNotADeadlock() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        _handIn(a);
        vm.prank(executor); a.raiseDispute();
        // The floor is raised for the same reason as the scene above: against
        // the default floor a modern deal's door charge already reaches it and
        // `fundDispute` reverts `TopUpNotNeeded`, leaving this scene with no
        // top-up to make claimable.
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(RAISED_FLOOR);
        vm.prank(executor);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));

        // ⚠️ BOTH TERMS ARE READ OFF THE CHAIN HERE, WHILE THEY STILL EXIST,
        // and the reason is measured rather than stylistic -- see the note at
        // the claim below. The quote needs the pot (an emptied clone answers the
        // floor for any deal) and the booked bounty needs the dispute (the
        // timeout spends it), so after the exit neither can be asked.
        uint256 quotedCharge = a.disputeFee();
        uint256 bookedTopUp  = ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a));

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
        // ⚠️ THE TWO LITERALS OF 7_300_000 IN THIS SCENE ARE RETIRED, AND IT IS
        // THE EXECUTOR WHO IS OWED HERE, because he is the one who opened the
        // dispute and funded it. Both the top-up and the door charge come back
        // to him, and he can receive neither, so both land in one claim.
        //
        // Worked out by hand, retired figure first -- the retired top-up was
        // the gap from the judge's nine tenths of a 3% fee to the default $10
        // floor:
        //     3_000_000 x 9_000 / 10_000 = 2_700_000
        //     10_000_000 - 2_700_000     = 7_300_000
        // -- the literal that stood here, so the subtraction is right. Today:
        //     the door charge  max( 10_000_000, 3_000_000 ) = 10_000_000
        //     the top-up       20_000_000 - 10_000_000      = 10_000_000
        //     his claim        10_000_000 + 10_000_000      = 20_000_000
        uint256 doorCharge = FEE_ON_HUNDRED;
        uint256 topUp      = 10_000_000;
        assertEq(doorCharge, 10_000_000, "arithmetic: the door charge on a $100 pot is not max( the $10 floor, 3% = $3 )");
        // ⚠️ AND THE TWO TERMS ARE ASSERTED SEPARATELY AGAINST THE CHAIN,
        // because the SUM cannot see them move. This was measured: with the
        // fee's floor mutated to nought this scene stayed GREEN, and the reason
        // is arithmetic rather than luck -- the gross top-up is
        // `the raised floor - the fee`, so top-up + charge is pinned to
        // RAISED_FLOOR for ANY fee whatsoever. A smaller charge buys a larger
        // top-up, to the base unit, and both the claim below and the identity
        // beside it are satisfied either way.
        //
        // So each term is checked against the chain on its own: the charge
        // against the deal's own quote, which moves when the rule moves, and
        // the top-up against what the funding actually booked. Either one
        // drifting now reds by name instead of being absorbed by the other.
        assertEq(quotedCharge, doorCharge, "the deal's own quote is not the ten dollar charge this scene is written against");
        assertEq(bookedTopUp,  topUp,      "the funding did not book the hand-derived top-up");
        assertEq(topUp + doorCharge, RAISED_FLOOR, "arithmetic: the top-up and the door charge do not add to the raised floor");
        assertEq(
            ArbiterVaultFacet(address(diamond)).getRefundableBounty(executor),
            topUp + doorCharge,
            "the top-up and the door charge did not both become a claim"
        );
        _assertDiamondBalances("blocked payer, claimable top-up");

        usdc.setBlacklisted(executor, false);
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(executor);
        ArbiterVaultFacet(address(diamond)).withdrawDisputeBounty();
        assertEq(usdc.balanceOf(executor) - e0, topUp + doorCharge, "and both were collectable later");
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
        ArbiterVaultFacet(address(diamond)).fundVault(50_000_000);
        _assertDiamondBalances("vault funded");

        // The first deal goes to a funded dispute and a verdict.
        // ⚠️ THE FLOOR IS RAISED FIRST (20 October 2026): against the default
        // the fee already reaches it and `fundDispute` would answer
        // `TopUpNotNeeded`, so there would be no funded dispute to walk. See
        // RAISED_FLOOR.
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(RAISED_FLOOR);
        _activate(a1);
        vm.prank(client); a1.raiseDispute();
        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a1));
        _trackDeal(address(a1));
        _assertDiamondBalances("dispute funded");
        _claimByArbiter(a1);
        _submitAndFinalize(a1, false);
        _assertDiamondBalances("verdict executed, levy credited");

        // Now let the treasury take everything it is owed. ⚠️ TWO WAYS AND NOT
        // THREE SINCE 21 OCTOBER 2026, which is what this scene failed on: the
        // line said "three separate ways" and the third of them no longer
        // exists. The treasury's cut of an ARBITRATION levy is a named nought
        // now -- the whole fee is the judge's -- so `withdrawTreasurySlice`
        // meets its own `if (slice == 0) revert NothingToPush()` and refuses.
        // The board's deferred fees are untouched by that move and still come
        // out through `withdrawUndeliveredFees`: the two pots are different
        // pots with different addressees, which is exactly why the levy's going
        // to nought does not empty the other one.
        //
        // The retired figure, so the method can be checked: the slice was a
        // tenth of the levy, and the levy on this scene's $100 deal was 3% --
        //     3_000_000 x 1_000 / 10_000 = 300_000
        // -- a non-zero slice, which is why a bare call stood here.
        usdc.setBlacklisted(feeRecipient, false);
        FactoryFacet(address(diamond)).withdrawUndeliveredFees();
        _assertDiamondBalances("board debt paid");
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), 0, "the treasury took a cut of an arbitration levy");
        vm.expectRevert(ArbiterRegistryFacet.NothingToPush.selector);
        ArbiterVaultFacet(address(diamond)).withdrawTreasurySlice();
        _assertDiamondBalances("the levy's slice is a nought and its door refuses");
        vm.prank(arbiterAddr);
        ArbiterVaultFacet(address(diamond)).withdrawArbiterReward();
        _assertDiamondBalances("arbiter paid");

        // What is left is exactly the vault and the still-pending request --
        // and the vault is three dollars lighter than it was donated, because
        // this dispute was funded while the bank had money and the bank took
        // its discount off the top-up. Those three dollars are
        // not lost: they went to the arbiter as part of the floor, which the
        // withdrawal three lines up already moved out of the diamond.
        //
        // ⚠️ THE DISCOUNT IS STILL THREE DOLLARS AND THE FLOOR BEHIND IT IS THE
        // RAISED $20 (20 October 2026). The bank's discount is `getDisputeDiscount`
        // and that number did not move; what moved is that there has to BE a
        // top-up for it to come off, which is why the floor is raised above.
        assertEq(
            usdc.balanceOf(address(diamond)),
            47_000_000 + seatBondHeld,
            "only the vault remains, less the discount it gave and the arbiter's bond"
        );
        assertEq(ArbiterVaultFacet(address(diamond)).getVaultBalance(), 47_000_000);
        // ⚠️ HIS PURSE IS IN THIS NUMBER SINCE 22 SEPTEMBER 2026. The rig funds
        // him so he can post the bond each CASE asks for, and this deal's bond
        // came home at finalization — so what he holds is the purse plus the
        // floor, not the floor alone.
        assertEq(
            usdc.balanceOf(arbiterAddr) - CASE_BOND_PURSE,
            RAISED_FLOOR,
            "and the arbiter got the whole raised floor anyway"
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
        ArbiterVaultFacet(address(diamond)).fundVault(10_000_000);
        assertEq(ArbiterVaultFacet(address(diamond)).getVaultBalance(), 10_000_000);

        // A dispute runs its whole course; the vault is untouched by it.
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        _claimByArbiter(a);
        _submitAndFinalize(a, true);

        assertEq(
            ArbiterVaultFacet(address(diamond)).getVaultBalance(),
            10_000_000,
            "paying an arbiter out of the levy alone does not touch the vault"
        );
        _assertDiamondBalances("vault untouched by a dispute");
    }
}
