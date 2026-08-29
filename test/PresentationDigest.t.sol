// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The presentation digest on chain.
//
// The chain cannot see the off-chain store and has no way whatever to check the
// content of a presentation. The point of the digest is not the content but the
// ORDER: 32 bytes landed in block N, the arbiter's record "asked, got no answer"
// in block M. If M > N, the arbiter's word is refuted by the chain, and no trust
// in the server is needed for that.
//
// Hence the two properties guarded here:
//   1. ONLY a party to the dispute may write. Otherwise an outsider would bury
//      somebody else's deal feed in digests, and "a party presented" would stop
//      meaning anything.
//   2. A digest does NOT forbid a record of silence. A hard ban would hand a
//      party a shield: put down the digest of an empty file and be invulnerable.
//
// ⚠️ Time here is taken ONLY through vm.getBlockTimestamp() — for the same
// reason as in the DisputeNoResponse suite: under via_ir solc treats TIMESTAMP
// as constant within a call, and a second `vm.warp(block.timestamp + …)` in one
// test body jumps to the same second as the first.
//
// The setup is the same light one as in the DisputeNoResponse suite: the facet
// is deployed on its own, no real diamond is needed. One difference is
// mandatory: recordPresentationDigest reads the parties from ITS OWN
// RegistryStorage, so a record of the deal has to be placed in the registry, and
// the tests will not run past it. The registry is filled by writing straight
// into slots (the production road, RegistryFacet.register(), is locked behind
// authorizedFactory and lives in another facet), and the slot offsets are not
// taken on trust: test_RegistrySlotOffsets_MatchLiveStorage guards them with
// unrelated code that predates this suite.

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";
import {RegistryStorage} from "../src/RegistryFacet.sol";
import {FactoryStorage} from "../src/FactoryFacet.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";

