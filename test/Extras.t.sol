// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Extras test suite.
// Covers proposeExtra / acceptExtra / rejectExtra and the settlement
// logic that folds accepted extras into the final payout.
//
// Money invariant: sum(all balances) == INITIAL_TOTAL at every step.
// _settlePending() returns un-accepted extras to client on any finalization.

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/Agreement.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

// ---------- MOCK USDC ----------

contract MockUSDCE {
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

contract ExtrasTest is Test {
    DiamondProxy diamond;
    MockUSDCE    usdc;

    address owner;
    address client;
    address executor;
    address arbiter;
    address feeRecipient;

    uint256 constant CLIENT_USDC   = 1_000_000_000;
    uint256 constant EXECUTOR_USDC =   200_000_000;
    uint256 constant INITIAL_TOTAL = CLIENT_USDC + EXECUTOR_USDC;

    uint8   constant REGION     = 0;
    uint256 constant JOB_AMOUNT = 100_000_000;
    // FactoryFacet direct path (deployAgreement) prices by quote():
    // max(JOB_AMOUNT * 500 / 10_000, 1_000_000) = 5% of JOB_AMOUNT.
    uint256 constant DIRECT_FEE = 5_000_000;
    uint256 constant EXTRA_A    =  20_000_000; // first extra
    uint256 constant EXTRA_B    =  10_000_000; // second extra
    // A top-up pays the same 5% the deal pays, with NO floor (26 August 2026).
    // The client pays it on top and the clone HOLDS it until the executor
    // accepts; an undone proposal takes it home again.
    uint256 constant EXTRA_A_FEE = 1_000_000;  // 5% of $20
    uint256 constant EXTRA_B_FEE =   500_000;  // 5% of $10
    uint256 constant DEADLINE   = 7;
    string constant TERMS = "Standard work terms";
    string constant EXTRA_HASH = "Extra work terms";
    bytes32 constant SALT       = bytes32("hexseal-extras-salt");

    // ============================================================
    //  SETUP
    // ============================================================

    function setUp() public {
        owner        = address(this);
        client       = address(0x1);
        executor     = address(0x2);
        arbiter      = address(0x3);
        feeRecipient = address(0x4);

        usdc = new MockUSDCE();
        usdc.mint(client,   CLIENT_USDC);
        usdc.mint(executor, EXECUTOR_USDC);

        RegistryFacet        registryFacet        = new RegistryFacet();
        FactoryFacet         factoryFacet         = new FactoryFacet();
        DiamondCutFacet      diamondCutFacet      = new DiamondCutFacet();
        DiamondLoupeFacet    diamondLoupeFacet    = new DiamondLoupeFacet();
        OwnershipFacet       ownershipFacet       = new OwnershipFacet();
        ArbiterRegistryFacet arbiterRegistryFacet = new ArbiterRegistryFacet();
        ArbiterVaultFacet arbiterRegistryFacetVault = new ArbiterVaultFacet();

        bytes4[] memory regSels = new bytes4[](14);
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
        // Appended 18 September 2026: a direct hire is an OFFER, so the
        // factory registers it through registerOffer, and the clone
        // announces the acceptance. Without both mounted this rig's
        // deployAndFund reverts with "function not found".
        regSels[12] = RegistryFacet.registerOffer.selector;
        regSels[13] = RegistryFacet.notifyOfferAccepted.selector;

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

        bytes4[] memory arbSels = new bytes4[](18);
        arbSels[0] = ArbiterRegistryFacet.setChiefArbiter.selector;
        arbSels[1] = ArbiterRegistryFacet.addArbiter.selector;
        arbSels[2] = ArbiterRegistryFacet.commitDisputeClaim.selector;
        arbSels[3] = ArbiterRegistryFacet.claimDispute.selector;
        arbSels[4] = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        arbSels[5] = ArbiterRegistryFacet.clearDisputeClaim.selector;
        arbSels[6] = ArbiterRegistryFacet.activateDAO.selector;
        arbSels[7] = ArbiterRegistryFacet.applyAsArbiter.selector;
        arbSels[8] = ArbiterRegistryFacet.isDaoActive.selector;
        arbSels[9] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        arbSels[10] = ArbiterRegistryFacet.getDaoThreshold.selector;
        arbSels[11] = ArbiterRegistryFacet.submitVerdict.selector;
        arbSels[12] = ArbiterRegistryFacet.finalizeVerdict.selector;
        arbSels[13] = ArbiterRegistryFacet.overturnVerdict.selector;
        arbSels[14] = ArbiterRegistryFacet.freezeVerdict.selector;
        arbSels[15] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        arbSels[16] = ArbiterRegistryFacet.setDAOAddress.selector;
        arbSels[17] = ArbiterRegistryFacet.clearStuckVerdict.selector;
        bytes4[] memory arbSelsVault = new bytes4[](12);
        arbSelsVault[0] = ArbiterVaultFacet.getChiefArbiter.selector;
        arbSelsVault[1] = ArbiterVaultFacet.isRegisteredArbiter.selector;
        arbSelsVault[2] = ArbiterVaultFacet.getArbiters.selector;
        arbSelsVault[3] = ArbiterVaultFacet.getDisputeClaimer.selector;
        arbSelsVault[4] = ArbiterVaultFacet.getClaimCommitment.selector;
        arbSelsVault[5] = ArbiterVaultFacet.withdrawArbiterReward.selector;
        arbSelsVault[6] = ArbiterVaultFacet.fundVault.selector;
        arbSelsVault[7] = ArbiterVaultFacet.setRewardPerDispute.selector;
        arbSelsVault[8] = ArbiterVaultFacet.getPendingVerdict.selector;
        arbSelsVault[9] = ArbiterVaultFacet.getVaultBalance.selector;
        arbSelsVault[10] = ArbiterVaultFacet.getRewardPerDispute.selector;
        arbSelsVault[11] = ArbiterVaultFacet.getDAOAddress.selector;

        // These readers live in ArbiterAccountabilityFacet, so that is the
        // facet they have to be mounted on. Leaving them in the list above
        // would route them to a facet that does not implement them — the
        // call arrives and reverts.
        bytes4[] memory accSels = new bytes4[](2);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        accSels[1] = ArbiterAccountabilityFacet.getArbiterReward.selector;

        bytes4[] memory cutSels   = new bytes4[](1);
        cutSels[0] = DiamondCutFacet.diamondCut.selector;

        bytes4[] memory loupeSels = new bytes4[](5);
        loupeSels[0] = DiamondLoupeFacet.facets.selector;
        loupeSels[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        loupeSels[2] = DiamondLoupeFacet.facetAddresses.selector;
        loupeSels[3] = DiamondLoupeFacet.facetAddress.selector;
        loupeSels[4] = DiamondLoupeFacet.supportsInterface.selector;

        bytes4[] memory ownSels   = new bytes4[](4);
        ownSels[0] = OwnershipFacet.transferOwnership.selector;
        ownSels[1] = OwnershipFacet.owner.selector;
        ownSels[2] = OwnershipFacet.acceptOwnership.selector;
        ownSels[3] = OwnershipFacet.pendingOwner.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](8);
        cut[0] = IDiamondCut.FacetCut(address(registryFacet),        IDiamondCut.FacetCutAction.Add, regSels);
        cut[1] = IDiamondCut.FacetCut(address(factoryFacet),         IDiamondCut.FacetCutAction.Add, facSels);
        cut[2] = IDiamondCut.FacetCut(address(diamondCutFacet),      IDiamondCut.FacetCutAction.Add, cutSels);
        cut[3] = IDiamondCut.FacetCut(address(diamondLoupeFacet),    IDiamondCut.FacetCutAction.Add, loupeSels);
        cut[4] = IDiamondCut.FacetCut(address(ownershipFacet),       IDiamondCut.FacetCutAction.Add, ownSels);
        cut[5] = IDiamondCut.FacetCut(address(arbiterRegistryFacet), IDiamondCut.FacetCutAction.Add, arbSels);
        cut[6] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()), IDiamondCut.FacetCutAction.Add, accSels
        );
        cut[7] = IDiamondCut.FacetCut(address(arbiterRegistryFacetVault), IDiamondCut.FacetCutAction.Add, arbSelsVault);

        diamond = new DiamondProxy(owner, cut, address(0), "");

        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
        // A hand-given seat carries no bond, and since 8 September 2026 an
        // unbonded seat is refused by every arbiter door. This rig mounts the
        // registry by hand and has no applications facet, so the field is
        // written directly — slot 12 of the arbiter namespace, pinned by
        // test/StorageLayout.t.sol. No USDC moves, and nothing here refunds or
        // forfeits a bond.
        vm.store(
            address(diamond),
            keccak256(abi.encode(
                arbiter,
                uint256(0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00) + 12
            )),
            bytes32(uint256(50_000_000))
        );
    }

    // ============================================================
    //  HELPERS
    // ============================================================

    function _systemBalance(address agr) internal view returns (uint256) {
        return usdc.balanceOf(client)
             + usdc.balanceOf(executor)
             + usdc.balanceOf(feeRecipient)
             + usdc.balanceOf(address(diamond))
             + (agr != address(0) ? usdc.balanceOf(agr) : 0);
    }

    // A deal in ACTIVE, hired directly: `deployAndFund` is the whole of the
    // direct road now — `deployAgreement` takes the diamond alone, so the
    // two-step version of this fixture (fee first, funding later) cannot be
    // walked from a wallet any more.
    function _deployActive() internal returns (address agr) {
        vm.startPrank(client);
        usdc.approve(address(diamond), JOB_AMOUNT + DIRECT_FEE);
        agr = FactoryFacet(address(diamond)).deployAndFund(
            client, executor, JOB_AMOUNT, DEADLINE, TERMS, REGION
        );
        vm.stopPrank();

        vm.prank(executor);
        Agreement(agr).activate();
    }

    function _proposeExtra(address agr, uint256 amount) internal returns (uint256 extraId) {
        vm.startPrank(client);
        // amount + the protocol's 5%: the client pays the top-up fee on top,
        // and one allowance covers both halves of the one transferFrom.
        usdc.approve(agr, amount + Agreement(agr).quoteExtraFee(amount));
        Agreement(agr).proposeExtra(amount, EXTRA_HASH);
        vm.stopPrank();
        extraId = Agreement(agr).nextExtraId() - 1;
    }

    function _claimDispute(address agr) internal {
        vm.prank(client);
        Agreement(agr).raiseDispute();
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

    // ============================================================
    //  HAPPY PATH — ACCEPTED EXTRAS
    // ============================================================

    function testExtras_AcceptedPaidOnRelease() public {
        address agr = _deployActive();

        uint256 extraId = _proposeExtra(agr, EXTRA_A);
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "invariant after propose");
        assertEq(usdc.balanceOf(agr), JOB_AMOUNT + EXTRA_A + EXTRA_A_FEE, "extra and its held fee locked in agreement");
        assertEq(Agreement(agr).pendingExtraFeeTotal(), EXTRA_A_FEE, "fee held, not yet collected");
        assertEq(Agreement(agr).pendingExtrasTotal(), EXTRA_A, "pending tracked");

        vm.prank(executor);
        Agreement(agr).acceptExtra(extraId);
        assertEq(Agreement(agr).extrasTotal(),        EXTRA_A, "moved to accepted");
        assertEq(Agreement(agr).pendingExtrasTotal(), 0,       "pending cleared");
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "invariant after accept");

        vm.prank(executor);
        Agreement(agr).markDone();
        vm.prank(client);
        Agreement(agr).release();

        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "invariant after release");
        assertEq(usdc.balanceOf(executor), EXECUTOR_USDC + JOB_AMOUNT + EXTRA_A, "executor got base + extra");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    function testExtras_MultipleAccepted_AllPaidOnRelease() public {
        address agr = _deployActive();

        uint256 id0 = _proposeExtra(agr, EXTRA_A);
        uint256 id1 = _proposeExtra(agr, EXTRA_B);
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "invariant after two proposals");
        assertEq(Agreement(agr).pendingExtrasTotal(), EXTRA_A + EXTRA_B);

        vm.startPrank(executor);
        Agreement(agr).acceptExtra(id0);
        Agreement(agr).acceptExtra(id1);
        vm.stopPrank();

        assertEq(Agreement(agr).extrasTotal(), EXTRA_A + EXTRA_B, "both accepted");

        vm.prank(executor);
        Agreement(agr).markDone();
        vm.prank(client);
        Agreement(agr).release();

        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "invariant after release");
        assertEq(
            usdc.balanceOf(executor),
            EXECUTOR_USDC + JOB_AMOUNT + EXTRA_A + EXTRA_B,
            "executor got base + both extras"
        );
    }

    function testExtras_AcceptedPaidOnAutoApprove() public {
        address agr = _deployActive();
        uint256 extraId = _proposeExtra(agr, EXTRA_A);

        vm.prank(executor);
        Agreement(agr).acceptExtra(extraId);
        vm.prank(executor);
        Agreement(agr).markDone();

        vm.warp(block.timestamp + 5 days + 1);
        Agreement(agr).triggerAutoApprove();

        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "invariant after autoApprove");
        assertEq(usdc.balanceOf(executor), EXECUTOR_USDC + JOB_AMOUNT + EXTRA_A, "executor got base + extra");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    // ============================================================
    //  REJECTED EXTRAS
    // ============================================================

    function testExtras_RejectedRefundedImmediately() public {
        address agr    = _deployActive();
        uint256 clientBefore = usdc.balanceOf(client);

        uint256 extraId = _proposeExtra(agr, EXTRA_A);
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "invariant after propose");

        vm.prank(executor);
        Agreement(agr).rejectExtra(extraId);

        assertEq(_systemBalance(agr), INITIAL_TOTAL, "invariant after reject");
        assertEq(usdc.balanceOf(client), clientBefore, "client fully refunded");
        assertEq(Agreement(agr).pendingExtrasTotal(), 0, "pending cleared");

        // Agreement has only the base amount
        assertEq(usdc.balanceOf(agr), JOB_AMOUNT, "only base in agreement");
    }

    function testExtras_RejectedThenNewProposal() public {
        address agr = _deployActive();

        uint256 id0 = _proposeExtra(agr, EXTRA_A);
        vm.prank(executor);
        Agreement(agr).rejectExtra(id0);

        // Client proposes again with a different amount
        uint256 id1 = _proposeExtra(agr, EXTRA_B);
        vm.prank(executor);
        Agreement(agr).acceptExtra(id1);

        vm.prank(executor);
        Agreement(agr).markDone();
        vm.prank(client);
        Agreement(agr).release();

        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "invariant after release");
        assertEq(usdc.balanceOf(executor), EXECUTOR_USDC + JOB_AMOUNT + EXTRA_B, "executor got base + accepted extra only");
    }

    // ============================================================
    //  PENDING EXTRAS RETURNED ON FINALIZATION
    // ============================================================

    // Pending extra (not accepted/rejected) must be returned to client
    // by _settlePending() on any finalization path.

    function testExtras_PendingReturnedOnDeadlineTimeout() public {
        address agr = _deployActive();
        uint256 clientBefore = usdc.balanceOf(client);

        _proposeExtra(agr, EXTRA_A); // pending, not accepted
        assertEq(Agreement(agr).pendingExtrasTotal(), EXTRA_A);

        vm.warp(block.timestamp + DEADLINE * 1 days + 1 days + 1); // + DEADLINE_GRACE(1d)
        vm.prank(client);
        Agreement(agr).triggerDeadlineTimeout();

        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "invariant after timeout");
        // clientBefore is measured before proposeExtra, so EXTRA_A nets to zero:
        // client paid EXTRA_A into agreement, _settlePending returned it, payout added JOB_AMOUNT.
        assertEq(usdc.balanceOf(client), clientBefore + JOB_AMOUNT, "client refunded base + pending extra");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    function testExtras_MixedPendingAndAccepted_CorrectSplit() public {
        // EXTRA_A accepted (→ executor), EXTRA_B pending (→ client on refund)
        address agr = _deployActive();

        uint256 id0 = _proposeExtra(agr, EXTRA_A);
        _proposeExtra(agr, EXTRA_B); // id1 stays pending — only the effect is needed

        vm.prank(executor);
        Agreement(agr).acceptExtra(id0);

        assertEq(Agreement(agr).extrasTotal(),        EXTRA_A, "accepted");
        assertEq(Agreement(agr).pendingExtrasTotal(), EXTRA_B, "pending");

        // Deadline timeout: executor gets nothing (refund path), client gets base + pending
        vm.warp(block.timestamp + DEADLINE * 1 days + 1 days + 1); // + DEADLINE_GRACE(1d)
        vm.prank(client);
        Agreement(agr).triggerDeadlineTimeout();

        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "invariant final");
        // _settlePending → EXTRA_B back to client
        // _complete(REFUNDED) → JOB_AMOUNT + EXTRA_A (extrasTotal) back to client
        // total refund = JOB_AMOUNT + EXTRA_A + EXTRA_B
        uint256 clientNet = usdc.balanceOf(client);
        // client started with CLIENT_USDC and paid DIRECT_FEE + JOB_AMOUNT
        // + EXTRA_A + EXTRA_B, plus the top-up fee on each of the two.
        // Back: JOB_AMOUNT + EXTRA_A + EXTRA_B, and EXTRA_B's held fee with it
        // -- it was never accepted, so it was never earned. EXTRA_A's fee WAS
        // earned, at the moment the executor accepted it, and stays with the
        // protocol even though the deal later refunded: that is what the deal's
        // own fee does too.
        assertEq(clientNet, CLIENT_USDC - DIRECT_FEE - EXTRA_A_FEE, "client net: both fees, no more");
        assertEq(usdc.balanceOf(feeRecipient), DIRECT_FEE + EXTRA_A_FEE, "and the protocol has exactly those");
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    function testExtras_PendingReturnedOnDisputeClientWins() public {
        address agr = _deployActive();

        _proposeExtra(agr, EXTRA_A); // pending
        _claimDispute(agr);

        _resolveDispute(agr, true); // client wins

        assertEq(_systemBalance(address(0)), INITIAL_TOTAL, "invariant final");
        // client gets JOB_AMOUNT + EXTRA_A (pending returned by _settlePending)
        assertEq(usdc.balanceOf(agr), 0, "agreement empty");
    }

    // ============================================================
    //  ACCESS CONTROL
    // ============================================================

    function testExtras_OnlyClientCanPropose() public {
        address agr = _deployActive();
        vm.startPrank(executor);
        usdc.approve(agr, EXTRA_A);
        vm.expectRevert(Agreement.NotClient.selector);
        Agreement(agr).proposeExtra(EXTRA_A, EXTRA_HASH);
        vm.stopPrank();
    }

    function testExtras_OnlyExecutorCanAccept() public {
        address agr    = _deployActive();
        uint256 extraId = _proposeExtra(agr, EXTRA_A);
        vm.prank(client);
        vm.expectRevert(Agreement.NotExecutor.selector);
        Agreement(agr).acceptExtra(extraId);
    }

    function testExtras_OnlyExecutorCanReject() public {
        address agr    = _deployActive();
        uint256 extraId = _proposeExtra(agr, EXTRA_A);
        vm.prank(client);
        vm.expectRevert(Agreement.NotExecutor.selector);
        Agreement(agr).rejectExtra(extraId);
    }

    function testExtras_CannotProposeAfterMarkDone() public {
        address agr = _deployActive();
        vm.prank(executor);
        Agreement(agr).markDone();
        vm.startPrank(client);
        usdc.approve(agr, EXTRA_A);
        vm.expectRevert(Agreement.AlreadyMarkedDone.selector);
        Agreement(agr).proposeExtra(EXTRA_A, EXTRA_HASH);
        vm.stopPrank();
    }

    function testExtras_CannotAcceptAlreadyAccepted() public {
        address agr    = _deployActive();
        uint256 extraId = _proposeExtra(agr, EXTRA_A);
        vm.prank(executor);
        Agreement(agr).acceptExtra(extraId);
        vm.prank(executor);
        vm.expectRevert(Agreement.ExtraNotPending.selector);
        Agreement(agr).acceptExtra(extraId);
    }

    function testExtras_CannotRejectAlreadyRejected() public {
        address agr    = _deployActive();
        uint256 extraId = _proposeExtra(agr, EXTRA_A);
        vm.prank(executor);
        Agreement(agr).rejectExtra(extraId);
        vm.prank(executor);
        vm.expectRevert(Agreement.ExtraNotPending.selector);
        Agreement(agr).rejectExtra(extraId);
    }

    function testExtras_ZeroAmountReverts() public {
        address agr = _deployActive();
        vm.startPrank(client);
        usdc.approve(agr, 1);
        vm.expectRevert(Agreement.ZeroAmount.selector);
        Agreement(agr).proposeExtra(0, EXTRA_HASH);
        vm.stopPrank();
    }

    // ============================================================
    //  A TOP-UP CARRIES WORDS OF ITS OWN  (decision 76)
    // ============================================================
    //
    // A dispute can begin with the top-up rather than with the deal. If it
    // does, the arbiter must not find money that moved with nothing saying
    // what for. The deal itself has refused empty terms since the beginning;
    // these are the tests that say the top-up now refuses them too.

    function testExtras_EmptyTermsReverts() public {
        address agr = _deployActive();
        vm.startPrank(client);
        usdc.approve(agr, EXTRA_A + Agreement(agr).quoteExtraFee(EXTRA_A));
        vm.expectRevert(Agreement.EmptyTerms.selector);
        Agreement(agr).proposeExtra(EXTRA_A, "");
        vm.stopPrank();
    }

    /// The positive half of the same pair. Without it the test above passes in
    /// a world where proposeExtra refuses everything.
    function testExtras_NonEmptyTermsIsAccepted() public {
        address agr = _deployActive();
        uint256 extraId = _proposeExtra(agr, EXTRA_A);

        (uint256 amount, string memory terms, Agreement.ExtraStatus status) =
            Agreement(agr).extras(extraId);
        assertEq(amount, EXTRA_A, "amount not recorded");
        assertEq(terms, EXTRA_HASH, "terms not recorded");
        assertEq(uint8(status), uint8(Agreement.ExtraStatus.PENDING), "status");
    }

    /// A single character is enough. The chain's question is "was anything
    /// recorded at all", not "is this good prose" — the same answer
    /// `initialize` gives, and pinning it here stops a future minimum length
    /// from arriving unannounced.
    function testExtras_OneCharacterOfTermsIsEnough() public {
        address agr = _deployActive();
        vm.startPrank(client);
        usdc.approve(agr, EXTRA_A + Agreement(agr).quoteExtraFee(EXTRA_A));
        Agreement(agr).proposeExtra(EXTRA_A, ".");
        vm.stopPrank();
        assertEq(Agreement(agr).nextExtraId(), 1, "a one-character top-up was refused");
    }

    /// ⚠️ HALF OF THIS RULE LIVES IN THE INTERFACE, and this test says so out
    /// loud rather than leaving it to be discovered on a live deal: the chain
    /// measures LENGTH, so a string of spaces is recorded. Trimming is the
    /// frontend's job (decision 37). If this test ever goes red because the
    /// chain started refusing whitespace, that is a deliberate change of
    /// position, not a bug fix — the deal's own terms would have to move with
    /// it, or the two would disagree.
    function testExtras_WhitespaceOnlyTermsPassTheChain() public {
        address agr = _deployActive();
        vm.startPrank(client);
        usdc.approve(agr, EXTRA_A + Agreement(agr).quoteExtraFee(EXTRA_A));
        Agreement(agr).proposeExtra(EXTRA_A, "   ");
        vm.stopPrank();

        (, string memory terms, ) = Agreement(agr).extras(0);
        assertEq(terms, "   ", "the chain is expected to record whitespace, not refuse it");
    }

    /// THE REFUSAL MUST BE FREE OF CONSEQUENCE, not merely a revert. The check
    /// sits ahead of nextExtraId, ahead of the write to `extras`, ahead of
    /// pendingExtrasTotal / pendingExtraFeeTotal and ahead of the one
    /// transferFrom — so an empty top-up must leave the ledger and both
    /// balances exactly as it found them. Measured, not assumed: a check
    /// placed after the writes would still revert and still look correct.
    function testExtras_EmptyTermsMovesNothingAtAll() public {
        address agr = _deployActive();

        uint256 nextIdBefore   = Agreement(agr).nextExtraId();
        uint256 pendingBefore  = Agreement(agr).pendingExtrasTotal();
        uint256 feeTotalBefore = Agreement(agr).pendingExtraFeeTotal();
        uint256 clientBefore   = usdc.balanceOf(client);
        uint256 agrBefore      = usdc.balanceOf(agr);
        uint256 execBefore     = usdc.balanceOf(executor);

        vm.startPrank(client);
        usdc.approve(agr, EXTRA_A + Agreement(agr).quoteExtraFee(EXTRA_A));
        vm.expectRevert(Agreement.EmptyTerms.selector);
        Agreement(agr).proposeExtra(EXTRA_A, "");
        vm.stopPrank();

        assertEq(Agreement(agr).nextExtraId(),          nextIdBefore,   "nextExtraId moved");
        assertEq(Agreement(agr).pendingExtrasTotal(),   pendingBefore,  "pendingExtrasTotal moved");
        assertEq(Agreement(agr).pendingExtraFeeTotal(), feeTotalBefore, "pendingExtraFeeTotal moved");
        assertEq(usdc.balanceOf(client), clientBefore, "client paid for a refused top-up");
        assertEq(usdc.balanceOf(agr),    agrBefore,    "the clone took money for a refused top-up");
        assertEq(usdc.balanceOf(executor), execBefore, "executor balance moved");

        // Slot 0 of the ledger must be untouched, not merely uncounted.
        (uint256 amount, string memory terms, Agreement.ExtraStatus status) =
            Agreement(agr).extras(nextIdBefore);
        assertEq(amount, 0, "an amount was written for a refused top-up");
        assertEq(terms, "", "terms were written for a refused top-up");
        assertEq(uint8(status), uint8(Agreement.ExtraStatus.PENDING), "a status was written");

        // And the money is still whole across every account.
        assertEq(_systemBalance(agr), INITIAL_TOTAL, "invariant after a refused top-up");
    }

    /// The refusal must arrive BEFORE the deal's own state is consulted for
    /// money reasons — but it must not arrive before the ones that are cheaper
    /// still. This pins the order: a stranger with empty terms is told
    /// NotClient, not EmptyTerms, so the new check did not quietly take over
    /// somebody else's refusal.
    function testExtras_EmptyTermsDoesNotShadowNotClient() public {
        address agr = _deployActive();
        vm.prank(executor);
        vm.expectRevert(Agreement.NotClient.selector);
        Agreement(agr).proposeExtra(EXTRA_A, "");
    }

    /// And the other side of the same order: zero amount still wins over empty
    /// terms, so `testExtras_ZeroAmountReverts` above is not passing by
    /// accident once both are wrong at once.
    function testExtras_ZeroAmountStillWinsOverEmptyTerms() public {
        address agr = _deployActive();
        vm.prank(client);
        vm.expectRevert(Agreement.ZeroAmount.selector);
        Agreement(agr).proposeExtra(0, "");
    }
}
