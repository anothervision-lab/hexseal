// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The moment a dispute is claimed, and the record "asked for the chat log, got
// no answer".
//
// The chain cannot see the message store and has no way whatever to verify
// "asked". All it can do is record the fact on the arbiter's word, together with
// the exact time. The anchor exists for the sake of that time: on an appeal the
// ORDER of events has to be visible (took the dispute → waited this long →
// recorded silence), not somebody's word.
//
// Hence the main property of both fields: neither the anchor nor the record is
// ever rewritten. Both are keyed by the PAIR (deal, arbiter) and written once.
// Both transactions available to the arbiter — release the dispute and claim it
// again — are free to them (gasless), so "wipe it when the claim is released"
// would mean "the arbiter chooses which time gets recorded": they could push the
// anchor to "now" AFTER the record of silence, and the chain would be left saying
// that silence was recorded before the dispute was claimed. The order of events —
// the only thing this whole record exists for — would fall apart.
//
// ⚠️ Time here is taken ONLY through vm.getBlockTimestamp() and never through
// block.timestamp, and that is not a matter of taste. The project is built with
// via_ir, and solc treats TIMESTAMP as constant within a call — on a real chain
// that is true, under vm.warp it is not. A second
// `vm.warp(block.timestamp + 24 hours)` in one test body in fact jumped to THE
// SAME second as the first (measured: `VM::warp(86401)` twice in a row). The
// class of mistake is exactly the dangerous one: the test looks like "a day
// passed" while checking zero seconds — and it was noticed only because a red
// happened to come out of it. Tests where such a jump would weaken a check in
// silence are fixed blind by the same device.
//
// The setup is the same as in the ArbiterChatKey suite: the facet is deployed on
// its own, the arbiter is seated straight into storage (applyAsArbiter is locked
// behind isDaoActive, and the DAO is deliberately not started — the owner's
// decision of 1 August), and the dispute is played by MockDisputedAgreementNR. No
// real diamond is needed here: everything asserted below is the state of the
// facet's own namespaced storage.

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";
import {FactoryStorage} from "../src/FactoryFacet.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";

