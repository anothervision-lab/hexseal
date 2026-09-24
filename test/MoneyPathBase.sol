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
import "../src/AgreementRenderer.sol";
import "../src/JobReceiptFacet.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ReputationFacet.sol";
import {TreasuryLinkFacet} from "../src/facets/TreasuryLinkFacet.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

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
        // The certificate's draughtsman, put where every Agreement compiled
        // from this checkout looks for it. Etched rather than deployed on
        // purpose: `new` here would move every later nonce, and with it every
        // clone address printed on the cards that
        // test/AgreementCertificateSnapshot.t.sol pins byte for byte.
        vm.etch(AGREEMENT_RENDERER, type(AgreementRenderer).runtimeCode);

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
        ArbiterVaultFacet arbFacetVault = new ArbiterVaultFacet();
        ArbiterAccountabilityFacet accFacet  = new ArbiterAccountabilityFacet();
        ReputationFacet      repFacet        = new ReputationFacet();
        TreasuryLinkFacet    linkFacet       = new TreasuryLinkFacet();

        bytes4[] memory regSels = new bytes4[](15);
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
        regSels[12] = RegistryFacet.notifyWorkHandedIn.selector;
        // Appended 18 September 2026: a direct hire is an OFFER, so the
        // factory registers it through registerOffer, and the clone
        // announces the acceptance. Without both mounted this rig's
        // deployAndFund reverts with "function not found".
        regSels[13] = RegistryFacet.registerOffer.selector;
        regSels[14] = RegistryFacet.notifyOfferAccepted.selector;

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

        bytes4[] memory arbSels = new bytes4[](11);
        arbSels[0] = ArbiterRegistryFacet.addArbiter.selector;
        arbSels[1] = ArbiterRegistryFacet.commitDisputeClaim.selector;
        arbSels[2] = ArbiterRegistryFacet.claimDispute.selector;
        arbSels[3] = ArbiterRegistryFacet.clearDisputeClaim.selector;
        arbSels[4] = ArbiterRegistryFacet.submitVerdict.selector;
        arbSels[5] = ArbiterRegistryFacet.finalizeVerdict.selector;
        arbSels[6] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        arbSels[7] = ArbiterRegistryFacet.overturnVerdict.selector;
        arbSels[8] = ArbiterRegistryFacet.raiseAppeal.selector;
        arbSels[9] = ArbiterRegistryFacet.voteOnAppeal.selector;
        arbSels[10] = ArbiterRegistryFacet.resolveAppeal.selector;
        bytes4[] memory arbSelsVault = new bytes4[](28);
        arbSelsVault[0] = ArbiterVaultFacet.isRegisteredArbiter.selector;
        arbSelsVault[1] = ArbiterVaultFacet.getDisputeClaimer.selector;
        arbSelsVault[2] = ArbiterVaultFacet.withdrawArbiterReward.selector;
        arbSelsVault[3] = ArbiterVaultFacet.fundVault.selector;
        arbSelsVault[4] = ArbiterVaultFacet.getPendingVerdict.selector;
        arbSelsVault[5] = ArbiterVaultFacet.getVaultBalance.selector;
        arbSelsVault[6] = ArbiterVaultFacet.creditDisputeFee.selector;
        arbSelsVault[7] = ArbiterVaultFacet.getTreasurySlice.selector;
        arbSelsVault[8] = ArbiterVaultFacet.withdrawTreasurySlice.selector;
        arbSelsVault[9] = ArbiterVaultFacet.hasSubmittedVerdict.selector;
        arbSelsVault[10] = ArbiterVaultFacet.setArbiterFloor.selector;
        arbSelsVault[11] = ArbiterVaultFacet.getArbiterFloor.selector;
        arbSelsVault[12] = ArbiterVaultFacet.quoteDisputeTopUp.selector;
        arbSelsVault[13] = ArbiterVaultFacet.fundDispute.selector;
        arbSelsVault[14] = ArbiterVaultFacet.getDisputeBounty.selector;
        arbSelsVault[15] = ArbiterVaultFacet.withdrawDisputeBounty.selector;
        arbSelsVault[16] = ArbiterVaultFacet.getRefundableBounty.selector;
        arbSelsVault[17] = ArbiterVaultFacet.setDisputeDiscount.selector;
        arbSelsVault[18] = ArbiterVaultFacet.getDisputeDiscount.selector;
        arbSelsVault[19] = ArbiterVaultFacet.getAppealVotes.selector;
        // The appeal economics (17 September 2026): the panel's pull is a
        // money exit, and its read is a ledger term below.
        arbSelsVault[20] = ArbiterVaultFacet.withdrawAppealShare.selector;
        arbSelsVault[21] = ArbiterVaultFacet.getAppealShareOwed.selector;
        arbSelsVault[22] = ArbiterVaultFacet.getAppealLedger.selector;
        arbSelsVault[23] = ArbiterVaultFacet.quoteAppealDeposit.selector;
        arbSelsVault[24] = ArbiterVaultFacet.settleAppealDebts.selector;
        arbSelsVault[25] = ArbiterVaultFacet.getAppealDebts.selector;
        // The bond THIS CASE carries (22 September 2026): a money exit and a
        // ledger term. It is on this rig because the identity below has to see
        // it — real USDC sits on the diamond from the claim until the verdict
        // finalizes or the arbiter collects.
        arbSelsVault[26] = ArbiterVaultFacet.withdrawCaseBond.selector;
        arbSelsVault[27] = ArbiterVaultFacet.getCaseBond.selector;

        bytes4[] memory accSels = new bytes4[](3);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        accSels[1] = ArbiterAccountabilityFacet.getArbiterBond.selector;
        accSels[2] = ArbiterAccountabilityFacet.getDisputeSubsidy.selector;

        // Two selectors and no more: the payroll pot and its reading. The pot
        // is the reason this facet is here at all — decision 69 fills it and
        // decision 73 has not yet given it a door, so from 4 September the
        // diamond starts holding money nobody comes for, and money nobody comes
        // for is exactly what would otherwise absorb a miscount in silence.
        bytes4[] memory linkSels = new bytes4[](2);
        linkSels[0] = TreasuryLinkFacet.fundArbiterPayroll.selector;
        linkSels[1] = TreasuryLinkFacet.getArbiterPayrollBalance.selector;

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

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](14);
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
        cut[11] = IDiamondCut.FacetCut(address(linkFacet),     IDiamondCut.FacetCutAction.Add, linkSels);
        cut[12] = IDiamondCut.FacetCut(address(new ArbiterApplicationsFacet()), IDiamondCut.FacetCutAction.Add, _applicationsSelectors());
        cut[13] = IDiamondCut.FacetCut(address(arbFacetVault),      IDiamondCut.FacetCutAction.Add, arbSelsVault);

        diamond = new DiamondProxy(owner, cut, address(0), "");

        Agreement impl = new Agreement();
        AgreementDeployer dep = new AgreementDeployer(address(diamond), address(impl));
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(dep)
        );
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiterAddr);

        _postSeatBond(arbiterAddr);

        vm.prank(client);   usdc.approve(address(diamond), type(uint256).max);
        vm.prank(executor); usdc.approve(address(diamond), type(uint256).max);
        vm.prank(stranger); usdc.approve(address(diamond), type(uint256).max);

        // The six the fixture funds. Anyone a test brings in on top of these
        // goes through _trackActor.
        _trackActor(owner);
        _trackActor(client);
        _trackActor(executor);
        _trackActor(arbiterAddr);
        _trackActor(feeRecipient);
        _trackActor(stranger);
    }

    /// The bond behind a hand-given seat (8 September 2026).
    ///
    /// `addArbiter` seats and takes no money; since the bond gate landed, every
    /// arbiter door refuses an unbonded seat with `BondNotPosted`. So this rig's
    /// arbiter pays like a real one — his own USDC, moved by his own call.
    ///
    /// ⚠️ NOT faked with `vm.store`. A bond booked without the money behind it
    /// would leave the balance identity 50 USDC short, and that identity is the
    /// whole point of this fixture.
    ///
    /// The amount is READ from the diamond, never written as a literal here: a
    /// copy would go on agreeing with itself after the real number moved.
    ///
    /// Its own function rather than four lines in setUp: setUp is already one
    /// stack slot from the via_ir limit.
    /// Three selectors of the applications facet, and no more: the door a seated
    /// arbiter posts his bond through, the read that says whether he has, and
    /// the requirements this fixture reads the amount from.
    ///
    /// A function rather than a local in the cut builder: that builder is one
    /// stack slot from the via_ir limit, and a fourth memory array there does
    /// not fit.
    function _applicationsSelectors() internal pure returns (bytes4[] memory appSels) {
        appSels = new bytes4[](4);
        appSels[0] = ArbiterApplicationsFacet.postArbiterBond.selector;
        appSels[1] = ArbiterApplicationsFacet.isArbiterActive.selector;
        appSels[2] = ArbiterApplicationsFacet.getApplicationRequirements.selector;
        appSels[3] = ArbiterApplicationsFacet.getBondState.selector;
    }

    /// What this fixture's arbiter has locked as his seat bond.
    ///
    /// Every assertion below that used to read "the diamond keeps nothing" now
    /// means "nothing BEYOND this": the bond is posted in setUp and sits there
    /// for the life of the rig. Kept as a field rather than a literal so those
    /// assertions stay tied to the number the diamond actually charges.
    uint256 internal seatBondHeld;

    /// ⚠️ THERE IS NO SEAT BOND ANY MORE (22 September 2026). The name is
    /// kept because every rig below calls it; what it does is what a seated
    /// arbiter now actually needs — money and an allowance for the bond he
    /// posts PER CASE, at the moment he claims a dispute.
    ///
    /// `seatBondHeld` stays a field and now reads zero, so every assertion
    /// below that says "the diamond keeps nothing beyond the arbiter's bond"
    /// goes on saying the true thing without being rewritten one by one.
    function _postSeatBond(address who) internal {
        usdc.mint(who, CASE_BOND_PURSE);
        vm.prank(who); usdc.approve(address(diamond), type(uint256).max);
        seatBondHeld = 0;
    }

    /// What a rig gives an arbiter to post case bonds out of. Generous on
    /// purpose: the bond is a percentage of the pot with a $20 floor, and a rig
    /// that ran out of it would fail with `CaseBondTransferFailed` in the
    /// middle of a scene about something else entirely.
    uint256 internal constant CASE_BOND_PURSE = 1_000_000_000;

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
        total += ArbiterVaultFacet(address(diamond)).getVaultBalance();
        total += ArbiterVaultFacet(address(diamond)).getTreasurySlice();

        // ---- the payroll pot (added 4 September 2026) ----
        //
        // The stream decision 69 opened and decision 73 has not yet given a
        // door. It was missing from this sum while nothing could fill it; from
        // the cut that set the stream's share it fills on its own, and a pot
        // that is held but not booked is the one thing that makes every OTHER
        // term unfalsifiable — a miscount anywhere else would simply be paid
        // for out of money nobody comes to collect, and the identity would go
        // on agreeing.
        total += TreasuryLinkFacet(address(diamond)).getArbiterPayrollBalance();

        // Per-address terms: only the actors this fixture ever funds can hold
        // one, and each is named rather than scanned. Forgetting one is a
        // SAFE forgetting: an unnamed holder makes the sum too small, and too
        // small is the direction that goes red.
        for (uint256 i = 0; i < _ledgerActors.length; i++) {
            address who = _ledgerActors[i];
            total += ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(who);
            total += ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(who);
            total += ArbiterVaultFacet(address(diamond)).getRefundableBounty(who);
        }

        // Per-agreement terms; the caller registers the deals it made.
        for (uint256 i = 0; i < _trackedDeals.length; i++) {
            address deal = _trackedDeals[i];
            total += ArbiterVaultFacet(address(diamond)).getDisputeBounty(deal);

            // ---- the bond THIS CASE carries (added 22 September 2026) ----
            //
            // Real USDC on the diamond from the moment an arbiter claims the
            // dispute until his verdict finalizes or he collects it with
            // `withdrawCaseBond`. It was the first thing this identity caught
            // when the per-case bond landed: 20 USDC held and nothing booking
            // it, on the timeout path where the bond outlives the claim.
            //
            // Read through the mounted door rather than off the slot, so a
            // record that stops being written makes this sum too small — and
            // too small is the direction that goes red.
            (uint256 caseBond, ) = ArbiterVaultFacet(address(diamond)).getCaseBond(deal);
            total += caseBond;

            // ---- the appeal deposit in flight (added 4 September 2026) ----
            //
            // ⚠️ `appealDeposit` is NOT a balance. It is never zeroed: neither
            // branch of resolveAppeal clears it, so after the appeal is settled
            // the field still holds what was paid while the money itself has
            // gone — to the appellant on a win, into `vaultBalance` on a loss.
            // Read it as a balance and this sum double-counts every resolved
            // appeal in the fixture's life. The predicate for "still held" is
            // therefore the pair of flags, not the number.
            //
            // The raw field, deliberately, and not `_depositOf`'s fallback to
            // the constant: the fallback exists for appeals raised before the
            // field existed, which cannot happen on a diamond this fixture
            // builds from nothing. Reading raw means that a raiseAppeal which
            // one day stops writing the field makes this sum too small, and
            // too small goes red — the fallback would have hidden it.
            ArbiterRegistryStorage.PendingVerdict memory v =
                ArbiterVaultFacet(address(diamond)).getPendingVerdict(deal);
            if (v.appealed && !v.appealResolved) total += v.appealDeposit;

            // ---- the panel's unpulled shares (added 17 September 2026) ----
            //
            // A settled appeal with a quorum leaves `voterShare` per voter on
            // the diamond until each voter pulls it. Summed per (deal, actor)
            // through the same read a screen uses, for every actor the fixture
            // knows — a voter the test forgot to track is money this sum does
            // not see, and too small goes red.
            //
            // ⚠️ NOT the ledger's `advanceFromBond` / `advanceFromVault` /
            // `debt`: the first two are money ALREADY PAID OUT to the
            // appellant, the third is money that does not exist. Counting any
            // of them would book what the diamond does not hold.
            for (uint256 j = 0; j < _ledgerActors.length; j++) {
                total += ArbiterVaultFacet(address(diamond)).getAppealShareOwed(deal, _ledgerActors[j]);
            }
        }
    }

    /// Deals whose per-agreement money the ledger should look at.
    address[] internal _trackedDeals;
    /// ⚠️ IDEMPOTENT SINCE 22 SEPTEMBER 2026, and that is a correction rather
    /// than a nicety. Every per-deal term below is summed ONCE PER ENTRY, so a
    /// deal pushed twice counts its bounty and its case bond twice and the
    /// identity reads "the diamond holds LESS than it books" — which is what
    /// happened the moment `_claimByArbiter` began registering the deal it
    /// claims and the scenes that already registered it kept doing so. The
    /// list is at most a handful of deals per scene, so the scan is free.
    function _trackDeal(address a) internal {
        for (uint256 i = 0; i < _trackedDeals.length; i++) {
            if (_trackedDeals[i] == a) return;
        }
        _trackedDeals.push(a);
    }

    /// Addresses that can hold a per-address term. Seeded with the six the
    /// fixture funds; a test that brings its own arbiter registers him here, or
    /// his bond is money the sum does not know about.
    address[] internal _ledgerActors;
    function _trackActor(address a) internal { _ledgerActors.push(a); }

    function _assertDiamondBalances(string memory when) internal view {
        uint256 held   = usdc.balanceOf(address(diamond));
        uint256 booked = _diamondLedger();
        if (held == booked) return;

        // ⚠️ STRICT EQUALITY, not `held >= booked`, and the direction is named
        // rather than left for the reader to work out of two bare numbers.
        //
        // Why strict: a surplus is the failure mode this lock exists for. Once
        // the diamond holds money nobody comes for, `>=` is satisfied by any
        // shortfall in any other term — the miscount is paid for out of the
        // idle pot and the lock stays green through it. A lock that tolerates
        // surplus stops being able to see the thing surplus hides.
        //
        // Its cost is that a gift from outside — anyone may transfer USDC to
        // this address — reads as a break. On a diamond built from nothing in
        // setUp that is not a false alarm but a true one: nobody gifts a test
        // diamond by accident, so every surplus here was either put there on
        // purpose or is a bug. On a live chain the same surplus would be a fact
        // of life, which is why this is a test-time invariant and must never be
        // copied into an on-chain `require`.
        assertEq(
            held,
            booked,
            string.concat(
                held > booked
                    ? "the diamond holds MORE USDC than it books, by "
                    : "the diamond holds LESS USDC than it books, by ",
                vm.toString(held > booked ? held - booked : booked - held),
                " (6dp) -- ",
                when
            )
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
        // ⚠️ TRACKED HERE AND NOT LEFT TO EACH SCENE (22 September 2026). From
        // this call the diamond holds the bond this CASE carries, and a deal
        // whose bond nothing books makes the identity below read a surplus —
        // which is the one direction that hides every other miscount. Claiming
        // is the moment that money arrives, so this is the place. Registering
        // a deal twice is harmless because `_trackDeal` is idempotent — and it
        // has to be, since every per-deal term is summed once per entry.
        _trackDeal(address(a));
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
