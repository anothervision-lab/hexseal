// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ArbiterApplicationsFacet.sol
//
// What is left of the interim admissions mechanism after the owner's decision
// of 22 September 2026 — the filter that takes back an unproven seat, the two
// retired bond doors, and the reads a form needs — PLUS, since 8 November 2026,
// the two doors by which an invited man answers, AND two more that arrived from
// `ArbiterRegistryFacet` later the same day: `applyAsArbiterWithPermit` and
// `revokeArbiterInvitation`.
//
// ⚠️ THE TWO IMMIGRANTS ARE HERE FOR A REASON THAT IS NOT ABOUT MEANING, AND
// SAYING SO IS THE POINT. The registry stood 3 716 bytes under EIP-170, where
// the appeal split of 15 October had bought it 4 937; the entry bond's own
// doors had spent exactly that room. These two could leave without a single
// chain write, because the cut that mounts them had not been signed — the
// chain routed 277 selectors and no entry bond when it was measured. After
// that cut the same move would have cost a second cut. The full argument, and
// what travelled with them, is at the two doors and in the notes left where
// they stood.
//
// ⚠️ THAT CUT WAS SIGNED ON 10 NOVEMBER 2026, so the window is shut: the
// chain now routes 282 selectors over the same fifteen facets, this facet
// among them with eighteen, and moving a door between facets from here on
// costs its own cut. The window was used in time — both immigrants went over
// inside it, at no chain cost. Measured at block 56 880 000.
//
// ⚠️ THE NEW DOORS ARE HERE AND NOT BESIDE THE SEAT, and the reason is one
// number. `addArbiter` stopped seating people on 8 November: it records an
// invitation, and the man answers with `acceptArbiterInvitation` /
// `acceptArbiterInvitationWithPermit`, which take his ten-dollar entry bond and
// seat him in one transaction. An invitation needs a LIFE, the owner's
// instruction was that no new number about the world be introduced for it, and
// the number that already has an owner is `APPLICATION_TTL` — declared in this
// file. A door in the registry would have had to mirror it or reach for it
// through a mounted selector; the door here reads the declaration. The SEATING
// travels the other way instead, as `ArbiterRegistryStorage.seatOnInvitation`,
// because the roster, the graves and the provenance belong to the registry.
//
// ⚠️ AND THE TWO RETIRED BOND DOORS STAY RETIRED, which looks like an oversight
// and is not. `postArbiterBond` / `postArbiterBondWithPermit` existed for a
// state this design does not have: a man already SEATED who still owes money,
// or whose standing bond a won appeal had drawn down. The seat and the money
// now move in one call and nothing sags, so there is nothing for those doors to
// do. They go on answering `SeatBondRetired` by name, and they come off the
// diamond when the screens pressing them do.
//
// ⚠️ THE DOOR THIS FACET WAS BUILT FOR IS GONE, and the reason is the reason
// it existed. It was written because `ArbiterRegistryFacet.applyAsArbiter`
// refused `DAONotActive` on its first line: before governance nobody could put
// himself forward by any means, so an interim human door was the only way into
// the corps for anyone the owner did not already know. On 22 September 2026 the
// self-service door was opened — the gate came off, and what stands there now
// is a run of five clean deals — and the interim door lost its premise in the
// same stroke.
//
// The argument for removing it: the application asked the same thing the
// self-service door asks, and what it ADDED was one person's right to say no to
// somebody the rules already admit. So three doors became one, and these three
// selectors come off the diamond:
//
//     applyForArbiterSeat()                    0x6fb78a56
//     approveArbiterApplication(address)       0xbcd90be1
//     rejectArbiterApplication(address,string) 0x8e7e21be
//
// ⚠️ THIS IS A REMOVAL FROM THE DIAMOND AND NOT A REPLACEMENT, so the cut
// that carries it uses `Remove` with a zero facet address for these three and
// must not put them in the same group as anything it replaces — `Replace`
// reverts on a selector that is not mounted and `Add` on one that is, and a
// mistake in either drops the WHOLE cut in one transaction.
//
// ⚠️ NOTHING IS STRANDED BY THE REMOVAL, and that is measured rather than
// assumed: `getApplicantCount()` on the deployed diamond
// (0x760F0736..., Base Sepolia) reads 0 on 22 September 2026. Nobody has ever
// applied, so there is no pending application that loses its decider and no
// refused applicant left waiting out a window.
//
// WHAT STAYS HERE, AND WHY EACH ONE:
//
//   * `withdrawArbiterApplication` — the applicant's own door out. Kept
//     although nothing can be Pending any more: it is not this task's to
//     remove, and removing a man's ability to clear his own record is a
//     decision somebody has to take out loud.
//   * `revokeUnprovenSeat` — the owner (or, for his own seats, the chief)
//     takes back a hand-granted seat before anything was earned in it. Still
//     real: `addArbiter` asks for nothing, so a seating by hand still needs an
//     undo that is not an accusation.
//   * `postArbiterBond` / `postArbiterBondWithPermit` — both answer
//     `SeatBondRetired`. They revert instead of being unmounted so that a
//     screen still pressing them gets a name it can read out; they come off the
//     diamond when those screens do.
//   * the views — `getArbiterApplication`, `getApplicationWindow`,
//     `getApplicationRequirements`, `isManualAdmissionOpen`, `getApplicants`,
//     `getApplicantCount`, `getApplicantsPage`, `isArbiterActive`,
//     `getBondState`. `getBondState` in particular is called by every live
//     Agreement clone and a clone is pinned to its implementation for life.
//
// WHY A SEPARATE FACET AT ALL, still true: `ArbiterRegistryFacet` stands under
// a thousand bytes clear of the EIP-170 ceiling, and this content has nowhere
// else to go.
//
// Storage: the same `ArbiterRegistryStorage`, the same POSITION. Facets of a
// diamond share storage by namespace, so nothing is migrated and nothing is
// copied. The application record stays in the layout untouched — a struct in a
// namespace is append-only, and deleting the doors that wrote it does not make
// its fields free to reuse.
// ============================================================

import {ArbiterRegistryStorage, ArbiterRegistryFacet} from "./ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "./ArbiterAccountabilityFacet.sol";
import {ReputationStorage} from "./ReputationFacet.sol";
import {OwnershipLib} from "../DiamondProxy.sol";
import {FactoryStorage} from "../FactoryFacet.sol";
import {MarketPresence} from "./MarketPresence.sol"; // "an arbiter is not a party"

