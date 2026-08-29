// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  MoneyPathBase — one diamond that carries every money path
// ============================================================
//
// WHY ANOTHER FIXTURE. BoardsFixture mounts the boards but no arbiter facets,
// DisputeSettlement mounts the arbiter facets but neither board, and
// DiamondDeathEscrowBase mounts the arbiter facets with a token that cannot
// refuse. The money audit of 26 August 2026 needs all three at once: the same
// diamond has to be able to take money in through BOTH boards and through
// direct hire, pay it out through every exit, run a real commit-reveal dispute,
// and have a token that says no in both of the two ways a real one can.
//
// The balance identity below is the reason the facets are mounted together
// rather than measured apart. "Where did the cent go" is only answerable when
// every namespace that can hold a cent is on the same proxy.
//
// Everything the tests assert is stated here as a literal or read from the
// token, never recomputed from the contract under measurement.

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/Agreement.sol";
import "../src/JobReceiptFacet.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ReputationFacet.sol";

// ---------- MOCK USDC ----------
//
// Two ways to refuse, because a real token has two. `blacklisted` REVERTS,
// which is what Circle's USDC does. `refusesSilently` returns false without
// reverting, which is what an older ERC-20 does. Code that only survives the
// first reads the second as success and loses the money off the books.

contract MockUSDCMoney {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public refusesSilently;

    function setBlacklisted(address who, bool on) external { blacklisted[who] = on; }
    function setRefusesSilently(address who, bool on) external { refusesSilently[who] = on; }

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!blacklisted[to] && !blacklisted[msg.sender], "blacklisted");
        if (refusesSilently[to]) return false;
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!blacklisted[to] && !blacklisted[from], "blacklisted");
        if (refusesSilently[to]) return false;
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function permit(address o, address s, uint256 v, uint256, uint8, bytes32, bytes32) external {
        allowance[o][s] = v;
    }
}

// ---------- FIXTURE ----------

