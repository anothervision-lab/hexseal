// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The SECOND condition of the handover (20 September 2026).
//
// `activateDAO()` used to ask two things: a successor who confirmed his own
// appointment, and `uniqueActiveUsers >= DAO_THRESHOLD`. The second of those
// counts every address that EVER earned XP and never falls — deliberately, so
// that the promise "governance moves when there are this many of you" cannot
// un-happen. The cost of that ratchet is that it cannot tell a living protocol
// from a dead one with a long history: ten thousand people could have passed
// through and left, and it would still read "ready".
//
// So a second condition was added beside it — a handover the system itself can
// say it is ready for, measured on what is happening rather than on anything
// declared. Its first draft asked for VOLUME (twenty disputes closed cleanly,
// ever) and was replaced the same day by a measure of AUTONOMY, because the
// chains say volume is years away: the flagship on-chain escrow of this kind
// has 286 deals and four disputes in seven and a third years. The three terms
// now are
//
//   • deals open across the protocol RIGHT NOW (`RegistryStorage.liveDeals`);
//   • disputes finalized on an arbiter's verdict IN A ROW with no governance
//     hand in any of them (`ArbiterRegistryStorage.cleanDisputeStreak`);
//   • DIFFERENT arbiters who have each closed one cleanly
//     (`ArbiterRegistryStorage.distinctCleanArbiters`).
//
// WHAT THIS SUITE IS FOR, and it is not "the rule works". It is four separate
// claims, each of which has a mutation that kills it and nothing else:
//
//   1. Each term ALONE does not open the door        — kills "a term was
//      quietly dropped" and "the three were OR'd".
//   2. All three together DO open it                 — kills a condition that
//      refuses for ever, which is the failure that looks like safety.
//   3. The first condition is untouched              — kills "the new door is
//      a way around the old one".
//   4. The reading answers from the SAME rule        — kills the mirror. This
//      repository carries `DAO_THRESHOLD` in three files and one of them has
//      been wrong since July; the whole point of `HandoverLib` is that there
//      is no second place to edit.
//
// ⚠️ WHAT THIS SUITE DOES NOT MEASURE, written here so nobody reads the green
// and thinks it does. Every scene below WRITES THE COUNTERS DIRECTLY. Nothing
// here drives a dispute through claim, verdict, freeze, unfreeze and
// finalization, so nothing here can tell a counter that is moved correctly
// from one that is never moved at all. That half lives in
// `test/HandoverCleanStreak.t.sol`, on a bench with a live Agreement clone,
// and it is the half that measures the sentence the whole condition is for:
// a dispute a hand reached into does not count as clean.
//
// ⚠️ WHY THE SLOTS ARE SWEPT FOR AND NOT WRITTEN DOWN. The counters live at
// the end of long append-only structs — `ArbiterRegistryStorage.Data` is past
// sixty fields. A hand-counted offset is the exact shape of the bug this
// repository already paid for on the live chain, and worse here: a test that
// writes the WRONG slot still passes, because the door then reads a zero it
// was always going to read. `_sweepFor` therefore finds each slot by writing a
// sentinel and asking the contract's own reader what it now sees, and FAILS
// if it cannot find it. A future append moves the field and the sweep follows
// it; a rename or a removal makes the sweep fail loudly instead of silently
// testing nothing.

import "forge-std/Test.sol";
import {ArbiterRegistryFacet, ArbiterRegistryStorage, HandoverLib} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";

