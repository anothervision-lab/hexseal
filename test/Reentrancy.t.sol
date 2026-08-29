// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Reentrancy test suite.
// Uses a malicious ERC20 that fires a re-entry attempt during every
// USDC exit (transfer to recipient).  Each test verifies:
//   1. The reentrant call was blocked (reentrantReverted == true).
//   2. The reentrant call did NOT succeed (reentrantSucceeded == false).
//   3. Where possible, the primary call completed correctly (correct balances).
//
// Two guards are at play:
//   Agreement   — ReentrancyGuard (_status ENTERED)
//   Diamond     — DiamondGuard     (shared across all facets)
//
// triggerAutoApprove is the highest-risk function: anyone can call it,
// so the reentrancy guard is its ONLY line of defence.

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

// ============================================================
//  MALICIOUS ERC20
//  Fires one reentrant call during transfer() (exit path only).
// ============================================================

contract MaliciousUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address private _target;
    bytes   private _data;
    bool    private _armed;

    bool public reentrantReverted;
    bool public reentrantSucceeded;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        _fire();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true; // no callback on incoming transfers
    }

    /// Arm the attack for the next transfer() call.
    function arm(address target, bytes calldata data) external {
        _target = target;
        _data   = data;
        _armed  = true;
        reentrantReverted   = false;
        reentrantSucceeded  = false;
    }

    function _fire() private {
        if (!_armed) return;
        _armed = false; // one-shot
        (bool ok,) = _target.call(_data);
        if (ok) { reentrantSucceeded = true; }
        else    { reentrantReverted  = true; }
    }
}

// ============================================================
//  TEST
// ============================================================

