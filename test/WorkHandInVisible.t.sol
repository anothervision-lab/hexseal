// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  The hand-in, seen from the diamond
// ============================================================
//
// markDone() used to touch the diamond not at all. It stamped `_markedDoneAt`
// on the clone and emitted `MarkedDone` there, and that was the whole of it.
//
// WHY THAT IS A MONEY PROBLEM AND NOT A COSMETIC ONE. markDone() starts
// AUTO_APPROVE_WINDOW. When the window closes, triggerAutoApprove() pays the
// executor the ENTIRE pot through a door open to anyone, the executor
// included. So the client has two days to look, and the transition that starts
// those two days was emitted at an address nothing watches: the one standing
// chain observer the web client keeps is pinned to the DIAMOND, and the
// subgraph does not index `MarkedDone` either. A client who was on another
// page when the work arrived found out by opening the deal, or did not find
// out.
//
// WHERE THE EXPECTED VALUES COME FROM. The oracle here is the diamond's own
// log stream and the registry record read back through the proxy -- never the
// clone's opinion of itself, and never a value derived from the code under
// test. `vm.expectEmit` is pointed at `address(diamond)` explicitly in every
// scene, because an event emitted by the clone at the clone's address would
// satisfy a check that did not name the emitter, and the clone already emitted
// one before this change: a lock that let the old behaviour pass is not a lock.

import "./MoneyPathBase.sol";
import "../src/MinimalForwarder.sol";