/// The three calls this facet makes on the bond token. `IUSDCFull` in the
/// registry declares only the two transfers; the two reads below are what turn
/// a raw token revert into a named refusal the ARBITER POSTING HIS BOND can act
/// on. It used to be the approver who met them, until seating and paying were
/// pulled apart on 13 September 2026 and the only doors left that move a bond
/// in are the two the arbiter presses himself.
interface IBondToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    /// The outbound half, needed since 11 September 2026 by `revokeUnprovenSeat`.
    /// The bond comes BACK on that door — it is a filter, not a punishment — and
    /// the money leaves the diamond's own balance, so it is `transfer` and not
    /// `transferFrom`. Same shape `ArbiterRegistryFacet.resignAsArbiter` uses.
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// EIP-2612 on the bond token — the one call `postArbiterBondWithPermit` makes
/// that no other door of this facet makes.
///
/// Declared as an interface of its own rather than added to `IBondToken` above,
/// in exactly the shape both boards already declare theirs (`IJobBoardUSDC`,
/// `IServiceBoardUSDC`): the other doors here have no business with `permit`,
/// and widening the interface all of them are called through would suggest they
/// do. Base USDC implements this; a bond token that did not would simply make
/// the signature door unusable while leaving the allowance door untouched.
interface IBondPermitToken {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

contract ArbiterApplicationsFacet {

    // -------- CONSTANTS --------

    /// How long an application stands, AND how long a refused applicant waits
    /// before putting himself forward again. Decided on 24 August 2026, and
    /// one number rather than two on purpose: as long as an application lives,
    /// that is how long you wait after a refusal.
    ///
    /// The life of the application answers the owner's own rule that a silent
    /// queue is worse than a refusal — nobody has to REMEMBER an applicant for
    /// him to learn his fate; if nobody presses anything, the application dies
    /// on its own and says so.
    ///
    /// The wait after a refusal is the same number because a refusal here
    /// arrives WITH ITS REASON: the applicant knows what to fix. A fixable
    /// reason (no allowance, not enough USDC) held for a month would be
    /// pointless cruelty; a serious one is refused again, which is one press.
    uint256 private constant APPLICATION_TTL = 7 days;

    /// Mirrors of the two thresholds `applyAsArbiter` applies. They live in
    /// `ArbiterRegistryFacet` as `private constant`, so there is nothing to
    /// call; the alternative to a mirror is not "one owner", it is "no rule at
    /// all on this door".
    ///
    /// ⚠️ Each mirror is held against the REGISTRY'S OWN ANSWER, not against
    /// this file, and not against the other mirror — the expected side of every
    /// one of those checks comes from outside this contract:
    ///
    ///   * MIN_XP_MIRROR            vs `getMinXPToRegister()`, a live getter;
    ///   * MIN_CLEAN_STREAK_MIRROR  vs the `need` field the registry itself
    ///                              puts into `InsufficientCleanStreak` when
    ///                              `applyAsArbiter` refuses;
    ///   * ARBITER_BOND_MIRROR      ⚠️ GONE (8 November 2026), AND IT IS NOT
    ///                              REPLACED BY A NEW MIRROR. It held 50 USDC
    ///                              and was checked against the USDC a
    ///                              successful `applyAsArbiter` actually moved;
    ///                              from 22 September it was checked against
    ///                              nothing and was kept "as the amount the
    ///                              four original seats paid". The owner put a
    ///                              real price back on the entrance that day,
    ///                              and a dead fifty declared beside a live ten
    ///                              is not a record — it is a second number
    ///                              about one thing, which is the exact defect
    ///                              this whole comment is about. The live one
    ///                              is `ArbiterRegistryStorage.ENTRY_BOND`,
    ///                              declared ONCE in the library both facets
    ///                              import and read from there by the two
    ///                              accept doors below and by
    ///                              `getApplicationRequirements` — the same
    ///                              arrangement `SUSPENSION_WINDOW` has, and
    ///                              for the same reason: four doors in two
    ///                              files charge it.
    ///
    /// See test/ArbiterApplications.t.sol, the "mirrors" section. A mirror that
    /// only agreed with a number typed in this same file would be a lock
    /// looking at itself.
    ///
    /// ⚠️ THE XP MIRROR IS ZERO SINCE 20 SEPTEMBER 2026, and it is zero for the
    /// same reason the registry's own constant is: the corps stopped asking for
    /// experience at the entrance. It is kept rather than deleted so that
    /// `getApplicationRequirements` keeps its four-field shape — a form reading
    /// three numbers where it used to read four is a broken form — and so that
    /// the cross-check against `getMinXPToRegister()` keeps standing. Nothing
    /// compares against it any more; since 22 September 2026 nothing in this
    /// facet compares against the streak mirror either — both doors that did
    /// have been removed — and the pair survives as what a form reads.
    uint256 private constant MIN_XP_MIRROR           = 0;
    uint256 private constant MIN_CLEAN_STREAK_MIRROR = 5;

    // ⚠️ `APPEAL_DECIDING_VOTES_MIRROR` STOOD HERE AND IS GONE
    // (22 September 2026). It capped the chief's bloc on the approval door, and
    // there is no approval door; the registry's own copy went with it, because
    // the chief lost `addArbiter` in the same change. A cap on a bloc that
    // cannot be built is a cap on nothing.

    // -------- STATES --------

    /// ⚠️ `Expired` IS NEVER STORED. Expiry is a fact about the clock, not a
    /// transition somebody performs: storing it would need a transaction that
    /// nobody has a reason to send, and until that transaction arrived the
    /// record would read as live. It is computed on every read instead, by
    /// `_effectiveState`, and that is the only shape in which a reader ever
    /// sees it.
    ///
    /// The stored values are `None`/`Pending`/`Approved`/`Rejected`/
    /// `Withdrawn`, and the field in storage is a `uint8`, not this enum: the
    /// enum is declared here, the layout lives in `ArbiterRegistryStorage`, and
    /// tying a storage layout to a type declared in another file means a rename
    /// here moves storage there. Same reason `RemovalProposal.cause` is a
    /// `uint8`.
    enum ApplicationState {
        None,       // 0 — never applied
        Pending,    // 1 — standing, and inside its window
        Approved,   // 2 — seated by a person, bond posted
        Rejected,   // 3 — refused with a reason, in words
        Withdrawn,  // 4 — taken back by the applicant himself
        Expired     // 5 — computed only, never written
    }

    // -------- ERRORS --------

    /// The DAO is live, so this whole mechanism is shut for good — the ratchet
    /// does not turn back. The entrance from here on is
    /// `ArbiterRegistryFacet.applyAsArbiter()`, which needs no human decision:
    /// the same XP and streak, the same bond, posted by the applicant himself.
    error ManualAdmissionClosed();

    error NotOwnerOrChief();

    /// The owner and nobody else — not the chief, not a seated arbiter.
    ///
    /// ⚠️ ARRIVED WITH A DOOR RATHER THAN WITH A NEW RULE (8 November 2026).
    /// `revokeArbiterInvitation` moved here from `ArbiterRegistryFacet`, where
    /// it stood under that facet's `onlyOwner` modifier, and this is the same
    /// refusal under the same name and the same four bytes. It is the FOURTH
    /// declaration of `NotOwner()` in src/ (FactoryFacet, RegistryFacet,
    /// TreasuryLinkFacet, ArbiterAccountabilityFacet and ArbiterRegistryFacet
    /// already carry it) and both relay tables already decode it into words, so
    /// the man who presses sees a sentence rather than four bytes — which is
    /// the one thing the revert census asks of a new declaration.
    ///
    /// ⚠️ IT IS NOT `NotOwnerOrChief` ABOVE, and the difference is the whole of
    /// why a second name was worth declaring. Every other administrative door
    /// in this file lets the chief through until governance is live; taking
    /// back an offer the OWNER made is the owner's, exactly as it was next
    /// door. Widening it to the chief would be a new decision, not a move.
    error NotOwner();

    // ⚠️ `ApplicantZeroAddress` STOOD HERE AND IS GONE (22 September 2026),
    // with the two doors that raised it. Deleted rather than kept as a type,
    // unlike the registry's `DAONotActive`: that one HAD been raised on the
    // live chain and its refusals have to stay decodable, whereas this one
    // never was — `getApplicantCount()` on the deployed diamond reads 0
    // (measured 22 September 2026), so nobody ever applied and nobody was ever
    // refused through these doors.

    /// There is nothing standing against this address that could be decided.
    /// Carries the state that IS there — including `Expired` — because
    /// "nobody ever applied", "he took it back an hour ago" and "it ran out
    /// yesterday" are three different things to say to whoever pressed the
    /// button, and a bare "no" says none of them.
    error NoPendingApplication(uint8 state);

    // ⚠️ `ApplicationAlreadyPending` AND `RejectedTooRecently` STOOD HERE
    // AND ARE GONE (22 September 2026). Both are about a state nothing can
    // reach any more: with no door to file an application, nothing becomes
    // Pending and nothing is Rejected. Same argument as `ApplicantZeroAddress`
    // above — neither was ever raised on the live chain.

    // ── The bond, and why its failures are named ──────────────────────────
    //
    // The bond is taken BY THE ARBITER HIMSELF, in a transaction of his own,
    // and by neither of the doors that seat him. Owner's decision of
    // 13 September 2026: seating is decoupled from paying.
    //
    // It was not always so, and the history is the argument. From 24 August
    // 2026 the bond was taken AT APPROVAL — the approver's press both seated
    // the applicant and pulled his 50 USDC. That put a stranger's allowance in
    // the way of the approver's own decision: no allowance, no seat, and the
    // refusal took the whole transaction with it. Worse, it made the state the
    // rest of this facet is built on — seated, still owing — unreachable for
    // everyone admitted this way.
    //
    // So the refusals below are now met by the man they are about, on
    // `postArbiterBond` and `postArbiterBondWithPermit`, and they are still
    // NAMED rather than silent for the same reason as before: "you have not
    // approved the diamond" and "you have spent your USDC" are two different
    // sentences to show a person, and neither of them is "your transaction
    // failed".

    // ── THESE SIX NAMES SERVE THE ENTRY BOND FROM 8 NOVEMBER 2026 ──────────
    //
    // They were written for the SEAT bond and outlived it by six weeks with
    // nothing raising them. The owner's decision of 8 November put a price back
    // on the ENTRANCE, and the four doors that charge it raise exactly these
    // six through `ArbiterRegistryStorage.takeEntryBond`,
    // `presentEntryBondPermit` and `returnEntryBond` — two of those doors from
    // the neighbouring facet, which imports this one for the names.
    //
    // ⚠️ REUSED RATHER THAN PARALLELED, and the reason is a gate. The entry
    // bond first declared six new names of its own (`EntryBondNotApproved` and
    // the rest) and they were deleted before the commit: the pre-commit revert
    // census (`shared/revertCensus.mjs`) demands that every error under src/ be
    // decoded into words by BOTH relay tables or argued for in
    // `shared/unreachable-reverts.json`. These six ARE in both tables already,
    // and they already say the right sentences. Six parallel names would have
    // reached a real person — on `applyAsArbiter` and `resignAsArbiter`, which
    // the browser has an ABI for — as four raw bytes.
    //
    // So every sentence below is still exactly true; what changed is WHICH bond
    // it is about, and that it is about one again instead of none.

    /// The applicant never approved the diamond, or approved less, or spent
    /// the allowance elsewhere in the meantime.
    error BondNotApproved(uint256 allowance, uint256 required);
    /// The allowance is there, the money is not.
    error BondBalanceTooLow(uint256 balance, uint256 required);
    /// The token answered `false` instead of reverting. Real USDC reverts, but
    /// a token that returns false is the older ERC-20 shape and the diamond's
    /// bond token is set by an owner transaction, not by this facet.
    ///
    /// ⚠️ What is NOT named, said out loud: a token that REVERTS inside
    /// `transferFrom` after both pre-checks passed — USDC's own blacklist is
    /// the live example — comes back as the token's own revert, not as one of
    /// the errors above. That revert carries USDC's reason string, which is
    /// readable, and catching it would mean swallowing genuine failures of the
    /// call as well. The two causes an approver can actually do something
    /// about are the two named above.
    error BondTransferFailed();
    /// The diamond has no bond token configured at all — a fresh diamond where
    /// `initFactory` has not run. Separate from the three above because
    /// nothing about the applicant is wrong.
    error BondTokenNotSet();
    /// The seat already carries a bond, so `postArbiterBond` has nothing to do.
    ///
    /// This is what stops the money being taken twice: the two bond doors are
    /// interchangeable and an arbiter may reach for either, so whichever he
    /// presses second runs into this. `arbiterBond` is ONE number per address,
    /// not a ledger of deposits — a second transfer would be unrefundable,
    /// since `resignAsArbiter` returns that one number.
    ///
    /// ⚠️ Since 13 September 2026 NO SEATING DOOR CAN RAISE THIS, and that is
    /// the change rather than an oversight: `addArbiter` writes no bond, and
    /// since 22 September it is the only door that seats by hand at all.
    ///
    /// ⚠️ AND NOTHING RAISES IT AT ALL FROM 8 NOVEMBER 2026, including the four
    /// doors that charge the entry bond — which is worth saying because it looks
    /// like the obvious guard for them and would be the wrong one. "Posted
    /// twice" is unreachable by construction now: the money and the seat move in
    /// ONE call, so the second attempt is refused by `AlreadyArbiter` before any
    /// bond is looked at, and that is the name the man should read. Kept as a
    /// type, because a refusal already in the chain's history stays decodable.
    error BondAlreadyPosted();

    /// The seat bond is retired (22 September 2026, the owner's decision): the
    /// money an arbiter puts at risk is posted per CASE, inside `claimDispute`.
    ///
    /// ⚠️ STILL THE RIGHT ANSWER AFTER 8 NOVEMBER 2026, when an ENTRANCE price
    /// came back. What these two doors served was a man who was already seated
    /// and still owed money — and that state no longer exists in either
    /// direction: the entry bond is taken in the same call that seats him
    /// (`acceptArbiterInvitation`, `applyAsArbiter` and their permit twins), and
    /// nothing draws it down afterwards, so there is never a seat to top up.
    /// A door that answered "paid" here would be creating that state again.
    ///
    /// ⚠️ THE TWO DOORS REVERT INSTEAD OF BEING UNMOUNTED, by the same
    /// device `setRewardPerDispute` already uses in ArbiterVaultFacet. A
    /// removed selector answers a pressed button with a bare failure and no
    /// name; this answers with one a screen can read out. They come off the
    /// diamond when the screens that press them do.
    error SeatBondRetired();

    /// The signed paper is older than its own deadline.
    ///
    /// ⚠️ ASKED HERE EVEN THOUGH USDC ASKS IT TOO, and that is the whole point
    /// of the error existing. Left to the token, an expired paper comes back as
    /// USDC's own revert string — "FiatTokenV2: permit is expired" — which is a
    /// sentence about a contract the person has never heard of, arriving from a
    /// call he did not know was being made. The two numbers travel with the
    /// refusal so a form can say "your signature ran out at 14:02, sign
    /// another" without going back to the chain to find out when that was.
    ///
    /// The comparison is the token's own (`deadline < now` is expired, so a
    /// paper valid to the exact second is still valid here): a door that
    /// refused what USDC would have accepted would be inventing a second,
    /// stricter clock.
    error BondPermitExpired(uint256 deadline, uint256 nowTs);

    // ── The filter door, and why every refusal names ONE fact ─────────────
    //
    // Decided on 11 September 2026, and this is the whole of it. The 48-hour
    // pause is a reset of something already confirmed, and an application does
    // not need one. What matters is what has already been EARNED, not the
    // selection window. The bond comes back and nothing is stolen: plainly a
    // filter.
    //
    // So a seat nothing has been earned in is taken back at once, and a seat
    // with a record behind it keeps the whole procedure — proposal, 48-hour
    // pause, the accused's right of reply, fourteen days.
    //
    // ⚠️ THE REFUSALS ARE ONE PER FACT, deliberately. The form has to be able
    // to print the sentence "he has taken three disputes" rather than "not
    // allowed", and the number that refused must travel WITH the refusal or
    // whoever reads it goes and asks the chain again — one day about a
    // different block.

    /// Nobody granted this seat, so nobody takes it back by hand. `seatedBy` is
    /// written by the ONE granting door left (`addArbiter`, the owner's since
    /// 22 September 2026) and erased by `ArbiterRegistryStorage.clearSeat` on
    /// every exit, so it answers about the seat he holds RIGHT NOW and not about
    /// one he held once. That is the whole reason the origin test is this field
    /// and not the application record, whose `Approved` never expires.
    ///
    /// ⚠️ WHICH CASES ACTUALLY REACH THIS, measured rather than assumed:
    ///   * a SEAT OLDER THAN THE PROVENANCE FIELDS — the reachable one. Arbiters
    ///     seated before `seatedBy` existed carry a zero, which is why
    ///     `ArbiterProvenanceInit` exists at all;
    ///   * a SELF-REGISTRATION through `applyAsArbiter` — unreachable through
    ///     this door, and not because of this line: that function refuses until
    ///     governance is live, and once it is live `_requireManualAdmissionOpen`
    ///     shuts this door first. The guard stands anyway. A door defended by
    ///     the ORDER of two other conditions is a door defended by nothing the
    ///     day one of them moves.
    error SeatNotGranted();

    /// The chief may take back only what HE granted. Carries the grantor, so a
    /// form says whose seat it is instead of "not allowed".
    ///
    /// ⚠️ This line is what stops the fast door handing the chief a power he
    /// does not have today: `removeArbiterForCause` is the owner's (or, after
    /// the handover, the DAO's) and the chief only PROPOSES. Without it the
    /// chief could clear out every unproven seat the owner sat, in one press
    /// each, and the procedure would be decoration on that half of the corps.
    error NotSeatGrantor(address grantor);

    // ── "Has he earned anything" — one error per counter ──────────────────

    /// He has claimed a dispute. `arbiterDeals` is append-only and is never
    /// cleared anywhere in src/, so this is "ever", not "right now".
    error ArbiterHasTakenDisputes(uint256 taken);
    /// He is holding one at this moment. Implied by the line above today, asked
    /// anyway — see `_requireNothingOnTheRecord`.
    error ArbiterHoldsOpenClaim(uint256 open);
    error ArbiterHasVerdicts(uint256 clean, uint256 overturned);
    error ArbiterCarriesMistakes(uint256 streak);
    /// Nothing earned in the seat at all -- the strictest reading of "unproven".
    error ArbiterHasEarned(uint256 amount);
    /// He has seats of his own standing under him — he is, or was, the chief.
    error ArbiterHasSeatedOthers(uint256 seats);
    /// He holds the chief's role. The role and the seat are two fields, and a
    /// chief who is not an arbiter is a state no door should be able to make.
    /// Clear the role first (`setChiefArbiter`), then this door opens.
    error ArbiterIsChief();

    // ── The procedure must not be cancellable through this door ───────────

    /// An accusation stands against him and its clock is running. Letting him
    /// out here would RETURN the bond that a removal for cause forfeits, and
    /// would erase the proposal on the way out (`clearSeat` deletes it) — that
    /// is, this door would become the way to rescue an accused arbiter from the
    /// forfeit, pressed by the very person who accused him.
    error RemovalProposalStands();
    /// He is suspended. The window is what holds the money on verdicts he took
    /// before it, and a fast exit would buy past it — the same hole
    /// `clearRemovalRecord(..., false)` was written against.
    error ArbiterSuspendedNow(uint256 until);

    /// The refund did not land. HARD, exactly as in
    /// `ArbiterRegistryFacet.resignAsArbiter`, and the argument is that the
    /// alternative is worse: a soft refund would take the seat and leave the
    /// money behind, which is the defect the appeal deposit already carries.
    ///
    /// ⚠️ What this costs, said out loud: an arbiter the token refuses to pay
    /// (USDC's blacklist is the live example) cannot be let go through this
    /// door at all. He is not stranded — `removeArbiterForCause` forfeits the
    /// bond into the vault and moves no money outward, so the procedure still
    /// reaches him. A filter that cannot run is better than a filter that
    /// silently keeps the money.
    error BondRefundFailed();

    /// Words are the accuser's duty here exactly as they are on a removal: the
    /// chain cannot check why somebody was turned down, so whoever turns him
    /// down says it in words, and those words are public.
    error ReasonRequired();
    /// Length in BYTES, not characters — the cap is shared with the removal
    /// doors and read from the facet that owns it, so there is no second
    /// number to drift.
    error ReasonTooLong(uint256 given);

    // -------- EVENTS --------

    // ⚠️ THREE EVENTS STOOD HERE AND ARE GONE (22 September 2026):
    // `ArbiterApplicationSubmitted`, `ArbiterApplicationApproved` and
    // `ArbiterApplicationRejected`. The doors that emitted them — the
    // application, its approval and its refusal — were removed by the owner's
    // decision of the same day: the application asked exactly what the
    // self-service door asks and added only a person's right to say no to
    // somebody the rules already admit.
    //
    // DELETED RATHER THAN LEFT STANDING, by the rule
    // script/check-subgraph-arbiter-events.sh holds and by the precedent
    // `ArbiterBondPosted` set in this same file: a declaration with no emit is
    // a promise in the ABI that the chain will never keep, and for an indexed
    // one it is worse — the handler, the manifest and the ABI copy all still
    // line up while the feed waits for a log that cannot arrive.
    //
    // `ArbiterApplicationWithdrawn` below stays, because its door does.

    event ArbiterApplicationWithdrawn(address indexed applicant);
    // ⚠️ `ArbiterBondPosted` STOOD HERE AND IS GONE (22 September 2026). It
    // announced a seated arbiter putting his own money behind a seat he was
    // given, and nothing puts money behind a seat any more: both doors that
    // emitted it answer `SeatBondRetired`.
    //
    // DELETED RATHER THAN LEFT STANDING, and the rule is
    // script/check-subgraph-arbiter-events.sh: a declaration with no emit is a
    // promise in the ABI that the chain will never keep, and for an indexed one
    // it is worse — the handler, the manifest and the ABI copy all still line
    // up while the feed goes silent for good.
    //
    // The moment it announced has an heir, and it is a different moment:
    // `ArbiterRegistryFacet.CaseBondPosted`, fired when an arbiter takes a CASE.

    /// A granted seat taken back before anything was earned in it.
    ///
    /// ⚠️ ITS OWN EVENT, and it must never be `ArbiterRemovedForCause`. That
    /// one means an accusation was laid, sat 48 hours, was answered or not, and
    /// ended in a forfeited bond. This one means the opposite on every count:
    /// no accusation, no pause, no forfeit — `bondReturned` is money going back
    /// OUT of the diamond, where `bondForfeited` is money staying in. A feed
    /// that folded the two together would print a man's name under "removed for
    /// cause" for the crime of being turned down.
    ///
    /// `reason` rides in the log rather than in a second event: nothing indexes
    /// this yet, so the shape can be right from the start — the same freedom
    /// `ArbiterApplicationRejected` had and the removal doors did not.
    event ArbiterSeatRevoked(
        address indexed arbiter,
        address indexed by,
        uint256         bondReturned,
        string          reason
    );

    // -------- ERC-2771 SENDER --------

    /// The third copy of this body in src/ (registry, accountability, here).
    /// Facets do not inherit from one another and this project has no common
    /// base contract, so a copy is the only shape available.
    ///
    /// ⚠️ It is proved the way the other two are — INDEPENDENTLY, against the
    /// address of the signer rather than against a neighbouring facet. The one
    /// gasless door this facet has left (`withdrawArbiterApplication`) is driven
    /// through a real `MinimalForwarder` in test/ArbiterApplications.t.sol, so
    /// corrupting this body to `sender = msg.sender` turns that scene red. No
    /// byte-for-byte comparison with the other copies exists, here or
    /// anywhere: a difference that changes behaviour goes red on its own, and
    /// one that does not, does no harm.
    function _msgSender() internal view returns (address sender) {
        address forwarder = FactoryStorage.store().trustedForwarder;
        if (msg.sender == forwarder && msg.data.length >= 20) {
            assembly { sender := shr(96, calldataload(sub(calldatasize(), 20))) }
        } else {
            sender = msg.sender;
        }
    }

    // -------- INTERNALS --------

    /// Owner or, until governance is live, the chief arbiter. The same shape
    /// the two neighbours use, and deliberately the same wording of the DAO
    /// half: the chief's role is abolished by DAO activation, and it is
    /// abolished HERE, in the role check, not in `activateDAO()` — because
    /// `setChiefArbiter` is the only writer of that slot and it closes at the
    /// same moment, so a chief who is sitting when the DAO arrives would
    /// otherwise sit there for ever.
    ///
    /// Raw `msg.sender`, on purpose and by the same argument as the
    /// neighbouring facet: trusting the tail of calldata inside an ownership
    /// check hands that ownership to the forwarder. Recorded per function as
    /// a documented exception to the build gate that rejects a raw
    /// `msg.sender` in gasless contracts.
    function _requireOwnerOrChief(ArbiterRegistryStorage.Data storage d) private view {
        if (msg.sender != OwnershipLib.contractOwner()) {
            if (_daoIsActive() || msg.sender != d.chiefArbiter) revert NotOwnerOrChief();
        }
    }

    /// Asked of the facet that owns the answer, through the diamond, rather
    /// than recomputed from a mirrored threshold.
    ///
    /// `address(this)` inside a facet is the diamond, so this is one external
    /// call into this same proxy that lands on `ArbiterRegistryFacet`. The
    /// neighbouring facet mirrors `DAO_THRESHOLD` instead and pays for it with
    /// a test that holds the two numbers together; there is no reason to buy
    /// that here — `isDaoActive()` is a mounted public function, and the whole
    /// point of the ratchet is that one predicate governs every door.
    function _daoIsActive() private view returns (bool) {
        return ArbiterRegistryFacet(address(this)).isDaoActive();
    }

    /// The ratchet. Closed means closed for ever: `activateDAO()` is one-way
    /// and the flag it sets is cleared nowhere in src/.
    ///
    /// ⚠️ THE EARNED HALF IS GONE (26 August 2026). This used to
    /// read "and the earned half (uniqueActiveUsers >= DAO_THRESHOLD) only ever
    /// grows", which was the other reason the ratchet could not spring back.
    /// The threshold now switches nothing on by itself; it is a CONDITION
    /// `activateDAO()` checks. The ratchet is unchanged and stands on the flag
    /// alone.
    ///
    /// ⚠️ The predicate is bare `isDaoActive()`, NOT the two-part
    /// `isDaoActive() && daoAddress != address(0)` that guards `addArbiter`.
    /// The extra half exists over there as a belt against a door with NO
    /// opener — and since decisions 50 and 51 the state it guards against
    /// ("governance live, successor still zero") is unreachable through the
    /// real doors at all, because `activateDAO()` demands a CONFIRMED
    /// successor. Its docstring carries the whole argument. Either way it never
    /// reached this door: were that window ever to open again,
    /// `applyAsArbiter` is what stands open in it — the entrance this
    /// mechanism was always going to hand over to.
    function _requireManualAdmissionOpen() private view {
        if (_daoIsActive()) revert ManualAdmissionClosed();
    }

    // ⚠️ `_requireEligible` STOOD HERE AND IS GONE (22 September 2026). It
    // held the streak against `MIN_CLEAN_STREAK_MIRROR` on both of the doors
    // this facet no longer has. The mirror itself stays, because
    // `getApplicationRequirements()` publishes it and a test holds it against
    // the registry's own refusal — a form still needs to be told what the
    // corps asks for before a man signs anything.

    /// Expiry folded in. Every read of an application goes through here.
    ///
    /// ⚠️ The raw `state` field used to be read directly in one more place —
    /// the "has this address ever applied" test inside `applyForArbiterSeat`,
    /// which asked about the LIST rather than about the application. That door
    /// is gone, so this is the only shape in which a state is ever seen.
    function _effectiveState(ArbiterRegistryStorage.ArbiterApplication storage a)
        private
        view
        returns (uint8)
    {
        if (a.state != uint8(ApplicationState.Pending)) return a.state;
        if (block.timestamp >= uint256(a.submittedAt) + APPLICATION_TTL) {
            return uint8(ApplicationState.Expired);
        }
        return uint8(ApplicationState.Pending);
    }

    /// The words cap, asked of the facet that declares it rather than copied.
    /// `MAX_REASON_BYTES` is one rule about how much a person may write on an
    /// arbiter's record, and it already has an owner and a public getter; a
    /// second literal here is the defect the removal doors already paid for
    /// once, when accusation and defence had two independent copies of it.
    function _requireReason(string calldata reason) private view {
        uint256 len = bytes(reason).length;
        uint256 cap = ArbiterAccountabilityFacet(address(this)).getMaxReasonBytes();
        if (len > cap) revert ReasonTooLong(len);
        if (len == 0) revert ReasonRequired();
    }

    // ── THE INVITATION'S TWO REFUSALS, 8 November 2026 ──────────────────────
    //
    // ⚠️ ALSO DECLARED IN `ArbiterRegistryFacet`, and the duplication is what
    // the revert ledger asks for rather than an oversight. A `no-screen-door`
    // entry in `shared/unreachable-reverts.json` must NAME the doors that can
    // raise a refusal, and each named door must live in a file that DECLARES
    // the error. The selector is the signature, so both declarations are the
    // same four bytes; for a `()` error there is nothing that can drift, and
    // for the other the argument list is held identical by the ledger itself,
    // which compares `declaredIn` against src/ exactly.
    //
    // ⚠️ AND SINCE LATE ON 8 NOVEMBER 2026 EVERY DOOR THAT RAISES EITHER OF
    // THEM IS IN THIS FILE. `revokeArbiterInvitation` was the owner's door next
    // door and moved here with `applyAsArbiterWithPermit`, so the registry's
    // copies now have no raiser at all — the position `SeatInvitationExpired`
    // was already in on the day it was written. They stay declared over there
    // on purpose, because the other half of the invitation story
    // (`addArbiter`, `ArbiterInvited`, `ArbiterInvitationRevoked`) is still
    // that facet's, and a refusal decodable from one facet's ABI and not the
    // other's is four raw bytes to half the readers. The argument is written
    // out beside those declarations.

    /// Nobody asked him in — `seatInvitations[him].inviter` is the zero
    /// address. It is also what a man who has already ANSWERED meets if he
    /// presses twice, because the record is deleted on the answer; that second
    /// press is caught one line earlier by `AlreadyArbiter`, which is the
    /// refusal he should actually read.
    error NoSeatInvitation();

    /// The offer ran out. Carries the moment it expired AND the moment now, so
    /// a form can say "it ran out on Tuesday" rather than "not allowed", and so
    /// nobody has to go back to the chain to find out when — one day, about a
    /// different block.
    ///
    /// ⚠️ THE WINDOW IS THE ONE THAT ALREADY HAS AN OWNER: `APPLICATION_TTL`,
    /// seven days, declared in this file and published by
    /// `getApplicationWindow()` and `getApplicationRequirements()`. No new
    /// number about the world was introduced for the invitation, deliberately —
    /// every number about the world needs somebody who answers for it, and this
    /// one has had an owner since 24 August 2026. That is also the reason the
    /// two accept doors are in THIS facet and not beside the seat.
    error SeatInvitationExpired(uint256 expiredAt, uint256 nowTs);

    // ── THE BOUNDARY BETWEEN "FRESH" AND "WORKING", AND WHERE IT IS DRAWN ──
    //
    // The criterion was settled before the mechanism: what matters is what has
    // already been EARNED, not the selection window. Three candidates
    // were weighed and two were dropped, for reasons that belong here rather
    // than in a document nobody opens next to the code:
    //
    //   * A TIMER ("N hours after seating") was dropped because it answers the
    //     boundary question WRONG. The question that settles it: an arbiter
    //     who takes a dispute a minute after being seated — is he working? Under
    //     a timer he stays fast-removable for the rest of the window, and
    //     pressing the door then strands a live dispute with a party waiting on
    //     it. Under the rule below the door shuts IN THE SAME TRANSACTION as
    //     the claim, because `claimDispute` pushes into `arbiterDeals` and
    //     increments `openClaimCount` on its way through. There is no window in
    //     which a working arbiter is cheap to remove.
    //
    //   * ORIGIN ALONE ("he came through the application window") was dropped
    //     because the application record does not answer the question asked of
    //     it. `state` stays `Approved` for ever: a man who was approved,
    //     resigned, and was later seated BY HAND still reads as "came through
    //     the window". Origin survives here only as a PRECONDITION, and it is
    //     read from `seatedBy` — which `clearSeat` erases on every exit and so
    //     describes the seat he holds now.
    //
    //   * WHAT IS EARNED is what the rule stands on, and it is measured field
    //     by field below.
    //
    // ⚠️ THE ONE FORM OF SERVICE THE CHAIN CANNOT COUNT PER PERSON, said out
    // loud rather than left to be discovered: an APPEAL VOTE.
    // `ArbiterRegistryFacet.voteToOverturn` records only
    // `hasVotedAppeal[deal][arbiter]` — a flag per pair, with no counter per
    // arbiter and no way to total it on chain. An arbiter whose entire record
    // is appeal votes therefore reads as unproven here and can be filtered out
    // by this door. Counting them needs a new counter incremented inside
    // `voteToOverturn`, and that function lives in `ArbiterRegistryFacet`, which
    // stood 44 bytes clear of the EIP-170 ceiling when this was written
    // (measured 11 September 2026, `forge build --sizes`). It does not fit.
    // What it costs if it is ever pressed: he loses a seat he was given and
    // keeps every coin — the bond goes back in full. It is a widening of the
    // filter, not a loss of anybody's money.

    /// Nothing on the record, field by field, each refusal carrying its number.
    ///
    /// ⚠️ EVERY FIELD IS ASKED, although four of them cannot be non-zero today
    /// unless the first one is. `cleanVerdicts`, `overturnedVerdicts`,
    /// `arbiterMistakeStreak` and `arbiterRewards` all descend from a claimed
    /// dispute in the code as it stands, so `arbiterDeals` alone would pass
    /// every test in this repository today. That implication is INVISIBLE
    /// COUPLING: nothing holds it, nothing goes red when a future door credits
    /// a reward or a verdict by some other path, and the failure it would
    /// produce is the exact one this door must never produce — a working
    /// arbiter reading as unproven. Six SLOADs on an administrative press is
    /// not a price worth arguing about.
    function _requireNothingOnTheRecord(ArbiterRegistryStorage.Data storage d, address who)
        private
        view
    {
        if (who == d.chiefArbiter) revert ArbiterIsChief();

        uint256 seats = d.seatedCountBy[who];
        if (seats != 0) revert ArbiterHasSeatedOthers(seats);

        uint256 taken = d.arbiterDeals[who].length;
        if (taken != 0) revert ArbiterHasTakenDisputes(taken);

        uint256 open = d.openClaimCount[who];
        if (open != 0) revert ArbiterHoldsOpenClaim(open);

        uint256 clean      = d.cleanVerdicts[who];
        uint256 overturned = d.overturnedVerdicts[who];
        if (clean != 0 || overturned != 0) revert ArbiterHasVerdicts(clean, overturned);

        uint256 streak = d.arbiterMistakeStreak[who];
        if (streak != 0) revert ArbiterCarriesMistakes(streak);

        uint256 earned = d.arbiterRewards[who];
        if (earned != 0) revert ArbiterHasEarned(earned);
    }

    /// The procedure, once it is running, owns the man — and this door must not
    /// be able to end it.
    ///
    /// Both predicates are ASKED OF THE FACET THAT OWNS THEM rather than
    /// recomputed here. `hasLiveProposal` folds in the per-proposal `ttl` and
    /// its fallback for records written before that field existed; `isSuspended`
    /// owns the comparison against the clock. A second copy of either would be
    /// a second rule that agrees today and drifts on the first edit — and the
    /// half that drifted would be the half that lets somebody out.
    function _requireProcedureNotRunning(address who) private view {
        ArbiterAccountabilityFacet a = ArbiterAccountabilityFacet(address(this));
        if (a.hasLiveProposal(who)) revert RemovalProposalStands();
        if (a.isSuspended(who)) revert ArbiterSuspendedNow(a.getSuspendedUntil(who));
    }

    // -------- APPLICANT: WITHDRAW --------

    /// Take it back. Free, and it leaves nothing behind that would stop the
    /// same person applying again in the next block: a withdrawal is not a
    /// refusal, so the APPLICATION_TTL wait does not apply to it.
    ///
    /// ⚠️ Deliberately NOT gated on the ratchet. Once the DAO is live nothing
    /// standing can be approved any more, and forcing a person to leave his own
    /// dead record in the public list to prove a point would be spite, not a
    /// rule.
    function withdrawArbiterApplication() external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        address caller = _msgSender();

        ArbiterRegistryStorage.ArbiterApplication storage a = d.arbiterApplications[caller];
        uint8 st = _effectiveState(a);
        if (st != uint8(ApplicationState.Pending)) revert NoPendingApplication(st);

        a.state     = uint8(ApplicationState.Withdrawn);
        a.decidedAt = uint64(block.timestamp);
        // Nobody decided this but the applicant himself, and writing his own
        // address into "who decided" would read in the feed as a decision made
        // ABOUT him.
        a.decidedBy = address(0);

        emit ArbiterApplicationWithdrawn(caller);
    }

