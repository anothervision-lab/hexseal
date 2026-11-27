// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ══════════════════════════════════════════════════════════════════════════
//  THE ONE NUMBER: HOW MUCH ROOM ArbiterRegistryFacet MUST KEEP UNDER EIP-170
//
//  Nothing else lives in this file. No contract, no bytecode, one constant and
//  the reasons beside it, so that the floor has ONE OWNER and not three
//  copies that nothing compares.
//
// ── WHY A FILE OF ITS OWN, AND THE MEASUREMENT THAT BOUGHT IT ─────────────
//  Until 19 November 2026 this number was written out three times: twice as a
//  bare literal inside an `assertGt` and once as a constant in the seat-price
//  cut script. NOTHING compared the three. Measured rather than supposed, on
//  the acceptance of the round that moved the floor: ONE copy quietly halved
//  to 2 048 while the other two stood at 3 584 reddened **ZERO** of the 25
//  tests that carry the floor — and the corrupted line went on promising "at
//  least 3,5 KiB of room" in its own message, so the one-digit diff read as
//  harmless to the person reviewing it too.
//
//  ⚠️ SO DO NOT COPY THIS NUMBER ANYWHERE. A lock, a script or a scene that
//  needs the floor imports `REGISTRY_MIN_ROOM`. The day a second literal
//  exists the pair can disagree, and the WEAKER of the two wins in silence:
//  a floor is only as high as its lowest copy.
//
//  ⚠️ AND NO READER MAY RESTATE THE SIZE IN ITS MESSAGE. A message that
//  spells "3,5 KiB" while the number says something else is the half of this
//  defect a human trips on; the readers build their text out of this constant
//  or name the constant instead of a size.
//
// ── THE NUMBER IS A POLICY, AND IT IS THE OWNER'S ─────────────────────────
//  3 584 bytes, decided by the owner on 19 November 2026 (decision 308 of the
//  working journal), down from a 4 096 that an executor had put into a lock
//  with no decision behind it at all.
//
//  ⚠️ IT IS A TRIPWIRE AND NOT THE CHAIN'S CEILING. EIP-170 is 24 576 and the
//  facet stands 4 074 under it: past this line the facet still deploys, and
//  the change after that is the one that cannot. That is why every reader
//  holds it with a STRICT comparison and why none may be loosened.
//
//  THE PRICE, recorded next to the number because a policy that moved with
//  nothing written beside it is what this tree treats as a defect:
//  512 BYTES OF THE RESERVE THE 15 OCTOBER SPLIT BOUGHT ARE GIVEN UP.
//  WHAT IT BUYS: one decision instead of two — at 4 000 the next piece of
//  work would have had 74 bytes and the same question would be back on the
//  next round. THE BUDGET IT LEAVES: 490 BYTES, room being 4 074 today
//  (ArbiterRegistryFacet at 20 502 bytes of runtime code).
//
//  ⚠️ MOVING IT AGAIN IS HIS CALL AND NOT AN EXECUTOR'S.
//
// ── WHO READS IT TODAY ────────────────────────────────────────────────────
//  Read off the tree by one search on 19 November 2026. The list is
//  INFORMATION, not the binding: what binds is the import, and an import that
//  loses its target fails the build loudly rather than quietly.
//
//    script/UpgradeSeatPrice.s.sol        — the cut's pre-flight `require`
//    test/AppealFacetSplitCut.t.sol       — the floor off a real deployment
//    test/UpgradeSeatPriceRehearsal.t.sol — the floor off the compiled facet
// ══════════════════════════════════════════════════════════════════════════

// The least room, in bytes, that ArbiterRegistryFacet must keep between its
// runtime code and the EIP-170 limit of 24 576.
//
// ⚠️ The comment is `//` and not `///` on purpose: solc refuses a natspec tag
// on a file-level variable ("Documentation tag @notice not valid for
// file-level variables", measured here on 19 November 2026), so a `///` block
// would not compile.
uint256 constant REGISTRY_MIN_ROOM = 3_584;
