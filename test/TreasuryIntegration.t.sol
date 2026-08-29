// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// An integration test of Treasury against a REAL diamond (not the mock diamond
// the rest of the ladder was exercised on).
//
// What is checked here is what a mock cannot check:
//   1) the deal-creation fee really does reach the treasury through a live
//      FactoryFacet.deployAgreement — without a single change in FactoryFacet;
//   2) the treasury can fill a real arbiter vault (ArbiterRegistryFacet)
//      through fundVault(), and not just a mock value set by hand;
//   3) putting the treasury in place with setFeeRecipient does not break the
//      old deal-creation path — the factory and the escrow do not see a
//      treasury at all, to them it is just an address.
//
// setUp is copied from Extras (the same set of mounted facets and the same
// MockUSDCE) and extended with ReputationFacet, which Extras does not mount.
// It is here to parallel the production configuration (DeployFull mounts it)
// and to leave room for future tests in this file — NOT because the present
// three tests fail without it (checked: they do not; the details sit at the
// mounting of repSels below).
import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/Agreement.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/Treasury.sol";

// ---------- MOCK USDC (a verbatim copy of the one in Extras) ----------

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

contract TreasuryIntegrationTest is Test {
    DiamondProxy diamond;
    MockUSDCE    usdc;

    address owner;
    address client;
    address executor;
    address arbiter;
    address feeRecipient;

    /// The foundation address for these tests — the treasury does not know, and
    /// must not know, what stands behind it (see the Treasury.foundation
    /// docstring).
    address constant FOUNDATION = address(0xF00D);

    uint256 constant CLIENT_USDC   = 1_000_000_000;
    uint256 constant EXECUTOR_USDC =   200_000_000;

    uint8   constant REGION     = 0; // CIS — the region no longer sets the fee; quote() does
    uint256 constant JOB_AMOUNT = 100_000_000;
    uint256 constant DEADLINE   = 7;
    string constant TERMS = "Standard work terms";

    // ============================================================
    //  SETUP — copied from Extras, extended with ReputationFacet
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

        // ReputationFacet selectors — added on top of what Extras mounts, where
        // this facet is not mounted at all. HONESTLY: the three tests below do
        // not need it — verified by deletion, all three still pass without it,
        // because none of them completes a deal (autoAwardXP in
        // Agreement._complete is reached through try/catch and is not called here
        // at all) and none of them touches withdrawReserve() (the only place
        // where Treasury makes an EXTERNAL call to getUniqueActiveUsers(), while
        // foundationBps()/isDaoActive() read ReputationStorage straight out of
        // the diamond's storage, which works whether or not the facet itself is
        // mounted). It is mounted to parallel the production configuration
        // (DeployFull mounts ReputationFacet) and to leave room for future tests
        // in this file that may complete a deal or exercise withdrawReserve() —
        // not because anything already written fails without it.
        bytes4[] memory repSels = new bytes4[](8);
        repSels[0] = ReputationFacet.claimXP.selector;
        repSels[1] = ReputationFacet.getXP.selector;
        repSels[2] = ReputationFacet.getUniqueActiveUsers.selector;
        repSels[3] = ReputationFacet.hasClaimed.selector;
        repSels[4] = ReputationFacet.isDealWin.selector;
        repSels[5] = ReputationFacet.autoAwardXP.selector;
        repSels[6] = ReputationFacet.notifyExecutorFault.selector;
        repSels[7] = ReputationFacet.getCleanStreak.selector;

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
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
    }

    // ============================================================
    //  TESTS
    // ============================================================

    /// The point of the whole exercise: the deal-creation fee must reach the
    /// treasury without a single change in FactoryFacet.
    function testDealFeeReachesTheTreasury() public {
        Treasury treasury = new Treasury(address(usdc), address(diamond), FOUNDATION);

        vm.prank(owner);
        FactoryFacet(address(diamond)).setFeeRecipient(address(treasury));

        uint256 before = usdc.balanceOf(address(treasury));

        // A deal created by the client — the fee is paid by the quote() formula.
        // Direct hiring goes through deployAndFund: deployAgreement now accepts
        // only the diamond itself and takes no fee.
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        FactoryFacet(address(diamond)).deployAndFund(
            client, executor, 100_000_000, 7, "terms", 0
        );
        vm.stopPrank();

        // The exact amount, not merely "greater than zero": the fee is
        // max(amount * feeBps / 10_000, feeFloor) from FactoryStorage.quote(),
        // and the region has nothing to do with it any more (regionFee is a dead
        // field). For 100_000_000 (the deployAndFund above) that is 5% =
        // 5_000_000, above the $1 floor. A weak ">0" check would not tell this
        // apart from a wrong rate or a doubled fee.
        assertEq(
            usdc.balanceOf(address(treasury)) - before,
            5_000_000,
            "deal fee arriving at the treasury does not match quote()'s 5%"
        );
    }

    /// The treasury must be able to fill a real diamond's vault, not only a mock's.
    function testTreasuryCanFillTheRealVault() public {
        Treasury treasury = new Treasury(address(usdc), address(diamond), FOUNDATION);

        vm.prank(owner);
        FactoryFacet(address(diamond)).setFeeRecipient(address(treasury));

        usdc.mint(address(treasury), 1_000_000_000);
        treasury.distribute();

        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(),
            treasury.VAULT_TARGET(),
            "the real vault was not filled to target"
        );

        // distribute() only records foundationOwed (a pull model — see the
        // Treasury.foundationOwed docstring on the Circle blacklist); the actual
        // transfer to the foundation wallet happens only through
        // withdrawFoundation(), which is why it is needed here before the balance
        // check.
        treasury.withdrawFoundation();
        assertEq(usdc.balanceOf(FOUNDATION), (1_000_000_000 - 500_000_000) * 70 / 100, "foundation share");
    }

    /// FactoryFacet, Agreement and the boards needed no changes — to them the
    /// treasury is just an address. That is checked by showing the old path still
    /// works after the treasury has been put in place.
    function testSettingTheTreasuryDoesNotBreakDealCreation() public {
        Treasury treasury = new Treasury(address(usdc), address(diamond), FOUNDATION);

        vm.prank(owner);
        FactoryFacet(address(diamond)).setFeeRecipient(address(treasury));

        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        address agreement = FactoryFacet(address(diamond)).deployAndFund(
            client, executor, 100_000_000, 7, "terms", 0
        );
        vm.stopPrank();

        assertTrue(agreement != address(0), "deal creation broke after the treasury was wired in");
    }
}
