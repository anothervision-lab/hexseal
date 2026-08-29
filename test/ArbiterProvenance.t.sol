// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Seating provenance: the chain must remember WHO seated an arbiter.
//
// Until 15 August 2026 `ArbiterAdded(arbiter)` said neither who pressed the
// button nor by what road the person took the seat. That made it impossible
// either to limit the chief or to show a reader honestly that a hand-seated
// arbiter is backed by no bond and no XP gate.
//
// The setup is light: the facet is deployed on its own, no real diamond is
// needed. The diamond's owner on this bench is the test contract itself
// (OwnershipLib reads the owner slot, and `new ArbiterRegistryFacet()` leaves it
// at zero), so the owner is seated by writing straight into the slot.

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";

contract ArbiterProvenanceTest is Test, ArbiterTwoFacetBench {
    /// Both handles point at ONE address — the proxy carrying both facets (see
    /// ArbiterTwoFacetBench). `facet` deliberately keeps its old name: every
    /// vm.store(address(facet), ...) below keeps hitting the very same storage.
    ArbiterRegistryFacet facet;
    ArbiterAccountabilityFacet accFacet;

    address owner;
    address chief;
    address seat1;
    address seat2;

    /// The diamond's owner slot — DiamondStorage.POSITION + 4
    /// (OwnershipLib.contractOwner() → DiamondStorage.Layout.contractOwner, the
    /// fifth field of struct Layout: mapping/mapping/array/mapping take slots
    /// +0..+3, contractOwner sits at +4).
    ///
    /// An earlier candidate value (0xc8fcad8d…) did not substitute the owner at
    /// all: measured — with it, `setChiefArbiter` in setUp failed with `NotOwner()`
    /// before the first test even ran. DIAMOND_STORAGE_POSITION was recomputed
    /// literally from the erc7201 formula in the comment above the constant in
    /// `src/DiamondProxy.sol` (`cast keccak` / `cast abi-encode`) and agrees with
    /// the source byte for byte; the first attempt, `POSITION + 0`, also gave
    /// `NotOwner()` — a field's offset inside struct Layout is visible only from
    /// the struct itself, never from the erc7201 formula. `POSITION + 4` was
    /// verified by running the test.
    bytes32 constant OWNER_SLOT = 0x178642b411f9f4783b21ef338f3e96db6c1272d763f0b7500ec93464dafb8604;

    function setUp() public {
        (facet, accFacet) = _deployArbiterBench();
        owner = address(0x0);
        chief = address(0xC4);
        seat1 = address(0xA1);
        seat2 = address(0xA2);

        owner = address(this);
        vm.store(address(facet), OWNER_SLOT, bytes32(uint256(uint160(owner))));
        facet.setChiefArbiter(chief);
    }

    function test_OwnerSeatIsAttributedToOwner() public {
        vm.expectEmit(true, true, false, true, address(facet));
        emit ArbiterRegistryFacet.ArbiterSeated(seat1, owner, false);

        facet.addArbiter(seat1);

        assertEq(accFacet.getSeatedBy(seat1), owner, "the chain must remember that the owner did the seating");
        assertEq(accFacet.getSeatedCountBy(owner), 1, "the owner's seating counter must go up");
    }

    function test_ChiefSeatIsAttributedToChief() public {
        vm.prank(chief);
        facet.addArbiter(seat1);

        assertEq(accFacet.getSeatedBy(seat1), chief, "the chief did the seating, and that is what is recorded");
        assertEq(accFacet.getSeatedCountBy(chief), 1, "the chief's counter");
        assertEq(accFacet.getSeatedCountBy(owner), 0, "somebody else's seating is not credited to the owner");
    }

    /// removeArbiter is deliberately not used in these tests: it is removed
    /// entirely by later work, and a test resting on it would become dead weight.
    /// Clearing the seat on the way out is checked through resignAsArbiter()
    /// instead — it outlives that change and calls the same _clearSeat helper. On
    /// a clean bench arbiterBond[seat1] == 0 (addArbiter takes no bond), so
    /// resignAsArbiter touches no USDC at all — no token mock is needed.
    function test_ResignDecrementsSeaterCount() public {
        vm.prank(chief);
        facet.addArbiter(seat1);
        assertEq(accFacet.getSeatedCountBy(chief), 1);

        vm.prank(seat1);
        facet.resignAsArbiter();

        assertEq(accFacet.getSeatedCountBy(chief), 0, "the removed arbiter no longer sits, so the seater's counter falls");
        assertEq(accFacet.getSeatedBy(seat1), address(0), "the provenance of the removed arbiter is cleared");
    }

    /// The seating counter accumulates and does not mix up who did the seating.
    ///
    /// ⚠️ Two are seated by the OWNER rather than by the chief: the chief's bloc
    /// ceiling came down to one, and the earlier version — two seatings by the
    /// chief in a row — now reverts. The property checked here is about the
    /// counter, not about the ceiling, so the actor the ceiling does not apply to
    /// is used; the chief stays in the scene with one seating, otherwise there
    /// would be nobody to check "kept separate" against.
    function test_TwoSeatsCountSeparately() public {
        facet.addArbiter(seat1);
        facet.addArbiter(seat2);
        assertEq(accFacet.getSeatedCountBy(owner), 2, "two seatings, counter of two");

        vm.prank(chief);
        facet.addArbiter(address(0xA3));

        assertEq(accFacet.getSeatedCountBy(owner), 2, "somebody else's seating does not move the owner's counter");
        assertEq(accFacet.getSeatedCountBy(chief), 1, "and one's own lands on the chief's counter");
    }

    // ============================================================
    //  THE CHIEF'S BLOC CEILING
    //
    //  The property required is not a number but a fact: the chief NEVER decides
    //  an appeal. Not "does not hold a quorum" — that is weaker and gives
    //  nothing: resolveAppeal settles the matter by a SIMPLE MAJORITY of the
    //  votes cast as soon as APPEAL_MIN_VOTES of them have arrived, and at a
    //  turnout of exactly the quorum, TWO out of three decide.
    //  So the ceiling has to hold at two rather than three: bloc ≤ 1.
    //
    //  A rate ceiling ("no more than one a week") does not give this property:
    //  over a year that adds up to fifty-two.
    // ============================================================

    function test_ChiefSeatsOneFreely() public {
        vm.prank(chief);
        facet.addArbiter(seat1);
        assertEq(facet.getChiefBloc(), 1, "the chief seats one on their own");
    }

    /// The second is already a majority at quorum turnout, and the chain refuses it.
    function test_ChiefCannotDecideAppeal() public {
        vm.startPrank(chief);
        facet.addArbiter(seat1);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterRegistryFacet.ChiefBlocWouldDecideAppeal.selector, 2, 2)
        );
        facet.addArbiter(seat2);
        vm.stopPrank();
    }

    /// The chief may be an arbiter themselves — setChiefArbiter does not forbid it.
    /// Then they plus ONE appointee are already two votes, i.e. the deciding
    /// majority at quorum turnout. So the chief must count inside the bloc, and
    /// their very first seating has to be refused.
    function test_ChiefCountsHimselfWhenHeIsArbiter() public {
        facet.addArbiter(chief);            // the owner seats the chief as an arbiter
        assertEq(facet.getChiefBloc(), 1, "a chief who is an arbiter is already one unit of the bloc");

        vm.prank(chief);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterRegistryFacet.ChiefBlocWouldDecideAppeal.selector, 2, 2)
        );
        facet.addArbiter(seat1);
    }

    /// The same arbiter-chief, but having seated THEMSELVES. The bloc is a SET of
    /// voters, not the sum of two counters: `seatedCountBy[chief]` has already
    /// counted them, and a blind "plus themselves" would call one person two
    /// votes.
    ///
    /// What disappears from the behaviour if the fix is removed: `getChiefBloc()`
    /// starts answering 2 on one real vote. Two is the threshold beyond which an
    /// appeal counts as decided; the reader of that getter (a person today, a
    /// screen tomorrow) makes a decision on that number, and it must not be off
    /// by one.
    ///
    /// The refusal of the second seating is NOT proof of the fix: it is identical
    /// in both versions (2 against 3, both >= 2). So the number itself is checked,
    /// and the threshold on a separate line below, so that "one" does not turn out
    /// to coincide with "the bloc is empty".
    function test_ChiefWhoSeatedHimselfIsCountedOnce() public {
        vm.prank(chief);
        facet.addArbiter(chief);            // the chief seats THEMSELVES

        assertTrue(facet.isRegisteredArbiter(chief), "setup: the chief took a seat");
        assertEq(accFacet.getSeatedBy(chief), chief, "setup: they seated themselves");
        assertEq(accFacet.getSeatedCountBy(chief), 1, "setup: the seating counter counted them");

        assertEq(
            facet.getChiefBloc(), 1,
            "one person, one vote: the terms overlapped rather than adding up"
        );
    }

    /// The ceiling does not apply to the owner: the owner is the one who decides.
    function test_OwnerIsNotCapped() public {
        facet.addArbiter(seat1);
        facet.addArbiter(seat2);
        facet.addArbiter(address(0xA3));
        facet.addArbiter(address(0xA4));
        assertEq(accFacet.getSeatedCountBy(owner), 4, "the owner seats as many as needed");
    }

    /// One left, so a place came free. Otherwise a chief who erred once is locked
    /// out forever.
    ///
    /// ⚠️ Leaving the corps here goes through `resignAsArbiter` and NOT through
    /// `removeArbiter`: the latter is removed entirely. `resignAsArbiter` calls
    /// the same seat-clearing helper.
    function test_ResignFreesChiefSlot() public {
        vm.prank(chief);
        facet.addArbiter(seat1);

        vm.prank(seat1);
        facet.resignAsArbiter();
        assertEq(facet.getChiefBloc(), 0, "the place came free");

        vm.prank(chief);
        facet.addArbiter(seat2);
        assertEq(facet.getChiefBloc(), 1, "and was taken again");
    }

    /// The fifth check, which was missing: the ceiling has to be STRICTLY BELOW
    /// the quorum, not equal to it. That is the whole difference between "does not
    /// decide an appeal" and "does not hold a quorum", and without a check of its
    /// own it is easy to lose again on the next edit — which is exactly how it
    /// came about.
    ///
    /// The number 2 is read out of the error's payload: a private constant cannot
    /// be read from outside, but the revert names it. The other end of the tie is
    /// behavioural and lives in the Diamond suite: there, two votes out of three
    /// really do overturn a verdict.
    function test_ChiefCapIsStrictlyBelowQuorum() public {
        vm.prank(chief);
        facet.addArbiter(seat1);

        vm.prank(chief);
        try facet.addArbiter(seat2) {
            revert("the chief's second seating must be refused");
        } catch (bytes memory err) {
            assertEq(bytes4(err), ArbiterRegistryFacet.ChiefBlocWouldDecideAppeal.selector);
            (uint256 bloc, uint256 deciding) = abi.decode(_stripSelector(err), (uint256, uint256));
            assertEq(bloc, 2, "the bloc after the seating is two");
            assertEq(deciding, 2, "the deciding majority at a quorum of 3 is two, not three");
        }
    }

    /// Cuts off the error's four-byte selector, leaving its fields.
    ///
    /// ⚠️ The length is checked EXPLICITLY. Without that check, `err.length - 4`
    /// on a short return is Panic(0x11), an arithmetic underflow of uint256, from
    /// which a reader learns precisely nothing: neither that the revert was the
    /// wrong one, nor what it actually was. And a short return here is no
    /// invention: an empty string arrives from a `require` with no message, from
    /// out-of-gas, and from a call to an address with no code — that is, in
    /// exactly the cases where a mistake is easiest and understanding it matters
    /// most.
    function _stripSelector(bytes memory err) internal pure returns (bytes memory out) {
        require(
            err.length >= 4,
            "_stripSelector: the return is shorter than a selector, so the revert was the wrong one"
        );
        out = new bytes(err.length - 4);
        for (uint256 i = 4; i < err.length; i++) out[i - 4] = err[i];
    }
}
