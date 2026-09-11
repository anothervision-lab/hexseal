// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ArbiterApplicationsFacet.sol
//
// Applications for a seat in the arbiter corps, decided by hand, and only
// until governance is live.
//
// WHY THE DOOR EXISTS AT ALL. `ArbiterRegistryFacet.applyAsArbiter` reverts
// `DAONotActive` on its first line, so before the DAO nobody can put himself
// forward by any means: the only entrance is `addArbiter`, pressed by the
// owner against somebody he already knows. The gate that guards the automatic
// door measures a RECORD — 3 000 XP is roughly thirty deals with thirty
// different people — and at the start of a marketplace there is no record to
// measure. Lowering the threshold until it becomes reachable would leave the
// bond as the only filter, and a bond is bought: weight from money instead of
// weight from work, which is the thing this protocol refuses.
//
// So the interim door is a human one, and it is interim BY EVENT, not by
// promise: it shuts on the same DAO activation that shuts `addArbiter`, after
// which the automatic `applyAsArbiter` is the entrance. The ratchet is the
// same one the rest of the corps rides — `isDaoActive()` is never switched
// back off anywhere in src/.
//
// WHY A SEPARATE FACET, AND WHY NOT THE NEIGHBOUR.
//
//   * `ArbiterRegistryFacet` is 23 369 bytes of the 24 576 EIP-170 allows.
//     1 207 bytes of margin is not room for a state machine, a bond transfer
//     and four events.
//   * `ArbiterAccountabilityFacet` has 15 745 bytes of margin and is still the
//     wrong home: that facet was cut out of the registry for lack of SPACE and
//     then named after its CONTENTS, so its name is already a half-truth.
//     Filing admissions under "accountability" would be a second layer of the
//     same lie, and the next reader would pay for it.
//
// The name says what is inside and nothing else: applications to join the
// corps, their approval, their refusal, their withdrawal.
//
// Storage: the same `ArbiterRegistryStorage`, the same POSITION. Facets of a
// diamond share storage by namespace, so nothing is migrated and nothing is
// copied — exactly the arrangement `ArbiterAccountabilityFacet` already uses.
// Two fields are APPENDED to `struct Data`; nothing above them is touched
// (a build gate over the struct's fields enforces this).
//
// ⚠️ TWO DOORS, NOT ONE, AND THE REASON IS WRITTEN DOWN.
//
// Folding both entrances into one selector would mean editing
// `applyAsArbiter` in the registry, which means REPLACING all 55 of the
// registry's mounted selectors in the same diamondCut that adds this facet —
// a `Replace`/`Add` pair is the operation that drops a whole cut on one
// transaction, and the registry is the largest facet in the diamond. It would
// also change which error `applyAsArbiter` throws, and `DAONotActive`
// (`0x6eb498a6`) is decoded by name today in both the backend relayer and
// the web client's relay route, neither of which is this piece of
// work. So the doors stay two, and the pointing is done from this side, where
// it costs nothing and breaks nothing:
//
//   * this facet's own refusal after the DAO is `ManualAdmissionClosed`, whose
//     docstring and whose name say where to go instead;
//   * `isManualAdmissionOpen()` answers "which door is open right now" in one
//     read, so neither a person nor a form has to guess;
//   * `getApplicationRequirements()` hands out the same four numbers the
//     automatic door checks, so an applicant is told what he needs BEFORE he
//     signs anything.
//
// The half that cannot be done from here — making `applyAsArbiter` name this
// door in its revert — stays undone on purpose: it belongs to a cut that
// replaces the registry facet for its own reasons, not to one smuggled in
// here. Until such a cut happens, `applyAsArbiter` refuses with
// `DAONotActive` and says nothing about this facet.
// ============================================================

import {ArbiterRegistryStorage, ArbiterRegistryFacet} from "./ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "./ArbiterAccountabilityFacet.sol";
import {ReputationStorage} from "./ReputationFacet.sol";
import {OwnershipLib} from "../DiamondProxy.sol";
import {FactoryStorage} from "../FactoryFacet.sol";

