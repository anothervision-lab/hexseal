// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Removing an arbiter with a cause.
//
// Half of the real causes can be verified by the chain and half never can. If both
// look the same in the record, "proof on chain" becomes a lie for the second half.
// So a cause is a CODE, and the chain knows which codes it is obliged to check:
//   • OverturnedVerdicts / Timeouts / Silence — it checks them itself, and without
//     the evidence the transaction refuses;
//   • Collusion / Leak / Other — it checks nothing and does not pretend to: it
//     requires a non-empty digest of the evidence and marks the record
//     verifiedByChain = false.
//
// The right of removal is handed over, not locked away: before the handover only
// the owner calls it, afterwards only daoAddress. "Afterwards" is the pair "the DAO
// is active AND a successor is named", the same predicate as on the seating door:
// `isDaoActive()` alone is not enough, since it used to switch itself on at the
// earned threshold, by somebody else's action, and in the window with no successor
// nobody opened the door at all. The hole in the first version of this design
// ("after the DAO nobody can") was found by the owner BEFORE implementation: there
// is no arbiter voting in the code, daoAddress defaults to zero, and a plain lock
// would mean that collusion and a leaked chat log become entirely unremovable once
// the DAO is switched on — the automatic path catches only what the chain can see.
//
// ⚠️ The slot offsets below were obtained by a throwaway sweep (offset 0..59,
// writing a probe value, comparing against the production getter) and NOT taken
// from an assumption: the obvious guesses missed twice (arbiterMistakeStreak was
// assumed to be 18, the reality is 11; packing chiefArbiter/daoActiveManual into
// one slot 5 shifts the indices of every field after it back by one relative to a
// naive calculation without packing). The values that were guessed correctly
// (SLOT_NO_RESPONSE=23, the chiefArbiter offset of 5) are confirmed by the same
// sweep and not taken on trust.
//
// ═══════════════ WHAT A REVIEW FOUND ON 15 AUGUST 2026 ═══════════════
//
// MISTAKE_THRESHOLD == MAX_ARBITER_MISTAKES made OverturnedVerdicts/Timeouts
// unreachable EVER — _recordArbiterMistake resets the counter IN THE SAME
// transaction that clears isArbiter, so "streak == 3 AND isArbiter == true" is a
// state the live contract cannot produce, while a bench with vm.store can, hence
// falsely green tests. The threshold became MAX_ARBITER_MISTAKES − 1 = 2 (declared
// as a subtraction in the facet itself and not as a separate literal). Every streak
// value below is recomputed for 2 rather than the old 3.
// test_OverturnedVerdictsIsReachableThroughRealPath was added (in a separate
// integration file — see test/ArbiterRemovalForCauseIntegration.t.sol) with the
// PRODUCTION path through overturnVerdict.
//
// Forfeiting the bond was covered by NOTHING — every expectEmit expected
// bondForfeited=0. test_RemovalForCauseForfeitsTheBond is below.
//
// setDAOAddress would have stayed a way round the ratchet (activateDAO →
// setDAOAddress(own address) → removal through the daoAddress branch) — fixed in
// ArbiterRegistryFacet, with tests for both sides in
// test/ArbiterSeatingHandover.t.sol.
//
// test_RemovalForCauseRevertsIfNotAnArbiter (below) plus removal from arbiterList
// (test/ArbiterRemovalForCauseIntegration.t.sol — that needs getArbiters(), which
// is not here).
//
// test_UnverifiableCauseRejectsDisputeRef (below) — the second copy of
// DisputeRefNotApplicable, living outside _requireProven, was not covered at all.
//
// isRegisteredArbiterHere/getMistakeStreakOf/getNoResponseAtHere were taken off —
// exactly the defect getChiefArbiterAddress had been (duplicates of the already
// mounted ArbiterRegistryFacet.isRegisteredArbiter/getArbiterMistakeStreak/
// getNoResponseAt). The post-conditions "no longer an arbiter" are read through
// _isArbiterRaw (a vm.load of slot 0, already proved live: EVERY test in this file
// rests on it through setUp). The offsets of arbiterMistakeStreak and
// disputeNoResponseAtBy are guarded by separate NAMED tests (not by a getter
// identity but by the production path — a positive and a negative), as was done
// with the chief.
//
// _isDaoActive is now the full expression (the manual flag OR the earned
// threshold), like ArbiterRegistryFacet.isDaoActive().
// test_DaoThresholdMatchesRegistry and its neighbours are below.

import "forge-std/Test.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {FactoryStorage} from "../src/FactoryFacet.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";