contract ReentrancyTest is Test {
    DiamondProxy  diamond;
    MaliciousUSDC malUSDC;

    address owner;
    address client;
    address executor;
    address arbiter;
    address feeRecipient;

    uint8   constant REGION     = 0;
    uint256 constant BOARD_FEE  = 2_000_000; // ServiceBoard: still region-priced (Task 4)
    uint256 constant JOB_AMOUNT = 100_000_000;
    uint256 constant SVC_AMOUNT =  80_000_000;
    // ServiceBoard requestService now prices by quote(): max(SVC_AMOUNT * 500 /
    // 10_000, 1_000_000) = 5% of SVC_AMOUNT.
    uint256 constant SVC_FEE    =   4_000_000;
    // FactoryFacet direct path (deployAgreement) prices by quote():
    // max(JOB_AMOUNT * 500 / 10_000, 1_000_000) = 5% of JOB_AMOUNT.
    uint256 constant DIRECT_FEE = 5_000_000;
    // JobBoardFacet now prices the same way — quote(JOB_AMOUNT) numerically
    // equals DIRECT_FEE. cancelJob only burns the floor, refunding the rest.
    uint256 constant JOB_FEE    = 5_000_000;
    uint256 constant JOB_FLOOR  = 1_000_000;
    uint256 constant DEADLINE   = 7;
    string constant TERMS = "Standard work terms";
    bytes32 constant SALT       = bytes32("hexseal-reentrant-salt");

    // ============================================================
    //  SETUP
    // ============================================================

    function setUp() public {
        owner        = address(this);
        client       = address(0x1);
        executor     = address(0x2);
        arbiter      = address(0x3);
        feeRecipient = address(0x4);

        malUSDC = new MaliciousUSDC();
        malUSDC.mint(client,   500_000_000);
        malUSDC.mint(executor, 200_000_000);

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

        bytes4[] memory facSels = new bytes4[](14);
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
        arbSels[30] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;

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
            address(malUSDC), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
    }

    // ============================================================
    //  STATE HELPERS
    // ============================================================

    function _deployFunded() internal returns (address agr) {
        vm.prank(address(diamond));
        agr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), JOB_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.startPrank(client);
        malUSDC.approve(agr, JOB_AMOUNT);
        Agreement(agr).fund();
        vm.stopPrank();
    }

    function _deployActive() internal returns (address agr) {
        agr = _deployFunded();
        vm.prank(executor);
        Agreement(agr).activate();
    }

    function _deployMarkedDone() internal returns (address agr) {
        agr = _deployActive();
        vm.prank(executor);
        Agreement(agr).markDone();
    }

    function _resolveDispute(address agr, bool clientWins) internal {
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agr, clientWins);
        vm.warp(block.timestamp + 24 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
    }

    function _deployDisputed() internal returns (address agr) {
        agr = _deployActive();
        vm.prank(client);
        Agreement(agr).raiseDispute();
        // Arbiter claims the dispute
        bytes32 commitment = keccak256(abi.encodePacked(agr, arbiter, SALT));
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agr, SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function _mintJobAndAccept() internal returns (uint256 jobId, address agr) {
        vm.startPrank(client);
        malUSDC.approve(address(diamond), JOB_FEE + JOB_AMOUNT);
        jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", JOB_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
        vm.prank(executor);
        JobBoardFacet(address(diamond)).applyForJob(jobId);
        vm.prank(client);
        agr = JobBoardFacet(address(diamond)).acceptApplicant(jobId, executor);
    }

    function _mintJobOpen() internal returns (uint256 jobId) {
        vm.startPrank(client);
        malUSDC.approve(address(diamond), JOB_FEE + JOB_AMOUNT);
        jobId = JobBoardFacet(address(diamond)).mintJob(
            "Build a dApp", "Need a Solidity dev", JOB_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    function _mintServiceAndRequest() internal returns (uint256 serviceId, uint256 requestId) {
        vm.startPrank(executor);
        malUSDC.approve(address(diamond), BOARD_FEE);
        serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Solidity dev", "Full-stack Web3", SVC_AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();
        vm.startPrank(client);
        malUSDC.approve(address(diamond), SVC_AMOUNT + SVC_FEE);
        requestId = ServiceBoardFacet(address(diamond)).requestService(
            serviceId, SVC_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();
    }

    // ============================================================
    //  AGREEMENT REENTRANCY TESTS
    // ============================================================

    // triggerAutoApprove has NO access-control check — pure guard test.
    // Without the guard, a malicious ERC20 could trigger a second payout.
    function testReentrancy_TriggerAutoApprove() public {
        address agr = _deployMarkedDone();
        vm.warp(block.timestamp + 5 days + 1);

        uint256 executorBefore = malUSDC.balanceOf(executor);

        malUSDC.arm(agr, abi.encodeCall(Agreement.triggerAutoApprove, ()));
        Agreement(agr).triggerAutoApprove(); // anyone can call this

        assertTrue(malUSDC.reentrantReverted(),  "guard must block reentrant triggerAutoApprove");
        assertFalse(malUSDC.reentrantSucceeded(), "double-payout must not happen");

        // Executor received exactly one payout
        assertEq(malUSDC.balanceOf(executor), executorBefore + JOB_AMOUNT, "single payout only");
        assertEq(malUSDC.balanceOf(agr), 0, "agreement drained exactly once");
    }

    function testReentrancy_Release() public {
        address agr = _deployMarkedDone();

        uint256 executorBefore = malUSDC.balanceOf(executor);

        malUSDC.arm(agr, abi.encodeCall(Agreement.release, ()));
        vm.prank(client);
        Agreement(agr).release();

        assertTrue(malUSDC.reentrantReverted(),  "guard must block reentrant release");
        assertFalse(malUSDC.reentrantSucceeded(), "double-payout must not happen");

        assertEq(malUSDC.balanceOf(executor), executorBefore + JOB_AMOUNT, "single payout only");
        assertEq(malUSDC.balanceOf(agr), 0, "agreement drained exactly once");
    }

    function testReentrancy_TriggerActivationTimeout() public {
        address agr = _deployFunded();
        vm.warp(block.timestamp + 3 days + 1);

        uint256 clientBefore = malUSDC.balanceOf(client);

        malUSDC.arm(agr, abi.encodeCall(Agreement.triggerActivationTimeout, ()));
        vm.prank(client);
        Agreement(agr).triggerActivationTimeout();

        assertTrue(malUSDC.reentrantReverted(),  "guard must block reentrant triggerActivationTimeout");
        assertFalse(malUSDC.reentrantSucceeded(), "double-refund must not happen");

        assertEq(malUSDC.balanceOf(client), clientBefore + JOB_AMOUNT, "single refund only");
        assertEq(malUSDC.balanceOf(agr), 0, "agreement drained exactly once");
    }

    function testReentrancy_TriggerDeadlineTimeout() public {
        address agr = _deployActive();
        vm.warp(block.timestamp + DEADLINE * 1 days + 1 days + 1); // + DEADLINE_GRACE(1d)

        uint256 clientBefore = malUSDC.balanceOf(client);

        malUSDC.arm(agr, abi.encodeCall(Agreement.triggerDeadlineTimeout, ()));
        vm.prank(client);
        Agreement(agr).triggerDeadlineTimeout();

        assertTrue(malUSDC.reentrantReverted(),  "guard must block reentrant triggerDeadlineTimeout");
        assertFalse(malUSDC.reentrantSucceeded(), "double-refund must not happen");

        assertEq(malUSDC.balanceOf(client), clientBefore + JOB_AMOUNT, "single refund only");
        assertEq(malUSDC.balanceOf(agr), 0, "agreement drained exactly once");
    }

    function testReentrancy_TriggerArbiterTimeout() public {
        address agr = _deployDisputed();
        vm.warp(block.timestamp + 7 days + 1); // past DISPUTE_WINDOW

        uint256 clientBefore = malUSDC.balanceOf(client);

        malUSDC.arm(agr, abi.encodeCall(Agreement.triggerArbiterTimeout, ()));
        vm.prank(client);
        Agreement(agr).triggerArbiterTimeout();

        assertTrue(malUSDC.reentrantReverted(),  "guard must block reentrant triggerArbiterTimeout");
        assertFalse(malUSDC.reentrantSucceeded(), "double-refund must not happen");

        assertEq(malUSDC.balanceOf(client), clientBefore + JOB_AMOUNT, "single refund only");
        assertEq(malUSDC.balanceOf(agr), 0, "agreement drained exactly once");
    }

    function testReentrancy_ResolveDispute_ClientWins() public {
        address agr = _deployDisputed();

        uint256 clientBefore = malUSDC.balanceOf(client);

        // Reentrancy tries to call Agreement.resolveDispute directly — blocked by NotArbiter (arbiter=Diamond)
        malUSDC.arm(agr, abi.encodeCall(Agreement.resolveDispute, (true)));
        _resolveDispute(agr, true);

        assertTrue(malUSDC.reentrantReverted(),  "guard must block reentrant resolveDispute");
        assertFalse(malUSDC.reentrantSucceeded(), "double-refund must not happen");

        assertEq(malUSDC.balanceOf(client), clientBefore + JOB_AMOUNT, "single refund only");
        assertEq(malUSDC.balanceOf(agr), 0, "agreement drained exactly once");
    }

    function testReentrancy_ResolveDispute_ExecutorWins() public {
        address agr = _deployDisputed();

        uint256 executorBefore = malUSDC.balanceOf(executor);

        // Reentrancy tries to call Agreement.resolveDispute directly — blocked by NotArbiter (arbiter=Diamond)
        malUSDC.arm(agr, abi.encodeCall(Agreement.resolveDispute, (false)));
        _resolveDispute(agr, false);

        assertTrue(malUSDC.reentrantReverted(),  "guard must block reentrant resolveDispute");
        assertFalse(malUSDC.reentrantSucceeded(), "double-payout must not happen");

        assertEq(malUSDC.balanceOf(executor), executorBefore + JOB_AMOUNT, "single payout only");
        assertEq(malUSDC.balanceOf(agr), 0, "agreement drained exactly once");
    }

    // ============================================================
    //  DIAMOND REENTRANCY TESTS (DiamondGuard)
    // ============================================================

    function testReentrancy_CancelJob() public {
        uint256 jobId = _mintJobOpen();

        uint256 clientBefore = malUSDC.balanceOf(client);

        // Arm: on receiving the refund transfer, try to cancelJob again
        malUSDC.arm(
            address(diamond),
            abi.encodeCall(JobBoardFacet.cancelJob, (jobId))
        );
        vm.prank(client);
        JobBoardFacet(address(diamond)).cancelJob(jobId);

        assertTrue(malUSDC.reentrantReverted(),  "DiamondGuard must block reentrant cancelJob");
        assertFalse(malUSDC.reentrantSucceeded(), "double-refund must not happen");

        // Refund = amount + fee above the floor; the floor itself is forfeited.
        assertEq(malUSDC.balanceOf(client), clientBefore + JOB_AMOUNT + (JOB_FEE - JOB_FLOOR), "single refund only");
        assertEq(malUSDC.balanceOf(address(diamond)), 0, "diamond drained exactly once");
    }

    function testReentrancy_CancelRequest() public {
        (, uint256 requestId) = _mintServiceAndRequest();

        uint256 clientBefore = malUSDC.balanceOf(client);

        malUSDC.arm(
            address(diamond),
            abi.encodeCall(ServiceBoardFacet.cancelRequest, (requestId))
        );
        vm.prank(client);
        ServiceBoardFacet(address(diamond)).cancelRequest(requestId);

        assertTrue(malUSDC.reentrantReverted(),  "DiamondGuard must block reentrant cancelRequest");
        assertFalse(malUSDC.reentrantSucceeded(), "double-refund must not happen");

        // Refund = amount + fee above the floor; the floor itself is forfeited.
        assertEq(malUSDC.balanceOf(client), clientBefore + SVC_AMOUNT + (SVC_FEE - JOB_FLOOR), "single refund only");
        assertEq(malUSDC.balanceOf(address(diamond)), 0, "diamond drained exactly once");
    }

    function testReentrancy_RejectRequest() public {
        (, uint256 requestId) = _mintServiceAndRequest();

        uint256 clientBefore = malUSDC.balanceOf(client);

        malUSDC.arm(
            address(diamond),
            abi.encodeCall(ServiceBoardFacet.rejectRequest, (requestId))
        );
        vm.prank(executor);
        ServiceBoardFacet(address(diamond)).rejectRequest(requestId);

        assertTrue(malUSDC.reentrantReverted(),  "DiamondGuard must block reentrant rejectRequest");
        assertFalse(malUSDC.reentrantSucceeded(), "double-refund must not happen");

        // Refund = amount + fee above the floor; the floor itself is forfeited.
        assertEq(malUSDC.balanceOf(client), clientBefore + SVC_AMOUNT + (SVC_FEE - JOB_FLOOR), "single refund only");
        assertEq(malUSDC.balanceOf(address(diamond)), 0, "diamond drained exactly once");
    }
}
