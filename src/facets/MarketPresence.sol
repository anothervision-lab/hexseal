// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — MarketPresence.sol
// "An arbiter is not a player in the market" — both halves of that rule,
// in one place, read off the boards' own storage.
// ============================================================
//
// ⚠️ REWRITTEN 22 SEPTEMBER 2026, AND THE OLD RULE IS KEPT HERE BECAUSE IT
// EXPLAINS THE NEW ONE.
//
// What stood here from 17 September was two rules:
//
//   RULE A — a seat may only be taken by somebody who has NOTHING open on the
//            boards. Asked by every door into the corps.
//   RULE B — a seat that holds a bond may not BECOME a party to a trade.
//
// Together they threw an arbiter off the market entirely, for as long as he
// held a seat. The seat's real price was therefore never the 50 USDC bond — it
// was his living, and the owner measured that and called it what it was:
// hostage-taking rather than work.
//
// The seat is free now and the bond is posted PER CASE, so the rule shrinks to
// the part that was ever about a conflict of interest:
//
//   AN ARBITER DOES NOT TRADE WHILE HE IS JUDGING. Every door through which a
//   person turns into a client, an executor, an applicant or a requester asks
//   it — on BOTH sides, the one pressing and the one named.
//   → `requireNotJudging`
//
// Rule A is GONE. He is an ordinary user who steps away for a few days to read
// a case; what he had open before he took it is his own business, and the one
// conflict that actually matters — judging a deal he is a party to — is
// refused by `claimDispute` and `voteOnAppeal` by name, as it always was.
//
// ⚠️ WHAT THE NARROWING COSTS, NAMED RATHER THAN DISCOVERED LATER: a deal he
// opened BEFORE taking a case goes on running while he judges somebody else's.
// It always could — rule B never closed anything retroactively either — and
// the alternative is a rule that cancels a stranger's live deal because his
// counterparty took a case.
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
    /// `who` is reading a case right now, so this door — the one that would
    /// have made him a client, an executor, an applicant or a requester — is
    /// shut until he signs the verdict. The wait is his own reading time: the
    /// slot is freed by `submitVerdict`, not by the finalization.
    ///
    /// ⚠️ THE NAME AND THE FOUR BYTES ARE KEPT ON PURPOSE (22 September
    /// 2026), though the question behind them narrowed. `Agreement.sol` carries
    /// a copy of this error for the same rule asked from a clone, and a clone
    /// is pinned to its implementation for life — renaming it here would leave
    /// every live deal raising a selector no reader has a name for.
    ///
    /// Carries the address because both sides are checked and a caller has to
    /// know WHICH of them is the arbiter: on `acceptApplicant` the presser and
    /// the person named are different people, and "one of you two" is not a
    /// sentence a screen can show.
    error ArbiterCannotBeAParty(address who);

    /// What `who` still has open, by kind.
    ///
    /// ⚠️ NOTHING RAISES IT FROM 22 SEPTEMBER 2026, and the declaration is
    /// kept anyway. It was rule A's refusal — "the corps is entered with an
    /// empty board" — and rule A is gone; the four bytes stay so that a
    /// refusal already in the chain's history, and a reader built against it,
    /// keep their name. `openItemsOf` below still answers the question the six
    /// numbers describe; what no longer exists is a door that refuses on them.
    error OpenMarketItems(
        uint256 jobs,
        uint256 applications,
        uint256 services,
        uint256 requestsSent,
        uint256 requestsReceived,
        uint256 deals
    );

    /// Is `who` judging a case right now?
    ///
    /// ⚠️ IT READS `judgingCount`, NOT `openClaimCount`, and the two part
    /// company exactly where this rule lives. `openClaimCount` stays up until
    /// the DEAL lets go of him — which is after the finalization delay and any
    /// appeal, days after his work ended. Reading that one would keep an
    /// arbiter off the boards for a week per case, which is the very cost the
    /// per-case bond was meant to stop charging him.
    ///
    /// Cheap on the hot path by construction: one cold SLOAD, and a person who
    /// has never judged anything stops there.
    function isJudging(address who) internal view returns (bool) {
        return ArbiterRegistryStorage.data().judgingCount[who] != 0;
    }

    function requireNotJudging(address who) internal view {
        if (isJudging(who)) revert ArbiterCannotBeAParty(who);
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

    // ⚠️ `requireNothingOpen` STOOD HERE AND IS GONE (22 September 2026). It
    // was rule A — the corps is entered with an empty board — and it went with
    // the standing bond it belonged to. `openItemsOf` above stays: it is also
    // what `JobBoardFacet.getOpenMarketItems` answers a screen with, and that
    // question ("what do I still have open?") is a useful one whoever asks it.
}
