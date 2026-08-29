// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BoardsFixture.sol";

// ---------- TEST ----------

contract ServiceBoardTest is BoardsFixture {
    // ============================================================
    //  SERVICE BOARD TESTS
    // ============================================================

    function _mintService() internal returns (uint256 serviceId) {
        vm.startPrank(executor);
        usdc.approve(address(diamond), FEE);
        serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Smart Contract Dev",
            "I write secure Solidity",
            AMOUNT, // suggested price
            DEADLINE,
            REGION
        );
        vm.stopPrank();
    }

    function testMintService() public {
        // Posting a service now costs a flat anti-spam floor (fs.feeFloor) rather
        // than a regional fee — at posting time there is no deal amount yet.
        uint256 floor_ = 1_000_000; // $1
        uint256 executorBefore = usdc.balanceOf(executor);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        uint256 serviceId = _mintService();

        assertEq(serviceId, 0);

        ServiceBoardStorage.Service memory svc = ServiceBoardFacet(address(diamond)).getService(serviceId);
        assertEq(svc.executor, executor);
        assertEq(svc.price, AMOUNT);
        assertEq(uint256(svc.status), uint256(ServiceBoardStorage.ServiceStatus.ACTIVE));
        assertEq(svc.hiresCount, 0);

        // The fee is burned, the amount is NOT locked
        assertEq(usdc.balanceOf(executor), executorBefore - floor_);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore + floor_);
        assertEq(usdc.balanceOf(address(diamond)), 0); // the Diamond holds nothing
    }

    function testMintService_ChargesFlatFloor() public {
        uint256 floor_ = 1_000_000; // $1
        uint256 before = usdc.balanceOf(executor);

        vm.startPrank(executor);
        usdc.approve(address(diamond), floor_);
        ServiceBoardFacet(address(diamond)).mintService(
            "Solidity audit", "I audit contracts", 500_000_000, DEADLINE, REGION
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(executor), before - floor_);
        assertEq(usdc.balanceOf(feeRecipient), floor_);
    }

    function _requestService(uint256 serviceId) internal returns (uint256 requestId) {
        vm.startPrank(client);
        // requestService now takes a percentage through quote() — numerically the
        // same as JOB_FEE for the same AMOUNT (5% of $100 = $5, above the floor).
        usdc.approve(address(diamond), AMOUNT + JOB_FEE);
        requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    function testRequestService() public {
        uint256 serviceId = _mintService();

        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore    = usdc.balanceOf(feeRecipient);

        uint256 requestId = _requestService(serviceId);
        assertEq(requestId, 0);

        // The fee is held in the Diamond along with the amount — there is no deal yet
        assertEq(usdc.balanceOf(feeRecipient), feeBefore);
        assertEq(usdc.balanceOf(address(diamond)), AMOUNT + JOB_FEE);
        assertEq(usdc.balanceOf(client), clientBefore - AMOUNT - JOB_FEE);

        ServiceBoardStorage.HireRequest memory req = ServiceBoardFacet(address(diamond)).getRequest(requestId);
        assertEq(req.client, client);
        assertEq(req.amount, AMOUNT);
        assertEq(uint256(req.status), uint256(ServiceBoardStorage.RequestStatus.PENDING));
        assertEq(req.agreement, address(0));
    }

    function testAcceptRequest() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        uint256 diamondBefore = usdc.balanceOf(address(diamond));
        uint256 feeBefore     = usdc.balanceOf(feeRecipient);

        vm.prank(executor);
        address agreementAddr = ServiceBoardFacet(address(diamond)).acceptRequest(requestId);

        assertTrue(agreementAddr != address(0));

        // The amount left the Diamond for the Agreement, the fee went to feeRecipient
        assertEq(usdc.balanceOf(address(diamond)), diamondBefore - AMOUNT - JOB_FEE);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore + JOB_FEE);

        // The pair is registered
        assertTrue(RegistryFacet(address(diamond)).hasActivePair(client, executor));

        // hiresCount went up
        ServiceBoardStorage.Service memory svc = ServiceBoardFacet(address(diamond)).getService(serviceId);
        assertEq(svc.hiresCount, 1);

        // The request's status changed
        ServiceBoardStorage.HireRequest memory req = ServiceBoardFacet(address(diamond)).getRequest(requestId);
        assertEq(uint256(req.status), uint256(ServiceBoardStorage.RequestStatus.ACCEPTED));
        assertEq(req.agreement, agreementAddr);
    }

    function testRejectRequest() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        uint256 clientBefore  = usdc.balanceOf(client);
        uint256 diamondBefore = usdc.balanceOf(address(diamond));

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId);

        // Amount + the fee above the floor are refunded to the client; the floor burns
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT + (JOB_FEE - JOB_FLOOR));
        assertEq(usdc.balanceOf(address(diamond)), diamondBefore - AMOUNT - JOB_FEE);

        ServiceBoardStorage.HireRequest memory req = ServiceBoardFacet(address(diamond)).getRequest(requestId);
        assertEq(uint256(req.status), uint256(ServiceBoardStorage.RequestStatus.REJECTED));
    }

    function testCancelRequest() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId);

        // Amount + the fee above the floor are refunded to the client; the floor burns
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT + (JOB_FEE - JOB_FLOOR));

        ServiceBoardStorage.HireRequest memory req = ServiceBoardFacet(address(diamond)).getRequest(requestId);
        assertEq(uint256(req.status), uint256(ServiceBoardStorage.RequestStatus.CANCELLED));
    }

    function testRequestServiceSelf() public {
        uint256 serviceId = _mintService();

        vm.startPrank(executor);
        usdc.approve(address(diamond), FEE + AMOUNT);
        vm.expectRevert(ServiceBoardFacet.SelfRequest.selector);
        ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    function testAcceptRequestNotExecutor() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        vm.prank(client);
        vm.expectRevert(ServiceBoardFacet.NotExecutor.selector);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
    }

    function testRequestServiceRevertsIfActivePairExists() public {
        // Client already has an active deal with this executor (from a prior service).
        uint256 serviceId1 = _mintService();
        uint256 requestId1 = _requestService(serviceId1);

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId1);

        assertTrue(RegistryFacet(address(diamond)).hasActivePair(client, executor));

        // Same executor posts a second service.
        uint256 serviceId2 = _mintService();

        // Client tries to hire them again while the first deal is still active —
        // must fail fast here, not lock funds only to have acceptRequest() revert later.
        vm.startPrank(client);
        usdc.approve(address(diamond), AMOUNT);
        vm.expectRevert(ServiceBoardFacet.ActiveDealExists.selector);
        ServiceBoardFacet(address(diamond)).requestService(serviceId2, AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    function testAcceptRequestSupersedesSiblingPendingFromSameClient() public {
        uint256 serviceId1 = _mintService();
        uint256 serviceId2 = _mintService();

        uint256 requestId1 = _requestService(serviceId1);

        // Client submits a second pending request to the SAME executor (different
        // service) before either is accepted — hasActivePair doesn't block this since
        // neither is active yet.
        vm.startPrank(client);
        usdc.approve(address(diamond), AMOUNT + JOB_FEE);
        uint256 requestId2 = ServiceBoardFacet(address(diamond)).requestService(
            serviceId2, AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        uint256 clientBefore = usdc.balanceOf(client);

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId1);

        // requestId1: accepted normally
        ServiceBoardStorage.HireRequest memory req1 = ServiceBoardFacet(address(diamond)).getRequest(requestId1);
        assertEq(uint256(req1.status), uint256(ServiceBoardStorage.RequestStatus.ACCEPTED));

        // requestId2: auto-superseded and refunded, even though nobody called cancel/reject —
        // amount + fee above the floor comes back, the floor is forfeited.
        ServiceBoardStorage.HireRequest memory req2 = ServiceBoardFacet(address(diamond)).getRequest(requestId2);
        assertEq(uint256(req2.status), uint256(ServiceBoardStorage.RequestStatus.SUPERSEDED));
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT + (JOB_FEE - JOB_FLOOR));
    }

    function testAcceptRequestDoesNotReprocessAlreadyResolvedSibling() public {
        uint256 serviceId1 = _mintService();
        uint256 serviceId2 = _mintService();

        uint256 requestId1 = _requestService(serviceId1);

        vm.startPrank(client);
        usdc.approve(address(diamond), AMOUNT + JOB_FEE);
        uint256 requestId2 = ServiceBoardFacet(address(diamond)).requestService(
            serviceId2, AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        // Client cancels requestId1 themselves before the executor does anything.
        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId1);

        uint256 clientBefore = usdc.balanceOf(client);

        // Executor accepts requestId2 — requestId1 is already CANCELLED (not PENDING),
        // must not be touched again (no double refund, stays CANCELLED).
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId2);

        ServiceBoardStorage.HireRequest memory req1 = ServiceBoardFacet(address(diamond)).getRequest(requestId1);
        assertEq(uint256(req1.status), uint256(ServiceBoardStorage.RequestStatus.CANCELLED));
        assertEq(usdc.balanceOf(client), clientBefore);
    }

    function testRejectAndCancelPruneThePendingPairList() public {
        uint256 serviceId = _mintService();

        uint256 requestId1 = _requestService(serviceId);
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId1);

        uint256[] memory afterReject = ServiceBoardFacet(address(diamond)).getPendingRequestIdsByClientAndExecutor(client, executor);
        assertEq(afterReject.length, 0);

        uint256 requestId2 = _requestService(serviceId);
        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId2);

        uint256[] memory afterCancel = ServiceBoardFacet(address(diamond)).getPendingRequestIdsByClientAndExecutor(client, executor);
        assertEq(afterCancel.length, 0);
    }

    function testAcceptRequestDoesNotSupersedeOtherClientsPendingRequests() public {
        uint256 serviceId = _mintService();

        address client2 = address(0x5);
        usdc.mint(client2, 500_000_000);

        uint256 requestId1 = _requestService(serviceId);

        vm.startPrank(client2);
        usdc.approve(address(diamond), AMOUNT + JOB_FEE);
        uint256 requestId2 = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId1);

        // client2's pending request for the SAME service is untouched — multi-buyer
        // per listing (see testServiceMultipleAccepts) is not affected.
        ServiceBoardStorage.HireRequest memory req2 = ServiceBoardFacet(address(diamond)).getRequest(requestId2);
        assertEq(uint256(req2.status), uint256(ServiceBoardStorage.RequestStatus.PENDING));
    }

    function testRequestServiceRevertsWhenPendingCapReached() public {
        uint256 serviceId = _mintService();

        // This test isolates the per-PAIR cap (MAX_PENDING_PER_PAIR = 20). The
        // per-CLIENT cap (Task 6, seeded to 5 by initFactory) is a separate,
        // stricter gate that would otherwise trip first — disable it here
        // (0 = unlimited) so this test still exercises the pair cap alone.
        FactoryFacet(address(diamond)).setMaxPendingRequests(0);

        // Ensure client has enough balance for 20 requests at (AMOUNT + fee) each,
        // plus slack for the 21st after cancelling frees a slot (refund is amount +
        // fee above the floor — one floor's worth less than a fresh request costs).
        usdc.mint(client, 1_200_000_000);

        // Fill the cap with PENDING requests to the same executor (different
        // client so hasActivePair never trips — this is purely exercising the
        // count cap, not the active-pair guard).
        vm.startPrank(client);
        for (uint256 i = 0; i < 20; i++) {
            usdc.approve(address(diamond), AMOUNT + JOB_FEE);
            ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
        }
        usdc.approve(address(diamond), AMOUNT + JOB_FEE);
        vm.expectRevert(ServiceBoardFacet.TooManyPendingRequests.selector);
        ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();

        // Cancelling one frees a slot.
        uint256[] memory pending = ServiceBoardFacet(address(diamond)).getPendingRequestIdsByClientAndExecutor(client, executor);
        assertEq(pending.length, 20);
        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(pending[0]);

        vm.startPrank(client);
        usdc.approve(address(diamond), AMOUNT + JOB_FEE);
        ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    function testPendingRequestCap_BlocksSixth() public {
        uint256 amount = 20_000_000;
        uint256 fee = 1_000_000;

        // Five different executors, each with a service of their own
        uint256[] memory serviceIds = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            address exec = address(uint160(0x2000 + i));
            usdc.mint(exec, fee);
            vm.startPrank(exec);
            usdc.approve(address(diamond), fee);
            serviceIds[i] = ServiceBoardFacet(address(diamond)).mintService(
                "Service", "Desc", 100_000_000, DEADLINE, REGION
            );
            vm.stopPrank();
        }

        usdc.mint(client, 6 * (amount + fee));
        vm.startPrank(client);
        usdc.approve(address(diamond), 6 * (amount + fee));

        for (uint256 i = 0; i < 5; i++) {
            ServiceBoardFacet(address(diamond)).requestService(
                serviceIds[i], amount, DEADLINE, TERMS, REGION
            );
        }

        // The sixth is over the ceiling
        vm.expectRevert(ServiceBoardFacet.TooManyPendingRequests.selector);
        ServiceBoardFacet(address(diamond)).requestService(
            serviceIds[5], amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    function testPendingRequestCap_FreesSlotOnCancel() public {
        uint256 amount = 20_000_000;
        uint256 fee = 1_000_000;

        uint256[] memory serviceIds = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            address exec = address(uint160(0x3000 + i));
            usdc.mint(exec, fee);
            vm.startPrank(exec);
            usdc.approve(address(diamond), fee);
            serviceIds[i] = ServiceBoardFacet(address(diamond)).mintService(
                "Service", "Desc", 100_000_000, DEADLINE, REGION
            );
            vm.stopPrank();
        }

        usdc.mint(client, 6 * (amount + fee));
        vm.startPrank(client);
        usdc.approve(address(diamond), 6 * (amount + fee));

        uint256 firstId = ServiceBoardFacet(address(diamond)).requestService(
            serviceIds[0], amount, DEADLINE, TERMS, REGION
        );
        for (uint256 i = 1; i < 5; i++) {
            ServiceBoardFacet(address(diamond)).requestService(
                serviceIds[i], amount, DEADLINE, TERMS, REGION
            );
        }

        // Free a slot — the sixth now goes through
        ServiceBoardFacet(address(diamond)).cancelRequest(firstId);
        uint256 sixthId = ServiceBoardFacet(address(diamond)).requestService(
            serviceIds[5], amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        // Not merely "it did not revert" — the request really was created and is
        // sitting PENDING (with no gate at all this test would be just as green).
        ServiceBoardStorage.HireRequest memory sixth = ServiceBoardFacet(address(diamond)).getRequest(sixthId);
        assertEq(uint256(sixth.status), uint256(ServiceBoardStorage.RequestStatus.PENDING));
    }

    function testPendingRequestCap_FreesSlotOnAccept() public {
        uint256 amount = 20_000_000;
        uint256 fee = 1_000_000;

        uint256[] memory serviceIds = new uint256[](6);
        address[] memory execs = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            execs[i] = address(uint160(0x6000 + i));
            usdc.mint(execs[i], fee);
            vm.startPrank(execs[i]);
            usdc.approve(address(diamond), fee);
            serviceIds[i] = ServiceBoardFacet(address(diamond)).mintService(
                "Service", "Desc", 100_000_000, DEADLINE, REGION
            );
            vm.stopPrank();
        }

        usdc.mint(client, 6 * (amount + fee));
        vm.startPrank(client);
        usdc.approve(address(diamond), 6 * (amount + fee));

        uint256 firstId = ServiceBoardFacet(address(diamond)).requestService(
            serviceIds[0], amount, DEADLINE, TERMS, REGION
        );
        for (uint256 i = 1; i < 5; i++) {
            ServiceBoardFacet(address(diamond)).requestService(
                serviceIds[i], amount, DEADLINE, TERMS, REGION
            );
        }
        vm.stopPrank();

        // Resolve one via acceptRequest (path 1's decrement), not cancel —
        // that decrement site is the one testPendingRequestCap_FreesSlotOnCancel
        // does not exercise.
        vm.prank(execs[0]);
        ServiceBoardFacet(address(diamond)).acceptRequest(firstId);

        vm.startPrank(client);
        uint256 sixthId = ServiceBoardFacet(address(diamond)).requestService(
            serviceIds[5], amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        ServiceBoardStorage.HireRequest memory sixth = ServiceBoardFacet(address(diamond)).getRequest(sixthId);
        assertEq(uint256(sixth.status), uint256(ServiceBoardStorage.RequestStatus.PENDING));
    }

    function testPendingRequestCap_FreesSlotOnReject() public {
        uint256 amount = 20_000_000;
        uint256 fee = 1_000_000;

        uint256[] memory serviceIds = new uint256[](6);
        address[] memory execs = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            execs[i] = address(uint160(0x7000 + i));
            usdc.mint(execs[i], fee);
            vm.startPrank(execs[i]);
            usdc.approve(address(diamond), fee);
            serviceIds[i] = ServiceBoardFacet(address(diamond)).mintService(
                "Service", "Desc", 100_000_000, DEADLINE, REGION
            );
            vm.stopPrank();
        }

        usdc.mint(client, 6 * (amount + fee));
        vm.startPrank(client);
        usdc.approve(address(diamond), 6 * (amount + fee));

        uint256 firstId = ServiceBoardFacet(address(diamond)).requestService(
            serviceIds[0], amount, DEADLINE, TERMS, REGION
        );
        for (uint256 i = 1; i < 5; i++) {
            ServiceBoardFacet(address(diamond)).requestService(
                serviceIds[i], amount, DEADLINE, TERMS, REGION
            );
        }
        vm.stopPrank();

        // Resolve one via rejectRequest (path 3's decrement).
        vm.prank(execs[0]);
        ServiceBoardFacet(address(diamond)).rejectRequest(firstId);

        vm.startPrank(client);
        uint256 sixthId = ServiceBoardFacet(address(diamond)).requestService(
            serviceIds[5], amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        ServiceBoardStorage.HireRequest memory sixth = ServiceBoardFacet(address(diamond)).getRequest(sixthId);
        assertEq(uint256(sixth.status), uint256(ServiceBoardStorage.RequestStatus.PENDING));
    }

    function testPendingRequestCap_FreesTwoSlotsOnSupersede() public {
        uint256 amount = 20_000_000;
        uint256 fee = 1_000_000;

        // exec0 hosts TWO services -- the client requests both, so accepting
        // one auto-supersedes the sibling request to the same executor via
        // the loop inside acceptRequest. Three more distinct executors fill
        // the cap to 5 pending total; two more distinct executors serve as
        // post-resolution probes.
        //
        // This isolates the sibling-loop decrement from acceptRequest's own
        // (path 1) decrement: accepting always frees exactly one slot via
        // path 1 alone, so a single post-resolution probe can't tell the two
        // decrements apart. Two probes can -- if the sibling-loop decrement
        // were missing, only one slot would actually be free (path 1's),
        // and the second probe would revert TooManyPendingRequests.
        address exec0 = address(uint160(0x8000));
        usdc.mint(exec0, 2 * fee);
        vm.startPrank(exec0);
        usdc.approve(address(diamond), 2 * fee);
        uint256 serviceA = ServiceBoardFacet(address(diamond)).mintService(
            "Service", "Desc", 100_000_000, DEADLINE, REGION
        );
        uint256 serviceB = ServiceBoardFacet(address(diamond)).mintService(
            "Service", "Desc", 100_000_000, DEADLINE, REGION
        );
        vm.stopPrank();

        uint256[] memory fillerServiceIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            address exec = address(uint160(0x8100 + i));
            usdc.mint(exec, fee);
            vm.startPrank(exec);
            usdc.approve(address(diamond), fee);
            fillerServiceIds[i] = ServiceBoardFacet(address(diamond)).mintService(
                "Service", "Desc", 100_000_000, DEADLINE, REGION
            );
            vm.stopPrank();
        }

        uint256[] memory probeServiceIds = new uint256[](2);
        for (uint256 i = 0; i < 2; i++) {
            address exec = address(uint160(0x8200 + i));
            usdc.mint(exec, fee);
            vm.startPrank(exec);
            usdc.approve(address(diamond), fee);
            probeServiceIds[i] = ServiceBoardFacet(address(diamond)).mintService(
                "Service", "Desc", 100_000_000, DEADLINE, REGION
            );
            vm.stopPrank();
        }

        usdc.mint(client, 7 * (amount + fee));
        vm.startPrank(client);
        usdc.approve(address(diamond), 7 * (amount + fee));

        uint256 requestA = ServiceBoardFacet(address(diamond)).requestService(
            serviceA, amount, DEADLINE, TERMS, REGION
        );
        uint256 requestB = ServiceBoardFacet(address(diamond)).requestService(
            serviceB, amount, DEADLINE, TERMS, REGION
        );
        for (uint256 i = 0; i < 3; i++) {
            ServiceBoardFacet(address(diamond)).requestService(
                fillerServiceIds[i], amount, DEADLINE, TERMS, REGION
            );
        }
        vm.stopPrank();

        // exec0 accepts requestA -- requestB (same client, same executor,
        // still PENDING) is auto-superseded by the sibling loop.
        vm.prank(exec0);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestA);

        ServiceBoardStorage.HireRequest memory reqB = ServiceBoardFacet(address(diamond)).getRequest(requestB);
        assertEq(uint256(reqB.status), uint256(ServiceBoardStorage.RequestStatus.SUPERSEDED));

        vm.startPrank(client);
        uint256 probe1 = ServiceBoardFacet(address(diamond)).requestService(
            probeServiceIds[0], amount, DEADLINE, TERMS, REGION
        );
        uint256 probe2 = ServiceBoardFacet(address(diamond)).requestService(
            probeServiceIds[1], amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        ServiceBoardStorage.HireRequest memory p1 = ServiceBoardFacet(address(diamond)).getRequest(probe1);
        ServiceBoardStorage.HireRequest memory p2 = ServiceBoardFacet(address(diamond)).getRequest(probe2);
        assertEq(uint256(p1.status), uint256(ServiceBoardStorage.RequestStatus.PENDING));
        assertEq(uint256(p2.status), uint256(ServiceBoardStorage.RequestStatus.PENDING));
    }

    function testMaxPendingRequestsZeroMeansUnlimited() public {
        // Standalone assertion of the zero-means-unlimited semantics, so it
        // doesn't depend on testRequestServiceRevertsWhenPendingCapReached's
        // unrelated setMaxPendingRequests(0) call for coverage -- if that
        // test's cap value is ever changed away from 0, this one still pins
        // the behavior.
        FactoryFacet(address(diamond)).setMaxPendingRequests(0);

        uint256 amount = 20_000_000;
        uint256 fee = 1_000_000;

        uint256[] memory serviceIds = new uint256[](7);
        for (uint256 i = 0; i < 7; i++) {
            address exec = address(uint160(0x9000 + i));
            usdc.mint(exec, fee);
            vm.startPrank(exec);
            usdc.approve(address(diamond), fee);
            serviceIds[i] = ServiceBoardFacet(address(diamond)).mintService(
                "Service", "Desc", 100_000_000, DEADLINE, REGION
            );
            vm.stopPrank();
        }

        usdc.mint(client, 7 * (amount + fee));
        vm.startPrank(client);
        usdc.approve(address(diamond), 7 * (amount + fee));
        for (uint256 i = 0; i < 7; i++) {
            ServiceBoardFacet(address(diamond)).requestService(
                serviceIds[i], amount, DEADLINE, TERMS, REGION
            );
        }
        vm.stopPrank();

        assertEq(ServiceBoardFacet(address(diamond)).getClientRequests(client).length, 7);
    }

    function testLegacyPendingRequestDoesNotUnderflowOnResolve() public {
        // Simulates a request created by the PRE-Task-6 facet: PENDING in
        // storage, but pendingRequestCount was never incremented for this
        // client, because the field (and the increment) didn't exist yet at
        // the time it was created. A plain `--` on any of the four
        // PENDING-exit paths would underflow (Panic 0x11) on the very first
        // resolve, permanently stranding requestFunds in the Diamond.
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        // pendingRequestCount is field index 11 (the 12th field) of
        // ServiceBoardStorage.Layout -- every field before it (mappings,
        // dynamic arrays, uint256) occupies exactly one slot in the struct's
        // own layout, so the mapping's base slot is POSITION + 11.
        bytes32 mappingSlot = bytes32(uint256(ServiceBoardStorage.POSITION) + 11);
        bytes32 countSlot = keccak256(abi.encode(client, mappingSlot));

        // Sanity check: _requestService() just incremented it to 1.
        assertEq(uint256(vm.load(address(diamond), countSlot)), 1);

        // Force it back to 0 -- the actual legacy state this request would
        // have had if the facet had never known about this counter.
        vm.store(address(diamond), countSlot, bytes32(uint256(0)));

        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId);

        ServiceBoardStorage.HireRequest memory req = ServiceBoardFacet(address(diamond)).getRequest(requestId);
        assertEq(uint256(req.status), uint256(ServiceBoardStorage.RequestStatus.CANCELLED));

        // Clamped at 0, not wrapped to type(uint256).max.
        assertEq(uint256(vm.load(address(diamond), countSlot)), 0);
    }

    function testRemoveService() public {
        uint256 serviceId = _mintService();

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).removeService(serviceId);

        ServiceBoardStorage.Service memory svc = ServiceBoardFacet(address(diamond)).getService(serviceId);
        assertEq(uint256(svc.status), uint256(ServiceBoardStorage.ServiceStatus.REMOVED));
    }

    function testRemoveServiceNotExecutor() public {
        uint256 serviceId = _mintService();

        vm.prank(client);
        vm.expectRevert(ServiceBoardFacet.NotExecutor.selector);
        ServiceBoardFacet(address(diamond)).removeService(serviceId);
    }

    function testPauseAndUnpauseService() public {
        uint256 serviceId = _mintService();

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).pauseService(serviceId);

        ServiceBoardStorage.Service memory svc = ServiceBoardFacet(address(diamond)).getService(serviceId);
        assertEq(uint256(svc.status), uint256(ServiceBoardStorage.ServiceStatus.PAUSED));

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).unpauseService(serviceId);

        svc = ServiceBoardFacet(address(diamond)).getService(serviceId);
        assertEq(uint256(svc.status), uint256(ServiceBoardStorage.ServiceStatus.ACTIVE));
    }

    function testRequestPausedService() public {
        uint256 serviceId = _mintService();

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).pauseService(serviceId);

        vm.startPrank(client);
        usdc.approve(address(diamond), FEE + AMOUNT);
        vm.expectRevert(ServiceBoardFacet.ServiceNotActive.selector);
        ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    function testServiceMultipleAccepts() public {
        uint256 serviceId = _mintService();

        address client2 = address(0x5);
        usdc.mint(client2, 500_000_000);

        // First request
        uint256 requestId1 = _requestService(serviceId);

        // Second request, from a different client
        uint256 amount2 = 50_000_000;
        uint256 fee2 = 2_500_000; // 5% of $50
        vm.startPrank(client2);
        usdc.approve(address(diamond), amount2 + fee2);
        uint256 requestId2 = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, amount2, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        // The executor accepts the first request
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId1);

        // The executor rejects the second
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId2);

        ServiceBoardStorage.Service memory svc = ServiceBoardFacet(address(diamond)).getService(serviceId);
        assertEq(svc.hiresCount, 1);
    }

    // ============================================================
    //  SERVICE BOARD EDIT + VIEW TESTS
    // ============================================================

    function testEditService() public {
        uint256 serviceId = _mintService();

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).editService(
            serviceId,
            "Updated Service",
            "New description",
            50_000_000, // new price
            14,         // new deadline
            REGION
        );

        ServiceBoardStorage.Service memory svc = ServiceBoardFacet(address(diamond)).getService(serviceId);
        assertEq(svc.title, "Updated Service");
        assertEq(svc.price, 50_000_000);
        assertEq(svc.deadlineDays, 14);
    }

    function testEditServiceRevertIfNotExecutor() public {
        uint256 serviceId = _mintService();

        vm.prank(client);
        vm.expectRevert(ServiceBoardFacet.NotExecutor.selector);
        ServiceBoardFacet(address(diamond)).editService(
            serviceId, "X", "X", 50_000_000, 14, REGION
        );
    }

    function testTotalRequests() public {
        uint256 serviceId = _mintService();
        assertEq(ServiceBoardFacet(address(diamond)).totalRequests(), 0);

        _requestService(serviceId);
        assertEq(ServiceBoardFacet(address(diamond)).totalRequests(), 1);
    }

    function testGetRequestFunds() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        assertEq(ServiceBoardFacet(address(diamond)).getRequestFunds(requestId), AMOUNT);
    }

    function testGetRequestFundsClearedOnAccept() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);

        // After accept the funds have left the Diamond for the Agreement
        assertEq(ServiceBoardFacet(address(diamond)).getRequestFunds(requestId), 0);
    }

    function testGetActiveServices() public {
        _mintService();

        (uint256[] memory ids, ServiceBoardStorage.Service[] memory svcs) =
            ServiceBoardFacet(address(diamond)).getActiveServices();
        assertEq(ids.length, 1);
        assertEq(svcs[0].executor, executor);
    }

    function testGetExecutorServices() public {
        _mintService();

        uint256[] memory ids = ServiceBoardFacet(address(diamond)).getExecutorServices(executor);
        assertEq(ids.length, 1);
        assertEq(ids[0], 0);
    }

    function testAcceptRequestRevertIfNotPending() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);

        // A repeated accept of the same requestId
        vm.prank(executor);
        vm.expectRevert(ServiceBoardFacet.RequestNotPending.selector);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
    }

    function testGetClientRequests() public {
        uint256 serviceId = _mintService();
        _requestService(serviceId);

        uint256[] memory reqs = ServiceBoardFacet(address(diamond)).getClientRequests(client);
        assertEq(reqs.length, 1);
        assertEq(reqs[0], 0);
    }

    // ============================================================
    //  SERVICE BOARD REQUEST FEE
    // ============================================================

    function _postService() internal returns (uint256 serviceId) {
        vm.startPrank(executor);
        usdc.approve(address(diamond), 1_000_000);
        serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Solidity audit", "I audit contracts", 500_000_000, DEADLINE, REGION
        );
        vm.stopPrank();
    }

    function testRequestService_ChargesPercentageAndHolds() public {
        uint256 serviceId = _postService();
        uint256 amount = 200_000_000;  // $200
        uint256 fee = 10_000_000;      // 5%
        uint256 recipientBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + fee);
        ServiceBoardFacet(address(diamond)).requestService(
            serviceId, amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        // The fee is held, not forwarded — there is no deal yet
        assertEq(usdc.balanceOf(feeRecipient), recipientBefore);
        assertEq(usdc.balanceOf(address(diamond)), amount + fee);
    }

    function testAcceptRequest_ForwardsHeldFee() public {
        uint256 serviceId = _postService();
        uint256 amount = 200_000_000;
        uint256 fee = 10_000_000;
        uint256 recipientBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + fee);
        uint256 requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);

        assertEq(usdc.balanceOf(feeRecipient), recipientBefore + fee);
        assertEq(usdc.balanceOf(address(diamond)), 0);
    }

    function testRejectRequest_RefundsFeeAboveFloor() public {
        uint256 serviceId = _postService();
        uint256 amount = 200_000_000;
        uint256 fee = 10_000_000;
        uint256 floor_ = 1_000_000;
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 recipientBefore = usdc.balanceOf(feeRecipient);

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + fee);
        uint256 requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, amount, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId);

        assertEq(usdc.balanceOf(client), clientBefore - floor_);
        assertEq(usdc.balanceOf(feeRecipient), recipientBefore + floor_);
        assertEq(usdc.balanceOf(address(diamond)), 0);
    }

    function testCancelRequest_RefundsFeeAboveFloor() public {
        uint256 serviceId = _postService();
        uint256 amount = 200_000_000;
        uint256 fee = 10_000_000;
        uint256 floor_ = 1_000_000;
        uint256 clientBefore = usdc.balanceOf(client);

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + fee);
        uint256 requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, amount, DEADLINE, TERMS, REGION
        );
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId);
        vm.stopPrank();

        assertEq(usdc.balanceOf(client), clientBefore - floor_);
    }

    function testTenHires_EachPaysPercentage() public {
        uint256 serviceId = _postService();
        uint256 amount = 200_000_000;
        uint256 fee = 10_000_000;
        uint256 floor_ = 1_000_000;

        // The posting floor has already been paid by the executor
        assertEq(usdc.balanceOf(feeRecipient), floor_);

        // Every hire gets its own client (hasActivePair blocks a second hire of the same pair)
        for (uint256 i = 0; i < 10; i++) {
            address hirer = address(uint160(0x1000 + i));
            usdc.mint(hirer, amount + fee);

            vm.startPrank(hirer);
            usdc.approve(address(diamond), amount + fee);
            uint256 requestId = ServiceBoardFacet(address(diamond)).requestService(
                serviceId, amount, DEADLINE, TERMS, REGION
            );
            vm.stopPrank();

            vm.prank(executor);
            ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
        }

        // The listing floor plus ten percent, not one floor
        assertEq(usdc.balanceOf(feeRecipient), floor_ + 10 * fee);
    }

    // ============================================================
    //  FEE LEDGER READ PATH
    // ============================================================

    function testGetRequestFeeHeld_ReportsWhatIsHeld() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        assertEq(ServiceBoardFacet(address(diamond)).getRequestFeeHeld(requestId), JOB_FEE);
    }

    function testGetRequestFeeHeld_ClearedOnAccept() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);

        assertEq(ServiceBoardFacet(address(diamond)).getRequestFeeHeld(requestId), 0);
    }

    function testGetRequestFeeHeld_ClearedOnCancelAndReject() public {
        uint256 serviceId = _mintService();

        uint256 cancelled = _requestService(serviceId);
        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(cancelled);
        assertEq(ServiceBoardFacet(address(diamond)).getRequestFeeHeld(cancelled), 0);

        uint256 rejected = _requestService(serviceId);
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(rejected);
        assertEq(ServiceBoardFacet(address(diamond)).getRequestFeeHeld(rejected), 0);
    }

    function testGetPendingRequestCount_TracksPendingAndFreesOnExit() public {
        uint256 serviceId = _mintService();
        assertEq(ServiceBoardFacet(address(diamond)).getPendingRequestCount(client), 0);

        uint256 requestId = _requestService(serviceId);
        assertEq(ServiceBoardFacet(address(diamond)).getPendingRequestCount(client), 1);

        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId);
        assertEq(ServiceBoardFacet(address(diamond)).getPendingRequestCount(client), 0);
    }

    // ============================================================
    //  FEE COLLECTED EVENT
    // ============================================================

    function testAcceptRequest_EmitsFeeCollected() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        // The event is emitted from the place where the transfer actually happens,
        // so it carries the amount withheld at request time rather than one
        // recomputed at hire time. _assertLedgerBalanced also proves that nothing
        // beyond what this event declares went to the treasury on this call.
        (, Vm.Log[] memory logs) = _assertLedgerBalanced(
            executor,
            abi.encodeWithSelector(ServiceBoardFacet.acceptRequest.selector, requestId)
        );
        _assertFeeCollected(logs, requestId, client, FEE_KIND_REQUEST_DEAL, JOB_FEE);
    }

    /// Posting a service — a flat anti-spam floor tied to no deal at all
    /// (id = serviceId, not requestId), and paid by the executor, not the client.
    function testMintService_EmitsFeeCollected() public {
        uint256 floor_ = 1_000_000; // $1 — fs.feeFloor

        vm.prank(executor);
        usdc.approve(address(diamond), FEE);

        (, Vm.Log[] memory logs) = _assertLedgerBalanced(
            executor,
            abi.encodeWithSelector(
                ServiceBoardFacet.mintService.selector,
                "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION
            )
        );
        _assertFeeCollected(logs, 0, executor, FEE_KIND_SERVICE_LISTING, floor_);
    }

    /// The same floor, the same kind, the same payer (executor) — only through the
    /// gasless permit() path rather than an approve() made in advance.
    function testMintServiceWithPermit_EmitsFeeCollected() public {
        uint256 floor_ = 1_000_000; // $1 — fs.feeFloor

        (, Vm.Log[] memory logs) = _assertLedgerBalanced(
            address(this),
            abi.encodeWithSelector(
                ServiceBoardFacet.mintServiceWithPermit.selector,
                executor, "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION,
                block.timestamp + 1 days, uint8(0), bytes32(0), bytes32(0)
            )
        );
        _assertFeeCollected(logs, 0, executor, FEE_KIND_SERVICE_LISTING, floor_);
    }

    /// Rejection — amount plus the fee above the floor come back, the floor burns.
    /// payer = req.client, kind = REQUEST_FORFEIT (not REQUEST_DEAL — there was no
    /// deal).
    function testRejectRequest_EmitsFeeCollected() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        (, Vm.Log[] memory logs) = _assertLedgerBalanced(
            executor,
            abi.encodeWithSelector(ServiceBoardFacet.rejectRequest.selector, requestId)
        );
        _assertFeeCollected(logs, requestId, client, FEE_KIND_REQUEST_FORFEIT, JOB_FLOOR);
    }

    /// Withdrawal by the client — the same refund and the same kind as a reject,
    /// but on the client's initiative rather than the executor's.
    function testCancelRequest_EmitsFeeCollected() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);

        (, Vm.Log[] memory logs) = _assertLedgerBalanced(
            client,
            abi.encodeWithSelector(ServiceBoardFacet.cancelRequest.selector, requestId)
        );
        _assertFeeCollected(logs, requestId, client, FEE_KIND_REQUEST_FORFEIT, JOB_FLOOR);
    }

    /// A sibling displaced inside acceptRequest — a third road to the same
    /// REQUEST_FORFEIT: nobody explicitly cancelled or rejected requestId2, but it
    /// was auto-refunded and its floor burned because requestId1 from the same
    /// (client, executor) pair was accepted first. Without kind this would be
    /// indistinguishable from the REQUEST_DEAL that acceptRequest emits in the very
    /// same transaction for requestId1. One call emits TWO FeeCollected with
    /// different ids — _assertLedgerBalanced has already proved their sum covers
    /// the whole balance increase; what is checked here is that they are precisely
    /// these two events.
    function testAcceptRequestSupersedesSibling_EmitsFeeCollected() public {
        uint256 serviceId1 = _mintService();
        uint256 serviceId2 = _mintService();

        uint256 requestId1 = _requestService(serviceId1);

        vm.startPrank(client);
        usdc.approve(address(diamond), AMOUNT + JOB_FEE);
        uint256 requestId2 = ServiceBoardFacet(address(diamond)).requestService(
            serviceId2, AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        (, Vm.Log[] memory logs) = _assertLedgerBalanced(
            executor,
            abi.encodeWithSelector(ServiceBoardFacet.acceptRequest.selector, requestId1)
        );
        _assertFeeCollected(logs, requestId1, client, FEE_KIND_REQUEST_DEAL, JOB_FEE);
        _assertFeeCollected(logs, requestId2, client, FEE_KIND_REQUEST_FORFEIT, JOB_FLOOR);
    }

    // ============================================================
    //  FEE LEDGER COMPLETENESS
    // ============================================================

    /// The central claim: FeeCollected must be a COMPLETE ledger of revenue, not a
    /// partial one. The scenario walks the protocol through all six kinds —
    /// JOB_DEAL, JOB_FORFEIT, SERVICE_LISTING (twice), REQUEST_DEAL,
    /// REQUEST_FORFEIT, DIRECT_DEAL (deployAndFund) — with different
    /// client/executor pairs, so that hasActivePair() is not tripped at any step.
    /// The definition of "the ledger is complete": the sum of amount over every
    /// FeeCollected in the scenario equals the actual increase of the feeRecipient
    /// balance across that same scenario — no more (no double counting) and no
    /// less (no missed transfer).
    ///
    /// The per-call structural check (_assertLedgerBalanced) already covers each
    /// of these sites individually — this test remains as a separate, wider proof:
    /// the invariant holds across a SEQUENCE of heterogeneous calls too, not only
    /// around a single isolated one.
    function testFeeLedger_SumOfCollectedEqualsBalanceIncrease() public {
        address executorJob = address(0x9);       // JobBoard deal — a new pair
        address executorForfeit = address(0xA);    // ServiceBoard forfeit — a new pair
        address executorDirectB = address(0xC);    // deployAndFund directly — a new pair
        usdc.mint(executorForfeit, 10_000_000);    // enough for the posting floor

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);

        vm.recordLogs();

        // --- ServiceBoard: SERVICE_LISTING ($1) + REQUEST_DEAL ($5) ---
        uint256 s1 = _mintService();
        uint256 r1 = _requestService(s1);
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(r1);

        // --- JobBoard: JOB_DEAL ($5) — a new pair (client, executorJob) ---
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 j1 = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
        vm.prank(executorJob);
        JobBoardFacet(address(diamond)).applyForJob(j1);
        vm.prank(client);
        JobBoardFacet(address(diamond)).acceptApplicant(j1, executorJob);

        // --- JobBoard: JOB_FORFEIT ($1) ---
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 j2 = JobBoardFacet(address(diamond)).mintJob(
            "Another job", "Different work", AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(j2);

        // --- ServiceBoard: SERVICE_LISTING ($1) + REQUEST_FORFEIT ($1) — a new pair ---
        vm.startPrank(executorForfeit);
        usdc.approve(address(diamond), JOB_FLOOR);
        uint256 s2 = ServiceBoardFacet(address(diamond)).mintService(
            "Another service", "Different description", AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();

        vm.startPrank(client);
        usdc.approve(address(diamond), AMOUNT + JOB_FEE);
        uint256 r2 = ServiceBoardFacet(address(diamond)).requestService(s2, AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(r2);

        // --- FactoryFacet: DIRECT_DEAL ($10) — a direct hire through deployAndFund,
        //     which moves the amount into the Agreement in the same transaction; a
        //     new pair (client, executorDirectB). There is no second direct hire
        //     here any more: deployAgreement takes no fee and sends no FeeCollected
        //     — its door is closed to everyone but the diamond itself ---
        vm.startPrank(client);
        usdc.approve(address(diamond), 210_000_000);
        FactoryFacet(address(diamond)).deployAndFund(
            client, executorDirectB, 200_000_000, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // JobBoardFacet.FeeCollected, ServiceBoardFacet.FeeCollected and
        // FactoryFacet.FeeCollected — one and the same signature in three facets,
        // hence one and the same selector. That couples their declarations: should
        // one facet's signature drift on the next upgrade, this line fails first,
        // before anybody notices the divergence in production.
        bytes32 feeCollectedTopic = ServiceBoardFacet.FeeCollected.selector;
        assertEq(feeCollectedTopic, JobBoardFacet.FeeCollected.selector);
        assertEq(feeCollectedTopic, FactoryFacet.FeeCollected.selector);

        uint256 totalCollected;
        uint256 eventCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == feeCollectedTopic) {
                totalCollected += abi.decode(logs[i].data, (uint256));
                eventCount++;
            }
        }

        // Seven transfers in the scenario — exactly seven emissions, no more
        // (double counting) and no fewer (a missed transfer).
        assertEq(eventCount, 7);
        assertEq(totalCollected, 24_000_000); // $1+$5+$5+$1+$1+$1 + $10

        uint256 feeRecipientAfter = usdc.balanceOf(feeRecipient);
        assertEq(totalCollected, feeRecipientAfter - feeRecipientBefore);
    }

    // ============================================================
    //  UPGRADE WINDOW: diamondCut landed, config transaction has not
    // ============================================================

    function testUnconfigured_MintServiceReverts() public {
        (DiamondProxy fresh, ) = _deployUnconfiguredDiamond();

        vm.startPrank(executor);
        usdc.approve(address(fresh), type(uint256).max);
        vm.expectRevert(FeeNotConfigured.selector);
        ServiceBoardFacet(address(fresh)).mintService(
            "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();
    }

    function testUnconfigured_MintServiceWithPermitReverts() public {
        (DiamondProxy fresh, ) = _deployUnconfiguredDiamond();

        // The floor is read BEFORE permit(), so the path fails on the fee rather than on the signature.
        vm.expectRevert(FeeNotConfigured.selector);
        ServiceBoardFacet(address(fresh)).mintServiceWithPermit(
            executor, "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION,
            block.timestamp + 1 days, 0, bytes32(0), bytes32(0)
        );
    }

    function testUnconfigured_RequestServiceReverts() public {
        (DiamondProxy fresh, ) = _deployUnconfiguredDiamond();

        vm.startPrank(client);
        usdc.approve(address(fresh), type(uint256).max);
        vm.expectRevert(FeeNotConfigured.selector);
        ServiceBoardFacet(address(fresh)).requestService(0, AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    function testUnconfigured_RequestServiceWithPermitReverts() public {
        (DiamondProxy fresh, ) = _deployUnconfiguredDiamond();

        vm.expectRevert(FeeNotConfigured.selector);
        ServiceBoardFacet(address(fresh)).requestServiceWithPermit(
            client, 0, AMOUNT, DEADLINE, TERMS, REGION,
            block.timestamp + 1 days, 0, bytes32(0), bytes32(0)
        );
    }

    /// Money must come out even of an unconfigured protocol: the request was filed
    /// BEFORE the cut, the seeding window is not closed yet, and the client cancels.
    function testUnconfigured_CancelRequestStillReturnsEverything() public {
        (DiamondProxy fresh, ) = _deployBoardsDiamond();

        vm.startPrank(executor);
        usdc.approve(address(fresh), type(uint256).max);
        uint256 serviceId = ServiceBoardFacet(address(fresh)).mintService(
            "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();

        vm.startPrank(client);
        usdc.approve(address(fresh), type(uint256).max);
        uint256 requestId = ServiceBoardFacet(address(fresh)).requestService(
            serviceId, AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        uint256 clientBefore = usdc.balanceOf(client);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        _unconfigureFeeModel(address(fresh));

        vm.prank(client);
        ServiceBoardFacet(address(fresh)).cancelRequest(requestId);

        // There is no floor — nothing to burn, everything comes back: amount and fee alike.
        assertEq(usdc.balanceOf(client), clientBefore + AMOUNT + JOB_FEE);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore);
        assertEq(usdc.balanceOf(address(fresh)), 0);
    }
}
