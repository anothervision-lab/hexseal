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
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
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
