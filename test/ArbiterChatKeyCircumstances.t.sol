// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The project's five circumstance questions, applied to setArbiterChatKey().
// The rule they come from, word for word: "'fix this' gets done formally;
// 'prove by measurement that something changed' does not." Every test below is
// a measurement rather than an argument: it checks the state AFTER the event,
// not the fact that a function was called.
//
// The fifth question — "the disk filled up: did it return an error or fall over
// entirely?" — has no direct analogue in a contract and is deliberately NOT
// tested here as "ran out of space". Diamond Storage has no disk and no space
// that runs out gradually: only gas runs out, and running out of gas on any
// line cancels the WHOLE transaction (the EVM guarantees that itself; it is not
// a property of this code, and inventing a gas test would be testing the EVM
// rather than setArbiterChatKey()). The real analogue of "error or total
// collapse?" in this system is "a failed write must leave the previous state
// untouched rather than half of a new one" — and that is exactly
// test_FailedKeyChange_LeavesOldKeyAlive below (measurement no. 1). It also
// answers the question honestly: a partial write is physically impossible here
// (two fields are written in one call, which either executes in full or is
// rolled back in full), but "a refusal does not damage the working key" is a
// claim that has to be measured, not declared true by construction of the EVM.
import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";

contract ArbiterChatKeyCircumstancesTest is Test, ArbiterTwoFacetBench {
    /// Both handles point at ONE address — the proxy carrying both facets (see
    /// ArbiterTwoFacetBench). `facet` deliberately keeps its old name: every
    /// vm.store(address(facet), ...) below keeps hitting the very same storage.
    ArbiterRegistryFacet facet;
    ArbiterAccountabilityFacet accFacet;

    function setUp() public { (facet, accFacet) = _deployArbiterBench(); }

    function _makeArbiter(address who) internal {
        bytes32 pos = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;
        vm.store(address(facet), keccak256(abi.encode(who, uint256(pos))), bytes32(uint256(1)));
        // The check is mandatory: with a wrong slot the seating silently fails to
        // take, all five measurements below would start failing on NotArbiter, and
        // they would read as "circumstances checked".
        assertTrue(facet.isRegisteredArbiter(who), "failed to seat the arbiter");
    }

    /// 1. ABANDONED HALFWAY — and this is the costliest of the five cases.
    ///    The arbiter HAS a working key, starts changing device and halfway
    ///    through sends rubbish (the second half is zero). The refusal must leave
    ///    the PREVIOUS key intact.
    ///
    ///    Why it is costly: an arbiter without a key cannot read what was
    ///    presented, and silence is read against the one who stayed silent. So a
    ///    failed key change that wiped the working key would turn a slip of the
    ///    finger into a lost dispute.
    ///    Measurement: after the refusal, EXACTLY the previous 0x11/0x22 are read
    ///    back.
    function test_FailedKeyChange_LeavesOldKeyAlive() public {
        address arb = address(0xA1);
        _makeArbiter(arb);

        vm.prank(arb);
        facet.setArbiterChatKey(bytes32(uint256(0x11)), bytes32(uint256(0x22)));

        vm.prank(arb);
        vm.expectRevert(ArbiterRegistryFacet.ZeroChatKey.selector);
        facet.setArbiterChatKey(bytes32(uint256(0x99)), bytes32(0));

        (bytes32 box, bytes32 sign) = accFacet.getArbiterChatKeys(arb);
        assertEq(box,  bytes32(uint256(0x11)), "a failed change wiped the working key");
        assertEq(sign, bytes32(uint256(0x22)), "a failed change wiped the working key");
    }

    /// 2. RUBBISH ARRIVED: a zero key in either half. What is expected is a
    ///    VERDICT (a named error), not a silent write and not a crash.
    function test_Garbage_GivesVerdictNotSilence() public {
        address arb = address(0xA1);
        _makeArbiter(arb);
        vm.prank(arb);
        vm.expectRevert(ArbiterRegistryFacet.ZeroChatKey.selector);
        facet.setArbiterChatKey(bytes32(0), bytes32(0));
    }

    /// 3. TWO PROCESSES AT ONCE: two arbiters writing in the same block. What is
    ///    expected is that they did not collide, each keeping their own. Measured
    ///    in numbers.
    function test_TwoAtOnce_DoNotCollide() public {
        address a = address(0xA1);
        address b = address(0xB2);
        _makeArbiter(a); _makeArbiter(b);

        vm.prank(a); facet.setArbiterChatKey(bytes32(uint256(0xA0)), bytes32(uint256(0xA1)));
        vm.prank(b); facet.setArbiterChatKey(bytes32(uint256(0xB0)), bytes32(uint256(0xB1)));

        (bytes32 aBox,) = accFacet.getArbiterChatKeys(a);
        (bytes32 bBox,) = accFacet.getArbiterChatKeys(b);
        assertEq(aBox, bytes32(uint256(0xA0)));
        assertEq(bBox, bytes32(uint256(0xB0)));
    }

    /// 4. DELIBERATE HAMMERING: a hundred rewrites in a row. The project's
    ///    question — "who does it hurt, them or the neighbour?" — is about TWO
    ///    sides, not one. First half: the one doing it (they pay gas every time,
    ///    and the state converges to the last write — the per-write gas from
    ///    --gas-report goes into the report). Second half, the reason this test
    ///    was rewritten: the neighbour — a second arbiter whose keys were written
    ///    BEFORE the hammering started — must be left untouched to the bit after
    ///    all hundred rewrites of somebody else's keys. Without that half the
    ///    measurement only answers "it hurts them" and never checks "it does not
    ///    hurt the neighbour".
    function test_Hammering_HurtsOnlySender() public {
        address arb = address(0xA1);
        _makeArbiter(arb);

        // The neighbour: keys written once, before the hammering of the first arbiter.
        address neighbor = address(0xB2);
        _makeArbiter(neighbor);
        bytes32 neighborBoxBefore  = bytes32(uint256(0xDEAD));
        bytes32 neighborSignBefore = bytes32(uint256(0xBEEF));
        vm.prank(neighbor);
        facet.setArbiterChatKey(neighborBoxBefore, neighborSignBefore);

        for (uint256 i = 1; i <= 100; i++) {
            vm.prank(arb);
            facet.setArbiterChatKey(bytes32(i), bytes32(i + 1000));
        }

        (bytes32 box, bytes32 sign) = accFacet.getArbiterChatKeys(arb);
        assertEq(box, bytes32(uint256(100)));
        assertEq(sign, bytes32(uint256(1100)));

        // The neighbour is untouched: not by a single bit, despite a hundred
        // foreign writes.
        (bytes32 neighborBoxAfter, bytes32 neighborSignAfter) = accFacet.getArbiterChatKeys(neighbor);
        assertEq(neighborBoxAfter,  neighborBoxBefore,  "hammering the first arbiter touched the neighbour's key");
        assertEq(neighborSignAfter, neighborSignBefore, "hammering the first arbiter touched the neighbour's key");
    }

    /// 5. RESTART / REPEAT: the write is idempotent in its result — the same key
    ///    twice gives the same state, not an error. An arbiter who pressed twice
    ///    must not get a refusal.
    function test_SameKeyTwice_IsNotAnError() public {
        address arb = address(0xA1);
        _makeArbiter(arb);
        vm.prank(arb); facet.setArbiterChatKey(bytes32(uint256(7)), bytes32(uint256(8)));
        vm.prank(arb); facet.setArbiterChatKey(bytes32(uint256(7)), bytes32(uint256(8)));
        (bytes32 box,) = accFacet.getArbiterChatKeys(arb);
        assertEq(box, bytes32(uint256(7)));
    }
}
