// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BoardsFixture.sol";
import "../src/Agreement.sol";

// ============================================================
// DeadlineCap.t.sol — a direct-hire deal cannot be created with a deadline
// that outlives arithmetic.
//
// The shape-before-mainnet audit of 26 August 2026, form A.
//
// `deadlineDays` used to be a raw uint256 in the clone, used in exactly one
// shape, six times over: `activatedAt + (deadlineDays * 1 days)`. Both boards
// refuse anything above 365 at post time. Direct hire refused nothing but
// zero — so a client could hand the factory type(uint256).max, and every door
// out of the funded, activated deal that touches that sum reverted with
// Panic 0x11 while the ones that do not touch it refused for their own,
// unrelated reasons. Seven doors, no exit, and no rescuer by construction.
//
// ⚠️ THE CLONE-LEVEL SCENE IS GONE, AND THAT IS THE POINT. On 28 August 2026
// the field was narrowed to uint16 as part of packing the deal's state into
// one slot (the same audit, form B), and
// initialize() now refuses anything above 65_535 by name. The trapped deal
// this file used to build — a clone with type(uint256).max days, made without
// the factory — CANNOT BE BUILT any more, at any level. What stood here as a
// scene of seven shut doors is therefore replaced by two things: the refusal
// itself, and the widest deal the field still allows, walked through the same
// doors to show they answer instead of overflowing.
//
// The overflow is now impossible by arithmetic rather than by policy: at the
// top of both fields the sum is 1_105_173_938_175, forty-one bits. The
// factory's 365-day ceiling stays where it is anyway — it is a product limit,
// not an overflow guard, and it is the one both boards promise.
//
// Two levels, deliberately:
//
//   * DeadlineLockSceneTest is the clone level, with no factory in the way.
//   * DeadlineCapFactoryTest goes through the two front doors a person
//     actually uses, and is the test that goes red if the cap is removed.
//
// Every expected revert is named by selector. An `expectRevert()` with no
// argument passed this suite's first draft for the wrong reason: it caught
// NotParty() thrown at an outsider instead of the Panic it was written for.
// ============================================================

