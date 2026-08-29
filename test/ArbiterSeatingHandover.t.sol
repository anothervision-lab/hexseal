// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// "No hand-picked ones" — the owner's decision, word for word, taken on
// 15 August 2026 AFTER the work had been briefed: "hand-picked arbiters will
// have to convert into DAO arbiters, the chief is abolished, the human must step
// out and only the diamond remains, admitting people through a gate". With the
// DAO active a human has no door into the corps at all:
//   • addArbiter      — reverts SeatingHandedOver(); the only way in is
//                        applyAsArbiter (self-enrolment through the
//                        XP/cleanStreak/bond gate);
//   • setChiefArbiter — reverts with the same error; the chief's role is
//                        abolished.
//
// Suspension (suspendArbiter/liftSuspension in ArbiterAccountabilityFacet) is
// deliberately NOT part of this: it is reversible and expires by itself, and the
// owner does not lose it.
//
// activateDAO() additionally requires an already appointed daoAddress — without
// that check the owner could switch the DAO on before naming a successor and
// orphan the corps in one transaction (activateDAO is irreversible and the flag
// is never cleared anywhere in src/): removeArbiterForCause, addArbiter and
// setChiefArbiter would lose their owner without a single address able to
// replace them.
//
// ═══ setDAOAddress is a ratchet too ═══
// setDAOAddress would otherwise be a way round the whole ratchet:
// activateDAO() → setDAOAddress(own_address) → removeArbiterForCause passes
// through the msg.sender == daoAddress branch — the owner would have taken
// removal back with ONE extra transaction, and "the human has stepped out" would
// remain true for only one of the two doors. Fixed: before the DAO is activated
// the owner calls it (naming a successor in advance), and afterwards only the
// CURRENT daoAddress (self-migration). An owner trying to appoint an address
// after activation gets NotCurrentDaoAddress.
//
// ═══ The seam between that fix and the earned threshold ═══
// The two fixes met and produced a new trap: isDaoActive() used to switch ITSELF
// on at the earned threshold (uniqueActiveUsers >= DAO_THRESHOLD), bypassing
// activateDAO() and its DaoAddressNotSet guard (which stands only INSIDE
// activateDAO()). Had the DAO come on by the earned road while daoAddress was
// still zero, and had the setDAOAddress ratchet simply listened to isDaoActive(),
// "only the current daoAddress may call" would have turned into "only address(0)
// may call" — that is, nobody, ever: both doors would have been orphaned
// irreversibly. Fixed by adding `&& d.daoAddress != address(0)` — the ratchet
// only latches once a successor exists and there is physically somebody to hand
// the right to.
//
// A light bench: the facet is deployed on its own, no diamond needed (the same
// device as in the ArbiterProvenance suite). Unlike the ArbiterRemovalForCause
// suite, no slots had to be dug out for
// setDAOAddress/activateDAO/addArbiter/setChiefArbiter — those are ordinary
// functions of this facet. The earned DAO does need the uniqueActiveUsers slot in
// ReputationStorage (8) — the same one found by sweeping in the
// ArbiterRemovalForCause suite (not rediscovered here; the same method would give
// the same number). The third test of that seam (the whole chain — a removal for
// cause working against an appointed successor) lives in the
// ArbiterRemovalForCauseIntegration suite: it needs removeArbiterForCause, and
// that lives in ArbiterAccountabilityFacet, a different contract with a different
// storage on this light bench.

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";

