// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — MarketPresence.sol
// "An arbiter is not a player in the market" — both halves of that rule,
// in one place, read off the boards' own storage.
// ============================================================
//
// The owner's decision of 17 September 2026 has two directions, and they are
// deliberately NOT one predicate:
//
//   RULE A — a seat may only be taken by somebody who has NOTHING open on the
//            boards. Every door on the way into the corps asks it:
//            `applyForArbiterSeat`, `approveArbiterApplication`, `addArbiter`,
//            `applyAsArbiter`, and the bond doors on the transition that turns
//            an unpaid seat into a working one.
//            → `requireNothingOpen`
//
//   RULE B — a seat that holds a bond may not BECOME a party to a trade. Every
//            door through which a person turns into a client, an executor, an
//            applicant or a requester asks it — on BOTH sides, the one pressing
//            and the one named.
//            → `requireNotBondedArbiter`
//
// "An arbiter" here is the owner's own definition: a seat AND a posted bond.
// A seat that has never paid in (`BOND_STATE_UNPOSTED`) is not an
// arbiter and trades like anybody else; the moment it pays, rule A is asked and
// rule B starts applying. A seat a won appeal drew below the norm
// (`BOND_STATE_SAGGING`) is still an arbiter: it finishes the cases it holds,
// and it may not trade.
//
// ⚠️ WHY THIS IS A LIBRARY AND NOT A FACET VIEW EVERYBODY CALLS.
// The natural shape would be one mounted view and a `staticcall` from each
// door. It was rejected for a measured reason: a `staticcall` into the diamond
// only works if the selector is MOUNTED, and the selector lives on a board
// facet. Twenty test rigs in this repository seat arbiters without mounting a
// board at all, and on the chain the order of a cut would decide whether the
// corps can be joined — a Replace that landed before the board's Add would
// shut every door into the corps until the second half of the cut arrived.
// Namespaced storage has no such ordering: the slots are the same slots
// whatever is mounted, and an empty namespace reads as zero, which is the true
// answer for a person who has never touched a board.
//
// ⚠️ THE ONE COUNTER THAT IS A SCAN, AND WHY IT IS THE ONE.
// Five of the six kinds are counters kept at O(1) on both sides, because every
// exit from them belongs to ONE person: a job closes for its client, a service
// for its executor, a request for its two sides, a deal for its two parties.
// An APPLICATION does not: when a client cancels a job or hires one applicant,
// the applications of everybody ELSE close in the same transaction, and there
// can be any number of them — the number is chosen by whoever applied, not by
// the client who pays for the cancel. A counter would mean a loop over that
// list on the client's money exit, i.e. an unbounded loop a stranger can grow;
// a stale counter would mean a person who can never become an arbiter because
// the chain still thinks he is waiting on a job that died a year ago. So
// applications are counted by READING the live truth — the job's status and the
// job's own `hasApplied` table — over an index of the job ids this person has
// applied to. Nothing about that count can go stale; what it costs is gas, and
// `JobBoardFacet.pruneClosedApplications` is the bound on that (anybody may
// press it, and it can only remove entries that are provably not open).
// ============================================================

import {JobBoardStorage} from "./JobBoardFacet.sol";
import {ServiceBoardStorage} from "./ServiceBoardFacet.sol";
import {ArbiterRegistryStorage} from "./ArbiterRegistryFacet.sol";
import {RegistryStorage} from "../RegistryFacet.sol";

library MarketPresence {
    /// Rule B. `who` holds a seat with a bond behind it, so this door — the one
    /// that would have made him a client, an executor, an applicant or a
    /// requester — is shut. The way out is his own: `resignAsArbiter` returns
    /// the bond and the boards open again.
    ///
    /// Carries the address because both sides are checked and a caller has to
    /// know WHICH of them is the arbiter: on `acceptApplicant` the presser and
    /// the person named are different people, and "one of you two" is not a
    /// sentence a screen can show.
    error ArbiterCannotBeAParty(address who);

    /// Rule A. What `who` still has open, by kind, so a screen can list what is
    /// in the way instead of saying "no". Every number is the count of things
    /// that still have an exit of their own — the six kinds named in the
    /// parameters below are the whole list, and each one is closed by its
    /// owner, never by an administrator.
    error OpenMarketItems(
        uint256 jobs,
        uint256 applications,
        uint256 services,
        uint256 requestsSent,
        uint256 requestsReceived,
        uint256 deals
    );

    /// The owner's definition of an arbiter: a seat AND money behind it.
    ///
    /// `bondDrawnByAppeal` is part of the answer and not a detail: a won appeal
    /// may draw a bond to zero, and a seat in that state is still an arbiter
    /// (it finishes what it holds) while a seat that never paid is not. The
    /// same three fields, in the same order, are what `getBondState` reads to
    /// tell states 1, 2 and 3 apart — this is that read with the states folded
    /// into a yes or no.
    ///
    /// Cheap on the hot path by construction: a person who is not in the corps
    /// costs ONE cold SLOAD and stops there.
    function holdsBond(address who) internal view returns (bool) {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (!d.isArbiter[who]) return false;
        return d.arbiterBond[who] != 0 || d.bondDrawnByAppeal[who];
    }

    function requireNotBondedArbiter(address who) internal view {
        if (holdsBond(who)) revert ArbiterCannotBeAParty(who);
    }

    /// Everything `who` has open on the boards right now, by kind.
    ///
    /// `requestsSent` reads `pendingRequestCount`, which the service board has
    /// kept since the fan-out cap landed — the rule needs exactly that number
    /// and a second counter beside it would be a second answer free to disagree
    /// with the first.
    function openItemsOf(address who)
        internal
        view
        returns (
            uint256 jobs,
            uint256 applications,
            uint256 services,
            uint256 requestsSent,
            uint256 requestsReceived,
            uint256 deals
        )
    {
        JobBoardStorage.Layout storage jb = JobBoardStorage.store();
        jobs         = jb.openJobCount[who];
        applications = JobBoardStorage.openApplicationsOf(jb, who);

        ServiceBoardStorage.Layout storage sb = ServiceBoardStorage.store();
        services         = sb.openServiceCount[who];
        requestsSent     = sb.pendingRequestCount[who];
        requestsReceived = sb.incomingRequestCount[who];

        deals = RegistryStorage.store().openDealCount[who];
    }

    function requireNothingOpen(address who) internal view {
        (
            uint256 jobs,
            uint256 applications,
            uint256 services,
            uint256 requestsSent,
            uint256 requestsReceived,
            uint256 deals
        ) = openItemsOf(who);

        if ((jobs | applications | services | requestsSent | requestsReceived | deals) != 0) {
            revert OpenMarketItems(jobs, applications, services, requestsSent, requestsReceived, deals);
        }
    }
}
