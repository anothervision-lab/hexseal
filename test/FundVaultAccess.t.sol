// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// FundVaultAccess test suite.
// The treasury will take the feeRecipient seat and must be allowed to top up
// the arbiter vault through fundVault. This suite checks that the owner and
// the current fee recipient both hold that right, and that an outside address
// does not.

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/Agreement.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";

// ---------- MOCK USDC ----------

contract MockUSDCFV {
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

contract FundVaultAccessTest is Test {
    DiamondProxy diamond;
    MockUSDCFV  usdc;

    address owner;
    address feeRecipient;

    // ============================================================
    //  SETUP
    // ============================================================

    function setUp() public {
        owner        = address(this);
        feeRecipient = address(0x4);

        usdc = new MockUSDCFV();

        FactoryFacet         factoryFacet         = new FactoryFacet();
        DiamondCutFacet      diamondCutFacet      = new DiamondCutFacet();
        DiamondLoupeFacet    diamondLoupeFacet    = new DiamondLoupeFacet();
        OwnershipFacet       ownershipFacet       = new OwnershipFacet();
        ArbiterRegistryFacet arbiterRegistryFacet = new ArbiterRegistryFacet();

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

        bytes4[] memory arbSels = new bytes4[](24);
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
        arbSels[23] = ArbiterRegistryFacet.getVaultBalance.selector;

        // These readers live in ArbiterAccountabilityFacet, so that is the
        // facet they have to be mounted on. Leaving them in the list above
        // would route them to a facet that does not implement them — the
        // call arrives and reverts.
        bytes4[] memory accSels = new bytes4[](1);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterDeals.selector;

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

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](6);
        cut[0] = IDiamondCut.FacetCut(address(factoryFacet),         IDiamondCut.FacetCutAction.Add, facSels);
        cut[1] = IDiamondCut.FacetCut(address(diamondCutFacet),      IDiamondCut.FacetCutAction.Add, cutSels);
        cut[2] = IDiamondCut.FacetCut(address(diamondLoupeFacet),    IDiamondCut.FacetCutAction.Add, loupeSels);
        cut[3] = IDiamondCut.FacetCut(address(ownershipFacet),       IDiamondCut.FacetCutAction.Add, ownSels);
        cut[4] = IDiamondCut.FacetCut(address(arbiterRegistryFacet), IDiamondCut.FacetCutAction.Add, arbSels);
        cut[5] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()), IDiamondCut.FacetCutAction.Add, accSels
        );

        diamond = new DiamondProxy(owner, cut, address(0), "");

        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );
    }

    // ============================================================
    //  ACCESS CONTROL
    // ============================================================

    /// The fee recipient is the address the treasury will become. Without the
    /// right to top up the arbiter vault it could not run the first rung of the
    /// ladder.
    function testFeeRecipientCanFundVault() public {
        address feeRecipient = FactoryFacet(address(diamond)).getFeeRecipient();

        usdc.mint(feeRecipient, 100_000_000);
        vm.startPrank(feeRecipient);
        usdc.approve(address(diamond), 100_000_000);
        ArbiterRegistryFacet(address(diamond)).fundVault(100_000_000);
        vm.stopPrank();

        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(),
            100_000_000,
            "vault did not receive the fee recipient's funding"
        );
    }

    /// Open to exactly those two, and to nobody else.
    function testStrangerCannotFundVault() public {
        address stranger = address(0xBAD);
        usdc.mint(stranger, 100_000_000);
        vm.startPrank(stranger);
        usdc.approve(address(diamond), 100_000_000);
        vm.expectRevert(ArbiterRegistryFacet.NotOwnerOrFeeRecipient.selector);
        ArbiterRegistryFacet(address(diamond)).fundVault(100_000_000);
        vm.stopPrank();
    }

    /// The owner has not lost the right.
    function testOwnerStillCanFundVault() public {
        usdc.mint(owner, 50_000_000);
        vm.startPrank(owner);
        usdc.approve(address(diamond), 50_000_000);
        ArbiterRegistryFacet(address(diamond)).fundVault(50_000_000);
        vm.stopPrank();

        assertEq(ArbiterRegistryFacet(address(diamond)).getVaultBalance(), 50_000_000, "owner funding lost");
    }
}