contract DisputeNoResponseTest is Test, ArbiterTwoFacetBench {
    /// Both handles point at ONE address — the proxy carrying both facets (see
    /// ArbiterTwoFacetBench). `facet` deliberately keeps its old name: every
    /// vm.store(address(facet), ...) below keeps hitting the very same storage.
    ArbiterRegistryFacet facet;
    ArbiterAccountabilityFacet accFacet;

    address arbiter;
    address otherArbiter;
    address agreement;

    /// The base of the ArbiterRegistryStorage namespace —
    /// keccak256("hexseal.arbiterregistry.storage") with the last byte zeroed
    /// (ERC-7201); the same thing as ArbiterRegistryStorage.POSITION.
    bytes32 constant ARB_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    /// The offset of the `disputeClaims` slot from the namespace base (the third field of Data).
    uint256 constant SLOT_DISPUTE_CLAIMS = 2;

    /// The offset of the `disputeClaimedAtBy` slot from the namespace base.
    ///
    /// ⚠️ The obvious route — `forge inspect ArbiterRegistryFacet storage-layout`
    /// — is useless here and says nothing: the facet has not one state variable,
    /// the whole of Data lives at a namespaced slot reached from assembly, and it
    /// simply does not appear in inspect's output. The number was obtained by
    /// measurement — by test_SlotOffsets_MatchLiveStorage below, which checks it
    /// against live storage.
    ///
    /// Counting it in one's head is even less possible: the number of the FIELD in
    /// struct Data (23) and the number of the SLOT (22) differ — `chiefArbiter`
    /// (address, 20 bytes) and `daoActiveManual` (bool, 1 byte) are packed into one
    /// slot, and everything after them shifted by one.
    uint256 constant SLOT_CLAIMED_AT_BY = 22;

    function setUp() public {
        (facet, accFacet) = _deployArbiterBench();
        arbiter = address(0xA1);
        otherArbiter = address(0xA2);
        _makeArbiter(arbiter);
        _makeArbiter(otherArbiter);
        agreement = address(new MockDisputedAgreementNR(address(0xC1), address(0xE1)));
    }

    // ============================================================
    //  THE ANCHOR: THE MOMENT THE DISPUTE WAS CLAIMED
    // ============================================================

    function test_ClaimDispute_RecordsClaimMoment() public {
        _claimBy(arbiter, agreement);
        assertEq(
            accFacet.getDisputeClaimedAt(agreement),
            vm.getBlockTimestamp(),
            "the time of claiming must land in storage"
        );
    }

    /// Before a claim there is no time. A zero here is not "the field is broken"
    /// but a working sign of "the dispute was never claimed": the refusal of
    /// disputes claimed before the cut rests on it too (ClaimTimeUnknown below).
    function test_GetDisputeClaimedAt_ZeroBeforeClaim() public view {
        assertEq(
            accFacet.getDisputeClaimedAt(agreement),
            0,
            "an unclaimed dispute cannot have a moment of claiming"
        );
    }

    /// Re-claiming by the same arbiter moves the anchor FORWARD, to the moment of
    /// the latest claim. The owner's decision of 14.08.2026, overriding an earlier
    /// "once and for all": the floor must measure the time while the dispute stood
    /// WITH THIS ARBITER, that is while the party had somebody to present to.
    ///
    /// Moving it forward is of no benefit to the arbiter — it only postpones their
    /// own record; see the next test, which shows that this very shift is what
    /// closes the hole.
    function test_ReclaimBySameArbiter_AnchorMovesForward() public {
        _claimBy(arbiter, agreement);
        uint256 firstClaim = accFacet.getDisputeClaimedAt(agreement);

        vm.prank(arbiter);
        facet.releaseDisputeClaim(agreement);

        vm.warp(vm.getBlockTimestamp() + 25 hours);
        _claimBy(arbiter, agreement);

        assertEq(
            accFacet.getDisputeClaimedAt(agreement),
            firstClaim + 25 hours,
            "a re-claim must move the anchor to the moment of the latest claim"
        );
    }

    /// The hole the anchor is rewritten on every claim to close.
    ///
    /// A bribed arbiter claims the dispute, releases it a minute later and comes
    /// back two days on. Formally they were "the claimer" two days ago — but for
    /// almost all that time the dispute stood unowned, the judge's key was unknown,
    /// and the party had NOBODY to present to. With a "first claim forever" anchor
    /// they would have recorded silence the same second they came back. Now the
    /// floor starts again for them.
    function test_ReclaimAfterLongGap_FloorStartsOver() public {
        _claimBy(arbiter, agreement);

        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        vm.prank(arbiter);
        facet.releaseDisputeClaim(agreement);

        vm.warp(vm.getBlockTimestamp() + 2 days);
        _claimBy(arbiter, agreement);

        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.NoResponseTooEarly.selector);
        facet.recordNoResponse(agreement);
    }

    /// While there is no claimer the getter must stay silent: the dispute is
    /// unowned, and there is nobody to show "claimed at such a time" to and nobody
    /// it is about.
    function test_Release_ClearsVisibleAnchor() public {
        _claimBy(arbiter, agreement);
        vm.prank(arbiter);
        facet.releaseDisputeClaim(agreement);
        assertEq(
            accFacet.getDisputeClaimedAt(agreement),
            0,
            "the claim was released, so the getter must stay silent: the dispute is unowned"
        );
    }

    /// The second road out of a claim is a callback from the Agreement itself (a
    /// timeout, the execution of a verdict). It behaves the same way, and not
    /// because cleanup was written here but because there is no cleanup at all (see
    /// the invariant below).
    function test_ClearDisputeClaim_ClearsVisibleAnchor() public {
        _claimBy(arbiter, agreement);
        vm.prank(agreement); // clearDisputeClaim is called only by the Agreement itself
        facet.clearDisputeClaim(agreement);
        assertEq(
            accFacet.getDisputeClaimedAt(agreement),
            0,
            "the claim was released by a callback, so the getter must stay silent"
        );
    }

    /// A new arbiter has an anchor of their own, from the moment THEY claimed. They
    /// inherit nobody else's in any form: otherwise the floor would already be
    /// passed and they would record silence the same second they claimed.
    function test_OtherArbiter_GetsOwnAnchor() public {
        _claimBy(arbiter, agreement);
        uint256 firstClaim = accFacet.getDisputeClaimedAt(agreement);

        vm.prank(arbiter);
        facet.releaseDisputeClaim(agreement);

        vm.warp(vm.getBlockTimestamp() + 25 hours);
        _claimBy(otherArbiter, agreement);

        assertEq(
            accFacet.getDisputeClaimedAt(agreement),
            firstClaim + 25 hours,
            "a new arbiter must get THEIR OWN anchor, not somebody else's"
        );

        vm.prank(otherArbiter);
        vm.expectRevert(ArbiterRegistryFacet.NoResponseTooEarly.selector);
        facet.recordNoResponse(agreement);
    }

    // ============================================================
    //  AN INVARIANT INSTEAD OF A LIST OF PLACES
    // ============================================================

    /// "The claim was released ⇒ nothing went stale" used to rest on two tests
    /// named one by one, one for each place a claim is released. A list rots — the
    /// facet itself already names a candidate for a THIRD such place
    /// (`abandonClaim`), and its author is under no obligation to know about this
    /// file.
    ///
    /// Here the lock stands on the property rather than on the list: the claim is
    /// released straight in storage — that is, by a road that does NOT yet exist in
    /// the code — and both getters must still return zero. The property is held by
    /// the shape of the storage (both fields are keyed by arbiter, and the getters
    /// go through disputeClaims) rather than by cleanup in each place: any future
    /// place of release inherits it by itself.
    function test_NoClaimer_EverythingReadsZero_ByShapeNotByCleanup() public {
        _claimBy(arbiter, agreement);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(arbiter);
        facet.recordNoResponse(agreement);

        // Both values are visible — otherwise the measurement below would pass over
        // an empty space.
        assertGt(accFacet.getDisputeClaimedAt(agreement), 0, "the anchor must be visible before release");
        assertGt(accFacet.getNoResponseAt(agreement), 0, "the record must be visible before release");

        // Releasing the claim by ANY road, including one not yet written.
        bytes32 claimSlot = keccak256(abi.encode(agreement, uint256(ARB_BASE) + SLOT_DISPUTE_CLAIMS));
        assertEq(
            address(uint160(uint256(vm.load(address(facet), claimSlot)))),
            arbiter,
            "the disputeClaims offset in struct Data has drifted"
        );
        vm.store(address(facet), claimSlot, bytes32(0));
        assertEq(facet.getDisputeClaimer(agreement), address(0), "the claim must be released");

        assertEq(accFacet.getDisputeClaimedAt(agreement), 0,
            "there is no claimer, so the anchor must stay silent whichever road released the claim");
        assertEq(accFacet.getNoResponseAt(agreement), 0,
            "there is no claimer, so the record must stay silent whichever road released the claim");
    }

    /// The lock on the two numbers above. Both offsets were obtained by measurement
    /// rather than from `forge inspect` (which knows nothing about namespaced
    /// storage) and not by counting in one's head (the field number and the slot
    /// number differ because chiefArbiter and daoActiveManual are packed together).
    /// Obtained by measurement, they are guarded by measurement: splicing a field
    /// into the middle of Data shifts the slots, and that has to fail here, with a
    /// comprehensible reason, rather than quietly turn the neighbouring tests into
    /// checks of an empty space.
    function test_SlotOffsets_MatchLiveStorage() public {
        _claimBy(arbiter, agreement);

        bytes32 claimSlot = keccak256(abi.encode(agreement, uint256(ARB_BASE) + SLOT_DISPUTE_CLAIMS));
        assertEq(
            address(uint160(uint256(vm.load(address(facet), claimSlot)))),
            arbiter,
            "SLOT_DISPUTE_CLAIMS no longer points at disputeClaims"
        );

        bytes32 anchorSlot = keccak256(abi.encode(
            arbiter, keccak256(abi.encode(agreement, uint256(ARB_BASE) + SLOT_CLAIMED_AT_BY))
        ));
        assertEq(
            uint256(vm.load(address(facet), anchorSlot)),
            vm.getBlockTimestamp(),
            "SLOT_CLAIMED_AT_BY no longer points at disputeClaimedAtBy"
        );
    }

    // ============================================================
    //  THE RECORD "ASKED, GOT NO ANSWER"
    // ============================================================

    function test_RecordNoResponse_RevertsBeforeFloor() public {
        _claimBy(arbiter, agreement);
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.NoResponseTooEarly.selector);
        facet.recordNoResponse(agreement);
    }

    function test_RecordNoResponse_PassesAtFloor() public {
        _claimBy(arbiter, agreement);
        vm.warp(vm.getBlockTimestamp() + 24 hours);

        vm.expectEmit(true, true, false, true, address(facet));
        emit ArbiterRegistryFacet.DisputeNoResponseRecorded(agreement, arbiter, vm.getBlockTimestamp());

        vm.prank(arbiter);
        facet.recordNoResponse(agreement);

        assertEq(
            accFacet.getNoResponseAt(agreement),
            vm.getBlockTimestamp(),
            "the floor is passed, so the record must land on chain with the block's second"
        );
    }

    function test_RecordNoResponse_OnlyOnce() public {
        _claimBy(arbiter, agreement);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.startPrank(arbiter);
        facet.recordNoResponse(agreement);
        vm.expectRevert(ArbiterRegistryFacet.NoResponseAlreadyRecorded.selector);
        facet.recordNoResponse(agreement);
        vm.stopPrank();
    }

    /// Being once-only is not washed away by releasing the dispute: an arbiter
    /// cannot erase their own record and put it down under another time. Here the
    /// anchor and the record diverge in their rules — the anchor is moved on a
    /// re-claim, the record is not — and this test guards exactly that divergence.
    function test_RecordNoResponse_ReclaimCannotRewriteRecord() public {
        _claimBy(arbiter, agreement);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(arbiter);
        facet.recordNoResponse(agreement);
        uint256 recordedAt = accFacet.getNoResponseAt(agreement);

        vm.prank(arbiter);
        facet.releaseDisputeClaim(agreement);
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        _claimBy(arbiter, agreement);

        assertEq(
            accFacet.getNoResponseAt(agreement),
            recordedAt,
            "a re-claim has no right to move the time of a record already made"
        );
        // A deliberate consequence of the "anchor on every claim" rule: in storage
        // the anchor is now LATER than the record of silence. This does not corrupt
        // the order of events — the order is read from the feed (DisputeClaimed /
        // DisputeReleased / DisputeNoResponseRecorded), and storage holds only the
        // last claim. It is asserted explicitly here so that the next reader does
        // not take it for a bug and "fix" it back to "once and for all".
        assertGt(
            accFacet.getDisputeClaimedAt(agreement),
            accFacet.getNoResponseAt(agreement),
            "the anchor must move to the latest claim, even if that is later than the record"
        );

        // The answer must be "already recorded" rather than "too early": after a
        // re-claim the anchor is fresh and the floor is formally not passed — but
        // promising the arbiter that it will work in a day would be a lie. So
        // once-only is checked before the floor; see recordNoResponse.
        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.NoResponseAlreadyRecorded.selector);
        facet.recordNoResponse(agreement);
    }

    /// An arbiter who never claimed the dispute at all. The lock is a weak one and
    /// is deliberately named as such: a foreign arbiter's anchor is zero, so without
    /// the NotClaimingArbiter check the call would not have gone through anyway but
    /// stumbled further on into ClaimTimeUnknown — the test would go red "with the
    /// wrong class of error", not because an unauthorised party recorded anything.
    /// The real scene is guarded by the next test.
    function test_RecordNoResponse_RevertsForNonClaimingArbiter() public {
        _claimBy(arbiter, agreement);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(otherArbiter);
        vm.expectRevert(ArbiterRegistryFacet.NotClaimingArbiter.selector);
        facet.recordNoResponse(agreement);
    }

    /// The ONLY scene the NotClaimingArbiter check exists for at all: a FORMER
    /// claimer with a LIVE anchor.
    ///
    /// The first arbiter claimed the dispute, waited a day, released it — and a
    /// second one claimed it. The first one's anchor stayed non-zero: the key is the
    /// pair (deal, arbiter), and it is deliberately not cleaned. So they pass every
    /// other check: the time of claiming is known, the floor is passed, they have no
    /// record of their own yet. Exactly one line keeps them out.
    ///
    /// ⚠️ And the loss of that line would be INVISIBLE where anybody would look for
    /// it: `getNoResponseAt` goes through the current claimer and would not show a
    /// former one's record at all. But the DisputeNoResponseRecorded event would go
    /// out into the feed — and the feed, not the getter, is what this whole piece of
    /// work was done for. Measured: without the check the call does not revert and
    /// the event is emitted.
    function test_FormerClaimer_WithLiveAnchor_CannotRecord() public {
        _claimBy(arbiter, agreement);
        vm.warp(vm.getBlockTimestamp() + 24 hours);

        vm.prank(arbiter);
        facet.releaseDisputeClaim(agreement);
        _claimBy(otherArbiter, agreement);

        // The former claimer's anchor is alive and old — every other gate is open to them.
        bytes32 anchorSlot = keccak256(abi.encode(
            arbiter, keccak256(abi.encode(agreement, uint256(ARB_BASE) + SLOT_CLAIMED_AT_BY))
        ));
        assertEq(
            uint256(vm.load(address(facet), anchorSlot)),
            vm.getBlockTimestamp() - 24 hours,
            "the scene did not assemble: the former claimer must still have a live anchor"
        );

        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.NotClaimingArbiter.selector);
        facet.recordNoResponse(agreement);
    }

    /// A dispute claimed BEFORE the cut: there is a claimer in storage but no time
    /// of claiming. The chain does not know when it happened and has nothing to
    /// measure the floor from, so it refuses, closed. The way out is cheap:
    /// releaseDisputeClaim and claim the dispute again.
    function test_RecordNoResponse_RevertsWhenClaimTimeUnknown() public {
        _claimBy(arbiter, agreement);
        _forceClaimedAtZero(agreement, arbiter);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.ClaimTimeUnknown.selector);
        facet.recordNoResponse(agreement);
    }

    /// A previous record of silence does not carry over to a new arbiter: they see a
    /// zero and make their own, with their own time.
    function test_Release_HidesRecordFromNextArbiter() public {
        _claimBy(arbiter, agreement);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.startPrank(arbiter);
        facet.recordNoResponse(agreement);
        facet.releaseDisputeClaim(agreement);
        vm.stopPrank();

        assertEq(
            accFacet.getNoResponseAt(agreement),
            0,
            "the claim was released, so a previous record of silence must not carry over to the new arbiter"
        );

        _claimBy(otherArbiter, agreement);
        assertEq(
            accFacet.getNoResponseAt(agreement),
            0,
            "a new arbiter must start from a clean sheet, not from somebody else's record"
        );

        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(otherArbiter);
        facet.recordNoResponse(agreement);
        assertEq(
            accFacet.getNoResponseAt(agreement),
            vm.getBlockTimestamp(),
            "a new arbiter must be able to make THEIR OWN record"
        );
    }

    /// The floor is declared on chain and only there: a client must ask for it here
    /// rather than keep a copy of its own.
    function test_NoResponseFloor_IsOnChainAndEqualsOneDay() public view {
        assertEq(
            facet.getNoResponseFloor(),
            24 hours,
            "the floor for a record of silence is a day from the claiming of the dispute"
        );
    }

    // ============================================================
    //  THROUGH A REAL FORWARDER (ERC-2771)
    // ============================================================
    //
    // Every test above calls facet.recordNoResponse directly under vm.prank — in
    // that environment trustedForwarder is unset, so _msgSender() returns
    // msg.sender, and swapping _msgSender() for msg.sender inside the function
    // would not change their green colour in the slightest. Exactly the same class
    // of bug already hit fundDispute: the paid arbiter call never fired once, and
    // direct tests did not catch it.
    //
    // The only road by which an arbiter really makes this record is the gasless one,
    // through the relayer. Were the function to read msg.sender, the call would run
    // into NotClaimingArbiter (the claimer is not the forwarder) and the record
    // would NEVER go through, while the arbiter would only see "the transaction did
    // not go through".

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    function test_RecordNoResponse_ThroughRealForwarder_CreditsHumanNotForwarder() public {
        uint256 arbiterPk = 0xCA11;
        address arb = vm.addr(arbiterPk);
        address relayer = address(0x9999); // a third address: not the arbiter, not the forwarder
        _makeArbiter(arb);
        _claimBy(arb, agreement);
        vm.warp(vm.getBlockTimestamp() + 24 hours);

        MinimalForwarder fwd = new MinimalForwarder();
        _setTrustedForwarder(address(fwd));

        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  arb,
            to:    address(facet),
            value: 0,
            gas:   500_000,
            nonce: fwd.getNonce(arb),
            data:  abi.encodeWithSelector(ArbiterRegistryFacet.recordNoResponse.selector, agreement)
        });

        vm.prank(relayer);
        (bool ok, bytes memory ret) = fwd.execute(req, _signFwd(fwd, arbiterPk, req));
        assertTrue(ok, string.concat("forwarded recordNoResponse failed: ", vm.toString(ret)));

        assertEq(
            accFacet.getNoResponseAt(agreement),
            vm.getBlockTimestamp(),
            "the record must land for THE SIGNER, not for the forwarder"
        );
    }

    // ============================================================
    //  HELPERS
    // ============================================================

    /// commit + roll + claim as one sequence in a helper rather than inline: the
    /// same device and the same reason as for _commitAndClaim in the ArbiterChatKey
    /// suite — repeating the same sequence inline twice in one test body under
    /// via_ir was observed as "the second vm.roll does not take".
    function _claimBy(address arb, address agr) internal {
        bytes32 salt = keccak256(abi.encodePacked(arb, agr, block.number, block.timestamp));
        bytes32 commitment = keccak256(abi.encodePacked(agr, arb, salt));
        vm.prank(arb);
        facet.commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arb);
        facet.claimDispute(agr, salt, bytes32(uint256(0x11)), bytes32(uint256(0x22)));
    }

    /// Seats an arbiter straight into the facet's storage — as in the ArbiterChatKey suite.
    function _makeArbiter(address who) internal {
        // The storage POSITION + the slot of the isArbiter mapping (the first field of Data).
        vm.store(address(facet), keccak256(abi.encode(who, uint256(ARB_BASE))), bytes32(uint256(1)));
        // The check is mandatory: with a wrong slot the seating silently fails to
        // take, every measurement below would fail on NotArbiter, and they would
        // read as "the time of claiming was checked".
        assertTrue(facet.isRegisteredArbiter(who), "failed to seat the arbiter");
    }

    /// Sets the time of claiming to zero, as on disputes claimed BEFORE the cut.
    /// Written straight into the slot: there is no production road to zero and there
    /// must not be one. disputeClaimedAtBy is a nested mapping, hence two keccaks:
    /// first the deal, then the arbiter.
    function _forceClaimedAtZero(address agr, address arb) internal {
        bytes32 outer = keccak256(abi.encode(agr, uint256(ARB_BASE) + SLOT_CLAIMED_AT_BY));
        bytes32 slot  = keccak256(abi.encode(arb, outer));
        // The offset is not taken on trust: with a wrong slot vm.store would quietly
        // write into another field, the anchor would stay non-zero, and the test
        // "old disputes are refused" would be checking something entirely different
        // from what its name says.
        assertGt(uint256(vm.load(address(facet), slot)), 0,
            "the disputeClaimedAtBy offset in struct Data has drifted");
        vm.store(address(facet), slot, bytes32(0));
        assertEq(accFacet.getDisputeClaimedAt(agr), 0, "the anchor must be zeroed");
    }

    /// The offset of trustedForwarder inside FactoryStorage.Layout — 3 slots from
    /// the base (usdc(0), feeRecipient(1), regionFee(2, a mapping — a slot of its
    /// own), trustedForwarder(3)). The same offset that is asserted in the
    /// ArbiterChatKey suite and in BoardsFixture.
    function _setTrustedForwarder(address forwarder) internal {
        bytes32 slot = bytes32(uint256(FactoryStorage.FACTORY_STORAGE_POSITION) + 3);
        vm.store(address(facet), slot, bytes32(uint256(uint160(forwarder))));
        assertEq(
            address(uint160(uint256(vm.load(address(facet), slot)))),
            forwarder,
            "the trustedForwarder offset in FactoryStorage.Layout has drifted"
        );
    }

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
}

/// A minimal Agreement stub — exactly the subset of the interface that
/// claimDispute()/releaseDisputeClaim() read with staticcalls
/// (status/disputedAt/DISPUTE_WINDOW/client/executor) and call (setArbiter).
/// It lives in status DISPUTED(4) with the dispute window open from the moment it
/// is deployed. A copy of MockDisputedAgreement from the ArbiterChatKey suite —
/// under a name of its own, because forge deploys both files in one project.
contract MockDisputedAgreementNR {
    uint8 public constant status = 4; // Agreement.Status.DISPUTED
    uint256 public disputedAt;
    /// 4 days, as in the real Agreement.sol (DISPUTE_WINDOW). A mock that lies about
    /// the window is not harmless here: the tests below move time by days, and an
    /// understated window would close re-claiming for them earlier than it would
    /// close it for a real dispute.
    uint256 public constant DISPUTE_WINDOW = 4 days;
    address public client;
    address public executor;
    address public arbiter;

    constructor(address _client, address _executor) {
        client = _client;
        executor = _executor;
        disputedAt = block.timestamp;
    }

    function setArbiter(address newArbiter) external {
        arbiter = newArbiter;
    }
}