abstract contract MoneyPathBase is Test {
    DiamondProxy   diamond;
    MockUSDCMoney  usdc;

    address owner;
    address client;
    address executor;
    address arbiterAddr;
    address feeRecipient;
    address stranger;

    // Deal sizes and the fee they imply, stated as literals. feeBps = 500,
    // feeFloor = 1_000_000 come from FactoryFacet.initFactory.
    uint256 constant AMOUNT     = 100_000_000;   // $100
    uint256 constant AMOUNT_FEE =   5_000_000;   // 5% of $100
    uint256 constant FEE_FLOOR  =   1_000_000;   // $1
    uint256 constant DEADLINE   = 7;
    uint256 constant BAG        = 1_000_000_000_000;

    uint256 constant ACTIVATION_WINDOW   = 2 days;
    uint256 constant AUTO_APPROVE_WINDOW = 2 days;
    uint256 constant DISPUTE_WINDOW      = 4 days;
    uint256 constant DEADLINE_GRACE      = 1 days;
    uint256 constant FINALIZE_DELAY      = 24 hours;

    string constant TERMS = "terms";

    function setUp() public virtual {
        owner        = address(this);
        client       = address(0x1);
        executor     = address(0x2);
        arbiterAddr  = address(0x3);
        feeRecipient = address(0x4);
        stranger     = address(0x5);

        usdc = new MockUSDCMoney();
        usdc.mint(client, BAG);
        usdc.mint(executor, BAG);
        usdc.mint(stranger, BAG);

        RegistryFacet        registryFacet   = new RegistryFacet();
        FactoryFacet         factoryFacet    = new FactoryFacet();
        DiamondCutFacet      cutFacet        = new DiamondCutFacet();
        DiamondLoupeFacet    loupeFacet      = new DiamondLoupeFacet();
        OwnershipFacet       ownFacet        = new OwnershipFacet();
        JobBoardFacet        jobFacet        = new JobBoardFacet();
        ServiceBoardFacet    svcFacet        = new ServiceBoardFacet();
        JobReceiptFacet      receiptFacet    = new JobReceiptFacet();
        ArbiterRegistryFacet arbFacet        = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet accFacet  = new ArbiterAccountabilityFacet();
        ReputationFacet      repFacet        = new ReputationFacet();

        bytes4[] memory regSels = new bytes4[](12);
        regSels[0]  = RegistryFacet.initRegistry.selector;
        regSels[1]  = RegistryFacet.register.selector;
        regSels[2]  = RegistryFacet.updateStatus.selector;
        regSels[3]  = RegistryFacet.setAuthorizedFactory.selector;
        regSels[4]  = RegistryFacet.hasActivePair.selector;
        regSels[5]  = RegistryFacet.getActivePair.selector;
        regSels[6]  = RegistryFacet.getRecord.selector;
        regSels[7]  = RegistryFacet.getByClient.selector;
        regSels[8]  = RegistryFacet.getByExecutor.selector;
        regSels[9]  = RegistryFacet.getActive.selector;
        regSels[10] = RegistryFacet.totalAgreements.selector;
        regSels[11] = RegistryFacet.authorizedFactory.selector;

        bytes4[] memory facSels = new bytes4[](18);
        facSels[0]  = FactoryFacet.initFactory.selector;
        facSels[1]  = FactoryFacet.deployAgreement.selector;
        facSels[2]  = FactoryFacet.deployAndFund.selector;
        facSels[3]  = FactoryFacet.setFeeRecipient.selector;
        facSels[4]  = FactoryFacet.setTrustedForwarder.selector;
        facSels[5]  = FactoryFacet.setAgreementDeployer.selector;
        facSels[6]  = FactoryFacet.getFeeRecipient.selector;
        facSels[7]  = FactoryFacet.getTrustedForwarder.selector;
        facSels[8]  = FactoryFacet.getUsdc.selector;
        facSels[9]  = FactoryFacet.getAgreementDeployer.selector;
        facSels[10] = FactoryFacet.setFeeBps.selector;
        facSels[11] = FactoryFacet.setFeeFloor.selector;
        facSels[12] = FactoryFacet.setMaxPendingRequests.selector;
        facSels[13] = FactoryFacet.quoteFee.selector;
        facSels[14] = FactoryFacet.getFeeFloor.selector;
        facSels[15] = FactoryFacet.getUndeliveredFees.selector;
        facSels[16] = FactoryFacet.withdrawUndeliveredFees.selector;
        facSels[17] = FactoryFacet.getFeeBps.selector;

        bytes4[] memory jobSels = new bytes4[](13);
        jobSels[0]  = JobBoardFacet.mintJob.selector;
        jobSels[1]  = JobBoardFacet.applyForJob.selector;
        jobSels[2]  = JobBoardFacet.acceptApplicant.selector;
        jobSels[3]  = JobBoardFacet.cancelJob.selector;
        jobSels[4]  = JobBoardFacet.getJob.selector;
        jobSels[5]  = JobBoardFacet.getClientJobs.selector;
        jobSels[6]  = JobBoardFacet.getApplicants.selector;
        jobSels[7]  = JobBoardFacet.withdrawApplication.selector;
        jobSels[8]  = JobBoardFacet.editJob.selector;
        jobSels[9]  = JobBoardFacet.totalJobs.selector;
        jobSels[10] = JobBoardFacet.getOpenJobs.selector;
        jobSels[11] = JobBoardFacet.getJobFeeHeld.selector;
        jobSels[12] = JobBoardFacet.mintJobWithPermit.selector;

        bytes4[] memory svcSels = new bytes4[](14);
        svcSels[0]  = ServiceBoardFacet.mintService.selector;
        svcSels[1]  = ServiceBoardFacet.requestService.selector;
        svcSels[2]  = ServiceBoardFacet.acceptRequest.selector;
        svcSels[3]  = ServiceBoardFacet.rejectRequest.selector;
        svcSels[4]  = ServiceBoardFacet.cancelRequest.selector;
        svcSels[5]  = ServiceBoardFacet.getService.selector;
        svcSels[6]  = ServiceBoardFacet.getRequest.selector;
        svcSels[7]  = ServiceBoardFacet.totalServices.selector;
        svcSels[8]  = ServiceBoardFacet.totalRequests.selector;
        svcSels[9]  = ServiceBoardFacet.getRequestFunds.selector;
        svcSels[10] = ServiceBoardFacet.getRequestFeeHeld.selector;
        svcSels[11] = ServiceBoardFacet.getPendingRequestIdsByClientAndExecutor.selector;
        svcSels[12] = ServiceBoardFacet.getPendingRequestCount.selector;
        svcSels[13] = ServiceBoardFacet.removeService.selector;

        bytes4[] memory receiptSels = new bytes4[](4);
        receiptSels[0] = JobReceiptFacet.mintJobReceipt.selector;
        receiptSels[1] = JobReceiptFacet.burnJobReceipt.selector;
        receiptSels[2] = JobReceiptFacet.isJobReceiptBurned.selector;
        receiptSels[3] = JobReceiptFacet.getTokenIdByJobId.selector;

        bytes4[] memory arbSels = new bytes4[](27);
        arbSels[0]  = ArbiterRegistryFacet.addArbiter.selector;
        arbSels[1]  = ArbiterRegistryFacet.commitDisputeClaim.selector;
        arbSels[2]  = ArbiterRegistryFacet.claimDispute.selector;
        arbSels[3]  = ArbiterRegistryFacet.clearDisputeClaim.selector;
        arbSels[4]  = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        arbSels[5]  = ArbiterRegistryFacet.getDisputeClaimer.selector;
        arbSels[6]  = ArbiterRegistryFacet.submitVerdict.selector;
        arbSels[7]  = ArbiterRegistryFacet.finalizeVerdict.selector;
        arbSels[8]  = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        arbSels[9]  = ArbiterRegistryFacet.fundVault.selector;
        arbSels[10] = ArbiterRegistryFacet.getPendingVerdict.selector;
        arbSels[11] = ArbiterRegistryFacet.getVaultBalance.selector;
        arbSels[12] = ArbiterRegistryFacet.creditDisputeFee.selector;
        arbSels[13] = ArbiterRegistryFacet.getTreasurySlice.selector;
        arbSels[14] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        arbSels[15] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        arbSels[16] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        arbSels[17] = ArbiterRegistryFacet.setArbiterFloor.selector;
        arbSels[18] = ArbiterRegistryFacet.getArbiterFloor.selector;
        arbSels[19] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;
        arbSels[20] = ArbiterRegistryFacet.fundDispute.selector;
        arbSels[21] = ArbiterRegistryFacet.getDisputeBounty.selector;
        arbSels[22] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        arbSels[23] = ArbiterRegistryFacet.getRefundableBounty.selector;
        arbSels[24] = ArbiterRegistryFacet.setDisputeDiscount.selector;
        arbSels[25] = ArbiterRegistryFacet.getDisputeDiscount.selector;
        arbSels[26] = ArbiterRegistryFacet.overturnVerdict.selector;

        bytes4[] memory accSels = new bytes4[](3);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        accSels[1] = ArbiterAccountabilityFacet.getArbiterBond.selector;
        accSels[2] = ArbiterAccountabilityFacet.getDisputeSubsidy.selector;

        bytes4[] memory repSels = new bytes4[](4);
        repSels[0] = ReputationFacet.autoAwardXP.selector;
        repSels[1] = ReputationFacet.notifyExecutorFault.selector;
        repSels[2] = ReputationFacet.getXP.selector;
        repSels[3] = ReputationFacet.getUnresolvedDisputes.selector;

        bytes4[] memory cutSels = new bytes4[](1);
        cutSels[0] = DiamondCutFacet.diamondCut.selector;

        bytes4[] memory loupeSels = new bytes4[](5);
        loupeSels[0] = DiamondLoupeFacet.facets.selector;
        loupeSels[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        loupeSels[2] = DiamondLoupeFacet.facetAddresses.selector;
        loupeSels[3] = DiamondLoupeFacet.facetAddress.selector;
        loupeSels[4] = DiamondLoupeFacet.supportsInterface.selector;

        bytes4[] memory ownSels = new bytes4[](4);
        ownSels[0] = OwnershipFacet.transferOwnership.selector;
        ownSels[1] = OwnershipFacet.owner.selector;
        ownSels[2] = OwnershipFacet.acceptOwnership.selector;
        ownSels[3] = OwnershipFacet.pendingOwner.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](11);
        cut[0]  = IDiamondCut.FacetCut(address(registryFacet), IDiamondCut.FacetCutAction.Add, regSels);
        cut[1]  = IDiamondCut.FacetCut(address(factoryFacet),  IDiamondCut.FacetCutAction.Add, facSels);
        cut[2]  = IDiamondCut.FacetCut(address(cutFacet),      IDiamondCut.FacetCutAction.Add, cutSels);
        cut[3]  = IDiamondCut.FacetCut(address(loupeFacet),    IDiamondCut.FacetCutAction.Add, loupeSels);
        cut[4]  = IDiamondCut.FacetCut(address(ownFacet),      IDiamondCut.FacetCutAction.Add, ownSels);
        cut[5]  = IDiamondCut.FacetCut(address(jobFacet),      IDiamondCut.FacetCutAction.Add, jobSels);
        cut[6]  = IDiamondCut.FacetCut(address(svcFacet),      IDiamondCut.FacetCutAction.Add, svcSels);
        cut[7]  = IDiamondCut.FacetCut(address(receiptFacet),  IDiamondCut.FacetCutAction.Add, receiptSels);
        cut[8]  = IDiamondCut.FacetCut(address(arbFacet),      IDiamondCut.FacetCutAction.Add, arbSels);
        cut[9]  = IDiamondCut.FacetCut(address(accFacet),      IDiamondCut.FacetCutAction.Add, accSels);
        cut[10] = IDiamondCut.FacetCut(address(repFacet),      IDiamondCut.FacetCutAction.Add, repSels);

        diamond = new DiamondProxy(owner, cut, address(0), "");

        Agreement impl = new Agreement();
        AgreementDeployer dep = new AgreementDeployer(address(diamond), address(impl));
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(dep)
        );
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiterAddr);

        vm.prank(client);   usdc.approve(address(diamond), type(uint256).max);
        vm.prank(executor); usdc.approve(address(diamond), type(uint256).max);
        vm.prank(stranger); usdc.approve(address(diamond), type(uint256).max);
    }

    // ============================================================
    //  THE BALANCE IDENTITY
    // ============================================================
    //
    // Everything the diamond says it holds, added up out of its own storage.
    // The other side of the comparison is the TOKEN's balanceOf — a contract
    // the diamond only ever writes to by transferring. Neither side is derived
    // from the other, so a term someone forgets to book cannot agree with
    // itself: a lock that looks at itself in the mirror is always satisfied.
    //
    // The list of terms is hand-written from FactoryStorage.Layout's own
    // comment, not generated from the facets.
    function _diamondLedger() internal view returns (uint256 total) {
        JobBoardFacet jb = JobBoardFacet(address(diamond));
        uint256 jobs = jb.totalJobs();
        for (uint256 i = 0; i < jobs; i++) {
            total += _jobFunds(i);
            total += jb.getJobFeeHeld(i);
        }

        ServiceBoardFacet sb = ServiceBoardFacet(address(diamond));
        uint256 reqs = sb.totalRequests();
        for (uint256 i = 0; i < reqs; i++) {
            total += sb.getRequestFunds(i);
            total += sb.getRequestFeeHeld(i);
        }

        total += FactoryFacet(address(diamond)).getUndeliveredFees();
        total += ArbiterRegistryFacet(address(diamond)).getVaultBalance();
        total += ArbiterRegistryFacet(address(diamond)).getTreasurySlice();

        // Per-address terms: only the actors this fixture ever funds can hold
        // one, and each is named rather than scanned.
        address[6] memory actors = [owner, client, executor, arbiterAddr, feeRecipient, stranger];
        for (uint256 i = 0; i < actors.length; i++) {
            total += ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(actors[i]);
            total += ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(actors[i]);
            total += ArbiterRegistryFacet(address(diamond)).getRefundableBounty(actors[i]);
        }

        // Bounties sit per-agreement; the caller registers the ones it made.
        for (uint256 i = 0; i < _bountyAgreements.length; i++) {
            total += ArbiterRegistryFacet(address(diamond)).getDisputeBounty(_bountyAgreements[i]);
        }
    }

    address[] internal _bountyAgreements;
    function _trackBounty(address a) internal { _bountyAgreements.push(a); }

    function _assertDiamondBalances(string memory when) internal view {
        assertEq(
            usdc.balanceOf(address(diamond)),
            _diamondLedger(),
            string.concat("diamond USDC does not add up to its own books: ", when)
        );
    }

    /// jobFunds is field 6 of JobBoardStorage.Layout and has no getter at all.
    /// Read raw, then anchored by _assertJobFundsSlot before it is believed.
    uint256 constant SLOT_JOB_FUNDS = 6;
    function _jobFunds(uint256 jobId) internal view returns (uint256) {
        bytes32 base = bytes32(uint256(JobBoardStorage.POSITION) + SLOT_JOB_FUNDS);
        return uint256(vm.load(address(diamond), keccak256(abi.encode(jobId, base))));
    }
    function _assertJobFundsSlot(uint256 jobId, uint256 expected) internal view {
        assertEq(_jobFunds(jobId), expected, "jobFunds slot offset drifted");
    }

    // ============================================================
    //  BUILDERS
    // ============================================================

    /// Job board: client posts, executor applies, client accepts.
    function _hireThroughJobBoard(uint256 amount) internal returns (Agreement a, uint256 jobId) {
        vm.prank(client);
        jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", amount, DEADLINE, TERMS, 0);
        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(client);
        a = Agreement(JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor));
    }

    /// Service board: executor posts, client requests, executor accepts.
    function _hireThroughServiceBoard(uint256 amount) internal returns (Agreement a, uint256 reqId) {
        vm.prank(executor);
        uint256 svcId = ServiceBoardFacet(address(diamond)).mintService("t", "d", amount, DEADLINE, 0);
        vm.prank(client);
        reqId = ServiceBoardFacet(address(diamond)).requestService(svcId, amount, DEADLINE, TERMS, 0);
        vm.prank(executor);
        a = Agreement(ServiceBoardFacet(address(diamond)).acceptRequest(reqId));
    }

    /// Direct hire, one transaction, money and fee together.
    function _hireDirectly(uint256 amount) internal returns (Agreement a) {
        vm.prank(client);
        a = Agreement(FactoryFacet(address(diamond)).deployAndFund(
            client, executor, amount, DEADLINE, TERMS, 0
        ));
    }

    // There was a `_hireDirectlyTwoStep` here — deployAgreement first, fund()
    // afterwards. That road is gone: `deployAgreement` takes the diamond and
    // nobody else, so a wallet cannot create an unfunded clone at all. Every
    // remaining entrance funds in the same transaction, which is the whole
    // point of closing it.

    function _activate(Agreement a) internal {
        vm.prank(executor);
        a.activate();
    }

    function _claimByArbiter(Agreement a) internal {
        bytes32 salt       = keccak256(abi.encodePacked("money-salt", address(a), block.number));
        bytes32 commitment = keccak256(abi.encodePacked(address(a), arbiterAddr, salt));
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            address(a), salt, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function _submitAndFinalize(Agreement a, bool clientWins) internal {
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), clientWins);
        vm.warp(block.timestamp + FINALIZE_DELAY + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));
    }

    /// The allowance is `amount + fee`, because the client pays the protocol
    /// fee on top of the top-up exactly as they pay it on top of the deal at
    /// hire. The fee is asked of the CHAIN rather than recomputed here: the
    /// numbers the tests assert are literals, and a helper that did the
    /// arithmetic itself would be checking the contract against its own answer.
    function _proposeExtra(Agreement a, uint256 amount) internal returns (uint256 id) {
        id = a.nextExtraId();
        vm.startPrank(client);
        usdc.approve(address(a), amount + a.quoteExtraFee(amount));
        a.proposeExtra(amount, "extra terms");
        vm.stopPrank();
    }

    /// 5% of a top-up, no floor -- the literal the scenes below compare against.
    function _extraFee(uint256 amount) internal pure returns (uint256) {
        return amount * 500 / 10_000;
    }
}
