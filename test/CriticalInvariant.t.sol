// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Money invariant test suite: at every point in every lifecycle,
// sum(all_participant_balances) == INITIAL_TOTAL.
// No funds should be created or destroyed; only moved.

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

contract MockUSDCC {
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

// ---------- TEST ----------

contract CriticalInvariantTest is Test {
    DiamondProxy diamond;
    MockUSDCC usdc;

    address owner;
    address client;
    address client2;
    address executor;
    address arbiter;
    address feeRecipient;

    uint256 constant CLIENT_USDC   = 1_000_000_000;
    uint256 constant EXECUTOR_USDC =   200_000_000;
    uint256 constant CLIENT2_USDC  =   500_000_000;
    uint256 constant INITIAL_TOTAL = CLIENT_USDC + EXECUTOR_USDC + CLIENT2_USDC;

    uint8   constant REGION     = 0;
    // ServiceBoard mintService now charges the flat anti-spam floor (fs.feeFloor) —
    // no deal amount exists yet at posting time, so there's nothing to take a % of.
    uint256 constant BOARD_FEE  = 1_000_000;
    uint256 constant JOB_AMOUNT = 100_000_000;
    uint256 constant SVC_AMOUNT =   80_000_000;
    uint256 constant SVC2_AMOUNT =  50_000_000;
    // ServiceBoard requestService now prices by quote(): max(amount * 500 /
    // 10_000, 1_000_000) — same formula, own fee per amount.
    uint256 constant SVC_FEE    =   4_000_000; // 5% of SVC_AMOUNT
    uint256 constant SVC2_FEE   =   2_500_000; // 5% of SVC2_AMOUNT
    // FactoryFacet direct paths (deployAgreement/deployAndFund) price by
    // quote(): max(JOB_AMOUNT * 500 / 10_000, 1_000_000) = 5% of JOB_AMOUNT.
    uint256 constant DIRECT_FEE = 5_000_000;
    // JobBoardFacet now prices the same way — quote(JOB_AMOUNT) numerically
    // equals DIRECT_FEE. cancelJob only burns the floor, refunding the rest.
    uint256 constant JOB_FEE    = 5_000_000;
    uint256 constant JOB_FLOOR  = 1_000_000;
    uint256 constant DEADLINE   = 7;
    string constant TERMS = "Standard work terms";
    bytes32 constant SALT       = bytes32("hexseal-invariant-salt");

    // ============================================================
    //  SETUP
    // ============================================================

    function setUp() public {
        owner       = address(this);
        client      = address(0x1);
        client2     = address(0x2);
        executor    = address(0x3);
        arbiter     = address(0x4);
        feeRecipient = address(0x5);

        usdc = new MockUSDCC();
        usdc.mint(client,   CLIENT_USDC);
        usdc.mint(client2,  CLIENT2_USDC);
        usdc.mint(executor, EXECUTOR_USDC);

        RegistryFacet        registryFacet        = new RegistryFacet();
        FactoryFacet         factoryFacet         = new FactoryFacet();
        DiamondCutFacet      diamondCutFacet      = new DiamondCutFacet();
        DiamondLoupeFacet    diamondLoupeFacet    = new DiamondLoupeFacet();
        OwnershipFacet       ownershipFacet       = new OwnershipFacet();
        ArbiterRegistryFacet arbiterRegistryFacet = new ArbiterRegistryFacet();
        JobBoardFacet        jobBoardFacet        = new JobBoardFacet();
        ServiceBoardFacet    serviceBoardFacet    = new ServiceBoardFacet();

        // ---- Registry selectors (12) ----
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

        // ---- Factory selectors (13) ----
        bytes4[] memory facSels = new bytes4[](15);
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
        facSels[13] = FactoryFacet.getFeeBps.selector;
        facSels[14] = FactoryFacet.deployAndFund.selector;

        // ---- JobBoardFacet selectors (11) ----
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

        // ---- ServiceBoardFacet selectors (20) ----
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

        // ---- ArbiterRegistryFacet selectors (13) ----
        bytes4[] memory arbSels = new bytes4[](30);
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

        // These readers live in ArbiterAccountabilityFacet, so that is the
        // facet they have to be mounted on. Leaving them in the list above
        // would route them to a facet that does not implement them — the
        // call arrives and reverts.
        bytes4[] memory accSels = new bytes4[](2);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        accSels[1] = ArbiterAccountabilityFacet.getArbiterReward.selector;

        // ---- Infrastructure selectors ----
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
            address(usdc),
            feeRecipient,
            address(0xDEAD),
            address(diamond),
            address(agDeployer)
        );
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
    }

    // ============================================================
    //  INVARIANT HELPER
    // ============================================================

    function _systemBalance(address agr) internal view returns (uint256) {
        return usdc.balanceOf(client)
             + usdc.balanceOf(client2)
             + usdc.balanceOf(executor)
             + usdc.balanceOf(feeRecipient)
             + usdc.balanceOf(address(diamond))
             + (agr != address(0) ? usdc.balanceOf(agr) : 0);
    }

    // ============================================================
    //  ACTION HELPERS
    // ============================================================

    function _mintJob() internal returns (uint256 jobId) {
        vm.startPrank(client);
        usdc.approve(address(diamond), JOB_FEE + JOB_AMOUNT);
        jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp",
            "Need a Solidity dev",
            JOB_AMOUNT,
            DEADLINE,
            TERMS,
            REGION
        );
        vm.stopPrank();
    }

    function _acceptJob(uint256 jobId) internal returns (address agr) {
        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(client);
        agr = JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
    }

    function _mintService() internal returns (uint256 serviceId) {
        vm.startPrank(executor);
        usdc.approve(address(diamond), BOARD_FEE);
        serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Solidity dev",
            "Full-stack Web3",
            SVC_AMOUNT,
            DEADLINE,
            REGION
        );
        vm.stopPrank();
    }

    function _requestService(address buyer, uint256 serviceId, uint256 amount, uint256 fee)
        internal returns (uint256 requestId)
    {
        vm.startPrank(buyer);
        usdc.approve(address(diamond), amount + fee);
        requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId,
            amount,
            DEADLINE,
            TERMS,
            REGION
        );
        vm.stopPrank();
    }

    function _claimDispute(address agr) internal {
        bytes32 commitment = keccak256(abi.encodePacked(agr, arbiter, SALT));
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agr, SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function _resolveDispute(address agr, bool clientWins) internal {
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agr, clientWins);
        vm.warp(block.timestamp + 24 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
    }

    /// The direct road, which is `deployAndFund` and nothing else now:
    /// `deployAgreement` takes the diamond alone, so the two-step direct hire
    /// that used to stand here cannot be walked from a wallet any more.
    function _deployAndFundDirectly() internal returns (address agr) {
        vm.startPrank(client);
        usdc.approve(address(diamond), JOB_AMOUNT + DIRECT_FEE);
        agr = FactoryFacet(address(diamond)).deployAndFund(
            client, executor, JOB_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    // ============================================================
    //  JOB BOARD INVARIANT TESTS
    // ============================================================

    function testJobCycle_Complete_Invariant() public {
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "initial");

        uint256 jobId = _mintJob();
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after mintJob");
        assertEq(usdc.balanceOf(feeRecipient), 0, "fee held, not forwarded yet");
        assertEq(usdc.balanceOf(address(diamond)), JOB_AMOUNT + JOB_FEE, "amount + fee locked in diamond");

        address agr = _acceptJob(jobId);
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after accept");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond empty after accept");
        assertEq(usdc.balanceOf(agr), JOB_AMOUNT, "amount in agreement");

        vm.prank(executor);
        Agreement(agr).activate();
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after activate");

        vm.prank(executor);
        Agreement(agr).markDone();
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after markDone");

        vm.prank(client);
        Agreement(agr).release();
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after release");

        assertEq(usdc.balanceOf(feeRecipient), JOB_FEE, "fee final");
        assertEq(usdc.balanceOf(executor), EXECUTOR_USDC + JOB_AMOUNT, "executor paid");
        assertEq(usdc.balanceOf(client), CLIENT_USDC - JOB_FEE - JOB_AMOUNT, "client paid for job + fee");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    function testJobCycle_Cancel_Invariant() public {
        uint256 clientBefore = usdc.balanceOf(client);

        uint256 jobId = _mintJob();
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after mint");

        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after cancel");

        // No deal was created — only the floor is forfeited, the rest of the fee refunds
        assertEq(usdc.balanceOf(client), clientBefore - JOB_FLOOR, "client net: floor only");
        assertEq(usdc.balanceOf(feeRecipient), JOB_FLOOR, "fee recipient got the floor");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond empty");
    }

    function testJobCycle_ActivationTimeout_Invariant() public {
        uint256 clientBefore = usdc.balanceOf(client);

        uint256 jobId = _mintJob();
        address agr = _acceptJob(jobId);
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after accept");

        // Past ACTIVATION_WINDOW (3 days)
        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(client);
        Agreement(agr).triggerActivationTimeout();
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after activation timeout");

        assertEq(usdc.balanceOf(client), clientBefore - JOB_FEE, "client net: fee only");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    function testJobCycle_DeadlineTimeout_Invariant() public {
        uint256 clientBefore = usdc.balanceOf(client);

        uint256 jobId = _mintJob();
        address agr = _acceptJob(jobId);

        vm.prank(executor);
        Agreement(agr).activate();
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after activate");

        // Past deadline + DEADLINE_GRACE(1d)
        vm.warp(block.timestamp + DEADLINE * 1 days + 1 days + 1);

        vm.prank(client);
        Agreement(agr).triggerDeadlineTimeout();
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after deadline timeout");

        assertEq(usdc.balanceOf(client), clientBefore - JOB_FEE, "client net: fee only");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    function testJobCycle_AutoApprove_Invariant() public {
        uint256 jobId = _mintJob();
        address agr = _acceptJob(jobId);

        vm.prank(executor);
        Agreement(agr).activate();
        vm.prank(executor);
        Agreement(agr).markDone();
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after markDone");

        // Past AUTO_APPROVE_WINDOW (5 days)
        vm.warp(block.timestamp + 5 days + 1);

        Agreement(agr).triggerAutoApprove();
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after autoApprove");

        assertEq(usdc.balanceOf(executor), EXECUTOR_USDC + JOB_AMOUNT, "executor paid");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    // ============================================================
    //  DISPUTE INVARIANT TESTS
    // ============================================================

    function testDispute_ClientWins_Invariant() public {
        uint256 clientBefore = usdc.balanceOf(client);

        address agr = _deployAndFundDirectly();
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after fund");
        assertEq(usdc.balanceOf(agr), JOB_AMOUNT, "amount in agreement");

        vm.prank(executor);
        Agreement(agr).activate();

        vm.prank(client);
        Agreement(agr).raiseDispute();
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after raiseDispute");

        _claimDispute(agr);

        _resolveDispute(agr, true);
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after resolve client wins");

        // Client only lost the direct-deploy fee; amount returned
        assertEq(usdc.balanceOf(client), clientBefore - DIRECT_FEE, "client net: fee only");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    function testDispute_ExecutorWins_Invariant() public {
        uint256 executorBefore = usdc.balanceOf(executor);

        address agr = _deployAndFundDirectly();
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after fund");

        vm.prank(executor);
        Agreement(agr).activate();

        vm.prank(executor);
        Agreement(agr).raiseDispute();
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after raiseDispute");

        _claimDispute(agr);

        _resolveDispute(agr, false);
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after resolve executor wins");

        assertEq(usdc.balanceOf(executor), executorBefore + JOB_AMOUNT, "executor got full amount");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    // ============================================================
    //  SERVICE BOARD INVARIANT TESTS
    // ============================================================

    function testServiceCycle_Complete_Invariant() public {
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "initial");

        uint256 serviceId = _mintService();
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after mintService");
        assertEq(usdc.balanceOf(feeRecipient), BOARD_FEE, "fee to recipient");

        uint256 requestId = _requestService(client, serviceId, SVC_AMOUNT, SVC_FEE);
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after request");
        assertEq(usdc.balanceOf(address(diamond)), SVC_AMOUNT + SVC_FEE, "amount + fee locked in diamond");

        vm.prank(executor);
        address agr = ServiceBoardFacet(address(diamond)).acceptRequest(requestId);
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after accept");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond empty after accept");
        assertEq(usdc.balanceOf(agr), SVC_AMOUNT, "amount in agreement");
        assertEq(usdc.balanceOf(feeRecipient), BOARD_FEE + SVC_FEE, "request fee forwarded on accept");

        vm.prank(executor);
        Agreement(agr).activate();
        vm.prank(executor);
        Agreement(agr).markDone();
        vm.prank(client);
        Agreement(agr).release();
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after release");

        assertEq(usdc.balanceOf(executor), EXECUTOR_USDC - BOARD_FEE + SVC_AMOUNT, "executor net");
        assertEq(usdc.balanceOf(client), CLIENT_USDC - SVC_AMOUNT - SVC_FEE, "client paid for service + fee");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    function testServiceCycle_RejectRequest_Invariant() public {
        uint256 clientBefore = usdc.balanceOf(client);

        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(client, serviceId, SVC_AMOUNT, SVC_FEE);
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after request");
        assertEq(usdc.balanceOf(address(diamond)), SVC_AMOUNT + SVC_FEE, "amount + fee locked");

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId);
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after reject");

        // No deal was created — only the floor is forfeited, the rest of the fee refunds
        assertEq(usdc.balanceOf(client), clientBefore - JOB_FLOOR, "client net: floor only");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond empty");
    }

    function testServiceCycle_CancelRequest_Invariant() public {
        uint256 clientBefore = usdc.balanceOf(client);

        uint256 serviceId = _mintService();
        uint256 requestId = _requestService(client, serviceId, SVC_AMOUNT, SVC_FEE);
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after request");

        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId);
        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after cancel");

        // No deal was created — only the floor is forfeited, the rest of the fee refunds
        assertEq(usdc.balanceOf(client), clientBefore - JOB_FLOOR, "client net: floor only");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond empty");
    }

    // Two concurrent requests on the same service; funds must not mix.
    // client cancels its request; executor accepts client2's — verify isolation.
    function testServiceCycle_MultiRequestFundIsolation() public {
        uint256 serviceId = _mintService();

        uint256 requestId1 = _requestService(client,  serviceId, SVC_AMOUNT, SVC_FEE);
        uint256 requestId2 = _requestService(client2, serviceId, SVC2_AMOUNT, SVC2_FEE);

        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after both requests");
        assertEq(
            usdc.balanceOf(address(diamond)),
            SVC_AMOUNT + SVC_FEE + SVC2_AMOUNT + SVC2_FEE,
            "both amounts + fees locked"
        );

        // Client cancels its own request — amount + fee above the floor comes back,
        // the floor is forfeited.
        uint256 clientBalanceBeforeCancel = usdc.balanceOf(client);
        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId1);

        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "after client cancel");
        assertEq(
            usdc.balanceOf(client),
            clientBalanceBeforeCancel + SVC_AMOUNT + (SVC_FEE - JOB_FLOOR),
            "client got own funds back minus the floor"
        );
        assertEq(usdc.balanceOf(address(diamond)), SVC2_AMOUNT + SVC2_FEE, "only client2 funds remain");

        // Executor accepts client2's request — must not touch client's returned funds
        vm.prank(executor);
        address agr = ServiceBoardFacet(address(diamond)).acceptRequest(requestId2);

        assertEq(_systemBalance(agr), INITIAL_TOTAL, "after accept client2 request");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond empty");
        assertEq(usdc.balanceOf(agr), SVC2_AMOUNT, "only client2 amount in agreement");

        // Client's refund is untouched by executor accepting client2's request
        assertEq(
            usdc.balanceOf(client),
            clientBalanceBeforeCancel + SVC_AMOUNT + (SVC_FEE - JOB_FLOOR),
            "client balance unchanged"
        );
    }

    // The auto-refund-of-siblings path inside acceptRequest (Task 5) must emit
    // what actually left the diamond for the superseded sibling — amount + fee
    // above the floor — not just the sibling's bare deal amount. A test that
    // only asserted the balance change (as testAcceptRequestSupersedesSiblingPendingFromSameClient
    // in test/Boards.t.sol already does) would pass even if the event still
    // reported the stale pre-fee value, since nothing reads the event's
    // payload back into a balance check.
    function testServiceCycle_AcceptSupersedesSiblingAndEmitsActualRefund() public {
        uint256 serviceId1 = _mintService();
        uint256 serviceId2 = _mintService();

        uint256 requestId1 = _requestService(client, serviceId1, SVC_AMOUNT, SVC_FEE);
        uint256 requestId2 = _requestService(client, serviceId2, SVC2_AMOUNT, SVC2_FEE);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ServiceBoardFacet.RequestSuperseded(requestId2, client, executor, SVC2_AMOUNT + (SVC2_FEE - JOB_FLOOR));

        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).acceptRequest(requestId1);

        ServiceBoardStorage.HireRequest memory req2 = ServiceBoardFacet(address(diamond)).getRequest(requestId2);
        assertEq(uint256(req2.status), uint256(ServiceBoardStorage.RequestStatus.SUPERSEDED), "sibling superseded");
    }
}
