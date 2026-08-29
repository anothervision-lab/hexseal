// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BoardsFixture.sol";
import "../src/Agreement.sol";

// ============================================================
// DealTermsRequired.t.sol — a deal cannot be created with no terms.
//
// The terms are the subject of the agreement and the
// only thing an arbiter has to judge a dispute by. They were stored, rendered
// into the NFT, and checked by nobody: an empty string went the whole way --
// deal created, money escrowed, dispute claimed -- and there was no subject.
//
// The guard lives in Agreement.initialize, which is the one place every deal
// passes through: FactoryFacet.deployAgreement, FactoryFacet.deployAndFund,
// JobBoardFacet.acceptApplicant and ServiceBoardFacet.acceptRequest all reach
// it through AgreementDeployer. Each of those four is measured below through
// its own front door, not through the shared one, because "they all call the
// same function" is the assumption the measurement exists to check.
// ============================================================

/// Clone level: the guard itself, with no diamond in the way.
contract DealTermsRequiredCloneTest is Test {
    Agreement         impl;
    AgreementDeployer cloneDeployer;

    address constant CALLER    = address(0xCA11E4);
    address constant CLIENT    = address(0xC11E17);
    address constant EXECUTOR  = address(0xE8EC);
    address constant DIAMOND   = address(0xD1A);
    address constant USDC_A    = address(0x05DC);
    address constant FORWARDER = address(0xF04D);

    function setUp() public {
        impl          = new Agreement();
        cloneDeployer = new AgreementDeployer(CALLER, address(impl));
    }

    function _deployWithTerms(string memory terms) internal returns (address) {
        vm.prank(CALLER);
        return cloneDeployer.deploy(
            CLIENT, EXECUTOR, address(0),
            1_000_000, 7, terms,
            DIAMOND, USDC_A, FORWARDER, DIAMOND
        );
    }

    /// THE guard. Remove the `bytes(terms_).length == 0` line in
    /// Agreement.initialize and this is the test that goes red.
    function testDeployWithEmptyTermsReverts() public {
        vm.expectRevert(Agreement.EmptyTerms.selector);
        _deployWithTerms("");
    }

    /// The same refusal reached by calling initialize() directly rather than
    /// through the deployer -- there is no path that skips it.
    function testInitializeWithEmptyTermsRevertsOnAFreshClone() public {
        // A clone that exists but has never been initialised: made by
        // deploying with real terms and then cloning the implementation again
        // through a deployer this test controls.
        AgreementDeployer bare = new AgreementDeployer(address(this), address(impl));
        vm.expectRevert(Agreement.EmptyTerms.selector);
        bare.deploy(
            CLIENT, EXECUTOR, address(0),
            1_000_000, 7, "",
            DIAMOND, USDC_A, FORWARDER, DIAMOND
        );
    }

    /// The rest of initialize still works, and the terms are stored verbatim.
    /// Without this, deleting the whole function body would also pass the
    /// test above.
    function testDeployWithRealTermsStoresThemVerbatim() public {
        Agreement a = Agreement(_deployWithTerms("Deliver a landing page by Friday"));
        assertEq(a.terms(), "Deliver a landing page by Friday", "terms not stored");
        assertEq(a.client(), CLIENT, "the rest of initialize did not run");
    }

    /// ⚠️ THIS TEST PASSES ON PURPOSE AND IS NOT A HOLE.
    ///
    /// The chain measures emptiness by length and nothing else. A single
    /// space is one byte, so it is accepted here -- and the interface is what
    /// refuses it (lib/requiredDealFields.isBlank trims before it sends).
    /// The reasoning is written out in Agreement.initialize; the short of it
    /// is that a whitespace scan costs a loop over an attacker-chosen string
    /// on every deal, cannot be defined over UTF-8 without missing U+00A0 and
    /// friends, and stops "   " while waving "." through.
    ///
    /// It is pinned as a test so that anyone who decides otherwise has to
    /// delete a line that says why, instead of quietly assuming the chain
    /// already did this.
    function testChainMeasuresLengthNotWhitespace() public {
        Agreement a = Agreement(_deployWithTerms(" "));
        assertEq(a.terms(), " ", "a one-byte string is not empty by length");
    }
}

