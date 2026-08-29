// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * The same fixture, one directory deeper.
 *
 * ⚠️ WHY. `src/facets/` is a subdirectory, and a census that only read the top
 * level would be green while missing every facet in the protocol — including the
 * one whose `JobNotFound()` started this work. The recursion is not obvious from
 * the outside, so it gets its own file rather than a comment claiming it works.
 */
contract DeeperFacet {
    error BuriedTwoDirectoriesDown();

    function alsoDoTheThing() external pure {
        revert BuriedTwoDirectoriesDown();
    }
}
