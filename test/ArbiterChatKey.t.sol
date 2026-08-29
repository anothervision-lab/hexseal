// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";
import {FactoryStorage} from "../src/FactoryFacet.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";

contract ArbiterChatKeyTest is Test, ArbiterTwoFacetBench {
    /// Both handles point at ONE address — the proxy carrying both facets (see
    /// ArbiterTwoFacetBench). `facet` deliberately keeps its old name: every
    /// vm.store(address(facet), ...) below keeps hitting the very same storage.
    ArbiterRegistryFacet facet;
    ArbiterAccountabilityFacet accFacet;

    function setUp() public {
        (facet, accFacet) = _deployArbiterBench();
    }

    /// No keys — both halves zero. A test of its own, because "there is no key"
    /// and "the key is zero" are the same thing to a reader, and that is
    /// deliberate: the evidence flow treats a zero key as "there is nobody to
    /// present to".
    function test_ChatKeysEmptyByDefault() public view {
        (bytes32 box, bytes32 sign) = accFacet.getArbiterChatKeys(address(0xBEEF));
        assertEq(box, bytes32(0), "boxKey must be zero");
        assertEq(sign, bytes32(0), "signKey must be zero");
    }

    /// An arbiter writes their keys and reads them back.
    function test_SetChatKey_WritesOwnKeys() public {
        address arb = address(0xA1);
        _makeArbiter(arb);
        bytes32 box  = bytes32(uint256(0x11));
        bytes32 sign = bytes32(uint256(0x22));

        vm.prank(arb);
        facet.setArbiterChatKey(box, sign);

        (bytes32 gotBox, bytes32 gotSign) = accFacet.getArbiterChatKeys(arb);
        assertEq(gotBox, box);
        assertEq(gotSign, sign);
    }

    /// A zero key is rejected: it is indistinguishable from "there are no keys",
    /// and writing it would declare oneself ready to receive evidence while being
    /// unable to read it.
    function test_SetChatKey_RejectsZero() public {
        address arb = address(0xA1);
        _makeArbiter(arb);

        vm.prank(arb);
        vm.expectRevert(ArbiterRegistryFacet.ZeroChatKey.selector);
        facet.setArbiterChatKey(bytes32(0), bytes32(uint256(0x22)));

        vm.prank(arb);
        vm.expectRevert(ArbiterRegistryFacet.ZeroChatKey.selector);
        facet.setArbiterChatKey(bytes32(uint256(0x11)), bytes32(0));
    }

    /// A non-arbiter cannot write: the registry is not a public noticeboard.
    function test_SetChatKey_OnlyArbiter() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ArbiterRegistryFacet.NotArbiter.selector);
        facet.setArbiterChatKey(bytes32(uint256(0x11)), bytes32(uint256(0x22)));
    }

    /// One can write ONLY to oneself: there is no "to whom" argument at all, the
    /// address comes from the sender. A lock against that argument appearing.
    function test_SetChatKey_WritesOnlyForSender() public {
        address a = address(0xA1);
        address b = address(0xB2);
        _makeArbiter(a);
        _makeArbiter(b);

        vm.prank(a);
        facet.setArbiterChatKey(bytes32(uint256(0xAA)), bytes32(uint256(0xAB)));

        (bytes32 bBox, bytes32 bSign) = accFacet.getArbiterChatKeys(b);
        assertEq(bBox, bytes32(0), "arbiter A's write landed on arbiter B");
        assertEq(bSign, bytes32(0), "arbiter A's write landed on arbiter B");
    }

    /// THE EVENT IS MANDATORY. Without it the evidence flow would have to poll the
    /// chain, and on 9 August 8 100 chain calls an hour from a single tab were
    /// removed for exactly that reason — a new poll would bring the same trouble
    /// back under another name.
    function test_SetChatKey_EmitsEvent() public {
        address arb = address(0xA1);
        _makeArbiter(arb);
        bytes32 box  = bytes32(uint256(0x11));
        bytes32 sign = bytes32(uint256(0x22));

        vm.expectEmit(true, false, false, true);
        emit ArbiterRegistryFacet.ArbiterChatKeySet(arb, box, sign);
        vm.prank(arb);
        facet.setArbiterChatKey(box, sign);
    }

    /// Rewriting is allowed and must change the value: an arbiter's key lives on a
    /// device, and otherwise changing phone would leave the parties sealing their
    /// evidence into a dead key.
    function test_SetChatKey_Overwrites() public {
        address arb = address(0xA1);
        _makeArbiter(arb);

        vm.prank(arb);
        facet.setArbiterChatKey(bytes32(uint256(0x11)), bytes32(uint256(0x22)));
        vm.prank(arb);
        facet.setArbiterChatKey(bytes32(uint256(0x33)), bytes32(uint256(0x44)));

        (bytes32 box, bytes32 sign) = accFacet.getArbiterChatKeys(arb);
        assertEq(box, bytes32(uint256(0x33)));
        assertEq(sign, bytes32(uint256(0x44)));
    }

    bytes32 constant CHAT_KEY_SET_TOPIC = keccak256("ArbiterChatKeySet(address,bytes32,bytes32)");

    function _countChatKeySetEvents(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == CHAT_KEY_SET_TOPIC) n++;
        }
    }

    /// Amplification through the event: an identical rewrite does NOT emit
    /// ArbiterChatKeySet. The evidence flow re-presents ON THE EVENT — without
    /// this condition an arbiter with N open disputes, taking dispute N+1 with the
    /// ordinary (same) key, would send N pointless re-presentations: a full
    /// re-encryption and re-upload of every chat log to storage, free of charge to
    /// the arbiter themselves.
    ///
    /// What disappears from the behaviour if the fix is removed: the event fires
    /// even on a byte-for-byte identical rewrite — exactly the amplification that
    /// was already caught and closed in the chain polling above (8 100 calls an
    /// hour, see the comment at ArbiterChatKeySet), returning here through another
    /// door.
    function test_SetChatKey_NoEventOnIdenticalRewrite() public {
        address arb = address(0xA1);
        _makeArbiter(arb);
        bytes32 box  = bytes32(uint256(0x11));
        bytes32 sign = bytes32(uint256(0x22));

        vm.prank(arb);
        facet.setArbiterChatKey(box, sign);

        vm.recordLogs();
        vm.prank(arb);
        facet.setArbiterChatKey(box, sign); // the same values — a no-op in effect
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countChatKeySetEvents(logs), 0,
            "an identical rewrite must not emit ArbiterChatKeySet"
        );
        // The record is there all the same — idempotence, not a refusal to write.
        (bytes32 gotBox, bytes32 gotSign) = accFacet.getArbiterChatKeys(arb);
        assertEq(gotBox, box);
        assertEq(gotSign, sign);
    }

    /// The mirror of the previous test: a rewrite that REALLY changes something
    /// must emit the event exactly once — otherwise
    /// test_SetChatKey_NoEventOnIdenticalRewrite would pass in a world where the
    /// event never fires at all (the lock would be guarding the text of a
    /// condition rather than a behaviour).
    function test_SetChatKey_EmitsEventWhenValueActuallyChanges() public {
        address arb = address(0xA1);
        _makeArbiter(arb);

        vm.prank(arb);
        facet.setArbiterChatKey(bytes32(uint256(0x11)), bytes32(uint256(0x22)));

        vm.recordLogs();
        vm.prank(arb);
        facet.setArbiterChatKey(bytes32(uint256(0x33)), bytes32(uint256(0x22))); // boxKey changes
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countChatKeySetEvents(logs), 1,
            "a changed rewrite must emit ArbiterChatKeySet exactly once"
        );
    }

    // ============================================================
    //  THROUGH A REAL FORWARDER (ERC-2771)
    // ============================================================
    //
    // All six tests above call facet.setArbiterChatKey(...) directly under
    // vm.prank — in that environment trustedForwarder is unset, so _msgSender()
    // returns msg.sender, and swapping _msgSender() for msg.sender inside the
    // function would not change their green colour at all. Exactly the same class
    // of bug already hit fundDispute — the paid arbiter call never fired once
    // because it read msg.sender, and direct tests did not catch it. The only
    // road by which an arbiter really publishes a key is the gasless one, through
    // the relayer: if the function reads msg.sender, the key is written to the
    // forwarder's address, the arbiter believes it is published, and the parties
    // seal their evidence into the void.
    // A model of the setup (the ForwardRequest signature, the EIP-712 domain) is
    // the paid-call-through-a-real-forwarder section of the DisputeSettlement
    // suite.

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    /// The offset of trustedForwarder inside FactoryStorage.Layout — 3 slots from
    /// the base (usdc(0), feeRecipient(1), regionFee(2, a mapping — a slot of its
    /// own), trustedForwarder(3)). The same offset that is already asserted and
    /// used in BoardsFixture (with the comment there). It is written straight into
    /// the facet's slot, because there is no diamond and no initFactory here — the
    /// facet is deployed on its own, as in every other test in this file.
    function _setTrustedForwarder(address forwarder) internal {
        bytes32 slot = bytes32(uint256(FactoryStorage.FACTORY_STORAGE_POSITION) + 3);
        vm.store(address(facet), slot, bytes32(uint256(uint160(forwarder))));
        // The offset is not taken on trust: if the Layout ever drifts, the test
        // must fail here with a comprehensible reason rather than quietly write
        // into somebody else's field and leave one guessing why the signature
        // "did not work".
        assertEq(
            address(uint160(uint256(vm.load(address(facet), slot)))),
            forwarder,
            "the trustedForwarder offset in FactoryStorage.Layout has moved"
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

    /// The measurement: setArbiterChatKey called through a real MinimalForwarder
    /// must write the key for the PERSON who signed the ForwardRequest, not for
    /// the forwarder address that physically made the msg.sender call on the
    /// facet. execute() is sent by a THIRD address (neither the arbiter nor the
    /// forwarder) — exactly as it works in production: the relayer pays the gas
    /// but is neither the signer nor the recipient.
    ///
    /// The second assertion (zeroes at the forwarder's address) is mandatory: it
    /// is what tells "the person was read" apart from "the messenger was read" —
    /// without it the test would pass in a world where _msgSender() quietly
    /// returned anything at all, as long as some keys ended up at that address.
    function test_SetChatKey_ThroughRealForwarder_RecordsHumanNotForwarder() public {
        uint256 arbiterPk = 0xCA11;
        address arb = vm.addr(arbiterPk);
        address relayer = address(0x9999); // a third address: not the arbiter, not the forwarder
        _makeArbiter(arb);

        MinimalForwarder fwd = new MinimalForwarder();
        _setTrustedForwarder(address(fwd));

        bytes32 box  = bytes32(uint256(0x77));
        bytes32 sign = bytes32(uint256(0x88));
        bytes memory data = abi.encodeWithSelector(ArbiterRegistryFacet.setArbiterChatKey.selector, box, sign);

        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  arb,
            to:    address(facet),
            value: 0,
            gas:   500_000,
            nonce: fwd.getNonce(arb),
            data:  data
        });
        bytes memory sig = _signFwd(fwd, arbiterPk, req);

        vm.prank(relayer);
        (bool ok, bytes memory ret) = fwd.execute(req, sig);
        assertTrue(ok, string.concat("forwarded setArbiterChatKey failed: ", vm.toString(ret)));

        (bytes32 gotBox, bytes32 gotSign) = accFacet.getArbiterChatKeys(arb);
        assertEq(gotBox, box, "the key must be written for the signer, not for the forwarder");
        assertEq(gotSign, sign, "the key must be written for the signer, not for the forwarder");

        (bytes32 fwdBox, bytes32 fwdSign) = accFacet.getArbiterChatKeys(address(fwd));
        assertEq(fwdBox, bytes32(0), "the key leaked to the forwarder address instead of the person");
        assertEq(fwdSign, bytes32(0), "the key leaked to the forwarder address instead of the person");
    }

    /// A claim must carry the keys and write them down. Checked at the level of the
    /// signature: the test does not compile if the arguments are missing.
    function test_ClaimDispute_HasKeyArguments() public {
        // It is enough that a call with four arguments compiles and falls over on
        // the arbiter check rather than on the shape of the call.
        vm.prank(address(0xDEAD));
        vm.expectRevert(ArbiterRegistryFacet.NotArbiter.selector);
        facet.claimDispute(
            address(0xA9),
            bytes32(uint256(1)),
            bytes32(uint256(0x11)),
            bytes32(uint256(0x22))
        );
    }

    /// A zero key in a claim is rejected with the same error as in
    /// setArbiterChatKey: two entrances, one rule.
    function test_ClaimDispute_RejectsZeroKey() public {
        address arb = address(0xA1);
        _makeArbiter(arb);
        vm.prank(arb);
        vm.expectRevert(ArbiterRegistryFacet.ZeroChatKey.selector);
        facet.claimDispute(address(0xA9), bytes32(uint256(1)), bytes32(0), bytes32(uint256(0x22)));
    }

    /// A successful claim must WRITE the keys, not merely accept them as the shape
    /// of an argument. A lock against the regression: "the key is a mandatory
    /// argument" without the write means the arbiter has claimed, the key went off
    /// into the calldata and vanished, and the parties still present their chat log
    /// into the void — precisely the hole this whole piece of work was to close.
    function test_ClaimDispute_WritesKeys() public {
        address arb = address(0xA1);
        _makeArbiter(arb);

        MockDisputedAgreement agr = new MockDisputedAgreement(address(0xC1), address(0xE1));

        bytes32 salt = bytes32(uint256(0x9));
        bytes32 commitment = keccak256(abi.encodePacked(address(agr), arb, salt));
        vm.prank(arb);
        facet.commitDisputeClaim(commitment);
        vm.roll(block.number + 1);

        bytes32 box  = bytes32(uint256(0x33));
        bytes32 sign = bytes32(uint256(0x44));
        vm.prank(arb);
        facet.claimDispute(address(agr), salt, box, sign);

        (bytes32 gotBox, bytes32 gotSign) = accFacet.getArbiterChatKeys(arb);
        assertEq(gotBox, box, "a successful claim did not write boxKey");
        assertEq(gotSign, sign, "a successful claim did not write signKey");
    }

    /// commit+roll+claim lives in a helper rather than inline twice in the body of
    /// a test: the same device as the Diamond suite's _claimDisputeAs — calling one
    /// and the same sequence a SECOND time inline within a single test function
    /// under this repository (via_ir) was observed as "the second
    /// vm.roll(block.number + 1) does not take", while the same pattern through a
    /// helper function works normally.
    function _commitAndClaim(MockDisputedAgreement agr, address arb, bytes32 salt, bytes32 box, bytes32 sign) internal {
        bytes32 commitment = keccak256(abi.encodePacked(address(agr), arb, salt));
        vm.prank(arb);
        facet.commitDisputeClaim(commitment);
        uint256 nextBlock = block.number + 1;
        vm.roll(nextBlock);
        vm.prank(arb);
        facet.claimDispute(address(agr), salt, box, sign);
    }

    /// Claiming a SECOND dispute with the key already recorded for the arbiter does
    /// not re-emit ArbiterChatKeySet. A direct continuation of the amplification
    /// above: an arbiter with N open disputes, taking dispute N+1 with the ordinary
    /// device key (rather than a new one), must not force the evidence flow to
    /// re-encrypt and re-upload N chat logs that are already open.
    function test_ClaimDispute_NoEventWhenKeySameAsAlreadyRecorded() public {
        address arb = address(0xA1);
        _makeArbiter(arb);

        MockDisputedAgreement agr1 = new MockDisputedAgreement(address(0xC1), address(0xE1));
        MockDisputedAgreement agr2 = new MockDisputedAgreement(address(0xC2), address(0xE2));

        bytes32 box  = bytes32(uint256(0x33));
        bytes32 sign = bytes32(uint256(0x44));

        _commitAndClaim(agr1, arb, bytes32(uint256(0x9)), box, sign); // first claim — the key is new, the event fires

        vm.recordLogs();
        _commitAndClaim(agr2, arb, bytes32(uint256(0xA)), box, sign); // the same key, a second dispute
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countChatKeySetEvents(logs), 0,
            "claiming a second dispute with the same key must not re-emit ArbiterChatKeySet"
        );

        // DisputeClaimed must fire all the same — the condition is only around
        // ArbiterChatKeySet, not around the whole function.
        bytes32 disputeClaimedTopic = keccak256("DisputeClaimed(address,address)");
        bool sawDisputeClaimed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == disputeClaimedTopic) sawDisputeClaimed = true;
        }
        assertTrue(sawDisputeClaimed, "DisputeClaimed must fire on every claim");
    }

    /// The mirror of the previous test: a claim with a DIFFERENT key must emit the
    /// event — otherwise the previous lock would pass in a world where
    /// ArbiterChatKeySet never fires from claimDispute at all.
    function test_ClaimDispute_EmitsEventWhenKeyDiffersFromRecorded() public {
        address arb = address(0xA1);
        _makeArbiter(arb);

        MockDisputedAgreement agr1 = new MockDisputedAgreement(address(0xC1), address(0xE1));
        MockDisputedAgreement agr2 = new MockDisputedAgreement(address(0xC2), address(0xE2));

        _commitAndClaim(agr1, arb, bytes32(uint256(0x9)), bytes32(uint256(0x33)), bytes32(uint256(0x44)));

        vm.recordLogs();
        _commitAndClaim(agr2, arb, bytes32(uint256(0xA)), bytes32(uint256(0x55)), bytes32(uint256(0x44))); // a new boxKey
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            _countChatKeySetEvents(logs), 1,
            "changing the key on a claim must emit ArbiterChatKeySet exactly once"
        );
    }

    /// Seats an arbiter straight into the facet's storage. `applyAsArbiter()` is
    /// locked behind `isDaoActive()` and the DAO is deliberately not started — the
    /// owner's decision of 1 August. The test must not depend on the manner of
    /// seating.
    function _makeArbiter(address who) internal {
        // The storage POSITION + the slot of the isArbiter mapping (the first field of Data).
        bytes32 pos = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;
        bytes32 slot = keccak256(abi.encode(who, uint256(pos)));
        vm.store(address(facet), slot, bytes32(uint256(1)));
        assertTrue(facet.isRegisteredArbiter(who), "failed to seat the arbiter");
    }
}

/// A minimal Agreement stub — exactly the subset of the interface that
/// claimDispute() reads with staticcalls (status/disputedAt/DISPUTE_WINDOW/
/// client/executor) and calls (setArbiter). It lives in status DISPUTED(4) with
/// the dispute window open from the moment it is deployed.
contract MockDisputedAgreement {
    uint8 public constant status = 4; // Agreement.Status.DISPUTED
    uint256 public disputedAt;
    uint256 public constant DISPUTE_WINDOW = 3 days;
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
