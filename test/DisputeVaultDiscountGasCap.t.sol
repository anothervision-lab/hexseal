// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  THE ONE THING THE DISCOUNT CHANGES FOR CODE THAT IS ALREADY ON CHAIN
// ============================================================
//
// Decision 54 added two storage operations to the branch of `clearDisputeClaim`
// that returns a funded bounty: the bank's share is taken out of the appended
// field and put back into `vaultBalance`.
//
// ⚠️ WHY THAT IS NOT A FREE CHANGE. Every live deal is an EIP-1167 clone, and a
// clone is nailed for life to the implementation it was born from. Those clones
// call `clearDisputeClaim` on the diamond under a HARD gas cap
// (`Agreement.CLAIM_CLEAR_GAS`, 200 000) inside a `try {} catch {}` with an
// EMPTY handler (src/Agreement.sol, `_clearArbiterClaim`). Replacing the facet
// changes what that call costs; the clone's cap cannot be changed at all.
//
// A cap that has become too tight does not announce itself. The call runs out of
// gas, the catch swallows it, the deal still exits the dispute — and the top-up
// is never refunded, the claim is never cleared, and the arbiter is left holding
// an open claim for ever. Nobody is told.
//
// ⚠️ WHAT THE EXISTING MEASUREMENT DOES NOT COVER, WHICH IS WHY THIS FILE EXISTS.
// test/DiamondDeathGasCaps.t.sol::testClaimClearCostSitsUnderItsCap measures
// `clearDisputeClaim` on a deal with a claim and a stuck verdict — and NO funded
// bounty, because its deal is 1000 USDC and the levy on that already pays the
// arbiter more than the floor, so `fundDispute` refuses with `TopUpNotNeeded`.
// The refund branch, which is the ONLY branch the discount made more expensive,
// is never entered there.
//
// So the deal here is small on purpose. Everything else is the same rig, the
// same real facets through the same real proxy, with `vm.cool()` putting the
// diamond account, the facet-address slot and the facet itself back to cold —
// the state the call is really in, because a fresh transaction starts cold.
//
// The cap literal below is hand-copied from src/Agreement.sol. Reading it back
// out of the contract under test would make this a mirror: expected and measured
// would come from the same place and the assertion could never fail
// derived from the thing it checks.

import "./DiamondDeathEscrowBase.sol";

