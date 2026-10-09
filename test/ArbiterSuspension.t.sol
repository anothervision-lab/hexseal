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
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

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

    /// ⚠️ ZERO MEANS "NOW", WHICH IS WHAT EVERY SCENE BUT ONE WANTS. The clock
    /// used to be `block.timestamp` flat, so the dispute window could never be
    /// made to run out and `abandonClaim` was unreachable on this bench. Needed
    /// since 9 October 2026, when `_driveToAutoDemotion` lost the owner's
    /// overturn and had to book its mistakes some other way. Left as an OVERRIDE
    /// rather than a stored timestamp written in the constructor, so that every
    /// existing scene keeps the behaviour it was written under -- a mock whose
    /// dispute is always fresh -- and only the scene that needs an expired window
    /// asks for one.
    uint256 public disputedAtOverride;

    function disputedAt() external view returns (uint256) {
        return disputedAtOverride == 0 ? block.timestamp : disputedAtOverride;
    }

    function setDisputedAt(uint256 t) external { disputedAtOverride = t; }

    function DISPUTE_WINDOW() external pure returns (uint256) { return 30 days; }
    function setArbiter(address) external {}
    function resolveDispute(bool) external {}
}

contract ArbiterSuspensionTest is Test, ArbiterTwoFacetBench {
    ArbiterAccountabilityFacet acc;
    ArbiterRegistryFacet reg;
    ArbiterVaultFacet regVault;

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
        (reg, acc, regVault) = _deployArbiterBench();

        owner    = address(this);
        chief    = address(0xC4);
        arbiter  = address(0xA1);
        stranger = address(0x5A);

        vm.store(address(acc), OWNER_SLOT, bytes32(uint256(uint160(owner))));
        _makeArbiter(acc, arbiter);
        _setChief(acc, chief);

        // ⚠️ THE CHAIN STARTS AT A SANE EPOCH, AND IT HAS TO (9 October 2026).
        // Forge's default `block.timestamp` is 1, and `_driveToAutoDemotion` now
        // runs a dispute window OUT by moving the deal's clock BACK rather than
        // the chain's forward -- it must not move the chain, because the callers
        // read `t0` before it and assert the suspension lands at exactly
        // `t0 + 72 hours`. At a timestamp of 1 there is no earlier moment to put
        // the dispute at, so the subtraction would underflow.
        //
        // Every assertion in this file is relative to `vm.getBlockTimestamp()`,
        // so moving the start costs nothing and nothing here reads an absolute
        // date.
        vm.warp(365 days);
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

        // ⚠️ LEAVING NEVER NEEDS A BOND, and this bench proves it the hard way:
        // it has no USDC contract at all, so a refund of a non-zero bond would
        // revert on a call into address(0). The bond is dropped to zero first,
        // which is exactly the state of a man who never paid — and he must still
        // be able to walk out. `resignAsArbiter` is deliberately not gated by
        // `_requireBonded` for this reason; gating it would lock an unbonded
        // arbiter into a seat he cannot quit.
        vm.store(address(reg), keccak256(abi.encode(arbiter, uint256(ARB_BASE) + 12)), bytes32(0));

        vm.prank(arbiter);
        reg.resignAsArbiter();
        assertFalse(regVault.isRegisteredArbiter(arbiter), "after the window one may resign");
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
        // The bond behind the seat (8 September 2026). Since the bond gate landed,
        // a seated arbiter with a zero bond is refused by every arbiter door with
        // `BondNotPosted`, so a rig that seats one has to fund him too. Slot 12 of
        // the arbiter namespace is `arbiterBond`, pinned by test/StorageLayout.t.sol.
        vm.store(address(reg), keccak256(abi.encode(who, uint256(ARB_BASE) + 12)), bytes32(uint256(50_000_000)));
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

        vm.warp(vm.getBlockTimestamp() + 72 hours); // FINALIZE_DELAY, 24 -> 72 h on 9 Oct 2026
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
    /// judicial mistakes in a row on three different deals. No vm.store into the
    /// mistake counter — otherwise the test would be staging a scene the production
    /// code might never reach.
    ///
    /// ⚠️ THE MISTAKES ARE MISSED WINDOWS NOW, NOT THE OWNER'S OVERTURNS
    /// (9 October 2026). This loop used to claim, submit a verdict and then call
    /// `overturnVerdict`; that door is gone. What this helper is FOR is reaching
    /// MAX_ARBITER_MISTAKES, and `arbiterMistakeStreak` counts every path the same
    /// — `_recordArbiterMistake` increments it before it looks at which road the
    /// mistake came down. So the cheapest surviving road is taken: the arbiter
    /// claims the dispute and never rules, and a stranger takes the dead claim off
    /// him with `abandonClaim`.
    ///
    /// ⚠️ WHAT THIS CHANGES ABOUT THE SCENE, SAID RATHER THAN GLOSSED OVER. The
    /// cumulative `overturnedVerdicts` counter is NOT touched by this road — it is
    /// an allow-list of `OwnerOverturn` and `AppealVote` — so a scene that read
    /// that counter could not use this helper. Nothing in this file reads it: what
    /// these tests prove is that an arbiter the automatic road has stopped cannot
    /// finalize, and the suspension is set by the streak alone.
    ///
    /// ⚠️ NO VERDICT IS SUBMITTED, and `abandonClaim` requires exactly that
    /// (`VerdictAlreadySubmitted` otherwise) — the door's whole subject is a
    /// dispute nobody ruled on. The window is run out by moving the DEAL's clock
    /// back rather than by warping the chain's forward, so the timestamps the
    /// callers measure afterwards are left where they were.
    function _driveToAutoDemotion() internal {
        for (uint256 i = 0; i < 3; i++) {
            MockAgreementForFinalize mistake =
                new MockAgreementForFinalize(address(uint160(0xD00 + i)), address(uint160(0xE00 + i)));

            bytes32 salt = bytes32(uint256(100 + i));
            vm.prank(arbiter);
            reg.commitDisputeClaim(keccak256(abi.encodePacked(address(mistake), arbiter, salt)));
            // vm.getBlockNumber() rather than block.number — see the note on
            // _advanceToSubmittedVerdict, which this loop used to call.
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(arbiter);
            reg.claimDispute(address(mistake), salt, bytes32(uint256(1)), bytes32(uint256(2)));

            // The window has run out on him: the deal's dispute is older than
            // DISPUTE_WINDOW, so the claim is dead and anybody may say so.
            mistake.setDisputedAt(vm.getBlockTimestamp() - 31 days);
            reg.abandonClaim(address(mistake));
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
        assertTrue(regVault.isRegisteredArbiter(arbiter), "wrong scene: the seat must survive the automatic road");

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
        assertTrue(regVault.isRegisteredArbiter(arbiter), "wrong scene: the seat must survive the automatic road");

        vm.warp(t0 + 72 hours);
        reg.finalizeVerdict(address(victim));

        assertEq(acc.getCleanVerdicts(arbiter), 1, "after the window the verdict executed in the ordinary way");
    }

    function _makeArbiter(ArbiterAccountabilityFacet f, address who) internal {
        vm.store(address(f), keccak256(abi.encode(who, uint256(ARB_BASE))), bytes32(uint256(1)));
        // The bond behind the seat (8 September 2026). Since the bond gate landed,
        // a seated arbiter with a zero bond is refused by every arbiter door with
        // `BondNotPosted`, so a rig that seats one has to fund him too. Slot 12 of
        // the arbiter namespace is `arbiterBond`, pinned by test/StorageLayout.t.sol.
        vm.store(address(f), keccak256(abi.encode(who, uint256(ARB_BASE) + 12)), bytes32(uint256(50_000_000)));
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
        assertEq(
            bond, 50_000_000,
            "the card must show the bond the seat actually carries"
        );
        // ⚠️ The literal is what this bench PUT there, not what a hand seating
        // gives. `addArbiter` still takes nothing — that claim is held by
        // test/ArbiterProvenance.t.sol and by
        // ArbiterBondRequiredTest.test_AHandGivenSeatCarriesNoBondAndIsNotActive.
        // What this line guards is that the standing card REPORTS the field
        // rather than a zero of its own.
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
        // cause (1..6) and does not fall into the auto-removal range (240..255 =
        // AUTO_REMOVAL_BASE + DemotionPath). The AUTO_REMOVAL_CODE constant that an
        // earlier version of this line referred to no longer exists — a base
        // replaced it; the statement itself did not stop being true, only the
        // reference was a lie.
        //
        // ⚠️ The range in that sentence was 252..255 until 18 September 2026, when
        // the base moved down to 240 to make room for a fifth path. 211 survives the
        // move — it is still below the floor, in the 7..239 gap that belongs to
        // nobody — but the margin is now 29 codes and not 41, and a base moved lower
        // still would swallow this marker and make the field read as an automatic
        // removal that never happened.

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

    // ============================================================
    //  THE CEILING ON THE HAND (8 October 2026)
    //
    //  Until this date `suspendArbiter` had no counter and no check of any kind:
    //  every press wrote a fresh 72-hour deadline, without limit, so one hand
    //  could hold one arbiter stopped for ever by pressing every third day. The
    //  owner's decision put a ceiling of three on it, with the count going back
    //  to zero after a week in which nobody pressed.
    //
    //  ⚠️ EVERY NUMBER IN THIS SECTION IS TYPED OUT BY HAND and never read back
    //  off the contract. A lock whose expectation comes from the thing it checks
    //  agrees with anything: a test that asked `HAND_SUSPENSION_LIMIT` what the
    //  limit is would be green at any limit. Three and a week are what a person
    //  decided; if the code moves away from them, these tests must say so.
    // ============================================================

    uint256 constant HAND_LIMIT    = 3;
    uint256 constant HAND_SILENCE  = 7 days;

    /// The whole sentence the fourth press is answered with, typed out once so
    /// that the two tests below cannot drift apart from each other.
    ///
    /// ⚠️ A STRING AND NOT A CUSTOM ERROR, deliberately: this refusal is read by
    /// WHOEVER PRESSED, often from a bare `cast` call, and four bytes of selector
    /// tell such a reader nothing at all.
    string constant HAND_CEILING_REFUSAL =
        "ArbiterAccountability: three suspensions already stand against this arbiter -"
        " propose his removal (proposeRemoval), or leave him a week unpressed and the lever comes back";

    /// Presses the lever `n` times, an hour apart, and asserts every one of them
    /// landed. The hour between presses is not decoration: it makes each
    /// deadline a different number, so "the press landed" is proved by a value
    /// that moved and not by a value that was already there.
    function _pressTheHand(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            uint256 t = vm.getBlockTimestamp();
            acc.suspendArbiter(arbiter);
            assertEq(
                acc.getSuspendedUntil(arbiter),
                t + 72 hours,
                "a press inside the ceiling must land and write its own deadline"
            );
            vm.warp(t + 1 hours);
        }
    }

    /// THE DESIGNATED LOCK for the ceiling itself.
    function test_TheFourthSuspensionInARowIsRefused() public {
        _pressTheHand(HAND_LIMIT);

        uint256 held = acc.getSuspendedUntil(arbiter);

        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);

        // A refused press changes NOTHING: the check stands above every write in
        // the function, so there is no half-pressed state to find.
        assertEq(acc.getSuspendedUntil(arbiter), held, "a refused press must not move the deadline");
    }

    /// THE DESIGNATED LOCK for "the refusal names the right instrument".
    ///
    /// Asked by searching the returned bytes for the door's name rather than by
    /// comparing the whole sentence: the sentence may be reworded, the duty to
    /// name a door the refused presser can actually open may not.
    ///
    /// ⚠️ `proposeRemoval` AND NOT `removeArbiterForCause`, and that is measured
    /// rather than chosen by taste: this ceiling binds the chief arbiter exactly
    /// as it binds the owner, and `removeArbiterForCause` does not admit the
    /// chief at all. Naming a door the refused presser may not be able to open
    /// would be worse than naming none.
    function test_TheRefusalNamesTheDoorToUseInstead() public {
        _pressTheHand(HAND_LIMIT);

        (bool ok, bytes memory ret) = address(acc).call(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.suspendArbiter.selector, arbiter)
        );
        assertFalse(ok, "wrong scene: the fourth press must be refused");
        assertTrue(_bytesContain(ret, "proposeRemoval"), "the refusal must name the door to use instead");
        assertTrue(_bytesContain(ret, "suspensions"), "and it must say what the refusal is about");
    }

    /// ONE LEVER, TWO HANDS. The count is per ARBITER and not per presser: the
    /// owner and the chief share the brake, so sharing the count is what makes
    /// the ceiling mean anything at all. Without this, two people hold six.
    function test_TheCeilingBindsTheOwnerAndTheChiefTogether() public {
        uint256 t = vm.getBlockTimestamp();
        acc.suspendArbiter(arbiter);                 // owner, 1
        vm.warp(t + 1 hours);
        vm.prank(chief);
        acc.suspendArbiter(arbiter);                 // chief, 2
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        acc.suspendArbiter(arbiter);                 // owner, 3

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(chief);
        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);
    }

    /// Three is three, not two: the ceiling must not refuse a press a person was
    /// promised. Proved by the deadline of the third press, which is a number
    /// that moved rather than a silence.
    function test_TheThirdPressStillLands() public {
        _pressTheHand(2);
        uint256 t = vm.getBlockTimestamp();
        acc.suspendArbiter(arbiter);
        assertEq(acc.getSuspendedUntil(arbiter), t + 72 hours, "the third press is inside the ceiling");
    }

    /// THE DESIGNATED LOCK for "the lever comes back".
    function test_AWeekOfSilenceGivesTheLeverBack() public {
        _pressTheHand(HAND_LIMIT);
        uint256 lastPress = vm.getBlockTimestamp() - 1 hours;

        vm.warp(lastPress + HAND_SILENCE);
        uint256 t = vm.getBlockTimestamp();
        acc.suspendArbiter(arbiter);
        assertEq(acc.getSuspendedUntil(arbiter), t + 72 hours, "after a week of silence the lever is whole");

        // And the count really RESTARTED rather than being nudged down by one:
        // two more land, the one after them does not.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        acc.suspendArbiter(arbiter);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        acc.suspendArbiter(arbiter);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);
    }

    /// The boundary of the silence, from the side that must still refuse.
    function test_OneSecondShortOfTheWeekStillRefuses() public {
        _pressTheHand(HAND_LIMIT);
        uint256 lastPress = vm.getBlockTimestamp() - 1 hours;

        vm.warp(lastPress + HAND_SILENCE - 1);
        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);
    }

    /// THE DESIGNATED LOCK for "silence, not the calendar".
    ///
    /// A calendar reset — three a week, read as `block.timestamp / 7 days` — is
    /// gamed by pressing three times just before a bucket boundary and three
    /// more just after it, which doubles the ceiling at a moment the presser
    /// picks. This scene stands on exactly that boundary: three presses end a
    /// minute before an epoch-week boundary, and the fourth comes a minute after
    /// it. Under a calendar rule the fourth would land. It must not.
    function test_TheResetIsBySilenceAndNotByTheCalendar() public {
        // A moment three minutes before an epoch multiple of seven days, so that
        // three hourly presses and the fourth press straddle it.
        uint256 boundary = ((vm.getBlockTimestamp() / HAND_SILENCE) + 2) * HAND_SILENCE;
        vm.warp(boundary - 3 hours - 60);

        _pressTheHand(HAND_LIMIT);                       // presses at -3h, -2h, -1h
        assertLt(vm.getBlockTimestamp(), boundary, "wrong scene: the presses must sit before the boundary");

        vm.warp(boundary + 60);
        assertGt(vm.getBlockTimestamp(), boundary, "wrong scene: the fourth press must sit after the boundary");

        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);
    }

    /// THE OBVERSE LIE: a lift must NOT hand the press back.
    ///
    /// If it did, the ceiling would cost nothing at all — press, lift, press,
    /// lift, for ever, with the arbiter stopped the whole time the window is
    /// open. What hands the press back is a week of silence and nothing else.
    function test_LiftingASuspensionDoesNotGiveThePressBack() public {
        _pressTheHand(HAND_LIMIT);
        acc.liftSuspension(arbiter);
        assertFalse(acc.isSuspended(arbiter), "wrong scene: the lift must have worked");

        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);
    }

    /// The count belongs to the ARBITER, so filling it on one man leaves the
    /// lever whole over everybody else. Without this a busy month would stop the
    /// brake for the entire corps.
    function test_TheCeilingIsPerArbiterAndNotProtocolWide() public {
        address second = address(0xA2);
        _makeArbiter(acc, second);

        _pressTheHand(HAND_LIMIT);
        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);

        uint256 t = vm.getBlockTimestamp();
        acc.suspendArbiter(second);
        assertEq(acc.getSuspendedUntil(second), t + 72 hours, "another arbiter's lever is untouched");
    }

    /// A refused press on somebody who is not an arbiter must not spend an
    /// allowance: the two older guards stand ABOVE the ceiling in the function,
    /// so a mistyped address costs nothing.
    function test_ARefusalOlderThanTheCeilingSpendsNothing() public {
        vm.expectRevert(ArbiterAccountabilityFacet.NotAnArbiter.selector);
        acc.suspendArbiter(stranger);
        vm.expectRevert(ArbiterAccountabilityFacet.ArbiterZeroAddress.selector);
        acc.suspendArbiter(address(0));

        // All three presses are still there.
        _pressTheHand(HAND_LIMIT);
        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);
    }

    /// THE DESIGNATED LOCK for "the ceiling binds the hand and not the chain".
    ///
    /// The automatic path writes `suspendedUntil` itself, from inside
    /// `_recordArbiterMistake`, and must keep doing so with the hand's three
    /// already spent. A ceiling that could be filled up by hand and thereby
    /// silence the automaton would be a way to PROTECT a bad arbiter by pressing
    /// at him — the exact opposite of what it is for.
    ///
    /// Proved by a deadline that MOVED: the hand's own window is walked out
    /// first (otherwise `claimDispute` would refuse the arbiter on the way to
    /// the third mistake), so the number this test reads afterwards can only
    /// have been written by the automatic path.
    function test_TheAutomatonIsNotBoundByTheHandsCeiling() public {
        vm.store(address(reg), OWNER_SLOT, bytes32(uint256(uint160(owner))));
        _makeArbiterReg(arbiter);

        _pressTheHand(HAND_LIMIT);
        uint256 lastPress = vm.getBlockTimestamp() - 1 hours;
        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);

        // Out the far end of the hand's own window, but nowhere near the week of
        // silence — so the hand's three are still spent when the chain presses.
        uint256 handWindowEnd = lastPress + 72 hours;
        vm.warp(handWindowEnd);
        assertFalse(acc.isSuspended(arbiter), "wrong scene: the hand's window must have let go");
        assertEq(acc.getSuspendedUntil(arbiter), handWindowEnd, "wrong scene: and the old deadline is still on file");

        _driveToAutoDemotion();

        assertTrue(acc.isSuspended(arbiter), "the chain's own suspension must land with the hand's three spent");
        assertGt(
            acc.getSuspendedUntil(arbiter),
            handWindowEnd,
            "and it must be a NEW window rather than the hand's old one read back"
        );

        // And the hand is still refused, so the scene above did not quietly
        // hand the press back by way of the automatic write.
        vm.expectRevert(bytes(HAND_CEILING_REFUSAL));
        acc.suspendArbiter(arbiter);
    }

    /// Searches `haystack` for `needle`. Used by the refusal test above, because
    /// what is being asked of the sentence is that it NAMES a door, not that it
    /// is any particular sentence.
    function _bytesContain(bytes memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory n = bytes(needle);
        if (n.length == 0 || haystack.length < n.length) return false;
        for (uint256 i = 0; i + n.length <= haystack.length; i++) {
            bool same = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (haystack[i + j] != n[j]) { same = false; break; }
            }
            if (same) return true;
        }
        return false;
    }
}
