// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  The gate for script/UpgradeAgreementHandInSignal.s.sol
// ============================================================
//
// This script is not a diamondCut. It swaps the implementation every future
// clone is cut from, and a clone is nailed to its implementation for life -- so
// the one thing worth guarding is the ORDER, and the order is guarded by
// behaviour here rather than by a sentence in a runbook.
//
// WHY THE ORDER IS A SILENT FAILURE AND NOT A LOUD ONE. The clone's
// announcement is wrapped in try/catch. Ship this implementation onto a diamond
// that does not route `notifyWorkHandedIn()` and nothing breaks: new deals hand
// in exactly as old ones did, announce nothing, and the only symptom is that
// the thing the work was for did not happen. Nobody gets an error. The
// pre-flight turns that silence into a refusal, and these scenes prove the
// refusal is real by building both diamonds and asking.

import "forge-std/Test.sol";
import "../script/UpgradeAgreementHandInSignal.s.sol";
import "../script/UpgradeRegistryHandInSignal.s.sol";
import "../script/DeployFull.s.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/ReputationFacet.sol";

contract AgreementHandInSignalUpgradeTest is Test {
    UpgradeAgreementHandInSignal internal upgrade;
    UpgradeRegistryHandInSignal  internal registryCut;
    DeployFull internal deploy;

    /// EIP-170, written by a person. The chain's rule, not this project's.
    uint256 constant CONTRACT_SIZE_LIMIT = 24_576;

    function setUp() public {
        upgrade     = new UpgradeAgreementHandInSignal();
        registryCut = new UpgradeRegistryHandInSignal();
        deploy      = new DeployFull();
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE ORDER GUARD
    // ══════════════════════════════════════════════════════════════════════

    /// A diamond that has NOT had the registry cut must be refused. Built by
    /// removing the selector, so the refusal is provoked rather than assumed.
    function test_ThePreFlightRefusesADiamondThatCannotHearAHandIn() public {
        DiamondProxy d = _deployFullShapedDiamond();
        _unmountTheHandInDoor(d);

        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: the diamond does not route notifyWorkHandedIn() - run script/UpgradeRegistryHandInSignal.s.sol FIRST, or every new deal ships announcing nothing, in silence"
            )
        );
        upgrade.assertTheDiamondCanHearAHandIn(address(d));
    }

    /// And the same diamond passes once the registry cut has landed on it -- so
    /// the guard is measuring the cut and not merely refusing everything.
    function test_ThePreFlightAcceptsADiamondOnceTheRegistryCutHasLanded() public {
        DiamondProxy d = _deployFullShapedDiamond();
        _unmountTheHandInDoor(d);

        // Precondition, stated: it really is refused first.
        (bool refusedBefore, ) = address(upgrade).staticcall(
            abi.encodeWithSelector(upgrade.assertTheDiamondCanHearAHandIn.selector, address(d))
        );
        assertFalse(refusedBefore, "precondition: the guard passed on a diamond without the door");

        // Now do what the first script does.
        RegistryFacet fresh = new RegistryFacet();
        IDiamondCut(address(d)).diamondCut(registryCut.buildCuts(address(fresh)), address(0), "");

        upgrade.assertTheDiamondCanHearAHandIn(address(d));
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE THINGS THAT COST MONEY IF THEY ARE WRONG
    // ══════════════════════════════════════════════════════════════════════

    /// `new Agreement()` over the EIP-170 ceiling reverts with NO reason at all,
    /// and it would do so inside the broadcast, after the gas is committed. The
    /// expected side is the chain's rule written down here, not a number read
    /// out of the contract being measured.
    function test_TheImplementationFitsUnderTheCeiling() public view {
        upgrade.assertTheImplementationFitsOnChain();
        assertLe(type(Agreement).runtimeCode.length, CONTRACT_SIZE_LIMIT, "over EIP-170");
        assertGt(upgrade.implementationHeadroom(), 0, "no headroom left at all");
    }

    /// Shipping a byte-identical implementation would pay for two contracts to
    /// change nothing -- a stale checkout, or a second run by mistake. Both
    /// directions are exercised: an identical implementation is refused, and a
    /// different one is allowed.
    function test_AnIdenticalImplementationIsRefusedAndADifferentOneIsNot() public {
        Agreement sameAsThisCheckout = new Agreement();
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: the live implementation is byte-identical to what this checkout compiles - nothing to ship, wrong commit?"
            )
        );
        upgrade.assertThereIsSomethingToShip(address(sameAsThisCheckout));

        // Any other contract stands for "an older implementation".
        upgrade.assertThereIsSomethingToShip(address(new RegistryFacet()));

        // And a deployer too old to answer implementation() is not a failure.
        upgrade.assertThereIsSomethingToShip(address(0));
    }

    /// The implementation is left standing on chain for ever. An unlocked one is
    /// a contract any stranger can name themselves the client of, under the
    /// project deployer's address, verified on Basescan. Asserted by behaviour.
    function test_TheFreshImplementationIsLocked() public {
        Agreement impl = new Agreement();
        upgrade.assertImplementationIsLocked(address(impl), address(0xD1A));
    }

    /// The identity check only means something while `type(Agreement).runtimeCode`
    /// is literally what lands on chain. If Agreement ever gains an immutable
    /// that stops being true, and the pre-flight would quietly never match again.
    function test_TheDeployedCodeIsWhatThisCheckoutCompiles() public {
        Agreement impl = new Agreement();
        upgrade.assertDeployedCodeIsWhatThisCheckoutCompiles(address(impl));
    }

    // ══════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════

    /// A DeployFull-shaped diamond already mounts the new door, because
    /// DeployFull was updated with this work. To stand in for the chain as it is
    /// TODAY, the door is taken back off.
    function _unmountTheHandInDoor(DiamondProxy d) internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = RegistryFacet.notifyWorkHandedIn.selector;
        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, one);
        IDiamondCut(address(d)).diamondCut(remove, address(0), "");
        require(
            IDiamondLoupe(address(d)).facetAddress(RegistryFacet.notifyWorkHandedIn.selector) == address(0),
            "the rig still routes the door it was meant to lose"
        );
    }

    function _deployFullShapedDiamond() internal returns (DiamondProxy d) {
        IDiamondCut.FacetCut[] memory initCuts = deploy.buildInitCuts(
            address(new DiamondCutFacet()),
            address(new DiamondLoupeFacet()),
            address(new OwnershipFacet()),
            address(new RegistryFacet()),
            address(new FactoryFacet())
        );
        d = new DiamondProxy(address(this), initCuts, address(0), "");

        IDiamondCut(address(d)).diamondCut(
            deploy.buildRemainingCuts(
                address(new JobBoardFacet()),
                address(new ServiceBoardFacet()),
                address(new ArbiterRegistryFacet()),
                address(new ArbiterAccountabilityFacet()),
                address(new ArbiterApplicationsFacet()),
                address(new DealMetadataFacet()),
                address(new JobReceiptFacet()),
                address(new ReputationFacet())
            ),
            address(0),
            ""
        );
    }
}
