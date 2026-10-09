// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// No hand-picked ones — decided on 15 August 2026, AFTER the work had been
// briefed: hand-picked arbiters convert into DAO arbiters, the chief is
// abolished, the human steps out and only the diamond remains, admitting
// people through a gate. With the DAO active a human has no door into the
// corps at all:
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
// ArbiterRemovalForCauseIntegration suite.
//
// ~~it needs removeArbiterForCause, and that lives in ArbiterAccountabilityFacet,
// a different contract with a different storage on this light bench.~~ -- that
// was true of the ONE-facet bench and stopped being true when this suite moved
// onto ArbiterTwoFacetBench (16 September 2026), which mounts both arbiter facets
// behind a single proxy. Struck through rather than deleted because it explains
// why the integration scene lives where it does. Since 9 October 2026 this suite
// does reach the accountability facet directly, for the one probe whose
// `owner OR dao` door the cut removed -- see
// test_ProposedSuccessorHasNoPowerUntilHeConfirms.

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";
import {HandoverReadinessSeed} from "./HandoverReadinessSeed.sol";

contract ArbiterSeatingHandoverTest is Test, ArbiterTwoFacetBench, HandoverReadinessSeed {
    ArbiterRegistryFacet facet;
    ArbiterVaultFacet facetVault;
    /// The third handle onto the SAME address. Taken since 9 October 2026: the
    /// only `owner OR dao` door this suite used as a probe (`freezeVerdict`) is
    /// gone, and the nearest surviving one lives on the accountability facet.
    ArbiterAccountabilityFacet facetAcc;

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

    /// ⚠️ ONE ADDRESS, THREE HANDLES (16 September 2026). This suite used to
    /// deploy a bare `new ArbiterRegistryFacet()` and call it directly, which
    /// stopped being possible when the reads it asserts on (isRegisteredArbiter,
    /// getChiefArbiter, getDAOAddress, getPendingDAOAddress) moved into
    /// ArbiterVaultFacet: two `new`s are two storages at one offset, and the
    /// second would answer a clean zero. The shared bench mounts both facets
    /// behind one proxy, exactly as production does, and every `vm.store(address(
    /// facet), ...)` below keeps hitting the same slot it always did.
    function setUp() public {
        (facet, facetAcc, facetVault) = _deployArbiterBench();
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
        _seedHandoverLiveness(address(facet));
        facet.activateDAO();
    }

    // ---------- addArbiter ----------

    function test_AddArbiterWorksBeforeDao() public {
        facet.addArbiter(address(0xA1));
        assertTrue(facetVault.isRegisteredArbiter(address(0xA1)), "before the DAO the owner seats as before");
    }

    function test_AddArbiterRevertsAfterDao() public {
        _activateDaoWithSuccessor();
        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        facet.addArbiter(address(0xA1));
    }

    // ---------- setChiefArbiter ----------

    function test_SetChiefArbiterWorksBeforeDao() public {
        facet.setChiefArbiter(address(0xC4));
        assertEq(facetVault.getChiefArbiter(), address(0xC4), "before the DAO the chief is appointed as before");
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
        assertTrue(facetVault.isRegisteredArbiter(address(0xA1)), "the owner still has seating");
        facet.setChiefArbiter(address(0xC4));
        assertEq(facetVault.getChiefArbiter(), address(0xC4), "the chief is not abolished");
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
        _seedHandoverLiveness(address(facet));

        facet.activateDAO();
        assertTrue(facet.isDaoActive(), "exactly at the threshold, switching on goes through");
    }

    /// A literal written down by a person rather than derived from the thing under
    /// test. The decision named the number out loud: one thousand unique addresses
    /// that CLOSED a deal and took XP for it.
    ///
    /// ⚠️ 10 000 → 1 000 on 20 September 2026, and the scene above
    /// (test_ActivateDaoPassesExactlyAtTheThreshold) would agree with ANY value
    /// of the constant — it takes the number from `getDaoThreshold()`. This line
    /// is the only thing in the suite that would notice the constant moving on
    /// its own, which is exactly why it is written out by hand.
    function test_TheThresholdIsOneThousand() public view {
        assertEq(facet.getDaoThreshold(), 1_000, "the handover threshold is 1 000");
    }

    // ---------- the two steps of handing over the DAO address ----------

    /// One who has been named but has not confirmed holds NOTHING, and once the
    /// hand-over has gone through he does. Checked by selector on a real door, so
    /// that "the rights have not moved" is a refusal somebody gets rather than a
    /// getter agreeing with itself.
    ///
    /// ⚠️ THE PROBE CHANGED ON 9 OCTOBER 2026 AND SO DID ITS SHAPE -- said
    /// plainly, because the second half of this scene no longer isolates what it
    /// used to. The old probe was `freezeVerdict` under `onlyOwnerOrDAO`, and
    /// that modifier admitted the owner ALWAYS and the `daoAddress` ALWAYS,
    /// caring nothing for whether governance was switched on. That made it a
    /// clean instrument for one question: does CONFIRMATION ALONE move the right?
    ///
    /// The cut removed the last door of that shape. Measured rather than assumed:
    /// after it, nothing in `ArbiterRegistryFacet` raises `NotOwnerOrDAO` at all
    /// (the error is kept as a declaration), and `setDAOAddress` is owner XOR dao
    /// rather than owner OR dao -- and it is the function under test here, so it
    /// cannot be its own probe.
    ///
    /// The nearest surviving door is `removeArbiterForCause`, whose authority
    /// comes from `_removalAuthority`: the successor once
    /// `_isDaoActive() && daoAddress != 0`, the owner until then. So the probe
    /// now needs ACTIVATION as well as confirmation, and the scene is written to
    /// say which step it is actually showing:
    ///
    ///   * BEFORE confirmation the successor is refused by the role check. This
    ///     is the half the scene was named for and it is unchanged -- and it is
    ///     genuinely a statement about confirmation, because `activateDAO()`
    ///     refuses while `daoAddress` is zero, so no sequence reaches authority
    ///     without confirming first.
    ///   * AFTER the hand-over the same call clears the role check and falls
    ///     through to `NotAnArbiter` -- the refusal changed, and changed to
    ///     precisely the right one.
    ///   * What the door can no longer separate is confirmation from activation.
    ///     That gap is covered beside it, by state rather than by a refusal:
    ///     `getDAOAddress()` is still zero before the confirmation and holds the
    ///     successor after it, with the proposal spent.
    function test_ProposedSuccessorHasNoPowerUntilHeConfirms() public {
        _setUniqueActiveUsers(facet.getDaoThreshold());
        facet.setDAOAddress(address(0xDA0));
        assertEq(facetVault.getPendingDAOAddress(), address(0xDA0), "the proposal is recorded");
        assertEq(facetVault.getDAOAddress(), address(0), "but the rights have not moved");

        vm.prank(address(0xDA0));
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwner.selector);
        facetAcc.removeArbiterForCause(
            address(0xDEA1), ArbiterAccountabilityFacet.Cause.Collusion, bytes32(uint256(0xE1)), address(0), "named, not seated"
        );

        vm.prank(address(0xDA0));
        facet.acceptDAOAddress();

        assertEq(facetVault.getDAOAddress(), address(0xDA0), "the confirmation handed the right over");
        assertEq(facetVault.getPendingDAOAddress(), address(0), "the proposal is spent");

        _seedHandoverLiveness(address(facet));
        facet.activateDAO();

        vm.prank(address(0xDA0));
        vm.expectRevert(ArbiterAccountabilityFacet.NotAnArbiter.selector);
        facetAcc.removeArbiterForCause(
            address(0xDEA1), ArbiterAccountabilityFacet.Cause.Collusion, bytes32(uint256(0xE1)), address(0), "named, not seated"
        );
    }

    /// Somebody else's proposal cannot be confirmed — otherwise the second step
    /// would prove that the door opens for SOMEBODY, not for the one named.
    function test_StrangerCannotConfirmSomebodyElsesProposal() public {
        facet.setDAOAddress(address(0xDA0));

        vm.prank(address(0xBEEF));
        vm.expectRevert(ArbiterRegistryFacet.NotProposedDaoAddress.selector);
        facet.acceptDAOAddress();

        assertEq(facetVault.getDAOAddress(), address(0), "a stranger's press moved nothing");
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
        assertEq(facetVault.getDAOAddress(), address(0), "the typo received no rights");

        facet.setDAOAddress(address(0xDA0));
        vm.prank(address(0xDA0));
        facet.acceptDAOAddress();

        assertEq(facetVault.getDAOAddress(), address(0xDA0), "the second attempt took the place of the first");
        vm.prank(typo);
        vm.expectRevert(ArbiterRegistryFacet.NotProposedDaoAddress.selector);
        facet.acceptDAOAddress();
    }

    // ---------- setDAOAddress is a ratchet too ----------

    function test_SetDaoAddressWorksBeforeDaoAsOwner() public {
        facet.setDAOAddress(address(0xDA0));
        assertEq(facetVault.getPendingDAOAddress(), address(0xDA0), "before the DAO the owner names a successor as before");
        vm.prank(address(0xDA0));
        facet.acceptDAOAddress();
        assertEq(facetVault.getDAOAddress(), address(0xDA0), "and the successor takes office in their own transaction");
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
            facetVault.getDAOAddress(), address(0xDA0),
            "until the successor's successor confirms, the right stays with the previous holder: the migration is not seamless and must not be"
        );
        vm.prank(address(0xBEEF));
        facet.acceptDAOAddress();
        assertEq(facetVault.getDAOAddress(), address(0xBEEF), "the current daoAddress migrates itself");
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
        assertEq(facetVault.getDAOAddress(), address(0xBEEF));
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
        assertEq(facetVault.getDAOAddress(), address(0), "setup: there is no successor yet");

        facet.addArbiter(address(0xA1));

        assertTrue(
            facetVault.isRegisteredArbiter(address(0xA1)),
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

        assertEq(facetVault.getChiefArbiter(), address(0xC4), "the chief's role is alive until the press");
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
    //  THE CHIEF AND THE ONE DOOR OF THIS FACET HE USED TO HAVE
    //
    //  ⚠️ HE LOST IT ON 22 SEPTEMBER 2026, and this section is what is left
    //  to say about it. `addArbiter` was the only function of this facet under
    //  `onlyOwnerOrChief`; the owner's decision made it `onlyOwner`, on the
    //  argument that it is the one entrance into the corps that measures
    //  nothing — a name and a press — and it was held by a man who had himself
    //  been appointed.
    //
    //  The abolition of the ROLE under live governance is unchanged and still
    //  matters: the chief's four remaining rights (suspension, lifting a
    //  suspension, proposing a removal, withdrawing a proposal) live in
    //  ArbiterAccountabilityFacet and are guarded by ITS copy of the modifier.
    //  Those scenes are in the ArbiterRemovalForCause suite.
    // ============================================================

    /// The chief is refused BEFORE the DAO, which is the whole change: the door
    /// was his until 22 September 2026 and is the owner's now.
    function test_ChiefCannotAddArbiterEvenBeforeTheDao() public {
        facet.setChiefArbiter(address(0xC4));
        assertFalse(facet.isDaoActive(), "setup: governance is on, so this proves less");

        vm.prank(address(0xC4));
        vm.expectRevert(ArbiterRegistryFacet.NotOwner.selector);
        facet.addArbiter(address(0xA1));
        assertFalse(facetVault.isRegisteredArbiter(address(0xA1)), "the chief seated him anyway");

        // The owner's press on the same man goes through, so the refusal is
        // about who pressed.
        facet.addArbiter(address(0xA1));
        assertTrue(facetVault.isRegisteredArbiter(address(0xA1)), "the owner lost the door too");
    }

    /// THE DISCRIMINATOR BETWEEN THE TWO REFUSALS, and it survived the change.
    /// After governance is switched on, two parties get DIFFERENT refusals to
    /// one and the same call: a chief gets `NotOwner` from the modifier, the
    /// owner gets `SeatingHandedOver` from the ratchet in the body.
    ///
    /// One refusal for both would mean "you are not allowed" and "the door has
    /// moved away" could not be told apart — two different statements about
    /// what the person has left.
    ///
    /// ⚠️ THE CHIEF'S HALF NOW SAYS `NotOwner` AND NOT `NotOwnerOrChief`, and
    /// the loss is worth naming: the refusal used to carry "the role is
    /// abolished" and now carries "this was never yours". For this door that is
    /// the truth; the abolition of the role is still measured, on the doors he
    /// actually has, in the ArbiterRemovalForCause suite.
    function test_ChiefAndOwnerGetDifferentRefusalsAfterGovernanceIsOn() public {
        facet.setChiefArbiter(address(0xC4));
        _activateDaoWithSuccessor();

        vm.prank(address(0xC4));
        vm.expectRevert(ArbiterRegistryFacet.NotOwner.selector);
        facet.addArbiter(address(0xA1));

        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        facet.addArbiter(address(0xA1));
    }
}