contract ArbiterSeatingHandoverTest is Test {
    ArbiterRegistryFacet facet;

    address owner;

    /// The diamond's owner slot — the same one as in the ArbiterProvenance suite
    /// (DiamondStorage.POSITION + 4), recomputed and verified by running it there.
    bytes32 constant OWNER_SLOT = 0x178642b411f9f4783b21ef338f3e96db6c1272d763f0b7500ec93464dafb8604;

    /// ReputationStorage.POSITION — see src/facets/ReputationFacet.sol.
    bytes32 constant REP_BASE = 0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400;

    /// uniqueActiveUsers — slot 8 in ReputationStorage.Data, found by sweeping in
    /// the ArbiterRemovalForCause suite. The seven fields before it are mappings,
    /// each eating exactly one slot, with no packing.
    uint256 constant SLOT_UNIQUE_ACTIVE_USERS = 8;

    function setUp() public {
        facet = new ArbiterRegistryFacet();
        owner = address(this);
        vm.store(address(facet), OWNER_SLOT, bytes32(uint256(uint160(owner))));
    }

    function _setUniqueActiveUsers(uint256 n) internal {
        vm.store(address(facet), bytes32(uint256(REP_BASE) + SLOT_UNIQUE_ACTIVE_USERS), bytes32(n));
    }

    /// Governance is switched on by three doors in a row, and the order here is no
    /// ornament: skip any one and the next refuses. The threshold, the proposal,
    /// the confirmation BY THE NAMED ADDRESS ITSELF, and only then the owner's
    /// press.
    function _activateDaoWithSuccessor() internal {
        _setUniqueActiveUsers(facet.getDaoThreshold());
        facet.setDAOAddress(address(0xDA0));
        vm.prank(address(0xDA0));
        facet.acceptDAOAddress();
        facet.activateDAO();
    }

    // ---------- addArbiter ----------

    function test_AddArbiterWorksBeforeDao() public {
        facet.addArbiter(address(0xA1));
        assertTrue(facet.isRegisteredArbiter(address(0xA1)), "before the DAO the owner seats as before");
    }

    function test_AddArbiterRevertsAfterDao() public {
        _activateDaoWithSuccessor();
        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        facet.addArbiter(address(0xA1));
    }

    // ---------- setChiefArbiter ----------

    function test_SetChiefArbiterWorksBeforeDao() public {
        facet.setChiefArbiter(address(0xC4));
        assertEq(facet.getChiefArbiter(), address(0xC4), "before the DAO the chief is appointed as before");
    }

    function test_SetChiefArbiterRevertsAfterDao() public {
        _activateDaoWithSuccessor();
        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        facet.setChiefArbiter(address(0xC4));
    }

    // ---------- activateDAO requires an already appointed daoAddress ----------

    function test_ActivateDaoRevertsWithoutDaoAddress() public {
        vm.expectRevert(ArbiterRegistryFacet.DaoAddressNotSet.selector);
        facet.activateDAO();
    }

    function test_ActivateDaoSucceedsAfterDaoAddressSet() public {
        _activateDaoWithSuccessor();
        assertTrue(facet.isDaoActive(), "the successor confirmed and the threshold reached: switching on goes through");
    }

    /// ⚠️ A PROPOSAL ALONE IS NOT ENOUGH. The owner named an address and stopped
    /// there: `daoAddress` is still zero, so governance cannot be switched on
    /// either. Exactly the typo the second step was introduced for — only here it
    /// shows as a refusal rather than as the loss of the whole governance system.
    function test_ActivateDaoStillRefusesWhileTheSuccessorHasNotConfirmed() public {
        _setUniqueActiveUsers(facet.getDaoThreshold());
        facet.setDAOAddress(address(0xDA0));

        vm.expectRevert(ArbiterRegistryFacet.DaoAddressNotSet.selector);
        facet.activateDAO();
    }

    // ---------- the threshold as a condition of switching on by hand ----------

    /// THE THRESHOLD SWITCHES NOTHING ON BY ITSELF. The counter is ten times over
    /// and governance stays silent, with all three of the owner's doors open as
    /// before.
    ///
    /// The mutation "put the earned half back into isDaoActive()" turns exactly
    /// this test red: it is the only scene on this bench where the counter is
    /// raised and the predicate's answer is checked.
    function test_TheThresholdAloneActivatesNothing() public {
        _setUniqueActiveUsers(facet.getDaoThreshold() * 10);

        assertFalse(facet.isDaoActive(), "a counter of outsiders does not switch governance on");

        facet.addArbiter(address(0xA1));
        assertTrue(facet.isRegisteredArbiter(address(0xA1)), "the owner still has seating");
        facet.setChiefArbiter(address(0xC4));
        assertEq(facet.getChiefArbiter(), address(0xC4), "the chief is not abolished");
    }

    /// The lower boundary: one below the threshold refuses, and the refusal names
    /// BOTH numbers, so that a form can show "this many out of that many".
    function test_ActivateDaoRefusesOneShortOfTheThreshold() public {
        uint256 need = facet.getDaoThreshold();
        _setUniqueActiveUsers(need - 1);
        facet.setDAOAddress(address(0xDA0));
        vm.prank(address(0xDA0));
        facet.acceptDAOAddress();

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterRegistryFacet.DaoThresholdNotReached.selector, need - 1, need
            )
        );
        facet.activateDAO();
        assertFalse(facet.isDaoActive(), "a refusal did not leave half of a switch-on behind");
    }

    /// The upper boundary: EXACTLY the threshold passes. Both halves of the
    /// boundary are needed together: one without the other does not tell `>=` from
    /// `>` or from "always refuse".
    ///
    /// The number is taken from the contract (`getDaoThreshold`), while its EQUALITY
    /// to ten thousand is guarded by a separate test with a literal — otherwise the
    /// scene would agree with itself at any value of the constant.
    function test_ActivateDaoPassesExactlyAtTheThreshold() public {
        _setUniqueActiveUsers(facet.getDaoThreshold());
        facet.setDAOAddress(address(0xDA0));
        vm.prank(address(0xDA0));
        facet.acceptDAOAddress();

        facet.activateDAO();
        assertTrue(facet.isDaoActive(), "exactly at the threshold, switching on goes through");
    }

    /// A literal written down by a person rather than derived from the thing under
    /// test. The decision named the number out loud: ten thousand unique addresses
    /// that CLOSED a deal.
    function test_TheThresholdIsTenThousand() public view {
        assertEq(facet.getDaoThreshold(), 10_000, "the handover threshold is 10 000");
    }

    // ---------- the two steps of handing over the DAO address ----------

    /// One who has been named but has not confirmed holds NOTHING. This is checked
    /// by selector and on a genuine owner-or-DAO door (`onlyOwnerOrDAO`): after the
    /// confirmation the same call passes the role check and runs into the absence
    /// of a verdict instead — that is, the refusal changed, and changed to
    /// precisely the right one.
    function test_ProposedSuccessorHasNoPowerUntilHeConfirms() public {
        facet.setDAOAddress(address(0xDA0));
        assertEq(facet.getPendingDAOAddress(), address(0xDA0), "the proposal is recorded");
        assertEq(facet.getDAOAddress(), address(0), "but the rights have not moved");

        vm.prank(address(0xDA0));
        vm.expectRevert(ArbiterRegistryFacet.NotOwnerOrDAO.selector);
        facet.freezeVerdict(address(0xDEA1));

        vm.prank(address(0xDA0));
        facet.acceptDAOAddress();

        assertEq(facet.getDAOAddress(), address(0xDA0), "the confirmation handed the right over");
        assertEq(facet.getPendingDAOAddress(), address(0), "the proposal is spent");

        vm.prank(address(0xDA0));
        vm.expectRevert(ArbiterRegistryFacet.NoVerdict.selector);
        facet.freezeVerdict(address(0xDEA1));
    }

    /// Somebody else's proposal cannot be confirmed — otherwise the second step
    /// would prove that the door opens for SOMEBODY, not for the one named.
    function test_StrangerCannotConfirmSomebodyElsesProposal() public {
        facet.setDAOAddress(address(0xDA0));

        vm.prank(address(0xBEEF));
        vm.expectRevert(ArbiterRegistryFacet.NotProposedDaoAddress.selector);
        facet.acceptDAOAddress();

        assertEq(facet.getDAOAddress(), address(0), "a stranger's press moved nothing");
    }

    /// And on an empty space there is nothing to confirm: no proposal means the same
    /// refusal, and the code has no separate branch for zero and needs none.
    function test_ConfirmingWithNoProposalIsRefused() public {
        vm.prank(address(0xDA0));
        vm.expectRevert(ArbiterRegistryFacet.NotProposedDaoAddress.selector);
        facet.acceptDAOAddress();
    }

    /// The typo the second step was written for. The owner named an address with no
    /// keys behind it; nobody will confirm, so `daoAddress` does not move, so the
    /// owner simply names another. Before the second step existed, this same typo
    /// would have meant that nobody at all could remove an arbiter any more.
    function test_ATypoIsSurvivableBecauseItNeverConfirms() public {
        address typo = address(0xDEAD);
        facet.setDAOAddress(typo);
        assertEq(facet.getDAOAddress(), address(0), "the typo received no rights");

        facet.setDAOAddress(address(0xDA0));
        vm.prank(address(0xDA0));
        facet.acceptDAOAddress();

        assertEq(facet.getDAOAddress(), address(0xDA0), "the second attempt took the place of the first");
        vm.prank(typo);
        vm.expectRevert(ArbiterRegistryFacet.NotProposedDaoAddress.selector);
        facet.acceptDAOAddress();
    }

    // ---------- setDAOAddress is a ratchet too ----------

    function test_SetDaoAddressWorksBeforeDaoAsOwner() public {
        facet.setDAOAddress(address(0xDA0));
        assertEq(facet.getPendingDAOAddress(), address(0xDA0), "before the DAO the owner names a successor as before");
        vm.prank(address(0xDA0));
        facet.acceptDAOAddress();
        assertEq(facet.getDAOAddress(), address(0xDA0), "and the successor takes office in their own transaction");
    }

    /// Exactly the hole a review found: after activating the DAO the owner tries to
    /// appoint THEMSELVES (or anyone) as daoAddress again — and must be refused,
    /// otherwise through activateDAO() → setDAOAddress(...) → removeArbiterForCause
    /// they would take removal back with one extra transaction.
    function test_SetDaoAddressRevertsForOwnerAfterDao() public {
        _activateDaoWithSuccessor(); // daoAddress = 0xDA0
        vm.expectRevert(ArbiterRegistryFacet.NotCurrentDaoAddress.selector);
        facet.setDAOAddress(address(0xBEEF));
    }

    /// The symmetrical half: the ACTING daoAddress may migrate itself (the DAO
    /// changes its implementation or contract address) — the right is not locked
    /// away forever, it belongs to the current holder.
    function test_SetDaoAddressSucceedsForCurrentDaoAfterDao() public {
        _activateDaoWithSuccessor(); // daoAddress = 0xDA0
        vm.prank(address(0xDA0));
        facet.setDAOAddress(address(0xBEEF));
        assertEq(
            facet.getDAOAddress(), address(0xDA0),
            "until the successor's successor confirms, the right stays with the previous holder: the migration is not seamless and must not be"
        );
        vm.prank(address(0xBEEF));
        facet.acceptDAOAddress();
        assertEq(facet.getDAOAddress(), address(0xBEEF), "the current daoAddress migrates itself");
    }

    // ---------- an earned DAO with a zero successor ----------

    /// ⚠️ THAT TRAP WAS CLOSED FROM THE OTHER END. The state "the DAO came on by
    /// itself, there is no successor yet" no longer occurs: it stopped coming on by
    /// itself, and switching on by hand requires an already confirmed successor. The
    /// `&& d.daoAddress != address(0)` clause is still in the code — its scenes now
    /// live on the direct-storage-write bench (the ArbiterRemovalForCause suite),
    /// while what is checked here is what is reachable through the real doors: until
    /// the owner presses, the counter closes nothing.
    ///
    /// The second test remains and has been rewritten onto the manual road: as soon
    /// as the successor HAS TAKEN OFFICE, the ratchet holds as it held — the owner
    /// can no longer act, the acting daoAddress can.
    function test_SetDaoAddressRatchetsOnceTheSuccessorIsInOffice() public {
        _activateDaoWithSuccessor(); // daoAddress = 0xDA0, governance is on

        vm.expectRevert(ArbiterRegistryFacet.NotCurrentDaoAddress.selector);
        facet.setDAOAddress(address(0xBEEF)); // the owner tries again: refused

        vm.prank(address(0xDA0));
        facet.setDAOAddress(address(0xBEEF)); // the acting daoAddress names its own
        vm.prank(address(0xBEEF));
        facet.acceptDAOAddress();
        assertEq(facet.getDAOAddress(), address(0xBEEF));
    }

    // ============================================================
    //  AN EARNED THRESHOLD USED TO CLOSE THE SEATING DOORS IRREVERSIBLY, AND AN
    //  OUTSIDER COULD PRESS IT.
    //
    //  `uniqueActiveUsers >= DAO_THRESHOLD` used only to OPEN the self-enrolment
    //  door (applyAsArbiter). Later work made it a LOCK on addArbiter and
    //  setChiefArbiter as well. Meanwhile the DaoAddressNotSet guard stands ONLY
    //  inside activateDAO() — that is, on the manual door; the automatic one was
    //  protected by nothing, and the cost of pressing it is measured in this very
    //  project (src/Treasury.sol: the threshold is reachable for money, and on a
    //  testnet simply for an outsider's time).
    //
    //  The result before the fix: a STRANGER permanently deprived the owner of the
    //  right to seat arbiters, and the corps could only be replenished by
    //  self-enrolment through the MIN_XP_TO_REGISTER = 3000 gate, which a live
    //  hand-picked arbiter (XP 0) does not satisfy.
    //
    //  Fixed by the same device already applied to setDAOAddress: the handover
    //  latches ONLY when a successor really exists. isDaoActive() was NOT touched —
    //  it is read by the already deployed and immutable src/Treasury.sol for its
    //  revenue proportions.
    //
    //  ⚠️ A LATER EDIT TOOK THAT RELAXATION AWAY FROM ONE OF THE TWO DOORS. It had
    //  been applied to both, and it is right only for addArbiter: that one is about
    //  SEATING ARBITERS, and while there is no successor there is nobody to seat
    //  them but the owner. setChiefArbiter is about the CHIEF'S ROLE, and that is
    //  abolished earlier, on isDaoActive() alone: a chief appointed in the interval
    //  is powerless, because both onlyOwnerOrChief modifiers no longer see them.
    //  Below are two tests with OPPOSITE expectations — as it should be, since the
    //  predicates on the two doors are different.
    // ============================================================

    /// ⚠️ REWRITTEN ONTO WHAT REMAINED REACHABLE. The interval "the DAO is earned,
    /// there is no successor" no longer occurs; the one reachable state with the
    /// counter over the line is "governance is not switched on yet", and in it the
    /// owner seats as before.
    function test_AddArbiterStillWorksWhenTheThresholdIsPastButNobodyPressed() public {
        _setUniqueActiveUsers(facet.getDaoThreshold() * 10);
        assertFalse(facet.isDaoActive(), "the counter is over the line and governance is not on");
        assertEq(facet.getDAOAddress(), address(0), "setup: there is no successor yet");

        facet.addArbiter(address(0xA1));

        assertTrue(
            facet.isRegisteredArbiter(address(0xA1)),
            "until the owner presses, there is nobody to seat but them, and they must be able to"
        );
    }

    /// ⚠️ THIS HALF WAS INVERTED BY A LATER EDIT. Before it the test asserted the
    /// opposite — that a chief is appointed in the interval — and that was a seam
    /// error: setChiefArbiter took the predicate of the SEATING HANDOVER although it
    /// is about ABOLISHING THE ROLE. In the interval (the DAO earned, no successor
    /// named yet) the call wrote the slot and emitted the event, although the
    /// appointed chief was already powerless: both onlyOwnerOrChief modifiers read
    /// isDaoActive() and do not see them while the DAO is live. getChiefArbiter()
    /// honestly returned an address while the public docs/DECENTRALIZATION.md said
    /// the role no longer existed.
    ///
    /// The discriminator is test_SetChiefArbiterWorksBeforeDao above: before the DAO
    /// is switched on the appointment goes through. Without it this test would not
    /// tell abolition of the role from "setChiefArbiter broke altogether".
    /// ⚠️ AND THIS HALF WAS INVERTED ONCE MORE. The first inversion said the chief's
    /// role is abolished EARLIER than the seating handover, on isDaoActive() alone.
    /// The condition stayed the same, but isDaoActive() stopped being switched on by
    /// the counter — so a threshold that has been passed no longer abolishes the
    /// role.
    ///
    /// The discriminator is test_SetChiefArbiterRevertsAfterDao above: after the
    /// manual switch-on the same call reverts SeatingHandedOver. The difference
    /// between the scenes is exactly whether a human pressed.
    function test_SetChiefArbiterSurvivesTheThresholdUntilSomebodyPresses() public {
        _setUniqueActiveUsers(facet.getDaoThreshold() * 10);
        assertFalse(facet.isDaoActive(), "the counter is over the line and governance is not on");

        facet.setChiefArbiter(address(0xC4));

        assertEq(facet.getChiefArbiter(), address(0xC4), "the chief's role is alive until the press");
    }

    /// The symmetrical half of both: as soon as governance is on, both doors close
    /// irreversibly — which is exactly what they were being closed for. This used to
    /// read "a named successor with an earned DAO"; being named is not enough, the
    /// press is mandatory.
    function test_AddArbiterRatchetsOnceGovernanceIsOn() public {
        _activateDaoWithSuccessor();

        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        facet.addArbiter(address(0xA1));
    }

    function test_SetChiefArbiterRatchetsOnceGovernanceIsOn() public {
        _activateDaoWithSuccessor();

        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        facet.setChiefArbiter(address(0xC4));
    }

    // ============================================================
    //  HALF OF THIS FACET
    //
    //  The chief stops existing while the DAO is active, because otherwise they
    //  become IRREMOVABLE: setChiefArbiter is the only writer of the slot and the
    //  only way to zero it, and it is itself closed under the DAO. What is checked
    //  here is the one function of this facet under onlyOwnerOrChief — addArbiter.
    //  The four functions of the other half (suspension, lifting a suspension,
    //  proposing a removal, withdrawing a proposal) live in the
    //  ArbiterRemovalForCause suite.
    // ============================================================

    function test_ChiefCanAddArbiterBeforeDao() public {
        facet.setChiefArbiter(address(0xC4));
        vm.prank(address(0xC4));
        facet.addArbiter(address(0xA1));
        assertTrue(facet.isRegisteredArbiter(address(0xA1)), "before the DAO the chief seats as before");
    }

    /// The refusal has to be NotOwnerOrChief and not SeatingHandedOver: the modifier
    /// stands BEFORE the body, and the distinction here is not cosmetic —
    /// SeatingHandedOver would mean "the chief still exists, the door is simply
    /// closed to everybody", that is, all their OTHER rights (in the neighbouring
    /// facet) are still theirs. What is checked is the abolition of the role, not
    /// the closing of one door.
    function test_ChiefLosesAddArbiterAfterDao() public {
        facet.setChiefArbiter(address(0xC4));
        _activateDaoWithSuccessor();

        vm.prank(address(0xC4));
        vm.expectRevert(ArbiterRegistryFacet.NotOwnerOrChief.selector);
        facet.addArbiter(address(0xA1));
    }

    /// THE DISCRIMINATOR BETWEEN THE TWO REFUSALS, and it survived by a change of
    /// scene rather than of meaning. The state used to be chosen by an earned
    /// threshold (the chief already powerless, the owner still seating); now it is
    /// taken after governance is switched on, where two parties get DIFFERENT
    /// refusals to one and the same call: the chief gets NotOwnerOrChief from the
    /// modifier (the role is abolished), the owner gets SeatingHandedOver from the
    /// ratchet in the body (the role is theirs, the door has moved away).
    ///
    /// One refusal for both would mean that abolition of the role is not told apart
    /// from the closing of one door — and those are two different statements about
    /// what the human has left.
    function test_ChiefAndOwnerGetDifferentRefusalsAfterGovernanceIsOn() public {
        facet.setChiefArbiter(address(0xC4));
        _activateDaoWithSuccessor();

        vm.prank(address(0xC4));
        vm.expectRevert(ArbiterRegistryFacet.NotOwnerOrChief.selector);
        facet.addArbiter(address(0xA1));

        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        facet.addArbiter(address(0xA1));
    }
}