    // -------- THE INVITED MAN ANSWERS --------

    /// Is there a live offer standing against this man, and may he take it?
    ///
    /// ⚠️ THE ORDER OF THE THREE REFUSALS IS PART OF THE ANSWER. The seat
    /// first, so a man who has already answered is told THAT and not that his
    /// invitation is missing (it is missing — it was deleted by his own
    /// answer); then whether anybody asked him; then the clock. The name of a
    /// refusal is the whole of what he is told, and a name that creates the
    /// wrong expectation is a defect of its own — the same lesson
    /// `applyAsArbiter` learned on 12 October 2026.
    ///
    /// ⚠️ NO COOLDOWN IS ASKED HERE, AND THAT IS A DECISION WITH A TEST
    /// HOLDING IT. `requireCooldownPassed` guards every entrance a man opens
    /// for HIMSELF; the owner's hand has always been exempt, because he
    /// reverses his own removal with one press and a half-year binding him
    /// would turn a mistaken removal into a sentence nobody can lift. When one
    /// door became two, that exemption had to be given to one of the halves on
    /// purpose: put the cooldown in THIS one and an invited man removed last
    /// month hits six months of silence, with every scene in the tree still
    /// green, because nothing in the tree had ever invited a removed arbiter.
    /// The exemption therefore lives with the INVITATION — the owner's
    /// judgement — and this door asks nothing about removals at all. Held by
    /// name:
    /// test/ArbiterEntryBond.t.sol::test_AnInvitedManInsideHisRemovalCooldownStillTakesTheSeat.
    ///
    /// ⚠️ NOR IS SUSPENSION ASKED. The seating routine LIFTS it
    /// (`liftSuspension = true`, the owner's decision on this seam of
    /// 16 August 2026), so refusing a suspended man here would make the
    /// invitation unanswerable by exactly the men the owner most often means to
    /// ask back.
    ///
    /// ⚠️ THE HANDOVER SHUTS THIS DOOR, and the predicate is the TWO-PART one
    /// that guards `addArbiter` (`ArbiterRegistryFacet._requireSeatingNotHandedOver`)
    /// and NOT the bare `_requireManualAdmissionOpen` the rest of this facet
    /// uses. An unanswered invitation is not a seat: once seating has been
    /// handed over, nobody seats by hand at all, and honouring a press the
    /// owner made the day before would let him hand the DAO a bloc it did not
    /// choose. The weaker half of the predicate matters here for the same
    /// reason it matters there — until a successor is actually named, the owner
    /// must still be able to fill the corps.
    ///
    /// ⚠️ IT IS A SECOND COPY OF THAT PREDICATE, said out loud rather than
    /// hidden, because the original is `private` in the neighbouring facet and
    /// a facet cannot call another facet's private body. What stops it drifting
    /// is a scene that drives BOTH doors under a live handover —
    /// test/ArbiterEntryBond.t.sol::test_TheHandoverShutsTheInvitationAndItsAnswerTogether.
    function _requireLiveInvitation(ArbiterRegistryStorage.Data storage d, address who)
        private
        view
    {
        if (d.isArbiter[who]) revert ArbiterRegistryFacet.AlreadyArbiter();

        ArbiterRegistryStorage.SeatInvitation storage inv = d.seatInvitations[who];
        if (inv.inviter == address(0)) revert NoSeatInvitation();

        if (_daoIsActive() && d.daoAddress != address(0)) {
            revert ArbiterRegistryFacet.SeatingHandedOver();
        }

        // The window is this file's own `APPLICATION_TTL`, read from the
        // declaration and not mirrored: that is the whole reason the two accept
        // doors live in this facet rather than beside the seat.
        uint256 expiresAt = uint256(inv.invitedAt) + APPLICATION_TTL;
        if (block.timestamp >= expiresAt) {
            revert SeatInvitationExpired(expiresAt, block.timestamp);
        }
    }

