// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  Money path, part 6 — the leftovers
// ============================================================
//
// Odds and ends that the four walkthroughs raised and that are worth a number
// of their own: money that ends up somewhere nobody can reach it, and the one
// branch that would hand out an escrow with no fee at all if anything could
// reach it.

import "./MoneyPathBase.sol";

contract MoneyPathLeftoversTest is MoneyPathBase {

    /// USDC sent to a clone by anyone other than the funding path stays there
    /// forever. The clone pays out `amount + extrasTotal` and nothing else, has
    /// no rescue function, and is nailed to its implementation for life.
    function testAnythingSentToACloneByHandStaysThereForever() public {
        (Agreement a, ) = _hireThroughJobBoard(AMOUNT);

        vm.prank(stranger);
        usdc.transfer(address(a), 5_000_000); // a fat-fingered $5
        assertEq(usdc.balanceOf(address(a)), AMOUNT + 5_000_000);

        _activate(a);
        vm.prank(executor); a.markDone();
        uint256 e0 = usdc.balanceOf(executor);
        vm.prank(client); a.release();

        assertEq(usdc.balanceOf(executor) - e0, AMOUNT, "the executor got the deal, not the donation");
        assertEq(usdc.balanceOf(address(a)), 5_000_000, "and $5 is in the clone forever");

        // Nothing left can move it: the deal is finalized.
        vm.prank(client);
        vm.expectRevert(Agreement.AlreadyFinalized.selector);
        a.release();
    }

    /// The same is true of the diamond, with one difference that matters: money
    /// donated there is NOT lost, because it makes the diamond hold more than
    /// its books say -- which is exactly what the identity is for. Named so the
    /// identity's direction is on record: it catches a missing term, and reads
    /// a donation as one.
    function testADonationToTheDiamondShowsUpAsABreakInTheIdentity() public {
        _assertDiamondBalances("clean start");
        vm.prank(stranger);
        usdc.transfer(address(diamond), 3_000_000);
        assertEq(usdc.balanceOf(address(diamond)), 3_000_000);
        assertEq(_diamondLedger(), 0, "the books say nothing is held");
    }

    /// deployAgreement charges nothing and funds nothing: it is the step a
    /// board takes on itself, having already held the client's fee since the
    /// posting. Nobody outside can reach it -- not a stranger, not the client
    /// whose deal it would be, not the diamond's own owner -- and each of the
    /// three is refused by name rather than by running out of allowance.
    function testDeployAgreementIsUnreachableFromOutside() public {
        vm.prank(stranger);
        vm.expectRevert(FactoryFacet.NotDiamond.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, DEADLINE, TERMS, 0
        );

        // The client is the one most likely to knock, and is refused too: the
        // clone this would create is one nobody could ever get out of.
        vm.prank(client);
        vm.expectRevert(FactoryFacet.NotDiamond.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, DEADLINE, TERMS, 0
        );

        // Not even the diamond's own owner may stand in for the client.
        vm.prank(owner);
        vm.expectRevert(FactoryFacet.NotDiamond.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, DEADLINE, TERMS, 0
        );
    }

    /// deployAgreement has no gasless path at all, and cannot have one: the
    /// only caller it accepts is the diamond, and through a forwarder the
    /// sender is the forwarder. deployAndFund reads _msgSender() and does have
    /// one. Measured because the two sit next to each other and look alike.
    function testDeployAgreementHasNoGaslessPathWhileDeployAndFundDoes() public {
        address forwarder = FactoryFacet(address(diamond)).getTrustedForwarder();

        // Imitate what a forwarder does: call with the sender appended.
        bytes memory inner = abi.encodeWithSelector(
            FactoryFacet.deployAgreement.selector,
            client, executor, address(0), AMOUNT, DEADLINE, TERMS, uint8(0)
        );
        vm.prank(forwarder);
        (bool ok, bytes memory ret) = address(diamond).call(abi.encodePacked(inner, client));
        assertFalse(ok, "deployAgreement refuses a forwarded call");
        assertEq(bytes4(ret), FactoryFacet.NotDiamond.selector, "and by name");

        bytes memory inner2 = abi.encodeWithSelector(
            FactoryFacet.deployAndFund.selector,
            client, executor, AMOUNT, DEADLINE, TERMS, uint8(0)
        );
        vm.prank(forwarder);
        (bool ok2, ) = address(diamond).call(abi.encodePacked(inner2, client));
        assertTrue(ok2, "deployAndFund accepts the same forwarded shape");
    }

    /// The supersede loop is bounded by the pending-request cap, so no client
    /// can make an accept unpayably long. Five requests, four refunded inside
    /// one hire.
    function testTheSupersedeLoopIsBoundedByThePendingCap() public {
        vm.prank(executor);
        uint256 svcId = ServiceBoardFacet(address(diamond)).mintService("t", "d", AMOUNT, DEADLINE, 0);

        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(client);
            ids[i] = ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);
        }
        // The sixth is refused, which is what bounds the loop.
        vm.prank(client);
        vm.expectRevert(ServiceBoardFacet.TooManyPendingRequests.selector);
        ServiceBoardFacet(address(diamond)).requestService(svcId, AMOUNT, DEADLINE, TERMS, 0);

        uint256 c0 = usdc.balanceOf(client);
        vm.prank(executor);
        Agreement a = Agreement(ServiceBoardFacet(address(diamond)).acceptRequest(ids[0]));

        assertEq(usdc.balanceOf(address(a)), AMOUNT, "one hired");
        assertEq(
            usdc.balanceOf(client) - c0,
            (AMOUNT + AMOUNT_FEE - FEE_FLOOR) * 4,
            "four refunded, each less its floor"
        );
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond keeps nothing");
        _assertDiamondBalances("after a five-wide supersede");
    }
}
