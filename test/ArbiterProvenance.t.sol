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
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

contract ArbiterProvenanceTest is Test, ArbiterTwoFacetBench {
    /// Both handles point at ONE address — the proxy carrying both facets (see
    /// ArbiterTwoFacetBench). `facet` deliberately keeps its old name: every
    /// vm.store(address(facet), ...) below keeps hitting the very same storage.
    ArbiterRegistryFacet facet;
    ArbiterVaultFacet facetVault;
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
        (facet, accFacet, facetVault) = _deployArbiterBench();
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

    /// ⚠️ THE CHIEF CANNOT SEAT ANYBODY SINCE 22 SEPTEMBER 2026, and this is
    /// the lock on that decision. `addArbiter` is `onlyOwner`, so his press is
    /// refused by the ownership check and never reaches a rule about blocs.
    ///
    /// The owner's argument: every other entrance measures something — the
    /// self-service one asks for five clean deals with counterparties that
    /// carried standing of their own — and this one measures nothing at all. It
    /// is a name and a press, which makes it the widest hole in the corps, and
    /// it was held by a man who had himself been appointed.
    function test_TheChiefCannotSeatAnybody() public {
        assertEq(facetVault.getChiefArbiter(), chief, "setup: there is no chief to refuse");

        vm.prank(chief);
        vm.expectRevert(ArbiterRegistryFacet.NotOwner.selector);
        facet.addArbiter(seat1);

        assertFalse(facetVault.isRegisteredArbiter(seat1), "the chief seated him anyway");
        assertEq(accFacet.getSeatedCountBy(chief), 0, "a seating was credited to the chief");
    }

    /// And the owner's press on the same address goes through, so the refusal
    /// above is about WHO pressed and not about the man or the bench.
    function test_TheSameSeatingFromTheOwnerGoesThrough() public {
        facet.addArbiter(seat1);
        assertTrue(facetVault.isRegisteredArbiter(seat1), "the owner could not seat him either");
        assertEq(accFacet.getSeatedBy(seat1), owner, "the owner's press was credited to somebody else");
    }

    /// Leaving the corps clears the provenance and the seater's counter.
    ///
    /// ⚠️ THE SEATER IS THE OWNER HERE and used to be the chief; the property
    /// is about `clearSeat`, which does not care which of them pressed, and the
    /// chief no longer has a press.
    function test_ResignDecrementsSeaterCount() public {
        facet.addArbiter(seat1);
        assertEq(accFacet.getSeatedCountBy(owner), 1);

        vm.prank(seat1);
        facet.resignAsArbiter();

        assertEq(accFacet.getSeatedCountBy(owner), 0, "the arbiter no longer sits, so the seater's counter falls");
        assertEq(accFacet.getSeatedBy(seat1), address(0), "the provenance of the departed arbiter is cleared");
    }

    /// The counter accumulates, and a seat nobody granted is credited to
    /// nobody. `applyAsArbiter` leaves `seatedBy` at zero, which is the chain's
    /// mark for "he walked in himself" — and the appeal panel reads that very
    /// field, so a self-seated man must not read as vouched-for.
    function test_TwoSeatsCountAndASelfSeatingCountsForNobody() public {
        facet.addArbiter(seat1);
        facet.addArbiter(seat2);
        assertEq(accFacet.getSeatedCountBy(owner), 2, "two seatings, counter of two");

        // The bench is the two arbiter facets and no reputation storage behind
        // them, so the self-service door is played by the mark it leaves rather
        // than by the press. What is asserted is that NOTHING credits a seat to
        // a person who did not grant one.
        assertEq(accFacet.getSeatedBy(address(0xA9)), address(0), "a stranger reads as vouched-for");
        assertEq(accFacet.getSeatedCountBy(chief), 0, "the chief is credited with a seat he cannot grant");
    }

    // ============================================================
    //  THE CHIEF'S BLOC
    //
    //  ⚠️ THE CEILING IS GONE AND THE READING STAYS (22 September 2026).
    //
    //  The ceiling lived in `addArbiter`: the chief's bloc might not reach the
    //  number of votes that decides an appeal, counted at his press. The chief
    //  has no press any more, so the rule has nothing to guard and
    //  `ChiefBlocWouldDecideAppeal` is raised nowhere.
    //
    //  `getChiefBloc()` is kept, and it is not decoration: it answers how many
    //  votes on an appeal panel stand with the chief, and a reader — a person
    //  today, a screen tomorrow — decides on that number. What can still make it
    //  non-zero is the OWNER seating the chief, or seats the chief granted
    //  BEFORE he lost the door, which exist on chain and do not evaporate.
    // ============================================================

    /// The chief who is himself an arbiter is one unit of his own bloc — the
    /// owner can still seat him, and that is the only road left to it.
    function test_AChiefTheOwnerSeatedIsOneUnitOfHisOwnBloc() public {
        assertEq(facet.getChiefBloc(), 0, "an empty corps already has a bloc");

        facet.addArbiter(chief);
        assertEq(facet.getChiefBloc(), 1, "a chief who is an arbiter is one unit of the bloc");

        // And seats the OWNER grants to other people are the owner's, not his.
        facet.addArbiter(seat1);
        facet.addArbiter(seat2);
        assertEq(facet.getChiefBloc(), 1, "the owner's seatings were credited to the chief");
        assertEq(accFacet.getSeatedCountBy(owner), 3, "the owner's own counter did not keep them");
    }

    /// The union, not the sum. `seatedCountBy[chief]` and "the chief himself"
    /// overlap when he was seated BY HIMSELF, and a blind addition would call
    /// one person two votes.
    ///
    /// ⚠️ THE SEAT IS WRITTEN INTO STORAGE, because the press that used to
    /// make it — the chief seating himself — is gone. Seats of exactly this
    /// shape are on the chain today, granted before the door closed, so this is
    /// the live case and not an invented one. The write is read back through the
    /// live getters, so a layout that moves turns the SETUP red.
    function test_AChiefWhoSeatedHimselfIsCountedOnce() public {
        facet.addArbiter(chief);
        _seatedByForTest(chief, chief);

        assertTrue(facetVault.isRegisteredArbiter(chief), "setup: the chief holds no seat");
        assertEq(accFacet.getSeatedBy(chief), chief, "setup: he does not read as having seated himself");
        assertEq(accFacet.getSeatedCountBy(chief), 1, "setup: his own counter did not count it");

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

    /// A seat the chief granted before 22 September 2026 still counts towards
    /// his bloc and still falls when its holder leaves. Those seats exist on
    /// chain; nothing about the closed door unwrites them.
    function test_ASeatTheChiefGrantedBeforeTheDoorClosedStillCounts() public {
        facet.addArbiter(seat1);
        _seatedByForTest(seat1, chief);
        assertEq(facet.getChiefBloc(), 1, "an old seat of his stopped counting");

        vm.prank(seat1);
        facet.resignAsArbiter();
        assertEq(facet.getChiefBloc(), 0, "the place did not come free");
    }

    /// Moves a seat's recorded grantor, and the grantor's counter with it, the
    /// way a press used to. Found by measurement, not by counting declarations:
    /// each offset is tried and the live getter is asked where the write landed.
    function _seatedByForTest(address who, address grantor) internal {
        address was = accFacet.getSeatedBy(who);
        _writeMappingByFindingIt(who, uint256(uint160(grantor)), _SEATED_BY);
        assertEq(accFacet.getSeatedBy(who), grantor, "rig: seatedBy was not found");

        _writeMappingByFindingIt(grantor, accFacet.getSeatedCountBy(grantor) + 1, _SEATED_COUNT);
        if (was != address(0) && was != grantor) {
            _writeMappingByFindingIt(was, accFacet.getSeatedCountBy(was) - 1, _SEATED_COUNT);
        }
    }

    uint8 constant _SEATED_BY    = 0;
    uint8 constant _SEATED_COUNT = 1;

    /// Namespace base of ArbiterRegistryStorage, as the library declares it.
    bytes32 constant ARB_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    function _writeMappingByFindingIt(address key, uint256 value, uint8 which) internal {
        for (uint256 f = 0; f < 64; f++) {
            bytes32 slot = keccak256(abi.encode(key, uint256(ARB_BASE) + f));
            bytes32 old = vm.load(address(facet), slot);
            vm.store(address(facet), slot, bytes32(value));
            bool hit = which == _SEATED_BY
                ? accFacet.getSeatedBy(key) == address(uint160(value))
                : accFacet.getSeatedCountBy(key) == value;
            if (hit) return;
            vm.store(address(facet), slot, old);
        }
        revert("rig: the field was not found - the storage layout moved");
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