    /// @notice Answer the owner's invitation: put down the entry bond and sit.
    ///
    /// The second half of the owner's decision of 8 November 2026. `addArbiter`
    /// no longer seats anybody; it records an offer, and this is the call that
    /// turns an offer into a seat. ONE transaction takes the money and gives
    /// the seat, which is the property the whole design is arranged around —
    /// there is no way to end up with a payment and no seat, and no way to end
    /// up seated without having paid.
    ///
    /// ⚠️ THE ORDER OF THE MONEY AND THE SEAT IS THE UNINTUITIVE ONE, on
    /// purpose, and the argument is written out once at
    /// `ArbiterRegistryFacet.applyAsArbiter`: the seat is written first and the
    /// token is touched LAST, because `transferFrom` hands control to a token
    /// the owner configures, and a re-entrant one that found the invitation
    /// still standing could pay twice for one seat. Here it finds the record
    /// deleted and the man seated, so the inner call refuses and takes the
    /// whole transaction down.
    ///
    /// ⚠️ THE SAME TEN DOLLARS AS THE SELF-SERVICE DOOR, read from
    /// `ArbiterRegistryStorage.ENTRY_BOND`. The owner's rule is that the two
    /// entrances ask exactly the same thing, and the only way to keep that true
    /// is for there to be one declaration — not two agreeing numbers.
    ///
    /// Gasless by the sender and not by the allowance: `_msgSender()` means the
    /// call relays through the `MinimalForwarder`, but an `approve` is a
    /// transaction sent to USDC, which has never heard of our forwarder. The
    /// twin below carries the allowance in as a signature, and that is the door
    /// a man with no ETH actually uses.
    function acceptArbiterInvitation() external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        _requireLiveInvitation(d, caller);

