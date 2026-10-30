// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Vm.sol";
import "../src/FactoryFacet.sol";

/// ONE LINE FOR A SUITE THAT IS NOT ABOUT THE DEAL CEILING.
///
/// The deal cap (12 October 2026) refuses any escrow above $500 on both birth
/// doors, and a great many scenes written years before it are built on $1,000,
/// $3,000 and $50,000 deals. Those scenes are about the split, the gas, the
/// appeal economics or the certificate -- the AMOUNT is scenery in them, and it
/// was chosen to make arithmetic readable.
///
/// ⚠️ WHY THE SCENERY IS NOT REWRITTEN SMALLER, which is the obvious cheaper
/// move. Every one of those suites asserts hand-typed money literals against
/// those amounts; retyping the amounts means retyping the expectations, and an
/// expectation retyped by whoever is fixing a build is an expectation that has
/// stopped being independent of the code. That is the exact accident this
/// project keeps a rule about: a limiter fixed under substituted values passed
/// review green and changed nothing. So the amounts stay, and the suite says
/// out loud that the ceiling is not its subject.
///
/// WHAT IT WRITES, AND WHY NOT THROUGH THE DOOR. `liftDealCap()` is the real
/// button, but it is a selector, and mounting a selector costs each fixture an
/// array resize in a cut that several other stands count. This writes the flag
/// the button writes, in one line, from a fixture that may not route the
/// button at all.
///
/// ⚠️ THE SLOT IS NOT ASSUMED. `capLifted` is the second field of
/// `DealCapStorage.Data` -- a `uint256` then a `bool`, and the `bool` cannot
/// share a slot with the `mapping` that follows it, so it stands alone at
/// POSITION + 1. That reasoning is held to a measurement rather than left as
/// prose: test/DealCap.t.sol's
/// `test_TheSlotTheOtherSuitesWriteIsTheSlotTheButtonWrites` presses the real
/// button and this helper on two separate diamonds and compares what the facet
/// answers. If the field ever moves, that scene reddens and names this file.
library DealCapOff {
    /// forge's cheatcode address, derived the standard way rather than typed:
    /// a library cannot inherit `Test`, and a hand-typed address here would be
    /// one transposed character away from writing storage into nothing at all.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// The offset of `capLifted` inside `DealCapStorage.Data`.
    uint256 private constant CAP_LIFTED_OFFSET = 1;

    /// Presses the one-way button on `diamond` by writing its flag.
    ///
    /// Named as a sentence because the call site is the documentation: a reader
    /// of someone else's `setUp` has to be able to tell in one glance that the
    /// ceiling was switched off deliberately and that the suite below is not
    /// measuring it.
    function thisSuiteIsNotAboutTheCeiling(address diamond) internal {
        vm.store(
            diamond,
            bytes32(uint256(DealCapStorage.POSITION) + CAP_LIFTED_OFFSET),
            bytes32(uint256(1))
        );
    }

    /// Puts the ceiling back on `diamond`.
    ///
    /// For the one suite whose subject IS the ceiling and which stands on a
    /// fixture that switched it off for everybody else. Nothing in `src/`
    /// writes `false` into that flag -- that is the whole claim of the one-way
    /// button -- so a suite that needs the ceiling live on a shared fixture has
    /// no door to go through either, and reaches for the same slot the other
    /// direction. It says so in its own `setUp` and then measures that the
    /// ceiling really is back before it asserts anything.
    function thisSuiteIsAboutTheCeiling(address diamond) internal {
        vm.store(
            diamond,
            bytes32(uint256(DealCapStorage.POSITION) + CAP_LIFTED_OFFSET),
            bytes32(uint256(0))
        );
    }
}
