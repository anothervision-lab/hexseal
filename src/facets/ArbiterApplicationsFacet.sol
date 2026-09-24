// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ArbiterApplicationsFacet.sol
//
// What is left of the interim admissions mechanism after the owner's decision
// of 22 September 2026: the filter that takes back an unproven seat, the two
// retired bond doors, and the reads a form needs.
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
    ///   * ARBITER_BOND_MIRROR      used to be checked against the USDC a
    ///                              successful `applyAsArbiter` actually moved.
    ///                              ⚠️ DEAD SINCE THE SEAT BECAME FREE: that
    ///                              door moves nothing, `getApplicationRequire-
    ///                              ments` reports a bond of 0 rather than this
    ///                              number, and nothing compares against it. It
    ///                              is kept as the amount the four original
    ///                              seats paid, not as a price anybody is asked.
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
    uint256 private constant ARBITER_BOND_MIRROR     = 50_000_000; // 50 USDC, 6 decimals

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
    error BondAlreadyPosted();

    /// The seat bond is retired (22 September 2026, the owner's decision): a
    /// seat costs nothing to hold, and the money an arbiter puts at risk is
    /// posted per CASE, inside `claimDispute`.
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
    // `ArbiterRegistryFacet.voteOnAppeal` records only
    // `hasVotedAppeal[deal][arbiter]` — a flag per pair, with no counter per
    // arbiter and no way to total it on chain. An arbiter whose entire record
    // is appeal votes therefore reads as unproven here and can be filtered out
    // by this door. Counting them needs a new counter incremented inside
    // `voteOnAppeal`, and that function lives in `ArbiterRegistryFacet`, which
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
    /// ⚠️ WHAT IT IS FOR HAS NARROWED, AND IT IS WORTH SAYING OUT LOUD
    /// (22 September 2026). It was written when a seat was created by two doors
    /// and carried a 50 USDC bond; there is one door now, it is the owner's, and
    /// it carries no money — so the `bondReturned` branch below can only ever
    /// refund a seat bond posted before the per-case cut, of which there are
    /// none left. What remains is the owner taking back a seat he granted by
    /// hand before anything was earned in it, which is still a real thing to
    /// want and still the only alternative to accusing a man of something.
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

        // The roster, spliced the way both existing exit doors splice it. The
        // loop is copied rather than shared because sharing it means editing
        // `ArbiterRegistryStorage`, and every internal-library edit re-emits
        // into `ArbiterRegistryFacet`, which has 44 bytes of room.
        uint256 len = d.arbiterList.length;
        for (uint256 i = 0; i < len; i++) {
            if (d.arbiterList[i] == arbiter) {
                d.arbiterList[i] = d.arbiterList[len - 1];
                d.arbiterList.pop();
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
    function getApplicationWindow() external pure returns (uint256) {
        return APPLICATION_TTL;
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
        // ⚠️ `bond` IS ZERO FROM 22 SEPTEMBER 2026 and the tuple keeps its
        // shape: a seat costs nothing, and a form that reads this number now
        // reads the truth instead of a price nobody charges.
        return (MIN_XP_MIRROR, MIN_CLEAN_STREAK_MIRROR, 0, APPLICATION_TTL);
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
    /// and merging them would leave a form unable to tell "post 50 USDC" from
    /// "wait 72 hours" — two different sentences to show a person.
    ///
    /// How much to post is `getApplicationRequirements()`, third return value:
    /// the same number this facet charges, so a form need keep no copy of it.
    function isArbiterActive(address addr) external view returns (bool) {
        // ⚠️ THE BOND HALF IS GONE (22 September 2026): a seat is free to hold
        // and the money is posted per case. What is left is the seat, which is
        // what this read now answers — the same thing `isRegisteredArbiter`
        // answers, and the duplication is kept on purpose: a form built against
        // this name goes on working, and the two will part company again the
        // day another condition is added to what "may act" means.
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
    /// ⚠️ IT ANSWERS "NONE" OR "UNPOSTED" AND NOTHING ELSE FROM 22 SEPTEMBER
    /// 2026, because from that day nothing writes a seat bond. A seat costs
    /// nothing to hold; the money is posted per CASE, when the arbiter claims
    /// a dispute, and lives in `ArbiterRegistryStorage.Data.caseBonds`.
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
    /// no seat, UNPOSTED for a seat. WHOLE and SAGGING are unreachable and
    /// their constants are kept — an old refusal in the chain's history stays
    /// readable, and `Agreement.BOND_STATE_SAGGING` is a copy that cannot be
    /// edited on the clones that already exist.
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