/// Clone level: what used to be the trap, with no factory in the way.
contract DeadlineLockSceneTest is Test {
    Agreement         impl;
    AgreementDeployer cloneDeployer;
    MockUSDCB         usdc;

    address constant CLIENT    = address(0xC11E17);
    address constant EXECUTOR  = address(0xE8EC);
    address constant OUTSIDER  = address(0x0475D);
    address constant DIAMOND   = address(0xD1A);
    address constant FORWARDER = address(0xF04D);

    uint256 constant AMOUNT   = 100_000_000; // $100 USDC
    uint256 constant MAX_DAYS = type(uint16).max; // 65_535 -- the widest the field holds

    function setUp() public {
        impl          = new Agreement();
        cloneDeployer = new AgreementDeployer(address(this), address(impl));
        usdc          = new MockUSDCB();
    }

    function _clone(uint256 deadlineDays) internal returns (Agreement) {
        return Agreement(
            cloneDeployer.deploy(
                CLIENT, EXECUTOR, address(0),
                AMOUNT, deadlineDays, "Standard work terms",
                DIAMOND, address(usdc), FORWARDER, address(this)
            )
        );
    }

    /// The deal the factory used to let through cannot be made at all now,
    /// not even by cloning the implementation by hand. This is the test that
    /// replaces the seven-door scene: there is no trapped deal to walk.
    function testTheTrappedDealCannotBeBuiltAnyMore() public {
        vm.expectRevert(Agreement.DeadlineDaysOverflow.selector);
        _clone(type(uint256).max);
    }

    /// One day past the field, not merely astronomically past it. An
    /// off-by-one in the refusal is the same class of hole as no refusal.
    function testOneDayPastTheFieldIsRefusedToo() public {
        vm.expectRevert(Agreement.DeadlineDaysOverflow.selector);
        _clone(MAX_DAYS + 1);
    }

    /// The widest deal the field DOES hold, walked through the same doors the
    /// trapped one used to blow up on. Every one of them either works or
    /// refuses by its own name; none of them reverts with an arithmetic panic.
    ///
    /// This is the real control on the change. If someone widened the field
    /// again without widening the sum it feeds, or narrowed the sum's
    /// arithmetic back into uint40, this goes red with Panic 0x11 on the very
    /// first line.
    function testTheWidestAllowedDealHasEveryDoorOpen() public {
        Agreement widest = _clone(MAX_DAYS);
        usdc.mint(CLIENT, AMOUNT);

        vm.startPrank(CLIENT);
        usdc.approve(address(widest), AMOUNT);
        widest.fund();
        vm.stopPrank();

        vm.prank(EXECUTOR);
        widest.activate();

        // The read that used to revert with Panic 0x11.
        assertEq(uint256(widest.status()), uint256(Agreement.Status.ACTIVE), "status unreadable");
        assertEq(widest.timeLeft(), MAX_DAYS * 1 days, "timeLeft unreadable");

        // --- the three that touch activatedAt + deadlineDays * 1 days ---
        // The deadline is 179 years out, so the two timeouts refuse BY NAME
        // rather than panicking, and markDone goes through.
        vm.prank(CLIENT);
        vm.expectRevert(Agreement.DeadlineNotPassed.selector);
        widest.triggerDeadlineTimeout();

        vm.prank(CLIENT);
        widest.raiseDispute();          // no panic: the deadline has not passed

        // --- and the four that never touch the sum ---
        vm.prank(CLIENT);
        vm.expectRevert(Agreement.NotMarkedDone.selector);
        widest.release();

        vm.prank(OUTSIDER); // triggerAutoApprove is callable by anyone
        vm.expectRevert(Agreement.NotMarkedDone.selector);
        widest.triggerAutoApprove();

        vm.prank(CLIENT);
        vm.expectRevert(Agreement.AlreadyActive.selector);
        widest.triggerActivationTimeout();

        vm.prank(CLIENT);
        vm.expectRevert(Agreement.WindowNotPassed.selector);
        widest.triggerArbiterTimeout();

        // And the door that IS open: the dispute times out and the money
        // leaves. The whole point of form A was that no such line existed.
        vm.warp(block.timestamp + 5 days);
        vm.prank(CLIENT);
        widest.triggerArbiterTimeout();
        assertEq(usdc.balanceOf(address(widest)), 0, "money never left the escrow");
    }

    /// Control: an ordinary deadline still runs its ordinary course. Without
    /// this, a build where every door reverts always would pass the scenes
    /// above just as happily.
    function testTheSameDealWithASaneDeadlineHasAWayOut() public {
        Agreement sane = _clone(7);
        usdc.mint(CLIENT, AMOUNT);

        vm.startPrank(CLIENT);
        usdc.approve(address(sane), AMOUNT);
        sane.fund();
        vm.stopPrank();

        vm.prank(EXECUTOR);
        sane.activate();

        // The executor never delivers; the deadline plus grace passes.
        vm.warp(block.timestamp + 9 days);

        vm.prank(CLIENT);
        sane.triggerDeadlineTimeout();

        assertEq(usdc.balanceOf(address(sane)), 0, "refund did not leave the escrow");
        assertEq(usdc.balanceOf(CLIENT), AMOUNT, "client did not get the money back");
    }
}

