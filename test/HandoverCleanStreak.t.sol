// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// THE SENTENCE THE WHOLE HANDOVER CONDITION IS FOR, MEASURED ON A LIVE DEAL
// (20 September 2026).
//
// `activateDAO()`'s second condition asks three things, and the one that
// carries its meaning is the middle one: disputes finalized IN A ROW on an
// arbiter's own verdict, with no governance hand in any of them. The claim
// underneath it is a single sentence — "a dispute a hand reached into is not
// evidence that the corps judges without me" — and until this file existed
// NOTHING measured it. `test/HandoverLiveness.t.sol` writes the counters
// straight into storage with `vm.store`, so it cannot tell a counter that is
// moved correctly from one that is never moved at all.
//
// ⚠️ WHY THE GAP WAS DANGEROUS RATHER THAN MERELY OPEN. One line above the new
// counters, `finalizeVerdict` already increments `cleanVerdicts[arbiter]`, on
// the WEAKER test `!v.overturned`. Reaching for that counter instead — or
// dropping the `govTouchedDispute` guard — produces exactly the same numbers on
// every dispute nobody touched, which is every dispute in every other suite in
// this repository. The mistake is invisible until somebody freezes a verdict
// and lets it go again, which is scene 2 below and nowhere else.
//
// ⚠️ NOTHING HERE WRITES A COUNTER. Every number this file asserts on is
// produced by the protocol doing its own work: a real Agreement clone is
// deployed, funded, activated, disputed, claimed through the commit/reveal, a
// verdict is submitted, the delay is waited out and `finalizeVerdict` calls
// `resolveDispute` on the clone. The reading is `getHandoverReadiness()`, the
// same one the screen calls. That is the whole point — the scenes are slow and
// long-winded because a shortcut would measure the shortcut.
//
// THE SIX SCENES, and what each one alone kills:
//
//   1. a clean dispute            — the counters never move at all
//   2. frozen and unfrozen        — the `govTouchedDispute` guard removed, or
//                                   the mark not written by `freezeVerdict`
//   3. the case taken off a judge — the mark not written by the owner's branch
//                                   of `releaseDisputeClaim`
//   4. overturned BY THE HAND     — the mark not written by `overturnVerdict`
//   5. overturned BY THE PANEL    — the run reset on a panel overturn, or the
//                                   panel's correction counted as clean
//   6. one arbiter, three closes  — the "different arbiters" term counting
//                                   disputes instead of men
//
// ⚠️ SCENES 4 AND 5 ARE THE SAME EVENT WITH DIFFERENT HANDS ON IT, and telling
// them apart is the owner's decision of 20 September 2026. An overturn by the
// owner or the DAO breaks the run; an overturn voted by the appeal panel leaves
// it standing where it is, because three arbiters correcting a fourth is the
// corps working WITHOUT the owner, which is the sentence the whole condition is
// trying to prove. Before that date there was one scene here, it pressed the
// OWNER'S door, and its name (`test_AnOverturnedVerdictBreaksTheStreak`) claimed
// more than it measured — nothing in this repository had ever put a panel
// overturn through `finalizeVerdict`.

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/Agreement.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

contract MockUSDCCleanStreak {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Allowance exceeded");
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function decimals() external pure returns (uint8) { return 6; }
}