contract PresentationDigestTest is Test, ArbiterTwoFacetBench {
    /// Both handles point at ONE address — the proxy carrying both facets (see
    /// ArbiterTwoFacetBench). `facet` deliberately keeps its old name: every
    /// vm.store(address(facet), ...) below keeps hitting the very same storage.
    ArbiterRegistryFacet facet;
    ArbiterAccountabilityFacet accFacet;

    address client;
    address executor;
    address stranger;
    address arbiter;
    address agreement;

    /// The base of the ArbiterRegistryStorage namespace — ArbiterRegistryStorage.POSITION.
    bytes32 constant ARB_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    /// The offset of the `agreements` slot (the first field of
    /// RegistryStorage.Layout) from the registry namespace base. Inside an
    /// AgreementRecord: agreement(+0),
    /// client(+1), executor(+2).
    ///
    /// ⚠️ `forge inspect ArbiterRegistryFacet storage-layout` says nothing here and
    /// will go on saying nothing: the facet has not one ordinary state variable,
    /// the whole storage is namespaced and reached from assembly. The numbers
    /// below were obtained by measurement and are guarded by measurement too —
    /// see test_RegistrySlotOffsets_MatchLiveStorage.
    uint256 constant SLOT_REGISTRY_AGREEMENTS = 0;
    uint256 constant REC_OFFSET_CLIENT   = 1;
    uint256 constant REC_OFFSET_EXECUTOR = 2;

    function setUp() public {
        (facet, accFacet) = _deployArbiterBench();

        client   = address(0xC1);
        executor = address(0xE1);
        stranger = address(0x5A);
        arbiter  = address(0xA1);

        _makeArbiter(arbiter);
        agreement = address(new MockDisputedAgreementPD(client, executor));
        _registerAgreement(agreement, client, executor);
    }

    // ============================================================
    //  WHO MAY WRITE A DIGEST
    // ============================================================

    function test_PartyRecordsDigest() public {
        bytes32 digest = keccak256("presentation one");

        vm.expectEmit(true, true, false, true, address(facet));
        emit ArbiterRegistryFacet.PresentationDigestRecorded(agreement, client, digest, 0);

        vm.prank(client);
        facet.recordPresentationDigest(agreement, digest);

        bytes32[] memory all = accFacet.getPresentationDigests(agreement);
        assertEq(all.length, 1, "the digest must land on chain");
        assertEq(all[0], digest, "the very 32 bytes that were signed must land on chain");
    }

    /// The executor is as much a party to the dispute as the client. It is usually
    /// the executor who presents: a dispute is normally about whether the work was
    /// done.
    function test_ExecutorIsAlsoAParty() public {
        vm.prank(executor);
        facet.recordPresentationDigest(agreement, keccak256("work delivered"));
        assertEq(
            accFacet.getPresentationDigestCount(agreement),
            1,
            "the executor is a party to the dispute and must be able to present"
        );
    }

    function test_ManyDigestsFit() public {
        vm.startPrank(client);
        facet.recordPresentationDigest(agreement, keccak256("one"));
        facet.recordPresentationDigest(agreement, keccak256("two"));
        vm.stopPrank();
        assertEq(
            accFacet.getPresentationDigestCount(agreement),
            2,
            "a chat log does not fit in one bag: there are as many presentations as needed"
        );
    }

    /// Order is the only thing this whole record exists for, so the list must be
    /// returned in order of appearance and the index in the event must match the
    /// place in the list. Without that there is no way to present "the digest
    /// landed before the record of silence": the feed and the storage would have
    /// drifted apart.
    function test_DigestsKeepOrderAndIndex() public {
        bytes32 first  = keccak256("first");
        bytes32 second = keccak256("second");

        vm.prank(client);
        facet.recordPresentationDigest(agreement, first);

        vm.expectEmit(true, true, false, true, address(facet));
        emit ArbiterRegistryFacet.PresentationDigestRecorded(agreement, executor, second, 1);
        vm.prank(executor);
        facet.recordPresentationDigest(agreement, second);

        bytes32[] memory all = accFacet.getPresentationDigests(agreement);
        assertEq(all.length, 2, "both digests must remain");
        assertEq(all[0], first,  "the first one written must come first in the list");
        assertEq(all[1], second, "the order in the list is the very thing being proved");
    }

    function test_StrangerCannotRecord() public {
        vm.prank(stranger);
        vm.expectRevert(ArbiterRegistryFacet.NotDisputeParty.selector);
        facet.recordPresentationDigest(agreement, keccak256("somebody else's"));
    }

    /// An arbiter who has taken the dispute does not thereby become a party: their
    /// business is to read presentations, not to slip in their own. The scene is
    /// kept separate from "an outsider" deliberately — the arbiter is the one
    /// person with a legitimate reason to touch this deal, and it is about them
    /// that a reader will ask "but surely they can?".
    function test_ArbiterIsNotAParty() public {
        _claimBy(arbiter, agreement);
        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.NotDisputeParty.selector);
        facet.recordPresentationDigest(agreement, keccak256("the judge's own"));
    }

    /// An address that is not in the registry. Without this check anybody could
    /// deploy their own contract, declare themselves a party to it and fill the
    /// feed with "presentations" for a deal that never existed here.
    function test_UnknownAgreementRejected() public {
        address foreign = address(new MockDisputedAgreementPD(client, executor));
        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.NotDisputeParty.selector);
        facet.recordPresentationDigest(foreign, keccak256("for somebody else's deal"));
    }

    function test_ZeroDigestRejected() public {
        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.ZeroDigest.selector);
        facet.recordPresentationDigest(agreement, bytes32(0));
    }

    function test_CountIsZeroBeforeAnyDigest() public view {
        assertEq(
            accFacet.getPresentationDigestCount(agreement),
            0,
            "nothing has been presented yet, so there is nothing to count"
        );
        assertEq(
            accFacet.getPresentationDigests(agreement).length,
            0,
            "an empty list, not rubbish"
        );
    }

    // ============================================================
    //  THE WINDOW: A READ THAT DOES NOT BREAK UNDER SOMEBODY ELSE'S ZEAL
    // ============================================================
    //
    // A full getPresentationDigests on a long list runs into the gas ceiling of
    // eth_call — and it breaks for the ARBITER and for the other party, not for
    // whoever inflated the list. The window is a way out for the reader without an
    // upgrade to the contract.
    //
    // The central property here is not "it cuts at limit" but "it does not revert
    // on an honest request". The reader does not know the length in advance: they
    // can only learn it with a second call, that is in another block, by which time
    // the length is already different. A revert at the edge would mean that whoever
    // is paging has to win a race against whoever is writing.

    function test_Page_ReturnsWindow() public {
        bytes32[] memory put = _fillDigests(5);

        bytes32[] memory page = accFacet.getPresentationDigestsPage(agreement, 1, 2);
        assertEq(page.length, 2, "the window must return exactly limit while the list suffices");
        assertEq(page[0], put[1], "the window must begin at offset");
        assertEq(page[1], put[2], "the order within the window is the order in the list");
    }

    /// An `offset` past the end returns an empty array, not a revert. That is the
    /// stopping condition for whoever is paging: "there is nothing more here".
    function test_Page_OffsetPastEnd_ReturnsEmptyNotRevert() public {
        _fillDigests(3);
        assertEq(
            accFacet.getPresentationDigestsPage(agreement, 3, 10).length,
            0,
            "an offset exactly past the end is empty, and that is an answer, not an error"
        );
        assertEq(
            accFacet.getPresentationDigestsPage(agreement, 999, 10).length,
            0,
            "an offset far past the end is empty too; the reader did not know the length"
        );
    }

    /// An empty list is the same case, and a common one: the screen was opened
    /// before the first presentation.
    function test_Page_EmptyList_ReturnsEmptyNotRevert() public view {
        assertEq(
            accFacet.getPresentationDigestsPage(agreement, 0, 10).length,
            0,
            "over an empty list the window must return empty rather than fail"
        );
    }

    function test_Page_ZeroLimit_ReturnsEmptyNotRevert() public {
        _fillDigests(3);
        assertEq(
            accFacet.getPresentationDigestsPage(agreement, 0, 0).length,
            0,
            "limit == 0 is a lawful request for nothing at all, not an error"
        );
    }

    /// A tail shorter than the window: return what there is. Without this, a reader
    /// asking for the last page would get a revert instead of the remainder.
    function test_Page_LimitBeyondEnd_ReturnsTail() public {
        bytes32[] memory put = _fillDigests(3);

        bytes32[] memory page = accFacet.getPresentationDigestsPage(agreement, 2, 100);
        assertEq(page.length, 1, "a tail shorter than the window returns the tail, not a revert");
        assertEq(page[0], put[2], "the tail must hold the last one written");
    }

    /// A `limit` at the uint256 ceiling is the same "to the end", and it is an
    /// honest request: "give me everything there is from this point", when the
    /// length is not known in advance.
    ///
    /// It is checked separately because a naive `offset + limit` PANICS here
    /// (0x11, checked arithmetic in 0.8) — that is, it breaks not the accuracy of
    /// the answer but the promise "it does not revert on an honest request".
    /// Measured by mutation: the naive sum turns exactly this test red.
    function test_Page_HugeLimit_IsUpToTheEnd_NotARevert() public {
        _fillDigests(3);
        assertEq(
            accFacet.getPresentationDigestsPage(agreement, 1, type(uint256).max).length,
            2,
            "a limit at the ceiling means to the end, not a panic on an honest request"
        );
    }

    /// The window and the full getter must say the same thing — otherwise "it adds
    /// up / it does not add up" on screen would depend on which getter was read.
    function test_Page_AgreesWithFullGetter() public {
        _fillDigests(4);
        bytes32[] memory full = accFacet.getPresentationDigests(agreement);
        bytes32[] memory page = accFacet.getPresentationDigestsPage(agreement, 0, full.length);

        assertEq(page.length, full.length, "a full-length window must give the whole list");
        for (uint256 i = 0; i < full.length; i++) {
            assertEq(page[i], full[i], "the window and the full list diverged, so the reader has nothing to trust");
        }
    }

    /// Paging must cover the whole list and cover it without repeats — that is
    /// exactly how it gets used.
    function test_Page_WalkCoversEverythingOnce() public {
        bytes32[] memory put = _fillDigests(5);

        uint256 seen = 0;
        for (uint256 off = 0; off < 6; off += 2) {
            bytes32[] memory page = accFacet.getPresentationDigestsPage(agreement, off, 2);
            for (uint256 i = 0; i < page.length; i++) {
                assertEq(page[i], put[seen], "paging slipped: the wrong digest in its place");
                seen++;
            }
        }
        assertEq(seen, put.length, "paging must cover the whole list");
    }

    // ============================================================
    //  A DIGEST IS NOT A SHIELD
    // ============================================================

    /// The temptation to say "once a party has presented, forbid the arbiter to
    /// record silence" looks fair and is a hole: the chain does not know what lies
    /// under the digest, so the shield would also go to whoever put down the hash
    /// of an empty file. A dispute is settled by an arbiter looking at the order,
    /// not by the contract.
    function test_DigestDoesNotBlockNoResponse() public {
        _claimBy(arbiter, agreement);

        vm.prank(client);
        facet.recordPresentationDigest(agreement, keccak256("something"));

        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(arbiter);
        facet.recordNoResponse(agreement);

        assertGt(
            accFacet.getNoResponseAt(agreement),
            0,
            "a hard ban would hand a party a shield: the digest of an empty file and invulnerability"
        );
    }

    /// The other side of the same coin: the arbiter's record of silence does not
    /// lock the party out. They must still be able to present AFTER it — and then
    /// the chain keeps the fact that the presentation was late, which is more
    /// honest than not letting them present at all.
    function test_NoResponseDoesNotBlockDigest() public {
        _claimBy(arbiter, agreement);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(arbiter);
        facet.recordNoResponse(agreement);

        vm.prank(client);
        facet.recordPresentationDigest(agreement, keccak256("late, but it happened"));

        assertEq(
            accFacet.getPresentationDigestCount(agreement),
            1,
            "a record of silence has no right to lock the party out"
        );
    }

    // ============================================================
    //  THROUGH A REAL FORWARDER (ERC-2771)
    // ============================================================
    //
    // Every test above calls the facet directly under vm.prank — in that
    // environment trustedForwarder is unset, so _msgSender() returns msg.sender,
    // and swapping _msgSender() for msg.sender inside the function would not change
    // their green colour in the slightest. Exactly the same class of bug already
    // hit fundDispute.
    //
    // Here it would not be "inconvenient" but "never works": a party to a dispute
    // travels gasless, and with msg.sender the sender would be the forwarder — an
    // address that is neither client nor executor. Every digest would run into
    // NotDisputeParty, and the person would see "the transaction did not go
    // through".

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    function test_DigestThroughRealForwarder_CreditsHumanNotForwarder() public {
        uint256 clientPk = 0xC11E27;
        address human = vm.addr(clientPk);
        address relayer = address(0x9999); // a third address: not a party, not the forwarder

        // The party recorded in the registry is the signer.
        address agr = address(new MockDisputedAgreementPD(human, executor));
        _registerAgreement(agr, human, executor);

        MinimalForwarder fwd = new MinimalForwarder();
        _setTrustedForwarder(address(fwd));

        bytes32 digest = keccak256("through the relayer");
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  human,
            to:    address(facet),
            value: 0,
            gas:   500_000,
            nonce: fwd.getNonce(human),
            data:  abi.encodeWithSelector(
                ArbiterRegistryFacet.recordPresentationDigest.selector, agr, digest
            )
        });

        vm.prank(relayer);
        (bool ok, bytes memory ret) = fwd.execute(req, _signFwd(fwd, clientPk, req));
        assertTrue(ok, string.concat("forwarded recordPresentationDigest failed: ", vm.toString(ret)));

        bytes32[] memory all = accFacet.getPresentationDigests(agr);
        assertEq(all.length, 1, "through a forwarder the sender must be taken to be the person, not the forwarder");
        assertEq(all[0], digest, "the digest from the signed request must land on chain");
    }

    // ============================================================
    //  A LOCK ON THE SETUP ITSELF
    // ============================================================

    /// The registry here is filled by writing straight into slots, and if the
    /// offsets drift the write lands elsewhere: `rec.agreement` stays zero, ANY
    /// call runs into NotDisputeParty — and every "an outsider cannot" test goes
    /// green for the wrong reason, checking an empty space.
    ///
    /// So the offsets are checked by UNRELATED code that predates this suite:
    /// notifyArbiterTimeout reads `rec.agreement`, fundDispute reads `rec.client`
    /// and `rec.executor`. The different answers of those functions are the
    /// measurement.
    function test_RegistrySlotOffsets_MatchLiveStorage() public {
        // (1) the `agreement` field. notifyArbiterTimeout is called only by the deal
        // itself and first of all requires that the registry record be found; there
        // is no claim, so beyond that it exits quietly, touching nothing.
        vm.prank(agreement);
        facet.notifyArbiterTimeout(agreement); // does not revert ⇒ rec.agreement is in place

        // (2) the `client` field. To an outsider fundDispute answers NotParty —
        // which means it has already passed the "record found" check
        // (rec.client != 0). Had the offset drifted, the answer would be
        // NotAuthorized.
        vm.prank(stranger);
        vm.expectRevert(ArbiterRegistryFacet.NotParty.selector);
        facet.fundDispute(agreement);

        // (3) the `executor` field. The same call from the executor must pass the
        // party check and stumble FURTHER ON (the mock cannot do disputeFee()).
        // Asserting "it reverts, but not with this" has to be done by hand:
        // vm.expectRevert can only do "it reverts with this".
        vm.prank(executor);
        (bool ok, bytes memory ret) = address(facet).call(
            abi.encodeWithSelector(ArbiterRegistryFacet.fundDispute.selector, agreement)
        );
        assertFalse(ok, "the scene did not assemble: the mock cannot do disputeFee(), the call must fail");
        assertTrue(ret.length >= 4, "the scene did not assemble: an answer with a reason was expected");
        assertTrue(
            bytes4(ret) != ArbiterRegistryFacet.NotParty.selector,
            "the executor was not recognised as a party: the executor offset in AgreementRecord has drifted"
        );
    }

    // ============================================================
    //  HELPERS
    // ============================================================

    /// Places a record of the deal into the facet's own RegistryStorage. The
    /// production road (RegistryFacet.register) is locked behind authorizedFactory
    /// and lives in another facet — it is not here at all, and no diamond is
    /// brought up.
    function _registerAgreement(address agr, address cli, address exe) internal {
        bytes32 rec = keccak256(abi.encode(
            agr,
            uint256(RegistryStorage.REGISTRY_STORAGE_POSITION) + SLOT_REGISTRY_AGREEMENTS
        ));
        vm.store(address(facet), rec, bytes32(uint256(uint160(agr))));
        vm.store(
            address(facet),
            bytes32(uint256(rec) + REC_OFFSET_CLIENT),
            bytes32(uint256(uint160(cli)))
        );
        vm.store(
            address(facet),
            bytes32(uint256(rec) + REC_OFFSET_EXECUTOR),
            bytes32(uint256(uint160(exe)))
        );
    }

    /// Places n digests from the client and returns them in the same order — so
    /// that the window tests compare content and not only length.
    function _fillDigests(uint256 n) internal returns (bytes32[] memory put) {
        put = new bytes32[](n);
        vm.startPrank(client);
        for (uint256 i = 0; i < n; i++) {
            put[i] = keccak256(abi.encodePacked("presentation", i));
            facet.recordPresentationDigest(agreement, put[i]);
        }
        vm.stopPrank();
    }

    /// commit + roll + claim as one sequence in a helper rather than inline — the
    /// same reason as for _claimBy in the DisputeNoResponse suite.
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
        vm.store(address(facet), keccak256(abi.encode(who, uint256(ARB_BASE))), bytes32(uint256(1)));
        assertTrue(facet.isRegisteredArbiter(who), "failed to seat the arbiter");
    }

    /// The offset of trustedForwarder inside FactoryStorage.Layout — 3 slots from
    /// the base. The same offset that is asserted in the DisputeNoResponse suite and
    /// test/ArbiterChatKey.t.sol.
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

/// A minimal Agreement stub — the subset that is read with staticcalls
/// (status/disputedAt/DISPUTE_WINDOW/client/executor) and called (setArbiter).
/// It lives in status DISPUTED(4) with the dispute window open from the moment it
/// is deployed. A copy of MockDisputedAgreement from the ArbiterChatKey suite —
/// under a name of its own, because forge deploys every test file in one project.
///
/// disputeFee() is deliberately absent here: the lock on the registry slot offsets
/// relies on fundDispute from a party stumbling over precisely that, having passed
/// the party check.
contract MockDisputedAgreementPD {
    uint8 public constant status = 4; // Agreement.Status.DISPUTED
    uint256 public disputedAt;
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