contract DisputeVaultDiscountGasCapTest is DiamondDeathEscrowBase {

    uint256 constant CAP_CLAIM_CLEAR = 200_000; // = Agreement.CLAIM_CLEAR_GAS

    /// Small enough that the levy leaves the arbiter under the floor, which is
    /// the only shape in which a top-up exists at all. Five dollars is the pot
    /// the discount was written about.
    uint256 constant SMALL_DEAL = 5_000_000; // $5

    /// More than one discount, so the bank actually pays and the branch under
    /// measurement has a non-zero share to move.
    uint256 constant VAULT_SEED = 50_000_000; // $50

    /// The default from ArbiterRegistryFacet, restated by hand.
    uint256 constant DISCOUNT = 3_000_000; // $3

    /// ⚠️ THE MEASUREMENT THIS CUT OWES THE CLONES ALREADY ON CHAIN.
    ///
    /// What disappears from behaviour if this is removed: nothing else anywhere
    /// drives `clearDisputeClaim` through the refund branch under the clone's
    /// real cap. A discount that pushed it over 200 000 would ship green.
    function testClaimClearWithAFundedBountyStillSitsUnderTheClonesCap() public {
        Agreement a = _smallDisputedDealWithAFundedBounty();

        // The scene is only worth measuring if the branch is actually entered.
        assertGt(
            ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a)), 0,
            "no bounty was funded - the branch this cut made more expensive is not entered"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getDisputeSubsidy(address(a)), DISCOUNT,
            "the bank did not put its share in - the two extra storage operations do not happen"
        );

        // And the worst case for this call: a claim to drop and a stuck verdict
        // to clear, on top of the refund.
        _claimByArbiter(a);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);

        uint256 used = _measureAsAgreement(
            a, abi.encodeWithSignature("clearDisputeClaim(address)", address(a))
        );
        emit log_named_uint("gas: clearDisputeClaim, funded bounty + claim + stuck verdict, all cold", used);
        assertLt(used, CAP_CLAIM_CLEAR, "the clone's 200 000 cap no longer covers this call");

        // Not a target, a tripwire: the clones on chain cannot be given a bigger
        // cap, so the margin is the whole safety here.
        assertLt(used * 2, CAP_CLAIM_CLEAR, "and keep at least 2x headroom against the clones' fixed cap");
    }

    /// The bank's share really goes back to the bank, and the payer gets back
    /// only what the payer paid. Measured through the same call, because a
    /// refund that quietly hands the bank's three dollars to a person would be a
    /// way to milk the vault by opening a dispute and waiting.
    function testTheAbandonedDisputeReturnsTheBanksShareToTheBank() public {
        Agreement a = _smallDisputedDealWithAFundedBounty();

        uint256 vaultBefore  = ArbiterRegistryFacet(address(diamond)).getVaultBalance();
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 bounty       = ArbiterRegistryFacet(address(diamond)).getDisputeBounty(address(a));

        vm.prank(address(a));
        ArbiterRegistryFacet(address(diamond)).clearDisputeClaim(address(a));

        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore + DISCOUNT,
            "the bank's share did not come back to the bank"
        );
        assertEq(
            usdc.balanceOf(client), clientBefore + (bounty - DISCOUNT),
            "the payer got back something other than exactly what the payer paid"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getDisputeSubsidy(address(a)), 0,
            "the booked share is still standing after the refund"
        );
    }

    // ════════════════════════════════════════════════════════════════════

    /// The base rig mounts three of the accountability facet's selectors and
    /// `getDisputeSubsidy` is not among them, so it is added here. A freshly
    /// deployed facet is enough: it shares the namespace and the POSITION with
    /// the registry that writes the field, which is the whole reason the read
    /// could sit on the other facet at all.
    function _mountTheSubsidyRead() internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = ArbiterAccountabilityFacet.getDisputeSubsidy.selector;
        IDiamondCut.FacetCut[] memory add = new IDiamondCut.FacetCut[](1);
        add[0] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()), IDiamondCut.FacetCutAction.Add, one
        );
        DiamondCutFacet(address(diamond)).diamondCut(add, address(0), "");
    }

    /// A five-dollar deal, disputed, with the top-up paid by the client and the
    /// bank's three dollars reserved against it.
    function _smallDisputedDealWithAFundedBounty() internal returns (Agreement a) {
        _mountTheSubsidyRead();

        // A vault with money in it, or the discount is capped to nothing and the
        // branch under measurement never has a share to move.
        usdc.mint(owner, VAULT_SEED);
        usdc.approve(address(diamond), VAULT_SEED);
        ArbiterRegistryFacet(address(diamond)).fundVault(VAULT_SEED);

        vm.prank(client);
        usdc.approve(address(diamond), type(uint256).max);

        // `deployAgreement` takes the diamond and nobody else now, so this
        // fixture stands where a board stands.
        vm.prank(address(diamond));
        address addr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), SMALL_DEAL, DEADLINE_DAYS, "terms", 0
        );
        a = Agreement(addr);

        usdc.mint(client, SMALL_DEAL);
        vm.startPrank(client);
        usdc.approve(addr, SMALL_DEAL);
        a.fund();
        vm.stopPrank();

        vm.prank(executor);
        a.activate();
        vm.prank(client);
        a.raiseDispute();

        uint256 quote = ArbiterRegistryFacet(address(diamond)).quoteDisputeTopUp(addr);
        assertGt(quote, 0, "this deal needs no top-up - the scene cannot be built on it");
        usdc.mint(client, quote);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).fundDispute(addr);
    }
}