contract HandoverCleanStreakTest is Test {
    DiamondProxy diamond;
    MockUSDCCleanStreak usdc;
    DeployFull deploy;

    address owner;
    address feeRecipient;

    /// Three seats, because the third term of the condition counts MEN.
    address constant JUDGE_A = address(0xA1);
    address constant JUDGE_B = address(0xB2);
    address constant JUDGE_C = address(0xC3);

    uint256 constant AMOUNT   = 100 * 10 ** 6;
    uint256 constant DEADLINE = 7;
    string  constant TERMS    = "clean streak terms";

    /// ArbiterRegistryFacet.ARBITER_BOND, and FINALIZE_DELAY, are private
    /// constants of the facet. Both are written out here rather than read,
    /// which is the rule for an expectation: a test that asked the contract
    /// what its own delay is would wait however long the contract felt like.
    uint256 constant ARBITER_BOND  = 50 * 10 ** 6;
    uint256 constant FINALIZE_WAIT = 72 hours + 1;

    /// APPEAL_DEPOSIT_CAP, written out for the same reason as the two above:
    /// what the appellant is minted has to cover the deposit whatever the price
    /// rule says, and a test that asked the contract how much it wants would
    /// be handed the answer it is supposed to be checking against.
    uint256 constant APPEAL_DEPOSIT_MAX = 200 * 10 ** 6;

    /// Counts up so that every deal gets a client and an executor of its own:
    /// a second live deal between the same pair is refused (ActiveDealExists).
    uint256 partyNonce;

    function setUp() public {
        owner        = address(this);
        feeRecipient = address(0x4);

        usdc   = new MockUSDCCleanStreak();
        deploy = new DeployFull();

        DiamondCutFacet cutFacet            = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet        = new DiamondLoupeFacet();
        OwnershipFacet ownFacet             = new OwnershipFacet();
        RegistryFacet regFacet              = new RegistryFacet();
        FactoryFacet facFacet               = new FactoryFacet();
        JobBoardFacet jobBoard              = new JobBoardFacet();
        ServiceBoardFacet serviceBoard      = new ServiceBoardFacet();
        ArbiterRegistryFacet arbiterFacet   = new ArbiterRegistryFacet();
        ArbiterVaultFacet vaultFacet        = new ArbiterVaultFacet();
        ArbiterAccountabilityFacet accFacet = new ArbiterAccountabilityFacet();
        ArbiterApplicationsFacet appFacet   = new ArbiterApplicationsFacet();
        DealMetadataFacet metaFacet         = new DealMetadataFacet();
        JobReceiptFacet receiptFacet        = new JobReceiptFacet();
        ReputationFacet repFacet            = new ReputationFacet();

        // The production selector lists, not a second hand-written set: a copy
        // would drift and the bench would start proving something about a
        // layout that does not exist.
        IDiamondCut.FacetCut[] memory initCuts = deploy.buildInitCuts(
            address(cutFacet), address(loupeFacet), address(ownFacet), address(regFacet), address(facFacet)
        );
        diamond = new DiamondProxy(owner, initCuts, address(0), "");

        IDiamondCut.FacetCut[] memory remainingCuts = deploy.buildRemainingCuts(
            address(jobBoard), address(serviceBoard), address(arbiterFacet), address(vaultFacet),
            address(accFacet), address(appFacet), address(metaFacet), address(receiptFacet), address(repFacet)
        );
        IDiamondCut(address(diamond)).diamondCut(remainingCuts, address(0), "");

        RegistryFacet(address(diamond)).initRegistry(address(diamond));

        Agreement agreementImpl   = new Agreement();
        AgreementDeployer agDep   = new AgreementDeployer(address(diamond), address(agreementImpl));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDep)
        );

        _seat(JUDGE_A);
        _seat(JUDGE_B);
        _seat(JUDGE_C);
    }

    // ---------- the bench's own doors ----------

    /// A seat by the owner's hand takes no bond, and since 8 September 2026 an
    /// unbonded seat is refused by every arbiter door — so the bond is paid
    /// with real money through the real door.
    function _seat(address who) internal {
        ArbiterRegistryFacet(address(diamond)).addArbiter(who);
        // ⚠️ NO SEAT BOND SINCE 22 SEPTEMBER 2026. What a seated arbiter now
        // needs is money and an allowance for the bond he posts PER CASE, and
        // that is what this leaves him with.
        usdc.mint(who, 1_000_000_000);
        vm.prank(who);
        usdc.approve(address(diamond), type(uint256).max);
    }

    function _reading() internal view returns (HandoverLib.Readiness memory) {
        return ArbiterAccountabilityFacet(address(diamond)).getHandoverReadiness();
    }

    /// A funded, activated, disputed deal between a fresh pair. Everything up
    /// to the point where an arbiter may take it.
    function _disputedDeal() internal returns (address agreementAddr) {
        partyNonce++;
        address cli  = address(uint160(0x1000 + partyNonce));
        address exec = address(uint160(0x2000 + partyNonce));

        usdc.mint(cli, AMOUNT * 10);
        vm.prank(cli);
        usdc.approve(address(diamond), AMOUNT);
        vm.prank(address(diamond));
        agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, exec, address(0), AMOUNT, DEADLINE, TERMS, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(exec);
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();
    }

    /// claimDispute needs a commitment laid in an earlier block — otherwise
    /// CommitmentTooEarly.
    ///
    /// ⚠️ `vm.getBlockNumber()` AND NOT `block.number`, AND THE SAME FOR THE
    /// CLOCK BELOW — measured here on 20 September 2026, not a preference.
    /// `block.number` is the NUMBER opcode, and solc treats it as invariant
    /// inside a call frame: written as `vm.roll(block.number + 1)` in a helper
    /// that a LOOP inlines, it is hoisted out of the loop and every iteration
    /// rolls to the same block. The commit, which happens inside the diamond in
    /// a fresh frame, sees the real number; the claim then arrives in the block
    /// the commit was made in and `CommitmentTooEarly()` comes back. Straight-
    /// line scenes are unaffected, which is why this only showed up in the one
    /// scene that loops — and why the loop is worth having.
    function _claimBy(address agreementAddr, address judge) internal {
        bytes32 salt       = keccak256(abi.encodePacked("clean-streak", agreementAddr, judge));
        bytes32 commitment = keccak256(abi.encodePacked(agreementAddr, judge, salt));
        vm.prank(judge);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(judge);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agreementAddr, salt, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function _submit(address agreementAddr, address judge) internal {
        vm.prank(judge);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreementAddr, true);
    }

    function _finalize(address agreementAddr) internal {
        vm.warp(vm.getBlockTimestamp() + FINALIZE_WAIT);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);
    }

    /// A real appeal, really voted, with no hand of the owner's in it: the
    /// losing party pays the deposit out of his own balance and every seated
    /// arbiter except the one who ruled votes to overturn.
    ///
    /// The quorum this clears is the corps's own: `raiseAppeal` freezes it at
    /// the number of arbiters who could vote (three seats minus the judge, minus
    /// the two parties — two here), capped at three. Two votes therefore both
    /// reach the quorum and carry a strict majority, so `resolveAppeal` settles
    /// on the spot without waiting out the four-day window.
    ///
    /// `_submit` rules for the client, so the EXECUTOR is the losing party and
    /// the only address `raiseAppeal` accepts. He is read off the clone rather
    /// than re-derived from `partyNonce`: the protocol is the one that knows
    /// who its parties are.
    function _panelOverturns(address agreementAddr, address ruling) internal {
        address appellant = Agreement(agreementAddr).executor();
        usdc.mint(appellant, APPEAL_DEPOSIT_MAX);
        vm.prank(appellant);
        usdc.approve(address(diamond), APPEAL_DEPOSIT_MAX);
        vm.prank(appellant);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agreementAddr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        address[3] memory bench = [JUDGE_A, JUDGE_B, JUDGE_C];
        for (uint256 i = 0; i < 3; i++) {
            if (bench[i] == ruling) continue;
            vm.prank(bench[i]);
            ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agreementAddr, true);
        }

        // Anyone may settle it, and nobody in particular does — the votes
        // decide. Pressed here by the test contract, which is also the owner:
        // that is deliberate and costs nothing, because this door is not one of
        // the three that mark a dispute as touched by governance. If it ever
        // becomes one, this scene is where it will show.
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agreementAddr);
    }

    /// The whole clean road, start to finish, by one judge.
    function _cleanDispute(address judge) internal returns (address agreementAddr) {
        agreementAddr = _disputedDeal();
        _claimBy(agreementAddr, judge);
        _submit(agreementAddr, judge);
        _finalize(agreementAddr);
    }

    // ---------- 0. the bench is not lying about where it starts ----------

    function test_AFreshProtocolHasNothingToShowForItself() public view {
        HandoverLib.Readiness memory r = _reading();
        assertEq(r.cleanStreak, 0, "a fresh bench already has a streak");
        assertEq(r.distinctCleanArbiters, 0, "a fresh bench already has judges counted");
        assertEq(r.cleanDisputesTotal, 0, "a fresh bench already has clean disputes");
        assertFalse(r.met, "a fresh bench is ready to hand over governance");
    }

    // ---------- 1. a dispute nobody touched ----------

    /// The baseline claim, and the one every other scene is measured against:
    /// the road works and the counters move by the road.
    function test_ACleanDisputeGrowsTheStreakAndCountsTheJudge() public {
        _cleanDispute(JUDGE_A);

        HandoverLib.Readiness memory r = _reading();
        assertEq(r.cleanStreak, 1, "a clean dispute did not grow the streak");
        assertEq(r.distinctCleanArbiters, 1, "a clean dispute did not count its judge");
        assertEq(r.cleanDisputesTotal, 1, "a clean dispute did not reach the lifetime total");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getCleanVerdicts(JUDGE_A), 1,
            "the per-arbiter counter did not move either"
        );
    }

    // ---------- 2. the hand that leaves no other trace ----------

    // ⚠️ `test_AFrozenAndUnfrozenDisputeBreaksTheStreak` IS GONE (9 October 2026).
    //   THE WRITER IT LOCKED IS GONE. Its subject was the mark that `freezeVerdict`
    //   set: the owner froze a verdict and let it go, `v.frozen` was erased by the
    //   unfreeze, and `govTouchedDispute` was the only record that a hand had ever
    //   been there. Both doors were removed on 9 October 2026 and with them two of
    //   the mark's three writers.
    //   ⚠️ THE PROPERTY IS STILL LOCKED, by the writer that survived. The mark now
    //   has exactly one: `releaseDisputeClaim` when the presser is not the holding
    //   arbiter (`if (caller != current) d.govTouchedDispute[agreement] = true`).
    //   test_TheOwnerTakingACaseOffAJudgeBreaksTheStreak asserts the same thing this
    //   did -- a touched dispute does not feed the run while it does feed the
    //   arbiter's own `cleanVerdicts` -- and its mirror,
    //   test_AJudgeLettingGoOfHisOwnCaseDoesNotBreakTheStreak, still keeps the
    //   over-correction out. What is gone is the second ROAD to the mark, not the
    //   rule about it.
    //
    // ⚠️ `test_AnOverturnByTheHandBreaksTheStreak` IS GONE (9 October 2026).
    //   THE WRITER IT LOCKED IS GONE, and its own docstring says exactly what that
    //   costs: "What it locks: the mark written by `overturnVerdict`. Remove that one
    //   assignment and the hand's press becomes indistinguishable from the panel's."
    //   The assignment went with the door on 9 October 2026.
    //   ⚠️ AND THE DISTINCTION IT GUARDED NO LONGER HAS TWO SIDES. The scene existed
    //   because "an overturned verdict" was two different things -- the hand's, which
    //   broke the run, and the panel's, which leaves it standing. There is only the
    //   panel's now, so there is nothing left to tell apart, and the behaviour of the
    //   one that remains is asserted by scene 5 (the corps overturning a verdict of
    //   its own leaves the run where it is). Should a hand-pressed overturn ever come
    //   back, this scene has to come back with it -- the mark would otherwise be
    //   unwritten and the two would be indistinguishable again.
    //
    /// And the run has to be earned again from zero, not resumed.
    ///
    /// ⚠️ THE HAND IN THIS SCENE IS THE RELEASE NOW, NOT THE FREEZE (9 October
    /// 2026). The three middle lines used to be `freezeVerdict` /
    /// `unfreezeVerdict`, and `govTouchedDispute` — the mark this whole file is
    /// about — had three writers. Two of them went with the two doors, so the
    /// mark now has exactly ONE writer left: `releaseDisputeClaim`, when somebody
    /// other than the holding arbiter presses it.
    ///
    /// What this scene is FOR is unchanged and is not about any particular hand:
    /// the run must be earned again FROM ZERO rather than resumed. So it takes
    /// the surviving writer, which is the same one
    /// test_TheOwnerTakingACaseOffAJudgeBreaksTheStreak uses, and the two scenes
    /// stay different in what they assert — that one that the mark lands, this one
    /// that the run does not pick up where it left off.
    function test_TheStreakStartsAgainFromZeroAfterAHand() public {
        _cleanDispute(JUDGE_A);
        _cleanDispute(JUDGE_A);
        assertEq(_reading().cleanStreak, 2, "two clean disputes did not make a run of two");

        address a = _disputedDeal();
        _claimBy(a, JUDGE_A);
        // The owner takes the case off him — not the arbiter standing down, which
        // is ordinary protocol life and leaves the run alone.
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(a);
        _claimBy(a, JUDGE_B);
        _submit(a, JUDGE_B);
        _finalize(a);
        assertEq(_reading().cleanStreak, 0, "the hand did not throw the run away");

        _cleanDispute(JUDGE_A);
        assertEq(_reading().cleanStreak, 1, "the run resumed instead of starting again");
        assertEq(_reading().cleanDisputesTotal, 3, "the lifetime total lost a dispute it should keep");
    }

    // ---------- 3. the case taken off a judge before any verdict ----------

    /// The third writer of the mark, and the one with no other record at all:
    /// `releaseDisputeClaim` fires before a verdict exists, and its event does
    /// not even name who pressed. A dispute the owner reassigned and a
    /// different arbiter then closed is not proof of a corps working alone.
    function test_TheOwnerTakingACaseOffAJudgeBreaksTheStreak() public {
        _cleanDispute(JUDGE_A);
        assertEq(_reading().cleanStreak, 1, "the bench did not get its first clean dispute");

        address a = _disputedDeal();
        _claimBy(a, JUDGE_A);
        // The owner, not the arbiter: an arbiter letting go of his own case is
        // not a governance hand and must not be marked as one.
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(a);
        _claimBy(a, JUDGE_B);
        _submit(a, JUDGE_B);
        _finalize(a);

        HandoverLib.Readiness memory r = _reading();
        assertEq(r.cleanStreak, 0, "a case the owner reassigned counted as clean");
        assertEq(r.distinctCleanArbiters, 1, "the second judge was counted off a touched dispute");
    }

    /// The mirror of it: the arbiter releasing his OWN claim is ordinary
    /// protocol life and must leave the run alone. Without this scene the
    /// obvious over-correction — mark every release — would pass.
    function test_AJudgeLettingGoOfHisOwnCaseDoesNotBreakTheStreak() public {
        address a = _disputedDeal();
        _claimBy(a, JUDGE_A);
        vm.prank(JUDGE_A);
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(a);
        _claimBy(a, JUDGE_B);
        _submit(a, JUDGE_B);
        _finalize(a);

        HandoverLib.Readiness memory r = _reading();
        assertEq(r.cleanStreak, 1, "an arbiter standing down was treated as a governance hand");
        assertEq(r.distinctCleanArbiters, 1, "the judge who finished it was not counted");
    }

    // ---------- 4. the verdict the OWNER'S HAND did not let stand ----------

    // ---------- 5. the verdict THE CORPS ITSELF did not let stand ----------

    /// ⚠️ THE THIRD OUTCOME, ADDED 20 SEPTEMBER 2026 BY THE OWNER'S DECISION,
    /// and the only one of the three that is neither +1 nor 0. Two arbiters
    /// overturn a third's verdict by vote; no hand goes anywhere near the
    /// dispute. The run must STAND WHERE IT IS — it does not grow, because the
    /// arbiter was wrong and a mistake is not to his credit, and it does not
    /// break, because nobody had to step in. The corps repaired itself, which
    /// is the very thing the condition is asked to measure.
    ///
    /// ⚠️ IT FAILS IN BOTH DIRECTIONS, which is what makes it a lock and not a
    /// decoration: put the old reset back and the first reading is 0 instead of
    /// 1; let a panel overturn count as clean and it is 2.
    ///
    /// ⚠️ AND IT GOES THROUGH THE REAL APPEAL DOOR — deposit paid by the losing
    /// party out of real balances, two real votes, `resolveAppeal`. Reaching
    /// into storage to set `overturned` would have measured the storage.
    function test_APanelOverturnLeavesTheRunWhereItIs() public {
        _cleanDispute(JUDGE_A);
        assertEq(_reading().cleanStreak, 1, "the bench did not get its first clean dispute");

        address a = _disputedDeal();
        _claimBy(a, JUDGE_B);
        _submit(a, JUDGE_B);
        _panelOverturns(a, JUDGE_B);
        assertTrue(
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(a).overturned,
            "the panel did not actually overturn the verdict"
        );
        _finalize(a);

        HandoverLib.Readiness memory r = _reading();
        assertEq(r.cleanStreak, 1, "the corps correcting itself was counted as a hand, or as clean");
        assertEq(r.distinctCleanArbiters, 1, "the overturned judge was counted as proven");
        assertEq(r.cleanDisputesTotal, 1, "an overturned verdict reached the lifetime total");
        // His own record does not grow either: `cleanVerdicts` keys on
        // `!v.overturned`, and the panel overturned him. The two counters agree
        // here and disagree in scene 2 — that pair is the difference between
        // them, drawn from both sides.
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getCleanVerdicts(JUDGE_B), 0,
            "an overturned arbiter kept a clean verdict on his own record"
        );

        // And the run CONTINUES from where it stood rather than starting again:
        // the next clean dispute is the second of a run, not the first.
        _cleanDispute(JUDGE_A);
        assertEq(_reading().cleanStreak, 2, "the run did not continue across the panel's correction");
    }

    // ---------- 6. the court has to be more than one man ----------

    /// The term that says "different arbiters" must count MEN. One seat
    /// closing three disputes is one man, however long his run.
    function test_OneJudgeClosingThreeDisputesIsStillOneJudge() public {
        _cleanDispute(JUDGE_A);
        _cleanDispute(JUDGE_A);
        _cleanDispute(JUDGE_A);

        HandoverLib.Readiness memory r = _reading();
        assertEq(r.cleanStreak, 3, "three clean disputes did not make a run of three");
        assertEq(r.distinctCleanArbiters, 1, "one man closing three disputes read as three judges");
        assertFalse(r.distinctCleanArbitersMet, "one man cleared the 'different arbiters' term");
    }

    /// And three men are three, counted once each however they interleave.
    function test_ThreeJudgesEachClosingOneAreThree() public {
        _cleanDispute(JUDGE_A);
        _cleanDispute(JUDGE_B);
        _cleanDispute(JUDGE_A);
        _cleanDispute(JUDGE_C);
        _cleanDispute(JUDGE_B);

        HandoverLib.Readiness memory r = _reading();
        assertEq(r.distinctCleanArbiters, 3, "the corps was miscounted");
        assertTrue(r.distinctCleanArbitersMet, "three different judges did not clear the term");
        assertEq(r.cleanStreak, 5, "the run was broken by nothing at all");
    }

    // ---------- the whole condition, end to end ----------

    /// ⚠️ THE ONLY SCENE IN THE REPOSITORY WHERE THE HANDOVER'S SECOND
    /// CONDITION IS MET BY WORK RATHER THAN BY `vm.store`. It is slow — eight
    /// full disputes — and it is the answer to "does this bar open at all,
    /// ever". A condition nothing can satisfy looks exactly like a condition
    /// that works.
    function test_TheCorpsCanActuallyEarnTheSecondCondition() public {
        HandoverLib.Readiness memory floors = _reading();
        address[3] memory judges = [JUDGE_A, JUDGE_B, JUDGE_C];
        for (uint256 i = 0; i < floors.cleanStreakFloor; i++) {
            _cleanDispute(judges[i % 3]);
        }

        HandoverLib.Readiness memory r = _reading();
        assertTrue(r.cleanStreakMet, "the corps judged the floor and the term says no");
        assertTrue(r.distinctCleanArbitersMet, "three judges and the term says no");
        // The market term is the one this bench cannot earn without leaving
        // deals open, and every deal here is closed by its own verdict. It is
        // the honest half of the answer: two terms of three are provably
        // reachable, and the third is measured in HandoverLiveness.
        assertFalse(r.liveDealsMet, "every deal was closed and the market still reads as busy");
        assertFalse(r.met, "two terms of three opened the door");
    }
}