contract HandoverLivenessTest is Test, ArbiterTwoFacetBench {
    ArbiterRegistryFacet       reg;
    ArbiterAccountabilityFacet acc;
    ArbiterVaultFacet          vault;

    address owner;
    address constant SUCCESSOR = address(0xDA0);

    /// The diamond's owner slot — DiamondStorage.POSITION + 4, the same
    /// constant the ArbiterSeatingHandover suite uses.
    bytes32 constant OWNER_SLOT = 0x178642b411f9f4783b21ef338f3e96db6c1272d763f0b7500ec93464dafb8604;

    /// ReputationStorage.POSITION — see src/facets/ReputationFacet.sol.
    bytes32 constant REP_BASE = 0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400;

    /// uniqueActiveUsers — slot 8 in ReputationStorage.Data. Not swept for:
    /// it is load-bearing in three other suites at this same number, and if it
    /// ever moves they will say so first.
    uint256 constant SLOT_UNIQUE_ACTIVE_USERS = 8;

    /// RegistryStorage.REGISTRY_STORAGE_POSITION — see src/RegistryFacet.sol.
    bytes32 constant REG_BASE = 0xc2046377b613f781ce75bf5776eb70f650372f5239ada8a3238d951cdca15e00;

    /// ArbiterRegistryStorage.POSITION — see src/facets/ArbiterRegistryFacet.sol.
    bytes32 constant ARB_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    /// How far past each namespace base the sweep looks. Generous on purpose:
    /// the cost of a slot too few is a suite that silently tests nothing.
    uint256 constant SWEEP_DEPTH = 128;

    /// Which term of the reading the sweep is looking for.
    uint8 constant TERM_LIVE_DEALS = 0;
    uint8 constant TERM_CLEAN_STREAK = 1;
    uint8 constant TERM_DISTINCT_ARBITERS = 2;

    bytes32 liveDealsSlot;
    bytes32 cleanStreakSlot;
    bytes32 distinctArbitersSlot;

    function setUp() public {
        (reg, acc, vault) = _deployArbiterBench();
        owner = address(this);
        vm.store(address(reg), OWNER_SLOT, bytes32(uint256(uint160(owner))));

        liveDealsSlot        = _sweepFor(REG_BASE, TERM_LIVE_DEALS);
        cleanStreakSlot      = _sweepFor(ARB_BASE, TERM_CLEAN_STREAK);
        distinctArbitersSlot = _sweepFor(ARB_BASE, TERM_DISTINCT_ARBITERS);
    }

    // ---------- finding the counters without counting fields ----------

    function _termOf(HandoverLib.Readiness memory r, uint8 term) internal pure returns (uint256) {
        if (term == TERM_LIVE_DEALS) return r.liveDeals;
        if (term == TERM_CLEAN_STREAK) return r.cleanStreak;
        return r.distinctCleanArbiters;
    }

    /// Writes a sentinel into each slot of a namespace in turn and asks the
    /// contract's own reader which one it came back through. Restores every
    /// slot it touched, so the sweep leaves the bench exactly as it found it.
    ///
    /// The sentinel is deliberately far from any floor (all three are under a
    /// hundred): a slot that happens to hold a plausible small number cannot
    /// be mistaken for the one we are looking for.
    function _sweepFor(bytes32 base, uint8 term) internal returns (bytes32 slot) {
        uint256 sentinel = 0xBEEF01;
        for (uint256 i = 0; i < SWEEP_DEPTH; i++) {
            bytes32 candidate = bytes32(uint256(base) + i);
            bytes32 before    = vm.load(address(acc), candidate);
            // A slot that already holds the sentinel would answer yes without
            // being written, so anything non-zero is skipped: every counter is
            // zero on a fresh bench.
            if (before != bytes32(0)) continue;
            vm.store(address(acc), candidate, bytes32(sentinel));
            uint256 seen = _termOf(acc.getHandoverReadiness(), term);
            vm.store(address(acc), candidate, before);
            if (seen == sentinel) return candidate;
        }
        revert(string.concat("sweep: term ", vm.toString(uint256(term)), " not found in the namespace"));
    }

    function _setLiveDeals(uint256 n) internal {
        vm.store(address(acc), liveDealsSlot, bytes32(n));
    }

    function _setCleanStreak(uint256 n) internal {
        vm.store(address(acc), cleanStreakSlot, bytes32(n));
    }

    function _setDistinctArbiters(uint256 n) internal {
        vm.store(address(acc), distinctArbitersSlot, bytes32(n));
    }

    /// All three terms at once — the shorthand every scene below leans on.
    function _setTerms(uint256 deals, uint256 streak, uint256 arbiters) internal {
        _setLiveDeals(deals);
        _setCleanStreak(streak);
        _setDistinctArbiters(arbiters);
    }

    function _setUniqueActiveUsers(uint256 n) internal {
        vm.store(address(reg), bytes32(uint256(REP_BASE) + SLOT_UNIQUE_ACTIVE_USERS), bytes32(n));
    }

    function _uniqueActiveUsers() internal view returns (uint256) {
        return uint256(vm.load(address(reg), bytes32(uint256(REP_BASE) + SLOT_UNIQUE_ACTIVE_USERS)));
    }

    /// Everything the FIRST condition needs, and nothing the second needs.
    function _satisfyTheFirstCondition() internal {
        _setUniqueActiveUsers(reg.getDaoThreshold());
        reg.setDAOAddress(SUCCESSOR);
        vm.prank(SUCCESSOR);
        reg.acceptDAOAddress();
    }

    /// ⚠️ THE FLOORS ARE READ FROM THE READING, NOT WRITTEN DOWN HERE. A suite
    /// that carried its own 15/8/3 would keep passing after somebody changed
    /// the contract's — it would be measuring its own copy. The one literal
    /// this file does pin is in `test_TheFloorsAreTheNumbersTheOwnerDECIDED`,
    /// deliberately and once.
    function _floors() internal view returns (uint256 deals, uint256 streak, uint256 arbiters) {
        HandoverLib.Readiness memory r = acc.getHandoverReadiness();
        deals    = r.liveDealsFloor;
        streak   = r.cleanStreakFloor;
        arbiters = r.distinctCleanArbitersFloor;
    }

    // ---------- the sweep itself has to be trustworthy ----------

    /// If these handles ever point at one slot, or at a slot that is not the
    /// one named, every scene below becomes decoration. The sweep already
    /// fails loudly when it finds nothing; this says the three it found are
    /// three different fields.
    function test_TheSweepFoundThreeDistinctCounters() public view {
        assertTrue(liveDealsSlot != bytes32(0), "liveDeals slot not found");
        assertTrue(cleanStreakSlot != bytes32(0), "cleanStreak slot not found");
        assertTrue(distinctArbitersSlot != bytes32(0), "distinctCleanArbiters slot not found");
        assertTrue(liveDealsSlot != cleanStreakSlot, "live deals and the streak share a handle");
        assertTrue(cleanStreakSlot != distinctArbitersSlot, "the streak and the arbiter count share a handle");
        assertTrue(liveDealsSlot != distinctArbitersSlot, "live deals and the arbiter count share a handle");
    }

    /// The sweep writes and restores; a bench left dirty would make the
    /// "no term is met" scenes pass for the wrong reason.
    function test_TheSweepLeavesEveryCounterAtZero() public view {
        HandoverLib.Readiness memory r = acc.getHandoverReadiness();
        assertEq(r.liveDeals, 0, "the sweep left live deals behind");
        assertEq(r.cleanStreak, 0, "the sweep left a streak behind");
        assertEq(r.distinctCleanArbiters, 0, "the sweep left arbiters behind");
    }

    // ---------- 1. each term alone does not open the door ----------

    function test_NoTermMetTheDoorRefuses() public {
        _satisfyTheFirstCondition();
        vm.expectRevert(ArbiterRegistryFacet.HandoverNotLive.selector);
        reg.activateDAO();
    }

    /// A busy market nobody has ever had to arbitrate is not a protocol that
    /// can be handed over: the thing being handed over IS the judging.
    function test_AShortStreakAloneKeepsTheDoorShut() public {
        _satisfyTheFirstCondition();
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals, streak - 1, arbiters);
        vm.expectRevert(ArbiterRegistryFacet.HandoverNotLive.selector);
        reg.activateDAO();
    }

    /// A well-judged corps with nothing left to judge is the other half of the
    /// same hole, and it is the one the first condition cannot see at all.
    function test_ADeadMarketAloneKeepsTheDoorShut() public {
        _satisfyTheFirstCondition();
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals - 1, streak, arbiters);
        vm.expectRevert(ArbiterRegistryFacet.HandoverNotLive.selector);
        reg.activateDAO();
    }

    /// THE TERM THE FIRST DRAFT DID NOT HAVE. A live market and a long clean
    /// run judged by two seats is a court that can be one man and his second
    /// address, and governance handed over on it goes to whoever holds them.
    function test_TooFewDifferentArbitersKeepsTheDoorShut() public {
        _satisfyTheFirstCondition();
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals, streak, arbiters - 1);
        vm.expectRevert(ArbiterRegistryFacet.HandoverNotLive.selector);
        reg.activateDAO();
    }

    /// One short on every side at once, to pin `>=` from the other direction
    /// than the scene below.
    function test_OneShortEverywhereStillRefuses() public {
        _satisfyTheFirstCondition();
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals - 1, streak - 1, arbiters - 1);
        vm.expectRevert(ArbiterRegistryFacet.HandoverNotLive.selector);
        reg.activateDAO();
    }

    // ---------- 2. all three together open it ----------

    /// The scene that keeps the condition from being a permanent refusal. A
    /// gate that never opens looks exactly like a gate that works.
    function test_AllThreeTermsMetTheDoorOpens() public {
        _satisfyTheFirstCondition();
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals, streak, arbiters);
        reg.activateDAO();
        assertTrue(reg.isDaoActive(), "every term met and governance did not come on");
    }

    /// Exactly ON the floors, not above them — `>=` on all three.
    function test_ExactlyOnTheFloorsIsEnough() public {
        _satisfyTheFirstCondition();
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals, streak, arbiters);
        HandoverLib.Readiness memory r = acc.getHandoverReadiness();
        assertTrue(r.met, "sitting exactly on the floors is not read as met");
        reg.activateDAO();
        assertTrue(reg.isDaoActive(), "sitting exactly on the floors did not open the door");
    }

    /// ⚠️ THE ONE PLACE THE NUMBERS ARE WRITTEN DOWN TWICE, and on purpose.
    /// Everything else in this file reads the floors out of the contract, so a
    /// floor silently dropped to zero would keep every other scene green — the
    /// mutation "open the bar" would have no lock at all. These three literals
    /// are the owner's decision of 20 September 2026 and nothing derives them.
    function test_TheFloorsAreTheNumbersTheOwnerDECIDED() public view {
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        assertEq(deals, 15, "the live-deal floor is not the number that was decided");
        assertEq(streak, 8, "the clean-streak floor is not the number that was decided");
        assertEq(arbiters, 3, "the distinct-arbiter floor is not the number that was decided");
    }

    /// A floor of zero is a term that is always met, which is a term that was
    /// deleted without the deletion showing in a diff. Said separately from
    /// the scene above because it is the failure, not the number.
    function test_NoFloorIsZero() public view {
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        assertGt(deals, 0, "the live-deal term is always met");
        assertGt(streak, 0, "the clean-streak term is always met");
        assertGt(arbiters, 0, "the distinct-arbiter term is always met");
    }

    // ---------- 3. the first condition is untouched ----------

    /// The new condition must not have become a way AROUND the old one. Below
    /// the people threshold the door still answers about people.
    function test_TheEarnedThresholdStillRefusesFirst() public {
        reg.setDAOAddress(SUCCESSOR);
        vm.prank(SUCCESSOR);
        reg.acceptDAOAddress();
        uint256 need = reg.getDaoThreshold();
        _setUniqueActiveUsers(need - 1);
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals, streak, arbiters);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterRegistryFacet.DaoThresholdNotReached.selector, need - 1, need)
        );
        reg.activateDAO();
    }

    /// And the successor still comes before everything.
    function test_TheSuccessorStillComesFirst() public {
        _setUniqueActiveUsers(reg.getDaoThreshold());
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals, streak, arbiters);
        vm.expectRevert(ArbiterRegistryFacet.DaoAddressNotSet.selector);
        reg.activateDAO();
    }

    /// The ratchet is still a ratchet: the people counter is the one term that
    /// must not fall, and nothing added here writes to it.
    function test_TheHistoricalCounterStillDoesNotRollBack() public {
        _satisfyTheFirstCondition();
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals, streak, arbiters);
        // Read straight out of the slot: ReputationFacet is not mounted on this
        // bench, and the point of the scene is the STORAGE, not a getter.
        uint256 before = _uniqueActiveUsers();
        reg.activateDAO();
        assertEq(_uniqueActiveUsers(), before, "the handover moved the historical counter");
        assertGe(_uniqueActiveUsers(), reg.getDaoThreshold(), "the ratchet fell below its floor");
    }

    // ---------- 4. the reading and the door are one rule ----------

    /// THE MIRROR SCENE. Across the whole neighbourhood of all three floors,
    /// the public reading's verdict and the door's behaviour must agree on
    /// every single point. A second copy of the rule — a different constant, a
    /// `>` for a `>=`, an `||` for an `&&` — shows up here as one disagreeing
    /// point and nowhere else.
    ///
    /// ⚠️ IT IS A GRID AND NOT A SAMPLE because `met()` (the door's short
    /// answer) and `readiness()` (the reading's long one) are now two written
    /// copies of the same three comparisons — the price paid for the room in
    /// the facet. This scene is the whole of what holds them together.
    function test_TheDoorAndTheReadingAnswerFromOneRule() public {
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        for (uint256 d = deals - 1; d <= deals + 1; d++) {
            for (uint256 c = streak - 1; c <= streak + 1; c++) {
                for (uint256 a = arbiters - 1; a <= arbiters + 1; a++) {
                    uint256 snap = vm.snapshotState();
                    _satisfyTheFirstCondition();
                    _setTerms(d, c, a);

                    bool said = acc.getHandoverReadiness().met;
                    (bool did, ) =
                        address(reg).call(abi.encodeWithSelector(ArbiterRegistryFacet.activateDAO.selector));

                    assertEq(
                        said,
                        did,
                        string.concat(
                            "the reading and the door disagree at liveDeals=", vm.toString(d),
                            " cleanStreak=", vm.toString(c),
                            " distinctArbiters=", vm.toString(a)
                        )
                    );
                    vm.revertToState(snap);
                }
            }
        }
    }

    /// The reading must also hand out the TERMS, not just a yes or no — that
    /// is the whole reason it returns a struct: a screen has to be able to say
    /// "three more disputes" instead of "no".
    function test_TheReadingNamesEveryTermAndItsFloor() public {
        (uint256 deals, uint256 streak, uint256 arbiters) = _floors();
        _setTerms(deals, streak - 3, arbiters);
        HandoverLib.Readiness memory r = acc.getHandoverReadiness();
        assertEq(r.liveDeals, deals, "live deals not reported");
        assertEq(r.cleanStreak, streak - 3, "the clean streak not reported");
        assertEq(r.distinctCleanArbiters, arbiters, "the arbiter count not reported");
        assertTrue(r.liveDealsMet, "a met term is not reported as met");
        assertTrue(r.distinctCleanArbitersMet, "a met term is not reported as met");
        assertFalse(r.cleanStreakMet, "the unmet term is reported as met");
        assertFalse(r.met, "one unmet term did not make the whole unmet");
        assertEq(r.cleanStreakFloor - r.cleanStreak, 3, "the reading cannot answer 'how many more'");
    }
}
