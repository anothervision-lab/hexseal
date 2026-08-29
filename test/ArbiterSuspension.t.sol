// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Suspending an arbiter.
//
// The central part of the whole piece of work. Between a dishonest arbiter and
// the pot stand exactly 24 hours (FINALIZE_DELAY): an appeal is possible only
// before finalisation, and after it nothing can be played back. A suspension is
// the only thing that fits inside that window.
//
// It is deliberately REVERSIBLE and expires by itself: the worst that can be
// done with it is to hold money for the length of the window, and the chain will
// show who did it. That is why it stays with the owner even after removal is
// handed over to a vote.
//
// ⚠️ Time is read ONLY through vm.getBlockTimestamp(): under via_ir solc treats
// TIMESTAMP as constant within a call, and a second vm.warp in one test body
// would jump to the same second.

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";

/// A minimal Agreement mock — only what finalizeVerdict reads and calls (by way
/// of claimDispute/submitVerdict on the road there): status/disputedAt/
/// DISPUTE_WINDOW/client/executor are read with a staticcall, and setArbiter/
/// resolveDispute are called. A real Agreement is not needed here — what is at
/// stake is not the execution of a verdict but the fact that a suspended arbiter
/// is not allowed to execute it.
contract MockAgreementForFinalize {
    address public client;
    address public executor;

    constructor(address client_, address executor_) {
        client = client_;
        executor = executor_;
    }

    function status() external pure returns (uint8) { return 4; } // DISPUTED
    function disputedAt() external view returns (uint256) { return block.timestamp; }
    function DISPUTE_WINDOW() external pure returns (uint256) { return 30 days; }
    function setArbiter(address) external {}
    function resolveDispute(bool) external {}
}