/// The three calls this facet makes on the bond token. `IUSDCFull` in the
/// registry declares only the two transfers; the two reads below are what turn
/// a raw token revert into a named refusal the approver can act on.
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
    /// before putting himself forward again. Owner's decision of 24 August
    /// 2026, and one number rather than two on purpose: "as long as an
    /// application lives, that is how long you wait after a refusal".
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
    ///   * ARBITER_BOND_MIRROR      vs the USDC actually moved by a successful
    ///                              `applyAsArbiter`.
    ///
    /// See test/ArbiterApplications.t.sol, the "mirrors" section. A mirror that
    /// only agreed with a number typed in this same file would be a lock
    /// looking at itself.
    uint256 private constant MIN_XP_MIRROR           = 3_000;
    uint256 private constant MIN_CLEAN_STREAK_MIRROR = 10;
    uint256 private constant ARBITER_BOND_MIRROR     = 50_000_000; // 50 USDC, 6 decimals

    /// Mirror of `ArbiterRegistryFacet.APPEAL_DECIDING_VOTES` — the number of
    /// votes that DECIDES an appeal at quorum, which is what `addArbiter` caps
    /// the chief's bloc below. Also private over there, also checked against
    /// the registry's own refusal (`ChiefBlocWouldDecideAppeal` carries it).
    uint256 private constant APPEAL_DECIDING_VOTES_MIRROR = 2;

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
    error ApplicantZeroAddress();

    /// There is nothing standing against this address that could be decided.
    /// Carries the state that IS there — including `Expired` — because
    /// "nobody ever applied", "he took it back an hour ago" and "it ran out
    /// yesterday" are three different things to say to whoever pressed the
    /// button, and a bare "no" says none of them.
    error NoPendingApplication(uint8 state);

    /// One application at a time. Carries the moment the standing one was
    /// filed, so the form can say "you applied on the 12th, it runs until the
    /// 19th" instead of refusing without a date.
    error ApplicationAlreadyPending(uint256 submittedAt);

    /// Refused applicants wait APPLICATION_TTL. Carries THE MOMENT the door
    /// opens again rather than the delay, so nobody has to add anything up.
    error RejectedTooRecently(uint256 mayReapplyAt);

    // ── The bond, and why its failures are named ──────────────────────────
    //
    // The bond is taken AT APPROVAL, not at submission (owner's decision of
    // 24 August 2026): the decision is made by a person, by hand, and if he
    // never gets to it then somebody else's money would have sat locked in
    // this contract for an unknown length of time.
    //
    // The consequence is that by the time the button is pressed the allowance
    // may be gone and the money may be gone. That is a NAMED refusal, not a
    // silent failure: the approver has to be able to see that the thing that
    // went wrong is not his, and tell the applicant which of the two to fix.

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
    /// This is what stops the money being taken twice: an arbiter admitted
    /// through `approveArbiterApplication` already paid at approval, and this
    /// refusal is what the second charge runs into. `arbiterBond` is ONE number
    /// per address, not a ledger of deposits — a second transfer would be
    /// unrefundable, since `resignAsArbiter` returns that one number.
    error BondAlreadyPosted();

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
    // Owner's decision of 11 September 2026, and the whole of it: "48 hours is
    // a reset of something already confirmed, and an application does not need
    // that. What matters is what has already been EARNED, not the selection
    // window. The bond comes back. Nothing is stolen. Plainly a filter."
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
    /// written by both granting doors (`addArbiter`,
    /// `approveArbiterApplication`) and erased by
    /// `ArbiterRegistryStorage.clearSeat` on every exit, so it answers about the
    /// seat he holds RIGHT NOW and not about one he held once. That is the whole
    /// reason the origin test is this field and not the application record,
    /// whose `Approved` never expires.
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

    /// `expiresAt` travels in the log rather than being left to the reader to
    /// compute: a feed that has to know APPLICATION_TTL to render a card is a
    /// feed carrying a second copy of that constant.
    event ArbiterApplicationSubmitted(
        address indexed applicant,
        uint256         submittedAt,
        uint256         expiresAt
    );

    /// `bondPosted` is in the log for the same reason `bondForfeited` is in
    /// `ArbiterRemovedForCause`: the money moved in this transaction, and a
    /// reader who has to go and ask the token separately will one day ask it
    /// about a different block.
    event ArbiterApplicationApproved(
        address indexed applicant,
        address indexed by,
        uint256         bondPosted
    );

    /// The refusal and its reason in ONE event, unlike the removal doors,
    /// which had to split theirs (`RemovalReasonGiven`) because their original
    /// signatures were already being indexed by a live subgraph. Nothing
    /// indexes these yet, so the shape can be right from the start.
    ///
    /// `mayReapplyAt` for the same reason `expiresAt` rides on the submission:
    /// the reader is told the date instead of the arithmetic.
    event ArbiterApplicationRejected(
        address indexed applicant,
        address indexed by,
        string          reason,
        uint256         mayReapplyAt
    );

    event ArbiterApplicationWithdrawn(address indexed applicant);
    /// A seated arbiter putting his own money behind a seat he was given.
    ///
    /// Its own event rather than a second seating event: since 8 September 2026
    /// the seat and the bond are two moments and may be days apart. A feed that
    /// showed only the seating would show a man as a working arbiter through
    /// the whole stretch in which every arbiter door refuses him.
    event ArbiterBondPosted(address indexed arbiter, uint256 amount);

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
    /// address of the signer rather than against a neighbouring facet. The two
    /// gasless doors of this facet (`applyForArbiterSeat`,
    /// `withdrawArbiterApplication`) are driven through a real
    /// `MinimalForwarder` in test/ArbiterApplications.t.sol, so corrupting
    /// this body to `sender = msg.sender` turns those scenes red. No
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

    /// The XP and the streak, checked the way `applyAsArbiter` checks them, and
    /// refusing with the REGISTRY'S OWN errors so a caller decodes one selector
    /// per condition no matter which door refused him.
    ///
    /// ⚠️ Called from BOTH doors — submission and approval — and that is the
    /// whole of the owner's decision of 24 August 2026, not a belt-and-braces
    /// repeat. State moves: a man who applied clean can pick up a judicial
    /// mistake in the week his application stands, and seating him then would
    /// mean the gate was measured at a moment nobody cares about.
    function _requireEligible(address who) private view {
        ReputationStorage.Data storage rep = ReputationStorage.data();
        uint256 xp = rep.xp[who];
        if (xp < MIN_XP_MIRROR) revert ArbiterRegistryFacet.InsufficientXP(xp, MIN_XP_MIRROR);
        uint256 streak = rep.cleanStreak[who];
        if (streak < MIN_CLEAN_STREAK_MIRROR) {
            revert ArbiterRegistryFacet.InsufficientCleanStreak(streak, MIN_CLEAN_STREAK_MIRROR);
        }
    }

    /// Expiry folded in. Every read of an application goes through here; the
    /// raw `state` field is read directly in exactly one place — the
    /// "has this address ever applied" test in `applyForArbiterSeat`, which
    /// asks about the LIST, not about the application.
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

    // -------- APPLICANT: SUBMIT / WITHDRAW --------

    /// Put yourself forward. Costs nothing and locks nothing: the bond is
    /// taken at approval, so an application that is never answered leaves the
    /// applicant's money where it was.
    ///
    /// Gasless (ERC-2771): whoever is worth seating has a record of deals, not
    /// necessarily a balance of ETH.
    function applyForArbiterSeat() external {
        _requireManualAdmissionOpen();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        address caller = _msgSender();

        if (d.isArbiter[caller]) revert ArbiterRegistryFacet.AlreadyArbiter();
        _requireEligible(caller);

        ArbiterRegistryStorage.ArbiterApplication storage a = d.arbiterApplications[caller];
        uint8 st = _effectiveState(a);

        if (st == uint8(ApplicationState.Pending)) {
            revert ApplicationAlreadyPending(a.submittedAt);
        }
        if (st == uint8(ApplicationState.Rejected)) {
            uint256 mayReapplyAt = uint256(a.decidedAt) + APPLICATION_TTL;
            if (block.timestamp < mayReapplyAt) revert RejectedTooRecently(mayReapplyAt);
        }

        // The public list carries every address that ever applied, once. The
        // raw field, not `_effectiveState`, is the right question here: it is
        // asking "is he already in the array", and `None` is the only value
        // that means he is not. `Expired` is a Pending record seen late, and
        // that record was listed when it was filed.
        if (a.state == uint8(ApplicationState.None)) {
            d.arbiterApplicants.push(caller);
        }

        a.state       = uint8(ApplicationState.Pending);
        a.submittedAt = uint64(block.timestamp);
        // A previous refusal or withdrawal leaves its verdict behind; this
        // application is new and carries none.
        a.decidedAt   = 0;
        a.decidedBy   = address(0);

        emit ArbiterApplicationSubmitted(
            caller,
            block.timestamp,
            block.timestamp + APPLICATION_TTL
        );
    }

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

    // -------- OWNER / CHIEF: APPROVE / REJECT --------

    /// Seat the applicant and take his bond, in that order.
    ///
    /// ⚠️ THIS DOOR CARRIES THE TWO LIMITS `addArbiter` CARRIES, and it has to:
    /// it reaches the same result — a new arbiter, seated by a named person —
    /// so any limit that lives only on the other door is a limit with a way
    /// round it.
    ///
    ///   * the chief may not reseat a REMOVED arbiter (`removedAt != 0`).
    ///     Undoing a removal is the mirror of a removal, and removing is not
    ///     his;
    ///   * the chief's bloc may not reach the number of votes that decides an
    ///     appeal. Without this line the chief would grow his bloc through
    ///     here at one press per applicant, and `addArbiter`'s cap would be
    ///     decoration.
    ///
    /// The owner is under neither, exactly as in `addArbiter`: he is the one
    /// who decides the composition, and capping him would cap his own ability
    /// to dilute the chief's bloc.
    ///
    /// ⚠️ `clearRemovalRecord(..., false)` — the suspension is NOT lifted, and
    /// this is the same seam `applyAsArbiter` already settles the same way.
    /// A removal puts a 72-hour window on the man, and that window is the only
    /// thing holding the money on verdicts he took before he was removed. This
    /// door must not become a second way to buy past it. The owner reversing
    /// his own removal has `addArbiter`, which lifts the window on purpose and
    /// says so.
    function approveArbiterApplication(address applicant) external {
        if (applicant == address(0)) revert ApplicantZeroAddress();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        // The ratchet is asked FIRST, and on purpose: once governance is live
        // this door is shut for everyone, and answering a stranger with
        // NotOwnerOrChief would tell him to go and find the right role for a
        // mechanism that no longer exists. The chief in particular stops being
        // recognised at that same moment, so without this order he would be
        // told his ROLE is wrong when what is actually wrong is the DOOR.
        _requireManualAdmissionOpen();
        _requireOwnerOrChief(d);

        ArbiterRegistryStorage.ArbiterApplication storage a = d.arbiterApplications[applicant];
        uint8 st = _effectiveState(a);
        if (st != uint8(ApplicationState.Pending)) revert NoPendingApplication(st);

        if (d.isArbiter[applicant]) revert ArbiterRegistryFacet.AlreadyArbiter();

        // Checked again, a week later, against today's record.
        _requireEligible(applicant);

        if (msg.sender != OwnershipLib.contractOwner()) {
            if (d.removedAt[applicant] != 0) {
                revert ArbiterRegistryFacet.ReseatingRemovedIsOwnerOnly();
            }
            uint256 blocAfter = ArbiterRegistryFacet(address(this)).getChiefBloc() + 1;
            if (blocAfter >= APPEAL_DECIDING_VOTES_MIRROR) {
                revert ArbiterRegistryFacet.ChiefBlocWouldDecideAppeal(
                    blocAfter,
                    APPEAL_DECIDING_VOTES_MIRROR
                );
            }
        }

        // ── Effects before the token call ────────────────────────────────
        // The bond transfer is a call into a contract this facet does not
        // own. Everything that describes the new state is written first, so a
        // token that calls back finds the application already decided and this
        // same function refusing with NoPendingApplication. If the transfer
        // then fails, the whole transaction unwinds and none of it happened.
        a.state     = uint8(ApplicationState.Approved);
        a.decidedAt = uint64(block.timestamp);
        a.decidedBy = msg.sender;

        d.isArbiter[applicant] = true;
        d.arbiterList.push(applicant);
        d.seatedBy[applicant] = msg.sender;
        d.seatedCountBy[msg.sender]++;
        d.arbiterBond[applicant] = ARBITER_BOND_MIRROR;
        ArbiterRegistryStorage.clearRemovalRecord(d, applicant, false);

        _takeBond(applicant);

        emit ArbiterApplicationApproved(applicant, msg.sender, ARBITER_BOND_MIRROR);
        // The registry's own events, declared once and emitted from here so the
        // accountability feed sees a seating with an origin instead of an
        // arbiter who appeared from nowhere. `selfService` is false: a person
        // decided, and his address is in the log.
        emit ArbiterRegistryFacet.ArbiterSeated(applicant, msg.sender, false);
        emit ArbiterRegistryFacet.ArbiterAdded(applicant);
    }

    /// Turn the applicant down, in words, in public.
    ///
    /// The reason is mandatory and it is symmetric with the removal doors: the
    /// chain cannot check why a person was refused, so the person who refuses
    /// him says it himself. The cost of that symmetry is that the refusal is
    /// public too — accepted deliberately by the owner on 24 August 2026, on
    /// the same argument that made removal-for-cause public.
    function rejectArbiterApplication(address applicant, string calldata reason) external {
        if (applicant == address(0)) revert ApplicantZeroAddress();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        // The ratchet is asked FIRST, and on purpose: once governance is live
        // this door is shut for everyone, and answering a stranger with
        // NotOwnerOrChief would tell him to go and find the right role for a
        // mechanism that no longer exists. The chief in particular stops being
        // recognised at that same moment, so without this order he would be
        // told his ROLE is wrong when what is actually wrong is the DOOR.
        _requireManualAdmissionOpen();
        _requireOwnerOrChief(d);

        ArbiterRegistryStorage.ArbiterApplication storage a = d.arbiterApplications[applicant];
        uint8 st = _effectiveState(a);
        if (st != uint8(ApplicationState.Pending)) revert NoPendingApplication(st);

        _requireReason(reason);

        a.state     = uint8(ApplicationState.Rejected);
        a.decidedAt = uint64(block.timestamp);
        a.decidedBy = msg.sender;

        emit ArbiterApplicationRejected(
            applicant,
            msg.sender,
            reason,
            block.timestamp + APPLICATION_TTL
        );
    }

    // -------- OWNER / CHIEF: TAKE BACK AN UNPROVEN SEAT --------

    /// @notice Take back a granted seat that nothing has been earned in. No
    /// pause, no accusation, and the bond goes back in full.
    ///
    /// THE HOLE THIS FILLS. `approveArbiterApplication` seats a man and debits
    /// his 50 USDC in one press. Until this door existed, changing one's mind
    /// afterwards meant `removeArbiterForCause` — a proposal, a 48-hour pause,
    /// a right of reply, a fourteen-day window, a numeric CAUSE and a forfeited
    /// bond. That is, to un-seat somebody who had done nothing at all, a person
    /// had to accuse him of something and take his money. The owner's words on
    /// 11 September 2026: "48 hours is a reset of something already confirmed,
    /// and an application does not need that... if I do not leave an accusation,
    /// what am I waiting 48 hours for. The bond comes back. Nothing is stolen,
    /// nobody is cheated. Plainly a filter."
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
        // Same order and same argument as `approveArbiterApplication` above: a
        // token that calls back finds the seat already gone and this function
        // refusing `NotAnArbiter`, so the bond cannot be paid out twice. If the
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
    /// The two reads cost one staticcall each and buy the approver the
    /// difference between "the applicant has not approved the diamond" and
    /// "the applicant has spent his USDC" — two different messages to send him,
    /// and neither of them is "your transaction failed".
    function _takeBond(address applicant) private {
        address token = FactoryStorage.store().usdc;
        if (token == address(0)) revert BondTokenNotSet();

        uint256 allowed = IBondToken(token).allowance(applicant, address(this));
        if (allowed < ARBITER_BOND_MIRROR) revert BondNotApproved(allowed, ARBITER_BOND_MIRROR);

        uint256 balance = IBondToken(token).balanceOf(applicant);
        if (balance < ARBITER_BOND_MIRROR) revert BondBalanceTooLow(balance, ARBITER_BOND_MIRROR);

        bool ok = IBondToken(token).transferFrom(applicant, address(this), ARBITER_BOND_MIRROR);
        if (!ok) revert BondTransferFailed();
    }

    /// The two refusals BOTH bond doors owe a caller, in one place: there is no
    /// seat, or the seat has already paid.
    ///
    /// ⚠️ THE CHECKS ARE SHARED AND THE WRITE IS NOT, and that is deliberate
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
    function _requireSeatStillOwesItsBond(ArbiterRegistryStorage.Data storage d, address caller)
        private
        view
    {
        if (!d.isArbiter[caller]) revert ArbiterRegistryFacet.NotAnArbiter();
        if (d.arbiterBond[caller] != 0) revert BondAlreadyPosted();
    }

    /// @notice A seated arbiter puts his own 50 USDC behind his seat.
    ///
    /// The door the owner's decision of 8 September 2026 needs and the protocol
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
    /// ⚠️ NOT A FOURTH WAY IN. It refuses anyone who does not already hold a
    /// seat, so it cannot seat its caller. Entry stays with `addArbiter`,
    /// `approveArbiterApplication` and `applyAsArbiter`.
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
    function postArbiterBond() external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        _requireSeatStillOwesItsBond(d, caller);

        // Effects before the token call, the same order and for the same reason
        // as approveArbiterApplication above: a token that calls back finds the
        // bond already recorded and this function refusing BondAlreadyPosted,
        // so the money cannot be taken twice. If the transfer then fails the
        // whole transaction unwinds and none of it happened.
        d.arbiterBond[caller] = ARBITER_BOND_MIRROR;
        _takeBond(caller);

        emit ArbiterBondPosted(caller, ARBITER_BOND_MIRROR);
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
    /// ⚠️ THE AMOUNT IS OURS, NOT THE CALLER'S. `ARBITER_BOND_MIRROR` is what
    /// goes into the permit, so a paper signed for any other number simply does
    /// not verify. There is no argument by which a caller could ask this door to
    /// pull more than the bond, and a form learns the number to sign from
    /// `getApplicationRequirements()` rather than keeping a copy.
    ///
    /// ⚠️ NOTHING IS LEFT STANDING AFTERWARDS. The paper grants exactly the
    /// bond and `_takeBond` spends exactly the bond, so the allowance is back at
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
    /// @param permitDeadline the moment the signature stops being good, as
    ///        signed. Expiry is refused by name here rather than by the token.
    /// @param v,r,s the EIP-2612 signature over (owner=the arbiter,
    ///        spender=this diamond, value=the bond, nonce=his current USDC
    ///        nonce, deadline=`permitDeadline`).
    function postArbiterBondWithPermit(
        uint256 permitDeadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external {
        address caller = _msgSender();

        if (permitDeadline < block.timestamp) {
            revert BondPermitExpired(permitDeadline, block.timestamp);
        }

        address token = FactoryStorage.store().usdc;
        if (token == address(0)) revert BondTokenNotSet();

        // The allowance, granted by the signature rather than by a transaction
        // he cannot afford to send. Replay is the token's nonce and nothing of
        // ours: a paper already spent recovers to a different address inside
        // USDC and is refused there.
        IBondPermitToken(token).permit(
            caller, address(this), ARBITER_BOND_MIRROR, permitDeadline, v, r, s
        );

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        _requireSeatStillOwesItsBond(d, caller);

        // Effects before the token call, the same order and for the same reason
        // as the door above. The write is repeated here rather than shared with
        // it on purpose — see `_requireSeatStillOwesItsBond`.
        d.arbiterBond[caller] = ARBITER_BOND_MIRROR;
        _takeBond(caller);

        emit ArbiterBondPosted(caller, ARBITER_BOND_MIRROR);
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
        return (MIN_XP_MIRROR, MIN_CLEAN_STREAK_MIRROR, ARBITER_BOND_MIRROR, APPLICATION_TTL);
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
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        return d.isArbiter[addr] && d.arbiterBond[addr] != 0;
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