/// Diamond level: the two direct-hire front doors, which are the ones that had
/// no ceiling at all.
contract DeadlineCapFactoryTest is BoardsFixture {
    /// FactoryFacet.deployAgreement — the entrance the boards use on the
    /// diamond itself, so the caller here is the diamond; a wallet is refused
    /// before the deadline is ever looked at.
    /// Remove `deadlineDays > MAX_DEADLINE_DAYS` from it and this goes red.
    function testDeployAgreementWithMaxDeadlineIsRefused() public {
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.DeadlineTooLong.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, type(uint256).max, TERMS, REGION
        );
    }

    /// FactoryFacet.deployAndFund — the gasless twin, with its own copy of the
    /// check. Two doors, two checks: a fix applied to one of them only would
    /// leave this red.
    function testDeployAndFundWithMaxDeadlineIsRefused() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        vm.expectRevert(FactoryFacet.DeadlineTooLong.selector);
        FactoryFacet(address(diamond)).deployAndFund(
            client, executor, AMOUNT, type(uint256).max, TERMS, REGION
        );
        vm.stopPrank();
    }

    /// ⚠️ Not a fantasy number. The refusal has to hold for a deadline that
    /// looks like an ordinary typo — hours typed where days were meant, or a
    /// bot with no upper bound on the field.
    function testDeployAgreementWithAnAbsurdButNonOverflowingDeadlineIsRefused() public {
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.DeadlineTooLong.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, 1_000_000, TERMS, REGION
        );
    }

    /// The zero end still has its own name. Widening the ceiling must not have
    /// swallowed the other refusal.
    function testDeployAgreementWithZeroDeadlineStillSaysZeroDeadline() public {
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.ZeroDeadline.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, 0, TERMS, REGION
        );
    }

    // -------- THE EDGE, NOT THE MIDDLE --------
    //
    // An off-by-one in a ceiling is the same class of hole as no ceiling: it
    // either lets through a value the boards refuse, or it refuses the top
    // value the boards promise. Both ends are pinned.

    function testExactly365DaysIsAcceptedByDeployAgreement() public {
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, 365, TERMS, REGION
        );
        assertTrue(agreementAddr != address(0), "365 days was refused");
        assertEq(Agreement(agreementAddr).deadlineDays(), 365, "deadline not carried through");
    }

    function test366DaysIsRefusedByDeployAgreement() public {
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.DeadlineTooLong.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, 366, TERMS, REGION
        );
    }

    function testExactly365DaysIsAcceptedByDeployAndFund() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        address agreementAddr = FactoryFacet(address(diamond)).deployAndFund(
            client, executor, AMOUNT, 365, TERMS, REGION
        );
        vm.stopPrank();
        assertTrue(agreementAddr != address(0), "365 days was refused");
        assertEq(Agreement(agreementAddr).deadlineDays(), 365, "deadline not carried through");
        assertEq(usdc.balanceOf(agreementAddr), AMOUNT, "escrow was not funded");
    }

    function test366DaysIsRefusedByDeployAndFund() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        vm.expectRevert(FactoryFacet.DeadlineTooLong.selector);
        FactoryFacet(address(diamond)).deployAndFund(
            client, executor, AMOUNT, 366, TERMS, REGION
        );
        vm.stopPrank();
    }

    /// A 365-day deal made through the factory is not the trapped one: the
    /// arithmetic the scene above blew up on resolves, and the deal has a way
    /// out. Without this the whole cap could be `revert always` and every test
    /// above would still be green.
    function testA365DayDealStillHasAWayOut() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        address agreementAddr = FactoryFacet(address(diamond)).deployAndFund(
            client, executor, AMOUNT, 365, TERMS, REGION
        );
        vm.stopPrank();

        Agreement a = Agreement(agreementAddr);
        vm.prank(executor);
        a.activate();

        // The status read that reverted with Panic 0x11 on the trapped deal.
        assertEq(uint256(a.status()), uint256(Agreement.Status.ACTIVE), "status unreadable");

        vm.warp(block.timestamp + 367 days);
        vm.prank(client);
        a.triggerDeadlineTimeout();

        assertEq(usdc.balanceOf(agreementAddr), 0, "money did not leave the escrow");
    }
}

