// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * A facet that does not exist, written so the revert census can be asked the
 * only question that matters about it: does it catch a refusal NOBODY has
 * decoded yet?
 *
 * ⚠️ WHY A FIXTURE AND NOT A MEASUREMENT ON A REAL FACET. Breaking a real facet
 * on purpose proves the census is wired to `src/` — that is measured by
 * mutation, once, by hand. It does not stay proved. This file makes the other
 * half permanent: the same census function, pointed at this directory, must
 * report `CutInTomorrowAndForgotten()` as undecoded and unexcused. A lock that
 * only ever sees errors somebody already thought about is guarding the past.
 *
 * It is real Solidity and it compiles with everything else under `test/` on
 * purpose: a fixture that merely LOOKED like Solidity would let a parser bug
 * pass as a fixture bug. Nothing deploys it and nothing imports it.
 */
contract FutureFacet {
    /// The point of the fixture: declared here, decoded in neither table, and
    /// argued for in no ledger. The census must name it.
    error CutInTomorrowAndForgotten();

    /// A control: this one IS decoded (it is a real board error), so a census
    /// that simply reported everything would fail the fixture test too.
    error TitleInvalid();

    function doTheThing(uint256 n) external pure returns (uint256) {
        if (n == 0) revert CutInTomorrowAndForgotten();
        if (n == 1) revert TitleInvalid();
        return n;
    }
}

/**
 * The SECOND spelling of a throw, added 14 September 2026.
 *
 * ⚠️ WHY IT IS HERE. `revert FutureFacet.CutInTomorrowAndForgotten()` and
 * `revert CutInTomorrowAndForgotten()` are one throw and one selector; only a
 * text scan can tell them apart, and until this date the census could not read
 * the first form at all. The cost fell on the money-press census next door —
 * nine qualified sites in `src/facets/ArbiterApplicationsFacet.sol` were read as
 * no sites at all, and a refusal reachable from both bond buttons had never
 * been counted, let alone worded. Here it cost only a column: `revertedFrom`
 * reported fewer sites than exist, and `shared/unreachable-reverts.json` holds
 * that field EXACTLY, so a blind scan makes a stale ledger look correct.
 *
 * No new error is declared: adding one would change what the orphan test above
 * expects, and this fixture answers a different question — not "is a new error
 * found" but "is a throw of a KNOWN error found when it is spelled the long way".
 */
contract QualifiedThrowFacet {
    function throwTheNeighboursError(uint256 n) external pure {
        if (n == 0) revert FutureFacet.CutInTomorrowAndForgotten();
    }
}