/// Diamond level: all four doors that create a deal.
contract DealTermsRequiredBoardsTest is BoardsFixture {
    /// FactoryFacet.deployAgreement — the boards' own entrance into the
    /// factory, which bypasses every form by definition. The caller is the
    /// diamond because nobody else is let in any more.
    function testDeployAgreementWithEmptyTermsReverts() public {
        vm.prank(address(diamond));
        vm.expectRevert(Agreement.EmptyTerms.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, DEADLINE, "", REGION
        );
    }

    /// The same door with real terms still opens — otherwise the test above
    /// would pass just as well against a facet that refuses everything.
    function testDeployAgreementWithRealTermsStillWorks() public {
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, DEADLINE, TERMS, REGION
        );
        assertTrue(agreementAddr != address(0), "no agreement deployed");
        assertEq(Agreement(agreementAddr).terms(), TERMS, "terms not carried through the factory");
    }

    /// FactoryFacet.deployAndFund — the gasless twin of the door above.
    function testDeployAndFundWithEmptyTermsReverts() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        vm.expectRevert(Agreement.EmptyTerms.selector);
        FactoryFacet(address(diamond)).deployAndFund(
            client, executor, AMOUNT, DEADLINE, "", REGION
        );
        vm.stopPrank();
    }

    /// ⚠️ THE REASON THE FORM IS NOT OPTIONAL.
    ///
    /// A job posted with empty terms is accepted by the chain at POST time --
    /// JobBoardFacet checks the title and not the terms, and it is not being
    /// redeployed by this change. The refusal arrives later, when the client
    /// accepts an applicant: by then someone has read the job, applied, and
    /// been chosen. The chain is the floor, not the moment.
    ///
    /// Like the service board, JobBoardFacet reaches the factory through a raw
    /// `call` and re-reverts with its own string, so the typed EmptyTerms does
    /// not survive the hop.
    function testJobWithEmptyTermsPostsFineAndDiesAtAcceptApplicant() public {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", AMOUNT, DEADLINE, "", REGION
        );
        vm.stopPrank();

        // Posting went through. Nothing warned anybody.
        assertEq(JobBoardFacet(address(diamond)).getJob(jobId).terms, "", "job did not keep the empty terms");

        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);

        // And only now, with an applicant already chosen, does it fail.
        vm.prank(client);
        vm.expectRevert(bytes("JobBoard: deploy failed"));
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
    }

    /// The same lateness, but here it lands on the OTHER person. The client
    /// sends the request and pays; the executor is the one whose accept
    /// reverts. This is the case the interface has to catch, because the
    /// person who can fix it is not the person who sees the error.
    ///
    /// ServiceBoardFacet.acceptRequest reaches the factory through a raw
    /// `call` and re-reverts with its own string, so the typed EmptyTerms
    /// does not survive the hop — asserted as the revert that is actually
    /// observable, not as the one it would be preferable to see.
    function testServiceRequestWithEmptyTermsDiesOnTheExecutorsAccept() public {
        vm.startPrank(executor);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Landing pages", "I build landing pages", AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();

        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, AMOUNT, DEADLINE, "", REGION
        );
        vm.stopPrank();

        // The client has already paid amount + fee into the diamond.
        assertGt(usdc.balanceOf(address(diamond)), AMOUNT, "request was not funded");

        vm.prank(executor);
        vm.expectRevert(bytes("ServiceBoard: deploy failed"));
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
    }

    /// And with terms typed in, the same executor's accept goes through.
    function testServiceRequestWithRealTermsIsAccepted() public {
        vm.startPrank(executor);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Landing pages", "I build landing pages", AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();

        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        uint256 requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        vm.prank(executor);
        address agreementAddr = ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
        assertTrue(agreementAddr != address(0), "no agreement deployed");
        assertEq(Agreement(agreementAddr).terms(), TERMS, "terms not carried through the service board");
    }
}