contract ArbiterSuspensionTest is Test, ArbiterTwoFacetBench {
    ArbiterAccountabilityFacet acc;
    ArbiterRegistryFacet reg;

    address owner;
    address chief;
    address arbiter;
    address stranger;

    bytes32 constant ARB_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;
    bytes32 constant OWNER_SLOT = 0x178642b411f9f4783b21ef338f3e96db6c1272d763f0b7500ec93464dafb8604;

    function setUp() public {
        // ⚠️ ONE ADDRESS FOR BOTH FACETS.
        // There used to be two separate `new`s here, and each facet had its OWN
        // storage at one and the same namespace offset. That worked while every
        // test touched the state of exactly one of them.
        //
        // Moving getCleanVerdicts into the accountability facet, while the counter
        // is still written by finalizeVerdict in the registry, made "written
        // through reg, read through acc" an ordinary thing. On two separate
        // contracts that would give a clean zero and look like an answer. The
        // bench now gives one proxy carrying the code of both facets, as in
        // production.
        (reg, acc) = _deployArbiterBench();

        owner    = address(this);
        chief    = address(0xC4);
        arbiter  = address(0xA1);
        stranger = address(0x5A);

        vm.store(address(acc), OWNER_SLOT, bytes32(uint256(uint160(owner))));
        _makeArbiter(acc, arbiter);
        _setChief(acc, chief);
    }

    function test_OwnerSuspends() public {
        uint256 t0 = vm.getBlockTimestamp();

        vm.expectEmit(true, true, false, true, address(acc));
        emit ArbiterAccountabilityFacet.ArbiterSuspended(arbiter, owner, t0 + 72 hours);

        acc.suspendArbiter(arbiter);

        assertTrue(acc.isSuspended(arbiter), "after the press the arbiter is suspended");
        assertEq(acc.getSuspendedUntil(arbiter), t0 + 72 hours, "the window is exactly 72 hours");
    }

    function test_ChiefSuspends() public {
        vm.prank(chief);
        acc.suspendArbiter(arbiter);
        assertTrue(acc.isSuspended(arbiter), "stopping the bleeding is the chief's job");
    }

    function test_StrangerCannotSuspend() public {
        vm.prank(stranger);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        acc.suspendArbiter(arbiter);
    }

    function test_SuspensionExpiresByItself() public {
        acc.suspendArbiter(arbiter);
        assertTrue(acc.isSuspended(arbiter));

        vm.warp(vm.getBlockTimestamp() + 72 hours);
        assertFalse(acc.isSuspended(arbiter), "at the edge of the window the suspension has already let go");
    }

    function test_SuspensionHoldsUntilTheLastSecond() public {
        acc.suspendArbiter(arbiter);
        vm.warp(vm.getBlockTimestamp() + 72 hours - 1);
        assertTrue(acc.isSuspended(arbiter), "a second before the end it still holds");
    }

    function test_OwnerLiftsEarly() public {
        acc.suspendArbiter(arbiter);
        acc.liftSuspension(arbiter);
        assertFalse(acc.isSuspended(arbiter), "sorted it out early and let go");
        assertEq(acc.getSuspendedUntil(arbiter), 0, "the counter is zeroed, not left in the past");
    }

    // ── a light hand does not undo a heavy one ──
    //
    // A suspension comes in two weights, and the chain tells them apart by the
    // removal record. The ordinary one is quick, reversible and accuses nobody:
    // the chief lifts it too, that is their job. The one imposed BY A REMOVAL is
    // the only thing holding the money on the removed arbiter's verdicts inside
    // FINALIZE_DELAY, and it cannot be restored after being lifted (suspendArbiter
    // requires isArbiter, and a removed arbiter is no longer one). Undoing it is
    // the same as undoing the removal itself, and the chief may not remove.

    /// The chief does not open a window imposed by a removal.
    function test_ChiefCannotLiftRemovalSuspension() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the chat log"));
        acc.removeArbiterForCause(
            arbiter,
            ArbiterAccountabilityFacet.Cause.Collusion,
            keccak256("the chat log"),
            address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        assertTrue(acc.isSuspended(arbiter), "setup: the removal imposed the window");

        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.RemovalSuspensionIsRemovalAuthorityOnly.selector);
        acc.liftSuspension(arbiter);

        assertTrue(acc.isSuspended(arbiter), "the window is in place: the chief did not open it");
    }

    /// The owner does open it. They are undoing THEIR OWN decision, and this is
    /// exactly the same fork already settled in addArbiter (liftSuspension = true).
    function test_OwnerLiftsRemovalSuspension() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the chat log"));
        acc.removeArbiterForCause(
            arbiter,
            ArbiterAccountabilityFacet.Cause.Collusion,
            keccak256("the chat log"),
            address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        acc.liftSuspension(arbiter);

        assertFalse(acc.isSuspended(arbiter), "the owner may undo their own decision");
        assertEq(acc.getSuspendedUntil(arbiter), 0, "the counter is zeroed, not left in the past");
    }

    /// The other side of the same check, and without it the lock would be too
    /// wide: the chief still lifts an ORDINARY suspension. Lose this check and
    /// "what is weighty is gated" quietly turns into "everything is gated", leaving
    /// the chief with no work at all.
    function test_ChiefStillLiftsAnOrdinarySuspension() public {
        acc.suspendArbiter(arbiter);
        assertTrue(acc.isSuspended(arbiter));

        vm.prank(chief);
        acc.liftSuspension(arbiter);

        assertFalse(acc.isSuspended(arbiter), "a light measure, a light hand: this is their job");
    }

    function test_SuspendingNonArbiterReverts() public {
        vm.expectRevert(ArbiterAccountabilityFacet.NotAnArbiter.selector);
        acc.suspendArbiter(stranger);
    }

    /// The ArbiterZeroAddress branch was declared but checked by no test: the
    /// behaviour was asserted by the name of an error rather than proved.
    function test_SuspendZeroAddressReverts() public {
        vm.expectRevert(ArbiterAccountabilityFacet.ArbiterZeroAddress.selector);
        acc.suspendArbiter(address(0));
    }

    /// A second press extends the window from the present moment rather than
    /// doubling its length: otherwise an owner who pressed twice by inattention
    /// holds somebody else's money for six days instead of three.
    function test_SecondSuspendRestartsWindow() public {
        acc.suspendArbiter(arbiter);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 t1 = vm.getBlockTimestamp();
        acc.suspendArbiter(arbiter);
        assertEq(acc.getSuspendedUntil(arbiter), t1 + 72 hours, "the window counts from the new press");
    }

    // ============================================================
    //  THE TEETH OF A SUSPENSION
    //
    //  Without them a suspension is a notice on a wall. The third prohibition
    //  (resigning) matters more than the first two: resignAsArbiter returns the
    //  bond IN FULL, so a suspect walks away with the money before the removal, and
    //  the whole money circuit of the punishment stays decorative.
    // ============================================================

    /// One facet across both contracts is needed here: the prohibition reads the
    /// same field the suspension writes. reg is deployed and its slots edited.
    function test_SuspendedCannotClaim() public {
        _makeArbiterReg(arbiter);
        _suspendInReg(arbiter, vm.getBlockTimestamp() + 72 hours);

        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterRegistryFacet.ArbiterSuspendedError.selector,
                vm.getBlockTimestamp() + 72 hours
            )
        );
        reg.claimDispute(address(0xDEAD), bytes32(0), bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_SuspendedCannotResign() public {
        _makeArbiterReg(arbiter);
        _suspendInReg(arbiter, vm.getBlockTimestamp() + 72 hours);

        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterRegistryFacet.ArbiterSuspendedError.selector,
                vm.getBlockTimestamp() + 72 hours
            )
        );
        reg.resignAsArbiter();
    }

    /// The suspension let go, so resigning is possible again. Otherwise it would be
    /// a permanent prohibition in the guise of a temporary one.
    function test_ResignWorksAfterSuspensionExpires() public {
        _makeArbiterReg(arbiter);
        _suspendInReg(arbiter, vm.getBlockTimestamp() + 72 hours);

        vm.warp(vm.getBlockTimestamp() + 72 hours);

        vm.prank(arbiter);
        reg.resignAsArbiter();
        assertFalse(reg.isRegisteredArbiter(arbiter), "after the window one may resign");
    }

    /// The third prohibition checks THE VERDICT'S ARBITER, not whoever calls
    /// finalizeVerdict (which anybody may call). The dispute is driven to a
    /// submitted verdict by the real road (commit → claim → submit), the arbiter is
    /// suspended AFTER the submission — and finalisation must refuse with the same
    /// error.
    function test_SuspendedArbiterCannotFinalize() public {
        _makeArbiterReg(arbiter);
        MockAgreementForFinalize agreement = new MockAgreementForFinalize(address(0xC1), address(0xE1));
        _advanceToSubmittedVerdict(agreement, bytes32(uint256(7)));

        uint256 until = vm.getBlockTimestamp() + 72 hours;
        _suspendInReg(arbiter, until);

        vm.expectRevert(
            abi.encodeWithSelector(ArbiterRegistryFacet.ArbiterSuspendedError.selector, until)
        );
        reg.finalizeVerdict(address(agreement));
    }

    /// commit → roll → claim → submit, the shared run-up of both tests on the
    /// finalizeVerdict path (the third prohibition and the clean-verdict counter) to
    /// a submitted verdict. Extracted because seven or eight lines were repeated
    /// word for word in two tests.
    function _advanceToSubmittedVerdict(MockAgreementForFinalize agreement, bytes32 salt) internal {
        vm.prank(arbiter);
        reg.commitDisputeClaim(keccak256(abi.encodePacked(address(agreement), arbiter, salt)));
        // vm.getBlockNumber() rather than block.number: under via_ir solc treats
        // NUMBER as constant within a call exactly as it does TIMESTAMP (see the
        // file header), and a second vm.roll in one test body would jump to the same
        // block — the claim would get CommitmentTooEarly. Single calls to the helper
        // did not care; the auto-demotion tests call it four times in a row.
        vm.roll(vm.getBlockNumber() + 1);

        vm.prank(arbiter);
        reg.claimDispute(address(agreement), salt, bytes32(uint256(1)), bytes32(uint256(2)));

        vm.prank(arbiter);
        reg.submitVerdict(address(agreement), true);
    }

    function _makeArbiterReg(address who) internal {
        vm.store(address(reg), keccak256(abi.encode(who, uint256(ARB_BASE))), bytes32(uint256(1)));
    }

    /// The offset of suspendedUntil inside Data. Found by sweeping rather than
    /// assumed: the obvious guess was 25 (following the pattern of an earlier case,
    /// where a guess of 21 turned out to be 13 in reality — packing an address and
    /// a bool into the chiefArbiter slot shifts the indices of every field after
    /// it). A throwaway probe (sweeping offset 0..59, writing 999999 into
    /// keccak256(arbiter, ARB_BASE+offset) and comparing with
    /// acc.getSuspendedUntil(arbiter)) gave a single hit — offset 27. Guarded by
    /// the test below.
    uint256 constant SLOT_SUSPENDED_UNTIL = 27;

    function _suspendInReg(address who, uint256 until) internal {
        bytes32 base = bytes32(uint256(ARB_BASE) + SLOT_SUSPENDED_UNTIL);
        vm.store(address(reg), keccak256(abi.encode(who, uint256(base))), bytes32(until));
    }

    /// ⚠️ Simplified when both facets moved onto one address, and that is a
    /// strengthening rather than a loss. The test used to write the raw slot into
    /// ONE contract, satisfy itself that the SECOND answered zero ("it is a
    /// different contract"), and only then duplicate the write into the second to
    /// check the offset. The first half checked not the offset but the fact that
    /// two separate `new`s have different storages.
    ///
    /// The bench is now one address for both facets, and the check has become
    /// direct: the raw slot is written exactly where the production getter looks,
    /// and that value is demanded back from it. Offset 27 is guarded as before —
    /// and now at the same address `_suspendInReg` uses in every teeth test.
    function test_SuspendedUntilSlotMatchesLiveStorage() public {
        _suspendInReg(arbiter, 12345);
        assertEq(acc.getSuspendedUntil(arbiter), 12345, "the suspendedUntil slot offset has drifted");
    }

    // ============================================================
    //  THE CLEAN-VERDICT COUNTER
    //
    //  Judging service will be needed LATER, when the DAO is switched on ("a bond
    //  plus judging service"), but there is nothing to count it from unless the
    //  counter is started now — starting it at the moment the DAO comes on is
    //  pointless, since everybody would be at zero.
    // ============================================================

    function test_CleanVerdictIncrementsOnFinalize() public {
        _makeArbiterReg(arbiter);
        MockAgreementForFinalize agreement = new MockAgreementForFinalize(address(0xC2), address(0xE2));
        _advanceToSubmittedVerdict(agreement, bytes32(uint256(11)));

        assertEq(acc.getCleanVerdicts(arbiter), 0, "before finalisation there is no service");

        vm.warp(vm.getBlockTimestamp() + 24 hours);
        reg.finalizeVerdict(address(agreement));

        assertEq(acc.getCleanVerdicts(arbiter), 1, "an unoverturned verdict added service");
    }

    // ============================================================
    //  THE AUTOMATIC ROAD SUSPENDS TOO
    //
    //  There are two doors out of the arbiter corps. The manual one
    //  (removeArbiterForCause) imposes a suspension. The automatic one — a third
    //  judging mistake in _recordArbiterMistake — did not impose one, and that was
    //  the same hole on the door that fires WITHOUT a human: finalizeVerdict looks
    //  at the suspension rather than at the status, so a punished arbiter drove
    //  disputes already claimed all the way to the money inside FINALIZE_DELAY, and
    //  there was nothing to stop them with (suspendArbiter on a non-arbiter reverts
    //  NotAnArbiter).
    //
    //  ⚠️ THIS SUSPENSION LATER BECAME THE MAIN EFFECT of the threshold branch
    //  rather than a side one: there is no removal there any more, there is an
    //  accusation in the chain's name and 48 hours of pause. So for all two days
    //  between the mistake and the removal the money is held by exactly this mark
    //  and by nothing else.
    //
    //  Both tests prove by CONSEQUENCE — a refusal from finalizeVerdict — rather
    //  than by reading the field: a field can be set and read nowhere.
    // ============================================================

    /// Drives `arbiter` to the automatic threshold by the real road: three
    /// overturned verdicts in a row on three different deals. No vm.store into the
    /// mistake counter — otherwise the test would be staging a scene the production
    /// code might never reach.
    function _driveToAutoDemotion() internal {
        for (uint256 i = 0; i < 3; i++) {
            MockAgreementForFinalize mistake =
                new MockAgreementForFinalize(address(uint160(0xD00 + i)), address(uint160(0xE00 + i)));
            _advanceToSubmittedVerdict(mistake, bytes32(uint256(100 + i)));
            reg.overturnVerdict(address(mistake), false);
        }
    }

    function test_AutoDemotedArbiterCannotFinalize() public {
        vm.store(address(reg), OWNER_SLOT, bytes32(uint256(uint160(owner))));
        _makeArbiterReg(arbiter);

        // A dispute claimed BEFORE the suspension: this is the one the stopped arbiter would drive to the money.
        MockAgreementForFinalize victim = new MockAgreementForFinalize(address(0xC7), address(0xE7));
        _advanceToSubmittedVerdict(victim, bytes32(uint256(77)));

        uint256 t0 = vm.getBlockTimestamp();
        _driveToAutoDemotion();

        // ⚠️ A third mistake no longer REMOVES anybody — it suspends and accuses in
        // the chain's name. The seat survives, and that made the scene sharper
        // rather than weaker: the property being proved — "the automatic road sets
        // the same suspension, and it holds the money" — is now the only thing
        // standing between a person and the pot for all 48 hours of the pause. It is
        // checked by CONSEQUENCE, by the refusal from finalizeVerdict below, and not
        // by reading the field.
        assertTrue(reg.isRegisteredArbiter(arbiter), "wrong scene: the seat must survive the automatic road");

        // The finalisation window has passed — the only thing now standing between a
        // punished arbiter and the pot is the suspension.
        vm.warp(t0 + 24 hours);

        vm.expectRevert(
            abi.encodeWithSelector(ArbiterRegistryFacet.ArbiterSuspendedError.selector, t0 + 72 hours)
        );
        reg.finalizeVerdict(address(victim));
    }

    /// The discriminator: without it the first test does not tell a suspension from
    /// "everything broke altogether". After the window the verdict is finalised in
    /// the ordinary way — a removed arbiter stays removed forever, but a suspension
    /// must not freeze somebody else's money for ever.
    function test_AutoDemotedArbiterVerdictFinalizesAfterWindow() public {
        vm.store(address(reg), OWNER_SLOT, bytes32(uint256(uint160(owner))));
        _makeArbiterReg(arbiter);

        MockAgreementForFinalize victim = new MockAgreementForFinalize(address(0xC8), address(0xE8));
        _advanceToSubmittedVerdict(victim, bytes32(uint256(78)));

        uint256 t0 = vm.getBlockTimestamp();
        _driveToAutoDemotion();

        // ⚠️ A third mistake no longer REMOVES anybody — it suspends and accuses in
        // the chain's name. The seat survives, and that made the scene sharper
        // rather than weaker: the property being proved — "the automatic road sets
        // the same suspension, and it holds the money" — is now the only thing
        // standing between a person and the pot for all 48 hours of the pause. It is
        // checked by CONSEQUENCE, by the refusal from finalizeVerdict below, and not
        // by reading the field.
        assertTrue(reg.isRegisteredArbiter(arbiter), "wrong scene: the seat must survive the automatic road");

        vm.warp(t0 + 72 hours);
        reg.finalizeVerdict(address(victim));

        assertEq(acc.getCleanVerdicts(arbiter), 1, "after the window the verdict executed in the ordinary way");
    }

    function _makeArbiter(ArbiterAccountabilityFacet f, address who) internal {
        vm.store(address(f), keccak256(abi.encode(who, uint256(ARB_BASE))), bytes32(uint256(1)));
    }

    /// Since 17 August 2026 a removal only runs through a proposal that has sat
    /// for REMOVAL_DELAY, and the cause at execution must match the one
    /// proposed. Words are passed because the causes used on this stand are the
    /// ones the chain does not check, and those demand them.
    ///
    /// ⚠️ vm.getBlockTimestamp(), not block.timestamp: under via_ir solc treats
    /// TIMESTAMP as constant within a call.
    function _proposeAndWait(address who, ArbiterAccountabilityFacet.Cause cause, bytes32 digest)
        internal
    {
        acc.proposeRemoval(who, cause, digest, "the accusation, stated once, on the proposal");
        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());
    }

    /// chiefArbiter is the sixth field of Data (index 5), an ordinary variable and
    /// not a mapping. It used to be checked with a call to
    /// acc.getChiefArbiterAddress() — a test-only getter, since removed: it
    /// duplicated the already existing ArbiterRegistryFacet.getChiefArbiter(), and
    /// through a proxy diamond both selectors go to the same address anyway.
    ///
    /// ⚠️ A bare write, with NO guard here. The first version read the written value
    /// back with a `vm.load` of the same computed slot — an identity of a write with
    /// itself: it would have matched at ANY value of the `+ 5` constant, right or
    /// wrong, and could never have gone red. A permanent public getter was not
    /// introduced (the same reason getChiefArbiterAddress was removed) — instead the
    /// guard on the offset was moved into a separate behavioural test,
    /// test_ChiefSlotOffsetIsCorrect below: it proves with production code
    /// (`_requireOwnerOrChief`) that the written slot is the right one, rather than
    /// proving an identity.
    function _setChief(ArbiterAccountabilityFacet f, address who) internal {
        vm.store(address(f), bytes32(uint256(ARB_BASE) + 5), bytes32(uint256(uint160(who))));
    }

    /// A behavioural guard on the chiefArbiter slot offset. It replaces the dead
    /// vm.load identity (see the _setChief docstring above): newChief is written
    /// through the same helper setUp uses, and BEHAVIOUR proves that the production
    /// read of the slot sees precisely them — by a call to liftSuspension (a no-op
    /// apart from the event, a safe probe: it damages nothing whether it succeeds or
    /// reverts). A stranger on the same call must get NotOwnerOrChief — a control
    /// that the test distinguishes anything at all rather than passing for any
    /// caller.
    ///
    /// ⚠️ THE PROBE DOES NOT GO THROUGH THE MODIFIER. Here and below it used to say
    /// "passed onlyOwnerOrChief" — since 16 August that is untrue: the modifier was
    /// taken off `liftSuspension` entirely. The body of the check is the same
    /// (`_requireOwnerOrChief`, which is what the modifier consists of), but it is
    /// now called EXPLICITLY and only in one of two branches — the one where
    /// `removedAt == 0`. On a fresh facet that is indeed zero, so the probe lands in
    /// that branch and remains valid. Should anybody set a non-zero `removedAt`
    /// here, the probe would quietly be checking the other branch.
    function test_ChiefSlotOffsetIsCorrect() public {
        ArbiterAccountabilityFacet f = new ArbiterAccountabilityFacet();
        address newChief = address(0xC5);
        _setChief(f, newChief);

        vm.prank(newChief);
        f.liftSuspension(arbiter); // does not revert: passed _requireOwnerOrChief through a production read of the slot

        vm.prank(stranger);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        f.liftSuspension(arbiter);
    }

    // ============================================================
    //  AN ARBITER'S STANDING IN ONE READ
    //
    //  getArbiterStanding is one call instead of seven or eight. A client and an
    //  outside reader need it: this cannot be assembled from seven separate
    //  requests — blocks pass between them and the picture disagrees with itself
    //  (the bond read before a removal, the status after).
    // ============================================================

    /// The offsets of the fields getArbiterStanding needs but a caller cannot reach
    /// through ArbiterAccountabilityFacet's own functions:
    /// arbiterMistakeStreak/arbiterBond/seatedBy/openClaimCount/cleanVerdicts/
    /// removedAt live in ArbiterRegistryStorage (the same raw-storage model as
    /// suspendedUntil above — SLOT_SUSPENDED_UNTIL = 27), while xp/cleanStreak live
    /// in ReputationStorage, a foreign namespace. Found by sweeping (offset 0..40 /
    /// 0..15, writing a marker into a candidate slot and reading through
    /// getArbiterStanding itself as the oracle: it uses the struct's named fields,
    /// the compiler computes the slot, and only the outside sweep can be wrong) —
    /// the throwaway probe was run and deleted, as prescribed.
    bytes32 constant REP_BASE            = 0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400;
    uint256 constant SLOT_MISTAKE_STREAK = 11;
    uint256 constant SLOT_BOND           = 12;
    uint256 constant SLOT_OPEN_CLAIMS    = 13;
    uint256 constant SLOT_SEATED_BY      = 25;
    uint256 constant SLOT_CLEAN_VERDICTS = 28;
    uint256 constant SLOT_REMOVED_AT     = 31;
    uint256 constant SLOT_XP             = 0;
    uint256 constant SLOT_CLEAN_STREAK   = 9;

    /// The permanent removal record was appended at the end of the struct, so its
    /// offsets follow removedAt (31). The numbers were derived by counting fields
    /// AND checked behaviourally right here: with a wrong offset vm.store quietly
    /// writes into another field, and the assertEq on its own number in
    /// test_StandingDistinguishesEveryField fails.
    uint256 constant SLOT_REMOVAL_COUNT       = 32;
    uint256 constant SLOT_LAST_REMOVAL_AT     = 33;
    uint256 constant SLOT_LAST_REMOVAL_CAUSE  = 34;

    /// The cumulative overturn count was appended at the end of the struct AFTER
    /// chainProposalPath (35), hence 36. The number is a literal and is checked
    /// behaviourally the same way as the three above: miss the slot and vm.store
    /// quietly writes into another field, and its own number in
    /// test_StandingDistinguishesEveryField will not add up.
    uint256 constant SLOT_OVERTURNED_VERDICTS = 36;

    function _storeUint(bytes32 base, uint256 offset, address who, uint256 value) internal {
        bytes32 slot = keccak256(abi.encode(who, uint256(base) + offset));
        vm.store(address(acc), slot, bytes32(value));
    }

    /// The standing of an arbiter who has just been suspended; everything else is
    /// the light bench's zeroes by default. Extended with fields that did not exist
    /// when the case was first written down (cleanVerdicts, overturnedVerdicts,
    /// removedAt, hasLiveRemovalProposal) — they appeared in storage later (see the
    /// getArbiterStanding docstring in the facet itself).
    function test_StandingReturnsEverythingAtOnce() public {
        acc.suspendArbiter(arbiter);

        (
            uint256 xp,
            uint256 cleanStreak,
            uint256 mistakeStreak,
            uint256 bond,
            address seatedBy,
            uint256 suspendedUntil,
            uint256 openClaims,
            uint256 cleanVerdicts,
            uint256 overturnedVerdicts,
            uint256 removedAt,
            bool    hasLiveRemovalProposal,
            uint256 removalCount,
            uint256 lastRemovalAt,
            uint8   lastRemovalCause
        ) = acc.getArbiterStanding(arbiter);

        assertEq(xp, 0);
        assertEq(cleanStreak, 0);
        assertEq(mistakeStreak, 0);
        assertEq(bond, 0, "a hand-picked arbiter has no bond, and that is visible");
        assertEq(seatedBy, address(0));
        assertEq(suspendedUntil, vm.getBlockTimestamp() + 72 hours, "the suspension is visible right here");
        assertEq(openClaims, 0);
        assertEq(cleanVerdicts, 0, "there is no judging service yet");
        assertEq(overturnedVerdicts, 0, "no overturns yet, and this is the SECOND half of the fraction");
        assertEq(removedAt, 0, "never removed: zero, not rubbish");
        assertFalse(hasLiveRemovalProposal, "there was no removal proposal");
        assertEq(removalCount, 0, "never removed once: zero, not rubbish");
        assertEq(lastRemovalAt, 0, "there is no moment of a past removal");
        assertEq(lastRemovalCause, 0, "zero means 'never removed', not Cause number zero");
    }

    /// A mutation probe: EVERY numeric and address field gets its own unique value
    /// — substituting any one field for another (returning bond where cleanVerdicts
    /// belongs, say) must fail exactly its own assertEq and no other.
    /// hasLiveRemovalProposal is a boolean and has no "own number" to substitute;
    /// both the direct corruption (hardcoded true) and the reverse one (hardcoded
    /// false) are caught here and in test_StandingReturnsEverythingAtOnce at the
    /// same time: false is expected there and true here.
    function test_StandingDistinguishesEveryField() public {
        _storeUint(REP_BASE, SLOT_XP, arbiter, 501);
        _storeUint(REP_BASE, SLOT_CLEAN_STREAK, arbiter, 502);
        _storeUint(ARB_BASE, SLOT_MISTAKE_STREAK, arbiter, 503);
        _storeUint(ARB_BASE, SLOT_BOND, arbiter, 504);
        _storeUint(ARB_BASE, SLOT_SEATED_BY, arbiter, uint256(uint160(address(0xBEEF))));
        _storeUint(ARB_BASE, SLOT_OPEN_CLAIMS, arbiter, 506);
        _storeUint(ARB_BASE, SLOT_CLEAN_VERDICTS, arbiter, 507);
        _storeUint(ARB_BASE, SLOT_REMOVED_AT, arbiter, 508);
        _storeUint(ARB_BASE, SLOT_REMOVAL_COUNT, arbiter, 509);
        _storeUint(ARB_BASE, SLOT_LAST_REMOVAL_AT, arbiter, 510);
        _storeUint(ARB_BASE, SLOT_OVERTURNED_VERDICTS, arbiter, 511);
        // The cause is a uint8 and does not fit 509/510, so it gets a marker of its
        // own from the same series but within the type's range: 211 matches no real
        // cause (1..6) and does not fall into the auto-removal range (252..255 =
        // AUTO_REMOVAL_BASE + DemotionPath). The AUTO_REMOVAL_CODE constant that an
        // earlier version of this line referred to no longer exists — a base
        // replaced it; the statement itself did not stop being true, only the
        // reference was a lie.
        _storeUint(ARB_BASE, SLOT_LAST_REMOVAL_CAUSE, arbiter, 211);

        // suspendedUntil goes through a production call rather than a marker: the
        // value (t0 + 72h) already differs from all eight markers above at any
        // sensible t0.
        acc.suspendArbiter(arbiter);
        uint256 expectedSuspendedUntil = vm.getBlockTimestamp() + 72 hours;

        // hasLiveRemovalProposal goes through a production call too: Collusion is not
        // checked by the chain, so proposeRemoval does not touch arbiterMistakeStreak
        // (the 503 above stays untouched) and requires only a non-zero digest.
        vm.prank(chief);
        acc.proposeRemoval(
            arbiter,
            ArbiterAccountabilityFacet.Cause.Collusion,
            bytes32(uint256(0xC0FFEE)),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        (
            uint256 xp,
            uint256 cleanStreak,
            uint256 mistakeStreak,
            uint256 bond,
            address seatedBy,
            uint256 suspendedUntil,
            uint256 openClaims,
            uint256 cleanVerdicts,
            uint256 overturnedVerdicts,
            uint256 removedAt,
            bool    hasLiveRemovalProposal,
            uint256 removalCount,
            uint256 lastRemovalAt,
            uint8   lastRemovalCause
        ) = acc.getArbiterStanding(arbiter);

        assertEq(xp, 501, "xp");
        assertEq(cleanStreak, 502, "cleanStreak");
        assertEq(mistakeStreak, 503, "mistakeStreak");
        assertEq(bond, 504, "bond");
        assertEq(seatedBy, address(0xBEEF), "seatedBy");
        assertEq(suspendedUntil, expectedSuspendedUntil, "suspendedUntil");
        assertEq(openClaims, 506, "openClaims");
        assertEq(cleanVerdicts, 507, "cleanVerdicts");
        assertEq(overturnedVerdicts, 511, "overturnedVerdicts");
        assertEq(removedAt, 508, "removedAt");
        assertTrue(hasLiveRemovalProposal, "hasLiveRemovalProposal");
        assertEq(removalCount, 509, "the removals field returns its own number");
        assertEq(lastRemovalAt, 510, "the moment field returns its own");
        assertEq(lastRemovalCause, uint8(211), "the cause field returns its own");
    }
}
