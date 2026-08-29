// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The ceiling on simultaneously claimed disputes.
//
// It caps fee farming: an arbiter earns a share of the fee on EVERY dispute
// regardless of which way the ruling went, so "claim a lot and rule at random"
// is income without work. The ceiling counts the NUMBER of disputes, not their
// value: the value is set by whoever created the deal, so any ceiling on it
// would inherit that untrustworthiness. The rule deliberately does not touch
// the value at all (decided while the verdict-appeal work was reviewed,
// 20 July 2026).
//
// ⚠️ The price of the ceiling is known and accepted: with a corps of one, the
// N+1-th dispute waits or times out into a split of the pot. That is a defined
// outcome, not a breakage.

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";

contract ArbiterClaimCapTest is Test, ArbiterTwoFacetBench {
    /// Both handles point at ONE address — the proxy carrying both facets (see
    /// ArbiterTwoFacetBench). `facet` deliberately keeps its old name: every
    /// vm.store(address(facet), ...) below keeps hitting the very same storage.
    ArbiterRegistryFacet facet;
    ArbiterAccountabilityFacet accFacet;
    address arbiter;

    bytes32 constant ARB_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;
    /// Offset of the openClaimCount field inside Data. Obtained by measurement
    /// and guarded by test_OpenClaimCountSlotMatchesLiveStorage below.
    ///
    /// Found by sweeping, and it is not the 21 that the field's position in the
    /// declaration suggests: a throwaway test walked offset 0..59, wrote 7 into
    /// keccak256(arbiter, ARB_BASE+offset) and checked that
    /// getOpenClaimCount(arbiter) == 7. The single hit was offset 13. Struct
    /// packing (bools and addresses share slots with their neighbours) shifts a
    /// field's slot index away from its ordinal in the declaration.
    uint256 constant SLOT_OPEN_CLAIM_COUNT = 13;

    function setUp() public {
        (facet, accFacet) = _deployArbiterBench();
        arbiter = address(0xA1);
        vm.store(address(facet), keccak256(abi.encode(arbiter, uint256(ARB_BASE))), bytes32(uint256(1)));
    }

    /// The slot offset is not taken on trust: if the field moves, the test below
    /// starts writing somewhere else and goes quietly green.
    function test_OpenClaimCountSlotMatchesLiveStorage() public {
        _setOpenClaims(arbiter, 7);
        assertEq(accFacet.getOpenClaimCount(arbiter), 7, "the openClaimCount slot offset has moved");
    }

    function test_CapIsTen() public view {
        assertEq(facet.getMaxClaimsPerArbiter(), 10, "ceiling set by the owner on 15.08.2026");
    }

    function test_ClaimRevertsAtCap() public {
        _setOpenClaims(arbiter, 10);
        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterRegistryFacet.TooManyOpenClaims.selector, 10, 10)
        );
        facet.claimDispute(address(0xDEAD), bytes32(0), bytes32(uint256(1)), bytes32(uint256(2)));
    }

    /// Below the ceiling the refusal has to be a DIFFERENT one — otherwise the
    /// test above would go green on any breakage of claimDispute, not on the
    /// ceiling.
    function test_BelowCapFailsForADifferentReason() public {
        _setOpenClaims(arbiter, 9);
        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.CommitmentNotFound.selector);
        facet.claimDispute(address(0xDEAD), bytes32(0), bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function _setOpenClaims(address who, uint256 n) internal {
        bytes32 base = bytes32(uint256(ARB_BASE) + SLOT_OPEN_CLAIM_COUNT);
        vm.store(address(facet), keccak256(abi.encode(who, uint256(base))), bytes32(n));
    }
}
