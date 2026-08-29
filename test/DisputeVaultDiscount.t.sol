// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  The arbiter bank's discount on a dispute top-up (29 August 2026)
// ============================================================
//
// A dispute over five dollars cost the party ten, because the arbiter floor is
// ten and the levy on a five-dollar pot yields twelve cents. Live people found
// that in twenty minutes. The answer chosen was not to lower the floor and not
// to have the bank pay for everything -- a dispute that costs the opener
// nothing is one that gets opened for nothing -- but a DISCOUNT: the arbiter
// bank takes a fixed amount off the top-up, and the party pays the rest.
//
// Every scene below is a balance, a stored counter, or both, and the identity
// the whole money audit rests on (`_assertDiamondBalances`) is re-checked
// around the moves: the diamond holds exactly the sum of what it books, and the
// two sides of that comparison come from different places -- storage on one
// side, the token's balanceOf on the other.
//
// THE QUESTION THIS FILE EXISTS FOR is section 3: between the promise of a
// discount (fundDispute) and the payout to the arbiter (finalizeVerdict) days
// pass. The three dollars are taken out of the bank AT THE PROMISE, so two
// disputes can never be promised the same three dollars, and there is no branch
// anywhere in which an arbiter is paid less than the floor because our
// arithmetic ran out of somebody else's money.

import "./MoneyPathBase.sol";

