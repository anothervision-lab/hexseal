// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ArbiterRegistryStorage} from "../src/facets/ArbiterRegistryFacet.sol";

/**
 * A one-shot init contract for the provenance migration.
 *
 * It is called ONLY by a delegated call from diamondCut(_init, _calldata), that
 * is, it executes in the diamond's storage and under the diamond's own ownership
 * check (DiamondCutFacet.diamondCut → OwnershipLib.enforceIsContractOwner). A
 * direct call to this contract by an outsider writes into ITS OWN storage and does
 * not touch the diamond — there is no gate here because none is needed, not
 * through an oversight.
 *
 * Why an init contract rather than a function in a facet: there is never again any
 * reason to write "who seated them" after the fact. A permanent entrance for that
 * is a permanent opportunity to rewrite a living arbiter's provenance, that is,
 * precisely the quiet edit of a public record this whole piece of work was done
 * against. An init contract lives for one transaction and does not stay in the
 * diamond: it receives no routes.
 *
 * The event is its own and not ArbiterSeated. The seating happened in July, and
 * emitting an event about a seating today would be a lie in the feed. What happens
 * here is that a missing field is filled in, and the record says exactly that.
 */
contract ArbiterProvenanceInit {
    event ArbiterProvenanceBackfilled(address indexed arbiter, address indexed seater);

    error ProvenanceZeroSeater();
    error ProvenanceNotAnArbiter(address who);

    /// Fills in seatedBy for those whose field is empty, and raises the seater's
    /// seatedCountBy by exactly the number filled in.
    ///
    /// It is idempotent: an arbiter with a provenance already recorded is skipped
    /// silently — a repeated run will not turn one seating into two and will not
    /// inflate the counter the chief's bloc ceiling rests on.
    ///
    /// A non-arbiter is a refusal, not a skip: an address that is not in the corps
    /// got here from a mistaken list, and writing a provenance for them means
    /// asserting on chain that somebody seated them.
    function backfillSeatedBy(address[] calldata arbiters, address seater) external {
        if (seater == address(0)) revert ProvenanceZeroSeater();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        for (uint256 i = 0; i < arbiters.length; i++) {
            address a = arbiters[i];
            if (!d.isArbiter[a]) revert ProvenanceNotAnArbiter(a);
            if (d.seatedBy[a] != address(0)) continue;

            d.seatedBy[a] = seater;
            d.seatedCountBy[seater]++;
            emit ArbiterProvenanceBackfilled(a, seater);
        }
    }
}
