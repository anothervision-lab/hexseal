// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Adversarial access-control test suite.
// Every test asserts that an unauthorized actor receives the correct revert
// and cannot read state as if they had the missing permission.
//
// Sections:
//   A. Board access control  (JobBoard + ServiceBoard)
//   B. Agreement access control
//   C. ArbiterRegistry access control (commit-reveal + double-claim)

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/Agreement.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";

// ---------- MOCK USDC ----------

contract MockUSDCAdv {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
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
}

// ---------- MOCK ZERO-RETURNING AGREEMENT DEPLOYER ----------
// Imitates a future (hypothetical) deployer that does not check its own CREATE
// result — unlike src/AgreementDeployer.sol, which carries a
// require(addr != address(0), ...). It exists to prove that the zero-check in
// FactoryFacet/JobBoardFacet really does insure against such a deployer, rather
// than merely duplicating somebody else's guard.
contract MockZeroAgreementDeployer is IAgreementDeployer {
    function deploy(
        address, address, address,
        uint256, uint256, string calldata,
        address, address, address, address
    ) external pure returns (address) {
        return address(0);
    }
}

// ---------- TEST ----------

contract AdversarialAccessTest is Test {
    DiamondProxy  diamond;
    MockUSDCAdv   usdc;

    address owner;
    address client;
    address executor;
    address arbiter;
    address arbiter2;
    address stranger;
    address feeRecipient;

    uint8   constant REGION     = 0;
    uint256 constant BOARD_FEE  = 2_000_000; // JobBoard/ServiceBoard: still region-priced (Task 3/4)
    uint256 constant JOB_AMOUNT = 100_000_000;
    uint256 constant SVC_AMOUNT =  80_000_000;
    // ServiceBoard requestService now prices by quote(): max(SVC_AMOUNT * 500 /
    // 10_000, 1_000_000) = 5% of SVC_AMOUNT.
    uint256 constant SVC_FEE    =  4_000_000;
    // FactoryFacet direct paths (deployAgreement/deployAndFund) price by
    // quote(): max(JOB_AMOUNT * 500 / 10_000, 1_000_000) = 5% of JOB_AMOUNT.
    uint256 constant DIRECT_FEE = 5_000_000;
    uint256 constant DEADLINE   = 7;
    string constant TERMS = "Standard work terms";
    bytes32 constant SALT       = bytes32("hexseal-adv-salt");
    bytes32 constant SALT2      = bytes32("hexseal-adv-salt2");

    // ============================================================
    //  SETUP
    // ============================================================

    function setUp() public {
        owner       = address(this);
        client      = address(0x1);
        executor    = address(0x2);
        arbiter     = address(0x3);
        arbiter2    = address(0x4);
        stranger    = address(0x5);
        feeRecipient = address(0x6);

        usdc = new MockUSDCAdv();
        usdc.mint(client,   500_000_000);
        usdc.mint(executor, 200_000_000);

        RegistryFacet        registryFacet        = new RegistryFacet();
        FactoryFacet         factoryFacet         = new FactoryFacet();
        DiamondCutFacet      diamondCutFacet      = new DiamondCutFacet();
        DiamondLoupeFacet    diamondLoupeFacet    = new DiamondLoupeFacet();
        OwnershipFacet       ownershipFacet       = new OwnershipFacet();
        ArbiterRegistryFacet arbiterRegistryFacet = new ArbiterRegistryFacet();
        JobBoardFacet        jobBoardFacet        = new JobBoardFacet();
        ServiceBoardFacet    serviceBoardFacet    = new ServiceBoardFacet();

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

        bytes4[] memory facSels = new bytes4[](16);
        facSels[0]  = FactoryFacet.initFactory.selector;
        facSels[1]  = FactoryFacet.deployAgreement.selector;
        facSels[2]  = FactoryFacet.setRegionFee.selector;
        facSels[3]  = FactoryFacet.setFeeRecipient.selector;
        facSels[4]  = FactoryFacet.setTrustedForwarder.selector;
        facSels[5]  = bytes4(0x16c38b3c);
        facSels[6]  = FactoryFacet.getRegionFee.selector;
        facSels[7]  = FactoryFacet.getAllFees.selector;
        facSels[8]  = FactoryFacet.getFeeRecipient.selector;
        facSels[9]  = FactoryFacet.getTrustedForwarder.selector;
        facSels[10] = bytes4(0xb187bd26);
        facSels[11] = FactoryFacet.getUsdc.selector;
        facSels[12] = bytes4(0x220f72fc);
        facSels[13] = FactoryFacet.setAgreementDeployer.selector;
        facSels[14] = FactoryFacet.deployAndFund.selector;
        facSels[15] = FactoryFacet.getFeeBps.selector;

        bytes4[] memory jobSels = new bytes4[](11);
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

        bytes4[] memory svcSels = new bytes4[](20);
        svcSels[0]  = ServiceBoardFacet.mintService.selector;
        svcSels[1]  = ServiceBoardFacet.requestService.selector;
        svcSels[2]  = ServiceBoardFacet.acceptRequest.selector;
        svcSels[3]  = ServiceBoardFacet.rejectRequest.selector;
        svcSels[4]  = ServiceBoardFacet.cancelRequest.selector;
        svcSels[5]  = ServiceBoardFacet.removeService.selector;
        svcSels[6]  = ServiceBoardFacet.pauseService.selector;
        svcSels[7]  = ServiceBoardFacet.unpauseService.selector;
        svcSels[8]  = ServiceBoardFacet.getService.selector;
        svcSels[9]  = ServiceBoardFacet.getExecutorServices.selector;
        svcSels[10] = ServiceBoardFacet.getServiceClients.selector;
        svcSels[11] = ServiceBoardFacet.getRequest.selector;
        svcSels[12] = ServiceBoardFacet.getServiceRequests.selector;
        svcSels[13] = ServiceBoardFacet.getClientRequests.selector;
        svcSels[14] = ServiceBoardFacet.totalServices.selector;
        svcSels[15] = ServiceBoardFacet.editService.selector;
        svcSels[16] = ServiceBoardFacet.totalRequests.selector;
        svcSels[17] = ServiceBoardFacet.getRequestFunds.selector;
        svcSels[18] = ServiceBoardFacet.getActiveServices.selector;
        svcSels[19] = ServiceBoardFacet.getPendingRequests.selector;

        bytes4[] memory arbSels = new bytes4[](31);
        arbSels[0] = ArbiterRegistryFacet.setChiefArbiter.selector;
        arbSels[1] = ArbiterRegistryFacet.addArbiter.selector;
        arbSels[2] = ArbiterRegistryFacet.commitDisputeClaim.selector;
        arbSels[3] = ArbiterRegistryFacet.claimDispute.selector;
        arbSels[4] = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        arbSels[5] = ArbiterRegistryFacet.clearDisputeClaim.selector;
        arbSels[6] = ArbiterRegistryFacet.getChiefArbiter.selector;
        arbSels[7] = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        arbSels[8] = ArbiterRegistryFacet.getArbiters.selector;
        arbSels[9] = ArbiterRegistryFacet.getDisputeClaimer.selector;
        arbSels[10] = ArbiterRegistryFacet.getClaimCommitment.selector;
        arbSels[11] = ArbiterRegistryFacet.activateDAO.selector;
        arbSels[12] = ArbiterRegistryFacet.applyAsArbiter.selector;
        arbSels[13] = ArbiterRegistryFacet.isDaoActive.selector;
        arbSels[14] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        arbSels[15] = ArbiterRegistryFacet.getDaoThreshold.selector;
        arbSels[16] = ArbiterRegistryFacet.submitVerdict.selector;
        arbSels[17] = ArbiterRegistryFacet.finalizeVerdict.selector;
        arbSels[18] = ArbiterRegistryFacet.overturnVerdict.selector;
        arbSels[19] = ArbiterRegistryFacet.freezeVerdict.selector;
        arbSels[20] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        arbSels[21] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        arbSels[22] = ArbiterRegistryFacet.fundVault.selector;
        arbSels[23] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        arbSels[24] = ArbiterRegistryFacet.setDAOAddress.selector;
        arbSels[25] = ArbiterRegistryFacet.getPendingVerdict.selector;
        arbSels[26] = ArbiterRegistryFacet.getVaultBalance.selector;
        arbSels[27] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        arbSels[28] = ArbiterRegistryFacet.getDAOAddress.selector;
        arbSels[29] = ArbiterRegistryFacet.clearStuckVerdict.selector;
        arbSels[30] = ArbiterRegistryFacet.raiseAppeal.selector;

        // These readers live in ArbiterAccountabilityFacet, so that is the
        // facet they have to be mounted on. Leaving them in the list above
        // would route them to a facet that does not implement them — the
        // call arrives and reverts.
        bytes4[] memory accSels = new bytes4[](2);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        accSels[1] = ArbiterAccountabilityFacet.getArbiterReward.selector;

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

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](9);
        cut[0] = IDiamondCut.FacetCut(address(registryFacet),        IDiamondCut.FacetCutAction.Add, regSels);
        cut[1] = IDiamondCut.FacetCut(address(factoryFacet),         IDiamondCut.FacetCutAction.Add, facSels);
        cut[2] = IDiamondCut.FacetCut(address(diamondCutFacet),      IDiamondCut.FacetCutAction.Add, cutSels);
        cut[3] = IDiamondCut.FacetCut(address(diamondLoupeFacet),    IDiamondCut.FacetCutAction.Add, loupeSels);
        cut[4] = IDiamondCut.FacetCut(address(ownershipFacet),       IDiamondCut.FacetCutAction.Add, ownSels);
        cut[5] = IDiamondCut.FacetCut(address(arbiterRegistryFacet), IDiamondCut.FacetCutAction.Add, arbSels);
        cut[8] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()), IDiamondCut.FacetCutAction.Add, accSels
        );
        cut[6] = IDiamondCut.FacetCut(address(jobBoardFacet),        IDiamondCut.FacetCutAction.Add, jobSels);
        cut[7] = IDiamondCut.FacetCut(address(serviceBoardFacet),    IDiamondCut.FacetCutAction.Add, svcSels);

        diamond = new DiamondProxy(owner, cut, address(0), "");

        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter2);
    }

    // ============================================================
    //  ACTION HELPERS
    // ============================================================

    function _mintJob() internal returns (uint256 jobId) {
        vm.startPrank(client);
        // JobBoard prices through quote(): max(JOB_AMOUNT * 500 / 10_000,
        // 1_000_000), numerically equal to DIRECT_FEE for the same JOB_AMOUNT.
        usdc.approve(address(diamond), JOB_AMOUNT + DIRECT_FEE);
        jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", JOB_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    function _mintService() internal returns (uint256 serviceId) {
        vm.startPrank(executor);
        usdc.approve(address(diamond), BOARD_FEE);
        serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Solidity dev", "Full-stack Web3", SVC_AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();
    }

    function _requestService(uint256 serviceId) internal returns (uint256 requestId) {
        vm.startPrank(client);
        usdc.approve(address(diamond), SVC_AMOUNT + SVC_FEE);
        requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, SVC_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    // A funded deal built the way a board builds one: the diamond calls
    // `deployAgreement` on itself (no fee moves on that call), then the client
    // funds the clone.
    function _deployFunded() internal returns (address agr) {
        vm.prank(address(diamond));
        agr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), JOB_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.startPrank(client);
        usdc.approve(agr, JOB_AMOUNT);
        Agreement(agr).fund();
        vm.stopPrank();
    }

    function _deployActive() internal returns (address agr) {
        agr = _deployFunded();
        vm.prank(executor);
        Agreement(agr).activate();
    }

    // Returns a disputed agreement with NO arbiter claimed yet.
    function _deployDisputed() internal returns (address agr) {
        agr = _deployActive();
        vm.prank(client);
        Agreement(agr).raiseDispute();
    }

    // Returns a disputed agreement WITH arbiter claimed.
    function _deployDisputedWithArbiter() internal returns (address agr) {
        agr = _deployDisputed();
        bytes32 commitment = keccak256(abi.encodePacked(agr, arbiter, SALT));
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agr, SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    // ============================================================
    //  A. BOARD ACCESS CONTROL
    // ============================================================

    function testSelfApply_Reverts() public {
        uint256 jobId = _mintJob();
        vm.prank(client);
        vm.expectRevert(JobBoardFacet.SelfApply.selector);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
    }

    function testDoubleApply_Reverts() public {
        uint256 jobId = _mintJob();
        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.AlreadyApplied.selector);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
    }

    function testAcceptJobNotClient_Reverts() public {
        uint256 jobId = _mintJob();
        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(executor);
        vm.expectRevert(JobBoardFacet.NotClient.selector);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
    }

    function testAcceptNonApplicant_Reverts() public {
        uint256 jobId = _mintJob();
        // executor never applied — client tries to accept them anyway
        vm.prank(client);
        vm.expectRevert(JobBoardFacet.NotApplicant.selector);
        JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
    }

    function testCancelJobNotClient_Reverts() public {
        uint256 jobId = _mintJob();
        vm.prank(stranger);
        vm.expectRevert(JobBoardFacet.NotClient.selector);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
    }

    function testSelfRequest_Reverts() public {
        uint256 serviceId = _mintService();
        vm.startPrank(executor);
        usdc.approve(address(diamond), SVC_AMOUNT);
        vm.expectRevert(ServiceBoardFacet.SelfRequest.selector);
        ServiceBoardFacet(address(diamond)).requestService(
            serviceId, SVC_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    function testWrongExecutorAcceptRequest_Reverts() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);
        // stranger is not the service executor
        vm.prank(stranger);
        vm.expectRevert(ServiceBoardFacet.NotExecutor.selector);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
    }

    function testDoubleAcceptRequest_Reverts() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
        // second accept on the same (now ACCEPTED) request
        vm.prank(executor);
        vm.expectRevert(ServiceBoardFacet.RequestNotPending.selector);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
    }

    function testCancelRequestNotClient_Reverts() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);
        vm.prank(stranger);
        vm.expectRevert(ServiceBoardFacet.NotClient.selector);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId);
    }

    function testRejectRequestNotExecutor_Reverts() public {
        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(serviceId);
        vm.prank(stranger);
        vm.expectRevert(ServiceBoardFacet.NotExecutor.selector);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId);
    }

    // ============================================================
    //  B. AGREEMENT ACCESS CONTROL
    // ============================================================

    function testAgreement_StrangerActivate_Reverts() public {
        address agr = _deployFunded();
        vm.prank(stranger);
        vm.expectRevert(Agreement.NotExecutor.selector);
        Agreement(agr).activate();
    }

    function testAgreement_ClientActivate_Reverts() public {
        address agr = _deployFunded();
        // Only executor can activate — client must not
        vm.prank(client);
        vm.expectRevert(Agreement.NotExecutor.selector);
        Agreement(agr).activate();
    }

    function testAgreement_StrangerMarkDone_Reverts() public {
        address agr = _deployActive();
        vm.prank(stranger);
        vm.expectRevert(Agreement.NotExecutor.selector);
        Agreement(agr).markDone();
    }

    function testAgreement_StrangerRelease_Reverts() public {
        address agr = _deployActive();
        vm.prank(executor);
        Agreement(agr).markDone();
        vm.prank(stranger);
        vm.expectRevert(Agreement.NotClient.selector);
        Agreement(agr).release();
    }

    function testAgreement_ExecutorRelease_Reverts() public {
        address agr = _deployActive();
        vm.prank(executor);
        Agreement(agr).markDone();
        // Only client can release — executor must not
        vm.prank(executor);
        vm.expectRevert(Agreement.NotClient.selector);
        Agreement(agr).release();
    }

    function testAgreement_RaiseDisputeStranger_Reverts() public {
        address agr = _deployActive();
        vm.prank(stranger);
        vm.expectRevert(Agreement.NotParty.selector);
        Agreement(agr).raiseDispute();
    }

    function testAgreement_NoArbiterResolve_Reverts() public {
        // Dispute raised but nobody claimed it → arbiter is address(0)
        address agr = _deployDisputed();
        vm.prank(stranger);
        vm.expectRevert(Agreement.NoArbiterSet.selector);
        Agreement(agr).resolveDispute(true);
    }

    function testAgreement_WrongArbiterResolve_Reverts() public {
        // Legitimate arbiter claimed the dispute; stranger tries to resolve
        address agr = _deployDisputedWithArbiter();
        vm.prank(stranger);
        vm.expectRevert(Agreement.NotArbiter.selector);
        Agreement(agr).resolveDispute(true);
    }

    // ============================================================
    //  C. ARBITERREGISTRY ACCESS CONTROL
    // ============================================================

    function testUnregisteredArbiterCommit_Reverts() public {
        // stranger is not in the registry → commit must fail
        bytes32 commitment = keccak256(abi.encodePacked(address(0xdead), stranger, SALT));
        vm.prank(stranger);
        vm.expectRevert(ArbiterRegistryFacet.NotArbiter.selector);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
    }

    function testDoubleDisputeClaim_Reverts() public {
        address agr = _deployDisputed();

        // arbiter commits and claims first
        bytes32 c1 = keccak256(abi.encodePacked(agr, arbiter, SALT));
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(c1);
        vm.roll(block.number + 1);
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agr, SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );

        // arbiter2 also committed (in same block range), but dispute is already claimed
        bytes32 c2 = keccak256(abi.encodePacked(agr, arbiter2, SALT2));
        vm.prank(arbiter2);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(c2);
        vm.roll(block.number + 1);
        vm.prank(arbiter2);
        vm.expectRevert(ArbiterRegistryFacet.AlreadyClaimed.selector);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agr, SALT2, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function testClaimWithoutCommit_Reverts() public {
        address agr = _deployDisputed();
        // arbiter skips commit step entirely
        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.CommitmentNotFound.selector);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agr, SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function testClaimSameBlock_Reverts() public {
        address agr = _deployDisputed();
        bytes32 commitment = keccak256(abi.encodePacked(agr, arbiter, SALT));
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        // No vm.roll — still in the same block
        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.CommitmentTooEarly.selector);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agr, SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function testFinalizeVerdictRejectsZeroAgreement() public {
        vm.expectRevert(ArbiterRegistryFacet.ArbiterZeroAddress.selector);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(0));
    }

    function testRaiseAppealRejectsZeroAgreement() public {
        vm.expectRevert(ArbiterRegistryFacet.ArbiterZeroAddress.selector);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(address(0));
    }

    function testClearStuckVerdictRejectsZeroAgreement() public {
        vm.prank(owner);
        vm.expectRevert(ArbiterRegistryFacet.ArbiterZeroAddress.selector);
        ArbiterRegistryFacet(address(diamond)).clearStuckVerdict(address(0));
    }

    // Proves that the zero-check in deployAndFund really does insure the protocol
    // if the owner ever plugs in a deployer without a zero-check of its own
    // (unlike the present AgreementDeployer with its require(addr != address(0))).
    function testDeployAndFundRejectsZeroAgreementFromDeployer() public {
        MockZeroAgreementDeployer zeroDeployer = new MockZeroAgreementDeployer();
        vm.prank(owner);
        FactoryFacet(address(diamond)).setAgreementDeployer(address(zeroDeployer));

        vm.startPrank(client);
        usdc.approve(address(diamond), DIRECT_FEE);
        // RegistryFacet.register() has a zero-check on `agreement` of its own,
        // which predates this one, but the errors are split per facet:
        // FactoryZeroAddress() != RegistryZeroAddress(), so a single
        // expectRevert(selector) is enough to tell "the factory's own guard
        // fired" apart from "register() caught the zero one frame later".
        vm.expectRevert(FactoryFacet.FactoryZeroAddress.selector);
        FactoryFacet(address(diamond)).deployAndFund(client, executor, JOB_AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    // Symmetrical to testDeployAndFundRejectsZeroAgreementFromDeployer above:
    // deployAgreement() got the same zero-check on the deployer's return value,
    // right after deploy() and before register(). Which guard fired is shown by
    // the error name itself: FactoryZeroAddress(), not RegistryZeroAddress()
    // from register().
    function testDeployAgreementRejectsZeroAgreementFromDeployer() public {
        MockZeroAgreementDeployer zeroDeployer = new MockZeroAgreementDeployer();
        vm.prank(owner);
        FactoryFacet(address(diamond)).setAgreementDeployer(address(zeroDeployer));

        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.FactoryZeroAddress.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), JOB_AMOUNT, DEADLINE, TERMS, REGION
        );
    }

    // There is deliberately no matching test for
    // JobBoardFacet.JobBoardZeroAddress.selector through acceptApplicant() with a
    // zero-returning deployer — that path is unreachable in practice: the nested
    // call to FactoryFacet.deployAgreement() trips over its own zero-check on the
    // deployer's return value (the very one the test above exercises) before
    // register() is ever reached, and `require(ok, "JobBoard: deploy failed")` in
    // acceptApplicant() collapses the revert data into its own string before
    // execution gets as far as abi.decode and that guard. The guard in
    // JobBoardFacet is left as it is (defence in depth, symmetrical to the guard
    // in deployAndFund), but through this path no test can reach it with the
    // present JobBoardFacet/FactoryFacet wiring.
}