/// The two ceilings that already existed. This change adds a third one in
/// front of them; it must not have loosened either.
contract DeadlineCapBoardsUnchangedTest is BoardsFixture {
    // -------- JOB BOARD --------

    function testMintJobStillRefuses366() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        vm.expectRevert(JobBoardFacet.DeadlineInvalid.selector);
        JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, 366, TERMS, REGION
        );
        vm.stopPrank();
    }

    function testMintJobWithPermitStillRefuses366() public {
        vm.prank(client);
        vm.expectRevert(JobBoardFacet.DeadlineInvalid.selector);
        JobBoardFacet(address(diamond)).mintJobWithPermit(
            client, "Build a dApp", "Need a Solidity dev", AMOUNT, 366, TERMS, REGION,
            block.timestamp + 1 hours, 0, bytes32(0), bytes32(0)
        );
    }

    function testEditJobStillRefuses366() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, 30, TERMS, REGION
        );
        vm.expectRevert(JobBoardFacet.DeadlineInvalid.selector);
        JobBoardFacet(address(diamond)).editJob(
            jobId, "Build a dApp", "Need a Solidity dev", 366, TERMS, REGION
        );
        vm.stopPrank();
    }

    // -------- SERVICE BOARD --------

    function testMintServiceStillRefuses366() public {
        vm.startPrank(executor);
        usdc.approve(address(diamond), type(uint256).max);
        vm.expectRevert(ServiceBoardFacet.DeadlineInvalid.selector);
        ServiceBoardFacet(address(diamond)).mintService(
            "Landing pages", "I build landing pages", AMOUNT, 366, REGION
        );
        vm.stopPrank();
    }

    function testMintServiceWithPermitStillRefuses366() public {
        vm.prank(executor);
        vm.expectRevert(ServiceBoardFacet.DeadlineInvalid.selector);
        ServiceBoardFacet(address(diamond)).mintServiceWithPermit(
            executor, "Landing pages", "I build landing pages", AMOUNT, 366, REGION,
            block.timestamp + 1 hours, 0, bytes32(0), bytes32(0)
        );
    }

    function testEditServiceStillRefuses366() public {
        vm.startPrank(executor);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Landing pages", "I build landing pages", AMOUNT, 30, REGION
        );
        vm.expectRevert(ServiceBoardFacet.DeadlineInvalid.selector);
        ServiceBoardFacet(address(diamond)).editService(
            serviceId, "Landing pages", "I build landing pages", AMOUNT, 366, REGION
        );
        vm.stopPrank();
    }

    function testRequestServiceStillRefuses366() public {
        vm.startPrank(executor);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Landing pages", "I build landing pages", AMOUNT, 30, REGION
        );
        vm.stopPrank();

        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        vm.expectRevert(ServiceBoardFacet.DeadlineInvalid.selector);
        ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, 366, TERMS, REGION);
        vm.stopPrank();
    }

    function testRequestServiceWithPermitStillRefuses366() public {
        vm.startPrank(executor);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Landing pages", "I build landing pages", AMOUNT, 30, REGION
        );
        vm.stopPrank();

        vm.prank(client);
        vm.expectRevert(ServiceBoardFacet.DeadlineInvalid.selector);
        ServiceBoardFacet(address(diamond)).requestServiceWithPermit(
            client, serviceId, AMOUNT, 366, TERMS, REGION,
            block.timestamp + 1 hours, 0, bytes32(0), bytes32(0)
        );
    }

    // -------- THE SEAM --------
    //
    // ⚠️ The board ceiling and the factory ceiling are two different numbers
    // written in two different files, and the board's value only meets the
    // factory's later — at accept time, on a person who has already chosen an
    // applicant and paid. Had the factory been written `>= 365`, everything
    // above would still be green and the top value the board advertises would
    // die on the client's accept. That is what these two measure.

    function testAJobPostedAtTheBoardCeilingSurvivesTheFactoryCeiling() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, 365, TERMS, REGION
        );
        vm.stopPrank();

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        vm.prank(client);
        address agreementAddr = JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
        assertTrue(agreementAddr != address(0), "the board's own maximum died at the factory");
        assertEq(Agreement(agreementAddr).deadlineDays(), 365, "deadline not carried through");
    }

    function testAServiceRequestAtTheBoardCeilingSurvivesTheFactoryCeiling() public {
        vm.startPrank(executor);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Landing pages", "I build landing pages", AMOUNT, 365, REGION
        );
        vm.stopPrank();

        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, AMOUNT, 365, TERMS, REGION
        );
        vm.stopPrank();

        vm.prank(executor);
        address agreementAddr = ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
        assertTrue(agreementAddr != address(0), "the board's own maximum died at the factory");
        assertEq(Agreement(agreementAddr).deadlineDays(), 365, "deadline not carried through");
    }
}