contract ArbiterRemovalForCauseTest is Test {
    ArbiterAccountabilityFacet acc;

    address owner;
    address chief;
    address arbiter;

    bytes32 constant ARB_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;
    bytes32 constant OWNER_SLOT = 0x178642b411f9f4783b21ef338f3e96db6c1272d763f0b7500ec93464dafb8604;
    bytes32 constant REP_BASE = 0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400;

    /// Obtained by sweeping (see the file docstring). The obvious guess was 18 — a
    /// miss: the real offset is 11, and it is guarded by the test below.
    uint256 constant SLOT_MISTAKE_STREAK = 11;

    /// arbiterBond is slot 12 and vaultBalance slot 9. Both were obtained by sweeping
    /// against ArbiterRegistryFacet.getArbiterBond/getVaultBalance — the same layout,
    /// a different deployed contract.
    uint256 constant SLOT_ARBITER_BOND = 12;
    uint256 constant SLOT_VAULT_BALANCE = 9;

    /// uniqueActiveUsers in ReputationStorage is slot 8, obtained by sweeping against
    /// ReputationFacet.getUniqueActiveUsers(). All seven fields before it in struct
    /// Data are mappings (each eats exactly one whole slot, with no packing alongside
    /// it — uniqueActiveUsers is itself a uint256, and the cleanStreak that follows
    /// it is a mapping again).
    uint256 constant SLOT_UNIQUE_ACTIVE_USERS = 8;

    /// Words the stand puts on a proposal whose cause the chain does not check
    /// (those causes require both a digest and words). Short and constant on
    /// purpose: what these scenes test is the pause, not the words.
    string constant PROPOSAL_WORDS = "the accusation, stated once, on the proposal";

    /// The digest the scenes about the door itself make do with: causes the chain
    /// does not verify require a non-empty bytes32, but which one is a matter of
    /// indifference to those scenes. One for all of them, so that a difference in
    /// digest is not read as part of the rule under test.
    bytes32 constant DIGEST = keccak256("the evidence, attested not verified");


    function setUp() public {
        acc = new ArbiterAccountabilityFacet();
        owner   = address(this);
        chief   = address(0xC4);
        arbiter = address(0xA1);
        vm.store(address(acc), OWNER_SLOT, bytes32(uint256(uint160(owner))));
        vm.store(address(acc), keccak256(abi.encode(arbiter, uint256(ARB_BASE))), bytes32(uint256(1)));
    }

    // ---------- VERIFIED BY THE CHAIN ----------

    function test_OverturnedVerdictsRequiresTheStreak() public {
        _setStreak(arbiter, 1);   // the threshold is now 2, and one is not enough
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.CauseNotProven.selector, uint8(0))
        );
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");
    }

    function test_OverturnedVerdictsPassesAtThreshold() public {
        _setStreak(arbiter, 2);   // MISTAKE_THRESHOLD = MAX_ARBITER_MISTAKES(3) − 1

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.ArbiterRemovedForCause(
            arbiter, owner, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, true, bytes32(0), 0
        );

        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");
        assertFalse(_isArbiterRaw(arbiter), "the removed one is no longer an arbiter");
    }

    // ---------- ATTESTED, BUT NOT VERIFIED ----------

    function test_CollusionWithoutEvidenceIsRefused() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the proposal's own evidence"), PROPOSAL_WORDS);
        vm.expectRevert(ArbiterAccountabilityFacet.EvidenceRequired.selector);
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, bytes32(0), address(0), "three times took the disputes of one counterparty and three times ruled in their favour");
    }

    function test_CollusionWithEvidenceIsMarkedUnverified() public {
        bytes32 digest = keccak256("a chat log with a party to the dispute");

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the proposal's own evidence"), PROPOSAL_WORDS);
        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.ArbiterRemovedForCause(
            arbiter, owner, ArbiterAccountabilityFacet.Cause.Collusion, false, digest, 0
        );

        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, digest, address(0), "three times took the disputes of one counterparty and three times ruled in their favour");
    }

    /// The second copy of DisputeRefNotApplicable, living OUTSIDE _requireProven (on
    /// the Collusion/Leak/Other road), was covered by nothing — removing it used to
    /// give 0 red.
    function test_UnverifiableCauseRejectsDisputeRef() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the proposal's own evidence"), PROPOSAL_WORDS);
        vm.expectRevert(ArbiterAccountabilityFacet.DisputeRefNotApplicable.selector);
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0xD1),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
    }

    /// Silence is evidence ABOUT A SPECIFIC DISPUTE, and without the dispute's
    /// address there is nothing to check it against. Merging it with the streak
    /// counter is impossible: the chain would then attest to something other than
    /// what the record says.
    function test_SilenceRequiresDisputeRef() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Silence, bytes32(0), "");
        vm.expectRevert(ArbiterAccountabilityFacet.DisputeRefRequired.selector);
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.Silence, bytes32(0), address(0), "");
    }

    function test_SilenceRequiresTheRecord() public {
        address deal = address(0xD1);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Silence, bytes32(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.CauseNotProven.selector, uint8(2))
        );
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.Silence, bytes32(0), deal, "");
    }

    function test_SilencePassesWhenRecorded() public {
        address deal = address(0xD1);
        _setNoResponse(deal, arbiter, 1_700_000_000);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Silence, bytes32(0), "");
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.Silence, bytes32(0), deal, "");
        assertFalse(_isArbiterRaw(arbiter), "removed on a recorded silence");
    }

    /// A dispute address on a code that does not read it is rubbish in the record: a
    /// reader would decide the removal is connected to that deal.
    function test_DisputeRefIsRefusedWhereItDoesNotApply() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        vm.expectRevert(ArbiterAccountabilityFacet.DisputeRefNotApplicable.selector);
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0xD1),
            ""
        );
    }

    /// Timeouts and OverturnedVerdicts rest on ONE counter — the chain does not tell
    /// them apart. This test pins that, so that nobody assumes it does.
    function test_TimeoutsUsesTheSameCounter() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Timeouts, bytes32(0), "");
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.Timeouts, bytes32(0), address(0), "");
        assertFalse(_isArbiterRaw(arbiter));
    }

    // ---------- WHO MAY ----------

    function test_ChiefCannotRemove() public {
        _setStreak(arbiter, 2);
        _setChief(chief);
        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwner.selector);
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");
    }

    /// NotAnArbiter on the removal road was covered by nothing.
    function test_RemovalForCauseRevertsIfNotAnArbiter() public {
        address stranger = address(0xF00D); // never registered
        vm.expectRevert(ArbiterAccountabilityFacet.NotAnArbiter.selector);
        acc.removeArbiterForCause(stranger, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");
    }

    /// The ratchet: after the DAO is activated AND a successor appointed, the chain
    /// does not admit the owner at all — the right has moved to daoAddress.
    ///
    /// ⚠️ `_setDaoAddress` here is mandatory. The earlier version deliberately left
    /// the successor at zero and expected RemovalHandedOver — that is, it guarded
    /// precisely the state in which nobody opened the door. The scenario "activated
    /// and forgot to appoint" is now checked with the opposite expectation:
    /// test_EarnedDaoWithoutSuccessorLeavesRemovalWithTheOwner.
    ///
    /// ⚠️ What this locked door is NOT. It does not limit the owner: they still have
    /// `overturnVerdict` (onlyOwnerOrDAO ALWAYS admits them, and with
    /// MAX_ARBITER_MISTAKES = 3, three overturns in a row remove an arbiter by the
    /// automatic path) and `diamondCut`, which replaces the facet whole.
    ///
    /// ⚠️ THE PRICE OF THAT WAY ROUND IS NAMED EXACTLY. The earlier version said
    /// simply "three overturnVerdicts", and that overstated it — the road is neither
    /// free nor always available. What it really requires, checked against the code
    /// rather than estimated:
    ///
    ///   • A LIVE, not yet finalised verdict OF THAT VERY ARBITER
    ///     (`v.submittedAt != 0`, `!v.finalized`, and no appeal under way). Against
    ///     an arbiter who has submitted no verdicts the road is not open AT ALL;
    ///   • time: `finalizeVerdict` is physically unavailable for the first
    ///     `FINALIZE_DELAY` = 24 hours from submission, and afterwards it is
    ///     available to ANYONE. So the owner's window is not "a day" but "until
    ///     somebody finalises"; only the first day is guaranteed.
    ///
    ///   • THREE DIFFERENT DISPUTES — since 18 August 2026 it is so, and before that
    ///     it was NOT: the `v.overturned` flag was written and read nowhere as a
    ///     prohibition, so three overturns of ONE agreement in one block removed an
    ///     arbiter. That is, the price of the road equalled one submitted verdict.
    ///     The flag now refuses (`AlreadyOverturned`), and the owner needs three live
    ///     verdicts on three different disputes — each with its own window and its
    ///     own party entitled to finalise it earlier. Measured by the live test
    ///     ArbiterRemovalForCauseIntegration::
    ///     test_OneVerdictCannotBeOverturnedThreeTimes.
    ///
    ///     ⚠️ AND THAT DID NOT BECOME TRUE AT ONCE. In the first version of that
    ///     change the line above already stood, while the price was in fact TWO
    ///     disputes, not three: the owner overturned by hand, the loser filed an
    ///     appeal (it stays open deliberately — it is the only check on the owner),
    ///     and a panel that RESTORED the arbiter's verdict recorded a second mistake
    ///     against that arbiter. That is, a correct decision by an honest panel gave
    ///     the owner half the road for free. Closed by a round of fixes in
    ///     resolveAppeal: the scenes are
    ///     Diamond::test_PanelVindicatingTheArbiterClearsHisMistake and
    ///     Diamond::test_VindicationAfterDemotionDoesNotUnderflowTheStreak.
    ///
    /// The real BACK door is not this one but `diamondCut`: it requires no verdict,
    /// no time and no cause, and it replaces the facet whole.
    ///
    /// The lock silences the LOUD door — the one that puts a cause, a digest and the
    /// name of whoever pressed it on chain — and pushes removal onto the quiet roads,
    /// where the feed shows only overturned verdicts. It is kept not as an obstacle
    /// but as a rule of the protocol, promised publicly.
    function test_OwnerCannotRemoveAfterDAO() public {
        _setStreak(arbiter, 2);
        _setDaoAddress(address(0xDA0));
        _activateDAO();
        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0),
            ""
        );
    }

    /// A handover and not a locking away into emptiness (the owner's correction after
    /// the first version of the design): daoAddress is appointed but the DAO is not
    /// active yet — the door is still the owner's alone.
    function test_DaoAddressCannotRemoveBeforeDao() public {
        _setStreak(arbiter, 2);
        address dao = address(0xDA0);
        _setDaoAddress(dao);
        vm.prank(dao);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwner.selector);
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");
    }

    /// The symmetrical half of test_OwnerCannotRemoveAfterDAO: the appointed
    /// daoAddress CAN remove after the DAO is activated — the right was not lost, it
    /// moved to a specific address.
    function test_DaoAddressCanRemoveAfterDao() public {
        _setStreak(arbiter, 2);
        address dao = address(0xDA0);
        _setDaoAddress(dao);
        _activateDAO();

        // The successor proposes for himself: past handover the owner cannot
        // (since 17 August 2026 the accusation door travels with the right to
        // act on it), and the whole point of a handover is that he needs nobody.
        _proposeAndWaitAs(dao, arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.ArbiterRemovedForCause(
            arbiter, dao, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, true, bytes32(0), 0
        );

        vm.prank(dao);
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");
        assertFalse(_isArbiterRaw(arbiter), "removed by a DAO vote after the handover");
    }

    // ---------- FORFEITING THE BOND ----------

    /// A removal for cause is not a voluntary departure: the bond is forfeited into
    /// the arbiter vault (the opposite behaviour to resignAsArbiter, which returns
    /// it). This was covered by NOTHING — every expectEmit expected bondForfeited=0,
    /// because a bond was never once set. Removing the forfeit block used to give 0
    /// red.
    function test_RemovalForCauseForfeitsTheBond() public {
        uint256 bond = 50_000_000; // 50 USDC, the same order as ARBITER_BOND
        _setArbiterBond(arbiter, bond);
        _setStreak(arbiter, 2);

        assertEq(_getArbiterBond(arbiter), bond, "setup: the bond is set");
        assertEq(_getVaultBalance(), 0, "setup: the vault is empty");

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.ArbiterRemovedForCause(
            arbiter, owner, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, true, bytes32(0), bond
        );

        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");

        assertEq(_getArbiterBond(arbiter), 0, "the bond was taken off the arbiter");
        assertEq(_getVaultBalance(), bond, "the bond went into the arbiter vault and was not lost");
    }

    // ---------- CLEARING THE SEAT ----------

    /// The earlier work deliberately left removeArbiter without a seat-clearing test,
    /// because it was going to be deleted. removeArbiterForCause is the new and only
    /// road out of somebody else's seating, and the seat-clearing road has to work
    /// through it too: an arbiter seated by the chief is removed, and
    /// getSeatedCountBy(the chief) must fall.
    function test_RemovalForCauseFreesDirectorSlot() public {
        address director = address(0xD3);
        _setStreak(arbiter, 2);
        _setSeatedBy(arbiter, director);
        _setSeatedCountBy(director, 1);
        assertEq(_getSeatedCountBy(director), 1, "setup: the chief's seating is counted");

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");

        assertEq(_getSeatedCountBy(director), 0, "a removal for cause must free the seater's place");
    }

    // ---------- GUARDS ON THE OFFSETS ----------
    //
    // isRegisteredArbiterHere/getMistakeStreakOf/getNoResponseAtHere were taken off —
    // exactly the defect getChiefArbiterAddress had been (duplicates of
    // ArbiterRegistryFacet getters already mounted through the diamond). As there,
    // the guard on the offset is a NAMED, SEPARATE test rather than a side effect of
    // other tests: that protection is accidental and would disappear unnoticed if
    // somebody in future removed or rewrote precisely that test.

    /// Positive: the streak is set THROUGH THE COMPUTED SLOT at the threshold and the
    /// removal goes through. Negative: a DIFFERENT, untouched arbiter and the removal
    /// fails. The difference proves that the test sees the written slot rather than
    /// agreeing at any offset (an identity of a write with itself cannot give such a
    /// difference).
    function test_MistakeStreakSlotOffsetIsCorrect() public {
        address untouched = address(0xA9);
        vm.store(address(acc), keccak256(abi.encode(untouched, uint256(ARB_BASE))), bytes32(uint256(1)));

        _proposeAndWait(untouched, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.CauseNotProven.selector, uint8(0))
        );
        acc.removeArbiterForCause(untouched, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");

        _setStreak(arbiter, acc.getMistakeThreshold());
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");
        assertFalse(_isArbiterRaw(arbiter), "the removed one is no longer an arbiter");
    }

    /// The same device for disputeNoResponseAtBy: a positive (a write through the
    /// computed slot and the removal goes through) and a negative (a different deal
    /// and it fails).
    function test_NoResponseSlotOffsetIsCorrect() public {
        address deal = address(0xD1);
        address untouchedDeal = address(0xD2);

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Silence, bytes32(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.CauseNotProven.selector, uint8(2))
        );
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.Silence, bytes32(0), untouchedDeal, "");

        _setNoResponse(deal, arbiter, 1_700_000_000);
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.Silence, bytes32(0), deal, "");
        assertFalse(_isArbiterRaw(arbiter), "removed on a recorded silence");
    }

    // ---------- THE FULL DAO EXPRESSION ----------

    function test_DaoThresholdMatchesRegistry() public {
        ArbiterRegistryFacet reg = new ArbiterRegistryFacet();
        assertEq(acc.getDaoThresholdMirror(), reg.getDaoThreshold(),
            "the automatic DAO threshold must be one and the same for both facets");
    }

    /// ⚠️ INVERTED ON 26 AUGUST 2026, and the inversion is the whole point. This used
    /// to be test_EarnedDaoActivatesWithoutManualFlag: the earned threshold was bound
    /// to close the door JUST AS the manual activateDAO() does. Now it closes NOTHING
    /// — `_isDaoActive` reads one flag.
    ///
    /// The scene is the same to the last line and the expectation is the opposite: the
    /// threshold is reached, the successor is named, governance is NOT switched on —
    /// and removal stays with the owner. The mutation "put the earned half back into
    /// _isDaoActive" turns exactly this test red: it is the only one on this bench
    /// where the counter is over the line.
    ///
    /// Why this matters more than it looks: OUTSIDERS could have pushed the threshold
    /// over the line by their own activity. While it switched governance on by itself,
    /// other people chose the moment at which the owner loses the loud door of removal
    /// with a cause and a name — and the distribution of money in an immutable
    /// treasury went with it.
    function test_ThresholdAloneDoesNotHandTheRemovalOver() public {
        _setStreak(arbiter, 2);
        _setUniqueActiveUsers(acc.getDaoThresholdMirror() * 10);
        _setDaoAddress(address(0xDA0));

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0),
            ""
        );

        assertFalse(
            _isArbiterRaw(arbiter),
            "a counter of outsiders does not close the owner's door: only their own press does"
        );
    }

    // ── The ratchet's predicate ──
    //
    // The earned threshold used to switch the DAO on BY ITSELF, by somebody else's
    // action and without a single human transaction. While no successor is named
    // there is nobody to hand the right of removal to — and the predicate has to take
    // that into account exactly as the neighbouring seating door does
    // (_requireSeatingNotHandedOver).

    /// Governance is on and there is no successor — the door stays with the owner.
    /// Before the fix this reverted RemovalHandedOver and NOBODY could remove: the
    /// condition degenerated into `msg.sender != address(0)`.
    ///
    /// ⚠️ THIS STATE IS NO LONGER REACHABLE THROUGH THE REAL DOORS:
    /// `activateDAO()` requires an already CONFIRMED successor, and the flag is
    /// cleared by nobody. It is brought here by a direct write into storage, and the
    /// test is kept deliberately: the `&& daoAddress != address(0)` clause is still in
    /// the predicate, and an unguarded belt gets taken off one day "as superfluous". A
    /// red here will say that it was.
    function test_ActiveDaoWithoutSuccessorLeavesRemovalWithTheOwner() public {
        _setStreak(arbiter, 2);
        _activateDAO();
        // daoAddress is deliberately NOT appointed — that is the window under examination

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0),
            ""
        );

        assertFalse(
            _isArbiterRaw(arbiter),
            "while there is no successor the door is the owner's, and it opens"
        );
    }

    /// As soon as a successor is named the door moves away, and with an earned
    /// threshold exactly as with the manual flag. The second half of the same fix:
    /// without it, "stays with the owner" would have turned into "stays with the owner
    /// forever".
    function test_ActiveDaoWithSuccessorHandsRemovalOver() public {
        _setStreak(arbiter, 2);
        _activateDAO();
        _setDaoAddress(address(0xDA0));

        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0),
            ""
        );
    }

    /// A control on the seam, not a lock: three places about one condition must answer
    /// alike. It is never the only red — on any corruption the corrupted side's own
    /// test goes red beside it. What it catches is the pair DRIFTING APART: if
    /// somebody weakens the seating predicate in the registry tomorrow, it becomes
    /// visible here that the doors have stopped closing together.
    function test_HandoverPredicateMatchesSeatingPredicate() public {
        ArbiterRegistryFacet reg = new ArbiterRegistryFacet();
        vm.store(address(reg), OWNER_SLOT, bytes32(uint256(uint160(owner))));
        // The flag is brought in by a direct write for the same reason as in
        // test_ActiveDaoWithoutSuccessorLeavesRemovalWithTheOwner: through the real
        // door this state has been unreachable since 26 August 2026 (activateDAO
        // requires a confirmed successor), while the pair of `&& daoAddress !=
        // address(0)` clauses under test is still in the code.
        bytes32 daoSlot = bytes32(uint256(ARB_BASE) + 5);
        vm.store(address(reg), daoSlot, vm.load(address(reg), daoSlot) | bytes32(uint256(1) << 160));

        assertTrue(reg.isDaoActive(), "setup: governance is switched on by both sides");
        assertEq(reg.getDAOAddress(), address(0), "setup: there is no successor");

        // The SEATING door is open to the owner in this state — it is already so, and
        // it is with that door that the removal door must agree.
        reg.addArbiter(address(0xA7));
        assertTrue(
            reg.isRegisteredArbiter(address(0xA7)),
            "seating works with a live DAO and no successor, so removal must too"
        );
    }

    // ============================================================
    //  A CASE THAT HAS BEGUN LIVES BY THE RULES OF ITS BEGINNING
    //
    //  The term of an accusation used to be read live from a constant. Shorten it to
    //  seven days with a cut, and an accusation filed eight days ago went stale
    //  INSTANTLY, without a single transaction: a person's state changed while
    //  nothing happened on chain. Harm by inaction, invisible both to the injured
    //  party and to everybody else.
    //
    //  ⚠️ HOW THIS IS CHECKED AT ALL. A compile-time constant cannot be changed at
    //  runtime — it is in the bytecode. So the divergence "the rule of the record ≠
    //  today's rule" is introduced from THE OTHER end: a term different from the
    //  current constant is put into the record, which is exactly the state a cut
    //  would have left behind. The expected numbers are literals (30 days, 3 days)
    //  chosen by a person and derived from nothing under test.
    // ============================================================

    /// An accusation filed under a LONGER rule survives a shortening of the constant.
    /// On the twentieth day: by today's fourteen days it would long since have gone
    /// stale, by its own thirty-day term it is alive, and the button works.
    function test_ProposalLaidUnderALongerRuleOutlivesTodaysConstant() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        _setProposalTtl(arbiter, uint64(30 days));

        vm.warp(vm.getBlockTimestamp() + 20 days);
        assertGt(20 days, acc.getProposalTTL(), "setup: by today's constant this day is already past the term");

        assertTrue(acc.hasLiveProposal(arbiter), "the record is judged by its own term and not by today's");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
        assertFalse(_isArbiterRaw(arbiter), "the button worked: the accusation did not go stale because a constant was edited");
    }

    /// And in the other direction: a record with a SHORT term goes stale by its own
    /// and does not live on to today's fourteen days. Without this half, "the record is
    /// read" could not be told from "the larger of the two is taken".
    ///
    /// The refusal is checked by selector AND WITH ITS ARGUMENT: `ProposalStale`
    /// carries the moment of filing, and a form shows by it what exactly went stale.
    function test_ProposalLaidUnderAShorterRuleExpiresByItsOwnClock() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        (, , uint256 proposedAt, ,) = acc.getRemovalProposal(arbiter);
        _setProposalTtl(arbiter, uint64(3 days));

        vm.warp(proposedAt + 4 days);
        assertLt(4 days, acc.getProposalTTL(), "setup: by today's constant this day is still within the term");

        assertFalse(acc.hasLiveProposal(arbiter), "a short term in the record means a short life for the accusation");
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.ProposalStale.selector, proposedAt)
        );
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
    }

    /// An accusation by THE CHAIN obeys the same rule: `executeChainRemoval` is the
    /// second of the two doors that compare the end of the term directly, and it must
    /// read the same record. Without this test half the door would stay unlocked: the
    /// one accused by the chain has neither an author to object to nor a way to leave
    /// of their own accord.
    function test_TheChainsOwnAccusationIsJudgedByItsOwnClockToo() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        // The author is erased — that is what a record laid down by the chain looks like.
        bytes32 slot = _proposalTtlSlot(arbiter);
        bytes32 packed = vm.load(address(acc), slot);
        vm.store(address(acc), slot, packed & ~bytes32(uint256(type(uint160).max)));
        (, , uint256 proposedAt, address by,) = acc.getRemovalProposal(arbiter);
        assertEq(by, address(0), "setup: the accusation is nobody's, that is, the chain's");

        _setProposalTtl(arbiter, uint64(30 days));
        vm.warp(proposedAt + 20 days);

        acc.executeChainRemoval(arbiter);
        assertFalse(_isArbiterRaw(arbiter), "the chain's door judges by the record, as the common one does");
    }

    /// A record MADE BEFORE the field existed lives by the constant in force — and not
    /// by reverting but by genuinely living: an accusation already filed must not
    /// become unexecutable because of an upgrade.
    ///
    /// A zero in the field is the only way to tell "the rule is not recorded" from
    /// "the rule is recorded and it is zero"; the second does not occur, because
    /// `proposeRemoval` puts the constant there, and the constant is not zero.
    function test_AProposalWithNoStoredRuleFallsBackToTheConstantInForce() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        (, , uint256 proposedAt, ,) = acc.getRemovalProposal(arbiter);
        _setProposalTtl(arbiter, 0);

        vm.warp(proposedAt + acc.getProposalTTL() - 1);
        assertTrue(acc.hasLiveProposal(arbiter), "the last second of the constant: still alive");

        vm.warp(proposedAt + acc.getProposalTTL());
        assertFalse(acc.hasLiveProposal(arbiter), "exactly at the constant: already stale");
    }

    // ============================================================
    //  THE CHIEF'S PROPOSAL
    //
    //  The chief does not remove — they propose. The proposal goes on chain as a
    //  separate record with their address, and the owner agrees in another. So the
    //  feed shows BOTH who proposed AND who agreed.
    //
    //  A proposal GOES STALE: otherwise it hangs in storage as an eternal accusation
    //  against a working arbiter, and "there is a proposal" stops meaning "the claim
    //  is alive".
    // ============================================================

    function test_ChiefProposes() public {
        _setChief(chief);
        bytes32 digest = keccak256("the memo");
        uint256 t0 = vm.getBlockTimestamp();

        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.RemovalProposed(
            arbiter, chief, ArbiterAccountabilityFacet.Cause.Leak, digest, t0
        );

        vm.prank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, digest, "published the chat log of a dispute to a third party");

        (uint8 c, bytes32 dg, uint256 at, address by, bool live) = acc.getRemovalProposal(arbiter);
        assertEq(c, uint8(ArbiterAccountabilityFacet.Cause.Leak));
        assertEq(dg, digest);
        assertEq(at, t0);
        assertEq(by, chief);
        assertTrue(live, "a fresh proposal must be live");
    }

    function test_ProposalExpires() public {
        _setChief(chief);
        vm.prank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");

        vm.warp(vm.getBlockTimestamp() + 14 days);
        assertFalse(acc.hasLiveProposal(arbiter), "after 14 days the proposal has gone stale");
    }

    function test_ProposalIsLiveUntilTheLastSecond() public {
        _setChief(chief);
        vm.prank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");

        vm.warp(vm.getBlockTimestamp() + 14 days - 1);
        assertTrue(acc.hasLiveProposal(arbiter), "a second before the end it is still alive");
    }

    /// ⚠️ COUNTER-HALF of test_ChiefCannotWithdrawTheOwnersProposal since
    /// 17 August 2026, when the pause was reviewed. The new rule is "your own
    /// only", not "nothing": a lock forbidding the chief every withdrawal would
    /// pass the forbidding measurement and kill the role in silence. This test
    /// is what reddens if that happens.
    function test_ChiefWithdrawsHisOwnProposal() public {
        _setChief(chief);
        vm.startPrank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");
        acc.withdrawProposal(arbiter);
        vm.stopPrank();
        assertFalse(acc.hasLiveProposal(arbiter), "changed their mind and withdrew it");
    }

    // ────────────────────────────────────────────────────────────
    //  THE ACCUSATION DOOR TRAVELS WITH THE RIGHT TO ACT ON IT
    //  (17 August 2026, on a later review of the pause)
    //
    //  proposeRemoval stood under onlyOwnerOrChief alone, and the named
    //  successor fits through neither half of that. Harmless while the proposal
    //  was optional — he removed with one button and needed nobody. The pause
    //  made the proposal MANDATORY, and so cancelled the very handover this
    //  branch was built to deliver: the right had moved, but the successor
    //  could not use it until the FORMER owner laid a proposal for him. A veto
    //  by inaction, invisible in the feed, held by the one person the handover
    //  exists to take out of the loop.
    // ────────────────────────────────────────────────────────────

    /// The designated lock. After handover the successor lays his own
    /// accusation and needs nobody — checked by the record, not by "it did not
    /// revert": the proposal must stand, and stand under HIS address.
    function test_SuccessorProposesAfterHandover() public {
        address dao = address(0xDA0);
        _setDaoAddress(dao);
        _activateDAO();

        vm.prank(dao);
        acc.proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );

        assertTrue(acc.hasLiveProposal(arbiter), "the successor's accusation is on chain");
        (, , , address by, ) = acc.getRemovalProposal(arbiter);
        assertEq(by, dao, "and it stands under his own address, not the former owner's");
    }

    /// The other side of the same rule: the handover is whole or it is theatre.
    /// A proposal the former owner could still lay would be executable by the
    /// successor, so leaving him the door would leave him in the loop by the
    /// back way.
    function test_OwnerCannotProposeAfterHandover() public {
        _setDaoAddress(address(0xDA0));
        _activateDAO();

        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        acc.proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );
        assertFalse(acc.hasLiveProposal(arbiter), "and nothing was written");
    }

    // ────────────────────────────────────────────────────────────
    //  WITHDRAWING SOMEONE ELSE'S PROPOSAL (17 August 2026, when the pause
    //  was reviewed)
    //
    //  The pause turned withdrawal into a weapon it never was. While a proposal
    //  was only a signal, clearing another person's record took nothing away.
    //  Now the removal runs ONLY through a proposal that has sat — so clearing
    //  the record is the power to STOP a removal, again and again, for as long
    //  as the accuser keeps trying.
    //
    //  Rule: your own only. Plus whoever holds the removal right may clear
    //  anyone's — before handover the owner, after it the named successor, by
    //  the SAME predicate as the removal itself.
    // ────────────────────────────────────────────────────────────

    /// The designated lock. Refusal is checked by BEHAVIOUR as well as by the
    /// label: the proposal must still be standing afterwards, or "he was
    /// refused" would say nothing about whether the record survived.
    function test_ChiefCannotWithdrawTheOwnersProposal() public {
        _setChief(chief);
        acc.proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );

        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.NotYourProposal.selector);
        acc.withdrawProposal(arbiter);

        assertTrue(acc.hasLiveProposal(arbiter), "the accusation is still standing");
        (, , , address by, ) = acc.getRemovalProposal(arbiter);
        assertEq(by, owner, "and it is still the owner's");
    }

    /// The right to clear anyone's travels WITH the right to remove.
    ///
    /// ⚠️ THE REFUSAL CHANGED ITS LABEL IN REVIEW ROUND 4 OF TASK 12 (19 August
    /// 2026), and the property got STRONGER rather than different. It used to
    /// be NotYourProposal — "this record is not yours" — which was true but
    /// small: the former owner was refused as a stranger to this particular
    /// record, and would still have cleared one he had laid himself.
    ///
    /// withdrawProposal now has its own handover branch, so he is refused as a
    /// man who gave the door away: RemovalHandedOver, and it applies to every
    /// record including his own. Same reasoning proposeRemoval already carried
    /// — "a proposal he could still lay would be executable by the successor,
    /// so keeping it would keep him in the loop by the back door" — read on the
    /// other side: a veto he could still exercise keeps him in the loop just as
    /// well. The handover is whole or it is theatre.
    ///
    /// The larger reason is the one the person should read; that is the same
    /// rule AlreadyOverturned is ordered by. What is asserted below did not
    /// move: the record survives him.
    function test_AfterHandoverTheOwnerCannotWithdrawTheChiefsProposal() public {
        _setChief(chief);
        vm.prank(chief);
        acc.proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );

        _setDaoAddress(address(0xDA0));
        _activateDAO();

        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        acc.withdrawProposal(arbiter);
        assertTrue(acc.hasLiveProposal(arbiter), "the chief's record survived the former owner");
    }

    /// And the door has an opener on the far side — otherwise "the owner may no
    /// longer" would mean "nobody may", which is the exact trap a review dug out of
    /// liftSuspension. onlyOwnerOrChief would not have let the successor in at
    /// all.
    function test_AfterHandoverTheSuccessorWithdrawsAnyProposal() public {
        address dao = address(0xDA0);
        _setChief(chief);
        vm.prank(chief);
        acc.proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );

        _setDaoAddress(dao);
        _activateDAO();

        vm.expectEmit(true, true, false, true, address(acc));
        emit ArbiterAccountabilityFacet.RemovalProposalWithdrawn(arbiter, dao);
        vm.prank(dao);
        acc.withdrawProposal(arbiter);

        assertFalse(acc.hasLiveProposal(arbiter), "whoever removes today also clears");
    }

    /// ⚠️ COUNTER-HALF of the handover rule as it stands since 17 August
    /// 2026: a stranger is still refused before handover, and refused BY ROLE
    /// (NotOwnerOrChief). A gate narrowed to "the removal authority only" would
    /// pass test_SuccessorProposesAfterHandover and silently take the door from
    /// the chief; this and test_ChiefProposes are what redden then.
    function test_StrangerCannotPropose() public {
        vm.prank(address(0x5A));
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");
    }

    /// The second requirement beyond the brief: for an attested code the digest is
    /// mandatory ALREADY at the proposal stage, not only at execution.
    function test_ProposeUnverifiableWithoutEvidenceIsRefused() public {
        _setChief(chief);
        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.EvidenceRequired.selector);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, bytes32(0), "three times took the disputes of one counterparty and three times ruled in their favour");
    }

    /// The chain-verifiable codes (OverturnedVerdicts/Timeouts/Silence) are
    /// deliberately NOT checked at the proposal stage: the streak here is below the
    /// threshold and the proposal goes through anyway — the evidence may appear after
    /// the chief has given warning.
    function test_ProposeVerifiableCauseDoesNotCheckTheStreakYet() public {
        _setChief(chief);
        // The streak is NOT set — below MISTAKE_THRESHOLD (and zero, in fact).
        vm.prank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        assertTrue(acc.hasLiveProposal(arbiter), "a chain-verifiable code is not checked at the proposal stage");
    }

    /// The owner proposes on equal terms with the chief — `_requireOwnerOrChief`
    /// admits both, not only the chief.
    ///
    /// ⚠️ "Under the modifier" is no longer said: `proposeRemoval` lost it from its
    /// signature when the pause was built and calls the check explicitly, in the
    /// "there was no handover" branch. Today one function of this facet carries the
    /// modifier — `suspendArbiter`. The scene is BEFORE the handover, and that
    /// matters: after it nobody admits the owner.
    function test_OwnerCanAlsoPropose() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");
        (, , , address by, ) = acc.getRemovalProposal(arbiter);
        assertEq(by, owner);
    }

    /// The owner may withdraw a proposal laid down by the chief: the right of
    /// withdrawal is not tied to who proposed — somebody else's is cleared by the
    /// holder of the right of removal.
    ///
    /// ⚠️ "Both go under one modifier" used to stand here. `withdrawProposal` has not
    /// carried the modifier since the pause was built, and it now has a handover
    /// branch of its own. The scene is BEFORE the handover; after it only the
    /// successor withdraws, and the owner gets RemovalHandedOver — see
    /// test_AfterHandoverTheOwnerCannotWithdrawTheChiefsProposal below.
    function test_OwnerWithdrawsChiefsProposal() public {
        _setChief(chief);
        vm.prank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");

        acc.withdrawProposal(arbiter);
        assertFalse(acc.hasLiveProposal(arbiter), "the owner withdrew somebody else's proposal");
    }

    /// There is one claim and not a queue of claims — the record is REPLACED, it does
    /// not accumulate.
    ///
    /// ⚠️ The scene used to be called test_SecondProposalOverwritesFirst and laid a
    /// second proposal straight on top of the first. That overwrite is precisely what
    /// a later change forbade: it silently reset the 48-hour clock. The meaning of the
    /// scene ("one claim, not a queue") is not cancelled by that change — what is
    /// cancelled is the way to change it, and it now goes through a withdrawal, which
    /// lands in the feed.
    function test_ChangingTheAccusationRunsThroughAWithdrawal() public {
        _setChief(chief);
        vm.startPrank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("first"), "published the chat log of a dispute to a third party");
        acc.withdrawProposal(arbiter);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, keccak256("second"), "the whole account is under the attached digest");
        vm.stopPrank();

        (uint8 c, bytes32 dg, , , ) = acc.getRemovalProposal(arbiter);
        assertEq(c, uint8(ArbiterAccountabilityFacet.Cause.Other));
        assertEq(dg, keccak256("second"));
    }

    // ── A live proposal occupies the door ──
    //
    // A review took away the chief's power to "stop a removal and start it again as
    // often as they like" on withdrawProposal. An overwrite gave it back through the
    // neighbouring door in one transaction and left NOTHING in the feed.

    function test_ChiefCannotOverwriteOwnersLiveProposal() public {
        _setChief(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, "owner's case");

        (, , uint256 proposedAt, address by, ) = acc.getRemovalProposal(arbiter);
        vm.prank(chief);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterAccountabilityFacet.ProposalAlreadyLive.selector, by, proposedAt
            )
        );
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST, "mine instead");
    }

    /// The author of their own proposal cannot either. Resetting the clock must be visible.
    function test_ProposerCannotRefreshHisOwnClockSilently() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, "first");
        (, , uint256 proposedAt, , ) = acc.getRemovalProposal(arbiter);

        vm.warp(vm.getBlockTimestamp() + 47 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterAccountabilityFacet.ProposalAlreadyLive.selector, owner, proposedAt
            )
        );
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, "again");
    }

    /// Through a withdrawal it can be, and the withdrawal stays in the feed.
    function test_WithdrawThenProposeIsAllowedAndRecorded() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, "first");

        vm.expectEmit(true, true, false, false);
        emit ArbiterAccountabilityFacet.RemovalProposalWithdrawn(arbiter, owner);
        acc.withdrawProposal(arbiter);

        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST, "second");
        (uint8 cause, , , , ) = acc.getRemovalProposal(arbiter);
        assertEq(cause, uint8(ArbiterAccountabilityFacet.Cause.Collusion));
    }

    /// A stale one does not occupy the door: the gate reads hasLiveProposal, not proposedAt != 0.
    function test_StaleProposalDoesNotBlockANewOne() public {
        _setChief(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, "old");

        vm.warp(vm.getBlockTimestamp() + acc.getProposalTTL() + 1);
        vm.prank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST, "fresh");
        (, , , address by, ) = acc.getRemovalProposal(arbiter);
        assertEq(by, chief);
    }

    /// The chief can no longer shield themselves.
    function test_ChiefCannotShieldHimselfByOverwriting() public {
        // seat the chief as an arbiter, so that a removal can be proposed against them
        _setChief(chief);
        _seatChiefAsArbiter();

        acc.proposeRemoval(chief, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST, "against the chief");
        (, , uint256 proposedAt, , ) = acc.getRemovalProposal(chief);

        vm.prank(chief);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterAccountabilityFacet.ProposalAlreadyLive.selector, owner, proposedAt
            )
        );
        acc.proposeRemoval(chief, ArbiterAccountabilityFacet.Cause.Other, DIGEST, "nothing to see");
    }

    // ── The order of the gate: "the door is occupied" is not for outsiders ──
    //
    // A review found that the property "an outsider runs into the role check BEFORE
    // learning about somebody else's accusation" was true and guarded by nothing — the
    // reviewer moved the gate above the role check and got 0 red out of 894. Until
    // then it rested on the order of the lines.
    //
    // Why this is not pedantry: ProposalAlreadyLive(by, proposedAt) is not a "no" but
    // A DISCLOSURE. It tells an outsider that an accusation hangs against a specific
    // arbiter, and who filed it — before the asker had any right to ask. The role must
    // refuse first.

    function test_StrangerLearnsNothingAboutALiveProposal() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, "owner's case");

        address stranger = address(0xF00D);
        vm.prank(stranger);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST, "prying");
    }

    /// The same check on the SECOND role door — after the right has been handed over.
    /// There the role is guarded not by _requireOwnerOrChief but by a separate
    /// RemovalHandedOver branch, and moving the gate up would bypass both at once.
    function test_StrangerLearnsNothingAboutALiveProposalAfterHandover() public {
        address dao = address(0xDA0);
        _setDaoAddress(dao);
        _activateDAO();

        vm.prank(dao);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, "the successor's case");

        // The former owner is an outsider here too, and that is the most valuable half:
        // the right moved away, and with it the right to know.
        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST, "prying");
    }

    /// A successful removal clears the proposal — otherwise it would outlive an
    /// already removed arbiter and hang against them as a meaningless accusation.
    ///
    /// ⚠️ Both doors now carry the SAME cause (design of 17 August 2026).
    /// This scene used to propose `Leak` and execute
    /// `OverturnedVerdicts`; that pair is refused outright now, and the scene
    /// where the codes diverge is test_RemovalUnderADifferentCauseIsRefused.
    function test_RemovalClearsTheProposal() public {
        _setChief(chief);
        vm.prank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");
        assertTrue(acc.hasLiveProposal(arbiter), "setup: the proposal is alive");

        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("dump"), address(0),
            "published the chat log of a dispute to a third party"
        );

        assertFalse(acc.hasLiveProposal(arbiter), "a removal must erase the proposal");
    }

    /// A proposal against a non-existent arbiter is not laid down — the same check as
    /// on the removal itself.
    function test_ProposeRevertsIfNotAnArbiter() public {
        address stranger = address(0xF00D);
        vm.expectRevert(ArbiterAccountabilityFacet.NotAnArbiter.selector);
        acc.proposeRemoval(stranger, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
    }

    /// The ArbiterZeroAddress branch was declared but checked by no test — removing
    /// the line would have turned not one test red, because the very next line reverts
    /// NotAnArbiter (the same class already caught on suspendArbiter, see
    /// test_SuspendZeroAddressReverts in test/ArbiterSuspension.t.sol).
    function test_ProposeRevertsOnZeroAddress() public {
        vm.expectRevert(ArbiterAccountabilityFacet.ArbiterZeroAddress.selector);
        acc.proposeRemoval(address(0), ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");
    }

    // ============================================================
    //  WHAT A REVIEW FOUND ON THE PROPOSAL DOOR
    // ============================================================

    /// A withdrawProposal against a person nobody laid anything against must not leave
    /// a RemovalProposalWithdrawn in the feed — such a log would read as "there was
    /// something against them and it was withdrawn", and the feed is the whole point of
    /// this work.
    function test_WithdrawProposalOnStrangerEmitsNothing() public {
        vm.recordLogs();
        acc.withdrawProposal(arbiter); // nobody proposed anything
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "a withdraw with no proposal must emit nothing");
    }

    /// The symmetrical positive half: a real proposal really is withdrawn with an event
    /// — the fix did not turn withdraw permanently mute.
    function test_WithdrawProposalOnExistingEmitsEvent() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");

        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.RemovalProposalWithdrawn(arbiter, owner);
        acc.withdrawProposal(arbiter);
    }

    /// A removal emits RemovalProposalConsumed with the fields of the ERASED record —
    /// they are visible in one transaction, both events lying in one log.
    ///
    /// ⚠️ THE SCENE CHANGED ON 17 AUGUST 2026. It used to propose `Leak` and
    /// remove for `OverturnedVerdicts`, so the log showed "proposed for X,
    /// removed for Y". That pair is now refused outright
    /// (CauseDiffersFromProposal): a pause is worth nothing if the warning
    /// names one thing and the execution another. What the event still shows in
    /// one transaction, and what this test still checks, is the rest of the
    /// divergence — the CHIEF proposed, the OWNER executed, and the digest in
    /// the consumed record is the proposer's, not the one the owner passed.
    function test_RemovalConsumesTheProposal() public {
        _setChief(chief);
        bytes32 proposedDigest = keccak256("the memo");
        vm.prank(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, proposedDigest, "published the chat log of a dispute to a third party");
        (, , uint256 proposedAt, , ) = acc.getRemovalProposal(arbiter);

        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());

        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.RemovalProposalConsumed(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, chief, proposedDigest, proposedAt
        );
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("what the owner actually found"),
            address(0), "published the chat log of a dispute to a third party"
        );
    }

    // ⚠️ test_RemovalWithoutProposalEmitsOnlyTheRemovalEvent DELETED HERE
    // (17 August 2026). It played "a removal with no preceding proposal", and
    // that scene no longer exists: removeArbiterForCause reverts NoLiveProposal
    // before it can emit anything. Kept, it would have become a test standing
    // guard over a state the contract cannot reach — exactly the dead lock this
    // project keeps finding. The negative half of Minor 4 it used to guard is
    // gone with the scene, not silently dropped: see the note on the `if
    // (consumedProposal.proposedAt != 0)` branch in the facet.

    /// An improvement: the fifth field `live` in getRemovalProposal agrees with
    /// hasLiveProposal on a stale record and not only on a fresh one (the fresh one is
    /// already checked by test_ChiefProposes).
    function test_GetRemovalProposalLiveFieldFalseAfterExpiry() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");
        vm.warp(vm.getBlockTimestamp() + 14 days);

        (, , , , bool live) = acc.getRemovalProposal(arbiter);
        assertFalse(live, "a stale record: live must be false");
        assertFalse(acc.hasLiveProposal(arbiter), "agrees with hasLiveProposal");
    }

    /// The seam: `proposedAt == 0` (never proposed at all, rather than "proposed and
    /// gone stale") is the only case where a copied formula and a call to
    /// `hasLiveProposal` can really diverge (a stale record with a real `proposedAt` is
    /// read the same way by both forms: the comparison with TTL gives false by itself).
    /// The test puts exactly that boundary.
    function test_GetRemovalProposalLiveFieldFalseForNeverProposed() public {
        (, , , , bool live) = acc.getRemovalProposal(arbiter);
        assertFalse(live, "nothing was ever proposed against this arbiter, so live must be false");
    }

    // ============================================================
    //  THE RIGHT OF REPLY
    //
    //  An accusation against a real address lies on chain forever. A reply cancels
    //  nothing and returns nothing — it exists so that a reader of the chain sees TWO
    //  records instead of one.
    //
    //  ⚠️ The scenes BELOW, in this section, play the reply AFTER a removal — the
    //  second of the two doors. The first, a reply during the pause, appeared on
    //  19 August 2026 and lives in the next section.
    //
    //  ⚠️ The only function of this facet that reads _msgSender(): it is called by an
    //  ordinary person who may have no ETH. Through a relayer msg.sender is the
    //  forwarder's address, and the reply would be recorded for the forwarder.
    // ============================================================

    function test_RemovedArbiterAnswers() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");

        bytes32 reply = keccak256("here is the whole chat log, judge for yourselves");

        vm.expectEmit(true, false, false, true, address(acc));
        emit ArbiterAccountabilityFacet.RemovalAnswered(arbiter, reply);

        vm.prank(arbiter);
        acc.respondToRemoval(reply, "");

        assertEq(acc.getRemovalReply(arbiter), reply, "the reply landed on chain");
    }

    /// ⚠️ RENAMED FROM test_AnswerIsOnceOnly. One now answers once PER ACCUSATION
    /// rather than once forever: a new accusation opens the right again
    /// (test_NewProposalReopensTheRightToAnswer). The scene did not change — the same
    /// second reply to the same accusation, the same refusal.
    function test_AnswerIsOncePerAccusation() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");

        vm.startPrank(arbiter);
        acc.respondToRemoval(keccak256("first"), "");
        vm.expectRevert(ArbiterAccountabilityFacet.AlreadyAnswered.selector);
        acc.respondToRemoval(keccak256("second"), "");
        vm.stopPrank();
    }

    function test_ZeroReplyIsRefused() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");
        vm.prank(arbiter);
        vm.expectRevert(ArbiterAccountabilityFacet.ZeroDigest.selector);
        acc.respondToRemoval(bytes32(0), "");
    }

    /// A stranger with nothing standing against him — no removal, no proposal
    /// — still cannot answer. The edit below WIDENED this door, it did not
    /// take it off its hinges.
    ///
    /// ⚠️ RENAMED FROM test_OnlyRemovedCanAnswer (19 August 2026), and
    /// the old name is why: since the answer is taken during the pause, "only
    /// the removed may answer" is no longer true, and a test name is an
    /// assertion like any other. The scene did not change — the same address
    /// with nothing against it gets the same refusal.
    function test_StrangerWithNoAccusationStillCannotAnswer() public {
        vm.prank(address(0x5A));
        vm.expectRevert(ArbiterAccountabilityFacet.NothingToAnswer.selector);
        acc.respondToRemoval(keccak256("x"), "I had nothing to do with it");
    }

    // ============================================================
    //  A WORD BEFORE THE SENTENCE
    //
    //  respondToRemoval used to require removedAt != 0 — that is, the word was given
    //  AFTER the sentence. The 48-hour pause without this fix would have been two days
    //  in which the accused can do precisely nothing on chain.
    //
    //  A reply does NOT move the clock: it neither starts nor extends the timer. Its
    //  work is to lie in the record BEFORE the decision, so that a removal happens on
    //  top of an objection rather than instead of it. Speeding a removal up by staying
    //  silent is impossible too: the silent would be removed faster, and replying would
    //  become worthwhile purely to drag things out.
    //
    //  ⚠️ The principal accused of this work — the one accused by THE CHAIN — is not
    //  played out here at all: their accusation is laid down by _recordArbiterMistake
    //  in ArbiterRegistryFacet, that is, behind another facet. Their scenes live in
    //  test/ArbiterRemovalForCauseIntegration.t.sol, on a real diamond.
    // ============================================================

    /// The main point of this work: under a live proposal a reply is accepted.
    function test_AccusedAnswersDuringThePause() public {
        acc.proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST, PROPOSAL_WORDS
        );

        bytes32 reply = keccak256("here is the whole chat log, judge for yourselves");
        vm.prank(arbiter);
        acc.respondToRemoval(reply, "I ran both disputes by the book, here is the log");

        assertEq(acc.getRemovalReply(arbiter), reply, "the reply landed on chain before the verdict");
        assertTrue(_isArbiterRaw(arbiter), "and they are still an arbiter: there was no verdict");
    }

    /// A reply does NOT move the timer. Measured by the outcome rather than by reading
    /// a field: the removal goes through on exactly the same second as without a reply.
    function test_AnswerDoesNotMoveTheClock() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        uint256 proposedAt = vm.getBlockTimestamp();

        vm.warp(proposedAt + 1 hours);
        vm.prank(arbiter);
        acc.respondToRemoval(keccak256("answer"), "I disagree");

        vm.warp(proposedAt + acc.getRemovalDelay());
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
        assertFalse(_isArbiterRaw(arbiter), "the reply postponed nothing");
    }

    /// A reply given BEFORE the removal survives the removal — and that is the whole
    /// point of the change: a reader of the chain sees TWO records instead of one, and
    /// the objection is now OLDER than the sentence rather than written after it.
    ///
    /// The same thing holds the decision NOT to erase removalReply in
    /// ArbiterRegistryStorage.clearSeat (which _performRemoval calls): clearing it
    /// there would make a removal a replacement of the objection rather than an
    /// overlay on it.
    function test_AnswerGivenBeforeRemovalSurvivesIt() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");

        bytes32 reply = keccak256("the objection");
        vm.prank(arbiter);
        acc.respondToRemoval(reply, "");

        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );

        assertEq(
            acc.getRemovalReply(arbiter), reply,
            "the removal happened ON TOP OF the objection and not instead of it"
        );
    }

    /// One may answer once per accusation, not once forever. A new proposal opens the
    /// right again.
    ///
    /// ⚠️ Without the clearing in proposeRemoval, a sitting arbiter who answered a
    /// proposal that later went stale WOULD HAVE LOST the right to answer forever:
    /// removalReply was erased only by clearRemovalRecord, and that is called only by
    /// the SEATING doors, which they do not pass through — they never left.
    ///
    /// ⚠️ THROUGH GOING STALE AND NOT THROUGH A WITHDRAWAL, and that is not a matter of
    /// taste. The obvious scene would be "answered → withdrawn → accused again", but a
    /// withdrawal itself erases removalReply — the lock aimed at it (the clearing in
    /// proposeRemoval) would stay green when removed, and the number of reds would be
    /// speaking about the neighbouring fix. Going stale erases nothing, so what goes
    /// red here is exactly the line the scene was written for.
    function test_NewProposalReopensTheRightToAnswer() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("e1"), "leaked the chat log");
        vm.prank(arbiter);
        acc.respondToRemoval(keccak256("a1"), "");

        // It went stale by itself; nobody withdrew or erased anything.
        vm.warp(vm.getBlockTimestamp() + acc.getProposalTTL());

        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("e2"), "leaked the chat log again");
        vm.prank(arbiter);
        acc.respondToRemoval(keccak256("a2"), "");

        assertEq(acc.getRemovalReply(arbiter), keccak256("a2"), "the second reply landed on top of the first");
    }

    /// The accused must see a withdrawal as a CLOSURE and not as silence. In storage a
    /// closure looks like this: nothing lies against them any more and there is nothing
    /// to answer.
    function test_WithdrawalClosesTheAnswer() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, PROPOSAL_WORDS);
        vm.prank(arbiter);
        acc.respondToRemoval(keccak256("a"), "");

        acc.withdrawProposal(arbiter);

        assertEq(acc.getRemovalReply(arbiter), bytes32(0), "the reply was taken away together with the accusation");
        vm.prank(arbiter);
        vm.expectRevert(ArbiterAccountabilityFacet.NothingToAnswer.selector);
        acc.respondToRemoval(keccak256("a"), "");
    }

    /// A withdrawal against an EMPTY record does not touch a removed arbiter's reply.
    /// The withdrawal door belongs to the accuser, and without this boundary they would
    /// erase the objection of a person they have already removed: a removed arbiter has
    /// no proposal (clearSeat took it away) but does have a reply — and it must survive
    /// somebody else's press.
    function test_WithdrawingNothingDoesNotEraseARemovedMansAnswer() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
        vm.prank(arbiter);
        acc.respondToRemoval(keccak256("my side"), "");

        acc.withdrawProposal(arbiter);   // there is no record, so there is nothing to withdraw

        assertEq(
            acc.getRemovalReply(arbiter), keccak256("my side"),
            "a removed arbiter's objection is not erased by a withdrawal of nothing"
        );
    }

    /// A stale proposal is not an accusation. It cannot be answered: there is no live
    /// accusation, and it can no longer be executed either (ProposalStale). The only
    /// boundary where the reply and the removal must agree.
    function test_StaleProposalIsNotAnAccusationToAnswer() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, PROPOSAL_WORDS);
        vm.warp(vm.getBlockTimestamp() + acc.getProposalTTL());

        vm.prank(arbiter);
        vm.expectRevert(ArbiterAccountabilityFacet.NothingToAnswer.selector);
        acc.respondToRemoval(keccak256("a"), "");
    }

    /// The invariant the clearing in proposeRemoval rests on: for a SITTING arbiter
    /// removedAt is always zero. Otherwise a new proposal would erase the reply to a
    /// live, not yet undone removal.
    ///
    /// A control on the seam, not a lock. It catches the PAIR "the entrance doors erase
    /// removedAt" / "proposeRemoval requires isArbiter" drifting apart — if somebody
    /// introduces a third seating door without clearRemovalRecord tomorrow, it becomes
    /// visible here.
    ///
    /// ⚠️ Measured rather than promised: removing `if (!d.isArbiter[arbiter]) revert
    /// NotAnArbiter();` from `proposeRemoval` gives TWO reds — this one and
    /// `test_ProposeRevertsIfNotAnArbiter`. So it is never the only red on that
    /// corruption, and its silence means nothing by itself. Claiming that it is so on
    /// ANY corruption would be a promise without a measurement.
    function test_SeatedArbiterNeverCarriesALiveRemoval() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );

        // A proposal cannot be laid against a removed arbiter at all — they are not an arbiter.
        vm.expectRevert(ArbiterAccountabilityFacet.NotAnArbiter.selector);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Other, DIGEST, PROPOSAL_WORDS);
    }

    // ============================================================
    //  THE FOURTH UNVERIFIABLE PLACE: the values of the cause enum.
    //
    //  `Cause` is stored as a number (a uint8 in RemovalProposal), flies as an indexed
    //  topic in three events (ArbiterRemovedForCause, RemovalProposed,
    //  RemovalProposalConsumed) and is returned outwards as a uint8 from
    //  getRemovalProposal. There was not one check of the NUMBERS themselves: both
    //  places that looked like a check — `assertEq(c, uint8(Cause.Leak))` in
    //  test_ChiefProposalIsReadable and `assertEq(c, uint8(Cause.Other))` in
    //  test_SecondProposalOverwritesTheFirst — compare the enum with itself and survive
    //  ANY permutation of its members.
    //
    //  The price of a permutation or of inserting a member in the middle: every
    //  proposal already lying on chain quietly changes meaning, and so do all past
    //  accusation logs — "removed for leaking a chat log" turns into "removed for
    //  collusion" retrospectively. It is an eternal public record against a real
    //  address, and it cannot be withdrawn.
    // ============================================================

    /// The literals are nailed down. New codes may only be appended AT THE END — like
    /// fields in Diamond Storage, and for exactly the same reason.
    function test_CauseCodesArePinnedToTheirNumbers() public {
        assertEq(uint8(ArbiterAccountabilityFacet.Cause.OverturnedVerdicts), 0, "OverturnedVerdicts");
        assertEq(uint8(ArbiterAccountabilityFacet.Cause.Timeouts),           1, "Timeouts");
        assertEq(uint8(ArbiterAccountabilityFacet.Cause.Silence),            2, "Silence");
        assertEq(uint8(ArbiterAccountabilityFacet.Cause.Collusion),          3, "Collusion");
        assertEq(uint8(ArbiterAccountabilityFacet.Cause.Leak),               4, "Leak");
        assertEq(uint8(ArbiterAccountabilityFacet.Cause.Other),              5, "Other");
    }

    /// The second half of the same lock: the boundary "verified by the chain / attested
    /// by a digest" runs between codes 2 and 3, and that is not cosmetic —
    /// _isChainVerifiable enumerates the first three by name. A permutation that failed
    /// the first test must fail this one too if it carries a member across the
    /// boundary; it is checked by the PRODUCTION path (the verifiedByChain flag in the
    /// event) rather than by reading the same enum again.
    function test_ChainVerifiableBorderSitsBetweenSilenceAndCollusion() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Timeouts, bytes32(0), "");
        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.ArbiterRemovedForCause(
            arbiter, owner, ArbiterAccountabilityFacet.Cause.Timeouts, true, bytes32(0), 0
        );
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.Timeouts, bytes32(0), address(0), "");

        address second = address(0xA2);
        vm.store(address(acc), keccak256(abi.encode(second, uint256(ARB_BASE))), bytes32(uint256(1)));
        _proposeAndWait(second, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the proposal's own evidence"), PROPOSAL_WORDS);
        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.ArbiterRemovedForCause(
            second, owner, ArbiterAccountabilityFacet.Cause.Collusion, false, keccak256("e"), 0
        );
        acc.removeArbiterForCause(second, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("e"), address(0), "three times took the disputes of one counterparty and three times ruled in their favour");
    }

    // ============================================================
    //  THE CAUSE IN WORDS
    //
    //  It is mandatory exactly where the chain stays silent — and on BOTH doors, not
    //  only on the removal: the pause gives the accused time to answer, and they must
    //  answer an accusation and not a numeric code.
    //
    //  The words live in the EVENT, not in storage: their reader is the feed and the
    //  card, and storage would cost more and would move the layout for nothing.
    // ============================================================

    /// An attested code without words does not go through. It used to: a non-zero
    /// digest was enough, and anything at all may lie under one.
    function test_UnverifiableCauseRequiresWords() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), PROPOSAL_WORDS);
        vm.expectRevert(ArbiterAccountabilityFacet.ReasonRequired.selector);
        acc.removeArbiterForCause(
            arbiter,
            ArbiterAccountabilityFacet.Cause.Collusion,
            keccak256("evidence"),
            address(0),
            ""
        );
    }

    /// A chain-verifiable code need not explain itself in words: "three overturned
    /// verdicts" explains itself, and demanding text on top of that would introduce a
    /// field that gets filled with a full stop.
    function test_VerifiableCauseNeedsNoWords() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(
            arbiter,
            ArbiterAccountabilityFacet.Cause.OverturnedVerdicts,
            bytes32(0),
            address(0),
            ""
        );
        assertFalse(_isArbiterRaw(arbiter), "a chain-verifiable code went through without words");
    }

    /// The words travel in a separate event — the old one is NOT redefined, because
    /// the feed already reads it.
    function test_WordsRideTheirOwnEvent() public {
        string memory why = "three times took the disputes of one counterparty and three times ruled in their favour";

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("dump"), PROPOSAL_WORDS);
        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.RemovalReasonGiven(arbiter, owner, 1, why);

        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("dump"), address(0), why
        );
    }

    /// The ceiling is counted in BYTES. 513 bytes is already too many.
    function test_ReasonOverTheCapIsRefused() public {
        bytes memory tooLong = new bytes(513);
        for (uint256 i = 0; i < 513; i++) tooLong[i] = "x";

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Other, keccak256("e"), PROPOSAL_WORDS);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.ReasonTooLong.selector, uint256(513))
        );
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Other, keccak256("e"), address(0), string(tooLong)
        );
    }

    /// Exactly the ceiling passes. The boundary is strict on one side, as every
    /// boundary in this project is.
    function test_ReasonExactlyAtTheCapPasses() public {
        bytes memory atCap = new bytes(acc.getMaxReasonBytes());
        for (uint256 i = 0; i < atCap.length; i++) atCap[i] = "x";

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Other, keccak256("e"), PROPOSAL_WORDS);
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Other, keccak256("e"), address(0), string(atCap)
        );
        assertFalse(_isArbiterRaw(arbiter), "512 bytes is a lawful length");
    }

    /// A proposal obeys the same rule. Without it the pause would give the accused a
    /// cause code and nothing more.
    function test_ProposalWithUnverifiableCauseRequiresWords() public {
        _setChief(chief);
        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.ReasonRequired.selector);
        acc.proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), ""
        );
    }

    /// The proposal's words travel in an event of their own too — and this is the only
    /// check that looks at them. Measured in review: delete the whole
    /// `emit RemovalReasonGiven` block from `proposeRemoval` — **0 red out of 872**;
    /// substitute stage 0 with 7 — **0** again. The indexer gate and the client's ABI
    /// test compare the DECLARATION of the event and not its emission, and the gasless
    /// gate looks at the sender — the removal side was played out, the reply side was
    /// played out, and the proposal side was played out by nothing.
    ///
    /// Why this matters more than it looks: the pause is built on top of this promise.
    /// The accused learns the words of the accusation ONLY from here, and `stage` is
    /// the mark by which the feed separates a proposal from a removal. Let the event
    /// disappear silently, and the pause becomes forty-eight hours of silence.
    ///
    /// ⚠️ The stage is compared against the LITERAL 0 and not against a facet
    /// constant: asking the same chain for the value, the test would be looking in a
    /// mirror and would be content with any substitution (the same defect as in
    /// test_ReasonExactlyAtTheCapPasses).
    function test_ProposalWordsRideTheirOwnEventAtStageZero() public {
        _setChief(chief);
        string memory why = "took three disputes of one client in a row and not one of anybody else's";

        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.RemovalReasonGiven(arbiter, chief, 0, why);

        vm.prank(chief);
        acc.proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), why
        );

        assertTrue(acc.hasLiveProposal(arbiter), "the proposal must lie on chain");
    }

    /// For the accused this is a RIGHT and not an obligation: a reply without words is
    /// accepted. A person must not be forced to justify themselves publicly.
    function test_ReplyWordsAreOptional() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );

        vm.prank(arbiter);
        acc.respondToRemoval(keccak256("full log attached"), "");

        assertEq(
            acc.getRemovalReply(arbiter),
            keccak256("full log attached"),
            "a reply without words is accepted"
        );
    }

    /// But if there are words, they are public, in an event of their own.
    function test_ReplyWordsRideTheirOwnEvent() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );

        string memory said = "both verdicts were overturned on appeal, there was no third";

        vm.expectEmit(true, false, false, true, address(acc));
        emit ArbiterAccountabilityFacet.RemovalReplyGiven(arbiter, said);

        vm.prank(arbiter);
        acc.respondToRemoval(keccak256("x"), said);
    }

    /// The ceiling is one for both sides: a reply longer than 512 bytes is rejected
    /// too. A different length for the accusation and the defence would be a bias
    /// exactly where the whole piece of work is about symmetry.
    function test_ReplyOverTheCapIsRefused() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );

        bytes memory tooLong = new bytes(513);
        for (uint256 i = 0; i < 513; i++) tooLong[i] = "y";

        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.ReasonTooLong.selector, uint256(513))
        );
        acc.respondToRemoval(keccak256("x"), string(tooLong));
    }

    /// There are no empty events. Silence is a signal, and an empty string in the feed
    /// would erase the difference between "explained" and "stayed silent".
    function test_NoWordsMeansNoWordsEvent() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        vm.recordLogs();
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != ArbiterAccountabilityFacet.RemovalReasonGiven.selector,
                "there must be no empty words in the feed"
            );
        }
    }

    // ────────────────────────────────────────────────────────────
    //  A BYTE, NOT A CHARACTER — AND IT SHOWS ONLY ON A MULTIBYTE LETTER
    //
    //  The three checks above measure the ceiling with a Latin "x", whose byte and
    //  character are one and the same. On them the rule "count characters" is
    //  indistinguishable from the rule "count bytes": both versions are green.
    //  That is the very class the ceiling is named in BYTES for.
    //
    //  Here a Cyrillic letter is used: 257 letters is 257 characters and 514 bytes.
    //  Counted by characters such a string passes (257 < 512), counted by bytes it is
    //  rejected. That is exactly the fork the two tests below play out, and nobody
    //  else plays it out.
    //
    //  ⚠️ The expectations here are the LITERALS 512 and 514 and not
    //  getMaxReasonBytes(): asking the same chain for the ceiling, the bench would be
    //  comparing it with itself and would survive any change of the number in silence.
    //  The neighbouring test_ReasonExactlyAtTheCapPasses does ask for that ceiling —
    //  it guards the boundary but not the value.
    // ────────────────────────────────────────────────────────────

    /// A string of `letters` Cyrillic letters. The bytes come from the letter itself,
    /// written as a \u escape so the source stays ASCII without changing a byte: a
    /// bench in which the "multibyte letter" turned out to be a single-byte typo must
    /// fail here rather than hand over a green measurement.
    function _cyrillic(uint256 letters) private pure returns (string memory) {
        bytes memory ya = bytes("\u044f");
        require(ya.length == 2, "the bench lies: the letter must weigh two bytes");
        bytes memory out = new bytes(letters * 2);
        for (uint256 i = 0; i < letters; i++) {
            out[2 * i]     = ya[0];
            out[2 * i + 1] = ya[1];
        }
        return string(out);
    }

    /// 257 Cyrillic letters is 514 bytes, and the chain rejects them. Counted by
    /// characters this would be a lawful string, and an accuser would be putting twice
    /// as much on chain as was promised.
    function test_TheCapCountsBytesNotCharacters() public {
        string memory tooLong = _cyrillic(257);
        assertEq(bytes(tooLong).length, 514, "the bench is built wrong: not 514 bytes");

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Other, keccak256("e"), PROPOSAL_WORDS);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.ReasonTooLong.selector, uint256(514))
        );
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Other, keccak256("e"), address(0), tooLong
        );
    }

    /// And 256 Cyrillic letters — exactly 512 bytes — pass. That is the "~256
    /// characters" promised to a person: in the worst encoding they write in here.
    function test_TwoHundredFiftySixCyrillicLettersFitExactly() public {
        string memory atCap = _cyrillic(256);
        assertEq(bytes(atCap).length, 512, "the bench is built wrong: not 512 bytes");

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Other, keccak256("e"), PROPOSAL_WORDS);
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Other, keccak256("e"), address(0), atCap
        );
        assertFalse(_isArbiterRaw(arbiter), "256 Cyrillic letters is a lawful length");
    }

    /// A reply is counted in the same unit. Should the two sides diverge in the unit of
    /// counting, the defence would get half the room the accusation has, and only
    /// somebody who does not write in English would notice.
    function test_TheReplyCapCountsBytesToo() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );

        string memory tooLong = _cyrillic(257);
        assertEq(bytes(tooLong).length, 514, "the bench is built wrong: not 514 bytes");

        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.ReasonTooLong.selector, uint256(514))
        );
        acc.respondToRemoval(keccak256("x"), tooLong);
    }

    // ============================================================
    //  "THE CHIEF IS ABOLISHED UNDER THE DAO" WAS UNTRUE
    //
    //  setChiefArbiter is the ONLY writer of the slot and the only way to zero it, and
    //  it was closed while the DAO is active. A sitting chief stayed in the slot
    //  forever with all the onlyOwnerOrChief rights. Fixed in the modifier itself — in
    //  both of its copies, one per facet.
    //
    //  Here is the ArbiterAccountabilityFacet half (four functions). The
    //  ArbiterRegistryFacet half (addArbiter) is in
    //  test/ArbiterSeatingHandover.t.sol.
    // ============================================================

    function test_ChiefCanSuspendBeforeDao() public {
        _setChief(chief);
        vm.prank(chief);
        acc.suspendArbiter(arbiter);
        assertTrue(acc.isSuspended(arbiter), "before the DAO the chief works as before");
    }

    function test_ChiefLosesSuspendAfterDao() public {
        _setChief(chief);
        _activateDAO();
        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        acc.suspendArbiter(arbiter);
    }

    function test_ChiefLosesLiftSuspensionAfterDao() public {
        _setChief(chief);
        _activateDAO();
        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        acc.liftSuspension(arbiter);
    }

    function test_ChiefLosesProposeRemovalAfterDao() public {
        _setChief(chief);
        _activateDAO();
        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");
    }

    /// The fourth door. It matters separately: without it an irremovable chief who had
    /// lost the right to LAY a proposal would keep the right to TAKE somebody else's
    /// away — that is, to quench the owner's accusations against their own appointees.
    function test_ChiefLosesWithdrawProposalAfterDao() public {
        _setChief(chief);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");
        _activateDAO();
        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        acc.withdrawProposal(arbiter);
    }

    /// The reverse half of the same fix: while governance is not switched on, THE CHIEF
    /// IS ALIVE — however many deals outsiders may have closed. The opposite
    /// expectation used to stand here, and it was true for exactly as long as the
    /// threshold switched governance on by itself.
    ///
    /// The discriminator against test_ChiefLosesSuspendAfterDao above: there the same
    /// call on the same bench goes through a refusal. The difference between the scenes
    /// is one line, and it names the reason for the refusal explicitly.
    function test_ThresholdAloneDoesNotAbolishTheChief() public {
        _setChief(chief);
        _setUniqueActiveUsers(acc.getDaoThresholdMirror() * 10);
        vm.prank(chief);
        acc.suspendArbiter(arbiter);
        assertTrue(acc.isSuspended(arbiter), "a counter of outsiders does not abolish the chief");
    }

    /// A control that the modifier did not close for everybody: a suspension is
    /// reversible and expires by itself, and the owner does not lose it even after
    /// handing removal over.
    function test_OwnerKeepsSuspendAfterDao() public {
        _setChief(chief);
        _activateDAO();
        acc.suspendArbiter(arbiter);
        assertTrue(acc.isSuspended(arbiter), "the owner never loses suspension");
    }

    // ============================================================
    //  A REMOVAL SETS A SUSPENSION
    //
    //  Without it the strong measure was weaker than the weak one (submitVerdict is
    //  gated on a claim and not on status, and suspendArbiter on a removed arbiter
    //  already reverts NotAnArbiter). Here only the mark itself; that it really holds
    //  the finalisation is proved by a chain of three pieces of work on a real diamond
    //  in test/ArbiterRemovalForCauseIntegration.t.sol.
    // ============================================================

    function test_RemovalForCauseSuspendsTheRemoved() public {
        _setStreak(arbiter, 2);
        assertEq(acc.getSuspendedUntil(arbiter), 0, "setup: there was no suspension");

        // ⚠️ t0 is read AFTER the pause, not before it. Since 17 August 2026 a
        // removal is two transactions two days apart, and the suspension window
        // is counted from the second one; reading t0 at the top of the body
        // would put the expectation 48 hours in the past.
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        uint256 t0 = vm.getBlockTimestamp();

        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");

        assertEq(
            acc.getSuspendedUntil(arbiter), t0 + acc.getSuspensionWindow(),
            "a removal must imply a suspension: the same window as suspendArbiter's"
        );
        assertTrue(acc.isSuspended(arbiter), "the removed one is suspended right now");
    }

    /// A suspension from a removal expires by itself, like any other: a removed arbiter
    /// stays removed forever, but freezing somebody else's money forever at the price
    /// of one removal is a new weapon, not a defence.
    function test_RemovalSuspensionExpiresByItself() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");

        vm.warp(vm.getBlockTimestamp() + acc.getSuspensionWindow());
        assertFalse(acc.isSuspended(arbiter), "at the edge of the window it let go");
    }

    // ============================================================
    //  THE 48-HOUR PAUSE (design of 17 August 2026, decisions 1-4)
    //
    //  Removal stopped being a single button. It is now two transactions two
    //  days apart, and between them the person has time to see the accusation
    //  and answer it on chain.
    //
    //  There is no fast path, deliberately: "stop right now" is covered by
    //  suspension — instant, reversible, expiring by itself.
    // ============================================================

    /// Without a proposal there is no removal at all. Before this change it
    /// went through in one transaction and the person learned of it afterwards.
    function test_RemovalWithoutProposalIsRefused() public {
        _setStreak(arbiter, 2);
        vm.expectRevert(ArbiterAccountabilityFacet.NoLiveProposal.selector);
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
    }

    /// The proposal is there but the clock is still running. The error carries
    /// THE MOMENT from which it is allowed: the form can say "19 hours to go"
    /// instead of "try later".
    function test_RemovalBeforeTheDelayIsRefused() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        uint256 proposedAt = vm.getBlockTimestamp();

        vm.warp(proposedAt + acc.getRemovalDelay() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterAccountabilityFacet.RemovalTooEarly.selector,
                proposedAt + acc.getRemovalDelay()
            )
        );
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
    }

    /// One second later it goes through — the same scene, the same setup, the
    /// boundary crossed. The pair is the point: a stand that only played "a lot
    /// of time has passed" could not tell 48 hours from 47, or from any
    /// positive number at all.
    function test_RemovalAtTheExactBoundaryPasses() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());

        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
        assertFalse(_isArbiterRaw(arbiter), "48 hours are up, the removal is allowed");
    }

    /// A stale proposal is not executed. Otherwise an accusation half a year
    /// old would fire without a fresh warning.
    function test_RemovalOnStaleProposalIsRefused() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        uint256 proposedAt = vm.getBlockTimestamp();

        vm.warp(proposedAt + acc.getProposalTTL());
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.ProposalStale.selector, proposedAt)
        );
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
    }

    /// The last second of the proposal's life still works. The same strictness
    /// as hasLiveProposal: they must not diverge, or the button goes dark a day
    /// before the feed stops showing the accusation as live.
    function test_RemovalOnTheLastSecondOfTheProposalPasses() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        vm.warp(vm.getBlockTimestamp() + acc.getProposalTTL() - 1);

        assertTrue(acc.hasLiveProposal(arbiter), "stand: the proposal is still live");
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
        assertFalse(_isArbiterRaw(arbiter), "a live proposal executes down to its last second");
    }

    /// Warned about one thing, removed for another. Refused: the pause is given
    /// so the person answers THAT PARTICULAR accusation.
    function test_RemovalUnderADifferentCauseIsRefused() public {
        _setStreak(arbiter, 2);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Timeouts, bytes32(0), "");

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterAccountabilityFacet.CauseDiffersFromProposal.selector,
                uint8(ArbiterAccountabilityFacet.Cause.Timeouts),
                uint8(ArbiterAccountabilityFacet.Cause.OverturnedVerdicts)
            )
        );
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
    }

    /// The digest and the dispute reference are still the accuser's OWN, not
    /// taken from the proposal. Exactly one field is compared — the cause code,
    /// the thing the person was warned about — and not the whole application.
    function test_EvidenceIsPassedAfreshNotTakenFromTheProposal() public {
        _proposeAndWait(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("first guess"), PROPOSAL_WORDS
        );

        bytes32 realEvidence = keccak256("what the owner actually found");
        vm.expectEmit(true, true, true, true, address(acc));
        emit ArbiterAccountabilityFacet.ArbiterRemovedForCause(
            arbiter, owner, ArbiterAccountabilityFacet.Cause.Leak, false, realEvidence, 0
        );
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, realEvidence, address(0), PROPOSAL_WORDS
        );
    }

    /// A withdrawal kills the clock along with the proposal: the hours do not
    /// "keep running", they are gone. Checked down the live road, not by
    /// reading a field.
    function test_WithdrawalKillsTheClock() public {
        _setStreak(arbiter, 2);
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.withdrawProposal(arbiter);
        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());

        vm.expectRevert(ArbiterAccountabilityFacet.NoLiveProposal.selector);
        acc.removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
    }

    /// The execution window is not empty. This looks like a tautology and is
    /// not one: let these two numbers cross in a future edit and removal would
    /// become impossible AT ALL, under any schedule, while no scenario test
    /// would show it — they would all fail one by one, each with its own
    /// plausible-looking error.
    function test_RemovalWindowIsNotEmpty() public view {
        assertLt(
            acc.getRemovalDelay(),
            acc.getProposalTTL(),
            "the pause must be shorter than the proposal's own lifetime"
        );
    }

    /// The number of the pause is pinned. Proportionality to its neighbours is
    /// not decoration: 48 hours sit between the finalisation window (24) and
    /// suspension (72), and a silent shift would break the reasoning without
    /// breaking a single scenario.
    ///
    /// ⚠️ The expectation is a LITERAL, not acc.getRemovalDelay() read twice:
    /// asking the same chain for the number would make the stand look into a
    /// mirror and be happy with any substitution. The boundary tests above ask
    /// the chain on purpose — they guard the boundary, this one guards the
    /// value.
    function test_RemovalDelayIsFortyEightHours() public view {
        assertEq(acc.getRemovalDelay(), 48 hours, "the pause is 48 hours");
    }


    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    /// The gasless path of THIS copy of _msgSender() in full: the signature, the
    /// forwarder, and the relayer as a third address.
    ///
    /// ⚠️ RENAMED. It used to be called `test_MsgSenderMatchesRegistry` — a name that
    /// promised a comparison of the two copies which the test does not make and never
    /// did; its own docstring below contradicted it. The name was brought into line
    /// with what the test actually checks.
    ///
    /// ⚠️ This test does NOT compare the two copies against each other, although its
    /// former name and former docstring promised it: it drives only respondToRemoval,
    /// and a change in the original (ArbiterRegistryFacet._msgSender) would turn
    /// nothing red here. Its real value lies elsewhere and does not disappear: it
    /// compares the reply against an EXTERNAL truth — the signer's address
    /// vm.addr(arbiterPk) — and so catches an identical corruption introduced into
    /// BOTH bodies at once, which no differential can do. The real comparison of the
    /// pair lives in test/ArbiterRemovalForCauseIntegration.t.sol::
    /// test_MsgSenderAgreesAcrossBothFacetsOnOneForwarder.
    ///
    /// ⚠️ Found in review: the earlier version pranked as the forwarder's address and
    /// glued the calldata tail on by hand (`abi.encodePacked`), bypassing
    /// `MinimalForwarder.execute()` and the signature check entirely — that proved
    /// "the function correctly extracts the address from the calldata tail" rather
    /// than "the gasless path works end to end: signature, check, relayer". It was
    /// rewritten to the golden model —
    /// `testFundDisputeThroughForwarderIsPaidByTheHuman` and
    /// `test/DisputeNoResponse.t.sol::test_RecordNoResponse_ThroughRealForwarder_CreditsHumanNotForwarder`:
    /// a real EIP-712 request, a real signature, a real `fwd.execute()` from a third
    /// address (neither the arbiter nor the forwarder) — as the relayer really does
    /// it.
    function test_RespondToRemovalThroughForwarderCreditsHuman() public {
        uint256 arbiterPk = 0xCA11;
        address arb = vm.addr(arbiterPk);
        address relayer = address(0x9999); // a third address: not the arbiter, not the forwarder

        // A fresh arbiter under this address — setUp seats only the fixed `arbiter`
        // (0xA1), for whom no private key is known.
        vm.store(address(acc), keccak256(abi.encode(arb, uint256(ARB_BASE))), bytes32(uint256(1)));

        MinimalForwarder fwd = new MinimalForwarder();
        _setForwarder(address(acc), address(fwd));

        _setStreak(arb, 2);
        _proposeAndWait(arb, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), "");
        acc.removeArbiterForCause(arb, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), "");

        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  arb,
            to:    address(acc),
            value: 0,
            gas:   500_000,
            nonce: fwd.getNonce(arb),
            // ⚠️ The selector is taken FROM THE TYPE, so the compiler picks up the
            // change of signature (17 August 2026, the words of the reply) by itself;
            // there are two arguments now. Calldata assembled by hand from the old
            // shape would have given "function not found" — a red for the wrong reason.
            data:  abi.encodeWithSelector(acc.respondToRemoval.selector, keccak256("x"), "")
        });

        vm.prank(relayer);
        (bool ok, bytes memory ret) = fwd.execute(req, _signFwd(fwd, arbiterPk, req));
        assertTrue(ok, string.concat("forwarded respondToRemoval failed: ", vm.toString(ret)));

        assertEq(acc.getRemovalReply(arb), keccak256("x"),
            "the reply must be recorded for THE PERSON and not for the forwarder");
    }

    // ---------- HELPERS ----------

    function _isArbiterRaw(address who) internal view returns (bool) {
        return vm.load(address(acc), keccak256(abi.encode(who, uint256(ARB_BASE)))) != bytes32(0);
    }

    /// Removal only runs through a proposal that has sat. The helper lays one
    /// down and winds time exactly to the far side of the pause.
    ///
    /// ⚠️ vm.getBlockTimestamp(), not block.timestamp: under via_ir solc treats
    /// TIMESTAMP as constant within a call, and a second warp in the same body
    /// would jump to the same second as the first.
    ///
    /// ⚠️ The cause given here must be the cause given to the removal — since
    /// 17 August 2026 the two are compared (CauseDiffersFromProposal).
    function _proposeAndWait(
        address who,
        ArbiterAccountabilityFacet.Cause cause,
        bytes32 digest,
        string memory reason
    ) internal {
        acc.proposeRemoval(who, cause, digest, reason);
        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());
    }

    /// Same, laid down by a named caller. Needed after handover: since
    /// 17 August 2026 the accusation door travels with the right to
    /// act on it, so past handover the OWNER cannot propose and the successor
    /// must do it himself — which is the point of a handover.
    function _proposeAndWaitAs(
        address caller,
        address who,
        ArbiterAccountabilityFacet.Cause cause,
        bytes32 digest,
        string memory reason
    ) internal {
        vm.prank(caller);
        acc.proposeRemoval(who, cause, digest, reason);
        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());
    }

    /// The human door must freeze TODAY'S term into the record.
    ///
    /// ⚠️ THE ONLY OBSERVABLE DIFFERENCE IS THE VALUE IN STORAGE, and that is said out
    /// loud rather than hidden. While the constant has not changed, a record with its
    /// own term and a record with a zero behave IDENTICALLY: a zero falls into the
    /// fallback branch of that very constant. A behavioural scene is impossible here in
    /// principle — measured and confirmed, a corruption of `ttl: 0` in
    /// `proposeRemoval` gave zero red out of 1278 — so storage is what is checked.
    ///
    /// The expectation is a LITERAL written down by a person: `getProposalTTL()` here
    /// would be comparing the facet's constant with itself and would agree at any
    /// value. The second line compares the getter against the same literal — so the
    /// divergence "the field is written with something other than what is returned
    /// outwards" is visible too, and it is visible WHICH of the two halves drifted.
    function test_TheHumanDoorFreezesTodaysRuleIntoTheAccusation() public {
        acc.proposeRemoval(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), "published the chat log of a dispute to a third party");

        assertEq(_storedProposalTtl(arbiter), 14 days, "the record must hold today's term and not a zero");
        assertEq(acc.getProposalTTL(), 14 days, "and the same one is returned outwards");
    }

    /// `removalProposals` is slot 29 (pinned by a literal in
    /// test/StorageLayout.t.sol). `ttl` lies in the THIRD slot of the record, packed
    /// with `by`: the address takes the low 20 bytes and the term the next 8.
    ///
    /// It is written read-modify-write so that `by` survives, and every call is
    /// CHECKED: the neighbouring fields must stay as they were. Miss the offset and
    /// either a neighbour changes (visible here) or nothing changes at all (visible to
    /// the scene itself, which then fails to go red for its own reason). Both halves of
    /// the trap are closed.
    function _proposalTtlSlot(address who) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(who, uint256(bytes32(uint256(ARB_BASE) + 29))))) + 3);
    }

    function _storedProposalTtl(address who) internal view returns (uint64) {
        return uint64(uint256(vm.load(address(acc), _proposalTtlSlot(who))) >> 160);
    }

    function _setProposalTtl(address who, uint64 ttl) internal {
        (uint8 causeBefore, bytes32 digestBefore, uint256 atBefore, address byBefore,) =
            acc.getRemovalProposal(who);

        bytes32 slot = _proposalTtlSlot(who);
        bytes32 packed = vm.load(address(acc), slot);
        bytes32 keepBy = packed & bytes32(uint256(type(uint160).max));
        vm.store(address(acc), slot, keepBy | bytes32(uint256(ttl) << 160));

        (uint8 causeAfter, bytes32 digestAfter, uint256 atAfter, address byAfter,) =
            acc.getRemovalProposal(who);
        assertEq(causeAfter,  causeBefore,  "the ttl offset missed: the cause moved");
        assertEq(digestAfter, digestBefore, "the ttl offset missed: the digest moved");
        assertEq(atAfter,     atBefore,     "the ttl offset missed: the time of filing moved");
        assertEq(byAfter,     byBefore,     "the ttl offset missed: the author moved");
        assertEq(_storedProposalTtl(who), ttl, "the ttl offset missed: the record did not change");
    }

    function _setStreak(address who, uint256 n) internal {
        bytes32 base = bytes32(uint256(ARB_BASE) + SLOT_MISTAKE_STREAK);
        vm.store(address(acc), keccak256(abi.encode(who, uint256(base))), bytes32(n));
    }

    /// Seats the chief as an arbiter, by the same single means setUp seats `arbiter`:
    /// `isArbiter[who] = true` at slot 0 of the namespace. Needed by the scenes that lay
    /// an accusation AGAINST the chief: proposeRemoval refuses NotAnArbiter to anybody
    /// not counted as an arbiter.
    function _seatChiefAsArbiter() internal {
        vm.store(address(acc), keccak256(abi.encode(chief, uint256(ARB_BASE))), bytes32(uint256(1)));
    }

    /// chiefArbiter shares slot 5 with daoActiveManual (a bool at byte offset 20). It
    /// is read-modify-written so that the order of the call relative to _activateDAO
    /// does not matter — no test today combines them, but a blind overwrite of the
    /// whole slot would be a quiet mine for the future.
    function _setChief(address who) internal {
        bytes32 slot = bytes32(uint256(ARB_BASE) + 5);
        bytes32 current = vm.load(address(acc), slot);
        bytes32 daoBit = current & bytes32(uint256(1) << 160);
        vm.store(address(acc), slot, bytes32(uint256(uint160(who))) | daoBit);
    }

    /// daoActiveManual is a bool packed into slot 5 (the same as chiefArbiter) at byte
    /// offset 20 (bit 160). Obtained by an offset-by-byte sweep, see the file
    /// docstring. The obvious guess was "slot 6, separately" — a miss: packing an
    /// address and a bool into one 32-byte slot shifts everything after them back by
    /// one relative to a naive calculation.
    function _activateDAO() internal {
        bytes32 slot = bytes32(uint256(ARB_BASE) + 5);
        bytes32 current = vm.load(address(acc), slot);
        vm.store(address(acc), slot, current | bytes32(uint256(1) << 160));
    }

    /// daoAddress is slot 10, obtained by sweeping.
    function _setDaoAddress(address dao) internal {
        vm.store(address(acc), bytes32(uint256(ARB_BASE) + 10), bytes32(uint256(uint160(dao))));
    }

    /// disputeNoResponseAtBy is a nested mapping: deal → arbiter → moment. The offset
    /// is guarded by test_NoResponseSlotOffsetIsCorrect.
    uint256 constant SLOT_NO_RESPONSE = 23;

    function _setNoResponse(address deal, address who, uint256 at) internal {
        bytes32 outer = keccak256(abi.encode(deal, uint256(bytes32(uint256(ARB_BASE) + SLOT_NO_RESPONSE))));
        vm.store(address(acc), keccak256(abi.encode(who, uint256(outer))), bytes32(at));
    }

    /// seatedBy is slot 25 and seatedCountBy slot 26. Both were obtained by sweeping
    /// against ArbiterRegistryFacet.getSeatedBy/getSeatedCountBy (the same layout, a
    /// different deployed contract — the slot position does not depend on that).
    /// ArbiterAccountabilityFacet has no getters of its own for these fields, so the
    /// read-back is a direct vm.load rather than a call through the ABI.
    function _setSeatedBy(address arbiterAddr, address seater) internal {
        bytes32 slot = keccak256(abi.encode(arbiterAddr, uint256(bytes32(uint256(ARB_BASE) + 25))));
        vm.store(address(acc), slot, bytes32(uint256(uint160(seater))));
    }

    function _setSeatedCountBy(address seater, uint256 count) internal {
        bytes32 slot = keccak256(abi.encode(seater, uint256(bytes32(uint256(ARB_BASE) + 26))));
        vm.store(address(acc), slot, bytes32(count));
    }

    function _getSeatedCountBy(address seater) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(seater, uint256(bytes32(uint256(ARB_BASE) + 26))));
        return uint256(vm.load(address(acc), slot));
    }

    function _setArbiterBond(address who, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(who, uint256(bytes32(uint256(ARB_BASE) + SLOT_ARBITER_BOND))));
        vm.store(address(acc), slot, bytes32(amount));
    }

    function _getArbiterBond(address who) internal view returns (uint256) {
        bytes32 slot = keccak256(abi.encode(who, uint256(bytes32(uint256(ARB_BASE) + SLOT_ARBITER_BOND))));
        return uint256(vm.load(address(acc), slot));
    }

    function _getVaultBalance() internal view returns (uint256) {
        return uint256(vm.load(address(acc), bytes32(uint256(ARB_BASE) + SLOT_VAULT_BALANCE)));
    }

    function _setUniqueActiveUsers(uint256 n) internal {
        vm.store(address(acc), bytes32(uint256(REP_BASE) + SLOT_UNIQUE_ACTIVE_USERS), bytes32(n));
    }

    /// trustedForwarder is slot 3 inside FactoryStorage.Layout (usdc(0),
    /// feeRecipient(1), regionFee(2, a mapping with a slot of its own),
    /// trustedForwarder(3)). NOT "the second field", as was mistakenly assumed — the
    /// same offset that is already asserted in test/DisputeNoResponse.t.sol,
    /// test/ArbiterChatKey.t.sol and test/BoardsFixture.sol. It is read back and
    /// compared at once: with a wrong offset vm.store quietly writes into another
    /// field, and test_RespondToRemovalThroughForwarderCreditsHuman would be checking
    /// something entirely different from what its name says.
    function _setForwarder(address facet, address forwarder) internal {
        bytes32 slot = bytes32(uint256(FactoryStorage.FACTORY_STORAGE_POSITION) + 3);
        vm.store(facet, slot, bytes32(uint256(uint160(forwarder))));
        assertEq(
            address(uint160(uint256(vm.load(facet, slot)))),
            forwarder,
            "the trustedForwarder offset in FactoryStorage.Layout has drifted"
        );
    }

    /// The EIP-712 signature of a ForwardRequest — a verbatim copy of
    /// test/DisputeNoResponse.t.sol::_signFwd: the same domain
    /// `("MinimalForwarder", "0.0.1")`, the same typehash.
    function _signFwd(MinimalForwarder fwd, uint256 pk, MinimalForwarder.ForwardRequest memory req)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            FWD_TYPEHASH, req.from, req.to, req.value, req.gas, req.nonce, keccak256(req.data)
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            keccak256(abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MinimalForwarder")),
                keccak256(bytes("0.0.1")),
                block.chainid,
                address(fwd)
            )),
            structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// MISTAKE_THRESHOLD in the new facet must be STRICTLY BELOW MAX_ARBITER_MISTAKES
    /// in the old one — not equal: on equality the automatic path
    /// (_recordArbiterMistake) resets the counter in the same transaction that clears
    /// isArbiter, and OverturnedVerdicts/Timeouts would never go through. The
    /// MAX_ARBITER_MISTAKES_MIRROR mirror is additionally compared separately from the
    /// derived threshold — that catches a drift of the mirror itself and not only the
    /// final inequality.
    function test_MistakeThresholdMatchesRegistry() public {
        ArbiterRegistryFacet reg = new ArbiterRegistryFacet();
        assertEq(acc.getMaxArbiterMistakesMirror(), reg.getMaxArbiterMistakes(),
            "the mirror of the threshold must match the production number");
        assertLt(acc.getMistakeThreshold(), reg.getMaxArbiterMistakes(),
            "the manual removal threshold must be STRICTLY below the automatic one, or it is unreachable");
    }
}