contract DisputeVaultDiscountTest is MoneyPathBase {

    uint256 constant ARBITER_FLOOR   = 10_000_000; // $10, the facet's default
    uint256 constant DEFAULT_DISCOUNT = 3_000_000; //  $3, the facet's default
    uint256 constant FULL_TOPUP      =  7_600_000; // $10 floor less $2.40 of levy on a $100 pot

    // ------------------------------------------------------------
    //  helpers
    // ------------------------------------------------------------

    function _fundVault(uint256 amount) internal {
        usdc.mint(owner, amount);
        usdc.approve(address(diamond), type(uint256).max);
        ArbiterRegistryFacet(address(diamond)).fundVault(amount);
    }

    /// A second client with its own wallet: the registry refuses a second live
    /// agreement between the same pair, and the two-dispute scenes need two.
    function _secondClient(address who) internal {
        usdc.mint(who, BAG);
        vm.prank(who); usdc.approve(address(diamond), type(uint256).max);
    }

    function _disputedDeal(address payer, uint256 amount) internal returns (Agreement a) {
        vm.prank(payer);
        a = Agreement(FactoryFacet(address(diamond)).deployAndFund(
            payer, executor, amount, DEADLINE, TERMS, 0
        ));
        vm.prank(executor); a.activate();
        vm.prank(payer); a.raiseDispute();
    }

    function _quote(Agreement a) internal view returns (uint256) {
        return ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
    }

    function _bounty(Agreement a) internal view returns (uint256) {
        return ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a));
    }

    function _subsidy(Agreement a) internal view returns (uint256) {
        return ArbiterAccountabilityFacet(address(diamond)).getDisputeSubsidy(address(a));
    }

    function _vault() internal view returns (uint256) {
        return ArbiterRegistryFacet(address(diamond)).getVaultBalance();
    }

    // ------------------------------------------------------------
    //  1. The discount itself
    // ------------------------------------------------------------

    function testTheDefaultIsThreeDollarsUntilSomebodySetsIt() public view {
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getDisputeDiscount(),
            DEFAULT_DISCOUNT,
            "three dollars out of the box, with nothing written to storage"
        );
    }

    /// The whole point, in one scene: the party pays less, and the arbiter is
    /// paid the same. The difference came out of the bank and nowhere else.
    function testTheBankTakesThreeDollarsOffAndTheArbiterStillGetsTheFloor() public {
        _fundVault(50_000_000);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        assertEq(_quote(a), FULL_TOPUP - DEFAULT_DISCOUNT, "$7.60 less the bank's $3");

        uint256 before = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        assertEq(before - usdc.balanceOf(client), 4_600_000, "the party paid $4.60, not $7.60");
        assertEq(_bounty(a), FULL_TOPUP, "the arbiter is still promised the whole $7.60");
        assertEq(_subsidy(a), DEFAULT_DISCOUNT, "of which $3 came from the bank");
        assertEq(_vault(), 47_000_000, "and the bank is $3 lighter this instant");
        _assertDiamondBalances("discounted top-up funded");

        _claimByArbiter(a);
        _submitAndFinalize(a, true);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            ARBITER_FLOOR,
            "the arbiter is owed the floor, both halves of the top-up included"
        );
        assertEq(_subsidy(a), 0, "the reservation is gone with the dispute");
        _assertDiamondBalances("verdict executed");

        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).withdrawArbiterReward();
        assertEq(usdc.balanceOf(arbiterAddr), ARBITER_FLOOR, "and it came out in real money");
        assertEq(_vault(), 47_000_000, "the bank did not get its $3 back: it was spent");
        _assertDiamondBalances("after the arbiter was paid");
    }

    /// The number on the screen and the number taken out of the wallet are the
    /// same subtraction, not two subtractions that agree today. This is the
    /// seam the design turns on: quoteDisputeTopUp is the single owner of it.
    function testTheQuoteIsExactlyWhatTheWalletPays() public {
        _fundVault(10_000_000);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        uint256 quoted = _quote(a);
        uint256 before = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        assertEq(before - usdc.balanceOf(client), quoted, "charged exactly what was quoted");
    }

    // ------------------------------------------------------------
    //  2. An empty or nearly empty bank
    // ------------------------------------------------------------

    /// A party in a dispute must never hit a revert because of somebody else's
    /// treasury. An empty bank gives nothing and refuses nobody.
    function testAnEmptyBankGivesNothingAndRefusesNobody() public {
        assertEq(_vault(), 0, "no donation in this scene");
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        assertEq(_quote(a), FULL_TOPUP, "no bank, no discount");

        uint256 before = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        assertEq(before - usdc.balanceOf(client), FULL_TOPUP, "the party paid all of it");
        assertEq(_subsidy(a), 0, "nothing was reserved");
        assertEq(_vault(), 0, "and the bank cannot go below zero");
        _assertDiamondBalances("undiscounted top-up on an empty bank");
    }

    /// A bank holding less than the discount gives what it has, to the cent.
    function testABankHoldingLessThanTheDiscountGivesWhatItHas() public {
        _fundVault(1_000_000); // $1, a third of the discount
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        assertEq(_quote(a), FULL_TOPUP - 1_000_000, "$1 off, because $1 is all there was");

        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        assertEq(_subsidy(a), 1_000_000);
        assertEq(_vault(), 0, "the bank is empty, not negative");
        _assertDiamondBalances("bank drained to the cent");

        _claimByArbiter(a);
        _submitAndFinalize(a, true);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            ARBITER_FLOOR,
            "the arbiter is paid the floor whatever the bank could manage"
        );
    }

    /// A bank holding exactly the discount gives exactly the discount.
    function testABankHoldingExactlyTheDiscountGivesAllOfIt() public {
        _fundVault(DEFAULT_DISCOUNT);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        assertEq(_quote(a), FULL_TOPUP - DEFAULT_DISCOUNT);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));
        assertEq(_subsidy(a), DEFAULT_DISCOUNT);
        assertEq(_vault(), 0);
        _assertDiamondBalances("bank spent exactly");
    }

    // ------------------------------------------------------------
    //  3. WHO WAITS FOR WHOM -- the reservation
    // ------------------------------------------------------------

    /// The bank holds exactly one discount. Two disputes want it. The first one
    /// to pay takes it, and the second is quoted the full price BEFORE the
    /// first is anywhere near a verdict -- which is the whole point: the money
    /// is spoken for at the promise, not at the payout.
    ///
    /// Without the reservation both quotes would read $4.60, both parties would
    /// pay $4.60, and the second arbiter would be short three dollars of the
    /// floor at a payout happening days later, for a reason having nothing to
    /// do with his dispute.
    function testTwoDisputesCannotBePromisedTheSameThreeDollars() public {
        _fundVault(DEFAULT_DISCOUNT);

        address c2 = address(0x41);
        _secondClient(c2);

        (Agreement a1, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a1);
        vm.prank(client); a1.raiseDispute();
        Agreement a2 = _disputedDeal(c2, AMOUNT);

        // Both are quoted the discount while the bank still holds it.
        assertEq(_quote(a1), FULL_TOPUP - DEFAULT_DISCOUNT, "first quote sees the bank");
        assertEq(_quote(a2), FULL_TOPUP - DEFAULT_DISCOUNT, "so does the second");

        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a1));
        _trackBounty(address(a1));

        // No verdict, no finalization, nothing resolved -- and the second quote
        // has already changed.
        assertEq(_vault(), 0, "the bank paid at the promise, not at the payout");
        assertEq(
            _quote(a2),
            FULL_TOPUP,
            "the second dispute is quoted the full price the moment the bank is empty"
        );

        uint256 before = usdc.balanceOf(c2);
        vm.prank(c2);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a2));
        _trackBounty(address(a2));
        assertEq(before - usdc.balanceOf(c2), FULL_TOPUP, "and paid it");
        assertEq(_subsidy(a2), 0);
        _assertDiamondBalances("two disputes, one discount");

        // Both arbiters -- the same person here -- are paid the whole floor.
        _claimByArbiter(a1);
        _submitAndFinalize(a1, true);
        _claimByArbiter(a2);
        _submitAndFinalize(a2, true);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            ARBITER_FLOOR * 2,
            "neither dispute paid its judge a cent under the floor"
        );
        _assertDiamondBalances("both verdicts executed");
    }

    /// Same shape, one bank, one and a half discounts in it: the first takes
    /// three, the second takes the remaining fifty cents.
    function testTheSecondDisputeGetsWhateverTheFirstLeftBehind() public {
        _fundVault(3_500_000);

        address c2 = address(0x42);
        _secondClient(c2);

        (Agreement a1, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a1);
        vm.prank(client); a1.raiseDispute();
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a1));
        _trackBounty(address(a1));

        Agreement a2 = _disputedDeal(c2, AMOUNT);
        assertEq(_quote(a2), FULL_TOPUP - 500_000, "fifty cents is what is left");
        vm.prank(c2);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a2));
        _trackBounty(address(a2));

        assertEq(_subsidy(a1), DEFAULT_DISCOUNT);
        assertEq(_subsidy(a2), 500_000);
        assertEq(_vault(), 0);
        _assertDiamondBalances("a discount and a half, spent");
    }

    // ------------------------------------------------------------
    //  4. The ways back: the bank's share returns to the bank
    // ------------------------------------------------------------

    /// Nobody took the case. The party gets back what the PARTY paid, and the
    /// bank gets back what the BANK paid. Refunding the whole bounty to the
    /// payer would have made an abandoned dispute a way to milk the bank.
    function testAnUnclaimedDisputeReturnsTheBanksShareToTheBank() public {
        _fundVault(DEFAULT_DISCOUNT);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        uint256 before = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        uint256 paid = before - usdc.balanceOf(client);
        assertEq(paid, FULL_TOPUP - DEFAULT_DISCOUNT, "$4.60 out of his own pocket");
        _trackBounty(address(a));
        assertEq(_vault(), 0, "reserved");

        uint256 afterFunding = usdc.balanceOf(client);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(executor); a.triggerArbiterTimeout();

        assertEq(_vault(), DEFAULT_DISCOUNT, "the bank has its $3 back");
        assertEq(_subsidy(a), 0, "and the reservation is cleared");
        assertEq(_bounty(a), 0);
        // The wallet gains the escrow share the timeout split off, plus HIS OWN
        // $4.60 -- and nothing else. The bank's $3 went home, not to him.
        assertEq(
            usdc.balanceOf(client) - afterFunding,
            (AMOUNT - AMOUNT / 4) + paid,
            "his own top-up came back and the bank's share did not follow it"
        );
        _assertDiamondBalances("abandoned dispute unwound");
    }

    /// The same accounting, stated as the abuse it prevents: open a dispute,
    /// pay the discounted top-up, let it die, collect. The bank ends whole and
    /// the milker ends with nothing but the levy he burned on the way in.
    function testMilkingTheBankThroughAnAbandonedDisputeGainsNothing() public {
        _fundVault(20_000_000);
        uint256 bankBefore = _vault();

        for (uint256 i = 0; i < 3; i++) {
            address milker = address(uint160(0x900 + i));
            _secondClient(milker);
            Agreement a = _disputedDeal(milker, AMOUNT);

            uint256 walletBefore = usdc.balanceOf(milker);
            vm.prank(milker);
            ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
            uint256 paid = walletBefore - usdc.balanceOf(milker);
            _trackBounty(address(a));

            uint256 afterFunding = usdc.balanceOf(milker);
            // Anchored on the deal's own clock rather than on the loop's: each
            // round starts later than the last one, and a relative warp read
            // the wrong side of the window on the second pass.
            vm.warp(a.disputedAt() + DISPUTE_WINDOW + 1);
            vm.prank(executor); a.triggerArbiterTimeout();

            // Exactly his own money back, plus the escrow share the timeout
            // owes him. Not one cent of the discount stuck to him.
            assertEq(
                usdc.balanceOf(milker) - afterFunding,
                (AMOUNT - AMOUNT / 4) + paid,
                "round trip on the top-up, no gain"
            );
        }

        assertEq(_vault(), bankBefore, "three abandoned disputes took nothing out of the bank");
        _assertDiamondBalances("after three abandoned disputes");
    }

    /// An overturned verdict pays the arbiter nothing, so the bank's share goes
    /// home the same way -- and the payer's claim is his own money only.
    function testAnOverturnedVerdictReturnsTheBanksShareToTheBank() public {
        _fundVault(DEFAULT_DISCOUNT);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        _claimByArbiter(a);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(address(a), false);
        vm.warp(block.timestamp + FINALIZE_DELAY + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));

        assertEq(_vault(), DEFAULT_DISCOUNT, "the bank got its share back");
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getRefundableBounty(client),
            FULL_TOPUP - DEFAULT_DISCOUNT,
            "the payer is owed his $4.60 and not a cent of the bank's $3"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            0,
            "the overturned arbiter is paid nothing of the top-up"
        );
        _assertDiamondBalances("overturned verdict unwound");
    }

    // ------------------------------------------------------------
    //  5. The size of the discount is a setting, not a constant
    // ------------------------------------------------------------

    function testTheOwnerMovesTheDiscountAndTheQuoteMovesWithIt() public {
        _fundVault(50_000_000);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        assertEq(_quote(a), FULL_TOPUP - DEFAULT_DISCOUNT);

        ArbiterRegistryFacet(address(diamond)).setDisputeDiscount(5_000_000);
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeDiscount(), 5_000_000);
        assertEq(_quote(a), FULL_TOPUP - 5_000_000, "a $5 discount, one transaction later");

        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));
        assertEq(_subsidy(a), 5_000_000);
        assertEq(_vault(), 45_000_000);
        _assertDiamondBalances("after a discount that moved");
    }

    function testTheDiscountIsTheOwnersAloneToMove() public {
        vm.prank(stranger);
        vm.expectRevert(ArbiterRegistryFacet.NotOwner.selector);
        ArbiterRegistryFacet(address(diamond)).setDisputeDiscount(9_000_000);
    }

    /// A dispute already funded keeps the split it was funded with: both halves
    /// are in storage, so nothing is recomputed behind anyone's back.
    function testMovingTheDiscountDoesNotMoveADisputeAlreadyFunded() public {
        _fundVault(50_000_000);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        ArbiterRegistryFacet(address(diamond)).setDisputeDiscount(9_000_000);

        assertEq(_bounty(a), FULL_TOPUP, "the promise to the arbiter is unchanged");
        assertEq(_subsidy(a), DEFAULT_DISCOUNT, "and so is the bank's share of it");

        _claimByArbiter(a);
        _submitAndFinalize(a, true);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            ARBITER_FLOOR
        );
        assertEq(_vault(), 47_000_000, "the bank paid the old discount, not the new one");
        _assertDiamondBalances("discount moved under a live dispute");
    }

    // ------------------------------------------------------------
    //  6. A discount larger than the top-up
    // ------------------------------------------------------------

    /// $300 pot: the levy already yields the arbiter $7.20, so the whole top-up
    /// is $2.80 -- less than the $3 discount. The subtraction must not go
    /// negative, and the top-up must not become free: zero from
    /// quoteDisputeTopUp already means "there is nothing to pay", which is what
    /// fundDispute answers with TopUpNotNeeded and what the deal screen answers
    /// by hiding the button.
    function testADiscountLargerThanTheTopUpNeitherUnderflowsNorMakesItFree() public {
        _fundVault(50_000_000);
        Agreement a = _disputedDeal(client, 300_000_000);

        uint256 gross = 2_800_000; // $10 floor less 80% of the $9 levy
        uint256 quoted = _quote(a);
        assertEq(quoted, 1, "the party still pays, even if it is the smallest coin there is");
        assertGt(quoted, 0, "and the quote never collapses into the 'nothing to pay' zero");

        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        assertEq(_bounty(a), gross, "the arbiter is still promised the whole $2.80");
        assertEq(_subsidy(a), gross - 1, "the bank covered all of it but the last coin");
        assertEq(_vault(), 50_000_000 - (gross - 1));
        _assertDiamondBalances("a discount bigger than the need");

        _claimByArbiter(a);
        _submitAndFinalize(a, true);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            ARBITER_FLOOR,
            "still exactly the floor"
        );
    }

    /// The same guard reached from the other side: an enormous discount on an
    /// ordinary pot. The party pays a coin, never nothing, and never a negative.
    function testAnEnormousDiscountStillLeavesTheDisputeCostingSomething() public {
        _fundVault(500_000_000);
        ArbiterRegistryFacet(address(diamond)).setDisputeDiscount(400_000_000); // $400

        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        assertEq(_quote(a), 1, "one millionth of a dollar, and not zero");

        uint256 before = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        _trackBounty(address(a));

        assertEq(before - usdc.balanceOf(client), 1);
        assertEq(_bounty(a), FULL_TOPUP);
        assertEq(_subsidy(a), FULL_TOPUP - 1);
        _assertDiamondBalances("an enormous discount");
    }

    /// A pot big enough that the levy alone clears the floor still needs no
    /// top-up at all, and the bank is not asked for one. This is the OTHER
    /// zero, and it has to stay distinguishable: here there is nothing to pay
    /// because the arbiter is already paid, and fundDispute says so by name.
    function testAPotThatPaysItsOwnArbiterAsksTheBankForNothing() public {
        _fundVault(50_000_000);
        Agreement a = _disputedDeal(client, 1_000_000_000); // $1000 -> arbiter gets $24

        assertEq(_quote(a), 0, "nothing to pay");
        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.TopUpNotNeeded.selector);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        assertEq(_vault(), 50_000_000, "and the bank was never touched");
    }
}
