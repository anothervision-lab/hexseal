// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  PULLING THE LOT, FOR EVERY SCENE THAT HAS AN APPEAL IN IT
// ============================================================
//
// WHY THIS FILE EXISTS. From 14 October 2026 an appeal panel is SUMMONED by
// the chain rather than filled by whoever presses first, so a scene that
// raises an appeal and then votes needs one more transaction between the two:
// `summonAppealPanel`. There were about a hundred such places, and the
// alternative to one helper was a hundred copies of "work out the seed height,
// roll to it, press".
//
// ⚠️ A FREE FUNCTION AND NOT A BASE CLASS, on purpose. The scenes that need it
// sit on four different rigs (MoneyPathBase, Diamond.t.sol's own, the upgrade
// rehearsals, the legacy split rig), and a shared base would have to be
// threaded into all four. A file-level function reaches the cheat codes through
// the address forge-std itself derives, and any contract can call it.
//
// ⚠️ IT TAKES NO `vm.prank` WITH IT. Pulling the lot is permissionless and the
// caller cannot change the answer, so every scene calls this unpranked — and
// deliberately so: a pranked call would be consumed by the view this function
// reads FIRST, not by the summons, which is exactly the kind of seam that
// looks fine and measures nothing.

import {Vm} from "forge-std/Vm.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAppealFacet} from "../src/facets/ArbiterAppealFacet.sol";

// The cheat-code address, derived the way forge-std derives it rather than
// pasted as a literal.
Vm constant LOT_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// Rolls to the appeal's seed height if needed and summons its panel.
///
/// Returns the five the chain called, read back through the live view, so a
/// scene that needs to know WHO was called does not have to guess or recompute
/// the draw. A scene that only needs a panel to exist can ignore the return.
///
/// ⚠️ IT ROLLS FORWARD, AND THAT IS VISIBLE TO THE SCENE AROUND IT. Five
/// blocks of delay plus one, nothing else: no warp, so every deadline the
/// scene set with `vm.warp` is where it was. A scene that asserts on
/// `block.number` has to take the roll into account, which is why this is a
/// named call at the call site and not hidden inside `raiseAppeal`'s rig.
function pullAppealLot(address diamond, address deal) returns (address[5] memory panel) {
    ArbiterRegistryFacet reg = ArbiterRegistryFacet(diamond);
    (, , , uint256 seedBlock, ) = ArbiterAppealFacet(address(reg)).getAppealSummons(deal);
    if (block.number <= seedBlock) LOT_VM.roll(seedBlock + 1);
    ArbiterAppealFacet(address(reg)).summonAppealPanel(deal);
    (panel, , , , ) = ArbiterAppealFacet(address(reg)).getAppealSummons(deal);
}

/// The same, with the seed under the scene's control.
///
/// ⚠️ THE OVERRIDE ONLY TAKES IF NOTHING HAS READ THE HASH YET — measured on
/// 14 October 2026 on this very foundry: `vm.setBlockhash` after a
/// `blockhash(n)` of the same height is a SILENT no-op, and the draw then runs
/// on the hash foundry invented instead of the one the scene asked for. So the
/// override happens here, before the summons reads it, and the positive
/// control below is what makes a silent miss loud. The distance from the
/// current block does not matter — one block behind takes as well as ten —
/// only whether the hash has been looked at.
function pullAppealLotWithSeed(address diamond, address deal, bytes32 seed)
    returns (address[5] memory panel)
{
    ArbiterRegistryFacet reg = ArbiterRegistryFacet(diamond);
    (, , , uint256 seedBlock, ) = ArbiterAppealFacet(address(reg)).getAppealSummons(deal);
    if (block.number <= seedBlock) LOT_VM.roll(seedBlock + 1);
    LOT_VM.setBlockhash(seedBlock, seed);
    require(blockhash(seedBlock) == seed, "the seed override did not take");
    ArbiterAppealFacet(address(reg)).summonAppealPanel(deal);
    (panel, , , , ) = ArbiterAppealFacet(address(reg)).getAppealSummons(deal);
}
