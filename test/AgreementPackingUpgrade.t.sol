// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeAgreementPacking.s.sol — the step that deploys a
// new Agreement implementation, a new AgreementDeployer pointed at it, and moves
// the factory's pointer onto the pair.
//
// ⚠️ THIS IS NOT A diamondCut, AND THAT CHANGES WHAT A STAND CAN DO FOR IT.
// There is no selector list to hold against a census: nothing is mounted,
// nothing is replaced, the diamond's shape does not move by one selector. What
// there is instead is a sequence of three transactions of which the first two
// cost real money and the third is the only one that changes anything the
// protocol reads — so the whole value of the pre-flight is that it refuses
// BEFORE the first `new`.
//
// So this file does two things:
//
//   * fires every check the script makes, in both directions — the passing one
//     against a correctly built rig, the refusing one against a rig broken in
//     exactly the way the check is named for;
//   * proves the pair the script wires up actually produces a working deal,
//     because "setAgreementDeployer succeeded" says nothing about whether a
//     clone made through it can be read.
//
// ⚠️ WHAT NO TEST HERE CAN GIVE BACK. A clone carries the layout of the
// implementation it was cloned from and is nailed to it for life. Every check
// below is about not making the mistake; none of them is about undoing it.

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/Agreement.sol";
import "../src/AgreementDeployer.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {MockUSDCB} from "./BoardsFixture.sol";
import {UpgradeAgreementPacking} from "../script/UpgradeAgreementPacking.s.sol";

/// An implementation that never locked itself — the shape a careless rewrite of
/// `Agreement`'s constructor would leave behind, and one any stranger could name
/// themselves the client of, under the project deployer address, verified on
/// Basescan.
contract UnlockedImplementation {
    function initialize(
        address, address, address, uint256, uint256, string calldata,
        address, address, address, address
    ) external pure {}
}

/// An implementation that refuses `initialize()` for some OTHER reason. The lock
/// check has to insist on the name, not merely on a refusal: a contract that
/// reverts because it ran out of something is not a contract that is locked.
contract WronglyRefusingImplementation {
    error SomethingElse();
    function initialize(
        address, address, address, uint256, uint256, string calldata,
        address, address, address, address
    ) external pure {
        revert SomethingElse();
    }
}

