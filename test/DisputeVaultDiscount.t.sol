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
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

contract DisputeVaultDiscountTest is MoneyPathBase {

    uint256 constant ARBITER_FLOOR   = 10_000_000; // $10, the facet's default
    uint256 constant DEFAULT_DISCOUNT = 3_000_000; //  $3, the facet's default

    /// ⚠️ THE FLOOR EVERY SCENE HERE RAISES IT TO, AND WHY IT HAS TO
    /// (20 October 2026). The dispute fee gained a flat ten dollar floor and
    /// the WHOLE of it goes to the judge, so on every pot he already receives
    /// the default ten -- `quoteDisputeTopUp` answers nought and `fundDispute`
    /// answers `TopUpNotNeeded`. That is the right answer and it leaves this
    /// file's subject, the BANK'S SHARE of a top-up, with no top-up to take a
    /// share of.
    ///
    /// Raising the floor to $20 restores a $10 difference and leaves every
    /// scene measuring what it was written for. The discount itself is
    /// untouched: three dollars off a ten dollar top-up instead of three off
    /// seven thirty.
    uint256 constant RAISED_FLOOR    = 20_000_000;
    /// The fee on this file's $100 pot: the floor, because 3% is $3.
    uint256 constant FEE_ON_HUNDRED  = 10_000_000;
    uint256 constant FULL_TOPUP      = 10_000_000; // $20 raised floor less the $10 fee
    // ⚠️ IT READ 7_300_000 UNTIL 20 OCTOBER 2026 -- the $10 default floor less
    // the $2.70 a 3% levy's 90% yielded on a $100 pot -- and it moved for three
    // reasons at once: the levy has a $10 floor, the judge takes all of it, and
    // the floor these scenes measure against is raised. $2.40 → $2.70 on
    // 22 September 2026 was the previous move, when the share went 80% → 90%.

    // ------------------------------------------------------------
    //  helpers
    // ------------------------------------------------------------

    /// ⚠️ THE ARBITER FLOOR IS RAISED ONCE, FOR THE WHOLE FILE (20 October
    /// 2026). It is here and not in each scene because eight of them open their
    /// dispute inline rather than through `_disputedDeal`, and a raise that
    /// covered only the helper would leave those eight measuring nought without
    /// saying so. The whole argument is at RAISED_FLOOR above.
    function setUp() public override {
        super.setUp();
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(RAISED_FLOOR);
        assertEq(
            ArbiterVaultFacet(address(diamond)).getArbiterFloor(), RAISED_FLOOR,
            "rig: the floor this file measures against was not raised"
        );
        assertTrue(
            RAISED_FLOOR > FEE_ON_HUNDRED,
            "rig: the raised floor is not above the fee, so there is no top-up for any scene here to measure"
        );
    }

    function _fundVault(uint256 amount) internal {
        usdc.mint(owner, amount);
        usdc.approve(address(diamond), type(uint256).max);
        ArbiterVaultFacet(address(diamond)).fundVault(amount);
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
        // Handed in before the dispute: these scenes are about the bank's share of
        // the top-up, and since 25 September 2026 an unclaimed timeout with no
        // markDone on the record pays the executor nothing at all.
        _handIn(a);
        vm.prank(payer); a.raiseDispute();
    }

    function _quote(Agreement a) internal view returns (uint256) {
        return ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
    }

    function _bounty(Agreement a) internal view returns (uint256) {
        return ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a));
    }

    function _subsidy(Agreement a) internal view returns (uint256) {
        return ArbiterAccountabilityFacet(address(diamond)).getDisputeSubsidy(address(a));
    }

    function _vault() internal view returns (uint256) {
        return ArbiterVaultFacet(address(diamond)).getVaultBalance();
    }

    // ------------------------------------------------------------
    //  1. The discount itself
    // ------------------------------------------------------------

    function testTheDefaultIsThreeDollarsUntilSomebodySetsIt() public view {
        assertEq(
            ArbiterVaultFacet(address(diamond)).getDisputeDiscount(),
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

        assertEq(_quote(a), FULL_TOPUP - DEFAULT_DISCOUNT, "the $10 top-up less the bank's $3");

        uint256 before = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));

        // ⚠️ $7 AND NOT $4.30, 21 OCTOBER 2026. Worked out by hand, retired
        // figure first: the retired top-up was the $10 default floor less the
        // judge's nine tenths of a 3% levy on a $100 pot,
        //     10_000_000 - 2_700_000 = 7_300_000 gross
        //      7_300_000 - 3_000_000 = 4_300_000 for the party
        // -- the two literals this scene's prose carried. At the live rates
        // the judge keeps the whole $10 levy and this file raises the floor to
        // $20, so
        //     20_000_000 - 10_000_000 = 10_000_000 gross (FULL_TOPUP)
        //     10_000_000 -  3_000_000 =  7_000_000 for the party
        // The bank's $3 did not move; both of the other two did.
        assertEq(before - usdc.balanceOf(client), FULL_TOPUP - DEFAULT_DISCOUNT, "the party paid $7, not the whole $10");
        assertEq(FULL_TOPUP - DEFAULT_DISCOUNT, 7_000_000, "arithmetic: the party's share of the top-up is not the gap less the bank's three dollars");
        assertEq(_bounty(a), FULL_TOPUP, "the arbiter is still promised the whole $10");
        assertEq(_subsidy(a), DEFAULT_DISCOUNT, "of which $3 came from the bank");
        assertEq(_vault(), 47_000_000, "and the bank is $3 lighter this instant");
        _assertDiamondBalances("discounted top-up funded");

        _claimByArbiter(a);
        _submitAndFinalize(a, true);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            RAISED_FLOOR,
            "the arbiter is owed the floor, both halves of the top-up included"
        );
        assertEq(_subsidy(a), 0, "the reservation is gone with the dispute");
        _assertDiamondBalances("verdict executed");

        // ⚠️ A DELTA AND NOT A BALANCE SINCE 22 SEPTEMBER 2026. The arbiter now
        // carries a purse of his own — the rig funds him so he can post the
        // bond each CASE asks for — and his bond for this deal came home at
        // finalization, so an absolute balance here would be measuring the rig's
        // generosity. What the scene is about is what the REWARD paid out.
        uint256 hisBefore = usdc.balanceOf(arbiterAddr);
        vm.prank(arbiterAddr);
        ArbiterVaultFacet(address(diamond)).withdrawArbiterReward();
        assertEq(usdc.balanceOf(arbiterAddr) - hisBefore, RAISED_FLOOR, "and it came out in real money");
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
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));

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
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));

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
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));

        assertEq(_subsidy(a), 1_000_000);
        assertEq(_vault(), 0, "the bank is empty, not negative");
        _assertDiamondBalances("bank drained to the cent");

        _claimByArbiter(a);
        _submitAndFinalize(a, true);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            RAISED_FLOOR,
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
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));
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
    /// Without the reservation both quotes would read $7, both parties would
    /// pay $7, and the second arbiter would be short three dollars of the
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
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a1));
        _trackDeal(address(a1));

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
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a2));
        _trackDeal(address(a2));
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
            RAISED_FLOOR * 2,
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
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a1));
        _trackDeal(address(a1));

        Agreement a2 = _disputedDeal(c2, AMOUNT);
        assertEq(_quote(a2), FULL_TOPUP - 500_000, "fifty cents is what is left");
        vm.prank(c2);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a2));
        _trackDeal(address(a2));

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
        _handIn(a);
        vm.prank(client); a.raiseDispute();

        uint256 before = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        uint256 paid = before - usdc.balanceOf(client);
        assertEq(paid, FULL_TOPUP - DEFAULT_DISCOUNT, "$7 out of his own pocket");
        _trackDeal(address(a));
        assertEq(_vault(), 0, "reserved");

        uint256 afterFunding = usdc.balanceOf(client);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.prank(executor); a.triggerArbiterTimeout();

        assertEq(_vault(), DEFAULT_DISCOUNT, "the bank has its $3 back");
        assertEq(_subsidy(a), 0, "and the reservation is cleared");
        assertEq(_bounty(a), 0);
        // The wallet gains the escrow share the timeout split off, HIS OWN $7,
        // and HIS OWN $10 from the dispute door -- and nothing else. The bank's
        // $3 went home, not to him.
        //
        // ⚠️ THE DOOR CHARGE IS THE TERM THAT WAS MISSING, 21 OCTOBER 2026. The
        // levy is taken when the dispute is OPENED since 20 October and
        // returned when no verdict is delivered, and `before` is read after
        // `raiseDispute` charged him, so its return lands in this subtraction.
        //
        // Worked out by hand. Nothing was charged at the door under the retired
        // rule, so the sum was the escrow share and his top-up share:
        //     75_000_000 + 7_000_000 = 82_000_000
        // -- which is what the line expected, reproduced from its own two
        // terms. What ships:
        //     the escrow share  100_000_000 - 100_000_000 / 4 = 75_000_000
        //     his top-up share  10_000_000 - 3_000_000        =  7_000_000
        //     the door charge   max( 10_000_000, 3_000_000 )  = 10_000_000
        //     in his wallet                                     92_000_000
        //
        // ⚠️ AND THE THREE ARE NAMED SEPARATELY, because the whole subject of
        // the scene is WHOSE money came back: his two sums did and the bank's
        // $3 did not, and a single 92_000_000 would be satisfied by the bank's
        // three dollars arriving while one of his was three dollars short.
        uint256 doorCharge = 10_000_000;
        assertEq(doorCharge, FEE_ON_HUNDRED, "arithmetic: the door charge is not this file's levy on a $100 pot");
        assertEq(
            usdc.balanceOf(client) - afterFunding,
            (AMOUNT - AMOUNT / 4) + paid + doorCharge,
            "his own top-up and his own door charge came back and the bank's share did not follow them"
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
            ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
            uint256 paid = walletBefore - usdc.balanceOf(milker);
            _trackDeal(address(a));

            uint256 afterFunding = usdc.balanceOf(milker);
            // Anchored on the deal's own clock rather than on the loop's: each
            // round starts later than the last one, and a relative warp read
            // the wrong side of the window on the second pass.
            vm.warp(a.disputedAt() + DISPUTE_WINDOW + 1);
            vm.prank(executor); a.triggerArbiterTimeout();

            // Exactly his own money back -- his top-up share AND the door
            // charge he paid to open the dispute -- plus the escrow share the
            // timeout owes him. Not one cent of the discount stuck to him.
            //
            // ⚠️ THE DOOR CHARGE IS THE TERM THAT WAS MISSING, 21 OCTOBER 2026,
            // the same correction as the scene above and derived there in full:
            //     the escrow share  100_000_000 - 100_000_000 / 4 = 75_000_000
            //     his top-up share   10_000_000 - 3_000_000       =  7_000_000
            //     the door charge    max( 10_000_000, 3_000_000 ) = 10_000_000
            //                                                       92_000_000
            // and the retired sum reproduces from its own two terms:
            // 75_000_000 + 7_000_000 = 82_000_000.
            //
            // ⚠️ AND THE SCENE'S CLAIM IS UNCHANGED BY THE EXTRA TERM, which is
            // what matters here: "no gain" means he ends level, and he does --
            // he put the charge in and took the charge out, three times over,
            // and the bank's balance on the line after is the lock that says
            // the discount never became his.
            assertEq(
                usdc.balanceOf(milker) - afterFunding,
                (AMOUNT - AMOUNT / 4) + paid + FEE_ON_HUNDRED,
                "round trip on the top-up and on the door charge, no gain"
            );
        }

        assertEq(_vault(), bankBefore, "three abandoned disputes took nothing out of the bank");
        _assertDiamondBalances("after three abandoned disputes");
    }

    // ⚠️ `testAnOverturnedVerdictReturnsTheBanksShareToTheBank` IS GONE (9 October 2026).
    //   STATE UNREACHABLE BY CONSTRUCTION, and the twin of the scene removed from
    //   test/DisputeFee.t.sol on the same day. It asserted two literals on a $100 pot
    //   -- the bank getting its $3 discount back PLUS the arbiter's forfeited $2.70 --
    //   and both depended on the overturn standing alone, with no appeal deposit
    //   having been refunded out of the bond or the bank first.
    //   ⚠️ WHY NOT SIMPLY MOUNT A PANEL AND RECOMPUTE THE SUMS. Because the scene's
    //   distinguishing condition was "AN OVERTURN WITH NO APPEAL BEHIND IT", and that
    //   state is now unreachable BY CONSTRUCTION rather than merely hard to build:
    //   `v.overturned` is written in exactly one place, inside `resolveAppeal`, which
    //   reverts `NoAppeal` unless `v.appealed` is set -- and `overturn` itself is
    //   `panelFormed && votesOverturn > votesUphold`, so an overturn implies an appeal
    //   AND a panel that read it. Every overturn therefore arrives with a deposit
    //   already refunded out of the case bond or the bank, and the forfeited fee share
    //   repays THAT first. Putting a panel in would not restore this scene; it would
    //   replace it with a different one that already exists.
    //   ⚠️ WHAT IT ASSERTED AND WHERE EACH PART STILL LIVES, checked rather than
    //   assumed, all in test/AppealEconomics.t.sol's
    //   test_OverturnedTheCaseBondCoversTheRefundToTheUnit:
    //     * "the overturned arbiter is paid nothing" -- asserted there verbatim;
    //     * "the treasury keeps its 10% and no more" -- asserted there as $30 of $300;
    //     * "the forfeited 90% goes to the arbiter bank" IN FULL -- this is the part
    //       that is gone, and it is gone because it is no longer true of any reachable
    //       state: the share repays the bond first and the bank takes the remainder.
    //
    // ------------------------------------------------------------
    //  5. The size of the discount is a setting, not a constant
    // ------------------------------------------------------------

    function testTheOwnerMovesTheDiscountAndTheQuoteMovesWithIt() public {
        _fundVault(50_000_000);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        assertEq(_quote(a), FULL_TOPUP - DEFAULT_DISCOUNT);

        ArbiterVaultFacet(address(diamond)).setDisputeDiscount(5_000_000);
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeDiscount(), 5_000_000);
        assertEq(_quote(a), FULL_TOPUP - 5_000_000, "a $5 discount, one transaction later");

        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));
        assertEq(_subsidy(a), 5_000_000);
        assertEq(_vault(), 45_000_000);
        _assertDiamondBalances("after a discount that moved");
    }

    function testTheDiscountIsTheOwnersAloneToMove() public {
        vm.prank(stranger);
        vm.expectRevert(ArbiterRegistryFacet.NotOwner.selector);
        ArbiterVaultFacet(address(diamond)).setDisputeDiscount(9_000_000);
    }

    /// A dispute already funded keeps the split it was funded with: both halves
    /// are in storage, so nothing is recomputed behind anyone's back.
    function testMovingTheDiscountDoesNotMoveADisputeAlreadyFunded() public {
        _fundVault(50_000_000);
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();
        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));

        ArbiterVaultFacet(address(diamond)).setDisputeDiscount(9_000_000);

        assertEq(_bounty(a), FULL_TOPUP, "the promise to the arbiter is unchanged");
        assertEq(_subsidy(a), DEFAULT_DISCOUNT, "and so is the bank's share of it");

        _claimByArbiter(a);
        _submitAndFinalize(a, true);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            RAISED_FLOOR
        );
        assertEq(_vault(), 47_000_000, "the bank paid the old discount, not the new one");
        _assertDiamondBalances("discount moved under a live dispute");
    }

    // ------------------------------------------------------------
    //  6. A discount larger than the top-up
    // ------------------------------------------------------------

    /// A pot big enough that the levy almost reaches the floor on its own, so
    /// the whole top-up is under the $3 discount. The subtraction must not go
    /// negative, and the top-up must not become free: zero from
    /// quoteDisputeTopUp already means "there is nothing to pay", which is what
    /// fundDispute answers with TopUpNotNeeded and what the deal screen answers
    /// by hiding the button.
    ///
    /// ⚠️ THE POT MOVED FROM $300 TO $600 ON 21 OCTOBER 2026, AND IT HAD TO.
    /// This scene's premise is a gross top-up SMALLER than the discount, and on
    /// a $300 pot that premise has ceased to hold: it was reached through the
    /// judge's nine tenths of a 3% levy against a $10 floor, and both of those
    /// moved on 20 October. The scene red with a quote of 7_000_000 against its
    /// expected single coin -- not a wrong figure, a premise that had quietly
    /// stopped being staged, which would have left the clamp below unmeasured
    /// on every pot.
    ///
    /// Worked out by hand, the retired column first so the method can be
    /// checked. At the retired rates on the retired $300 pot:
    ///     the levy        300_000_000 x 300 / 10_000  = 9_000_000
    ///     the judge's 90%   9_000_000 x 9_000 / 10_000 = 8_100_000
    ///     the gross       10_000_000 - 8_100_000      = 1_900_000
    ///     the discount                                  3_000_000, bigger
    /// -- which reproduces the 1_900_000 this scene carried, so the arithmetic
    /// was the right arithmetic. At the live rates the judge keeps the WHOLE
    /// levy and this file raises the floor to $20, so the pot has to be big
    /// enough that 3% of it comes within $3 of twenty dollars -- above
    /// $566.67, by `20_000_000 - 3_000_000 = 17_000_000` and
    /// `17_000_000 / 0.03`. On $600:
    ///     the levy        600_000_000 x 300 / 10_000  = 18_000_000
    ///     the judge's     the whole of it             = 18_000_000
    ///     the gross       20_000_000 - 18_000_000     =  2_000_000
    ///     the discount                                  3_000_000, bigger
    /// and the clamp leaves the party exactly one base unit either way.
    ///
    /// ⚠️ THE SINGLE COIN IS THE ONE FIGURE THAT CANNOT TELL THE TWO ERAS
    /// APART, which is why the gross is asserted beside it: `quoted == 1` was
    /// green under the old rule and is green under the new one, and on a $300
    /// pot today it would be green for neither reason -- it would simply be
    /// 7_000_000. The gross is what says which premise is on the table.
    function testADiscountLargerThanTheTopUpNeitherUnderflowsNorMakesItFree() public {
        _fundVault(50_000_000);
        Agreement a = _disputedDeal(client, 600_000_000);

        uint256 gross = 2_000_000; // the $20 raised floor less the whole $18 levy
        assertEq(a.disputeFee(), 18_000_000, "the levy on a $600 pot is not 3% of it, so this scene's premise is not staged");
        assertTrue(gross < DEFAULT_DISCOUNT, "the top-up is not smaller than the discount, so the clamp below is not being exercised at all");

        uint256 quoted = _quote(a);
        assertEq(quoted, 1, "the party still pays, even if it is the smallest coin there is");
        assertGt(quoted, 0, "and the quote never collapses into the 'nothing to pay' zero");

        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));

        assertEq(_bounty(a), gross, "the arbiter is still promised the whole two dollars");
        assertEq(_subsidy(a), gross - 1, "the bank covered all of it but the last coin");
        assertEq(_vault(), 50_000_000 - (gross - 1));
        _assertDiamondBalances("a discount bigger than the need");

        _claimByArbiter(a);
        _submitAndFinalize(a, true);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            RAISED_FLOOR,
            "still exactly the floor"
        );
    }

    /// The same guard reached from the other side: an enormous discount on an
    /// ordinary pot. The party pays a coin, never nothing, and never a negative.
    function testAnEnormousDiscountStillLeavesTheDisputeCostingSomething() public {
        _fundVault(500_000_000);
        ArbiterVaultFacet(address(diamond)).setDisputeDiscount(400_000_000); // $400

        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(client); a.raiseDispute();

        assertEq(_quote(a), 1, "one millionth of a dollar, and not zero");

        uint256 before = usdc.balanceOf(client);
        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        _trackDeal(address(a));

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
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        assertEq(_vault(), 50_000_000, "and the bank was never touched");
    }
}
