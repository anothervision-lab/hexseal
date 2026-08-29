// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// DisputeSettlement test suite.
//
// Computes and deducts the 3% fee on the disputed amount
// (Agreement.disputeFee() / Agreement.resolveDispute()) and checks that a failed
// credit on the diamond does not block the closing of a dispute.
//
// THE TRAP: Agreement.arbiter is not a person. claimDispute() always makes the
// diamond itself the arbiter (Diamond-as-arbiter), so resolveDispute() is
// reachable only through the real chain
// commitDisputeClaim → claimDispute → submitVerdict → finalizeVerdict.
// A direct vm.prank(arbiterAddr); a.resolveDispute(true) reverts NotArbiter.

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/Agreement.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/MinimalForwarder.sol";

// ---------- MOCK USDC ----------
// Copied from Extras and extended with a per-address blocking switch (imitating
// a Circle-style blacklist) for testBlacklistedArbiterCannotBlockResolution.

contract MockUSDCDST {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool)    public blocked;

    error Blocked();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setBlocked(address who, bool state) external {
        blocked[who] = state;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (blocked[to]) revert Blocked();
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (blocked[to]) revert Blocked();
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

contract DisputeSettlementTest is Test {
    using stdStorage for StdStorage;

    DiamondProxy   diamond;
    MockUSDCDST    usdc;

    address owner;
    address client;
    address executor;
    address arbiterAddr;
    address feeRecipient;

    uint256 constant CLIENT_USDC = 1_000_000_000_000; // with room for the cap test (a 50k USDC deal)

    // ============================================================
    //  SETUP
    // ============================================================
    // Copied from Extras (a full real diamond, not a cut-down setup). Beyond the
    // original set of ArbiterRegistryFacet selectors, creditDisputeFee and
    // getTreasurySlice are added — Extras was written before they existed.
    // DiamondCutFacet is needed for _removeSelectorFromDiamond.

    function setUp() public {
        owner        = address(this);
        client       = address(0x1);
        executor     = address(0x2);
        arbiterAddr  = address(0x3);
        feeRecipient = address(0x4);

        usdc = new MockUSDCDST();
        usdc.mint(client, CLIENT_USDC);

        RegistryFacet        registryFacet        = new RegistryFacet();
        FactoryFacet         factoryFacet         = new FactoryFacet();
        DiamondCutFacet      diamondCutFacet      = new DiamondCutFacet();
        DiamondLoupeFacet    diamondLoupeFacet    = new DiamondLoupeFacet();
        OwnershipFacet       ownershipFacet       = new OwnershipFacet();
        ArbiterRegistryFacet arbiterRegistryFacet = new ArbiterRegistryFacet();
        ReputationFacet      reputationFacet      = new ReputationFacet();

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

        bytes4[] memory arbSels = new bytes4[](42);
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
        arbSels[30] = ArbiterRegistryFacet.creditDisputeFee.selector;
        arbSels[31] = ArbiterRegistryFacet.getTreasurySlice.selector;
        arbSels[32] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        arbSels[33] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        arbSels[34] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        arbSels[35] = ArbiterRegistryFacet.setArbiterFloor.selector;
        arbSels[36] = ArbiterRegistryFacet.getArbiterFloor.selector;
        arbSels[37] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;
        arbSels[38] = ArbiterRegistryFacet.fundDispute.selector;
        arbSels[39] = ArbiterRegistryFacet.getDisputeBounty.selector;
        arbSels[40] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        arbSels[41] = ArbiterRegistryFacet.getRefundableBounty.selector;

        // These readers live in ArbiterAccountabilityFacet, so that is the
        // facet they have to be mounted on. Leaving them in the list above
        // would route them to a facet that does not implement them — the
        // call arrives and reverts.
        bytes4[] memory accSels = new bytes4[](3);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        accSels[1] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        accSels[2] = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;

        // The counter of disputes without a verdict. The getter only — the write
        // goes straight from ArbiterRegistryFacet into the shared namespaced
        // storage, and this selector is here purely so a test can read it through
        // the diamond.
        bytes4[] memory repSels  = new bytes4[](1);
        repSels[0] = ReputationFacet.getUnresolvedDisputes.selector;

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
        cut[7] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()), IDiamondCut.FacetCutAction.Add, accSels
        );
        cut[6] = IDiamondCut.FacetCut(address(reputationFacet),      IDiamondCut.FacetCutAction.Add, repSels);

        diamond = new DiamondProxy(owner, cut, address(0), "");

        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiterAddr);
    }

    // ============================================================
    //  HELPERS
    // ============================================================

    function _createFundedAgreement(uint256 dealAmount) internal returns (address) {
        vm.prank(client);
        usdc.approve(address(diamond), type(uint256).max);
        // `deployAgreement` takes the diamond and nobody else now, so this
        // fixture stands where a board stands: acceptApplicant/acceptRequest
        // reach it as `address(this).call(...)` from inside the diamond.
        vm.prank(address(diamond));
        address a = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), dealAmount, 7, "terms", 0
        );

        usdc.mint(client, dealAmount);
        vm.startPrank(client);
        usdc.approve(a, dealAmount);
        Agreement(a).fund();
        vm.stopPrank();
        return a;
    }

    /// Drives an agreement to DISPUTED and genuinely claims it as arbiter through
    /// commit-reveal — claimDispute() requires a prior commitDisputeClaim() and at
    /// least one block between the commit and the claim (CommitmentTooEarly
    /// otherwise). raiseDispute() takes no arguments.
    function _activateAndDispute(Agreement a) internal {
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        _claimByArbiter(a);
    }

    /// A dispute claimed by an arbiter through the real commit-reveal. Pulled out
    /// of _activateAndDispute because the paid-call tests need to raise a dispute,
    /// top it up and only then claim it.
    function _claimByArbiter(Agreement a) internal {
        bytes32 salt       = keccak256(abi.encodePacked("settlement-salt", address(a), block.number));
        bytes32 commitment = keccak256(abi.encodePacked(address(a), arbiterAddr, salt));
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            address(a), salt, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    /// The real chain of executing a verdict. In production resolveDispute() is
    /// reachable ONLY this way — after claimDispute the Agreement.arbiter is the
    /// diamond itself, and finalizeVerdict calls resolveDispute in its name. A
    /// direct a.resolveDispute(...) from a human arbiter reverts NotArbiter.
    function _submitAndFinalize(Agreement a, bool clientWins) internal {
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), clientWins);
        vm.warp(block.timestamp + 24 hours + 1); // FINALIZE_DELAY (a private constant of the facet)
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));
    }

    function _removeSelectorFromDiamond(bytes4 selector) internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress:      address(0),
            action:            IDiamondCut.FacetCutAction.Remove,
            functionSelectors: sels
        });
        DiamondCutFacet(address(diamond)).diamondCut(cut, address(0), "");
    }

    /// Requires a vm.recordLogs() call before the operation under test. A check
    /// against a silent failure: without it the try/catch in resolveDispute hides
    /// a failed credit, and every assertion except the counters passes anyway.
    function _assertDisputeFeeSkippedNotEmitted() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 skippedSig = Agreement.DisputeFeeSkipped.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == skippedSig) {
                fail("DisputeFeeSkipped must not fire on the happy path");
            }
        }
    }

    function _assertDisputeFeeSkippedEmitted(uint256 expectedAmount) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 skippedSig = Agreement.DisputeFeeSkipped.selector;
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == skippedSig) {
                found = true;
                assertEq(abi.decode(logs[i].data, (uint256)), expectedAmount, "skipped amount must match the computed fee");
            }
        }
        assertTrue(found, "DisputeFeeSkipped must fire when the credit call fails");
    }

    /// Neither FeePaid nor FeeSkipped must fire — for the fee == 0 case, where the
    /// `if (fee > 0)` block is skipped whole: nothing was attempted, so there is
    /// nothing to skip either. FeeSkipped would be a LIE here: it means "the credit
    /// failed", not "there was no credit at all".
    function _assertNoDisputeFeeEventEmitted() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 paidSig    = Agreement.DisputeFeePaid.selector;
        bytes32 skippedSig = Agreement.DisputeFeeSkipped.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != paidSig, "DisputeFeePaid must not fire when there is nothing to take");
            assertTrue(logs[i].topics[0] != skippedSig, "DisputeFeeSkipped must not fire when nothing was ever attempted");
        }
    }

    // ============================================================
    //  disputeFee() — 3%, no floor, with a cap
    // ============================================================

    /// 3% of the pot, no floor and no rounding up.
    function testDisputeFeeIsThreePercent() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        assertEq(a.disputeFee(), 6_000_000, "3% of 200 USDC");
    }

    /// There is no floor: on a small deal the fee is small, not $5.
    function testDisputeFeeHasNoFloor() public {
        Agreement a = Agreement(_createFundedAgreement(10_000_000));
        assertEq(a.disputeFee(), 300_000, "3% of 10 USDC, not a 5 USDC floor");
    }

    /// The cap applies to the whole fee.
    function testDisputeFeeIsCapped() public {
        Agreement a = Agreement(_createFundedAgreement(50_000_000_000));
        assertEq(a.disputeFee(), 500_000_000, "capped at 500 USDC");
    }

    /// The invariant the removed runtime branch `fee < pot` rests on (Agreement.sol,
    /// the comment above `if (fee > 0)` in resolveDispute): with BPS < 10_000 (100%),
    /// floor(pot * BPS / 10_000) < pot for any pot >= 1, and DISPUTE_FEE_CAP only
    /// reduces the fee. Pinned here statically instead of by an unreachable runtime
    /// check that no input could exercise.
    function testDisputeFeeBpsIsBelowOneHundredPercent() public {
        Agreement impl = new Agreement();
        assertLt(impl.DISPUTE_FEE_BPS(), 10_000, "BPS must stay under 100% or the removed fee<pot branch becomes reachable");
    }

    /// The pot is so small (33 units) that 3% rounds to zero by floor — not a
    /// minimum but an honest zero: floor(33 * 300 / 10_000) = 0. Without the
    /// `fee > 0` gate this would call creditDisputeFee(0), catch ZeroAmount() in the
    /// try/catch and emit a FALSE DisputeFeeSkipped(0) where nothing was in fact
    /// skipped — no credit was ever attempted.
    function testDisputeFeeFloorsToZeroSkipsBothEvents() public {
        Agreement a = Agreement(_createFundedAgreement(33));
        assertEq(a.disputeFee(), 0, "3% of 33 units floors to zero");
        _activateAndDispute(a);

        uint256 clientBefore = usdc.balanceOf(client);

        vm.recordLogs();
        _submitAndFinalize(a, true);
        _assertNoDisputeFeeEventEmitted();

        assertEq(uint8(a.status()), uint8(Agreement.Status.RESOLVED), "the dispute must still close");
        assertEq(usdc.balanceOf(client) - clientBefore, 33, "no fee taken, winner gets the whole (tiny) pot");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 0, "nothing credited");
        assertEq(ArbiterRegistryFacet(address(diamond)).getTreasurySlice(), 0, "nothing credited");
    }

    // ============================================================
    //  resolveDispute() — the happy path: the fee really is taken
    // ============================================================

    /// The winner gets the pot minus the fee, and the arbiter and the treasury are
    /// credited. It goes through the real finalizeVerdict chain — otherwise
    /// Agreement.arbiter is the diamond rather than arbiterAddr and resolveDispute()
    /// would revert NotArbiter.
    function testResolveDisputeDeductsTheFee() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        uint256 clientBefore = usdc.balanceOf(client);

        vm.recordLogs();
        _submitAndFinalize(a, true);
        _assertDisputeFeeSkippedNotEmitted();

        assertEq(usdc.balanceOf(client) - clientBefore, 194_000_000, "client gets 97%");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 4_800_000, "arbiter 80% of the fee");
        assertEq(ArbiterRegistryFacet(address(diamond)).getTreasurySlice(), 1_200_000, "treasury 20% of the fee");
    }

    /// The same happy path, but the executor wins — the payout goes to them rather
    /// than to the client. It exercises the clientWins == false branch, which
    /// testResolveDisputeDeductsTheFee does not touch.
    function testResolveDisputeDeductsTheFeeWhenExecutorWins() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        uint256 executorBefore = usdc.balanceOf(executor);

        vm.recordLogs();
        _submitAndFinalize(a, false);
        _assertDisputeFeeSkippedNotEmitted();

        assertEq(usdc.balanceOf(executor) - executorBefore, 194_000_000, "executor gets 97%");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 4_800_000, "arbiter 80% of the fee");
        assertEq(ArbiterRegistryFacet(address(diamond)).getTreasurySlice(), 1_200_000, "treasury 20% of the fee");
    }

    /// End to end: the counters mean nothing unless real USDC stand behind them on
    /// the diamond. Not checking this would mean failing to notice if the fee were
    /// credited (the counters would rise) but really transferred elsewhere (left on
    /// the Agreement itself, say, rather than sent to the diamond): the counters
    /// would look healthy and there would be nothing to pay a withdrawal with.
    function testDisputeFeeActuallyReachesArbiterAndTreasuryWallets() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);
        _submitAndFinalize(a, true);

        uint256 arbBefore = usdc.balanceOf(arbiterAddr);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).withdrawArbiterReward();
        assertEq(usdc.balanceOf(arbiterAddr) - arbBefore, 4_800_000, "reward must actually reach the arbiter's wallet");

        uint256 recipientBefore = usdc.balanceOf(feeRecipient);
        ArbiterRegistryFacet(address(diamond)).withdrawTreasurySlice();
        assertEq(usdc.balanceOf(feeRecipient) - recipientBefore, 1_200_000, "treasury slice must actually reach the fee recipient");
    }

    // ============================================================
    //  resolveDispute() — a failed credit is tolerated, but visible
    // ============================================================

    /// The fee must not be able to block the closing of a dispute. If the credit
    /// failed, the dispute closes anyway and the fee is not taken — the money goes
    /// to the winner in full, and that is visible in an event.
    function testResolveDisputeSurvivesAFailingCredit() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        // creditDisputeFee is removed from the diamond — imitating a facet upgrade
        // that broke the taking of the fee.
        _removeSelectorFromDiamond(ArbiterRegistryFacet.creditDisputeFee.selector);

        uint256 clientBefore  = usdc.balanceOf(client);
        uint256 diamondBefore = usdc.balanceOf(address(diamond));

        vm.recordLogs();
        _submitAndFinalize(a, true);
        _assertDisputeFeeSkippedEmitted(6_000_000);

        // The credit failed, so the fee is NOT taken at all. The winner gets the
        // whole pot and not a cent settles on the diamond: from there it could never
        // be recovered, as there is no rescue function.
        assertEq(uint8(a.status()), uint8(Agreement.Status.RESOLVED), "the dispute must still close");
        assertEq(usdc.balanceOf(client) - clientBefore, 200_000_000, "no fee taken, winner gets the whole pot");
        assertEq(usdc.balanceOf(address(diamond)) - diamondBefore, 0, "not a cent may be stranded on the diamond");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 0, "nothing credited");
        assertEq(ArbiterRegistryFacet(address(diamond)).getTreasurySlice(), 0, "nothing credited");
    }

    // ============================================================
    //  resolveDispute() — a blocked arbiter does not block the closing
    // ============================================================

    /// An arbiter's address on the USDC blacklist must not prevent a dispute from
    /// being closed. The reward simply stays credited and the parties get theirs.
    /// Crediting (rather than a direct transfer) removes this risk by construction —
    /// the arbiter collects it themselves, whenever they like.
    function testBlacklistedArbiterCannotBlockResolution() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        usdc.setBlocked(arbiterAddr, true);

        vm.recordLogs();
        _submitAndFinalize(a, true);
        _assertDisputeFeeSkippedNotEmitted();

        assertEq(uint8(a.status()), uint8(Agreement.Status.RESOLVED), "the dispute must still close");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            4_800_000,
            "the reward stays credited and withdrawable later"
        );

        // And it cannot be collected yet — but that is a refused payout, not a refused closing.
        vm.prank(arbiterAddr);
        vm.expectRevert();
        ArbiterRegistryFacet(address(diamond)).withdrawArbiterReward();
    }

    // ============================================================
    //  triggerArbiterTimeout() — the pot in half if nobody took the dispute
    // ============================================================

    /// Nobody took the dispute, so the pot is split in half. Otherwise a small deal
    /// would be a free lottery for the client: no arbiter will take one on for
    /// $1.20, a timeout would return everything to the client, and the work would
    /// come free.
    function testTimeoutWithoutClaimSplitsThePot() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();
        // The other side responded: halves now mean "both showed up".
        vm.prank(executor);
        a.respondToDispute();
        assertEq(a.arbiter(), address(0), "setup: nobody claimed");

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore,   100_000_000, "half to client");
        assertEq(usdc.balanceOf(executor) - eBefore, 100_000_000, "half to executor");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// An arbiter took it on and did not finish — the earlier behaviour: everything
    /// to the client, and punish the arbiter. Halves are impossible here: dragging
    /// it out would become a strategy, and on a large deal a crook would only have
    /// to do nothing.
    function testTimeoutAfterClaimStillRefundsTheClient() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);
        assertTrue(a.arbiter() != address(0), "setup: somebody claimed");

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore,   200_000_000, "whole pot to client");
        assertEq(usdc.balanceOf(executor) - eBefore, 0,           "executor gets nothing");
    }

    /// The fee is taken on no timeout path in any case: there is no verdict, the
    /// work is not done, and there is nobody to pay.
    function testTimeoutTakesNoFee() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(ArbiterRegistryFacet(address(diamond)).getTreasurySlice(), 0, "no treasury slice");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// An odd pot: not one unit must settle in the contract. 33 units → 16 to the
    /// executor, 17 to the client (the remainder to whoever's money it was).
    function testTimeoutSplitLosesNoUnitOnAnOddPot() public {
        Agreement a = Agreement(_createFundedAgreement(33));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();
        // The other side responded: halves now mean "both showed up".
        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - eBefore, 16, "floor half to executor");
        assertEq(usdc.balanceOf(client)   - cBefore, 17, "remainder to the client");
        assertEq(usdc.balanceOf(address(a)), 0, "not one unit may be stranded");
    }

    /// Unaccepted extras are not part of the disputed amount: the executor never
    /// agreed to them. They go back to the client IN FULL and are not divided.
    function testPendingExtrasReturnWholeAndAreNotSplit() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();

        usdc.mint(client, 50_000_000);
        vm.startPrank(client);
        usdc.approve(address(a), 50_000_000 + a.quoteExtraFee(50_000_000));
        a.proposeExtra(50_000_000, "extra work");
        a.raiseDispute();
        vm.stopPrank();
        // The other side responded: halves now mean "both showed up".
        vm.prank(executor);
        a.respondToDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        // 50 back whole, together with the $2.50 fee held on the top-up (nobody
        // accepted it, so nobody earned it), plus half of 200.
        assertEq(usdc.balanceOf(client) - cBefore,   152_500_000, "pending back whole, held fee with it, plus half the pot");
        assertEq(usdc.balanceOf(executor) - eBefore, 100_000_000, "half of the pot only");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// An executor on the USDC blacklist must not freeze the deal: a timeout is the
    /// last road, and after it the agreement has neither a rescue nor a second
    /// attempt.
    ///
    /// Since 26 August 2026 the undeliverable share is BOOKED to the executor
    /// rather than handed to the client. It used to be handed over, and that
    /// was the asymmetry in miniature: two lines apart in one function, the
    /// client's undeliverable share became a debt they could pull later while
    /// the executor's was given away to the other party.
    function testBlockedExecutorCannotFreezeTheTimeout() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        usdc.setBlocked(executor, true);

        uint256 cBefore = usdc.balanceOf(client);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore, 150_000_000, "the client's own three quarters, no more");
        assertEq(a.undeliveredPayout(), 50_000_000, "the executor's quarter is owed to the executor");
        assertEq(usdc.balanceOf(address(a)), 50_000_000, "and waits in the clone for them");

        usdc.setBlocked(executor, false);
        uint256 eAfter = usdc.balanceOf(executor);
        a.withdrawUndeliveredPayout();
        assertEq(usdc.balanceOf(executor) - eAfter, 50_000_000, "pulled once the token serves them");
        assertEq(usdc.balanceOf(address(a)), 0, "nothing may stay locked");
    }

    /// A late claim is forbidden. A verdict after the window is impossible anyway
    /// (submitVerdict refuses), so such a claim carries no lawful function — it is
    /// needed only to cancel the splitting of the pot in half.
    function testCannotClaimAfterTheVerdictWindow() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        bytes32 salt       = keccak256(abi.encodePacked("late-claim", address(a), block.number));
        bytes32 commitment = keccak256(abi.encodePacked(address(a), arbiterAddr, salt));
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);

        vm.prank(arbiterAddr);
        vm.expectRevert(ArbiterRegistryFacet.DisputeWindowPassed.selector);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            address(a), salt, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    /// The same gate, but checking the money: an attempt at a late claim must not
    /// turn the split into a full refund to the client.
    function testLateClaimCannotCancelTheSplit() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();
        // The other side responded: halves now mean "both showed up".
        vm.prank(executor);
        a.respondToDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        bytes32 salt       = keccak256(abi.encodePacked("late-claim-money", address(a), block.number));
        bytes32 commitment = keccak256(abi.encodePacked(address(a), arbiterAddr, salt));
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arbiterAddr);
        try ArbiterRegistryFacet(address(diamond)).claimDispute(
            address(a), salt, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        ) {} catch {}

        assertEq(a.arbiter(), address(0), "a late claim must not stick");

        uint256 eBefore = usdc.balanceOf(executor);
        vm.prank(client);
        a.triggerArbiterTimeout();
        assertEq(usdc.balanceOf(executor) - eBefore, 100_000_000, "the split must survive");
    }

    // ============================================================
    //  releaseDisputeClaim() — no releasing after the window has closed
    // ============================================================

    /// After the window has closed a dispute cannot be released. A verdict is
    /// already impossible there and the dispute cannot be re-claimed either — so a
    /// late release does not put the dispute back into circulation, it only decides
    /// who gets the money.
    function testCannotReleaseAfterTheVerdictWindow() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(arbiterAddr);
        vm.expectRevert(ArbiterRegistryFacet.DisputeWindowPassed.selector);
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(address(a));
    }

    /// The same gate, but checking the money: a late release must not turn a full
    /// refund to the client into a split in half.
    function testLateReleaseCannotFlipTheTimeoutToASplit() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(arbiterAddr);
        try ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(address(a)) {} catch {}
        assertTrue(a.arbiter() != address(0), "a late release must not stick");

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore,   200_000_000, "whole pot still to the client");
        assertEq(usdc.balanceOf(executor) - eBefore, 0,           "the executor must gain nothing");
    }

    /// The second half of the hole: a release zeroed disputeClaims, and
    /// notifyArbiterTimeout on an empty key exits silently — an arbiter who never
    /// showed up walked away with no judging mistake at all.
    function testLateReleaseCannotDodgeTheArbiterPenalty() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        uint256 before = ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiterAddr);

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);
        vm.prank(arbiterAddr);
        try ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(address(a)) {} catch {}

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiterAddr),
            before + 1,
            "the no-show must be recorded"
        );
    }

    /// A release INSIDE the window is lawful and must work: an arbiter realised they
    /// could not cope and returned the dispute to others. The gate must not break
    /// that.
    function testReleaseInsideTheWindowStillWorks() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(address(a));

        assertEq(a.arbiter(), address(0), "the dispute goes back on the market");
    }

    /// Exactly the last second of the window — a release is still lawful. The
    /// boundary here is the same as for submitVerdict and claimDispute: the window
    /// closes STRICTLY after disputedAt + DISPUTE_WINDOW, not on that second.
    /// Without this test the gate could have been narrowed by one second (`>` →
    /// `>=`) unnoticed: the mutation passed unnoticed until this test appeared.
    function testReleaseOnTheLastSecondOfTheWindowStillWorks() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        vm.warp(a.disputedAt() + a.DISPUTE_WINDOW());

        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(address(a));

        assertEq(a.arbiter(), address(0), "the window is open through its last second");
    }

    /// The length check on the token's reply in trySafeTransfer was held by no test:
    /// it could have been thrown away and the whole suite would still have passed. A
    /// token returning fewer than 32 bytes would, without it, break abi.decode and
    /// freeze the whole pot on the deal's last road.
    function testShortTokenReplyDoesNotFreezeTheTimeout() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();
        // The other side responded: halves now mean "both showed up".
        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        // 1 byte instead of 32 — abi.decode reverts on that.
        vm.mockCall(
            address(usdc),
            abi.encodeWithSelector(bytes4(0xa9059cbb), executor, uint256(100_000_000)),
            hex"01"
        );

        uint256 cBefore = usdc.balanceOf(client);

        vm.prank(client);
        a.triggerArbiterTimeout();

        vm.clearMockedCalls();

        assertEq(usdc.balanceOf(client) - cBefore, 100_000_000, "the client's half went out");
        assertEq(a.undeliveredPayout(), 100_000_000, "the short reply became a debt, not a revert");
        assertEq(usdc.balanceOf(address(a)), 100_000_000, "and is held for the executor");
    }

    // -------- SHOWING UP IN A DISPUTE --------

    /// Raising a dispute means showing up. The second flag stays empty: that is what
    /// tells "both stated their position" from "one stayed silent".
    function testRaiseDisputeMarksTheRaiserAsPresent() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        assertTrue(a.clientResponded(), "raiser must be marked present");
        assertFalse(a.executorResponded(), "counterparty must start silent");
    }

    /// The mirror: the executor raises the dispute, so the flag is theirs.
    function testRaiseDisputeByExecutorMarksExecutor() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(executor);
        a.raiseDispute();

        assertTrue(a.executorResponded(), "raiser must be marked present");
        assertFalse(a.clientResponded(), "counterparty must start silent");
    }

    function testRespondToDisputeMarksTheCounterparty() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.prank(executor);
        a.respondToDispute();

        assertTrue(a.executorResponded(), "counterparty must be marked present");
    }

    /// A repeated response reverts — otherwise the relayer would pay for endless calls.
    function testRespondToDisputeTwiceReverts() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.prank(executor);
        a.respondToDispute();

        vm.prank(executor);
        vm.expectRevert(Agreement.AlreadyResponded.selector);
        a.respondToDispute();
    }

    /// Whoever raised it is already marked, so their response reverts too.
    function testRaiserCannotRespondAgain() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.prank(client);
        vm.expectRevert(Agreement.AlreadyResponded.selector);
        a.respondToDispute();
    }

    function testRespondToDisputeFromStrangerReverts() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.prank(address(0xBEEF));
        vm.expectRevert(Agreement.NotParty.selector);
        a.respondToDispute();
    }

    function testRespondToDisputeWithoutDisputeReverts() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();

        vm.prank(executor);
        vm.expectRevert(Agreement.NotDisputed.selector);
        a.respondToDispute();
    }

    /// The key test against front-running. Without the window gate the silent side
    /// sees the timeout transaction in the mempool, manages to respond ahead of it
    /// and turns 25/75 back into 50/50 — that is, cancels the punishment after it
    /// has already fallen.
    function testRespondToDisputeAfterWindowReverts() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(executor);
        vm.expectRevert(Agreement.WindowAlreadyPassed.selector);
        a.respondToDispute();
    }

    /// On the last second of the window a response is still accepted — the boundary
    /// is inclusive, as it is for claimDispute.
    function testRespondToDisputeOnTheLastSecondWorks() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW());

        vm.prank(executor);
        a.respondToDispute();
        assertTrue(a.executorResponded(), "last second of the window must still count");
    }

    /// After a timeout the deal is finalised, but resolvedAt stays zero — only
    /// resolveDispute sets it. Without the _finalized check one could "show up" to a
    /// closed deal.
    function testRespondToDisputeAfterFinalizationReverts() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);
        vm.prank(client);
        a.triggerArbiterTimeout();

        vm.prank(executor);
        vm.expectRevert(Agreement.AlreadyFinalized.selector);
        a.respondToDispute();
    }

    /// A response is allowed once the dispute has been claimed too: it is a useful
    /// signal of involvement and does no harm — that timeout branch does not read
    /// the flags.
    function testRespondToDisputeWorksWhileClaimed() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        vm.prank(executor);
        a.respondToDispute();
        assertTrue(a.executorResponded(), "responding must work on a claimed dispute");
    }

    function testRespondToDisputeEmitsEvent() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.expectEmit(true, false, false, false, address(a));
        emit Agreement.DisputeResponded(executor);
        vm.prank(executor);
        a.respondToDispute();
    }

    // -------- TIMEOUT: 25/75 BY WHO SHOWED UP --------

    /// Both showed up — there was simply nobody to judge, so it is split in half.
    /// That is the real meaning of the split: not "nobody noticed" but "both stated
    /// their position".
    function testTimeoutSplitsInHalfWhenBothResponded() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore,   100_000_000, "half to client");
        assertEq(usdc.balanceOf(executor) - eBefore, 100_000_000, "half to executor");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// The executor stayed silent — a quarter to them, three quarters to the client.
    function testTimeoutGivesQuarterToTheSilentExecutor() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - eBefore, 50_000_000,  "quarter to the silent executor");
        assertEq(usdc.balanceOf(client)   - cBefore, 150_000_000, "three quarters to the client");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// The mirror: the client stayed silent — a quarter to them, three quarters to
    /// the executor. Without this test the rule is easy to write one-sidedly.
    function testTimeoutGivesQuarterToTheSilentClient() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(executor);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(executor);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client)   - cBefore, 50_000_000,  "quarter to the silent client");
        assertEq(usdc.balanceOf(executor) - eBefore, 150_000_000, "three quarters to the executor");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// The remainder of the division is not lost: it is computed by subtraction and
    /// goes to whoever showed up. On a pot of 7 that is 1 to the silent one and 6 to
    /// the one who showed up, not 1 and 5.
    function testTimeoutUnansweredLosesNoUnitOnAnOddPot() public {
        Agreement a = Agreement(_createFundedAgreement(7));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        uint256 toExecutor = usdc.balanceOf(executor) - eBefore;
        uint256 toClient   = usdc.balanceOf(client)   - cBefore;

        assertEq(toExecutor, 1, "floor(7/4) to the silent executor");
        assertEq(toClient,   6, "remainder to the responder");
        assertEq(toExecutor + toClient, 7, "not a single unit may vanish");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// The executor is on the USDC blacklist and was also the silent one: their
    /// quarter is not delivered, is booked as a debt, and the transaction runs to
    /// the end. Otherwise a timeout would freeze the whole pot — and after it the
    /// deal has neither a second attempt nor a rescue function.
    function testBlockedSilentExecutorDoesNotFreezeTheTimeout() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        usdc.setBlocked(executor, true);
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);

        // The event carries executorPaid rather than toExecutor: 50 USDC were due and
        // zero arrived. Without this check, swapping one variable for the other would
        // slip past the balance assertions above — they look only at the client, to
        // whom the undelivered amount fell anyway.
        vm.expectEmit(true, false, false, true, address(a));
        emit Agreement.DisputeUnanswered(client, 150_000_000, 0);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore, 150_000_000, "the responder's own three quarters");
        assertEq(a.undeliveredPayout(), 50_000_000, "the silent side's quarter is owed to them");
        assertEq(usdc.balanceOf(address(a)), 50_000_000, "held, not confiscated");
    }

    /// The same blacklist, but the executor showed up and three quarters were due to
    /// them: the undelivered amount is booked as a debt to them.
    function testBlockedRespondingExecutorDoesNotFreezeTheTimeout() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(executor);
        a.raiseDispute();

        usdc.setBlocked(executor, true);
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);

        // The same check on the second branch (the client stayed silent, and the
        // arguments are written out in a DIFFERENT order): the executor who showed up
        // is blocked, 150 USDC were due to them, zero arrived — and the event must
        // carry zero.
        vm.expectEmit(true, false, false, true, address(a));
        emit Agreement.DisputeUnanswered(executor, 0, 50_000_000);
        vm.prank(executor);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore, 50_000_000, "the silent client's quarter, and only that");
        assertEq(a.undeliveredPayout(), 150_000_000, "the responder's three quarters are owed to them");
        assertEq(usdc.balanceOf(address(a)), 150_000_000, "held, not handed to the silent side");
    }

    /// The event carries the amounts transferred rather than the amounts intended —
    /// otherwise an interface prints a figure that never reached a wallet.
    function testTimeoutUnansweredEmitsTransferredAmounts() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.expectEmit(true, false, false, true, address(a));
        emit Agreement.DisputeUnanswered(client, 150_000_000, 50_000_000);
        vm.prank(client);
        a.triggerArbiterTimeout();
    }

    /// The same payload on the MIRROR branch — the client stayed silent. The
    /// arguments there are written out by hand a second time and in a different
    /// order: it is the only place in the contract where one event is assembled
    /// twice. The balance tests would not notice a swap of `toResponder` and
    /// `toSilent` at all (the money leaves by the same transfers), while the event is
    /// decoded positionally — into indexer fields and into notification amounts. A
    /// swap would print the silent party's quarter as the share of the one who
    /// showed up.
    function testTimeoutUnansweredEmitsResponderFirstWhenTheClientWasSilent() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(executor);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        // responder = the executor, 150 to them (three quarters), 50 to the silent client.
        vm.expectEmit(true, false, false, true, address(a));
        emit Agreement.DisputeUnanswered(executor, 150_000_000, 50_000_000);
        vm.prank(executor);
        a.triggerArbiterTimeout();
    }

    /// A split in half: the event carries the transferred amounts too, and until now
    /// no test checked it — only balances. The argument order here is the reverse of
    /// `DisputeUnanswered`'s (toClient first), so nothing stopped anybody confusing
    /// them between the two branches.
    function testTimeoutSplitEmitsTransferredAmounts() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_001));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        // The pot is odd on purpose: floor(pot/2) to the executor, the remainder to
        // the client — on equal amounts a swap of arguments would be invisible.
        vm.expectEmit(false, false, false, true, address(a));
        emit Agreement.DisputeSplitNoVerdict(100_000_001, 100_000_000);
        vm.prank(client);
        a.triggerArbiterTimeout();
    }

    /// A claimed dispute does not read the attendance flags: the fault there is the
    /// arbiter's, and the whole pot goes to the client regardless of who responded.
    function testTimeoutAfterClaimIgnoresResponseFlags() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);
        vm.prank(executor);
        a.respondToDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore, 200_000_000, "whole pot to the client");
        assertEq(usdc.balanceOf(executor) - eBefore, 0, "executor gets nothing on arbiter fault");
    }

    // -------- THE PAID CALL: THE FLOOR AND THE QUOTE --------

    /// The floor defaults to 10 USDC. It is what decides from what deal amount the
    /// service makes any sense at all.
    function testArbiterFloorDefaultsToTen() public view {
        assertEq(ArbiterRegistryFacet(address(diamond)).getArbiterFloor(), 10_000_000, "default floor is $10");
    }

    function testSetArbiterFloorOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(ArbiterRegistryFacet.NotOwner.selector);
        ArbiterRegistryFacet(address(diamond)).setArbiterFloor(15_000_000);
    }

    function testSetArbiterFloorChangesQuote() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        uint256 before_ = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        ArbiterRegistryFacet(address(diamond)).setArbiterFloor(20_000_000);
        uint256 after_ = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));

        assertEq(after_ - before_, 10_000_000, "raising the floor by $10 raises the top-up by $10");
    }

    /// A pot of $100: the fee is 3% = $3, 80% to the arbiter = $2.40, $7.60 short of $10.
    function testQuoteTopUpOnSmallPot() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        assertEq(ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a)), 7_600_000, "top-up to reach $10");
    }

    /// The pot is large enough — the arbiter gets $10 by themselves, so the top-up is
    /// zero. $10 / 0.024 = $416.67, which is why at $420 no top-up is needed any more.
    function testQuoteTopUpIsZeroOnLargePot() public {
        Agreement a = Agreement(_createFundedAgreement(420_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        assertEq(ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a)), 0, "big pot pays the arbiter by itself");
    }

    /// The quote takes the fee FROM THE DEAL rather than recomputing it. The numbers
    /// are chosen so that the fee cap is decisive: on a pot of $30 000 a correct
    /// implementation sees a capped fee of $500 → $400 to the arbiter → $50 short of
    /// the $450 floor. An implementation that computed 3% itself and forgot the cap
    /// would see $900 → $720 to the arbiter → the floor cleared → a top-up of zero.
    /// The difference between 50_000_000 and 0 is what this test guards.
    function testQuoteUsesAgreementFeeIncludingCap() public {
        Agreement a = Agreement(_createFundedAgreement(30_000_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        ArbiterRegistryFacet(address(diamond)).setArbiterFloor(450_000_000);

        assertEq(a.disputeFee(), 500_000_000, "setup: fee is capped at $500");
        assertEq(
            ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a)),
            50_000_000,
            "top-up must be computed from the CAPPED fee, not from raw 3%"
        );
    }

    function testQuoteRevertsIfNotDisputed() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();

        vm.expectRevert(ArbiterRegistryFacet.NotDisputed.selector);
        ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
    }

    // -------- THE PAID CALL: PAYMENT AND REFUND --------

    function _disputedAgreement(uint256 dealAmount) internal returns (Agreement a) {
        a = Agreement(_createFundedAgreement(dealAmount));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();
    }

    function testFundDisputePullsExactQuote() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));

        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        uint256 before_ = usdc.balanceOf(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        assertEq(before_ - usdc.balanceOf(client), need, "exactly the quoted amount is pulled");
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), need, "bounty recorded");
    }

    function testFundDisputeFromStrangerReverts() public {
        Agreement a = _disputedAgreement(100_000_000);
        vm.prank(address(0xBEEF));
        vm.expectRevert(ArbiterRegistryFacet.NotParty.selector);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
    }

    function testFundDisputeTwiceReverts() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need * 2);
        vm.startPrank(client);
        usdc.approve(address(diamond), need * 2);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        vm.expectRevert(ArbiterRegistryFacet.BountyAlreadyFunded.selector);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();
    }

    /// On a large pot no top-up is needed — there is nothing to pay, and the
    /// function says so rather than silently accepting money.
    function testFundDisputeRevertsWhenTopUpIsZero() public {
        Agreement a = _disputedAgreement(420_000_000);
        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.TopUpNotNeeded.selector);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
    }

    /// After a claim the bait has already done its work: an arbiter took it on, so
    /// there is no point paying.
    function testFundDisputeAfterClaimReverts() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        _activateAndDispute(a);

        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.DisputeAlreadyClaimed.selector);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
    }

    /// No verdict happened, so the money goes back in full to whoever paid it in.
    function testBountyRefundedOnTimeoutWithoutVerdict() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 before_ = usdc.balanceOf(client);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - before_ - 50_000_000, need, "bounty came back on top of the split half");
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty cleared");
    }

    /// Refunded exactly once: a repeated clearDisputeClaim does not pay a second time.
    function testBountyRefundHappensOnlyOnce() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);
        vm.prank(client);
        a.triggerArbiterTimeout();

        uint256 after1 = usdc.balanceOf(client);
        vm.prank(address(a));
        ArbiterRegistryFacet(address(diamond)).clearDisputeClaim(address(a));
        assertEq(usdc.balanceOf(client), after1, "second clear pays nothing");
    }

    /// A payer on the USDC blacklist must not break the release of the claim.
    /// Agreement calls clearDisputeClaim inside a swallowing catch, so a hard refund
    /// would drag openClaimCount down with it and lock the arbiter out.
    ///
    /// The EXECUTOR is blocked here rather than the client, and the executor is also
    /// the one who pays the top-up. That choice dates from when the client's share
    /// left by a hard safeTransfer on every branch of triggerArbiterTimeout, so a
    /// blocked client would have brought the trigger transaction itself down before
    /// clearDisputeClaim was ever reached. Both sides are now paid by the soft
    /// _payClient/_payExecutor, which book an undeliverable share as a debt instead
    /// of failing, so either side would do — the scene is kept as it is because it
    /// exercises the path that mattered.
    function testBlacklistedPayerDoesNotBreakClaimClearing() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(executor, need);
        vm.startPrank(executor);
        usdc.approve(address(diamond), need);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        a.respondToDispute();
        vm.stopPrank();

        usdc.setBlocked(executor, true);
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty left the dispute");
        assertEq(ArbiterRegistryFacet(address(diamond)).getRefundableBounty(executor), need, "and became claimable instead");

        usdc.setBlocked(executor, false);
        uint256 before_ = usdc.balanceOf(executor);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).withdrawDisputeBounty();
        assertEq(usdc.balanceOf(executor) - before_, need, "payer got it once unblocked");
    }

    /// Nothing to withdraw is not a silent no-op but an explicit revert. The error is
    /// its own and not NothingToPush from withdrawTreasurySlice: both live in the
    /// relayer's decoder, the name reaches the user verbatim, and "push" in the
    /// message would speak of an action the person never performed.
    function testWithdrawDisputeBountyRevertsIfNothingOwed() public {
        vm.prank(executor);
        vm.expectRevert(ArbiterRegistryFacet.NoRefundableBounty.selector);
        ArbiterRegistryFacet(address(diamond)).withdrawDisputeBounty();
    }

    /// The error for withdrawing a top-up and the error for pushing the treasury's
    /// share are DIFFERENT selectors. A test on a bare name rather than on behaviour:
    /// confused errors behave identically and differ only in what a person reads.
    function testBountyAndTreasuryErrorsAreNotTheSameSelector() public pure {
        assertTrue(
            ArbiterRegistryFacet.NoRefundableBounty.selector != ArbiterRegistryFacet.NothingToPush.selector,
            "the payer must not be told about a push he never made"
        );
    }

    /// A short (1..31 byte) reply from a token must not turn a soft return into a
    /// hard one: abi.decode without a length check panics by itself on such a reply,
    /// and the revert would then drag the release of the claim down with it — the
    /// same trap as with the blacklist above, only with a different trigger on the
    /// token's side.
    ///
    /// A mock of the call rather than of the address — the same device as in
    /// testShortTokenReplyDoesNotFreezeTheTimeout (mockCall on one specific transfer
    /// call, not a replacement of the whole usdc contract).
    function testShortTokenReplyDoesNotBreakClaimClearing() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(executor, need);
        vm.startPrank(executor);
        usdc.approve(address(diamond), need);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        a.respondToDispute();
        vm.stopPrank();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        // 1 byte instead of 32 — abi.decode reverts on that without a length check.
        vm.mockCall(
            address(usdc),
            abi.encodeWithSelector(bytes4(0xa9059cbb), executor, need),
            hex"01"
        );

        vm.prank(client);
        a.triggerArbiterTimeout();

        vm.clearMockedCalls();

        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty left the dispute");
        assertEq(ArbiterRegistryFacet(address(diamond)).getRefundableBounty(executor), need, "and became claimable instead");
    }

    // -------- THE PAID CALL: THE PAYOUT --------

    /// A verdict happened, so the top-up goes to the arbiter rather than back to the
    /// payer. clearDisputeClaim (called from resolveDispute inside the same
    /// finalizeVerdict) sees disputeBounty already zeroed and stays silent.
    function testBountyGoesToArbiterOnVerdict() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        _claimByArbiter(a);
        _submitAndFinalize(a, true);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr) >= need, true, "arbiter got at least the bounty");
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty cleared after payout");
    }

    /// The verdict was overturned by the owner before finalisation — the top-up must
    /// not go to the arbiter: on an overturn 80% of the fee already goes entirely to
    /// the treasury (creditDisputeFee), and the top-up cannot be an exception. The
    /// money goes back to the payer through claimable (refundableBounty) rather than
    /// by a direct transfer — a hard transfer here could take the whole finalisation
    /// down.
    function testOverturnedVerdictRefundsBountyToPayer() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        _claimByArbiter(a);

        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);

        // The owner (== address(this) in this setup) overturns the verdict before finalisation.
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(address(a), false);

        vm.warp(block.timestamp + 24 hours + 1); // FINALIZE_DELAY
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));

        assertEq(ArbiterRegistryFacet(address(diamond)).getRefundableBounty(client), need, "bounty went to the payer as claimable");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 0, "overturned arbiter got nothing, including the bounty");
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty left the dispute either way");
    }

    /// The flat payout from the vault is no longer credited: the vault is unchanged
    /// after finalisation. It used to be added to 80% of the fee, and with the top-up
    /// there would have been three sources at once.
    ///
    /// rewardPerDispute is a dead field (ArbiterRegistryFacet), and
    /// setRewardPerDispute now reverts unconditionally (RewardPathRetired) — there is
    /// no ordinary way to raise the field above zero any more. Without a workaround
    /// this test would pass on the old, unfixed code too: the field defaults to 0
    /// anyway, and the removed block was locked behind `rewardPerDispute > 0`. The
    /// field is therefore written directly through stdstore (bypassing the reverting
    /// setter — imitating a value that could have survived from a deployment before
    /// 31 July; the field is append-only and was never zeroed) and the vault is
    /// filled with fundVault by the same amount, so that the old condition
    /// (`vaultBalance >= rewardPerDispute`) has a chance to fire. That way the test
    /// catches the regression itself rather than passing by default.
    function testVaultNoLongerPaysPerDispute() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);

        stdstore
            .target(address(diamond))
            .sig(ArbiterRegistryFacet.getRewardPerDispute.selector)
            .checked_write(5_000_000);

        usdc.mint(owner, 5_000_000);
        vm.startPrank(owner);
        usdc.approve(address(diamond), 5_000_000);
        ArbiterRegistryFacet(address(diamond)).fundVault(5_000_000);
        vm.stopPrank();

        uint256 vaultBefore = ArbiterRegistryFacet(address(diamond)).getVaultBalance();
        _submitAndFinalize(a, true);
        assertEq(ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore, "vault untouched by a resolved dispute");
    }

    /// setRewardPerDispute no longer writes anything — it reverts unconditionally,
    /// whoever the caller is. onlyOwner no longer guards the entrance, because there
    /// is no entrance left to guard: it was replaced by error RewardPathRetired and a
    /// pure function.
    function testSetRewardPerDisputeAlwaysReverts() public {
        vm.expectRevert(ArbiterRegistryFacet.RewardPathRetired.selector);
        ArbiterRegistryFacet(address(diamond)).setRewardPerDispute(5_000_000);

        vm.prank(address(0xBEEF));
        vm.expectRevert(ArbiterRegistryFacet.RewardPathRetired.selector);
        ArbiterRegistryFacet(address(diamond)).setRewardPerDispute(1);
    }

    // -------- THE COUNTER OF DISPUTES WITHOUT A VERDICT --------

    function testUnresolvedCounterIncrementsBothOnSplit() public {
        Agreement a = _disputedAgreement(100_000_000);
        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(ReputationFacet(address(diamond)).getUnresolvedDisputes(client), 1, "client counted");
        assertEq(ReputationFacet(address(diamond)).getUnresolvedDisputes(executor), 1, "executor counted");
    }

    /// 75/25 counts for both as well: who is at fault there is obvious, but the
    /// counter asserts nothing about fault — it is about who systematically ends up
    /// in disputes.
    function testUnresolvedCounterIncrementsBothOnUnanswered() public {
        Agreement a = _disputedAgreement(100_000_000);
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(ReputationFacet(address(diamond)).getUnresolvedDisputes(client), 1, "client counted");
        assertEq(ReputationFacet(address(diamond)).getUnresolvedDisputes(executor), 1, "executor counted");
    }

    /// A verdict happened, so the counter is not touched for anybody.
    function testUnresolvedCounterNotIncrementedAfterVerdict() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        _activateAndDispute(a);
        _submitAndFinalize(a, true);

        assertEq(ReputationFacet(address(diamond)).getUnresolvedDisputes(client), 0, "verdict is not an unresolved dispute");
        assertEq(ReputationFacet(address(diamond)).getUnresolvedDisputes(executor), 0, "verdict is not an unresolved dispute");
    }

    /// The third timeout branch: the arbiter DID take the dispute and did not finish
    /// it. Here Agreement.arbiter is no longer zero, so no split happens at all — the
    /// pot goes back to the client in full (Agreement.sol: the branch after
    /// `if (arbiter == address(0))`), and the top-up comes back on top. The branch
    /// goes through the same clearDisputeClaim, so the counter of disputes without a
    /// verdict must rise for both — no judging happened here either.
    function testTimeoutAfterClaimRefundsTheBountyAndCountsBoth() public {
        Agreement a = _disputedAgreement(100_000_000);

        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertGt(need, 0, "setup: the pot must be small enough to need a top-up");
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        // The arbiter takes the dispute and stays silent to the end of the window: there will be no verdict.
        _claimByArbiter(a);
        assertEq(a.arbiter(), address(diamond), "setup: the claim must stick");

        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);
        vm.prank(client);
        a.triggerArbiterTimeout();

        // The whole pot to the client, and the top-up on top of it to whoever paid it.
        assertEq(usdc.balanceOf(client) - cBefore, 100_000_000 + need, "whole pot plus the refunded top-up");
        assertEq(usdc.balanceOf(executor) - eBefore, 0, "the claimed branch does not split anything");
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty cleared");
        assertEq(ArbiterRegistryFacet(address(diamond)).getRefundableBounty(client), 0, "the push refund succeeded, nothing left claimable");

        assertEq(ReputationFacet(address(diamond)).getUnresolvedDisputes(client), 1, "client counted");
        assertEq(ReputationFacet(address(diamond)).getUnresolvedDisputes(executor), 1, "executor counted");
    }

    // -------- THE PAID CALL: THE DISPUTE WINDOW --------

    /// Money must not be taken for a service that can no longer be rendered. After
    /// disputedAt + DISPUTE_WINDOW a dispute can neither be claimed (claimDispute)
    /// nor judged (submitVerdict) — both hit DisputeWindowPassed, while the status
    /// stays DISPUTED until somebody pulls the timeout. A top-up in that window would
    /// not be lost, but it would be frozen until somebody else acted.
    function testFundDisputeAfterTheWindowReverts() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.prank(client);
        usdc.approve(address(diamond), need);

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.DisputeWindowPassed.selector);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));

        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0, "nothing was taken");
    }

    /// The boundary is exactly the same as for claimDispute: the last second of the
    /// window still accepts both. Checked in one test so that the gates cannot drift
    /// apart by one — a top-up is possible exactly while the dispute can still be
    /// claimed.
    function testFundDisputeOnTheLastSecondMatchesClaimDispute() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.prank(client);
        usdc.approve(address(diamond), need);

        // vm.warp onto the exact boundary: block.timestamp == disputedAt + DISPUTE_WINDOW.
        vm.warp(a.disputedAt() + a.DISPUTE_WINDOW());

        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(address(a));
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), need, "top-up accepted on the last second");

        // ...and a claim on the same second goes through too. Had the gates diverged,
        // one of the two would fail here.
        _claimByArbiter(a);
        assertEq(a.arbiter(), address(diamond), "claimDispute accepts the same second");
    }

    // ============================================================
    //  THE PAID CALL THROUGH A REAL FORWARDER (ERC-2771)
    // ============================================================
    //
    // The only road by which the client ever calls fundDispute at all (the relay
    // client → MinimalForwarder.execute → the diamond). On it msg.sender is the
    // forwarder's address rather than the person, so every money test above, driving
    // the function by direct calls under vm.prank, would miss a party check that
    // reads msg.sender directly.
    // A model of the setup is the gasless section of the AgreementClone suite.

    uint256 constant PAYER_PK    = 0xA11CE;
    uint256 constant PEER_PK     = 0xB0BB1E;
    uint256 constant OUTSIDER_PK = 0xDECAFB;

    MinimalForwarder relayForwarder;

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    /// Raises a dispute between two ADDRESSES WITH KEYS (the setup's global
    /// client/executor are the literals 0x1/0x2 and cannot sign EIP-712) and gives
    /// the diamond a real forwarder in place of the 0xDEAD stub.
    function _forwardedDispute(uint256 dealAmount)
        internal returns (Agreement a, address payer, address peer)
    {
        payer = vm.addr(PAYER_PK);
        peer  = vm.addr(PEER_PK);

        relayForwarder = new MinimalForwarder();
        FactoryFacet(address(diamond)).setTrustedForwarder(address(relayForwarder));

        usdc.mint(payer, dealAmount * 4);
        vm.prank(payer);
        usdc.approve(address(diamond), type(uint256).max);
        // Only the diamond may open this door now, which is what a board does
        // from inside acceptApplicant/acceptRequest.
        vm.prank(address(diamond));
        address addr = FactoryFacet(address(diamond)).deployAgreement(
            payer, peer, address(0), dealAmount, 7, "terms", 0
        );
        vm.startPrank(payer);
        usdc.approve(addr, dealAmount);
        Agreement(addr).fund();
        vm.stopPrank();

        a = Agreement(addr);
        vm.prank(peer);
        a.activate();
        vm.prank(payer);
        a.raiseDispute();
    }

    function _signFwd(uint256 pk, MinimalForwarder.ForwardRequest memory req)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            FWD_TYPEHASH, req.from, req.to, req.value, req.gas, req.nonce, keccak256(req.data)
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            keccak256(abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MinimalForwarder")),
                keccak256(bytes("0.0.1")),
                block.chainid,
                address(relayForwarder)
            )),
            structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// execute() does not revert when the inner call fails — it returns
    /// (false, revertData), so success is read from the return value.
    function _relayToDiamond(uint256 pk, bytes memory data)
        internal returns (bool success, bytes memory retdata)
    {
        address from = vm.addr(pk);
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  from,
            to:    address(diamond),
            value: 0,
            gas:   3_000_000,
            nonce: relayForwarder.getNonce(from),
            data:  data
        });
        return relayForwarder.execute(req, _signFwd(pk, req));
    }

    /// The whole main road of the feature. It checks three things that broke
    /// together: the call passes the party check at all; the USDC is pulled from THE
    /// PERSON and not from the forwarder; and the person is recorded as the payer —
    /// which is visible in that the refund on a timeout comes to them rather than to
    /// the forwarder.
    function testFundDisputeThroughForwarderIsPaidByTheHuman() public {
        (Agreement a, address payer, address peer) = _forwardedDispute(100_000_000);

        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertGt(need, 0, "setup: the pot must need a top-up");
        usdc.mint(payer, need);
        vm.prank(payer);
        usdc.approve(address(diamond), need);

        uint256 payerBefore = usdc.balanceOf(payer);

        (bool ok, bytes memory retdata) = _relayToDiamond(
            PAYER_PK,
            abi.encodeWithSelector(ArbiterRegistryFacet.fundDispute.selector, address(a))
        );
        assertTrue(ok, string.concat("forwarded fundDispute() failed: ", vm.toString(retdata)));

        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), need, "bounty recorded");
        assertEq(payerBefore - usdc.balanceOf(payer), need, "USDC pulled from the human, not the forwarder");
        assertEq(usdc.balanceOf(address(relayForwarder)), 0, "the forwarder must never hold the deal's money");

        // The payer is recorded as the person: the refund on a timeout comes to them.
        // Had the forwarder's address gone into storage, this money would have gone there.
        vm.prank(peer);
        a.respondToDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 beforeTimeout = usdc.balanceOf(payer);
        vm.prank(payer);
        a.triggerArbiterTimeout();

        assertEq(
            usdc.balanceOf(payer) - beforeTimeout - 50_000_000,
            need,
            "the refund went to the human payer on top of his split half"
        );
        assertEq(usdc.balanceOf(address(relayForwarder)), 0, "the forwarder got nothing back either");
    }

    /// Negative control: without it the test above would pass in a world where
    /// _msgSender() returns anything at all, as long as it happens to equal a party.
    /// A stranger signing through the same forwarder must get NotParty.
    function testFundDisputeThroughForwarderFromStrangerIsRejected() public {
        (Agreement a, , ) = _forwardedDispute(100_000_000);

        address outsider = vm.addr(OUTSIDER_PK);
        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(outsider, need);
        vm.prank(outsider);
        usdc.approve(address(diamond), need);

        (bool ok, bytes memory retdata) = _relayToDiamond(
            OUTSIDER_PK,
            abi.encodeWithSelector(ArbiterRegistryFacet.fundDispute.selector, address(a))
        );

        assertFalse(ok, "the diamond accepted a forwarded top-up from a non-party");
        assertEq(bytes4(retdata), ArbiterRegistryFacet.NotParty.selector, "wrong revert reason");
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0, "nothing was taken");
    }

    /// The second function of the same road. A return through claimable happens when
    /// the push did not go through (the USDC blacklist), and the person collects it —
    /// also through the forwarder.
    ///
    /// It is the EXECUTOR (peer) who pays here rather than the client, for the same
    /// reason as in testBlacklistedPayerDoesNotBreakClaimClearing, and with the same
    /// caveat: that reason no longer holds, because both shares are now paid by the
    /// soft _payClient/_payExecutor.
    function testWithdrawDisputeBountyThroughForwarderPaysTheHuman() public {
        (Agreement a, address payer, address peer) = _forwardedDispute(100_000_000);

        uint256 need = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(peer, need);
        vm.startPrank(peer);
        usdc.approve(address(diamond), need);
        a.respondToDispute();
        vm.stopPrank();

        (bool funded, bytes memory fundRet) = _relayToDiamond(
            PEER_PK,
            abi.encodeWithSelector(ArbiterRegistryFacet.fundDispute.selector, address(a))
        );
        assertTrue(funded, string.concat("setup: forwarded fundDispute failed: ", vm.toString(fundRet)));

        // Block the payer in USDC — the soft refund inside clearDisputeClaim will not
        // go through and will settle into refundableBounty.
        usdc.setBlocked(peer, true);
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(payer);
        a.triggerArbiterTimeout();
        usdc.setBlocked(peer, false);

        uint256 owed = ArbiterRegistryFacet(address(diamond)).getRefundableBounty(peer);
        assertEq(owed, need, "the failed push must land on the human's claimable balance");

        uint256 before_ = usdc.balanceOf(peer);
        (bool ok, bytes memory retdata) = _relayToDiamond(
            PEER_PK,
            abi.encodeWithSelector(ArbiterRegistryFacet.withdrawDisputeBounty.selector)
        );
        assertTrue(ok, string.concat("forwarded withdrawDisputeBounty() failed: ", vm.toString(retdata)));

        assertEq(usdc.balanceOf(peer) - before_, owed, "the human got his top-up back");
        assertEq(ArbiterRegistryFacet(address(diamond)).getRefundableBounty(peer), 0, "claimable cleared");
        assertEq(usdc.balanceOf(address(relayForwarder)), 0, "the forwarder must never receive the refund");
    }
}
