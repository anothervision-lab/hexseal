// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  COMPLETED has two endings, and only an event tells them apart
// ============================================================
//
// The registry stamps the same COMPLETED(1) whichever way the escrow reached
// the executor:
//
//   * the client pressed confirm            -> release()            -> Released
//   * the client said nothing for two days,
//     and ANYONE pushed the deal shut       -> triggerAutoApprove() -> AutoApproved
//
// `RegistryStorage.AgreementStatus` mirrors the agreement's frozen `enum
// Status` and cannot grow a member, so the status can never carry the
// difference. Since 31 August 2026 (`f0b5ed93`) the bell and the push read the
// difference off the CLONE's own event, found in the same receipt as the
// diamond's `AgreementStatusUpdated`:
//
//   frontend/src/lib/completionCause.ts   -> classifyCompletion()
//   relayer/app.js                        -> findCompletionCause()
//
// WHAT IS AT STAKE. A client who has just lost the entire escrow to his own
// silence is told, word for word, what a client who paid on purpose is told.
// That was the bug this pair of events fixed; this file is what keeps the pair
// from drifting out from under the two readers, neither of which can notice on
// its own -- both decode by signature, and a signature that no longer matches
// simply yields nothing, silently, for everyone.
//
// ─── WHERE THE EXPECTED VALUES COME FROM ─────────────────────────────────────
//
// Not from `Agreement`. Importing the events from the contract under test would
// move the expectation along with any rename or reorder, which is the mirror
// trap: the lock would agree with the mutation and stay green.
//
// The topics below are keccak of signature strings TYPED OUT BY HAND, and each
// one is the same string the readers hold:
//
//   relayer/app.js:747      'event Released(address indexed client, address indexed executor, uint256 amount)'
//   relayer/app.js:748      'event AutoApproved(address indexed executor, uint256 amount)'
//   frontend/src/config/contracts.ts:1062  RELEASED_EVENT
//   frontend/src/config/contracts.ts:1073  AUTO_APPROVED_EVENT
//
// The indexed positions are asserted separately from the topic, because
// `Released(client, executor, amount)` and `Released(executor, client, amount)`
// have the SAME signature -- swapping the two addresses is invisible to a
// keccak check and would make the frontend attribute the deal to the wrong
// person.
//
// ─── THE THIRD ENDING IS REAL, AND IT IS NOT A HOLE ──────────────────────────
//
// `_complete()` syncs the registry through a tolerated call. When that call
// fails the clone emits `RegistrySyncFailed` and the status arrives LATER, in
// its own `syncRegistry()` transaction, whose receipt carries neither of the
// two events. Both readers already answer 'unknown' there and say so in copy
// that claims neither ending. `testAFailedSyncSplitsTheStatusFromTheCause`
// below states that branch as it really is -- and locks the honest half of it:
// the repair transaction must never grow a cause of its own, because
// `syncRegistry()` is callable BY ANYONE and would then be a way to tell a
// stranger's deal how it ended.

import "./MoneyPathBase.sol";
import "../src/MinimalForwarder.sol";

