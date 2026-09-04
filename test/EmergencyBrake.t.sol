// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BoardsFixture.sol";
import "../src/Agreement.sol";

/// Tests for the emergency brake (decision 17, docs/DECISIONS.md).
///
/// The brake is a self-expiring hold on the doors where money ENTERS the
/// protocol. Three properties carry the whole design, and each one is a way the
/// brake could be wrong rather than merely absent:
///
///   1. pressed  -> no new money comes in, by ANY door;
///   2. pressed  -> money already inside can still leave, and a deal that
///                  already exists runs to payout untouched;
///   3. pressed  -> it lets go BY ITSELF, with nobody calling anything.
///
/// (2) is the half that is easy to get wrong and impossible to notice: a brake
/// that also traps the money it stopped is not a brake, it is the accident. So
/// the exits here are asserted by BALANCE, never by "it did not revert" — a
/// call can return successfully and still move nothing.
contract EmergencyBrakeTest is BoardsFixture {
    // Local mirrors of the facet's events. `vm.expectEmit` matches on topics and
    // data, so a mirror declaration is how a test names an event it does not own.
    event NewDealsPaused(address indexed by, uint256 until);
    event NewDealsResumed(address indexed by);

    /// The advertised hold. NOT hardcoded as `72 hours` in the assertions
    /// below: it is read back off the chain through the public constant, so
    /// that changing the duration in the facet moves the tests with it instead
    /// of turning them red for the wrong reason. The one place the literal
    /// appears is `testDurationIsSeventyTwoHours`, which is the test whose
    /// whole job is to pin the number the owner named.
    uint256 brake;

    function setUp() public override {
        super.setUp();
        brake = FactoryFacet(address(diamond)).NEW_DEALS_PAUSE_DURATION();
    }

    // ============================================================
    //  HELPERS
    // ============================================================

    function _press() internal {
        // owner == address(this) in this fixture, so no prank.
        FactoryFacet(address(diamond)).pauseNewDeals();
    }

    function _until() internal view returns (uint256) {
        return FactoryFacet(address(diamond)).newDealsPausedUntil();
    }

    /// A pair of funded, fully-approved strangers. Fresh actors per scenario
    /// because the registry refuses a second live deal between the same two
    /// people (`hasActivePair`) — reusing `client`/`executor` across the doors
    /// would make some of them revert with ActiveDealExists and quietly stop
    /// testing the brake at all.
    function _freshPair(uint256 salt) internal returns (address c, address e) {
        c = address(uint160(0x10000 + salt));
        e = address(uint160(0x20000 + salt));
        usdc.mint(c, 1_000_000_000);
        usdc.mint(e, 1_000_000_000);
        vm.prank(c);
        usdc.approve(address(diamond), type(uint256).max);
        vm.prank(e);
        usdc.approve(address(diamond), type(uint256).max);
    }

    function _mintJobAs(address c) internal returns (uint256 jobId) {
        vm.prank(c);
        jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION
        );
    }

    function _mintServiceAs(address e) internal returns (uint256 serviceId) {
        vm.prank(e);
        serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION
        );
    }

    function _requestAs(address c, uint256 serviceId) internal returns (uint256 requestId) {
        vm.prank(c);
        requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, AMOUNT, DEADLINE, TERMS, REGION
        );
    }

    /// The full set of entrances, exercised for real (not just "did not
    /// revert"): every one of them is expected to SUCCEED. Used to prove the
    /// protocol is open both before the press and after the brake has let go of
    /// its own accord.
    ///
    /// Every door gets its own fresh pair, so a success on one cannot block a
    /// success on the next through the active-pair rule.
    function _assertEveryEntranceOpen(uint256 salt) internal {
        (address c1, address e1) = _freshPair(salt + 1);
        uint256 j1 = _mintJobAs(c1);
        vm.prank(e1);
        JobBoardFacet(address(diamond)).applyForJob(j1);
        vm.prank(c1);
        address agr1 = JobBoardFacet(address(diamond)).acceptApplicant(j1, e1);
        assertTrue(agr1 != address(0), "acceptApplicant produced no agreement");

        // editJob: a separate job, because editing is refused once anybody has applied.
        (address c2, ) = _freshPair(salt + 2);
        uint256 j2 = _mintJobAs(c2);
        vm.prank(c2);
        JobBoardFacet(address(diamond)).editJob(j2, "Edited", "Edited body", DEADLINE, TERMS, REGION);

        // mintJobWithPermit: the mock's permit only sets an allowance, so the
        // signature fields are zeroes — the same idiom the other board tests use.
        (address c3, ) = _freshPair(salt + 3);
        JobBoardFacet(address(diamond)).mintJobWithPermit(
            c3, "Permit job", "body", AMOUNT, DEADLINE, TERMS, REGION,
            block.timestamp + 1 days, 0, bytes32(0), bytes32(0)
        );

        (address c4, address e4) = _freshPair(salt + 4);
        uint256 s4 = _mintServiceAs(e4);
        uint256 r4 = _requestAs(c4, s4);
        vm.prank(e4);
        address agr4 = ServiceBoardFacet(address(diamond)).acceptRequest(r4);
        assertTrue(agr4 != address(0), "acceptRequest produced no agreement");

        (, address e5) = _freshPair(salt + 5);
        uint256 s5 = _mintServiceAs(e5);
        vm.prank(e5);
        ServiceBoardFacet(address(diamond)).editService(s5, "Edited", "Edited body", AMOUNT, DEADLINE, REGION);

        (, address e6) = _freshPair(salt + 6);
        ServiceBoardFacet(address(diamond)).mintServiceWithPermit(
            e6, "Permit service", "body", AMOUNT, DEADLINE, REGION,
            block.timestamp + 1 days, 0, bytes32(0), bytes32(0)
        );

        (address c7, address e7) = _freshPair(salt + 7);
        uint256 s7 = _mintServiceAs(e7);
        ServiceBoardFacet(address(diamond)).requestServiceWithPermit(
            c7, s7, AMOUNT, DEADLINE, TERMS, REGION,
            block.timestamp + 1 days, 0, bytes32(0), bytes32(0)
        );

        // The factory's own direct-hire door, called by the client himself.
        (address c8, address e8) = _freshPair(salt + 8);
        vm.prank(c8);
        address agr8 = FactoryFacet(address(diamond)).deployAndFund(
            c8, e8, AMOUNT, DEADLINE, TERMS, REGION
        );
        assertTrue(agr8 != address(0), "deployAndFund produced no agreement");
    }

    // ============================================================
    //  1. PRESSED — NO MONEY COMES IN, BY ANY DOOR
    // ============================================================
    //
    // Eleven doors carry the gate: nine on the two boards through
    // `whenNotPaused`, plus the factory's own `deployAndFund` and
    // `deployAgreement`. Each one gets its own test, so a red run names the
    // door rather than "the brake is broken somewhere".

    function testBrakeShutsMintJob() public {
        (address c, ) = _freshPair(100);
        _press();
        vm.prank(c);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION
        );
    }

    function testBrakeShutsMintJobWithPermit() public {
        (address c, ) = _freshPair(101);
        _press();
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        JobBoardFacet(address(diamond)).mintJobWithPermit(
            c, "Permit job", "body", AMOUNT, DEADLINE, TERMS, REGION,
            block.timestamp + 1 days, 0, bytes32(0), bytes32(0)
        );
    }

    function testBrakeShutsAcceptApplicant() public {
        (address c, address e) = _freshPair(102);
        uint256 jobId = _mintJobAs(c);
        vm.prank(e);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        _press();

        vm.prank(c);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, e);
    }

    function testBrakeShutsEditJob() public {
        (address c, ) = _freshPair(103);
        uint256 jobId = _mintJobAs(c);
        _press();
        vm.prank(c);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        JobBoardFacet(address(diamond)).editJob(jobId, "Edited", "body", DEADLINE, TERMS, REGION);
    }

    function testBrakeShutsMintService() public {
        (, address e) = _freshPair(104);
        _press();
        vm.prank(e);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        ServiceBoardFacet(address(diamond)).mintService(
            "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION
        );
    }

    function testBrakeShutsMintServiceWithPermit() public {
        (, address e) = _freshPair(105);
        _press();
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        ServiceBoardFacet(address(diamond)).mintServiceWithPermit(
            e, "Permit service", "body", AMOUNT, DEADLINE, REGION,
            block.timestamp + 1 days, 0, bytes32(0), bytes32(0)
        );
    }

    function testBrakeShutsEditService() public {
        (, address e) = _freshPair(106);
        uint256 serviceId = _mintServiceAs(e);
        _press();
        vm.prank(e);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        ServiceBoardFacet(address(diamond)).editService(
            serviceId, "Edited", "body", AMOUNT, DEADLINE, REGION
        );
    }

    function testBrakeShutsRequestService() public {
        (address c, address e) = _freshPair(107);
        uint256 serviceId = _mintServiceAs(e);
        _press();
        vm.prank(c);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
    }

    function testBrakeShutsRequestServiceWithPermit() public {
        (address c, address e) = _freshPair(108);
        uint256 serviceId = _mintServiceAs(e);
        _press();
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        ServiceBoardFacet(address(diamond)).requestServiceWithPermit(
            c, serviceId, AMOUNT, DEADLINE, TERMS, REGION,
            block.timestamp + 1 days, 0, bytes32(0), bytes32(0)
        );
    }

    function testBrakeShutsAcceptRequest() public {
        (address c, address e) = _freshPair(109);
        uint256 serviceId = _mintServiceAs(e);
        uint256 requestId = _requestAs(c, serviceId);
        _press();
        vm.prank(e);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
    }

    function testBrakeShutsDeployAndFund() public {
        (address c, address e) = _freshPair(110);
        _press();
        vm.prank(c);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        FactoryFacet(address(diamond)).deployAndFund(c, e, AMOUNT, DEADLINE, TERMS, REGION);
    }

    /// Not a door a person can knock on: `deployAgreement` refuses anything but
    /// a call from the diamond to itself (`msg.sender != address(this)` ->
    /// NotDiamond), so the only callers it will ever have are the two boards,
    /// and both of them are stopped by `whenNotPaused` before they get here.
    ///
    /// This test pins that fact rather than the gate. It is the honest record
    /// of why the gate inside `deployAgreement` cannot be shown to fire: it is
    /// defence in depth against a FUTURE facet, and no test on today's tree can
    /// distinguish it from a no-op. See the report accompanying this file.
    function testDeployAgreementIsUnreachableFromOutside() public {
        (address c, address e) = _freshPair(111);
        vm.prank(c);
        vm.expectRevert(FactoryFacet.NotDiamond.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            c, e, address(0), AMOUNT, DEADLINE, TERMS, REGION
        );
    }

    /// The three `FactoryPaused` declarations (factory + both boards) are
    /// deliberately one selector, so the relayer's decode table and the
    /// fourteen locales keep working on the factory's new door. If somebody
    /// renames one of them, the person hitting that door starts getting a hex
    /// string instead of a sentence — and nothing else in the suite would say so.
    function testAllThreeFactoryPausedErrorsAreOneSelector() public pure {
        assertEq(
            bytes32(JobBoardFacet.FactoryPaused.selector),
            bytes32(FactoryFacet.FactoryPaused.selector),
            "JobBoard.FactoryPaused drifted from Factory.FactoryPaused"
        );
        assertEq(
            bytes32(ServiceBoardFacet.FactoryPaused.selector),
            bytes32(FactoryFacet.FactoryPaused.selector),
            "ServiceBoard.FactoryPaused drifted from Factory.FactoryPaused"
        );
        assertEq(
            bytes32(FactoryFacet.FactoryPaused.selector),
            bytes32(bytes4(0x68c2f226)),
            "FactoryPaused selector is no longer 0x68c2f226"
        );
    }

    // ============================================================
    //  2. PRESSED — EVERY EXIT STAYS OPEN
    // ============================================================
    //
    // Asserted by BALANCE. "It did not revert" is not the property: a refund
    // path that returns cleanly and moves nothing would pass that and fail the
    // people it was written for.

    function testCancelJobRefundsWhileBraked() public {
        (address c, ) = _freshPair(200);
        uint256 jobId = _mintJobAs(c);

        _press();

        uint256 clientBefore = usdc.balanceOf(c);
        uint256 diamondBefore = usdc.balanceOf(address(diamond));

        vm.prank(c);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        assertGt(usdc.balanceOf(c), clientBefore, "cancelJob returned nothing while braked");
        assertLt(
            usdc.balanceOf(address(diamond)),
            diamondBefore,
            "money did not leave the diamond on cancelJob while braked"
        );
        // The principal comes back whole; only the floor is kept.
        assertEq(
            usdc.balanceOf(c) - clientBefore,
            AMOUNT + JOB_FEE - JOB_FLOOR,
            "refund is not amount + fee - floor"
        );
    }

    function testCancelRequestRefundsWhileBraked() public {
        (address c, address e) = _freshPair(201);
        uint256 serviceId = _mintServiceAs(e);
        uint256 requestId = _requestAs(c, serviceId);

        _press();

        uint256 clientBefore = usdc.balanceOf(c);
        uint256 diamondBefore = usdc.balanceOf(address(diamond));

        vm.prank(c);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId);

        assertGt(usdc.balanceOf(c), clientBefore, "cancelRequest returned nothing while braked");
        assertLt(
            usdc.balanceOf(address(diamond)),
            diamondBefore,
            "money did not leave the diamond on cancelRequest while braked"
        );
    }

    function testRejectRequestRefundsWhileBraked() public {
        (address c, address e) = _freshPair(202);
        uint256 serviceId = _mintServiceAs(e);
        uint256 requestId = _requestAs(c, serviceId);

        _press();

        uint256 clientBefore = usdc.balanceOf(c);
        uint256 diamondBefore = usdc.balanceOf(address(diamond));

        vm.prank(e);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId);

        assertGt(usdc.balanceOf(c), clientBefore, "rejectRequest returned nothing while braked");
        assertLt(
            usdc.balanceOf(address(diamond)),
            diamondBefore,
            "money did not leave the diamond on rejectRequest while braked"
        );
    }

    /// Withdrawing an application moves no money — nothing was staked to apply.
    /// Kept in the exit set because the owner named it, and asserted on STATE
    /// for exactly that reason: a balance assertion here would be theatre.
    function testWithdrawApplicationWorksWhileBraked() public {
        (address c, address e) = _freshPair(203);
        uint256 jobId = _mintJobAs(c);
        vm.prank(e);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        assertEq(JobBoardFacet(address(diamond)).getApplicants(jobId).length, 1, "did not apply");

        _press();

        vm.prank(e);
        JobBoardFacet(address(diamond)).withdrawApplication(jobId);
        assertEq(
            JobBoardFacet(address(diamond)).getApplicants(jobId).length,
            0,
            "withdrawApplication did not remove the applicant while braked"
        );
    }

    /// Taking a listing down moves no money either (the listing fee was spent
    /// at mint and is not refundable). Asserted on state, same reason as above.
    function testRemoveServiceWorksWhileBraked() public {
        (, address e) = _freshPair(204);
        uint256 serviceId = _mintServiceAs(e);

        _press();

        vm.prank(e);
        ServiceBoardFacet(address(diamond)).removeService(serviceId);
        assertTrue(
            ServiceBoardFacet(address(diamond)).getService(serviceId).status
                != ServiceBoardStorage.ServiceStatus.ACTIVE,
            "removeService left the listing active while braked"
        );
    }

    // ============================================================
    //  3. A DEAL THAT ALREADY EXISTS DOES NOT NOTICE THE BRAKE
    // ============================================================

    /// The owner's actual fear, written down as a test: press the brake in the
    /// middle of somebody's job and see whether they still get paid.
    ///
    /// The deal is born BEFORE the press and runs the whole way to payout
    /// AFTER it — activate, markDone, release — with the brake down the entire
    /// time. Measured on the executor's wallet, because "the calls succeeded"
    /// is not what the executor cares about.
    function testLiveDealRunsToPayoutWhileBraked() public {
        (address c, address e) = _freshPair(300);
        uint256 jobId = _mintJobAs(c);
        vm.prank(e);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(c);
        Agreement agreement = Agreement(JobBoardFacet(address(diamond)).acceptApplicant(jobId, e));

        _press();
        assertTrue(_until() > block.timestamp, "brake is not actually down");

        uint256 executorBefore = usdc.balanceOf(e);
        assertEq(usdc.balanceOf(address(agreement)), AMOUNT, "escrow did not hold the amount");

        vm.prank(e);
        agreement.activate();
        vm.prank(e);
        agreement.markDone();
        vm.prank(c);
        agreement.release();

        // Still braked when the money landed — not released half-way through.
        assertTrue(_until() > block.timestamp, "the brake let go during the deal");

        assertEq(
            usdc.balanceOf(e) - executorBefore,
            AMOUNT,
            "executor was not paid in full while the brake was down"
        );
        assertEq(usdc.balanceOf(address(agreement)), 0, "escrow did not empty while braked");
    }

    // ============================================================
    //  4. IT LETS GO BY ITSELF
    // ============================================================

    /// No call between the press and the reopening — only time passing. This is
    /// the property a bool cannot have, and the reason the field is a timestamp.
    function testBrakeLetsGoByItselfWithNobodyCallingAnything() public {
        _press();
        uint256 until_ = _until();

        vm.warp(until_ + 1);

        // Nothing has been called on the brake in between. The only thing that
        // happened is that time passed.
        _assertEveryEntranceOpen(400);
    }

    /// The boundary, recorded as the code actually behaves rather than as
    /// anyone hoped. The predicate is `block.timestamp < until`, so at EXACTLY
    /// `until` the comparison is already false and the protocol is already
    /// open; the last braked instant is `until - 1`.
    function testBoundaryOpensAtExactlyTheDeadlineNotAfterIt() public {
        (address cBefore, ) = _freshPair(401);
        _press();
        uint256 until_ = _until();

        // One second before the deadline: still shut.
        vm.warp(until_ - 1);
        vm.prank(cBefore);
        vm.expectRevert(FactoryFacet.FactoryPaused.selector);
        JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION
        );

        // Exactly at the deadline: already open, because the test is strict `<`.
        vm.warp(until_);
        (address cAt, ) = _freshPair(402);
        uint256 jobId = _mintJobAs(cAt);
        assertEq(jobId, JobBoardFacet(address(diamond)).totalJobs() - 1, "mintJob did not go through at exactly `until`");
    }

    function testUntilIsNowPlusTheAdvertisedDuration() public {
        _press();
        assertEq(_until(), block.timestamp + brake, "until is not now + the advertised duration");
    }

    /// The number the owner named on 3 September 2026, pinned once so that
    /// changing it is a deliberate act with a red test attached.
    function testDurationIsSeventyTwoHours() public view {
        assertEq(
            FactoryFacet(address(diamond)).NEW_DEALS_PAUSE_DURATION(),
            72 hours,
            "the advertised hold is no longer 72 hours"
        );
    }

    /// Zero is the state of the live diamond on the day the field appears, and
    /// it has to read as "not braked" — otherwise the upgrade itself would
    /// freeze the protocol.
    function testUnpressedDiamondReadsAsOpen() public {
        assertEq(_until(), 0, "a fresh diamond is not at zero");
        _assertEveryEntranceOpen(450);
    }

    // ============================================================
    //  5. EARLY RELEASE
    // ============================================================

    function testResumeReopensAndZeroesTheClock() public {
        _press();
        assertGt(_until(), 0, "brake did not go down");

        FactoryFacet(address(diamond)).resumeNewDeals();

        assertEq(_until(), 0, "resume left a non-zero clock");
        _assertEveryEntranceOpen(500);
    }

    /// Releasing a brake that is not down is a no-op, not a revert: the owner
    /// reaching for the release in an emergency must not have to first find out
    /// whether he needs it.
    function testResumeOnAnOpenProtocolIsHarmless() public {
        assertEq(_until(), 0, "precondition: not braked");
        FactoryFacet(address(diamond)).resumeNewDeals();
        assertEq(_until(), 0, "resume on an open protocol changed something");
    }

    // ============================================================
    //  6. WHO MAY PRESS
    // ============================================================

    function testStrangerCannotPress() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).pauseNewDeals();
    }

    function testStrangerCannotRelease() public {
        _press();
        vm.prank(address(0xBAD));
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).resumeNewDeals();
    }

    /// Decision 17 says it outright: the brake stops the whole marketplace, and
    /// the arbiter chief is a role invented to run the arbiter corps — it does
    /// not reach this far.
    ///
    /// `protocolArbiter` has no setter on FactoryFacet, so it is seated
    /// directly in its slot. The offset is not taken on trust: the write is
    /// read back before it is used, the same discipline `_unconfigureFeeModel`
    /// uses on the fee-model slots.
    function testProtocolArbiterCannotPressOrRelease() public {
        address arbiter = address(0xA2B1);
        bytes32 slot = bytes32(uint256(FactoryStorage.FACTORY_STORAGE_POSITION) + 5);
        vm.store(address(diamond), slot, bytes32(uint256(uint160(arbiter))));
        assertEq(
            address(uint160(uint256(vm.load(address(diamond), slot)))),
            arbiter,
            "protocolArbiter slot offset drifted"
        );

        vm.prank(arbiter);
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).pauseNewDeals();

        _press();
        vm.prank(arbiter);
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).resumeNewDeals();
    }

    /// A stranger's failed press must leave the protocol exactly as it was —
    /// neither braked nor, if it was braked, released.
    function testRefusedPressChangesNothing() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).pauseNewDeals();
        assertEq(_until(), 0, "a refused press moved the clock");
    }

    // ============================================================
    //  7. A SECOND PRESS IS A FRESH HOLD, NOT AN EXTENSION
    // ============================================================

    /// Pressing again while the brake is already down restarts the full
    /// duration from NOW. It does not add to what is left — otherwise two
    /// presses would buy six days, and the brake could be stacked out to a year
    /// in a handful of transactions, which is exactly the "quietly freeze it
    /// forever" that decision 17 rejects.
    function testSecondPressIsFreshDurationNotAnExtension() public {
        _press();
        uint256 firstUntil = _until();

        vm.warp(block.timestamp + 40 hours);
        _press();

        assertEq(_until(), block.timestamp + brake, "second press is not a fresh full hold from now");
        // And specifically NOT the leftover plus another full duration.
        uint256 wouldBeIfItAccumulated = firstUntil + brake;
        assertTrue(_until() != wouldBeIfItAccumulated, "second press accumulated onto the remainder");
        assertLt(_until(), wouldBeIfItAccumulated, "second press extended rather than restarted");
    }

    // ============================================================
    //  8. EVERY PRESS IS IN THE LOG
    // ============================================================
    //
    // The self-expiry only stops "press and forget" if holding the brake longer
    // costs a signed, logged transaction each time. That makes the log the
    // record of how long the protocol was braked — so a press that emitted
    // nothing would quietly break the guarantee without breaking anything else.

    function testPressIsLogged() public {
        uint256 expectedUntil = block.timestamp + brake;
        vm.expectEmit(true, false, false, true, address(diamond));
        emit NewDealsPaused(address(this), expectedUntil);
        FactoryFacet(address(diamond)).pauseNewDeals();
    }

    function testPressOnTopOfAPressIsAlsoLogged() public {
        _press();
        vm.warp(block.timestamp + 40 hours);

        uint256 expectedUntil = block.timestamp + brake;
        vm.expectEmit(true, false, false, true, address(diamond));
        emit NewDealsPaused(address(this), expectedUntil);
        FactoryFacet(address(diamond)).pauseNewDeals();
    }

    function testReleaseIsLogged() public {
        _press();
        vm.expectEmit(true, false, false, true, address(diamond));
        emit NewDealsResumed(address(this));
        FactoryFacet(address(diamond)).resumeNewDeals();
    }
}
