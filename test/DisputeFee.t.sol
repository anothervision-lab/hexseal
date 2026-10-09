// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// DisputeFee test suite.
// The fee can no longer be zeroed through the region (regionFee is a dead
// field); the price is now set by feeBps and feeFloor. feeFloor does not accept
// a zero from its setter, so the only remaining way to try to make a deal free
// is setFeeBps(0), and even then quote() returns the floor. This file pins that
// invariant (testDeployAgreementNeverFree), not the old region gate.

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

contract MockUSDCDF {
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

contract DisputeFeeTest is Test {
    DiamondProxy diamond;
    MockUSDCDF   usdc;

    address owner;
    address client;
    address executor;
    address feeRecipient;

    uint256 constant CLIENT_USDC = 1_000_000_000;

    // ============================================================
    //  SETUP
    // ============================================================
    // Copied from Extras and pared down: RegistryFacet and FactoryFacet
    // (deployAgreement — creates the agreement the tests below need;
    // deployAndFund — its direct counterpart, with an unconditional transfer of
    // both the fee and the deal amount; getFeeRecipient — to check where the
    // treasury's share went) are what this file needs. setRegionFee is mounted,
    // but with the move to the percentage formula nobody calls it any more — it
    // is left as is, and removing the selector is a separate piece of work.
    // ArbiterRegistryFacet (creditDisputeFee/getArbiterReward/getTreasurySlice/
    // withdrawTreasurySlice) is here to take in and split the dispute fee.
    // DiamondCut/Loupe and OwnershipFacet are deliberately not mounted, because
    // no test here calls them.

    function setUp() public {
        owner        = address(this);
        client       = address(0x1);
        executor     = address(0x2);
        feeRecipient = address(0x4);

        usdc = new MockUSDCDF();
        usdc.mint(client, CLIENT_USDC);

        RegistryFacet registryFacet = new RegistryFacet();
        FactoryFacet  factoryFacet  = new FactoryFacet();
        ArbiterRegistryFacet arbiterFacet = new ArbiterRegistryFacet();
        ArbiterVaultFacet arbiterFacetVault = new ArbiterVaultFacet();

        // updateStatus is mounted for the sake of Agreement.raiseDispute()'s
        // _updateRegistry(): without it the call is silently swallowed by the
        // try/catch inside Agreement (which emits RegistrySyncFailed) and
        // activePartyPairs stays stuck on ACTIVE — a second agreement between the
        // same client/executor would then hit ActiveDealAlreadyExists even though
        // the first one is already in dispute.
        bytes4[] memory regSels = new bytes4[](6);
        regSels[0] = RegistryFacet.initRegistry.selector;
        regSels[1] = RegistryFacet.register.selector;
        regSels[2] = RegistryFacet.hasActivePair.selector;
        regSels[3] = RegistryFacet.updateStatus.selector;
        // Appended 18 September 2026: a direct hire is an OFFER, so the
        // factory registers it through registerOffer, and the clone
        // announces the acceptance. Without both mounted this rig's
        // deployAndFund reverts with "function not found".
        regSels[4] = RegistryFacet.registerOffer.selector;
        regSels[5] = RegistryFacet.notifyOfferAccepted.selector;

        bytes4[] memory facSels = new bytes4[](7);
        facSels[0] = FactoryFacet.initFactory.selector;
        facSels[1] = FactoryFacet.deployAgreement.selector;
        facSels[2] = FactoryFacet.setRegionFee.selector;
        facSels[3] = FactoryFacet.deployAndFund.selector;
        facSels[4] = FactoryFacet.getFeeRecipient.selector;
        facSels[5] = FactoryFacet.setFeeBps.selector;
        facSels[6] = FactoryFacet.getFeeBps.selector;

        // ArbiterRegistryFacet: beyond taking in and paying out the fee
        // (creditDisputeFee/getArbiterReward/getTreasurySlice/
        // withdrawTreasurySlice), the commit-reveal claim path is mounted too —
        // submitVerdict/overturnVerdict/withdrawArbiterReward. A review required a
        // real claim on the dispute instead of passing arbiter_ as an argument (no
        // such argument exists in production, see creditDisputeFee), so the tests
        // now drive the agreement to DISPUTED and genuinely claim it as arbiter.
        bytes4[] memory arbSels = new bytes4[](4);
        arbSels[0] = ArbiterRegistryFacet.addArbiter.selector;
        arbSels[1] = ArbiterRegistryFacet.commitDisputeClaim.selector;
        arbSels[2] = ArbiterRegistryFacet.claimDispute.selector;
        arbSels[3] = ArbiterRegistryFacet.submitVerdict.selector;
        bytes4[] memory arbSelsVault = new bytes4[](6);
        arbSelsVault[0] = ArbiterVaultFacet.creditDisputeFee.selector;
        arbSelsVault[1] = ArbiterVaultFacet.getTreasurySlice.selector;
        arbSelsVault[2] = ArbiterVaultFacet.withdrawTreasurySlice.selector;
        arbSelsVault[3] = ArbiterVaultFacet.isRegisteredArbiter.selector;
        arbSelsVault[4] = ArbiterVaultFacet.withdrawArbiterReward.selector;
        // Since 17 September 2026 an overturned arbiter's share lands in the
        // bank, and the scene that says so has to be able to read it.
        arbSelsVault[5] = ArbiterVaultFacet.getVaultBalance.selector;

        // These readers live in ArbiterAccountabilityFacet, so that is the
        // facet they have to be mounted on. Leaving them in the list above
        // would route them to a facet that does not implement them — the
        // call arrives and reverts.
        bytes4[] memory accSels = new bytes4[](1);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterReward.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](5);
        cut[0] = IDiamondCut.FacetCut(address(registryFacet), IDiamondCut.FacetCutAction.Add, regSels);
        cut[1] = IDiamondCut.FacetCut(address(factoryFacet),  IDiamondCut.FacetCutAction.Add, facSels);
        cut[2] = IDiamondCut.FacetCut(address(arbiterFacet),  IDiamondCut.FacetCutAction.Add, arbSels);
        cut[3] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()), IDiamondCut.FacetCutAction.Add, accSels
        );
        cut[4] = IDiamondCut.FacetCut(address(arbiterFacetVault),  IDiamondCut.FacetCutAction.Add, arbSelsVault);

        diamond = new DiamondProxy(owner, cut, address(0), "");

        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );
    }

    // ============================================================
    //  FEE CAN NEVER BE ZERO
    // ============================================================

    /// The invariant survived the change of model: the fee cannot be zeroed. It
    /// used to be zeroed through setRegionFee(region, 0) and caught by the ZeroFee
    /// gate; now the price comes from feeBps and feeFloor, the floor's setter does
    /// not accept a zero, and a zero rate simply yields the floor.
    /// Measured on deployAndFund: direct hiring goes only there now —
    /// deployAgreement is closed to everyone but the diamond itself and takes no
    /// fee at all (the board has been holding it since the posting).
    function testDirectHireNeverFree() public {
        vm.prank(owner);
        FactoryFacet(address(diamond)).setFeeBps(0);

        uint256 before = usdc.balanceOf(feeRecipient);

        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        FactoryFacet(address(diamond)).deployAndFund(
            client, executor, 100_000_000, 7, "terms", 0
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(feeRecipient), before + 1_000_000, "floor charged even at zero bps");
    }

    /// The ordinary deployAgreement path with a normal (non-zero) fee — creating a
    /// deal does not break. Called by the diamond: no other caller is admitted.
    function testDeployAgreementWorksWithNonZeroFee() public {
        vm.prank(address(diamond));
        address agreement = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), 100_000_000, 7, "terms", 0
        );
        assertTrue(agreement != address(0), "deal creation broke");
    }

    // ============================================================
    //  DEPLOY AND FUND: HAPPY PATH
    // ============================================================

    /// The only test of the ordinary deployAndFund path. It differs from
    /// deployAgreement precisely around the fee: deployAgreement transfers no fee
    /// at all (the board settles it a few lines after the call returns), while
    /// deployAndFund transfers it unconditionally and then moves the deal amount
    /// as well — before this test nothing asserted how much deployAndFund charges,
    /// and nothing walked its happy path.
    function testDeployAndFundChargesPercentageAndFundsTheDeal() public {
        uint256 amount = 100_000_000;      // $100
        uint256 expectedFee = 5_000_000;   // 5%

        uint256 before = usdc.balanceOf(feeRecipient);

        vm.startPrank(client);
        usdc.approve(address(diamond), amount + expectedFee);
        address agreement = FactoryFacet(address(diamond)).deployAndFund(
            client, executor, amount, 7, "terms", 0
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(feeRecipient) - before, expectedFee, "fee charged at 5%");
        assertEq(usdc.balanceOf(agreement), amount, "deal amount funded into the agreement");
    }

    // ============================================================
    //  DISPUTE FEE: ACCEPT + SPLIT 80/20
    // ============================================================

    /// Only deploys through the factory, does not fund. The old name
    /// (_createFundedAgreement) was a lie — there was never any funding inside.
    function _createAgreement() internal returns (address) {
        vm.prank(client);
        usdc.approve(address(diamond), type(uint256).max);
        // Only the diamond may open this door now, which is what a board does
        // from inside acceptApplicant/acceptRequest.
        vm.prank(address(diamond));
        address a = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), 100_000_000, 7, "terms", 0
        );
        return a;
    }

    /// Drives an agreement to DISPUTED, genuinely claims it as arbiter through
    /// commit-reveal AND submits a verdict — exactly what in production writes
    /// pendingVerdicts[agreement].arbiter (submitVerdict requires caller ==
    /// disputeClaims[agreement]). creditDisputeFee no longer takes the arbiter as
    /// an argument (see the comment above the function in the source:
    /// Agreement.arbiter is always either 0 or the diamond itself, never a
    /// person), so without a real claim and verdict the mutation "substitute
    /// address(this) for the arbiter" would pass this suite unnoticed. clientWins
    /// is always true — the verdict itself takes part in no test here
    /// (finalizeVerdict is never called); all that matters is that
    /// pendingVerdicts[agreement].arbiter == arb.
    function _disputeAndClaim(address agreement, address arb) internal {
        vm.prank(client);
        usdc.approve(agreement, type(uint256).max);
        vm.prank(client);
        Agreement(agreement).fund();

        vm.prank(executor);
        Agreement(agreement).activate();

        vm.prank(client);
        Agreement(agreement).raiseDispute();

        if (!ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(arb)) {
            ArbiterRegistryFacet(address(diamond)).addArbiter(arb);
            _bondSeat(arb);
        }

        bytes32 salt       = keccak256(abi.encodePacked("salt", agreement, arb, block.number));
        bytes32 commitment = keccak256(abi.encodePacked(agreement, arb, salt));
        vm.prank(arb);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arb);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agreement, salt, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );

        vm.prank(arb);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreement, true);
    }

    /// Only a registered agreement can credit the fee. Otherwise anyone off the
    /// street could write themselves a reward with a single call.
    function testCreditDisputeFeeRejectsStranger() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(ArbiterRegistryFacet.NotRegisteredAgreement.selector);
        ArbiterVaultFacet(address(diamond)).creditDisputeFee(6_000_000);
    }

    /// Nobody carried the dispute through to a verdict — there is nobody to credit,
    /// so it reverts rather than quietly losing money on the address(0) counter.
    function testCreditDisputeFeeRejectsWhenNoVerdictSubmitted() public {
        address agreement = _createAgreement();
        usdc.mint(agreement, 6_000_000);
        vm.startPrank(agreement);
        usdc.transfer(address(diamond), 6_000_000);
        vm.expectRevert(ArbiterRegistryFacet.NoVerdictSubmitted.selector);
        ArbiterVaultFacet(address(diamond)).creditDisputeFee(6_000_000);
        vm.stopPrank();
    }

    /// A zero amount reverts rather than crediting zeroes to both sides. It is
    /// checked before the arbiter lookup, so it needs no real claim.
    function testCreditDisputeFeeRejectsZeroAmount() public {
        address agreement = _createAgreement();
        vm.prank(agreement);
        vm.expectRevert(ArbiterRegistryFacet.ZeroAmount.selector);
        ArbiterVaultFacet(address(diamond)).creditDisputeFee(0);
    }

    /// The 80/20 split and both counters — the arbiter really claimed the dispute,
    /// and their address is passed nowhere as an argument.
    function testCreditDisputeFeeSplitsNinetyTen() public {
        address agreement = _createAgreement();
        address arb = address(0xA1);
        _disputeAndClaim(agreement, arb);

        // The agreement transfers the fee to the diamond and then asks for it to be
        // credited — the same way resolveDispute will do it.
        usdc.mint(agreement, 6_000_000);
        vm.startPrank(agreement);
        usdc.transfer(address(diamond), 6_000_000);
        ArbiterVaultFacet(address(diamond)).creditDisputeFee(6_000_000);
        vm.stopPrank();

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arb), 5_400_000, "arbiter 90%");
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(),        600_000, "treasury 10%");
    }

    /// The treasury's share is computed by subtraction, so no unit is lost on a
    /// non-round amount. 1_000_003 * 9000 / 10000 = 900_002 (floor), remainder
    /// 200_001.
    function testCreditDisputeFeeLosesNoUnitOnOddAmount() public {
        address agreement = _createAgreement();
        address arb = address(0xA1);
        _disputeAndClaim(agreement, arb);

        usdc.mint(agreement, 1_000_003);
        vm.startPrank(agreement);
        usdc.transfer(address(diamond), 1_000_003);
        ArbiterVaultFacet(address(diamond)).creditDisputeFee(1_000_003);
        vm.stopPrank();

        uint256 toArb = ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arb);
        uint256 toTre = ArbiterVaultFacet(address(diamond)).getTreasurySlice();
        assertEq(toArb, 900_002, "arbiter share floors");
        assertEq(toArb + toTre, 1_000_003, "parts must sum to the whole");
    }

    /// Two credits in a row (different agreements, the same arbiter, different
    /// amounts) — both counters must ADD UP rather than be overwritten. A review
    /// replaced += with = on both lines and got all 380 tests green; this test is
    /// the one that has to catch exactly that.
    function testCreditDisputeFeeAccumulatesAcrossMultipleCredits() public {
        address arb = address(0xA1);

        address agreement1 = _createAgreement();
        _disputeAndClaim(agreement1, arb);
        usdc.mint(agreement1, 6_000_000);
        vm.startPrank(agreement1);
        usdc.transfer(address(diamond), 6_000_000);
        ArbiterVaultFacet(address(diamond)).creditDisputeFee(6_000_000);
        vm.stopPrank();

        address agreement2 = _createAgreement();
        _disputeAndClaim(agreement2, arb);
        usdc.mint(agreement2, 1_000_003);
        vm.startPrank(agreement2);
        usdc.transfer(address(diamond), 1_000_003);
        ArbiterVaultFacet(address(diamond)).creditDisputeFee(1_000_003);
        vm.stopPrank();

        // 6_000_000 -> 5_400_000/600_000; 1_000_003 -> 900_002/100_001.
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arb), 5_400_000 + 900_002, "arbiter reward must accumulate");
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(),        600_000 + 100_001, "treasury slice must accumulate");
    }

    // ⚠️ `testCreditDisputeFeeOverturnedSendsTheForfeitedShareToTheBankNotTheTreasury` IS GONE (9 October 2026).
    //   STATE UNREACHABLE BY CONSTRUCTION. The scene credited the dispute fee on a
    //   verdict the owner's hand had overturned with NOTHING ELSE in the picture --
    //   its own docstring said so: "With no appeal behind the overturn there is
    //   nothing to pay back, so the whole 90% lands in the bank."
    //   ⚠️ WHY NOT SIMPLY MOUNT A PANEL AND RECOMPUTE THE SUMS. Because the scene's
    //   distinguishing condition was "AN OVERTURN WITH NO APPEAL BEHIND IT", and that
    //   state is now unreachable BY CONSTRUCTION rather than merely hard to build:
    //   `v.overturned` is written in exactly one place, inside `resolveAppeal`, which
    //   reverts `NoAppeal` unless `v.appealed` is set -- and `overturn` itself is
    //   `panelFormed && votesOverturn > votesUphold`, so an overturn implies an appeal
    //   AND a panel that read it. Every overturn therefore arrives with a deposit
    //   already refunded out of the case bond or the bank, and the forfeited fee share
    //   repays THAT first. Putting a panel in would not restore this scene; it would
    //   replace it with a different one that already exists.
    //   ⚠️ WHAT IT ASSERTED AND WHERE EACH PART STILL LIVES, checked rather than
    //   assumed, all in test/AppealEconomics.t.sol's
    //   test_OverturnedTheCaseBondCoversTheRefundToTheUnit:
    //     * "the overturned arbiter is paid nothing" -- asserted there verbatim;
    //     * "the treasury keeps its 10% and no more" -- asserted there as $30 of $300;
    //     * "the forfeited 90% goes to the arbiter bank" IN FULL -- this is the part
    //       that is gone, and it is gone because it is no longer true of any reachable
    //       state: the share repays the bond first and the bank takes the remainder.
    //
    /// End to end: a real (non-diamond) arbiter can actually take the credited
    /// reward through withdrawArbiterReward(), and the USDC land on their balance.
    /// Before this test withdrawArbiterReward() was never called in the suite —
    /// and that was the gap through which the critical bug "the arbiter is the
    /// diamond itself" would have passed unnoticed: the event and the counters
    /// would look healthy, and there would be nobody to collect what accumulated.
    function testWithdrawArbiterRewardActuallyPaysTheRealArbiter() public {
        address agreement = _createAgreement();
        address arb = address(0xA1);
        _disputeAndClaim(agreement, arb);

        usdc.mint(agreement, 6_000_000);
        vm.startPrank(agreement);
        usdc.transfer(address(diamond), 6_000_000);
        ArbiterVaultFacet(address(diamond)).creditDisputeFee(6_000_000);
        vm.stopPrank();

        uint256 before = usdc.balanceOf(arb);
        vm.prank(arb);
        ArbiterVaultFacet(address(diamond)).withdrawArbiterReward();

        assertEq(usdc.balanceOf(arb) - before, 5_400_000, "reward must actually reach the arbiter's wallet");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterReward(arb), 0, "counter must be cleared");
    }

    /// Paying out the treasury's share is open to anyone: the money goes only to
    /// feeRecipient anyway, so the right to call decides nothing, and being open
    /// means the payout does not depend on the owner remembering it.
    function testAnyoneCanPushTheTreasurySlice() public {
        address agreement = _createAgreement();
        address arb = address(0xA1);
        _disputeAndClaim(agreement, arb);

        usdc.mint(agreement, 6_000_000);
        vm.startPrank(agreement);
        usdc.transfer(address(diamond), 6_000_000);
        ArbiterVaultFacet(address(diamond)).creditDisputeFee(6_000_000);
        vm.stopPrank();

        address recipient = FactoryFacet(address(diamond)).getFeeRecipient();
        uint256 before = usdc.balanceOf(recipient);

        vm.prank(address(0xBEEF));
        ArbiterVaultFacet(address(diamond)).withdrawTreasurySlice();

        assertEq(usdc.balanceOf(recipient) - before, 600_000, "slice must reach the fee recipient");
        assertEq(ArbiterVaultFacet(address(diamond)).getTreasurySlice(), 0, "counter must be cleared");
    }

    /// Nothing to push — a revert rather than a transfer of zero.
    function testPushTreasurySliceRevertsWhenEmpty() public {
        vm.expectRevert(ArbiterRegistryFacet.NothingToPush.selector);
        ArbiterVaultFacet(address(diamond)).withdrawTreasurySlice();
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
    /// ⚠️ NO SEAT BOND SINCE 22 SEPTEMBER 2026, so nothing is written into
    /// `arbiterBond` by hand any more. What a seated arbiter needs is money and
    /// an allowance: the bond is posted PER CASE, inside `claimDispute`. The
    /// name is kept because every scene in this file calls it.
    function _bondSeat(address who) internal {
        usdc.mint(who, 1_000_000_000);
        vm.prank(who);
        usdc.approve(address(diamond), type(uint256).max);
    }

}
