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
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {DealCapOff} from "./DealCapOff.sol";
import {inviteAndSeatArbiter, mountAcceptDoor} from "./ArbiterSeatRig.sol";

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


    /// ⚠️ ITS OWN FUNCTION SINCE 20 OCTOBER 2026, AND THE REASON IS THE STACK.
    /// Inline in `setUp`, this list pushed the frame one slot past what via_ir
    /// can hold once it grew the three doors of the dispute fee -- the error is
    /// "Variable ... is 1 too deep in the stack" and it names no file. Moving
    /// the longest list into a frame of its own takes its pointer and its
    /// twenty-six stores with it. Same remedy, same error, as
    /// test/Diamond.t.sol and test/MoneyPathBase.sol.
    function _arbSelsVault() private pure returns (bytes4[] memory sels) {
        sels = new bytes4[](26);
        sels[0] = ArbiterVaultFacet.getChiefArbiter.selector;
        sels[1] = ArbiterVaultFacet.isRegisteredArbiter.selector;
        sels[2] = ArbiterVaultFacet.getArbiters.selector;
        sels[3] = ArbiterVaultFacet.getDisputeClaimer.selector;
        sels[4] = ArbiterVaultFacet.getClaimCommitment.selector;
        sels[5] = ArbiterVaultFacet.withdrawArbiterReward.selector;
        sels[6] = ArbiterVaultFacet.fundVault.selector;
        sels[7] = ArbiterVaultFacet.setRewardPerDispute.selector;
        sels[8] = ArbiterVaultFacet.getPendingVerdict.selector;
        sels[9] = ArbiterVaultFacet.getVaultBalance.selector;
        sels[10] = ArbiterVaultFacet.getRewardPerDispute.selector;
        sels[11] = ArbiterVaultFacet.getDAOAddress.selector;
        sels[12] = ArbiterVaultFacet.creditDisputeFee.selector;
        sels[13] = ArbiterVaultFacet.getTreasurySlice.selector;
        sels[14] = ArbiterVaultFacet.withdrawTreasurySlice.selector;
        sels[15] = ArbiterVaultFacet.hasSubmittedVerdict.selector;
        sels[16] = ArbiterVaultFacet.setArbiterFloor.selector;
        sels[17] = ArbiterVaultFacet.getArbiterFloor.selector;
        sels[18] = ArbiterVaultFacet.quoteDisputeTopUp.selector;
        sels[19] = ArbiterVaultFacet.fundDispute.selector;
        sels[20] = ArbiterVaultFacet.getDisputeBounty.selector;
        sels[21] = ArbiterVaultFacet.withdrawDisputeBounty.selector;
        sels[22] = ArbiterVaultFacet.getRefundableBounty.selector;
        // ⚠️ THE DISPUTE FEE TAKEN AT THE DOOR (20 October 2026), AND THESE
        // THREE ARE NOT OPTIONAL ON ANY RIG THAT OPENS A DISPUTE.
        // `Agreement.raiseDispute` calls `holdDisputeFee` and will not open the
        // dispute if the call fails, so an unmounted selector turns every
        // disputed scene on this stand into "Diamond: function not found" --
        // measured on 20 October 2026 as 874 such failures across the tree
        // before the fixtures were taught the doors.
        sels[23] = ArbiterVaultFacet.holdDisputeFee.selector;
        sels[24] = ArbiterVaultFacet.settleDisputeFee.selector;
        sels[25] = ArbiterVaultFacet.getHeldDisputeFee.selector;
    }

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
        ArbiterVaultFacet arbiterRegistryFacetVault = new ArbiterVaultFacet();
        ReputationFacet      reputationFacet      = new ReputationFacet();

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
        // ⚠️ APPENDED 12 OCTOBER 2026, AND IT IS LOAD BEARING ON EVERY TOP-UP.
        // `Agreement.proposeExtra` reads the ceiling its pot is held to by
        // staticcalling this selector on the diamond, and a non-answer LOCKS
        // the door on purpose (`PotCeilingUnavailable`). Without this line the
        // pending-extras scene below reverts on the read rather than measuring
        // what it is about.
        facSels[14] = FactoryFacet.getAgreementPotCeiling.selector;

        bytes4[] memory arbSels = new bytes4[](16);
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
        arbSels[13] = ArbiterRegistryFacet.setDAOAddress.selector;
        arbSels[14] = ArbiterRegistryFacet.clearStuckVerdict.selector;
        arbSels[15] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        bytes4[] memory arbSelsVault = _arbSelsVault();

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
        // notifyExecutorFault and getCleanStreak are mounted since 25 September
        // 2026: the unjudged timeout now records the executor's fault when
        // nothing was handed in, and a swallowed `try` on an unmounted selector
        // would have made that mark untestable here -- the harness would have
        // measured silence and called it agreement.
        bytes4[] memory repSels  = new bytes4[](3);
        repSels[0] = ReputationFacet.getUnresolvedDisputes.selector;
        repSels[1] = ReputationFacet.notifyExecutorFault.selector;
        repSels[2] = ReputationFacet.getCleanStreak.selector;

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

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](9);
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
        cut[8] = IDiamondCut.FacetCut(address(arbiterRegistryFacetVault), IDiamondCut.FacetCutAction.Add, arbSelsVault);

        diamond = new DiamondProxy(owner, cut, address(0), "");

        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );

        // ⚠️ THE ANSWERING DOOR, MOUNTED ON PURPOSE (8 November 2026). This rig
        // never mounted ArbiterApplicationsFacet at all, and from that day a seat
        // is taken by the invited man through `acceptArbiterInvitation` — see
        // ArbiterSeatRig.mountAcceptDoor. Without it every seating below would
        // die in the diamond's fallback instead of saying what it was measuring.
        mountAcceptDoor(address(diamond));
        inviteAndSeatArbiter(address(diamond), arbiterAddr);
        _bondSeat(arbiterAddr);

        // ⚠️ THIS SUITE IS NOT ABOUT THE DEAL CEILING. Its subject is what a
        // verdict does to the money, and its scenes are written on $30,000 and
        // $50,000 deals so that a 3% levy and an arbiter's cut come out as
        // round readable numbers. The ceiling that landed on 12 October 2026
        // refuses anything over $500 at birth, and those amounts are not
        // retyped smaller: the expectations beside them are hand-typed
        // literals, and retyping both halves to make a build pass is how an
        // expectation stops being independent of the code. The ceiling is
        // measured in test/DealCap.t.sol.
        DealCapOff.thisSuiteIsNotAboutTheCeiling(address(diamond));
    }

    // ============================================================
    //  HELPERS
    // ============================================================

    /// ⚠️ WHAT THE OPENER GETS BACK ON A TIMEOUT, AND WHY IT APPEARS IN TWENTY
    /// EXPECTATIONS BELOW (20 October 2026). `raiseDispute` takes
    /// `disputeFee()` from whoever opens the dispute, and on every road where
    /// NO VERDICT was written the diamond sends it home again -- the owner's
    /// decision of 19 October, that the fee is earned by a delivered verdict
    /// and nothing else.
    ///
    /// So on a timeout the opener's purse ends with his share of the escrow
    /// PLUS this ten dollars. It is written as a named SUM at each site, never
    /// folded into the escrow figure: the escrow share is what the split rule
    /// decides and this is his own money coming back, and a reader who cannot
    /// tell them apart cannot check either.
    uint256 constant DOOR_CHARGE_HOME = 10_000_000;   // Agreement.DISPUTE_FEE_FLOOR

    /// ⚠️ WHAT THE TREASURY TAKES OUT OF A DISPUTE FEE, AND IT IS A NAMED
    /// NOUGHT RATHER THAN A BARE `0` (21 October 2026). The owner's decision of
    /// 20 October: the treasury takes nothing out of arbitration, the WHOLE fee
    /// is the judge's. A bare zero at these sites reads as an empty counter
    /// nobody has got round to filling; a name says a decision was taken.
    ///
    /// Worked out by hand, and the retired figure first so that the method can
    /// be checked: on this file's $200 pot the fee used to be 3% of the pot,
    /// 200_000_000 x 3 / 100 = 6_000_000, of which the treasury took a tenth,
    /// 6_000_000 / 10 = 600_000 -- which is the literal that stood at every one
    /// of these sites. The share is nought now, so the same subtraction gives
    /// 6_000_000 - 6_000_000 = 0 to the treasury and the whole of the fee to
    /// the judge. (On this pot the fee itself also moved, from 6_000_000 to the
    /// ten dollar floor above it; the two changes are separate and are derived
    /// separately at each site.)
    uint256 constant TREASURY_TAKES_NOTHING = 0;

    /// ⚠️ MINT AND APPROVE EXACTLY THE DOOR CHARGE, IMMEDIATELY BEFORE THE
    /// PRESS (20 October 2026). `raiseDispute` pulls `disputeFee()` from the
    /// opener through the diamond, and the parties in this fixture hold NOTHING
    /// after the hire -- the mint is exactly the deal amount and `fund()` takes
    /// all of it. Minting a standing float in the hire instead would shift
    /// every absolute balance this file asserts; minting the exact charge here
    /// leaves each purse where it was, because the door takes it straight back.
    ///
    /// Reading `disputeFee()` decides what to MINT and is never an expectation.
    function _armTheDoor(address who, Agreement a) internal {
        uint256 doorCharge = a.disputeFee();
        usdc.mint(who, doorCharge);
        vm.prank(who); usdc.approve(address(diamond), doorCharge);
    }

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

    /// The executor hands the work in. Every scene below whose subject is the
    /// SPLIT rather than delivery needs this since 25 September 2026: the
    /// unclaimed-timeout branch now pays the executor nothing at all without a
    /// markDone on the record, so an attendance test that skips the hand-in
    /// stopped being a test about attendance.
    function _handIn(Agreement a) internal {
        vm.prank(executor);
        a.markDone();
    }

    /// Drives an agreement to DISPUTED and genuinely claims it as arbiter through
    /// commit-reveal — claimDispute() requires a prior commitDisputeClaim() and at
    /// least one block between the commit and the claim (CommitmentTooEarly
    /// otherwise). raiseDispute() takes no arguments.
    /// ⚠️ OPEN A DISPUTE AND PAY FOR IT, which since 20 October 2026 is one
    /// act: `raiseDispute` pulls `disputeFee()` out of the opener's wallet
    /// through the diamond and refuses to open the dispute without it.
    ///
    /// The ten dollars are minted and approved here rather than in the hire,
    /// because the scenes in this file count a party's purse against hand
    /// literals and an allowance sized for the hire alone answers
    /// `DisputeFeeNotCovered` at this door.
    ///
    /// ⚠️ IT READS `disputeFee()` TO DECIDE WHAT TO MINT, WHICH IS MONEY THE
    /// RIG SUPPLIES AND NEVER AN EXPECTATION. What the fee IS is measured
    /// against hand literals in test/SmallDisputeFloor.t.sol; nothing here
    /// asserts it.
    function _openTheDispute(address who, Agreement a) internal {
        _armTheDoor(who, a);
        vm.prank(who); a.raiseDispute();
    }

    function _activateAndDispute(Agreement a) internal {
        vm.prank(executor);
        a.activate();
        _openTheDispute(client, a);

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
        vm.warp(block.timestamp + 72 hours + 1); // FINALIZE_DELAY (a private constant of the facet)
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

    /// FeePaid fired with the amount the door took, and FeeSkipped not fired.
    ///
    /// ⚠️ THIS IS THE ORDINARY ENDING OF EVERY JUDGED DISPUTE SINCE THE FLOOR
    /// LANDED (21 October 2026), which is why it needed a check of its own. The
    /// helper above it describes a pot that pays NOTHING, and no pot reaches
    /// that state any more: the fee's floor is ten dollars on a pot of 33 base
    /// units as much as on a pot of $200. `_assertNoDisputeFeeEventEmitted` is
    /// kept, with its reasoning, as the record of the premise that was retired
    /// rather than disproved -- it is correct about what the two events mean,
    /// and it is simply about a fee of nought that cannot now exist.
    function _assertDisputeFeePaidEmitted(uint256 expectedAmount) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 paidSig    = Agreement.DisputeFeePaid.selector;
        bytes32 skippedSig = Agreement.DisputeFeeSkipped.selector;
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == skippedSig) {
                fail("DisputeFeeSkipped must not fire when the settlement went through");
            }
            if (logs[i].topics[0] == paidSig) {
                found = true;
                assertEq(abi.decode(logs[i].data, (uint256)), expectedAmount, "the paid amount must be the fee the door took");
            }
        }
        assertTrue(found, "DisputeFeePaid must fire when the fee reaches the judge");
    }

    // ============================================================
    //  disputeFee() — 3%, no floor, with a cap
    // ============================================================

    /// 3% of the pot, no floor and no rounding up.
    function testDisputeFeeIsThreePercent() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        // ⚠️ THE FLOOR DECIDES ON A $200 POT (20 October 2026): 3% of it is $6,
        // under the ten dollar floor. The scene keeps its name because the
        // PERCENTAGE is still the rule above the floor -- measured in
        // test/SmallDisputeFloor.t.sol at the pot where it takes over -- and
        // what it holds here is that this pot is not in that band.
        assertEq(a.disputeFee(), 10_000_000, "the $10 floor decides on a $200 pot: 3% of it is only $6");
    }

    /// ⚠️ THE SCENE WAS `testDisputeFeeHasNoFloor` UNTIL 20 OCTOBER 2026 AND
    /// IT ASSERTED THE OPPOSITE OF WHAT NOW SHIPS. It read: "there is no floor:
    /// on a small deal the fee is small, not $5", and held 300 000 -- 3% of a
    /// $10 pot. The owner's flat price put a TEN DOLLAR floor under it, and the
    /// floor is safe only because the fee no longer comes out of the escrow: it
    /// is paid at the door by whoever opens the dispute. On a $10 pot the fee
    /// is now the whole size of the deal, and none of it is the deal's money.
    /// ⚠️ AND THE OLD NAME IS CITED OUTSIDE THIS FILE, which the rename does
    /// not fix. Measured with `grep -rln` over docs/ .claude/ src/ test/
    /// script/ frontend/ on 20 October 2026, `testDisputeFeeHasNoFloor`
    /// appears in TWO working documents of the owner's -- a plan and a spec,
    /// neither of which is in git -- and in nothing that ships. Both now
    /// point at a scene name that does not exist. They are his documents, so
    /// they were reported rather than edited; this paragraph is where whoever
    /// follows either citation lands, instead of on nothing.
    function testDisputeFeeFloorIsTenDollarsOnASmallDeal() public {
        Agreement a = Agreement(_createFundedAgreement(10_000_000));
        assertEq(a.disputeFee(), 10_000_000, "the floor is ten dollars, where 3% of a $10 pot would be 30 cents");
    }

    /// The cap applies to the whole fee.
    function testDisputeFeeIsCapped() public {
        Agreement a = Agreement(_createFundedAgreement(50_000_000_000));
        assertEq(a.disputeFee(), 500_000_000, "capped at 500 USDC");
    }

    /// ⚠️ THE INVARIANT THIS PINNED IS GONE, AND THE PIN IS KEPT FOR A
    /// NARROWER CLAIM (20 October 2026). It read: with BPS under 100%,
    /// floor(pot * BPS / 10 000) < pot for any pot, so the removed runtime
    /// branch `fee < pot` was unreachable. A TEN DOLLAR FLOOR breaks that
    /// outright -- ten dollars is more than a five dollar pot -- and the branch
    /// is not needed anyway, because nothing is subtracted from the pot any
    /// more: `resolveDispute` pays the winner `pot` and the fee was taken at
    /// the door. What is still worth pinning is the PERCENTAGE staying under
    /// 100%, because a rate at or above it would make the fee grow without
    /// bound with the pot.
    function testDisputeFeeBpsIsBelowOneHundredPercent() public {
        Agreement impl = new Agreement();
        assertLt(impl.DISPUTE_FEE_BPS(), 10_000, "BPS must stay under 100% or the removed fee<pot branch becomes reachable");
    }

    /// ⚠️ THE SCENE WAS `testDisputeFeeFloorsToZeroSkipsBothEvents` UNTIL
    /// 20 OCTOBER 2026 AND ITS PREMISE NO LONGER EXISTS. It read: a pot of 33
    /// units makes 3% round to zero by floor, so the fee is an honest nought
    /// and the `fee > 0` gate stops a false `DisputeFeeSkipped(0)`. A fee of
    /// nought is unreachable now -- the floor is ten dollars on any pot, and 33
    /// base units of escrow carry the same ten dollar charge as any other deal.
    /// What the scene holds instead is the pair that replaced it: the tiniest
    /// pot that exists still charges the full floor, and the winner still gets
    /// the whole of his 33 units because the fee never touches the escrow.
    /// ⚠️ AND THE OLD NAME IS CITED OUTSIDE THIS FILE TOO. Measured the same
    /// way on the same day, `testDisputeFeeFloorsToZeroSkipsBothEvents`
    /// appears in one of those same two working documents -- the spec, not
    /// the plan -- which now points at a name that does not exist. His
    /// document, reported and not edited.
    function testTheTiniestPotStillPaysTheFloorAndKeepsItsEscrow() public {
        Agreement a = Agreement(_createFundedAgreement(33));
        assertEq(a.disputeFee(), 10_000_000, "33 base units of escrow still carry the ten dollar floor");
        _activateAndDispute(a);

        uint256 clientBefore = usdc.balanceOf(client);

        vm.recordLogs();
        _submitAndFinalize(a, true);
        // ⚠️ THE EVENT PAIR THIS SCENE ASSERTED IS THE WRONG PAIR NOW
        // (21 October 2026), AND IT IS THE PREMISE THAT MOVED, NOT THE EVENTS.
        // It called `_assertNoDisputeFeeEventEmitted`, whose subject is a fee of
        // NOUGHT: 3% of 33 base units is 33 x 300 / 10 000 = 0 by floor
        // division, the `fee > 0` gate skipped the whole block, and neither
        // event could fire. A ten dollar floor makes a fee of nought
        // unreachable on any pot, so what fires here is FeePaid with the floor
        // in it, and the old helper is kept for the record rather than called.
        _assertDisputeFeePaidEmitted(10_000_000);

        assertEq(uint8(a.status()), uint8(Agreement.Status.RESOLVED), "the dispute must still close");
        assertEq(usdc.balanceOf(client) - clientBefore, 33, "the fee never touches the escrow, so the winner gets the whole (tiny) pot");
        // Worked out by hand. Retired first: fee 3% of 33 = 0, of which 90% to
        // the judge = 0 and a tenth to the treasury = 0 -- both noughts, and
        // both for the same reason, which is what made this scene silent.
        // Now: fee = max($10 floor, 3% of 33 = 0) = 10_000_000, the whole of it
        // the judge's, 10_000_000 - 10_000_000 = 0 left for the treasury. The
        // two noughts above have become one nought and one ten dollars, and
        // they are asserted apart because they are no longer the same fact.
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 10_000_000, "the floor is the judge's whole and the smallest pot pays it like any other");
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), TREASURY_TAKES_NOTHING, "the treasury takes nothing out of arbitration");
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

        // ⚠️ THE WHOLE POT (20 October 2026): the fee left the opener's wallet
        // at the door, so nothing is deducted at the verdict. It read
        // 194_000_000 -- the pot less 3% of it.
        assertEq(usdc.balanceOf(client) - clientBefore, 200_000_000, "client gets the whole pot");
        // ⚠️ RE-DERIVED 20 OCTOBER 2026. It read 5_400_000 -- 90% of a $6 fee
        // (3% of a $200 pot). The fee's floor is $10, which 3% of $200 does not
        // reach, and the whole fee is the judge's.
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 10_000_000, "arbiter takes the whole ten dollar fee");
        // ⚠️ AND THE TREASURY'S TENTH IS GONE WITH IT (21 October 2026), which
        // the line above was re-derived without. Retired, to check the method:
        // 200_000_000 x 3 / 100 = 6_000_000 of fee, 6_000_000 / 10 = 600_000 to
        // the treasury -- the literal that stood here. The owner's share is
        // nought now, so the subtraction is 10_000_000 - 10_000_000 = 0: the
        // judge's figure above and this one are the SAME fee split two ways,
        // and together they are the whole of it.
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), TREASURY_TAKES_NOTHING, "the treasury takes nothing out of arbitration");
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

        // ⚠️ THE WHOLE POT, AND THE SISTER SCENE ABOVE WAS RE-DERIVED WHILE
        // THIS ONE WAS NOT (21 October 2026). Retired, to check the method:
        // 200_000_000 of pot less 3% of it, 200_000_000 x 3 / 100 = 6_000_000,
        // gives 200_000_000 - 6_000_000 = 194_000_000 -- the literal that stood
        // here, and the "97%" the message still named. The fee left the
        // opener's wallet at the door, so nothing at all is deducted at the
        // verdict and the subtraction is gone rather than changed: the winner
        // gets 200_000_000. The message is corrected with the number, because
        // "97%" is exactly the thing a reader would check against.
        assertEq(usdc.balanceOf(executor) - executorBefore, 200_000_000, "the executor gets the whole pot -- the fee was paid at the door, not out of the escrow");
        // ⚠️ RE-DERIVED 20 OCTOBER 2026. It read 5_400_000 -- 90% of a $6 fee
        // (3% of a $200 pot). The fee's floor is $10, which 3% of $200 does not
        // reach, and the whole fee is the judge's.
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 10_000_000, "arbiter takes the whole ten dollar fee");
        // The treasury's tenth, 6_000_000 / 10 = 600_000, is nought now for the
        // reason given at length on the sister scene above.
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), TREASURY_TAKES_NOTHING, "the treasury takes nothing out of arbitration");
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

        // Worked out by hand, retired figure first so that the method can be
        // checked: the fee was 3% of the pot, 200_000_000 x 3 / 100 = 6_000_000,
        // of which the judge took 90%, 6_000_000 x 9 / 10 = 5_400_000 -- the
        // literal that stood here. Now the fee is max($10, 6_000_000) =
        // 10_000_000 and the whole of it is his, so 10_000_000 reaches his hand.
        uint256 arbBefore = usdc.balanceOf(arbiterAddr);
        vm.prank(arbiterAddr);
        ArbiterVaultFacet(address(diamond)).withdrawArbiterReward();
        assertEq(usdc.balanceOf(arbiterAddr) - arbBefore, 10_000_000, "reward must actually reach the arbiter's wallet");

        // ⚠️ AND THE TREASURY HALF OF THIS SCENE IS A REFUSAL NOW RATHER THAN A
        // PAYMENT (21 October 2026), which is the only honest way to keep the
        // claim the scene is named for. Retired: 6_000_000 / 10 = 600_000 of
        // slice, pushed to the fee recipient. The owner's share is nought, so
        // there is no slice to push and `withdrawTreasurySlice` answers
        // `NothingToPush` by name.
        //
        // The refusal is asserted rather than skipped ON PURPOSE. Dropping the
        // push would leave this file with no statement at all about where the
        // treasury's end of a fee goes, and a counter that merely READS nought
        // cannot tell "the decision holds" from "the credit silently failed and
        // the money is sitting somewhere else". The balance of the fee
        // recipient after the refused push is what rules the second out.
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), TREASURY_TAKES_NOTHING, "the treasury takes nothing out of arbitration");
        uint256 recipientBefore = usdc.balanceOf(feeRecipient);
        vm.expectRevert(ArbiterRegistryFacet.NothingToPush.selector);
        ArbiterVaultFacet(address(diamond)).withdrawTreasurySlice();
        assertEq(usdc.balanceOf(feeRecipient), recipientBefore, "not a base unit of a dispute fee may reach the fee recipient");
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

        // ⚠️ THE SELECTOR THIS SCENE BREAKS HAD MOVED AND THE SCENE WAS
        // BREAKING A DOOR NOTHING WALKS THROUGH ANY MORE (21 October 2026).
        // `resolveDispute` used to call `creditDisputeFee`, which took the fee
        // out of the pot at the verdict; it calls `settleDisputeFee` now,
        // because the money was taken at the door and only its DESTINATION is
        // decided here. Removing `creditDisputeFee` therefore broke nothing at
        // all, FeeSkipped never fired, and the scene went red on the one
        // assertion that noticed -- which is the good outcome of a lock whose
        // door was moved, and not the usual one.
        _removeSelectorFromDiamond(ArbiterVaultFacet.settleDisputeFee.selector);

        uint256 clientBefore  = usdc.balanceOf(client);
        uint256 diamondBefore = usdc.balanceOf(address(diamond));

        vm.recordLogs();
        _submitAndFinalize(a, true);
        // Worked out by hand, retired figure first: the fee was 3% of the pot,
        // 200_000_000 x 3 / 100 = 6_000_000, and that whole figure was what the
        // event announced as skipped. The fee has a ten dollar floor now and
        // max(10_000_000, 6_000_000) = 10_000_000 is what the door took, so
        // 10_000_000 is what cannot be settled.
        _assertDisputeFeeSkippedEmitted(10_000_000);

        // The bond this case carries came home at finalization, so the
        // diamond's balance FELL by it while the fee never arrived. Named, or
        // the subtraction below underflows (22 September 2026).
        uint256 caseBondBack = 20_000_000;

        // ⚠️ AND WHAT A FAILED SETTLEMENT COSTS IS NOT WHAT A FAILED CREDIT
        // COST (21 October 2026). The old sentence here was "the fee is NOT
        // taken at all, the winner gets it instead": the credit happened at the
        // verdict, so a broken credit left the money in the pot. The fee was
        // taken at the DOOR now and is on the diamond before this scene starts,
        // so a broken settlement cannot give it to anybody -- it STAYS, with
        // its amount and its payer still written down, which is a recoverable
        // state and the reason the ending is tolerated at all.
        //
        // So the two claims below are different claims. The winner still gets
        // the whole pot -- for a new reason, the fee never being in it. And
        // the diamond's balance must not MOVE either way: a cent appearing
        // would be the pot leaking into it, and a cent leaving would be the
        // failed settlement paying somebody after all.
        assertEq(uint8(a.status()), uint8(Agreement.Status.RESOLVED), "the dispute must still close");
        assertEq(usdc.balanceOf(client) - clientBefore, 200_000_000, "the fee was never in the pot, so the winner gets the whole of it");
        assertEq(usdc.balanceOf(address(diamond)) + caseBondBack - diamondBefore, 0, "the failed settlement must move nothing in either direction");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 0, "nothing credited");
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), TREASURY_TAKES_NOTHING, "nothing credited");

        // ⚠️ AND THE RECORD HAS TO SURVIVE, which is the whole of what makes
        // this ending recoverable instead of a loss. Ten dollars with no name
        // on them are ten dollars nobody can ever be paid.
        (uint256 heldStill, address payerStill) =
            ArbiterVaultFacet(address(diamond)).getHeldDisputeFee(address(a));
        assertEq(heldStill, 10_000_000, "the held fee must still be recorded, or it can never be paid to anyone");
        assertEq(payerStill, client, "and the man who put it down must still be named");
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
        // Worked out by hand, retired figure first: fee 3% of the pot,
        // 200_000_000 x 3 / 100 = 6_000_000, of which 90% was the judge's,
        // 6_000_000 x 9 / 10 = 5_400_000. The fee is max($10, 6_000_000) =
        // 10_000_000 now and the whole of it is his.
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            10_000_000,
            "the reward stays credited and withdrawable later"
        );

        // And it cannot be collected yet — but that is a refused payout, not a refused closing.
        vm.prank(arbiterAddr);
        vm.expectRevert();
        ArbiterVaultFacet(address(diamond)).withdrawArbiterReward();
    }

    // ============================================================
    //  triggerArbiterTimeout() — the pot in half if nobody took the dispute
    // ============================================================

    /// Nobody took the dispute on AND nothing was ever handed in: the whole escrow
    /// goes home to the client, whoever turned up.
    ///
    /// ⚠️ THIS TEST IS THE ONE THE FIX WAS MEASURED BY, and until 25 September 2026
    /// it stood here green under the name `testTimeoutWithoutClaimSplitsThePot`,
    /// asserting `100_000_000` to each side on exactly this setup — an executor who
    /// activated the deal, never pressed markDone, answered the dispute, and walked
    /// off with half. That was the junk-dispute payoff in one line of arithmetic; the
    /// old body is what item 157 of OPEN-ITEMS called a free way to be paid for doing
    /// nothing. The name changed with the expectation on purpose: a test called
    /// "SplitsThePot" that asserts a full refund is a trap for the next reader.
    ///
    /// The scene the old name described is still measured, one hand-in richer:
    /// testTimeoutSplitsInHalfWhenBothResponded.
    function testTimeoutWithoutAHandInRefundsTheClientInFull() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _openTheDispute(client, a);
        // The other side turned up — and turning up is no longer worth anything on
        // its own. This is the whole point: attendance cannot manufacture money out
        // of work that was never handed in.
        vm.prank(executor);
        a.respondToDispute();
        assertEq(a.arbiter(), address(0), "setup: nobody claimed");
        assertEq(a.markedDoneAt(), 0, "setup: nothing was ever handed in");

        vm.warp(vm.getBlockTimestamp() + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        // Both events, and the money statement keeps the name every reader already
        // understands — otherwise the deal shows "in dispute" for ever in the app,
        // the card and the subgraph.
        vm.expectEmit(true, false, false, true, address(a));
        emit Agreement.TimedOut(client, 200_000_000);
        vm.expectEmit(true, false, false, false, address(a));
        emit Agreement.DisputeNothingHandedIn(executor);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore,   200_000_000 + DOOR_CHARGE_HOME, "the whole escrow home, and the door charge with it");
        assertEq(usdc.balanceOf(executor) - eBefore, 0,           "nothing for work never handed in");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// THE MIRROR THE FIX EXISTS FOR: the executor raises the empty dispute himself,
    /// the client never answers, and four days later the executor presses the timeout
    /// with his own hand. Before 25 September 2026 that paid him three quarters of
    /// the pot — 150 USDC of 200 — for having delivered nothing and pressed two free
    /// buttons. It is the cheapest attack the escrow had, and it now pays zero.
    function testTheExecutorsOwnEmptyDisputeEarnsHimNothing() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _openTheDispute(executor, a);
        assertEq(a.markedDoneAt(), 0, "setup: he never handed anything in");
        assertTrue(a.executorResponded(), "setup: raising it counts as turning up");
        assertFalse(a.clientResponded(),  "setup: the client stayed silent");

        vm.warp(vm.getBlockTimestamp() + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(executor);
        a.triggerArbiterTimeout();

        // ⚠️ HIS OWN TEN DOLLARS COME BACK AND NOTHING ELSE DOES (20 October
        // 2026). He opened the dispute, so he paid `disputeFee()` at the door;
        // no verdict was written, so it goes home. Of the ESCROW he still gets
        // nothing, which is what this scene is named for -- and the two sums
        // are asserted apart so that neither can cover the other.
        assertEq(
            usdc.balanceOf(executor) - eBefore, DOOR_CHARGE_HOME,
            "the griefer kept something besides his own door charge"
        );
        assertEq(usdc.balanceOf(client)   - cBefore, 200_000_000, "and the client is whole");
        assertEq(a.undeliveredPayout(), 0, "not even booked as a debt to him");
    }

    /// ⚠️ THE NAME SAYS "STILL FREE TO OPEN" AND THAT IS NOW HALF FALSE, AND
    /// THE NAME IS KEPT ANYWAY. Measured with `grep -rln` across the whole
    /// checkout on 20 October 2026, it is cited by name in the owner's own
    /// working journal -- which does NOT travel to the public showcase, so the
    /// path is deliberately not written here -- and renaming it from this side
    /// would break a live citation in the document he reads. Whether the
    /// name moves is his call; what this file owes him is a body that measures
    /// the truth under the old name.
    ///
    /// The truth, in two halves that must not be collapsed:
    ///
    ///   OPENING IT IS NOT FREE. `raiseDispute` takes `disputeFee()` -- ten
    ///   dollars on any pot -- out of the opener's own wallet, through the
    ///   diamond, and will not open the dispute without it.
    ///
    ///   IT STILL COSTS HIM NOUGHT IN THE END, because this road is the one
    ///   where no verdict is written and the fee goes home (the owner's
    ///   decision of 19 October, kept on the 20th). So the sentence the old
    ///   name carries -- "the payoff is gone but the entrance costs nothing" --
    ///   survives as a statement about the NET and is false about the moment.
    ///
    /// ⚠️ AND THE SCENE WAS GREEN FOR THE WRONG REASON BEFORE THIS REWRITE,
    /// which is the part worth reading twice. It called `_armTheDoor` -- the
    /// helper that mints exactly the charge -- and then asserted the purse was
    /// unchanged after the press. It was unchanged: the mint cancelled the
    /// charge to the base unit, so the one scene written to measure whether
    /// opening a dispute costs anything was reporting the rig's own mint.
    /// It funds the opener with a KNOWN FLOAT instead, and reads his purse
    /// after the float, so the debit is visible.
    function testAnEmptyDisputeIsStillFreeToOpenAndNowPaysNothing() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();

        // A float he already has, big enough for the charge and not equal to
        // it: an equal float is what made the old reading unfalsifiable.
        uint256 float_ = DOOR_CHARGE_HOME * 3;
        usdc.mint(executor, float_);
        vm.prank(executor); usdc.approve(address(diamond), float_);

        uint256 walletBefore = usdc.balanceOf(executor);
        vm.prank(executor);
        a.raiseDispute();

        // ── HALF ONE: the press cost him the charge, out of money he had. ──
        assertEq(
            walletBefore - usdc.balanceOf(executor), DOOR_CHARGE_HOME,
            "opening a dispute moved no USDC out of the opener's wallet -- the charge at the door is gone"
        );

        vm.warp(vm.getBlockTimestamp() + a.DISPUTE_WINDOW() + 1);
        vm.prank(executor);
        a.triggerArbiterTimeout();

        // ── HALF TWO: and the end of it leaves him exactly where he began, so
        //    the attempt is free on the net. This is the finding, not a defect
        //    report: the owner was shown it and kept his decision. ──
        assertEq(
            usdc.balanceOf(executor), walletBefore,
            "the door charge did NOT come home on a dispute nobody judged -- the junk attempt now has a price and this scene is the one to re-read"
        );
    }

    /// THE BORDER OF "HANDED IN", top side: markDone is refused after the deadline
    /// plus its grace, so the last instant at which delivery can be claimed at all
    /// is `activatedAt + deadlineDays + DEADLINE_GRACE` exactly. A hand-in on that
    /// very second counts, and the pot splits.
    function testAHandInOnTheLastSecondOfTheGraceStillCountsAsDelivery() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();

        uint256 border = a.activatedAt() + 7 days + a.DEADLINE_GRACE();
        vm.warp(border);
        vm.prank(executor);
        a.markDone();
        assertEq(a.markedDoneAt(), border, "the hand-in is stamped on the border second");

        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();
        vm.warp(vm.getBlockTimestamp() + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - eBefore, 100_000_000, "a border hand-in is a hand-in");
        assertEq(usdc.balanceOf(client)   - cBefore, 100_000_000 + DOOR_CHARGE_HOME, "half each, and the opener's door charge home");
    }

    /// THE BORDER, one second past it: markDone is refused BY NAME, and so is the
    /// dispute — past the grace the deal has exactly one door left and it pays the
    /// client in full. So there is no window in which "too late to hand in" and
    /// "still in time to argue about it" overlap: the split branch cannot be reached
    /// with a late hand-in at all.
    function testASecondPastTheGraceThereIsNoHandInAndNoDisputeEither() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();

        vm.warp(a.activatedAt() + 7 days + a.DEADLINE_GRACE() + 1);

        vm.prank(executor);
        vm.expectRevert(Agreement.DeadlinePassed.selector);
        a.markDone();

        vm.prank(client);
        vm.expectRevert(Agreement.DeadlinePassed.selector);
        a.raiseDispute();

        uint256 cBefore = usdc.balanceOf(client);
        vm.prank(client);
        a.triggerDeadlineTimeout();
        assertEq(usdc.balanceOf(client) - cBefore, 200_000_000, "the one door left pays the client");
    }

    // ============================================================
    //  markDone() during a dispute nobody has taken on
    // ============================================================

    /// THE HOLE THE 25 SEPTEMBER FIX OPENED, AND THE LOCK THAT CLOSES IT.
    ///
    /// Until the hand-in decided the unjudged timeout, a client who disputed
    /// BEFORE the hand-in took the whole pot back: `markDone` refused a disputed
    /// deal outright (`AlreadyDisputed`), so the executor could not put delivery
    /// on the record at all, and the timeout read "nothing handed in" and sent
    /// every cent home. Measured on this very scene: 200 USDC of 200 to the
    /// client, nothing to the executor, with his deadline still four days away.
    /// Before the fix this test reddens on the `markDone` line itself.
    ///
    /// The owner's rule read "no hand-in AND THE DEADLINE PASSED -> all to the
    /// client", and the second half is what protects the executor. It cannot be
    /// asked of `_disputedAt` though: `raiseDispute` already refuses a
    /// hand-in-less dispute once the grace is over, so "the window was over when
    /// the dispute was opened" is a contradiction and the branch would be dead
    /// (measured: asking it reddens testTheExecutorsOwnEmptyDisputeEarnsHimNothing
    /// with 150000000 != 0, which is the junk-dispute payoff restored).
    ///
    /// So the shape is the other one: give the executor his action back instead
    /// of paying him for losing it. The dispute no longer bars the hand-in while
    /// nobody is judging, and the timeout then splits because there IS delivery
    /// on the record. The floor under a junk dispute stays exactly where the
    /// 25 September fix put it -- a permanent on-chain claim of delivery.
    function testAnEarlyClientDisputeDoesNotLockTheExecutorOutOfHandingIn() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();

        // Day one of a seven-day deal: the client goes to dispute before any
        // delivery, which used to be the whole attack.
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();
        assertEq(a.arbiter(), address(0), "setup: nobody has taken it on");

        // THE LINE THIS TEST EXISTS FOR. It reverted AlreadyDisputed before the
        // fix, and with it the executor's only way to prove delivery on chain.
        vm.prank(executor);
        a.markDone();
        assertTrue(a.markedDoneAt() != 0, "the hand-in is on the record");
        assertEq(uint8(a.status()), uint8(Agreement.Status.DISPUTED),
                 "and the deal is still in dispute, not back in delivery");

        vm.prank(executor);
        a.respondToDispute();

        vm.warp(vm.getBlockTimestamp() + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - eBefore, 100_000_000, "half to the executor, not nothing");
        assertEq(usdc.balanceOf(client)   - cBefore, 100_000_000 + DOOR_CHARGE_HOME, "half to the client, not everything, plus his door charge");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// THE FENCE, and without it this fix is worse than the hole it closes: a
    /// hand-in during a dispute an arbiter is ALREADY JUDGING would let the
    /// executor edit the record the verdict is being formed on, after the
    /// arbiter has read it. So the door is open only while `arbiter == 0` --
    /// while there is nobody whose judgement could be undercut.
    function testAHandInIsRefusedOnceAnArbiterHasTakenTheDisputeOn() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();

        _claimByArbiter(a);
        assertTrue(a.arbiter() != address(0), "setup: the dispute is being judged");

        vm.prank(executor);
        vm.expectRevert(Agreement.AlreadyDisputed.selector);
        a.markDone();
        assertEq(a.markedDoneAt(), 0, "the record the arbiter reads is untouched");
    }

    /// THE BORDER IS THE DELIVERY WINDOW AND NOTHING ELSE. An open dispute does
    /// not extend it and does not shorten it: on the last second of
    /// `activatedAt + deadlineDays + DEADLINE_GRACE` the hand-in still counts,
    /// one second later it is `DeadlinePassed` -- the same border, to the second,
    /// that a deal without a dispute has.
    function testAHandInDuringAnOpenDisputeStopsAtTheSameGraceBorder() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();

        uint256 border = a.activatedAt() + 7 days + a.DEADLINE_GRACE();

        // One second past it: refused by name, dispute or no dispute.
        vm.warp(border + 1);
        vm.prank(executor);
        vm.expectRevert(Agreement.DeadlinePassed.selector);
        a.markDone();

        // And on the border second itself it lands.
        vm.warp(border);
        vm.prank(executor);
        a.markDone();
        assertEq(a.markedDoneAt(), border, "the hand-in is stamped on the border second");
    }

    // ============================================================
    //  The mark on an executor who delivered nothing
    // ============================================================

    /// Field offset of `cleanStreak` inside ReputationStorage.Data, counted from
    /// the namespace position -- the same rig CleanStreakSpeaks.t.sol uses. A
    /// streak cannot be earned cheaply in this harness (it needs settled deals
    /// whose counterparty already holds XP), and the point here is what the
    /// timeout DOES to a streak, not how one is built.
    uint256 constant SLOT_CLEAN_STREAK = 9;

    function _seedStreak(address who, uint256 streak) internal {
        vm.store(
            address(diamond),
            keccak256(abi.encode(who, uint256(ReputationStorage.POSITION) + SLOT_CLEAN_STREAK)),
            bytes32(streak)
        );
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(who), streak,
                 "rig: seeding the streak hit the wrong slot");
    }

    /// TOOK THE DEAL ON AND NOTHING FOLLOWED -- and now it shows in the record.
    /// The two other roads to that same ending (`triggerDeadlineTimeout` and the
    /// refusal before the start) have always called `notifyExecutorFault`; the
    /// unjudged dispute was the one way to reach it with a clean sheet, which
    /// made the free dispute a way to launder a no-show as well as a way to be
    /// paid for one.
    function testAnUnjudgedTimeoutWithNoHandInMarksTheExecutorsRecord() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _seedStreak(executor, 5);

        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();
        assertEq(a.markedDoneAt(), 0, "setup: nothing was ever handed in");

        vm.warp(vm.getBlockTimestamp() + a.DISPUTE_WINDOW() + 1);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(ReputationFacet(address(diamond)).getCleanStreak(executor), 0,
                 "the clean streak is broken: 5 -> 0");
    }

    /// AND NOT WHEN THE WORK WAS HANDED IN. A dispute over delivered work is an
    /// argument about quality that nobody judged; marking the executor at fault
    /// there would be a verdict handed down by a clock. His streak survives the
    /// split untouched.
    function testAnUnjudgedTimeoutAfterAHandInLeavesTheRecordAlone() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _seedStreak(executor, 5);

        _handIn(a);
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();

        vm.warp(vm.getBlockTimestamp() + a.DISPUTE_WINDOW() + 1);
        uint256 eBefore = usdc.balanceOf(executor);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - eBefore, 100_000_000, "setup: this really was the split");
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(executor), 5,
                 "a quality argument nobody judged is not a fault: 5 stays 5");
    }

    /// THE MARK MUST NEVER COST THE MONEY. The reputation write is broken in the
    /// harness the only way a chain could break it -- the selector is taken off
    /// the diamond, so the clone's `try` finds the fallback and reverts inside
    /// it. The timeout must still pay, and must not revert.
    function testABrokenFaultWriteDoesNotHoldUpTheTimeoutsMoney() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _seedStreak(executor, 5);

        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();

        _removeSelectorFromDiamond(ReputationFacet.notifyExecutorFault.selector);

        vm.warp(vm.getBlockTimestamp() + a.DISPUTE_WINDOW() + 1);
        uint256 cBefore = usdc.balanceOf(client);
        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore, 200_000_000 + DOOR_CHARGE_HOME, "the money arrives regardless, and the door charge with it");
        assertEq(usdc.balanceOf(address(a)), 0, "and the clone is emptied");
        assertEq(uint8(a.status()), uint8(Agreement.Status.REFUNDED), "the deal is closed, not stuck");
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(executor), 5,
                 "proof the write really did fail -- the streak is untouched at 5");
    }

    /// THE MIRROR, BOTH WAYS IN ONE PLACE, because the hole existed precisely
    /// because only one direction had ever been played through.
    ///
    /// The client disputes early: the executor hands in, takes his half, and his
    /// record is NOT marked -- he did the thing that was asked of him.
    /// The executor disputes with empty hands: he gets nothing AND his record is
    /// marked. Same branch, same timeout, opposite endings.
    function testTheTwoDirectionsOfAnUnjudgedDisputeEndDifferently() public {
        // --- the client raised it before any delivery ---
        Agreement byClient = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        byClient.activate();
        _seedStreak(executor, 5);
        _armTheDoor(client, byClient);
        vm.prank(client);
        byClient.raiseDispute();
        vm.prank(executor);
        byClient.markDone();          // the door form B gives back
        vm.prank(executor);
        byClient.respondToDispute();
        vm.warp(vm.getBlockTimestamp() + byClient.DISPUTE_WINDOW() + 1);
        uint256 eBefore = usdc.balanceOf(executor);
        vm.prank(client);
        byClient.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - eBefore, 100_000_000, "he delivered, so he is paid his half");
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(executor), 5,
                 "and he is not marked for having been dragged into a dispute");

        // --- the executor raised it with empty hands ---
        Agreement byExecutor = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        byExecutor.activate();
        _armTheDoor(executor, byExecutor);
        vm.prank(executor);
        byExecutor.raiseDispute();
        vm.warp(vm.getBlockTimestamp() + byExecutor.DISPUTE_WINDOW() + 1);
        uint256 eBefore2 = usdc.balanceOf(executor);
        vm.prank(executor);
        byExecutor.triggerArbiterTimeout();

        // ⚠️ NAMED AS A SUM OF TWO THINGS THAT ARE NOT THE SAME MONEY, and the
        // nought is written out rather than dropped. Nought of the ESCROW is
        // what the split rule decides for a man who handed nothing in; the ten
        // dollars are HIS OWN, paid at the door when he opened the dispute and
        // sent home because no verdict was ever written. Folded into one
        // literal the reader can check neither: he cannot tell a man paid
        // nothing from a man paid ten dollars for walking away.
        assertEq(usdc.balanceOf(executor) - eBefore2, 0 + DOOR_CHARGE_HOME, "nothing of the escrow for empty hands, and only his own door charge back");
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(executor), 0,
                 "and the record says so: 5 -> 0");
    }

    /// TWO PROCESSES AT ONCE: the claim and the timeout can never both succeed,
    /// because their windows do not overlap by one second. On `disputedAt +
    /// DISPUTE_WINDOW` the claim is still lawful and the timeout refuses
    /// WindowNotPassed; a second later it is the other way round. Measured in ONE
    /// block, since that is the case the arithmetic would have to survive.
    function testTheClaimAndTheTimeoutCannotBothWinInOneBlock() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();

        vm.warp(a.disputedAt() + a.DISPUTE_WINDOW());

        // Same block, the timeout first: refused.
        vm.prank(client);
        vm.expectRevert(Agreement.WindowNotPassed.selector);
        a.triggerArbiterTimeout();

        // Same block, the claim: lawful.
        _claimByArbiter(a);
        assertTrue(a.arbiter() != address(0), "the boundary second belongs to the claim");

        // And now the timeout takes the arbiter-fault road, not the split: the pot
        // cannot leave twice, and a claimed dispute never reads delivery at all.
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 cBefore = usdc.balanceOf(client);
        vm.prank(client);
        a.triggerArbiterTimeout();
        assertEq(usdc.balanceOf(client) - cBefore, 200_000_000 + DOOR_CHARGE_HOME, "whole pot and door charge to the client, once");

        vm.prank(client);
        vm.expectRevert(Agreement.AlreadyFinalized.selector);
        a.triggerArbiterTimeout();
        assertEq(usdc.balanceOf(address(a)), 0, "and the clone stays empty");
    }

    /// The pot cannot go out twice on the delivery road either.
    function testTheRefundForANonDeliveryHappensOnlyOnce() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();
        vm.warp(vm.getBlockTimestamp() + a.DISPUTE_WINDOW() + 1);

        vm.prank(client);
        a.triggerArbiterTimeout();

        uint256 cBefore = usdc.balanceOf(client);
        vm.prank(client);
        vm.expectRevert(Agreement.AlreadyFinalized.selector);
        a.triggerArbiterTimeout();
        assertEq(usdc.balanceOf(client), cBefore, "a second press pays nothing");
    }

    /// JUNK ON THE SEAM: `_markedDoneAt == 0` means "never handed in", so the one
    /// input that could lie to the new branch is a hand-in stamped at zero. It
    /// cannot be reached, and the refusal has a NAME rather than a wrong split: at
    /// epoch zero the escrow cannot even be activated, because `fundedAt` uses the
    /// same sentinel and is checked first. Nothing in the contract takes a timestamp
    /// from a caller, so there is no second way in.
    function testAtEpochZeroTheDealRefusesByNameInsteadOfLosingItsHandIn() public {
        vm.warp(0);
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        assertEq(a.fundedAt(), 0, "the sentinel and the real stamp collide at epoch zero");
        assertEq(uint8(a.status()), uint8(Agreement.Status.CREATED), "so the deal reads as unfunded");

        vm.prank(executor);
        vm.expectRevert(Agreement.NotFunded.selector);
        a.activate();
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

        assertEq(usdc.balanceOf(client) - cBefore,   200_000_000 + DOOR_CHARGE_HOME, "whole pot to client, with his door charge");
        assertEq(usdc.balanceOf(executor) - eBefore, 0,           "executor gets nothing");
    }

    /// The fee is taken on no timeout path in any case: there is no verdict, the
    /// work is not done, and there is nobody to pay.
    function testTimeoutTakesNoFee() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), 0, "no treasury slice");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// An odd pot: not one unit must settle in the contract. 33 units → 16 to the
    /// executor, 17 to the client (the remainder to whoever's money it was).
    function testTimeoutSplitLosesNoUnitOnAnOddPot() public {
        Agreement a = Agreement(_createFundedAgreement(33));
        vm.prank(executor);
        a.activate();
        _handIn(a);
        _armTheDoor(client, a);
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
        assertEq(usdc.balanceOf(client)   - cBefore, 17 + DOOR_CHARGE_HOME, "remainder to the client, plus his door charge -- the charge is round, so it cannot hide the odd unit");
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
        vm.stopPrank();
        // The hand-in sits between the top-up and the dispute on purpose:
        // proposeExtra refuses a marked-done deal (AlreadyMarkedDone), and
        // without a hand-in the timeout would pay the executor nothing at all
        // and this scene would stop being about the pending top-up.
        _handIn(a);
        _armTheDoor(client, a);
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

        // Worked out by hand, as four named things rather than one literal:
        //   50_000_000   the pending top-up back whole -- never accepted
        //    2_500_000   the fee held on that top-up, 5% of 50_000_000, which
        //                nobody earned because nobody accepted it
        //  100_000_000   half of the 200_000_000 pot, both sides having shown up
        //   10_000_000   his own door charge home, no verdict having been written
        //  ------------
        //  162_500_000
        // ⚠️ THE FIRST THREE SUMMED TO THE RETIRED LITERAL, which is how the
        // method was checked: 50_000_000 + 2_500_000 + 100_000_000 =
        // 152_500_000, exactly what stood here. The message already said "held
        // fee with it" and the number did not -- the fourth line is the only
        // addition, and it is kept apart because it is the only one of the four
        // that is not the deal's money.
        assertEq(
            usdc.balanceOf(client) - cBefore,
            50_000_000 + 2_500_000 + 100_000_000 + DOOR_CHARGE_HOME,
            "pending back whole, held fee with it, half the pot, and his door charge"
        );
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
        _handIn(a);
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        usdc.setBlocked(executor, true);

        uint256 cBefore = usdc.balanceOf(client);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore, 150_000_000 + DOOR_CHARGE_HOME, "the client's own three quarters and his door charge, no more");
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
        _armTheDoor(client, a);
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
        _handIn(a);
        _armTheDoor(client, a);
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

        assertEq(usdc.balanceOf(client) - cBefore,   200_000_000 + DOOR_CHARGE_HOME, "whole pot still to the client, with his door charge");
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
        _handIn(a);
        _armTheDoor(client, a);
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

        assertEq(usdc.balanceOf(client) - cBefore, 100_000_000 + DOOR_CHARGE_HOME, "the client's half went out, and his door charge with it");
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
        _armTheDoor(client, a);
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
        _armTheDoor(executor, a);
        vm.prank(executor);
        a.raiseDispute();

        assertTrue(a.executorResponded(), "raiser must be marked present");
        assertFalse(a.clientResponded(), "counterparty must start silent");
    }

    function testRespondToDisputeMarksTheCounterparty() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _armTheDoor(client, a);
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
        _armTheDoor(client, a);
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
        _armTheDoor(client, a);
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
        _armTheDoor(client, a);
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
        _armTheDoor(client, a);
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
        _armTheDoor(client, a);
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
        _armTheDoor(client, a);
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
        _armTheDoor(client, a);
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
        _handIn(a);
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client) - cBefore,   100_000_000 + DOOR_CHARGE_HOME, "half to client, plus his door charge");
        assertEq(usdc.balanceOf(executor) - eBefore, 100_000_000, "half to executor");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// The executor stayed silent — a quarter to them, three quarters to the client.
    function testTimeoutGivesQuarterToTheSilentExecutor() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _handIn(a);
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(executor) - eBefore, 50_000_000,  "quarter to the silent executor");
        assertEq(usdc.balanceOf(client)   - cBefore, 150_000_000 + DOOR_CHARGE_HOME, "three quarters to the client, plus the door charge he paid");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// The mirror: the client stayed silent — a quarter to them, three quarters to
    /// the executor. Without this test the rule is easy to write one-sidedly.
    function testTimeoutGivesQuarterToTheSilentClient() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _handIn(a);
        _armTheDoor(executor, a);
        vm.prank(executor);
        a.raiseDispute();

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 cBefore = usdc.balanceOf(client);
        uint256 eBefore = usdc.balanceOf(executor);

        vm.prank(executor);
        a.triggerArbiterTimeout();

        assertEq(usdc.balanceOf(client)   - cBefore, 50_000_000,  "quarter to the silent client");
        assertEq(usdc.balanceOf(executor) - eBefore, 150_000_000 + DOOR_CHARGE_HOME, "three quarters to the executor, plus the door charge he paid");
        assertEq(usdc.balanceOf(address(a)), 0, "the agreement must be emptied");
    }

    /// The remainder of the division is not lost: it is computed by subtraction and
    /// goes to whoever showed up. On a pot of 7 that is 1 to the silent one and 6 to
    /// the one who showed up, not 1 and 5.
    function testTimeoutUnansweredLosesNoUnitOnAnOddPot() public {
        Agreement a = Agreement(_createFundedAgreement(7));
        vm.prank(executor);
        a.activate();
        _handIn(a);
        _armTheDoor(client, a);
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
        assertEq(toClient,   6 + DOOR_CHARGE_HOME, "remainder to the responder, plus the door charge he paid -- the charge is round, so it cannot hide the odd unit");
        // The conservation claim, with the door charge named on the side it
        // arrived on. 1 + (6 + 10_000_000) = 7 + 10_000_000: the pot is whole
        // and the charge is the client's own money coming back on top of it.
        // Folding the charge into the 7 would make the identity unreadable --
        // the point of the scene is that the ODD UNIT is not lost, and a round
        // ten million either side of it must not be able to hide one.
        assertEq(toExecutor + toClient, 7 + DOOR_CHARGE_HOME, "not a single unit of the pot may vanish, and the door charge must not hide one");
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
        _handIn(a);
        _armTheDoor(client, a);
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

        assertEq(usdc.balanceOf(client) - cBefore, 150_000_000 + DOOR_CHARGE_HOME, "the responder's own three quarters, plus the door charge he paid");
        assertEq(a.undeliveredPayout(), 50_000_000, "the silent side's quarter is owed to them");
        assertEq(usdc.balanceOf(address(a)), 50_000_000, "held, not confiscated");
    }

    /// The same blacklist, but the executor showed up and three quarters were due to
    /// them: the undelivered amount is booked as a debt to them.
    function testBlockedRespondingExecutorDoesNotFreezeTheTimeout() public {
        Agreement a = Agreement(_createFundedAgreement(200_000_000));
        vm.prank(executor);
        a.activate();
        _handIn(a);
        _armTheDoor(executor, a);
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
        _handIn(a);
        _armTheDoor(client, a);
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
        _handIn(a);
        _armTheDoor(executor, a);
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
        _handIn(a);
        _armTheDoor(client, a);
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

        assertEq(usdc.balanceOf(client) - cBefore, 200_000_000 + DOOR_CHARGE_HOME, "whole pot to the client, with his door charge");
        assertEq(usdc.balanceOf(executor) - eBefore, 0, "executor gets nothing on arbiter fault");
    }

    // -------- THE PAID CALL: THE FLOOR AND THE QUOTE --------

    /// The floor defaults to 10 USDC. It is what decides from what deal amount the
    /// service makes any sense at all.
    function testArbiterFloorDefaultsToTen() public view {
        assertEq(ArbiterVaultFacet(address(diamond)).getArbiterFloor(), 10_000_000, "default floor is $10");
    }

    function testSetArbiterFloorOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(ArbiterRegistryFacet.NotOwner.selector);
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(15_000_000);
    }

    function testSetArbiterFloorChangesQuote() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();
        _openTheDispute(client, a);

        uint256 before_ = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(20_000_000);
        uint256 after_ = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));

        assertEq(after_ - before_, 10_000_000, "raising the floor by $10 raises the top-up by $10");
    }

    /// ⚠️ RE-DERIVED 20 OCTOBER 2026, AND THE SCENE NEEDED A HIGHER FLOOR TO
    /// SURVIVE AT ALL. It used to read: a pot of $100, fee 3% = $3, 90% to the
    /// arbiter = $2.70, so $7.30 short of the $10 floor. Both halves of that
    /// moved on the same day -- the fee gained a $10 floor of its own and the
    /// arbiter now takes the WHOLE of it -- so on a $100 pot the fee already
    /// IS the floor and the top-up is nought.
    ///
    /// A scene asserting nought there would prove nothing: it is the answer on
    /// EVERY pot while the two floors are the same ten dollars. So this one
    /// raises the arbiter floor to $20 by the owner's own door, which is the
    /// only state in which a top-up exists at all now, and measures the
    /// difference: $20 to find, $10 of it already in the fee, $10 left.
    ///
    /// ⚠️ AND THAT IS THE SENTENCE TO CARRY AWAY ABOUT THE DOOR: it is alive
    /// exactly when the arbiter floor stands ABOVE the dispute fee. On a deal
    /// cut from this implementation, with the floor at its default, it never
    /// is. It stays for the sixteen clones already on Base Sepolia, whose fee
    /// is 3% of the pot with nothing under it.
    function testQuoteTopUpOnSmallPot() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();
        _openTheDispute(client, a);

        assertEq(
            ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a)), 0,
            "with the floor at its default a modern deal needs no top-up -- the fee already reaches it"
        );

        ArbiterVaultFacet(address(diamond)).setArbiterFloor(20_000_000);
        assertEq(
            ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a)), 10_000_000,
            "top-up to reach a $20 floor from a $10 fee"
        );
    }

    /// The pot is large enough that the arbiter reaches the floor by himself,
    /// so the top-up is nought.
    ///
    /// ⚠️ RE-DERIVED 20 OCTOBER 2026, AND MEASURED AGAINST A RAISED FLOOR FOR
    /// THE SAME REASON AS THE SCENE ABOVE. The old arithmetic was
    /// $10 / 0.024 = $416.67, which is why $420 was the pot. With the whole fee
    /// going to the judge and a $10 floor under it, every pot clears a $10
    /// floor and this scene would be green on nothing. Against a $20 floor the
    /// claim is real again: 3% reaches $20 at a pot of $666.666667, so
    /// $700 clears it and $100 (above) does not.
    function testQuoteTopUpIsZeroOnLargePot() public {
        Agreement a = Agreement(_createFundedAgreement(700_000_000));
        vm.prank(executor);
        a.activate();
        _openTheDispute(client, a);

        ArbiterVaultFacet(address(diamond)).setArbiterFloor(20_000_000);
        assertEq(a.disputeFee(), 21_000_000, "setup: 3% of a $700 pot is $21, over the $20 floor this scene raises");
        assertEq(ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a)), 0, "big pot pays the arbiter by itself");
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
        _openTheDispute(client, a);

        // ⚠️ $450 → $500 ON 22 SEPTEMBER 2026, and the scene keeps its point.
        // The arbiter's share went from 80% to 90%, so 90% of the CAPPED $500
        // fee is $450 and a $450 floor would need no top-up at all — the scene
        // would pass on zero and prove nothing. At a $500 floor the capped fee
        // leaves $50 to find, while the raw 3% of a $30 000 pot ($900, 90% of
        // which is $810) would leave nothing: the two answers still differ, and
        // that difference is what this measures.
        // ⚠️ $500 → $550 ON 20 OCTOBER 2026, AND THE SCENE KEEPS ITS POINT A
        // SECOND TIME. The arbiter's share went from 90% to the WHOLE fee, so
        // the capped $500 fee now reaches a $500 floor exactly and that floor
        // would need no top-up at all — the scene would pass on nought and
        // prove nothing, which is the same accident the 22 September note
        // describes one rung lower. At a $550 floor the capped fee leaves $50
        // to find, while the raw 3% of a $30 000 pot ($900, all of which would
        // be the judge's) would leave nothing: the two answers still differ by
        // 50_000_000, and that difference is what this measures.
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(550_000_000);

        assertEq(a.disputeFee(), 500_000_000, "setup: fee is capped at $500");
        assertEq(
            ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a)),
            50_000_000,
            "top-up must be computed from the CAPPED fee, not from raw 3%"
        );
    }

    function testQuoteRevertsIfNotDisputed() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();

        vm.expectRevert(ArbiterRegistryFacet.NotDisputed.selector);
        ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
    }

    // -------- THE PAID CALL: PAYMENT AND REFUND --------

    function _disputedAgreement(uint256 dealAmount) internal returns (Agreement a) {
        a = Agreement(_createFundedAgreement(dealAmount));
        vm.prank(executor);
        a.activate();
        // Handed in before the dispute, so the scenes built on this fixture stay
        // scenes about the top-up and the split rather than about delivery: with
        // no markDone the unclaimed timeout now pays the executor nothing.
        _handIn(a);
        _openTheDispute(client, a);

        // ⚠️ AND THE ARBITER FLOOR IS RAISED ABOVE THE FEE, 20 OCTOBER 2026,
        // BECAUSE OTHERWISE EVERY TOP-UP SCENE BELOW HAS NOTHING TO MEASURE.
        // The top-up door exists to carry the difference between what the fee
        // pays a judge and what the floor says he must receive. The fee's own
        // floor is now the same ten dollars `DEFAULT_ARBITER_FLOOR` asks for,
        // so on a deal cut from this implementation that difference is nought
        // and `fundDispute` answers `TopUpNotNeeded` -- which is the correct
        // answer and makes the door's machinery unreachable.
        //
        // Raising the floor to $20 by the owner's own door restores a real
        // difference of $10 and leaves every scene below about what it was
        // written for: the pull, the reservation, the discount, the refund.
        // Nothing else in this file reads `getArbiterFloor`, so the raise
        // touches the top-up quote and nothing more.
        //
        // ⚠️ THE DOOR IS NOT DEAD, which is why it is reached this way rather
        // than deleted: the sixteen clones already on Base Sepolia take 3% of
        // the pot with no floor under it, and on those the difference is real
        // at the default floor.
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(20_000_000);
    }

    function testFundDisputePullsExactQuote() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));

        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        uint256 before_ = usdc.balanceOf(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        assertEq(before_ - usdc.balanceOf(client), need, "exactly the quoted amount is pulled");
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), need, "bounty recorded");
    }

    function testFundDisputeFromStrangerReverts() public {
        Agreement a = _disputedAgreement(100_000_000);
        vm.prank(address(0xBEEF));
        vm.expectRevert(ArbiterRegistryFacet.NotParty.selector);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
    }

    /// ⚠️ THIS WAS A PIN ON A DEFECT AND IS NOW A LOCK ON THE FIX. It was
    /// written on 24 September 2026 as
    /// `testAFrozenVerdictHoldsTheTopUpAYearLater` — green, recording that a
    /// freeze had NO deadline: a brake and a suspension let go by themselves
    /// after 72 hours, a frozen verdict never did, and the arbiter's top-up sits
    /// on the DIAMOND rather than inside the deal's escrow, so the only way out
    /// of it was a second press by the same hand.
    ///
    /// It went red on 25 September when the freeze got a clock — `[FAIL: next
    /// call did not revert as expected]`, on the `finalizeVerdict` below — which
    /// was the handshake it was written for. Rewritten here to the behaviour that
    /// replaced it, keeping the year: a year is not a boundary of anything in the
    /// code, it is simply longer than any deadline anyone would choose, so it is
    /// the honest place to ask "is there still a way out at all".
    ///
    /// The tight boundary lives in
    /// testTheFreezeLapsesAfterSeventyTwoHoursAndTheTopUpReachesTheArbiter and
    /// testTheFreezeStillHoldsOneSecondBeforeItsWindowRuns below; this one asks
    /// the blunt question the mainnet list asked.
    function testAFrozenVerdictNoLongerHoldsTheTopUpAYearLater() public {
        Agreement a = _disputedAgreement(100_000_000);

        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertGt(need, 0, "setup: this pot needs a top-up to reach the arbiter floor");
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();
        uint256 bounty = ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a));
        assertEq(bounty, need, "setup: the top-up is booked on the diamond");

        _claimByArbiter(a);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);

        _freezeAsAHandDidBeforeTheCut(a);
        vm.warp(vm.getBlockTimestamp() + 365 days);

        // 1. ⚠️ THE PARTIES' OWN TIMEOUT STILL REFUSES, AND NOT BECAUSE OF THE
        // FREEZE. `Agreement._verdictInFlight()` asks the diamond
        // `hasSubmittedVerdict` and knows nothing about `frozen`, so this door was
        // never the freeze's to open and is untouched by the clock. Asserted here
        // rather than deleted: the 17 September wording of D6 blamed the freeze
        // for this refusal, the mechanism turned out to be a different one, and a
        // test is the only place that can keep saying so.
        vm.prank(client);
        vm.expectRevert(Agreement.VerdictInFlight.selector);
        a.triggerArbiterTimeout();

        // 2. The way out that DOES open: execution, by anybody, with nobody's
        // second press.
        uint256 rewardBefore = ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr);
        vm.prank(address(0xBEEF));
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));

        // 3. So the top-up moved, and it moved to the arbiter who did the work.
        assertEq(
            ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)),
            0,
            "the top-up no longer sits on the diamond for ever"
        );
        assertGe(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr) - rewardBefore,
            bounty,
            "and a year later it reached the arbiter"
        );

        // 4. The flag still records that the press happened — the clock decides
        // whether it still stops anything, and the history is not rewritten.
        assertTrue(
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(address(a)).frozen,
            "the press is still on the record"
        );
    }

    // ============================================================
    //  D6 — THE FREEZE HAS A CLOCK (owner's decision, 24 September 2026)
    // ============================================================
    //
    // ⚠️ EVERY WARP BELOW IS MEASURED FROM `vm.getBlockTimestamp()` AND NEVER
    // FROM A CACHED `block.timestamp`. Under via_ir the compiler hoists
    // `block.timestamp` out of a frame, so a value read before the previous warp
    // is not the clock the diamond will see: the test would then be warping to a
    // moment it has already passed and asserting about a window it never entered.
    //
    // The number the scenes below are pinned against is FREEZE_WINDOW, a private
    // constant of the facet (72 hours). It is written out here on purpose rather
    // than read through a getter: the whole point of the fix was that
    // `ArbiterRegistryFacet` is a named Replace group in signed cut scripts and
    // must not gain an external function, so there IS nothing to read it through.
    // That makes these literals the human-fixed side of the seam — if the
    // constant moves, these go red, which is the correct direction.

    /// Set the scene D6 is about: a disputed deal, a top-up paid in by the client
    /// The base of this deal's `PendingVerdict` record. `pendingVerdicts` is
    /// field 6 of ArbiterRegistryStorage.Data; the offsets inside the record are
    /// pinned independently in test/Diamond.t.sol.
    function _verdictRecordBase(Agreement a) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(address(a), uint256(ArbiterRegistryStorage.POSITION) + 6)));
    }

    /// Puts a verdict into the state A HAND left behind: `frozen` set and
    /// `frozenAt` carrying the moment of the press.
    ///
    /// ⚠️ WHY A SLOT WRITE AND NOT A CALL (9 October 2026). `freezeVerdict` is
    /// gone, and `frozenAt` now has NO writer anywhere in the facet -- measured,
    /// not assumed. `raiseAppeal` still sets `frozen`, but it sets `appealed` in
    /// the same breath and `_freezeHolds` then answers from the APPEAL's clock
    /// (`appealDeadline`) rather than from FREEZE_WINDOW, so it cannot build the
    /// state these scenes are about at all.
    ///
    /// ⚠️ THE STATE IS REAL AND THAT IS THE WHOLE REASON THESE SCENES SURVIVE
    /// THE CUT. Verdicts a hand froze before 9 October are on chain with exactly
    /// these two fields set, unfinalized, and `FREEZE_WINDOW` plus `_freezeHolds`
    /// were deliberately KEPT for them: the clock is the only thing that ever
    /// lets them go now that `unfreezeVerdict` is gone too. Delete these scenes
    /// and nothing watches the only exit somebody's escrow has.
    ///
    /// ⚠️ THE OFFSETS ARE WITNESSED, NOT TRUSTED -- the same rig, and the same
    /// reason for it, as testAFreezeFromBeforeTheFieldExistedLapsesFromTheSubmission
    /// below: the flag word is read and OR-ed rather than overwritten, so a
    /// drifted offset cannot quietly clear a neighbour, and the getter is then
    /// asked whether both fields actually landed.
    function _freezeAsAHandDidBeforeTheCut(Agreement a) internal {
        uint256 base = _verdictRecordBase(a);
        bytes32 flagSlot  = bytes32(base + 2);
        bytes32 clockSlot = bytes32(base + 7);

        vm.store(address(diamond), flagSlot, vm.load(address(diamond), flagSlot) | bytes32(uint256(1)));
        vm.store(address(diamond), clockSlot, bytes32(vm.getBlockTimestamp()));

        ArbiterRegistryStorage.PendingVerdict memory v =
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(address(a));
        assertTrue(v.frozen, "the frozen offset missed - this helper is poking an unrelated slot");
        assertEq(v.frozenAt, vm.getBlockTimestamp(), "the frozenAt offset missed - likewise");
        assertFalse(v.finalized, "the write landed on a neighbour (finalized)");
        assertFalse(v.appealed, "the write landed on a neighbour (appealed)");
        assertGt(v.submittedAt, 0, "the record itself was not found");
    }

    /// Sets `overturned` the way a panel that voted to overturn would leave it.
    ///
    /// ⚠️ UNLIKE THE FREEZE ABOVE, THIS STATE IS REACHABLE BY A CALL, and the
    /// shortcut is taken for a stand reason rather than a protocol one: this
    /// bench mounts a hand-picked selector list that carries no appeal doors at
    /// all, and seating a bonded panel plus funding an appellant would move the
    /// deposit, the case bond and the bank through every balance identity this
    /// file asserts -- turning a scene about where a TOP-UP goes into a scene
    /// about appeal economics, which test/AppealEconomics.t.sol already is.
    ///
    /// What is being measured here is `finalizeVerdict`'s routing of the money on
    /// a verdict that did not stand, and that reads the bit and nothing about how
    /// the bit was set.
    function _markOverturnedAsThePanelWould(Agreement a) internal {
        bytes32 flagSlot = bytes32(_verdictRecordBase(a) + 2);
        // `overturned` is the THIRD bool of the packed word: frozen, finalized,
        // overturned.
        vm.store(address(diamond), flagSlot, vm.load(address(diamond), flagSlot) | bytes32(uint256(1) << 16));

        ArbiterRegistryStorage.PendingVerdict memory v =
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(address(a));
        assertTrue(v.overturned, "the overturned offset missed - this helper is poking an unrelated slot");
        assertFalse(v.finalized, "the write landed on a neighbour (finalized)");
        assertFalse(v.frozen, "the write landed on a neighbour (frozen)");
    }

    /// and booked on the DIAMOND, an arbiter's verdict, and then the owner's
    /// freeze. Returns the top-up so each scene can follow that exact money.
    function _frozenVerdictWithTopUp() internal returns (Agreement a, uint256 bounty) {
        a = _disputedAgreement(100_000_000);

        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertGt(need, 0, "setup: this pot needs a top-up to reach the arbiter floor");
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();
        bounty = ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a));
        assertEq(bounty, need, "setup: the top-up is booked on the diamond");

        _claimByArbiter(a);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);

        // ⚠️ THE PRESS IS A SLOT WRITE NOW — see _freezeAsAHandDidBeforeTheCut,
        // which also carries the witness that used to stand here.
        _freezeAsAHandDidBeforeTheCut(a);
    }

    /// ⚠️ THE DESIGNATED LOCK FOR D6, and the scene the whole item exists for:
    /// the owner froze a verdict and never came back, and seventy-two hours later
    /// the arbiter's top-up finds its way out WITHOUT a second press by anybody.
    ///
    /// "Where it went" is asserted all the way to the man's own balance and not
    /// merely to a credit line: a claimable that cannot be claimed would be the
    /// same dead end wearing a different name.
    ///
    /// Exactly `FREEZE_WINDOW`, not a second more — the boundary belongs to the
    /// lapse (`_freezeHolds` compares with `<`), and its other side is pinned by
    /// testTheFreezeStillHoldsOneSecondBeforeItsWindowRuns below.
    function testTheFreezeLapsesAfterSeventyTwoHoursAndTheTopUpReachesTheArbiter() public {
        (Agreement a, uint256 bounty) = _frozenVerdictWithTopUp();

        vm.warp(vm.getBlockTimestamp() + 72 hours);

        uint256 rewardBefore = ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr);
        // Anybody may press it — there is no privileged caller here, which is the
        // half that makes this a way out rather than a second lever.
        vm.prank(address(0xBEEF));
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));

        assertEq(
            ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)),
            0,
            "the top-up has left the holding pen on the diamond"
        );
        assertGe(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr) - rewardBefore,
            bounty,
            "and it was credited to the arbiter who did the work"
        );
        assertTrue(
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(address(a)).finalized,
            "the verdict stood, because nobody came back to overturn it"
        );

        // All the way to the money. This is "where exactly it went".
        uint256 owed = ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr);
        uint256 walletBefore = usdc.balanceOf(arbiterAddr);
        vm.prank(arbiterAddr);
        ArbiterVaultFacet(address(diamond)).withdrawArbiterReward();
        assertEq(
            usdc.balanceOf(arbiterAddr) - walletBefore,
            owed,
            "and the arbiter could take it out in USDC"
        );
    }

    /// ⚠️ WITHOUT THIS SCENE THE DEADLINE IS NOT PROVEN — only "it lets go
    /// eventually" is. A lapse that fired immediately would satisfy the scene
    /// above and destroy the lever the owner keeps.
    function testInsideTheFreezeWindowTheTopUpIsStillHeld() public {
        (Agreement a, uint256 bounty) = _frozenVerdictWithTopUp();

        vm.warp(vm.getBlockTimestamp() + 71 hours);

        vm.expectRevert(ArbiterRegistryFacet.VerdictFrozenError.selector);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));
        assertEq(
            ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)),
            bounty,
            "the top-up has not moved inside the window"
        );
    }

    /// The exact second the window ends, from the side that still holds. Together
    /// with the lapse scene this pins the boundary rather than the neighbourhood.
    function testTheFreezeStillHoldsOneSecondBeforeItsWindowRuns() public {
        (Agreement a, ) = _frozenVerdictWithTopUp();

        vm.warp(vm.getBlockTimestamp() + 72 hours - 1);

        vm.expectRevert(ArbiterRegistryFacet.VerdictFrozenError.selector);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));
    }

    // ⚠️ `testTheOwnersDecisionInsideTheWindowIsStillHis` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF. Its subject, in its own words, was that "the owner's own
    //   decision inside the window is still his": the clock insures against the one
    //   case he named -- nobody came back to decide -- and must not take the decision
    //   away from him when he DOES come back. He came back by pressing
    //   `overturnVerdict`, which also cleared `frozen` itself, so the clock was never
    //   consulted. With no hand there is nobody to come back, and nothing to keep the
    //   decision for.
    //   ⚠️ WHERE THE MONEY HALF STILL LIVES: that an overturned verdict routes the
    //   top-up back to the payer as a claimable and pays the arbiter nothing is
    //   asserted by testOverturnedVerdictRefundsBountyToPayer, in this file, which was
    //   rewritten rather than removed.
    //
    // ⚠️ `testTheOwnersUnfreezeInsideTheWindowOpensItAtOnce` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF -- `unfreezeVerdict` inside the window opening the way at
    //   once instead of waiting out a clock. There is nothing left to lift by hand:
    //   the only hand-pressed freeze is gone, and the freeze an APPEAL raises is
    //   cleared by `resolveAppeal`, which anybody may call once the window closes.
    //   A legacy freeze still on chain now leaves only by the clock, and THAT is what
    //   the surviving scenes in this section measure.
    //
    // ⚠️ `testARepressedFreezeGetsAFreshWindow` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF -- a SECOND press restarting the window.
    //   ⚠️ AND ITS DISAPPEARANCE IS A GOOD THING, WHICH IS WORTH WRITING DOWN RATHER
    //   THAN ONLY NOTING THE LOSS. This scene existed to say out loud what it called
    //   "the honest limit of D6": a hand that pressed freeze every three days could
    //   hold a verdict -- and somebody's escrow -- INDEFINITELY, and that was the
    //   lever working as designed rather than the clock failing. The press is gone, so
    //   the indefinite hold is gone with it. No verdict can be re-frozen by anybody,
    //   and every freeze still standing on chain has exactly one window left to run.
    //   There is therefore no fresh window to test, and nothing to guard against: the
    //   state the scene warned about can no longer be entered.
    //
    /// ⚠️ THE MIGRATION SEAM: a verdict frozen BEFORE `frozenAt` existed reads a
    /// zero there, and a zero must not mean "frozen for ever" — that would leave
    /// the defect alive for exactly the verdicts already caught by it.
    /// `_freezeHolds` falls back to `submittedAt`, the earliest moment the press
    /// can have happened.
    ///
    /// ⚠️ THE SLOT IS WITNESSED BEFORE IT IS USED, and the first attempt at this
    /// test is why the warning is here. It found the slot by recording what
    /// `freezeVerdict` writes and picking the one whose value equalled the press's
    /// timestamp — and under forge's default clock `block.timestamp` is 1, which is
    /// also the packed value of the word holding `frozen` alone. The search matched
    /// the flag instead of the clock, zeroed the flag, and the test's own setup
    /// assertion caught it. A marker written through the offset and read back
    /// through the real getter cannot go wrong that way: if the offset drifts, the
    /// witness below fails rather than some unrelated slot being poked.
    function testAFreezeFromBeforeTheFieldExistedLapsesFromTheSubmission() public {
        (Agreement a, uint256 bounty) = _frozenVerdictWithTopUp();

        // `pendingVerdicts` is field 6 of ArbiterRegistryStorage.Data, and
        // `frozenAt` is the eighth slot of the record — appended at the end,
        // one past `appealDeposit`. Both offsets are pinned independently in
        // test/Diamond.t.sol.
        bytes32 recordBase = keccak256(
            abi.encode(address(a), uint256(ArbiterRegistryStorage.POSITION) + 6)
        );
        bytes32 clockSlot = bytes32(uint256(recordBase) + 7);

        // The witness: a marker nobody else could have put there.
        vm.store(address(diamond), clockSlot, bytes32(uint256(0xC10C)));
        assertEq(
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(address(a)).frozenAt,
            0xC10C,
            "the frozenAt offset missed - this test would be poking an unrelated slot"
        );

        vm.store(address(diamond), clockSlot, bytes32(0));
        ArbiterRegistryStorage.PendingVerdict memory v0 =
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(address(a));
        assertTrue(v0.frozen, "setup: it still reads as frozen");
        assertEq(v0.frozenAt, 0, "setup: and as a press from before the field existed");

        // `submittedAt` is the fallback, and it is at or before the press — so the
        // window has already run by the time we are 72 hours past the submission.
        vm.warp(v0.submittedAt + 72 hours);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));
        assertEq(
            ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)),
            0,
            "a legacy freeze lapses too, measured from the submission"
        );
        assertGe(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr),
            bounty,
            "and the top-up reached the arbiter"
        );
    }

    function testFundDisputeTwiceReverts() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need * 2);
        vm.startPrank(client);
        usdc.approve(address(diamond), need * 2);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        vm.expectRevert(ArbiterRegistryFacet.BountyAlreadyFunded.selector);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();
    }

    /// On a large pot no top-up is needed — there is nothing to pay, and the
    /// function says so rather than silently accepting money.
    ///
    /// ⚠️ $420 → $700 ON 21 OCTOBER 2026, AND THE POT IS THE WHOLE OF THE FIX.
    /// Derived by hand, retired figure first so that the method can be checked:
    /// $420 was picked as $10 / 0.024, the rate 3% times the judge's share of
    /// 80%, and it stayed correct when the share rose to 90% --
    /// 420_000_000 x 3 / 100 = 12_600_000 of fee, x 9 / 10 = 11_340_000 to the
    /// judge, which clears the $10 default floor, so the quote was nought and
    /// the door answered `TopUpNotNeeded`.
    ///
    /// Two things moved underneath that. The judge takes the WHOLE fee, and
    /// `_disputedAgreement` raises the arbiter floor to $20 -- which it must,
    /// because at the default floor the fee's own ten dollar floor already
    /// meets it on every pot and the top-up door is unreachable. Against a $20
    /// floor a $420 pot is short: 12_600_000 of fee against 20_000_000 asked
    /// leaves 20_000_000 - 12_600_000 = 7_400_000 to find, so the quote is NOT
    /// nought, `fundDispute` goes on to pull money this scene never approved,
    /// and the refusal it was watching for never comes. (That is exactly how
    /// the scene failed: on the token's allowance, not on `TopUpNotNeeded` --
    /// which is the measurement that confirms the arithmetic above.)
    ///
    /// 3% reaches $20 at a pot of 20_000_000 x 100 / 3 = 666_666_666.67, so
    /// $700 clears it: 700_000_000 x 3 / 100 = 21_000_000, over the floor, and
    /// the quote is nought again for the reason the scene is named for -- the
    /// arbiter is paid enough by the deal itself.
    function testFundDisputeRevertsWhenTopUpIsZero() public {
        Agreement a = _disputedAgreement(700_000_000);
        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.TopUpNotNeeded.selector);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
    }

    /// After a claim the bait has already done its work: an arbiter took it on, so
    /// there is no point paying.
    function testFundDisputeAfterClaimReverts() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        _activateAndDispute(a);

        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.DisputeAlreadyClaimed.selector);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
    }

    /// No verdict happened, so the money goes back in full to whoever paid it in.
    function testBountyRefundedOnTimeoutWithoutVerdict() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        uint256 before_ = usdc.balanceOf(client);
        vm.prank(client);
        a.triggerArbiterTimeout();

        // Named as a sum of two refunds that are not the same money. `need` is
        // the top-up he put in to attract an arbiter, back because no arbiter
        // delivered; the door charge is what `raiseDispute` took from him,
        // back because no verdict was written. The escrow half, 50_000_000 of
        // the 100_000_000 pot, is subtracted on the left.
        // ⚠️ THE LEFT SIDE ALONE REPRODUCED THE RETIRED LITERAL, which is how
        // the method was checked: `need` was the whole of the right-hand side
        // and the measurement printed 10_000_000 for it. What is new is only
        // the second term.
        assertEq(usdc.balanceOf(client) - before_ - 50_000_000, need + DOOR_CHARGE_HOME, "bounty and door charge both came back on top of the split half");
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty cleared");
    }

    /// Refunded exactly once: a repeated clearDisputeClaim does not pay a second time.
    function testBountyRefundHappensOnlyOnce() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
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
        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(executor, need);
        vm.startPrank(executor);
        usdc.approve(address(diamond), need);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        a.respondToDispute();
        vm.stopPrank();

        usdc.setBlocked(executor, true);
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(client);
        a.triggerArbiterTimeout();

        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty left the dispute");
        assertEq(ArbiterVaultFacet(address(diamond)).getRefundableBounty(executor), need, "and became claimable instead");

        usdc.setBlocked(executor, false);
        uint256 before_ = usdc.balanceOf(executor);
        vm.prank(executor);
        ArbiterVaultFacet(address(diamond)).withdrawDisputeBounty();
        assertEq(usdc.balanceOf(executor) - before_, need, "payer got it once unblocked");
    }

    /// Nothing to withdraw is not a silent no-op but an explicit revert. The error is
    /// its own and not NothingToPush from withdrawTreasurySlice: both live in the
    /// relayer's decoder, the name reaches the user verbatim, and "push" in the
    /// message would speak of an action the person never performed.
    function testWithdrawDisputeBountyRevertsIfNothingOwed() public {
        vm.prank(executor);
        vm.expectRevert(ArbiterRegistryFacet.NoRefundableBounty.selector);
        ArbiterVaultFacet(address(diamond)).withdrawDisputeBounty();
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
        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(executor, need);
        vm.startPrank(executor);
        usdc.approve(address(diamond), need);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
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

        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty left the dispute");
        assertEq(ArbiterVaultFacet(address(diamond)).getRefundableBounty(executor), need, "and became claimable instead");
    }

    // -------- THE PAID CALL: THE PAYOUT --------

    /// A verdict happened, so the top-up goes to the arbiter rather than back to the
    /// payer. clearDisputeClaim (called from resolveDispute inside the same
    /// finalizeVerdict) sees disputeBounty already zeroed and stays silent.
    function testBountyGoesToArbiterOnVerdict() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();

        // ⚠️ THE ARBITER FLOOR ABOVE THE FEE, 21 OCTOBER 2026, for the reason
        // `_disputedAgreement` sets out at length: the fee's own floor and the
        // default arbiter floor are the same ten dollars, so on a deal cut from
        // this implementation there is nothing to top up and `fundDispute`
        // answers `TopUpNotNeeded` -- the correct answer, and one that makes
        // this scene's whole subject unreachable. This fixture is built by hand
        // rather than through `_disputedAgreement` (it has to claim the dispute
        // AFTER the top-up), so it raises the floor itself.
        //
        // What that leaves to find, by hand: the floor asks 20_000_000; the fee
        // on a $100 pot is max($10 floor, 100_000_000 x 3 / 100 = 3_000_000) =
        // 10_000_000 and the whole of it is the judge's; 20_000_000 -
        // 10_000_000 = 10_000_000 is the quote.
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(20_000_000);

        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertEq(need, 10_000_000, "setup: $20 asked less the $10 fee leaves $10 to find");
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        _claimByArbiter(a);
        _submitAndFinalize(a, true);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr) >= need, true, "arbiter got at least the bounty");
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty cleared after payout");
    }

    /// The verdict was overturned before finalisation — the top-up must not go to
    /// the arbiter, and it goes back to the payer through claimable
    /// (refundableBounty) rather than by a direct transfer: a hard transfer here
    /// could take the whole finalisation down.
    ///
    /// ⚠️ THE REASON GIVEN HERE NAMED A DESTINATION THAT IS NOT THE DESTINATION
    /// ANY MORE (21 October 2026). It read: "on an overturn 80% of the fee
    /// already goes entirely to the treasury (creditDisputeFee), and the top-up
    /// cannot be an exception". Both halves have moved. The treasury takes
    /// nothing out of arbitration at all, and the fee an overturned judge
    /// forfeits is the PANEL's -- the owner's decision of 20 October, measured
    /// in test/AppealEconomics.t.sol, where it is the pocket the panel divides.
    /// The conclusion the sentence was supporting is untouched: whatever the
    /// forfeited fee pays for, it is not the man whose verdict fell, and
    /// neither is the top-up.
    function testOverturnedVerdictRefundsBountyToPayer() public {
        Agreement a = Agreement(_createFundedAgreement(100_000_000));
        vm.prank(executor);
        a.activate();
        _armTheDoor(client, a);
        vm.prank(client);
        a.raiseDispute();

        // The arbiter floor above the fee, for the reason spelled out on
        // testBountyGoesToArbiterOnVerdict just above: 20_000_000 asked less
        // the 10_000_000 the fee pays the judge leaves 10_000_000 to find, and
        // without the raise there is no top-up here to refuse to pay him.
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(20_000_000);

        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertEq(need, 10_000_000, "setup: $20 asked less the $10 fee leaves $10 to find");
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        vm.stopPrank();

        _claimByArbiter(a);

        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);

        // ⚠️ THE VERDICT IS MARKED OVERTURNED THE WAY A PANEL LEAVES IT (9 October
        // 2026). This line was the owner's `overturnVerdict`; the door is gone and
        // the panel is the only writer left. See
        // _markOverturnedAsThePanelWould for why the bit is set directly on this
        // particular bench rather than by seating one.
        _markOverturnedAsThePanelWould(a);

        vm.warp(block.timestamp + 72 hours + 1); // FINALIZE_DELAY
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(address(a));

        assertEq(ArbiterVaultFacet(address(diamond)).getRefundableBounty(client), need, "bounty went to the payer as claimable");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arbiterAddr), 0, "overturned arbiter got nothing, including the bounty");
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty left the dispute either way");
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
            .sig(ArbiterVaultFacet.getRewardPerDispute.selector)
            .checked_write(5_000_000);

        usdc.mint(owner, 5_000_000);
        vm.startPrank(owner);
        usdc.approve(address(diamond), 5_000_000);
        ArbiterVaultFacet(address(diamond)).fundVault(5_000_000);
        vm.stopPrank();

        uint256 vaultBefore = ArbiterVaultFacet(address(diamond)).getVaultBalance();
        _submitAndFinalize(a, true);
        assertEq(ArbiterVaultFacet(address(diamond)).getVaultBalance(), vaultBefore, "vault untouched by a resolved dispute");
    }

    /// setRewardPerDispute no longer writes anything — it reverts unconditionally,
    /// whoever the caller is. onlyOwner no longer guards the entrance, because there
    /// is no entrance left to guard: it was replaced by error RewardPathRetired and a
    /// pure function.
    function testSetRewardPerDisputeAlwaysReverts() public {
        vm.expectRevert(ArbiterRegistryFacet.RewardPathRetired.selector);
        ArbiterVaultFacet(address(diamond)).setRewardPerDispute(5_000_000);

        vm.prank(address(0xBEEF));
        vm.expectRevert(ArbiterRegistryFacet.RewardPathRetired.selector);
        ArbiterVaultFacet(address(diamond)).setRewardPerDispute(1);
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

        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertGt(need, 0, "setup: the pot must be small enough to need a top-up");
        usdc.mint(client, need);
        vm.startPrank(client);
        usdc.approve(address(diamond), need);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
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

        // The whole pot to the client, the top-up on top of it to whoever paid
        // it, and his door charge on top of that because no verdict was written.
        // Three named things: the pot is what the claimed-timeout branch
        // decides, `need` is money he put in to attract a judge, and the charge
        // is what the door took to let him in.
        // ⚠️ THE FIRST TWO REPRODUCED THE RETIRED EXPRESSION EXACTLY -- it was
        // `100_000_000 + need` and the run printed 110_000_000 for it, so the
        // measured `need` is 10_000_000 and the third term is the only addition.
        assertEq(usdc.balanceOf(client) - cBefore, 100_000_000 + need + DOOR_CHARGE_HOME, "whole pot, the refunded top-up, and his door charge");
        assertEq(usdc.balanceOf(executor) - eBefore, 0, "the claimed branch does not split anything");
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), 0, "bounty cleared");
        assertEq(ArbiterVaultFacet(address(diamond)).getRefundableBounty(client), 0, "the push refund succeeded, nothing left claimable");

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
        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.prank(client);
        usdc.approve(address(diamond), need);

        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.DisputeWindowPassed.selector);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));

        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), 0, "nothing was taken");
    }

    /// The boundary is exactly the same as for claimDispute: the last second of the
    /// window still accepts both. Checked in one test so that the gates cannot drift
    /// apart by one — a top-up is possible exactly while the dispute can still be
    /// claimed.
    function testFundDisputeOnTheLastSecondMatchesClaimDispute() public {
        Agreement a = _disputedAgreement(100_000_000);
        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(client, need);
        vm.prank(client);
        usdc.approve(address(diamond), need);

        // vm.warp onto the exact boundary: block.timestamp == disputedAt + DISPUTE_WINDOW.
        vm.warp(a.disputedAt() + a.DISPUTE_WINDOW());

        vm.prank(client);
        ArbiterVaultFacet(address(diamond)).fundDispute(address(a));
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), need, "top-up accepted on the last second");

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
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
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
        // The peer hands the work in before the dispute: this fixture's scenes are
        // about who PAYS through the forwarder, and an unclaimed timeout without a
        // hand-in would hand the whole pot to the payer and hide the top-up refund
        // it is actually measuring.
        vm.prank(peer);
        a.markDone();
        _armTheDoor(payer, a);
        vm.prank(payer);
        a.raiseDispute();

        // ⚠️ THE ARBITER FLOOR ABOVE THE FEE, 21 OCTOBER 2026, and the same
        // raise `_disputedAgreement` makes for the same reason: the fee's own
        // ten dollar floor already meets the default arbiter floor, so the
        // quote is nought on every pot and `fundDispute` -- which is the
        // subject of both forwarder scenes built on this fixture -- answers
        // `TopUpNotNeeded` before it can be measured at all.
        //
        // By hand, what the raise leaves to find on this fixture's $100 pot:
        // the floor asks 20_000_000; the fee is max($10 floor,
        // 100_000_000 x 3 / 100 = 3_000_000) = 10_000_000, the judge's whole;
        // 20_000_000 - 10_000_000 = 10_000_000 is the quote.
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(20_000_000);
    }

    function _signFwd(uint256 pk, MinimalForwarder.ForwardRequest memory req)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            FWD_TYPEHASH, req.from, req.to, req.value, req.gas, req.nonce, req.deadline, keccak256(req.data)
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
            deadline: type(uint48).max,   // not this file's subject; the window is locked in ForwardRequestDeadline.t.sol
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

        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        assertGt(need, 0, "setup: the pot must need a top-up");
        usdc.mint(payer, need);
        vm.prank(payer);
        usdc.approve(address(diamond), need);

        uint256 payerBefore = usdc.balanceOf(payer);

        (bool ok, bytes memory retdata) = _relayToDiamond(
            PAYER_PK,
            abi.encodeWithSelector(ArbiterVaultFacet.fundDispute.selector, address(a))
        );
        assertTrue(ok, string.concat("forwarded fundDispute() failed: ", vm.toString(retdata)));

        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), need, "bounty recorded");
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

        // Two refunds, named apart. `need` is the top-up the HUMAN paid through
        // the forwarder, back because no arbiter delivered -- which is the
        // whole subject of the scene, since a forwarder recorded as the payer
        // would have taken it instead. The door charge is what `raiseDispute`
        // took from him in the fixture, back because no verdict was written;
        // it is his own money and is not evidence about who the payer is.
        // ⚠️ `need` ALONE WAS THE RETIRED EXPRESSION, so the second term is
        // the only addition here.
        assertEq(
            usdc.balanceOf(payer) - beforeTimeout - 50_000_000,
            need + DOOR_CHARGE_HOME,
            "the refund went to the human payer on top of his split half, and his door charge with it"
        );
        assertEq(usdc.balanceOf(address(relayForwarder)), 0, "the forwarder got nothing back either");
    }

    /// Negative control: without it the test above would pass in a world where
    /// _msgSender() returns anything at all, as long as it happens to equal a party.
    /// A stranger signing through the same forwarder must get NotParty.
    function testFundDisputeThroughForwarderFromStrangerIsRejected() public {
        (Agreement a, , ) = _forwardedDispute(100_000_000);

        address outsider = vm.addr(OUTSIDER_PK);
        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(outsider, need);
        vm.prank(outsider);
        usdc.approve(address(diamond), need);

        (bool ok, bytes memory retdata) = _relayToDiamond(
            OUTSIDER_PK,
            abi.encodeWithSelector(ArbiterVaultFacet.fundDispute.selector, address(a))
        );

        assertFalse(ok, "the diamond accepted a forwarded top-up from a non-party");
        assertEq(bytes4(retdata), ArbiterRegistryFacet.NotParty.selector, "wrong revert reason");
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeBounty(address(a)), 0, "nothing was taken");
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

        uint256 need = ArbiterVaultFacet(address(diamond)).quoteDisputeTopUp(address(a));
        usdc.mint(peer, need);
        vm.startPrank(peer);
        usdc.approve(address(diamond), need);
        a.respondToDispute();
        vm.stopPrank();

        (bool funded, bytes memory fundRet) = _relayToDiamond(
            PEER_PK,
            abi.encodeWithSelector(ArbiterVaultFacet.fundDispute.selector, address(a))
        );
        assertTrue(funded, string.concat("setup: forwarded fundDispute failed: ", vm.toString(fundRet)));

        // Block the payer in USDC — the soft refund inside clearDisputeClaim will not
        // go through and will settle into refundableBounty.
        usdc.setBlocked(peer, true);
        vm.warp(block.timestamp + a.DISPUTE_WINDOW() + 1);

        vm.prank(payer);
        a.triggerArbiterTimeout();
        usdc.setBlocked(peer, false);

        uint256 owed = ArbiterVaultFacet(address(diamond)).getRefundableBounty(peer);
        assertEq(owed, need, "the failed push must land on the human's claimable balance");

        uint256 before_ = usdc.balanceOf(peer);
        (bool ok, bytes memory retdata) = _relayToDiamond(
            PEER_PK,
            abi.encodeWithSelector(ArbiterVaultFacet.withdrawDisputeBounty.selector)
        );
        assertTrue(ok, string.concat("forwarded withdrawDisputeBounty() failed: ", vm.toString(retdata)));

        assertEq(usdc.balanceOf(peer) - before_, owed, "the human got his top-up back");
        assertEq(ArbiterVaultFacet(address(diamond)).getRefundableBounty(peer), 0, "claimable cleared");
        assertEq(usdc.balanceOf(address(relayForwarder)), 0, "the forwarder must never receive the refund");
    }

    /// The bond behind a hand-given seat (8 September 2026).
    ///
    /// `addArbiter` seats and takes no money, and since the bond gate landed a
    /// seated arbiter with a zero bond is refused by every arbiter door with
    /// `BondNotPosted`. The real door is `ArbiterApplicationsFacet.postArbiterBond`;
    /// this rig does not mount that facet, so the field is written directly —
    /// the same device this file already uses to seat.
    ///
    /// Slot 12 of the arbiter namespace is `arbiterBond`, pinned by
    /// test/StorageLayout.t.sol. The value is the real bond, 50 USDC at six
    /// decimals.
    ///
    /// ⚠️ NO USDC MOVES. That is deliberate and safe HERE only because nothing
    /// in this file refunds or forfeits a bond; a rig that does either must
    /// move real money instead, or the diamond pays out what it never took.
    /// ⚠️ THE ENTRANCE COSTS TEN DOLLARS AGAIN SINCE 8 NOVEMBER 2026, AND THIS
    /// HELPER STILL WRITES NO BOND. The entry bond is taken by the seating door
    /// itself, inside the same transaction as the seat, out of the man's own
    /// wallet — never by hand into `arbiterBond` from here. What this leaves him
    /// with is what a seated arbiter still needs on top: money and an allowance
    /// for the bond each CASE asks for, inside `claimDispute`. Two different
    /// sums at two different moments, and the name is kept because every scene
    /// in this file calls it.
    function _bondSeat(address who) internal {
        usdc.mint(who, 1_000_000_000);
        vm.prank(who);
        usdc.approve(address(diamond), type(uint256).max);
    }

}