contract CompletionCauseTest is MoneyPathBase {
    // Re-declared here rather than imported, for the reason in the header.
    event Released(address indexed client, address indexed executor, uint256 amount);
    event AutoApproved(address indexed executor, uint256 amount);

    bytes32 constant RELEASED_TOPIC      = keccak256("Released(address,address,uint256)");
    bytes32 constant AUTO_APPROVED_TOPIC = keccak256("AutoApproved(address,uint256)");
    bytes32 constant STATUS_TOPIC        = keccak256("AgreementStatusUpdated(address,uint8)");
    bytes32 constant SYNC_FAILED_TOPIC   = keccak256("RegistrySyncFailed(address,uint8)");

    /// AgreementStatus.COMPLETED, written as the number the readers compare
    /// against rather than read off the enum under test.
    uint256 constant REG_COMPLETED = 1;

    MinimalForwarder forwarder;

    uint256 constant CLIENT_PK = 0xC11E;
    address clientSigner;

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    function setUp() public override {
        super.setUp();

        // A REAL forwarder, mounted before any clone is born, because a clone
        // reads the forwarder once at init and is nailed to it for life. The
        // scar is `fundDispute` reading raw msg.sender: in a direct call the
        // relayer and the human are the same address and the bug hides.
        forwarder = new MinimalForwarder();
        vm.prank(owner);
        FactoryFacet(address(diamond)).setTrustedForwarder(address(forwarder));

        clientSigner = vm.addr(CLIENT_PK);
        usdc.mint(clientSigner, BAG);
        vm.prank(clientSigner);
        usdc.approve(address(diamond), type(uint256).max);
    }

    // ------------------------------------------------------------
    //  Helpers
    // ------------------------------------------------------------

    function _dealAtHandIn() internal returns (Agreement a) {
        (a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);
        vm.prank(executor);
        a.markDone();
    }

    function _countFrom(Vm.Log[] memory logs, address emitter, bytes32 topic0)
        internal pure returns (uint256 n)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    /// Deliberately NOT scoped to an emitter: used only to assert ABSENCE, and
    /// an absence that ignored the emitter is the stronger statement.
    function _countAnywhere(Vm.Log[] memory logs, bytes32 topic0)
        internal pure returns (uint256 n)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    function _findFrom(Vm.Log[] memory logs, address emitter, bytes32 topic0)
        internal pure returns (Vm.Log memory found, bool ok)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                return (logs[i], true);
            }
        }
    }

    function _asTopic(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// The shape `parseEventLogs`/`Interface.parseLog` will decode on the other
    /// side: two indexed addresses in this order, the amount in `data`.
    function _assertReleasedShape(
        Vm.Log memory log,
        address expClient,
        address expExecutor,
        uint256 expAmount
    ) internal pure {
        assertEq(log.topics.length, 3, "Released must carry exactly two indexed fields");
        assertEq(log.topics[1], _asTopic(expClient),   "the first indexed field of Released is the client");
        assertEq(log.topics[2], _asTopic(expExecutor), "the second indexed field of Released is the executor");
        assertEq(abi.decode(log.data, (uint256)), expAmount, "the unindexed word of Released is the amount");
    }

    function _assertAutoApprovedShape(
        Vm.Log memory log,
        address expExecutor,
        uint256 expAmount
    ) internal pure {
        assertEq(log.topics.length, 2, "AutoApproved must carry exactly one indexed field");
        assertEq(log.topics[1], _asTopic(expExecutor), "the indexed field of AutoApproved is the executor");
        assertEq(abi.decode(log.data, (uint256)), expAmount, "the unindexed word of AutoApproved is the amount");
    }

    /// The status log the readers were already decoding before this pair
    /// existed -- the one the cause has to ride alongside.
    function _assertCompletedStatus(Vm.Log memory log, address agreement) internal pure {
        assertEq(log.topics.length, 2, "AgreementStatusUpdated indexes the agreement and nothing else");
        assertEq(log.topics[1], _asTopic(agreement), "the status is about this deal");
        assertEq(uint256(abi.decode(log.data, (uint8))), REG_COMPLETED, "and it says COMPLETED");
    }

    function _signFwd(uint256 pk, MinimalForwarder.ForwardRequest memory req)
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
                address(forwarder)
            )),
            structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _relay(uint256 pk, address to, bytes memory data) internal returns (bool, bytes memory) {
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  vm.addr(pk),
            to:    to,
            value: 0,
            gas:   3_000_000,
            nonce: forwarder.getNonce(vm.addr(pk)),
            data:  data
        });
        return forwarder.execute(req, _signFwd(pk, req));
    }

    // ============================================================
    //  1. The pair, one door at a time
    // ============================================================

    /// THE DESIGNATED LOCK for `release()`.
    ///
    /// Exclusivity is half of it. An `AutoApproved` anywhere in this receipt
    /// would make `classifyCompletion` answer 'auto' -- the clock is checked
    /// FIRST there, on purpose -- and a client who paid on purpose would be
    /// told he had lost the escrow by staying silent.
    function testReleaseSaysReleasedAndNeverTheClock() public {
        Agreement a = _dealAtHandIn();

        vm.recordLogs();
        vm.prank(client);
        a.release();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (Vm.Log memory rel, bool ok) = _findFrom(logs, address(a), RELEASED_TOPIC);
        assertTrue(ok, "release() left no Released the readers can find on this clone");
        _assertReleasedShape(rel, client, executor, AMOUNT);
        assertEq(_countFrom(logs, address(a), RELEASED_TOPIC), 1, "exactly one Released");

        assertEq(
            _countAnywhere(logs, AUTO_APPROVED_TOPIC), 0,
            "release() must not say the clock paid"
        );
    }

    /// THE DESIGNATED LOCK for `triggerAutoApprove()`.
    ///
    /// Pushed by a STRANGER, which is the shape that matters: this door is open
    /// to anyone, and the person who needs the notification is the client, who
    /// is not in the transaction at all.
    function testAutoApproveSaysTheClockAndNeverTheClient() public {
        Agreement a = _dealAtHandIn();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);

        vm.recordLogs();
        vm.prank(stranger);
        a.triggerAutoApprove();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (Vm.Log memory auto_, bool ok) = _findFrom(logs, address(a), AUTO_APPROVED_TOPIC);
        assertTrue(ok, "triggerAutoApprove() left no AutoApproved the readers can find on this clone");
        _assertAutoApprovedShape(auto_, executor, AMOUNT);
        assertEq(_countFrom(logs, address(a), AUTO_APPROVED_TOPIC), 1, "exactly one AutoApproved");

        assertEq(
            _countAnywhere(logs, RELEASED_TOPIC), 0,
            "the clock must not be reported as the client's own payment"
        );
    }

    /// The same two shapes stated a second way, as a person reads them. This
    /// scene is what a swap of `client` and `executor` inside `Released` runs
    /// into on top of the topic assertions above -- the signature would not
    /// change, so nothing keccak-shaped could see it.
    function testTheShapesAreTheOnesBothReadersDecode() public {
        Agreement a = _dealAtHandIn();

        vm.expectEmit(true, true, true, true, address(a));
        emit Released(client, executor, AMOUNT);
        vm.prank(client);
        a.release();

        // A second deal, because the registry keeps one live deal per pair.
        Agreement b = _dealAtHandIn();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);

        vm.expectEmit(true, true, true, true, address(b));
        emit AutoApproved(executor, AMOUNT);
        vm.prank(stranger);
        b.triggerAutoApprove();
    }

    // ============================================================
    //  2. The whole trick is "in the same receipt"
    // ============================================================

    /// THE DESIGNATED LOCK for co-location, release side.
    ///
    /// Both readers hold the diamond's `AgreementStatusUpdated` receipt already
    /// and look for the cause INSIDE IT -- no second chain read, and none
    /// budgeted. Split the registry sync and the clone's event into two
    /// transactions and the signal stays formally intact while becoming
    /// unreachable: the receipt in hand would carry a status and no cause, and
    /// every completion would read 'unknown'.
    function testTheReleaseAndTheDiamondStatusRideInOneReceipt() public {
        Agreement a = _dealAtHandIn();

        vm.recordLogs();
        vm.prank(client);
        a.release();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (Vm.Log memory st, bool okStatus) = _findFrom(logs, address(diamond), STATUS_TOPIC);
        assertTrue(okStatus, "the diamond's status update is not in the closing transaction");
        _assertCompletedStatus(st, address(a));

        assertEq(
            _countFrom(logs, address(a), RELEASED_TOPIC), 1,
            "and the cause has to be in the very same one"
        );
        assertEq(
            _countAnywhere(logs, SYNC_FAILED_TOPIC), 0,
            "precondition: the registry sync really went through in-band"
        );
    }

    /// THE DESIGNATED LOCK for co-location, clock side.
    function testTheAutoApprovalAndTheDiamondStatusRideInOneReceipt() public {
        Agreement a = _dealAtHandIn();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);

        vm.recordLogs();
        vm.prank(stranger);
        a.triggerAutoApprove();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (Vm.Log memory st, bool okStatus) = _findFrom(logs, address(diamond), STATUS_TOPIC);
        assertTrue(okStatus, "the diamond's status update is not in the closing transaction");
        _assertCompletedStatus(st, address(a));

        assertEq(
            _countFrom(logs, address(a), AUTO_APPROVED_TOPIC), 1,
            "and the cause has to be in the very same one"
        );
        assertEq(
            _countAnywhere(logs, SYNC_FAILED_TOPIC), 0,
            "precondition: the registry sync really went through in-band"
        );
    }

    // ============================================================
    //  3. The path people actually use
    // ============================================================

    /// Through a REAL MinimalForwarder. `release()` is gated on `_msgSender()`;
    /// were it ever to read raw `msg.sender`, the relayed call would be refused
    /// with NotClient and no test that calls the clone directly would notice.
    ///
    /// And the receipt must name the HUMAN. The frontend hands
    /// `Released.client` to copy that says who confirmed; a forwarder address
    /// there would be a lie told about a person's own money.
    function testTheReceiptSurvivesAndStaysHonestThroughTheForwarder() public {
        vm.prank(clientSigner);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(clientSigner);
        Agreement a = Agreement(JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor));

        assertEq(a.trustedForwarder(), address(forwarder), "precondition: the clone trusts the real forwarder");

        _activate(a);
        vm.prank(executor);
        a.markDone();

        vm.recordLogs();
        (bool ok, ) = _relay(CLIENT_PK, address(a), abi.encodeWithSignature("release()"));
        assertTrue(ok, "release() through the forwarder");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (Vm.Log memory rel, bool found) = _findFrom(logs, address(a), RELEASED_TOPIC);
        assertTrue(found, "a relayed release left no Released");
        _assertReleasedShape(rel, clientSigner, executor, AMOUNT);
        assertTrue(
            rel.topics[1] != _asTopic(address(forwarder)),
            "the receipt names the relayer instead of the person"
        );

        (Vm.Log memory st, bool okStatus) = _findFrom(logs, address(diamond), STATUS_TOPIC);
        assertTrue(okStatus, "and the status still rides with it");
        _assertCompletedStatus(st, address(a));
    }

    // ============================================================
    //  4. The third ending, told as it is
    // ============================================================

    /// THE BRANCH WHERE THE SIGNAL LEGITIMATELY IS NOT THERE.
    ///
    /// `_updateRegistry` is tolerated: money outranks the registry, so a
    /// diamond that cannot take the status update does not stop the deal from
    /// closing. The clone emits `RegistrySyncFailed`, the status arrives later
    /// in a separate `syncRegistry()` transaction -- and THAT receipt has no
    /// cause in it, because the cause was emitted in the earlier one.
    ///
    /// So there are three endings, not two, and both readers already answer
    /// 'unknown' here. What this scene locks is the honest half: the repair
    /// must never grow a cause of its own. `syncRegistry()` takes no arguments
    /// and is callable BY ANYONE, so a cause emitted from it would be a
    /// stranger's handle on how somebody else's deal is described.
    function testAFailedSyncSplitsTheStatusFromTheCause() public {
        Agreement a = _dealAtHandIn();

        // The refusal is fed in from OUTSIDE the contract under measurement.
        vm.mockCallRevert(
            address(diamond),
            abi.encodeWithSelector(RegistryFacet.updateStatus.selector),
            "no"
        );

        vm.recordLogs();
        vm.prank(client);
        a.release();
        Vm.Log[] memory closing = vm.getRecordedLogs();

        assertEq(_countFrom(closing, address(a), RELEASED_TOPIC), 1, "the cause is in the closing transaction");
        assertEq(_countFrom(closing, address(a), SYNC_FAILED_TOPIC), 1, "and the clone announced the drift");
        assertEq(_countAnywhere(closing, STATUS_TOPIC), 0, "the diamond's status is not in it");

        vm.clearMockedCalls();

        vm.recordLogs();
        vm.prank(stranger);
        a.syncRegistry();
        Vm.Log[] memory repair = vm.getRecordedLogs();

        (Vm.Log memory st, bool okStatus) = _findFrom(repair, address(diamond), STATUS_TOPIC);
        assertTrue(okStatus, "the repair carries the status");
        _assertCompletedStatus(st, address(a));

        assertEq(
            _countAnywhere(repair, RELEASED_TOPIC), 0,
            "the repair must claim no cause: 'unknown' is the only honest reading of it"
        );
        assertEq(
            _countAnywhere(repair, AUTO_APPROVED_TOPIC), 0,
            "and it must not claim the other one either"
        );
    }

    // ============================================================
    //  5. Nobody else may say either word
    // ============================================================

    /// Both readers scope the pair by CLONE ADDRESS and by nothing else -- not
    /// by status, not by function. So a third exit that emitted `Released`
    /// would have a refunded or arbitrated deal read as "the client confirmed
    /// and paid".
    ///
    /// Three exits, one scene, because the statement is about the pair being
    /// exclusive to two doors and not about any one of the three.
    function testNoOtherExitEverSaysEitherWord() public {
        // Activation timeout -> REFUNDED
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);
        vm.recordLogs();
        vm.prank(client);
        a.triggerActivationTimeout();
        Vm.Log[] memory l1 = vm.getRecordedLogs();
        assertEq(_countAnywhere(l1, RELEASED_TOPIC), 0, "an activation timeout is not a release");
        assertEq(_countAnywhere(l1, AUTO_APPROVED_TOPIC), 0, "an activation timeout is not the clock");

        // Deadline timeout -> REFUNDED
        (Agreement b, ) = _hireThroughJobBoard(AMOUNT);
        _activate(b);
        vm.warp(block.timestamp + DEADLINE * 1 days + DEADLINE_GRACE + 1);
        vm.recordLogs();
        vm.prank(executor);
        b.triggerDeadlineTimeout();
        Vm.Log[] memory l2 = vm.getRecordedLogs();
        assertEq(_countAnywhere(l2, RELEASED_TOPIC), 0, "a deadline timeout is not a release");
        assertEq(_countAnywhere(l2, AUTO_APPROVED_TOPIC), 0, "a deadline timeout is not the clock");

        // Arbitrated verdict for the executor -> RESOLVED, and the executor is
        // paid the pot. Paid, and still not a release.
        (Agreement c, ) = _hireThroughJobBoard(AMOUNT);
        _activate(c);
        vm.prank(client);
        c.raiseDispute();
        _claimByArbiter(c);
        vm.recordLogs();
        _submitAndFinalize(c, false);
        Vm.Log[] memory l3 = vm.getRecordedLogs();
        assertEq(_countAnywhere(l3, RELEASED_TOPIC), 0, "a verdict is not a release");
        assertEq(_countAnywhere(l3, AUTO_APPROVED_TOPIC), 0, "a verdict is not the clock");
        assertEq(uint8(c.status()), uint8(Agreement.Status.RESOLVED), "precondition: the deal really resolved");
    }
}
