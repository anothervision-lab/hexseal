// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ArbiterRegistryFacet.sol
//
// Arbiter registry + DAO mode + Diamond-as-arbiter + rewards
//
// Architecture:
//   1. An arbiter claims a dispute through commit-reveal → the Diamond becomes the Agreement's arbiter
//   2. The arbiter calls submitVerdict(agreement, clientWins) → the verdict enters the queue
//   3. Anyone calls finalizeVerdict(agreement) → the Diamond executes resolveDispute
//   4. Owner/DAO may overturnVerdict before finalization → the arbiter's XP is slashed, no payout
//
// ⚠️ THE MONEY AND THE PLAIN READS LIVE NEXT DOOR (16 September 2026).
//   This facet was 24 532 bytes of the 24 576 EIP-170 allows — forty-four free —
//   and the approved appeal economics did not fit. Twenty-eight selectors moved
//   to `ArbiterVaultFacet`: every door that only moves money (fundVault,
//   creditDisputeFee, withdrawTreasurySlice, withdrawArbiterReward, fundDispute,
//   withdrawDisputeBounty, the floor and discount setters, quoteDisputeTopUp)
//   and every door that only reads a number (getArbiters, getPendingVerdict,
//   getAppealVotes and the rest). Measured: 24 532 → 19 205 here, the new facet
//   6 619; the diamond's selector total did not change, because a selector moved
//   to another address is still the same selector at the same proxy.
//   The paragraph below therefore DESCRIBES THE MONEY, IT DOES NOT HOLD IT —
//   the rules it states are still true, they are just enforced in the file next
//   to this one.
//
// FeeVault: topped up by hand (fundVault) and holds a buffer against future
//   needs of the arbiter vault (Treasury.distribute()), but it no longer pays
//   for an individual dispute — the flat rewardPerDispute payout was rejected
//   by design on 28 July and removed on 31 July (setRewardPerDispute now
//   reverts RewardPathRetired, the rewardPerDispute field is dead). Payment
//   for a verdict comes from two sources today: creditDisputeFee (80% of the
//   3% fee charged on the disputed amount) and disputeBounty — a party's
//   top-up to reach arbiterFloor on a small pot (fundDispute), which goes to
//   the arbiter on finalization inside finalizeVerdict. The arbiter collects
//   what has piled up through withdrawArbiterReward().
//
// Appeal panel: since 17 September 2026 the arbiters who vote on an appeal are
//   paid out of its deposit, equally, on every outcome that reached a quorum,
//   and pull their share through withdrawAppealShare(). A won appeal is paid
//   back by the arbiter who was wrong — see resolveAppeal.
//
// DAO mode: ONLY after owner.activateDAO() — which does not go through before
//   uniqueActiveUsers >= DAO_THRESHOLD (1 000) and the successor has confirmed
//   itself. From then on anyone holding a clean streak of 5 may join through
//   applyAsArbiter() — experience is no longer asked for at that door.
//   The threshold alone switches nothing on; activateDAO() stays a separate call.
// ============================================================

import "../../src/FactoryFacet.sol";         // FactoryStorage (trustedForwarder, usdc)
import "../../src/DiamondProxy.sol";          // OwnershipLib
import "../../src/facets/ReputationFacet.sol"; // ReputationStorage (XP + cleanStreak + uniqueActiveUsers)
import "../RegistryFacet.sol";                // RegistryStorage — verifying notifyArbiterTimeout's caller
// ArbiterAccountabilityFacet for ONE event declaration: ArbiterSuspensionLifted.
// The vindication branch below lifts a suspension, and a lift that leaves no log
// reads in the feed as a suspension that never ended. The declaration stays
// where the other suspension events live — a second copy here would compile,
// produce an identical log, and drift on the first edit.
//
// ⚠️ The import is circular (that file imports this one for ArbiterRegistryStorage)
// and Solidity resolves it: neither side inherits from the other, both references
// are to types. Measured by building, not assumed.
import {ArbiterAccountabilityFacet} from "./ArbiterAccountabilityFacet.sol";
import {MarketPresence} from "./MarketPresence.sol"; // "an arbiter is not a party"

// ---------- INTERFACES ----------

interface IAgreementStatus {
    function status()    external view returns (uint8);
    function setArbiter(address newArbiter) external;
    function client()    external view returns (address);
    function executor()  external view returns (address);
    function amount()    external view returns (uint256);
    function disputedAt() external view returns (uint256);
}

interface IUSDCFull {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ---------- STORAGE ----------

library ArbiterRegistryStorage {
    /// @custom:storage-location erc7201:hexseal.arbiterregistry.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.arbiterregistry.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant POSITION = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    /// How long an arbiter's suspension holds if it is not lifted earlier.
    /// Approved by the owner on 15 August 2026: the finalization window is one
    /// day, the appeal window is four; three days is enough to sort a case out
    /// and does not hold honest parties for a week.
    ///
    /// ⚠️ LIVES IN THE LIBRARY, NOT IN THE FACET (16 August 2026). A suspension
    /// is set from TWO places in TWO different files, and which two those are
    /// changed on 18 August 2026:
    ///
    ///   • `ArbiterAccountabilityFacet._performRemoval` — the shared body of a
    ///     removal, that is, both doors to removal at once (was: only
    ///     `removeArbiterForCause`);
    ///   • `ArbiterRegistryFacet._recordArbiterMistake` — the threshold branch,
    ///     where the suspension is now the MAIN action, not a side effect: no
    ///     lift happens there any more, only an accusation and a fast lever.
    ///
    /// A third place CLEARS the mark —
    /// `ArbiterRegistryFacet.resolveAppeal`, when the panel vindicates the
    /// arbiter and the chain takes its own accusation back. Copying the number
    /// into the second file would create exactly the defect this avoids: two
    /// values, a promise that they agree, and nothing that goes red when they
    /// diverge. No copy is left here and nothing needs reconciling — both
    /// facets read one declaration.
    ///
    /// It is exposed through ArbiterAccountabilityFacet.getSuspensionWindow() —
    /// the only public getter of this number, and it must keep returning the
    /// same thing: moving it changed the PLACE of the declaration, not the value.
    ///
    /// Constants do not sit in storage: `Data` below does not move because of this.
    uint256 internal constant SUSPENSION_WINDOW = 72 hours;

    /// How many times A HUMAN HAND may suspend one arbiter before the lever
    /// refuses and points at the other door. The owner's decision of
    /// 8 October 2026. What the refusal is for, in the plainest terms: at this
    /// many presses the question has stopped being "stop him for three days"
    /// and become "should he be an arbiter at all", and the refusal says so.
    ///
    /// ⚠️ IT BINDS THE HAND AND NOT THE CHAIN. `suspendArbiter` is the only
    /// counted door; the automatic path (`_suspendAndAccuse`, reached from
    /// `_recordArbiterMistake`) writes `suspendedUntil` itself and is
    /// deliberately outside this count. A ceiling that could be filled up by
    /// hand and thereby silence the automaton would be a way to protect a bad
    /// arbiter by pressing at him, which is the opposite of what it is for.
    ///
    /// ⚠️ THREE, NOT FOUR, AND THE FOURTH IS THE ONE THAT REFUSES. Three
    /// presses are 9 days of held money (3 x SUSPENSION_WINDOW); past that the
    /// honest instrument is the removal door, which carries a cause, a pause
    /// and a right of reply. The refusal says so in words rather than leaving
    /// the presser to guess — see the revert in `suspendArbiter`.
    uint256 internal constant HAND_SUSPENSION_LIMIT = 3;

    /// How long the arbiter must stand WITH NO HAND-PRESSED SUSPENSION before
    /// the count goes back to zero.
    ///
    /// ⚠️ SILENCE, NOT THE CALENDAR, and that is the whole shape of it. A
    /// calendar reset — "three per week", read as `block.timestamp / 7 days` —
    /// is gamed by pressing three times at 23:59 and three more at 00:01, which
    /// turns a ceiling of three into a ceiling of six at a moment the presser
    /// chooses. Measured from the LAST press, there is no boundary to stand on:
    /// the only way back to a full lever is to leave the man alone for a week.
    ///
    /// It is also what keeps the lever from seizing up for good, which the
    /// owner required in the same decision: a ceiling with no way back would
    /// end the fast brake on one arbiter for ever after three presses. Leave
    /// the man alone for a week and the lever comes back whole.
    uint256 internal constant HAND_SUSPENSION_SILENCE = 7 days;

    /// How long a man removed against his will waits before any door into the
    /// corps opens to him again — half a year (owner's decision, 22 September
    /// 2026).
    ///
    /// ⚠️ IT IS A WIDENING, NOT A NEW LOCK, and that is the whole argument.
    /// Before it, `removedAt != 0` sent every non-owner door away with
    /// `ReseatingRemovedIsOwnerOnly`, and the only hand that could clear that
    /// mark was the same owner's — so for a man the owner did not choose to
    /// bring back, the door was shut FOREVER, and everything he did afterwards
    /// counted for nothing.
    ///
    /// ⚠️ MEASURED FROM `lastRemovalAt`, NEVER FROM `removedAt`. The second is
    /// erased by the next seating (`clearRemovalRecord`), so a cooldown keyed
    /// on it would be cleared by the very act it is supposed to delay; the
    /// first is one of the three fields nothing erases. Both are written by the
    /// same removals — `_recordRemoval` writes `lastRemovalAt`,
    /// `_performRemoval` writes `removedAt` — and resigning writes neither, so
    /// a man who simply stopped waits for nothing.
    ///
    /// ⚠️ IN THE LIBRARY, LIKE SUSPENSION_WINDOW ABOVE, AND FOR THE SAME
    /// REASON: four doors into the corps apply it and they live in two files.
    /// A copy in the second file would be a second number free to disagree with
    /// the first, and nothing would go red when they did.
    uint256 internal constant REMOVAL_COOLDOWN = 180 days;

    /// He was removed against his will and the half-year has not run out. The
    /// moment it does is in the error, so a screen shows a date instead of a
    /// refusal with no end to it.
    error RemovalCooldownActive(uint256 until);

    /// Half a year after an involuntary removal, every door opens again.
    ///
    /// Asked by all four entrances to the corps. The owner's own `addArbiter`
    /// is exempt for the reason `ReseatingRemovedIsOwnerOnly` already gives: he
    /// reverses HIS OWN removal with one command, and a cooldown binding him
    /// would turn a mistaken removal into a half-year sentence nobody could
    /// lift.
    function requireCooldownPassed(Data storage d, address who) internal view {
        uint256 removedWhen = d.lastRemovalAt[who];
        if (removedWhen == 0) return;
        uint256 until_ = removedWhen + REMOVAL_COOLDOWN;
        if (block.timestamp < until_) revert RemovalCooldownActive(until_);
    }

    // ── THE OVERTURN RATE, 21 September 2026 (the owner's decision) ─────────
    //
    // A SECOND trigger beside `MAX_ARBITER_MISTAKES`, not a replacement for it.
    // That one counts mistakes IN A ROW and is cleared by any clean verdict, so
    // it catches an arbiter who falls apart at once and never catches one who
    // alternates: mistake, clean, mistake, clean. Measured against the sector's
    // own numbers, the gap is not theoretical — the flagship on-chain escrow
    // saw four disputes in seven years, so a corps of any size hands each
    // arbiter a handful of cases a year and "three in a row" is a threshold
    // nothing reaches.
    //
    // ⚠️ THE THREE NUMBERS LIVE HERE, IN THE LIBRARY, AND NOWHERE ELSE — the
    // same argument as SUSPENSION_WINDOW above, and it is load-bearing twice
    // over. The rule is applied by ArbiterRegistryFacet (`finalizeVerdict`) and
    // published by ArbiterAccountabilityFacet (`getArbiterOutcomeRecord`),
    // which is what the web client reads to decide whether to show a rate at
    // all. A copy of `OUTCOME_MIN_SAMPLE` on the screen would be a second
    // number nothing compares: the screen would hide the rate at four while the
    // chain removed at three, or the other way round, and no test anywhere
    // would go red. The screen therefore holds no number — it reads these.
    //
    // Constants do not sit in storage: `Data` below does not move because of
    // this.

    /// How many of the most recent CLOSED cases the rate is measured over.
    /// Six, and the window is a fixed-width bit field below — widening it past
    /// eight needs a wider field, not just a bigger number.
    uint256 internal constant OUTCOME_WINDOW = 6;

    /// Overturns inside that window that trip the automatic path. Two.
    uint256 internal constant OUTCOME_OVERTURN_LIMIT = 2;

    /// Closed cases before the rate is allowed to judge at all, and before any
    /// reader may show one.
    ///
    /// Under four the fraction lies about itself rather than about the arbiter:
    /// one overturn out of one closed case reads as a hundred per cent of bad
    /// work, and it is one case. Four is the first denominator at which two
    /// overturns are a pattern rather than an accident, and it is deliberately
    /// the SAME number the screen hides the rate below — see the warning above.
    uint256 internal constant OUTCOME_MIN_SAMPLE = 4;

    /// The packing of `Data.verdictOutcomes`, one word per arbiter:
    ///
    ///   bits   0..5   — the window: bit 0 is the most recent closed case, a
    ///                   set bit means that case was overturned;
    ///   bits   6..7   — unused, and they must stay zero: the shift-in below
    ///                   masks with OUTCOME_MASK, so a stray bit 6 would be
    ///                   dropped, but a reader counting bits would see it;
    ///   bits   8..71  — closed cases, ever (uint64);
    ///   bits  72..135 — of those, overturned, ever (uint64).
    ///
    /// One word and not three mappings: this is read on every finalization and
    /// written on every finalization, and three slots would be three SLOADs and
    /// three SSTOREs on the hottest path the arbiter corps has. uint64 holds
    /// eighteen quintillion cases; the protocol has seen zero.
    uint256 internal constant OUTCOME_MASK        = (1 << OUTCOME_WINDOW) - 1;
    uint256 internal constant OUTCOME_CLOSED_SHIFT  = 8;
    uint256 internal constant OUTCOME_TURNED_SHIFT  = 72;
    uint256 internal constant OUTCOME_COUNT_MASK    = type(uint64).max;

    // ── The arbiter payroll period (25 September 2026, mainnet item D3) ──
    //
    // ⚠️ BOTH NUMBERS LIVE HERE, IN THE LIBRARY, AND NOWHERE ELSE — the same
    // argument as OUTCOME_MIN_SAMPLE above. The period is applied in two
    // different facets: `ArbiterRegistryFacet.finalizeVerdict` counts a case
    // into a period, and `TreasuryLinkFacet` credits money into one and pays
    // out of one. A second copy of the length would let the counter file work
    // under one calendar while the payer divided by another, and the money
    // would go to the wrong month with nothing red anywhere.

    /// How long one payroll period lasts. THIRTY DAYS.
    ///
    /// The word the protocol uses for this pot is "payroll", and a payroll is
    /// monthly in every language the client is translated into — the thing has
    /// to match the expectation its own name creates.
    ///
    /// The two neighbours were weighed and both lose on a measured number
    /// rather than on taste. On 25 September 2026 the live diamond had closed
    /// ZERO disputes cleanly in its whole life (`cleanDisputesTotal` = 0, read
    /// off Base Sepolia), and the sector it copies is no busier — Kleros
    /// Escrow settled four disputes in seven years. So:
    ///
    ///   • SHORTER (a week) multiplies EMPTY periods, and an empty period's
    ///     money has no claimant who can ever exist. Every one of them
    ///     eventually leaves for the foundation through the remainder door, so
    ///     the shorter the period the more of the arbiters' twenty per cent
    ///     quietly becomes a second foundation share. The label would stop
    ///     being true before the code stopped working.
    ///   • LONGER (a quarter, a year) makes an arbiter who judged on day two
    ///     wait until day ninety-one to be paid for it, and stretches the
    ///     remainder window past the point where anybody will still be
    ///     watching.
    ///
    /// Thirty DAYS and not "a calendar month": one division, no leap rules, no
    /// anchor, and every period the same width — a month-length that varied
    /// would make the same work worth more in February.
    uint256 internal constant PAYROLL_PERIOD = 30 days;

    /// How long a CLOSED period's money waits for its earners before anybody
    /// may push the rest out to the foundation. ONE YEAR, AS A PROPOSAL.
    ///
    /// ⚠️ THIS NUMBER IS THE DIFFERENCE BETWEEN A PAYROLL AND A SECOND
    /// FOUNDATION SHARE, and it is the owner's to name. Measured on 25
    /// September 2026: not one dispute has ever been finalized cleanly on the
    /// live diamond, so on today's evidence EVERY period is an empty one and
    /// every empty period's money ends at the foundation once this window
    /// lapses. A short window makes that the normal road; a long one keeps the
    /// money where its name says it belongs while the corps is still young.
    ///
    /// A year is proposed and not chosen, the same way `RESERVE_DAO_WAIT` was
    /// proposed at four years for mainnet item D4. Changing it is one literal
    /// on this line.
    ///
    /// ⚠️ IT IS NOT ZERO AND MUST NOT BE. A pot a stranger may empty the
    /// instant the period closes is a race against the arbiters who earned it,
    /// and the stranger wins it every time — he is watching, and they are
    /// working.
    uint256 internal constant PAYROLL_CLAIM_WINDOW = 365 days;

    /// The first period index this library refuses to do arithmetic about.
    ///
    /// Half of what the multiplication could hold, which is fourteen orders of
    /// magnitude above any period a real clock will ever produce — period
    /// numbers are timestamps over thirty days, so the year 3000 is about
    /// twelve thousand. Written as a division of the type's own maximum rather
    /// than as a literal, so it follows PAYROLL_PERIOD if that ever moves.
    uint256 internal constant PAYROLL_PERIOD_CEILING = type(uint256).max / PAYROLL_PERIOD / 2;

    struct PendingVerdict {
        address arbiter;        // who submitted the verdict
        bool    clientWins;     // the outcome
        uint256 submittedAt;    // submission timestamp
        bool    frozen;         // frozen by owner/DAO (cannot be finalized)
        bool    finalized;      // executed on the Agreement
        bool    overturned;     // overturned by owner/DAO (no payout, XP slashed)
        bool    executing;      // finalizeVerdict is running — do not drop via clearDisputeClaim
        // ── User-initiated appeal (pre-finalization only) ──
        bool    appealed;        // an appeal was raised
        bool    appealResolved;  // the appeal vote has finished
        address appellant;       // who raised it — for the deposit refund/forfeit
        uint256 appealDeadline;  // deadline of the voting window
        uint256 votesUphold;     // votes to leave the verdict as it stands
        uint256 votesOverturn;   // votes to overturn
        /// What the appellant ACTUALLY PAID, frozen when he paid it
        /// (26 August 2026). The refund used to be written as
        /// `transfer(v.appellant, APPEAL_DEPOSIT)` — the constant, not the
        /// money that came in — so raising the deposit from $20 to $50 paid
        /// fifty to a man who had put down twenty, and lowering it to $10 paid
        /// him ten. Neither is the deposit; both are somebody else's money.
        ///
        /// ⚠️ APPENDED AT THE END. `votesOverturn` fills its slot, so this one
        /// starts a new slot and pays one SSTORE on `raiseAppeal`. The order
        /// and the types of the fields above are not touched — layout is
        /// append-only, enforced by a build gate over the struct's fields.
        ///
        /// ⚠️ ZERO MEANS "APPEAL RAISED BEFORE THIS FIELD EXISTED". Both
        /// readers in resolveAppeal fall back to the constant then, which is
        /// exactly the rule those appeals were raised under.
        uint256 appealDeposit;
        /// WHEN THE OWNER'S FREEZE WAS PRESSED (25 September 2026). Written by
        /// `freezeVerdict` and by nothing else, and read only through
        /// `_freezeHolds` — the freeze now lapses `FREEZE_WINDOW` after this
        /// moment, so that a verdict nobody ever came back to decide stops
        /// holding the arbiter's top-up for ever. See `freezeVerdict`.
        ///
        /// ⚠️ APPENDED AT THE END, for the same reason `appealDeposit` above
        /// was: `appealDeposit` fills its own slot, so this field starts a new
        /// one and costs one SSTORE on a freeze — a press that only the owner
        /// or the DAO can make. Nothing above it moves, and nothing above it
        /// changes type. Enforced by script/check-storage-structs.sh.
        ///
        /// ⚠️ IT IS NOT WRITTEN BY `raiseAppeal`, which also sets `frozen`.
        /// An appeal's freeze is owned by `appealDeadline`, not by this clock,
        /// and `_freezeHolds` says so in its first branch rather than relying
        /// on this field being zero there.
        ///
        /// ⚠️ ZERO MEANS "FROZEN BEFORE THIS FIELD EXISTED". `_freezeHolds`
        /// then measures from `submittedAt`, which is never zero on a verdict
        /// that exists and is always at or before the freeze — so such a
        /// verdict lapses rather than staying stuck, which is the whole point
        /// of the change. Deliberately NOT a revert and not "never lapses":
        /// either would keep the defect alive for exactly the verdicts that
        /// were already caught by it.
        uint256 frozenAt;
    }

    /// A chief arbiter's proposal to remove an arbiter (15 August 2026).
    ///
    /// `cause` is kept as a `uint8` rather than as `Cause` — that enum is
    /// declared in ArbiterAccountabilityFacet, and tying a storage layout to a
    /// type from another file would mean that a rename over there moves storage
    /// over here. The value is the same numeric code already used in the
    /// ArbiterRemovedForCause event.
    struct RemovalProposal {
        uint8   cause;
        bytes32 evidenceDigest;
        uint256 proposedAt;
        address by;
        /// How long THIS accusation runs, frozen at the moment it was laid
        /// (26 August 2026). Until this field existed the life of
        /// an accusation was read live out of
        /// `ArbiterAccountabilityFacet.PROPOSAL_TTL`, so shortening that
        /// constant by a cut expired every standing accusation at once,
        /// without a single transaction — the accused lost his window and
        /// nothing happened on chain that he could see.
        ///
        /// ⚠️ APPENDED AT THE END, and it costs no slot: `by` is an address,
        /// so 20 + 8 = 28 bytes still fit the slot it already occupies. The
        /// order and the types of the fields above are not touched — layout is
        /// append-only, enforced by a build gate over the struct's fields.
        ///
        /// ⚠️ ZERO MEANS "WRITTEN BEFORE THIS FIELD EXISTED", not "expires
        /// immediately". Records laid by the facets deployed before 26 August
        /// 2026 carry a zero here, and both readers fall back to the constant
        /// in force — `_proposalDeadline` in the accountability facet and
        /// `_hasLiveProposalHere` in the registry. A live accusation must not
        /// die of an upgrade either.
        uint64  ttl;
        /// How long THIS accusation owes the accused before it may be executed,
        /// frozen at the moment it was laid (25 September 2026).
        ///
        /// ⚠️ THE OTHER HALF OF THE PAIR ABOVE, AND IT WAS LEFT OUT FOR A MONTH.
        /// The execution window is bounded on both sides by two neighbouring
        /// lines in `ArbiterAccountabilityFacet.removeArbiterForCause` and
        /// `executeChainRemoval`. `ttl` above froze the UPPER bound, the one
        /// that protects the ACCUSER; the LOWER bound — the pause that protects
        /// the ACCUSED — went on reading `REMOVAL_DELAY` live out of the same
        /// pair. Shorten that constant by a cut and every standing accusation
        /// became executable in the same block: the accused was told
        /// "forty-eight hours to answer", the answer is the only thing that can
        /// call a removal off, and the hours were taken back without a single
        /// transaction he could have seen coming. A removal for cause forfeits
        /// his seat bond, so what the missing freeze cost was money.
        ///
        /// ⚠️ APPENDED AT THE END, and it costs no slot either: `by` (20) +
        /// `ttl` (8) + `delay` (4) is exactly the 32 bytes of the word they
        /// share. Measured with the compiler's own layout — this struct is 128
        /// bytes before the field and 128 bytes after it — not assumed.
        ///
        /// ⚠️ ZERO MEANS "WRITTEN BEFORE THIS FIELD EXISTED", exactly as on
        /// `ttl`, and the readers fall back to the constant in force. The other
        /// reading — zero as "no pause owed" — would have the upgrade itself
        /// make every standing accusation executable on the spot, which is the
        /// harm this field exists to prevent.
        ///
        /// `uint32` holds 136 years in seconds; the pause is measured in hours.
        uint32  delay;
    }

    /// An application for a seat in the corps, decided by hand and only until
    /// governance is live. Written and read by `ArbiterApplicationsFacet`, which
    /// shares this namespace and this POSITION exactly as
    /// `ArbiterAccountabilityFacet` does — see the header of that file for why
    /// admissions are a third facet rather than a paragraph in either of the
    /// first two.
    ///
    /// `state` is a `uint8`, not the `ApplicationState` enum that facet
    /// declares, for the same reason `RemovalProposal.cause` is: tying a
    /// storage layout to a type declared in another file means a rename over
    /// there moves storage over here. Values, and the one that is never
    /// written:
    ///
    ///   0 None       — never applied
    ///   1 Pending    — standing; whether it is still INSIDE its window is a
    ///                  question about the clock, answered on read
    ///   2 Approved   — seated by a person, bond posted in the same transaction
    ///   3 Rejected   — refused with a reason in words; `decidedAt` starts the
    ///                  wait before the same address may apply again
    ///   4 Withdrawn  — taken back by the applicant; leaves no wait behind
    ///
    ///   ⚠️ Expired is NEVER STORED. Nobody sends a transaction to expire an
    ///   application, so a stored flag would mean the record read as live until
    ///   somebody did. It is computed from `submittedAt` on every read.
    ///
    /// The three fields after `state` pack with it into two slots: 1 + 8 + 8 +
    /// 20 = 37 bytes.
    struct ArbiterApplication {
        uint8   state;
        uint64  submittedAt;
        uint64  decidedAt;
        address decidedBy;
    }

    /// Where one settled appeal's money went, per agreement (17 September
    /// 2026). Written by `resolveAppeal`, consumed by `creditDisputeFee` and
    /// `withdrawAppealShare`.
    ///
    /// ⚠️ NOT A FIELD OF `PendingVerdict`, deliberately. `getPendingVerdict()`
    /// returns that struct whole, and its shape is pinned outside this
    /// repository's Solidity — the frontend, the relayer and the ABI tuple
    /// census all decode it field by field, and a tail appended there has
    /// already been lost once. A mapping of its own changes no return type.
    ///
    /// ⚠️ ONLY TWO OF THE FOUR ARE BALANCES, and neither is a balance by itself.
    ///   • `voterShare` is what EACH voter may pull. The money behind it is
    ///     `voterShare × voters who have not pulled yet`, which is why the
    ///     per-voter read `getAppealShareOwed` exists — a sum over voters is
    ///     the balance, this field alone is not.
    ///   • `advanceFromBond` and `advanceFromVault` are NOT money held: they
    ///     are what the appellant was already PAID out of the ruling
    ///     arbiter's bond and out of the bank, and what his forfeited fee
    ///     share still has to give back to them when it arrives.
    ///   • `debt` is owed to the appellant with NOTHING behind it. It is kept
    ///     here and not in `refundableBounty` on purpose: every entry there is
    ///     backed by USDC on the diamond, and `withdrawDisputeBounty` pays it
    ///     out of the diamond's whole balance — booking an unbacked debt there
    ///     would pay the appellant with somebody else's escrow. It moves into
    ///     `refundableBounty` only as real money arrives.
    ///
    /// Four uint64 fill one slot. The bound is structural rather than hoped
    /// for: every amount here is at most one appeal deposit, and a deposit is
    /// capped at APPEAL_DEPOSIT_CAP (200 USDC = 2e8 base units), eleven orders
    /// of magnitude under 2^64.
    ///
    /// `appellant` is the second slot and is written ONLY when a debt is
    /// created. The verdict record also names him, but that record can be
    /// deleted after the deal ends (`clearStuckVerdict`), while a debt can
    /// outlive the deal — it is paid later by the arbiter's top-up or out of
    /// the bank, and whoever pays it needs to know to whom.
    struct AppealLedger {
        uint64 voterShare;
        uint64 advanceFromBond;
        uint64 advanceFromVault;
        uint64 debt;
        address appellant;
    }

    /// The bond one arbiter put down to take one case (22 September 2026):
    /// how much, and whose it is. The field that holds these —
    /// `Data.caseBonds` — carries the whole argument; this declaration sits
    /// here because Solidity does not allow a struct inside a struct.
    ///
    /// One slot. `uint96` cannot truncate: the amount is
    /// `appealDepositFor(deal)`, capped at APPEAL_DEPOSIT_CAP (2e8).
    struct CaseBond {
        uint96  amount;
        address arbiter;
    }

    // ── Appeal pricing, 17 September 2026 ───────────────────────────────────
    //
    // Declared in the LIBRARY, like SUSPENSION_WINDOW above, because two facets
    // apply it: `raiseAppeal` charges it and `quoteAppealDeposit` in
    // ArbiterVaultFacet tells a screen what will be charged. One declaration,
    // one function, so the quote and the charge cannot disagree.

    /// The least an appeal costs: 20 USDC.
    uint256 internal constant APPEAL_DEPOSIT_FLOOR = 20_000_000;
    /// The most an appeal costs: 200 USDC.
    uint256 internal constant APPEAL_DEPOSIT_CAP = 200_000_000;

    /// What an appeal on `agreement` costs right now: the deal's own dispute
    /// fee (`Agreement.disputeFee()`, 3% of the pot with its own ceiling),
    /// held between the floor and the cap — the same "whichever is larger, the
    /// floor or the percentage" shape the boards use for their fee.
    ///
    /// The percentage is READ, not recomputed: a second copy of "3% of amount
    /// plus extras" here would drift from the clone's on the first edit, and
    /// the clone's is the one the fee is actually taken by.
    ///
    /// ⚠️ A CLONE THAT CANNOT ANSWER PAYS THE FLOOR, it is not refused. Clones
    /// are pinned to the implementation they were made from; one made before
    /// `disputeFee()` existed would otherwise have no appeal at all, and a
    /// refused appeal strands nothing but takes away the only check on a
    /// verdict. The response length is checked before decoding for the same
    /// reason as `_softTransfer`: a short reply must not become a panic.
    function appealDepositFor(address agreement) internal view returns (uint256 deposit) {
        deposit = APPEAL_DEPOSIT_FLOOR;
        (bool ok, bytes memory ret) = agreement.staticcall(abi.encodeWithSignature("disputeFee()"));
        if (ok && ret.length >= 32) {
            uint256 fee = abi.decode(ret, (uint256));
            if (fee > deposit) deposit = fee > APPEAL_DEPOSIT_CAP ? APPEAL_DEPOSIT_CAP : fee;
        }
    }

    struct Data {
        mapping(address => bool)     isArbiter;
        address[]                    arbiterList;
        mapping(address => address)  disputeClaims;      // agreement → arbiter
        mapping(address => address[]) arbiterDeals;
        mapping(bytes32 => uint256)  claimCommitments;
        address                      chiefArbiter;
        bool                         daoActiveManual;
        // ── Diamond-as-arbiter + rewards ──
        mapping(address => PendingVerdict) pendingVerdicts;  // agreement → verdict
        mapping(address => uint256)        arbiterRewards;   // arbiter → USDC claimable
        uint256                            rewardPerDispute; // DEAD. The flat payout from the vault was rejected
                                                              // by design on 28.07 (§7) and removed on 31.07; the field
                                                              // stays because the layout is append-only. Never read or write it.
        uint256                            vaultBalance;     // USDC held by Diamond for rewards
        address                            daoAddress;       // future DAO governance contract
        // ── Provisional status ──
        mapping(address => uint256)        arbiterMistakeStreak; // arbiter → consecutive judging mistakes
        // ── Sybil-resistance: forfeitable bond ──
        mapping(address => uint256)        arbiterBond;           // arbiter → locked USDC bond
        mapping(address => uint256)        openClaimCount;        // arbiter → disputes claimed right now and not closed
        // ── Appeal voting ──
        mapping(address => mapping(address => bool)) hasVotedAppeal; // agreement → arbiter → has already voted
        // ── Dispute settlement fee (3% of the disputed amount, computed by Agreement) ──
        // The treasury's share of disputes (20% of the fee). Credited, not transferred
        // at settlement time: a blocked feeRecipient would otherwise break every dispute.
        uint256                            treasurySlice;
        // ── Paid arbiter call ──
        // A top-up to a workable threshold: on a small pot 80% of a 3% fee does
        // not pay for even fifteen minutes of reading, and nobody takes the
        // dispute. The party that needs a judge pays, so no subsidy out of the
        // shared vault — and no farming of such a subsidy — is required.
        mapping(address => uint256)        disputeBounty;      // deal → top-up paid in
        mapping(address => address)        disputeBountyPayer; // deal → who paid it
        uint256                            arbiterFloor;       // what the arbiter must receive in total
        // Soft refund of the top-up: clearDisputeClaim pushes transfer() and, if it
        // did not land (the payer is on the USDC blacklist), does not revert —
        // Agreement calls this function inside an empty try/catch (Agreement.sol,
        // _clearDisputeClaim), and a hard revert here would silently drag the claim
        // release and the openClaimCount decrement down with it. What did not land
        // piles up here and is pulled out through withdrawDisputeBounty().
        mapping(address => uint256)        refundableBounty;   // payer → undelivered refund, pulled by the payer
        // ── Arbiter chat keys (9 August 2026) ──
        // Public halves of the chat keys: encryption (X25519) and signing (Ed25519).
        // They live HERE and not in the relayer directory, by the owner's
        // requirement: arbiters must be governed by the Diamond, not by the owner.
        // The directory sits on a project-run server, and whoever reached that
        // server could slip in a key of their own in place of the arbiter's and
        // read ALL presentations in ALL disputes without giving themselves away.
        // Here the arbiter writes the key with his own transaction — the server
        // stopped being a substitution point, and that is the whole gain.
        //
        // The Diamond owner is still a substitution point: the upgrade right
        // allows deploying a small facet with a function that writes arbiterBoxKey
        // for an arbitrary address, mounting it through diamondCut, rewriting the
        // key, reading the parties' presentations and unmounting the facet again.
        // ArbiterChatKeySet does NOT fire on that path — the parties' apps see no
        // change. Same class and the same order of cost as the already measured
        // bypass of the treasury reserve gate (~31 700 gas, invisible to loupe).
        //
        // The private halves NEVER reach the chain: they are derived from the
        // arbiter's signature and stay on his device. The public half being
        // public is not a leak but a condition of the work: a party takes it to
        // seal a presentation so that only the holder of the private half can
        // open it.
        mapping(address => bytes32)        arbiterBoxKey;   // arbiter → public encryption key
        mapping(address => bytes32)        arbiterSignKey;  // arbiter → public signing key
        // ── When the dispute was claimed (14 August 2026) ──
        // Needed for the floor under a no-response record: the chain rejects "no
        // answer" earlier than NO_RESPONSE_FLOOR after the claim. Counted from
        // here and not from the request: a request travels off chain and its time
        // could be forged, while "claimed in block N" is a settled fact — and it
        // is when a party can first present: before it the arbiter's key is unknown.
        //
        // The key is a PAIR (deal, arbiter). Not "deal → time": otherwise a new
        // arbiter would inherit the old one's time, the floor would already be
        // passed, and a no-response record would go through the same second he
        // claimed the dispute. Keying by the pair removes that structurally and
        // also removes the need to zero the entry on claim release — there are
        // two release sites and a third one (`abandonClaim`) is already planned,
        // where the cleanup would have to be remembered. What is exposed is the
        // anchor of the CURRENT claimer, see getDisputeClaimedAt.
        //
        // ⚠️ Written on EVERY claim by this arbiter, not only on the first one.
        // Owner's decision of 14.08.2026, superseding the earlier "once and for
        // all". The floor must measure the time during which the party had
        // SOMEONE to present to — that is, while the dispute stood with this
        // arbiter. With a "first claim forever" anchor a bribed arbiter claimed
        // the dispute, released it a minute later and came back a day later: the
        // floor is passed, a no-response record goes through at once, while for
        // almost all that time the dispute stood unowned with nobody to present to.
        //
        // The flip side — that re-claiming moves the anchor forward — is not a
        // weapon: moving it forward only DELAYS the record, which hurts the
        // arbiter himself. The order of events is visible not from here but from
        // the DisputeClaimed / DisputeNoResponseRecorded events: storage holds
        // the last claim, the feed holds all of them.
        mapping(address => mapping(address => uint256)) disputeClaimedAtBy;
        // The record "asked for the chat log, got no answer" — the block second.
        // 0 means no record. Same key, the pair (deal, arbiter), but the write
        // rule is DIFFERENT: written ONCE and never erased. An erasable or
        // rewritable record would mean the arbiter is free to move its time —
        // release the dispute, claim it again, record it again — and "when exactly
        // he claimed this" becomes his choice rather than a fact. The anchor has
        // no such freedom: it moves only forward and only to his own detriment.
        mapping(address => mapping(address => uint256)) disputeNoResponseAtBy;
        // ── Presentation digests (14 August 2026) ──
        // Deal → list of 32-byte hashes of the canonical form that a party
        // SIGNS when presenting (canonicalPresentationBytes, the web
        // client's canonical-encoding function).
        //
        // A list and not a single value: a chat log does not fit into one bag,
        // and a dispute carries as many presentations as it needs. The key is the
        // deal, not the pair (deal, party): what is proven is the ORDER, the
        // order is shared by the dispute, and the feed must read in one query.
        // Who put it there is visible from the event — storage needs no copy.
        //
        // The digest is immortal, the chat log is not: the store is swept, the
        // 32 bytes remain. From the same rule comes what is NOT here and must
        // never be — neither deletion nor rewriting: a record that can be taken
        // back proves exactly nothing.
        mapping(address => bytes32[]) presentationDigests;
        // ── Accountability of hand-seated arbiters, 15 August 2026 ──────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: layout is append-only, enforced by a build gate over
        // the struct's fields.

        /// Who seated this arbiter. `address(0)` means self-registration through
        /// applyAsArbiter. Needed for two things at once: to show a reader of the
        /// chain honestly that a hand-seated arbiter has neither a bond nor an XP
        /// gate behind him, and to count the chief arbiter's block.
        mapping(address => address) seatedBy;

        /// How many arbiters seated by THIS seater are sitting right now. Kept by
        /// incrementing on seating and decrementing on any departure — otherwise
        /// the chief's cap is bypassed by a seat-then-remove loop.
        mapping(address => uint256) seatedCountBy;

        /// Until when the arbiter is suspended. Zero means not suspended.
        /// The comparison is always strict: `block.timestamp < suspendedUntil` —
        /// that is, exactly on the boundary the window has already let go.
        mapping(address => uint256) suspendedUntil;

        /// How many of this arbiter's verdicts reached finalization unoverturned.
        /// Owner's decision of 15 August 2026: when governance goes live, sitting
        /// arbiters convert on "bond plus judging record", and there was nothing
        /// to count that record with. Starting the counter later is pointless —
        /// by the time governance goes live everyone would be at zero. The
        /// increment sits in the finalizeVerdict branch that resets arbiterMistakeStreak.
        ///
        /// ⚠️ THIS COUNTER CAN BE FARMED, AND THAT IS KNOWN (16 August 2026).
        /// It is written down here on purpose — the code does not fix it, and
        /// nothing here ever fixed it.
        ///
        /// The path is the one already named undetectable for XP: "own
        /// counterparty". One person with three addresses (client, executor,
        /// arbiter) opens a dust deal for the minimum amount, raises a dispute,
        /// claims it with the third address, judges himself, waits out
        /// FINALIZE_DELAY and finalizes. The verdict is unoverturned — only the
        /// owner could overturn it, and nothing makes such a deal visible to him
        /// — and the record grows by one. The chain is not lying here: the
        /// verdict did reach finalization. It simply does not and cannot know
        /// that all three parties are one person.
        ///
        /// The cost matters more than the mechanics: the counter was started FOR
        /// the conversion of hand-seated arbiters when governance goes live. By
        /// the time that conversion is designed, the chain will already hold
        /// numbers that LOOK like proof of judging skill. Whoever reads them sees
        /// a ready metric with a history and no note about what it does not
        /// prove. This is that note.
        ///
        /// How it could be cured (not now): count the record only over disputes
        /// where both parties hold XP from THIRD parties (the MIN_COUNTERPARTY_XP
        /// device from ReputationFacet), or count by disputed amount rather than
        /// by number, or never let a conversion rest on this number alone.
        ///
        /// ⚠️ AND THIS IS ONLY HALF THE FRACTION (21 August 2026). The record
        /// must not be read without the overturns: a repeating "mistake, mistake,
        /// clean" cycle grows EXACTLY THIS NUMBER while never driving the streak
        /// to its threshold, and from outside such an arbiter looked better than
        /// an honest newcomer. The other half is `overturnedVerdicts`, appended
        /// at the end of this struct; `getArbiterStanding` returns them together.
        mapping(address => uint256) cleanVerdicts;

        /// A chief arbiter's proposal to remove an arbiter (15 August 2026).
        /// Stored under the arbiter's address — one live proposal per person,
        /// and that is right: a charge, not a queue of charges.
        ///
        /// ⚠️ It can no longer be replaced by overwriting (18 August 2026).
        /// A live record occupies the door: proposeRemoval reverts with
        /// ProposalAlreadyLive(by, proposedAt) for everyone who passed the role
        /// check, including whoever laid it (an outsider never reaches this
        /// point: the role refuses earlier, and that is deliberate — "the door
        /// is taken" would on its own tell him that something stands against the
        /// arbiter). A charge can be changed, but through a withdrawal, and then
        /// the reset of the 48-hour clock is visible in the feed
        /// (RemovalProposalWithdrawn) instead of happening silently. Measured:
        /// overwriting gave the chief the right to bury someone else's charge
        /// forever, including a charge against himself.
        ///
        /// It lives for ArbiterAccountabilityFacet.PROPOSAL_TTL, after which it
        /// reads as stale (hasLiveProposal) but is not erased by itself —
        /// erasing is done either by withdrawProposal or by ArbiterRegistryStorage.
        /// clearSeat (ONE point for every door out of the corps, not only a
        /// successful removeArbiterForCause).
        ///
        /// ⚠️ A by-name list of those doors used to stand here, and it lied: the
        /// third one was called "auto-demotion", that is `_recordArbiterMistake`
        /// — and since 18 August 2026 that function takes no seat at all, a
        /// third mistake suspends and accuses. The list was removed rather than
        /// corrected: it went stale on edits inside another function whose diff
        /// never included this line. The current list is in the docstring of
        /// `clearSeat` itself; checked with `grep -rn "clearSeat(" src/`.
        ///
        /// resignAsArbiter additionally REFUSES while a live proposal stands
        /// against the caller (see HasLiveRemovalProposal below) — otherwise a
        /// forewarned arbiter reads the public record and leaves on his own in
        /// one transaction, carrying the whole bond away, and the monetary part
        /// of the punishment is zeroed by the very signal the protocol itself
        /// published.
        mapping(address => RemovalProposal) removalProposals;

        // ── The accused's right of reply (15 August 2026; since 19 August the
        //    reply is accepted while the pause is still running) ──────────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: layout is append-only, enforced by a build gate over
        // the struct's fields.

        /// Digest of the accused arbiter's reply. One per CHARGE, not per person
        /// and not for his whole life: "did he answer what stands against him
        /// right now".
        ///
        /// ⚠️ It is now erased by FOUR doors instead of one (19 August 2026),
        /// and they come in two pairs:
        ///
        ///   • a charge APPEARED — `ArbiterAccountabilityFacet.proposeRemoval`
        ///     (a person accused) and `_recordArbiterMistake` below (the chain
        ///     accused, writing directly past that door);
        ///   • a charge WAS TAKEN BACK — `ArbiterAccountabilityFacet.withdrawProposal`
        ///     (a withdrawal) and the vindication branch in `resolveAppeal`
        ///     below (the panel found the arbiter right).
        ///
        /// A fifth, `clearRemovalRecord` on seating, erased this field before and
        /// erases it now — there it is about the marks of a PAST removal.
        ///
        /// Why one door stopped being enough: a reply became possible for a
        /// SITTING arbiter (design of 17 August 2026), and he passes through none
        /// of the seating doors — he never left. Without the new clears he would
        /// lose the right to answer forever, without ever having been removed.
        ///
        /// ⚠️ A REMOVAL DOES NOT TOUCH THIS FIELD, and that is no omission:
        /// `clearSeat` erases the proposal but not the reply to it — the verdict
        /// must land ON TOP of the objection, not instead of it
        /// (test_AnswerGivenBeforeRemovalSurvivesIt).
        ///
        /// The words themselves are lost nowhere: they live in the
        /// `RemovalAnswered`/`RemovalReplyGiven` logs, while storage answers only
        /// the question about the CURRENT charge.
        mapping(address => bytes32) removalReply;

        /// The moment of removal. ONE OF TWO doors to a reply, not the only one
        /// (19 August 2026): `respondToRemoval` admits either on this mark or on
        /// a live proposal. This is the half that reads "he has already been
        /// removed, the proposal is gone (`clearSeat` took it away) — and he is
        /// still entitled to speak".
        ///
        /// It used to say here that without this field any outsider could answer
        /// a charge that does not exist. One field is no longer enough for that:
        /// the boundary is held by both halves together — zero here AND no live
        /// proposal (`test_StrangerWithNoAccusationStillCannotAnswer`).
        ///
        /// ⚠️ Exactly ONE place writes this field — `_performRemoval` in
        /// `ArbiterAccountabilityFacet`; exactly one erases it —
        /// `clearRemovalRecord` below. Unlike `removalReply` above, it knows
        /// nothing about the doors of accusation.
        mapping(address => uint256) removedAt;

        // ── Permanent record of removals, 16 August 2026 ────────────────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: layout is append-only, enforced by a build gate over
        // the struct's fields.
        //
        // The three fields below are the only ones in this struct that NOTHING
        // erases, and that is a requirement rather than an oversight. The two
        // fields above are erasable, but DIFFERENTLY, and one phrase cannot do:
        //
        //   • removalReply lives no longer than the CURRENT CHARGE — it is erased
        //     by a seating, by every new charge, and by every withdrawal of one;
        //   • removedAt lives until the NEXT SEATING — only clearRemovalRecord
        //     erases it, and it knows nothing about the doors of accusation.
        //
        // ⚠️ This used to say "removedAt/removalReply live exactly until the next
        // seating" — a change on 19 August 2026 made that untrue for the first of
        // them. A follow-up fix replaced it with the common phrase "no longer
        // than the current charge", and that became untrue for the SECOND: one
        // rule over two fields with different lifetimes is wrong in either
        // direction. Hence the split above. The question
        // "how many times was he removed" cannot be answered by an erasable
        // field — the erasing door belongs to the accuser (addArbiter), and once
        // governance is live also to the accused himself (applyAsArbiter).
        //
        // Before this change the only unkillable copy of the history was the
        // events. No subgraph indexes them and no screen reads them: "visible"
        // existed only for someone who manually scans raw logs by an address he
        // already knows.

        /// How many times this arbiter was removed AGAINST HIS WILL — through
        /// both such doors: removal for cause and auto-demotion. resignAsArbiter
        /// does not count here: leaving on one's own is not a removal, and mixing
        /// the two would brand a man who simply stopped.
        mapping(address => uint256) removalCount;

        /// The moment of the LAST removal. Not to be confused with removedAt
        /// above: that one is erased by a re-seating, this one never is.
        mapping(address => uint256) lastRemovalAt;

        /// The cause of the last removal, ENCODED (see REMOVAL_CAUSE_SHIFT and
        /// AUTO_REMOVAL_BASE next to the writing functions): 0 — never removed,
        /// 1..6 — the Cause code plus one, 240..255 — auto-demotion (there is no
        /// cause at all, but the path is named: AUTO_REMOVAL_BASE + DemotionPath).
        /// Between the two, 7..239, is nothing: a code no writer produces, which
        /// a reader must show as unknown rather than guess at.
        ///
        /// The type is uint8 and not the enum: that enum is declared in
        /// ArbiterAccountabilityFacet, and tying a storage layout to a type
        /// from another file would mean that a rename over there moves storage
        /// over here — the same reason why RemovalProposal.cause is a uint8
        /// as well.
        mapping(address => uint8) lastRemovalCause;

        // ── Chain-laid removal proposal (18 August 2026) ────────────────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: the layout is append-only, enforced by a build gate
        // over the struct's fields, and this is the very class of bug
        // that broke the live JobBoard in July 2026.

        /// The demotion path, kept until the removal it will be recorded with.
        ///
        /// It used to be known at the instant of unseating and went straight
        /// into recordAutomaticRemoval. Since 18 August 2026 the unseating moves
        /// two days out — through a proposal laid by the chain and the common
        /// door — while getArbiterStanding must still tell the three paths
        /// apart; that distinction exists on purpose.
        ///
        /// The value is uint8(ArbiterRegistryFacet.DemotionPath) as-is; the
        /// AUTO_REMOVAL_BASE offset is added by recordAutomaticRemoval, as
        /// before. Zero here is MEANINGFUL (DemotionPath.Unspecified), so the
        /// question "is there a chain proposal" is asked of removalProposals
        /// (by == address(0) while proposedAt != 0), never of this field.
        mapping(address => uint8) chainProposalPath;

        // ── Overturned verdicts, cumulative (21 August 2026) ────────────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: the layout is append-only, enforced by a build gate
        // over the struct's fields, and this is the very class of bug
        // that broke the live JobBoard in July 2026.

        /// How many of this arbiter's verdicts have been overturned, counted
        /// over his whole service — the half of the fraction that was missing.
        ///
        /// ⚠️ THIS IS NOT A SECOND `arbiterMistakeStreak`, AND IT IS NOT ITS
        /// REPLACEMENT. That one is a streak of judicial mistakes IN A ROW, and
        /// finalizeVerdict clears it on every clean verdict — which is exactly
        /// how a bad arbiter stayed invisible. "Mistake, mistake, clean" round
        /// and round never reaches MAX_ARBITER_MISTAKES, the automatic path
        /// never fires, and `cleanVerdicts` keeps growing, so the record showed
        /// a man with thirteen overturns as BETTER than an honest newcomer with
        /// none. The streak keeps its meaning; this field answers the other
        /// question, the one nothing answered.
        ///
        /// ⚠️ IT DECIDES NOTHING AND GATES NOTHING (owner's decision of
        /// 21 August 2026). The rungs of the design are "visible →
        /// counted", and this is the second one. No threshold reads it, no
        /// automation fires on it, and no door asks it — deliberately, because
        /// the number that expresses the principle is a FRACTION, not a sum: a
        /// bare total punishes long service, twenty overturns out of five
        /// hundred being a different man from twenty out of twenty-five. The
        /// other half of the fraction is `cleanVerdicts`, and both go out
        /// together through getArbiterStanding so the READER divides.
        ///
        /// ⚠️ WHAT IS COUNTED: the two paths where a verdict actually WAS
        /// overturned — the hand (DemotionPath.OwnerOverturn) and the panel
        /// (DemotionPath.AppealVote). NOT the timeout: nothing was overturned
        /// there because nothing was ruled, and notifyArbiterTimeout says so
        /// itself where it refuses to slash XP. The list is an ALLOW-list in
        /// _recordArbiterMistake, not "everything except the timeout", so a
        /// fourth path added later has to be named before it counts.
        ///
        /// ⚠️ A PANEL THAT VINDICATES TAKES ONE BACK, same as the streak. The
        /// sequence: the arbiter rules, the hand overturns him (+1 here), the
        /// losing side appeals, and the panel flips the ruling back to the
        /// ARBITER'S OWN. In the end his verdict stands, so counting an
        /// overturn against him would be the record lying — the same defect
        /// already fixed one counter over. ONE is subtracted, never the whole
        /// count: overturns on OTHER disputes are his and stay his.
        ///
        /// That subtraction is sound only because "a hand pressed" now implies
        /// "the outcome differs from what the arbiter ruled": overturnVerdict
        /// refuses an empty press with VerdictUnchanged, a guard added on
        /// 21 August 2026. Without that guard a panel DISAGREEING with the
        /// arbiter was recorded as acquitting him.
        ///
        /// ⚠️ One shape survives, and it belongs to the migration rather than
        /// to the design: this count is per ARBITER, so during the window where
        /// pre-cut overturns went unrecorded, a give-back can spend a
        /// post-cut one. Shut today by the corps having one member, and left
        /// open deliberately rather than patched.
        ///
        /// ⚠️ IT IS NOT THE FULL TRUTH ABOUT THE VINDICATED, and that is said
        /// out loud: `cleanVerdicts` does not grow for him either, because
        /// `v.overturned` stays true forever and finalizeVerdict reads that one
        /// flag for two different facts. So a vindicated arbiter
        /// lands back at zero-zero for that dispute rather than at a clean
        /// verdict. Fixing that means splitting the flag, which is a fork in
        /// the design and touches the money paths — not this field's to make.
        mapping(address => uint256) overturnedVerdicts;

        // ── Applications for a seat, 24 August 2026 ─────────────────────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: the layout is append-only, enforced by a build gate
        // over the struct's fields, and this is the very class of bug
        // that broke the live JobBoard in July 2026.
        //
        // Written and read by ArbiterApplicationsFacet only. Nothing in THIS
        // file reads either field, and that is deliberate: the registry is at
        // 95% of the EIP-170 limit, so the door lives in a facet of its own and
        // reaches the corps through the fields it already shares — isArbiter,
        // arbiterList, seatedBy, seatedCountBy, arbiterBond.

        /// One record per address, ever. A new application overwrites the old
        /// one in place; the address is pushed into `arbiterApplicants` below
        /// only the first time, so the public list holds no duplicates.
        mapping(address => ArbiterApplication) arbiterApplications;

        /// Every address that has ever applied, in the order it first did.
        /// Public by the owner's decision of 24 August 2026 — until this
        /// existed there was no way to see the door being pushed at all.
        ///
        /// Append-only and never compacted: a withdrawal or a refusal changes
        /// the RECORD, not the membership of this list. Removing entries would
        /// let an applicant erase his own refusal by re-applying and
        /// withdrawing, which is the opposite of what the list is for.
        address[] arbiterApplicants;

        // ── Handover of the DAO address in two steps, 26 August 2026 ────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: the layout is append-only, enforced by a build gate
        // over the struct's fields, and this is the very class of bug
        // that broke the live JobBoard in July 2026.

        /// The successor NAMED but not yet in office (26 August
        /// 2026). `setDAOAddress` writes here and nothing else; `daoAddress`
        /// above moves only when the named address sends `acceptDAOAddress()`
        /// itself.
        ///
        /// ⚠️ WHAT THE SECOND STEP PROVES IS NOT THAT THE CANDIDATE AGREES.
        /// `daoAddress` is not a person applying for anything — it is the
        /// governance contract or the multisig the owner deploys himself, and
        /// nobody proposes it because until he deploys it, it does not exist.
        /// The confirmation proves the door opens FROM THE INSIDE: a typo
        /// sends no transaction, and neither do lost keys. Before this field,
        /// one wrong letter in one argument meant nobody could ever remove an
        /// arbiter again — the mistake had no way back.
        ///
        /// Cleared on acceptance, so a standing proposal and a seated
        /// successor are never both readable at once.
        address pendingDaoAddress;

        // ── The bank's discount on a dispute top-up, 29 August 2026 ─────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: the layout is append-only, enforced by a build gate
        // over the struct's fields, and this is the very class of bug
        // that broke the live JobBoard in July 2026.
        //
        // By design: the arbiter floor stays at $10 and the party in the
        // dispute still pays the difference, but the arbiter vault takes a
        // fixed amount off that difference. A DISCOUNT, not cover: full cover
        // would make an empty dispute free, and free is what gets opened for
        // no reason.

        /// How much the vault takes off the top-up. Stored and not a constant
        /// for the same reason `arbiterFloor` is stored: the protocol has seen
        /// ZERO disputes in its life, so three dollars is a starting point and
        /// will be moved by the first hundred real deals. Moving it must not
        /// cost a facet replacement.
        ///
        /// Zero here means "never set" and reads back as
        /// DEFAULT_DISPUTE_DISCOUNT — the same shape as `arbiterFloor` /
        /// `getArbiterFloor()`, both applied in ArbiterVaultFacet. The cost of
        /// that shape is named out loud: the owner cannot express "no discount
        /// at all" by writing 0, he writes 1 (a millionth of a dollar). The
        /// alternative — 0 meaning off — would have shipped the cut dead until
        /// a second transaction nobody would remember to send.
        uint256 disputeVaultDiscount;

        /// Per agreement: how much of `disputeBounty` came out of the vault.
        ///
        /// ⚠️ THIS IS THE ANSWER TO "WHO WAITS FOR WHOM". The discount is
        /// promised in `fundDispute` and paid out in `finalizeVerdict`, and
        /// time passes in between. The money is therefore RESERVED at the
        /// promise: `fundDispute` subtracts it from `vaultBalance` there and
        /// then and writes the amount here. Two disputes cannot be promised the
        /// same three dollars, because the second one reads a vault already
        /// short by the first one's share.
        ///
        /// The consequence at payout time is that there is nothing to check:
        /// the arbiter's floor is whole by construction, not by an `if`. A
        /// check at payout would have had a branch where the vault came up
        /// empty and the arbiter got less than the floor by arithmetic here —
        /// that branch does not exist.
        ///
        /// Cleared together with `disputeBounty` on every exit, and on every
        /// exit that does not pay the arbiter this amount goes BACK into
        /// `vaultBalance` while the payer gets back only what the payer paid.
        /// Refunding the whole bounty to the payer would have handed him the
        /// vault's three dollars, and an unclaimed dispute would have become a
        /// way to milk the bank.
        mapping(address => uint256) disputeVaultSubsidy;

        // ── What the diamond tells the treasury, 4 September 2026 ───────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: the layout is append-only, enforced by a build gate
        // over the struct's fields, and this is the very class of bug that
        // broke the live JobBoard in July 2026.
        //
        // Written and read by `TreasuryLinkFacet`, which shares this namespace
        // and this POSITION exactly as `ArbiterAccountabilityFacet` and
        // `ArbiterApplicationsFacet` do. Why they live here rather than in a
        // namespace of their own is argued in the header of that file; the
        // short of it is that everything the treasury already reads off the
        // live diamond — `vaultBalance`, `daoAddress`, `daoActiveManual` — is
        // in this namespace, and splitting one conversation across two would
        // leave the next selector's author guessing which half it belongs to.
        //
        // ⚠️ ZERO IS THE STATE OF A DIAMOND THAT HAS JUST BEEN CUT, and for
        // these five it is a legitimate, silent answer rather than "not set":
        // no vault share, no payroll share, no foundation share, no target. The
        // treasury then ladders everything into the reserve, and money laddered
        // that way is never re-laddered. There is deliberately NO
        // zero-means-default fallback of the kind `getArbiterFloor()` and
        // `getDisputeDiscount()` carry — decision 65 forbids substituting an
        // invented number for one that was never chosen, and decision 69 says
        // in as many words that the payroll share has no value yet. What closes
        // the window instead is the cut carrying `setTreasuryShares` and
        // `setVaultTargetDisputes` in the same transaction.

        /// The pot the arbiter payroll stream is paid into (decision 69).
        /// A SIBLING of `vaultBalance`, not a share of it: the two are spent by
        /// different rules, and this one has no spender at all yet.
        uint256 arbiterPayrollBalance;

        /// The vault's target, as a COUNT OF DISPUTES (decision 60). The dollar
        /// sum is `count × getArbiterFloor()` and is computed on read, so that
        /// the target follows what a dispute actually costs instead of going
        /// stale the way the old treasury's frozen 500 USDC did.
        uint256 vaultTargetDisputes;

        /// The arbiter vault's share of treasury income, in basis points.
        uint256 treasuryVaultBps;

        /// The arbiter payroll stream's share of treasury income, in basis
        /// points. Stays at zero until decision 69's payout exists — a share
        /// above zero fills a pot that has no door.
        uint256 treasuryPayrollBps;

        /// The foundation's share of treasury income, in basis points. The
        /// ceiling over it is frozen in the treasury and drops on the
        /// governance handover; nothing here can lift it.
        uint256 treasuryFoundationBps;

        // ── Appeal economics, 17 September 2026 ─────────────────────────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: the layout is append-only, enforced by a build gate
        // over the struct's fields, and this is the very class of bug that
        // broke the live JobBoard in July 2026.
        //
        // In `Data` and NOT in `PendingVerdict` — see `AppealLedger` for why.

        /// Per agreement: the panel's share per voter, and what the appellant's
        /// refund borrowed from the arbiter's bond, from the bank, and on
        /// credit. See `AppealLedger`.
        mapping(address => AppealLedger) appealLedgers;

        /// Per agreement, per voter: the panel share has been pulled. A
        /// separate flag rather than clearing `hasVotedAppeal`, which is a
        /// public record of who voted and must outlive the payment.
        mapping(address => mapping(address => bool)) appealShareTaken;

        // ── The rest of the appeal economics, 17 September 2026 (second pass) ──
        //
        // All of these are new on this branch together with the two above;
        // none of them is on the chain yet.

        /// Per arbiter: an appeal refund has been advanced out of this seat's
        /// bond at least once since it was last granted. Tells "the bond sagged,
        /// possibly all the way to zero" apart from "no bond was ever posted" —
        /// two different states with two different rights: a sagging seat
        /// finishes the cases it already holds, a seat that never paid does no
        /// arbiter work at all. Cleared when a seat is granted again
        /// (`clearRemovalRecord`), so a fresh seat starts unposted.
        mapping(address => bool) bondDrawnByAppeal;

        /// Per arbiter: the agreements whose won appeal left a debt to the
        /// appellant that this arbiter's bond could not advance. His top-up
        /// pays them first, and so does his resignation, out of the bond it
        /// returns. Entries whose debt was paid some other way are skipped and
        /// the list is emptied once nothing on it is owed.
        mapping(address => address[]) arbiterDebtCases;

        /// Every agreement that has ever carried such a debt, in the order the
        /// debts arose, and the first entry not yet known to be paid. The bank
        /// pays them in this order (`settleAppealDebts`, anyone may press).
        address[] appealDebtQueue;
        uint256   appealDebtQueueHead;

        /// The sum of every appeal debt still owed. The bank's money is spent
        /// on anything else — a dispute top-up discount, a new appeal's advance
        /// — only above this line, so whatever enters the bank while debts
        /// stand is theirs first.
        uint256 appealDebtTotal;

        // ── appended 18 September 2026: the quorum of an appeal became
        //    movable (the owner's decision of the same day) ──
        //
        /// Per agreement: how many votes THIS appeal needs, written when it was
        /// raised. `min(APPEAL_VOTES_CAP, eligible voters)`, never under
        /// APPEAL_VOTES_FLOOR — see the constants in ArbiterRegistryFacet.
        ///
        /// ⚠️ WRITTEN BY NOTHING SINCE 23 SEPTEMBER 2026, when the panel
        /// stopped being drawn from the roster and the bar became the floor
        /// for everybody. Kept because the layout is append-only and because
        /// an appeal raised in the five days between the two rules carries a
        /// three here and is held to it. Every appeal raised from that date
        /// leaves it at zero, and the single reader
        /// (`ArbiterRegistryFacet._appealVotesRequired`) answers
        /// APPEAL_VOTES_FLOOR for a zero. Same shape as `arbiterBond` one
        /// namespace over: a field is retired by having no writer, never by
        /// being taken out.
        ///
        /// ⚠️ A MAPPING OF ITS OWN AND NOT A FIELD OF `PendingVerdict`, for the
        /// reason written out at `AppealLedger` above: `getPendingVerdict()`
        /// returns that struct whole, its shape is pinned outside this
        /// repository's Solidity (the frontend, the relayer and the ABI tuple
        /// census all decode it field by field), and a tail appended there has
        /// already been lost once.
        ///
        /// ⚠️ ZERO MEANS "RAISED BEFORE THIS FIELD EXISTED", not "no votes
        /// needed". The single reader falls back to the flat three those
        /// appeals were raised under. Appended at the end; no field above it
        /// moves.
        mapping(address => uint8) appealVotesRequired;

        // ── appended 20 September 2026: the second condition of the handover —
        //    the corps judges without a hand on its shoulder ──
        //
        // ⚠️ APPENDED AT THE END. Nothing above moves, and no type above
        // changes: this namespace is append-only, enforced by
        // script/check-storage-structs.sh, and a type changed inside an
        // occupied slot is the bug that broke the live JobBoard in July 2026.

        /// Per deal: a GOVERNANCE HAND reached into this dispute. Written by
        /// `overturnVerdict`, `freezeVerdict` and the owner's branch of
        /// `releaseDisputeClaim`; never cleared.
        ///
        /// ⚠️ IT IS STICKY BECAUSE TWO OF THOSE THREE LEAVE NO OTHER TRACE.
        /// `v.overturned` is durable, but `v.frozen` is a LIVE flag: freeze,
        /// unfreeze, let it finalize, and the record is byte-identical to a
        /// verdict nobody ever touched. `releaseDisputeClaim` is worse — it
        /// only fires before a verdict exists, so there is no record to mark at
        /// all, and its event does not even name who pressed. Counting
        /// "clean" off the surviving `PendingVerdict` alone would therefore
        /// report a dispute the owner held frozen for a week as proof that the
        /// corps works without him. That is a miscount in the one direction
        /// that matters: it hands power over on evidence that is not there.
        ///
        /// ⚠️ "GOVERNANCE", NOT "THE OWNER". Two of the three doors are
        /// `onlyOwnerOrDAO`, and a named successor holds them from the moment
        /// he accepts — before `activateDAO()`, not after. Marking only
        /// `msg.sender == owner` would leave the owner a second key that does
        /// not count: name the address, press through it, stay clean. The mark
        /// is therefore made whoever of the two pressed.
        ///
        /// ⚠️ WHAT IT DOES NOT COVER, said out loud: `suspendArbiter` and
        /// `proposeRemoval` are per-ARBITER, not per-dispute. An arbiter judged
        /// while suspended or under a live accusation still counts clean here.
        /// Closing that needs a different shape — every open dispute of his
        /// marked at the moment of the press — and it is not done.
        ///
        /// ⚠️ `resolveAppeal` IS NOT A WRITER, AND THAT IS NOW LOAD-BEARING
        /// (20 September 2026). The appeal PANEL is not a governance hand: it
        /// is three arbiters correcting a fourth, which is the corps working
        /// without the owner rather than instead of him. Since the owner's
        /// decision of that date `finalizeVerdict` tells the two apart by
        /// exactly one thing — `v.overturned` with this mark UNSET means the
        /// panel did it — and a panel overturn leaves the run standing where it
        /// is. Adding a write here from the appeal flow would silently turn
        /// every panel overturn back into a broken run, and no test of the
        /// appeal flow would notice: the number it moves is read three hundred
        /// lines away.
        mapping(address => bool) govTouchedDispute;

        /// How many disputes have been finalized on the arbiter's own verdict
        /// with no governance hand in them, ever. Protocol-wide, one per deal.
        ///
        /// An overturn keeps a dispute out of this total whoever ordered it —
        /// the hand or the appeal panel. The two part ways one field down, at
        /// `cleanDisputeStreak`, and only there: a panel overturn does not GROW
        /// this number and does not break the run, while a hand does both.
        ///
        /// ⚠️ IT IS A RECORD, NOT A CONDITION — changed 20 September 2026.
        /// The handover used to read this number against a floor of twenty, and
        /// the floor was dropped because a TOTAL cannot be made to fall: twenty
        /// clean disputes with nineteen frozen ones in between would clear it,
        /// and the sentence it was supposed to prove is "the corps judges
        /// without a hand on its shoulder", which is about the RECENT past.
        /// `cleanDisputeStreak` below is what the door reads now. This stays
        /// because it answers a different and still useful question — how much
        /// judging has ever happened cleanly here — and because a total is the
        /// only one of the three numbers that a reader can compare across time.
        ///
        /// The per-arbiter half already existed (`cleanVerdicts`), and the sum
        /// of it is NOT this number: `cleanVerdicts` keys on `!v.overturned`
        /// alone, so it counts frozen-then-unfrozen verdicts as clean, and its
        /// own docstring records that it is farmable through the "own
        /// counterparty" path. This one is incremented in the same branch, in
        /// the same call, under the stricter test.
        ///
        /// ⚠️ NEVER GOES DOWN. Unlike `RegistryStorage.liveDeals` this is a
        /// record of what happened, not a picture of now — an overturn a year
        /// later cannot un-happen a dispute that was closed clean.
        uint256 cleanDisputeCount;

        // ── appended 20 September 2026, second pass: the measure changed from
        //    VOLUME to AUTONOMY ──
        //
        // ⚠️ APPENDED AT THE END, like everything above. `cleanDisputeCount`
        // is kept and keeps its type for the same reason: this namespace is
        // append-only (script/check-storage-structs.sh), and dropping a field
        // to make room is the same class of edit as changing one's type.

        /// Disputes finalized on an arbiter's verdict, IN A ROW, with no
        /// governance hand in any of them and no overturn.
        ///
        /// ⚠️ THREE OUTCOMES AT A FINALIZATION, NOT TWO — the owner's decision
        /// of 20 September 2026, and the reason the rule is not "reset on
        /// anything that is not clean":
        ///
        ///   • clean (no hand, no overturn)  → +1, and the arbiter is counted
        ///     in `distinctCleanArbiters` if he has not been yet;
        ///   • a governance hand in this dispute → 0. Earn it again;
        ///   • overturned by the APPEAL PANEL, no hand → UNCHANGED. Neither
        ///     grown nor broken.
        ///
        /// The third outcome is the one that looks wrong and is not. A panel
        /// overturn is three arbiters saying a fourth got it wrong, decided and
        /// executed without the owner in the room — so it is evidence FOR the
        /// sentence this condition is trying to prove ("the court works without
        /// a hand on its shoulder"), not against it. It does not grow the run,
        /// because a mistake is not to the arbiter's credit and the corps has
        /// not shown it can close a dispute cleanly here; it does not break the
        /// run either, because nothing was interfered with. A rule that zeroed
        /// it would make an honest, self-correcting corps LOOK worse than a
        /// corps nobody ever appeals against, and would hand anybody who can
        /// buy one appeal a way to keep the handover shut forever.
        ///
        /// What tells the panel from the hand is `govTouchedDispute`, which
        /// `overturnVerdict` sets and `resolveAppeal` deliberately does not —
        /// see the warning at that field before adding a writer to it.
        ///
        /// ⚠️ WHY A STREAK AND NOT A TOTAL. A total only ever goes up, so
        /// every hand the owner ever put in is forgiven by the next clean
        /// dispute, and the number keeps saying "the corps works on its own"
        /// about a corps he has been steering all year. A streak is the only
        /// shape in which interference COSTS something: it throws away the
        /// evidence already collected, so the protocol has to go and earn it
        /// again without him. That is the sentence the owner asked the system
        /// to be able to say — "you are not needed here" — and a total cannot
        /// say it.
        ///
        /// ⚠️ WHAT RESETS IT IS FINALIZATION, NOT THE PRESS. The hand is
        /// recorded when it reaches in (`govTouchedDispute`) and read when the
        /// dispute ENDS. A dispute frozen today and finalized in a month zeroes
        /// the streak in a month, not today. That is deliberate: the streak
        /// counts finished disputes, so a dispute that has not finished yet has
        /// nothing to say about it either way.
        ///
        /// ⚠️ WHAT IT DOES NOT COUNT, said out loud. A dispute that ends by
        /// `triggerArbiterTimeout` — nobody judged it, the pot was split —
        /// never reaches `finalizeVerdict` and therefore neither grows this
        /// number nor breaks it. A corps that lets a hundred disputes time out
        /// and judges eight cleanly still clears the floor. Closing that needs
        /// a term this condition does not have (a RATE, which needs a
        /// denominator nothing counts today) and it is written down rather than
        /// quietly fixed.
        uint256 cleanDisputeStreak;

        /// Has this arbiter ever taken a dispute to a clean finalization? One
        /// bit per arbiter, set on his FIRST clean one and never cleared.
        ///
        /// Exists so that `distinctCleanArbiters` below counts men and not
        /// disputes: without it, one arbiter closing eight disputes would read
        /// as a corps of eight.
        ///
        /// ⚠️ NEVER CLEARED, not even when the seat is. A removed arbiter's
        /// clean work still happened, and clearing the bit on removal would let
        /// the same man be counted twice by being re-seated — the farm this
        /// mapping exists to close.
        mapping(address => bool) countedCleanArbiter;

        /// How many DIFFERENT arbiters have taken at least one dispute to a
        /// clean finalization. Grows only on an arbiter's first one.
        ///
        /// ⚠️ THE TERM THAT KEEPS "THE COURT" FROM BEING ONE MAN. The streak
        /// above is blind to who earned it: eight clean disputes judged by a
        /// single friendly address look exactly like eight judged by a corps.
        /// Handing governance over on that evidence would hand it to whoever
        /// holds that one seat.
        ///
        /// ⚠️ IT RATCHETS, and that is the honest shape: "three different
        /// people have judged cleanly here" is a fact about history, and unlike
        /// the streak it is not a claim about the present. The present tense is
        /// carried by the other two terms.
        uint256 distinctCleanArbiters;

        // ── appended 21 September 2026: an arbiter answers for a SHARE of his
        //    recent work, not for a run of blunders ──
        //
        // ⚠️ APPENDED AT THE END. Nothing above moves, and no type above
        // changes: this namespace is append-only, enforced by
        // script/check-storage-structs.sh, and a type changed inside an
        // occupied slot is the bug that broke the live JobBoard in July 2026.

        /// Per arbiter: his last six closed cases and his two lifetime totals,
        /// packed into one word. The layout is written out at OUTCOME_MASK
        /// above; the only writer is `recordClosedCase` and the only readers
        /// are `outcomeRecord` and that same writer.
        ///
        /// ⚠️ IT IS WRITTEN AT FINALIZATION AND NOWHERE ELSE, which is the
        /// whole definition of "a closed case": this arbiter's verdict reached
        /// `finalizeVerdict`, cleanly or overturned. A dispute that timed out
        /// or was abandoned never gets here — nothing was judged, so there is
        /// no verdict to hold him to, and counting one would hand him a way to
        /// dilute the fraction with cases nobody ever ruled on.
        ///
        /// ⚠️ NEVER CLEARED, not by a removal and not by a re-seating. The
        /// lifetime halves are a record of what happened; the six-bit window
        /// empties by itself as new cases push the old ones out, which is the
        /// only forgiveness the design offers and the only one it should.
        mapping(address => uint256) verdictOutcomes;

        /// Per deal: the appeal panel restored THIS arbiter's own ruling after
        /// a hand had overturned it. Written once, in the vindication branch of
        /// `resolveAppeal`, and read once, by `finalizeVerdict`.
        ///
        /// ⚠️ IT EXISTS BECAUSE `v.overturned` ANSWERS TWO QUESTIONS WITH ONE
        /// BIT, and the second trigger made that ambiguity expensive. After a
        /// vindication the flag stays true forever — `resolveAppeal` sets it
        /// while flipping the outcome back to what the arbiter ruled — so
        /// `finalizeVerdict` reading it alone would file a case the panel just
        /// decided in his favour as an overturn against him. `cleanVerdicts`
        /// has always miscounted that case and says so in its own docstring;
        /// there the cost was a card reading one low. Here the cost is a
        /// suspension and an accusation from the chain, laid for the one thing
        /// three of his colleagues had just cleared him of.
        ///
        /// ⚠️ NOT A FIELD OF `PendingVerdict`, deliberately. That struct is
        /// returned whole by `getPendingVerdict()` and decoded field by field
        /// outside this repository (the web client, the relayer, the ABI tuple
        /// census); a tail appended there has been lost once already. A mapping
        /// here costs one slot per vindicated deal and breaks nothing.
        ///
        /// ⚠️ IT DOES NOT TOUCH `cleanVerdicts`, and that is left alone on
        /// purpose: changing what that counter means is a separate decision
        /// with its own readers, and this branch is about the trigger only.
        mapping(address => bool) verdictVindicated;

        // ── The seat stops being hostage money, 22 September 2026 ───────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: the layout is append-only, enforced by a build gate
        // over the struct's fields, and this is the very class of bug that
        // broke the live JobBoard in July 2026.
        //
        // The owner's decision: a bond is no longer posted to HOLD A SEAT and
        // left lying there against a dispute that may never come. It is posted
        // when the arbiter TAKES A CASE and taken home when his verdict has
        // stood. `arbiterBond` above is therefore written by nothing from this
        // day on; it is not deleted, because this layout is append-only, and
        // the four live seats that carried 50 USDC in it were paid back by the
        // cut's own initialiser, and every read of it answers zero now.

        /// Per DEAL: what the arbiter holding it put down to take it, and who
        /// put it down.
        ///
        /// Keyed by the deal and NOT by the arbiter, because that is what the
        /// money is about: one case, one bond, sized to that case's own stake.
        /// The size is `appealDepositFor(deal)` — the very function that prices
        /// an appeal on the same deal, called and not copied, so that "the bond
        /// covers exactly one refund to the appellant" is one subtraction
        /// rather than two rules promising to agree.
        ///
        /// The poster is carried BESIDE the amount instead of being read back
        /// off `disputeClaims[deal]` or `pendingVerdicts[deal].arbiter`. Both
        /// of those are erased on paths this record has to outlive —
        /// `clearDisputeClaim` empties the first inside the very finalization
        /// that returns the bond, and `clearStuckVerdict` deletes the second —
        /// so reading the owner of the money off either would make the refund
        /// depend on the order of somebody else's cleanup. One slot holds both:
        /// a deposit is capped at APPEAL_DEPOSIT_CAP (2e8), twenty orders of
        /// magnitude under 2^96. The struct itself is declared beside
        /// `AppealLedger` above — Solidity has no struct inside a struct.
        mapping(address => CaseBond) caseBonds;

        /// How many cases this arbiter is JUDGING right now. Capped at
        /// `caseSlotsFor(d, him)` — MAX_CASES_AT_ONCE (three) once three clean
        /// verdicts of his have stood, and one until then.
        ///
        /// ⚠️ NOT `openClaimCount`, AND THE TWO MUST NOT BE MERGED. They are
        /// released at different moments on purpose:
        ///
        ///   • this one is released by the SIGNATURE OF THE VERDICT — the work
        ///     is done, the arbiter should not have to sit out the finalization
        ///     delay and the appeal window before he may take the next case;
        ///   • `openClaimCount` is released when the deal lets go of him, and
        ///     it is what guards the exit from the corps (`resignAsArbiter`).
        ///
        /// Releasing the exit guard on the signature instead would let an
        /// arbiter sign a verdict, resign, and walk out with the deal's bond
        /// before the panel had a chance to overturn him — which is the one
        /// thing the bond exists to make impossible.
        mapping(address => uint256) judgingCount;

        // ── The arbiter payroll pot gets a door, 25 September 2026 ──────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: the layout is append-only, enforced by
        // script/check-storage-structs.sh, and a type changed inside an
        // occupied slot is the bug that broke the live JobBoard in July 2026.
        //
        // Mainnet item D3, and decision 73's shape at last. `arbiterPayrollBalance`
        // above has had an inlet since 4 September 2026 — a fifth of every
        // treasury distribution — and no outlet at all. These five fields are
        // the outlet: they cut the one running balance into PERIODS, so that a
        // period's money is divided by the work done inside that same period.
        //
        // ⚠️ WHY PERIODS AND NOT ONE RUNNING BALANCE. A single pot divided by
        // lifetime case counts pays the wrong people twice over: a newcomer's
        // first case dilutes every case closed before it, and a veteran with a
        // long count goes on drawing from money that arrived years after his
        // last hearing. Neither is "payment for work already done", which is
        // what decision 69 said the stream was for. A period is the smallest
        // shape in which the two sides of the fraction are about the same
        // stretch of time.
        //
        // ⚠️ THE INDEX IS ABSOLUTE — `block.timestamp / PAYROLL_PERIOD` — and
        // there is deliberately NO anchor field recording when period zero
        // began. An anchor is one more thing a cut can fail to set, and a
        // diamond that answered zero for it would put every period's money in
        // period 0x0 forever. An absolute index cannot be unset, cannot drift,
        // and survives any number of upgrades: the same second of wall clock
        // always names the same period, whoever is asking.

        /// Period → USDC frozen to that period. Grows only while the period is
        /// the current one (`fundArbiterPayroll` credits the period it is
        /// called in) and never moves afterwards, so a share computed from it
        /// cannot change under a claimant who waited.
        mapping(uint256 => uint256) payrollPeriodPot;

        /// Period → how much of that pot has left it, by a booked share or by
        /// the remainder door. The period's own ledger, and the reason
        /// `payrollPeriodPot` can stay frozen: the identity
        /// `arbiterPayrollBalance == Σ(pot − booked)` is what
        /// test/DiamondLedgerIdentity.t.sol holds the two to.
        mapping(uint256 => uint256) payrollPeriodBooked;

        /// Period → closed cases counted for it, protocol-wide. The
        /// DENOMINATOR of every share in that period.
        ///
        /// ⚠️ ONLY WORK THAT STOOD IS COUNTED. The single writer is
        /// `creditPayrollCase`, called from `finalizeVerdict` on the same
        /// `!countAsOverturn` branch that `recordClosedCase` is told — so a
        /// verdict the appeal panel threw out is not work here either. There is
        /// no second bookkeeping and no second definition of "a closed case":
        /// one flag, computed once, read by both.
        mapping(uint256 => uint256) payrollPeriodCases;

        /// Period → arbiter → his own closed cases in it. The NUMERATOR.
        mapping(uint256 => mapping(address => uint256)) payrollPeriodCasesBy;

        /// Period → arbiter → his share has been booked. A flag and not a
        /// "casesBy = 0" erasure: the case count is the public record of who
        /// judged what in that period and must outlive the payment, exactly as
        /// `appealShareTaken` is kept apart from `hasVotedAppeal` above.
        mapping(uint256 => mapping(address => bool)) payrollShareBooked;

        // ── A ceiling on the hand's own suspensions, 8 October 2026 ─────────
        //
        // ⚠️ APPENDED AT THE END. Do not touch the order or the types of the
        // fields above: this namespace is append-only, enforced by
        // script/check-storage-structs.sh, and a type changed inside an
        // occupied slot is the bug that broke the live JobBoard in July 2026.
        //
        // Two fields and not one: the count alone cannot say whether it is
        // still current, and a count that never expires would end the lever
        // for good at the third press. The pair is read and written in exactly
        // one place, `ArbiterAccountabilityFacet.suspendArbiter`.

        /// Per arbiter: how many times a HUMAN HAND has suspended him in the
        /// current run. Counted by `suspendArbiter` and by nothing else — the
        /// automatic path writes `suspendedUntil` directly and is not counted
        /// here, on purpose (see `HAND_SUSPENSION_LIMIT`).
        ///
        /// ⚠️ `liftSuspension` DOES NOT CLEAR IT, and that is load-bearing.
        /// A lift that gave the press back would make the ceiling cost
        /// nothing: press, lift, press, lift, for ever. What gives the press
        /// back is a week of silence and nothing else.
        mapping(address => uint256) handSuspensions;

        /// Per arbiter: when the last HAND-PRESSED suspension landed. The
        /// clock the reset is measured from, so the reset is by silence rather
        /// than by a calendar bucket somebody can stand on the edge of.
        ///
        /// Zero means no hand has ever pressed at this man, which is also what
        /// a fresh seat reads — and that is right: the count it is paired with
        /// is zero too, so nothing can be reset wrongly.
        mapping(address => uint256) lastHandSuspensionAt;
    }

    /// Files one CLOSED case against `arbiter` and answers whether the overturn
    /// rate has just become something the chain must act on.
    ///
    /// ⚠️ THE ANSWER IS AN EDGE, NOT THE STATE. The state — "two of the last
    /// six, with at least four closed" — can hold for several cases in a row,
    /// and re-accusing on every one of them would mean a CLEAN verdict laying a
    /// fresh accusation against the man who just delivered it. So the trip
    /// fires on exactly two transitions:
    ///
    ///   • this case is itself an overturn and the state holds — a new mistake
    ///     while the rate already stands says it again, and must;
    ///   • this case is the one that reaches OUTCOME_MIN_SAMPLE while the
    ///     window already holds the overturns — the measure has only now become
    ///     applicable, and this is the first honest moment to apply it.
    ///
    /// The second condition reads `closed == OUTCOME_MIN_SAMPLE` rather than
    /// "the state did not hold before", and the two are the same thing here: a
    /// clean case can only ever shift an overturn OUT of the window, so if the
    /// state holds after a clean case it held before it too, and the only way
    /// to enter the state on a clean case is by crossing the sample floor.
    ///
    /// ⚠️ WHAT IT DOES NOT DO: it does not clear the window on a trip. The six
    /// bits are a record of the last six cases and stay true whatever the chain
    /// decides to do about them. Clearing them would let an arbiter buy a fresh
    /// slate with the very accusation he was just given.
    function recordClosedCase(Data storage d, address arbiter, bool overturned)
        internal
        returns (bool trips)
    {
        uint256 packed = d.verdictOutcomes[arbiter];
        // The shift-in. `packed << 1` also moves the count fields, and the mask
        // throws every one of those bits away — the oldest case falls off the
        // top of the window in the same operation.
        uint256 window = ((packed << 1) | (overturned ? 1 : 0)) & OUTCOME_MASK;
        uint256 closed = ((packed >> OUTCOME_CLOSED_SHIFT) & OUTCOME_COUNT_MASK) + 1;
        uint256 turned = ((packed >> OUTCOME_TURNED_SHIFT) & OUTCOME_COUNT_MASK)
            + (overturned ? 1 : 0);
        d.verdictOutcomes[arbiter] =
            window
            | (closed << OUTCOME_CLOSED_SHIFT)
            | (turned << OUTCOME_TURNED_SHIFT);

        if (closed < OUTCOME_MIN_SAMPLE) return false;
        if (_windowOverturns(window) < OUTCOME_OVERTURN_LIMIT) return false;
        return overturned || closed == OUTCOME_MIN_SAMPLE;
    }

    /// The whole public record of an arbiter's closed cases, in one read.
    /// `sample` is how much of the window is actually filled — the denominator
    /// a reader must divide `turnedInWindow` by, and never OUTCOME_WINDOW,
    /// which would report two out of six for a man who has closed four.
    function outcomeRecord(Data storage d, address arbiter)
        internal
        view
        returns (uint256 closed, uint256 turned, uint256 sample, uint256 turnedInWindow)
    {
        uint256 packed = d.verdictOutcomes[arbiter];
        closed = (packed >> OUTCOME_CLOSED_SHIFT) & OUTCOME_COUNT_MASK;
        turned = (packed >> OUTCOME_TURNED_SHIFT) & OUTCOME_COUNT_MASK;
        sample = closed < OUTCOME_WINDOW ? closed : OUTCOME_WINDOW;
        turnedInWindow = _windowOverturns(packed & OUTCOME_MASK);
    }

    /// Set bits in the six-bit window. A loop and not a lookup table: six
    /// iterations of three opcodes beat a table this facet has no room for.
    function _windowOverturns(uint256 window) private pure returns (uint256 n) {
        while (window != 0) {
            n += window & 1;
            window >>= 1;
        }
    }

    // ── The payroll period, in one place (25 September 2026) ────────────

    /// Which payroll period a moment of wall clock belongs to.
    ///
    /// A pure function of the timestamp and of PAYROLL_PERIOD, with no storage
    /// read at all, so the answer cannot depend on what a cut remembered to
    /// set. The index is absolute: period 58 is the same thirty days for every
    /// caller, in every facet, before and after any upgrade.
    function payrollPeriodOf(uint256 at) internal pure returns (uint256) {
        return at / PAYROLL_PERIOD;
    }

    /// The period a transaction landing right now belongs to.
    function currentPayrollPeriod() internal view returns (uint256) {
        return payrollPeriodOf(block.timestamp);
    }

    /// The first moment anybody may push a closed period's unclaimed remainder
    /// out to the foundation: the period's own end plus the claim window.
    ///
    /// ⚠️ MEASURED FROM THE PERIOD'S END AND NOT FROM ITS START. From the start
    /// the window would already be a month old the day the period closed, and
    /// an arbiter who judged on the last day of it would get thirty days less
    /// to come than one who judged on the first.
    ///
    /// ⚠️ IT SATURATES, AND THAT IS NOT DEFENSIVENESS FOR ITS OWN SAKE. The
    /// multiplication below overflows for an absurd `period`, and the first
    /// version of this function let it: the remainder door answered `Panic(0x11)`
    /// on a garbage argument instead of a refusal anybody could read. Caught by
    /// the scene that feeds it rubbish, not by review. A period beyond the
    /// ceiling is one no clock will ever reach, so "never sweepable" is both the
    /// safe answer and the true one, and the door turns it into
    /// `PayrollPeriodNotLapsed` — a refusal with a name on it.
    function payrollSweepableAt(uint256 period) internal pure returns (uint256) {
        if (period >= PAYROLL_PERIOD_CEILING) return type(uint256).max;
        return (period + 1) * PAYROLL_PERIOD + PAYROLL_CLAIM_WINDOW;
    }

    /// Files one case that STOOD against the period it finalized in — both
    /// halves of the fraction, in one call, so the two can never be written by
    /// different rules.
    ///
    /// ⚠️ THE ONLY CALLER IS `finalizeVerdict`, ON ITS `!countAsOverturn`
    /// BRANCH, and that is the whole definition of the work this pot pays for.
    /// A dispute that timed out or was abandoned never reaches that function,
    /// so it enters neither half — nothing was judged, and a period whose
    /// denominator counted unjudged disputes would pay its arbiters a fraction
    /// of what they earned. A verdict the appeal panel threw out does reach it
    /// and is deliberately NOT counted: paying for a ruling three colleagues
    /// had to undo is paying for the defect.
    ///
    /// ⚠️ THE PERIOD IS THE ONE FINALIZATION LANDS IN, not the one the dispute
    /// was opened or claimed in. The money the pot holds arrived from fees
    /// collected over the period too, and both sides of the fraction have to be
    /// about the same stretch of time or the division means nothing. It also
    /// makes the number unforgeable in the one direction that matters: nobody
    /// can move a case into a richer period after the fact, because the only
    /// timestamp read is the block's own.
    function creditPayrollCase(Data storage d, address arbiter) internal {
        uint256 period = payrollPeriodOf(block.timestamp);
        d.payrollPeriodCases[period] += 1;
        d.payrollPeriodCasesBy[period][arbiter] += 1;
    }

    /// What a press of the payroll door would book for `arbiter` out of
    /// `period` — and zero for every reason a press would refuse.
    ///
    /// The quote and the door read THE SAME function, so a screen that offers
    /// no button at zero cannot be offering one the chain will reject.
    function payrollShareOf(Data storage d, uint256 period, address arbiter)
        internal
        view
        returns (uint256)
    {
        if (d.payrollShareBooked[period][arbiter]) return 0;
        uint256 cases = d.payrollPeriodCases[period];
        if (cases == 0) return 0;
        uint256 mine = d.payrollPeriodCasesBy[period][arbiter];
        if (mine == 0) return 0;

        // ⚠️ A SETTLED PERIOD PAYS NOBODY, AND THIS LINE IS NOT DECORATION. The
        // remainder door settles a lapsed period by writing `booked = pot`,
        // WITHOUT clearing anybody's case record — the record is public history
        // and must outlive the money. So an arbiter who never came for his share
        // still has `payrollShareBooked` false afterwards, and without this test
        // the fraction below would hand him a share out of a period that no
        // longer holds one — taken, by the subtraction in `bookPayrollShare`,
        // out of OTHER periods' money. Found by the scene that presses a booking
        // after a sweep (`test_TheUnclaimedRemainder…`), not by reading.
        uint256 pot = d.payrollPeriodPot[period];
        if (d.payrollPeriodBooked[period] >= pot) return 0;

        // ⚠️ NO CAP AGAINST WHAT IS LEFT, AND IT IS SAFE WITHOUT ONE. With the
        // case counts frozen (nothing can be credited into a period that has
        // ended) the shares of one period sum to at most its pot: floor division
        // only ever rounds down, and every man's numerator is part of the same
        // denominator. So while ANY of the pot is left, this arbiter's share fits
        // inside it. A cap here would be an unreachable line, and an unreachable
        // line is where a future bug hides instead of showing itself.
        return pot * mine / cases;
    }

    /// What `arbiter` still owes appellants across his debt cases.
    function arbiterDebtOf(Data storage d, address arbiter) internal view returns (uint256 total) {
        address[] storage cases = d.arbiterDebtCases[arbiter];
        uint256 n = cases.length;
        for (uint256 i = 0; i < n; i++) total += d.appealLedgers[cases[i]].debt;
    }

    /// Pays `arbiter`'s appeal debts, oldest first, out of money he is putting
    /// in or taking out right now, up to `budget`. Called by the two bond
    /// doors (a top-up pays his debts before it tops the bond up) and by
    /// `resignAsArbiter` (the bond he takes home pays them first).
    ///
    /// The payment is booked the way an advance out of the bond is booked —
    /// the debt shrinks and `advanceFromBond` grows by the same amount — so a
    /// forfeited fee share that arrives later gives it back to the bond exactly
    /// as it would have given back an advance made at `resolveAppeal`. The
    /// appellant is paid into `refundableBounty`: the money is on the diamond
    /// the moment this runs (the caller has just taken it in, or is about to
    /// hand it out), so the booking is backed.
    ///
    /// The list is emptied only when nothing on it is owed any more.
    function payArbiterDebts(Data storage d, address arbiter, uint256 budget)
        internal returns (uint256 paid)
    {
        address[] storage cases = d.arbiterDebtCases[arbiter];
        uint256 n = cases.length;
        bool cleared = true;
        for (uint256 i = 0; i < n; i++) {
            address agreement = cases[i];
            AppealLedger storage l = d.appealLedgers[agreement];
            uint256 debt = l.debt;
            if (debt == 0) continue;
            uint256 pay = budget - paid;
            if (pay > debt) pay = debt;
            if (pay == 0) { cleared = false; break; }
            // uint64 cannot truncate: debt + advances never exceed one deposit.
            l.debt = uint64(debt - pay);
            l.advanceFromBond = uint64(l.advanceFromBond + pay);
            d.refundableBounty[l.appellant] += pay;
            paid += pay;
            emit ArbiterRegistryFacet.DisputeBountyRefundable(agreement, l.appellant, pay);
            if (pay < debt) { cleared = false; break; }
        }
        if (paid != 0) d.appealDebtTotal -= paid;
        if (cleared) delete d.arbiterDebtCases[arbiter];
    }

    /// The bank above the appeal debts it owes — the only part of it any other
    /// spend may touch.
    function bankAboveDebts(Data storage d) internal view returns (uint256) {
        uint256 bank = d.vaultBalance;
        uint256 owed = d.appealDebtTotal;
        return bank > owed ? bank - owed : 0;
    }

    // ── How many cases one man reads at once ──────────────────────────
    //
    /// THREE, AND FOR A NEWCOMER ONE (owner's decision, 22 September 2026).
    ///
    /// The cap used to be a flat one, and it was set while a seat cost 50 USDC
    /// and a case cost nothing: grabbing a handful of disputes and ruling on
    /// them by coin toss was free, so the only thing that could stop it was a
    /// number. Since the bond moved ONTO THE CASE, a handful costs a handful of
    /// bonds, each of them forfeitable to the appellant of that same case. The
    /// price is now proportional to the grab, and the number no longer has to
    /// do that work alone.
    ///
    /// What the number still has to do is stop a man who has shown NOTHING from
    /// taking an armful on his first day. So the full three are earned, and what
    /// earns them is the same thing the corps measures judicial service by.
    ///
    /// ⚠️ ONE LITERAL FOR TWO ROLES, AND THAT IS DELIBERATE. Three cases at
    /// once, and three clean verdicts to be trusted with three: a second copy of
    /// the number is a second rule that agrees today and drifts on the first
    /// edit, and the half that drifted would be the half that lets somebody in.
    /// If the two ever have to part company, they part with an argument and a
    /// second named constant, not by accident.
    ///
    /// ⚠️ IT DOES NOT REPLACE `MAX_CLAIMS_PER_ARBITER`. This one is released
    /// by `submitVerdict`, that one by the deal letting go of him — see
    /// `Data.judgingCount`.
    uint256 internal constant MAX_CASES_AT_ONCE = 3;

    /// How many cases THIS man may hold at once.
    ///
    /// ⚠️ THE SIGNAL IS `cleanVerdicts`, the same field the corps already
    /// counts judicial service by — `getCleanVerdicts`, the appeal panel's
    /// "has he carried one case of his own" test, and the denominator of the
    /// overturn rate all read it. A counter of its own for this rule would be a
    /// second answer to the question "what has he done as a judge", and the two
    /// would disagree the first time one of them moved.
    ///
    /// It counts verdicts that STOOD: `finalizeVerdict` increments it on the
    /// branch where the verdict was not overturned. So the three that buy the
    /// third slot cannot be three wrong ones, and they cannot be bought at all.
    function caseSlotsFor(Data storage d, address who) internal view returns (uint256) {
        return d.cleanVerdicts[who] >= MAX_CASES_AT_ONCE ? MAX_CASES_AT_ONCE : 1;
    }

    function data() internal pure returns (Data storage d) {
        bytes32 pos = POSITION;
        assembly { d.slot := pos }
    }

    /// Clears the provenance and decrements the seater's counter. Lives in the
    /// LIBRARY rather than in a facet because it is called from ALL doors out of
    /// the corps, and those sit in different files. Three copies would drift
    /// apart on the first edit.
    ///
    /// ⚠️ THE SET OF CALLERS CHANGED ON 18 August 2026, and the old list here
    /// became untrue. It was: `resignAsArbiter`, `_recordArbiterMistake`
    /// (auto-demotion) and `removeArbiterForCause`. It is now TWO callers:
    ///
    ///   • `ArbiterRegistryFacet.resignAsArbiter` — leaving of one's own will;
    ///   • `ArbiterAccountabilityFacet._performRemoval` — the shared body of a
    ///     removal, and through it BOTH removal doors: `removeArbiterForCause`
    ///     (a person accused, a person executed) and `executeChainRemoval` (the
    ///     chain accused, anyone pressed the button).
    ///
    /// `_recordArbiterMistake` no longer comes here at all: a third mistake
    /// does not free the seat — the chain only accuses.
    ///
    /// ⚠️ It also erases `removalProposals[arbiterAddr]` (found in review,
    /// 15 August 2026). Before that fix the delete stood ONLY in
    /// removeArbiterForCause — a man who left through resignAsArbiter or was
    /// taken out on the automatic path carried a live proposal away with him:
    /// hasLiveProposal would keep answering true for up to two weeks against an
    /// arbiter who is no longer there and cannot clear the record about
    /// himself. Centralizing here means one point for all exit doors instead
    /// of a copy of the same line in each.
    function clearSeat(Data storage d, address arbiterAddr) internal {
        address seater = d.seatedBy[arbiterAddr];
        if (seater != address(0) && d.seatedCountBy[seater] > 0) {
            d.seatedCountBy[seater]--;
        }
        delete d.seatedBy[arbiterAddr];
        delete d.removalProposals[arbiterAddr];
        // The saved demotion path belongs to the proposal being erased on the
        // line above, and outlives it nowhere: leaving it behind would let a
        // later, unrelated chain accusation inherit the path of an older one.
        // Same argument as the delete above it, same single point for all
        // three exit doors (18 August 2026).
        delete d.chainProposalPath[arbiterAddr];
    }

    /// Shifts the cause code by one. The owner of this encoding is this library
    /// and only it: both facets write through recordRemovalForCause /
    /// recordAutomaticRemoval and do no arithmetic at all. The shift is
    /// mandatory because zero in lastRemovalCause must mean "never removed",
    /// while Cause.OverturnedVerdicts == 0 — without the shift the most common
    /// cause of all would be indistinguishable from emptiness.
    uint8 internal constant REMOVAL_CAUSE_SHIFT = 1;

    /// The START of the auto-demotion range. The automatic path has no cause:
    /// the chain removed the arbiter over a streak of mistakes, not on anyone's
    /// accusation, and the record must say so plainly rather than pose as cause
    /// number zero. The range sits at the far end so no future Cause reaches it.
    ///
    /// ⚠️ This is a BASE, not a single value (16 August 2026). Automatic
    /// removal has several paths, and ArbiterRegistryFacet.DemotionPath
    /// already tells them apart — but only in the event feed, that is, exactly
    /// where nobody reads. The getArbiterStanding card is the only readable
    /// place, and one shared code would lose in it a distinction that was
    /// introduced there on purpose.
    ///
    /// Encoding: `AUTO_REMOVAL_BASE + uint8(DemotionPath)`, that is
    ///   240 — Unspecified (the path is not named; no caller sends it),
    ///   241 — OwnerOverturn, 242 — AgreementTimeout, 243 — AppealVote,
    ///   244 — ClaimAbandoned.
    /// The range is 240..255: SIXTEEN places, five of them taken today.
    ///
    /// ⚠️ THE BASE WAS 252 AND THE PROMISE IT CARRIED WAS BROKEN (moved to 240
    /// on 18 September 2026). The old text here said "a fifth one cannot be
    /// added silently" — and on 18 September 2026 a fifth one
    /// (DemotionPath.ClaimAbandoned, value 4) was added silently, in the same
    /// hour, by the same hands that read this paragraph. 252 + 4 is 256, which
    /// a uint8 does not hold: recordAutomaticRemoval below would have stopped
    /// with Panic 0x11, and stopped executeChainRemoval with it. An arbiter
    /// whose third mistake in a row was booked by abandonClaim could never have
    /// been unseated by the chain at all, and his bond would have stayed frozen
    /// under a charge nobody could execute. Nothing on the chain had recorded a
    /// cause yet, so moving the base re-meant no record that exists — a freedom
    /// this constant will NOT have again once the first automatic removal is
    /// written down.
    ///
    /// ⚠️ A DOCSTRING IS NOT A LOCK, AND THAT IS THE ACTUAL LESSON. The warning
    /// above was correct, prominent and ignored, because nothing went red. What
    /// replaces it is test/ArbiterDemotionPathCodes.t.sol, which does not
    /// reason about the arithmetic: it walks EVERY member of DemotionPath —
    /// the enum itself, through `type(DemotionPath).max`, so a member added
    /// tomorrow is walked without anyone remembering to add it — pushes each
    /// one through this very function, and reads the card back. A path that
    /// does not fit stops that sweep with the same Panic the live door would
    /// have hit, by name and with the number printed.
    ///
    /// So: a new path may be added freely while the range has room, and the day
    /// it has none the sweep goes red BEFORE the chain does. What must not
    /// happen is this constant moving UPWARD, or a path being added past the
    /// ceiling, on the strength of a comment nobody had to satisfy.
    uint8 internal constant AUTO_REMOVAL_BASE = 240;

    /// Removal for cause. `rawCause` is the numeric value of
    /// ArbiterAccountabilityFacet.Cause as-is; the library applies the shift.
    function recordRemovalForCause(Data storage d, address arbiterAddr, uint8 rawCause) internal {
        _recordRemoval(d, arbiterAddr, rawCause + REMOVAL_CAUSE_SHIFT);
    }

    /// Removal on an accusation laid by the CHAIN. A separate entry point and
    /// not "pass 253 in here": if the caller named the code, the encoding would
    /// get a second owner — and drift apart on the first edit.
    ///
    /// ⚠️ THE CALLER MOVED TO ANOTHER FILE (18 August 2026): it is
    /// `ArbiterAccountabilityFacet.executeChainRemoval` that calls, not the
    /// threshold branch in this file. The path is known two days earlier than
    /// it is written down — hence the `chainProposalPath` field in `Data`.
    ///
    /// `rawPath` is the numeric value of ArbiterRegistryFacet.DemotionPath
    /// as-is; the library adds the base. The type is uint8 rather than
    /// DemotionPath itself for the same reason lastRemovalCause is stored as a
    /// uint8: the enum is declared in a FACET, and binding the storage library
    /// to it would mean that an edit there moves the layout here.
    function recordAutomaticRemoval(Data storage d, address arbiterAddr, uint8 rawPath) internal {
        _recordRemoval(d, arbiterAddr, AUTO_REMOVAL_BASE + rawPath);
    }

    /// ⚠️ THIS FUNCTION NO LONGER SITS ON THE PATH OF AN EMPTY try/catch, and
    /// the old warning here became untrue (18 August 2026). It said: "called
    /// from a branch that Agreement executes inside an empty try/catch
    /// (Agreement.triggerArbiterTimeout), reverting here is not
    /// allowed". Both of today's callers — `recordRemovalForCause` from
    /// `removeArbiterForCause` and `recordAutomaticRemoval` from
    /// `executeChainRemoval` — are SEPARATE human transactions, and a revert
    /// in them is visible to the caller.
    ///
    /// ⚠️ The ban on reverting DID NOT DISAPPEAR, it MOVED — into the threshold
    /// branch `ArbiterRegistryFacet._recordArbiterMistake`, where it is now
    /// written down. Reading this as "a try/catch covers the call" and
    /// weakening that ban would be the worst possible conclusion: there a
    /// revert is still swallowed silently, leaving the arbiter unpunished.
    ///
    /// There is nothing to revert here anyway: a uint256 increment and two writes.
    function _recordRemoval(Data storage d, address arbiterAddr, uint8 code) private {
        d.removalCount[arbiterAddr] += 1;
        d.lastRemovalAt[arbiterAddr] = block.timestamp;
        d.lastRemovalCause[arbiterAddr] = code;
    }

    /// Erases the marks of a PREVIOUS removal on seating (15 August 2026).
    /// `removedAt`/`removalReply` are bound to an ADDRESS and not to a specific
    /// removal event — addArbiter does not look at history (only
    /// `!isDaoActive()` and `!d.isArbiter[arbiter]`), and the owner brings a
    /// removed arbiter back with one command (undoing a mistaken removal is a
    /// real, not hypothetical, scenario under hand seating). Without the
    /// clearing, a second charge against the same address would end up either
    /// invisible (respondToRemoval would immediately see "already answered" —
    /// AlreadyAnswered out of nowhere) or, had only removalReply been cleared,
    /// a serving, not-yet-removed arbiter could answer a long-closed charge
    /// (removedAt != 0 on an active person).
    ///
    /// Lives in the LIBRARY and is called from BOTH entry doors —
    /// ArbiterRegistryFacet.addArbiter (hand seating) and .applyAsArbiter
    /// (self-registration once governance is live) — so that copies cannot
    /// diverge, exactly as `clearSeat` above centralizes the exit doors. How
    /// many exit doors there are is not written here: the number changed (three
    /// became two on 18 August 2026), and a list in someone else's docstring
    /// went stale silently — `clearSeat` keeps the current one.
    ///
    /// ⚠️ This does NOT erase history: the ArbiterRemovedForCause /
    /// RemovalAnswered events lie on the chain forever, a reader still sees both
    /// sides of every past dispute. These fields are only a counter of "did he
    /// answer the CURRENT, not yet cancelled removal".
    ///
    /// ⚠️ And since 16 August 2026 it erases no history in storage either:
    /// removalCount / lastRemovalAt / lastRemovalCause are NOT TOUCHED by this
    /// function on purpose, under any value of liftSuspension. Adding their
    /// deletion here means bringing back exactly the defect those fields were
    /// created against: the erasing door belongs to the accuser (addArbiter),
    /// and once governance is live also to the accused himself
    /// (applyAsArbiter), and an erasable history is no history.
    ///
    /// ⚠️ `suspendedUntil` is erased ONLY ON THE CALLER'S EXPLICIT REQUEST
    /// (16 August 2026, an owner's decision about this seam).
    ///
    /// The rationale in one phrase: **a suspension is not imposed by the
    /// arbiter, so lifting it is not his to do either.**
    ///
    /// A removal now SETS a suspension (ArbiterAccountabilityFacet.
    /// removeArbiterForCause), and before this fix NOBODY erased it — neither
    /// an exit door nor a re-seating. But the two entry doors have different
    /// owners, and equating them was a mistake:
    ///
    ///   • `addArbiter` passes `liftSuspension = true`. The owner deliberately
    ///     reverses HIS OWN decision; bringing a man back with an unexpired
    ///     suspension means bringing him back mute — he silently cannot claim,
    ///     finalize or resign, and nothing on the chain shows why, except
    ///     getSuspendedUntil.
    ///   • `applyAsArbiter` passes `liftSuspension = false`. This is
    ///     SELF-REGISTRATION. The first draft of the fix erased the suspension
    ///     here too — and thereby opened a hole: a man removed for cause paid a
    ///     fresh ARBITER_BOND (50 USDC) on top of the one just burned, returned
    ///     to the corps and finalized verdicts claimed BEFORE the removal
    ///     without waiting out 72 hours. That is, he bought a bypass of the
    ///     window in which the owner must reach overturnVerdict/freezeVerdict.
    ///
    /// The marks of the removal itself (`removedAt`, `removalReply`) are erased
    /// in BOTH cases: they are about the record of a PAST removal and must not
    /// stand in the way of answering a future one (see two paragraphs above).
    ///
    /// ⚠️ AND THIS FUNCTION IS NO LONGER THE ONLY ONE THAT ERASES
    /// `removalReply` (19 August 2026). A reply became possible for a SITTING
    /// arbiter, who passes through no seating door — so the slot is also
    /// cleared by the four doors of accusation itself. The list and rationale
    /// are in the docstring of the `removalReply` field above; what matters
    /// here is different: `removedAt` is still erased ONLY from here, and the
    /// second half of the invariant "`isArbiter` ⇒ `removedAt == 0`" rests on that. Split by a parameter, not a second copy
    /// of the function: there are still no copies, and the difference between
    /// the doors is visible AT THE CALL SITE, not hidden in the body.
    function clearRemovalRecord(Data storage d, address arbiterAddr, bool liftSuspension) internal {
        // A seat granted again starts unposted, not sagging (17 September 2026):
        // an appeal that drew the PREVIOUS seat's bond does not give the new
        // seat the right to finish cases without paying. Every seating door
        // passes through here, which is why the line lives here.
        delete d.bondDrawnByAppeal[arbiterAddr];
        delete d.removedAt[arbiterAddr];
        delete d.removalReply[arbiterAddr];
        if (liftSuspension) delete d.suspendedUntil[arbiterAddr];
    }
}

// ---------- THE HANDOVER'S SECOND CONDITION ----------

/// The liveness half of `activateDAO()`, in ONE place.
///
/// ⚠️ WHY A LIBRARY AND NOT THREE COPIES. The door that refuses and the view
/// that explains the refusal must be the same sentence, or the screen tells a
/// man he needs two more disputes while the door wants eight. This repository
/// has already paid for that shape twice over: `DAO_THRESHOLD` is written out
/// THREE times — here, as `DAO_THRESHOLD_MIRROR` in ArbiterAccountabilityFacet,
/// and again in `Treasury`, where it still says 100 000 and is wrong. The three
/// floors below are written once, and both callers go through this file.
///
/// ⚠️ IT IS STILL INLINED TWICE IN BYTECODE — `internal` functions are copied
/// into every contract that calls them, so ArbiterRegistryFacet and
/// ArbiterAccountabilityFacet each carry their own copy of these lines. What
/// the library buys is ONE SOURCE, not one copy: the two cannot drift apart
/// without somebody editing this file, and the scene
/// `test_TheDoorAndTheReadingAnswerFromOneRule` fails if they ever do.
///
/// WHAT IS DELIBERATELY NOT HERE: the FIRST condition. `uniqueActiveUsers >=
/// DAO_THRESHOLD` and "the successor has confirmed" stay written out in
/// `activateDAO()` exactly as they were. This is an addition beside them, not
/// a rewrite of them — the ratchet must keep its own plain line in the door.
library HandoverLib {

    /// The three floors, and the argument for each number.
    ///
    /// ⚠️ THE MEASURE CHANGED ON 20 SEPTEMBER 2026, FROM VOLUME TO AUTONOMY,
    /// and the reason is a count off other people's chains rather than a
    /// preference. The first draft asked for twenty disputes closed cleanly.
    /// The flagship on-chain escrow of this kind (Kleros Escrow) has carried
    /// 286 deals and FOUR disputes in seven and a third years; the nearest
    /// like-for-like freelance protocol (TalentLayer) has 18 deals and none at
    /// all. Twenty disputes therefore means somewhere near fifteen hundred
    /// deals and several years — a bar that is not a condition but a refusal,
    /// and a refusal dressed as a condition is the worst of the three, because
    /// it looks like safety while it quietly makes the handover impossible.
    ///
    /// What replaced it asks the same question in terms the protocol can
    /// actually reach: is the market moving NOW, does judging survive a run
    /// without a hand in it, and is "the court" more than one man. All three
    /// must hold at the same moment — see `readiness()` for why it is AND and
    /// not OR.
    ///
    /// ⚠️ THESE ARE STILL CHOSEN NUMBERS, NOT MEASURED ONES. Nothing on any
    /// chain has produced them; what is measured is the ORDER OF MAGNITUDE they
    /// had to come down to. They are constants rather than settable storage on
    /// purpose — a handover condition the owner can lower by one transaction is
    /// not a condition. To move them, replace the facet, which is visible.

    /// Deals open across the protocol at the moment of the press.
    ///
    /// Fifteen. The point of this term is that the first condition cannot see
    /// the present tense at all: `uniqueActiveUsers` counts everybody who ever
    /// earned XP and never falls, so ten thousand people could have come and
    /// gone and it would still read "ready" over a market with nothing in it.
    /// Fifteen is set above what the protocol has ever held at once, and below
    /// the 18 lifetime deals of the nearest comparable protocol, so that it is
    /// a bar a working market clears and a dead one cannot.
    uint256 internal constant LIVE_DEALS_FLOOR = 15;

    /// Disputes finalized on an arbiter's verdict IN A ROW with no governance
    /// hand in any of them.
    ///
    /// Eight. A run, not a total, because only a run can be BROKEN: a total
    /// forgives every press the owner ever made as soon as the next clean
    /// dispute lands, and the number then says "he is not needed" about a corps
    /// he has been steering all year. Eight rather than two because a pair can
    /// be staged between friendly addresses in an afternoon, and rather than
    /// twenty because the chains above say twenty disputes is years away.
    ///
    /// ⚠️ ONLY A GOVERNANCE HAND BREAKS IT (the owner's decision of
    /// 20 September 2026). A verdict the APPEAL PANEL overturns leaves the run
    /// standing where it is — it does not count towards the eight, and it does
    /// not throw the eight away. What the number is evidence of is the ABSENCE
    /// OF THE OWNER, and a panel correcting an arbiter happens without him.
    /// Two things follow, and both are the point: eight still means eight
    /// disputes closed cleanly, so the bar is not softened; and a losing party
    /// with the price of one appeal cannot hold the handover shut by breaking
    /// the run whenever it gets long. See
    /// `ArbiterRegistryStorage.Data.cleanDisputeStreak`.
    uint256 internal constant CLEAN_STREAK_FLOOR = 8;

    /// Different arbiters who have each taken at least one dispute to a clean
    /// finalization.
    ///
    /// Three. The streak alone is blind to WHO earned it — eight clean
    /// disputes judged by one friendly seat look exactly like eight judged by a
    /// corps, and governance handed over on that evidence is governance handed
    /// to whoever holds that seat. Three rather than four (the size of the
    /// corps today) so that one arbiter being ill, suspended or removed does
    /// not make the condition unreachable; more than two so that "the court"
    /// cannot be a man and his second address.
    uint256 internal constant DISTINCT_CLEAN_ARBITERS_FLOOR = 3;

    /// Everything the door looks at, with what it wants beside what it has, so
    /// a screen can say "three more disputes" instead of "no".
    struct Readiness {
        uint256 liveDeals;
        uint256 liveDealsFloor;
        uint256 cleanStreak;
        uint256 cleanStreakFloor;
        uint256 distinctCleanArbiters;
        uint256 distinctCleanArbitersFloor;
        /// Not a term and not compared to anything — the lifetime total of
        /// clean finalizations, carried here because it is the one number of
        /// the four a reader can watch grow across time. See
        /// `ArbiterRegistryStorage.Data.cleanDisputeCount`.
        uint256 cleanDisputesTotal;
        bool    liveDealsMet;
        bool    cleanStreakMet;
        bool    distinctCleanArbitersMet;
        bool    met;
    }

    /// Reads all three terms and answers all three questions in one pass.
    function readiness() internal view returns (Readiness memory r) {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        r.liveDeals                  = RegistryStorage.store().liveDeals;
        r.liveDealsFloor             = LIVE_DEALS_FLOOR;
        r.cleanStreak                = d.cleanDisputeStreak;
        r.cleanStreakFloor           = CLEAN_STREAK_FLOOR;
        r.distinctCleanArbiters      = d.distinctCleanArbiters;
        r.distinctCleanArbitersFloor = DISTINCT_CLEAN_ARBITERS_FLOOR;
        r.cleanDisputesTotal         = d.cleanDisputeCount;
        r.liveDealsMet               = r.liveDeals             >= r.liveDealsFloor;
        r.cleanStreakMet             = r.cleanStreak           >= r.cleanStreakFloor;
        r.distinctCleanArbitersMet   = r.distinctCleanArbiters >= r.distinctCleanArbitersFloor;
        // ALL THREE, not any. They answer three different questions — "is
        // there a market", "does judging survive a run without me" and "is the
        // court more than one man" — and a handover that needed only one of
        // them could be made on a busy market nobody has ever had to arbitrate,
        // on a well-judged corps with nothing left to judge, or on the word of
        // a single seat.
        r.met = r.liveDealsMet && r.cleanStreakMet && r.distinctCleanArbitersMet;
    }

    /// The same answer as `readiness().met`, without the eleven-field struct.
    ///
    /// ⚠️ IT EXISTS FOR ROOM, AND THE ROOM IS MEASURED. The door needs one
    /// bit; `readiness()` allocates and fills a struct in memory, and an
    /// `internal` function is copied into every contract that calls it, so
    /// ArbiterRegistryFacet was carrying the whole struct builder for the sake
    /// of its last field. The facet stood at 24 337 bytes of the 24 576 the
    /// chain allows, 239 to spare, and the gate wants 512 so the NEXT fix still
    /// fits; taking the struct out of the door bought back 135.
    ///
    /// ⚠️ THE COMPARISONS ARE NOW WRITTEN TWICE, and that is the price. The
    /// FLOORS are still written once (the three constants above), which is the
    /// drift that would actually hurt — a screen promising a bar the door does
    /// not want. The operators could still drift, so
    /// `test_TheDoorAndTheReadingAnswerFromOneRule` drives both over a grid
    /// around every floor and fails if they ever differ.
    function met() internal view returns (bool) {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        return RegistryStorage.store().liveDeals >= LIVE_DEALS_FLOOR
            && d.cleanDisputeStreak     >= CLEAN_STREAK_FLOOR
            && d.distinctCleanArbiters  >= DISTINCT_CLEAN_ARBITERS_FLOOR;
    }
}

// ---------- FACET ----------

contract ArbiterRegistryFacet {

    // -------- CONSTANTS --------

    uint256 private constant COMMIT_MAX_BLOCKS  = 50;         // ~100s on Base
    /// How many unique addresses must have EARNED their way in — closed a deal
    /// and taken XP for it — before the owner is allowed to hand governance
    /// over. A decision of 26 August 2026 changed both the number and what the
    /// number is FOR, and the second half matters more:
    ///
    ///   • it is a CONDITION, not a trigger. `isDaoActive()` no longer reads
    ///     it at all. Crossing it switches nothing on; it only unlocks
    ///     `activateDAO()`, which a person still has to press.
    ///   • 100 000 → 10 000, and that is a CONSEQUENCE of the first line. While
    ///     the threshold fired by itself, a big number PROTECTED — harder for
    ///     outsiders to snap it shut. As a condition, a big number LOCKS THE
    ///     OWNER IN: he could not hand power over even when he wanted to and
    ///     even when there was somebody to hand it to. What is left of the
    ///     number's work is a promise to people — "governance moves when there
    ///     are this many of you" — and an unreachable promise is the saying
    ///     one thing and doing another that this project keeps tripping over.
    ///
    /// ⚠️ 10 000 → 1 000 ON 20 SEPTEMBER 2026, AND THIS TIME THE NUMBER WAS
    /// DERIVED RATHER THAN JUDGED. The paragraph above records that 10 000 was
    /// picked by eye against Farcaster, with no data on exchanges of this kind.
    /// There is now an arithmetic to hold it against, and 10 000 failed it.
    ///
    /// The counter counts ADDRESSES THAT HAVE EVER EARNED XP, and a deal has
    /// two sides, so 10 000 of them means on the order of 5 000 finished deals
    /// before this condition is even reachable. At the pace this sector
    /// actually runs — the flagship closed 286 deals in seven years — that is
    /// not a decade, it is a century.
    ///
    /// The handover does not rest on this number alone: the other condition is
    /// a RUN of clean disputes, and at an honest dispute rate of one to three
    /// per hundred deals that run needs somewhere between three hundred and
    /// eight hundred deals behind it — six hundred to fifteen hundred people.
    /// At 1 000, the two conditions come due at roughly the same time, which is
    /// the whole point of having two: a promise that reads "governance moves
    /// when there are this many of you" should come true on the day the other
    /// half of the promise does. At 500 the population condition would never
    /// bind at all and would be decoration.
    ///
    /// ⚠️ `Treasury.DAO_THRESHOLD` IS A SEPARATE CONSTANT AND STILL SAYS
    /// 100 000 — NOW TWO ORDERS OF MAGNITUDE AWAY, NOT ONE. The treasury is
    /// DEPLOYED AND IMMUTABLE: the 100 000 in that source is what is running on
    /// chain, and editing it would not change the chain — it would only make
    /// the source stop describing the contract, which is worse than a known
    /// disagreement. The two are meant to agree by design, so this stays a
    /// KNOWN DISAGREEMENT until another treasury is deployed, and it is the
    /// treasury's copy that is stale, not this one.
    uint256 private constant DAO_THRESHOLD      = 1_000;     // uniqueActiveUsers — condition for switching on by hand
    /// ⚠️ NOT A DOOR ANY MORE — ZERO SINCE 20 SEPTEMBER 2026.
    ///
    /// It read 3 000, about thirty deals with thirty different people, and it
    /// stood in front of `applyAsArbiter` beside the clean streak. The owner's
    /// decision: the corps is entered on ONE test, and that test is the streak.
    /// Experience stays — as a record, as public standing and as the surface an
    /// overturn is slashed from — but it is no longer asked at the entrance.
    ///
    /// ⚠️ WHY A ZERO AND NOT A DELETION. `getMinXPToRegister()` is a selector
    /// mounted on the live diamond; unmounting it needs a signed cut, and a
    /// getter that answers a number nothing enforces would be a promise we do
    /// not keep. Zero is the honest answer to "how much XP do I need": none.
    /// The check itself is gone from `applyAsArbiter` — a comparison against
    /// zero that can never fail is dead weight in a facet with 752 bytes of
    /// room, and dead code that looks like a gate is how a reader comes to
    /// believe there is one.
    uint256 private constant MIN_XP_TO_REGISTER = 0;
    uint256 private constant OVERTURN_XP_SLASH  = 200;       // XP penalty on an overturn
    // DEFAULT_REWARD (5 USDC) was deleted on 31 July: no call read it, while the
    // comment above it called it "the floor of the formula" — even though the real
    // floor of an arbiter's payout is DEFAULT_ARBITER_FLOOR (ArbiterVaultFacet). Two constants
    // sharing one word in their description, one of them dead, are a false trail
    // and not documentation.
    /// The window between a verdict and its execution. It does TWO jobs with one
    /// number, and after 9 October 2026 the second is the one that sets it:
    ///
    ///   * `finalizeVerdict` will not run before it has passed;
    ///   * `raiseAppeal` will not run after it has.
    ///
    /// ⚠️ 24 → 72 HOURS, the owner's decision of 9 October 2026, and it follows
    /// from the same cut that removed the owner's hand from a verdict. While the
    /// hand existed, a wrong verdict nobody appealed could still be reversed by
    /// a person. It cannot now, and that is measured rather than argued:
    /// `raiseAppeal` admits ONLY the losing party (`NotLosingParty`) and only
    /// inside this window, while `clearStuckVerdict` demands the deal NOT be in
    /// dispute (`status != 4`), so it refuses in exactly the case where it would
    /// be wanted. One missed day is therefore final, for ever, for everybody —
    /// and twenty-four hours is not a day for a person in another time zone who
    /// is asleep when the verdict lands.
    ///
    /// ⚠️ WHAT IT COSTS, SAID AS THE NUMBER IT IS: a dispute nobody appeals now
    /// settles 48 hours later than it did. That is the whole price, it falls on
    /// the honest case, and the owner took it knowingly. Nothing else moves: the
    /// panel's own window (`APPEAL_REVIEW_WINDOW`, four days) is a separate
    /// constant and starts when an appeal is raised.
    ///
    /// ⚠️ GIVING BOTH SIDES THE RIGHT TO APPEAL WAS CONSIDERED AND REFUSED, and
    /// the reason is structural rather than a preference: there is ONE appeal
    /// slot per verdict (`AlreadyAppealed`), so the WINNING side could spend it
    /// — cheaply, on a case it has already won — and lock the loser out for
    /// good. A wider door with one slot behind it is narrower than a narrow one.
    ///
    /// (It was one hour before 2026 — not enough for an ordinary user at all.)
    uint256 private constant FINALIZE_DELAY      = 72 hours;

    /// HOW LONG THE OWNER'S FREEZE HOLDS BEFORE IT LAPSES BY ITSELF
    /// (owner's decision, 24 September 2026).
    ///
    /// WHY IT EXISTS. `freezeVerdict` stopped `finalizeVerdict` with no clock at
    /// all, and the arbiter's top-up (`disputeBounty`) is booked on the DIAMOND
    /// rather than inside the deal — so the only way out of it was a second press
    /// by the same hand that pressed the first. The escrow may freeze: the
    /// parties chose their counterparty and answer for the deal. The money a
    /// party put down to make an arbiter read the case may not, because nobody in
    /// that transaction agreed to a hold without an end. Measured 24 September
    /// 2026: frozen, a year later, `finalizeVerdict` still answered
    /// `VerdictFrozenError` and the top-up had not moved.
    ///
    /// ⚠️ IT DOES NOT TAKE THE LEVER AWAY, AND IT IS NOT SUPPOSED TO. The owner
    /// deciding inside the window is still his decision — unfreeze, overturn,
    /// freeze again. The window insures against the one case he named: nobody
    /// came back to decide at all. What it therefore does NOT stop is a hand
    /// that presses again every three days; that is the lever working, not the
    /// clock failing, and it is out of scope by his decision.
    ///
    /// ⚠️ THE SAME 72 HOURS the emergency brake and `SUSPENSION_WINDOW` use,
    /// and deliberately so — one familiar number for "a hold that releases
    /// itself", not a third one to remember. It is NOT declared by reading
    /// `SUSPENSION_WINDOW`: that one is the span an accused arbiter sits out,
    /// and tying the two together would mean that moving one moves the other
    /// silently.
    uint256 private constant FREEZE_WINDOW = 72 hours;

    // Floor under a no-response record: this much must pass from the CLAIM of a
    // dispute before the arbiter may write "asked, no answer". Owner's decision of
    // 14.08.2026. ~~Matches FINALIZE_DELAY on purpose: one familiar number, not
    // two.~~ — it no longer matches, since 9 October 2026 FINALIZE_DELAY is 72
    // hours. The two were never the same question (how long before an arbiter
    // may record silence, against how long a verdict waits before it executes),
    // and only one of them was moved by that decision. This one stays at 24 on
    // purpose: nothing about the appeal window changes how long is long enough
    // to call a counterparty silent.
    //
    // ⚠️ This is the ONLY place the number is declared. The frontend must read it
    // through getNoResponseFloor() rather than keep a copy of its own.
    uint256 private constant NO_RESPONSE_FLOOR = 24 hours;

    /// THE ONLY DOOR INTO THE CORPS, and five since 20 September 2026.
    ///
    /// It was ten, and ten was chosen against an imagined market. Measured
    /// against the real one: the flagship of this sector (Kleros Escrow) closed
    /// 286 deals and 4 disputes in seven and a quarter years, and the nearest
    /// analogue (TalentLayer) 18 deals and no disputes at all. Ten clean deals
    /// in a row, each of them with a counterparty who already held standing, is
    /// not a high bar on such a market — it is an unreachable one.
    ///
    /// Five reads as one sentence a person can hold in their head: work five
    /// deals in a row without a dispute, and you may judge.
    ///
    /// ⚠️ IT IS NOT THE SAME NUMBER AS `CLEAN_STREAK_FLOOR` a few hundred lines
    /// up. That one counts the PROTOCOL'S run of clean disputes for the
    /// handover condition; this one counts ONE PERSON'S run of clean deals. They
    /// have never been equal and must not be made to track each other.
    ///
    /// ⚠️ Mirrored once, in `ArbiterApplicationsFacet.MIN_CLEAN_STREAK_MIRROR`,
    /// which is held against the `need` field of the refusal THIS door emits —
    /// not against this file. See that mirror's docstring.
    uint256 private constant MIN_CLEAN_STREAK_TO_REGISTER = 5;
    /// Mistakes in a row before THE CHAIN ACCUSES (not before a removal —
    /// 18 August 2026). At this number `_recordArbiterMistake` suspends the
    /// arbiter and lays a removal proposal in the chain's name; the removal
    /// itself goes through the common door after `REMOVAL_DELAY`. Not to be
    /// confused with ArbiterAccountabilityFacet.MISTAKE_THRESHOLD (2) — that
    /// one is how a PERSON proves a cause, and it is one lower on purpose.
    uint256 private constant MAX_ARBITER_MISTAKES         = 3;
    // ⚠️ DEMOTION_XP_RESET (2500) WAS REMOVED ON 21 SEPTEMBER 2026, and the
    // note is left standing where the constant stood, because it explains a
    // rule that ran for two months and is quoted in the record.
    //
    // What it was: a FLAT LANDING POINT, not a subtraction. The automatic path
    // set a punished arbiter's XP to 2500 whatever he had earned, and the whole
    // point of the number was that it sat BELOW MIN_XP_TO_REGISTER (3000 then)
    // — so the way back into the corps had to be earned a second time.
    //
    // Why it went. The entrance stopped asking for XP on 20 September 2026
    // (decision 104) and asks for the clean streak, which `_performRemoval`
    // already takes on a removal — the barrier this number bought is there
    // without it. What the number still did was REWRITE A RECORD OF WORK
    // ALREADY DONE: XP is how much a man worked, and under the frame this
    // repository settled on, that is history. A punishment that edits history
    // is a forgery and not a penalty, so the penalty is carried by the things
    // that are actually his standing now — the forfeited bond, the seat, the
    // zeroed clean streak and a permanent public record of the removal.
    //
    // ⚠️ NOT TO BE CONFUSED WITH OVERTURN_XP_SLASH (200), WHICH STAYS. That
    // one charges for ONE judicial mistake, at the moment it is proven, and it
    // is a different thing from charging a man for who he had been.
    // ⚠️ DEAD SINCE THE SEAT BOND WAS RETIRED. Nothing reads it: it used to be
    // forfeited on demotion and returned on resignAsArbiter(), and neither
    // happens any more, because no seat carries a bond. Kept so that the number
    // the four original seats paid stays readable next to the rule that took it.
    uint256 private constant ARBITER_BOND                 = 50_000_000; // 50 USDC (6 decimals)

    uint256 private constant APPEAL_REVIEW_WINDOW = 4 days;     // the same span DISPUTE_WINDOW gives the arbiter

    /// ── THE SEATS DO NOT OPEN IN THE BLOCK THE APPEAL IS RAISED
    ///    (24 September 2026, the owner's decision) ──
    ///
    /// First come, first served is what makes the panel cost nothing to
    /// assemble, and it is also its one practical weakness: a pair of bots
    /// watching the mempool can take all three seats in the same block the
    /// appeal is raised, and no arbiter who reads cases like a person ever sees
    /// the case at all. That is not collusion being solved — collusion is
    /// answered by the case bond, the mistake streak and every vote being
    /// public — it is the RACE being taken out of the first instant.
    ///
    /// An hour out of a window of four days is 1/96 of it. What it buys is that
    /// the appeal is on the board, visible, before anybody can close it.
    ///
    /// DECLARED ONCE. The door and the view both read `_seatsOpenAt`, never the
    /// arithmetic — two copies of one rule agree until the first edit.
    uint256 private constant APPEAL_SEAT_DELAY = 1 hours;

    /// ── AN APPEAL HAS THREE SEATS, AND ARBITERS TAKE THEM THEMSELVES
    ///    (23 September 2026, the owner's decision) ──
    ///
    /// THE HISTORY, kept because both retired rules explain this one. The
    /// quorum began as a flat `APPEAL_MIN_VOTES = 3`; on 18 September it became
    /// `min(CAP, eligible voters)` with this floor, counted by walking
    /// `arbiterList` at the moment the appeal was raised. That count was the
    /// defect: part 2 of this branch let anybody with five clean deals seat
    /// himself, nothing caps the corps, and the walk was paid for BY THE
    /// APPELLANT — 150 029 gas at four seats, 2 546 205 at five hundred,
    /// measured in test/AppealPanelGas.t.sol. The price of challenging a
    /// verdict grew with the number of people entitled to review it.
    ///
    /// THE RULE NOW. The panel has APPEAL_VOTES_CAP seats. An arbiter takes one
    /// by voting — first come, first served — and the fourth to arrive is
    /// refused with `AppealPanelFull`. Nothing walks the roster at any door:
    /// whether THIS man may sit is asked of him alone, by `_mayVoteOnAppeals`
    /// and the two party checks in `voteOnAppeal`. Whether a panel assembled at
    /// all is answered at the END of the review window instead of guessed at
    /// its start, and if fewer than APPEAL_VOTES_FLOOR sat down the appeal did
    /// not happen and the deposit goes home whole.
    ///
    /// WHY A CEILING AT ALL, rather than letting the whole corps vote: a corps
    /// of hundreds all voting on one appeal is the same unbounded cost moved
    /// from the appellant onto the arbiters and onto the payout, and the pay
    /// per voter would fall to dust. Three is enough to decide and small enough
    /// to pay.
    ///
    /// WHAT THREE NEVER DEFENDED, said again because the number looks like a
    /// safety margin and is not: at three seats an appeal is decided by TWO, so
    /// three never stopped a pair who agreed in advance, and "first come" makes
    /// a determined pair FASTER rather than slower. Collusion is answered by
    /// the case bond, by the mistake streak and by every vote being public —
    /// not by the size of the panel. This is the owner's position and it is
    /// recorded rather than argued here.
    uint256 private constant APPEAL_VOTES_CAP   = 3;
    /// Fewer seats than this taken by the end of the review window and the
    /// appeal did not happen: the verdict stands, the deposit goes back whole
    /// and nobody is paid.
    ///
    /// ⚠️ IT IS NO LONGER A DOOR CONDITION, and that moved the moment the
    /// roster walk went (23 September 2026). It used to be checked ABOVE the
    /// transfer in `raiseAppeal`, so a corps too small to review anything could
    /// not take the appellant's money. Nothing can be counted at that door any
    /// more, so the money IS taken and comes back at `resolveAppeal` instead.
    /// One arbiter is not a panel: he is the single overturn the cap exists to
    /// prevent.
    uint256 private constant APPEAL_VOTES_FLOOR = 2;

    /// What an appeal cost before its price was written next to it — the
    /// flat 20 USDC in force until 26 August 2026. Read by `_depositOf` and by
    /// nothing else.
    ///
    /// ⚠️ NOT THE FLOOR OF TODAY'S PRICE, although the two are equal today.
    /// Since 17 September 2026 an appeal is priced by
    /// `ArbiterRegistryStorage.appealDepositFor` (floor 20, 3% of the pot, cap
    /// 200). Reading that floor here instead would bring back the defect the
    /// receipt field was written to kill: the day the floor moves, a man who
    /// paid twenty under the old rule would be refunded the new number.
    uint256 private constant APPEAL_DEPOSIT_BEFORE_RECEIPT = 20_000_000;

    /// The FEWEST votes that can ever decide an appeal — the number the cap on
    /// the chief's bloc is measured against (16 August 2026).
    ///
    /// resolveAppeal settles the matter by a strict majority of the votes CAST
    /// once the quorum of them exists, and anyone may call it. With three cast,
    /// two decide — so the guarded property "the chief does not decide an
    /// appeal" requires a block of STRICTLY FEWER THAN two, not fewer than
    /// three as the earliest version of the cap assumed.
    ///
    /// DERIVED, not written as a number: two values about one rule would drift
    /// apart silently — the same class as MISTAKE_THRESHOLD in
    /// ArbiterAccountabilityFacet, declared as a subtraction rather than a
    /// literal.
    ///
    /// ⚠️ DERIVED FROM THE FLOOR AND NOT FROM THE CAP since the quorum became
    /// movable (18 September 2026). The two happen to give the same 2 today
    /// (2/2+1 and 3/2+1), so nothing about the cap on the chief changes with
    /// this edit — but they are the same number by arithmetic, not by meaning,
    /// and this constant means "the smallest panel that can still decide". A
    /// cap raised to five would leave the floor's 2 the safe answer and the
    /// cap's 3 a hole.
    uint256 private constant APPEAL_DECIDING_VOTES = APPEAL_VOTES_FLOOR / 2 + 1;

    // ARBITER_SHARE_BPS, DEFAULT_ARBITER_FLOOR and DEFAULT_DISPUTE_DISCOUNT are
    // declared in ArbiterVaultFacet, beside the only code that applies them.
    // Until 17 September 2026 a second declaration of each stayed here after the
    // split with no reader in this file, and front-end locks pinned the share
    // to that dead copy: a mutation setting the applied share to 7 000 turned
    // none of three of them red. Deleted rather than kept "in sync" — an unread
    // copy is a mirror.

    // ── Cap on disputes held at once ──
    /// How many disputes an arbiter holds at once. It limits fee farming — an
    /// arbiter earns a share of the fee on EVERY dispute regardless of which
    /// way he ruled, so "grab many and rule at random" is income without
    /// work. The cap counts the NUMBER, not the amount: the amount is set by
    /// whoever created the deal, so a cap on it inherits an untrusted number.
    /// Approved by the owner on 15 August 2026.
    uint256 private constant MAX_CLAIMS_PER_ARBITER = 10;

    // ⚠️ `MAX_CASES_AT_ONCE` STOOD HERE AND HAS MOVED (22 September 2026),
    // into `ArbiterRegistryStorage` beside `caseSlotsFor`, which is the rule it
    // belongs to: three cases at once, and one until three clean verdicts have
    // stood. It moved rather than being copied because the number does two jobs
    // now — the ceiling and the threshold that earns it — and a second copy
    // would be a second rule that drifts.

    // -------- ENUM --------

    /// Which path triggered an AUTOMATIC removal over a streak of judicial
    /// mistakes. There is one value more than there are callers of
    /// _recordArbiterMistake, and each answers "who did this" honestly,
    /// including the answer "nobody":
    ///
    ///   Unspecified      — ⚠️ THE ZERO VALUE IS DELIBERATELY NOT A PATH
    ///                      (16 August 2026). In Solidity zero is the default:
    ///                      it is what anyone who forgot to set a path gets,
    ///                      and what every new path whose author forgot to add
    ///                      a value here gets. Had OwnerOverturn stood at zero,
    ///                      forgetfulness would silently accuse the OWNER, and
    ///                      the record would read as an accusation nobody ever
    ///                      raised. Exactly the defect this design exists to
    ///                      prevent, only inside out. No caller sends this
    ///                      value; a reader who sees it in the feed must read
    ///                      "the path is not named", not "so-and-so is guilty".
    ///   OwnerOverturn    — overturnVerdict. Called by the owner or daoAddress,
    ///                      and holds not a single soundness check. Someone did
    ///                      press, and the `by` field names him — it may NOT be
    ///                      the owner (test_ArbiterDemotedNamesTheDaoNotTheOwner).
    ///   AgreementTimeout — notifyArbiterTimeout. Called by THE AGREEMENT ITSELF
    ///                      from inside triggerArbiterTimeout (msg.sender ==
    ///                      agreement). No person behind it, `by` is zero.
    ///   AppealVote       — resolveAppeal. Settles the vote, and anyone may call
    ///                      it. This is where msg.sender would lie loudest: the
    ///                      VOTES decide, not whoever pressed "settle". `by` is
    ///                      zero, and the voters are in the AppealVoteCast feed
    ///                      for the same agreement.
    ///   ClaimAbandoned   — abandonClaim (18 September 2026, item D1). The same
    ///                      missed window as AgreementTimeout, reached from the
    ///                      other side: there the deal announced it, here a
    ///                      stranger took the dead claim off the arbiter because
    ///                      neither party ever came. Told apart from
    ///                      AgreementTimeout and not folded into it, because the
    ///                      permanent record is asked "how did this come about"
    ///                      and "nobody pressed the timeout for four days" is a
    ///                      different answer from "a party pressed it". `by` is
    ///                      zero for the same reason as on the two paths above:
    ///                      whoever pressed neither judged nor accused. The log
    ///                      that names the arbiter is DisputeClaimAbandoned.
    ///
    /// ⚠️ APPENDED AT THE END. The numeric value of every path above is
    /// unchanged: `chainProposalPath` keeps this enum as a raw uint8 in storage
    /// and the ArbiterDemoted feed carries it as an indexed topic, so inserting
    /// a value would rewrite history already on the chain.
    ///
    /// ⚠️ EVERY VALUE HERE ALSO HAS TO FIT THE PERMANENT RECORD, which encodes
    /// it as `ArbiterRegistryStorage.AUTO_REMOVAL_BASE + uint8(path)` inside a
    /// uint8 — a range with a ceiling and therefore a finite number of places
    /// (240..255 today: sixteen, five taken). Appending past the ceiling does
    /// not truncate, it makes recordAutomaticRemoval revert with Panic 0x11 and
    /// takes the chain's own removal door down with it. This was not caught
    /// when ClaimAbandoned was added, because a docstring was all that stood
    /// here; test/ArbiterDemotionPathCodes.t.sol now walks this enum and pushes
    /// every member through the real encoder, so the day the range runs out is
    /// a red test and not a stuck arbiter.
    ///   OverturnRate     — finalizeVerdict (21 September 2026). Not a fourth
    ///                      way of getting a verdict wrong but a different
    ///                      MEASURE of the same ones: OUTCOME_OVERTURN_LIMIT of
    ///                      the last OUTCOME_WINDOW closed cases came back
    ///                      overturned. Told apart from OwnerOverturn and
    ///                      AppealVote and not folded into either, because the
    ///                      permanent record is asked "how did this come about"
    ///                      and "two of his last six" is a different answer
    ///                      from "three in a row" — and because the reader of
    ///                      the card needs to know the chain counted a SHARE,
    ///                      which no single dispute can be blamed for. `by` is
    ///                      zero: nobody pressed, arithmetic did it. The
    ///                      `agreement` carried with it is the case that
    ///                      completed the count, not the cause of it.
    enum DemotionPath { Unspecified, OwnerOverturn, AgreementTimeout, AppealVote, ClaimAbandoned, OverturnRate }

    // -------- EVENTS --------

    event ArbiterAdded(address indexed arbiter);
    /// A seating that names who pressed. `ArbiterAdded` stays for compatibility
    /// with subgraph v2.3.0, which is already live and reads it.
    event ArbiterSeated(address indexed arbiter, address indexed by, bool selfService);
    // ArbiterRemoved was deleted together with removeArbiter (15 August 2026):
    // its only emit site disappeared with the function. The replacement is
    // ArbiterAccountabilityFacet.ArbiterRemovedForCause.
    /// The chain accuses, in its own name, having proved the cause itself
    /// (18 August 2026). Laid by _recordArbiterMistake when the
    /// mistake streak reaches MAX_ARBITER_MISTAKES: the arbiter is suspended
    /// on the spot and a removal proposal opens against him with no author —
    /// `by` in the record is the zero address, and no such field exists here,
    /// because there is nobody to name.
    ///
    /// `path` is uint8(DemotionPath) raw, the same value that goes into the
    /// permanent record two days later; `agreement` is the deal whose verdict
    /// tipped him over. Both are carried HERE and not on the removal, because
    /// here is where they are known.
    event RemovalProposedByChain(
        address indexed arbiter,
        uint8           path,
        address indexed agreement,
        uint256         proposedAt
    );

    // ⚠️ `event ChainAccusationCleared(address indexed arbiter, address indexed
    // agreement)` STOOD HERE AND IS RETIRED (9 October 2026).
    //
    // It said: the panel found the arbiter right, so the chain takes its own
    // accusation back — proposal erased, streak zeroed, suspension lifted, one
    // record because the three happened together and meant one thing. It was a
    // separate event rather than RemovalProposalWithdrawn because that one names
    // `by` and `by` is always a person; a zero there would have read as "withdrawn
    // by nobody".
    //
    // ⚠️ IT WAS RETIRED BECAUSE NOTHING COULD EMIT IT ANY MORE, AND A GATE SAID SO
    // BEFORE A PERSON DID. Its only emitter was the vindication branch of
    // `resolveAppeal`, which went with the governance hand over a verdict. A
    // declaration with no emit is a promise in the ABI the chain can never keep,
    // and `script/check-subgraph-arbiter-events.sh` names exactly that: the feed
    // would wait for a log that cannot arrive.
    //
    // ⚠️ WHAT THIS MEANS, SAID PLAINLY RATHER THAN LEFT IN THE DIFF: the chain no
    // longer withdraws its own accusation, ever. An arbiter the chain accused
    // after three judicial mistakes in a row still has the two things that
    // matter — the accusation EXPIRES by its own TTL, and he may answer it during
    // the pause — but there is no state left called "shown to have been right",
    // because the hand that could be wrong about him is gone.
    //
    // ⚠️ THE SUBGRAPH KEEPS ITS HANDLER, for the same reason it keeps
    // handleVerdictOverturned: the logs already on chain do not disappear, and a
    // reindex from block zero must still show an arbiter whose accusation really
    // was cleared before this date. Three readers in `frontend/` also know this
    // name — the ABI copy in config/contracts.ts, the notification router, and the
    // ABI census test. The frontend is a separate task and is deliberately NOT
    // touched here.

    /// A judicial mistake booked on the TIMEOUT path — the one path that left
    /// nothing a reader could recover it from (added alongside the subgraph
    /// work, 21 August 2026).
    ///
    /// ⚠️ WHY A CONTRACT CHANGE FOR WHAT LOOKS LIKE A READING PROBLEM. The
    /// owner's rule is that the accused must see EVERY dispute his accusation
    /// stands on. Two of the three mistake paths are recoverable from logs that
    /// already exist — `VerdictOverturned` names the arbiter outright, and the
    /// appeal vote is recoverable from `AppealResolved` plus the arbiter of the
    /// verdict it is about. The third could not be recovered by ANY reading:
    /// `notifyArbiterTimeout` emitted nothing at all, and
    /// `Agreement.ArbiterTimedOut(address indexed client, uint256)` lives on the
    /// deal and names the CLIENT. A run with a timeout in it therefore came out
    /// one dispute short, and the accused was shown two of the three things he
    /// was about to be removed over.
    ///
    /// ⚠️ TWO INDEXED ADDRESSES AND NOTHING ELSE, and that is the BYTECODE
    /// budget talking rather than taste: this facet had 1 213 bytes of its
    /// 24 576 left when the event was written, and the whole event cost 6.
    /// Indexing both fields means the log carries three topics and an empty
    /// data section, so the compiled code holds no memory layout and no length
    /// — which is what the six bytes buy.
    ///
    /// It is NOT the cheapest to EXECUTE, and saying so keeps the trade honest:
    /// LOG3 with no data costs 1 500 gas where LOG2 with one 32-byte word costs
    /// 1 381. The 119 gas go to the reader, who can then filter the log by the
    /// arbiter — which is the entire point of the event.
    ///
    /// The demotion path is not carried because there is only one it could be:
    /// this event is emitted from exactly one place, and that place is the
    /// timeout.
    ///
    /// ⚠️ NOTHING AROUND THIS EMIT MAY REVERT. `notifyArbiterTimeout` is reached
    /// from `Agreement.triggerArbiterTimeout` inside an EMPTY try/catch — a
    /// revert there is swallowed in silence and the arbiter walks away
    /// untouched, without a trace. An `emit` cannot revert, which is the reason
    /// this is an event and not a storage field.
    event ArbiterTimeoutRecorded(address indexed arbiter, address indexed agreement);

    event ChiefArbiterSet(address indexed prev, address indexed next);
    event DisputeClaimCommitted(address indexed arbiter, bytes32 indexed commitment);
    event DisputeClaimed(address indexed agreement, address indexed arbiter);

    // ── The bond a case carries (22 September 2026) ────────────────────────
    /// The arbiter put money down to take this case.
    event CaseBondPosted(address indexed agreement, address indexed arbiter, uint256 amount);
    /// His verdict stood (or the case left him without one) — the money went
    /// home. `amount` is what was still there, which after a won appeal is what
    /// the refund left.
    event CaseBondReturned(address indexed agreement, address indexed arbiter, uint256 amount);
    /// The panel overturned him, and this much of his bond went to the
    /// appellant. Emitted from `_advanceAppealRefund`, beside `AppealRefundAdvanced`.
    event CaseBondForfeited(address indexed agreement, address indexed arbiter, uint256 amount);
    event DisputeReleased(address indexed agreement, address indexed prevArbiter);
    /// A dead claim taken off an arbiter after his window ran out
    /// (18 September 2026, item D1). Separate from DisputeReleased, which is a
    /// voluntary hand-back INSIDE the window and carries no fault: this one is
    /// always a missed window and always books a judicial mistake. `by` is
    /// whoever pressed — he chooses nothing, the money is untouched, and the
    /// deal's own timeout rule pays out later exactly as written.
    event DisputeClaimAbandoned(
        address indexed agreement,
        address indexed arbiter,
        address indexed by
    );
    /// The arbiter recorded on chain: asked a party for the chat log — no answer.
    /// The event carries the same as storage and exists for the appeal feed:
    /// storage shows only the record of the CURRENT claimer, while an appeal
    /// looks at the whole course of a dispute, including arbiters who let it go.
    event DisputeNoResponseRecorded(address indexed agreement, address indexed arbiter, uint256 at);
    /// A party to the dispute put a presentation digest on chain.
    ///
    /// ⚠️ THE EVENT IS MANDATORY, and not as a duplicate of storage: storage
    /// answers "how many and which", while a dispute turns on "what came
    /// first". The block number and the ordering relative to
    /// DisputeNoResponseRecorded exist only in the feed. `index` duplicates the
    /// position in the list on purpose — a feed reader must not have to go into
    /// storage to tell a first presentation from a tenth.
    event PresentationDigestRecorded(
        address indexed agreement, address indexed submitter, bytes32 digest, uint256 index
    );
    event DAOActivated(address indexed by);
    event ArbiterApplied(address indexed arbiter);
    /// The arbiter's chat keys were published or replaced.
    ///
    /// ⚠️ THE EVENT IS MANDATORY, and here is why: the presentation flow watches
    /// for a key change to re-present automatically when an arbiter switches
    /// device. Without the event it would have to POLL the chain — and on
    /// 9 August 8 100 chain calls an hour from one tab were removed; a new poll
    /// would bring the same trouble back renamed. Do not delete, do not unindex.
    event ArbiterChatKeySet(address indexed arbiter, bytes32 boxKey, bytes32 signKey);
    event VerdictSubmitted(address indexed agreement, address indexed arbiter, bool clientWins);
    event VerdictFinalized(address indexed agreement, address indexed arbiter, bool clientWins);
    // ⚠️ `VerdictFrozen`, `VerdictUnfrozen` and `VerdictOverturned` STOOD HERE
    // AND ARE GONE (9 October 2026), with the three doors that emitted them.
    // An event declared and emitted nowhere is a red from
    // script/check-subgraph-arbiter-events.sh, so they could not simply be left
    // standing. What a reader of the chain's history needs is unchanged: the
    // logs already emitted are still decodable from the ABI of the facet that
    // emitted them, which is what the indexer's own abis/ copy is for.
    event ArbiterRewarded(address indexed arbiter, uint256 amount);
    event ArbiterRewardWithdrawn(address indexed arbiter, uint256 amount);
    event VaultFunded(address indexed by, uint256 amount);
    // RewardPerDisputeUpdated was deleted on 31 July together with the last
    // thing that sent it: setRewardPerDispute became a `pure revert`, so there
    // is nobody left to write the value. A declaration with no emit is a promise
    // of an event that will never come, made to everyone who reads the ABI.
    event DAOAddressSet(address indexed daoAddress);
    /// The successor is NAMED but has not taken office. A pair with DAOAddressSet
    /// above: the first event is the owner's proposal, the second is the
    /// confirmation by the address itself, and no rights move in between.
    event DAOAddressProposed(address indexed daoAddress);
    event StuckVerdictAutoCleared(address indexed agreement);
    event AppealRaised(address indexed agreement, address indexed appellant);
    event AppealVoteCast(address indexed agreement, address indexed arbiter, bool overturn);
    event AppealResolved(address indexed agreement, address indexed appellant, bool overturned);

    // ── Appeal economics, 17 September 2026 ──────────────────────────────────
    // Emitted beside AppealResolved, never instead of it: that event's topic is
    // read by the subgraph and the screens, and its shape does not move.

    /// The window closed without a quorum and the whole deposit went back to
    /// the appellant — nobody reviewed anything, so nothing was bought.
    event AppealDepositReturned(address indexed agreement, address indexed appellant, uint256 amount);
    /// A quorum voted: each voter may pull `perVoter`, whatever the outcome;
    /// `toVault` is the remainder of the division.
    event AppealPanelPaid(address indexed agreement, uint256 perVoter, uint256 voters, uint256 toVault);
    /// A won appeal refunded before the ruling arbiter's forfeited fee share
    /// exists: `fromBond` out of his bond, `fromVault` out of the bank, `debt`
    /// owed with nothing behind it yet.
    event AppealRefundAdvanced(
        address indexed agreement, address indexed appellant, uint256 fromBond, uint256 fromVault, uint256 debt
    );
    /// The forfeited fee share arrived and was spent in the fixed order: the
    /// unpaid debt to the appellant, the bank's advance, the bond's advance
    /// (back into the bond only while the seat is still held), the rest to the
    /// bank. `fromTreasury` is what the treasury's 20% of the same fee covered
    /// of the debt and the bank's advance after that; it keeps the rest.
    event ForfeitedShareSpent(
        address indexed agreement, uint256 toAppellant, uint256 toBond, uint256 toVault, uint256 fromTreasury
    );
    /// A voter pulled his share of a panel's pay.
    event AppealShareWithdrawn(address indexed agreement, address indexed voter, uint256 amount);
    /// Removal over a streak of judicial mistakes.
    ///
    /// ⚠️ FOUR FIELDS INSTEAD OF ONE (16 August 2026). The earlier version —
    /// `ArbiterDemoted(address indexed arbiter)` — named neither the cause nor
    /// who pressed. From outside it read as "the system demoted a judge by
    /// itself over three mistakes in a row": the record did not just hide the
    /// accuser, it shifted blame onto the accused more convincingly than any
    /// accusation. All while the owner unseated an arbiter with three overturns
    /// past the door with a cause, and overturnVerdict holds no soundness check.
    ///
    /// ⚠️ AND THIS EVENT NOW FIRES FROM ELSEWHERE (18 August 2026). Three
    /// overturns no longer remove: they suspend and open an accusation in the
    /// chain's name (`RemovalProposedByChain` below), and "removed" becomes
    /// true 48 hours later, in
    /// `ArbiterAccountabilityFacet.executeChainRemoval` — that is where it fires.
    /// The declaration stays here alone: the signature and topic0 are the same,
    /// the live subgraph needs no edit, and the gate
    /// script/check_subgraph_arbiter_events.py checks both ends.
    ///
    /// `by` at the new site is always zero: there is no hand on that path, and
    /// naming whoever pressed the button is wrong — he is not the accuser.
    ///
    /// ⚠️ THE PRICE OF THIS PATH ROSE TWICE ON 18 August 2026, and the earlier
    /// wording of the line above — "three calls against ONE agreement" — has
    /// been untrue since:
    ///
    ///   • `AlreadyOverturned` shut a repeated press on one verdict: three
    ///     DIFFERENT disputes are needed, not three presses;
    ///   • a panel that restores the arbiter's verdict takes the booked mistake
    ///     back (see resolveAppeal). Before that fix it did the opposite and
    ///     GAVE the owner a second mistake by ruling correctly, so a removal
    ///     cost two disputes instead of three.
    ///
    /// `by` is zero wherever there is NO presser AT ALL (timeout, vote) — that
    /// is an assertion, not an omission: see the DemotionPath docstring.
    ///
    /// `agreement` is the dispute the LAST mistake of the streak landed on. It
    /// is not the whole history and does not pretend to be: it is the way in.
    ///
    /// ⚠️ A WAY IN, NOT THE HISTORY — but the streak now reads in FULL from the
    /// logs (21 August 2026). This used to say "a timeout mistake cannot be
    /// found by this field at all" and concluded "the first two cannot be
    /// recomputed": true as of 16 August, and fixed not by reading but by the
    /// contract — `notifyArbiterTimeout` sent silence, and no indexer could
    /// have corrected that.
    ///
    /// The PROPERTY guarded here, instead of the list that went stale twice:
    /// **every path of a judicial mistake has a log that names the arbiter**.
    /// `VerdictOverturned` and `ArbiterTimeoutRecorded` name him outright; the
    /// vote path does it through the pair `AppealResolved` (the dispute) and
    /// that dispute's verdict (`VerdictSubmitted` names the arbiter), because
    /// `AppealResolved` itself carries the appellant and `AppealVoteCast` a voter.
    ///
    /// How that is checked, so it does not rest on this paragraph. There are
    /// exactly as many paths as there are callers of `_recordArbiterMistake` —
    /// three today, and the list comes from a grep on its name, not from here.
    /// Recoverability of the streak from LOGS is played out by the scene `test_TheWholeRunIsRecoverableFromLogsWithATimeoutInIt`
    /// (test/ArbiterRemovalForCauseIntegration.t.sol): the streak "overturn,
    /// timeout, overturn" is assembled from topics, and removing either emit
    /// breaks it on the number of disputes found. The pair for the vote path is
    /// held by a scene in the subgraph's own test suite — there a panel overturn
    /// is attributed to the arbiter of the verdict.
    ///
    /// ⚠️ WHAT NOTHING GUARDS: a FOURTH path. Adding a caller of
    /// `_recordArbiterMistake` without giving it a log that names the arbiter
    /// passes with green tests — the scene above knows three and will not ask
    /// about a fourth. Same class as the allow-list inside
    /// `_recordArbiterMistake`, and cured the same way: name a new path by hand.
    ///
    /// The field itself stays ONE dispute and does not pretend to be a history:
    /// a reader who needs the whole streak reads the feed, not this field.
    ///
    /// An event is not part of a function selector — the facet's selector set is
    /// unchanged by this edit, and that was checked by hashing methodIdentifiers
    /// before and after rather than taken on faith.
    event ArbiterDemoted(
        address      indexed arbiter,
        address      indexed by,
        DemotionPath indexed path,
        address              agreement
    );
    event ArbiterResigned(address indexed arbiter, uint256 bondRefunded);
    event DisputeFeeCredited(address indexed arbiter, uint256 toArbiter, uint256 toTreasury);
    event TreasurySlicePushed(address indexed to, uint256 amount);
    event ArbiterFloorUpdated(uint256 amount);
    /// `amount` is what the PAYER handed over; `fromVault` is what the arbiter
    /// bank took off it. Their sum is the whole top-up the
    /// arbiter is promised, and it is booked in `disputeBounty`.
    ///
    /// The vault's half is put back on every exit that does not pay the
    /// arbiter, always in full, so the way back needs no log of its own — it
    /// carries no number this one does not already give. That is a byte
    /// budget talking as much as a design: the registry facet is at the
    /// EIP-170 ceiling.
    event DisputeBountyFunded(address indexed agreement, address indexed payer, uint256 amount, uint256 fromVault);
    event DisputeBountyRefunded(address indexed agreement, address indexed payer, uint256 amount);
    event DisputeBountyRefundable(address indexed agreement, address indexed payer, uint256 amount);
    event DisputeBountyWithdrawn(address indexed payer, uint256 amount);
    event DisputeDiscountUpdated(uint256 amount);

    // -------- ERRORS --------

    error NotOwner();
    error NotOwnerOrFeeRecipient();
    error NotOwnerOrChief();
    error NotOwnerOrDAO();
    error NotArbiter();
    error AlreadyArbiter();
    error NotAnArbiter();
    /// The seat is held; the money that makes the seat forfeitable is not.
    ///
    /// A NAMED refusal rather than a generic one, and that is the whole point
    /// of it (owner's requirement, 8 September 2026): a form that catches this
    /// selector can say "post your bond" and offer the button. A bare revert
    /// would reach the arbiter as an unexplained failure on a screen that had
    /// just told him he is an arbiter.
    error BondNotPosted();
    /// The seat has posted a bond and an appeal refund has drawn it below the
    /// norm (17 September 2026). It may finish the cases it holds; new work
    /// waits for the top-up, which takes only what is missing plus the seat's
    /// unpaid appeal debts.
    error BondBelowNorm(uint256 bond, uint256 norm);
    error AlreadyClaimed();
    error NotClaimed();
    error NotDisputed();
    error NotAuthorized();
    error CommitmentNotFound();
    error CommitmentTooEarly();
    error CommitmentExpired();
    /// ⚠️ NOTHING RAISES THIS ANY MORE (22 September 2026). It was the first
    /// line of `applyAsArbiter` and it is the line the owner's decision
    /// removed — self-enrolment no longer waits for governance. The type is
    /// KEPT, exactly as `InsufficientXP` below is kept: refusals already
    /// written into the chain's history stay decodable, and the relayer and the
    /// web client both map `0x6eb498a6` to this name by hand.
    error DAONotActive();
    error ZeroChatKey();
    error InsufficientXP(uint256 have, uint256 need);
    error NoVerdict();
    error DisputeWindowPassed();
    /// `abandonClaim` before the arbiter's window has run out — his four days
    /// are his, and nobody takes a live case off him.
    error DisputeWindowNotPassed();
    error NotLosingParty();
    error AlreadyAppealed();
    error AppealWindowClosed();
    error NoAppeal();
    error AlreadyVoted();
    error CannotVoteOnOwnVerdict();
    /// A party to the deal voting on the appeal against its own verdict
    /// (17 September 2026, journal item 199).
    error CannotVoteOnOwnDeal();
    /// Nothing to pull: no quorum was paid on this appeal, the caller did not
    /// vote on it, or he has already pulled his share.
    error NoAppealShare();
    error AppealAlreadyResolved();
    error AppealWindowNotClosed();
    /// All three seats on this appeal's panel are taken (23 September 2026).
    /// Not a fault of the caller's — he was fourth.
    error AppealPanelFull();
    /// The seats have not opened yet: nobody sits in the first
    /// APPEAL_SEAT_DELAY after an appeal is raised (24 September 2026).
    ///
    /// ⚠️ IT CARRIES THE MOMENT THEY OPEN, and that is the whole reason it is
    /// its own error rather than a bare refusal. "You cannot, and I will not
    /// say when" is the shape of refusal this repository keeps finding on the
    /// far side of a press somebody has already decided to make. With the
    /// timestamp in hand a screen says "in forty minutes"; without it the
    /// arbiter is left to guess whether the door is shut for an hour or for
    /// good.
    error AppealSeatsNotOpenYet(uint256 openAt);
    error AlreadyFinalized();
    /// The flag was written and never read back as a refusal, so three calls
    /// against the SAME agreement in the SAME block reached the demotion
    /// threshold — the price of unseating an arbiter was one submitted verdict,
    /// not three disputes.
    ///
    /// ⚠️ This error is only HALF of "one verdict, at most one judicial
    /// mistake". It shuts the hand pressing twice; it never touched the second
    /// way to book two, which ran through resolveAppeal and is closed there.
    /// Alone it was not the promise, and saying otherwise here would be the
    /// very class of documentation this branch keeps having to correct.
    error AlreadyOverturned();
    /// An overturn that changes nothing (found in review, 21 August
    /// 2026). Not a nicety: `overturned` is read as "the outcome differs from
    /// what the arbiter ruled", and an empty press made that false while
    /// costing the arbiter XP and a mistake. See overturnVerdict.
    error VerdictUnchanged();
    error VerdictFrozenError();
    error VerdictAlreadySubmitted();
    error NotTheClaimer();
    error VaultInsufficient();
    error NoRewardToClaim();
    error ArbiterZeroAddress();
    error InsufficientCleanStreak(uint256 have, uint256 need);
    error HasOpenDisputeClaims();
    error AppealInProgress();
    error NotRegisteredAgreement();
    error NothingToPush();
    // Its own error rather than NothingToPush: that one lives in
    // withdrawTreasurySlice. Both are decoded by the backend relayer (its own
    // FORWARDER_CUSTOM_ERRORS table, selectors 0x2d4e8c7b and 0x68d369c9), so the name
    // reaches a person verbatim — and a person collecting his own top-up would
    // otherwise see a message about a push he never made. The split works only
    // as long as both errors are in the decoder: miss one and raw hex arrives,
    // in which there is nothing left to tell apart.
    error NoRefundableBounty();
    error ZeroAmount();
    // The name reflects the check actually guarded: the arbiter comes from
    // pendingVerdicts, so the gate fires on a missing verdict rather than a
    // missing claimer (claim and verdict parted ways once the arbiter argument
    // was removed from creditDisputeFee — see the comment above that function).
    error NoVerdictSubmitted();
    error TopUpNotNeeded();
    error BountyAlreadyFunded();
    error DisputeAlreadyClaimed();
    error NotParty();
    error RewardPathRetired();

    // ── The "asked, no answer" record ──
    error NoResponseTooEarly();
    error NoResponseAlreadyRecorded();
    /// Kept separate from NotTheClaimer on purpose: that one answers on the
    /// verdict path, and a party who saw it after pressing "no answer" would
    /// decide the problem was with the verdict. Same meaning, different screens.
    error NotClaimingArbiter();
    error ClaimTimeUnknown();

    // ── Presentation digest ──
    /// Kept separate from NotParty on purpose, for the same reason
    /// NotClaimingArbiter is separate from NotTheClaimer: NotParty lives on the
    /// arbiter PAYMENT path (fundDispute), and whoever got it after asking to
    /// present a chat log would look for a money problem. One meaning, two screens.
    error NotDisputeParty();
    /// A zero digest is not a presentation but an empty line in the feed: zero
    /// has no preimage that anyone could ever show.
    error ZeroDigest();

    // ── Cap on the chief arbiter's bloc (renamed and recomputed
    // 16 August 2026) ──
    /// The chief cannot assemble a bloc that DECIDES an appeal WITH HIS OWN
    /// HANDS: otherwise his appointees settle the outcome of any appeal, and
    /// once removal goes to a vote, of any removal, including his own.
    ///
    /// ⚠️ THE PROMISE WAS NARROWED TO THE TRUTH. The earlier version promised
    /// the property ABSOLUTELY — "the chief cannot assemble a bloc". It rests on
    /// much less: on ONE door (`addArbiter`), for ONE presser (the chief), at
    /// ONE moment (the press). After that the invariant "bloc ≤ 1" is supported
    /// by nothing:
    ///
    ///   • the owner, seating the chief as an arbiter AFTER his appointee,
    ///     brings the bloc to a real two — measured, `getChiefBloc()` = 2;
    ///   • `applyAsArbiter` does not call `_chiefBloc` AT ALL, so once
    ///     governance is live an appointee can re-enter past the cap.
    ///
    /// This is no regression (under the earlier cap the same order gave 3) and
    /// no hole in today's sense: both loopholes are opened by the owner, and he
    /// is the one who hands out the chief's role. The honest formulation in one
    /// phrase: the property is guarded at the door THE CHIEF controls.
    /// The real cure is counting the bloc at the moment of the VOTE rather than
    /// of the seating; that is a design change and is not made here.
    ///
    /// ⚠️ The earlier name — ChiefBlocWouldReachQuorum — named the wrong
    /// property, and that was more dangerous than the number itself: the next
    /// reader would lean on the name. A quorum and a deciding majority are
    /// different quantities, and an appeal is settled by the second. An error
    /// name is not part of a FUNCTION selector, so the deploy cascade is
    /// untouched by the rename.
    /// ⚠️ NOTHING RAISES THIS ANY MORE (22 September 2026). It was raised in
    /// the branch of `addArbiter` that admitted the chief, and the chief no
    /// longer has that door: a cap on a bloc he cannot build is a cap on
    /// nothing. Kept as a type, like `DAONotActive` and
    /// `ReseatingRemovedIsOwnerOnly`.
    error ChiefBlocWouldDecideAppeal(uint256 bloc, uint256 decidingVotes);

    // ── Cap on disputes held at once ──
    error TooManyOpenClaims(uint256 held, uint256 cap);

    /// He is already reading a case. The slot is freed by the SIGNATURE of the
    /// verdict, not by its finalization — so the wait is his own reading time,
    /// never the delay plus the appeal window.
    error AlreadyJudgingACase();

    /// The bond this case asks for could not be pulled in — the USDC
    /// `transferFrom` came back false or the allowance was short. Named apart
    /// from `BondTransferFailed` (the seat bond, which nothing takes any more)
    /// so that a screen can say WHICH money was refused and offer the right
    /// approval.
    ///
    /// ⚠️ NO ARGUMENT, DELIBERATELY. What the case asks for is already a
    /// mounted read — `ArbiterVaultFacet.quoteAppealDeposit(deal)`, the same
    /// function that prices the bond — so carrying the number here would be a
    /// second copy of it that travels no further than the relay's decode table,
    /// which maps four bytes to a NAME and drops every argument. The empty
    /// parentheses are also what `script/check-allowance-marks.sh` can see: it
    /// reads `revert Name();` beside a pull, and a refusal it cannot read is a
    /// pull whose answer on the screen is unknown.
    error CaseBondTransferFailed();

    /// He holds a seat but has never carried a case of his own to a verdict
    /// that stood, so he does not vote on other arbiters' verdicts. Hand-seated
    /// arbiters (`seatedBy != 0`) are exempt — see `_mayVoteOnAppeals`.
    error NoAdjudicatedCase();

    // ── Teeth of a suspension ──
    /// The arbiter is suspended: he takes no disputes, his verdicts are not
    /// finalized, and he cannot resign. The last is no trifle: resignAsArbiter
    /// returns the bond in full, and without this ban a suspect leaves with the
    /// money in one transaction, and the money side of the punishment is a label.
    error ArbiterSuspendedError(uint256 until);

    // ── Teeth of a proposal (15 August 2026): the resignation door has to be
    // shut against a live accusation, not only against a suspension ──
    /// A third ban on the resignation door, symmetrical to ArbiterSuspendedError
    /// above — the same device against a DIFFERENT threat. A suspension does not
    /// serve here on its own: its window is 72 hours against the proposal's
    /// 14 days, and from the eleventh day the door is open again, even if the
    /// owner suspended in the very second he proposed. Without a separate ban the
    /// accused reads the public `RemovalProposed` on chain and leaves on his own
    /// in one transaction, carrying the whole bond away (resignAsArbiter returns
    /// the bond without remainder) — the only material sanction (the forfeit in
    /// removeArbiterForCause) is zeroed by reading a record the protocol itself
    /// published.
    error HasLiveRemovalProposal();

    // ── Handover of the corps to governance (15 August 2026): no hand-seated
    // ones, the person steps out and only the diamond stays, admitting people
    // through the gate ──
    /// activateDAO() is one-way and is undone nowhere: switching it on without
    /// having set daoAddress orphans the corps in one transaction — automation
    /// catches only what the chain sees, and seating or removing by hand becomes
    /// available to nobody.
    error DaoAddressNotSet();
    /// activateDAO before the threshold has been earned. The threshold stopped
    /// switching governance on by itself and became a condition of the manual
    /// switch — this refusal is all that is left of it. Both arguments are
    /// named so a form can show "how many of how many" rather than a blank "no".
    error DaoThresholdNotReached(uint256 uniqueActiveUsers, uint256 required);
    /// activateDAO while the protocol is not demonstrably running on its own —
    /// the SECOND condition, added 20 September 2026. Every term is named with
    /// what it has and what it needs, for the same reason
    /// `DaoThresholdNotReached` names both: a door that answers "no" without
    /// saying how far off it is cannot be read by a screen, and the owner ends
    /// up asking the chain by hand.
    ///
    /// ⚠️ IT CARRIES NO ARGUMENTS, unlike its neighbour above, and that is a
    /// MEASURED concession rather than a preference. Naming the terms and their
    /// floors in the revert itself cost 525 bytes in this facet, measured on
    /// 20 September 2026 against a facet that had 708 to spare under the 24 576
    /// the chain allows — it left 183, and the gate wants 512 so that the next
    /// fix still fits. The numbers are not lost: `getHandoverReadiness()` hands
    /// out every term, its floor and the shortfall, and it is the reading a
    /// screen was always going to call. A revert that repeats them buys
    /// nothing and spends the last of the room in the fullest facet in the
    /// repository.
    error HandoverNotLive();

    // ---- the eighteen sentences that used to be written out in full
    //      (20 September 2026) ----
    //
    // ⚠️ WHY TEXT WAS TRADED FOR CODES, AND IT WAS A MEASUREMENT, NOT TASTE.
    // Eighteen refusals of the shape `require(ok, "ArbiterRegistry:
    // DISPUTE_WINDOW read failed")` carried their English into the deployed
    // bytecode and cost 785 bytes of it — more than the whole of the handover
    // condition this commit adds. The facet stood 239 bytes under the EIP-170
    // limit with the gate asking for 512. A person never reads those bytes
    // anyway: the screen and the relayer both decode four bytes into a sentence
    // in the reader's own language, and an English string in the middle of a
    // page drawn in one of fourteen is the defect repaired on 4 September 2026.
    //
    // ⚠️ THE NAMES DISTINGUISH WHAT COULD NOT BE READ, and that is the whole
    // value of the trade. One `AgreementReadFailed` covering status, date,
    // window and parties would be four bytes that say "the deal did not answer"
    // and leave the reader exactly where a blank refusal does. Four separate
    // codes cost nothing extra — the revert sites already exist, only the
    // selector in them changes.
    //
    // ⚠️ EVERY ONE OF THESE IS A SEAM. `frontend/src/lib/moneyDoor.ts`
    // recognised `"ArbiterRegistry: deposit transfer failed"` by its TEXT to
    // tell a person his spending allowance had run out; replacing the text with
    // a code broke that silently, and its own test could not see it because the
    // test held the function against the same string the function carried.
    // `script/check-allowance-marks.sh` now reads THIS file for the refusals
    // that guard a pull of somebody's money and fails when the frontend no
    // longer knows one of them.

    /// The deal would not say what state it is in — `status()` reverted or is
    /// not there. The address is not an Agreement of this protocol, or is not a
    /// contract at all.
    error AgreementStatusUnreadable();
    /// The deal would not say WHEN it went into dispute — `disputedAt()` did
    /// not answer. Every window in this facet is measured from that moment, and
    /// a window this facet guessed at would be a window it invented.
    error DisputeDateUnreadable();
    /// The deal would not say HOW LONG the dispute window is —
    /// `DISPUTE_WINDOW()` did not answer. The length belongs to the deal, not
    /// to the registry: clones deployed against different implementations may
    /// legitimately carry different ones.
    error DisputeWindowUnreadable();
    /// The deal would not name its client and executor — `client()` or
    /// `executor()` did not answer. Without both, "the arbiter is not a party
    /// to this dispute" cannot be checked, and it is not assumed.
    error DealPartiesUnreadable();
    /// The registry could not hand itself the deal's arbiter seat, or could not
    /// give it back — `setArbiter(address)` reverted. Both directions share one
    /// code on purpose: the caller's situation is the same either way, the deal
    /// did not accept the registry as its judge.
    error ArbiterHandoffFailed();
    /// The arbiter's bond could not be pulled in — the USDC `transferFrom` came
    /// back false. In practice the standing allowance ran out between the read
    /// and the block. Recognised as such by `moneyDoor.ts`.
    error BondTransferFailed();
    /// The bond could not be handed back — the USDC `transfer` out came back
    /// false. NOT an allowance question: this one moves the protocol's own
    /// money outward, and a person meeting it has nothing to approve.
    error BondRefundFailed();
    /// The appeal deposit could not be pulled in — the USDC `transferFrom` came
    /// back false. Same situation, and the same sentence, as
    /// `BondTransferFailed`.
    error DepositTransferFailed();
    /// acceptDAOAddress called by someone other than the one named (or nobody
    /// was named: an empty proposal is the zero address, and it sends nothing).
    error NotProposedDaoAddress();
    /// addArbiter/setChiefArbiter: entry only through applyAsArbiter (past the
    /// gate), and the chief's role is abolished together with governance.
    ///
    /// ⚠️ ONE ERROR, TWO DIFFERENT CONDITIONS — and that is not carelessness
    /// (16 August 2026). `addArbiter` refuses on the handover of seating
    /// (`isDaoActive() && daoAddress != address(0)`,
    /// _requireSeatingNotHandedOver), `setChiefArbiter` on the abolition of the
    /// role (`isDaoActive()`), because appointing a powerless chief is pointless.
    /// A new error was deliberately not introduced: this text already names both
    /// halves, and an extra selector in the facet's ABI would cost a cut.
    error SeatingHandedOver();
    /// setDAOAddress after governance is live: only the daoAddress already in
    /// office may name a successor (self-migration), not the owner. Without this
    /// gate the owner could take removal for cause back with one extra
    /// transaction — activateDAO() → setDAOAddress(his_own_address) →
    /// removeArbiterForCause on the msg.sender == daoAddress branch — and "the
    /// person stepped out" would hold for only one of the two doors.
    error NotCurrentDaoAddress();

    // ── The weight of a suspension, second door (16 August 2026) ──
    /// Bringing a REMOVED arbiter back into the corps is an owner's action, out
    /// of the chief's reach. Undoing a removal is the mirror of a removal, and
    /// the chief may not remove at all.
    ///
    /// Found in review: the gate on `ArbiterAccountabilityFacet.liftSuspension`
    /// shut one door, while `addArbiter` led to the same place and stood open to
    /// the chief. `clearRemovalRecord(d, arbiter, true)` below erases `removedAt`
    /// AND `suspendedUntil` at once — so in one transaction the chief lifted the
    /// very window that holds the money on a removed arbiter's verdicts, and
    /// returned him to the registry with his claims untouched (a removal touches
    /// neither `disputeClaims` nor `openClaimCount`). Measured against a real
    /// diamond: `liftSuspension` reverts for the chief, `addArbiter` goes through.
    ///
    /// ⚠️ Why a refusal and not "bring him back but keep the suspension" (the
    /// soft variant was considered and rejected): `clearRemovalRecord(..., false)`
    /// would erase `removedAt`, leaving the window — and the very next
    /// transaction `liftSuspension` would pass its gate, the discriminator being
    /// zero already. The soft variant lengthens the bypass, it does not close it.
    ///
    /// Who is NOT affected: seating a new person and bringing back one who left
    /// voluntarily — `resignAsArbiter` does not write `removedAt`, so for them it
    /// is zero and the chief seats them as before. Who IS affected in addition:
    /// bringing back someone removed ON THE CHAIN'S ACCUSATION — `removedAt` is
    /// written by the shared removal body (`_performRemoval` in
    /// ArbiterAccountabilityFacet), identically for both doors, so undoing the
    /// automatic path is the owner's right alone. Intended: the chain's
    /// accusation has no author to argue with but whoever answers for the corps.
    ///
    /// ⚠️ The change of 18 August 2026 moved the MOMENT, not the rule: before it
    /// the third mistake set `removedAt` itself, now it is the press of
    /// `executeChainRemoval` two days later. While the accusation stands and the
    /// button is unpressed, `removedAt` is ZERO, the person is still in the
    /// corps, and this branch does not touch him at all.
    /// ⚠️ NOTHING RAISES THIS ANY MORE (22 September 2026), for the same
    /// reason as `ChiefBlocWouldDecideAppeal` above: both stood inside
    /// `addArbiter`'s non-owner branch, and there is no non-owner. Kept as a
    /// type — a refusal already in the chain's history stays decodable.
    error ReseatingRemovedIsOwnerOnly();

    // -------- MODIFIERS --------

    modifier onlyOwner() {
        if (OwnershipLib.contractOwner() != msg.sender) revert NotOwner();
        _;
    }

    // ⚠️ `onlyOwnerOrChief` STOOD HERE AND IS GONE (22 September 2026). It
    // guarded exactly one door in this facet — `addArbiter` — and that door is
    // the owner's alone now. The chief's remaining rights all live in
    // ArbiterAccountabilityFacet and are guarded by ITS copy of this modifier,
    // which is untouched: he proposes removals, suspends and answers. What he
    // may no longer do is CREATE a seat.
    //
    // `error NotOwnerOrChief()` above is kept although nothing in this facet
    // raises it: the two neighbouring facets declare the same error, a custom
    // error's selector is its signature, and an old refusal in the chain's
    // history is decoded by that selector and not by which contract declared it.

    // ⚠️ `onlyOwnerOrDAO` STOOD HERE AND IS GONE (9 October 2026). It guarded
    // exactly three doors in this facet -- `overturnVerdict`, `freezeVerdict`
    // and `unfreezeVerdict` -- and all three went in the same cut, so the
    // modifier had no user left. Same shape as `onlyOwnerOrChief` above, which
    // left the same way on 22 September 2026.
    //
    // ⚠️ AND THE DAO ADDRESS LOSES ITS LAST SHARED LEVER ON THIS FACET WITH IT.
    // It still holds doors on the accountability facet; what it no longer has
    // is any say over a verdict. That is the point of the cut rather than a
    // side effect of it.
    //
    // `error NotOwnerOrDAO()` above is kept although nothing in this facet
    // raises it, for the reason written at `NotOwnerOrChief`.

    // -------- ERC-2771 SENDER --------

    function _msgSender() internal view returns (address sender) {
        address forwarder = FactoryStorage.store().trustedForwarder;
        if (msg.sender == forwarder && msg.data.length >= 20) {
            assembly { sender := shr(96, calldataload(sub(calldatasize(), 20))) }
        } else {
            sender = msg.sender;
        }
    }

    // -------- DAO MODE --------

    /// Requires daoAddress to be set already. Without this check the owner could
    /// switch governance on before naming its address and orphan the corps in one
    /// transaction: activateDAO() is irreversible (the flag is cleared nowhere in
    /// src/), and removeArbiterForCause/addArbiter/setChiefArbiter no longer let
    /// the owner through after activation — with no ill intent, simply by mixing
    /// up the order of the setDAOAddress/activateDAO calls.
    ///
    /// ⚠️ Since 26 August 2026 a non-zero `daoAddress` means MORE than it used
    /// to: not "the owner named an address" but "the named address sent its own
    /// transaction". The check is the same, but what it proves now is that the
    /// door opens from the inside — see `acceptDAOAddress`.
    ///
    /// ⚠️ AND A SECOND CHECK, THE THRESHOLD — the very half that used to sit in
    /// `isDaoActive()` and switched governance on BY ITSELF. It did not vanish,
    /// it moved here and changed role: the corps having been earned is still a
    /// condition, but a person picks the moment. Below the threshold power
    /// cannot be handed over even by hand — otherwise the promise "governance
    /// moves when there are this many of you" would mean nothing.
    /// ⚠️ AND A THIRD CHECK, THE LIVENESS — added 20 September 2026 on the
    /// owner's decision of 19 September, and its MEASURE changed the same day.
    /// What he asked for was a handover the system itself could say it was
    /// ready for, measured on what is actually happening rather than on
    /// anything declared.
    ///
    /// The threshold above counts people who have EVER earned XP and never
    /// falls — that is right for a promise ("governance moves when there are
    /// this many of you" must not un-happen) and blind for a readiness test: it
    /// cannot tell a live protocol from a dead one with a long history. The
    /// THREE terms in `HandoverLib` are the present tense and the proof, and
    /// they live there so that `getHandoverReadiness()` refuses in exactly the
    /// same words this door does.
    ///
    /// ⚠️ THE FIRST DRAFT ASKED FOR VOLUME AND WAS WRONG BY A COUNT, not by
    /// taste: twenty disputes closed cleanly, ever. The flagship on-chain
    /// escrow of this kind has carried 286 deals and FOUR disputes in seven and
    /// a third years, and the nearest like-for-like freelance protocol has 18
    /// deals and none at all. Twenty disputes therefore means somewhere near
    /// fifteen hundred deals and several years — a door that cannot be opened,
    /// which from outside is indistinguishable from one that works. What
    /// replaced it asks whether the thing runs without him NOW: a live market,
    /// a RUN of clean disputes that any interference throws away, and a court
    /// of more than one man.
    ///
    /// ⚠️ THE ORDER OF THE THREE CHECKS IS PART OF THE ANSWER. The successor
    /// first, then the earned threshold, then liveness — cheapest and most
    /// fundamental first, so the owner who has not named a successor is told
    /// that, and not handed a report about disputes.
    function activateDAO() external onlyOwner {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (d.daoAddress == address(0)) revert DaoAddressNotSet();
        uint256 users = ReputationStorage.data().uniqueActiveUsers;
        if (users < DAO_THRESHOLD) revert DaoThresholdNotReached(users, DAO_THRESHOLD);
        if (!HandoverLib.met()) revert HandoverNotLive();
        d.daoActiveManual = true;
        emit DAOActivated(msg.sender);
    }

    /// @notice The named successor takes office with ITS OWN transaction.
    ///
    /// The second step, added 26 August 2026. Before it `setDAOAddress` took
    /// effect instantly and a mistake had no way back: a typo in the address, or
    /// an address whose keys are lost, and nobody could ever remove an arbiter
    /// again. One wrong letter cost the whole governance
    /// system.
    ///
    /// ⚠️ THIS IS NOT A SCREENING OF THE CANDIDATE. Nobody "applies" —
    /// `daoAddress` is the governance contract or the multisig the owner deploys
    /// himself. The confirmation checks not consent but that somebody is at that
    /// address at all and can send a transaction.
    ///
    /// Raw `msg.sender`, not `_msgSender()`, and that too is part of the proof:
    /// a gasless path would prove that someone signed a message, whereas the
    /// call must come FROM THE ADDRESS ITSELF — a governance contract signs no
    /// EIP-712 messages at all.
    ///
    /// A zero `pendingDaoAddress` needs no branch of its own: there is no
    /// transaction from `address(0)`, so the same line answers "no proposal".
    function acceptDAOAddress() external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        address pending = d.pendingDaoAddress;
        if (msg.sender != pending) revert NotProposedDaoAddress();
        d.pendingDaoAddress = address(0);
        d.daoAddress = pending;
        emit DAOAddressSet(pending);
    }

    /// @notice Put yourself in the arbiter corps. One condition, and it is a
    /// record of work.
    ///
    /// ⚠️ THE GOVERNANCE GATE IS GONE FROM THIS DOOR (22 September 2026, the
    /// owner's decision), and that is the change rather than a relaxation of
    /// it. `if (!isDaoActive()) revert DAONotActive();` stood on the first
    /// line, and `isDaoActive()` is switched on by `activateDAO()` — which
    /// needs a confirmed successor, a threshold of earned reputation and a
    /// live court. So the ladder this protocol advertises — work cleanly, then
    /// judge — ENDED IN A WALL: the only way into the corps was the owner's own
    /// hand, and the automatic door could not be reached until after the very
    /// handover it was supposed to prepare for.
    ///
    /// What is left standing in its place is the thing that was always meant to
    /// be the filter: a RUN OF CLEAN DEALS, five of them, each with a
    /// counterparty that carried standing of its own. It cannot be bought and it
    /// cannot be manufactured by a ring of fresh wallets — see
    /// `MIN_COUNTERPARTY_XP` in ReputationFacet.
    ///
    /// ⚠️ `DAONotActive` IS NOT DELETED AS A TYPE. Refusals already in the
    /// chain's history have to stay decodable, and a relayer that maps the
    /// selector to a name keeps working. Nothing raises it any more.
    ///
    /// GASLESS, AND WITHOUT A DOOR OF ITS OWN. The sender is `_msgSender()`, so
    /// the whole call relays through the `MinimalForwarder`; and since
    /// 22 September 2026 the seat costs nothing, so there is no allowance and no
    /// permit to carry with it. The neighbour `postArbiterBondWithPermit` was
    /// written for exactly the beggar's problem this door has — a candidate has
    /// earned nothing IN the protocol, so he has no ETH from it — and it is not
    /// needed here, because nothing in this transaction touches a token. The
    /// proof is a measurement, not this paragraph:
    /// test/ArbiterSelfEnrolment.t.sol drives this selector through a real
    /// forwarder from an address holding zero wei.
    function applyAsArbiter() external {
        address caller = _msgSender();
        ReputationStorage.Data storage rep = ReputationStorage.data();

        // ONE TEST, AND IT IS THE STREAK (20 September 2026). The XP comparison
        // that used to stand here is gone, not relaxed: see MIN_XP_TO_REGISTER.
        //
        // The streak is not the weaker half of the pair it used to belong to —
        // it is the harder one to manufacture. XP could be bought with volume
        // (a big deal pays volume XP), whereas a streak only moves on a deal
        // whose COUNTERPARTY already carried standing of its own, which is what
        // MIN_COUNTERPARTY_XP over in ReputationFacet is for. A ring of fresh
        // wallets can run up neither.
        uint256 streak = rep.cleanStreak[caller];
        if (streak < MIN_CLEAN_STREAK_TO_REGISTER) revert InsufficientCleanStreak(streak, MIN_CLEAN_STREAK_TO_REGISTER);

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (d.isArbiter[caller]) revert AlreadyArbiter();

        // Half a year after an involuntary removal this door opens again — and
        // before that it does not. Until 22 September 2026 nothing stood here
        // at all: a man the chain had just unseated for three wrong verdicts
        // could walk back in the same block, paying one bond.
        ArbiterRegistryStorage.requireCooldownPassed(d, caller);

        // ⚠️ RULE A AND THE SEAT BOND ARE BOTH GONE FROM THIS DOOR
        // (22 September 2026, the owner's decision). It used to demand an empty
        // board and 50 USDC to sit down; it now demands neither, because a bond
        // is posted per CASE and an arbiter is an ordinary user of the market
        // until he takes one. The argument is at `_requireStillSeated`.
        //
        // What that means for this function in particular: it no longer moves
        // money at all, so there is no transfer to order the checks around and
        // no way to end up with a payment and no seat.
        d.isArbiter[caller] = true;
        d.arbiterList.push(caller);

        // Marks of a past removal (if any) do not survive a re-seating —
        // respondToRemoval judges the CURRENT status, not ancient history.
        //
        // ⚠️ liftSuspension = FALSE — a self-registration does NOT lift the
        // suspension (owner's decision on this seam, 16 August 2026): it is
        // imposed by the owner or the chief, so lifting it is not the arbiter's
        // to do. Otherwise a man removed for cause would buy a bypass of the
        // 72-hour window for one fresh bond: back in, and finalizing verdicts
        // claimed before the removal without waiting the window out.
        ArbiterRegistryStorage.clearRemovalRecord(d, caller, false);

        emit ArbiterAdded(caller);
        emit ArbiterApplied(caller);
        // Self-registration: seatedBy stays zero — that is the mark of "seated
        // himself". The event fires anyway, so a reader has one stream, not two.
        emit ArbiterSeated(caller, address(0), true);
    }

    /// @notice Voluntary exit from arbiter status, with no penalty. Returns the bond
    /// in full. Without it, arbiter status would be a one-way road for anyone who was
    /// never demoted — the bond would stay locked forever at the moment a person
    /// simply wants to stop.
    function resignAsArbiter() external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        _requireNotSuspended(d, caller);
        _requireNoLiveRemovalProposal(d, caller);
        if (!d.isArbiter[caller]) revert NotAnArbiter();
        if (d.openClaimCount[caller] > 0) revert HasOpenDisputeClaims();

        d.isArbiter[caller] = false;

        uint256 len = d.arbiterList.length;
        for (uint256 i = 0; i < len; i++) {
            if (d.arbiterList[i] == caller) {
                d.arbiterList[i] = d.arbiterList[len - 1];
                d.arbiterList.pop();
                break;
            }
        }

        // ⚠️ NOTHING IS PAID OUT HERE ANY MORE (22 September 2026), AND THAT
        // IS THE CHANGE RATHER THAN A LOSS. A seat holds no money to give back:
        // the bond is posted per CASE and comes home when the case closes, and
        // `openClaimCount` above already refuses to let a man leave while he
        // still holds one. So an arbiter walks out of the corps owning exactly
        // what he owned when he walked in.
        //
        // What went with the payout, said out loud: his unpaid appeal debts
        // used to be taken out of the seat bond on the way out. There is no
        // seat bond to take them from, so they stay where the other two ways
        // out already pay them — the bank's queue (`settleAppealDebts`, anyone
        // may press it) and his own forfeited share of the dispute fee when the
        // overturned verdict finally executes.
        //
        // `arbiterBond` is deliberately not read and not written: after the
        // cut's refund of the four live seats it is zero everywhere and stays
        // zero, and reading a field nothing writes would only keep a dead rule
        // looking alive.
        ArbiterRegistryStorage.clearSeat(d, caller);

        // Zero, and it is a fact rather than a formality — the same shape and
        // the same reason as `ArbiterApplicationApproved`'s bond field, which
        // has read zero since seating and paying came apart: the event keeps
        // its signature because a live subgraph indexes it, and it reports what
        // THIS transaction moved, which is nothing.
        emit ArbiterResigned(caller, 0);
    }

    /// The seat alone is not the right to act — and since 22 September 2026
    /// the thing that makes it one is not a standing bond.
    ///
    /// ── WHAT THIS REPLACES ────────────────────────────────────────────────
    /// Until now a man locked 50 USDC to SIT, and waited — possibly a year —
    /// for a dispute that might never come. The money bought nothing while it
    /// waited, and the real price of the seat was not the 50 USDC at all: rule
    /// A and rule B together threw him off the boards entirely, so what he
    /// actually paid was his living.
    ///
    /// The owner's decision: the bond is posted WHEN HE TAKES A CASE, sized to
    /// that case, and taken home when his verdict has stood. Everything the
    /// standing bond was carrying comes apart with it:
    ///
    ///   • a "sagging" bond has no meaning left — every case carries its own
    ///     money, so one wrong verdict cannot leave the next case underfunded;
    ///   • the two gates below collapse into one question each door can ask
    ///     for itself: does he hold the seat, and is his slot free;
    ///   • rule A (a seat may only be taken by somebody with nothing open on
    ///     the boards) is gone. He is an ordinary user who steps away for a few
    ///     days to judge;
    ///   • rule B narrows from "an arbiter may never be a party" to "he does
    ///     not trade WHILE HE IS JUDGING" — `MarketPresence.requireNotJudging`.
    ///
    /// ⚠️ WHAT WENT WITH IT, SAID OUT LOUD RATHER THAN DISCOVERED LATER: a
    /// removal for cause used to forfeit 50 USDC, and now it forfeits nothing,
    /// because there is nothing standing there to forfeit. The seat is free, so
    /// the sanction for a bad arbiter is the record, the suspension and the
    /// loss of the seat — not money. The hole that opens with a free seat (a
    /// paid vote in an appeal bought by a seat that cost nothing) is closed by
    /// `_mayVoteOnAppeals`, not by a bond.
    ///
    /// ⚠️ `arbiterBond` IS NOT DELETED and is written by nothing from here on.
    /// The layout is append-only; the four live seats that held 50 USDC in it
    /// were paid back by the cut's own initialiser, and every read of it answers
    /// zero now.
    function _requireStillSeated(ArbiterRegistryStorage.Data storage d, address who) private view {
        if (!d.isArbiter[who]) revert NotArbiter();
    }

    /// Who may vote on somebody else's verdict.
    ///
    /// ⚠️ THE SEAT IS FREE NOW, SO THE SEAT CANNOT BE THE ANSWER. A paid vote
    /// on an appeal, reachable by anybody willing to fill a corps with
    /// addresses, is the hole a free seat opens; the bond used to be what stood
    /// in the way. The owner's replacement is a record of WORK: one case of his
    /// own, carried to a verdict that stood (`cleanVerdicts`, incremented in
    /// `finalizeVerdict` on the branch where the verdict was not overturned).
    ///
    /// It is not money on purpose. Nothing sits above the panel, so a bad vote
    /// has nothing to be punished with — and a price on the vote would filter
    /// out the poor rather than the dishonest.
    ///
    /// ⚠️ THE BOOTSTRAP IS `seatedBy != 0` AND IT IS LOAD-BEARING. On the day
    /// this lands the chain holds four hand-seated arbiters and no clean verdict
    /// counted for the purpose; without this half, the first appeal ever raised
    /// would have nobody at all entitled to review it. A hand-seated arbiter was
    /// chosen by a person who answers for the choice — that is the standing the
    /// counter would otherwise have to prove.
    ///
    /// ⚠️ IT IS ASKED OF ONE MAN AND NEVER OF THE ROSTER (23 September 2026).
    /// `_eligibleVoterCount` used to call this in a loop over `arbiterList` at
    /// the appellant's expense; that loop is gone and must not come back. The
    /// only caller is `voteOnAppeal`, on the arbiter pressing the button.
    function _mayVoteOnAppeals(ArbiterRegistryStorage.Data storage d, address who)
        private
        view
        returns (bool)
    {
        return d.seatedBy[who] != address(0) || d.cleanVerdicts[who] != 0;
    }

    /// Takes the bond this case asks for and books it against the deal.
    ///
    /// The size is `appealDepositFor(agreement)` — the percentage of the pot
    /// an appeal on this same deal costs, floored at 20 and capped at 200 USDC.
    /// Called, never copied: the bond has to cover exactly one refund to an
    /// appellant, and two copies of one formula agree only until the first edit.
    function _takeCaseBond(
        ArbiterRegistryStorage.Data storage d,
        address agreement,
        address arbiterAddr
    ) private {
        // ⚠️ A BOND THE PREVIOUS CLAIMER HAS NOT COLLECTED IS MOVED OUT OF THE
        // WAY FIRST, AND THAT IS NOT HOUSEKEEPING. A deal can be claimed again
        // after a release, an abandonment or a timeout, and the man who let go
        // collects his bond with `withdrawCaseBond` whenever he gets round to
        // it. Writing the new bond over his record would take his money and
        // give it to the new claimer; refusing until he collects would let one
        // arbiter's inaction block a deal that needs a judge. So it becomes a
        // claimable of his, and the slot is free.
        ArbiterRegistryStorage.CaseBond memory stale = d.caseBonds[agreement];
        if (stale.amount != 0) {
            d.refundableBounty[stale.arbiter] += stale.amount;
            emit DisputeBountyRefundable(agreement, stale.arbiter, stale.amount);
        }

        uint256 amount = ArbiterRegistryStorage.appealDepositFor(agreement);
        if (amount == 0) return;
        address usdc = FactoryStorage.store().usdc;
        if (!IUSDCFull(usdc).transferFrom(arbiterAddr, address(this), amount)) {
            revert CaseBondTransferFailed();
        }
        // uint96 cannot truncate: amount <= APPEAL_DEPOSIT_CAP.
        d.caseBonds[agreement] = ArbiterRegistryStorage.CaseBond(uint96(amount), arbiterAddr);
        emit CaseBondPosted(agreement, arbiterAddr, amount);
    }

    /// Hands back whatever of this case's bond is still there and forgets it.
    ///
    /// ⚠️ SOFT WHEREVER IT PUSHES AT ALL. It is called from inside
    /// `finalizeVerdict`, which is also the call that moves the parties'
    /// escrow; a hard transfer there would let an arbiter the token stopped
    /// serving wedge the deal's own payout. What does not land goes to
    /// `refundableBounty` and is pulled with `withdrawDisputeBounty`.
    ///
    /// ⚠️ CALLED FROM ONE PLACE ONLY — `finalizeVerdict`, the happy ending,
    /// where a second transaction to collect would be an insult. Every OTHER
    /// way a case leaves an arbiter (he let go, a stranger abandoned it, the
    /// deal timed out) leaves the record standing and he collects it himself
    /// with `ArbiterVaultFacet.withdrawCaseBond`.
    ///
    /// That is not a preference, it is the clone's gas cap. `clearDisputeClaim`
    /// is called BY THE CLONE with exactly CLAIM_CLEAR_GAS (200 000) inside an
    /// empty try/catch, and a clone is pinned to its implementation for life,
    /// so that number can never be raised for a deal that already exists. A
    /// push there cost a measured +46 000 gas and tripped the rig's own
    /// tripwire (test/DisputeVaultDiscountGasCap.t.sol, which asks for 2x
    /// headroom, not merely for being under the cap): 74 746 → 120 658 of
    /// 100 000 allowed. Over the cap the catch swallows everything, and what it
    /// would swallow is the release of the claim itself — the arbiter would
    /// keep an open dispute for ever, which is the exact dead end `abandonClaim`
    /// was written to close.
    function _releaseCaseBond(ArbiterRegistryStorage.Data storage d, address agreement) private {
        ArbiterRegistryStorage.CaseBond memory b = d.caseBonds[agreement];
        if (b.amount == 0) return;
        delete d.caseBonds[agreement];
        if (_softTransfer(FactoryStorage.store().usdc, b.arbiter, b.amount)) {
            emit CaseBondReturned(agreement, b.arbiter, b.amount);
        } else {
            d.refundableBounty[b.arbiter] += b.amount;
            emit DisputeBountyRefundable(agreement, b.arbiter, b.amount);
        }
    }

    /// Frees the judging slot. Called where a case leaves the arbiter WITHOUT a
    /// verdict (release, abandon, timeout); `submitVerdict` frees it too, on
    /// the signature, which is the whole point of the counter.
    function _freeJudgingSlot(ArbiterRegistryStorage.Data storage d, address who) private {
        uint256 held = d.judgingCount[who];
        if (held > 0) d.judgingCount[who] = held - 1;
    }


    // -------- ADMIN: MANAGE ARBITERS --------

    /// The chief's role is abolished together with governance activation
    /// (decided 15 August 2026: no hand-seated ones, the person steps out and
    /// only the diamond stays, admitting people through the gate). A ratchet:
    /// isDaoActive() is irreversible, and after the handover nobody at all can
    /// appoint a new chief.
    ///
    /// ⚠️ THE PREDICATE HERE IS THE ABOLITION OF THE ROLE, NOT THE HANDOVER OF
    /// SEATING (16 August 2026). It is NOT the same condition as in
    /// addArbiter, and the two drifted apart on live state:
    ///
    ///   • the chief's role is ABOLISHED when `isDaoActive()` — that is how the
    ///     `onlyOwnerOrChief` modifier in ArbiterAccountabilityFacet works
    ///     (this facet's copy is gone, with the only door it guarded): under
    ///     live governance it does not see a chief at all, and none of his
    ///     rights remain;
    ///   • seating is HANDED OVER when `isDaoActive() && daoAddress != address(0)`
    ///     (_requireSeatingNotHandedOver) — the condition there is weaker on
    ///     purpose: until a successor is named, nobody but the owner can seat
    ///     arbiters, and he must be able to.
    ///
    /// In between — governance earned, successor not yet written down — the
    /// earlier version wrote the slot and fired the event even though the
    /// appointed chief is already powerless: no function will let him through.
    /// `getChiefArbiter()` honestly returned an address while the public
    /// docs/DECENTRALIZATION.md said the role no longer exists. A function about
    /// the chief's ROLE must refuse when the role is gone.
    ///
    /// `addArbiter` below does NOT change its predicate: it is about seating
    /// arbiters, and its condition is right.
    function setChiefArbiter(address arbiter) external onlyOwner {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (isDaoActive()) revert SeatingHandedOver();
        emit ChiefArbiterSet(d.chiefArbiter, arbiter);
        d.chiefArbiter = arbiter;
    }

    /// The handover of the seating right latches ONLY when a successor really
    /// exists (16 August 2026) — by the same device already applied to
    /// setDAOAddress, whose docstring carries the fuller version of this
    /// argument.
    ///
    /// ⚠️ THE ONLY CALLER IS `addArbiter` (16 August 2026).
    /// `setChiefArbiter` no longer calls this check: it is about the chief's
    /// ROLE and refuses on abolition (`isDaoActive()`), not on the handover of
    /// seating — see its docstring above.
    ///
    /// ⚠️ WHY THIS QUALIFIER WAS NEEDED — AND WHY IT STAYS THOUGH THE REASON
    /// IS GONE (26 August 2026).
    ///
    /// It was needed for this. The earned threshold switched governance on BY
    /// ITSELF, through the action of strangers, bypassing `activateDAO()` and
    /// its `DaoAddressNotSet` guard (which stands only inside). Governance then
    /// also became an irreversible lock on addArbiter/setChiefArbiter — so a
    /// STRANGER permanently stripped the owner of the right to seat arbiters,
    /// with a zero successor and without a single transaction from here. The
    /// qualifier kept the owner in play exactly while nobody could be handed it.
    ///
    /// The reason is gone: `isDaoActive()` now reads one manual flag, and
    /// `activateDAO()` requires an already CONFIRMED successor — so "governance
    /// on while daoAddress is zero" is unreachable through the real doors, and
    /// the expression collapses to `isDaoActive()`.
    ///
    /// The qualifier is kept deliberately, as a belt: if a second way to switch
    /// on is ever added — automatic, emergency, whatever — a removed qualifier
    /// orphans the corps irreversibly, and the first report of it would arrive
    /// from a person whose button stopped working. It is guarded by
    /// test_ActiveDaoWithoutSuccessorLeavesRemovalWithTheOwner and
    /// test_HandoverPredicateMatchesSeatingPredicate — both through a direct
    /// storage write, because that state is unreachable otherwise.
    ///
    /// ⚠️ AND HERE STOOD "THE FIX IS NOT IN isDaoActive() (TEMPTING, BUT NO)",
    /// and that stopped being true. The fix went into `isDaoActive()` — by the
    /// owner's decision, not as a side effect. The argument "the treasury is
    /// deployed and immutable, moving the moment moves money" holds today too,
    /// and the consequence was accepted knowingly: the foundation's share
    /// (70% → 20% in `Treasury.distribute`) now switches when a person pressed,
    /// not when outsiders filled a counter. That is exactly the point — a
    /// handover of power must have someone who performed it.
    function _requireSeatingNotHandedOver(ArbiterRegistryStorage.Data storage d) private view {
        if (isDaoActive() && d.daoAddress != address(0)) revert SeatingHandedOver();
    }

    /// @notice Seat a man by hand. THE OWNER'S, AND NOBODY ELSE'S.
    ///
    /// ⚠️ THE CHIEF LOST THIS DOOR ON 22 SEPTEMBER 2026 (the owner's
    /// decision), and the argument is what the door IS rather than who held it.
    /// Every other entrance to the corps measures something: the self-service
    /// one asks for five clean deals with counterparties that carried standing
    /// of their own. This one asks for nothing at all — it is a name and a
    /// press. That makes it the widest hole in the corps, and until today it
    /// was held by a man who had himself been APPOINTED: an appointee could
    /// seat, and the only thing standing between him and a bloc of his own was
    /// a cap counted here.
    ///
    /// The cap went with the power rather than being kept beside it. A limit on
    /// a door nobody but the owner can press is a limit on the owner, and he is
    /// the one who decides the composition; the thing the cap defended against
    /// — an appointee building a bloc that decides appeals — cannot happen
    /// through a door he cannot open. `ChiefBlocWouldDecideAppeal` and
    /// `ReseatingRemovedIsOwnerOnly` are therefore raised by nothing any more
    /// and are kept only as types.
    ///
    /// What the chief KEEPS is everything that is not a seat: proposing a
    /// removal, suspending, answering. The rule the owner set for that role is
    /// that it restores and accuses but does not create.
    ///
    /// ⚠️ AND THE DOOR STILL DIES AT THE HANDOVER. Once governance is live
    /// and a successor is named, nobody seats by hand at all —
    /// `_requireSeatingNotHandedOver` — and `applyAsArbiter` is the only
    /// entrance left. That is unchanged, and it is the whole reason this door is
    /// allowed to exist in the meantime.
    ///
    /// ⚠️ THE HALF-YEAR COOLDOWN IS NOT ASKED HERE, and it was not before
    /// either: it stood inside the branch this change deletes, and the owner was
    /// exempt from it there for the reason he is exempt from it now. He reverses
    /// HIS OWN removals with one press, and a cooldown binding him would turn a
    /// mistaken removal into a half-year sentence nobody could lift.
    function addArbiter(address arbiter) external onlyOwner {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        _requireSeatingNotHandedOver(d);
        if (d.isArbiter[arbiter]) revert AlreadyArbiter();

        // ⚠️ RULE A IS GONE FROM THIS DOOR TOO (22 September 2026). It used to
        // refuse a seat to anybody with a job, a service, an application or a
        // deal open, and it bound the owner as well — the seat cost a man his
        // living, which is the price the owner set out to stop charging. An
        // arbiter is an ordinary user of the boards; what he may not do is
        // trade WHILE he is reading a case, and that is held at the boards'
        // own doors (`MarketPresence.requireNotJudging`), not here.

        d.isArbiter[arbiter] = true;
        d.arbiterList.push(arbiter);

        d.seatedBy[arbiter] = msg.sender;
        d.seatedCountBy[msg.sender]++;
        emit ArbiterSeated(arbiter, msg.sender, false);

        // Marks of a past removal (if any) do not survive a re-seating —
        // respondToRemoval judges the CURRENT status, not ancient history. A
        // real scenario: the owner corrects a mistaken removal with one
        // addArbiter command.
        //
        // ⚠️ liftSuspension = TRUE — and only here (owner's decision on this
        // seam, 16 August 2026). The owner reverses HIS OWN decision: bringing a
        // man back with an unexpired suspension means bringing him back mute —
        // he can neither claim, nor finalize, nor resign, and nothing on the
        // chain shows why, except getSuspendedUntil.
        ArbiterRegistryStorage.clearRemovalRecord(d, arbiter, true);

        emit ArbiterAdded(arbiter);
    }

    // removeArbiter(address) was deleted on 15 August 2026. It removed an arbiter
    // with no cause and no record of who pressed, and returned the bond in full —
    // a deserved removal and a quiet purge looked the same on chain and cost the
    // same. The replacement is ArbiterAccountabilityFacet.removeArbiterForCause.
    // The selector is unmounted by the UpgradeArbiterAccountability cut.

    // -------- ARBITER: CLAIM DISPUTE --------

    function commitDisputeClaim(bytes32 commitment) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (!d.isArbiter[caller]) revert NotArbiter();
        // Gated at the COMMIT and not only at the reveal: a refusal an hour
        // before the arbiter has arranged anything is kinder than one at the
        // moment he reaches for the dispute, and it costs one SLOAD.
        //
        // ⚠️ THE QUESTION CHANGED WITH THE BOND (22 September 2026). It used to
        // be "is your seat bond whole"; there is no seat bond any more, and the
        // money for a case is taken at the reveal, where the case — and so its
        // price — is known. What can still be asked an hour early is the SLOT:
        // an arbiter already reading a case will be refused at the reveal, and
        // hearing it now costs him one SLOAD instead of a wasted commitment.
        if (d.judgingCount[caller] >= ArbiterRegistryStorage.caseSlotsFor(d, caller)) revert AlreadyJudgingACase();
        d.claimCommitments[commitment] = block.number;
        emit DisputeClaimCommitted(caller, commitment);
    }

    /// Publish or replace the public halves of one's own chat keys.
    ///
    /// Needed separately from a dispute claim for one case: an arbiter who loses
    /// the key AFTER claiming gets stuck — the address on chain is the same, but
    /// there is nothing to read the presentation with, and re-presenting to the
    /// same key does not help. With this function the loop closes itself:
    /// publish a new one → the parties' apps notice by the event → re-present.
    ///
    /// The address comes from the sender; there is NO "to whom" argument at all:
    /// another person's key cannot be written not because of a check, but
    /// because there is nowhere to write it.
    ///
    /// ⚠️ The exception where the loop does NOT close itself: the gate here is
    /// `isArbiter`, and it drops (removeArbiterForCause / resignAsArbiter /
    /// demotion on 3 mistakes in a row) without clearing an already written key.
    /// An arbiter who loses status with an open dispute in hand can no longer
    /// rotate his key (this function reverts `NotArbiter`), while
    /// `getArbiterChatKeys` still hands out the old one — alive-looking, with
    /// nobody able to replace it. `submitVerdict` does not cover this case: it
    /// checks only `disputeClaims`, never `isArbiter`. The real cure (allowing
    /// rotation while `openClaimCount` is non-empty) changes rights and is
    /// deliberately not implemented here.
    function setArbiterChatKey(bytes32 boxKey, bytes32 signKey) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (!d.isArbiter[caller]) revert NotArbiter();
        // Publishing the key a party seals a presentation to is arbiter work
        // like any other, and the seat check one line up is the whole of it.
        //
        // ⚠️ IT USED TO ASK ABOUT A BOND AND NO LONGER DOES (22 September
        // 2026). The rule it carried — a seat an appeal had drawn down still
        // finishes the cases it holds — died with the standing bond itself:
        // every case now carries its own money, so there is no such thing as a
        // seat that is short. What is left is the half that always mattered
        // here, and it is held by `isArbiter` above: a man removed for cause
        // keeps his claims but stops being able to work them.
        if (boxKey == bytes32(0) || signKey == bytes32(0)) revert ZeroChatKey();

        // The event fires only if at least one half actually changed. The write
        // happens always (it is idempotent and cheaper than branching) — the
        // condition wraps the emit alone. The reason lies in the presentation
        // flow, not here: it re-presents ON THE EVENT, and an identical rewrite
        // — an ordinary no-op from the frontend (a repeated call, a race between
        // tabs) — would otherwise force it to re-encrypt and re-upload the chat
        // log for every open dispute of that arbiter, though the key never moved.
        bool changed = d.arbiterBoxKey[caller] != boxKey || d.arbiterSignKey[caller] != signKey;
        d.arbiterBoxKey[caller]  = boxKey;
        d.arbiterSignKey[caller] = signKey;
        if (changed) emit ArbiterChatKeySet(caller, boxKey, signKey);
    }

    /// @notice Claiming a dispute. The Diamond is set as the arbiter in the Agreement (not the arbiter himself).
    /// That lets the Diamond control the execution of the verdict (delay, overturn).
    ///
    /// The chat keys are MANDATORY arguments, held by the shape of the argument
    /// and not by a check: the contract cannot tell a real key from two junk
    /// bytes32 — the shape only makes it impossible to claim a dispute while
    /// sending nothing at all. That closes the case WITHOUT ill intent (forgot,
    /// device not set up). An arbiter who deliberately brings junk instead of a
    /// key is not stopped by the shape: he gets the same outcome, while the
    /// parties re-encrypt the chat log to a key nobody owns, all for nothing.
    /// A deliberate refusal to read is closed by DETECTION, not by the shape of
    /// an argument — that is the work of the parts that follow, not of this one.
    ///
    /// Every claim OVERWRITES the keys. ⚠️ It used to say here that this "cures
    /// a device change by itself" — that is wrong, and was corrected on
    /// 9 August after reading the frontend code. For an ORDINARY wallet the chat
    /// key is deterministic: it is derived from a signature over fixed typed
    /// data (all 65 bytes of the signature go into the seed), and ordinary
    /// wallets sign deterministically (RFC 6979). So the same wallet on a new
    /// device yields THE SAME key, the key published on chain stays alive, and
    /// there is nothing to cure.
    ///
    /// The overwrite is needed where the key really dies, and there are two:
    ///  1. a contract wallet — the key there is random rather than derived, and
    ///     without the recovery code (12 words) a new device produces another;
    ///  2. a Safe with threshold 1 — it returns exactly 65 bytes signed by the
    ///     owner, so it is detected as an ordinary wallet while the key is in
    ///     fact derived from the OWNER'S signature. Owner changed, key changed,
    ///     and no recovery code is issued to that kind.
    /// Plus the general case: the key is simply lost. For these cases there is
    /// also setArbiterChatKey — no need to wait for a claim.
    ///
    /// ⚠️ This function's selector changed on 9 August 2026. The old
    /// `claimDispute(address,bytes32)` was unmounted by the same diamondCut —
    /// keeping it would have meant a second road on which a dispute is claimed
    /// WITHOUT a key, that is, exactly the hole this change closes.
    function claimDispute(
        address agreement,
        bytes32 salt,
        bytes32 boxKey,
        bytes32 signKey
    ) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        if (!d.isArbiter[caller]) revert NotArbiter();

        // ⚠️ THE SELECTION ITSELF. This is where a man becomes the judge of a
        // real escrow — and since 22 September 2026 it is also where he pays
        // for the right to be one. The bond is posted HERE, against THIS case,
        // priced by this case's own stake, and it goes home when his verdict
        // has stood. The transfer itself is at the foot of this function,
        // after every refusal: a bond taken before a check that then refuses
        // would leave his money on the diamond with no case behind it.
        //
        // The two caps, and they are different questions:
        //
        //   • ONE CASE AT A TIME. Released by the signature of the verdict,
        //     so the wait is his own reading time and not the finalization
        //     delay plus the appeal window.
        //   • TEN CLAIMS AT ONCE. Released when the deal lets go of him. Sign,
        //     take the next, sign, take the next — the first cap does not stop
        //     that, and this one does.
        //
        // Both before the staticcalls into Agreement: a refusal must be cheap,
        // not four reads of a foreign contract deep.
        if (d.judgingCount[caller] >= ArbiterRegistryStorage.caseSlotsFor(d, caller)) revert AlreadyJudgingACase();

        uint256 held = d.openClaimCount[caller];
        if (held >= MAX_CLAIMS_PER_ARBITER) revert TooManyOpenClaims(held, MAX_CLAIMS_PER_ARBITER);

        _requireNotSuspended(d, caller);

        if (boxKey == bytes32(0) || signKey == bytes32(0)) revert ZeroChatKey();
        if (d.disputeClaims[agreement] != address(0)) revert AlreadyClaimed();

        bytes32 commitment = keccak256(abi.encodePacked(agreement, caller, salt));
        uint256 committedAt = d.claimCommitments[commitment];
        if (committedAt == 0) revert CommitmentNotFound();
        if (block.number <= committedAt) revert CommitmentTooEarly();
        if (block.number > committedAt + COMMIT_MAX_BLOCKS) revert CommitmentExpired();
        delete d.claimCommitments[commitment];

        (bool statusOk, bytes memory statusData) = agreement.staticcall(
            abi.encodeWithSignature("status()")
        );
        if (!statusOk) revert AgreementStatusUnreadable();
        uint8 agreementStatus = abi.decode(statusData, (uint8));
        if (agreementStatus != 4) revert NotDisputed();

        // Claiming after the verdict window is not allowed. submitVerdict would
        // refuse anyway (DisputeWindowPassed), so a late claim cannot lead to a
        // verdict — but it does set arbiter in the Agreement and thereby cancels
        // the even split of the pot on timeout. Without this check a party with
        // a friendly arbiter would take the whole pot, having proved nothing.
        (bool dOk, bytes memory dData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        if (!dOk) revert DisputeDateUnreadable();
        (bool wOk, bytes memory wData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        if (!wOk) revert DisputeWindowUnreadable();
        if (block.timestamp > abi.decode(dData, (uint256)) + abi.decode(wData, (uint256))) {
            revert DisputeWindowPassed();
        }

        // An arbiter cannot be a party to the dispute
        (bool clientOk, bytes memory clientData) = agreement.staticcall(abi.encodeWithSignature("client()"));
        (bool execOk,   bytes memory execData)   = agreement.staticcall(abi.encodeWithSignature("executor()"));
        if (!(clientOk && execOk)) revert DealPartiesUnreadable();
        address agreementClient   = abi.decode(clientData,  (address));
        address agreementExecutor = abi.decode(execData,    (address));
        require(caller != agreementClient && caller != agreementExecutor, "ArbiterRegistry: arbiter is party");

        // The Diamond becomes the arbiter in the Agreement — that is what lets it control the verdict
        (bool setOk,) = agreement.call(
            abi.encodeWithSignature("setArbiter(address)", address(this))
        );
        if (!setOk) revert ArbiterHandoffFailed();

        d.disputeClaims[agreement] = caller;
        // The floor anchor is written on EVERY claim, with no "only if zero"
        // condition. That condition stood here and was removed by the owner's
        // decision of 14.08.2026: it protected against self-harm (a re-claim
        // delays the record against the arbiter himself) and in exchange opened a
        // real hole — claim a dispute, release it a minute later, come back a day
        // later and record silence at once, though for almost all that time the
        // dispute stood unowned. Details are at the field in ArbiterRegistryStorage.
        d.disputeClaimedAtBy[agreement][caller] = block.timestamp;
        d.arbiterDeals[caller].push(agreement);
        d.openClaimCount[caller]++;
        d.judgingCount[caller]++;

        // ⚠️ THE MONEY, LAST, AFTER EVERY REFUSAL AND AFTER THE CLONE HAS
        // ACCEPTED THE HANDOFF. `setArbiter` above is the only step that can
        // fail on the clone's side; taking the bond before it would mean a
        // failed handoff reverts a transfer that had already been made, which
        // is harmless today and stops being harmless the day anything here is
        // wrapped in a try/catch. It is also the last thing an arbiter loses
        // if he got the salt wrong.
        _takeCaseBond(d, agreement, caller);

        // The keys are written HERE and not by a separate call: one transaction
        // instead of two, and an arbiter cannot end up holding a claim without a
        // key even for an instant.
        //
        // The event fires only on a real change (see setArbiterChatKey above,
        // same device and same reason): without the condition an arbiter with N
        // open disputes, claiming dispute N+1 with his usual key, sends N free
        // re-presentations to the store — a claim almost always carries THE SAME
        // key that is already written.
        bool keysChanged = d.arbiterBoxKey[caller] != boxKey || d.arbiterSignKey[caller] != signKey;
        d.arbiterBoxKey[caller]  = boxKey;
        d.arbiterSignKey[caller] = signKey;
        if (keysChanged) emit ArbiterChatKeySet(caller, boxKey, signKey);

        emit DisputeClaimed(agreement, caller);
    }

    function releaseDisputeClaim(address agreement) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        address current = d.disputeClaims[agreement];
        if (current == address(0)) revert NotClaimed();
        if (caller != current && caller != OwnershipLib.contractOwner()) revert NotAuthorized();
        // The owner taking the case off an arbiter is a hand in this dispute; the
        // arbiter letting go of his own case is not. This is the ONLY record
        // either way — the door leaves no per-dispute state behind (a verdict
        // does not exist yet, by the require below) and `DisputeReleased` does
        // not name who pressed. See `Data.govTouchedDispute`.
        if (caller != current) d.govTouchedDispute[agreement] = true;

        // A claim cannot be released once a verdict has been submitted (awaiting finalization)
        require(d.pendingVerdicts[agreement].submittedAt == 0, "ArbiterRegistry: verdict pending");

        // Releasing a dispute after the window has closed is not allowed, for the
        // same reason claiming it after the window is not: a verdict is already
        // impossible there (submitVerdict refuses) and the dispute cannot be
        // re-claimed — so a late release puts nothing back into circulation.
        //
        // It does harm twice. It leads away from punishment: notifyArbiterTimeout
        // reads disputeClaims and exits silently on an empty key, so an arbiter
        // who never showed up walked away without a judicial mistake. And it
        // switches the timeout branch — setArbiter(0) below turns a full refund
        // to the client into an even split, which an arbiter friendly to the
        // executor could use for free.
        //
        // Its third effect is useful and is lost here: a release decremented
        // openClaimCount, that is, freed the arbiter himself. Until a party pulls
        // triggerArbiterTimeout, the absentee's counter stays occupied, and with
        // it the exit from arbiter status together with the bond. A deliberate
        // trade: the cost is 50 USDC to someone who already broke the rules; the
        // hole would have cost half of any disputed pot. The honest cure is a
        // future `abandonClaim`, which would drop the counter, book the mistake
        // and NOT touch Agreement.arbiter; it does not exist yet.
        //
        // ⚠️ THE "THE OWNER WILL UNJAM IT" CURE IS GONE FROM HERE (16 August
        // 2026). The earlier version of these lines named
        // `removeArbiter` for it — a function deleted on 15 August: it dropped
        // the status and returned the bond IN FULL, so it really did free a
        // jammed arbiter without loss. Its replacement,
        // ArbiterAccountabilityFacet.removeArbiterForCause, does not return the
        // bond but BURNS it into the arbiter vault, demands a cause code and puts
        // a permanent public accusation on chain. That is a punishment, not an
        // unjamming: applying it to a man who merely got stuck on somebody else's
        // counter means accusing him publicly for a hole left open here.
        //
        // The Diamond owner (the second admissible caller above) falls under the
        // gate the same way and gets no bypass: an exception would bring back
        // exactly the hole the gate stands for. Until `abandonClaim` exists, a
        // jammed counter is unlocked only by a party calling triggerArbiterTimeout.
        (bool dOk, bytes memory dData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        if (!dOk) revert DisputeDateUnreadable();
        (bool wOk, bytes memory wData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        if (!wOk) revert DisputeWindowUnreadable();
        if (block.timestamp > abi.decode(dData, (uint256)) + abi.decode(wData, (uint256))) {
            revert DisputeWindowPassed();
        }

        // The claim anchor and the no-response record are NOT touched here: they
        // are keyed by the pair (deal, arbiter), so "a new arbiter inherits
        // somebody else's time" is impossible even without cleanup, and erasing a
        // no-response record is forbidden — that would hand the arbiter the right
        // to move its time. Both getters reach the outside through disputeClaims,
        // so immediately after this line they honestly return zero.
        delete d.disputeClaims[agreement];
        if (d.openClaimCount[current] > 0) d.openClaimCount[current]--;
        // No verdict was submitted (the require above), so the slot is still
        // his and the bond has bought nothing. The slot is freed here; the
        // money stays booked against this deal and he collects it with
        // `withdrawCaseBond` — see `_releaseCaseBond` for why only the
        // finalization pushes.
        _freeJudgingSlot(d, current);

        (bool ok,) = agreement.call(
            abi.encodeWithSignature("setArbiter(address)", address(0))
        );
        if (!ok) revert ArbiterHandoffFailed();

        emit DisputeReleased(agreement, current);
    }

    /// @notice Takes a dispute off an arbiter who let his window run out.
    ///         ANYONE may press it, and pressing it decides nothing.
    ///
    /// ── WHAT WAS STUCK (item D1 of the mainnet list, closed here) ──────────
    /// An arbiter claimed a dispute and never ruled. Four days later:
    /// `submitVerdict` refuses (past the window), `releaseDisputeClaim` refuses
    /// (`DisputeWindowPassed`, for a reason still written out above),
    /// `resignAsArbiter` refuses (`HasOpenDisputeClaims`) and since 17 September
    /// the boards refuse him too. The only key was `triggerArbiterTimeout`, and
    /// the clone lets none but the two parties press THAT. So a client who
    /// simply never came back locked 50 USDC of somebody else's money with no
    /// door at all — an arbiter's own mistake turned into a life sentence by
    /// a stranger's silence.
    ///
    /// This is the `abandonClaim` the note in `releaseDisputeClaim` promised.
    ///
    /// ── WHY IT IS SAFE TO GIVE IT TO EVERYBODY ────────────────────────────
    /// Because it touches no money and chooses no outcome. It clears the claim,
    /// frees the seat's counter and books the missed window against the arbiter.
    /// It deliberately does NOT call `setArbiter(0)` on the clone — that one
    /// call is what would switch the timeout branch from "everything back to the
    /// client" to "the pot in half", i.e. it would let whoever pressed pick how
    /// the money is split. `Agreement.arbiter` stays set, so when a party does
    /// come and presses `triggerArbiterTimeout`, the rule that was already
    /// written pays out, unchanged and unchosen.
    ///
    /// The parties' money therefore stays inside the deal until one of them
    /// presses. That is the freeze the owner allowed: an escrow nobody claims
    /// waits, a bond nobody owes does not.
    ///
    /// ── AND WHY THE MISTAKE IS STILL HIS ──────────────────────────────────
    /// A door that only freed the bond would turn a missed window into a
    /// no-cost exit — press it yourself and walk away clean. So this books a
    /// judicial mistake through the same helper every other path uses, with a
    /// path of its own (`DemotionPath.ClaimAbandoned`) so the permanent record
    /// says how it came about. At the third mistake in a row the corps stops
    /// him on the spot and the chain accuses him, exactly as a party-pressed
    /// timeout would have.
    ///
    /// A later `triggerArbiterTimeout` cannot book it twice:
    /// `notifyArbiterTimeout` reads `disputeClaims`, which this function has
    /// just emptied, and returns in silence on an empty key.
    ///
    /// Junk presses cost the presser gas and change nothing: with no claim on
    /// the deal it refuses `NotClaimed`, inside the window
    /// `DisputeWindowNotPassed`, and after a verdict `VerdictAlreadySubmitted`.
    /// A second press finds the claim already gone.
    function abandonClaim(address agreement) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        address held = d.disputeClaims[agreement];
        if (held == address(0)) revert NotClaimed();

        // A verdict came in, so nothing was missed: `submitVerdict` itself
        // refuses past the window, so a submitted verdict is by construction an
        // arbiter who did his work inside it. Whatever is wrong with that
        // verdict is the appeal's business, not this door's.
        if (d.pendingVerdicts[agreement].submittedAt != 0) revert VerdictAlreadySubmitted();

        // The clone's own clock, read the same way `claimDispute` and
        // `releaseDisputeClaim` read it — the window belongs to the deal, not to
        // this facet, and a clone that cannot answer is not guessed about.
        (bool dOk, bytes memory dData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        if (!dOk) revert DisputeDateUnreadable();
        (bool wOk, bytes memory wData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        if (!wOk) revert DisputeWindowUnreadable();
        uint256 disputedAt = abi.decode(dData, (uint256));
        if (disputedAt == 0) revert NotDisputed();
        // Strictly the mirror of the gate in `releaseDisputeClaim`: that one
        // refuses AFTER `disputedAt + DISPUTE_WINDOW`, this one refuses up to
        // and including it. Between them there is no moment when a claim can be
        // neither released nor abandoned, and none when it can be both.
        if (block.timestamp <= disputedAt + abi.decode(wData, (uint256))) {
            revert DisputeWindowNotPassed();
        }

        // The claim anchor and the no-response record are left alone, for the
        // reason spelled out in `releaseDisputeClaim`: they are keyed by the
        // pair (deal, arbiter), and erasing them would hand the arbiter the
        // right to move his own clock.
        delete d.disputeClaims[agreement];
        if (d.openClaimCount[held] > 0) d.openClaimCount[held]--;
        _freeJudgingSlot(d, held);
        // ⚠️ THE BOND IS STILL HIS, AND THE MISTAKE IS STILL HIS TOO. The bond
        // is not a fine — it exists to cover one refund to an appellant, and a
        // case nobody ruled on has no appellant. Taking it here would turn a
        // missed window into a second, monetary punishment nobody decided on,
        // on top of the judicial mistake booked three lines down. He collects
        // it with `withdrawCaseBond`; this door is pressed by strangers, and a
        // stranger should not pay for a transfer to somebody else.

        _recordArbiterMistake(
            d,
            ReputationStorage.data(),
            held,
            address(0),
            DemotionPath.ClaimAbandoned,
            agreement
        );

        // ⚠️ THE SAME LOG THE TIMEOUT PATH EMITS, AND NOT A NEW NAME FOR THE
        // SAME FACT. What happened here is what `ArbiterTimeoutRecorded` means
        // wherever it appears: this arbiter took this dispute and let his window
        // run out. A second event name would split one fact across two feeds,
        // and every reader that knows only the first would come out a dispute
        // short on the mistake run — which is exactly how the timeout path was
        // found silent for two days in August 2026. The pair (deal, arbiter) is
        // what a reader needs, and this is the log that carries it and is
        // already indexed. The register of this rule is
        // script/arbiter-mistake-paths.allow.
        emit ArbiterTimeoutRecorded(held, agreement);

        // And the half that is NOT a mark against anybody: who pressed, and
        // that the seat's counter is free again. `by` comes through the
        // forwarder like everywhere else — he is not the accuser and decides
        // nothing, he is just who paid the gas. The two logs together also tell
        // a stranger's press apart from a party's timeout, which the shared
        // name above cannot.
        //
        // BOTH BELOW the booking, which is the ordering `notifyArbiterTimeout`
        // and `overturnVerdict` already use: if this mistake is the third of a
        // run, the chain's own accusation (`RemovalProposedByChain`, emitted
        // from inside the booking) reaches a reader before the outer events, so
        // every path puts them in the same relative position.
        emit DisputeClaimAbandoned(agreement, held, _msgSender());
    }

    /// @notice The arbiter records a fact on chain: asked for the chat log — no answer.
    /// @dev Fired only on the arbiter's word; nothing goes out on a timer.
    /// There are no consequences: no XP, no reputation, no shift of the verdict — the
    /// chain cannot see the presentation box and can only take the arbiter's word, and
    /// hanging automation on an unverifiable word hands a bribed arbiter a real weapon.
    /// A presentation digest does NOT block the record: a hard ban would give a party a
    /// shield — send the digest of a blank and become untouchable.
    function recordNoResponse(address agreement) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        if (d.disputeClaims[agreement] != caller) revert NotClaimingArbiter();
        // Writing a public record against a party is arbiter work, and the same
        // reasoning as submitVerdict applies: the claim outlives the seat, so
        // the seat is asked for here too. (Until 22 September 2026 this asked
        // about a bond as well; there is no standing bond to ask about.)
        _requireStillSeated(d, caller);

        uint256 claimedAt = d.disputeClaimedAtBy[agreement][caller];
        // Zero means the dispute was claimed BEFORE this field existed: the chain
        // does not know when, so there is nothing to count the floor from. Refused
        // outright. The cheap way out: releaseDisputeClaim, then claim again.
        if (claimedAt == 0) revert ClaimTimeUnknown();
        // Uniqueness is checked BEFORE the floor, and the order here is not
        // cosmetic. With an anchor that moves on every claim, an arbiter who has
        // already made the record and re-claimed the dispute would hit
        // NoResponseTooEarly: an answer that lies, promising it will work in a
        // day, while in a day it gives NoResponseAlreadyRecorded. "Already
        // recorded" is a final state independent of time, so it is the one to
        // answer with first.
        if (d.disputeNoResponseAtBy[agreement][caller] != 0) revert NoResponseAlreadyRecorded();
        if (block.timestamp < claimedAt + NO_RESPONSE_FLOOR) revert NoResponseTooEarly();

        d.disputeNoResponseAtBy[agreement][caller] = block.timestamp;
        emit DisputeNoResponseRecorded(agreement, caller, block.timestamp);
    }

    /// @notice A party to the dispute puts a presentation digest on chain — 32 bytes.
    /// @dev This is the `keccak256` of the same canonical form the party
    /// SIGNS when presenting (`canonicalPresentationBytes`, the web
    /// client's canonical-encoding function: a length before every field, no
    /// concatenation). The hash function is named here verbatim and not by
    /// accident: this is a seam where the chain sees only 32 bytes and cannot
    /// check the match with anything. Let the frontend take sha256 — the chain
    /// would hold equally lawful 32 bytes, "it matches" would never match, and
    /// the first report would come from a person with a broken screen. The point
    /// is not to prove content but to show the ORDER: the digest landed in block
    /// N, the arbiter's "asked, no answer" in block M. No trust in the server is
    /// needed, and if the server loses the box, the presentation stands recorded.
    ///
    /// A digest does NOT block a no-response record — neither here nor in
    /// recordNoResponse is there a line tying one to the other. A hard ban would
    /// give a party a shield: the chain does not know what lies under the hash,
    /// so invulnerability would be bought with the digest of an empty file. Who
    /// is right is decided by the arbiter looking at the order, not the contract.
    function recordPresentationDigest(address agreement, bytes32 digest) external {
        if (digest == bytes32(0)) revert ZeroDigest();

        address caller = _msgSender();

        // The parties are taken from the protocol's OWN registry, not by an
        // external call to the deal. RegistryStorage.AgreementRecord already
        // holds client and executor (src/RegistryFacet.sol), and the other
        // functions of this facet go there too (notifyArbiterTimeout,
        // fundDispute). That is cheaper, adds no external call with returndata
        // decoding — and answers "is this deal registered here at all?" along
        // the way: an address absent from the registry has neither client nor
        // executor, so nobody is a party to it and nobody fills a stranger's feed.
        RegistryStorage.AgreementRecord storage rec =
            RegistryStorage.store().agreements[agreement];
        // ⚠️ The first line CANNOT FIRE today, and that is written here so the
        // next reader does not take it for a live guard. Registry records are
        // written whole (RegistryFacet.register) and are deleted nowhere, so "no
        // record" means both client == 0 and executor == 0 — and then the second
        // line rejects any non-zero caller by itself. Measured by removal:
        // dropping the first line gives 0 red out of 632; dropping both gives
        // 3 red. It is kept as a declaration of intent ("the deal must be a
        // registered one") at the price of one cold SLOAD; if that SLOAD ever
        // becomes worth saving, this is the line to drop, not the second.
        if (rec.agreement != agreement) revert NotDisputeParty();
        if (caller != rec.client && caller != rec.executor) revert NotDisputeParty();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        d.presentationDigests[agreement].push(digest);
        emit PresentationDigestRecorded(
            agreement, caller, digest, d.presentationDigests[agreement].length - 1
        );
    }

    // -------- VERDICT FLOW --------

    /// @notice The arbiter submits a verdict. Not executed yet — it waits for finalizeVerdict.
    function submitVerdict(address agreement, bool clientWins) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        if (d.disputeClaims[agreement] != caller) revert NotTheClaimer();
        // This door is gated by the CLAIM, never by the seat — which is why the
        // bond is asked here in its own right and not left to claimDispute. A
        // man removed for cause has his bond forfeited to zero by
        // _performRemoval while his claims survive untouched; before this line
        // he went on filing verdicts on every escrow he still held. Suspension
        // covered that at finalization; this covers it at submission.
        //
        // ⚠️ WHAT IS LEFT OF IT AFTER 22 SEPTEMBER 2026 IS THE SEAT ALONE.
        // The bond half is gone with the standing bond — this case's money was
        // taken when he claimed it and is sitting in `caseBonds` right now, so
        // there is nothing to ask him for here.
        _requireStillSeated(d, caller);
        if (d.pendingVerdicts[agreement].submittedAt != 0) revert VerdictAlreadySubmitted();

        // Check that the agreement is still in dispute
        (bool ok, bytes memory st) = agreement.staticcall(abi.encodeWithSignature("status()"));
        if (!ok) revert AgreementStatusUnreadable();
        require(abi.decode(st, (uint8)) == 4, "ArbiterRegistry: not disputed");

        // The arbiter must submit the verdict within DISPUTE_WINDOW of disputedAt. This
        // check used to live in Agreement.resolveDispute() and fired at EXECUTION time —
        // because of FINALIZE_DELAY and appeals, execution legitimately happens long after
        // submission, so the only place where time may be checked is submission.
        (bool disputedOk, bytes memory disputedData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        if (!disputedOk) revert DisputeDateUnreadable();
        uint256 disputedAt = abi.decode(disputedData, (uint256));

        (bool windowOk, bytes memory windowData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        if (!windowOk) revert DisputeWindowUnreadable();
        uint256 disputeWindow = abi.decode(windowData, (uint256));

        if (block.timestamp > disputedAt + disputeWindow) revert DisputeWindowPassed();

        // ⚠️ THE SLOT IS FREED BY THE SIGNATURE, NOT BY THE FINALIZATION
        // (owner's decision, 22 September 2026). His work on this case is done;
        // making him sit out FINALIZE_DELAY and then a four-day appeal window
        // before he may read the next one would mean one arbiter can close
        // about one case a week.
        //
        // ⚠️ AND IT IS NOT `openClaimCount` THAT MOVES HERE. That one guards
        // the exit from the corps, and releasing it on the signature would let
        // an arbiter sign, resign, and walk out with this deal's bond before
        // the panel had a chance to overturn him — the one thing the bond
        // exists to make impossible. See `Data.judgingCount`.
        _freeJudgingSlot(d, caller);

        d.pendingVerdicts[agreement] = ArbiterRegistryStorage.PendingVerdict({
            arbiter:        caller,
            clientWins:     clientWins,
            submittedAt:    block.timestamp,
            frozen:         false,
            finalized:      false,
            overturned:     false,
            executing:      false,
            appealed:       false,
            appealResolved: false,
            appellant:      address(0),
            appealDeadline: 0,
            votesUphold:    0,
            votesOverturn:  0,
            // Nothing has been paid yet — raiseAppeal writes this when the
            // money actually arrives.
            appealDeposit:  0,
            // Nobody has frozen anything yet — freezeVerdict writes this when a
            // press actually happens. Named here rather than left out so that
            // appending a field to PendingVerdict cannot silently inherit a
            // previous verdict's value on this deal: this assignment replaces
            // the whole struct.
            frozenAt:       0
        });

        emit VerdictSubmitted(agreement, caller, clientWins);
    }

    /// @notice Execute the verdict. Anyone may call. The Diamond calls resolveDispute on the Agreement.
    /// If the verdict is frozen, it waits until owner/DAO unfreezes or overturns it.
    function finalizeVerdict(address agreement) external {
        if (agreement == address(0)) revert ArbiterZeroAddress();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (v.submittedAt == 0) revert NoVerdict();
        if (v.finalized) revert AlreadyFinalized();
        // THE FREEZE HAS A CLOCK NOW — see FREEZE_WINDOW and `_freezeHolds`.
        // Read by the clock and not by a button: an expiry somebody has to press
        // would again be waiting for an event that may never come, which is the
        // defect this replaces rather than a fix for it. `v.frozen` stays set in
        // storage — the flag records that the press happened, the clock decides
        // whether it still stops anything.
        if (_freezeHolds(v)) revert VerdictFrozenError();
        // Checks the VERDICT'S ARBITER, not the caller: anyone may finalize, and
        // the one held back here is the suspended judge.
        _requireNotSuspended(d, v.arbiter);
        require(block.timestamp >= v.submittedAt + FINALIZE_DELAY, "ArbiterRegistry: finalize delay not passed");

        // Guards against auto-deletion in clearDisputeClaim during this call
        v.executing = true;

        // The top-up is zeroed HERE, before the external call, whatever the
        // outcome. resolveDispute reaches clearDisputeClaim through the agreement,
        // and if the top-up were still in place, that would refund it to the
        // payer — meaning that on an ordinary payout the arbiter and the payer
        // would receive the same money. Zeroing before the call makes a double
        // payout impossible by construction rather than by a check.
        uint256 bounty = d.disputeBounty[agreement];
        if (bounty > 0) {
            d.disputeBounty[agreement] = 0;
            address bountyPayer = d.disputeBountyPayer[agreement];
            delete d.disputeBountyPayer[agreement];
            uint256 subsidy = d.disputeVaultSubsidy[agreement];
            delete d.disputeVaultSubsidy[agreement];

            if (v.overturned) {
                // An overturned verdict is not paid for: on an overturn the
                // arbiter's 80% of the fee is withheld from him (creditDisputeFee
                // spends it on the appeal's refund and the arbiter bank — since
                // 17 September 2026, and into the treasury before that), and the
                // top-up must not be an exception — one mistake cannot cost one
                // part of the payment and spare another. The money goes back to
                // the payer: he bought a resolution of the dispute and did not get
                // one. Through a claimable (refundableBounty/withdrawDisputeBounty)
                // and not a direct transfer — a hard transfer here would bring down
                // the whole finalization if the payer is on the USDC blacklist or
                // otherwise cannot accept a transfer.
                //
                // The vault's share goes back TO THE VAULT, not to the payer: he
                // put in only his own half, and the second was never his for a
                // second. Handing it over here would create a way to milk the
                // buffer — open a dispute, wait for the verdict to be overturned
                // and take three dollars of shared money.
                if (subsidy != 0) {
                    d.vaultBalance += subsidy;
                }
                uint256 own = bounty - subsidy;
                d.refundableBounty[bountyPayer] += own;
                emit DisputeBountyRefundable(agreement, bountyPayer, own);
            } else {
                // The arbiter gets the whole top-up, both halves: the floor is
                // what he must receive, and whose pocket the difference came out
                // of is none of his concern.
                d.arbiterRewards[v.arbiter] += bounty;
                emit ArbiterRewarded(v.arbiter, bounty);
            }
        }

        // The Diamond (address(this)) calls resolveDispute — it works because Diamond = arbiter
        (bool ok, bytes memory ret) = agreement.call(
            abi.encodeWithSignature("resolveDispute(bool)", v.clientWins)
        );

        v.executing = false; // always reset, even on a revert

        if (!ok) {
            // bubble up the revert reason from Agreement
            assembly { revert(add(ret, 32), mload(ret)) }
        }

        v.finalized = true;

        // ⚠️ THE BOND GOES HOME HERE, AND "HERE" IS THE DEFINITION OF "THE
        // VERDICT STOOD". Everything that could take it has already happened:
        // `resolveAppeal` draws it for the appellant's refund when the panel
        // overturns him, and `_requireNotSuspended` plus `v.frozen` above hold
        // this door shut while anything is still being decided.
        //
        // What is left is therefore exactly what nobody claimed — the whole
        // bond on a verdict that stood, the remainder after a won appeal,
        // nothing at all when the refund used it up.
        //
        // ⚠️ A VERDICT THE OWNER'S HAND OVERTURNED, WITH NO APPEAL BEHIND
        // IT, STILL GETS ITS BOND BACK, and that is a decision rather than an
        // oversight. The bond covers one refund to an appellant; a hand
        // overturn has no appellant and refunds nobody. What that verdict costs
        // its arbiter is the other three things: his 80% of the fee, withheld
        // by `creditDisputeFee`; the top-up, returned to the payer above; and a
        // judicial mistake on his record.
        //
        // AFTER the external call, so a reverting `resolveDispute` takes the
        // release down with it rather than paying a bond out on a finalization
        // that did not happen.
        _releaseCaseBond(d, agreement);

        // The verdict reached finalization without an overturn — the judicial mistake
        // was not confirmed, so the mistake streak resets. The judging record grows
        // at the same time (15 August 2026): a counter of unoverturned finalized
        // verdicts, needed for the future "bond plus record" conversion once governance is live.
        if (!v.overturned) {
            d.arbiterMistakeStreak[v.arbiter] = 0;
            d.cleanVerdicts[v.arbiter]++;
        }

        // ---- the handover's second condition, counted here and nowhere else
        //      (20 September 2026) ----
        //
        // THREE OUTCOMES, NOT TWO — the middle one added 20 September 2026 by
        // the owner's decision, and it is the whole shape of this block:
        //
        //   • no hand, no overturn      → the run grows, the man is counted,
        //                                 the lifetime total grows;
        //   • a GOVERNANCE HAND in this dispute (freeze, an overturn by the
        //     owner or the DAO, the case taken off an arbiter)
        //                               → the run is thrown away, back to zero;
        //   • the verdict overturned by the APPEAL PANEL, with no hand in it
        //                               → the run STANDS WHERE IT IS. It does
        //                                 not grow — the arbiter was wrong and
        //                                 that is not to his credit — and it is
        //                                 not broken, because three arbiters
        //                                 correcting a fourth is the corps
        //                                 repairing itself WITHOUT the owner,
        //                                 which is the very sentence this
        //                                 condition is trying to measure. A
        //                                 court that never has to correct
        //                                 anyone is not a court that works; it
        //                                 is a court nobody has tested.
        //
        // CLEAN is therefore still both halves — not overturned AND no hand —
        // and `cleanVerdicts` above is still the weaker test: it keys on
        // `!v.overturned` alone, so a verdict the owner froze for a week and
        // then let go counts clean there. That is right for what THAT counter
        // is for (the arbiter was not proved wrong) and wrong for what these
        // are for (nobody had to step in).
        //
        // ⚠️ HOW THE PANEL IS TOLD FROM THE HAND, and why no new field was
        // needed: `v.overturned` has exactly two writers — `overturnVerdict`,
        // which sets `govTouchedDispute` in the same call, and `resolveAppeal`,
        // which deliberately sets nothing of the kind. So at this line
        // `overturned && !handed` holds if and only if the PANEL did it.
        //
        // ⚠️ AND THAT EQUIVALENCE IS LOAD-BEARING FROM NOW ON. Writing the
        // mark inside `resolveAppeal` — an innocent-looking "the appeal touched
        // this dispute too" — would silently turn every panel overturn back
        // into a broken run, which is the change this block just undid. The
        // warning is repeated at `Data.govTouchedDispute`, where somebody
        // adding a writer would be standing.
        //
        // ⚠️ AND THE ORDER OF THE BRANCHES IS THE RULE, NOT A STYLE. The hand
        // is asked FIRST, so a dispute that had both — frozen by the owner and
        // then overturned by the panel — is a broken run and not a standing
        // one. A hand was in it; that is the fact the term is about, whoever
        // pressed last.
        bool handed = d.govTouchedDispute[agreement];
        if (handed) {
            // ⚠️ THE RESET IS THE WHOLE POINT OF THE TERM. A total can only be
            // forgiven; a run has to be earned again from zero. This is the
            // line that makes interference COST something, and it is the one a
            // "simplification" would delete first — see
            // `test_AFrozenAndUnfrozenDisputeBreaksTheStreak` and
            // `test_AnOverturnByTheHandBreaksTheStreak`.
            d.cleanDisputeStreak = 0;
        } else if (!v.overturned) {
            d.cleanDisputeStreak++;
            d.cleanDisputeCount++;
            // The man, counted once however many disputes he closes. Without
            // this bit one arbiter closing eight disputes would read as a corps
            // of eight; see `Data.countedCleanArbiter`.
            if (!d.countedCleanArbiter[v.arbiter]) {
                d.countedCleanArbiter[v.arbiter] = true;
                d.distinctCleanArbiters++;
            }
        }
        // The third outcome has no branch on purpose: the panel overturned a
        // verdict nobody's hand had been near, so every one of these three
        // numbers is left exactly as it was. Guarded by
        // `test_APanelOverturnLeavesTheRunWhereItIs`, which fails both ways —
        // if the run is reset AND if it is grown.

        // ---- the arbiter's own record: a SHARE of his recent work, not a run
        //      of blunders (21 September 2026) ----
        //
        // ⚠️ THIS LINE IS THE DEFINITION OF "A CLOSED CASE", and the
        // definition is the whole guard against dilution. A case is closed here
        // and only here — the arbiter ruled, the ruling reached finalization.
        // A dispute that timed out (`triggerArbiterTimeout`) or whose claim was
        // abandoned never arrives at this function at all, so it enters neither
        // half of the fraction. That is not an omission: nothing was judged, so
        // there is no verdict to hold him to, and counting those cases as
        // "closed" would let an arbiter drown two overturns in a pile of
        // disputes he never touched.
        //
        // ⚠️ AND THE OUTCOME IS NOT `v.overturned` ALONE. That flag stays true
        // after the appeal panel has RESTORED the arbiter's own ruling, so
        // reading it by itself would file the panel's acquittal as an overturn
        // against him — see `Data.verdictVindicated`, which is set in exactly
        // that branch of `resolveAppeal` and read nowhere else. `cleanVerdicts`
        // above still reads the bare flag and still miscounts this case; there
        // the cost is a card one low, here it would be a suspension.
        bool countAsOverturn = v.overturned && !d.verdictVindicated[agreement];

        // ---- and the same closed case, filed against the PERIOD it closed in
        //      (25 September 2026, mainnet item D3) ----
        //
        // ⚠️ THE SAME FLAG, READ ONCE, USED TWICE — deliberately. The payroll
        // pot pays for work that STOOD, and "stood" already has a definition on
        // the line above: `countAsOverturn`. Computing the question a second
        // time here, however innocently, would be a second definition of the
        // arbiter's work, and the two would drift the first time either was
        // refined. `verdictVindicated` is exactly the case that would drift
        // first: a panel that RESTORED this arbiter's ruling leaves
        // `v.overturned` true forever, so a payer reading the bare flag would
        // refuse to pay the one man three of his colleagues had just cleared.
        //
        // ⚠️ IT IS NOT GATED ON `handed`. A governance hand in the dispute
        // breaks the clean RUN above, because that number is a claim about the
        // corps working unattended. It does not unmake the arbiter's work: he
        // ruled, the ruling stood, and the freeze was somebody else's doing.
        // Docking his pay for it would make the owner's hand a fine on the
        // arbiter, which is the opposite of what the hand is for.
        if (!countAsOverturn) ArbiterRegistryStorage.creditPayrollCase(d, v.arbiter);

        if (ArbiterRegistryStorage.recordClosedCase(d, v.arbiter, countAsOverturn)) {
            // ⚠️ THE SAME CONSEQUENCE AS THE THIRD MISTAKE IN A ROW, through
            // the same body — no new kind of punishment was decided on, only a
            // second way of arriving at the old one. `_suspendAndAccuse`
            // cannot revert and yields to a live accusation, so a rate trip
            // landing on top of a human charge leaves that charge standing.
            //
            // AFTER the external call and after the two counters above, not
            // before: the suspension must not decide whether this dispute's
            // money moves, and `_requireNotSuspended` at the top of this
            // function has already let this verdict through.
            _suspendAndAccuse(
                d,
                ReputationStorage.data(),
                v.arbiter,
                DemotionPath.OverturnRate,
                agreement
            );
        }

        emit VerdictFinalized(agreement, v.arbiter, v.clientWins);
    }

    // ⚠️ `overturnVerdict` STOOD HERE AND IS GONE (9 October 2026), by the
    // owner's decision. The reasons, in the order they were measured:
    //
    //   * AN OVERTURN IS AN APPEAL WITH ONE VOTER. The appeal panel does the
    //     same work with three, and there is nobody to hand a single-voter
    //     version to -- there is no DAO contract in this repository, only an
    //     empty `daoAddress` slot, so "move it to the DAO" would have meant
    //     moving it to another single address without a vote.
    //   * IT FED THE AUTOMATON. This door did not finalize anything; it set
    //     `v.overturned`, and `finalizeVerdict` reads that flag and files the
    //     case as an overturn. Two such cases inside the window suspend the
    //     arbiter and lay the chain's own accusation. So one person's opinion
    //     could drive a man out of the corps automatically, which breaks the
    //     rule that automatic consequences follow objective facts only.
    //   * THE RECORD IT WROTE IS KEPT. `DemotionPath.OwnerOverturn` stays in
    //     the enum: it is the value 241 in permanent records and in the
    //     `ArbiterDemoted` feed, and removing a member would shift the two
    //     after it. Nothing reaches it any more.
    //
    // ⚠️ WHAT THIS COSTS, SAID OUT LOUD RATHER THAN DISCOVERED LATER: a wrong
    // verdict that nobody appeals is now FINAL, and no key can change it.
    // `clearStuckVerdict` is not a substitute -- it demands the deal not be in
    // dispute (`status != 4`), so it refuses in exactly the case where it would
    // be wanted. That is why the appeal window was widened from 24 to 72 hours
    // in the same decision: the only remaining correction is the parties' own,
    // so they are given three days to use it instead of one.
    //
    // `error AlreadyOverturned()` and `error VerdictUnchanged()` are kept
    // although nothing raises them now -- the selector argument at
    // `AppealInProgress` below applies to both.

    /// @notice Called by the Agreement when the arbiter failed to deliver a verdict within
    /// DISPUTE_WINDOW (triggerArbiterTimeout). Counts as a judicial mistake for demotion
    /// (unlike overturnVerdict, no XP is slashed here — the verdict was not wrong, there
    /// simply was none). The real arbiter is read from disputeClaims and NOT from
    /// Agreement.arbiter() — after claimDispute() that points at the Diamond itself (the
    /// Diamond-as-arbiter pattern for controlling the verdict), not at the person who took
    /// the dispute. Called BEFORE _clearDisputeClaim() inside triggerArbiterTimeout, so the record is still there.
    function notifyArbiterTimeout(address agreement) external {
        if (msg.sender != agreement) revert NotAuthorized();
        if (RegistryStorage.store().agreements[agreement].agreement != agreement) revert NotAuthorized();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        address arbiterAddr = d.disputeClaims[agreement];
        if (arbiterAddr == address(0)) return; // nobody claimed the dispute — nobody to book it against

        ReputationStorage.Data storage rep = ReputationStorage.data();
        // `by` is zero: msg.sender here is the agreement itself (checked above),
        // there is no person behind the call at all.
        _recordArbiterMistake(d, rep, arbiterAddr, address(0), DemotionPath.AgreementTimeout, agreement);

        // ⚠️ BELOW the booking and not above it, which puts this log AFTER the
        // chain's own accusation when this mistake is the third of a run —
        // _recordArbiterMistake emits RemovalProposedByChain from inside. That
        // ordering is deliberate and is the one overturnVerdict already uses:
        // there too the booking runs first and the outer event (VerdictOverturned)
        // lands after any accusation it caused. Both outer events therefore reach
        // a reader in the same relative position, and neither needs a rule of its
        // own.
        emit ArbiterTimeoutRecorded(arbiterAddr, agreement);
    }

    /// @notice Deducts OVERTURN_XP_SLASH from the arbiter without underflowing.
    /// A shared helper for overturnVerdict and resolveAppeal (both slash XP the same way).
    function _slashArbiterXP(ReputationStorage.Data storage rep, address arbiterAddr) private {
        if (rep.xp[arbiterAddr] >= OVERTURN_XP_SLASH) {
            rep.xp[arbiterAddr] -= OVERTURN_XP_SLASH;
        } else {
            rep.xp[arbiterAddr] = 0;
        }
    }

    /// A shared ban for three places: claimDispute, resignAsArbiter, finalizeVerdict.
    /// Reads the same field ArbiterAccountabilityFacet.suspendArbiter writes —
    /// both facets share one ArbiterRegistryStorage.
    function _requireNotSuspended(ArbiterRegistryStorage.Data storage d, address who) private view {
        uint256 until = d.suspendedUntil[who];
        if (block.timestamp < until) revert ArbiterSuspendedError(until);
    }

    /// Does the freeze on this verdict still stop anything? The single owner of
    /// that question (25 September 2026) — see `FREEZE_WINDOW` for why the
    /// question has an answer other than "yes, for ever".
    ///
    /// ⚠️ INTERNAL AND NOT A GETTER, on purpose. `ArbiterRegistryFacet` is a
    /// named Replace group in scripts the owner has already signed: they carry
    /// "N Replace + M Add" and the artifact path, and one new external function
    /// — a view included — moves those counts and turns every cut rehearsal
    /// red. The number this answers is reconstructible from outside already:
    /// `getPendingVerdict()` returns `frozen` and `frozenAt`.
    ///
    /// ⚠️ THE APPEAL BRANCH IS FIRST AND IT IS LOAD-BEARING. `raiseAppeal` also
    /// sets `frozen`, and that freeze belongs to `appealDeadline`
    /// (APPEAL_REVIEW_WINDOW, four days) — not to this clock. Without this
    /// branch a 72-hour lapse would let anybody finalize a verdict while its
    /// panel was still voting, throwing away votes already cast. It is written
    /// as an explicit branch rather than left to `frozenAt == 0`, because the
    /// owner may press freeze ON TOP of an appeal (`unfreezeVerdict` refuses
    /// while an appeal runs, `freezeVerdict` does not) and then `frozenAt` is
    /// set while the appeal still owns the clock.
    function _freezeHolds(ArbiterRegistryStorage.PendingVerdict storage v)
        private view returns (bool)
    {
        if (!v.frozen) return false;
        if (v.appealed && !v.appealResolved) return true;
        // Zero means the press happened before the field existed; `submittedAt`
        // is then the earliest moment the freeze can have been applied, and it
        // is never zero on a verdict that exists — `finalizeVerdict` has already
        // refused a zero above. See `PendingVerdict.frozenAt`.
        uint256 pressedAt = v.frozenAt == 0 ? v.submittedAt : v.frozenAt;
        return block.timestamp < pressedAt + FREEZE_WINDOW;
    }

    /// What THIS appeal was paid with (26 August 2026). One owner
    /// for the rule, read by both ends of resolveAppeal — the refund and the
    /// forfeit — so they can never disagree about the same money.
    ///
    /// Zero means the appeal was raised before the field existed; the constant
    /// in force is then the rule it was raised under. Deliberately NOT a revert:
    /// an appeal already paid for must not become unresolvable because of an
    /// upgrade.
    function _depositOf(ArbiterRegistryStorage.PendingVerdict storage v)
        private view returns (uint256)
    {
        uint256 paid = v.appealDeposit;
        return paid == 0 ? APPEAL_DEPOSIT_BEFORE_RECEIPT : paid;
    }

    /// @dev A transfer that REPORTS failure instead of reverting on it. Used
    /// wherever a refund must not be able to drag down the state change it
    /// accompanies: the claim release in clearDisputeClaim (wrapped by the
    /// Agreement in a swallowing catch) and the appeal deposit in resolveAppeal
    /// (the only thing that unfreezes the verdict, and with it the escrow).
    ///
    /// The response length is checked explicitly, by the same device as
    /// SafeUSDC.trySafeTransfer in Agreement.sol: abi.decode panics by itself
    /// on a response of 1 to 31 bytes, which would make a branch written to be
    /// soft exactly as hard as an ordinary transfer.
    ///
    /// Callers must treat `false` as "the money is still here" and put it
    /// somewhere it can be pulled from — never as "the money is gone".
    function _softTransfer(address usdc, address to, uint256 amount)
        private returns (bool delivered)
    {
        (bool ok, bytes memory ret) = usdc.call(
            abi.encodeWithSelector(IUSDCFull.transfer.selector, to, amount)
        );
        if (ok) {
            if (ret.length == 0) delivered = true;
            else if (ret.length >= 32) delivered = abi.decode(ret, (bool));
            // ret.length in 1..31 — delivered stays false, decode is not called.
        }
    }

    /// A mirror of ArbiterAccountabilityFacet.PROPOSAL_TTL (15 August 2026) —
    /// resignAsArbiter must know the life of a proposal without calling the
    /// other facet (the same device as MISTAKE_THRESHOLD/DAO_THRESHOLD in the
    /// opposite direction). Equality is proved BEHAVIOURALLY — boundary tests on
    /// "14 days minus a second" / "exactly 14 days" in
    /// test/ArbiterSuspension.t.sol
    /// (test_ResignHoldsUntilTheLastSecondOfProposal /
    /// test_ResignSucceedsAfterProposalExpires) — rather than by identity
    /// through a getter: a separate public getter would cost a new selector for
    /// a number that a single helper reads in this facet, and the boundary
    /// test catches drift more reliably — it fails if the mirrored number
    /// differs from the real one by even a second, while identity would compare
    /// two equally wrong numbers as equal.
    ///
    /// ⚠️ THE NUMBER'S ROLE NARROWED ON 26 AUGUST 2026, and the resignation
    /// boundary tests no longer prove it. The life now sits in the record itself
    /// (`RemovalProposal.ttl`), written there by the neighbouring facet out of
    /// its own `PROPOSAL_TTL` — so for every new accusation both facets read ONE
    /// number out of storage and cannot structurally diverge. The mirror stayed
    /// as the answer to exactly one case: a record with a zero `ttl`, that is,
    /// written by the facets deployed before that change. Guarded by
    /// test_LegacyProposalIsJudgedByTheSameClockInBothFacets: one such record
    /// and both halves asked about it on the very same second.
    ///
    /// ⚠️ EXACTLY ONE HELPER READS THE NUMBER, AND THREE PLACES CALL THAT
    /// HELPER (18 August 2026). This used to say "read nowhere else in this
    /// facet", and that went stale twice in a row — first with one change, then
    /// with the follow-up to it.
    ///
    /// The one reader of the number is `_hasLiveProposalHere`. It is called by:
    ///   • `_requireNoLiveRemovalProposal` — the resignation door;
    ///   • the threshold branch in `_recordArbiterMistake` — the chain quietly
    ///     yields to an occupied door;
    ///   • the vindication branch in `resolveAppeal` — only a LIVE accusation by
    ///     the chain is quashed (a dead one used to wipe the counter entirely).
    ///
    /// ⚠️ Listing the callers here by name means keeping a list that goes stale
    /// on an edit in someone else's function. It did go stale, twice. The value
    /// of this paragraph is not the list but what it guards: THERE IS NO SECOND
    /// WRITING OF THE STALENESS FORMULA IN THIS FILE. Check that — with a grep
    /// for `PROPOSAL_TTL_MIRROR`, not by reading this enumeration.
    uint256 private constant PROPOSAL_TTL_MIRROR = 14 days;

    /// `ArbiterAccountabilityFacet.REMOVAL_DELAY`, mirrored here for the same
    /// reason as the term above and used for one thing only: freezing the pause
    /// into the accusation THE CHAIN lays (25 September 2026). The constant lives
    /// in the other facet, this facet writes the record directly, and the record
    /// must carry the pause it was laid with — otherwise a cut that shortens the
    /// constant makes the accusation executable in the same block and the accused
    /// loses the answer that is the only thing able to call it off.
    ///
    /// ⚠️ NOTHING IN THIS FACET READS IT BACK — unlike the term, whose staleness
    /// this facet judges for itself in `_hasLiveProposalHere`. Both readers of the
    /// pause are the two execute doors next door. So this mirror is write-only,
    /// which is precisely why a silent drift from the original would be invisible
    /// here: guarded BEHAVIOURALLY by
    /// test_TheChainFreezesTodaysPauseIntoTheAccusationItLays, which compares what
    /// this facet WROTE against what the OTHER facet PUBLISHES
    /// (`getRemovalDelay()`) — two independent sources. An identity getter would
    /// have cost a selector and compared two equally wrong numbers as equal.
    uint256 private constant REMOVAL_DELAY_MIRROR = 48 hours;

    /// Numeric codes of ArbiterAccountabilityFacet.Cause, mirrored here
    /// because the proposal the chain lays needs a cause and the enum lives in
    /// the OTHER facet (18 August 2026). Same reason the storage
    /// struct keeps `cause` as uint8: importing a type from another file to
    /// write a record would mean a rename there moves the record here.
    ///
    /// ⚠️ A copy without a guard drifts in silence, so this pair is guarded
    /// BEHAVIOURALLY, the way PROPOSAL_TTL_MIRROR above is: the tests read the
    /// expected value out of ArbiterAccountabilityFacet.Cause — an independent
    /// source, the enum itself — and compare it against the cause the chain
    /// actually wrote into getRemovalProposal(). Reorder the enum and they go
    /// red. An identity getter would have cost a second selector and would
    /// have compared two equally wrong numbers as equal.
    uint8 private constant CAUSE_OVERTURNED_VERDICTS_MIRROR = 0;
    uint8 private constant CAUSE_TIMEOUTS_MIRROR            = 1;

    /// Which cause the chain writes for which path. Both codes are
    /// _isChainVerifiable and both are proved by the SAME counter, so
    /// _requireProven admits either — while the feed and the standing card
    /// keep the distinction a dedicated field was added for.
    ///
    /// ⚠️ CANNOT REVERT, and the default is deliberate rather than lazy: this
    /// runs inside the threshold branch, which notifyArbiterTimeout reaches
    /// from an EMPTY try/catch in Agreement.sol. DemotionPath.Unspecified is
    /// sent by no caller (see the enum's docstring); were it ever sent, the
    /// record would say OverturnedVerdicts, which is the cause the counter
    /// actually proves.
    /// ⚠️ AN ALLOW-LIST OF THE TIMEOUT PATHS, not `!= AgreementTimeout`
    /// (18 September 2026, when ClaimAbandoned became the fourth path). A
    /// missed window is a missed window whichever door reported it, and the
    /// cause code is what the accused answers to — reading "his verdicts get
    /// overturned" for a man who never ruled would accuse him of the wrong
    /// thing. A fifth path added later must name itself here.
    function _causeForPath(DemotionPath path) private pure returns (uint8) {
        return path == DemotionPath.AgreementTimeout || path == DemotionPath.ClaimAbandoned
            ? CAUSE_TIMEOUTS_MIRROR
            : CAUSE_OVERTURNED_VERDICTS_MIRROR;
    }

    /// Is a removal proposal — anyone's — standing against this person right
    /// now. One owner for the staleness rule inside this facet:
    /// _requireNoLiveRemovalProposal below is written on top of this, not
    /// beside it.
    function _hasLiveProposalHere(ArbiterRegistryStorage.Data storage d, address who)
        private view returns (bool)
    {
        ArbiterRegistryStorage.RemovalProposal storage p = d.removalProposals[who];
        uint256 proposedAt = p.proposedAt;
        if (proposedAt == 0) return false;
        // ⚠️ THE RECORD DECIDES, THE MIRROR ONLY FILLS IN
        // (26 August 2026). The accusation carries the life it was laid with, so
        // shortening the constant by a cut no longer expires what is already
        // standing. The mirror answers for one case only — records written
        // before the field existed, which carry a zero — and it must keep
        // agreeing with the other facet for exactly that case; guarded by
        // test_LegacyProposalIsJudgedByTheSameClockInBothFacets.
        uint256 ttl = p.ttl;
        return block.timestamp < proposedAt + (ttl == 0 ? PROPOSAL_TTL_MIRROR : ttl);
    }

    /// The third ban on the resignation door (see HasLiveRemovalProposal and the
    /// docstring of the removalProposals field). NOT through suspendArbiter
    /// inside proposeRemoval (a reviewer proposed that; the owner's decision was
    /// to reject it): a suspension freezes the arbiter's already submitted
    /// verdicts, so every proposal would freeze honest parties' money in his OPEN
    /// disputes, which have nothing to do with the proposal. A proposal is weaker
    /// than a removal and is not worth that price — a targeted ban here and only
    /// here freezes nothing extraneous.
    ///
    /// ⚠️ A known limitation, not a bug: the chief can lay a proposal anew every
    /// 14 days and keep someone else's bond locked indefinitely. That is
    /// acceptable today — proposals are publicly attributed to his address
    /// (RemovalProposed indexes `by`), and attestable codes demand a digest, so a
    /// baseless re-filing is as visible in the feed as the proposal itself.
    function _requireNoLiveRemovalProposal(ArbiterRegistryStorage.Data storage d, address who) private view {
        if (_hasLiveProposalHere(d, who)) revert HasLiveRemovalProposal();
    }

    /// The chief's bloc = the arbiters he seated who are sitting now, PLUS
    /// himself if he is an arbiter. The second term is mandatory:
    /// setChiefArbiter does not forbid the chief from being an arbiter, and ONE
    /// appointee plus himself is already two votes, that is, a deciding majority
    /// at a turnout of exactly the quorum (16 August 2026; the earlier version
    /// counted up to three here).
    ///
    /// ⚠️ This is the SIZE OF A UNION, not a sum. A chief who seated HIMSELF
    /// falls into both terms at once: `seatedCountBy[chief]` has already counted
    /// him, and a blind `+1` would count him as a second vote that does not
    /// exist. The condition `seatedBy[chief] != chief` removes that second copy.
    ///
    /// It changes no seating OUTCOME in any reachable state — on a self-seating
    /// both versions give `blocAfter >= APPEAL_DECIDING_VOTES` and refuse
    /// identically — but the getter `getChiefBloc` is public and is read from
    /// outside, and the number it answers with is declared as "how many votes
    /// the bloc has". It may not lie by one: two is the threshold past which an
    /// appeal is decided, and a reader makes decisions on that number.
    ///
    /// ⚠️ The property "bloc ≤ 1" rests ONLY on the addArbiter door, ONLY for
    /// the chief and ONLY at the moment of the press. The owner, seating the
    /// chief as an arbiter AFTER his appointee, brings the bloc to a real two —
    /// measured, `getChiefBloc()` = 2. `applyAsArbiter` does not call
    /// `_chiefBloc` at all. The real cure is counting the bloc at the moment of
    /// the VOTE rather than of the seating; that is a design change, not made here.
    function _chiefBloc(ArbiterRegistryStorage.Data storage d) private view returns (uint256) {
        address chief = d.chiefArbiter;
        if (chief == address(0)) return 0;
        uint256 bloc = d.seatedCountBy[chief];
        // The same person is not counted twice: see "the size of a union".
        if (d.isArbiter[chief] && d.seatedBy[chief] != chief) bloc += 1;
        return bloc;
    }

    /// @notice The shared judicial-mistake counter for overturnVerdict,
    /// notifyArbiterTimeout and resolveAppeal.
    ///
    /// On the MAX_ARBITER_MISTAKES-th mistake in a row: suspension for
    /// SUSPENSION_WINDOW and a removal proposal opened in the CHAIN'S OWN
    /// NAME. The seat is NOT taken here any more — see the branch below.
    /// cleanStreak (the executor streak) is untouched HERE: judging and
    /// delivering are different skills. It is taken on the REMOVAL itself
    /// (ArbiterAccountabilityFacet._performRemoval), because the streak is the
    /// key to the corps and a removal takes the key.
    ///
    /// ⚠️ THIS PARAGRAPH USED TO OPEN WITH "XP hard-reset to
    /// DEMOTION_XP_RESET (a landing point, not a subtraction)". It stopped
    /// being true on 21 September 2026: the reset is gone, XP is not touched on
    /// this path at all, and the note where the constant stood says why. The
    /// sentence is recorded rather than deleted because the record quotes it.
    ///
    /// ⚠️ TWO THRESHOLDS LIVE NEXT TO EACH OTHER AND THEY ARE NOT THE SAME
    /// NUMBER (18 August 2026 — this is what a reviewer
    /// tripped over):
    ///
    ///   • MAX_ARBITER_MISTAKES = 3 — the AUTOMATIC threshold, right here. The
    ///     chain acts on its own: suspension plus an accusation with no author.
    ///   • ArbiterAccountabilityFacet.MISTAKE_THRESHOLD = 2 — the PROOF
    ///     threshold, read by _requireProven. It is what a HUMAN needs to have
    ///     against an arbiter before Cause.OverturnedVerdicts/Timeouts counts
    ///     as proven, and it is one lower on purpose: the manual door is
    ///     valuable precisely because it fires EARLIER than the automaton.
    ///
    /// ⚠️ AND THE CONSEQUENCE IS NOT THE ONE THIS PARAGRAPH USED TO CLAIM
    /// (18 August 2026). It said: "the streak stays
    /// at 3, and 3 >= 2, so the accusation the chain just laid is provable when
    /// the button is pressed two days later" — which stopped being true in the
    /// same change that wrote it, when executeChainRemoval stopped re-proving
    /// the cause at all. The button asks the RECORD, never the counter,
    /// and works at streak 0.
    ///
    /// What the two thresholds still do differ about: MISTAKE_THRESHOLD gates
    /// the MANUAL door, and only it. The reachable case is not hypothetical —
    /// the chain's accusation goes stale after PROPOSAL_TTL with nobody having
    /// pressed, and a human may then propose on the very same evidence, because
    /// the counter is still standing where the mistakes left it.
    ///
    /// `by` is kept in the signature and no longer read: ArbiterDemoted moved
    /// to the actual removal (ArbiterAccountabilityFacet.executeChainRemoval),
    /// where nobody pressed anything and the presser is deliberately not named.
    /// Unnamed rather than deleted — the three call sites still say who acted,
    /// which is the thing to restore if the record ever wants him again.
    function _recordArbiterMistake(
        ArbiterRegistryStorage.Data storage d,
        ReputationStorage.Data storage rep,
        address arbiterAddr,
        address /* by */,
        DemotionPath path,
        address agreement
    ) private {
        uint256 mistakes = d.arbiterMistakeStreak[arbiterAddr] + 1;
        d.arbiterMistakeStreak[arbiterAddr] = mistakes;

        // ⚠️ THE CUMULATIVE COUNT IS NOT THE STREAK, AND IT DOES NOT TAKE ALL
        // THREE PATHS (21 August 2026). The line above records "one
        // more judicial mistake in a row"; this one records "one more verdict
        // of his was overturned", and the timeout is a judicial mistake that
        // overturned NOTHING — there was no ruling to overturn, which is why
        // notifyArbiterTimeout refuses to slash XP for it two hundred lines up.
        // Counting it here would put an overturn in the numerator of a fraction
        // whose denominator (`cleanVerdicts`) counts verdicts, and the reader
        // would be dividing two different things.
        //
        // Written as an ALLOW-list rather than `!= AgreementTimeout`: a fourth
        // DemotionPath added later must be named before it counts, instead of
        // being counted by default by a condition nobody revisits.
        if (path == DemotionPath.OwnerOverturn || path == DemotionPath.AppealVote) {
            d.overturnedVerdicts[arbiterAddr]++;
        }

        if (mistakes >= MAX_ARBITER_MISTAKES) {
            _suspendAndAccuse(d, rep, arbiterAddr, path, agreement);
        }
    }

    /// The SHARED consequence of both automatic triggers: stop the arbiter now
    /// and let the chain accuse him in its own name.
    ///
    /// ⚠️ ONE BODY, TWO TRIGGERS, AND THAT IS THE POINT (21 September 2026).
    /// It is reached from `_recordArbiterMistake` on the
    /// MAX_ARBITER_MISTAKES-th mistake IN A ROW, and from `finalizeVerdict`
    /// when the overturn RATE over the last OUTCOME_WINDOW closed cases reaches
    /// OUTCOME_OVERTURN_LIMIT. The owner's decision when the rate was added was
    /// that it buys NO NEW KIND OF PUNISHMENT: the same suspension, the same
    /// accusation with no author, the same 48 hours and the same right to
    /// answer. Copying the body for the second trigger would have been the
    /// cheap way to a second, slightly different punishment that nobody
    /// decided on.
    ///
    /// ⚠️ NOTHING IN HERE MAY REVERT. `notifyArbiterTimeout` reaches the first
    /// trigger from Agreement.sol (`triggerArbiterTimeout`) inside an EMPTY
    /// try/catch, so a revert is swallowed in silence and the arbiter walks
    /// away without a trace. Hence the yielding to a live proposal below
    /// instead of the refusal `proposeRemoval` uses.
    /// ⚠️ `rep` IS KEPT IN THE SIGNATURE AND NO LONGER READ (21 September
    /// 2026), the same way `by` is kept on `_recordArbiterMistake` and for a
    /// related reason. It was here to carry the XP reset, and the reset is gone;
    /// the name is commented out rather than the parameter dropped so that the
    /// two call sites keep saying "this branch is allowed to touch reputation
    /// storage" out loud. That is the thing to un-comment if a later decision
    /// ever gives the automatic path something to write there — and it is also
    /// the reason the removal of the reset is one deletion and not a reshuffle
    /// of three signatures.
    function _suspendAndAccuse(
        ArbiterRegistryStorage.Data storage d,
        ReputationStorage.Data storage /* rep */,
        address arbiterAddr,
        DemotionPath path,
        address agreement
    ) private {
        // The seat is no longer taken here. The automatic path stops the
        // arbiter at once and ACCUSES him; the removal itself runs through
        // the common door — proposal, 48 hours, a right to answer — like
        // every other removal. Decided 18 August 2026: the same door, and
        // the suspension is the fast path.
        //
        // Before this, the quiet door also survived the handover:
        // overturnVerdict sits under onlyOwnerOrDAO, which lets the owner
        // through always, so the ratchet this whole branch exists to build
        // was bypassed by three presses.
        //
        // ⚠️ XP IS NOT TOUCHED HERE, AND THE LINE THAT TOUCHED IT IS GONE
        // (21 September 2026). It read
        // `rep.xp[arbiterAddr] = DEMOTION_XP_RESET;` and stood exactly here.
        // Experience is the count of work a man actually did; rewriting it
        // backwards is not a punishment but a forgery of the record, and the
        // barrier it used to buy — keeping him under the entrance threshold —
        // is bought by the clean streak now, which the removal takes. The full
        // reasoning sits on the note where the constant used to be declared.
        //
        // What DOES land on this path: the suspension below, the accusation in
        // the chain's name, and — when the removal is executed — the forfeited
        // bond, the lost seat, the zeroed clean streak and a permanent record.
        // The per-mistake XP charge is a separate thing and still happens:
        // _slashArbiterXP takes OVERTURN_XP_SLASH at the moment ONE mistake is
        // proven, and that is not being reconsidered here.

        // ⚠️ THE SUSPENSION IS UNCONDITIONAL and stands ABOVE the guard
        // below. It is the fast lever, and it must land even when the
        // accusation cannot: an arbiter whose third mistake arrives while
        // a human accusation stands is still stopped this second.
        d.suspendedUntil[arbiterAddr] = block.timestamp + ArbiterRegistryStorage.SUSPENSION_WINDOW;

        // ⚠️ THE STREAK IS NOT CLEARED HERE, AND THE REASON WAS REWRITTEN
        // (18 August 2026). It used to say that _requireProven
        // reads this counter and zeroing it would leave the chain's own
        // accusation unprovable — "a door that looks built and never
        // opens". That became false: executeChainRemoval does not ask the
        // counter at all, and opens at streak 0.
        //
        // The reason it stays is plainer. The counter means "judicial
        // mistakes in an unbroken row", and the arbiter has done nothing to
        // break the row by being accused — clearing it here would have the
        // chain assert an end that did not happen. Two readers still live
        // on that value: the MANUAL door through _requireProven (reachable
        // once this accusation goes stale unpressed), and resolveAppeal,
        // which subtracts from it when a panel takes a mistake back.
        //
        // ⚠️ WHERE THE "BUILT AND NEVER OPENS" RISK ACTUALLY LIVES NOW: in
        // WRITING THE RECORD BELOW. That record is the whole proof the
        // button consults, so the way to build a door that never opens is
        // to skip it, not to touch this counter.
        //
        // The streak clears on the actual removal (_performRemoval), on
        // withdrawal of this proposal, and when a panel vindicates him.
        //
        // ⚠️ AND NOTHING BELOW MAY REVERT. notifyArbiterTimeout reaches
        // here from Agreement.sol (triggerArbiterTimeout) inside an EMPTY
        // try/catch: a revert is swallowed in silence and the arbiter walks
        // away untouched, without a trace. So a live proposal — anyone's —
        // is yielded to, not fought over: proposeRemoval was made to
        // refuse overwriting a standing record, and this branch writes
        // storage directly, past that door. It must obey the same rule
        // WITHOUT the revert that enforces it there.
        //
        // What yielding costs, named rather than hidden: the human
        // accusation may later be withdrawn, and the chain's proof does not
        // turn into a proposal by itself — another overturn is needed. The
        // streak is kept for exactly that, so the next one tries again.
        if (!_hasLiveProposalHere(d, arbiterAddr)) {
            // ⚠️ A NEW ACCUSATION IS A NEW RIGHT TO ANSWER, AND THE CHAIN
            // LAYS ITS OWN PAST proposeRemoval (19 August 2026).
            // The human door clears this flag for the same reason and says
            // so at length; this branch writes the record directly, so it
            // must obey the same rule without the door that enforces it.
            //
            // Reachable, not theoretical: an accusation nobody presses goes
            // stale after PROPOSAL_TTL, the arbiter stays seated and the
            // streak stays standing, so the next overturn lands here and
            // writes a fresh accusation. Without this line his answer to the
            // stale one would meet him as AlreadyAnswered — and the chain's
            // accusation is the one he can neither withdraw nor walk away
            // from. Guarded by
            // test_ANewChainAccusationReopensTheRightToAnswer.
            //
            // Inside the `if`, deliberately: when a live accusation is being
            // yielded to, nothing new is laid and the answer to what stands
            // must not be touched. And nothing here can revert — it is a
            // delete, which matters because notifyArbiterTimeout reaches
            // this branch inside an empty try/catch.
            delete d.removalReply[arbiterAddr];
            d.removalProposals[arbiterAddr] = ArbiterRegistryStorage.RemovalProposal({
                cause:          _causeForPath(path),
                // No digest: the evidence is the chain's own state, and a
                // hash of nothing would be a promise of a preimage nobody
                // can show. _requireProven reads the counter instead.
                evidenceDigest: bytes32(0),
                proposedAt:     block.timestamp,
                // ⚠️ THE ACCUSER IS THE CHAIN, so this is the zero address
                // and that is the whole guarantee: executeChainRemoval
                // refuses anything else, and nobody's name is dirtied by an
                // accusation no person made (a deliberate consequence of
                // the design).
                by:             address(0),
                // The chain's own accusation is bound by the same rule as a
                // person's: it lives as long as the constant in force when
                // it was laid, not as long as whatever the constant becomes
                // (26 August 2026).
                ttl:            uint64(PROPOSAL_TTL_MIRROR),
                // And the pause it owes him, frozen by the same argument from
                // the other end (25 September 2026). This one matters more on
                // this path than on the human one: the man accused by the chain
                // is also the man the accusation stops from working, and he
                // cannot resign while it stands, so for those forty-eight hours
                // answering is the only thing he can do on chain at all.
                delay:          uint32(REMOVAL_DELAY_MIRROR)
            });
            d.chainProposalPath[arbiterAddr] = uint8(path);
            emit RemovalProposedByChain(arbiterAddr, uint8(path), agreement, block.timestamp);
        }
    }

    // ⚠️ `freezeVerdict` STOOD HERE AND IS GONE (9 October 2026), by the
    // owner's decision. Three reasons, all measured:
    //
    //   * with `overturnVerdict` gone it was a weapon with no pair -- it could
    //     hold a verdict but never change one;
    //   * a press inside the appeal window takes the losing party's appeal away
    //     IRREVERSIBLY: `raiseAppeal` refuses on `frozen` before it looks at the
    //     clock, and the hold outlasts the window. Since 9 October both are 72
    //     hours, so the hold covers the window end to end -- and presses were
    //     unlimited, so the old margin was never load-bearing either;
    //   * suspending the arbiter does the same job without taking the appeal
    //     away: `finalizeVerdict` is gated on the suspension of the verdict's
    //     own arbiter. That lever now has a ceiling of three
    //     (`HAND_SUSPENSION_LIMIT`), which is the point -- a hold that cannot be
    //     repeated for ever is a hold somebody has to answer for.
    //
    // ⚠️ `FREEZE_WINDOW` AND `_freezeHolds` ARE KEPT, AND THAT IS LOAD-BEARING.
    // Verdicts frozen by this door BEFORE the cut may still be on chain with
    // `frozen = true`; the clock is the only thing that ever lets them go, and
    // `unfreezeVerdict` is gone too. Delete the clock and those verdicts --
    // somebody's escrow -- hang for ever. The appeal branch of `_freezeHolds`
    // stays live in its own right: `raiseAppeal` still sets `frozen`.

    // ⚠️ `unfreezeVerdict` STOOD HERE AND IS GONE (9 October 2026), together
    // with `freezeVerdict` above it. There is nothing left to lift: the only
    // hand-pressed freeze is gone, and the freeze an APPEAL raises is cleared
    // by `resolveAppeal`, which anybody may call once the window has closed.
    //
    // `error AppealInProgress()` is kept although nothing in this facet raises
    // it any more -- it was raised only by this door and by `overturnVerdict`.
    // Same argument as `NotOwnerOrChief` further up: a custom error's selector
    // is its signature, and a refusal already in the chain's history is decoded
    // by that selector and not by which contract still declares it.

    // -------- APPEAL FLOW (user-initiated, pre-finalization only) --------

    /// @notice The losing party challenges a verdict before the money reaches executor/client.
    ///
    /// ⚠️ THE PRICE IS NO LONGER FLAT (17 September 2026), and both sides of
    /// that argument are kept here rather than the losing one erased.
    ///
    /// The old argument: the deal amount is chosen by the parties, so it
    /// cannot be trusted as the input to anything that can be won or lost —
    /// hence a flat $20 on every deal.
    ///
    /// The argument that won: a flat $20 is a toll on a $100 deal and nothing
    /// on a $10 000 one, where overturning a verdict moves thousands and the
    /// appeal is the cheapest bet in the protocol. The panel is now paid out
    /// of the deposit, so a deposit that does not grow with what is at stake
    /// pays the same three arbiters the same six dollars to read a case of any
    /// size. And the first argument is weaker than it looked: the amount is
    /// the parties' own choice, but it is also the escrow itself — lowering it
    /// to cheapen an appeal lowers the very money the appeal is about, and the
    /// floor holds regardless.
    ///
    /// Decided by the owner: the price is the deal's own dispute fee (3% of
    /// the pot), held between 20 and 200 USDC —
    /// `ArbiterRegistryStorage.appealDepositFor`. What was actually paid is
    /// written into `appealDeposit`, so later changes to the rule reach only
    /// later appeals.
    function raiseAppeal(address agreement) external {
        if (agreement == address(0)) revert ArbiterZeroAddress();
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (v.submittedAt == 0) revert NoVerdict();
        if (v.finalized) revert AlreadyFinalized();
        // Checked before `frozen`: raiseAppeal() itself sets frozen=true as a side effect, so
        // once appealed, frozen is always already true too — checking frozen first would make
        // AlreadyAppealed unreachable on a second call to this same function.
        if (v.appealed) revert AlreadyAppealed();
        if (v.frozen) revert VerdictFrozenError();
        if (block.timestamp >= v.submittedAt + FINALIZE_DELAY) revert AppealWindowClosed();

        (bool clientOk, bytes memory clientData) = agreement.staticcall(abi.encodeWithSignature("client()"));
        (bool execOk,   bytes memory execData)   = agreement.staticcall(abi.encodeWithSignature("executor()"));
        if (!(clientOk && execOk)) revert DealPartiesUnreadable();
        address agreementClient   = abi.decode(clientData, (address));
        address agreementExecutor = abi.decode(execData,   (address));

        bool callerIsLosingClient   = caller == agreementClient   && !v.clientWins;
        bool callerIsLosingExecutor = caller == agreementExecutor &&  v.clientWins;
        if (!callerIsLosingClient && !callerIsLosingExecutor) revert NotLosingParty();

        // ⚠️ NOTHING IS COUNTED HERE ANY MORE (23 September 2026, the owner's
        // decision). Until this edit the line above walked `arbiterList` end to
        // end, two cold reads a seat, to find out whether a panel could
        // assemble — and THE APPELLANT PAID FOR THE WALK. Measured through the
        // real diamond with cold slots, in test/AppealPanelGas.t.sol: 150 029
        // gas at four seats, 613 805 at a hundred, 2 546 205 at five hundred.
        // Part 2 of this branch opened the corps to anybody with five clean
        // deals and put no ceiling on its size, so the price of challenging a
        // verdict was set to grow without bound. An appeal only the rich can
        // afford is not an appeal.
        //
        // The owner's answer was not a cheaper count but no count: the panel
        // has three seats, arbiters take them themselves, and whether two of
        // them are ever taken is settled at the END of the review window rather
        // than guessed at its start. What that costs, said plainly and not
        // discovered later: a deposit is now taken on an appeal that may find
        // no reader at all. It comes back whole when that happens — the
        // no-panel branch of `resolveAppeal`, which already existed and only
        // changed its reason.
        uint256 deposit = ArbiterRegistryStorage.appealDepositFor(agreement);
        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transferFrom(caller, address(this), deposit);
        if (!ok) revert DepositTransferFailed();

        v.appealed       = true;
        v.frozen         = true;
        v.appellant      = caller;
        v.appealDeadline = block.timestamp + APPEAL_REVIEW_WINDOW;
        // The money he put down, written next to the appeal it belongs to.
        // Not for reading back the price rule — for paying back
        // THIS man. See PendingVerdict.appealDeposit.
        v.appealDeposit  = deposit;
        // ⚠️ NO BAR IS FROZEN HERE ANY MORE, and the mapping that held it
        // (`appealVotesRequired`) keeps its slot unwritten — the layout is
        // append-only and a field is never taken back out. The bar stopped
        // depending on the corps when the panel stopped being drawn from it,
        // so there is nothing left to freeze: every appeal raised from today
        // needs the same two votes, and `_appealVotesRequired` answers that
        // for a zero. One cold SSTORE saved on every appeal, which is the
        // appellant's money.

        emit AppealRaised(agreement, caller);
    }

    // ⚠️ `_eligibleVoterCount` WAS DELETED HERE ON 23 SEPTEMBER 2026, together
    // with `_votesRequiredFor`, and this note stands in their place because
    // their absence is load-bearing. The first walked `arbiterList` to count
    // who could vote; the second turned that count into a quorum. Both were
    // called from `raiseAppeal`, so the corps' size was priced into every
    // appeal — see the measurement quoted there. Nothing in this file may walk
    // that list on a user's path again: the list has no ceiling, and the man
    // paying is the one challenging a verdict.
    //
    // What replaced them is the seat count itself. The panel has
    // APPEAL_VOTES_CAP seats, a vote IS the seat, and `voteOnAppeal` refuses
    // the arbiter who arrives when they are gone. Who may sit is asked of the
    // ONE man pressing the button, never of the roster.

    /// When this appeal's seats open: an hour after it was raised.
    ///
    /// ⚠️ THE MOMENT IT WAS RAISED IS NOT STORED, AND IS NOT GOING TO BE.
    /// `appealDeadline` is the only mark `raiseAppeal` leaves on the clock, so
    /// the raise is read back out of it. A field of its own would be honest
    /// arithmetic bought with one cold SSTORE on every appeal — the
    /// appellant's money, and this whole branch exists because he was being
    /// charged for things that are not his case.
    ///
    /// ⚠️ WHAT THAT COSTS, said out loud rather than discovered at a cut. The
    /// subtraction reads APPEAL_REVIEW_WINDOW LIVE, so a cut that changes the
    /// window moves the computed raise moment of every appeal already standing
    /// — the same class as PROPOSAL_TTL and the flat appeal deposit, both of
    /// which were given frozen copies here after they bit. It is left live
    /// because the damage is bounded and small: the window can only be changed
    /// by a cut, an appeal lives four days, and the worst case is an arbiter
    /// waiting that much longer or that much less for a seat. If the window is
    /// ever made settable by a lever rather than a cut, this must be frozen per
    /// appeal before that lever lands.
    ///
    /// Only ever called where `v.appealed` is already true, so `appealDeadline`
    /// is non-zero; the guard below is for the view, which answers for verdicts
    /// that carry no appeal at all.
    function _seatsOpenAt(ArbiterRegistryStorage.PendingVerdict storage v)
        private
        view
        returns (uint256)
    {
        uint256 deadline = v.appealDeadline;
        if (deadline < APPEAL_REVIEW_WINDOW) return APPEAL_SEAT_DELAY;
        return deadline - APPEAL_REVIEW_WINDOW + APPEAL_SEAT_DELAY;
    }

    /// The bar a raised appeal has to clear: APPEAL_VOTES_FLOOR, two votes.
    ///
    /// ⚠️ A STORED VALUE STILL WINS, AND THE MAPPING IS NOT DEAD WEIGHT.
    /// Between 18 and 23 September 2026 `raiseAppeal` froze `min(CAP,
    /// eligible)` into it, so an appeal raised in that window carries the bar
    /// it was paid for and is held to that and not to today's rule. Nothing
    /// writes the mapping from 23 September on; this is its only reader.
    ///
    /// ⚠️ AND ZERO NOW ANSWERS TWO, WHERE IT USED TO ANSWER THREE — said out
    /// loud because it is a loosening. Zero means one of two things: an appeal
    /// raised from today (whose bar is the floor by the rule in force), or an
    /// appeal raised before the mapping existed at all, under the flat quorum
    /// of three. The second sort would now settle on two votes instead of
    /// three. It is a window of four days that closed in September, on a
    /// testnet, and paying for a second field to keep three alive for it would
    /// be paying for a memory of nobody.
    function _appealVotesRequired(
        ArbiterRegistryStorage.Data storage d,
        address agreement
    ) private view returns (uint256) {
        uint256 stored = d.appealVotesRequired[agreement];
        return stored == 0 ? APPEAL_VOTES_FLOOR : stored;
    }

    /// @notice What this appeal's panel looks like right now, for a screen that
    /// has to say "one seat left, two votes needed" without guessing a number.
    ///
    /// ⚠️ THE FIRST RETURN CHANGED MEANING ON 23 SEPTEMBER 2026 and was
    /// renamed with it, deliberately rather than quietly. It used to be
    /// `eligible` — arbiters who could vote, counted by walking the roster.
    /// There is no roster walk any more and nothing to count: the panel is
    /// three seats and a vote is a seat, so what a board actually needs to know
    /// is how many are left. A front end reading the old name gets a compile
    /// error instead of a number that means something else.
    ///
    /// ⚠️ A FOURTH RETURN WAS APPENDED ON 24 SEPTEMBER 2026 with the hour the
    /// seats stay shut. A screen that can only say "no" is the refusal this
    /// repository keeps finding on the far side of a press already decided on;
    /// with this number it says "in forty minutes" instead.
    ///
    /// Appended to THIS view rather than given a view of its own, and that is a
    /// deliberate choice about the CUT: a new function is a new selector, and a
    /// selector added beside a facet being replaced turns one `Replace` group
    /// into a `Replace` and an `Add`. Return values do not enter a selector —
    /// `getAppealPanel(address)` is the same four bytes it was — so the whole
    /// facet still goes in as a single clean Replace.
    ///
    /// @return seatsFree   seats on this appeal's panel nobody has taken
    /// @return required    votes needed before it can be settled
    /// @return cast        votes already in — the seats taken, the same number
    /// @return seatsOpenAt when an arbiter may first take one; zero when no
    ///                     appeal stands, because there is nothing to wait for
    function getAppealPanel(address agreement)
        external
        view
        returns (uint256 seatsFree, uint256 required, uint256 cast, uint256 seatsOpenAt)
    {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        cast      = v.votesUphold + v.votesOverturn;
        seatsFree = cast >= APPEAL_VOTES_CAP ? 0 : APPEAL_VOTES_CAP - cast;
        // Answered for a verdict with no appeal on it too, and the answer is
        // the same two: the bar no longer depends on anything that could have
        // changed between the quote and the appeal.
        required  = _appealVotesRequired(d, agreement);
        // Read through the same helper the door reads, never recomputed here.
        seatsOpenAt = v.appealed ? _seatsOpenAt(v) : 0;
    }

    /// @notice Any registered arbiter with a whole bond votes exactly once — except the one
    /// who ruled and the two parties to the deal.
    function voteOnAppeal(address agreement, bool overturn) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (!d.isArbiter[caller]) revert NotArbiter();
        // ⚠️ THIS IS THE ONLY PLACE THE QUESTION IS ASKED (23 September 2026).
        // It used to be asked twice — here, and over every seat in the roster
        // inside `raiseAppeal` — and the two had to be kept in step or the
        // appellant paid for a panel that could not assemble. The roster walk
        // is gone, so there is nothing left to keep in step.
        //
        // ⚠️ ONE CASE OF HIS OWN, CARRIED TO A VERDICT THAT STOOD — the
        // owner's replacement for the bond that used to stand here. A free seat
        // plus a paid vote is a hole anybody with addresses could work; a
        // record of work is not something a fresh wallet can bring. Hand-seated
        // arbiters are exempt, and on the day this lands that exemption is the
        // only reason an appeal can be reviewed at all. See `_mayVoteOnAppeals`.
        if (!_mayVoteOnAppeals(d, caller)) revert NoAdjudicatedCase();
        if (!v.appealed) revert NoAppeal();
        if (v.appealResolved) revert AppealAlreadyResolved();
        if (caller == v.arbiter) revert CannotVoteOnOwnVerdict();
        // ⚠️ NOR A PARTY TO THE DEAL (17 September 2026, journal item 199).
        // claimDispute already refused a party as the JUDGE; the panel had no
        // such check, so a party holding a bonded seat could cast one of the
        // three votes that decide where its own escrow goes. Read from the
        // registry's record of the deal rather than from the clone: the same
        // two addresses, written once at creation, without an external call.
        RegistryStorage.AgreementRecord storage rec = RegistryStorage.store().agreements[agreement];
        if (caller == rec.client || caller == rec.executor) revert CannotVoteOnOwnDeal();
        if (block.timestamp >= v.appealDeadline) revert AppealWindowClosed();
        // ⚠️ AND NOT IN THE FIRST HOUR (24 September 2026, the owner's
        // decision). Checked BELOW the window and ABOVE the seat count, so that
        // an arbiter who is too early hears "too early" and not "full": the two
        // refusals send him away for very different lengths of time.
        uint256 openAt = _seatsOpenAt(v);
        if (block.timestamp < openAt) revert AppealSeatsNotOpenYet(openAt);
        if (d.hasVotedAppeal[agreement][caller]) revert AlreadyVoted();
        // ⚠️ THREE SEATS, AND THE THIRD IS THE LAST (23 September 2026, the
        // owner's decision). Whoever presses first takes a seat; the fourth
        // arbiter to arrive is refused, and the appeal is off the board.
        //
        // A VOTE IS THE SEAT — there is no separate claim, and that is a
        // decision and not an omission:
        //
        //   • a seat booked and never voted from is a seat nobody else can
        //     take. Three addresses that sit down and stay silent would kill
        //     every appeal in the protocol for the price of the gas, and an
        //     appeal is the only check a wrong verdict has;
        //   • the panel's pay is already per vote cast, so "who really sat" and
        //     "who gets paid" stay ONE set. Two records of the same fact agree
        //     only until the first edit.
        //
        // The count is `votesUphold + votesOverturn` and not a field of its
        // own, for the same reason: the two are the same number by
        // construction, and the second copy would be a mirror.
        if (v.votesUphold + v.votesOverturn >= APPEAL_VOTES_CAP) revert AppealPanelFull();

        d.hasVotedAppeal[agreement][caller] = true;
        if (overturn) {
            v.votesOverturn++;
        } else {
            v.votesUphold++;
        }

        emit AppealVoteCast(agreement, caller, overturn);
    }

    /// @notice Settles the appeal vote. It may be called as soon as the votes
    /// cast both reach the bar and point one way, without waiting for the
    /// window to end; a tie waits, because the seat still open could break it.
    /// If the window closes with fewer than APPEAL_VOTES_FLOOR arbiters having
    /// sat down, the appeal is rejected by default and the deposit goes home
    /// whole (nothing hangs forever).
    ///
    /// ⚠️ THE OUTCOME IS A STRICT MAJORITY OF THE VOTES CAST, and it is read
    /// off the votes rather than off the quorum on purpose (18 September 2026,
    /// when the quorum became movable). The two agree wherever the rule can
    /// actually take them — at two cast both must say overturn, at three cast
    /// two do — and they part on ONE turnout: four cast, two each. There a
    /// threshold taken from the quorum (2) would let both sides "decide" at
    /// once, while a majority of the votes cast upholds, because a tie is not a
    /// majority. Upholding on a tie is also what the flat quorum already did.
    /// Nothing here can decide an appeal on fewer than APPEAL_DECIDING_VOTES
    /// votes, which is what the cap on the chief's bloc is measured against.
    ///
    /// ⚠️ WHERE THE DEPOSIT GOES (17 September 2026, the owner's decision):
    ///
    ///   no quorum        → back to the appellant, whole. Nobody reviewed the
    ///                      case, so the deposit bought nothing.
    ///   quorum, any side → to the panel, equally per vote cast, the remainder
    ///                      of the division to the bank. Paid on EVERY outcome,
    ///                      and that is the point: a panel paid only when it
    ///                      refuses the appeal is a panel paid to refuse.
    ///   quorum, overturn → the appellant is ALSO made whole, at the cost of the
    ///                      arbiter who was wrong: his forfeited share of the
    ///                      dispute fee, then his bond, then the treasury's
    ///                      share of the same fee, then the bank, then a debt.
    ///                      Neither share exists yet at this line — both are
    ///                      credited in `creditDisputeFee`, inside the
    ///                      `finalizeVerdict` this very call unblocks (measured in
    ///                      test/AppealFeeTimingSeam.t.sol) — so the refund is
    ///                      ADVANCED out of the bond and the bank here, recorded
    ///                      in `appealLedgers`, and the shares pay the advance
    ///                      back when they land. A debt left standing is paid by
    ///                      the arbiter's next top-up or out of his bond when he
    ///                      resigns, or out of the bank by `settleAppealDebts`.
    ///
    /// ⚠️ NO LOOP OVER THE VOTERS, and none may be added. This is the only door
    /// that unfreezes the escrow; a payout per voter inside it would give it a
    /// cost that grows with turnout, and the day it ran out of gas the escrow
    /// would be frozen for good. The panel's pay is written as ONE number per
    /// voter and each voter pulls his own through `withdrawAppealShare`.
    function resolveAppeal(address agreement) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (!v.appealed) revert NoAppeal();
        if (v.appealResolved) revert AppealAlreadyResolved();

        uint256 votes = v.votesUphold + v.votesOverturn;
        // THE PANEL IS WHOEVER SAT DOWN, and two of them are a panel. The bar
        // is a constant now (see `_appealVotesRequired`), except for the
        // handful of appeals raised in the five days the bar was frozen per
        // appeal.
        bool panelFormed  = votes >= _appealVotesRequired(d, agreement);
        bool windowClosed = block.timestamp >= v.appealDeadline;
        // ⚠️ A TIE IS NOT A RESULT, SO IT IS NOT A REASON TO SETTLE EARLY
        // (23 September 2026, and it arrived WITH the seats rather than being
        // noticed after). Anyone may press this door. With the bar at two and
        // a third seat still open, one vote each way would otherwise let the
        // side the verdict favours press at exactly the wrong moment: a tie
        // upholds, so rushing this call at 1–1 buys the win the third arbiter
        // might have taken away. Holding a tie back to the window costs the
        // honest case nothing — the third vote breaks it and settles it the
        // same second, and three votes can never tie.
        bool settledEarly = panelFormed && v.votesOverturn != v.votesUphold;
        if (!settledEarly && !windowClosed) revert AppealWindowNotClosed();

        v.appealResolved = true;
        v.frozen         = false;

        bool overturn = panelFormed && v.votesOverturn > v.votesUphold;
        address usdc  = FactoryStorage.store().usdc;
        uint256 deposit = _depositOf(v);

        if (panelFormed) {
            // Integer division, the remainder to the bank: at most `votes - 1`
            // base units, and never a unit invented or lost — share × votes +
            // remainder is the deposit exactly.
            uint256 perVoter = deposit / votes;
            uint256 remainder = deposit - perVoter * votes;
            // uint64 cannot truncate: perVoter <= deposit <= APPEAL_DEPOSIT_CAP.
            d.appealLedgers[agreement].voterShare = uint64(perVoter);
            if (remainder != 0) d.vaultBalance += remainder;
            emit AppealPanelPaid(agreement, perVoter, votes, remainder);
        } else {
            // The window closed on fewer than two arbiters, so the case was
            // never really read and the deposit bought nothing. Since
            // 23 September 2026 this is also where a corps too small to review
            // anything lands — `raiseAppeal` used to refuse those at the door
            // and no longer counts, so the refusal became a refund.
            _payAppellant(d, usdc, agreement, v.appellant, deposit);
            emit AppealDepositReturned(agreement, v.appellant, deposit);
        }

        if (overturn) {
            address slashedArbiter = v.arbiter;

            // ⚠️ THE READ OF `overturned` THAT STOOD HERE IS GONE WITH THE
            // BRANCH IT FED (9 October 2026). It existed to tell "the panel is
            // correcting the HAND" from "the panel is correcting the ARBITER",
            // and after the hand was removed there is only the second. The
            // paragraph that used to stand here reasoned about TWO writers of
            // the flag; there is one now, and the reasoning would be false.

            v.clientWins = !v.clientWins;
            v.overturned = true;

            // ⚠️ A PANEL THAT VINDICATES THE ARBITER TAKES HIS MISTAKE BACK.
            // The sequence that made this necessary: the arbiter rules, the
            // owner's hand overturns him (mistake one), the losing side appeals
            // — which stays open on purpose, it is the only check on the owner
            // there is — and the panel votes to overturn, flipping the ruling
            // back to the ARBITER'S OWN. The panel has just said he was right
            // and the owner was wrong.
            //
            // Booking that as HIS mistake slashed his XP twice for one verdict
            // and wrote DemotionPath.AppealVote into the permanent record: the
            // chain asserting "the panel found him wrong" precisely where it
            // found the opposite. Measured before the fix: two disputes unseated
            // an arbiter instead of three, and no collusion was needed — an
            // honest panel deciding correctly handed the owner the second
            // mistake for free.
            //
            // So the second booking does not happen, and the first is taken
            // back: if the panel says there was no judicial mistake, then a
            // mark standing against him for that verdict is the record lying.
            // ONE is subtracted, not the whole streak — mistakes on OTHER
            // disputes are his and stay his.
            //
            // ⚠️ XP IS NOT GIVEN BACK, and that is said out loud rather than
            // passed over. _slashArbiterXP takes OVERTURN_XP_SLASH with a floor
            // at zero and records nowhere how much it actually took, so adding
            // the constant back would hand an arbiter who was slashed INTO the
            // floor points he never had. Storing the amount taken would cost a
            // storage field for a small truth, and that trade was refused. The
            // slash he keeps is one instead of two, the second having left
            // together with the booking.
            //
            // ⚠️ HOW FAR THE VINDICATION REACHES, REWRITTEN ON
            // (18 August 2026). This paragraph used to say "the counter comes
            // back, the seat does not: the demotion already fired inside
            // _recordArbiterMistake — seat gone, bond forfeited, suspension set
            // — and none of that is walked back here". Two of its three facts
            // died with the threshold branch, and the code seven lines below
            // now contradicts a third.
            //
            // As it stands:
            //   • the third mistake takes NO seat and burns NO bond — it
            //     suspends and accuses, so on the ordinary timeline there is
            //     nothing to walk back and the branch below simply cancels the
            //     accusation, the counter and the suspension together;
            //   • the seat is still not restored, and that remains true in the
            //     one case where it was really lost: somebody pressed
            //     executeChainRemoval before the panel finished. Re-seating a
            //     removed arbiter is a different decision from arithmetic on a
            //     counter, and it is not this line's to make;
            //   • the bond is not returned in that same case, for the same
            //     reason and by the same silence.
            //
            // Named so that it stays a known gap rather than a silent one.
            // ⚠️ THE VINDICATION BRANCH STOOD HERE AND IS GONE (9 October 2026).
            //
            // It handled one state and one only: THE HAND HAD ALREADY OVERTURNED
            // THIS VERDICT, and the panel was now flipping the outcome back to
            // the arbiter's own ruling. It took one overturn back off his
            // record, set `verdictVindicated`, withdrew the chain's own
            // accusation and restored the streak -- a counterweight to the
            // owner's mistake, and nothing else.
            //
            // ⚠️ THE STATE IS NOW UNREACHABLE BY CONSTRUCTION, not by care.
            // `v.overturned` has exactly ONE writer left, and it is the line a
            // few above this one, inside this same function. The flag was read
            // at the TOP of this branch, before that write; one appeal exists
            // per verdict (`appealResolved` above), so this branch cannot see
            // its own write. With the hand gone there is no other writer, so
            // "already overturned when the panel sat down" cannot happen.
            // Guarded mechanically rather than by this paragraph:
            // test/ArbiterOverturnedHasOneWriter.t.sol counts the writers in
            // src/ and demands exactly one, inside `resolveAppeal`.
            //
            // ⚠️ WHAT IS DELIBERATELY KEPT, THOUGH NOTHING WRITES IT ANY MORE:
            // the `verdictVindicated` mapping (this namespace is append-only, a
            // field is never taken back out) and its read in `finalizeVerdict`.
            // With no writer it answers false for every deal, which makes
            // `countAsOverturn` equal to `v.overturned` -- the same arithmetic,
            // one SLOAD. Deals vindicated BEFORE this cut keep their bit and are
            // still read correctly, which is the reason the read stays rather
            // than being simplified away.
            {
                ReputationStorage.Data storage rep = ReputationStorage.data();
                _slashArbiterXP(rep, slashedArbiter);
                // `by` is zero: anyone may call resolveAppeal, and the VOTES decide.
                // Naming whoever pressed "settle" as the author would be the worst
                // of the three possible untruths.
                _recordArbiterMistake(d, rep, slashedArbiter, address(0), DemotionPath.AppealVote, agreement);
            }

            // Outside the mistake branch: the appellant won the vote and is
            // made whole. His own deposit went to the panel above, so "made
            // whole" is now paid by somebody else — see the function's header
            // for who, and `_advanceAppealRefund` for how.
            //
            // ⚠️ THE ARBITER ALWAYS PAYS NOW, AND THE BRANCH THAT EXCUSED HIM IS
            // GONE (9 October 2026). This line used to read
            // `alreadyOverturned ? address(0) : slashedArbiter`: a VINDICATED
            // arbiter paid nothing, because the panel had just restored his
            // ruling against the owner's hand and charging his bond for the
            // hand's mistake would have been the chain punishing the man it
            // found right. With the hand removed there is no such state —
            // `v.overturned` has one writer and it is this very function, read
            // before its own write — so the ternary had exactly one reachable
            // arm and is written out as that arm. Behaviour is unchanged for
            // every verdict this code can now meet.
            //
            // The older gap it names is untouched: the fee share
            // `creditDisputeFee` withholds on every overturned verdict still
            // pays the advance back, the `overturned` flag holds two facts (see
            // `overturnedVerdicts`), and this line neither widens nor closes
            // that.
            _advanceAppealRefund(
                d, usdc, agreement, v.appellant, slashedArbiter, deposit
            );
        }

        emit AppealResolved(agreement, v.appellant, overturn);
    }

    /// Pays a won appeal back before the ruling arbiter's forfeited fee share
    /// exists: out of his bond, then out of the bank, and records the rest as a
    /// debt. `arbiterAddr` zero means "nobody's bond" (a vindicated arbiter).
    ///
    /// ⚠️ THE DEBT IS WRITTEN IN `appealLedgers`, NOT IN `refundableBounty`.
    /// Every entry of the second is USDC the diamond holds; a debt has nothing
    /// behind it, and `withdrawDisputeBounty` would have paid it out of other
    /// people's escrow. It becomes claimable only as `creditDisputeFee` brings
    /// real money in.
    ///
    /// ⚠️ THE BOND IT DRAWS IS THIS CASE'S OWN (22 September 2026), never a
    /// standing one — there is no standing one. The arbiter put it down when he
    /// took this deal, priced by `appealDepositFor(deal)`, which is the very
    /// function that priced the deposit being refunded: the bond covers exactly
    /// one refund to one appellant, and on an unchanged pot it covers it to the
    /// unit. That is the whole of the owner's sizing argument, and it holds by
    /// arithmetic rather than by two constants agreeing.
    ///
    /// What is left of it after this — nothing, in the ordinary case — goes
    /// home to him at `finalizeVerdict`. His OTHER cases are untouched: each
    /// carries its own money, so one wrong verdict cannot leave the next one
    /// underfunded, which is the failure mode the old "sagging seat" machinery
    /// existed to paper over.
    ///
    /// ⚠️ THE BOND'S SHARE OF THE BURDEN IS FIXED HERE, at the moment the
    /// verdict is overturned: whatever it holds now, up to the deposit. When
    /// the fee arrives, the treasury's 20% of it covers only what the
    /// arbiter's 80% and THIS advance left uncovered.
    ///
    /// ⚠️ THE BANK IS SPENT ONLY ABOVE THE DEBTS IT ALREADY OWES
    /// (`bankAboveDebts`), so an older appellant's debt is not overtaken by a
    /// newer appeal. A debt created here goes onto the arbiter's own list
    /// (paid first by his top-up or out of his bond when he resigns) and onto
    /// the bank's queue (paid out of the bank by anyone's press, in order) —
    /// the two ways out that do not depend on this deal's fee ever arriving.
    function _advanceAppealRefund(
        ArbiterRegistryStorage.Data storage d,
        address usdc,
        address agreement,
        address appellant,
        address arbiterAddr,
        uint256 owed
    ) private {
        uint256 fromBond;
        if (arbiterAddr != address(0)) {
            ArbiterRegistryStorage.CaseBond storage cb = d.caseBonds[agreement];
            uint256 bond = cb.amount;
            fromBond = owed < bond ? owed : bond;
            if (fromBond != 0) {
                // uint96 cannot truncate: fromBond <= bond, already a uint96.
                cb.amount = uint96(bond - fromBond);
                owed -= fromBond;
                emit CaseBondForfeited(agreement, arbiterAddr, fromBond);
            }
        }

        uint256 bank = ArbiterRegistryStorage.bankAboveDebts(d);
        uint256 fromVault = owed < bank ? owed : bank;
        if (fromVault != 0) {
            d.vaultBalance -= fromVault;
            owed -= fromVault;
        }

        // One slot for three fields. uint64 cannot truncate: each is at most
        // one deposit, and a deposit is at most APPEAL_DEPOSIT_CAP.
        ArbiterRegistryStorage.AppealLedger storage l = d.appealLedgers[agreement];
        l.advanceFromBond  = uint64(fromBond);
        l.advanceFromVault = uint64(fromVault);
        l.debt             = uint64(owed);

        if (owed != 0) {
            l.appellant = appellant;
            d.appealDebtTotal += owed;
            d.appealDebtQueue.push(agreement);
            if (arbiterAddr != address(0)) d.arbiterDebtCases[arbiterAddr].push(agreement);
        }

        if (fromBond + fromVault != 0) _payAppellant(d, usdc, agreement, appellant, fromBond + fromVault);
        emit AppealRefundAdvanced(agreement, appellant, fromBond, fromVault, owed);
    }

    /// Money to the appellant, SOFT. For a heavier reason than in
    /// clearDisputeClaim: the writes in resolveAppeal are what unfreeze the
    /// verdict; a reverting refund takes them down with it, and every other
    /// door out is already shut (finalizeVerdict: VerdictFrozenError,
    /// unfreezeVerdict and overturnVerdict: AppealInProgress, raiseAppeal:
    /// AlreadyAppealed, Agreement.triggerArbiterTimeout: VerdictInFlight,
    /// forever, because hasSubmittedVerdict never goes back to false). A
    /// deposit that cannot be delivered would therefore strand the WHOLE
    /// escrow, in the clone, where no rescue function exists. What does not
    /// land goes into the existing claimable — real USDC stays on the diamond,
    /// so the booking is backed.
    function _payAppellant(
        ArbiterRegistryStorage.Data storage d,
        address usdc,
        address agreement,
        address appellant,
        uint256 amount
    ) private {
        if (!_softTransfer(usdc, appellant, amount)) {
            d.refundableBounty[appellant] += amount;
            emit DisputeBountyRefundable(agreement, appellant, amount);
        }
    }


    /// Before governance is live the owner appoints (naming a successor in
    /// advance — activateDAO() requires daoAddress to be non-zero already). After
    /// activation only the daoAddress already in office changes itself
    /// (self-migration) — NOT through `onlyOwner`: that would let the owner back
    /// in through a door he supposedly closed forever (found in review,
    /// 15 August 2026). Without this gate the owner could take
    /// removeArbiterForCause back with one extra transaction:
    /// activateDAO() → setDAOAddress(his_own_address) → a removal on the
    /// msg.sender == daoAddress branch.
    ///
    /// ⚠️ The ratchet latches only when `d.daoAddress != address(0)` — a
    /// qualifier added on 15 August 2026. Its original reason —
    /// "governance switched itself on, there is no successor, and `only the
    /// current daoAddress may call` degenerates into `only address(0) may call`"
    /// — disappeared on 26 August 2026: governance now switches on by one manual
    /// flag, and `activateDAO()` requires an already confirmed successor.
    /// The qualifier is kept as a belt for exactly the same reason as in
    /// _requireSeatingNotHandedOver — see its docstring in full, which also
    /// covers the fact that the change to `isDaoActive()` was made in the end and
    /// what it does to the money.
    /// ⚠️ THIS FUNCTION NO LONGER APPOINTS, IT PROPOSES
    /// (26 August 2026). Rights move on a second step — `acceptDAOAddress()`,
    /// sent by THE NAMED ADDRESS ITSELF. The fork "before governance the owner,
    /// after it only the holder in office" is exactly the same and is set out
    /// above: the two steps are laid on top of it, they do not replace it.
    ///
    /// Until a proposal is confirmed NOTHING changes: `daoAddress` is unchanged,
    /// the rights are unchanged, and the ratchet below reads the previous value.
    /// Hence there is no separate cancellation — proposing a different address
    /// costs the same single transaction, and a zero one is still rejected:
    /// "erase the successor" and "name the successor" must not be one button.
    function setDAOAddress(address dao) external {
        if (dao == address(0)) revert ArbiterZeroAddress();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (isDaoActive() && d.daoAddress != address(0)) {
            if (msg.sender != d.daoAddress) revert NotCurrentDaoAddress();
        } else {
            if (msg.sender != OwnershipLib.contractOwner()) revert NotOwner();
        }
        d.pendingDaoAddress = dao;
        emit DAOAddressProposed(dao);
    }

    // -------- AGREEMENT CALLBACKS --------

    function clearDisputeClaim(address agreement) external {
        require(msg.sender == agreement, "ArbiterRegistry: only agreement");
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        address claimedArbiter = d.disputeClaims[agreement];
        if (claimedArbiter != address(0)) {
            // The anchor and the no-response record are untouched — see releaseDisputeClaim.
            delete d.disputeClaims[agreement];
            if (d.openClaimCount[claimedArbiter] > 0) d.openClaimCount[claimedArbiter]--;
            // The slot only if he never signed: `submitVerdict` already freed
            // it on the signature, and freeing it twice would let one arbiter
            // read two cases at once. Read BEFORE the stuck-verdict branch
            // below deletes the record it is read from.
            if (d.pendingVerdicts[agreement].submittedAt == 0) {
                _freeJudgingSlot(d, claimedArbiter);
            }
        }
        // Auto-clearing a stuck verdict: if the Agreement left the dispute through a
        // timeout while the verdict is not finalized and not executing right now, drop it.
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];
        if (v.submittedAt > 0 && !v.finalized && !v.executing) {
            delete d.pendingVerdicts[agreement];
            emit StuckVerdictAutoCleared(agreement);
        }

        // Refund of the top-up if no verdict happened.
        //
        // The discriminator already exists and no second one is needed:
        // finalizeVerdict sets v.executing before calling resolveDispute and clears
        // it after, while v.finalized is set LATER than the external call — so here
        // it is still false. So executing == true means "inside the finalization of
        // a verdict", set on that path only; on both timeout branches it is false.
        //
        // Selling what cannot be guaranteed is worse than not selling: having paid
        // and received neither a judge nor the money back is no longer a service.
        if (!v.executing) {
            // A counter for both: the dispute ended with nobody, or no time, to
            // judge it. Written straight into the namespaced reputation storage —
            // the same device this file already uses to slash XP on a proven
            // overturn (_slashArbiterXP).
            //
            // ⚠️ THE EXAMPLE WAS SWAPPED ON 21 SEPTEMBER 2026. It used to point at
            // "reset XP on a demotion (_recordArbiterMistake)", which is no longer
            // a thing this file does at all — the reset is gone. The TECHNIQUE
            // being justified is unchanged (one facet writing a neighbouring
            // namespace directly, no cross-facet call, no selector); only the
            // living example of it had to be replaced by one that still exists.
            RegistryStorage.AgreementRecord storage rec = RegistryStorage.store().agreements[agreement];
            if (rec.client != address(0)) {
                ReputationStorage.Data storage rep = ReputationStorage.data();
                rep.unresolvedDisputes[rec.client]   += 1;
                rep.unresolvedDisputes[rec.executor] += 1;
            }

            // ⚠️ AND NOT ONE INSTRUCTION IS SPENT ON THE CASE BOND HERE. The
            // deal ended with nobody judging it, so that bond covers nothing
            // and is the arbiter's to collect — but this whole function runs
            // under the clone's CLAIM_CLEAR_GAS cap (200 000, unraisable), and
            // a refund on this path was measured at +46 000 gas. The record
            // stays where it is and he takes it with `withdrawCaseBond`; see
            // `_releaseCaseBond` for the measurement.

            uint256 bounty = d.disputeBounty[agreement];
            if (bounty > 0) {
                address payer = d.disputeBountyPayer[agreement];
                d.disputeBounty[agreement] = 0;
                delete d.disputeBountyPayer[agreement];

                // The vault's share goes back to the vault, and only the
                // remainder goes to the person. Otherwise a dispute that never
                // happened would be a way to pull three dollars out of the buffer:
                // pay your half, never get a judge, take both. The return to the
                // vault is a plain write that cannot fail to land, so it stands
                // BEFORE the soft transfer and does not depend on its outcome.
                uint256 subsidy = d.disputeVaultSubsidy[agreement];
                if (subsidy != 0) {
                    delete d.disputeVaultSubsidy[agreement];
                    d.vaultBalance += subsidy;
                }
                bounty -= subsidy;

                // A soft refund. A hard one is inadmissible here: the Agreement
                // calls this function inside a `try {} catch {}` with an empty
                // handler (the soft creditDisputeFee payment in Agreement.sol), so
                // a reverting transfer would silently drag down the claim release
                // and the openClaimCount decrement, leaving the arbiter with an open
                // dispute forever.
                //
                // The response length is checked inside _softTransfer, by the same
                // device as SafeUSDC.trySafeTransfer in Agreement.sol.
                if (_softTransfer(FactoryStorage.store().usdc, payer, bounty)) {
                    emit DisputeBountyRefunded(agreement, payer, bounty);
                } else {
                    d.refundableBounty[payer] += bounty;
                    emit DisputeBountyRefundable(agreement, payer, bounty);
                }
            }
        }
    }

    /// @notice Emergency clearing of a stuck pending verdict.
    /// Arises when the Agreement executes triggerArbiterTimeout before finalizeVerdict —
    /// the Agreement goes to REFUNDED while pendingVerdicts hangs there forever.
    function clearStuckVerdict(address agreement) external {
        if (msg.sender != OwnershipLib.contractOwner()) revert NotOwner();
        if (agreement == address(0)) revert ArbiterZeroAddress();
        // Make sure the Agreement is already in a terminal state (not DISPUTED = 4)
        (bool ok, bytes memory st) = agreement.staticcall(abi.encodeWithSignature("status()"));
        if (!ok) revert AgreementStatusUnreadable();
        require(abi.decode(st, (uint8)) != 4, "ArbiterRegistry: agreement still disputed");
        delete ArbiterRegistryStorage.data().pendingVerdicts[agreement];
    }

    // -------- VIEWS --------
    //
    // ⚠️ THE BOUNDARY WITH ArbiterAccountabilityFacet (16 August 2026).
    // The facet hit the EIP-170 ceiling: 24 516 bytes out of 24 576, 60 free. Any
    // next edit of the registry would physically not have fitted. Fourteen READS
    // moved to the neighbouring facet, which holds the same ArbiterRegistryStorage
    // and the same POSITION — from outside the diamond the move is invisible: same
    // address, same selector, same answer, only a row in the routing table changes.
    //
    // The boundary is drawn by meaning, not by size:
    //   moved    — reads about an arbiter's BEHAVIOUR, STANDING and EVIDENCE
    //              (mistake and clean-verdict counters, the bond, disputes in
    //              hand, seating provenance, reward, the record of deals, chat
    //              keys, presentation anchor, no-response record, digests);
    //   remained — the registry as the OWNER OF THE ROSTER, DISPUTES, VERDICTS
    //              and APPEALS (getArbiters, isRegisteredArbiter, getChiefArbiter,
    //              getDisputeClaimer, getClaimCommitment, getPendingVerdict,
    //              hasSubmittedVerdict, getAppealVotes, hasVotedOnAppeal, the
    //              dispute and vault money).
    //
    // ⚠️ FOUR CONSTANT GETTERS DID NOT MOVE, AND THAT IS NOT AN OVERSIGHT.
    // getMinXPToRegister, getNoResponseFloor, getMaxArbiterMistakes and
    // getMaxClaimsPerArbiter read PRIVATE CONSTANTS OF THIS FACET, applied by the
    // code that stays here (applyAsArbiter, recordNoResponse,
    // _recordArbiterMistake, claimDispute). Moving a getter would require a SECOND
    // DECLARATION of the number in the neighbouring file — and then the outside
    // would be answered by a mirror while the live rule applied the original.
    // Exactly the class this split guards against: getMaxArbiterMistakes, once
    // moved, would turn test_MistakeThresholdMatchesRegistry into a mirror
    // checked against itself. If those bytes are ever needed, the constant moves
    // into ArbiterRegistryStorage as ONE declaration for both facets, as already
    // done with SUSPENSION_WINDOW; that is separate work, not done here.
    //
    // Three reads did not move for another reason — they are called FROM INSIDE:
    // isDaoActive (the onlyOwnerOrChief modifier), getArbiterFloor (from
    // quoteDisputeTopUp), quoteDisputeTopUp (from fundDispute). Plus getChiefBloc
    // — it calls the private _chiefBloc that addArbiter holds, and moving it
    // would cost a second copy of the body.
    //
    // ⚠️ THE SECOND BOUNDARY, WITH ArbiterVaultFacet (16 September 2026), and it
    // moved two of the four paragraphs above. The ceiling was hit AGAIN — 24 532
    // of 24 576, forty-four bytes — and the appeal economics could not be
    // written into that. The new line is one sentence: THIS FACET KEEPS EVERY
    // DOOR THAT DECIDES A DISPUTE OR CHANGES WHO IS AN ARBITER; ArbiterVaultFacet
    // TAKES EVERY DOOR THAT ONLY MOVES MONEY AND EVERY DOOR THAT ONLY READS A
    // NUMBER. Measured: 24 532 → 19 205 here, 28 selectors moved, the diamond's
    // total unchanged.
    //
    // So the paragraph above that ends "the dispute and vault money" is now the
    // history of the August split and not a description of today. Gone from here
    // to ArbiterVaultFacet: getArbiters, isRegisteredArbiter, getChiefArbiter,
    // getDisputeClaimer, getClaimCommitment, getPendingVerdict,
    // hasSubmittedVerdict, getAppealVotes, hasVotedOnAppeal, getDAOAddress,
    // getPendingDAOAddress — and all of the money, getArbiterFloor,
    // getDisputeDiscount and quoteDisputeTopUp with it, together with the three
    // constants no reader here uses any more (ARBITER_SHARE_BPS,
    // DEFAULT_ARBITER_FLOOR, DEFAULT_DISPUTE_DISCOUNT). Their declarations
    // stayed behind in this file, unread, until 17 September 2026 and were
    // deleted then; see the CONSTANTS block above.
    //
    // What is left below is what the paragraph about the FIVE constant getters
    // says it is — getMinXPToRegister, getDaoThreshold, getMaxArbiterMistakes,
    // getNoResponseFloor, getMaxClaimsPerArbiter, each reading a private
    // constant this file still applies — plus isDaoActive and getChiefBloc,
    // which are called from inside. The same rule decided the same way twice.

    /// @notice Is governance live. ONE source: the flag a person set.
    ///
    /// ⚠️ THE EARNED HALF IS GONE (26 August 2026). This used to
    /// read `daoActiveManual || uniqueActiveUsers >= DAO_THRESHOLD`, and the
    /// second half checked nothing that mattered: STRANGERS closing their own
    /// deals could snap it shut, at any moment, with `daoAddress` still zero.
    /// The instant it flipped, three doors into the corps closed
    /// (`addArbiter`, `setChiefArbiter`, applications), the chief's office was
    /// abolished — and there was nobody to hand any of it to. The guard that
    /// stops exactly that (`DaoAddressNotSet`) sits inside `activateDAO()`, so
    /// the earned path went round it.
    ///
    /// An intermediate form — keep the automatic path, give it the same
    /// successor check — was accepted and reversed the same hour: even guarded,
    /// an outsider still chooses WHEN, and the money moves with the power
    /// (the foundation's share drops 70% → 20% in an immutable treasury the
    /// moment this returns true). A handover of power needs somebody who
    /// performed it, not a counter that reached a number.
    ///
    /// The threshold did not disappear; it moved to `activateDAO()`, where it
    /// is a condition on the person's own press — see DAO_THRESHOLD.
    function isDaoActive() public view returns (bool) {
        return ArbiterRegistryStorage.data().daoActiveManual;
    }

    function getMinXPToRegister() external pure returns (uint256) { return MIN_XP_TO_REGISTER; }
    function getDaoThreshold()    external pure returns (uint256) { return DAO_THRESHOLD; }

    /// MAX_ARBITER_MISTAKES read from this side. It must equal
    /// ArbiterAccountabilityFacet.MAX_ARBITER_MISTAKES_MIRROR and must stay
    /// STRICTLY ABOVE that facet's MISTAKE_THRESHOLD — the manual door fires
    /// earlier than the automaton. Both are checked by test_MistakeThresholdMatchesRegistry.
    function getMaxArbiterMistakes() external pure returns (uint256) { return MAX_ARBITER_MISTAKES; }



    // getDisputeClaimedAt / getNoResponseAt moved to ArbiterAccountabilityFacet
    // (16 August 2026) — evidence about an arbiter's behaviour. What stays here
    // is getNoResponseFloor: it reads the private constant NO_RESPONSE_FLOOR,
    // applied by recordNoResponse in this same file, and moving it would require
    // a second declaration of the number. The argument is in the VIEWS header below.

    /// @notice How much must pass from claiming a dispute to a no-response record.
    /// The frontend must ask here rather than keep a number of its own.
    function getNoResponseFloor() external pure returns (uint256) {
        return NO_RESPONSE_FLOOR;
    }

    // getPresentationDigests / getPresentationDigestsPage /
    // getPresentationDigestCount / getArbiterChatKeys / getArbiterDeals moved
    // to ArbiterAccountabilityFacet (16 August 2026). The writes in this
    // file (recordPresentationDigest, setArbiterChatKey) stayed — only the
    // reads moved.



    // getSeatedBy / getSeatedCountBy moved to ArbiterAccountabilityFacet
    // (16 August 2026) — seating provenance. Writing the provenance
    // (addArbiter, clearSeat) stayed here; only the reads moved. The cut
    // script reads them THROUGH THE DIAMOND, so the provenance migration is
    // untouched — the address is the same one.

    /// @notice The chief's current bloc: how many votes in an appeal would fall
    /// to him if every arbiter he seated, and he himself (if he is an arbiter
    /// too), voted together.
    ///
    /// The guarded property is "the chief does not DECIDE an appeal", not "does
    /// not reach the quorum" (16 August 2026). resolveAppeal settles by a strict
    /// majority of the votes cast once the quorum of them exists: with three
    /// cast, two decide. addArbiter does not let this number grow to a deciding
    /// majority for the chief's own seatings, that is, it holds it at one.
    ///
    /// ⚠️ What this does NOT give and does not promise: the quorum is capped at
    /// APPEAL_VOTES_CAP however large the corps grows (18 September 2026 made it
    /// movable DOWNWARD, not upward), so any three who collude decide
    /// everything — the cap counts only the chief's people and does not touch
    /// such a three.
    function getChiefBloc() external view returns (uint256) {
        return _chiefBloc(ArbiterRegistryStorage.data());
    }

    /// @notice The cap on disputes an arbiter may hold at once.
    /// The only place the number is declared — the frontend must read it through
    /// this function rather than keep a copy.
    function getMaxClaimsPerArbiter() external pure returns (uint256) {
        return MAX_CLAIMS_PER_ARBITER;
    }

    // getCleanVerdicts moved to ArbiterAccountabilityFacet
    // (16 August 2026) — the clean-verdict counter. finalizeVerdict in this
    // file writes it; it is read only from outside.
}