contract WorkHandInVisibleTest is MoneyPathBase {
    /// Re-declared here rather than imported, so the expectation is a shape
    /// written down by a person. Importing the event from the facet under test
    /// would let a change of its parameters move the expectation with it.
    event WorkHandedIn(
        address indexed agreement,
        address indexed client,
        address indexed executor
    );

    event MarkedDone(address indexed executor);

    MinimalForwarder forwarder;

    uint256 constant EXECUTOR_PK = 0xE8EC0;
    address executorSigner;

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    function setUp() public override {
        super.setUp();

        // A REAL forwarder, not the 0xDEAD placeholder the base fixture uses.
        // The scar this guards is `fundDispute` reading raw msg.sender: a test
        // that calls the facet directly cannot see that bug, because msg.sender
        // and the real sender are the same address in a direct call. Only a
        // relayed call tells them apart.
        forwarder = new MinimalForwarder();
        vm.prank(owner);
        FactoryFacet(address(diamond)).setTrustedForwarder(address(forwarder));

        executorSigner = vm.addr(EXECUTOR_PK);
    }

    // ------------------------------------------------------------
    //  Helpers
    // ------------------------------------------------------------

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

    // ------------------------------------------------------------
    //  1. The lock this whole change exists for
    // ------------------------------------------------------------

    /// THE DESIGNATED LOCK. Hire for real through the job board, activate, hand
    /// in -- and the DIAMOND must say so.
    ///
    /// The emitter is asserted, not just the event: `MarkedDone` on the clone
    /// has been emitted since the first version of this contract, so a check
    /// that only asked "did a log appear" would have been green before the fix
    /// and after it alike.
    function testTheHandInIsAnnouncedOnTheDiamond() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit WorkHandedIn(address(a), client, executor);

        vm.prank(executor);
        a.markDone();

        assertEq(a.markedDoneAt(), block.timestamp, "and the clone still holds the timestamp");
    }

    /// The clone keeps saying it too. The diamond's announcement is an
    /// addition, not a replacement: `useDealLiveRefresh` watches the clone for
    /// exactly this event, and dropping it would break the open deal page to
    /// fix the bell.
    function testTheCloneStillAnnouncesItToo() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        vm.expectEmit(true, true, true, true, address(a));
        emit MarkedDone(executor);

        vm.prank(executor);
        a.markDone();
    }

    // ------------------------------------------------------------
    //  2. The gasless path, which is the one people actually use
    // ------------------------------------------------------------

    /// Through a REAL MinimalForwarder. If markDone() or the facet behind it
    /// ever read raw `msg.sender`, this is the only scene in the file that
    /// would notice: in a direct call the forwarder and the human are the same
    /// address, and the bug hides.
    ///
    /// The executor here is a signing key, not the fixture's plain address, so
    /// the deal is hired against that key from the start.
    function testTheHandInIsAnnouncedWhenItArrivesThroughTheForwarder() public {
        vm.prank(client);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(executorSigner);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(client);
        Agreement a = Agreement(JobBoardFacet(address(diamond)).acceptApplicant(jobId, executorSigner));

        assertEq(a.trustedForwarder(), address(forwarder), "precondition: the clone trusts the real forwarder");

        (bool ok1, ) = _relay(EXECUTOR_PK, address(a), abi.encodeWithSignature("activate()"));
        assertTrue(ok1, "activate through the forwarder");

        vm.expectEmit(true, true, true, true, address(diamond));
        emit WorkHandedIn(address(a), client, executorSigner);

        (bool ok2, ) = _relay(EXECUTOR_PK, address(a), abi.encodeWithSignature("markDone()"));
        assertTrue(ok2, "markDone through the forwarder");

        assertEq(a.markedDoneAt(), block.timestamp, "and the hand-in landed");
    }

    // ------------------------------------------------------------
    //  3. Nobody else may say it
    // ------------------------------------------------------------

    /// The door names its caller and nothing else, so there is no argument for
    /// a stranger to point at somebody else's deal. A plain address is not in
    /// the registry and is refused by name.
    function testAStrangerCannotAnnounceAHandIn() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        vm.prank(stranger);
        vm.expectRevert(RegistryFacet.AgreementNotRegistered.selector);
        RegistryFacet(address(diamond)).notifyWorkHandedIn();

        // And the client is no more privileged than the stranger.
        vm.prank(client);
        vm.expectRevert(RegistryFacet.AgreementNotRegistered.selector);
        RegistryFacet(address(diamond)).notifyWorkHandedIn();

        assertEq(a.markedDoneAt(), 0, "nothing was handed in");
    }

    /// THE REASON THE EVENT IS ITS OWN, made measurable.
    ///
    /// The cheap design was to have markDone() call the existing
    /// `updateStatus(agreement, ACTIVE)` and let the observer read ACTIVE as
    /// "handed in" -- no new selector, no cut. This scene is why that would
    /// have been a forgery: `syncRegistry()` is callable BY ANYONE, takes no
    /// arguments and pushes exactly ACTIVE for any live deal. A stranger could
    /// have rung the client's "your work has arrived" bell on demand.
    ///
    /// So: a stranger pushes the sync, the registry emits its ACTIVE status
    /// update, and NO hand-in is announced.
    function testAStrangerPushingSyncRegistryCannotForgeAHandIn() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        vm.recordLogs();
        vm.prank(stranger);
        a.syncRegistry();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 handIn = keccak256("WorkHandedIn(address,address,address)");
        bytes32 statusUpdated = keccak256("AgreementStatusUpdated(address,uint8)");

        bool sawStatus;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == statusUpdated) sawStatus = true;
            assertTrue(logs[i].topics[0] != handIn, "a stranger forged a hand-in");
        }
        assertTrue(sawStatus, "precondition: syncRegistry really does push ACTIVE");
        assertEq(a.markedDoneAt(), 0, "and nothing was handed in");
    }

    // ------------------------------------------------------------
    //  4. The announcement must not become a status change
    // ------------------------------------------------------------

    /// A handed-in deal is still ACTIVE, and the registry must keep saying so.
    ///
    /// This guards the other half of the design: the day somebody "simplifies"
    /// this into a status transition, the pair would drop out of
    /// `activePartyPairs` and `resolvedAt` would be stamped on a deal that has
    /// not resolved -- which frees the pair to open a SECOND deal while the
    /// first still holds the money.
    function testHandingInDoesNotCloseTheDealInTheRegistry() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        vm.prank(executor);
        a.markDone();

        RegistryStorage.AgreementRecord memory rec =
            RegistryFacet(address(diamond)).getRecord(address(a));

        assertEq(uint8(rec.status), uint8(RegistryStorage.AgreementStatus.ACTIVE), "still ACTIVE");
        assertEq(rec.resolvedAt, 0, "and not resolved");
        assertTrue(
            RegistryFacet(address(diamond)).hasActivePair(client, executor),
            "the pair is still busy with this deal"
        );
        assertEq(
            RegistryFacet(address(diamond)).getActivePair(client, executor),
            address(a),
            "and it is this deal"
        );
    }

    // ------------------------------------------------------------
    //  5. The announcement may never cost the executor the hand-in
    // ------------------------------------------------------------

    /// A clone is nailed to its implementation for life. If the diamond cannot
    /// take the announcement -- cut in the wrong order, selector removed, facet
    /// reverting -- markDone() must still work, or every deal born from this
    /// implementation would be unable to hand work in at all.
    ///
    /// The refusal is fed in from OUTSIDE the contract under test: the diamond
    /// is made to revert on that one selector.
    function testAHandInGoesThroughEvenWhenTheDiamondRefusesToHearIt() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        vm.mockCallRevert(
            address(diamond),
            abi.encodeWithSelector(RegistryFacet.notifyWorkHandedIn.selector),
            "no"
        );

        vm.prank(executor);
        a.markDone();

        assertEq(a.markedDoneAt(), block.timestamp, "the hand-in landed anyway");
        assertEq(uint8(a.status()), uint8(Agreement.Status.ACTIVE), "and the deal is still live");

        // And the deal still finishes normally afterwards, which is the point:
        // the executor is not left holding a deal that cannot be closed.
        vm.clearMockedCalls();
        uint256 before = usdc.balanceOf(executor);
        vm.prank(client);
        a.release();
        assertEq(usdc.balanceOf(executor) - before, AMOUNT, "and the money still moved");
    }

    /// The same tolerance against a diamond with no code at all -- the shape
    /// `_diamondHasCode()` exists for, and the one a clone deployed against a
    /// dead address would be in.
    function testAHandInGoesThroughWhenTheDiamondHasNoCodeAtAll() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);
        _activate(a);

        vm.etch(address(diamond), "");

        vm.prank(executor);
        a.markDone();

        assertEq(a.markedDoneAt(), block.timestamp, "the hand-in landed anyway");
    }
}