contract AgreementPackingUpgradeTest is Test {
    UpgradeAgreementPacking upgrade;
    DeployFull deploy;
    DiamondProxy diamond;
    MockUSDCB usdc;

    address constant FEE_RECIPIENT = address(0xFEE);
    address constant FORWARDER     = address(0xF0F0);

    address oldImpl;
    AgreementDeployer oldDeployer;

    function setUp() public {
        upgrade = new UpgradeAgreementPacking();
        deploy  = new DeployFull();
        usdc    = new MockUSDCB();
        diamond = _deployFullShapedDiamond();

        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        // The "old" implementation on this rig is a different contract on
        // purpose: this checkout can only compile ONE Agreement, so the thing
        // being stood in for is "an implementation other than the compiled one".
        oldImpl = address(new UnlockedImplementation());
        oldDeployer = new AgreementDeployer(address(diamond), oldImpl);
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), FEE_RECIPIENT, FORWARDER, address(diamond), address(oldDeployer)
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE CEILING
    // ══════════════════════════════════════════════════════════════════════

    /// EIP-170, checked where the failure has a sentence attached to it. The
    /// packing traded seven storage slots for shift-and-mask code and moved this
    /// contract materially closer to the ceiling — 21 060 bytes before, and the
    /// number below after — so the headroom is worth an assertion rather than a
    /// hope.
    ///
    /// What disappears from behaviour if this is removed: `new Agreement()` on
    /// an oversized contract reverts with NO reason at all, and it does so
    /// INSIDE the broadcast, after the gas is committed.
    function test_TheImplementationFitsUnderTheContractSizeLimit() public view {
        upgrade.assertTheImplementationFitsOnChain();

        uint256 size = type(Agreement).runtimeCode.length;
        assertLe(size, upgrade.CONTRACT_SIZE_LIMIT(), "the compiled Agreement is over EIP-170");
        assertEq(
            upgrade.implementationHeadroom(), upgrade.CONTRACT_SIZE_LIMIT() - size,
            "the headroom reported does not match the size measured"
        );

        // Not a target, a tripwire. If this ever fails, the implementation has
        // grown by more than a kilobyte since the packing landed and somebody
        // should look at why before it stops fitting at all.
        assertGt(upgrade.implementationHeadroom(), 0, "there is no headroom left under EIP-170");
    }

    // ══════════════════════════════════════════════════════════════════════
    // "IS THERE ANYTHING TO SHIP"
    // ══════════════════════════════════════════════════════════════════════

    /// The pre-flight that stops a second run, a stale checkout, or a rerun by
    /// mistake from paying for two contracts to change nothing. Its expected side
    /// is the compiler's output for the current source; its actual side is a
    /// codehash read off the chain. Two independent sources on purpose.
    function test_ShippingIsRefusedWhenTheLiveImplementationIsAlreadyThisCode() public {
        address live = address(new Agreement());
        vm.expectRevert(
            bytes("pre-flight: the live implementation is byte-identical to what this checkout compiles - nothing to ship, wrong commit?")
        );
        upgrade.assertThereIsSomethingToShip(live);
    }

    /// And it must NOT refuse when the live implementation is something else —
    /// which is the situation on Base Sepolia today.
    function test_ShippingIsAllowedWhenTheLiveImplementationIsDifferent() public view {
        upgrade.assertThereIsSomethingToShip(oldImpl);
    }

    /// A deployer older than the EIP-1167 switch has no `implementation()` at
    /// all, and the script reads that as the zero address. That is not a reason
    /// to refuse the upgrade, and treating it as one would make this script
    /// unusable on exactly the diamonds that most need it.
    function test_AnUnknownLiveImplementationIsNotARefusal() public view {
        upgrade.assertThereIsSomethingToShip(address(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE LOCK ON THE IMPLEMENTATION
    // ══════════════════════════════════════════════════════════════════════

    /// The implementation stands on chain for ever and clones only delegatecall
    /// into it, so its own storage is nobody's escrow. It is still a contract
    /// under the project deployer address and verified on Basescan, and an unlocked one
    /// is a contract any stranger can name themselves the client of.
    ///
    /// Asserted by BEHAVIOUR: a staticcall cannot write, so the only way it comes
    /// back with `AlreadyInitialized` is that the guard is really there.
    function test_AFreshImplementationRefusesToBeClaimed() public {
        upgrade.assertImplementationIsLocked(address(new Agreement()), address(diamond));
    }

    function test_TheLockCheckCatchesAnImplementationThatAcceptsInitialize() public {
        // ⚠️ Deployed BEFORE the expectation is armed: `vm.expectRevert` arms the
        // NEXT call, and `new UnlockedImplementation()` is itself one.
        address unlocked = address(new UnlockedImplementation());
        vm.expectRevert(
            bytes("post-flight: the implementation accepted initialize() - a stranger can claim it")
        );
        upgrade.assertImplementationIsLocked(unlocked, address(diamond));
    }

    /// ⚠️ REFUSING IS NOT ENOUGH, AND THIS IS THE HALF THAT IS EASY TO SKIP. A
    /// contract that reverts for some unrelated reason would satisfy a check that
    /// only asked "did it fail". The name is the check.
    function test_TheLockCheckInsistsOnTheNameAndNotMerelyOnARefusal() public {
        address wrong = address(new WronglyRefusingImplementation());
        vm.expectRevert(
            bytes("post-flight: the implementation did not refuse initialize() with AlreadyInitialized - the constructor lock is gone")
        );
        upgrade.assertImplementationIsLocked(wrong, address(diamond));
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE WIRING
    // ══════════════════════════════════════════════════════════════════════

    /// The whole sequence the script performs, minus the broadcast: two deploys
    /// and one owner call, then every fact read back off the chain rather than
    /// assumed from three transactions having succeeded.
    function test_TheThreeStepsWireUpAndEveryFactReadsBack() public {
        Agreement impl = new Agreement();
        AgreementDeployer newDeployer = new AgreementDeployer(address(diamond), address(impl));
        FactoryFacet(address(diamond)).setAgreementDeployer(address(newDeployer));

        upgrade.assertWiring(address(diamond), address(newDeployer), address(impl));
        upgrade.assertDeployedCodeIsWhatThisCheckoutCompiles(address(impl));
        upgrade.assertImplementationIsLocked(address(impl), address(diamond));

        // And the pointer really moved, which is the only thing of the three
        // that any other contract reads.
        assertTrue(
            FactoryFacet(address(diamond)).getAgreementDeployer() != address(oldDeployer),
            "the factory still points at the old deployer"
        );
    }

    function test_TheWiringCheckCatchesAPointerThatDidNotMove() public {
        Agreement impl = new Agreement();
        AgreementDeployer newDeployer = new AgreementDeployer(address(diamond), address(impl));
        // ...and setAgreementDeployer is deliberately NOT called.

        vm.expectRevert(bytes("post-flight: setAgreementDeployer did not take effect"));
        upgrade.assertWiring(address(diamond), address(newDeployer), address(impl));
    }

    /// A deployer wired to somebody else would be accepted by the factory and
    /// would then refuse every single deal — which reads from outside as "the
    /// site is broken", not as "the wiring is wrong".
    function test_TheWiringCheckCatchesADeployerWiredToSomebodyElse() public {
        Agreement impl = new Agreement();
        AgreementDeployer strayDeployer = new AgreementDeployer(address(0xBADCA11), address(impl));
        FactoryFacet(address(diamond)).setAgreementDeployer(address(strayDeployer));

        vm.expectRevert(
            bytes("post-flight: the new deployer is wired to a different caller - every deal through it would revert")
        );
        upgrade.assertWiring(address(diamond), address(strayDeployer), address(impl));
    }

    function test_TheWiringCheckCatchesADeployerPointedAtAnotherImplementation() public {
        Agreement impl      = new Agreement();
        Agreement otherImpl = new Agreement();
        AgreementDeployer newDeployer = new AgreementDeployer(address(diamond), address(otherImpl));
        FactoryFacet(address(diamond)).setAgreementDeployer(address(newDeployer));

        vm.expectRevert(bytes("post-flight: the new deployer points at a different implementation"));
        upgrade.assertWiring(address(diamond), address(newDeployer), address(impl));
    }

    /// The identity check is what makes the "nothing to ship" pre-flight mean
    /// anything: the two compare a codehash off the chain against
    /// `keccak256(type(Agreement).runtimeCode)`, and that comparison is only
    /// valid while the compiler's runtimeCode is literally what lands on chain.
    function test_TheIdentityCheckCatchesCodeThatIsNotWhatThisCheckoutCompiles() public {
        address stranger = address(new UnlockedImplementation());
        vm.expectRevert(
            bytes("post-flight: deployed implementation differs from type(Agreement).runtimeCode - the pre-flight identity check is blind")
        );
        upgrade.assertDeployedCodeIsWhatThisCheckoutCompiles(stranger);
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE PAIR ACTUALLY MAKES A DEAL
    // ══════════════════════════════════════════════════════════════════════

    /// ⚠️ THE CHECK THE OTHERS CANNOT REPLACE. `setAgreementDeployer` succeeding
    /// says nothing about whether a clone made through the pair can be READ. The
    /// deployer clones an implementation and calls `initialize()` on the clone in
    /// the same transaction; if the two disagreed about anything — the signature,
    /// the layout, the constructor lock — the failure would arrive at the first
    /// person to hire somebody, not here.
    ///
    /// So a clone is made the way the diamond makes one, and read back through
    /// the accessors the front end and the subgraph use. `_deadlineDays` is a
    /// `uint16` inside the packed word since 28 August; a clone whose layout did
    /// not match the implementation would answer this with a number from some
    /// other field.
    function test_ACloneMadeThroughTheNewPairIsReadableAndCarriesItsTerms() public {
        Agreement impl = new Agreement();
        AgreementDeployer newDeployer = new AgreementDeployer(address(diamond), address(impl));
        FactoryFacet(address(diamond)).setAgreementDeployer(address(newDeployer));

        // Only the diamond may ask the deployer for a clone.
        vm.prank(address(diamond));
        address clone = newDeployer.deploy(
            address(0xC11E17), address(0xE8EC0), address(0),
            250_000_000, 30, "one clone, read back",
            address(diamond), address(usdc), FORWARDER, address(diamond)
        );

        assertTrue(clone != address(0), "the deployer returned no clone");
        assertGt(clone.code.length, 0, "the clone has no code");

        Agreement deal = Agreement(clone);
        assertEq(deal.client(), address(0xC11E17), "the clone's client is not who it was initialised with");
        assertEq(deal.executor(), address(0xE8EC0), "the clone's executor is not who it was initialised with");
        assertEq(deal.amount(), 250_000_000, "the clone's amount is not what it was initialised with");
        assertEq(deal.deadlineDays(), 30, "the packed deadline does not read back - the clone's layout does not match the implementation");
        assertEq(deal.terms(), "one clone, read back", "the clone lost its terms");
        assertEq(uint8(deal.status()), 0, "a fresh clone is not in CREATED");
        assertEq(deal.fundedAt(), 0, "a fresh clone claims to have been funded");
    }

    /// And the clone is a clone, not a second full copy: EIP-1167 minimal
    /// proxies are 45 bytes. This is the property the whole deployer exists for,
    /// and the one that would silently disappear if somebody put `new Agreement()`
    /// back into it.
    function test_TheDeployerMakesAMinimalProxyAndNotACopy() public {
        Agreement impl = new Agreement();
        AgreementDeployer newDeployer = new AgreementDeployer(address(diamond), address(impl));

        vm.prank(address(diamond));
        address clone = newDeployer.deploy(
            address(0xC11E17), address(0xE8EC0), address(0),
            1_000_000, 7, "size probe",
            address(diamond), address(usdc), FORWARDER, address(diamond)
        );

        assertEq(clone.code.length, 45, "the deployer did not produce an EIP-1167 minimal proxy");
        assertLt(clone.code.length, address(impl).code.length, "the clone is not smaller than what it clones");
    }

    /// The deployer admits the diamond and nobody else. Said here because this
    /// script is the thing that puts a NEW deployer in place, and a deployer that
    /// let anyone in would be an entrance to unfunded clones all over again.
    function test_TheNewDeployerAdmitsTheDiamondAlone() public {
        Agreement impl = new Agreement();
        AgreementDeployer newDeployer = new AgreementDeployer(address(diamond), address(impl));

        vm.prank(address(0xBADCA11));
        vm.expectRevert(bytes("AgreementDeployer: unauthorized"));
        newDeployer.deploy(
            address(0xC11E17), address(0xE8EC0), address(0),
            1_000_000, 7, "stranger",
            address(diamond), address(usdc), FORWARDER, address(diamond)
        );
    }

    /// The deployer's constructor refuses an implementation with no code.
    /// `Clones.clone()` checks neither, and a call to a codeless address returns
    /// SUCCESS in the EVM — so `initialize()` would "work", `deploy()` would
    /// return an address, and a client would fund an empty shell that any
    /// stranger could then initialise onto themselves.
    function test_TheDeployerRefusesAnImplementationWithNoCode() public {
        address d = address(diamond);
        vm.expectRevert(bytes("AgreementDeployer: implementation has no code"));
        new AgreementDeployer(d, address(0xBEEF));
    }

    // ══════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════

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
