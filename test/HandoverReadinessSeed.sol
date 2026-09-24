// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {HandoverLib} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";

/// Puts a bench over the handover's SECOND condition, for the stands that are
/// about what happens AFTER governance is live and not about the condition
/// itself (20 September 2026).
///
/// ⚠️ WHY THIS EXISTS. `activateDAO()` gained three terms — deals open now, a
/// run of clean disputes, and the number of different arbiters who earned it —
/// and thirty-six stands across six files pressed that door to get to the
/// scene they were actually about. Earning the terms honestly costs eight full
/// disputes (`test/HandoverCleanStreak.t.sol` does exactly that, once, and it
/// is the slowest scene in the repository). Doing it thirty-six times would buy
/// nothing: those stands are about removal windows, seating and bonds.
///
/// ⚠️ WHY THE SLOTS ARE SWEPT FOR AND NOT WRITTEN DOWN, which is the whole
/// reason this is a file and not three constants. All three counters sit at the
/// END of append-only structs, one of them past sixty fields. A hand-counted
/// offset is the shape of the bug that broke the live job board in July 2026,
/// and here it would be worse than wrong: a stand that seeded the WRONG slot
/// would still compile, still run, and `activateDAO()` would simply keep
/// refusing — thirty-six red tests with a plausible-looking cause. The sweep
/// writes a sentinel into each slot in turn and asks the contract's own reader
/// which one it came back through, so a future append moves the field and this
/// follows it.
///
/// ⚠️ IT NEEDS `getHandoverReadiness()` MOUNTED. A bench without it gets a
/// loud revert naming the missing door, never a silent zero.
abstract contract HandoverReadinessSeed {
    Vm private constant _hvm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// RegistryStorage.REGISTRY_STORAGE_POSITION — see src/RegistryFacet.sol.
    bytes32 private constant _SEED_REG_BASE =
        0xc2046377b613f781ce75bf5776eb70f650372f5239ada8a3238d951cdca15e00;
    /// ArbiterRegistryStorage.POSITION — see src/facets/ArbiterRegistryFacet.sol.
    bytes32 private constant _SEED_ARB_BASE =
        0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    uint256 private constant _SEED_DEPTH = 160;

    uint8 private constant _TERM_LIVE_DEALS = 0;
    uint8 private constant _TERM_CLEAN_STREAK = 1;
    uint8 private constant _TERM_DISTINCT_ARBITERS = 2;

    /// The sentinel is far from every floor, so a slot that happens to hold a
    /// plausible small number cannot be mistaken for the one being looked for.
    uint256 private constant _SEED_SENTINEL = 0xBEEF01;

    function _readiness(address diamond) private view returns (HandoverLib.Readiness memory) {
        return ArbiterAccountabilityFacet(diamond).getHandoverReadiness();
    }

    function _seedAtLeast(uint256 has, uint256 floorValue) private pure returns (uint256) {
        return has > floorValue ? has : floorValue;
    }

    function _seedTermOf(HandoverLib.Readiness memory r, uint8 term) private pure returns (uint256) {
        if (term == _TERM_LIVE_DEALS) return r.liveDeals;
        if (term == _TERM_CLEAN_STREAK) return r.cleanStreak;
        return r.distinctCleanArbiters;
    }

    function _seedSweep(address diamond, bytes32 base, uint8 term) private returns (bytes32) {
        // ⚠️ NON-ZERO SLOTS ARE SWEPT TOO, and that was a correction rather
        // than a refinement. The first draft skipped every slot already holding
        // something, which is safe on a fresh bench and WRONG on a working one:
        // two stands in ArbiterRemovalForCauseIntegration reach the handover
        // with deals still open, so `liveDeals` is not zero and the sweep walked
        // straight past the field it was looking for. What makes a candidate the
        // right one is that writing the sentinel MAKES THE READER SAY THE
        // SENTINEL and it did not say so before — which holds whatever the slot
        // held. Every slot is put back before the next one is tried.
        uint256 before = _seedTermOf(_readiness(diamond), term);
        if (before == _SEED_SENTINEL) revert("handover seed: the term already reads as the sentinel");
        for (uint256 i = 0; i < _SEED_DEPTH; i++) {
            bytes32 candidate = bytes32(uint256(base) + i);
            bytes32 held      = _hvm.load(diamond, candidate);
            if (held == bytes32(_SEED_SENTINEL)) continue;
            _hvm.store(diamond, candidate, bytes32(_SEED_SENTINEL));
            uint256 seen = _seedTermOf(_readiness(diamond), term);
            _hvm.store(diamond, candidate, held);
            if (seen == _SEED_SENTINEL) return candidate;
        }
        revert("handover seed: a term of getHandoverReadiness() was not found in its namespace");
    }

    /// Writes exactly the three floors, nothing more. The stand is then over
    /// the second condition and no further over it than it has to be — a scene
    /// that later asserts on one of these numbers sees the floor, not a made-up
    /// large value.
    function _seedHandoverLiveness(address diamond) internal {
        // Fails loudly rather than sweeping 480 slots for a door that is not
        // there.
        (bool mounted, ) = diamond.staticcall(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.getHandoverReadiness.selector)
        );
        require(mounted, "handover seed: this bench does not mount getHandoverReadiness()");

        HandoverLib.Readiness memory r = _readiness(diamond);
        // The floor, or whatever the bench has already earned if that is more:
        // a stand with deals genuinely open must not have its market counter
        // pushed DOWN to the floor by the seeding.
        _hvm.store(
            diamond,
            _seedSweep(diamond, _SEED_REG_BASE, _TERM_LIVE_DEALS),
            bytes32(_seedAtLeast(r.liveDeals, r.liveDealsFloor))
        );
        _hvm.store(
            diamond,
            _seedSweep(diamond, _SEED_ARB_BASE, _TERM_CLEAN_STREAK),
            bytes32(_seedAtLeast(r.cleanStreak, r.cleanStreakFloor))
        );
        _hvm.store(
            diamond,
            _seedSweep(diamond, _SEED_ARB_BASE, _TERM_DISTINCT_ARBITERS),
            bytes32(_seedAtLeast(r.distinctCleanArbiters, r.distinctCleanArbitersFloor))
        );

        require(_readiness(diamond).met, "handover seed: the three floors were written and the door still says no");
    }
}