        // `arbiterBond` is assigned HERE, by name, and not inside a shared
        // writer — see the warning at `ArbiterRegistryStorage.takeEntryBond`
        // and the pinned writer set in
        // `script/check_arbiter_bond_writers.py`.
        d.arbiterBond[caller] = ArbiterRegistryStorage.ENTRY_BOND;
        ArbiterRegistryStorage.seatOnInvitation(d, caller);
        ArbiterRegistryStorage.takeEntryBond(caller, ArbiterRegistryStorage.ENTRY_BOND);

        emit ArbiterRegistryFacet.ArbiterEntryBondPosted(caller, ArbiterRegistryStorage.ENTRY_BOND);
    }

    /// @notice The same answer, with the allowance carried in on a signature.
    ///
    /// The door an invited man with no ETH uses, and the reason it has to exist
    /// is not a preference: `approve` is a transaction sent TO USDC, our
    /// forwarder is trusted by our own contracts and by nothing else, so that
    /// one step can never be relayed by us, for anybody, ever. The man the
    /// owner just invited has by definition earned nothing in the protocol, so
    /// the protocol is not where his ETH comes from either. The whole argument,
    /// and what the signature does and does not authorise, is at
    /// `ArbiterRegistryStorage.presentEntryBondPermit`.
    ///
    /// ⚠️ THE ARGUMENT SHAPE IS THE RETIRED DOOR'S — `(uint256 deadline,
    /// uint8 v, bytes32 r, bytes32 s)` — kept deliberately, so that a screen
    /// which once drove `postArbiterBondWithPermit` needs no new argument
    /// order. The AMOUNT is not an argument and never was: it is `ENTRY_BOND`,
    /// so a paper signed for any other number does not verify, and the SIGNER
    /// is `_msgSender()`, so a paper signed by anybody else is refused by the
    /// token. Neither refusal rests on a check written here, which is why
    /// neither can be edited away here.
    ///
    /// ⚠️ THE PAPER IS PRESENTED BEFORE THE DOOR DECIDES. A refusal costs him
    /// nothing — the transaction unwinds, the allowance with it, and USDC's
    /// nonce with it, so the same signature still works on the next attempt —
    /// while the reverse order would mean copying the rules above the call and
    /// re-reading them below it, and the copy that drifted would be the one
    /// saying yes.
    function acceptArbiterInvitationWithPermit(
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        ArbiterRegistryStorage.presentEntryBondPermit(
            caller, ArbiterRegistryStorage.ENTRY_BOND, deadline, v, r, s
        );

        _requireLiveInvitation(d, caller);

        d.arbiterBond[caller] = ArbiterRegistryStorage.ENTRY_BOND;
        ArbiterRegistryStorage.seatOnInvitation(d, caller);
        ArbiterRegistryStorage.takeEntryBond(caller, ArbiterRegistryStorage.ENTRY_BOND);

        emit ArbiterRegistryFacet.ArbiterEntryBondPosted(caller, ArbiterRegistryStorage.ENTRY_BOND);
    }

    // ── THE EARNED ENTRANCE'S SIGNATURE TWIN, MOVED HERE 8 November 2026 ────
    //
    // ⚠️ THESE TWO DOORS ARE IMMIGRANTS FROM `ArbiterRegistryFacet` AND THE
    // MOVE COST NOTHING ON CHAIN, which is the only reason it was done in this
    // hour rather than later. The cut that mounts them had not been signed:
    // the chain routed 277 selectors and no entry bond at all when this was
    // measured, so the pending cut simply named the other facet for the same
    // four bytes. After that cut it would have cost a SECOND cut and a second
    // transaction.
    //
    // ⚠️ AND IT HAS BEEN SIGNED SINCE 10 NOVEMBER 2026: one `diamondCut`,
    // block 56 872 217, receipt status 0x1, which Replaced this facet's
    // thirteen mounted selectors onto 0x10eE3C98…, Added these five, and
    // Replaced the registry's twenty-seven onto 0x22A0b090…. The chain routes
    // 282 over fifteen facets as of block 56 880 000 and eighteen of them are
    // here. The free window is closed; the next door that wants to change
    // facets pays for its own cut.
    //
    // WHY THEY HAD TO LEAVE. `ArbiterRegistryFacet` stood 3 716 bytes under
    // EIP-170 and the appeal split of 15 October had bought it 4 937: the entry
    // bond spent exactly the room that split was performed to buy, and
    // test/AppealFacetSplitCut.t.sol::test_BothFacetsFitUnderEip170 — whose
    // floor was set "high enough that losing the room this work bought would
    // red" — said so by name.
    //
    // WHY THIS FACET. The twin below is the same shape as
    // `acceptArbiterInvitationWithPermit` above, line for line, and already
    // calls the same two library routines; this file also holds the ERC-2771
    // sender it needs and the six bond refusals it raises.
    //
    // ⚠️ THE SELECTORS DID NOT MOVE — 0x205d501d and 0x2693a9d5 are derived
    // from the signatures and not from the facet. What changed is the address
    // that answers them.
    //
    // ⚠️ AND THE RULES DID NOT GET A SECOND COPY. The eligibility test and the
    // seating live in `ArbiterRegistryStorage` as `requireSelfEnrolmentEarned`
    // and `seatSelfEnrolled` — one body, called from `applyAsArbiter` next door
    // and from the twin below, exactly the device `seatOnInvitation` already
    // uses. A copy in this file would have been a second set of entrance rules
    // free to drift, with the half that drifted being the half that says yes.

    /// @notice The earned entrance, with the allowance carried in on a
    /// signature.
    ///
    /// Added 8 November 2026, because the entrance stopped being free and a
    /// free entrance was the only reason this door did not already exist. The
    /// whole argument — why `approve` can never be relayed by us, for anybody,
    /// ever, and why the man at this door is precisely the one without ETH — is
    /// at `ArbiterRegistryStorage.presentEntryBondPermit`.
    ///
    /// ⚠️ IT IS THE TWIN OF `ArbiterRegistryFacet.applyAsArbiter` AND NOT OF
    /// THE TWO ACCEPT DOORS ABOVE, and the difference is who decided. Those
    /// answer an offer the owner made; this one is the road in for a man NOBODY
    /// invited, and the whole of what it asks is
    /// `ArbiterRegistryStorage.requireSelfEnrolmentEarned` — five clean deals
    /// with five distinct standing clients, sixteen days of calendar, and no
    /// live removal cooldown.
    ///
    /// ⚠️ THE ARGUMENTS ARE THE PAPER AND NOTHING ELSE: a deadline and a
    /// signature. The amount is `ENTRY_BOND`, read from the library, so a paper
    /// signed for any other number does not verify; the payer is
    /// `_msgSender()`, so a paper signed by somebody else is refused by USDC.
    /// Neither refusal rests on a check written here, which is why neither can
    /// be edited away here. The shape is the one `postArbiterBondWithPermit`
    /// used — `(uint256 deadline, uint8 v, bytes32 r, bytes32 s)` — kept
    /// deliberately so that a screen that once drove that door needs no new
    /// argument order.
    ///
    /// ⚠️ THE PAPER IS PRESENTED BEFORE THE DOOR DECIDES, and a refusal costs
    /// the candidate nothing: the transaction unwinds, the allowance with it,
    /// and USDC's nonce with it, so the same signature still works on the next
    /// attempt. Presenting it after the checks would mean copying the rules
    /// above the call and re-reading them below it, and the copy that drifted
    /// would be the one saying yes.
    ///
    /// ⚠️ THE ORDER OF THE SEAT AND THE MONEY IS THE UNINTUITIVE ONE, on
    /// purpose, and the argument is written out once at
    /// `ArbiterRegistryFacet.applyAsArbiter`: the seat is written first and the
    /// token is touched LAST, because a re-entrant token that found the man
    /// unseated could buy two seats for one entrance.
    function applyAsArbiterWithPermit(uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        ArbiterRegistryStorage.presentEntryBondPermit(
            caller, ArbiterRegistryStorage.ENTRY_BOND, deadline, v, r, s
        );

        ArbiterRegistryStorage.requireSelfEnrolmentEarned(d, caller);

        // `arbiterBond` is assigned HERE, by name, and not inside a shared
        // writer — see the warning at `ArbiterRegistryStorage.takeEntryBond`
        // and the pinned writer set in
        // `script/check_arbiter_bond_writers.py`.
        d.arbiterBond[caller] = ArbiterRegistryStorage.ENTRY_BOND;
        ArbiterRegistryStorage.seatSelfEnrolled(d, caller);
        ArbiterRegistryStorage.takeEntryBond(caller, ArbiterRegistryStorage.ENTRY_BOND);

        emit ArbiterRegistryFacet.ArbiterEntryBondPosted(caller, ArbiterRegistryStorage.ENTRY_BOND);
    }

    /// @notice Take an unanswered invitation back. THE OWNER'S.
    ///
    /// ⚠️ THE DOOR IS KEPT BY THE OWNER'S WORD OF 8 NOVEMBER 2026, and
    /// this paragraph is the RECORD OF THAT DECISION rather than a flag on it.
    /// It began as an executor's addition — his own decision that day covered
    /// the invitation and the bond and said nothing about withdrawing an offer
    /// — so the price of both outcomes, keeping it and striking it out, was put
    /// to him, and he kept the door. The argument he accepted: without it a
    /// press cannot be undone AT ALL. An invitation stands for seven days, and
    /// an owner who mistypes an address, or changes his mind about a man, has
    /// no way to say so except to wait it out. What was given up for that is
    /// named in the same record and not left implied: one more door in the
    /// public surface that only the owner's key can press, and one more place
    /// to read for anybody taking the protocol apart from outside.
    ///
    /// ⚠️ IT IS THEREFORE NOT TO BE STRUCK OUT AS UNATTRIBUTED. The
    /// decision is kept as a written record rather than as anybody's memory on
    /// purpose, because this mechanism is not one the owner keeps in his head:
    /// a flag inviting him to strike the door out would come back round as a
    /// question nobody could answer the same way twice. Taking the door out
    /// again is his call and costs one `Remove` in a cut; nothing reads this
    /// selector but his own hand.
    ///
    /// The half of that decision which says the door may not touch a man
    /// ALREADY SEATED stopped resting on prose the same day. Held by name:
    /// test/ArbiterEntryBond.t.sol::test_TheWithdrawalDoorRefusesAManWhoIsAlreadySeated.
    ///
    /// ⚠️ IT IS NOT A REMOVAL DOOR AND MUST NEVER GROW INTO ONE. It refuses
    /// anybody who is already seated, by omission rather than by a check: an
    /// answered invitation has been DELETED, so a seated man has no record here
    /// and meets `NoSeatInvitation`. A seat already taken is given back through
    /// `revokeUnprovenSeat` below (nothing earned in it, bond returned) or
    /// through the removal procedure (an accusation, a 48-hour pause, a right
    /// of reply), and neither of those is this.
    ///
    /// ⚠️ THE OWNER TEST IS WRITTEN INTO THE BODY RATHER THAN WORN AS A
    /// MODIFIER, and that is the one thing the move changed. Next door it rode
    /// `ArbiterRegistryFacet.onlyOwner`; this file has no such modifier — every
    /// administrative door in it is owner-OR-CHIEF, and this one is not — so a
    /// modifier declared for a single user would be the shape the linter
    /// already complains about. Two raw `msg.sender` reads instead of one, both
    /// recorded in `script/gasless-sender.allow`.
    ///
    /// Raw `msg.sender` twice, and for the same reason both times: the first
    /// read IS the authorisation, and the second has to name the same address
    /// the first one proved. Take the second through `_msgSender()` and a
    /// forwarder could write anybody it liked into a permanent record while the
    /// decision was the owner's — the rule written out at
    /// `ArbiterRegistryFacet.addArbiter`.
    function revokeArbiterInvitation(address arbiter) external {
        if (msg.sender != OwnershipLib.contractOwner()) revert NotOwner();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (d.seatInvitations[arbiter].inviter == address(0)) revert NoSeatInvitation();

        delete d.seatInvitations[arbiter];
        emit ArbiterRegistryFacet.ArbiterInvitationRevoked(arbiter, msg.sender);
    }

    // -------- OWNER / CHIEF: TAKE BACK AN UNPROVEN SEAT --------

    /// @notice Take back a granted seat that nothing has been earned in. No
    /// pause, no accusation, and the bond goes back in full.
    ///
    /// THE HOLE THIS FILLS. A seating by hand is a name and a press. Until this
    /// door existed, changing one's mind afterwards meant `removeArbiterForCause`
    /// — a proposal, a 48-hour pause, a right of reply, a fourteen-day window, a
    /// numeric CAUSE and a forfeited bond. That is, to un-seat somebody who had
    /// done nothing at all, a person had to accuse him of something and take his
    /// money. Decided on 11 September 2026: the 48-hour pause is a reset of
    /// something already confirmed, and a seating nothing has been earned in does
    /// not need one. With no accusation left behind, nothing is stolen and nobody
    /// is cheated -- plainly a filter.
    ///
    /// ⚠️ WHAT IT IS FOR NARROWED ON 22 SEPTEMBER 2026 AND WIDENED BACK ON
    /// 8 NOVEMBER, AND BOTH HALVES ARE WORTH SAYING OUT LOUD. It was written
    /// when a seat was created by two doors and carried a 50 USDC bond; from
    /// 22 September there was one door, it was the owner's, and it carried no
    /// money, so the `bondReturned` branch below could only refund a seat bond
    /// posted before the per-case cut, of which there were none left — dead
    /// code kept for the record.
    ///
    /// It is live code again. Since 8 November 2026 a seat is taken by a man
    /// ANSWERING the owner's invitation and putting ten dollars down, so a seat
    /// the owner takes back before anything was earned in it holds real money,
    /// and this door is where it goes home. Nothing in the branch changed; what
    /// changed is that `arbiterBond` is non-zero for the seats it reaches. The
    /// direction is the one the whole design turns on: a filter returns the
    /// money, an accusation forfeits it.
    ///
    /// WHAT IT IS NOT. It is not a second removal door and it must never grow
    /// into one. The procedure is untouched: every arbiter with a record behind
    /// him — one claimed dispute is enough — is refused here and reachable only
    /// the long way round. The argument for the boundary, and the three
    /// candidates weighed for it, is written above `_requireNothingOnTheRecord`.
    ///
    /// ⚠️ THE FIVE GUARDS, and each one is load-bearing:
    ///
    ///   1. the ratchet. Hand admission retires when governance goes live, and
    ///      this retires with it — after the handover arbiters seat themselves
    ///      through `applyAsArbiter` and removal belongs to the DAO;
    ///   2. `seatedBy != 0`. A seat nobody granted is nobody's to take back;
    ///   3. the chief may take back only what he granted. Without this the fast
    ///      door would hand him a removal power `removeArbiterForCause` deliberately
    ///      withholds;
    ///   4. no live proposal and no suspension. The procedure, once running,
    ///      must not be cancellable through here — it would return a bond the
    ///      removal forfeits and erase the accusation on the way out;
    ///   5. nothing on the record. This is the rule itself.
    ///
    /// WHAT IT LEAVES BEHIND, on purpose:
    ///
    ///   * NO `removedAt`, no `removalCount`, no `lastRemovalCause`, no
    ///     suspension. He was not removed and his record must not say he was —
    ///     that record is read by `getArbiterStanding` and shown to people;
    ///   * the application record is NOT rewritten. He WAS approved; that is a
    ///     fact and stays one. The consequence, said out loud: he may file again
    ///     in the next block, and whoever pressed this may simply not answer —
    ///     an application costs him nothing and dies on its own in seven days;
    ///   * `arbiterBoxKey`/`arbiterSignKey` stay where they are, exactly as
    ///     after `resignAsArbiter`. They are public halves and describe a device,
    ///     not a seat.
    ///
    /// Raw `msg.sender` throughout, like both neighbouring administrative doors
    /// and for the same reason: this is a decision by a named person, and the
    /// name in the log has to be the name of whoever pressed — not an address
    /// out of the tail of somebody's calldata. Recorded in
    /// `script/gasless-sender.allow`.
    function revokeUnprovenSeat(address arbiter, string calldata reason) external {
        if (arbiter == address(0)) revert ArbiterAccountabilityFacet.ArbiterZeroAddress();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        // The ratchet first, then the role — the same order and the same
        // argument as the two doors above: once governance is live this whole
        // mechanism is gone, and telling a chief his ROLE is wrong when what is
        // gone is the DOOR sends him looking for a permission that no longer
        // exists.
        _requireManualAdmissionOpen();
        _requireOwnerOrChief(d);

        if (!d.isArbiter[arbiter]) revert ArbiterRegistryFacet.NotAnArbiter();

        address grantor = d.seatedBy[arbiter];
        if (grantor == address(0)) revert SeatNotGranted();
        if (msg.sender != OwnershipLib.contractOwner() && grantor != msg.sender) {
            revert NotSeatGrantor(grantor);
        }

        _requireProcedureNotRunning(arbiter);
        _requireNothingOnTheRecord(d, arbiter);
        _requireReason(reason);

        // ── Effects before the token call ────────────────────────────────
        // This door still refunds, so it still calls the token and still needs
        // the order. Everything describing the exit is written first, so a
        // token that calls back finds the seat already gone and this function
        // refusing `NotAnArbiter` — the bond cannot be paid out twice. If the
        // transfer then fails the whole transaction unwinds and none of it
        // happened.
        uint256 bond = d.arbiterBond[arbiter];
        d.arbiterBond[arbiter] = 0;
        d.isArbiter[arbiter]   = false;

        // The roster, emptied the way both other exit doors empty it: the slot
        // goes to zero and the array KEEPS ITS LENGTH.
        //
        // ⚠️ AND IT IS SHARED NOW, WHICH REVERSES WHAT THIS COMMENT SAID UNTIL
        // 16 OCTOBER 2026. It said the loop was copied rather than shared
        // because an edit to `ArbiterRegistryStorage` re-emits into
        // `ArbiterRegistryFacet`, the facet nearest the EIP-170 wall — true,
        // and right for a body that was one assignment. Decision 185 made the
        // exit do two things: zero the slot AND file its index on
        // `vacantSeats`, so the next arbiter in can sit here. A door that does
        // the first and forgets the second loses that index for ever and
        // nothing about the roster looks wrong afterwards, which is why all
        // three doors now call one `burySeat` instead of carrying one copy
        // each. The wall was measured rather than argued about.
        //
        // ⚠️ IT WAS SWAP-AND-POP UNTIL 14 OCTOBER 2026, in all three doors, and
        // the splice was a lever on the appeal lot: the lot's indices are
        // decided when an appeal is RAISED and the addresses are read at the
        // DRAW, so moving the last arbiter into a departing man's index moved a
        // man the seed never chose onto the panel. The argument, the
        // measurement and what it costs are written once, at
        // ArbiterRegistryFacet.resignAsArbiter.
        uint256 len = d.arbiterList.length;
        for (uint256 i = 0; i < len; i++) {
            if (d.arbiterList[i] == arbiter) {
                ArbiterRegistryStorage.burySeat(d, i);
                break;
            }
        }

        // Provenance, the grantor's counter, and any proposal record — the one
        // shared exit routine both other doors call.
        ArbiterRegistryStorage.clearSeat(d, arbiter);

        if (bond > 0) {
            address token = FactoryStorage.store().usdc;
            if (token == address(0)) revert BondTokenNotSet();
            if (!IBondToken(token).transfer(arbiter, bond)) revert BondRefundFailed();
        }

        emit ArbiterSeatRevoked(arbiter, msg.sender, bond, reason);
    }

    // -------- BOND --------

    /// Named refusals first, then the move.
    ///
    /// The two reads cost one staticcall each and buy the CALLER the difference
    /// between "you have not approved the diamond" and "you have spent your
    /// USDC" — two different messages to show a person, and neither of them is
    /// "your transaction failed".
    ///
    /// Both callers were bond doors the arbiter pressed himself
    /// (`postArbiterBond`, `postArbiterBondWithPermit`), so the man who read the
    /// refusal was the man who could fix it; both now answer `SeatBondRetired`.
    ///
    /// ⚠️ `amount` IS WHAT THE SEAT IS SHORT, not the whole bond (17 September
    /// 2026). A won appeal is now refunded partly out of the ruling arbiter's
    /// bond, so a seat can be short by any sum from one base unit to the whole
    /// norm, and the man topping it up is asked for exactly the gap — asking a
    /// sagging seat for the full 50 USDC again would lock money nobody decided
    /// to lock. For a seat that never paid, the gap IS the whole bond, so both
    /// refusals still name the number a first-time payer needs.
    // ⚠️ `_takeBond` STOOD HERE AND IS GONE (22 September 2026). It was the
    // careful mover for the SEAT bond, and nothing posts a seat bond any more.
    // The per-case bond is taken by `ArbiterRegistryFacet._takeCaseBond`, at
    // the moment the arbiter claims a dispute.
    /// rather than sloppy. `script/check-arbiter-bond-writers.sh` pins the exact
    /// set of functions that assign a non-zero `arbiterBond`, and it is the only
    /// thing standing between a new way of creating a bond and the public claim
    /// in docs/DECENTRALIZATION.md about how many there are. Funnel both doors
    /// through one private writer and that gate goes blind to door number three:
    /// the writer set would not move, the gate would stay green, and the
    /// document would rot in silence — the exact failure it was written to
    /// prevent. So each door performs its own three-line effect, under the
    /// ordering comment below, and the gate sees every one of them by name.
    ///
    /// What is shared is everything that could drift into a DIFFERENT answer:
    /// the refusals, their names, and `_takeBond`.
    ///
    /// ⚠️ "ALREADY POSTED" MEANS "WHOLE" (17 September 2026), the same norm
    /// `ArbiterRegistryFacet._requireBonded` and `isArbiterActive` apply. A seat
    /// that has paid for a won appeal out of its bond is not "posted" any more:
    /// every arbiter door refuses it, and this door is where it comes back.
    /// Returns what the seat is short, so both doors charge the same gap.
    ///
    /// ⚠️ AND WHAT IS OWED INCLUDES THE SEAT'S APPEAL DEBTS (second decision,
    /// same day). A won appeal the bond could not advance leaves an appellant
    /// owed; the top-up pays that FIRST and only then fills the bond. A seat
    /// cannot take new work without the top-up, so the debt is either paid or
    /// the arbiter stops working. `owed` is the gap to the norm plus those
    /// debts; zero of both is the only thing refused as "already posted".
    /// ⚠️ AND RULE A IS ASKED ON EXACTLY ONE OF THE TWO TRANSITIONS THIS DOOR
    /// SERVES (18 September 2026). The door is pressed in two different
    /// situations, and only the first is an ENTRANCE:
    ///
    ///   * a seat that never paid (`BOND_STATE_UNPOSTED`) becomes an arbiter
    ///     here, because the rule's definition of an arbiter is a seat AND a
    ///     posted bond. Until he presses this he trades like anybody else, so
    ///     this is the moment the boards have to be empty, and it is asked;
    ///   * a seat a won appeal drew below the norm (`BOND_STATE_SAGGING`) tops
    ///     itself back up. That seat is ALREADY an arbiter and already forbidden
    ///     to trade, so it can have opened nothing since — and asking would
    ///     only punish the man whose open items predate the rule, by locking
    ///     him out of the top-up his own appeal debt is paid with. Refusing a
    ///     restoration does not keep anybody out of the market; it keeps a
    ///     half-bonded judge in it.
    ///
    /// ⚠️ THE DISCRIMINATOR IS `bondDrawnByAppeal` ALONE, NOT "is the bond
    /// zero". That is deliberate and it closes a hole a bond-based test would
    /// leave open. There is a third way for a seat to hold money it never
    /// posted: `ArbiterVaultFacet._settleForfeitedShare` pays an arbiter's
    /// forfeited fee share back INTO his bond when a verdict finally executes,
    /// and it does so for whoever holds the seat at that moment. A man who
    /// resigned and was seated again in between gets a fresh, unpaid seat
    /// (`clearRemovalRecord` erases the flag) with a few dollars in its bond —
    /// so "bond == 0" would read that seat as sagging and wave the rule
    /// through, letting him top up to the norm while holding open deals. The
    /// flag cannot be reached that way: only `resolveAppeal` sets it, and every
    /// seating erases it. A seat that never paid therefore always asks the
    /// rule, whatever its balance.

    /// debts — what either bond door takes, and what `getBondState` shows.
    // ⚠️ `_owedOnTopUp` STOOD HERE AND IS GONE (22 September 2026). It answered
    // "what is this seat short of the 50 USDC norm, plus its unpaid appeal
    // debts" — a question with no seat bond behind it any more. Appeal debts
    // are still paid, by `settleAppealDebts` out of the bank and by the ruling
    // arbiter's forfeited fee share; what no longer pays them is a top-up
    // nobody posts.

    /// @notice RETIRED 22 SEPTEMBER 2026 with the seat bond itself, and on the
    /// chain since the cut of the 24th: this door answers `SeatBondRetired` and
    /// takes no money. It reverts instead of being unmounted so that a screen
    /// still pressing it gets a name it can read out; it comes off the diamond
    /// when those screens do. Everything below describes what it USED to do and
    /// is kept for the argument, not as a description of the protocol today.
    ///
    /// What it was: a seated arbiter put his own 50 USDC behind his seat — or,
    /// after a won appeal was refunded out of it, topped it back up by exactly
    /// what was missing.
    ///
    /// The door the owner's decision of 8 September 2026 needed and the protocol
    /// did not have. `ArbiterRegistryFacet.addArbiter` seats without money, and
    /// from that same cut every arbiter door refuses the seat with
    /// `ArbiterRegistryFacet.BondNotPosted` until this is called.
    ///
    /// ⚠️ WHY IT LIVES IN THIS FACET AND NOT THE REGISTRY, where the seat and
    /// the gate are. Two reasons, and the second is the hard one:
    ///   • `_takeBond` is already here, and it is the careful version — it
    ///     separates "you have not approved the diamond" from "you have spent
    ///     your USDC", two different sentences to show a person. Writing a
    ///     third bond mover in the registry would be the duplicate that drifts;
    ///   • the registry does not fit. Measured 8 September 2026: it stood 209
    ///     bytes clear of the EIP-170 ceiling before this work and 44 after the
    ///     gates alone. This function there would not deploy.
    ///
    /// ⚠️ NOT GATED BY `_requireManualAdmissionOpen`, unlike every other door
    /// in this facet, and that is deliberate. The rest of the facet retires
    /// when governance goes live; this must not. A man hand-seated before the
    /// handover and still unbonded after it would otherwise have no way left to
    /// pay — `addArbiter` is shut by then too — and would sit in a seat that
    /// every door refuses, permanently.
    ///
    /// ⚠️ NOT A WAY IN. It refuses anyone who does not already hold a
    /// seat, so it cannot seat its caller. Entry is `addArbiter` and
    /// `applyAsArbiter`, and since 22 September 2026 those are the only two.
    ///
    /// Gasless like the rest of the applicant's side: the sender comes from
    /// `_msgSender()`, so the bond can be posted through the forwarder. The
    /// relayer pays the gas; the USDC still leaves the ARBITER's own balance,
    /// which is the entire point of a bond.

    /// ⚠️ THIS DOOR STILL NEEDS AN ALLOWANCE GRANTED BEFOREHAND, and granting
    /// one is a transaction sent to USDC, which has never heard of our
    /// forwarder — so that half cannot be relayed and needs ETH the arbiter may
    /// not have. `postArbiterBondWithPermit` below is the same bond with the
    /// allowance carried in as a signature instead. This one is kept for
    /// everybody who has already approved the diamond, and for any bond token
    /// that does not implement EIP-2612.
    ///
    /// The refund needs nothing new. `resignAsArbiter` returns
    /// `arbiterBond[caller]` whatever wrote it, and `_performRemoval` forfeits
    /// the same field into the vault — so a bond posted here comes back on a
    /// voluntary exit and burns on a removal for cause, with no second code
    /// path for either.
    function postArbiterBond() external pure {
        revert SeatBondRetired();
    }

    /// @notice The same bond, carried in on a signature instead of an allowance.
    ///
    /// Owner's decision of 11 September 2026. The man on this door is applying
    /// to serve; he is the one being asked for something, and he should not be
    /// charged for the privilege of being asked.
    ///
    /// ⚠️ WHY THE OTHER DOOR IS NOT ENOUGH, AND WHY NO AMOUNT OF WORK ON OUR
    /// SIDE COULD HAVE MADE IT ENOUGH. `postArbiterBond` above needs an
    /// allowance, and an allowance is granted by a transaction sent TO USDC.
    /// Our forwarder is trusted by OUR contracts and by nothing else: USDC has
    /// never heard of it, so `approve` cannot be made gasless by us at all, for
    /// anybody, ever. It needs ETH. The man this door exists for is an arbiter
    /// who has not yet worked a single dispute — he has earned nothing in the
    /// protocol, so the protocol is not where the ETH comes from either. The
    /// screen as measured on 10 September 2026 told him to allow the diamond
    /// 50 USDC and gave him neither a button nor a reading of the allowance, so
    /// the refusal he walked into was not his doing.
    ///
    /// EIP-2612 moves that step off the chain: he SIGNS a paper granting this
    /// diamond exactly `ARBITER_BOND_MIRROR`, which costs nothing and needs no
    /// ETH, the relayer brings it here with the call, and the allowance and the
    /// transfer both happen inside this one transaction. The form is not
    /// invented here — it is the one both boards already take money in
    /// (`mintJobWithPermit`, `mintServiceWithPermit`, `requestServiceWithPermit`).
    ///
    /// ⚠️ THE SIGNER IS `_msgSender()` AND NOT AN ARGUMENT, which is the one
    /// place this deliberately departs from those three. They take the payer as
    /// a parameter, so anybody may present anybody's paper. Here the paper and
    /// the seat have to belong to the same man: the diamond learns who he is
    /// from ERC-2771, not from the caller's word, and USDC then checks the
    /// signature against THAT address. A paper signed by somebody else is
    /// refused by the token, and a paper signed by him cannot be spent by
    /// anybody else. Neither refusal rests on a check written here, which is
    /// why neither can be edited away here.
    ///
    /// ⚠️ THE AMOUNT IS OURS, NOT THE CALLER'S. What goes into the permit is
    /// the gap between this seat's bond and `ARBITER_BOND_MIRROR`, computed
    /// here from storage, so a paper signed for any other number simply does
    /// not verify. There is no argument by which a caller could ask this door to
    /// pull more than the gap.
    ///
    /// ⚠️ THE GAP IS NOT ALWAYS THE WHOLE BOND (17 September 2026). For a seat
    /// that never paid it is `getApplicationRequirements()`'s bond; for a seat
    /// that paid a won appeal out of its bond it is less, and a form reads it as
    /// the norm minus `getArbiterBond`. A paper signed for the old gap stops
    /// verifying if the gap moves before it is presented — for instance when
    /// the arbiter's forfeited fee share restores part of the bond — and the
    /// arbiter signs again; nothing is taken in the meantime.
    ///
    /// ⚠️ NOTHING IS LEFT STANDING AFTERWARDS. The paper grants exactly the
    /// gap and `_takeBond` spends exactly the gap, so the allowance is back at
    /// zero when this returns — the diamond is not left holding a standing
    /// claim on an arbiter's wallet.
    ///
    /// ⚠️ THE PAPER IS PRESENTED BEFORE THE DOOR DECIDES, deliberately. The
    /// permit runs first and the seat is judged after, so the rules live in
    /// exactly one place (`_requireSeatStillOwesItsBond`) instead of being
    /// copied above the call and re-checked below it. A refusal costs the
    /// applicant nothing: the whole transaction unwinds, the allowance with it,
    /// and — the part that matters — USDC's nonce with it too, so the same
    /// paper still works on the next attempt. The reverse order would be a
    /// second copy of the rules, and the copy that drifted would be the one
    /// saying yes. A reentrant bond token calling back in here finds
    /// `arbiterBond` still zero, posts, returns — and the outer call then meets
    /// its own `BondAlreadyPosted` and takes the whole transaction down with it,
    /// so the money still cannot be taken twice.
    ///
    /// ⚠️ RETIRED 22 SEPTEMBER 2026 with the seat bond itself. The arguments
    /// keep their types and lose their names: the selector must not move while
    /// a screen is still pressing it, and a named argument nothing reads is a
    /// promise the function no longer keeps.
    function postArbiterBondWithPermit(
        uint256,
        uint8,
        bytes32,
        bytes32
    ) external pure {
        revert SeatBondRetired();
    }

    // -------- VIEWS --------

    /// One read, everything about one application, expiry already folded in.
    ///
    /// `expiresAt` is returned even for decided applications, where it is the
    /// moment the application WOULD have run out; a form that shows it only
    /// while pending simply ignores it, and a form that shows a countdown does
    /// not have to know APPLICATION_TTL.
    function getArbiterApplication(address applicant)
        external
        view
        returns (
            uint8   state,
            uint256 submittedAt,
            uint256 expiresAt,
            uint256 decidedAt,
            address decidedBy
        )
    {
        ArbiterRegistryStorage.ArbiterApplication storage a =
            ArbiterRegistryStorage.data().arbiterApplications[applicant];

        state       = _effectiveState(a);
        submittedAt = a.submittedAt;
        expiresAt   = a.submittedAt == 0 ? 0 : uint256(a.submittedAt) + APPLICATION_TTL;
        decidedAt   = a.decidedAt;
        decidedBy   = a.decidedBy;
    }

    /// How long an application stands, and how long a refused applicant waits.
    /// One number, and the form is required to read it here rather than keep
    /// its own copy.
    ///
    /// ⚠️ IT IS ALSO HOW LONG AN INVITATION STANDS, from 8 November 2026, and
    /// that is a reuse rather than a coincidence. The invitation needed a
    /// window; a new number about the world needs somebody who answers for it,
    /// and this one has had an owner since 24 August 2026. So the accept doors
    /// read this declaration and no second figure was introduced. What it costs
    /// is said out loud: shorten this number and you shorten the life of every
    /// invitation in flight at the same moment, which is why the invitation
    /// stores its own `invitedAt` and the expiry is computed, never frozen.
    function getApplicationWindow() external pure returns (uint256) {
        return APPLICATION_TTL;
    }

    /// @notice One read, everything about one standing invitation.
    ///
    /// The read a form needs the moment `addArbiter` stopped seating people
    /// (8 November 2026): an invited man's screen has to be able to say "the
    /// owner asked you in, you have four days left, it will cost you ten
    /// dollars" without three round trips and without a copy of the window.
    ///
    /// `live` is the whole predicate the accept door applies to the RECORD —
    /// somebody asked, and the clock has not run out. It deliberately does NOT
    /// fold in the seat or the handover: a man who has already answered reads
    /// `inviter == 0` here (the record is deleted by his own answer) and
    /// `isRegisteredArbiter` true, which are two different sentences to show
    /// him; and whether seating has been handed over is a fact about the
    /// protocol rather than about him, answered by `isManualAdmissionOpen`.
    ///
    /// `expiresAt` is zero when nobody asked, rather than `APPLICATION_TTL`
    /// counted from the epoch — a form showing a countdown must not be handed a
    /// date in 1977.
    function getArbiterInvitation(address who)
        external
        view
        returns (address inviter, uint256 invitedAt, uint256 expiresAt, bool live)
    {
        ArbiterRegistryStorage.SeatInvitation storage inv =
            ArbiterRegistryStorage.data().seatInvitations[who];

        inviter   = inv.inviter;
        invitedAt = inv.invitedAt;
        expiresAt = inv.inviter == address(0) ? 0 : uint256(inv.invitedAt) + APPLICATION_TTL;
        live      = inv.inviter != address(0) && block.timestamp < expiresAt;
    }

    /// What the applicant needs before he signs anything. Four numbers in one
    /// read so a form can be honest about the requirements without three
    /// round-trips, and so the two mirrored constants have a public voice that
    /// a test can hold against the registry.
    function getApplicationRequirements()
        external
        pure
        returns (uint256 minXP, uint256 minCleanStreak, uint256 bond, uint256 window)
    {
        // ⚠️ `bond` STOPPED BEING A HARD ZERO ON 8 NOVEMBER 2026, and the
        // tuple keeps its shape. From 22 September it returned a literal `0`
        // because a seat cost nothing — true then, a lie from the moment the
        // owner put ten dollars back on the entrance. It is the DECLARATION
        // that is returned, not a figure typed here: one number, read by the
        // four doors that charge it and by this form, so a screen that prints
        // it cannot print a price different from the one the door takes.
        //
        // ⚠️ IT IS THE NORM AND NOT WHAT ANY ONE MAN OWES. What a particular
        // address has standing is `getBondState(addr)`, second return value.
        // The two were the same question while the only way to hold a bond was
        // to pay this exact amount, and they part company for the four seats on
        // Base Sepolia that hold zero under an older rule.
        return (
            MIN_XP_MIRROR,
            MIN_CLEAN_STREAK_MIRROR,
            ArbiterRegistryStorage.ENTRY_BOND,
            APPLICATION_TTL
        );
    }

    /// @notice May this address act as an arbiter right now — seat AND bond.
    ///
    /// The read a form needs and could not make before 8 September 2026. Asking
    /// `isRegisteredArbiter` alone now returns true for a man every arbiter
    /// door refuses: the form would show him the working screen and let him
    /// press buttons that all revert `BondNotPosted`. One read tells the three
    /// states apart — not an arbiter, an arbiter who owes a bond, an arbiter
    /// who may work.
    ///
    /// ⚠️ SUSPENSION IS DELIBERATELY NOT FOLDED IN. It is a separate state with
    /// its own expiry and its own read (`ArbiterAccountabilityFacet.isSuspended`),
    /// and merging them would leave a form unable to tell "you are not in the
    /// corps" from "wait 72 hours" — two different sentences to show a person.
    ///
    /// How much to post is `getApplicationRequirements()`, third return value:
    /// the same number this facet charges, so a form need keep no copy of it.
    function isArbiterActive(address addr) external view returns (bool) {
        // ⚠️ THE BOND HALF IS GONE (22 September 2026) AND DID NOT COME BACK
        // WITH THE MONEY (8 November 2026). It was a separate question while
        // "seated" and "paid" were two states a man could be in one at a time;
        // the entry bond is taken in the same call as the seat, so a seat
        // implies a paid bond by construction and asking twice would be asking
        // the same thing. What is left is the seat — the same thing
        // `isRegisteredArbiter` answers, and the duplication is kept on
        // purpose: a form built against this name goes on working, and the two
        // will part company again the day another condition is added to what
        // "may act" means.
        return ArbiterRegistryStorage.data().isArbiter[addr];
    }

    /// Not an arbiter at all.
    uint8 internal constant BOND_STATE_NONE      = 0;
    /// Holds a seat. Until 22 September 2026 this meant "and has never posted
    /// a bond for it, so: no arbiter work at all"; a seat needs no bond now,
    /// and this is simply what every seat reads as.
    uint8 internal constant BOND_STATE_UNPOSTED  = 1;
    /// Unreachable from 22 September 2026. Kept so that a refusal already in
    /// the chain's history stays readable, and because
    /// `Agreement.BOND_STATE_SAGGING` is a copy on clones that cannot be edited.
    uint8 internal constant BOND_STATE_SAGGING   = 2;
    /// Unreachable from 22 September 2026, kept for the same reason.
    uint8 internal constant BOND_STATE_WHOLE     = 3;

    /// @notice Where a seat's bond stands.
    ///
    /// ⚠️⚠️ THE `state` HALF MUST GO ON ANSWERING "NONE" OR "UNPOSTED" ONLY,
    /// AND THE REASON IS NOT IN THIS FILE. Since 8 November 2026 the second
    /// return value (`bond`) is non-zero again for every seat that paid its
    /// entry bond — and the temptation that comes with it is to make `state`
    /// report WHOLE (3) when the money is there, which would read as tidying up
    /// and would be the most expensive line in this facet.
    ///
    /// EVERY LIVE Agreement CLONE READS THIS SELECTOR, and it reads it to
    /// decide rule B: `Agreement._holdsArbiterBond` staticcalls
    /// `getBondState(who)`, decodes the tuple and refuses the man as a PARTY if
    /// `state >= BOND_STATE_SAGGING` (2). A clone is nailed to its
    /// implementation for life — no upgrade reaches it — so a `state` of 2 or 3
    /// would switch rule B back on across every deal that already exists and
    /// every deal those implementations ever create, silently, with no cut and
    /// no line of src/ to point at. Rule B in its wide form ("an arbiter may
    /// never be a party") is exactly what the owner removed on 22 September
    /// 2026, because it cost a man his living; what stands in its place is
    /// "he does not trade WHILE HE IS JUDGING" (`MarketPresence.requireNotJudging`).
    /// Held by name:
    /// test/ArbiterEntryBond.t.sol::test_ANonZeroEntryBondDoesNotTurnRuleBBackOnForTheClones.
    ///
    /// So: `bond` tells the truth about the money, `state` tells the truth about
    /// the RULE, and they are deliberately not the same question any more.
    ///
    /// The money a judge puts at risk per CASE is a third thing again, and it
    /// is not here either — it lives in
    /// `ArbiterRegistryStorage.Data.caseBonds`, keyed by the deal.
    ///
    /// ⚠️ IT IS KEPT MOUNTED, AND THAT IS DELIBERATE. Every live Agreement
    /// clone calls this selector to ask rule B ("is this person an arbiter
    /// holding a bond, and therefore barred from becoming a party?"), and a
    /// clone is pinned to its implementation for life. Unmounting it would be
    /// read by those clones as "this diamond does not carry rule B" — which is
    /// now the true answer, but a selector that vanishes and a selector that
    /// answers are different things to everything else reading the chain.
    /// Answering honestly means the clones stop refusing arbiters as parties,
    /// which is exactly what the owner decided on 22 September 2026.
    ///
    /// The two live states are unchanged in meaning: NONE for a man who holds
    /// no seat, UNPOSTED for a seat. WHOLE and SAGGING stay unreachable — see
    /// the double warning at the top of this docstring, which is the whole
    /// reason the entry bond did not change this line — and their constants
    /// are kept so that an old refusal in the chain's history stays readable,
    /// and because `Agreement.BOND_STATE_SAGGING` is a copy that cannot be
    /// edited on the clones that already exist.
    ///
    /// `toPost` stays zero, and from 8 November 2026 that is a fact rather than
    /// a leftover: there is no such thing as a seat that owes money. A man
    /// either paid at the door and sat down, or he did neither.
    function getBondState(address addr) external view returns (uint8 state, uint256 bond, uint256 toPost) {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        bond = d.arbiterBond[addr];
        state = d.isArbiter[addr] ? BOND_STATE_UNPOSTED : BOND_STATE_NONE;
    }

    /// Which door is open right now. False means this facet is finished and
    /// `ArbiterRegistryFacet.applyAsArbiter()` is the entrance.
    function isManualAdmissionOpen() external view returns (bool) {
        return !_daoIsActive();
    }

    /// Everyone who has ever applied, in the order they first did.
    ///
    /// Public on purpose (owner's decision of 24 August 2026): today there is
    /// no way to see that the door is being pushed at all. The price is that
    /// refusals are public as well, which is the same price already accepted
    /// for removal with cause.
    function getApplicants() external view returns (address[] memory) {
        return ArbiterRegistryStorage.data().arbiterApplicants;
    }

    function getApplicantCount() external view returns (uint256) {
        return ArbiterRegistryStorage.data().arbiterApplicants.length;
    }

    /// The paged read exists for the same reason the presentation digests have
    /// one: the array is append-only and never shrinks, so a caller that can
    /// only afford a window needs one that does not revert as the list grows.
    /// An `offset` past the end returns an empty array rather than reverting —
    /// a reader paging to the end is not making a mistake.
    function getApplicantsPage(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        address[] storage all = ArbiterRegistryStorage.data().arbiterApplicants;
        uint256 total = all.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = all[i];
        }
    }
}
